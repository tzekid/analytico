const std = @import("std");
const domain = @import("../domain.zig");
const report = @import("../report.zig");
const duckdb = @import("duckdb.zig");
const deadline = @import("deadline.zig");
const events = @import("events.zig");
const meta = @import("meta.zig");
const traffic = @import("traffic.zig");

const deadline_milliseconds: u32 = 2_000;

pub const TrafficContext = struct {
    strict_mode: bool = false,
    daily_event_ceiling: i64 = meta.default_daily_event_ceiling,
    active_goals: []const meta.Goal = &.{},
    heuristic_available: bool = true,

    pub fn validate(self: TrafficContext) !void {
        if (self.daily_event_ceiling < 1 or
            self.daily_event_ceiling > meta.maximum_daily_event_ceiling)
        {
            return error.InvalidDailyEventCeiling;
        }
        if (self.heuristic_available and
            self.active_goals.len > meta.maximum_active_goals)
        {
            return error.TooManyActiveGoals;
        }
        if (self.strict_mode and !self.heuristic_available) {
            return error.StrictTrafficHeuristicsUnavailable;
        }
    }
};

const PreparedReport = struct {
    statement: duckdb.Statement,
    next_binding: usize,
};

fn prepareClassified(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    tail: []const u8,
    site_id: []const u8,
    context: TrafficContext,
) !PreparedReport {
    try context.validate();
    var goals: [meta.maximum_active_goals]traffic.Goal = undefined;
    const goal_count = if (context.heuristic_available) context.active_goals.len else 0;
    for (context.active_goals[0..goal_count], 0..) |goal, index| {
        goals[index] = .{ .kind = goal.match_kind, .value = goal.match_value };
    }
    const fragment = try traffic.classifierFragment(
        allocator,
        site_id,
        goals[0..goal_count],
        context.heuristic_available,
    );
    var sql = std.Io.Writer.Allocating.init(allocator);
    try sql.writer.writeAll("WITH ");
    try sql.writer.writeAll(fragment.sql);
    try sql.writer.writeAll(", ");
    try sql.writer.writeAll(tail);
    const sql_z = try sql.toOwnedSliceSentinel(0);
    var statement = try event_store.database.prepare(sql_z);
    errdefer statement.deinit();
    var binding: usize = 1;
    for (fragment.bindings) |value| {
        switch (value) {
            .text => |text| try statement.bindText(binding, text),
            .integer => |integer| try statement.bindInt64(binding, integer),
        }
        binding += 1;
    }
    return .{ .statement = statement, .next_binding = binding };
}

fn prepareProduct(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    default_sql: [:0]const u8,
    site_id: []const u8,
    context: TrafficContext,
) !PreparedReport {
    try context.validate();
    if (context.strict_mode) {
        if (!std.mem.startsWith(u8, default_sql, "WITH ")) {
            return error.InvalidProductSql;
        }
        var tail = std.Io.Writer.Allocating.init(allocator);
        try tail.writer.writeAll(
            "events AS (SELECT * EXCLUDE (d34_person_key)" ++
                " FROM site_product_events WHERE session_id NOT IN" ++
                " (SELECT session_id FROM d34_current_suspected_sessions)), ",
        );
        try tail.writer.writeAll(default_sql[5..]);
        return prepareClassified(
            allocator,
            event_store,
            tail.written(),
            site_id,
            context,
        );
    }
    return .{
        .statement = try event_store.database.prepare(default_sql),
        .next_binding = 1,
    };
}

pub const IdentityCoverage = struct {
    total_people: i64,
    persistent_people: i64,
    ephemeral_people: i64,
    legacy_people: i64,
    persistent_basis_points: u16,
    persistent_since_local_date: ?[]u8,
};

const identity_coverage_sql: [:0]const u8 =
    \\WITH meaningful AS (
    \\  SELECT e.site_local_date, e.anonymous_id, e.identity_quality,
    \\         COALESCE(l.user_id, '') AS linked_user_id
    \\  FROM events e
    \\  LEFT JOIN identity_links l
    \\    ON l.site_id = e.site_id AND l.anonymous_id = e.anonymous_id
    \\  WHERE e.site_id = ?
    \\    AND e.site_local_date BETWEEN CAST(? AS DATE) AND CAST(? AS DATE)
    \\    AND e.kind IN (1, 2)
    \\    AND e.traffic_class IN (1, 5)
    \\), people AS (
    \\  SELECT DISTINCT CASE
    \\    WHEN identity_quality = 1 AND linked_user_id != ''
    \\      THEN 'u:' || linked_user_id
    \\    WHEN identity_quality = 1
    \\      THEN 'a:' || CAST(anonymous_id AS VARCHAR)
    \\    WHEN identity_quality = 2
    \\      THEN 'e:' || CAST(anonymous_id AS VARCHAR)
    \\    WHEN identity_quality = 3
    \\      THEN 'l:' || CAST(anonymous_id AS VARCHAR)
    \\    ELSE NULL
    \\  END AS canonical_key, identity_quality
    \\  FROM meaningful
    \\)
    \\SELECT count(*),
    \\       count(*) FILTER (WHERE identity_quality = 1),
    \\       count(*) FILTER (WHERE identity_quality = 2),
    \\       count(*) FILTER (WHERE identity_quality = 3),
    \\       (SELECT CAST(min(site_local_date) AS VARCHAR)
    \\        FROM events
    \\        WHERE site_id = ? AND kind IN (1, 2)
    \\          AND traffic_class IN (1, 5)
    \\          AND identity_quality = 1)
    \\FROM people
    \\WHERE canonical_key IS NOT NULL
;
const session_cte =
    \\WITH filtered_all AS (
    \\  SELECT * FROM events
    \\  WHERE site_id = ?
    \\    AND received_date_utc BETWEEN CAST(? AS DATE) AND CAST(? AS DATE)
    \\),
    \\filtered AS (
    \\  SELECT * FROM filtered_all
    \\  WHERE traffic_class IN (1, 5)
    \\),
    \\sessioned AS (
    \\  SELECT * FROM filtered
    \\)
;

const page_position_cte = session_cte ++
    \\,
    \\page_positions AS (
    \\  SELECT *,
    \\    row_number() OVER (
    \\      PARTITION BY session_id
    \\      ORDER BY received_at_utc_micros, event_id
    \\    ) AS first_position,
    \\    row_number() OVER (
    \\      PARTITION BY session_id
    \\      ORDER BY received_at_utc_micros DESC, event_id DESC
    \\    ) AS last_position
    \\  FROM sessioned
    \\  WHERE kind = 1
    \\)
;

const first_event_cte = session_cte ++
    \\,
    \\first_events AS (
    \\  SELECT *,
    \\    row_number() OVER (
    \\      PARTITION BY session_id
    \\      ORDER BY received_at_utc_micros, event_id
    \\    ) AS first_position
    \\  FROM sessioned
    \\)
;

const overview_sql: [:0]const u8 =
    \\SELECT
    \\  count(*) FILTER (
    \\    WHERE kind = 1 AND traffic_class IN (1, 5)
    \\  ),
    \\  count(*) FILTER (
    \\    WHERE visitor_day_start AND traffic_class IN (1, 5)
    \\  ),
    \\  count(*) FILTER (
    \\    WHERE session_start AND traffic_class IN (1, 5)
    \\  ),
    \\  count(*) FILTER (
    \\    WHERE kind = 2 AND traffic_class IN (1, 5)
    \\  ),
    \\  count(*) FILTER (
    \\    WHERE traffic_class IN (2, 3)
    \\  )
    \\FROM events
    \\WHERE site_id = ?
    \\  AND received_date_utc BETWEEN CAST(? AS DATE) AND CAST(? AS DATE)
;

const strict_overview_sql_tail =
    \\range_product AS (
    \\  SELECT e.* FROM site_product_events e
    \\  WHERE e.site_id = ?
    \\    AND e.received_date_utc BETWEEN CAST(? AS DATE) AND CAST(? AS DATE)
    \\    AND e.session_id NOT IN (
    \\      SELECT session_id FROM d34_current_suspected_sessions
    \\    )
    \\)
    \\SELECT
    \\  count(*) FILTER (WHERE kind = 1),
    \\  count(DISTINCT (received_date_utc, visitor_day_id)),
    \\  count(DISTINCT session_id),
    \\  count(*) FILTER (WHERE kind = 2),
    \\  (SELECT count(*) FROM events
    \\   WHERE site_id = ?
    \\     AND received_date_utc BETWEEN CAST(? AS DATE) AND CAST(? AS DATE)
    \\     AND traffic_class IN (2, 3))
    \\FROM range_product
;

const traffic_quality_sql_tail =
    \\params AS (
    \\  SELECT ?::VARCHAR AS site_id, CAST(? AS DATE) AS start_date,
    \\         CAST(? AS DATE) AS end_date, ?::BOOLEAN AS strict_mode,
    \\         ?::BIGINT AS daily_event_ceiling, ?::BOOLEAN AS heuristic_available
    \\), range_events AS (
    \\  SELECT e.site_id, e.received_date_utc, e.site_local_date, e.kind,
    \\    e.anonymous_id,
    \\    e.identity_quality, e.session_id, e.visitor_day_start,
    \\    e.traffic_class, e.classifier_version, e.bot_rule,
    \\    e.signal_version, e.navigator_webdriver,
    \\    e.trusted_interactions, e.was_visible, e.was_prerendered,
    \\    e.client_hint_consistency, e.accept_language_present, e.network_day_id
    \\  FROM events e, params p
    \\  WHERE e.site_id = p.site_id
    \\    AND e.received_date_utc BETWEEN p.start_date AND p.end_date
    \\), eligible_range AS (
    \\  SELECT * FROM range_events
    \\  WHERE traffic_class IN (1, 5)
    \\), meaningful AS (
    \\  SELECT e.anonymous_id, e.identity_quality,
    \\         COALESCE(l.user_id, '') AS linked_user_id
    \\  FROM eligible_range e
    \\  LEFT JOIN identity_links l
    \\    ON l.site_id = e.site_id AND l.anonymous_id = e.anonymous_id
    \\  WHERE e.kind IN (1, 2)
    \\), people AS (
    \\  SELECT DISTINCT CASE
    \\    WHEN identity_quality = 1 AND linked_user_id != ''
    \\      THEN 'u:' || linked_user_id
    \\    WHEN identity_quality = 1
    \\      THEN 'a:' || CAST(anonymous_id AS VARCHAR)
    \\    WHEN identity_quality = 2
    \\      THEN 'e:' || CAST(anonymous_id AS VARCHAR)
    \\    WHEN identity_quality = 3
    \\      THEN 'l:' || CAST(anonymous_id AS VARCHAR)
    \\    ELSE NULL
    \\  END AS canonical_key, identity_quality
    \\  FROM meaningful
    \\), person_summary AS (
    \\  SELECT count(*) AS total,
    \\    count(*) FILTER (WHERE identity_quality = 1) AS persistent,
    \\    count(*) FILTER (WHERE identity_quality = 2) AS ephemeral,
    \\    count(*) FILTER (WHERE identity_quality = 3) AS legacy
    \\  FROM people WHERE canonical_key IS NOT NULL
    \\), identity_summary AS (
    \\  SELECT
    \\    count(*) FILTER (WHERE identity_quality = 1) AS persistent_events,
    \\    count(*) FILTER (
    \\      WHERE identity_quality = 1 AND visitor_day_start
    \\    ) AS persistent_visitor_days,
    \\    count(*) FILTER (WHERE identity_quality = 2) AS ephemeral_events,
    \\    count(*) FILTER (
    \\      WHERE identity_quality = 2 AND visitor_day_start
    \\    ) AS ephemeral_visitor_days,
    \\    count(*) FILTER (WHERE identity_quality = 3) AS legacy_events,
    \\    count(*) FILTER (
    \\      WHERE identity_quality = 3 AND visitor_day_start
    \\    ) AS legacy_visitor_days
    \\  FROM eligible_range
    \\), traffic_summary AS (
    \\  SELECT
    \\    count(*) FILTER (
    \\      WHERE traffic_class = 4 AND bot_rule = 'exclude.tracker'
    \\    ) AS tracker_events,
    \\    count(*) FILTER (
    \\      WHERE traffic_class = 4 AND bot_rule = 'exclude.network'
    \\    ) AS network_events,
    \\    count(*) FILTER (
    \\      WHERE traffic_class = 4 AND bot_rule = 'exclude.both'
    \\    ) AS both_events,
    \\    count(*) FILTER (WHERE traffic_class = 1) AS human_presumed,
    \\    count(*) FILTER (WHERE traffic_class = 2) AS declared_bot,
    \\    count(*) FILTER (WHERE traffic_class = 3) AS automation,
    \\    count(*) FILTER (WHERE traffic_class = 4) AS excluded,
    \\    count(*) FILTER (WHERE traffic_class = 5) AS suspected,
    \\    count(*) FILTER (WHERE signal_version = 1)
    \\      AS client_signal_v1_events,
    \\    count(*) FILTER (WHERE navigator_webdriver) AS webdriver_events,
    \\    count(*) FILTER (WHERE trusted_interactions != 0)
    \\      AS trusted_interaction_events,
    \\    count(*) FILTER (WHERE was_visible) AS visible_events,
    \\    count(*) FILTER (WHERE was_prerendered) AS prerendered_events,
    \\    count(*) FILTER (WHERE client_hint_consistency = 2)
    \\      AS client_hint_mismatch_events,
    \\    count(*) FILTER (WHERE client_hint_consistency = 3)
    \\      AS client_hint_absent_expected_events,
    \\    count(*) FILTER (WHERE accept_language_present)
    \\      AS accept_language_present_events
    \\  FROM range_events
    \\), range_sessions AS (
    \\  SELECT DISTINCT session_id FROM eligible_range
    \\  WHERE kind IN (1, 2)
    \\), session_quality AS (
    \\  SELECT count(*) FILTER (
    \\    WHERE meaningful_events = 1 AND engagement_ms = 0 AND max_scroll = 0
    \\  ) AS zero_engagement_single_event_sessions
    \\  FROM (
    \\    SELECT e.session_id,
    \\      count(*) FILTER (WHERE kind IN (1, 2)) AS meaningful_events,
    \\      sum(engagement_ms) AS engagement_ms,
    \\      max(max_scroll_depth) AS max_scroll
    \\    FROM events e
    \\    JOIN range_sessions r ON r.session_id = e.session_id
    \\    JOIN params p ON p.site_id = e.site_id
    \\    WHERE e.traffic_class IN (1, 5)
    \\    GROUP BY e.session_id
    \\  ) sessions
    \\), anonymous_ranked AS (
    \\  SELECT e.anonymous_id, e.received_date_utc, e.network_day_id,
    \\    row_number() OVER (PARTITION BY e.anonymous_id
    \\      ORDER BY e.received_at_utc_micros, e.event_id) AS position
    \\  FROM site_product_events e
    \\  WHERE e.kind IN (1, 2) AND e.identity_quality IN (1, 2)
    \\), anonymous_first AS (
    \\  SELECT anonymous_id, received_date_utc AS first_date, network_day_id
    \\  FROM anonymous_ranked WHERE position = 1
    \\), mint_group_counts AS (
    \\  SELECT first_date, network_day_id, count(*) AS minted_identities
    \\  FROM anonymous_first
    \\  WHERE network_day_id != from_hex('00000000000000000000000000000000')
    \\  GROUP BY first_date, network_day_id
    \\), heuristic_summary AS (
    \\  SELECT
    \\    count(*) AS raw_candidates,
    \\    count(*) FILTER (WHERE NOT v.contradicted) AS current_suspected,
    \\    count(*) FILTER (WHERE v.contradicted) AS contradicted
    \\  FROM d34_raw_candidates c
    \\  JOIN d34_candidate_verdicts v USING (session_id), params p
    \\  WHERE c.received_date_utc BETWEEN p.start_date AND p.end_date
    \\), health_summary AS (
    \\  SELECT
    \\    (SELECT count(*) FROM range_events) AS accepted_events,
    \\    (SELECT count(*) FROM (
    \\      SELECT e.site_local_date
    \\      FROM events e, params p
    \\      WHERE e.site_id = p.site_id
    \\        AND e.site_local_date BETWEEN p.start_date AND p.end_date
    \\      GROUP BY e.site_local_date, p.daily_event_ceiling
    \\      HAVING count(*) >= p.daily_event_ceiling
    \\    ) reached) AS ceiling_reached_days,
    \\    (SELECT count(*) FROM mint_group_counts m, params p
    \\      WHERE m.first_date BETWEEN p.start_date AND p.end_date
    \\        AND m.minted_identities > 64) AS mint_anomaly_groups,
    \\    (SELECT COALESCE(max(m.minted_identities), 0)
    \\      FROM mint_group_counts m, params p
    \\      WHERE m.first_date BETWEEN p.start_date AND p.end_date)
    \\      AS maximum_minted_identities
    \\), dates AS (
    \\  SELECT p.start_date + CAST(day AS INTEGER) AS date
    \\  FROM params p,
    \\    range(date_diff('day', p.start_date, p.end_date) + 1) days(day)
    \\), daily AS (
    \\  SELECT d.date,
    \\    (SELECT count(*) FROM anonymous_first a WHERE a.first_date = d.date)
    \\      AS new_anonymous_identities,
    \\    (SELECT count(*) FROM range_events e
    \\      WHERE e.received_date_utc = d.date
    \\        AND e.traffic_class IN (2, 3))
    \\      AS bot_events,
    \\    (SELECT count(*) FROM d34_raw_candidates c
    \\      JOIN d34_candidate_verdicts v USING (session_id)
    \\      WHERE c.received_date_utc = d.date AND NOT v.contradicted)
    \\      AS suspected_sessions,
    \\    (SELECT count(*) FROM events e, params p
    \\      WHERE e.site_id = p.site_id AND e.site_local_date = d.date)
    \\      AS accepted_events,
    \\    (SELECT count(*) FROM mint_group_counts m
    \\      WHERE m.first_date = d.date AND m.minted_identities > 64)
    \\      AS mint_anomaly_groups,
    \\    (SELECT COALESCE(max(m.minted_identities), 0)
    \\      FROM mint_group_counts m WHERE m.first_date = d.date)
    \\      AS maximum_minted_identities
    \\  FROM dates d
    \\), daily_page AS (
    \\  SELECT * FROM daily ORDER BY date
    \\  LIMIT ? OFFSET ?
    \\), rule_counts AS (
    \\  SELECT traffic_class, classifier_version, bot_rule, count(*) AS events
    \\  FROM range_events
    \\  GROUP BY traffic_class, classifier_version, bot_rule
    \\  ORDER BY traffic_class, classifier_version, bot_rule
    \\  LIMIT 64
    \\)
    \\SELECT 0 AS row_kind, CAST(d.date AS VARCHAR) AS date,
    \\  d.new_anonymous_identities, d.bot_events,
    \\  p.total, p.persistent, p.ephemeral, p.legacy,
    \\  i.persistent_visitor_days + i.ephemeral_visitor_days +
    \\    i.legacy_visitor_days AS visitor_days,
    \\  s.zero_engagement_single_event_sessions,
    \\  i.persistent_events, i.persistent_visitor_days,
    \\  i.ephemeral_events, i.ephemeral_visitor_days,
    \\  i.legacy_events, i.legacy_visitor_days,
    \\  t.tracker_events, t.network_events, t.both_events,
    \\  t.human_presumed, t.declared_bot, t.automation, t.excluded,
    \\  t.suspected, t.client_signal_v1_events, t.webdriver_events,
    \\  t.trusted_interaction_events, t.visible_events, t.prerendered_events,
    \\  t.client_hint_mismatch_events, t.client_hint_absent_expected_events,
    \\  t.accept_language_present_events,
    \\  p2.heuristic_available, 1 AS heuristic_version,
    \\  h.raw_candidates, h.current_suspected, h.contradicted,
    \\  p2.strict_mode, p2.daily_event_ceiling, hs.accepted_events,
    \\  hs.ceiling_reached_days, hs.mint_anomaly_groups,
    \\  hs.maximum_minted_identities,
    \\  d.suspected_sessions, d.accepted_events, d.mint_anomaly_groups,
    \\  d.maximum_minted_identities,
    \\  d.accepted_events >= p2.daily_event_ceiling AS ceiling_reached,
    \\  0 AS rule_class, 0 AS rule_version, '' AS rule_id, 0 AS rule_events
    \\FROM daily_page d
    \\CROSS JOIN person_summary p
    \\CROSS JOIN identity_summary i
    \\CROSS JOIN session_quality s
    \\CROSS JOIN traffic_summary t
    \\CROSS JOIN heuristic_summary h
    \\CROSS JOIN health_summary hs
    \\CROSS JOIN params p2
    \\UNION ALL
    \\SELECT 1, '',
    \\  0, 0,
    \\  0, 0, 0, 0,
    \\  0, 0,
    \\  0, 0, 0, 0, 0, 0,
    \\  0, 0, 0,
    \\  0, 0, 0, 0, 0,
    \\  0, 0, 0, 0, 0, 0, 0, 0,
    \\  FALSE, 0,
    \\  0, 0, 0,
    \\  FALSE, 0, 0, 0, 0, 0,
    \\  0, 0, 0, 0, FALSE,
    \\  r.traffic_class, r.classifier_version, r.bot_rule, r.events
    \\FROM rule_counts r
    \\ORDER BY row_kind, date, rule_class, rule_version, rule_id
;

fn pagedSql(
    comptime body: []const u8,
    comptime order: report.Sort,
) [:0]const u8 {
    return body ++ switch (order) {
        .count =>
        \\ ORDER BY value_primary DESC, label ASC
        \\ LIMIT ? OFFSET ?
        ,
        .label =>
        \\ ORDER BY label ASC, value_primary DESC
        \\ LIMIT ? OFFSET ?
        ,
    };
}

fn selectPagedSql(
    comptime body: []const u8,
    sort: report.Sort,
) [:0]const u8 {
    return switch (sort) {
        .count => pagedSql(body, .count),
        .label => pagedSql(body, .label),
    };
}

const pages_body = session_cte ++
    \\SELECT path AS label,
    \\       count(*) AS value_primary,
    \\       count(DISTINCT visitor_day_id) AS value_secondary
    \\FROM sessioned
    \\WHERE kind = 1
    \\GROUP BY path
;
fn pagePositionBody(comptime position: []const u8) []const u8 {
    return page_position_cte ++
        \\SELECT path AS label,
        \\       count(*) AS value_primary,
        \\       count(DISTINCT visitor_day_id) AS value_secondary
        \\FROM page_positions
        \\WHERE
    ++ " " ++ position ++
        \\ = 1
        \\GROUP BY path
    ;
}

const sources_body = page_position_cte ++
    \\SELECT CASE WHEN referrer_host = ''
    \\            THEN 'Direct / Unknown' ELSE referrer_host END AS label,
    \\       count(*) AS value_primary,
    \\       count(DISTINCT visitor_day_id) AS value_secondary
    \\FROM page_positions
    \\WHERE first_position = 1
    \\GROUP BY label
;
fn campaignBody(comptime expression: []const u8) []const u8 {
    return page_position_cte ++
        \\SELECT
    ++ " " ++ expression ++
        \\ AS label,
        \\       count(*) AS value_primary,
        \\       count(DISTINCT visitor_day_id) AS value_secondary
        \\FROM page_positions
        \\WHERE first_position = 1
        \\  AND (utm_source <> '' OR utm_medium <> '' OR utm_campaign <> ''
        \\       OR utm_term <> '' OR utm_content <> '')
        \\GROUP BY label
    ;
}

fn dimensionBody(comptime expression: []const u8) []const u8 {
    return first_event_cte ++
        \\SELECT
    ++ " " ++ expression ++
        \\ AS label,
        \\       count(*) AS value_primary,
        \\       count(DISTINCT visitor_day_id) AS value_secondary
        \\FROM first_events
        \\WHERE first_position = 1
        \\GROUP BY label
    ;
}

const events_body = session_cte ++
    \\SELECT event_name AS label,
    \\       count(*) AS value_primary,
    \\       count(DISTINCT session_id)
    \\         AS value_secondary
    \\FROM sessioned
    \\WHERE kind = 2
    \\GROUP BY event_name
;
const campaign_all_expression =
    \\concat(
    \\  'source=', utm_source,
    \\  ' | medium=', utm_medium,
    \\  ' | campaign=', utm_campaign,
    \\  ' | term=', utm_term,
    \\  ' | content=', utm_content
    \\)
;

const goal_event_sql: [:0]const u8 = session_cte ++
    \\,
    \\matching AS (
    \\  SELECT * FROM sessioned WHERE event_name = ?
    \\)
    \\SELECT
    \\  (SELECT count(*) FROM matching),
    \\  (SELECT count(DISTINCT session_id) FROM matching),
    \\  (SELECT count(DISTINCT session_id) FROM sessioned)
;
const goal_path_sql: [:0]const u8 = session_cte ++
    \\,
    \\matching AS (
    \\  SELECT * FROM sessioned WHERE path = ?
    \\)
    \\SELECT
    \\  (SELECT count(*) FROM matching),
    \\  (SELECT count(DISTINCT session_id) FROM matching),
    \\  (SELECT count(DISTINCT session_id) FROM sessioned)
;
const goal_prefix_sql: [:0]const u8 = session_cte ++
    \\,
    \\matching AS (
    \\  SELECT * FROM sessioned WHERE starts_with(path, ?)
    \\)
    \\SELECT
    \\  (SELECT count(*) FROM matching),
    \\  (SELECT count(DISTINCT session_id) FROM matching),
    \\  (SELECT count(DISTINCT session_id) FROM sessioned)
;
const funnel_sql: [:0]const u8 =
    \\WITH step_defs(step_index, match_kind, match_value) AS (
    \\  VALUES
    \\    (0, ?, ?), (1, ?, ?), (2, ?, ?), (3, ?, ?),
    \\    (4, ?, ?), (5, ?, ?), (6, ?, ?), (7, ?, ?)
    \\),
    \\active_steps AS (
    \\  SELECT * FROM step_defs WHERE step_index < ?
    \\),
    \\filtered AS (
    \\  SELECT session_id, session_start, received_at_utc_micros,
    \\         event_id, event_name, path
    \\  FROM events
    \\  WHERE site_id = ?
    \\    AND received_date_utc BETWEEN CAST(? AS DATE) AND CAST(? AS DATE)
    \\    AND traffic_class IN (1, 5)
    \\),
    \\sessioned AS (
    \\  SELECT * FROM filtered
    \\),
    \\candidate_events AS (
    \\  SELECT e.session_id, e.received_at_utc_micros, e.event_id,
    \\         s.step_index
    \\  FROM sessioned e
    \\  JOIN active_steps s ON
    \\       ((s.match_kind = 1 AND e.event_name = s.match_value)
    \\     OR (s.match_kind = 2 AND e.path = s.match_value)
    \\     OR (s.match_kind = 3 AND starts_with(e.path, s.match_value)))
    \\),
    \\step_0 AS (
    \\  SELECT e.session_id,
    \\         min((e.received_at_utc_micros, e.event_id)) AS matched_at
    \\  FROM candidate_events e
    \\  WHERE e.step_index = 0
    \\  GROUP BY e.session_id
    \\),
    \\step_1 AS (
    \\  SELECT e.session_id,
    \\         min((e.received_at_utc_micros, e.event_id)) AS matched_at
    \\  FROM candidate_events e
    \\  JOIN step_0 p ON p.session_id = e.session_id
    \\  WHERE e.step_index = 1
    \\    AND (e.received_at_utc_micros, e.event_id) > p.matched_at
    \\  GROUP BY e.session_id
    \\),
    \\step_2 AS (
    \\  SELECT e.session_id,
    \\         min((e.received_at_utc_micros, e.event_id)) AS matched_at
    \\  FROM candidate_events e
    \\  JOIN step_1 p ON p.session_id = e.session_id
    \\  WHERE e.step_index = 2
    \\    AND (e.received_at_utc_micros, e.event_id) > p.matched_at
    \\  GROUP BY e.session_id
    \\),
    \\step_3 AS (
    \\  SELECT e.session_id,
    \\         min((e.received_at_utc_micros, e.event_id)) AS matched_at
    \\  FROM candidate_events e
    \\  JOIN step_2 p ON p.session_id = e.session_id
    \\  WHERE e.step_index = 3
    \\    AND (e.received_at_utc_micros, e.event_id) > p.matched_at
    \\  GROUP BY e.session_id
    \\),
    \\step_4 AS (
    \\  SELECT e.session_id,
    \\         min((e.received_at_utc_micros, e.event_id)) AS matched_at
    \\  FROM candidate_events e
    \\  JOIN step_3 p ON p.session_id = e.session_id
    \\  WHERE e.step_index = 4
    \\    AND (e.received_at_utc_micros, e.event_id) > p.matched_at
    \\  GROUP BY e.session_id
    \\),
    \\step_5 AS (
    \\  SELECT e.session_id,
    \\         min((e.received_at_utc_micros, e.event_id)) AS matched_at
    \\  FROM candidate_events e
    \\  JOIN step_4 p ON p.session_id = e.session_id
    \\  WHERE e.step_index = 5
    \\    AND (e.received_at_utc_micros, e.event_id) > p.matched_at
    \\  GROUP BY e.session_id
    \\),
    \\step_6 AS (
    \\  SELECT e.session_id,
    \\         min((e.received_at_utc_micros, e.event_id)) AS matched_at
    \\  FROM candidate_events e
    \\  JOIN step_5 p ON p.session_id = e.session_id
    \\  WHERE e.step_index = 6
    \\    AND (e.received_at_utc_micros, e.event_id) > p.matched_at
    \\  GROUP BY e.session_id
    \\),
    \\step_7 AS (
    \\  SELECT e.session_id,
    \\         min((e.received_at_utc_micros, e.event_id)) AS matched_at
    \\  FROM candidate_events e
    \\  JOIN step_6 p ON p.session_id = e.session_id
    \\  WHERE e.step_index = 7
    \\    AND (e.received_at_utc_micros, e.event_id) > p.matched_at
    \\  GROUP BY e.session_id
    \\),
    \\progress_counts(step_index, sessions) AS (
    \\  SELECT 0, count(*) FROM step_0
    \\  UNION ALL SELECT 1, count(*) FROM step_1
    \\  UNION ALL SELECT 2, count(*) FROM step_2
    \\  UNION ALL SELECT 3, count(*) FROM step_3
    \\  UNION ALL SELECT 4, count(*) FROM step_4
    \\  UNION ALL SELECT 5, count(*) FROM step_5
    \\  UNION ALL SELECT 6, count(*) FROM step_6
    \\  UNION ALL SELECT 7, count(*) FROM step_7
    \\),
    \\eligible AS (
    \\  SELECT count(DISTINCT session_id) AS sessions FROM sessioned
    \\)
    \\SELECT s.step_index, p.sessions, eligible.sessions
    \\FROM active_steps s
    \\CROSS JOIN eligible
    \\JOIN progress_counts p ON p.step_index = s.step_index
    \\ORDER BY s.step_index
;

pub fn run(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: report.Request,
    site_id: []const u8,
    goal: ?meta.Goal,
    funnel_steps: ?[]const meta.FunnelStep,
    traffic_context: TrafficContext,
) !report.Result {
    return runWithTimeout(
        allocator,
        event_store,
        request,
        site_id,
        goal,
        funnel_steps,
        traffic_context,
        deadline_milliseconds,
    );
}

pub fn identityCoverage(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    site_id: []const u8,
    start_local_date: []const u8,
    end_local_date: []const u8,
    traffic_context: TrafficContext,
    timeout_ms: u32,
) !IdentityCoverage {
    try domain.validateUuid(site_id);
    try domain.validateDate(start_local_date);
    try domain.validateDate(end_local_date);
    const start_day = try report.dateDay(start_local_date);
    const end_day = try report.dateDay(end_local_date);
    if (end_day < start_day or
        end_day - start_day + 1 > report.maximum_range_days or
        timeout_ms == 0 or timeout_ms > deadline_milliseconds)
    {
        return error.InvalidIdentityCoverageRange;
    }
    const prepared = try prepareProduct(
        allocator,
        event_store,
        identity_coverage_sql,
        site_id,
        traffic_context,
    );
    var statement = prepared.statement;
    defer statement.deinit();
    const binding = prepared.next_binding;
    try statement.bindText(binding, site_id);
    try statement.bindText(binding + 1, start_local_date);
    try statement.bindText(binding + 2, end_local_date);
    try statement.bindText(binding + 3, site_id);
    var result = try deadline.execute(&event_store.database, &statement, timeout_ms);
    defer result.deinit();
    if (result.rowCount() != 1 or result.columnCount() != 5) {
        return error.InvalidIdentityCoverageResult;
    }
    const total = result.int64(0, 0);
    const persistent = result.int64(1, 0);
    const ephemeral = result.int64(2, 0);
    const legacy = result.int64(3, 0);
    if (total < 0 or persistent < 0 or ephemeral < 0 or legacy < 0 or
        persistent + ephemeral + legacy != total)
    {
        return error.InvalidIdentityCoverageResult;
    }
    const basis_points: u16 = if (total == 0)
        0
    else
        @intCast(@divTrunc(
            std.math.mul(i64, persistent, 10_000) catch
                return error.InvalidIdentityCoverageResult,
            total,
        ));
    return .{
        .total_people = total,
        .persistent_people = persistent,
        .ephemeral_people = ephemeral,
        .legacy_people = legacy,
        .persistent_basis_points = basis_points,
        .persistent_since_local_date = if (result.isNull(4, 0))
            null
        else
            try result.text(allocator, 4, 0),
    };
}

pub fn runWithTimeout(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: report.Request,
    site_id: []const u8,
    goal: ?meta.Goal,
    funnel_steps: ?[]const meta.FunnelStep,
    traffic_context: TrafficContext,
    timeout_ms: u32,
) !report.Result {
    if (timeout_ms == 0 or timeout_ms > deadline_milliseconds) {
        return error.InvalidReportTimeout;
    }
    try domain.validateUuid(site_id);
    return switch (request.kind) {
        .overview => .{ .overview = try overview(
            allocator,
            event_store,
            request,
            site_id,
            traffic_context,
            timeout_ms,
        ) },
        .traffic_quality => .{ .traffic_quality = try trafficQuality(
            allocator,
            event_store,
            request,
            site_id,
            traffic_context,
            timeout_ms,
        ) },
        .pages => .{ .list = try list(
            allocator,
            event_store,
            request,
            site_id,
            selectPagedSql(pages_body, request.sort),
            "path",
            "page_views",
            "visitor_days",
            traffic_context,
            timeout_ms,
        ) },
        .entries => .{ .list = try list(
            allocator,
            event_store,
            request,
            site_id,
            selectPagedSql(pagePositionBody("first_position"), request.sort),
            "path",
            "sessions",
            "visitor_days",
            traffic_context,
            timeout_ms,
        ) },
        .exits => .{ .list = try list(
            allocator,
            event_store,
            request,
            site_id,
            selectPagedSql(pagePositionBody("last_position"), request.sort),
            "path",
            "sessions",
            "visitor_days",
            traffic_context,
            timeout_ms,
        ) },
        .sources => .{ .list = try list(
            allocator,
            event_store,
            request,
            site_id,
            selectPagedSql(sources_body, request.sort),
            "source",
            "sessions",
            "visitor_days",
            traffic_context,
            timeout_ms,
        ) },
        .campaigns => .{ .list = try campaignList(
            allocator,
            event_store,
            request,
            site_id,
            traffic_context,
            timeout_ms,
        ) },
        .countries => .{ .list = try dimensionList(
            allocator,
            event_store,
            request,
            site_id,
            .country,
            traffic_context,
            timeout_ms,
        ) },
        .browsers => .{ .list = try dimensionList(
            allocator,
            event_store,
            request,
            site_id,
            .browser,
            traffic_context,
            timeout_ms,
        ) },
        .operating_systems => .{ .list = try dimensionList(
            allocator,
            event_store,
            request,
            site_id,
            .operating_system,
            traffic_context,
            timeout_ms,
        ) },
        .devices => .{ .list = try dimensionList(
            allocator,
            event_store,
            request,
            site_id,
            .device,
            traffic_context,
            timeout_ms,
        ) },
        .events => .{ .list = try list(
            allocator,
            event_store,
            request,
            site_id,
            selectPagedSql(events_body, request.sort),
            "event",
            "event_count",
            "sessions",
            traffic_context,
            timeout_ms,
        ) },
        .goal => .{ .goal = try goalReport(
            allocator,
            event_store,
            request,
            site_id,
            goal orelse return error.GoalNotFound,
            traffic_context,
            timeout_ms,
        ) },
        .funnel => .{ .funnel = try funnelReport(
            allocator,
            event_store,
            request,
            site_id,
            funnel_steps orelse return error.FunnelNotFound,
            traffic_context,
            timeout_ms,
        ) },
    };
}

fn overview(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: report.Request,
    site_id: []const u8,
    traffic_context: TrafficContext,
    timeout_ms: u32,
) !report.Overview {
    const prepared = if (traffic_context.strict_mode)
        try prepareClassified(
            allocator,
            event_store,
            strict_overview_sql_tail,
            site_id,
            traffic_context,
        )
    else
        PreparedReport{
            .statement = try event_store.database.prepare(overview_sql),
            .next_binding = 1,
        };
    var statement = prepared.statement;
    defer statement.deinit();
    const binding = prepared.next_binding;
    try statement.bindText(binding, site_id);
    try statement.bindText(binding + 1, request.start_date);
    try statement.bindText(binding + 2, request.end_date);
    if (traffic_context.strict_mode) {
        try statement.bindText(binding + 3, site_id);
        try statement.bindText(binding + 4, request.start_date);
        try statement.bindText(binding + 5, request.end_date);
    }
    var result = try deadline.execute(&event_store.database, &statement, timeout_ms);
    defer result.deinit();
    if (result.rowCount() != 1 or result.columnCount() != 5) {
        return error.InvalidReportResult;
    }
    return .{
        .page_views = result.int64(0, 0),
        .visitor_days = result.int64(1, 0),
        .sessions = result.int64(2, 0),
        .custom_events = result.int64(3, 0),
        .bot_events = result.int64(4, 0),
    };
}

pub fn trafficQuality(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: report.Request,
    site_id: []const u8,
    traffic_context: TrafficContext,
    timeout_ms: u32,
) !report.TrafficQuality {
    const prepared = try prepareClassified(
        allocator,
        event_store,
        traffic_quality_sql_tail,
        site_id,
        traffic_context,
    );
    var statement = prepared.statement;
    defer statement.deinit();
    const binding = prepared.next_binding;
    try statement.bindText(binding, site_id);
    try statement.bindText(binding + 1, request.start_date);
    try statement.bindText(binding + 2, request.end_date);
    try statement.bindInt64(binding + 3, @intFromBool(traffic_context.strict_mode));
    try statement.bindInt64(binding + 4, traffic_context.daily_event_ceiling);
    try statement.bindInt64(
        binding + 5,
        @intFromBool(traffic_context.heuristic_available),
    );
    try statement.bindInt64(binding + 6, @as(i64, request.limit) + 1);
    const offset = try request.offset();
    const range_days = @as(i64, request.end_day - request.start_day + 1);
    if (offset >= range_days) return error.InvalidReportPage;
    try statement.bindInt64(binding + 7, offset);
    var result = try deadline.execute(&event_store.database, &statement, timeout_ms);
    defer result.deinit();
    if (result.columnCount() != 52) {
        return error.InvalidReportResult;
    }
    var daily_returned: usize = 0;
    var rule_count: usize = 0;
    for (0..result.rowCount()) |index| {
        switch (result.int64(0, index)) {
            0 => daily_returned += 1,
            1 => rule_count += 1,
            else => return error.InvalidReportResult,
        }
    }
    const decoded = @min(daily_returned, @as(usize, request.limit));
    if (decoded == 0 or daily_returned > @as(usize, request.limit) + 1 or
        rule_count > 64 or daily_returned + rule_count != result.rowCount())
    {
        return error.InvalidReportResult;
    }
    const total = result.int64(4, 0);
    const persistent = result.int64(5, 0);
    const ephemeral = result.int64(6, 0);
    const legacy = result.int64(7, 0);
    const visitor_days = result.int64(8, 0);
    const zero_sessions = result.int64(9, 0);
    const identity_quality = [3]report.IdentityQualityRow{
        .{
            .quality = .persistent,
            .events = result.int64(10, 0),
            .visitor_days = result.int64(11, 0),
        },
        .{
            .quality = .ephemeral,
            .events = result.int64(12, 0),
            .visitor_days = result.int64(13, 0),
        },
        .{
            .quality = .legacy_daily,
            .events = result.int64(14, 0),
            .visitor_days = result.int64(15, 0),
        },
    };
    const exclusion_sources = [3]report.ExclusionSourceRow{
        .{ .source = .tracker, .events = result.int64(16, 0) },
        .{ .source = .network, .events = result.int64(17, 0) },
        .{ .source = .both, .events = result.int64(18, 0) },
    };
    const traffic_classes = [5]report.TrafficClassRow{
        .{ .class = .human_presumed, .events = result.int64(19, 0) },
        .{ .class = .declared_bot, .events = result.int64(20, 0) },
        .{ .class = .automation, .events = result.int64(21, 0) },
        .{ .class = .excluded, .events = result.int64(22, 0) },
        .{ .class = .suspected, .events = result.int64(23, 0) },
    };
    const signals: report.TrafficSignals = .{
        .client_signal_v1_events = result.int64(24, 0),
        .webdriver_events = result.int64(25, 0),
        .trusted_interaction_events = result.int64(26, 0),
        .visible_events = result.int64(27, 0),
        .prerendered_events = result.int64(28, 0),
        .client_hint_mismatch_events = result.int64(29, 0),
        .client_hint_absent_expected_events = result.int64(30, 0),
        .accept_language_present_events = result.int64(31, 0),
    };
    const heuristic_available = result.int64(32, 0) != 0;
    const heuristic_version = result.int64(33, 0);
    const raw_candidates = result.int64(34, 0);
    const current_suspected = result.int64(35, 0);
    const contradicted = result.int64(36, 0);
    const strict_mode = result.int64(37, 0) != 0;
    const daily_event_ceiling = result.int64(38, 0);
    const accepted_events = result.int64(39, 0);
    const ceiling_reached_days = result.int64(40, 0);
    const mint_anomaly_groups = result.int64(41, 0);
    const maximum_minted_identities = result.int64(42, 0);
    if (total < 0 or persistent < 0 or ephemeral < 0 or legacy < 0 or
        visitor_days < 0 or zero_sessions < 0 or
        persistent + ephemeral + legacy != total or
        identity_quality[0].visitor_days + identity_quality[1].visitor_days +
            identity_quality[2].visitor_days != visitor_days or
        exclusion_sources[0].events < 0 or exclusion_sources[1].events < 0 or
        exclusion_sources[2].events < 0 or heuristic_version != 1 or
        raw_candidates < 0 or current_suspected < 0 or contradicted < 0 or
        current_suspected + contradicted != raw_candidates or
        daily_event_ceiling < 1 or accepted_events < 0 or
        ceiling_reached_days < 0 or mint_anomaly_groups < 0 or
        maximum_minted_identities < 0 or
        strict_mode != traffic_context.strict_mode or
        heuristic_available != traffic_context.heuristic_available)
    {
        return error.InvalidReportResult;
    }
    var class_total: i64 = 0;
    for (traffic_classes) |row| {
        if (row.events < 0) return error.InvalidReportResult;
        class_total = std.math.add(i64, class_total, row.events) catch
            return error.InvalidReportResult;
    }
    const excluded_total = exclusion_sources[0].events +
        exclusion_sources[1].events + exclusion_sources[2].events;
    inline for (.{
        signals.client_signal_v1_events,
        signals.webdriver_events,
        signals.trusted_interaction_events,
        signals.visible_events,
        signals.prerendered_events,
        signals.client_hint_mismatch_events,
        signals.client_hint_absent_expected_events,
        signals.accept_language_present_events,
    }) |value| if (value < 0 or value > class_total) {
        return error.InvalidReportResult;
    };
    if (excluded_total != traffic_classes[3].events or
        signals.webdriver_events > signals.client_signal_v1_events or
        signals.trusted_interaction_events > signals.client_signal_v1_events or
        signals.visible_events > signals.client_signal_v1_events or
        signals.prerendered_events > signals.client_signal_v1_events)
    {
        return error.InvalidReportResult;
    }
    const days = try allocator.alloc(report.TrafficQualityDay, decoded);
    for (days, 0..) |*day, index| {
        if (result.int64(0, index) != 0) return error.InvalidReportResult;
        const new_identities = result.int64(2, index);
        const bot_events = result.int64(3, index);
        const day_suspected = result.int64(43, index);
        const day_accepted = result.int64(44, index);
        const day_mint_groups = result.int64(45, index);
        const day_maximum_minted = result.int64(46, index);
        if (new_identities < 0 or bot_events < 0 or
            day_suspected < 0 or day_accepted < 0 or day_mint_groups < 0 or
            day_maximum_minted < 0 or
            result.int64(4, index) != total or
            result.int64(8, index) != visitor_days or
            result.int64(24, index) != signals.client_signal_v1_events)
        {
            return error.InvalidReportResult;
        }
        day.* = .{
            .date = try result.text(allocator, 1, index),
            .new_anonymous_identities = new_identities,
            .bot_events = bot_events,
            .suspected_sessions = day_suspected,
            .accepted_events = day_accepted,
            .mint_anomaly_groups = day_mint_groups,
            .maximum_minted_identities = day_maximum_minted,
            .ceiling_reached = result.int64(47, index) != 0,
        };
    }
    const rules = try allocator.alloc(report.TrafficRuleRow, rule_count);
    var rule_index: usize = 0;
    var rule_total: i64 = 0;
    for (daily_returned..result.rowCount()) |index| {
        if (result.int64(0, index) != 1) return error.InvalidReportResult;
        const class_value = result.int64(48, index);
        const version_value = result.int64(49, index);
        const rule_events = result.int64(51, index);
        if (class_value < 1 or class_value > 5 or version_value < 0 or
            version_value > std.math.maxInt(u16) or rule_events < 0)
        {
            return error.InvalidReportResult;
        }
        const rule = try result.text(allocator, 50, index);
        if (rule.len > 64) return error.InvalidReportResult;
        rules[rule_index] = .{
            .class = @fromBackingInt(@intCast(@as(u8, @intCast(class_value)))),
            .classifier_version = @intCast(version_value),
            .rule = rule,
            .events = rule_events,
        };
        rule_index += 1;
        rule_total = std.math.add(i64, rule_total, rule_events) catch
            return error.InvalidReportResult;
    }
    if (rule_index != rule_count or rule_total != class_total) {
        return error.InvalidReportResult;
    }
    const basis_points: u16 = if (total == 0)
        0
    else
        @intCast(@divTrunc(
            std.math.mul(i64, persistent, 10_000) catch
                return error.InvalidReportResult,
            total,
        ));
    const contradiction_basis_points: u16 = if (raw_candidates == 0)
        0
    else
        @intCast(@divTrunc(
            std.math.mul(i64, contradicted, 10_000) catch
                return error.InvalidReportResult,
            raw_candidates,
        ));
    return .{
        .distinct_people = total,
        .persistent_people = persistent,
        .ephemeral_people = ephemeral,
        .legacy_people = legacy,
        .persistent_basis_points = basis_points,
        .visitor_days = visitor_days,
        .zero_engagement_single_event_sessions = zero_sessions,
        .heuristic_available = heuristic_available,
        .heuristic_version = @intCast(heuristic_version),
        .raw_candidates = raw_candidates,
        .current_suspected_sessions = current_suspected,
        .contradicted_candidates = contradicted,
        .contradiction_basis_points = contradiction_basis_points,
        .strict_mode = strict_mode,
        .daily_event_ceiling = daily_event_ceiling,
        .accepted_events = accepted_events,
        .ceiling_reached_days = ceiling_reached_days,
        .mint_anomaly_groups = mint_anomaly_groups,
        .maximum_minted_identities = maximum_minted_identities,
        .identity_quality = identity_quality,
        .exclusion_sources = exclusion_sources,
        .traffic_classes = traffic_classes,
        .signals = signals,
        .rules = rules,
        .days = days,
        .next_page = if (daily_returned > decoded) request.page + 1 else null,
    };
}

fn list(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: report.Request,
    site_id: []const u8,
    sql: [:0]const u8,
    label_name: []const u8,
    primary_name: []const u8,
    secondary_name: []const u8,
    traffic_context: TrafficContext,
    timeout_ms: u32,
) !report.List {
    const prepared = try prepareProduct(
        allocator,
        event_store,
        sql,
        site_id,
        traffic_context,
    );
    var statement = prepared.statement;
    defer statement.deinit();
    const binding = prepared.next_binding;
    try statement.bindText(binding, site_id);
    try statement.bindText(binding + 1, request.start_date);
    try statement.bindText(binding + 2, request.end_date);
    try statement.bindInt64(binding + 3, @as(i64, request.limit) + 1);
    try statement.bindInt64(binding + 4, try request.offset());
    var result = try deadline.execute(&event_store.database, &statement, timeout_ms);
    defer result.deinit();
    if (result.columnCount() != 3) return error.InvalidReportResult;
    const returned = result.rowCount();
    const decoded = @min(returned, @as(usize, request.limit));
    const rows = try allocator.alloc(report.ListRow, decoded);
    for (rows, 0..) |*row, index| {
        row.* = .{
            .label = try result.text(allocator, 0, index),
            .primary = result.int64(1, index),
            .secondary = result.int64(2, index),
        };
    }
    return .{
        .label_name = label_name,
        .primary_name = primary_name,
        .secondary_name = secondary_name,
        .rows = rows,
        .next_page = if (returned > decoded) request.page + 1 else null,
    };
}

fn campaignList(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: report.Request,
    site_id: []const u8,
    traffic_context: TrafficContext,
    timeout_ms: u32,
) !report.List {
    const sql = switch (request.campaign_dimension) {
        .source => selectPagedSql(
            campaignBody("coalesce(nullif(utm_source, ''), '(not set)')"),
            request.sort,
        ),
        .medium => selectPagedSql(
            campaignBody("coalesce(nullif(utm_medium, ''), '(not set)')"),
            request.sort,
        ),
        .campaign => selectPagedSql(
            campaignBody("coalesce(nullif(utm_campaign, ''), '(not set)')"),
            request.sort,
        ),
        .term => selectPagedSql(
            campaignBody("coalesce(nullif(utm_term, ''), '(not set)')"),
            request.sort,
        ),
        .content => selectPagedSql(
            campaignBody("coalesce(nullif(utm_content, ''), '(not set)')"),
            request.sort,
        ),
        .all => selectPagedSql(
            campaignBody(campaign_all_expression),
            request.sort,
        ),
    };
    return list(
        allocator,
        event_store,
        request,
        site_id,
        sql,
        switch (request.campaign_dimension) {
            .source => "utm_source",
            .medium => "utm_medium",
            .campaign => "utm_campaign",
            .term => "utm_term",
            .content => "utm_content",
            .all => "campaign_tuple",
        },
        "sessions",
        "visitor_days",
        traffic_context,
        timeout_ms,
    );
}

const Dimension = enum {
    country,
    browser,
    operating_system,
    device,
};

fn dimensionList(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: report.Request,
    site_id: []const u8,
    dimension: Dimension,
    traffic_context: TrafficContext,
    timeout_ms: u32,
) !report.List {
    const sql = switch (dimension) {
        .country => selectPagedSql(
            dimensionBody(
                "CASE WHEN country_code = 'ZZ' THEN 'Unknown' ELSE country_code END",
            ),
            request.sort,
        ),
        .browser => selectPagedSql(
            dimensionBody("browser_family"),
            request.sort,
        ),
        .operating_system => selectPagedSql(
            dimensionBody("os_family"),
            request.sort,
        ),
        .device => selectPagedSql(
            dimensionBody("device_category"),
            request.sort,
        ),
    };
    return list(
        allocator,
        event_store,
        request,
        site_id,
        sql,
        switch (dimension) {
            .country => "country",
            .browser => "browser",
            .operating_system => "operating_system",
            .device => "device",
        },
        "sessions",
        "visitor_days",
        traffic_context,
        timeout_ms,
    );
}

fn goalReport(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: report.Request,
    site_id: []const u8,
    goal: meta.Goal,
    traffic_context: TrafficContext,
    timeout_ms: u32,
) !report.Goal {
    const sql = switch (goal.match_kind) {
        .event => goal_event_sql,
        .path => goal_path_sql,
        .prefix => goal_prefix_sql,
    };
    const prepared = try prepareProduct(
        allocator,
        event_store,
        sql,
        site_id,
        traffic_context,
    );
    var statement = prepared.statement;
    defer statement.deinit();
    const binding = prepared.next_binding;
    try statement.bindText(binding, site_id);
    try statement.bindText(binding + 1, request.start_date);
    try statement.bindText(binding + 2, request.end_date);
    try statement.bindText(binding + 3, goal.match_value);
    var result = try deadline.execute(&event_store.database, &statement, timeout_ms);
    defer result.deinit();
    if (result.rowCount() != 1 or result.columnCount() != 3) {
        return error.InvalidReportResult;
    }
    return .{
        .name = goal.name,
        .total_matches = result.int64(0, 0),
        .matching_sessions = result.int64(1, 0),
        .eligible_sessions = result.int64(2, 0),
    };
}

fn funnelReport(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: report.Request,
    site_id: []const u8,
    steps: []const meta.FunnelStep,
    traffic_context: TrafficContext,
    timeout_ms: u32,
) !report.Funnel {
    if (steps.len < 2 or steps.len > 8) return error.InvalidFunnelLength;
    for (steps, 0..) |step, index| {
        if (step.index != index) return error.InvalidFunnelDefinition;
    }
    const prepared = try prepareProduct(
        allocator,
        event_store,
        funnel_sql,
        site_id,
        traffic_context,
    );
    var statement = prepared.statement;
    defer statement.deinit();
    var parameter = prepared.next_binding;
    for (0..8) |index| {
        if (index < steps.len) {
            try statement.bindInt64(parameter, @backingInt(steps[index].match_kind));
            try statement.bindText(parameter + 1, steps[index].match_value);
        } else {
            try statement.bindInt64(parameter, @backingInt(domain.MatchKind.event));
            try statement.bindText(parameter + 1, "__unused_step__");
        }
        parameter += 2;
    }
    try statement.bindInt64(parameter, @intCast(steps.len));
    try statement.bindText(parameter + 1, site_id);
    try statement.bindText(parameter + 2, request.start_date);
    try statement.bindText(parameter + 3, request.end_date);
    var result = try deadline.execute(&event_store.database, &statement, timeout_ms);
    defer result.deinit();
    if (result.columnCount() != 3 or result.rowCount() != steps.len) {
        return error.InvalidReportResult;
    }
    const output_steps = try allocator.alloc(report.FunnelStep, steps.len);
    var eligible_sessions: i64 = 0;
    for (output_steps, 0..) |*output_step, index| {
        if (result.int64(0, index) != index) return error.InvalidReportResult;
        eligible_sessions = result.int64(2, index);
        output_step.* = .{
            .name = steps[index].name,
            .sessions = result.int64(1, index),
        };
    }
    return .{
        .name = request.subject,
        .eligible_sessions = eligible_sessions,
        .steps = output_steps,
    };
}

fn bindRange(
    statement: *duckdb.Statement,
    site_id: []const u8,
    request: report.Request,
) !void {
    try statement.bindText(1, site_id);
    try statement.bindText(2, request.start_date);
    try statement.bindText(3, request.end_date);
}

pub fn timeoutProbe(event_store: *events.Store) !void {
    var statement = try event_store.database.prepare(
        "SELECT sum(sqrt(i::DOUBLE)) FROM range(1000000000000) rows(i)",
    );
    defer statement.deinit();
    _ = deadline.execute(&event_store.database, &statement, 10) catch |err| {
        if (err != error.ReportTimeout) return err;
        _ = try event_store.eventCount();
        return;
    };
    return error.TimeoutProbeCompletedUnexpectedly;
}
