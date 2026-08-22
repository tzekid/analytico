const std = @import("std");
const domain = @import("../domain.zig");
const report = @import("../report.zig");
const duckdb = @import("duckdb.zig");
const deadline = @import("deadline.zig");
const events = @import("events.zig");
const meta = @import("meta.zig");

const deadline_milliseconds: u32 = 2_000;

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
    \\    AND e.device_category <> 'bot'
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
    \\          AND device_category <> 'bot' AND identity_quality = 1)
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
    \\  SELECT * FROM filtered_all WHERE device_category <> 'bot'
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
    \\  count(*) FILTER (WHERE kind = 1 AND device_category <> 'bot'),
    \\  count(*) FILTER (
    \\    WHERE visitor_day_start AND device_category <> 'bot'
    \\  ),
    \\  count(*) FILTER (WHERE session_start AND device_category <> 'bot'),
    \\  count(*) FILTER (WHERE kind = 2 AND device_category <> 'bot'),
    \\  count(*) FILTER (WHERE device_category = 'bot')
    \\FROM events
    \\WHERE site_id = ?
    \\  AND received_date_utc BETWEEN CAST(? AS DATE) AND CAST(? AS DATE)
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
    \\  (SELECT count(*) FROM sessioned WHERE session_start)
;

const goal_path_sql: [:0]const u8 = session_cte ++
    \\,
    \\matching AS (
    \\  SELECT * FROM sessioned WHERE path = ?
    \\)
    \\SELECT
    \\  (SELECT count(*) FROM matching),
    \\  (SELECT count(DISTINCT session_id) FROM matching),
    \\  (SELECT count(*) FROM sessioned WHERE session_start)
;

const goal_prefix_sql: [:0]const u8 = session_cte ++
    \\,
    \\matching AS (
    \\  SELECT * FROM sessioned WHERE starts_with(path, ?)
    \\)
    \\SELECT
    \\  (SELECT count(*) FROM matching),
    \\  (SELECT count(DISTINCT session_id) FROM matching),
    \\  (SELECT count(*) FROM sessioned WHERE session_start)
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
    \\    AND device_category <> 'bot'
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
    \\  SELECT count(*) AS sessions FROM sessioned WHERE session_start
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
) !report.Result {
    return runWithTimeout(
        allocator,
        event_store,
        request,
        site_id,
        goal,
        funnel_steps,
        deadline_milliseconds,
    );
}

pub fn identityCoverage(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    site_id: []const u8,
    start_local_date: []const u8,
    end_local_date: []const u8,
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
    var statement = try event_store.database.prepare(identity_coverage_sql);
    defer statement.deinit();
    try statement.bindText(1, site_id);
    try statement.bindText(2, start_local_date);
    try statement.bindText(3, end_local_date);
    try statement.bindText(4, site_id);
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
    timeout_ms: u32,
) !report.Result {
    if (timeout_ms == 0 or timeout_ms > deadline_milliseconds) {
        return error.InvalidReportTimeout;
    }
    try domain.validateUuid(site_id);
    return switch (request.kind) {
        .overview => .{ .overview = try overview(
            event_store,
            request,
            site_id,
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
            timeout_ms,
        ) },
        .campaigns => .{ .list = try campaignList(
            allocator,
            event_store,
            request,
            site_id,
            timeout_ms,
        ) },
        .countries => .{ .list = try dimensionList(
            allocator,
            event_store,
            request,
            site_id,
            .country,
            timeout_ms,
        ) },
        .browsers => .{ .list = try dimensionList(
            allocator,
            event_store,
            request,
            site_id,
            .browser,
            timeout_ms,
        ) },
        .operating_systems => .{ .list = try dimensionList(
            allocator,
            event_store,
            request,
            site_id,
            .operating_system,
            timeout_ms,
        ) },
        .devices => .{ .list = try dimensionList(
            allocator,
            event_store,
            request,
            site_id,
            .device,
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
            timeout_ms,
        ) },
        .goal => .{ .goal = try goalReport(
            event_store,
            request,
            site_id,
            goal orelse return error.GoalNotFound,
            timeout_ms,
        ) },
        .funnel => .{ .funnel = try funnelReport(
            allocator,
            event_store,
            request,
            site_id,
            funnel_steps orelse return error.FunnelNotFound,
            timeout_ms,
        ) },
    };
}

fn overview(
    event_store: *events.Store,
    request: report.Request,
    site_id: []const u8,
    timeout_ms: u32,
) !report.Overview {
    var statement = try event_store.database.prepare(overview_sql);
    defer statement.deinit();
    try bindRange(&statement, site_id, request);
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

fn list(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: report.Request,
    site_id: []const u8,
    sql: [:0]const u8,
    label_name: []const u8,
    primary_name: []const u8,
    secondary_name: []const u8,
    timeout_ms: u32,
) !report.List {
    var statement = try event_store.database.prepare(sql);
    defer statement.deinit();
    try bindRange(&statement, site_id, request);
    try statement.bindInt64(4, @as(i64, request.limit) + 1);
    try statement.bindInt64(5, try request.offset());
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
        timeout_ms,
    );
}

fn goalReport(
    event_store: *events.Store,
    request: report.Request,
    site_id: []const u8,
    goal: meta.Goal,
    timeout_ms: u32,
) !report.Goal {
    const sql = switch (goal.match_kind) {
        .event => goal_event_sql,
        .path => goal_path_sql,
        .prefix => goal_prefix_sql,
    };
    var statement = try event_store.database.prepare(sql);
    defer statement.deinit();
    try bindRange(&statement, site_id, request);
    try statement.bindText(4, goal.match_value);
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
    timeout_ms: u32,
) !report.Funnel {
    if (steps.len < 2 or steps.len > 8) return error.InvalidFunnelLength;
    for (steps, 0..) |step, index| {
        if (step.index != index) return error.InvalidFunnelDefinition;
    }
    var statement = try event_store.database.prepare(funnel_sql);
    defer statement.deinit();
    var parameter: usize = 1;
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
    try statement.bindInt64(17, @intCast(steps.len));
    try statement.bindText(18, site_id);
    try statement.bindText(19, request.start_date);
    try statement.bindText(20, request.end_date);
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
