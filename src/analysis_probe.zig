const std = @import("std");
const analysis = @import("analysis.zig");
const events = @import("store/events.zig");
const analysis_store = @import("store/analysis.zig");
const meta = @import("store/meta.zig");

const site = "00000000-0000-4000-8000-000000000024";

pub fn seedTrafficQuality(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
) !void {
    const meta_path = try std.fs.path.join(allocator, &.{ directory, "meta.db" });
    const event_path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var metadata = try meta.Store.open(allocator, meta_path);
    defer metadata.deinit();
    try metadata.requireCurrent();
    var event_store = try events.Store.open(allocator, event_path);
    defer event_store.deinit();
    try event_store.requireCurrent();
    if (try metadata.siteCount() != 0 or try event_store.eventCount() != 0) {
        return error.TrafficQualitySeedRequiresEmptyStores;
    }
    try metadata.addSite(
        allocator,
        site,
        "quality",
        "Traffic Quality",
        "https://quality.example",
        "UTC",
        1_767_225_600_000_000,
    );
    try analysis_store.seedSemanticFixture(&event_store.database);
    try event_store.database.exec(
        \\INSERT INTO identity_links VALUES (
        \\  '00000000-0000-4000-8000-000000000024',
        \\  CAST('00000000-0000-4000-8000-0000000000a2' AS UUID),
        \\  'user-a', 1767398404000000,
        \\  CAST('00000000-0000-4000-8000-000000000107' AS UUID)
        \\)
    );
    try event_store.database.exec(
        \\INSERT INTO events SELECT * REPLACE (
        \\  CAST('00000000-0000-4000-8000-000000000113' AS UUID) AS event_id,
        \\  1767398410000000 AS received_at_utc_micros,
        \\  1767398410000000 AS occurred_at_utc_micros,
        \\  '/excluded-tracker' AS path, 'Excluded tracker' AS page_title,
        \\  CAST('00000000-0000-4000-8000-0000000000e1' AS UUID) AS anonymous_id,
        \\  CAST('00000000-0000-4000-8000-0000000000d1' AS UUID) AS session_id,
        \\  FALSE AS visitor_day_start, FALSE AS session_start,
        \\  repeat('1', 64) AS event_payload_digest,
        \\  4 AS traffic_class, 1 AS classifier_version,
        \\  'exclude.tracker' AS bot_rule
        \\) FROM events
        \\WHERE event_id = CAST('00000000-0000-4000-8000-000000000107' AS UUID);
        \\INSERT INTO events SELECT * REPLACE (
        \\  CAST('00000000-0000-4000-8000-000000000114' AS UUID) AS event_id,
        \\  1767398411000000 AS received_at_utc_micros,
        \\  1767398411000000 AS occurred_at_utc_micros,
        \\  '/excluded-network' AS path, 'Excluded network' AS page_title,
        \\  CAST('00000000-0000-4000-8000-0000000000e2' AS UUID) AS anonymous_id,
        \\  CAST('00000000-0000-4000-8000-0000000000d2' AS UUID) AS session_id,
        \\  FALSE AS visitor_day_start, FALSE AS session_start,
        \\  repeat('2', 64) AS event_payload_digest,
        \\  4 AS traffic_class, 1 AS classifier_version,
        \\  'exclude.network' AS bot_rule
        \\) FROM events
        \\WHERE event_id = CAST('00000000-0000-4000-8000-000000000107' AS UUID);
        \\INSERT INTO events SELECT * REPLACE (
        \\  CAST('00000000-0000-4000-8000-000000000115' AS UUID) AS event_id,
        \\  1767398412000000 AS received_at_utc_micros,
        \\  1767398412000000 AS occurred_at_utc_micros,
        \\  '/excluded-both' AS path, 'Excluded both' AS page_title,
        \\  CAST('00000000-0000-4000-8000-0000000000e3' AS UUID) AS anonymous_id,
        \\  CAST('00000000-0000-4000-8000-0000000000d3' AS UUID) AS session_id,
        \\  FALSE AS visitor_day_start, FALSE AS session_start,
        \\  repeat('3', 64) AS event_payload_digest,
        \\  4 AS traffic_class, 1 AS classifier_version,
        \\  'exclude.both' AS bot_rule
        \\) FROM events
        \\WHERE event_id = CAST('00000000-0000-4000-8000-000000000107' AS UUID);
    );
    try metadata.checkpoint();
    try event_store.checkpoint();
    try output.writeAll("traffic-quality fixture committed sites=1 events=15 links=2\n");
}

pub fn seedHeuristics(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
) !void {
    const meta_path = try std.fs.path.join(allocator, &.{ directory, "meta.db" });
    const event_path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var metadata = try meta.Store.open(allocator, meta_path);
    defer metadata.deinit();
    try metadata.requireCurrent();
    var event_store = try events.Store.open(allocator, event_path);
    defer event_store.deinit();
    try event_store.requireCurrent();
    if (try metadata.siteCount() != 0 or try event_store.eventCount() != 0) {
        return error.HeuristicsSeedRequiresEmptyStores;
    }
    try metadata.addSite(
        allocator,
        site,
        "heuristics",
        "Heuristics",
        "https://heuristics.example",
        "UTC",
        1_777_161_600_000_000,
    );
    try metadata.addGoal(
        allocator,
        "00000000-0000-4000-8000-000000000070",
        "heuristics",
        "Purchase",
        .event,
        "purchase",
        &.{},
        1_777_161_600_000_001,
    );
    try analysis_store.seedSemanticFixture(&event_store.database);
    try event_store.database.exec(
        \\INSERT INTO events
        \\SELECT template.* REPLACE (
        \\  7 AS event_schema_version, CAST(v.event_id AS UUID) AS event_id,
        \\  v.received_at AS received_at_utc_micros,
        \\  v.received_at AS occurred_at_utc_micros,
        \\  CAST('2026-08-23' AS DATE) AS received_date_utc,
        \\  CAST('2026-08-23' AS DATE) AS site_local_date,
        \\  v.kind AS kind, v.event_name AS event_name, v.path AS path,
        \\  CAST(v.anonymous_id AS UUID) AS anonymous_id,
        \\  CAST(v.session_id AS UUID) AS session_id, v.sequence AS sequence,
        \\  v.sequence = 0 AS session_start,
        \\  from_hex(md5(v.anonymous_id)) AS visitor_day_id,
        \\  v.sequence = 0 AS visitor_day_start,
        \\  repeat('7', 64) AS event_payload_digest,
        \\  v.traffic_class AS traffic_class,
        \\  v.classifier_version AS classifier_version,
        \\  v.bot_rule AS bot_rule, v.signal_version AS signal_version,
        \\  v.webdriver AS navigator_webdriver,
        \\  v.trusted AS trusted_interactions,
        \\  v.visible AS was_visible, FALSE AS was_prerendered,
        \\  v.viewport AS viewport_bucket, v.timing AS beacon_timing_bucket,
        \\  v.hint AS client_hint_consistency,
        \\  v.language_present AS accept_language_present,
        \\  v.engagement_ms AS engagement_ms, v.scroll AS max_scroll_depth,
        \\  CASE v.event_id
        \\    WHEN '00000000-0000-4000-8000-000000000201'
        \\      THEN CAST('9.000000' AS DECIMAL(18, 6))
        \\    WHEN '00000000-0000-4000-8000-000000000202'
        \\      THEN CAST('4.000000' AS DECIMAL(18, 6))
        \\    ELSE NULL END AS value_amount,
        \\  CASE WHEN v.event_id IN (
        \\    '00000000-0000-4000-8000-000000000201',
        \\    '00000000-0000-4000-8000-000000000202')
        \\    THEN 'EUR' ELSE '' END AS value_currency,
        \\  from_hex('22222222222222222222222222222222') AS network_day_id
        \\) FROM events template CROSS JOIN (VALUES
        \\ ('00000000-0000-4000-8000-000000000201',1777161600000000,1,'pageview','/candidate','00000000-0000-4000-8000-000000000201','00000000-0000-4000-8000-000000000301',0,1,2,'',1,FALSE,0,FALSE,4,1,3,FALSE,0,0),
        \\ ('00000000-0000-4000-8000-000000000202',1777161601000000,1,'pageview','/ordinary','00000000-0000-4000-8000-000000000202','00000000-0000-4000-8000-000000000302',0,1,2,'',1,FALSE,0,TRUE,4,2,1,TRUE,0,0),
        \\ ('00000000-0000-4000-8000-000000000203',1777161602000000,1,'pageview','/historical','00000000-0000-4000-8000-000000000203','00000000-0000-4000-8000-000000000303',0,1,2,'',0,FALSE,0,FALSE,0,0,0,FALSE,0,0),
        \\ ('00000000-0000-4000-8000-000000000204',1777161603000000,1,'pageview','/second-page-veto','00000000-0000-4000-8000-000000000204','00000000-0000-4000-8000-000000000304',0,1,2,'',1,FALSE,0,FALSE,4,1,3,FALSE,0,0),
        \\ ('00000000-0000-4000-8000-000000000205',1777161604000000,1,'pageview','/human-second-page','00000000-0000-4000-8000-000000000204','00000000-0000-4000-8000-000000000304',1,1,2,'',1,FALSE,1,TRUE,4,3,1,TRUE,0,0),
        \\ ('00000000-0000-4000-8000-000000000206',1777161605000000,1,'pageview','/engagement-veto','00000000-0000-4000-8000-000000000206','00000000-0000-4000-8000-000000000306',0,1,2,'',1,FALSE,0,FALSE,4,1,3,FALSE,0,0),
        \\ ('00000000-0000-4000-8000-000000000207',1777161606000000,3,'engagement','/engagement-veto','00000000-0000-4000-8000-000000000206','00000000-0000-4000-8000-000000000306',1,1,2,'',1,FALSE,1,TRUE,4,3,1,TRUE,10000,50),
        \\ ('00000000-0000-4000-8000-000000000208',1777161607000000,2,'purchase','/goal-veto','00000000-0000-4000-8000-000000000208','00000000-0000-4000-8000-000000000308',0,1,2,'',1,FALSE,0,FALSE,4,1,3,FALSE,0,0),
        \\ ('00000000-0000-4000-8000-000000000209',1777161608000000,1,'pageview','/return-veto','00000000-0000-4000-8000-0000000000a1','00000000-0000-4000-8000-000000000309',0,1,2,'',1,FALSE,0,FALSE,4,1,3,FALSE,0,0),
        \\ ('00000000-0000-4000-8000-000000000210',1777161609000000,1,'pageview','/hard-webdriver','00000000-0000-4000-8000-000000000210','00000000-0000-4000-8000-000000000310',0,3,2,'signal.webdriver',1,TRUE,0,FALSE,4,1,3,FALSE,0,0),
        \\ ('00000000-0000-4000-8000-000000000211',1777161610000000,1,'pageview','/hard-ua','00000000-0000-4000-8000-000000000211','00000000-0000-4000-8000-000000000311',0,2,1,'crawler.google',1,FALSE,0,FALSE,4,1,3,FALSE,0,0)
        \\) v(event_id,received_at,kind,event_name,path,anonymous_id,session_id,
        \\ sequence,traffic_class,classifier_version,bot_rule,signal_version,
        \\ webdriver,trusted,visible,viewport,timing,hint,language_present,
        \\ engagement_ms,scroll)
        \\WHERE template.event_id = CAST('00000000-0000-4000-8000-000000000107' AS UUID);
        \\INSERT INTO events
        \\SELECT template.* REPLACE (
        \\  7 AS event_schema_version,
        \\  CAST(md5('mint-event-' || CAST(i AS VARCHAR)) AS UUID) AS event_id,
        \\  1777161700000000 + i AS received_at_utc_micros,
        \\  1777161700000000 + i AS occurred_at_utc_micros,
        \\  CAST('2026-08-23' AS DATE) AS received_date_utc,
        \\  CAST('2026-08-23' AS DATE) AS site_local_date,
        \\  'pageview' AS event_name, '/mint' AS path,
        \\  CAST(md5('mint-anonymous-' || CAST(i AS VARCHAR)) AS UUID) AS anonymous_id,
        \\  CAST(md5('mint-session-' || CAST(i AS VARCHAR)) AS UUID) AS session_id,
        \\  0 AS sequence, TRUE AS session_start,
        \\  from_hex(md5('mint-visitor-' || CAST(i AS VARCHAR))) AS visitor_day_id,
        \\  TRUE AS visitor_day_start, repeat('8', 64) AS event_payload_digest,
        \\  1 AS traffic_class, 2 AS classifier_version, '' AS bot_rule,
        \\  0 AS signal_version, FALSE AS navigator_webdriver,
        \\  0 AS trusted_interactions, FALSE AS was_visible,
        \\  FALSE AS was_prerendered, 0 AS viewport_bucket,
        \\  0 AS beacon_timing_bucket, 0 AS client_hint_consistency,
        \\  FALSE AS accept_language_present,
        \\  from_hex('33333333333333333333333333333333') AS network_day_id
        \\) FROM events template CROSS JOIN range(65) minted(i)
        \\WHERE template.event_id = CAST('00000000-0000-4000-8000-000000000107' AS UUID);
    );
    try metadata.checkpoint();
    try event_store.checkpoint();
    try output.writeAll("heuristics fixture committed events=88 candidates=5 current=1\n");
}

pub fn checkHeuristics(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
) !void {
    const event_path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var event_store = try events.Store.open(allocator, event_path);
    defer event_store.deinit();
    try event_store.requireCurrent();
    const query = analysis.Query{
        .site_id = site,
        .range = .{ .start = "2026-08-23", .end = "2026-08-23" },
        .mode = .trend,
        .metric = .{ .kind = .page_views },
        .interval = .day,
    };
    const goals = [_]analysis.ResolvedGoal{.{
        .id = "00000000-0000-4000-8000-000000000070",
        .selector = .{ .kind = .exact_event, .value = "purchase" },
    }};
    const default_result = (try analysis_store.execute(
        allocator,
        &event_store,
        .{ .query = query, .active_goals = &goals },
    )).trend;
    const strict_result = (try analysis_store.execute(
        allocator,
        &event_store,
        .{
            .query = query,
            .active_goals = &goals,
            .strict_traffic_mode = true,
        },
    )).trend;
    const default_overview = try analysis_store.executeOverview(
        allocator,
        &event_store,
        .{
            .site_id = site,
            .range = .{ .start = "2026-08-23", .end = "2026-08-23" },
            .active_goals = &goals,
        },
    );
    const strict_overview = try analysis_store.executeOverview(
        allocator,
        &event_store,
        .{
            .site_id = site,
            .range = .{ .start = "2026-08-23", .end = "2026-08-23" },
            .active_goals = &goals,
            .strict_traffic_mode = true,
        },
    );
    const default_eur = overviewRevenue(default_overview.revenue, "EUR") orelse
        return error.InvalidHeuristicsAnalysisResult;
    const strict_eur = overviewRevenue(strict_overview.revenue, "EUR") orelse
        return error.InvalidHeuristicsAnalysisResult;
    if (default_result.total.len != 1 or strict_result.total.len != 1 or
        default_result.total[0] != .count or strict_result.total[0] != .count or
        !std.mem.eql(u8, default_eur.current.decimal, "13.000000") or
        !std.mem.eql(u8, strict_eur.current.decimal, "4.000000"))
    {
        return error.InvalidHeuristicsAnalysisResult;
    }
    try std.json.Stringify.value(.{
        .metric_version = analysis.metric_version,
        .default_page_views = default_result.total[0].count,
        .strict_page_views = strict_result.total[0].count,
    }, .{}, output);
    try output.writeByte('\n');
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, path);
    defer store.deinit();
    try store.migrate();
    if (try store.eventCount() != 0) return error.AnalysisProbeRequiresEmptyStore;
    try analysis_store.seedSemanticFixture(&store.database);
    try store.database.exec(
        \\INSERT INTO events SELECT * REPLACE (
        \\  1 AS protocol_version, 1 AS tracker_version,
        \\  CAST('00000000-0000-4000-8000-000000000116' AS UUID) AS event_id,
        \\  '00000000-0000-4000-8000-000000000026' AS site_id,
        \\  1767393000000000 AS received_at_utc_micros,
        \\  1767393000000000 AS occurred_at_utc_micros,
        \\  CAST('2026-01-02' AS DATE) AS received_date_utc,
        \\  CAST('2026-01-02' AS DATE) AS site_local_date,
        \\  60 AS site_utc_offset_minutes,
        \\  1 AS kind, 'pageview' AS event_name, '/before-local-midnight' AS path,
        \\  CAST('00000000-0000-4000-8000-0000000000a6' AS UUID) AS anonymous_id,
        \\  3 AS identity_quality, '' AS user_id,
        \\  CAST('00000000-0000-4000-8000-0000000000b6' AS UUID) AS session_id,
        \\  0 AS sequence, TRUE AS session_start,
        \\  from_hex('26262626262626262626262626262626') AS visitor_day_id,
        \\  TRUE AS visitor_day_start, repeat('6', 64) AS event_payload_digest,
        \\  1 AS traffic_class, 0 AS classifier_version, '' AS bot_rule,
        \\  0 AS signal_version, FALSE AS navigator_webdriver,
        \\  0 AS trusted_interactions, FALSE AS was_visible,
        \\  FALSE AS was_prerendered, 0 AS viewport_bucket,
        \\  0 AS beacon_timing_bucket, 0 AS client_hint_consistency,
        \\  FALSE AS accept_language_present
        \\) FROM events WHERE event_id =
        \\  CAST('00000000-0000-4000-8000-000000000107' AS UUID);
        \\INSERT INTO events SELECT * REPLACE (
        \\  1 AS protocol_version, 1 AS tracker_version,
        \\  CAST('00000000-0000-4000-8000-000000000117' AS UUID) AS event_id,
        \\  '00000000-0000-4000-8000-000000000026' AS site_id,
        \\  1767396600000000 AS received_at_utc_micros,
        \\  1767396600000000 AS occurred_at_utc_micros,
        \\  CAST('2026-01-02' AS DATE) AS received_date_utc,
        \\  CAST('2026-01-03' AS DATE) AS site_local_date,
        \\  60 AS site_utc_offset_minutes,
        \\  1 AS kind, 'pageview' AS event_name, '/after-local-midnight' AS path,
        \\  CAST('00000000-0000-4000-8000-0000000000a6' AS UUID) AS anonymous_id,
        \\  3 AS identity_quality, '' AS user_id,
        \\  CAST('00000000-0000-4000-8000-0000000000b6' AS UUID) AS session_id,
        \\  1 AS sequence, FALSE AS session_start,
        \\  from_hex('26262626262626262626262626262626') AS visitor_day_id,
        \\  FALSE AS visitor_day_start, repeat('7', 64) AS event_payload_digest,
        \\  1 AS traffic_class, 0 AS classifier_version, '' AS bot_rule,
        \\  0 AS signal_version, FALSE AS navigator_webdriver,
        \\  0 AS trusted_interactions, FALSE AS was_visible,
        \\  FALSE AS was_prerendered, 0 AS viewport_bucket,
        \\  0 AS beacon_timing_bucket, 0 AS client_hint_consistency,
        \\  FALSE AS accept_language_present
        \\) FROM events WHERE event_id =
        \\  CAST('00000000-0000-4000-8000-000000000107' AS UUID);
        \\INSERT INTO events SELECT * REPLACE (
        \\  1 AS protocol_version, 1 AS tracker_version,
        \\  CAST('00000000-0000-4000-8000-000000000118' AS UUID) AS event_id,
        \\  '00000000-0000-4000-8000-000000000027' AS site_id,
        \\  1767400200000000 AS received_at_utc_micros,
        \\  1767400200000000 AS occurred_at_utc_micros,
        \\  CAST('2026-01-03' AS DATE) AS received_date_utc,
        \\  CAST('2026-01-03' AS DATE) AS site_local_date,
        \\  0 AS site_utc_offset_minutes,
        \\  1 AS kind, 'pageview' AS event_name, '/ineligible-boundary' AS path,
        \\  CAST('00000000-0000-4000-8000-0000000000a7' AS UUID) AS anonymous_id,
        \\  3 AS identity_quality, '' AS user_id,
        \\  CAST('00000000-0000-4000-8000-0000000000b7' AS UUID) AS session_id,
        \\  0 AS sequence, TRUE AS session_start,
        \\  from_hex('27272727272727272727272727272727') AS visitor_day_id,
        \\  TRUE AS visitor_day_start, repeat('8', 64) AS event_payload_digest,
        \\  2 AS traffic_class, 1 AS classifier_version,
        \\  'crawler.fixture' AS bot_rule,
        \\  0 AS signal_version, FALSE AS navigator_webdriver,
        \\  0 AS trusted_interactions, FALSE AS was_visible,
        \\  FALSE AS was_prerendered, 0 AS viewport_bucket,
        \\  0 AS beacon_timing_bucket, 0 AS client_hint_consistency,
        \\  FALSE AS accept_language_present
        \\) FROM events WHERE event_id =
        \\  CAST('00000000-0000-4000-8000-000000000107' AS UUID);
        \\INSERT INTO events SELECT * REPLACE (
        \\  1 AS protocol_version, 1 AS tracker_version,
        \\  CAST('00000000-0000-4000-8000-000000000119' AS UUID) AS event_id,
        \\  '00000000-0000-4000-8000-000000000027' AS site_id,
        \\  1767403800000000 AS received_at_utc_micros,
        \\  1767403800000000 AS occurred_at_utc_micros,
        \\  CAST('2026-01-03' AS DATE) AS received_date_utc,
        \\  CAST('2026-01-03' AS DATE) AS site_local_date,
        \\  0 AS site_utc_offset_minutes,
        \\  1 AS kind, 'pageview' AS event_name, '/eligible-later' AS path,
        \\  CAST('00000000-0000-4000-8000-0000000000a7' AS UUID) AS anonymous_id,
        \\  3 AS identity_quality, '' AS user_id,
        \\  CAST('00000000-0000-4000-8000-0000000000b7' AS UUID) AS session_id,
        \\  1 AS sequence, FALSE AS session_start,
        \\  from_hex('27272727272727272727272727272727') AS visitor_day_id,
        \\  FALSE AS visitor_day_start, repeat('9', 64) AS event_payload_digest,
        \\  1 AS traffic_class, 1 AS classifier_version, '' AS bot_rule,
        \\  0 AS signal_version, FALSE AS navigator_webdriver,
        \\  0 AS trusted_interactions, FALSE AS was_visible,
        \\  FALSE AS was_prerendered, 0 AS viewport_bucket,
        \\  0 AS beacon_timing_bucket, 0 AS client_hint_consistency,
        \\  FALSE AS accept_language_present
        \\) FROM events WHERE event_id =
        \\  CAST('00000000-0000-4000-8000-000000000107' AS UUID);
        \\INSERT INTO events SELECT * REPLACE (
        \\  1 AS protocol_version, 1 AS tracker_version,
        \\  CAST('00000000-0000-4000-8000-000000000120' AS UUID) AS event_id,
        \\  '00000000-0000-4000-8000-000000000028' AS site_id,
        \\  1767400200000000 AS received_at_utc_micros,
        \\  1767400200000000 AS occurred_at_utc_micros,
        \\  CAST('2026-01-03' AS DATE) AS received_date_utc,
        \\  CAST('2026-01-03' AS DATE) AS site_local_date,
        \\  0 AS site_utc_offset_minutes,
        \\  3 AS kind, 'engagement' AS event_name, '/non-page-boundary' AS path,
        \\  CAST('00000000-0000-4000-8000-0000000000a8' AS UUID) AS anonymous_id,
        \\  3 AS identity_quality, '' AS user_id,
        \\  CAST('00000000-0000-4000-8000-0000000000b8' AS UUID) AS session_id,
        \\  0 AS sequence, TRUE AS session_start,
        \\  from_hex('28282828282828282828282828282828') AS visitor_day_id,
        \\  TRUE AS visitor_day_start, repeat('a', 64) AS event_payload_digest,
        \\  1 AS traffic_class, 1 AS classifier_version, '' AS bot_rule,
        \\  0 AS signal_version, FALSE AS navigator_webdriver,
        \\  0 AS trusted_interactions, FALSE AS was_visible,
        \\  FALSE AS was_prerendered, 0 AS viewport_bucket,
        \\  0 AS beacon_timing_bucket, 0 AS client_hint_consistency,
        \\  FALSE AS accept_language_present
        \\) FROM events WHERE event_id =
        \\  CAST('00000000-0000-4000-8000-000000000107' AS UUID);
        \\INSERT INTO events SELECT * REPLACE (
        \\  1 AS protocol_version, 1 AS tracker_version,
        \\  CAST('00000000-0000-4000-8000-000000000121' AS UUID) AS event_id,
        \\  '00000000-0000-4000-8000-000000000029' AS site_id,
        \\  1767400200000000 AS received_at_utc_micros,
        \\  1767400200000000 AS occurred_at_utc_micros,
        \\  CAST('2026-01-03' AS DATE) AS received_date_utc,
        \\  CAST('2026-01-03' AS DATE) AS site_local_date,
        \\  0 AS site_utc_offset_minutes,
        \\  1 AS kind, 'pageview' AS event_name, '/plain' AS path,
        \\  CAST('00000000-0000-4000-8000-0000000000a9' AS UUID) AS anonymous_id,
        \\  1 AS identity_quality, '' AS user_id,
        \\  CAST('00000000-0000-4000-8000-0000000000b9' AS UUID) AS session_id,
        \\  0 AS sequence, TRUE AS session_start,
        \\  from_hex('29292929292929292929292929292929') AS visitor_day_id,
        \\  TRUE AS visitor_day_start, repeat('b', 64) AS event_payload_digest,
        \\  1 AS traffic_class, 1 AS classifier_version, '' AS bot_rule,
        \\  0 AS engagement_ms, 0 AS signal_version,
        \\  FALSE AS navigator_webdriver, 0 AS trusted_interactions,
        \\  FALSE AS was_visible, FALSE AS was_prerendered,
        \\  0 AS viewport_bucket, 0 AS beacon_timing_bucket,
        \\  0 AS client_hint_consistency, FALSE AS accept_language_present
        \\) FROM events WHERE event_id =
        \\  CAST('00000000-0000-4000-8000-000000000107' AS UUID);
        \\INSERT INTO events SELECT * REPLACE (
        \\  1 AS protocol_version, 1 AS tracker_version,
        \\  CAST('00000000-0000-4000-8000-000000000122' AS UUID) AS event_id,
        \\  '00000000-0000-4000-8000-000000000029' AS site_id,
        \\  1767403800000000 AS received_at_utc_micros,
        \\  1767403800000000 AS occurred_at_utc_micros,
        \\  CAST('2026-01-03' AS DATE) AS received_date_utc,
        \\  CAST('2026-01-03' AS DATE) AS site_local_date,
        \\  0 AS site_utc_offset_minutes,
        \\  3 AS kind, 'engagement' AS event_name, '/goal-only' AS path,
        \\  CAST('00000000-0000-4000-8000-0000000000a9' AS UUID) AS anonymous_id,
        \\  1 AS identity_quality, '' AS user_id,
        \\  CAST('00000000-0000-4000-8000-0000000000b9' AS UUID) AS session_id,
        \\  1 AS sequence, FALSE AS session_start,
        \\  from_hex('29292929292929292929292929292929') AS visitor_day_id,
        \\  FALSE AS visitor_day_start, repeat('c', 64) AS event_payload_digest,
        \\  1 AS traffic_class, 1 AS classifier_version, '' AS bot_rule,
        \\  0 AS engagement_ms, 0 AS signal_version,
        \\  FALSE AS navigator_webdriver, 0 AS trusted_interactions,
        \\  FALSE AS was_visible, FALSE AS was_prerendered,
        \\  0 AS viewport_bucket, 0 AS beacon_timing_bucket,
        \\  0 AS client_hint_consistency, FALSE AS accept_language_present
        \\) FROM events WHERE event_id =
        \\  CAST('00000000-0000-4000-8000-000000000107' AS UUID)
    );
    try store.database.exec(
        \\INSERT INTO events SELECT * REPLACE (
        \\  CAST('00000000-0000-4000-8000-000000000123' AS UUID) AS event_id,
        \\  '00000000-0000-4000-8000-000000000030' AS site_id,
        \\  1 AS kind, 'pageview' AS event_name, '/real-page' AS path,
        \\  CAST('00000000-0000-4000-8000-0000000000a0' AS UUID) AS anonymous_id,
        \\  CAST('00000000-0000-4000-8000-0000000000b0' AS UUID) AS session_id,
        \\  0 AS sequence, TRUE AS session_start,
        \\  '{"plan":"pro"}' AS properties_json,
        \\  repeat('d', 64) AS event_payload_digest
        \\) FROM events WHERE event_id =
        \\  CAST('00000000-0000-4000-8000-000000000107' AS UUID);
        \\INSERT INTO events SELECT * REPLACE (
        \\  CAST('00000000-0000-4000-8000-000000000124' AS UUID) AS event_id,
        \\  '00000000-0000-4000-8000-000000000030' AS site_id,
        \\  2 AS kind, 'custom_only' AS event_name, '/custom-only' AS path,
        \\  CAST('00000000-0000-4000-8000-0000000000a0' AS UUID) AS anonymous_id,
        \\  CAST('00000000-0000-4000-8000-0000000000b0' AS UUID) AS session_id,
        \\  1 AS sequence, FALSE AS session_start,
        \\  '{"plan":"pro"}' AS properties_json,
        \\  repeat('e', 64) AS event_payload_digest
        \\) FROM events WHERE event_id =
        \\  CAST('00000000-0000-4000-8000-000000000107' AS UUID)
    );
    const delayed_evidence = evidence: {
        var statement = try store.database.prepare(
            "SELECT received_at_utc_micros, occurred_at_utc_micros, " ++
                "site_utc_offset_minutes FROM events " ++
                "WHERE site_id = ? AND event_id = CAST(? AS UUID)",
        );
        defer statement.deinit();
        try statement.bindText(1, site);
        try statement.bindText(2, "00000000-0000-4000-8000-000000000112");
        var result = try statement.execute();
        defer result.deinit();
        if (result.rowCount() != 1 or result.columnCount() != 3) {
            return error.InvalidDelayedEventFixture;
        }
        break :evidence .{
            .received_at = result.int64(0, 0),
            .occurred_at = result.int64(1, 0),
            .offset_minutes = result.int64(2, 0),
        };
    };
    if (delayed_evidence.received_at - delayed_evidence.occurred_at !=
        3_600_000_000 or delayed_evidence.offset_minutes != 60)
    {
        return error.InvalidDelayedEventFixture;
    }

    const range = analysis.LocalDateRange{
        .start = "2026-01-02",
        .end = "2026-01-03",
    };
    const semantic_started = std.Io.Clock.awake.now(io).nanoseconds;
    const visitor_result = (try analysis_store.execute(allocator, &store, .{
        .query = trendQuery(range, .visitors),
    })).trend;
    const engaged_result = (try analysis_store.execute(allocator, &store, .{
        .query = trendQuery(range, .engaged_sessions),
    })).trend;
    const returning_result = (try analysis_store.execute(allocator, &store, .{
        .query = trendQuery(range, .returning_visitors),
    })).trend;
    const delayed_result = (try analysis_store.execute(allocator, &store, .{
        .query = .{
            .site_id = site,
            .range = .{ .start = "2026-01-03", .end = "2026-01-03" },
            .mode = .trend,
            .metric = .{
                .kind = .event_count,
                .selector = .{
                    .kind = .exact_event,
                    .value = "delayed_event",
                },
            },
            .interval = .hour,
        },
    })).trend;

    const session_values = [_][]const u8{"desktop"};
    const session_filters = [_]analysis.Clause{.{
        .scope = .session,
        .field = .{ .kind = .device },
        .operator = .is,
        .scalar_type = .string,
        .values = &session_values,
    }};
    const sessions_result = (try analysis_store.execute(allocator, &store, .{
        .query = .{
            .site_id = site,
            .range = range,
            .mode = .trend,
            .metric = .{ .kind = .sessions },
            .filters = .{ .clauses = &session_filters },
            .interval = .day,
        },
    })).trend;

    const plan_values = [_][]const u8{"pro"};
    const event_filters = [_]analysis.Clause{.{
        .scope = .event,
        .field = .{
            .kind = .event_property,
            .property_ref = .{ .name = "plan", .scalar_type = .string },
        },
        .operator = .is,
        .scalar_type = .string,
        .values = &plan_values,
    }};
    const page_result = (try analysis_store.execute(allocator, &store, .{
        .query = .{
            .site_id = site,
            .range = range,
            .mode = .breakdown,
            .metric = .{ .kind = .page_views },
            .dimension = .{ .kind = .page },
            .filters = .{ .clauses = &event_filters },
            .limit = 1,
        },
    })).breakdown;
    const custom_only_page_result = (try analysis_store.execute(
        allocator,
        &store,
        .{ .query = .{
            .site_id = "00000000-0000-4000-8000-000000000030",
            .range = .{ .start = "2026-01-03", .end = "2026-01-03" },
            .mode = .breakdown,
            .metric = .{ .kind = .page_views },
            .dimension = .{ .kind = .page },
            .filters = .{ .clauses = &event_filters },
            .limit = 100,
        } },
    )).breakdown;
    const custom_only_empty_page = (try analysis_store.execute(
        allocator,
        &store,
        .{ .query = .{
            .site_id = "00000000-0000-4000-8000-000000000030",
            .range = .{ .start = "2026-01-03", .end = "2026-01-03" },
            .mode = .breakdown,
            .metric = .{ .kind = .page_views },
            .dimension = .{ .kind = .page },
            .filters = .{ .clauses = &event_filters },
            .page = 2,
            .limit = 1,
        } },
    )).breakdown;
    const event_filtered_page_views = (try analysis_store.execute(
        allocator,
        &store,
        .{ .query = .{
            .site_id = site,
            .range = .{ .start = "2026-01-03", .end = "2026-01-03" },
            .mode = .trend,
            .metric = .{ .kind = .page_views },
            .filters = .{ .clauses = &event_filters },
            .interval = .day,
        } },
    )).trend;

    const trait_values = [_][]const u8{"enterprise"};
    const person_filters = [_]analysis.Clause{.{
        .scope = .person,
        .field = .{
            .kind = .user_trait,
            .property_ref = .{ .name = "plan", .scalar_type = .string },
        },
        .operator = .is,
        .scalar_type = .string,
        .values = &trait_values,
    }};
    const identified_result = (try analysis_store.execute(allocator, &store, .{
        .query = .{
            .site_id = site,
            .range = range,
            .mode = .trend,
            .metric = .{ .kind = .visitors },
            .filters = .{ .clauses = &person_filters },
            .interval = .day,
        },
    })).trend;

    const suggestion_execution = analysis.Execution{ .query = trendQuery(
        range,
        .visitors,
    ) };
    const page_suggestions = try analysis_store.executeSuggestions(
        allocator,
        &store,
        .{
            .execution = suggestion_execution,
            .scope = .event,
            .field = .{ .kind = .page },
            .scalar_type = .string,
            .search = "pric",
        },
    );
    var filtered_suggestion_execution = suggestion_execution;
    filtered_suggestion_execution.query.filters = .{
        .clauses = &event_filters,
    };
    const device_suggestions = try analysis_store.executeSuggestions(
        allocator,
        &store,
        .{
            .execution = filtered_suggestion_execution,
            .scope = .session,
            .field = .{ .kind = .device },
            .scalar_type = .string,
        },
    );
    const amount_suggestions = try analysis_store.executeSuggestions(
        allocator,
        &store,
        .{
            .execution = suggestion_execution,
            .scope = .event,
            .field = .{
                .kind = .event_property,
                .property_ref = .{
                    .name = "amount",
                    .scalar_type = .decimal,
                },
            },
            .scalar_type = .decimal,
            .search = "14",
        },
    );
    const trait_suggestions = try analysis_store.executeSuggestions(
        allocator,
        &store,
        .{
            .execution = suggestion_execution,
            .scope = .person,
            .field = .{
                .kind = .user_trait,
                .property_ref = .{
                    .name = "plan",
                    .scalar_type = .string,
                },
            },
            .scalar_type = .string,
        },
    );
    var isolated_suggestion_execution = suggestion_execution;
    isolated_suggestion_execution.query.site_id =
        "00000000-0000-4000-8000-000000000025";
    const isolated_suggestions = try analysis_store.executeSuggestions(
        allocator,
        &store,
        .{
            .execution = isolated_suggestion_execution,
            .scope = .event,
            .field = .{ .kind = .page },
            .scalar_type = .string,
        },
    );

    const amount_values = [_][]const u8{"10.0"};
    const selector_predicates = [_]analysis.PropertyPredicate{.{
        .property_ref = .{ .name = "amount", .scalar_type = .decimal },
        .operator = .gte,
        .values = &amount_values,
    }};
    const conversion_result = (try analysis_store.execute(allocator, &store, .{
        .query = .{
            .site_id = site,
            .range = range,
            .mode = .trend,
            .metric = .{
                .kind = .conversions,
                .conversion_basis = .event,
                .selector = .{
                    .kind = .exact_event,
                    .value = "purchase",
                    .predicates = &selector_predicates,
                },
            },
            .interval = .day,
        },
    })).trend;
    const revenue_result = (try analysis_store.execute(allocator, &store, .{
        .query = trendQuery(range, .revenue),
    })).trend;
    const comparison_result = (try analysis_store.execute(allocator, &store, .{
        .query = .{
            .site_id = site,
            .range = .{ .start = "2026-01-03", .end = "2026-01-03" },
            .comparison = .previous,
            .mode = .trend,
            .metric = .{ .kind = .visitors },
            .interval = .day,
        },
        .comparison_range = .{ .start = "2026-01-02", .end = "2026-01-02" },
    })).trend;
    const overview_goals = [_]analysis.ResolvedGoal{
        .{
            .id = "00000000-0000-4000-8000-000000000072",
            .selector = .{ .kind = .exact_event, .value = "purchase" },
        },
        .{
            .id = "00000000-0000-4000-8000-000000000071",
            .selector = .{ .kind = .exact_event, .value = "purchase" },
        },
    };
    const overview_result = try analysis_store.executeOverview(
        allocator,
        &store,
        .{
            .site_id = site,
            .range = .{ .start = "2026-01-03", .end = "2026-01-03" },
            .comparison_range = .{
                .start = "2026-01-02",
                .end = "2026-01-02",
            },
            .active_goals = &overview_goals,
            .daily_event_ceiling = 1,
            .trend = .{
                .metric = .visitors,
                .interval = .day,
                .current_buckets = &.{.{ .label = "2026-01-03" }},
                .comparison_buckets = &.{.{ .label = "2026-01-02" }},
            },
        },
    );
    const filtered_overview_base = analysis.OverviewExecution{
        .site_id = site,
        .range = .{ .start = "2026-01-03", .end = "2026-01-03" },
        .active_goals = &overview_goals,
        .trend = .{
            .metric = .visitors,
            .interval = .day,
            .current_buckets = &.{.{ .label = "2026-01-03" }},
        },
    };
    var session_filtered_execution = filtered_overview_base;
    session_filtered_execution.filters = .{ .clauses = &session_filters };
    const session_filtered_overview = try analysis_store.executeOverview(
        allocator,
        &store,
        session_filtered_execution,
    );
    var event_filtered_execution = filtered_overview_base;
    event_filtered_execution.filters = .{ .clauses = &event_filters };
    const event_filtered_overview = try analysis_store.executeOverview(
        allocator,
        &store,
        event_filtered_execution,
    );
    var person_filtered_execution = filtered_overview_base;
    person_filtered_execution.filters = .{ .clauses = &person_filters };
    const person_filtered_overview = try analysis_store.executeOverview(
        allocator,
        &store,
        person_filtered_execution,
    );
    const cache_goal_low_values = [_][]const u8{"10.0"};
    const cache_goal_high_values = [_][]const u8{"20.0"};
    const cache_goal_low_predicates = [_]analysis.PropertyPredicate{.{
        .property_ref = .{ .name = "amount", .scalar_type = .decimal },
        .operator = .gte,
        .values = &cache_goal_low_values,
    }};
    const cache_goal_high_predicates = [_]analysis.PropertyPredicate{.{
        .property_ref = .{ .name = "amount", .scalar_type = .decimal },
        .operator = .gte,
        .values = &cache_goal_high_values,
    }};
    const cache_goal_low = [_]analysis.ResolvedGoal{.{
        .id = "00000000-0000-4000-8000-000000000074",
        .selector = .{
            .kind = .exact_event,
            .value = "purchase",
            .predicates = &cache_goal_low_predicates,
        },
    }};
    const cache_goal_high = [_]analysis.ResolvedGoal{.{
        .id = "00000000-0000-4000-8000-000000000074",
        .selector = .{
            .kind = .exact_event,
            .value = "purchase",
            .predicates = &cache_goal_high_predicates,
        },
    }};
    const cache_goal_execution = analysis.OverviewExecution{
        .site_id = site,
        .range = .{ .start = "2026-01-03", .end = "2026-01-03" },
        .active_goals = &cache_goal_low,
        .filters = .{ .clauses = &session_filters },
        .trend = .{
            .metric = .visitors,
            .interval = .day,
            .current_buckets = &.{.{ .label = "2026-01-03" }},
        },
    };
    const cache_goal_low_overview = try analysis_store.executeOverview(
        allocator,
        &store,
        cache_goal_execution,
    );
    var cache_goal_high_execution = cache_goal_execution;
    cache_goal_high_execution.active_goals = &cache_goal_high;
    const cache_goal_high_overview = try analysis_store.executeOverview(
        allocator,
        &store,
        cache_goal_high_execution,
    );
    const overview_revenue_trend = try analysis_store.executeOverview(
        allocator,
        &store,
        .{
            .site_id = site,
            .range = .{ .start = "2026-01-03", .end = "2026-01-03" },
            .comparison_range = .{
                .start = "2026-01-02",
                .end = "2026-01-02",
            },
            .active_goals = &overview_goals,
            .trend = .{
                .metric = .revenue,
                .currency = "EUR",
                .interval = .day,
                .current_buckets = &.{.{ .label = "2026-01-03" }},
                .comparison_buckets = &.{.{ .label = "2026-01-02" }},
            },
        },
    );
    const overview_without_comparison = try analysis_store.executeOverview(
        allocator,
        &store,
        .{
            .site_id = site,
            .range = .{ .start = "2026-01-03", .end = "2026-01-03" },
            .active_goals = &overview_goals,
        },
    );
    const empty_execution = analysis.OverviewExecution{
        .site_id = "00000000-0000-4000-8000-000000000025",
        .range = .{ .start = "2026-01-03", .end = "2026-01-03" },
        .daily_event_ceiling = 1,
        .comparison_range = .{
            .start = "2026-01-02",
            .end = "2026-01-02",
        },
        .trend = .{
            .metric = .visitors,
            .interval = .day,
            .current_buckets = &.{.{ .label = "2026-01-03" }},
            .comparison_buckets = &.{.{ .label = "2026-01-02" }},
        },
    };
    const empty_overview = try analysis_store.executeOverview(
        allocator,
        &store,
        empty_execution,
    );
    try store.insert(.{
        .event_id = "00000000-0000-4000-8000-000000000250",
        .site_id = empty_execution.site_id,
        .received_at_utc_micros = 1_767_398_430_000_000,
        .received_date_utc = "2026-01-03",
        .site_local_date = "2026-01-03",
        .site_utc_offset_minutes = 0,
        .kind = 1,
        .event_name = "pageview",
        .path = "/cache-invalidation",
        .visitor_day_id = @splat(0x25),
    });
    const refreshed_empty_overview = try analysis_store.executeOverview(
        allocator,
        &store,
        empty_execution,
    );
    var raised_ceiling_execution = empty_execution;
    raised_ceiling_execution.daily_event_ceiling = 2;
    const raised_ceiling_overview = try analysis_store.executeOverview(
        allocator,
        &store,
        raised_ceiling_execution,
    );
    const boundary_exact = (try analysis_store.execute(allocator, &store, .{
        .query = trendQueryForSite(
            "00000000-0000-4000-8000-000000000026",
            .{ .start = "2026-01-03", .end = "2026-01-03" },
            .visitors,
        ),
    })).trend;
    const boundary_overview = try analysis_store.executeOverview(
        allocator,
        &store,
        .{
            .site_id = "00000000-0000-4000-8000-000000000026",
            .range = .{ .start = "2026-01-03", .end = "2026-01-03" },
        },
    );
    const ineligible_boundary_exact = (try analysis_store.execute(
        allocator,
        &store,
        .{ .query = trendQueryForSite(
            "00000000-0000-4000-8000-000000000027",
            .{ .start = "2026-01-03", .end = "2026-01-03" },
            .visitors,
        ) },
    )).trend;
    const ineligible_boundary_overview = try analysis_store.executeOverview(
        allocator,
        &store,
        .{
            .site_id = "00000000-0000-4000-8000-000000000027",
            .range = .{ .start = "2026-01-03", .end = "2026-01-03" },
        },
    );
    const non_page_boundary_exact = (try analysis_store.execute(
        allocator,
        &store,
        .{ .query = trendQueryForSite(
            "00000000-0000-4000-8000-000000000028",
            .{ .start = "2026-01-03", .end = "2026-01-03" },
            .visitors,
        ) },
    )).trend;
    const non_page_boundary_overview = try analysis_store.executeOverview(
        allocator,
        &store,
        .{
            .site_id = "00000000-0000-4000-8000-000000000028",
            .range = .{ .start = "2026-01-03", .end = "2026-01-03" },
        },
    );
    const meaningful_goal = [_]analysis.ResolvedGoal{.{
        .id = "00000000-0000-4000-8000-000000000073",
        .selector = .{ .kind = .exact_page, .value = "/goal-only" },
    }};
    const nonmeaningful_goal_overview = try analysis_store.executeOverview(
        allocator,
        &store,
        .{
            .site_id = "00000000-0000-4000-8000-000000000029",
            .range = .{ .start = "2026-01-03", .end = "2026-01-03" },
            .active_goals = &meaningful_goal,
        },
    );
    const landing_result = (try analysis_store.execute(allocator, &store, .{
        .query = .{
            .site_id = site,
            .range = .{ .start = "2026-01-03", .end = "2026-01-03" },
            .mode = .breakdown,
            .metric = .{ .kind = .sessions },
            .dimension = .{ .kind = .landing_page },
            .limit = 100,
        },
    })).breakdown;
    const channel_result = (try analysis_store.execute(allocator, &store, .{
        .query = .{
            .site_id = site,
            .range = .{ .start = "2026-01-03", .end = "2026-01-03" },
            .mode = .breakdown,
            .metric = .{ .kind = .sessions },
            .dimension = .{ .kind = .channel },
            .limit = 100,
        },
    })).breakdown;
    const semantic_elapsed_ms = @divTrunc(
        std.Io.Clock.awake.now(io).nanoseconds - semantic_started,
        std.time.ns_per_ms,
    );

    const visitors = visitor_result.total[0].count;
    const engaged = engaged_result.total[0].count;
    const returning = returning_result.total[0].count;
    const desktop_sessions = sessions_result.total[0].count;
    const identified_visitors = identified_result.total[0].count;
    const conversions = conversion_result.total[0].count;
    if (visitors != 4 or engaged != 2 or returning != 1 or
        desktop_sessions != 1 or identified_visitors != 1 or
        page_suggestions.values.len != 1 or page_suggestions.has_more or
        !std.mem.eql(u8, page_suggestions.values[0], "/pricing") or
        device_suggestions.values.len != 1 or device_suggestions.has_more or
        !std.mem.eql(u8, device_suggestions.values[0], "desktop") or
        amount_suggestions.values.len != 1 or amount_suggestions.has_more or
        !std.mem.eql(u8, amount_suggestions.values[0], "14.250000") or
        trait_suggestions.values.len != 1 or trait_suggestions.has_more or
        !std.mem.eql(u8, trait_suggestions.values[0], "enterprise") or
        isolated_suggestions.values.len != 0 or isolated_suggestions.has_more or
        page_result.cardinality != 2 or page_result.next_page != 2 or
        conversions != 1 or
        revenue_result.total.len != 2 or
        comparison_result.comparison_points == null or
        comparison_result.comparison_total == null or
        comparison_result.comparison_total.?[0].count != 1 or
        comparison_result.comparison_completeness == null or
        !hasCount(landing_result.rows, "/landing", 1) or
        !hasCount(channel_result.rows, "Paid Search", 1))
    {
        return error.InvalidAnalysisSemanticEvidence;
    }
    if (delayed_result.points.len != 1 or
        !std.mem.eql(
            u8,
            delayed_result.points[0].bucket,
            "2026-01-03T01:00",
        ) or
        delayed_result.points[0].measure != .count or
        delayed_result.points[0].measure.count != 1)
    {
        return error.InvalidReceiptHourBucket;
    }
    const eur = overviewRevenue(overview_result.revenue, "EUR") orelse
        return error.InvalidOverviewSemanticEvidence;
    const gbp = overviewRevenue(overview_result.revenue, "GBP") orelse
        return error.InvalidOverviewSemanticEvidence;
    const usd = overviewRevenue(overview_result.revenue, "USD") orelse
        return error.InvalidOverviewSemanticEvidence;
    const overview_details = overview_result.details orelse
        return error.InvalidOverviewSemanticEvidence;
    var acquisition_sessions: i64 = 0;
    var direct_sessions: ?i64 = null;
    var search_sessions: ?i64 = null;
    for (overview_details.acquisition) |row| {
        if (row.source.len == 0 or row.sessions <= 0 or
            row.converting_sessions < 0 or
            row.converting_sessions > row.sessions)
        {
            return error.InvalidOverviewSemanticEvidence;
        }
        acquisition_sessions = std.math.add(
            i64,
            acquisition_sessions,
            row.sessions,
        ) catch return error.InvalidOverviewSemanticEvidence;
        if (std.mem.eql(u8, row.source, "Direct")) {
            if (direct_sessions != null) return error.InvalidOverviewSemanticEvidence;
            direct_sessions = row.sessions;
        } else if (std.mem.eql(u8, row.source, "search.example")) {
            if (search_sessions != null) return error.InvalidOverviewSemanticEvidence;
            search_sessions = row.sessions;
        }
    }
    const revenue_details = overview_revenue_trend.details orelse
        return error.InvalidOverviewSemanticEvidence;
    const empty_details = empty_overview.details orelse
        return error.InvalidOverviewSemanticEvidence;
    const refreshed_empty_details = refreshed_empty_overview.details orelse
        return error.InvalidOverviewSemanticEvidence;
    const raised_ceiling_details = raised_ceiling_overview.details orelse
        return error.InvalidOverviewSemanticEvidence;
    const cache_goal_low_details = cache_goal_low_overview.details orelse
        return error.InvalidOverviewSemanticEvidence;
    const cache_goal_high_details = cache_goal_high_overview.details orelse
        return error.InvalidOverviewSemanticEvidence;
    if (overview_result.visitors.current != 4 or
        overview_result.visitors.comparison.? != 1 or
        overview_result.sessions.current != 4 or
        overview_result.sessions.comparison.? != 1 or
        overview_result.page_views.current != 4 or
        overview_result.page_views.comparison.? != 1 or
        overview_result.engagement_rate.current.numerator != 2 or
        overview_result.engagement_rate.current.denominator != 4 or
        overview_result.engagement_rate.comparison.?.numerator != 1 or
        overview_result.engagement_rate.comparison.?.denominator != 1 or
        overview_result.conversions.current != 4 or
        overview_result.conversions.comparison.? != 0 or
        overview_result.conversion_rate.current.numerator != 1 or
        overview_result.conversion_rate.current.denominator != 4 or
        overview_result.conversion_rate.comparison.?.numerator != 0 or
        overview_result.conversion_rate.comparison.?.denominator != 1 or
        overview_result.completeness.persistent_people != 2 or
        overview_result.completeness.ephemeral_people != 1 or
        overview_result.completeness.legacy_people != 1 or
        overview_result.comparison_completeness.?.persistent_people != 1 or
        overview_result.revenue.len != 3 or
        session_filtered_overview.sessions.current != desktop_sessions or
        event_filtered_page_views.total.len != 1 or
        event_filtered_page_views.total[0] != .count or
        event_filtered_overview.page_views.current !=
            event_filtered_page_views.total[0].count or
        custom_only_page_result.cardinality != 1 or
        custom_only_page_result.rows.len != 1 or
        custom_only_page_result.rows[0].measure != .count or
        custom_only_page_result.rows[0].measure.count != 1 or
        !std.mem.eql(
            u8,
            custom_only_page_result.rows[0].label.value,
            "/real-page",
        ) or
        custom_only_empty_page.cardinality != 1 or
        custom_only_empty_page.rows.len != 0 or
        custom_only_empty_page.next_page != null or
        person_filtered_overview.visitors.current != identified_visitors or
        session_filtered_overview.details == null or
        event_filtered_overview.details == null or
        person_filtered_overview.details == null or
        event_filtered_overview.details.?.health.accepted_events !=
            overview_details.health.accepted_events or
        !std.mem.eql(u8, eur.current.decimal, "12.500000") or
        !std.mem.eql(u8, eur.comparison.?.decimal, "0.000000") or
        !std.mem.eql(u8, gbp.current.decimal, "0.000000") or
        !std.mem.eql(u8, gbp.comparison.?.decimal, "0.000000") or
        !std.mem.eql(u8, usd.current.decimal, "7.500000") or
        !std.mem.eql(u8, usd.comparison.?.decimal, "0.000000") or
        overview_details.trend.current.len != 1 or
        overview_details.trend.current[0].measure != .count or
        overview_details.trend.current[0].measure.count != 4 or
        overview_details.trend.comparison == null or
        overview_details.trend.comparison.?[0].measure != .count or
        overview_details.trend.comparison.?[0].measure.count != 1 or
        overview_details.content.len == 0 or overview_details.content.len > 5 or
        overview_details.acquisition.len == 0 or overview_details.acquisition.len > 5 or
        acquisition_sessions != overview_result.sessions.current or
        direct_sessions != 3 or search_sessions != 1 or
        overview_details.conversions.len != 2 or
        !std.mem.eql(
            u8,
            overview_details.conversions[0].goal_id,
            overview_goals[0].id,
        ) or
        !std.mem.eql(
            u8,
            overview_details.conversions[1].goal_id,
            overview_goals[1].id,
        ) or
        overview_details.conversions[0].converting_people != 1 or
        overview_details.conversions[1].converting_people != 1 or
        overview_details.audience.len == 0 or overview_details.audience.len > 5 or
        overview_details.health.accepted_events <= 0 or
        overview_details.health.daily_event_ceiling != 1 or
        overview_details.health.ceiling_reached_days != 1 or
        overview_details.health.protocol_v1_events +
            overview_details.health.protocol_v2_events !=
            overview_details.health.accepted_events or
        revenue_details.trend.current.len != 1 or
        revenue_details.trend.current[0].measure != .amount or
        !std.mem.eql(
            u8,
            revenue_details.trend.current[0].measure.amount.decimal,
            "12.500000",
        ) or
        !std.mem.eql(
            u8,
            revenue_details.trend.current[0].measure.amount.currency,
            "EUR",
        ) or
        overview_without_comparison.visitors.comparison != null or
        overview_without_comparison.engagement_rate.comparison != null or
        empty_overview.visitors.current != 0 or
        empty_overview.visitors.comparison.? != 0 or
        empty_overview.engagement_rate.current.denominator != 0 or
        empty_overview.conversion_rate.current.denominator != 0 or
        empty_overview.revenue.len != 0 or
        empty_details.trend.current.len != 1 or
        empty_details.trend.current[0].measure != .count or
        empty_details.trend.current[0].measure.count != 0 or
        empty_details.content.len != 0 or
        empty_details.acquisition.len != 0 or
        empty_details.conversions.len != 0 or
        empty_details.audience.len != 0 or
        empty_details.health.accepted_events != 0 or
        refreshed_empty_overview.visitors.current != 1 or
        refreshed_empty_details.trend.current[0].measure != .count or
        refreshed_empty_details.trend.current[0].measure.count != 1 or
        refreshed_empty_details.health.accepted_events != 1 or
        raised_ceiling_details.health.daily_event_ceiling != 2 or
        raised_ceiling_details.health.ceiling_reached_days != 0 or
        cache_goal_low_details.conversions.len != 1 or
        cache_goal_low_details.conversions[0].converting_people != 1 or
        cache_goal_high_details.conversions.len != 1 or
        cache_goal_high_details.conversions[0].converting_people != 0 or
        boundary_exact.total.len != 1 or
        boundary_exact.total[0] != .count or
        boundary_exact.total[0].count != 1 or
        boundary_exact.completeness.legacy_people != 1 or
        boundary_overview.visitors.current != 1 or
        boundary_overview.completeness.legacy_people != 1 or
        ineligible_boundary_exact.total.len != 1 or
        ineligible_boundary_exact.total[0] != .count or
        ineligible_boundary_exact.total[0].count != 1 or
        ineligible_boundary_exact.completeness.legacy_people != 1 or
        ineligible_boundary_overview.visitors.current != 1 or
        ineligible_boundary_overview.completeness.legacy_people != 1 or
        non_page_boundary_exact.total.len != 1 or
        non_page_boundary_exact.total[0] != .count or
        non_page_boundary_exact.total[0].count != 0 or
        non_page_boundary_exact.completeness.legacy_people != 0 or
        non_page_boundary_overview.visitors.current != 0 or
        non_page_boundary_overview.completeness.legacy_people != 0 or
        nonmeaningful_goal_overview.sessions.current != 1 or
        nonmeaningful_goal_overview.engagement_rate.current.numerator != 0 or
        nonmeaningful_goal_overview.engagement_rate.current.denominator != 1 or
        nonmeaningful_goal_overview.conversions.current != 0 or
        nonmeaningful_goal_overview.conversion_rate.current.numerator != 0)
    {
        return error.InvalidOverviewSemanticEvidence;
    }
    try analysis_store.timeoutProbe(&store);
    try std.json.Stringify.value(.{
        .metric_version = analysis.metric_version,
        .visitors = visitors,
        .engaged_sessions = engaged,
        .returning_visitors = returning,
        .desktop_sessions = desktop_sessions,
        .identified_trait_visitors = identified_visitors,
        .suggestions_range_search_filter_type_trait_site_exact = true,
        .event_filter_cardinality = page_result.cardinality,
        .event_filter_next_page = page_result.next_page,
        .typed_property_conversions = conversions,
        .currencies = revenue_result.total.len,
        .persistent_people = visitor_result.completeness.persistent_people,
        .ephemeral_people = visitor_result.completeness.ephemeral_people,
        .legacy_people = visitor_result.completeness.legacy_people,
        .comparison_points = comparison_result.comparison_points.?.len,
        .comparison_total = comparison_result.comparison_total.?[0].count,
        .comparison_persistent_people = comparison_result.comparison_completeness.?.persistent_people,
        .overview_visitors = overview_result.visitors.current,
        .overview_comparison_visitors = overview_result.visitors.comparison.?,
        .overview_sessions = overview_result.sessions.current,
        .overview_page_views = overview_result.page_views.current,
        .overview_engaged_sessions = overview_result.engagement_rate.current.numerator,
        .overview_conversions = overview_result.conversions.current,
        .overview_converting_visitors = overview_result.conversion_rate.current.numerator,
        .overview_revenue_currencies = overview_result.revenue.len,
        .overview_history_only_currency = gbp.currency,
        .overview_detail_trend_visitors = overview_details.trend.current[0].measure.count,
        .overview_detail_comparison_visitors = overview_details.trend.comparison.?[0].measure.count,
        .overview_detail_content_rows = overview_details.content.len,
        .overview_detail_acquisition_rows = overview_details.acquisition.len,
        .overview_detail_acquisition_direct_sessions = direct_sessions.?,
        .overview_detail_conversion_rows = overview_details.conversions.len,
        .overview_detail_conversion_ties_follow_resolved_name_order = std.mem.eql(u8, overview_details.conversions[0].goal_id, overview_goals[0].id) and std.mem.eql(u8, overview_details.conversions[1].goal_id, overview_goals[1].id),
        .overview_detail_audience_rows = overview_details.audience.len,
        .overview_detail_revenue_eur = revenue_details.trend.current[0].measure.amount.decimal,
        .overview_detail_health_protocol_total = overview_details.health.protocol_v1_events + overview_details.health.protocol_v2_events,
        .overview_detail_ceiling_reached_days = overview_details.health.ceiling_reached_days,
        .overview_detail_empty_dense_zero = empty_details.trend.current[0].measure.count == 0 and empty_details.health.accepted_events == 0,
        .overview_detail_cache_invalidated = refreshed_empty_details.trend.current[0].measure.count == 1 and refreshed_empty_details.health.accepted_events == 1 and refreshed_empty_details.health.ceiling_reached_days == 1,
        .overview_detail_ceiling_cache_key_exact = raised_ceiling_details.health.ceiling_reached_days == 0,
        .overview_result_cache_selector_predicate_key_exact = cache_goal_low_details.conversions[0].converting_people == 1 and cache_goal_high_details.conversions[0].converting_people == 0,
        .filtered_overview_goal_predicate_projection_exact = cache_goal_low_details.conversions[0].converting_people == 1 and cache_goal_high_details.conversions[0].converting_people == 0,
        .filtered_page_breakdown_custom_only_path_excluded = custom_only_page_result.cardinality == 1 and custom_only_page_result.rows.len == 1 and std.mem.eql(u8, custom_only_page_result.rows[0].label.value, "/real-page") and custom_only_empty_page.cardinality == 1 and custom_only_empty_page.rows.len == 0,
        .overview_filter_scopes_exact = session_filtered_overview.sessions.current == desktop_sessions and event_filtered_overview.page_views.current == event_filtered_page_views.total[0].count and person_filtered_overview.visitors.current == identified_visitors,
        .overview_no_comparison = overview_without_comparison.visitors.comparison == null,
        .overview_empty_revenue_omitted = empty_overview.revenue.len == 0,
        .overview_legacy_local_boundary_exact = boundary_overview.visitors.current == boundary_exact.total[0].count,
        .overview_ineligible_boundary_later_eligible_exact = ineligible_boundary_overview.visitors.current == ineligible_boundary_exact.total[0].count,
        .overview_non_page_boundary_excluded = non_page_boundary_overview.visitors.current == non_page_boundary_exact.total[0].count,
        .overview_nonmeaningful_goal_not_engaged = nonmeaningful_goal_overview.engagement_rate.current.numerator == 0,
        .delayed_event_delay_micros = delayed_evidence.received_at - delayed_evidence.occurred_at,
        .delayed_event_offset_minutes = delayed_evidence.offset_minutes,
        .delayed_event_hour = delayed_result.points[0].bucket,
        .cross_midnight_landing_preserved = true,
        .channel_v1_paid_search = true,
        .semantic_elapsed_ms = semantic_elapsed_ms,
        .timeout_interrupted_and_reused = true,
    }, .{}, output);
    try output.writeByte('\n');
}

fn overviewRevenue(
    rows: []const analysis.ComparedAmount,
    currency: []const u8,
) ?analysis.ComparedAmount {
    for (rows) |row| {
        if (std.mem.eql(u8, row.currency, currency)) return row;
    }
    return null;
}

fn trendQueryForSite(
    site_id: []const u8,
    range: analysis.LocalDateRange,
    kind: analysis.MetricKind,
) analysis.Query {
    var query = trendQuery(range, kind);
    query.site_id = site_id;
    return query;
}

fn hasCount(
    rows: []const analysis.BreakdownRow,
    label: []const u8,
    count: i64,
) bool {
    for (rows) |row| {
        if (std.mem.eql(u8, row.label.value, label) and
            row.measure == .count and row.measure.count == count)
        {
            return true;
        }
    }
    return false;
}

fn trendQuery(
    range: analysis.LocalDateRange,
    metric: analysis.MetricKind,
) analysis.Query {
    return .{
        .site_id = site,
        .range = range,
        .mode = .trend,
        .metric = .{ .kind = metric },
        .interval = .day,
    };
}
