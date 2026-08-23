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
        \\  'exclude.tracker' AS bot_rule, FALSE AS legacy_bot_verdict
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
        \\  'exclude.network' AS bot_rule, FALSE AS legacy_bot_verdict
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
        \\  'exclude.both' AS bot_rule, FALSE AS legacy_bot_verdict
        \\) FROM events
        \\WHERE event_id = CAST('00000000-0000-4000-8000-000000000107' AS UUID);
    );
    try metadata.checkpoint();
    try event_store.checkpoint();
    try output.writeAll("traffic-quality fixture committed sites=1 events=15 links=2\n");
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
    try analysis_store.timeoutProbe(&store);
    try std.json.Stringify.value(.{
        .metric_version = analysis.metric_version,
        .visitors = visitors,
        .engaged_sessions = engaged,
        .returning_visitors = returning,
        .desktop_sessions = desktop_sessions,
        .identified_trait_visitors = identified_visitors,
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
