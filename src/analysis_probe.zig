const std = @import("std");
const analysis = @import("analysis.zig");
const events = @import("store/events.zig");
const analysis_store = @import("store/analysis.zig");

const site = "00000000-0000-4000-8000-000000000024";

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
