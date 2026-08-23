const std = @import("std");
const analysis = @import("../analysis.zig");
const property = @import("../property.zig");
const deadline = @import("deadline.zig");
const duckdb = @import("duckdb.zig");
const events = @import("events.zig");
const traffic = @import("traffic.zig");

pub const maximum_sql_bytes: usize = 128 * 1024;
pub const maximum_bindings: usize = 8192;

pub const Binding = union(enum) {
    text: []const u8,
    integer: i64,
};

pub const StatementPlan = struct {
    sql: [:0]const u8,
    bindings: []const Binding,
};

pub const Compiled = struct {
    primary_rows: StatementPlan,
    primary_total: ?StatementPlan,
    comparison_rows: ?StatementPlan,
    comparison_total: ?StatementPlan,
    coverage: StatementPlan,
    comparison_coverage: ?StatementPlan,
    interval: analysis.Interval,
};

const Builder = struct {
    allocator: std.mem.Allocator,
    output: std.Io.Writer.Allocating,
    bindings: std.ArrayList(Binding) = .empty,

    fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .allocator = allocator,
            .output = std.Io.Writer.Allocating.init(allocator),
        };
    }

    fn write(self: *Builder, literal: []const u8) !void {
        try self.output.writer.writeAll(literal);
    }

    fn bindText(self: *Builder, value: []const u8) !void {
        if (self.bindings.items.len >= maximum_bindings) {
            return error.TooManyAnalysisBindings;
        }
        try self.output.writer.writeByte('?');
        try self.bindings.append(self.allocator, .{ .text = value });
    }

    fn bindInteger(self: *Builder, value: i64) !void {
        if (self.bindings.items.len >= maximum_bindings) {
            return error.TooManyAnalysisBindings;
        }
        try self.output.writer.writeByte('?');
        try self.bindings.append(self.allocator, .{ .integer = value });
    }

    fn finish(self: *Builder) !StatementPlan {
        if (self.output.writer.buffered().len > maximum_sql_bytes) {
            return error.AnalysisSqlTooLong;
        }
        return .{
            .sql = try self.output.toOwnedSliceSentinel(0),
            .bindings = try self.bindings.toOwnedSlice(self.allocator),
        };
    }

    fn appendTraffic(self: *Builder, fragment: traffic.Fragment) !void {
        try self.write(fragment.sql);
        for (fragment.bindings) |binding| switch (binding) {
            .text => |value| {
                if (self.bindings.items.len >= maximum_bindings) {
                    return error.TooManyAnalysisBindings;
                }
                try self.bindings.append(self.allocator, .{ .text = value });
            },
            .integer => |value| {
                if (self.bindings.items.len >= maximum_bindings) {
                    return error.TooManyAnalysisBindings;
                }
                try self.bindings.append(self.allocator, .{ .integer = value });
            },
        };
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    execution: analysis.Execution,
) !Compiled {
    try execution.validate();
    try validateCombination(execution.query);
    const interval = try resolveInterval(execution.query);
    const primary_rows = try compileRows(
        allocator,
        execution,
        execution.query.range,
        interval,
    );
    const primary_total = if (execution.query.mode == .trend)
        try compileTotal(allocator, execution, execution.query.range)
    else
        null;
    const comparison_rows = if (execution.comparison_range) |range|
        try compileRows(allocator, execution, range, interval)
    else
        null;
    const comparison_total = if (execution.comparison_range) |range|
        try compileTotal(allocator, execution, range)
    else
        null;
    return .{
        .primary_rows = primary_rows,
        .primary_total = primary_total,
        .comparison_rows = comparison_rows,
        .comparison_total = comparison_total,
        .coverage = try compileCoverage(
            allocator,
            execution,
            execution.query.range,
        ),
        .comparison_coverage = if (execution.comparison_range) |range|
            try compileCoverage(allocator, execution, range)
        else
            null,
        .interval = interval,
    };
}

const DecodedRow = struct {
    label: []const u8,
    measure: analysis.Measure,
    cardinality: i64,
};

pub fn execute(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    execution: analysis.Execution,
) !analysis.Result {
    const compiled = try compile(allocator, execution);
    var budget = deadline.Budget.init(execution.timeout_ms);
    const completeness = try executeCoverage(
        allocator,
        &event_store.database,
        compiled.coverage,
        &budget,
    );
    const comparison_completeness = if (compiled.comparison_coverage) |plan|
        try executeCoverage(
            allocator,
            &event_store.database,
            plan,
            &budget,
        )
    else
        null;
    const primary = try executeRows(
        allocator,
        &event_store.database,
        compiled.primary_rows,
        &budget,
    );
    const comparison = if (compiled.comparison_rows) |plan|
        try executeRows(
            allocator,
            &event_store.database,
            plan,
            &budget,
        )
    else
        null;
    return switch (execution.query.mode) {
        .trend => .{ .trend = .{
            .points = try trendPoints(allocator, primary),
            .comparison_points = if (comparison) |rows|
                try trendPoints(allocator, rows)
            else
                null,
            .comparison_total = if (compiled.comparison_total) |plan|
                try executeTotals(
                    allocator,
                    &event_store.database,
                    plan,
                    &budget,
                )
            else
                null,
            .comparison_completeness = comparison_completeness,
            .total = try executeTotals(
                allocator,
                &event_store.database,
                compiled.primary_total.?,
                &budget,
            ),
            .interval = compiled.interval,
            .completeness = completeness,
        } },
        .breakdown => .{ .breakdown = try breakdownResult(
            allocator,
            execution.query,
            primary,
            completeness,
        ) },
    };
}

pub fn compileOverview(
    allocator: std.mem.Allocator,
    execution: analysis.OverviewExecution,
) !StatementPlan {
    try execution.validate();
    var builder = Builder.init(allocator);
    if (execution.strict_traffic_mode) {
        var goals: [analysis.maximum_active_goals]traffic.Goal = undefined;
        for (execution.active_goals, 0..) |goal, index| goals[index] = .{
            .kind = switch (goal.selector.kind) {
                .exact_event => .event,
                .exact_page => .path,
                .page_prefix => .prefix,
                .saved_goal => return error.UnresolvedGoalSelector,
            },
            .value = goal.selector.value,
        };
        try builder.write("WITH ");
        try builder.appendTraffic(try traffic.classifierFragment(
            allocator,
            execution.site_id,
            goals[0..execution.active_goals.len],
            true,
        ));
        try builder.write(", ");
    } else try builder.write("WITH ");
    try builder.write(
        "periods(period, start_date, end_date) AS (VALUES" ++
            " (1::UTINYINT, CAST(",
    );
    try builder.bindText(execution.range.start);
    try builder.write(" AS DATE), CAST(");
    try builder.bindText(execution.range.end);
    try builder.write(" AS DATE))");
    if (execution.comparison_range) |range| {
        try builder.write(", (2::UTINYINT, CAST(");
        try builder.bindText(range.start);
        try builder.write(" AS DATE), CAST(");
        try builder.bindText(range.end);
        try builder.write(" AS DATE))");
    }
    try builder.write(
        "), range_events AS NOT MATERIALIZED (SELECT p.period, e.session_id," ++
            " e.kind, ",
    );
    try writeGoalMatchCount(&builder, execution.active_goals, "e");
    try builder.write(
        " AS goal_matches FROM events e JOIN periods p" ++
            " ON e.site_local_date BETWEEN p.start_date AND p.end_date" ++
            " WHERE e.site_id = ",
    );
    try builder.bindText(execution.site_id);
    try builder.write(
        " AND e.kind IN (1, 2) AND e.traffic_class IN (1, 5))," ++
            " qualified AS NOT MATERIALIZED (SELECT * FROM range_events WHERE TRUE",
    );
    if (execution.strict_traffic_mode) try builder.write(
        " AND session_id NOT IN (SELECT session_id" ++
            " FROM d34_current_suspected_sessions)",
    );
    try builder.write(
        "), range_sessions AS MATERIALIZED (SELECT period, session_id," ++
            " count(*) FILTER (WHERE kind = 1)::BIGINT AS range_page_views," ++
            " sum(goal_matches)::BIGINT AS conversions" ++
            " FROM qualified GROUP BY period, session_id)," ++
            " session_events AS (SELECT e.session_id, e.kind," ++
            " e.engagement_ms, ",
    );
    try writeAnyGoalMatch(&builder, execution.active_goals, "e");
    try builder.write(
        " AS goal_match FROM events e SEMI JOIN range_sessions rs" ++
            " ON rs.session_id = e.session_id WHERE e.site_id = ",
    );
    try builder.bindText(execution.site_id);
    try builder.write(
        " AND e.traffic_class IN (1, 5))," ++
            " session_stats AS MATERIALIZED (SELECT session_id," ++
            " count(*) FILTER (WHERE kind = 1)::BIGINT AS page_views," ++
            " sum(engagement_ms)::BIGINT AS engagement_ms," ++
            " bool_or(goal_match) AS goal_match" ++
            " FROM session_events GROUP BY session_id)," ++
            " event_summary AS (SELECT period, count(*)::BIGINT AS sessions," ++
            " sum(range_page_views)::BIGINT AS page_views," ++
            " sum(conversions)::BIGINT AS conversions" ++
            " FROM range_sessions GROUP BY period),",
    );
    try builder.write(
        " legacy_events AS NOT MATERIALIZED (SELECT p.period," ++
            " e.anonymous_id, ",
    );
    try writeAnyGoalMatch(&builder, execution.active_goals, "e");
    try builder.write(
        " AS goal_match FROM events e JOIN periods p" ++
            " ON e.site_local_date BETWEEN p.start_date AND p.end_date" ++
            " WHERE e.site_id = ",
    );
    try builder.bindText(execution.site_id);
    try builder.write(
        " AND e.identity_quality = 3 AND e.kind IN (1, 2)" ++
            " AND e.traffic_class IN (1, 5)",
    );
    if (execution.strict_traffic_mode) try builder.write(
        " AND e.session_id NOT IN (SELECT session_id" ++
            " FROM d34_current_suspected_sessions)",
    );
    try builder.write(
        "), legacy_people AS MATERIALIZED (SELECT period, anonymous_id," ++
            " bool_or(goal_match) AS converted FROM legacy_events" ++
            " GROUP BY period, anonymous_id)," ++
            " legacy_summary AS MATERIALIZED (SELECT period," ++
            " count(*)::BIGINT AS legacy_people," ++
            " count(*) FILTER (WHERE converted)::BIGINT" ++
            " AS converting_visitors FROM legacy_people GROUP BY period),",
    );
    try builder.write(
        " session_summary AS (SELECT rs.period," ++
            " count(*) FILTER (WHERE s.engagement_ms >= 10000" ++
            " OR s.page_views >= 2 OR s.goal_match)::BIGINT AS engaged_sessions" ++
            " FROM range_sessions rs JOIN session_stats s USING (session_id)" ++
            " GROUP BY rs.period)," ++
            " person_events AS (SELECT p.period, e.identity_quality," ++
            " CASE WHEN e.identity_quality = 1" ++
            " AND COALESCE(l.user_id, e.user_id, '') <> ''" ++
            " THEN COALESCE(l.user_id, e.user_id) ELSE '' END" ++
            " AS canonical_user_id," ++
            " CASE WHEN e.identity_quality = 1" ++
            " AND COALESCE(l.user_id, e.user_id, '') <> ''" ++
            " THEN NULL ELSE e.anonymous_id END AS canonical_anonymous_id, ",
    );
    try writeAnyGoalMatch(&builder, execution.active_goals, "e");
    try builder.write(
        " AS goal_match FROM events e JOIN periods p" ++
            " ON e.site_local_date BETWEEN p.start_date AND p.end_date" ++
            " LEFT JOIN identity_links l ON l.site_id = e.site_id" ++
            " AND l.anonymous_id = e.anonymous_id" ++
            " WHERE e.site_id = ",
    );
    try builder.bindText(execution.site_id);
    try builder.write(
        " AND e.kind IN (1, 2) AND e.traffic_class IN (1, 5)",
    );
    if (execution.strict_traffic_mode) try builder.write(
        " AND e.session_id NOT IN (SELECT session_id" ++
            " FROM d34_current_suspected_sessions)",
    );
    try builder.write(" AND e.identity_quality IN (1, 2)");
    try builder.write(
        "), people AS MATERIALIZED (SELECT period, identity_quality," ++
            " bool_or(goal_match) AS converted FROM person_events",
    );
    try builder.write(
        " GROUP BY period, identity_quality, canonical_user_id," ++
            " canonical_anonymous_id)," ++
            " people_summary AS (SELECT period," ++
            " count(*) FILTER (WHERE identity_quality = 1)::BIGINT" ++
            " AS persistent," ++
            " count(*) FILTER (WHERE identity_quality = 2)::BIGINT" ++
            " AS ephemeral," ++
            " count(*) FILTER (WHERE converted)::BIGINT AS converting_visitors" ++
            " FROM people GROUP BY period)," ++
            " overview_summary AS MATERIALIZED (SELECT p.period," ++
            " COALESCE(e.sessions, 0)::BIGINT AS sessions," ++
            " COALESCE(e.page_views, 0)::BIGINT AS page_views," ++
            " COALESCE(s.engaged_sessions, 0)::BIGINT AS engaged_sessions," ++
            " COALESCE(e.conversions, 0)::BIGINT AS conversions,",
    );
    try builder.write(
        " COALESCE(pp.persistent, 0) + COALESCE(pp.ephemeral, 0)" ++
            " + COALESCE(ls.legacy_people, 0) AS visitors,",
    );
    try builder.write(
        " COALESCE(pp.persistent, 0)::BIGINT AS persistent," ++
            " COALESCE(pp.ephemeral, 0)::BIGINT AS ephemeral,",
    );
    try builder.write(" COALESCE(ls.legacy_people, 0)::BIGINT AS legacy,");
    try builder.write(
        " (COALESCE(pp.converting_visitors, 0)" ++
            " + COALESCE(ls.converting_visitors, 0))::BIGINT" ++
            " AS converting_visitors FROM periods p" ++
            " LEFT JOIN event_summary e USING (period)" ++
            " LEFT JOIN legacy_summary ls USING (period)" ++
            " LEFT JOIN session_summary s USING (period)" ++
            " LEFT JOIN people_summary pp USING (period))," ++
            " value_events AS MATERIALIZED (SELECT site_local_date," ++
            " value_amount, value_currency FROM events WHERE site_id = ",
    );
    try builder.bindText(execution.site_id);
    try builder.write(
        " AND kind IN (1, 2) AND traffic_class IN (1, 5)" ++
            " AND value_amount IS NOT NULL AND value_currency <> ''",
    );
    if (execution.strict_traffic_mode) try builder.write(
        " AND session_id NOT IN (SELECT session_id" ++
            " FROM d34_current_suspected_sessions)",
    );
    try builder.write(
        "), overview_revenue AS (SELECT p.period," ++
            " e.value_currency AS currency," ++
            " CAST(sum(e.value_amount) AS VARCHAR) AS amount," ++
            " count(*)::BIGINT AS value_count," ++
            " row_number() OVER (PARTITION BY p.period" ++
            " ORDER BY e.value_currency) AS position" ++
            " FROM value_events e JOIN periods p ON e.site_local_date" ++
            " BETWEEN p.start_date AND p.end_date" ++
            " GROUP BY p.period, e.value_currency)" ++
            " SELECT CASE o.period WHEN 1 THEN 'current' ELSE 'comparison' END" ++
            " AS period, v.metric, v.numerator::BIGINT," ++
            " v.denominator::BIGINT, CAST(NULL AS VARCHAR) AS amount," ++
            " '' AS currency, 0::BIGINT AS value_count," ++
            " o.persistent, o.ephemeral, o.legacy," ++
            " CAST(NULL AS VARCHAR) AS text_value" ++
            " FROM overview_summary o CROSS JOIN LATERAL (VALUES" ++
            " ('visitors', o.visitors, 0)," ++
            " ('sessions', o.sessions, 0)," ++
            " ('page-views', o.page_views, 0)," ++
            " ('engagement-rate', o.engaged_sessions, o.sessions)," ++
            " ('conversions', o.conversions, 0)," ++
            " ('conversion-rate', o.converting_visitors, o.visitors)" ++
            ") v(metric, numerator, denominator)" ++
            " UNION ALL SELECT CASE r.period WHEN 1 THEN 'current'" ++
            " ELSE 'comparison' END AS period, 'revenue' AS metric," ++
            " 0::BIGINT AS numerator, 0::BIGINT AS denominator," ++
            " r.amount, r.currency, r.value_count," ++
            " o.persistent, o.ephemeral, o.legacy," ++
            " CAST(NULL AS VARCHAR) AS text_value" ++
            " FROM overview_revenue r JOIN overview_summary o USING (period)" ++
            " WHERE r.position <= ",
    );
    try builder.bindInteger(@as(i64, analysis.maximum_currency_series) + 1);
    try builder.write(
        " UNION ALL SELECT * FROM (SELECT 'history' AS period," ++
            " 'revenue' AS metric, 0::BIGINT AS numerator," ++
            " 0::BIGINT AS denominator, CAST(NULL AS VARCHAR) AS amount," ++
            " value_currency AS currency, 0::BIGINT AS value_count," ++
            " 0::BIGINT AS persistent, 0::BIGINT AS ephemeral," ++
            " 0::BIGINT AS legacy, CAST(NULL AS VARCHAR) AS text_value" ++
            " FROM value_events GROUP BY value_currency" ++
            " ORDER BY value_currency LIMIT ",
    );
    try builder.bindInteger(@as(i64, analysis.maximum_currency_series) + 1);
    try builder.write(") AS observed_currency_rows");
    return builder.finish();
}

pub fn executeOverview(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    execution: analysis.OverviewExecution,
) !analysis.OverviewResult {
    const plan = try compileOverview(allocator, execution);
    var budget = deadline.Budget.init(execution.timeout_ms);
    var result = try executePlan(&event_store.database, plan, &budget);
    defer result.deinit();
    if (result.columnCount() != 11 or result.rowCount() > 64) {
        return error.InvalidOverviewResult;
    }

    var current = OverviewPeriodState{};
    var comparison = OverviewPeriodState{};
    var revenues: std.ArrayList(MutableRevenue) = .empty;
    defer revenues.deinit(allocator);

    for (0..result.rowCount()) |row| {
        const period = try result.text(allocator, 0, row);
        const metric = try result.text(allocator, 1, row);
        if (std.mem.eql(u8, period, "history")) {
            if (std.mem.eql(u8, metric, "revenue")) {
                const currency = try result.text(allocator, 5, row);
                _ = try revenueForCurrency(allocator, &revenues, currency);
            } else return error.InvalidOverviewResult;
            continue;
        }

        const state = if (std.mem.eql(u8, period, "current"))
            &current
        else if (std.mem.eql(u8, period, "comparison"))
            &comparison
        else
            return error.InvalidOverviewResult;
        try state.setCoverage(
            result.int64(7, row),
            result.int64(8, row),
            result.int64(9, row),
        );
        const numerator = result.int64(2, row);
        const denominator = result.int64(3, row);
        if (std.mem.eql(u8, metric, "visitors")) {
            try setCount(&state.visitors, numerator, denominator);
        } else if (std.mem.eql(u8, metric, "sessions")) {
            try setCount(&state.sessions, numerator, denominator);
        } else if (std.mem.eql(u8, metric, "page-views")) {
            try setCount(&state.page_views, numerator, denominator);
        } else if (std.mem.eql(u8, metric, "engagement-rate")) {
            try setRatio(&state.engagement_rate, numerator, denominator);
        } else if (std.mem.eql(u8, metric, "conversions")) {
            try setCount(&state.conversions, numerator, denominator);
        } else if (std.mem.eql(u8, metric, "conversion-rate")) {
            try setRatio(&state.conversion_rate, numerator, denominator);
        } else if (std.mem.eql(u8, metric, "revenue")) {
            if (result.isNull(4, row)) return error.InvalidOverviewResult;
            const amount = try result.text(allocator, 4, row);
            const currency = try result.text(allocator, 5, row);
            const value_count = result.int64(6, row);
            if (currency.len != 3 or value_count <= 0) {
                return error.InvalidOverviewResult;
            }
            const revenue = try revenueForCurrency(allocator, &revenues, currency);
            if (std.mem.eql(u8, period, "current")) {
                if (revenue.current != null) return error.InvalidOverviewResult;
                revenue.current = .{
                    .decimal = amount,
                    .currency = revenue.currency,
                    .value_count = value_count,
                };
            } else {
                if (revenue.comparison != null) return error.InvalidOverviewResult;
                revenue.comparison = .{
                    .decimal = amount,
                    .currency = revenue.currency,
                    .value_count = value_count,
                };
            }
        } else return error.InvalidOverviewResult;
    }

    try current.validate();
    if (execution.comparison_range != null) {
        try comparison.validate();
    } else if (comparison.hasAny()) return error.InvalidOverviewResult;
    if (current.coverage.?.total_people != current.visitors.?) {
        return error.InvalidOverviewResult;
    }
    if (execution.comparison_range != null and
        comparison.coverage.?.total_people != comparison.visitors.?)
    {
        return error.InvalidOverviewResult;
    }

    std.mem.sort(MutableRevenue, revenues.items, {}, MutableRevenue.lessThan);
    const decoded_revenue = try allocator.alloc(
        analysis.ComparedAmount,
        revenues.items.len,
    );
    for (decoded_revenue, revenues.items) |*decoded, source| {
        decoded.* = .{
            .currency = source.currency,
            .current = source.current orelse .{
                .decimal = "0.000000",
                .currency = source.currency,
                .value_count = 0,
            },
            .comparison = if (execution.comparison_range != null)
                source.comparison orelse .{
                    .decimal = "0.000000",
                    .currency = source.currency,
                    .value_count = 0,
                }
            else
                null,
        };
    }
    var current_coverage = current.coverage.?;
    current_coverage.persistent_since_local_date = null;
    const comparison_coverage = if (execution.comparison_range != null) value: {
        var coverage = comparison.coverage.?;
        coverage.persistent_since_local_date = null;
        break :value coverage;
    } else null;
    return .{
        .visitors = .{
            .current = current.visitors.?,
            .comparison = if (execution.comparison_range != null)
                comparison.visitors.?
            else
                null,
        },
        .sessions = .{
            .current = current.sessions.?,
            .comparison = if (execution.comparison_range != null)
                comparison.sessions.?
            else
                null,
        },
        .page_views = .{
            .current = current.page_views.?,
            .comparison = if (execution.comparison_range != null)
                comparison.page_views.?
            else
                null,
        },
        .engagement_rate = .{
            .current = current.engagement_rate.?,
            .comparison = if (execution.comparison_range != null)
                comparison.engagement_rate.?
            else
                null,
        },
        .conversions = .{
            .current = current.conversions.?,
            .comparison = if (execution.comparison_range != null)
                comparison.conversions.?
            else
                null,
        },
        .conversion_rate = .{
            .current = current.conversion_rate.?,
            .comparison = if (execution.comparison_range != null)
                comparison.conversion_rate.?
            else
                null,
        },
        .revenue = decoded_revenue,
        .completeness = current_coverage,
        .comparison_completeness = comparison_coverage,
    };
}

pub fn profileOverview(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    execution: analysis.OverviewExecution,
) ![]u8 {
    const plan = try compileOverview(allocator, execution);
    var sql = std.Io.Writer.Allocating.init(allocator);
    try sql.writer.writeAll("EXPLAIN ANALYZE ");
    try sql.writer.writeAll(plan.sql);
    const sql_z = try sql.toOwnedSliceSentinel(0);
    var statement = try event_store.database.prepare(sql_z);
    defer statement.deinit();
    for (plan.bindings, 1..) |binding, index| switch (binding) {
        .text => |value| try statement.bindText(index, value),
        .integer => |value| try statement.bindInt64(index, value),
    };
    var result = try statement.execute();
    defer result.deinit();
    if (result.columnCount() != 2 or result.rowCount() == 0) {
        return error.InvalidOverviewProfile;
    }
    var output = std.Io.Writer.Allocating.init(allocator);
    for (0..result.rowCount()) |row| {
        try output.writer.writeAll(try result.text(allocator, 1, row));
        try output.writer.writeByte('\n');
    }
    return output.toOwnedSlice();
}

const OverviewPeriodState = struct {
    visitors: ?i64 = null,
    sessions: ?i64 = null,
    page_views: ?i64 = null,
    engagement_rate: ?analysis.Ratio = null,
    conversions: ?i64 = null,
    conversion_rate: ?analysis.Ratio = null,
    coverage: ?analysis.Completeness = null,

    fn setCoverage(self: *OverviewPeriodState, persistent: i64, ephemeral: i64, legacy: i64) !void {
        if (persistent < 0 or ephemeral < 0 or legacy < 0) {
            return error.InvalidOverviewResult;
        }
        const total = std.math.add(
            i64,
            std.math.add(i64, persistent, ephemeral) catch
                return error.InvalidOverviewResult,
            legacy,
        ) catch return error.InvalidOverviewResult;
        const coverage = analysis.Completeness{
            .total_people = total,
            .persistent_people = persistent,
            .ephemeral_people = ephemeral,
            .legacy_people = legacy,
            .persistent_basis_points = if (total == 0)
                0
            else
                @intCast(@divTrunc(
                    std.math.mul(i64, persistent, 10_000) catch
                        return error.InvalidOverviewResult,
                    total,
                )),
            .persistent_since_local_date = null,
        };
        if (self.coverage) |prior| {
            if (prior.total_people != coverage.total_people or
                prior.persistent_people != persistent or
                prior.ephemeral_people != ephemeral or
                prior.legacy_people != legacy)
            {
                return error.InvalidOverviewResult;
            }
        } else self.coverage = coverage;
    }

    fn validate(self: OverviewPeriodState) !void {
        if (self.coverage == null or self.visitors == null or
            self.sessions == null or
            self.page_views == null or self.engagement_rate == null or
            self.conversions == null or self.conversion_rate == null)
        {
            return error.InvalidOverviewResult;
        }
    }

    fn hasAny(self: OverviewPeriodState) bool {
        return self.coverage != null or self.visitors != null or
            self.sessions != null or self.page_views != null or
            self.engagement_rate != null or self.conversions != null or
            self.conversion_rate != null;
    }
};

const MutableRevenue = struct {
    currency: []const u8,
    current: ?analysis.ExactAmount = null,
    comparison: ?analysis.ExactAmount = null,

    fn lessThan(_: void, left: MutableRevenue, right: MutableRevenue) bool {
        return std.mem.lessThan(u8, left.currency, right.currency);
    }
};

fn revenueForCurrency(
    allocator: std.mem.Allocator,
    revenues: *std.ArrayList(MutableRevenue),
    currency: []const u8,
) !*MutableRevenue {
    if (currency.len != 3) return error.InvalidOverviewResult;
    for (revenues.items) |*revenue| {
        if (std.mem.eql(u8, revenue.currency, currency)) return revenue;
    }
    if (revenues.items.len >= analysis.maximum_currency_series) {
        return error.TooManyAnalysisCurrencies;
    }
    try revenues.append(allocator, .{ .currency = currency });
    return &revenues.items[revenues.items.len - 1];
}

fn setCount(slot: *?i64, numerator: i64, denominator: i64) !void {
    if (slot.* != null or numerator < 0 or denominator != 0) {
        return error.InvalidOverviewResult;
    }
    slot.* = numerator;
}

fn setRatio(slot: *?analysis.Ratio, numerator: i64, denominator: i64) !void {
    if (slot.* != null or numerator < 0 or denominator < 0 or
        numerator > denominator)
    {
        return error.InvalidOverviewResult;
    }
    slot.* = .{ .numerator = numerator, .denominator = denominator };
}

fn writeGoalMatchCount(
    builder: *Builder,
    goals: []const analysis.ResolvedGoal,
    event_alias: []const u8,
) !void {
    if (goals.len == 0) return builder.write("0::BIGINT");
    try builder.write("(");
    for (goals, 0..) |goal, index| {
        if (index != 0) try builder.write(" + ");
        try builder.write("CASE WHEN ");
        try writeSelector(builder, goal.selector, event_alias);
        try builder.write(" THEN 1 ELSE 0 END");
    }
    try builder.write(")::BIGINT");
}

fn writeAnyGoalMatch(
    builder: *Builder,
    goals: []const analysis.ResolvedGoal,
    event_alias: []const u8,
) !void {
    if (goals.len == 0) return builder.write("FALSE");
    try builder.write("(");
    for (goals, 0..) |goal, index| {
        if (index != 0) try builder.write(" OR ");
        try writeSelector(builder, goal.selector, event_alias);
    }
    try builder.write(")");
}

fn executeRows(
    allocator: std.mem.Allocator,
    database: *duckdb.Database,
    plan: StatementPlan,
    budget: *deadline.Budget,
) ![]const DecodedRow {
    var result = try executePlan(database, plan, budget);
    defer result.deinit();
    if (result.columnCount() != 7) return error.InvalidAnalysisResult;
    if (result.rowCount() > analysis.maximum_trend_rows) {
        return error.TooManyAnalysisTrendRows;
    }
    const rows = try allocator.alloc(DecodedRow, result.rowCount());
    for (rows, 0..) |*row, index| {
        row.* = .{
            .label = try result.text(allocator, 0, index),
            .measure = try decodeMeasure(allocator, &result, index),
            .cardinality = result.int64(6, index),
        };
    }
    return rows;
}

fn executeTotals(
    allocator: std.mem.Allocator,
    database: *duckdb.Database,
    plan: StatementPlan,
    budget: *deadline.Budget,
) ![]const analysis.Measure {
    var result = try executePlan(database, plan, budget);
    defer result.deinit();
    if (result.columnCount() != 7) return error.InvalidAnalysisResult;
    const totals = try allocator.alloc(analysis.Measure, result.rowCount());
    for (totals, 0..) |*total, index| {
        total.* = try decodeMeasure(allocator, &result, index);
    }
    if (totals.len > analysis.maximum_currency_series) {
        return error.TooManyAnalysisCurrencies;
    }
    return totals;
}

fn executeCoverage(
    allocator: std.mem.Allocator,
    database: *duckdb.Database,
    plan: StatementPlan,
    budget: *deadline.Budget,
) !analysis.Completeness {
    var result = try executePlan(database, plan, budget);
    defer result.deinit();
    if (result.columnCount() != 4 or result.rowCount() != 1) {
        return error.InvalidAnalysisResult;
    }
    const persistent = result.int64(0, 0);
    const ephemeral = result.int64(1, 0);
    const legacy = result.int64(2, 0);
    const total = std.math.add(
        i64,
        std.math.add(i64, persistent, ephemeral) catch
            return error.InvalidAnalysisResult,
        legacy,
    ) catch return error.InvalidAnalysisResult;
    return .{
        .total_people = total,
        .persistent_people = persistent,
        .ephemeral_people = ephemeral,
        .legacy_people = legacy,
        .persistent_basis_points = if (total == 0)
            0
        else
            @intCast(@divTrunc(
                std.math.mul(i64, persistent, 10_000) catch
                    return error.InvalidAnalysisResult,
                total,
            )),
        .persistent_since_local_date = if (result.isNull(3, 0))
            null
        else
            try result.text(allocator, 3, 0),
    };
}

fn executePlan(
    database: *duckdb.Database,
    plan: StatementPlan,
    budget: *deadline.Budget,
) !duckdb.Result {
    var statement = try database.prepare(plan.sql);
    defer statement.deinit();
    for (plan.bindings, 1..) |binding, index| switch (binding) {
        .text => |value| try statement.bindText(index, value),
        .integer => |value| try statement.bindInt64(index, value),
    };
    return budget.execute(database, &statement) catch |err| {
        if (err == error.ReportTimeout) return error.AnalysisTimeout;
        return err;
    };
}

fn decodeMeasure(
    allocator: std.mem.Allocator,
    result: *duckdb.Result,
    row: usize,
) !analysis.Measure {
    return switch (result.int64(1, row)) {
        1 => .{ .count = result.int64(2, row) },
        2 => .{ .ratio = .{
            .numerator = result.int64(2, row),
            .denominator = result.int64(3, row),
        } },
        3 => .{ .amount = .{
            .decimal = try result.text(allocator, 4, row),
            .currency = try result.text(allocator, 5, row),
            .value_count = result.int64(3, row),
        } },
        else => error.InvalidAnalysisMeasure,
    };
}

fn trendPoints(
    allocator: std.mem.Allocator,
    rows: []const DecodedRow,
) ![]const analysis.TrendPoint {
    const points = try allocator.alloc(analysis.TrendPoint, rows.len);
    for (points, rows) |*point, row| {
        point.* = .{ .bucket = row.label, .measure = row.measure };
    }
    return points;
}

fn breakdownResult(
    allocator: std.mem.Allocator,
    query: analysis.Query,
    primary: []const DecodedRow,
    completeness: analysis.Completeness,
) !analysis.BreakdownResult {
    const decoded = @min(primary.len, @as(usize, query.limit));
    const rows = try allocator.alloc(analysis.BreakdownRow, decoded);
    for (rows, primary[0..decoded]) |*row, source| {
        row.* = .{
            .label = .{
                .value = source.label,
                .scalar_type = if (query.dimension.?.kind == .event_property)
                    query.dimension.?.property_ref.?.scalar_type
                else
                    null,
            },
            .measure = source.measure,
        };
    }
    const cardinality = if (primary.len == 0) 0 else primary[0].cardinality;
    return .{
        .rows = rows,
        .next_page = if (primary.len > decoded) query.page + 1 else null,
        .cardinality = cardinality,
        .completeness = completeness,
    };
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

fn validateCombination(query: analysis.Query) !void {
    if (query.mode == .breakdown and query.dimension.?.kind == .event_property and
        query.dimension.?.property_ref == null)
    {
        return error.MissingAnalysisProperty;
    }
    if ((query.metric.kind == .new_visitors or
        query.metric.kind == .returning_visitors) and
        query.dimension != null and
        query.dimension.?.kind == .event_property)
    {
        return error.UnsupportedMetricDimension;
    }
}

fn resolveInterval(query: analysis.Query) !analysis.Interval {
    if (query.mode == .breakdown) return .auto;
    if (query.interval != .auto) return query.interval;
    const days = try query.range.days();
    if (days <= 2) return .hour;
    if (days <= 45) return .day;
    if (days <= 180) return .week;
    return .month;
}

fn compileRows(
    allocator: std.mem.Allocator,
    execution: analysis.Execution,
    range: analysis.LocalDateRange,
    interval: analysis.Interval,
) !StatementPlan {
    var builder = Builder.init(allocator);
    try writeCommon(&builder, execution, range);
    try builder.write(", metric_rows AS (SELECT ");
    if (execution.query.mode == .trend) {
        try writeBucket(&builder, interval, "e");
    } else {
        try writeDimension(&builder, execution.query.dimension.?, "e", "s");
    }
    try builder.write(" AS label, ");
    try writeMeasure(&builder, execution, range, "e", "s");
    try builder.write(" FROM qualified e JOIN session_facts s USING (session_id)");
    try writeMetricWhere(&builder, execution, "e", "s");
    try builder.write(" GROUP BY 1");
    if (isAmount(execution.query.metric.kind)) try builder.write(", e.value_currency");
    try builder.write(") SELECT label, measure_kind, numerator, denominator, amount, currency, count(*) OVER ()::BIGINT AS cardinality FROM metric_rows");
    try writeOrder(&builder, execution.query);
    if (execution.query.mode == .breakdown) {
        try builder.write(" LIMIT ");
        try builder.bindInteger(@as(i64, execution.query.limit) + 1);
        try builder.write(" OFFSET ");
        try builder.bindInteger(try execution.query.offset());
    } else {
        try builder.write(" LIMIT ");
        try builder.bindInteger(@as(i64, analysis.maximum_trend_rows) + 1);
    }
    return builder.finish();
}

fn compileTotal(
    allocator: std.mem.Allocator,
    execution: analysis.Execution,
    range: analysis.LocalDateRange,
) !StatementPlan {
    var builder = Builder.init(allocator);
    try writeCommon(&builder, execution, range);
    try builder.write(" SELECT '' AS label, ");
    try writeMeasure(&builder, execution, range, "e", "s");
    try builder.write(", 1::BIGINT AS cardinality FROM qualified e JOIN session_facts s USING (session_id)");
    try writeMetricWhere(&builder, execution, "e", "s");
    if (isAmount(execution.query.metric.kind)) {
        try builder.write(" GROUP BY e.value_currency ORDER BY e.value_currency LIMIT ");
        try builder.bindInteger(@as(i64, analysis.maximum_currency_series) + 1);
    }
    return builder.finish();
}

fn compileCoverage(
    allocator: std.mem.Allocator,
    execution: analysis.Execution,
    range: analysis.LocalDateRange,
) !StatementPlan {
    var builder = Builder.init(allocator);
    try writeCommon(&builder, execution, range);
    try builder.write(
        " SELECT count(DISTINCT person_key) FILTER (WHERE identity_quality = 1)," ++
            " count(DISTINCT person_key) FILTER (WHERE identity_quality = 2)," ++
            " count(DISTINCT person_key) FILTER (WHERE identity_quality = 3)," ++
            " (SELECT CAST(min(site_local_date) AS VARCHAR) FROM events" ++
            " WHERE site_id = ",
    );
    try builder.bindText(execution.query.site_id);
    try builder.write(
        " AND kind IN (1, 2) AND traffic_class IN (1, 5)" ++
            " AND identity_quality = 1",
    );
    if (execution.strict_traffic_mode) try builder.write(
        " AND session_id NOT IN (SELECT session_id" ++
            " FROM d34_current_suspected_sessions)",
    );
    try builder.write(") FROM qualified");
    return builder.finish();
}

fn writeCommon(
    builder: *Builder,
    execution: analysis.Execution,
    range: analysis.LocalDateRange,
) !void {
    if (execution.strict_traffic_mode) {
        var goals: [analysis.maximum_active_goals]traffic.Goal = undefined;
        for (execution.active_goals, 0..) |goal, index| {
            goals[index] = .{
                .kind = switch (goal.selector.kind) {
                    .exact_event => .event,
                    .exact_page => .path,
                    .page_prefix => .prefix,
                    .saved_goal => return error.UnresolvedGoalSelector,
                },
                .value = goal.selector.value,
            };
        }
        try builder.write("WITH ");
        try builder.appendTraffic(try traffic.classifierFragment(
            builder.allocator,
            execution.query.site_id,
            goals[0..execution.active_goals.len],
            true,
        ));
        try builder.write(", range_events AS (SELECT e.*, CASE");
    } else {
        try builder.write("WITH range_events AS (SELECT e.*, CASE");
    }
    try builder.write(
        " WHEN e.identity_quality = 1 AND COALESCE(l.user_id, e.user_id, '') <> ''" ++
            " THEN 'u:' || COALESCE(l.user_id, e.user_id)" ++
            " WHEN e.identity_quality = 1 THEN 'a:' || CAST(e.anonymous_id AS VARCHAR)" ++
            " WHEN e.identity_quality = 2 THEN 'e:' || CAST(e.anonymous_id AS VARCHAR)" ++
            " WHEN e.identity_quality = 3 THEN 'l:' || CAST(e.anonymous_id AS VARCHAR)" ++
            " ELSE NULL END AS person_key" ++
            " FROM events e LEFT JOIN identity_links l" ++
            " ON l.site_id = e.site_id AND l.anonymous_id = e.anonymous_id" ++
            " WHERE e.site_id = ",
    );
    try builder.bindText(execution.query.site_id);
    try builder.write(" AND e.site_local_date BETWEEN CAST(");
    try builder.bindText(range.start);
    try builder.write(" AS DATE) AND CAST(");
    try builder.bindText(range.end);
    try builder.write(
        " AS DATE) AND e.traffic_class IN (1, 5))," ++
            " base AS (SELECT * FROM range_events WHERE kind IN (1, 2))," ++
            " session_events AS (SELECT e.* FROM events e" ++
            " WHERE e.site_id = ",
    );
    try builder.bindText(execution.query.site_id);
    try builder.write(
        " AND e.traffic_class IN (1, 5)" ++
            " AND e.session_id IN" ++
            " (SELECT DISTINCT session_id FROM range_events))," ++
            " session_meaningful AS (SELECT * FROM session_events WHERE kind IN (1, 2))," ++
            " page_ascending AS (SELECT *, row_number() OVER (PARTITION BY session_id" ++
            " ORDER BY occurred_at_utc_micros, sequence, received_at_utc_micros, event_id) AS position" ++
            " FROM session_meaningful WHERE kind = 1)," ++
            " page_descending AS (SELECT *, row_number() OVER (PARTITION BY session_id" ++
            " ORDER BY occurred_at_utc_micros DESC, sequence DESC, received_at_utc_micros DESC, event_id DESC) AS position" ++
            " FROM session_meaningful WHERE kind = 1)," ++
            " event_ascending AS (SELECT *, row_number() OVER (PARTITION BY session_id" ++
            " ORDER BY occurred_at_utc_micros, sequence, received_at_utc_micros, event_id) AS position" ++
            " FROM session_meaningful)," ++
            " session_stats AS (SELECT session_id," ++
            " min(occurred_at_utc_micros) AS first_at," ++
            " max(occurred_at_utc_micros) AS last_at," ++
            " count(*) FILTER (WHERE kind = 1)::BIGINT AS page_views," ++
            " sum(engagement_ms)::BIGINT AS engagement_ms" ++
            " FROM session_events GROUP BY session_id)," ++
            " session_facts AS (SELECT st.session_id," ++
            " COALESCE(fp.path, '') AS landing_page," ++
            " COALESCE(lp.path, '') AS exit_page," ++
            " COALESCE(fp.referrer_host, '') AS referrer," ++
            " COALESCE(fp.utm_source, '') AS utm_source," ++
            " COALESCE(fp.utm_medium, '') AS utm_medium," ++
            " COALESCE(fp.utm_campaign, '') AS utm_campaign," ++
            " COALESCE(fp.utm_term, '') AS utm_term," ++
            " COALESCE(fp.utm_content, '') AS utm_content," ++
            " COALESCE(fe.country_code, 'ZZ') AS country," ++
            " COALESCE(fe.language, '') AS language," ++
            " COALESCE(fe.device_category, 'unknown') AS device," ++
            " COALESCE(fe.browser_family, 'Unknown') AS browser," ++
            " COALESCE(fe.os_family, 'Unknown') AS operating_system," ++
            " CASE" ++
            " WHEN COALESCE(fp.utm_source, '') = ''" ++
            "  AND COALESCE(fp.utm_medium, '') = ''" ++
            "  AND COALESCE(fp.referrer_host, '') = '' THEN 'Direct'" ++
            " WHEN lower(fp.utm_medium) IN ('cpc', 'ppc', 'paidsearch') THEN 'Paid Search'" ++
            " WHEN lower(fp.utm_medium) = 'organic' THEN 'Organic Search'" ++
            " WHEN lower(fp.utm_medium) IN" ++
            "  ('social', 'social-network', 'social-media', 'sm') THEN 'Social'" ++
            " WHEN lower(fp.utm_medium) = 'email' THEN 'Email'" ++
            " WHEN lower(fp.utm_medium) = 'referral'" ++
            "  OR (COALESCE(fp.referrer_host, '') <> ''" ++
            "      AND COALESCE(fp.utm_source, '') = ''" ++
            "      AND COALESCE(fp.utm_medium, '') = '') THEN 'Referral'" ++
            " ELSE 'Other / Unknown' END AS channel," ++
            " greatest(0, (st.last_at - st.first_at) / 1000)::BIGINT AS duration_ms," ++
            " st.engagement_ms, st.page_views," ++
            " (st.engagement_ms >= 10000 OR st.page_views >= 2 OR ",
    );
    try writeActiveGoalExists(builder, execution.active_goals, "st.session_id");
    try builder.write(
        ") AS engaged, ",
    );
    try writeActiveGoalExists(builder, execution.active_goals, "st.session_id");
    try builder.write(
        " AS converted FROM session_stats st" ++
            " LEFT JOIN page_ascending fp ON fp.session_id = st.session_id AND fp.position = 1" ++
            " LEFT JOIN page_descending lp ON lp.session_id = st.session_id AND lp.position = 1" ++
            " LEFT JOIN event_ascending fe ON fe.session_id = st.session_id AND fe.position = 1)",
    );
    if (hasUserTraitClause(execution.query.filters.clauses)) {
        try writePersonTraits(
            builder,
            execution.query.site_id,
            execution.strict_traffic_mode,
        );
    }
    try builder.write(
        ", qualified AS (SELECT e.* FROM base e JOIN session_facts s USING (session_id) WHERE TRUE",
    );
    for (execution.query.filters.clauses) |clause| {
        try builder.write(" AND ");
        try writeClause(builder, clause, "e", "s");
    }
    if (execution.strict_traffic_mode) try builder.write(
        " AND e.session_id NOT IN (SELECT session_id" ++
            " FROM d34_current_suspected_sessions)",
    );
    try builder.write(")");
}

fn writeActiveGoalExists(
    builder: *Builder,
    goals: []const analysis.ResolvedGoal,
    session_expression: []const u8,
) !void {
    if (goals.len == 0) return builder.write("FALSE");
    try builder.write("EXISTS (SELECT 1 FROM session_meaningful g WHERE g.session_id = ");
    try builder.write(session_expression);
    try builder.write(" AND (");
    for (goals, 0..) |goal, index| {
        if (index != 0) try builder.write(" OR ");
        try writeSelector(builder, goal.selector, "g");
    }
    try builder.write("))");
}

fn hasUserTraitClause(clauses: []const analysis.Clause) bool {
    for (clauses) |clause| {
        if (clause.field.kind == .user_trait) return true;
    }
    return false;
}

fn writePersonTraits(
    builder: *Builder,
    site_id: []const u8,
    strict_traffic_mode: bool,
) !void {
    try builder.write(
        ", person_trait_events AS (SELECT e.*, CASE" ++
            " WHEN COALESCE(l.user_id, e.user_id, '') <> ''" ++
            " THEN 'u:' || COALESCE(l.user_id, e.user_id)" ++
            " ELSE 'a:' || CAST(e.anonymous_id AS VARCHAR) END AS person_key" ++
            " FROM events e LEFT JOIN identity_links l" ++
            " ON l.site_id = e.site_id AND l.anonymous_id = e.anonymous_id" ++
            " WHERE e.site_id = ",
    );
    try builder.bindText(site_id);
    try builder.write(
        " AND e.kind = 4 AND e.identity_quality = 1" ++
            " AND e.traffic_class IN (1, 5)",
    );
    if (strict_traffic_mode) try builder.write(
        " AND e.session_id NOT IN (SELECT session_id" ++
            " FROM d34_current_suspected_sessions)",
    );
    try builder.write(
        ")," ++
            " person_traits AS (SELECT * EXCLUDE (position) FROM (SELECT *," ++
            " row_number() OVER (PARTITION BY person_key" ++
            " ORDER BY occurred_at_utc_micros DESC, sequence DESC," ++
            " received_at_utc_micros DESC, event_id DESC) AS position" ++
            " FROM person_trait_events) ranked WHERE position = 1)",
    );
}

fn writeMeasure(
    builder: *Builder,
    execution: analysis.Execution,
    range: analysis.LocalDateRange,
    event_alias: []const u8,
    session_alias: []const u8,
) !void {
    const metric = execution.query.metric;
    switch (metric.kind) {
        .revenue, .average_value => {
            try builder.write(
                "3::UTINYINT AS measure_kind, 0::BIGINT AS numerator," ++
                    " count(*)::BIGINT AS denominator," ++
                    " CAST(sum(",
            );
            try builder.write(event_alias);
            try builder.write(".value_amount) AS VARCHAR) AS amount, ");
            try builder.write(event_alias);
            try builder.write(".value_currency AS currency");
        },
        .engagement_rate, .bounce_rate, .conversion_rate => {
            try builder.write("2::UTINYINT AS measure_kind, ");
            switch (metric.kind) {
                .engagement_rate => {
                    try builder.write("count(DISTINCT CASE WHEN ");
                    try builder.write(session_alias);
                    try builder.write(".engaged THEN ");
                    try builder.write(event_alias);
                    try builder.write(".session_id END)::BIGINT");
                },
                .bounce_rate => {
                    try builder.write("(count(DISTINCT ");
                    try builder.write(event_alias);
                    try builder.write(".session_id) - count(DISTINCT CASE WHEN ");
                    try builder.write(session_alias);
                    try builder.write(".engaged THEN ");
                    try builder.write(event_alias);
                    try builder.write(".session_id END))::BIGINT");
                },
                .conversion_rate => {
                    const selector = (try analysis.resolvedSelector(
                        metric.selector,
                        execution.active_goals,
                    )).?;
                    try builder.write("count(DISTINCT CASE WHEN ");
                    try writeSelectorResolution(builder, selector, event_alias);
                    try builder.write(" THEN ");
                    switch (metric.conversion_basis.?) {
                        .event => unreachable,
                        .visitor => {
                            try builder.write(event_alias);
                            try builder.write(".person_key");
                        },
                        .session => {
                            try builder.write(event_alias);
                            try builder.write(".session_id");
                        },
                    }
                    try builder.write(" END)::BIGINT");
                },
                else => unreachable,
            }
            try builder.write(" AS numerator, count(DISTINCT ");
            if (metric.kind == .conversion_rate and
                metric.conversion_basis.? == .visitor)
            {
                try builder.write(event_alias);
                try builder.write(".person_key");
            } else {
                try builder.write(event_alias);
                try builder.write(".session_id");
            }
            try builder.write(
                ")::BIGINT AS denominator, CAST(NULL AS VARCHAR) AS amount," ++
                    " '' AS currency",
            );
        },
        else => {
            try builder.write("1::UTINYINT AS measure_kind, ");
            try writeCount(builder, execution, range, event_alias, session_alias);
            try builder.write(
                "::BIGINT AS numerator, 0::BIGINT AS denominator," ++
                    " CAST(NULL AS VARCHAR) AS amount, '' AS currency",
            );
        },
    }
}

fn writeCount(
    builder: *Builder,
    execution: analysis.Execution,
    range: analysis.LocalDateRange,
    event_alias: []const u8,
    session_alias: []const u8,
) !void {
    switch (execution.query.metric.kind) {
        .visitors, .event_visitors => {
            try builder.write("count(DISTINCT ");
            try builder.write(event_alias);
            try builder.write(".person_key)");
        },
        .new_visitors, .returning_visitors => {
            try builder.write("count(DISTINCT CASE WHEN ");
            try builder.write(event_alias);
            try builder.write(".identity_quality = 1 AND ");
            try writeFirstPersonDate(builder, event_alias);
            if (execution.query.metric.kind == .new_visitors) {
                try builder.write(" BETWEEN CAST(");
                try builder.bindText(range.start);
                try builder.write(" AS DATE) AND CAST(");
                try builder.bindText(range.end);
                try builder.write(" AS DATE)");
            } else {
                try builder.write(" < CAST(");
                try builder.bindText(range.start);
                try builder.write(" AS DATE)");
            }
            try builder.write(" THEN ");
            try builder.write(event_alias);
            try builder.write(".person_key END)");
        },
        .sessions => {
            try builder.write("count(DISTINCT ");
            try builder.write(event_alias);
            try builder.write(".session_id)");
        },
        .engaged_sessions => {
            try builder.write("count(DISTINCT CASE WHEN ");
            try builder.write(session_alias);
            try builder.write(".engaged THEN ");
            try builder.write(event_alias);
            try builder.write(".session_id END)");
        },
        .conversions => switch (execution.query.metric.conversion_basis.?) {
            .event => try builder.write("count(*)"),
            .visitor => {
                try builder.write("count(DISTINCT ");
                try builder.write(event_alias);
                try builder.write(".person_key)");
            },
            .session => {
                try builder.write("count(DISTINCT ");
                try builder.write(event_alias);
                try builder.write(".session_id)");
            },
        },
        .page_views, .custom_events, .event_count => {
            try builder.write("count(*)");
        },
        else => unreachable,
    }
}

fn writeFirstPersonDate(builder: *Builder, event_alias: []const u8) !void {
    try builder.write(
        "(SELECT min(h.site_local_date) FROM events h" ++
            " LEFT JOIN identity_links hl ON hl.site_id = h.site_id" ++
            " AND hl.anonymous_id = h.anonymous_id" ++
            " WHERE h.site_id = ",
    );
    try builder.write(event_alias);
    try builder.write(
        ".site_id AND h.kind IN (1, 2) AND h.traffic_class IN (1, 5)" ++
            " AND h.identity_quality = 1 AND (CASE" ++
            " WHEN COALESCE(hl.user_id, h.user_id, '') <> ''" ++
            " THEN 'u:' || COALESCE(hl.user_id, h.user_id)" ++
            " ELSE 'a:' || CAST(h.anonymous_id AS VARCHAR) END) = ",
    );
    try builder.write(event_alias);
    try builder.write(".person_key)");
}

fn writeMetricWhere(
    builder: *Builder,
    execution: analysis.Execution,
    event_alias: []const u8,
    _: []const u8,
) !void {
    const metric = execution.query.metric;
    try builder.write(" WHERE TRUE");
    switch (metric.kind) {
        .page_views => try builder.write(" AND e.kind = 1"),
        .custom_events => try builder.write(" AND e.kind = 2"),
        .conversions, .event_count, .event_visitors => {
            const selector = (try analysis.resolvedSelector(
                metric.selector,
                execution.active_goals,
            )).?;
            try builder.write(" AND ");
            try writeSelectorResolution(builder, selector, event_alias);
        },
        .revenue, .average_value => {
            try builder.write(" AND e.value_amount IS NOT NULL AND e.value_currency <> ''");
            if (try analysis.resolvedSelector(metric.selector, execution.active_goals)) |selector| {
                try builder.write(" AND ");
                try writeSelectorResolution(builder, selector, event_alias);
            }
        },
        else => {},
    }
    if (execution.query.mode == .breakdown and
        execution.query.dimension.?.kind == .event_property)
    {
        try builder.write(" AND ");
        const reference = execution.query.dimension.?.property_ref.?;
        try writePropertyPredicate(
            builder,
            event_alias,
            "properties_json",
            reference,
            .exists,
            &.{},
        );
    }
}

fn isAmount(metric: analysis.MetricKind) bool {
    return metric == .revenue or metric == .average_value;
}

fn writeBucket(
    builder: *Builder,
    interval: analysis.Interval,
    event_alias: []const u8,
) !void {
    switch (interval) {
        .hour => {
            try builder.write("strftime(to_timestamp(");
            try builder.write(event_alias);
            try builder.write(".received_at_utc_micros / 1000000.0) + ");
            try builder.write(event_alias);
            try builder.write(
                ".site_utc_offset_minutes * INTERVAL '1 minute'," ++
                    " '%Y-%m-%dT%H:00')",
            );
        },
        .day => {
            try builder.write("CAST(");
            try builder.write(event_alias);
            try builder.write(".site_local_date AS VARCHAR)");
        },
        .week => {
            try builder.write("CAST(date_trunc('week', ");
            try builder.write(event_alias);
            try builder.write(".site_local_date) AS VARCHAR)");
        },
        .month => {
            try builder.write("strftime(");
            try builder.write(event_alias);
            try builder.write(".site_local_date, '%Y-%m')");
        },
        .auto => unreachable,
    }
}

fn writeDimension(
    builder: *Builder,
    dimension: analysis.Dimension,
    event_alias: []const u8,
    session_alias: []const u8,
) !void {
    switch (dimension.kind) {
        .page => try writeStringLabel(builder, event_alias, "path"),
        .hostname => try writeStringLabel(builder, event_alias, "hostname"),
        .event_name => try writeStringLabel(builder, event_alias, "event_name"),
        .landing_page => try writeStringLabel(builder, session_alias, "landing_page"),
        .exit_page => try writeStringLabel(builder, session_alias, "exit_page"),
        .channel => try writeStringLabel(builder, session_alias, "channel"),
        .referrer => try writeStringLabel(builder, session_alias, "referrer"),
        .utm_source => try writeStringLabel(builder, session_alias, "utm_source"),
        .utm_medium => try writeStringLabel(builder, session_alias, "utm_medium"),
        .utm_campaign => try writeStringLabel(builder, session_alias, "utm_campaign"),
        .utm_term => try writeStringLabel(builder, session_alias, "utm_term"),
        .utm_content => try writeStringLabel(builder, session_alias, "utm_content"),
        .country => try writeStringLabel(builder, session_alias, "country"),
        .language => try writeStringLabel(builder, session_alias, "language"),
        .device => try writeStringLabel(builder, session_alias, "device"),
        .browser => try writeStringLabel(builder, session_alias, "browser"),
        .operating_system => try writeStringLabel(
            builder,
            session_alias,
            "operating_system",
        ),
        .event_property => try writePropertyLabel(
            builder,
            event_alias,
            "properties_json",
            dimension.property_ref.?,
        ),
    }
}

fn writeStringLabel(
    builder: *Builder,
    alias: []const u8,
    column: []const u8,
) !void {
    try builder.write("COALESCE(NULLIF(");
    try builder.write(alias);
    try builder.write(".");
    try builder.write(column);
    try builder.write(", ''), '(not set)')");
}

fn writePropertyLabel(
    builder: *Builder,
    alias: []const u8,
    document: []const u8,
    reference: analysis.PropertyRef,
) !void {
    if (reference.scalar_type == .null) return builder.write("'(null)'");
    if (reference.scalar_type == .missing) return builder.write("'(missing)'");
    const pointer = try property.jsonPointer(builder.allocator, reference.name);
    try builder.write("COALESCE(json_extract_string(");
    try builder.write(alias);
    try builder.write(".");
    try builder.write(document);
    try builder.write(", ");
    try builder.bindText(pointer);
    try builder.write("), '(missing)')");
}

fn writeOrder(builder: *Builder, query: analysis.Query) !void {
    if (query.mode == .trend) return builder.write(" ORDER BY label ASC, currency ASC");
    switch (query.sort) {
        .label_asc => try builder.write(" ORDER BY label ASC, currency ASC"),
        .label_desc => try builder.write(" ORDER BY label DESC, currency ASC"),
        .value_desc => try builder.write(
            " ORDER BY CASE measure_kind WHEN 3 THEN" ++
                " TRY_CAST(amount AS DECIMAL(18,6))" ++
                " WHEN 2 THEN CASE WHEN denominator = 0 THEN 0" ++
                " ELSE numerator::DOUBLE / denominator END" ++
                " ELSE numerator END DESC, label ASC, currency ASC",
        ),
        .value_asc => try builder.write(
            " ORDER BY CASE measure_kind WHEN 3 THEN" ++
                " TRY_CAST(amount AS DECIMAL(18,6))" ++
                " WHEN 2 THEN CASE WHEN denominator = 0 THEN 0" ++
                " ELSE numerator::DOUBLE / denominator END" ++
                " ELSE numerator END ASC, label ASC, currency ASC",
        ),
    }
}

fn writeClause(
    builder: *Builder,
    clause: analysis.Clause,
    event_alias: []const u8,
    session_alias: []const u8,
) !void {
    switch (clause.scope) {
        .event => try writeFieldPredicate(builder, clause, event_alias),
        .session => if (hasSessionFact(clause.field.kind)) {
            try writeFieldPredicate(builder, clause, session_alias);
        } else {
            try builder.write("EXISTS (SELECT 1 FROM base sf WHERE sf.session_id = ");
            try builder.write(event_alias);
            try builder.write(".session_id AND ");
            try writeFieldPredicate(builder, clause, "sf");
            try builder.write(")");
        },
        .person => {
            if (clause.field.kind == .identity_state) {
                return writeFieldPredicate(builder, clause, event_alias);
            }
            try builder.write(event_alias);
            try builder.write(".person_key IS NOT NULL AND EXISTS (SELECT 1 FROM ");
            try builder.write(if (clause.field.kind == .user_trait)
                "person_traits"
            else
                "base");
            try builder.write(" pf WHERE pf.person_key = ");
            try builder.write(event_alias);
            try builder.write(".person_key AND ");
            try writeFieldPredicate(builder, clause, "pf");
            try builder.write(")");
        },
    }
}

fn hasSessionFact(field: analysis.FieldKind) bool {
    return switch (field) {
        .landing_page,
        .exit_page,
        .channel,
        .referrer,
        .utm_source,
        .utm_medium,
        .utm_campaign,
        .utm_term,
        .utm_content,
        .country,
        .language,
        .device,
        .browser,
        .operating_system,
        .session_converted,
        .session_duration_ms,
        .session_engagement_ms,
        => true,
        else => false,
    };
}

fn writeSelector(
    builder: *Builder,
    selector: analysis.EventSelector,
    event_alias: []const u8,
) !void {
    try builder.write("(");
    switch (selector.kind) {
        .exact_page => {
            try builder.write(event_alias);
            try builder.write(".kind = 1 AND ");
            try builder.write(event_alias);
            try builder.write(".path = ");
            try builder.bindText(selector.value);
        },
        .page_prefix => {
            try builder.write(event_alias);
            try builder.write(".kind = 1 AND starts_with(");
            try builder.write(event_alias);
            try builder.write(".path, ");
            try builder.bindText(selector.value);
            try builder.write(")");
        },
        .exact_event => {
            try builder.write(event_alias);
            try builder.write(".kind = 2 AND ");
            try builder.write(event_alias);
            try builder.write(".event_name = ");
            try builder.bindText(selector.value);
        },
        .saved_goal => unreachable,
    }
    for (selector.predicates) |predicate| {
        try builder.write(" AND ");
        try writePropertyPredicate(
            builder,
            event_alias,
            "properties_json",
            predicate.property_ref,
            predicate.operator,
            predicate.values,
        );
    }
    try builder.write(")");
}

fn writeSelectorResolution(
    builder: *Builder,
    resolution: analysis.SelectorResolution,
    event_alias: []const u8,
) !void {
    try builder.write("(");
    try writeSelector(builder, resolution.selector, event_alias);
    for (resolution.additional_predicates) |predicate| {
        try builder.write(" AND ");
        try writePropertyPredicate(
            builder,
            event_alias,
            "properties_json",
            predicate.property_ref,
            predicate.operator,
            predicate.values,
        );
    }
    try builder.write(")");
}

fn writeFieldPredicate(
    builder: *Builder,
    clause: analysis.Clause,
    alias: []const u8,
) !void {
    if (clause.field.property_ref) |reference| {
        return writePropertyPredicate(
            builder,
            alias,
            if (clause.field.kind == .user_trait)
                "user_traits_json"
            else
                "properties_json",
            reference,
            clause.operator,
            clause.values,
        );
    }
    try writeScalarPredicate(
        builder,
        clause.field.kind,
        alias,
        clause.scalar_type,
        clause.operator,
        clause.values,
    );
}

fn writeScalarPredicate(
    builder: *Builder,
    field: analysis.FieldKind,
    alias: []const u8,
    scalar_type: analysis.ScalarType,
    operator: analysis.Operator,
    values: []const []const u8,
) !void {
    switch (operator) {
        .is, .is_not => {
            try writeScalarExpression(builder, field, alias);
            try builder.write(if (operator == .is) " IN (" else " NOT IN (");
            for (values, 0..) |value, index| {
                if (index != 0) try builder.write(", ");
                try builder.bindText(value);
            }
            try builder.write(")");
        },
        .contains, .not_contains, .starts_with => {
            try builder.write("(");
            for (values, 0..) |value, index| {
                if (index != 0) try builder.write(
                    if (operator == .not_contains) " AND " else " OR ",
                );
                if (operator == .not_contains) try builder.write("NOT ");
                try builder.write(if (operator == .starts_with) "starts_with(" else "contains(");
                try writeScalarExpression(builder, field, alias);
                try builder.write(", ");
                try builder.bindText(value);
                try builder.write(")");
            }
            try builder.write(")");
        },
        .gt, .gte, .lt, .lte => {
            try writeScalarExpression(builder, field, alias);
            try builder.write(switch (operator) {
                .gt => " > CAST(",
                .gte => " >= CAST(",
                .lt => " < CAST(",
                .lte => " <= CAST(",
                else => unreachable,
            });
            try builder.bindText(values[0]);
            try builder.write(" AS BIGINT)");
        },
        .is_true, .is_false => {
            try writeScalarExpression(builder, field, alias);
            try builder.write(if (operator == .is_true) " = TRUE" else " = FALSE");
        },
        .exists, .absent => {
            if (scalar_type == .string) try builder.write("NULLIF(");
            try writeScalarExpression(builder, field, alias);
            if (scalar_type == .string) try builder.write(", '')");
            try builder.write(if (operator == .exists)
                " IS NOT NULL"
            else
                " IS NULL");
        },
    }
}

fn writeScalarExpression(
    builder: *Builder,
    field: analysis.FieldKind,
    alias: []const u8,
) !void {
    if (field == .identity_state) {
        try builder.write("CASE WHEN starts_with(");
        try builder.write(alias);
        try builder.write(".person_key, 'u:') THEN 'identified' WHEN ");
        try builder.write(alias);
        try builder.write(".identity_quality = 1 THEN 'anonymous' WHEN ");
        try builder.write(alias);
        try builder.write(".identity_quality = 2 THEN 'ephemeral' ELSE 'legacy' END");
        return;
    }
    const column = switch (field) {
        .page => "path",
        .page_title => "page_title",
        .hostname => "hostname",
        .landing_page => "landing_page",
        .exit_page => "exit_page",
        .channel => "channel",
        .referrer => "referrer",
        .utm_source => "utm_source",
        .utm_medium => "utm_medium",
        .utm_campaign => "utm_campaign",
        .utm_term => "utm_term",
        .utm_content => "utm_content",
        .country => "country",
        .language => "language",
        .device => "device",
        .browser => "browser",
        .operating_system => "operating_system",
        .event_name => "event_name",
        .session_converted => "converted",
        .session_duration_ms => "duration_ms",
        .session_engagement_ms => "engagement_ms",
        .event_property, .user_trait, .identity_state => unreachable,
    };
    try builder.write(alias);
    try builder.write(".");
    try builder.write(column);
}

fn writePropertyPredicate(
    builder: *Builder,
    alias: []const u8,
    document: []const u8,
    reference: analysis.PropertyRef,
    operator: analysis.Operator,
    values: []const []const u8,
) !void {
    const pointer = try property.jsonPointer(builder.allocator, reference.name);
    if (operator == .absent or reference.scalar_type == .missing) {
        if (reference.scalar_type == .missing and operator == .is_not) {
            try writeJsonType(builder, alias, document, pointer);
            return builder.write(" IS NOT NULL");
        }
        try writeJsonType(builder, alias, document, pointer);
        return builder.write(" IS NULL");
    }
    if (operator == .exists) {
        try writeJsonTypeGuard(builder, alias, document, pointer, reference.scalar_type);
        return;
    }
    if (reference.scalar_type == .null) {
        try writeJsonType(builder, alias, document, pointer);
        return builder.write(if (operator == .is) " = 'NULL'" else " <> 'NULL'");
    }

    try builder.write("(");
    try writeJsonTypeGuard(builder, alias, document, pointer, reference.scalar_type);
    try builder.write(" AND ");
    switch (operator) {
        .is, .is_not => {
            try writeJsonValue(builder, alias, document, pointer, reference.scalar_type);
            try builder.write(if (operator == .is) " IN (" else " NOT IN (");
            for (values, 0..) |value, index| {
                if (index != 0) try builder.write(", ");
                try writeTypedBinding(builder, reference.scalar_type, value);
            }
            try builder.write(")");
        },
        .contains, .not_contains, .starts_with => {
            try builder.write("(");
            for (values, 0..) |value, index| {
                if (index != 0) try builder.write(
                    if (operator == .not_contains) " AND " else " OR ",
                );
                if (operator == .not_contains) try builder.write("NOT ");
                try builder.write(if (operator == .starts_with) "starts_with(" else "contains(");
                try writeJsonValue(builder, alias, document, pointer, .string);
                try builder.write(", ");
                try builder.bindText(value);
                try builder.write(")");
            }
            try builder.write(")");
        },
        .gt, .gte, .lt, .lte => {
            try writeJsonValue(builder, alias, document, pointer, reference.scalar_type);
            try builder.write(switch (operator) {
                .gt => " > ",
                .gte => " >= ",
                .lt => " < ",
                .lte => " <= ",
                else => unreachable,
            });
            try writeTypedBinding(builder, reference.scalar_type, values[0]);
        },
        .is_true, .is_false => {
            try writeJsonValue(builder, alias, document, pointer, .boolean);
            try builder.write(if (operator == .is_true) " = TRUE" else " = FALSE");
        },
        .exists, .absent => unreachable,
    }
    try builder.write(")");
}

fn writeJsonTypeGuard(
    builder: *Builder,
    alias: []const u8,
    document: []const u8,
    pointer: []const u8,
    scalar_type: analysis.ScalarType,
) !void {
    try writeJsonType(builder, alias, document, pointer);
    try builder.write(switch (scalar_type) {
        .string => " = 'VARCHAR'",
        .integer => " IN ('BIGINT', 'UBIGINT')",
        .decimal => " IN ('DOUBLE', 'DECIMAL')",
        .boolean => " = 'BOOLEAN'",
        .null => " = 'NULL'",
        .missing => " IS NULL",
    });
}

fn writeJsonType(
    builder: *Builder,
    alias: []const u8,
    document: []const u8,
    pointer: []const u8,
) !void {
    try builder.write("json_type(");
    try builder.write(alias);
    try builder.write(".");
    try builder.write(document);
    try builder.write(", ");
    try builder.bindText(pointer);
    try builder.write(")");
}

fn writeJsonValue(
    builder: *Builder,
    alias: []const u8,
    document: []const u8,
    pointer: []const u8,
    scalar_type: analysis.ScalarType,
) !void {
    switch (scalar_type) {
        .integer => try builder.write("TRY_CAST("),
        .decimal => try builder.write("TRY_CAST("),
        .boolean => try builder.write("CAST("),
        else => {},
    }
    try builder.write("json_extract_string(");
    try builder.write(alias);
    try builder.write(".");
    try builder.write(document);
    try builder.write(", ");
    try builder.bindText(pointer);
    try builder.write(")");
    switch (scalar_type) {
        .integer => try builder.write(" AS BIGINT)"),
        .decimal => try builder.write(" AS DECIMAL(18,6))"),
        .boolean => try builder.write(" AS BOOLEAN)"),
        else => {},
    }
}

fn writeTypedBinding(
    builder: *Builder,
    scalar_type: analysis.ScalarType,
    value: []const u8,
) !void {
    switch (scalar_type) {
        .integer => {
            try builder.write("CAST(");
            try builder.bindText(value);
            try builder.write(" AS BIGINT)");
        },
        .decimal => {
            try builder.write("CAST(");
            try builder.bindText(value);
            try builder.write(" AS DECIMAL(18,6))");
        },
        else => try builder.bindText(value),
    }
}

fn planContainsText(plan: StatementPlan, value: []const u8) bool {
    for (plan.bindings) |binding| switch (binding) {
        .text => |candidate| if (std.mem.eql(u8, candidate, value)) return true,
        .integer => {},
    };
    return false;
}

test "finite compiler covers every metric dimension and current analysis preset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const adversarial = "/x'); DROP TABLE events; -- &=~";
    const selector = analysis.EventSelector{
        .kind = .exact_page,
        .value = adversarial,
    };
    const site = "00000000-0000-4000-8000-000000000024";
    const range = analysis.LocalDateRange{
        .start = "2026-01-01",
        .end = "2026-01-31",
    };

    inline for (@typeInfo(analysis.MetricKind).@"enum".field_values) |raw| {
        const kind: analysis.MetricKind = @fromBackingInt(@intCast(raw));
        const query = analysis.Query{
            .site_id = site,
            .range = range,
            .mode = .trend,
            .metric = .{
                .kind = kind,
                .selector = if (kind.requiresSelector()) selector else null,
                .conversion_basis = if (kind == .conversion_rate)
                    .visitor
                else if (kind == .conversions)
                    .event
                else
                    null,
            },
            .interval = .day,
        };
        const compiled = try compile(allocator, .{ .query = query });
        try std.testing.expect(std.mem.find(
            u8,
            compiled.primary_rows.sql,
            adversarial,
        ) == null);
        if (kind.requiresSelector()) {
            try std.testing.expect(planContainsText(compiled.primary_rows, adversarial));
        }
    }

    inline for (@typeInfo(analysis.DimensionKind).@"enum".field_values) |raw| {
        const kind: analysis.DimensionKind = @fromBackingInt(@intCast(raw));
        const query = analysis.Query{
            .site_id = site,
            .range = range,
            .mode = .breakdown,
            .metric = .{ .kind = if (kind == .event_property)
                .custom_events
            else
                .sessions },
            .dimension = .{
                .kind = kind,
                .property_ref = if (kind == .event_property)
                    .{ .name = "plan", .scalar_type = .string }
                else
                    null,
            },
        };
        _ = try compile(allocator, .{ .query = query });
    }

    inline for (@typeInfo(analysis.Preset).@"enum".field_values) |raw| {
        const preset: analysis.Preset = @fromBackingInt(@intCast(raw));
        _ = try compile(allocator, .{
            .query = analysis.presetQuery(preset, site, range),
        });
    }
}

test "compiler binds property pointers and filter values without SQL interpolation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const adversarial = "x'); SELECT * FROM identity_links; --";
    const clauses = [_]analysis.Clause{.{
        .scope = .event,
        .field = .{
            .kind = .event_property,
            .property_ref = .{ .name = "plan", .scalar_type = .string },
        },
        .operator = .contains,
        .scalar_type = .string,
        .values = &.{adversarial},
    }};
    const query = analysis.Query{
        .site_id = "00000000-0000-4000-8000-000000000024",
        .range = .{ .start = "2026-01-01", .end = "2026-01-02" },
        .mode = .breakdown,
        .metric = .{ .kind = .page_views },
        .dimension = .{ .kind = .page },
        .filters = .{ .clauses = &clauses },
    };
    const compiled = try compile(arena.allocator(), .{ .query = query });
    try std.testing.expect(std.mem.find(
        u8,
        compiled.primary_rows.sql,
        adversarial,
    ) == null);
    try std.testing.expect(planContainsText(compiled.primary_rows, adversarial));
    try std.testing.expect(planContainsText(compiled.primary_rows, "/plan"));
}

test "declared maximum filters selectors and active goals still compile bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var values: [analysis.maximum_values][]const u8 = undefined;
    for (&values, 0..) |*value, index| {
        value.* = try std.fmt.allocPrint(allocator, "value-{d}", .{index});
    }
    var predicates: [analysis.maximum_selector_predicates]analysis.PropertyPredicate = undefined;
    for (&predicates, 0..) |*predicate, index| {
        predicate.* = .{
            .property_ref = .{
                .name = try std.fmt.allocPrint(allocator, "property-{d}", .{index}),
                .scalar_type = .string,
            },
            .operator = .is,
            .values = &values,
        };
    }
    var goals: [analysis.maximum_active_goals]analysis.ResolvedGoal = undefined;
    for (&goals, 0..) |*goal, index| {
        goal.* = .{
            .id = try std.fmt.allocPrint(
                allocator,
                "00000000-0000-4000-8000-{d:0>12}",
                .{index + 1},
            ),
            .selector = .{
                .kind = .exact_event,
                .value = "purchase",
                .predicates = &predicates,
            },
        };
    }
    var clauses: [analysis.maximum_clauses]analysis.Clause = undefined;
    for (&clauses) |*clause| {
        clause.* = .{
            .scope = .session,
            .field = .{ .kind = .device },
            .operator = .is,
            .scalar_type = .string,
            .values = &values,
        };
    }
    const compiled = try compile(allocator, .{
        .query = .{
            .site_id = "00000000-0000-4000-8000-000000000024",
            .range = .{ .start = "2026-01-01", .end = "2026-01-02" },
            .mode = .trend,
            .metric = .{ .kind = .engaged_sessions },
            .filters = .{ .clauses = &clauses },
            .interval = .day,
        },
        .active_goals = &goals,
    });
    try std.testing.expect(compiled.primary_rows.sql.len <= maximum_sql_bytes);
    try std.testing.expect(compiled.primary_rows.bindings.len <= maximum_bindings);
}

test "metric v2 executes against a real on-disk schema four store" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/events.duckdb",
        .{temporary.sub_path},
    );
    defer allocator.free(path);
    var event_store = try events.Store.open(allocator, path);
    defer event_store.deinit();
    try event_store.migrate();
    try seedSemanticFixture(&event_store.database);
    var query_arena = std.heap.ArenaAllocator.init(allocator);
    defer query_arena.deinit();
    const query_allocator = query_arena.allocator();

    const site = "00000000-0000-4000-8000-000000000024";
    const range = analysis.LocalDateRange{
        .start = "2026-01-02",
        .end = "2026-01-03",
    };
    const visitors = try execute(query_allocator, &event_store, .{
        .query = .{
            .site_id = site,
            .range = range,
            .mode = .trend,
            .metric = .{ .kind = .visitors },
            .interval = .day,
        },
    });
    try std.testing.expectEqual(@as(i64, 4), visitors.trend.total[0].count);
    try std.testing.expectEqual(@as(i64, 2), visitors.trend.completeness.persistent_people);
    try std.testing.expectEqual(@as(i64, 1), visitors.trend.completeness.ephemeral_people);
    try std.testing.expectEqual(@as(i64, 1), visitors.trend.completeness.legacy_people);

    const engaged = try execute(query_allocator, &event_store, .{
        .query = .{
            .site_id = site,
            .range = range,
            .mode = .trend,
            .metric = .{ .kind = .engaged_sessions },
            .interval = .day,
        },
    });
    try std.testing.expectEqual(@as(i64, 2), engaged.trend.total[0].count);

    const returning = try execute(query_allocator, &event_store, .{
        .query = .{
            .site_id = site,
            .range = range,
            .mode = .trend,
            .metric = .{ .kind = .returning_visitors },
            .interval = .day,
        },
    });
    try std.testing.expectEqual(@as(i64, 1), returning.trend.total[0].count);

    const plan_values = [_][]const u8{"pro"};
    const plan_filter = [_]analysis.Clause{.{
        .scope = .event,
        .field = .{
            .kind = .event_property,
            .property_ref = .{ .name = "plan", .scalar_type = .string },
        },
        .operator = .is,
        .scalar_type = .string,
        .values = &plan_values,
    }};
    const pages = try execute(query_allocator, &event_store, .{
        .query = .{
            .site_id = site,
            .range = range,
            .mode = .breakdown,
            .metric = .{ .kind = .page_views },
            .dimension = .{ .kind = .page },
            .filters = .{ .clauses = &plan_filter },
            .limit = 1,
        },
    });
    try std.testing.expectEqual(@as(i64, 2), pages.breakdown.cardinality);
    try std.testing.expectEqual(@as(?u32, 2), pages.breakdown.next_page);

    const traits = [_][]const u8{"enterprise"};
    const trait_filter = [_]analysis.Clause{.{
        .scope = .person,
        .field = .{
            .kind = .user_trait,
            .property_ref = .{ .name = "plan", .scalar_type = .string },
        },
        .operator = .is,
        .scalar_type = .string,
        .values = &traits,
    }};
    const identified = try execute(query_allocator, &event_store, .{
        .query = .{
            .site_id = site,
            .range = range,
            .mode = .trend,
            .metric = .{ .kind = .visitors },
            .filters = .{ .clauses = &trait_filter },
            .interval = .day,
        },
    });
    try std.testing.expectEqual(@as(i64, 1), identified.trend.total[0].count);

    const revenue = try execute(query_allocator, &event_store, .{
        .query = .{
            .site_id = site,
            .range = range,
            .mode = .trend,
            .metric = .{ .kind = .revenue },
            .interval = .day,
        },
    });
    try std.testing.expectEqual(@as(usize, 2), revenue.trend.total.len);
    try std.testing.expectEqualStrings("EUR", revenue.trend.total[0].amount.currency);
    try std.testing.expectEqualStrings("12.500000", revenue.trend.total[0].amount.decimal);
    try std.testing.expectEqualStrings("USD", revenue.trend.total[1].amount.currency);
    try std.testing.expectEqualStrings("7.500000", revenue.trend.total[1].amount.decimal);

    inline for (@typeInfo(analysis.MetricKind).@"enum".field_values) |raw| {
        const kind: analysis.MetricKind = @fromBackingInt(@intCast(raw));
        _ = try execute(query_allocator, &event_store, .{
            .query = .{
                .site_id = site,
                .range = range,
                .mode = .trend,
                .metric = .{
                    .kind = kind,
                    .selector = if (kind.requiresSelector())
                        .{ .kind = .exact_event, .value = "purchase" }
                    else
                        null,
                    .conversion_basis = if (kind == .conversion_rate)
                        .visitor
                    else if (kind == .conversions)
                        .event
                    else
                        null,
                },
                .interval = .day,
            },
        });
    }
    inline for (@typeInfo(analysis.DimensionKind).@"enum".field_values) |raw| {
        const kind: analysis.DimensionKind = @fromBackingInt(@intCast(raw));
        _ = try execute(query_allocator, &event_store, .{
            .query = .{
                .site_id = site,
                .range = range,
                .mode = .breakdown,
                .metric = .{ .kind = .page_views },
                .dimension = .{
                    .kind = kind,
                    .property_ref = if (kind == .event_property)
                        .{ .name = "plan", .scalar_type = .string }
                    else
                        null,
                },
            },
        });
    }
}

pub fn seedSemanticFixture(database: *duckdb.Database) !void {
    try database.exec(
        \\INSERT INTO identity_links VALUES (
        \\  '00000000-0000-4000-8000-000000000024',
        \\  CAST('00000000-0000-4000-8000-0000000000a1' AS UUID),
        \\  'user-a', 1767225600000000,
        \\  CAST('00000000-0000-4000-8000-0000000000f1' AS UUID)
        \\);
        \\INSERT INTO events
        \\SELECT 7, 2, 2, CAST(event_id AS UUID),
        \\  '00000000-0000-4000-8000-000000000024',
        \\  occurred + receipt_delay_micros, occurred,
        \\  CAST(local_date AS DATE), CAST(local_date AS DATE), offset_minutes,
        \\  kind, event_name, path, title, hostname, CAST(anonymous_id AS UUID),
        \\  identity_quality, user_id, CAST(session_id AS UUID), sequence,
        \\  sequence = 0, referrer, country, language, browser, os,
        \\  CASE WHEN device = 'bot' THEN 'unknown' ELSE device END,
        \\  utm_source, utm_medium, utm_campaign, '', '', properties, traits,
        \\  CASE WHEN amount = '' THEN CAST(NULL AS DECIMAL(18,6))
        \\       ELSE CAST(amount AS DECIMAL(18,6)) END,
        \\  currency, engagement_ms, 0, CAST(event_id AS BLOB), sequence = 0,
        \\  repeat('a', 64), CASE WHEN device = 'bot' THEN 2 ELSE 1 END,
        \\  0, CASE WHEN device = 'bot' THEN 'legacy-device-bot' ELSE '' END,
        \\  0, FALSE, 0, FALSE, FALSE, 0, 0, 0, FALSE,
        \\  from_hex('00000000000000000000000000000000')
        \\FROM (VALUES
        \\ ('00000000-0000-4000-8000-000000000101',1767139200000000,'2025-12-31',0,1,'pageview','/old','Old','example.test','00000000-0000-4000-8000-0000000000a1',1,'user-a','00000000-0000-4000-8000-0000000000b0',0,'','DE','en','Chrome','Linux','desktop','','','','{}','{}','5.000000','GBP',0,0),
        \\ ('00000000-0000-4000-8000-000000000102',1767312000000000,'2026-01-02',60,1,'pageview','/landing','Landing','example.test','00000000-0000-4000-8000-0000000000a1',1,'user-a','00000000-0000-4000-8000-0000000000b1',0,'search.example','DE','en','Chrome','Linux','desktop','google','cpc','winter','{"plan":"pro"}','{}','','',0,0),
        \\ ('00000000-0000-4000-8000-000000000103',1767398400000000,'2026-01-03',60,1,'pageview','/pricing','Pricing','example.test','00000000-0000-4000-8000-0000000000a1',1,'user-a','00000000-0000-4000-8000-0000000000b1',1,'','DE','en','Chrome','Linux','desktop','','','','{"plan":"pro"}','{}','','',0,0),
        \\ ('00000000-0000-4000-8000-000000000104',1767398401000000,'2026-01-03',60,2,'purchase','/pricing','Pricing','example.test','00000000-0000-4000-8000-0000000000a1',1,'user-a','00000000-0000-4000-8000-0000000000b1',2,'','DE','en','Chrome','Linux','desktop','','','','{"plan":"pro","amount":14.25}','{}','12.500000','EUR',0,0),
        \\ ('00000000-0000-4000-8000-000000000105',1767398402000000,'2026-01-03',60,2,'purchase','/pricing','Pricing','example.test','00000000-0000-4000-8000-0000000000a1',1,'user-a','00000000-0000-4000-8000-0000000000b1',3,'','DE','en','Chrome','Linux','desktop','','','','{"plan":"pro","amount":7.5}','{}','7.500000','USD',0,0),
        \\ ('00000000-0000-4000-8000-000000000106',1767398403000000,'2026-01-03',60,4,'identify','/pricing','Pricing','example.test','00000000-0000-4000-8000-0000000000a1',1,'user-a','00000000-0000-4000-8000-0000000000b1',4,'','DE','en','Chrome','Linux','desktop','','','','{}','{"plan":"enterprise"}','','',0,0),
        \\ ('00000000-0000-4000-8000-000000000112',1767394809000000,'2026-01-03',60,2,'delayed_event','/pricing','Pricing','example.test','00000000-0000-4000-8000-0000000000a1',1,'user-a','00000000-0000-4000-8000-0000000000b1',5,'','DE','en','Chrome','Linux','desktop','','','','{}','{}','','',0,3600000000),
        \\ ('00000000-0000-4000-8000-000000000107',1767398404000000,'2026-01-03',60,1,'pageview','/','Home','example.test','00000000-0000-4000-8000-0000000000a2',1,'','00000000-0000-4000-8000-0000000000b2',0,'','US','en','Firefox','Windows','mobile','','','','{"plan":"free"}','{}','','',0,0),
        \\ ('00000000-0000-4000-8000-000000000108',1767398405000000,'2026-01-03',60,3,'engagement','/','Home','example.test','00000000-0000-4000-8000-0000000000a2',1,'','00000000-0000-4000-8000-0000000000b2',1,'','US','en','Firefox','Windows','mobile','','','','{}','{}','','',10000,0),
        \\ ('00000000-0000-4000-8000-000000000109',1767398406000000,'2026-01-03',60,1,'pageview','/ephemeral','Ephemeral','example.test','00000000-0000-4000-8000-0000000000a3',2,'','00000000-0000-4000-8000-0000000000b3',0,'','FR','fr','Safari','macOS','tablet','','','','{}','{}','','',0,0),
        \\ ('00000000-0000-4000-8000-000000000110',1767398407000000,'2026-01-03',60,1,'pageview','/legacy','Legacy','example.test','00000000-0000-4000-8000-0000000000a4',3,'','00000000-0000-4000-8000-0000000000b4',0,'','ZZ','','Unknown','Unknown','unknown','','','','{}','{}','','',0,0),
        \\ ('00000000-0000-4000-8000-000000000111',1767398408000000,'2026-01-03',60,1,'pageview','/bot','Bot','example.test','00000000-0000-4000-8000-0000000000a5',1,'','00000000-0000-4000-8000-0000000000b5',0,'','ZZ','','Bot','Bot','bot','','','','{}','{}','','',0,0)
        \\) fixture(event_id,occurred,local_date,offset_minutes,kind,event_name,
        \\ path,title,hostname,anonymous_id,identity_quality,user_id,session_id,
        \\ sequence,referrer,country,language,browser,os,device,utm_source,
        \\ utm_medium,utm_campaign,properties,traits,amount,currency,engagement_ms,
        \\ receipt_delay_micros);
    );
}
