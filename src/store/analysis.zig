const std = @import("std");
const analysis = @import("../analysis.zig");
const domain = @import("../domain.zig");
const funnel = @import("../funnel.zig");
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
    var budget = deadline.Budget.init(execution.timeout_ms);
    return executeWithBudget(allocator, event_store, execution, &budget);
}

fn executeWithBudget(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    execution: analysis.Execution,
    budget: *deadline.Budget,
) !analysis.Result {
    const compiled = try compile(allocator, execution);
    const completeness = try executeCoverage(
        allocator,
        &event_store.database,
        compiled.coverage,
        budget,
    );
    const comparison_completeness = if (compiled.comparison_coverage) |plan|
        try executeCoverage(
            allocator,
            &event_store.database,
            plan,
            budget,
        )
    else
        null;
    const primary = try executeRows(
        allocator,
        &event_store.database,
        compiled.primary_rows,
        budget,
    );
    const empty_page_cardinality: ?i64 = if (execution.query.mode == .breakdown and
        execution.query.page > 1 and primary.len == 0)
        try executeCardinality(
            &event_store.database,
            try compileBreakdownCardinality(allocator, execution),
            budget,
        )
    else
        null;
    const comparison = if (compiled.comparison_rows) |plan|
        try executeRows(
            allocator,
            &event_store.database,
            plan,
            budget,
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
                    budget,
                )
            else
                null,
            .comparison_completeness = comparison_completeness,
            .total = try executeTotals(
                allocator,
                &event_store.database,
                compiled.primary_total.?,
                budget,
            ),
            .interval = compiled.interval,
            .completeness = completeness,
        } },
        .breakdown => .{ .breakdown = try breakdownResult(
            allocator,
            execution.query,
            primary,
            completeness,
            empty_page_cardinality,
        ) },
    };
}

fn compileFilteredPageBreakdown(
    allocator: std.mem.Allocator,
    execution: analysis.Execution,
) !StatementPlan {
    const selection = analysis.OverviewTrendSelection{
        .metric = .page_views,
        .interval = .day,
        .current_buckets = &.{},
        .comparison_buckets = &.{},
    };
    const overview_execution = analysis.OverviewExecution{
        .site_id = execution.query.site_id,
        .range = execution.query.range,
        .active_goals = execution.active_goals,
        .filters = execution.query.filters,
        .strict_traffic_mode = execution.strict_traffic_mode,
        .daily_event_ceiling = 1,
        .trend = selection,
    };
    var builder = Builder.init(allocator);
    try writeFilteredOverviewCommon(
        &builder,
        overview_execution,
        selection,
        false,
    );
    try builder.write(
        ", metric_rows AS (SELECT path AS label," ++
            " count(*) FILTER (WHERE kind = 1)::BIGINT AS page_views" ++
            " FROM qualified GROUP BY path" ++
            " HAVING count(*) FILTER (WHERE kind = 1) > 0)," ++
            " filtered_rows AS (SELECT *" ++
            " FROM metric_rows",
    );
    if (execution.query.search.len != 0) {
        try builder.write(" WHERE contains(lower(label), lower(");
        try builder.bindText(execution.query.search);
        try builder.write("))");
    }
    try builder.write(
        "), ranked_rows AS (SELECT label, page_views," ++
            " count(*) OVER ()::BIGINT AS cardinality FROM filtered_rows",
    );
    switch (execution.query.sort) {
        .value_desc => try builder.write(
            " ORDER BY page_views DESC, label ASC",
        ),
        .value_asc => try builder.write(
            " ORDER BY page_views ASC, label ASC",
        ),
        .label_asc => try builder.write(" ORDER BY label ASC"),
        .label_desc => try builder.write(" ORDER BY label DESC"),
    }
    try builder.write(" LIMIT ");
    try builder.bindInteger(@as(i64, execution.query.limit) + 1);
    try builder.write(" OFFSET ");
    try builder.bindInteger(try execution.query.offset());
    try builder.write(
        "), summary_values AS (SELECT" ++
            " count(DISTINCT person_key)::BIGINT AS visitors," ++
            " count(DISTINCT CASE WHEN identity_quality = 1" ++
            " THEN person_key END)::BIGINT AS persistent," ++
            " count(DISTINCT CASE WHEN identity_quality = 2" ++
            " THEN person_key END)::BIGINT AS ephemeral," ++
            " count(DISTINCT CASE WHEN identity_quality = 3" ++
            " THEN person_key END)::BIGINT AS legacy FROM qualified)," ++
            " persistent_since AS (SELECT CAST(min(site_local_date) AS VARCHAR)" ++
            " AS local_date FROM events WHERE site_id = ",
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
    try builder.write(
        ") SELECT 'row' AS row_kind, r.label, r.page_views," ++
            " r.cardinality, s.persistent, s.ephemeral, s.legacy, p.local_date" ++
            " FROM ranked_rows r CROSS JOIN summary_values s" ++
            " CROSS JOIN persistent_since p" ++
            " UNION ALL SELECT 'summary', '', s.visitors," ++
            " (SELECT count(*)::BIGINT FROM filtered_rows)," ++
            " s.persistent, s.ephemeral, s.legacy, p.local_date" ++
            " FROM summary_values s CROSS JOIN persistent_since p",
    );
    return builder.finish();
}

fn executeFilteredPageBreakdown(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    execution: analysis.Execution,
    budget: *deadline.Budget,
) !analysis.Result {
    var result = try executePlan(
        &event_store.database,
        try compileFilteredPageBreakdown(allocator, execution),
        budget,
    );
    defer result.deinit();
    if (result.columnCount() != 8 or
        result.rowCount() > @as(usize, execution.query.limit) + 2)
    {
        return error.InvalidAnalysisResult;
    }
    var rows: std.ArrayList(analysis.BreakdownRow) = .empty;
    defer rows.deinit(allocator);
    var cardinality: ?i64 = null;
    var completeness: ?analysis.Completeness = null;
    for (0..result.rowCount()) |row| {
        const row_kind = try result.text(allocator, 0, row);
        if (std.mem.eql(u8, row_kind, "row")) {
            const value = result.int64(2, row);
            const row_cardinality = result.int64(3, row);
            if (value < 0 or row_cardinality < 0 or
                (cardinality != null and cardinality.? != row_cardinality))
            {
                return error.InvalidAnalysisResult;
            }
            cardinality = row_cardinality;
            try rows.append(allocator, .{
                .label = .{ .value = try result.text(allocator, 1, row) },
                .measure = .{ .count = value },
            });
            continue;
        }
        if (!std.mem.eql(u8, row_kind, "summary") or completeness != null) {
            return error.InvalidAnalysisResult;
        }
        const total = result.int64(2, row);
        const persistent = result.int64(4, row);
        const ephemeral = result.int64(5, row);
        const legacy = result.int64(6, row);
        const summary_cardinality = result.int64(3, row);
        if (total < 0 or summary_cardinality < 0 or
            persistent < 0 or ephemeral < 0 or legacy < 0 or
            persistent + ephemeral + legacy != total)
        {
            return error.InvalidAnalysisResult;
        }
        if (cardinality != null and cardinality.? != summary_cardinality) {
            return error.InvalidAnalysisResult;
        }
        cardinality = summary_cardinality;
        const persistent_scaled = std.math.mul(i64, persistent, 10_000) catch
            return error.InvalidAnalysisResult;
        completeness = .{
            .total_people = total,
            .persistent_people = persistent,
            .ephemeral_people = ephemeral,
            .legacy_people = legacy,
            .persistent_basis_points = if (total == 0)
                0
            else
                @intCast(@divTrunc(persistent_scaled, total)),
            .persistent_since_local_date = if (result.isNull(7, row))
                null
            else
                try result.text(allocator, 7, row),
        };
    }
    if (completeness == null) return error.InvalidAnalysisResult;
    const visible = @min(rows.items.len, @as(usize, execution.query.limit));
    return .{ .breakdown = .{
        .rows = try allocator.dupe(analysis.BreakdownRow, rows.items[0..visible]),
        .next_page = if (rows.items.len > visible) execution.query.page + 1 else null,
        .cardinality = cardinality orelse 0,
        .completeness = completeness.?,
    } };
}

pub fn executeBreakdownPage(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    execution: analysis.Execution,
) !analysis.BreakdownPageResult {
    try execution.validate();
    if (execution.query.mode != .breakdown) return error.InvalidBreakdownPageQuery;
    const catalog_key = try propertyCatalogCacheKey(allocator, execution);
    var budget = deadline.Budget.init(execution.timeout_ms);
    const result = if (execution.query.filters.clauses.len != 0 and
        execution.query.metric.kind == .page_views and
        execution.query.dimension.?.kind == .page)
        try executeFilteredPageBreakdown(
            allocator,
            event_store,
            execution,
            &budget,
        )
    else
        try executeWithBudget(
            allocator,
            event_store,
            execution,
            &budget,
        );
    var site_has_events = result.breakdown.cardinality != 0;
    if (!site_has_events) {
        const presence = try executeCardinality(
            &event_store.database,
            try compileSiteEventPresence(allocator, execution.query.site_id),
            &budget,
        );
        if (presence > 1) return error.InvalidAnalysisResult;
        site_has_events = presence == 1;
    }
    const cached_catalog = if (event_store.property_catalog_cache) |cache|
        if (std.mem.eql(u8, cache.key, catalog_key) and
            cache.expires_at_nanos > (monotonicNanos() orelse cache.expires_at_nanos))
            try clonePropertyCatalog(allocator, cache.catalog)
        else
            null
    else
        null;
    const properties = cached_catalog orelse catalog: {
        const decoded = try executePropertyCatalog(
            allocator,
            &event_store.database,
            try compilePropertyCatalog(allocator, execution),
            &budget,
        );
        try cachePropertyCatalog(event_store, catalog_key, decoded);
        break :catalog decoded;
    };
    return .{
        .breakdown = result.breakdown,
        .properties = properties,
        .site_has_events = site_has_events,
    };
}

pub fn executeSuggestions(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: analysis.SuggestionRequest,
) !analysis.SuggestionResult {
    try request.validate();
    var budget = deadline.Budget.init(request.execution.timeout_ms);
    var result = try executePlan(
        &event_store.database,
        try compileSuggestions(allocator, request),
        &budget,
    );
    defer result.deinit();
    if (result.columnCount() != 1 or
        result.rowCount() > analysis.maximum_suggestions + 1)
    {
        return error.InvalidAnalysisResult;
    }
    const visible = @min(result.rowCount(), analysis.maximum_suggestions);
    const values = try allocator.alloc([]const u8, visible);
    for (0..visible) |index| {
        const value = try result.text(allocator, 0, index);
        if (value.len == 0 or value.len > analysis.maximum_filter_value_bytes or
            !std.unicode.utf8ValidateSlice(value))
        {
            return error.InvalidAnalysisResult;
        }
        values[index] = value;
    }
    return .{
        .values = values,
        .has_more = result.rowCount() > analysis.maximum_suggestions,
    };
}

pub fn executeGoalDiscovery(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: analysis.GoalDiscoveryRequest,
) !analysis.GoalDiscoveryResult {
    try request.validate();
    var budget = deadline.Budget.init(request.timeout_ms);
    var result = try executePlan(
        &event_store.database,
        try compileGoalDiscovery(allocator, request),
        &budget,
    );
    defer result.deinit();
    if (result.columnCount() != 3 or result.rowCount() > 51) {
        return error.InvalidGoalDiscoveryResult;
    }
    const visible = @min(result.rowCount(), 50);
    const entities = try allocator.alloc(analysis.DiscoveredGoalEntity, visible);
    for (entities, 0..) |*entity, index| {
        const label = try result.text(allocator, 0, index);
        try (analysis.EventSelector{
            .kind = if (request.kind == .page) .exact_page else .exact_event,
            .value = label,
        }).validate();
        const eligible_count = result.int64(1, index);
        const last_received = result.int64(2, index);
        if (eligible_count <= 0 or last_received < 0) {
            return error.InvalidGoalDiscoveryResult;
        }
        entity.* = .{
            .label = label,
            .eligible_count = eligible_count,
            .last_received_at_utc_micros = last_received,
        };
    }
    return .{
        .entities = entities,
        .has_more = result.rowCount() > 50,
    };
}

pub fn executeGoalResult(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: analysis.GoalResultRequest,
) !analysis.GoalResult {
    try request.validate();
    var budget = deadline.Budget.init(request.timeout_ms);
    return executeGoalResultWithBudget(
        allocator,
        event_store,
        request,
        &budget,
    );
}

pub fn executeGoalPreview(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: analysis.GoalResultRequest,
) !analysis.GoalPreviewResult {
    try request.validate();
    var budget = deadline.Budget.init(request.timeout_ms);
    const result = try executeGoalResultWithBudget(
        allocator,
        event_store,
        request,
        &budget,
    );
    const properties = try executePropertyCatalog(
        allocator,
        &event_store.database,
        try compileGoalPropertyCatalog(allocator, request),
        &budget,
    );
    return .{ .result = result, .properties = properties };
}

const SessionKey = struct {
    id: []const u8,
    started_at_utc_micros: i64,
};

const SessionSummaryRequest = struct {
    site_id: []const u8,
    active_goals: []const analysis.ResolvedGoal,
    now_utc_micros: i64,

    fn fromList(request: analysis.SessionListRequest) SessionSummaryRequest {
        return .{
            .site_id = request.site_id,
            .active_goals = request.active_goals,
            .now_utc_micros = request.now_utc_micros,
        };
    }

    fn fromDetail(request: analysis.SessionDetailRequest) SessionSummaryRequest {
        return .{
            .site_id = request.site_id,
            .active_goals = request.active_goals,
            .now_utc_micros = request.now_utc_micros,
        };
    }

    fn validate(self: SessionSummaryRequest) !void {
        try domain.validateUuid(self.site_id);
        try analysis.validateActiveGoals(self.active_goals);
        if (self.now_utc_micros < 0) return error.InvalidSessionClock;
    }
};

pub fn executeSessionList(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: analysis.SessionListRequest,
) !analysis.SessionPage {
    try request.validate();
    var budget = deadline.Budget.init(request.timeout_ms);
    return executeSessionListWithBudget(
        allocator,
        event_store,
        request,
        &budget,
    );
}

fn executeSessionListWithBudget(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: analysis.SessionListRequest,
    budget: *deadline.Budget,
) !analysis.SessionPage {
    try request.validate();
    const keys = try executeSessionKeys(
        allocator,
        &event_store.database,
        request,
        budget,
    );
    const visible_count = @min(keys.len, @as(usize, analysis.session_page_size));
    return .{
        .rows = if (visible_count == 0)
            &.{}
        else
            try executeSessionDetails(
                allocator,
                event_store,
                SessionSummaryRequest.fromList(request),
                keys[0..visible_count],
                budget,
            ),
        .has_more = keys.len > visible_count,
    };
}

pub fn profileSessionList(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: analysis.SessionListRequest,
) ![]u8 {
    try request.validate();
    var output = std.Io.Writer.Allocating.init(allocator);
    try output.writer.writeAll("SESSION KEY STATEMENT\n");
    const key_plan = try compileSessionKeys(allocator, request);
    try profileOverviewPlan(allocator, event_store, key_plan, &output.writer);
    var budget = deadline.Budget.init(request.timeout_ms);
    const keys = try executeSessionKeys(
        allocator,
        &event_store.database,
        request,
        &budget,
    );
    const visible_count = @min(keys.len, @as(usize, analysis.session_page_size));
    if (visible_count != 0) {
        try output.writer.writeAll("SESSION DETAIL STATEMENT\n");
        try profileOverviewPlan(
            allocator,
            event_store,
            try compileSessionDetails(
                allocator,
                SessionSummaryRequest.fromList(request),
                keys[0..visible_count],
            ),
            &output.writer,
        );
    }
    return output.toOwnedSlice();
}

pub fn executeSessionDetail(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: analysis.SessionDetailRequest,
) !analysis.SessionDetail {
    try request.validate();
    var budget = deadline.Budget.init(request.timeout_ms);
    const key = try executeSessionDetailKey(
        allocator,
        &event_store.database,
        request,
        &budget,
    );
    const rows = try executeSessionDetails(
        allocator,
        event_store,
        SessionSummaryRequest.fromDetail(request),
        &.{key},
        &budget,
    );
    if (rows.len != 1) return error.InvalidSessionDetailResult;
    const timeline = try executeSessionTimeline(
        allocator,
        &event_store.database,
        request,
        &budget,
    );
    const visible_count = @min(
        timeline.len,
        @as(usize, analysis.session_timeline_page_size),
    );
    return .{
        .summary = rows[0],
        .timeline = timeline[0..visible_count],
        .has_more = timeline.len > visible_count,
    };
}

pub fn profileSessionDetail(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: analysis.SessionDetailRequest,
) ![]u8 {
    try request.validate();
    var output = std.Io.Writer.Allocating.init(allocator);
    try output.writer.writeAll("SESSION DETAIL KEY STATEMENT\n");
    try profileOverviewPlan(
        allocator,
        event_store,
        try compileSessionDetailKey(allocator, request),
        &output.writer,
    );
    var budget = deadline.Budget.init(request.timeout_ms);
    const key = try executeSessionDetailKey(
        allocator,
        &event_store.database,
        request,
        &budget,
    );
    try output.writer.writeAll("SESSION DETAIL SUMMARY STATEMENT\n");
    try profileOverviewPlan(
        allocator,
        event_store,
        try compileSessionDetails(
            allocator,
            SessionSummaryRequest.fromDetail(request),
            &.{key},
        ),
        &output.writer,
    );
    try output.writer.writeAll("SESSION TIMELINE STATEMENT\n");
    try profileOverviewPlan(
        allocator,
        event_store,
        try compileSessionTimeline(allocator, request),
        &output.writer,
    );
    return output.toOwnedSlice();
}

pub fn executePersonProfile(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: analysis.SessionListRequest,
) !analysis.PersonProfile {
    try request.validate();
    if (request.profile_person_key == null) return error.MissingProfilePerson;
    var budget = deadline.Budget.init(request.timeout_ms);
    const summary = try executePersonSummary(
        allocator,
        &event_store.database,
        request,
        &budget,
    );
    const sessions = try executeSessionListWithBudget(
        allocator,
        event_store,
        request,
        &budget,
    );
    return .{ .summary = summary, .sessions = sessions };
}

pub fn profilePersonProfile(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: analysis.SessionListRequest,
) ![]u8 {
    try request.validate();
    if (request.profile_person_key == null) return error.MissingProfilePerson;
    var output = std.Io.Writer.Allocating.init(allocator);
    try output.writer.writeAll("PERSON RETAINED SUMMARY STATEMENT\n");
    try profileOverviewPlan(
        allocator,
        event_store,
        try compilePersonSummary(allocator, request),
        &output.writer,
    );
    try output.writer.writeAll("PERSON CONTEXT SESSION KEY STATEMENT\n");
    try profileOverviewPlan(
        allocator,
        event_store,
        try compileSessionKeys(allocator, request),
        &output.writer,
    );
    var budget = deadline.Budget.init(request.timeout_ms);
    const keys = try executeSessionKeys(
        allocator,
        &event_store.database,
        request,
        &budget,
    );
    const visible_count = @min(keys.len, @as(usize, analysis.session_page_size));
    if (visible_count != 0) {
        try output.writer.writeAll("PERSON CONTEXT SESSION DETAIL STATEMENT\n");
        try profileOverviewPlan(
            allocator,
            event_store,
            try compileSessionDetails(
                allocator,
                SessionSummaryRequest.fromList(request),
                keys[0..visible_count],
            ),
            &output.writer,
        );
    }
    return output.toOwnedSlice();
}

pub fn executeLive(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: analysis.LiveRequest,
) !analysis.LiveResult {
    try request.validate();
    var budget = deadline.Budget.init(request.timeout_ms);
    var result = try executePlan(
        &event_store.database,
        try compileLive(allocator, request),
        &budget,
    );
    defer result.deinit();
    return decodeLive(allocator, request, &result);
}

pub fn profileLive(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: analysis.LiveRequest,
) ![]u8 {
    try request.validate();
    var output = std.Io.Writer.Allocating.init(allocator);
    try profileOverviewPlan(
        allocator,
        event_store,
        try compileLive(allocator, request),
        &output.writer,
    );
    return output.toOwnedSlice();
}

fn compileLive(
    allocator: std.mem.Allocator,
    request: analysis.LiveRequest,
) !StatementPlan {
    try request.validate();
    var builder = Builder.init(allocator);
    if (request.strict_traffic_mode) {
        var goals: [analysis.maximum_active_goals]traffic.Goal = undefined;
        for (request.active_goals, 0..) |goal, index| goals[index] = .{
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
            request.site_id,
            goals[0..request.active_goals.len],
            true,
        ));
        try builder.write(", ");
    } else try builder.write("WITH ");
    try builder.write(
        "stored_window AS MATERIALIZED (SELECT e.* FROM events e" ++
            " WHERE e.site_id = ",
    );
    try builder.bindText(request.site_id);
    try builder.write(" AND e.received_at_utc_micros BETWEEN ");
    try builder.bindInteger(try request.windowStart());
    try builder.write(" AND ");
    try builder.bindInteger(request.now_utc_micros);
    try builder.write(
        "), product_window AS MATERIALIZED (SELECT e.* FROM stored_window e" ++
            " WHERE e.traffic_class IN (1, 5)",
    );
    if (request.strict_traffic_mode) try builder.write(
        " AND e.session_id NOT IN (SELECT session_id" ++
            " FROM d34_current_suspected_sessions)",
    );
    try builder.write(
        "), meaningful AS MATERIALIZED (SELECT e.*, ",
    );
    try writeGoalMatchMask(&builder, request.active_goals, "e");
    try builder.write(
        " AS goal_mask FROM product_window e WHERE e.kind IN (1, 2))," ++
            " window_sessions AS MATERIALIZED (SELECT session_id," ++
            " max(received_at_utc_micros)::BIGINT AS last_received" ++
            " FROM product_window GROUP BY session_id)," ++
            " session_events AS MATERIALIZED (SELECT e.session_id, e.kind," ++
            " e.occurred_at_utc_micros, e.sequence," ++
            " e.received_at_utc_micros, e.event_id, e.utm_source," ++
            " e.referrer_host, e.country_code, e.device_category" ++
            " FROM events e JOIN window_sessions w USING (session_id)" ++
            " WHERE e.site_id = ",
    );
    try builder.bindText(request.site_id);
    try builder.write(
        " AND e.received_at_utc_micros <= ",
    );
    try builder.bindInteger(request.now_utc_micros);
    try builder.write(" AND e.traffic_class IN (1, 5)");
    if (request.strict_traffic_mode) try builder.write(
        " AND e.session_id NOT IN (SELECT session_id" ++
            " FROM d34_current_suspected_sessions)",
    );
    try builder.write(
        "), session_facts AS MATERIALIZED (SELECT e.session_id," ++
            " w.last_received, COALESCE(first(CASE" ++
            " WHEN e.utm_source <> '' THEN e.utm_source" ++
            " WHEN e.referrer_host <> '' THEN e.referrer_host" ++
            " ELSE 'Direct' END ORDER BY e.occurred_at_utc_micros," ++
            " e.sequence, e.received_at_utc_micros, e.event_id)" ++
            " FILTER (WHERE e.kind = 1), 'Direct') AS source," ++
            " COALESCE(NULLIF(first(CASE WHEN e.country_code = 'ZZ'" ++
            " THEN 'Unknown' ELSE e.country_code END ORDER BY" ++
            " e.occurred_at_utc_micros, e.sequence," ++
            " e.received_at_utc_micros, e.event_id)" ++
            " FILTER (WHERE e.kind IN (1, 2)), ''), 'Unknown') AS country," ++
            " COALESCE(NULLIF(first(e.device_category ORDER BY" ++
            " e.occurred_at_utc_micros, e.sequence," ++
            " e.received_at_utc_micros, e.event_id)" ++
            " FILTER (WHERE e.kind IN (1, 2)), ''), 'Unknown') AS device" ++
            " FROM session_events e JOIN window_sessions w USING (session_id)" ++
            " GROUP BY e.session_id, w.last_received)," ++
            " kpis AS (SELECT count(*) FILTER (WHERE last_received >= ",
    );
    try builder.bindInteger(try request.activeStart());
    try builder.write(
        ")::BIGINT AS active_sessions FROM session_facts)," ++
            " event_kpis AS (SELECT" ++
            " count(*) FILTER (WHERE kind = 1)::BIGINT AS page_views," ++
            " count(*) FILTER (WHERE kind = 2)::BIGINT AS custom_events," ++
            " COALESCE(sum(bit_count(goal_mask)), 0)::BIGINT AS conversions" ++
            " FROM meaningful)," ++
            " page_rows AS (SELECT path AS label, count(*)::BIGINT AS value" ++
            " FROM meaningful WHERE kind = 1 GROUP BY path" ++
            " ORDER BY value DESC, label ASC LIMIT ",
    );
    try builder.bindInteger(analysis.maximum_live_breakdown_rows);
    try builder.write(
        "), source_rows AS (SELECT source AS label," ++
            " count(*)::BIGINT AS value FROM session_facts GROUP BY source" ++
            " ORDER BY value DESC, label ASC LIMIT ",
    );
    try builder.bindInteger(analysis.maximum_live_breakdown_rows);
    try builder.write(
        "), event_rows AS (SELECT event_name AS label," ++
            " count(*)::BIGINT AS value FROM meaningful WHERE kind = 2" ++
            " GROUP BY event_name ORDER BY value DESC, label ASC LIMIT ",
    );
    try builder.bindInteger(analysis.maximum_live_breakdown_rows);
    try builder.write(
        "), country_rows AS (SELECT country AS label," ++
            " count(*)::BIGINT AS value FROM session_facts GROUP BY country" ++
            " ORDER BY value DESC, label ASC LIMIT ",
    );
    try builder.bindInteger(analysis.maximum_live_breakdown_rows);
    try builder.write(
        "), device_rows AS (SELECT device AS label," ++
            " count(*)::BIGINT AS value FROM session_facts GROUP BY device" ++
            " ORDER BY value DESC, label ASC LIMIT ",
    );
    try builder.bindInteger(analysis.maximum_live_breakdown_rows);
    try builder.write(
        "), protocol_rows AS (SELECT CAST(protocol_version AS VARCHAR) AS label," ++
            " count(*)::BIGINT AS value FROM stored_window" ++
            " GROUP BY protocol_version)," ++
            " goal_counts AS (SELECT CAST('' AS VARCHAR) AS label," ++
            " 0::BIGINT AS value WHERE FALSE",
    );
    for (request.active_goals, 0..) |goal, index| {
        try builder.write(" UNION ALL SELECT ");
        try builder.bindText(goal.id);
        try builder.write(", count(*)::BIGINT FROM meaningful WHERE" ++
            " (goal_mask & ");
        try builder.bindInteger(@as(i64, 1) << @intCast(index));
        try builder.write(") <> 0 HAVING count(*) > 0");
    }
    try builder.write(
        "), goal_rows AS (SELECT label, value FROM goal_counts" ++
            " ORDER BY value DESC, label ASC",
    );
    try builder.write(
        "), latest AS (SELECT max(received_at_utc_micros)::BIGINT AS value" ++
            " FROM events WHERE site_id = ",
    );
    try builder.bindText(request.site_id);
    try builder.write(" AND received_at_utc_micros <= ");
    try builder.bindInteger(request.now_utc_micros);
    try builder.write(
        "), output(section, label, value, section_order, position) AS (" ++
            " SELECT 'kpi', 'active-sessions', active_sessions, 1, 1 FROM kpis" ++
            " UNION ALL SELECT 'kpi', 'page-views', page_views, 1, 2" ++
            " FROM event_kpis" ++
            " UNION ALL SELECT 'kpi', 'custom-events', custom_events, 1, 3" ++
            " FROM event_kpis" ++
            " UNION ALL SELECT 'kpi', 'conversions', conversions, 1, 4" ++
            " FROM event_kpis" ++
            " UNION ALL SELECT 'page', label, value, 2, 0 FROM page_rows" ++
            " UNION ALL SELECT 'source', label, value, 3, 0 FROM source_rows" ++
            " UNION ALL SELECT 'event', label, value, 4, 0 FROM event_rows" ++
            " UNION ALL SELECT 'goal', label, value, 5, 0 FROM goal_rows" ++
            " UNION ALL SELECT 'country', label, value, 6, 0 FROM country_rows" ++
            " UNION ALL SELECT 'device', label, value, 7, 0 FROM device_rows" ++
            " UNION ALL SELECT 'protocol', label, value, 8, 0 FROM protocol_rows" ++
            " UNION ALL SELECT 'latest', '', value, 9, 0 FROM latest)" ++
            " SELECT section, label, value FROM output" ++
            " ORDER BY section_order, position, value DESC NULLS LAST, label ASC",
    );
    return builder.finish();
}

fn decodeLive(
    allocator: std.mem.Allocator,
    request: analysis.LiveRequest,
    result: *duckdb.Result,
) !analysis.LiveResult {
    const maximum_rows = 4 + 5 * analysis.maximum_live_breakdown_rows +
        analysis.maximum_active_goals + 2 + 1;
    if (result.columnCount() != 3 or result.rowCount() > maximum_rows) {
        return error.InvalidLiveResult;
    }
    var active_sessions: ?i64 = null;
    var page_views: ?i64 = null;
    var custom_events: ?i64 = null;
    var conversions: ?i64 = null;
    var latest_seen = false;
    var latest_accepted_at_utc_micros: ?i64 = null;
    var pages: std.ArrayList(analysis.LiveRow) = .empty;
    var sources: std.ArrayList(analysis.LiveRow) = .empty;
    var event_rows: std.ArrayList(analysis.LiveRow) = .empty;
    var goals: std.ArrayList(analysis.LiveGoalRow) = .empty;
    var countries: std.ArrayList(analysis.LiveRow) = .empty;
    var devices: std.ArrayList(analysis.LiveRow) = .empty;
    var protocols: std.ArrayList(analysis.LiveProtocolRow) = .empty;
    for (0..result.rowCount()) |index| {
        const section = try result.text(allocator, 0, index);
        const label = try result.text(allocator, 1, index);
        if (std.mem.eql(u8, section, "latest")) {
            if (latest_seen or label.len != 0) return error.InvalidLiveResult;
            latest_seen = true;
            if (!result.isNull(2, index)) {
                const value = result.int64(2, index);
                if (value < 0 or value > request.now_utc_micros) {
                    return error.InvalidLiveResult;
                }
                latest_accepted_at_utc_micros = value;
            }
            continue;
        }
        if (result.isNull(2, index)) return error.InvalidLiveResult;
        const value = result.int64(2, index);
        if (value < 0) return error.InvalidLiveResult;
        if (std.mem.eql(u8, section, "kpi")) {
            const slot = if (std.mem.eql(u8, label, "active-sessions"))
                &active_sessions
            else if (std.mem.eql(u8, label, "page-views"))
                &page_views
            else if (std.mem.eql(u8, label, "custom-events"))
                &custom_events
            else if (std.mem.eql(u8, label, "conversions"))
                &conversions
            else
                return error.InvalidLiveResult;
            if (slot.* != null) return error.InvalidLiveResult;
            slot.* = value;
        } else if (std.mem.eql(u8, section, "page")) {
            try appendLiveRow(allocator, &pages, label, value);
        } else if (std.mem.eql(u8, section, "source")) {
            try appendLiveRow(allocator, &sources, label, value);
        } else if (std.mem.eql(u8, section, "event")) {
            try appendLiveRow(allocator, &event_rows, label, value);
        } else if (std.mem.eql(u8, section, "country")) {
            try appendLiveRow(allocator, &countries, label, value);
        } else if (std.mem.eql(u8, section, "device")) {
            try appendLiveRow(allocator, &devices, label, value);
        } else if (std.mem.eql(u8, section, "goal")) {
            if (goals.items.len >= request.active_goals.len) {
                return error.InvalidLiveResult;
            }
            var known = false;
            for (request.active_goals) |goal| {
                if (std.mem.eql(u8, goal.id, label)) known = true;
            }
            if (!known) return error.InvalidLiveResult;
            for (goals.items) |row| {
                if (std.mem.eql(u8, row.goal_id, label)) {
                    return error.InvalidLiveResult;
                }
            }
            try goals.append(allocator, .{ .goal_id = label, .count = value });
        } else if (std.mem.eql(u8, section, "protocol")) {
            const version = std.fmt.parseInt(u8, label, 10) catch
                return error.InvalidLiveResult;
            if (version != 1 and version != 2) return error.InvalidLiveResult;
            for (protocols.items) |row| {
                if (row.version == version) return error.InvalidLiveResult;
            }
            try protocols.append(allocator, .{ .version = version, .count = value });
        } else return error.InvalidLiveResult;
    }
    if (active_sessions == null or page_views == null or custom_events == null or
        conversions == null or !latest_seen)
    {
        return error.InvalidLiveResult;
    }
    return .{
        .active_sessions = active_sessions.?,
        .page_views = page_views.?,
        .custom_events = custom_events.?,
        .conversions = conversions.?,
        .pages = try pages.toOwnedSlice(allocator),
        .sources = try sources.toOwnedSlice(allocator),
        .events = try event_rows.toOwnedSlice(allocator),
        .goals = try goals.toOwnedSlice(allocator),
        .countries = try countries.toOwnedSlice(allocator),
        .devices = try devices.toOwnedSlice(allocator),
        .protocols = try protocols.toOwnedSlice(allocator),
        .latest_accepted_at_utc_micros = latest_accepted_at_utc_micros,
    };
}

fn appendLiveRow(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(analysis.LiveRow),
    label: []const u8,
    count: i64,
) !void {
    if (label.len == 0 or rows.items.len >= analysis.maximum_live_breakdown_rows) {
        return error.InvalidLiveResult;
    }
    for (rows.items) |row| {
        if (std.mem.eql(u8, row.label, label)) return error.InvalidLiveResult;
    }
    try rows.append(allocator, .{ .label = label, .count = count });
}

fn executeSessionDetailKey(
    allocator: std.mem.Allocator,
    database: *duckdb.Database,
    request: analysis.SessionDetailRequest,
    budget: *deadline.Budget,
) !SessionKey {
    var result = try executePlan(
        database,
        try compileSessionDetailKey(allocator, request),
        budget,
    );
    defer result.deinit();
    if (result.columnCount() != 2 or result.rowCount() != 1) {
        return error.SessionNotFound;
    }
    const key = SessionKey{
        .id = try result.text(allocator, 0, 0),
        .started_at_utc_micros = result.int64(1, 0),
    };
    if (!std.mem.eql(u8, key.id, request.session_id) or
        key.started_at_utc_micros < 0)
    {
        return error.InvalidSessionDetailResult;
    }
    return key;
}

fn compileSessionDetailKey(
    allocator: std.mem.Allocator,
    request: analysis.SessionDetailRequest,
) !StatementPlan {
    try request.validate();
    var builder = Builder.init(allocator);
    try builder.write(
        "SELECT CAST(session_id AS VARCHAR)," ++
            " min(occurred_at_utc_micros)::BIGINT" ++
            " FROM events WHERE site_id = ",
    );
    try builder.bindText(request.site_id);
    try builder.write(" AND session_id = CAST(");
    try builder.bindText(request.session_id);
    try builder.write(
        " AS UUID) AND kind IN (1, 2)" ++
            " AND traffic_class IN (1, 5) GROUP BY session_id",
    );
    return builder.finish();
}

fn executeSessionTimeline(
    allocator: std.mem.Allocator,
    database: *duckdb.Database,
    request: analysis.SessionDetailRequest,
    budget: *deadline.Budget,
) ![]const analysis.SessionTimelineRow {
    var result = try executePlan(
        database,
        try compileSessionTimeline(allocator, request),
        budget,
    );
    defer result.deinit();
    const maximum_rows = @as(usize, analysis.session_timeline_page_size) + 1;
    if (result.columnCount() != 14 or result.rowCount() > maximum_rows) {
        return error.InvalidSessionTimelineResult;
    }
    const rows = try allocator.alloc(
        analysis.SessionTimelineRow,
        result.rowCount(),
    );
    for (rows, 0..) |*row, index| {
        const raw_kind = result.int64(0, index);
        const kind: analysis.SessionTimelineKind = switch (raw_kind) {
            1 => .page,
            2 => .custom,
            3 => .engagement,
            4 => .identify,
            else => return error.InvalidSessionTimelineResult,
        };
        const occurred = result.int64(4, index);
        const engagement_ms = result.int64(10, index);
        const max_scroll_depth = result.int64(11, index);
        const engagement_fragments = result.int64(12, index);
        const raw_goal_mask = result.int64(13, index);
        const valid_goal_mask: u64 = if (request.active_goals.len == 32)
            std.math.maxInt(u32)
        else
            (@as(u64, 1) << @intCast(request.active_goals.len)) - 1;
        if (occurred < 0 or engagement_ms < 0 or max_scroll_depth < 0 or
            max_scroll_depth > 100 or engagement_fragments <= 0 or
            raw_goal_mask < 0 or raw_goal_mask > std.math.maxInt(u32) or
            (@as(u64, @intCast(raw_goal_mask)) & ~valid_goal_mask) != 0 or
            (kind != .engagement and
                (engagement_ms != 0 or max_scroll_depth != 0 or
                    engagement_fragments != 1)) or
            (kind == .engagement and raw_goal_mask != 0))
        {
            return error.InvalidSessionTimelineResult;
        }
        const value_amount = if (result.isNull(8, index))
            null
        else
            try result.text(allocator, 8, index);
        const value_currency = try result.text(allocator, 9, index);
        if (value_amount) |amount| {
            if ((property.numberType(amount) catch
                return error.InvalidSessionTimelineResult) != .decimal)
            {
                return error.InvalidSessionTimelineResult;
            }
            domain.validateCurrency(value_currency) catch
                return error.InvalidSessionTimelineResult;
        } else if (value_currency.len != 0) {
            return error.InvalidSessionTimelineResult;
        }
        row.* = .{
            .kind = kind,
            .event_name = try result.text(allocator, 1, index),
            .path = try result.text(allocator, 2, index),
            .page_title = try result.text(allocator, 3, index),
            .occurred_at_utc_micros = occurred,
            .properties_json = try result.text(allocator, 5, index),
            .user_id = try result.text(allocator, 6, index),
            .user_traits_json = try result.text(allocator, 7, index),
            .value_amount = value_amount,
            .value_currency = value_currency,
            .engagement_ms = engagement_ms,
            .max_scroll_depth = max_scroll_depth,
            .engagement_fragments = engagement_fragments,
            .goal_mask = @intCast(raw_goal_mask),
        };
    }
    return rows;
}

fn compileSessionTimeline(
    allocator: std.mem.Allocator,
    request: analysis.SessionDetailRequest,
) !StatementPlan {
    try request.validate();
    var builder = Builder.init(allocator);
    try builder.write(
        "WITH ordered AS MATERIALIZED (SELECT e.*," ++
            " sum(CASE WHEN e.kind = 1 THEN 1 ELSE 0 END) OVER" ++
            " (ORDER BY e.occurred_at_utc_micros, e.sequence," ++
            " e.received_at_utc_micros, e.event_id) AS page_visit" ++
            " FROM events e WHERE e.site_id = ",
    );
    try builder.bindText(request.site_id);
    try builder.write(" AND e.session_id = CAST(");
    try builder.bindText(request.session_id);
    try builder.write(
        " AS UUID) AND e.traffic_class IN (1, 5))," ++
            " event_rows AS (SELECT e.kind, e.event_name, e.path," ++
            " e.page_title, e.occurred_at_utc_micros," ++
            " e.properties_json, e.user_id, e.user_traits_json," ++
            " CAST(e.value_amount AS VARCHAR) AS value_amount," ++
            " e.value_currency, 0::BIGINT AS engagement_ms," ++
            " 0::BIGINT AS max_scroll_depth," ++
            " 1::BIGINT AS engagement_fragments, CASE" ++
            " WHEN e.kind IN (1, 2) THEN ",
    );
    try writeGoalMatchMask(&builder, request.active_goals, "e");
    try builder.write(
        " ELSE 0::UBIGINT END AS goal_mask, e.sequence," ++
            " e.received_at_utc_micros, e.event_id FROM ordered e" ++
            " WHERE e.kind <> 3)," ++
            " engagement_rows AS (SELECT 3::UTINYINT AS kind," ++
            " 'engagement' AS event_name, e.path," ++
            " first(e.page_title ORDER BY e.occurred_at_utc_micros DESC," ++
            " e.sequence DESC, e.received_at_utc_micros DESC," ++
            " e.event_id DESC) AS page_title," ++
            " first(e.occurred_at_utc_micros ORDER BY" ++
            " e.occurred_at_utc_micros DESC, e.sequence DESC," ++
            " e.received_at_utc_micros DESC, e.event_id DESC)::BIGINT" ++
            " AS occurred_at_utc_micros, '{}' AS properties_json," ++
            " '' AS user_id, '{}' AS user_traits_json," ++
            " CAST(NULL AS VARCHAR) AS value_amount," ++
            " '' AS value_currency, sum(e.engagement_ms)::BIGINT," ++
            " max(e.max_scroll_depth)::BIGINT," ++
            " count(*)::BIGINT AS engagement_fragments," ++
            " 0::UBIGINT AS goal_mask," ++
            " first(e.sequence ORDER BY e.occurred_at_utc_micros DESC," ++
            " e.sequence DESC, e.received_at_utc_micros DESC," ++
            " e.event_id DESC) AS sequence," ++
            " first(e.received_at_utc_micros ORDER BY" ++
            " e.occurred_at_utc_micros DESC, e.sequence DESC," ++
            " e.received_at_utc_micros DESC, e.event_id DESC)" ++
            " AS received_at_utc_micros," ++
            " first(e.event_id ORDER BY e.occurred_at_utc_micros DESC," ++
            " e.sequence DESC, e.received_at_utc_micros DESC," ++
            " e.event_id DESC) AS event_id FROM ordered e" ++
            " WHERE e.kind = 3 GROUP BY e.page_visit, e.path)," ++
            " timeline AS (SELECT * FROM event_rows UNION ALL" ++
            " SELECT * FROM engagement_rows) SELECT kind, event_name, path," ++
            " page_title, occurred_at_utc_micros, properties_json, user_id," ++
            " user_traits_json, value_amount, value_currency, engagement_ms," ++
            " max_scroll_depth, engagement_fragments, goal_mask" ++
            " FROM timeline ORDER BY occurred_at_utc_micros, sequence," ++
            " received_at_utc_micros, event_id LIMIT ",
    );
    try builder.bindInteger(
        @as(i64, analysis.session_timeline_page_size) + 1,
    );
    try builder.write(" OFFSET ");
    try builder.bindInteger(try request.offset());
    return builder.finish();
}

fn executePersonSummary(
    allocator: std.mem.Allocator,
    database: *duckdb.Database,
    request: analysis.SessionListRequest,
    budget: *deadline.Budget,
) !analysis.PersonSummary {
    const person_key = request.profile_person_key orelse
        return error.MissingProfilePerson;
    var result = try executePlan(
        database,
        try compilePersonSummary(allocator, request),
        budget,
    );
    defer result.deinit();
    if (result.columnCount() != 13 or result.rowCount() == 0) {
        return error.InvalidPersonProfileResult;
    }
    if (result.rowCount() > analysis.maximum_currency_series + 1) {
        return error.TooManyAnalysisCurrencies;
    }
    var summary: analysis.PersonSummary = undefined;
    var seen_summary = false;
    var revenue: std.ArrayList(analysis.SessionRevenue) = .empty;
    var expected_currency_position: i64 = 1;
    for (0..result.rowCount()) |index| {
        const section = try result.text(allocator, 0, index);
        const result_person = try result.text(allocator, 1, index);
        if (!std.mem.eql(u8, result_person, person_key)) {
            return error.InvalidPersonProfileResult;
        }
        if (std.mem.eql(u8, section, "summary")) {
            if (result.isNull(2, index) or result.isNull(3, index)) {
                return error.PersonNotFound;
            }
            if (seen_summary or !result.isNull(9, index) or
                result.int64(11, index) != 0 or
                result.int64(12, index) != 0)
            {
                return error.InvalidPersonProfileResult;
            }
            const first_seen = result.int64(2, index);
            const last_seen = result.int64(3, index);
            const sessions = result.int64(4, index);
            const engagement_ms = result.int64(5, index);
            const conversions = result.int64(6, index);
            const linked = result.int64(8, index);
            if (first_seen < 0 or first_seen > last_seen or sessions <= 0 or
                engagement_ms < 0 or conversions < 0 or linked < 0 or
                (std.mem.startsWith(u8, person_key, "a:") and linked != 0) or
                (std.mem.startsWith(u8, person_key, "u:") and linked == 0))
            {
                return error.InvalidPersonProfileResult;
            }
            summary = .{
                .person_key = result_person,
                .first_seen_utc_micros = first_seen,
                .last_seen_utc_micros = last_seen,
                .sessions = sessions,
                .engagement_ms = engagement_ms,
                .conversions = conversions,
                .latest_traits_json = try result.text(allocator, 7, index),
                .linked_anonymous_ids = linked,
                .revenue = &.{},
            };
            seen_summary = true;
        } else if (std.mem.eql(u8, section, "revenue")) {
            if (!seen_summary or result.isNull(9, index) or
                result.int64(12, index) != expected_currency_position)
            {
                return error.InvalidPersonProfileResult;
            }
            const decimal = try result.text(allocator, 9, index);
            const currency = try result.text(allocator, 10, index);
            const value_count = result.int64(11, index);
            if ((property.numberType(decimal) catch
                return error.InvalidPersonProfileResult) != .decimal or
                value_count <= 0)
            {
                return error.InvalidPersonProfileResult;
            }
            domain.validateCurrency(currency) catch
                return error.InvalidPersonProfileResult;
            try revenue.append(allocator, .{
                .decimal = decimal,
                .currency = currency,
                .value_count = value_count,
            });
            expected_currency_position += 1;
        } else return error.InvalidPersonProfileResult;
    }
    if (!seen_summary) return error.PersonNotFound;
    summary.revenue = try revenue.toOwnedSlice(allocator);
    return summary;
}

fn compilePersonSummary(
    allocator: std.mem.Allocator,
    request: analysis.SessionListRequest,
) !StatementPlan {
    try request.validate();
    const person_key = request.profile_person_key orelse
        return error.MissingProfilePerson;
    var builder = Builder.init(allocator);
    try builder.write(
        "WITH person_events AS MATERIALIZED (SELECT e.*," ++
            " CASE WHEN e.identity_quality = 1" ++
            " AND COALESCE(l.user_id, e.user_id, '') <> ''" ++
            " THEN 'u:' || COALESCE(l.user_id, e.user_id)" ++
            " WHEN e.identity_quality = 1" ++
            " THEN 'a:' || CAST(e.anonymous_id AS VARCHAR)" ++
            " ELSE NULL END AS person_key FROM events e" ++
            " LEFT JOIN identity_links l ON l.site_id = e.site_id" ++
            " AND l.anonymous_id = e.anonymous_id WHERE e.site_id = ",
    );
    try builder.bindText(request.site_id);
    try builder.write(
        " AND e.traffic_class IN (1, 5))," ++
            " selected AS MATERIALIZED (SELECT * FROM person_events" ++
            " WHERE person_key = ",
    );
    try builder.bindText(person_key);
    try builder.write(
        "), meaningful_sessions AS MATERIALIZED" ++
            " (SELECT DISTINCT session_id FROM selected" ++
            " WHERE kind IN (1, 2)), profile_events AS NOT MATERIALIZED" ++
            " (SELECT e.* FROM selected e JOIN meaningful_sessions s" ++
            " USING (session_id)), profile_summary AS (SELECT" ++
            " min(occurred_at_utc_micros) FILTER" ++
            " (WHERE kind IN (1, 2))::BIGINT AS first_seen," ++
            " max(occurred_at_utc_micros) FILTER" ++
            " (WHERE kind IN (1, 2))::BIGINT AS last_seen," ++
            " count(DISTINCT session_id)::BIGINT AS sessions," ++
            " COALESCE(sum(engagement_ms), 0)::BIGINT AS engagement_ms," ++
            " COALESCE(sum(CASE WHEN kind IN (1, 2) THEN ",
    );
    try writeGoalMatchCount(&builder, request.active_goals, "profile_events");
    try builder.write(
        " ELSE 0 END), 0)::BIGINT AS conversions," ++
            " COALESCE(first(user_traits_json ORDER BY" ++
            " occurred_at_utc_micros DESC, sequence DESC," ++
            " received_at_utc_micros DESC, event_id DESC)" ++
            " FILTER (WHERE kind = 4), '{}') AS latest_traits_json" ++
            " FROM profile_events), profile_revenue AS" ++
            " (SELECT value_currency," ++
            " CAST(sum(value_amount) AS VARCHAR) AS amount," ++
            " count(value_amount)::BIGINT AS value_count," ++
            " row_number() OVER (ORDER BY value_currency)::BIGINT" ++
            " AS currency_position FROM profile_events" ++
            " WHERE kind IN (1, 2) AND value_amount IS NOT NULL" ++
            " GROUP BY value_currency) SELECT 'summary' AS section, ",
    );
    try builder.bindText(person_key);
    try builder.write(
        " AS person_key, first_seen, last_seen, sessions," ++
            " engagement_ms, conversions, latest_traits_json, ",
    );
    if (std.mem.startsWith(u8, person_key, "u:")) {
        try builder.write("(SELECT count(*)::BIGINT FROM identity_links" ++
            " WHERE site_id = ");
        try builder.bindText(request.site_id);
        try builder.write(" AND user_id = ");
        try builder.bindText(person_key[2..]);
        try builder.write(")");
    } else try builder.write("0::BIGINT");
    try builder.write(
        " AS linked_anonymous_ids, CAST(NULL AS VARCHAR) AS amount," ++
            " '' AS value_currency, 0::BIGINT AS value_count," ++
            " 0::BIGINT AS currency_position FROM profile_summary" ++
            " UNION ALL SELECT 'revenue', ",
    );
    try builder.bindText(person_key);
    try builder.write(
        ", 0::BIGINT, 0::BIGINT, 0::BIGINT, 0::BIGINT, 0::BIGINT," ++
            " '', 0::BIGINT, amount, value_currency, value_count," ++
            " currency_position FROM profile_revenue ORDER BY" ++
            " currency_position LIMIT ",
    );
    try builder.bindInteger(
        @as(i64, analysis.maximum_currency_series) + 2,
    );
    return builder.finish();
}

fn executeSessionKeys(
    allocator: std.mem.Allocator,
    database: *duckdb.Database,
    request: analysis.SessionListRequest,
    budget: *deadline.Budget,
) ![]const SessionKey {
    var result = try executePlan(
        database,
        try compileSessionKeys(allocator, request),
        budget,
    );
    defer result.deinit();
    const maximum_keys = @as(usize, analysis.session_page_size) + 1;
    if (result.columnCount() != 2 or result.rowCount() > maximum_keys) {
        return error.InvalidSessionListResult;
    }
    const keys = try allocator.alloc(SessionKey, result.rowCount());
    var previous: ?SessionKey = null;
    for (keys, 0..) |*key, index| {
        key.* = .{
            .id = try result.text(allocator, 0, index),
            .started_at_utc_micros = result.int64(1, index),
        };
        domain.validateUuid(key.id) catch return error.InvalidSessionListResult;
        if (previous) |prior| {
            if (prior.started_at_utc_micros < key.started_at_utc_micros or
                (prior.started_at_utc_micros == key.started_at_utc_micros and
                    std.mem.order(u8, prior.id, key.id) != .lt))
            {
                return error.InvalidSessionListResult;
            }
        }
        previous = key.*;
    }
    return keys;
}

fn executeSessionDetails(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: SessionSummaryRequest,
    keys: []const SessionKey,
    budget: *deadline.Budget,
) ![]const analysis.SessionRow {
    if (keys.len == 0 or keys.len > analysis.session_page_size) {
        return error.InvalidSessionListResult;
    }
    const plan = try compileSessionDetails(allocator, request, keys);
    const statement = try event_store.sessionDetailStatement(plan.sql);
    for (plan.bindings, 1..) |binding, index| switch (binding) {
        .text => |value| statement.bindText(index, value) catch |err| {
            event_store.discardSessionDetailTemplate();
            return err;
        },
        .integer => |value| statement.bindInt64(index, value) catch |err| {
            event_store.discardSessionDetailTemplate();
            return err;
        },
    };
    var result = budget.execute(&event_store.database, statement) catch |err| {
        event_store.discardSessionDetailTemplate();
        if (err == error.ReportTimeout) return error.AnalysisTimeout;
        return err;
    };
    defer {
        result.deinit();
        statement.clear() catch event_store.discardSessionDetailTemplate();
    }
    const maximum_rows = keys.len *
        (@as(usize, analysis.maximum_currency_series) + 2);
    if (result.columnCount() != 24 or result.rowCount() > maximum_rows) {
        return error.InvalidSessionListResult;
    }
    const rows = try allocator.alloc(analysis.SessionRow, keys.len);
    const seen = try allocator.alloc(bool, keys.len);
    @memset(seen, false);
    const revenue = try allocator.alloc(
        std.ArrayList(analysis.SessionRevenue),
        keys.len,
    );
    for (revenue) |*values| values.* = .empty;
    var expected_currency_positions = try allocator.alloc(usize, keys.len);
    @memset(expected_currency_positions, 1);

    for (0..result.rowCount()) |result_row| {
        const section = try result.text(allocator, 0, result_row);
        const raw_position = result.int64(1, result_row);
        if (raw_position < 0 or raw_position >= keys.len) {
            return error.InvalidSessionListResult;
        }
        const position: usize = @intCast(raw_position);
        const session_id = try result.text(allocator, 2, result_row);
        if (!std.mem.eql(u8, session_id, keys[position].id)) {
            return error.InvalidSessionListResult;
        }
        if (std.mem.eql(u8, section, "session")) {
            if (seen[position] or !result.isNull(20, result_row) or
                result.int64(22, result_row) != 0 or
                result.int64(23, result_row) != 0)
            {
                return error.InvalidSessionListResult;
            }
            const person_key = try result.text(allocator, 3, result_row);
            if (!validSessionPersonKey(person_key)) {
                return error.InvalidSessionListResult;
            }
            const started = result.int64(4, result_row);
            const last_activity = result.int64(5, result_row);
            const last_received = result.int64(6, result_row);
            const duration_ms = result.int64(15, result_row);
            const engagement_ms = result.int64(16, result_row);
            const page_views = result.int64(17, result_row);
            const custom_events = result.int64(18, result_row);
            const conversions = result.int64(19, result_row);
            if (started != keys[position].started_at_utc_micros or
                started < 0 or last_activity < 0 or
                started > last_activity or last_received < 0 or
                duration_ms < 0 or engagement_ms < 0 or page_views < 0 or
                custom_events < 0 or conversions < 0 or
                page_views + custom_events == 0)
            {
                return error.InvalidSessionListResult;
            }
            const age = std.math.sub(
                i64,
                request.now_utc_micros,
                last_received,
            ) catch -1;
            rows[position] = .{
                .session_id = session_id,
                .person_key = person_key,
                .started_at_utc_micros = started,
                .last_activity_utc_micros = last_activity,
                .last_received_at_utc_micros = last_received,
                .landing_page = try result.text(allocator, 7, result_row),
                .channel = try result.text(allocator, 8, result_row),
                .referrer = try result.text(allocator, 9, result_row),
                .utm_source = try result.text(allocator, 10, result_row),
                .utm_campaign = try result.text(allocator, 11, result_row),
                .country = try result.text(allocator, 12, result_row),
                .device = try result.text(allocator, 13, result_row),
                .browser = try result.text(allocator, 14, result_row),
                .duration_ms = duration_ms,
                .engagement_ms = engagement_ms,
                .page_views = page_views,
                .custom_events = custom_events,
                .conversions = conversions,
                .current = age >= 0 and age <= 30 * 60 * 1_000_000,
                .revenue = &.{},
            };
            seen[position] = true;
        } else if (std.mem.eql(u8, section, "revenue")) {
            if (!seen[position] or result.isNull(20, result_row)) {
                return error.InvalidSessionListResult;
            }
            const currency_position = result.int64(23, result_row);
            const currency = try result.text(allocator, 21, result_row);
            const decimal = try result.text(allocator, 20, result_row);
            const value_count = result.int64(22, result_row);
            const number_type = property.numberType(decimal) catch
                return error.InvalidSessionListResult;
            if (currency_position != expected_currency_positions[position] or
                value_count <= 0 or number_type != .decimal)
            {
                return error.InvalidSessionListResult;
            }
            domain.validateCurrency(currency) catch
                return error.InvalidSessionListResult;
            if (revenue[position].items.len >= analysis.maximum_currency_series) {
                return error.TooManyAnalysisCurrencies;
            }
            if (revenue[position].items.len != 0) {
                const prior = revenue[position].items[
                    revenue[position].items.len - 1
                ];
                if (std.mem.order(u8, prior.currency, currency) != .lt) {
                    return error.InvalidSessionListResult;
                }
            }
            try revenue[position].append(allocator, .{
                .decimal = decimal,
                .currency = currency,
                .value_count = value_count,
            });
            expected_currency_positions[position] += 1;
        } else return error.InvalidSessionListResult;
    }
    for (rows, revenue, seen) |*row, *values, was_seen| {
        if (!was_seen) return error.InvalidSessionListResult;
        row.revenue = try values.toOwnedSlice(allocator);
    }
    return rows;
}

fn validSessionPersonKey(value: []const u8) bool {
    if (value.len < 3 or value[1] != ':') return false;
    return switch (value[0]) {
        'a', 'e', 'l' => value.len == 38 and value: {
            domain.validateUuid(value[2..]) catch break :value false;
            break :value true;
        },
        'u' => value.len <= 162 and std.unicode.utf8ValidateSlice(value[2..]) and
            value: {
                for (value[2..]) |byte| {
                    if (byte < 0x20 or byte == 0x7f) break :value false;
                }
                break :value true;
            },
        else => false,
    };
}

fn compileSessionKeys(
    allocator: std.mem.Allocator,
    request: analysis.SessionListRequest,
) !StatementPlan {
    try request.validate();
    const session_columns = FilteredSessionColumns.resolve(request.filters, false);
    const selected_goal = if (request.selected_goal_index) |index|
        request.active_goals[index].selector
    else
        null;
    const range_columns = SessionRangeColumns.resolve(
        request.filters,
        selected_goal,
    );
    const include_person = hasPersonClause(request.filters.clauses) or
        request.profile_person_key != null;
    const include_engagement = hasSessionFieldClause(
        request.filters.clauses,
        .session_engagement_ms,
    );
    const include_converted = hasSessionFieldClause(
        request.filters.clauses,
        .session_converted,
    );
    var builder = Builder.init(allocator);
    if (request.strict_traffic_mode) {
        var goals: [analysis.maximum_active_goals]traffic.Goal = undefined;
        for (request.active_goals, 0..) |goal, index| goals[index] = .{
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
            request.site_id,
            goals[0..request.active_goals.len],
            true,
        ));
        try builder.write(", ");
    } else try builder.write("WITH ");
    try builder.write(
        "range_events AS NOT MATERIALIZED (SELECT e.session_id, e.kind",
    );
    if (range_columns.event_name) try builder.write(", e.event_name");
    if (range_columns.path) try builder.write(", e.path");
    if (range_columns.page_title) try builder.write(", e.page_title");
    if (range_columns.hostname) try builder.write(", e.hostname");
    if (range_columns.referrer) try builder.write(", e.referrer_host AS referrer");
    if (range_columns.country) try builder.write(", e.country_code AS country");
    if (range_columns.language) try builder.write(", e.language");
    if (range_columns.device) try builder.write(", e.device_category AS device");
    if (range_columns.browser) try builder.write(", e.browser_family AS browser");
    if (range_columns.operating_system) try builder.write(", e.os_family AS operating_system");
    if (range_columns.utm_source) try builder.write(", e.utm_source");
    if (range_columns.utm_medium) try builder.write(", e.utm_medium");
    if (range_columns.utm_campaign) try builder.write(", e.utm_campaign");
    if (range_columns.utm_term) try builder.write(", e.utm_term");
    if (range_columns.utm_content) try builder.write(", e.utm_content");
    if (range_columns.properties) try builder.write(", e.properties_json");
    if (include_person) try builder.write(
        ", e.identity_quality, CASE" ++
            " WHEN e.identity_quality = 1" ++
            " AND COALESCE(l.user_id, e.user_id, '') <> ''" ++
            " THEN 'u:' || COALESCE(l.user_id, e.user_id)" ++
            " WHEN e.identity_quality = 1" ++
            " THEN 'a:' || CAST(e.anonymous_id AS VARCHAR)" ++
            " WHEN e.identity_quality = 2" ++
            " THEN 'e:' || CAST(e.anonymous_id AS VARCHAR)" ++
            " WHEN e.identity_quality = 3" ++
            " THEN 'l:' || CAST(e.anonymous_id AS VARCHAR)" ++
            " ELSE NULL END AS person_key",
    );
    try builder.write(" FROM events e");
    if (include_person) try builder.write(
        " LEFT JOIN identity_links l ON l.site_id = e.site_id" ++
            " AND l.anonymous_id = e.anonymous_id",
    );
    try builder.write(" WHERE e.site_id = ");
    try builder.bindText(request.site_id);
    try builder.write(" AND e.site_local_date BETWEEN CAST(");
    try builder.bindText(request.range.start);
    try builder.write(" AS DATE) AND CAST(");
    try builder.bindText(request.range.end);
    try builder.write(
        " AS DATE) AND e.kind IN (1, 2)" ++
            " AND e.traffic_class IN (1, 5))," ++
            " base AS NOT MATERIALIZED (SELECT * FROM range_events)," ++
            " range_sessions AS NOT MATERIALIZED" ++
            " (SELECT DISTINCT session_id FROM base)," ++
            " session_events AS NOT MATERIALIZED" ++
            " (SELECT e.session_id, e.kind, e.occurred_at_utc_micros," ++
            " e.sequence, e.received_at_utc_micros, e.event_id",
    );
    if (include_engagement) try builder.write(", e.engagement_ms");
    if (session_columns.landing_page or session_columns.exit_page or
        include_converted)
    {
        try builder.write(", e.path");
    }
    if (include_converted) try builder.write(", e.event_name, e.properties_json");
    if (session_columns.referrer) try builder.write(", e.referrer_host");
    if (session_columns.utm_source) try builder.write(", e.utm_source");
    if (session_columns.utm_medium) try builder.write(", e.utm_medium");
    if (session_columns.utm_campaign) try builder.write(", e.utm_campaign");
    if (session_columns.utm_term) try builder.write(", e.utm_term");
    if (session_columns.utm_content) try builder.write(", e.utm_content");
    if (session_columns.country) try builder.write(", e.country_code");
    if (session_columns.language) try builder.write(", e.language");
    if (session_columns.device) try builder.write(", e.device_category");
    if (session_columns.browser) try builder.write(", e.browser_family");
    if (session_columns.operating_system) try builder.write(", e.os_family");
    try builder.write(
        " FROM events e JOIN range_sessions r" ++
            " ON r.session_id = e.session_id WHERE e.site_id = ",
    );
    try builder.bindText(request.site_id);
    try builder.write(
        " AND e.traffic_class IN (1, 5))," ++
            " session_summary AS NOT MATERIALIZED" ++
            " (SELECT session_id",
    );
    if (session_columns.landing_page) try writeSessionFirst(
        &builder,
        "path",
        "landing_page",
        "''",
        "= 1",
        false,
    );
    if (session_columns.exit_page) try writeSessionFirst(
        &builder,
        "path",
        "exit_page",
        "''",
        "= 1",
        true,
    );
    if (session_columns.referrer) try writeSessionFirst(
        &builder,
        "referrer_host",
        "referrer",
        "''",
        "= 1",
        false,
    );
    if (session_columns.utm_source) try writeSessionFirst(
        &builder,
        "utm_source",
        "utm_source",
        "''",
        "= 1",
        false,
    );
    if (session_columns.utm_medium) try writeSessionFirst(
        &builder,
        "utm_medium",
        "utm_medium",
        "''",
        "= 1",
        false,
    );
    if (session_columns.utm_campaign) try writeSessionFirst(
        &builder,
        "utm_campaign",
        "utm_campaign",
        "''",
        "= 1",
        false,
    );
    if (session_columns.utm_term) try writeSessionFirst(
        &builder,
        "utm_term",
        "utm_term",
        "''",
        "= 1",
        false,
    );
    if (session_columns.utm_content) try writeSessionFirst(
        &builder,
        "utm_content",
        "utm_content",
        "''",
        "= 1",
        false,
    );
    if (session_columns.country) try writeSessionFirst(
        &builder,
        "country_code",
        "country",
        "'ZZ'",
        "IN (1, 2)",
        false,
    );
    if (session_columns.language) try writeSessionFirst(
        &builder,
        "language",
        "language",
        "''",
        "IN (1, 2)",
        false,
    );
    if (session_columns.device) try writeSessionFirst(
        &builder,
        "device_category",
        "device",
        "'unknown'",
        "IN (1, 2)",
        false,
    );
    if (session_columns.browser) try writeSessionFirst(
        &builder,
        "browser_family",
        "browser",
        "'Unknown'",
        "IN (1, 2)",
        false,
    );
    if (session_columns.operating_system) try writeSessionFirst(
        &builder,
        "os_family",
        "operating_system",
        "'Unknown'",
        "IN (1, 2)",
        false,
    );
    try builder.write(
        ", min(occurred_at_utc_micros) AS first_at," ++
            " max(occurred_at_utc_micros) AS last_at",
    );
    if (include_engagement) try builder.write(
        ", COALESCE(sum(engagement_ms), 0)::BIGINT AS engagement_ms",
    );
    if (include_converted) {
        try builder.write(", bool_or(CASE WHEN kind IN (1, 2) THEN ");
        try writeAnyGoalMatch(&builder, request.active_goals, "session_events");
        try builder.write(" ELSE FALSE END) AS converted");
    }
    try builder.write(
        " FROM session_events GROUP BY session_id)," ++
            " session_facts AS NOT MATERIALIZED (SELECT st.session_id",
    );
    if (session_columns.landing_page) try builder.write(", st.landing_page");
    if (session_columns.exit_page) try builder.write(", st.exit_page");
    if (session_columns.referrer) try builder.write(", st.referrer");
    if (session_columns.utm_source) try builder.write(", st.utm_source");
    if (session_columns.utm_medium) try builder.write(", st.utm_medium");
    if (session_columns.utm_campaign) try builder.write(", st.utm_campaign");
    if (session_columns.utm_term) try builder.write(", st.utm_term");
    if (session_columns.utm_content) try builder.write(", st.utm_content");
    if (session_columns.country) try builder.write(", st.country");
    if (session_columns.language) try builder.write(", st.language");
    if (session_columns.device) try builder.write(", st.device");
    if (session_columns.browser) try builder.write(", st.browser");
    if (session_columns.operating_system) try builder.write(", st.operating_system");
    if (session_columns.channel) try builder.write(
        ", CASE WHEN st.utm_source = '' AND st.utm_medium = ''" ++
            " AND st.referrer = '' THEN 'Direct'" ++
            " WHEN lower(st.utm_medium) IN ('cpc', 'ppc', 'paidsearch')" ++
            " THEN 'Paid Search'" ++
            " WHEN lower(st.utm_medium) = 'organic' THEN 'Organic Search'" ++
            " WHEN lower(st.utm_medium) IN" ++
            " ('social', 'social-network', 'social-media', 'sm') THEN 'Social'" ++
            " WHEN lower(st.utm_medium) = 'email' THEN 'Email'" ++
            " WHEN lower(st.utm_medium) = 'referral' OR" ++
            " (st.referrer <> '' AND st.utm_source = ''" ++
            " AND st.utm_medium = '') THEN 'Referral'" ++
            " ELSE 'Other / Unknown' END AS channel",
    );
    try builder.write(
        ", st.first_at, st.last_at," ++
            " greatest(0, (st.last_at - st.first_at) / 1000)::BIGINT" ++
            " AS duration_ms",
    );
    if (include_engagement) try builder.write(", st.engagement_ms");
    if (include_converted) try builder.write(", st.converted");
    try builder.write(" FROM session_summary st)");
    if (hasUserTraitClause(request.filters.clauses)) {
        try writePersonTraits(
            &builder,
            request.site_id,
            request.strict_traffic_mode,
            false,
        );
    }
    const has_row_qualification = request.filters.clauses.len != 0 or
        selected_goal != null or request.profile_person_key != null;
    if (has_row_qualification) {
        try builder.write(
            ", qualified_sessions AS (SELECT DISTINCT e.session_id," ++
                " s.first_at FROM base e JOIN session_facts s" ++
                " USING (session_id) WHERE TRUE",
        );
        for (request.filters.clauses) |clause| {
            try builder.write(" AND ");
            try writeClause(&builder, clause, "e", "s");
        }
        if (request.profile_person_key) |person_key| {
            try builder.write(" AND e.person_key = ");
            try builder.bindText(person_key);
        }
        if (request.strict_traffic_mode) try builder.write(
            " AND e.session_id NOT IN (SELECT session_id" ++
                " FROM d34_current_suspected_sessions)",
        );
        if (selected_goal) |selector| {
            try builder.write(
                " AND EXISTS (SELECT 1 FROM base sg" ++
                    " WHERE sg.session_id = e.session_id AND ",
            );
            try writeSelector(&builder, selector, "sg");
            try builder.write(")");
        }
        try builder.write(
            ") SELECT CAST(q.session_id AS VARCHAR), q.first_at" ++
                " FROM qualified_sessions q ORDER BY q.first_at DESC," ++
                " q.session_id ASC",
        );
    } else {
        try builder.write(
            " SELECT CAST(s.session_id AS VARCHAR), s.first_at" ++
                " FROM session_facts s WHERE TRUE",
        );
        if (request.strict_traffic_mode) try builder.write(
            " AND s.session_id NOT IN (SELECT session_id" ++
                " FROM d34_current_suspected_sessions)",
        );
        try builder.write(" ORDER BY s.first_at DESC, s.session_id ASC");
    }
    try builder.write(" LIMIT ");
    try builder.bindInteger(@as(i64, analysis.session_page_size) + 1);
    try builder.write(" OFFSET ");
    try builder.bindInteger(try request.offset());
    return builder.finish();
}

fn compileSessionDetails(
    allocator: std.mem.Allocator,
    request: SessionSummaryRequest,
    keys: []const SessionKey,
) !StatementPlan {
    try request.validate();
    if (keys.len == 0 or keys.len > analysis.session_page_size) {
        return error.InvalidSessionListResult;
    }
    var builder = Builder.init(allocator);
    try builder.write("WITH page_sessions(position, session_id) AS (VALUES ");
    for (keys, 0..) |key, index| {
        domain.validateUuid(key.id) catch return error.InvalidSessionListResult;
        if (index != 0) try builder.write(", ");
        try builder.write("(");
        try builder.bindInteger(@intCast(index));
        try builder.write("::BIGINT, CAST(");
        try builder.bindText(key.id);
        try builder.write(" AS UUID))");
    }
    try builder.write(
        "), session_events AS NOT MATERIALIZED" ++
            " (SELECT p.position, e.session_id, e.kind, e.event_name, e.path," ++
            " e.referrer_host, e.utm_source, e.utm_medium, e.utm_campaign," ++
            " e.country_code, e.device_category, e.browser_family," ++
            " e.properties_json, e.value_amount, e.value_currency," ++
            " e.engagement_ms, e.occurred_at_utc_micros, e.sequence," ++
            " e.received_at_utc_micros, e.event_id," ++
            " CASE WHEN e.identity_quality = 1" ++
            " AND COALESCE(l.user_id, e.user_id, '') <> ''" ++
            " THEN 'u:' || COALESCE(l.user_id, e.user_id)" ++
            " WHEN e.identity_quality = 1" ++
            " THEN 'a:' || CAST(e.anonymous_id AS VARCHAR)" ++
            " WHEN e.identity_quality = 2" ++
            " THEN 'e:' || CAST(e.anonymous_id AS VARCHAR)" ++
            " WHEN e.identity_quality = 3" ++
            " THEN 'l:' || CAST(e.anonymous_id AS VARCHAR)" ++
            " ELSE NULL END AS person_key" ++
            " FROM events e JOIN page_sessions p" ++
            " ON p.session_id = e.session_id" ++
            " LEFT JOIN identity_links l ON l.site_id = e.site_id" ++
            " AND l.anonymous_id = e.anonymous_id WHERE e.site_id = ",
    );
    try builder.bindText(request.site_id);
    try builder.write(
        " AND e.traffic_class IN (1, 5))," ++
            " session_summary AS MATERIALIZED" ++
            " (SELECT position, session_id," ++
            " first(person_key ORDER BY occurred_at_utc_micros, sequence," ++
            " received_at_utc_micros, event_id)" ++
            " FILTER (WHERE kind IN (1, 2)) AS person_key",
    );
    try writeSessionFirst(
        &builder,
        "path",
        "landing_page",
        "''",
        "= 1",
        false,
    );
    try writeSessionFirst(
        &builder,
        "referrer_host",
        "referrer",
        "''",
        "= 1",
        false,
    );
    try writeSessionFirst(
        &builder,
        "utm_source",
        "utm_source",
        "''",
        "= 1",
        false,
    );
    try writeSessionFirst(
        &builder,
        "utm_medium",
        "utm_medium",
        "''",
        "= 1",
        false,
    );
    try writeSessionFirst(
        &builder,
        "utm_campaign",
        "utm_campaign",
        "''",
        "= 1",
        false,
    );
    try writeSessionFirst(
        &builder,
        "country_code",
        "country",
        "'ZZ'",
        "IN (1, 2)",
        false,
    );
    try writeSessionFirst(
        &builder,
        "device_category",
        "device",
        "'unknown'",
        "IN (1, 2)",
        false,
    );
    try writeSessionFirst(
        &builder,
        "browser_family",
        "browser",
        "'Unknown'",
        "IN (1, 2)",
        false,
    );
    try builder.write(
        ", min(occurred_at_utc_micros)::BIGINT AS first_at," ++
            " max(occurred_at_utc_micros)::BIGINT AS last_at," ++
            " max(received_at_utc_micros)::BIGINT AS last_received," ++
            " count(*) FILTER (WHERE kind = 1)::BIGINT AS page_views," ++
            " count(*) FILTER (WHERE kind = 2)::BIGINT AS custom_events," ++
            " COALESCE(sum(engagement_ms), 0)::BIGINT AS engagement_ms," ++
            " sum(CASE WHEN kind IN (1, 2) THEN ",
    );
    try writeGoalMatchCount(&builder, request.active_goals, "session_events");
    try builder.write(
        " ELSE 0 END)::BIGINT AS conversions" ++
            " FROM session_events GROUP BY position, session_id)," ++
            " session_rows AS MATERIALIZED" ++
            " (SELECT s.position, CAST(s.session_id AS VARCHAR) AS session_id," ++
            " s.person_key, s.first_at, s.last_at, s.last_received," ++
            " s.landing_page," ++
            " CASE WHEN s.utm_source = '' AND s.utm_medium = ''" ++
            " AND s.referrer = '' THEN 'Direct'" ++
            " WHEN lower(s.utm_medium) IN ('cpc', 'ppc', 'paidsearch')" ++
            " THEN 'Paid Search'" ++
            " WHEN lower(s.utm_medium) = 'organic' THEN 'Organic Search'" ++
            " WHEN lower(s.utm_medium) IN" ++
            " ('social', 'social-network', 'social-media', 'sm') THEN 'Social'" ++
            " WHEN lower(s.utm_medium) = 'email' THEN 'Email'" ++
            " WHEN lower(s.utm_medium) = 'referral' OR" ++
            " (s.referrer <> '' AND s.utm_source = ''" ++
            " AND s.utm_medium = '') THEN 'Referral'" ++
            " ELSE 'Other / Unknown' END AS channel," ++
            " s.referrer, s.utm_source, s.utm_campaign, s.country, s.device," ++
            " s.browser," ++
            " greatest(0, (s.last_at - s.first_at) / 1000)::BIGINT" ++
            " AS duration_ms, s.engagement_ms, s.page_views," ++
            " s.custom_events, s.conversions FROM session_summary s)," ++
            " revenue_rows AS (SELECT position," ++
            " CAST(session_id AS VARCHAR) AS session_id, value_currency," ++
            " CAST(sum(value_amount) AS VARCHAR) AS amount," ++
            " count(*)::BIGINT AS value_count," ++
            " row_number() OVER (PARTITION BY position" ++
            " ORDER BY value_currency ASC)::BIGINT AS currency_position" ++
            " FROM session_events WHERE kind IN (1, 2)" ++
            " AND value_amount IS NOT NULL AND value_currency <> ''" ++
            " GROUP BY position, session_id, value_currency)" ++
            " SELECT * FROM (SELECT 'session' AS section, position, session_id," ++
            " person_key, first_at, last_at, last_received, landing_page," ++
            " channel, referrer, utm_source, utm_campaign, country, device," ++
            " browser, duration_ms, engagement_ms, page_views, custom_events," ++
            " conversions, CAST(NULL AS VARCHAR) AS amount, '' AS currency," ++
            " 0::BIGINT AS value_count, 0::BIGINT AS currency_position" ++
            " FROM session_rows UNION ALL SELECT 'revenue', position," ++
            " session_id, '', 0::BIGINT, 0::BIGINT, 0::BIGINT, '', '', ''," ++
            " '', '', '', '', '', 0::BIGINT, 0::BIGINT, 0::BIGINT," ++
            " 0::BIGINT, 0::BIGINT, amount, value_currency, value_count," ++
            " currency_position FROM revenue_rows WHERE currency_position <= ",
    );
    try builder.bindInteger(@as(i64, analysis.maximum_currency_series) + 1);
    try builder.write(
        ") result ORDER BY position," ++
            " CASE section WHEN 'session' THEN 0 ELSE 1 END," ++
            " currency_position",
    );
    return builder.finish();
}

fn hasPersonClause(clauses: []const analysis.Clause) bool {
    for (clauses) |clause| {
        if (clause.scope == .person) return true;
    }
    return false;
}

fn hasSessionFieldClause(
    clauses: []const analysis.Clause,
    field: analysis.FieldKind,
) bool {
    for (clauses) |clause| {
        if (clause.scope == .session and clause.field.kind == field) return true;
    }
    return false;
}

pub fn profileGoalResult(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: analysis.GoalResultRequest,
) ![]u8 {
    try request.validate();
    var output = std.Io.Writer.Allocating.init(allocator);
    try output.writer.writeAll("GOAL RESULT STATEMENT\n");
    try profileOverviewPlan(
        allocator,
        event_store,
        try compileGoalResult(allocator, request),
        &output.writer,
    );
    return output.toOwnedSlice();
}

pub fn executeFunnelAvailability(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: analysis.FunnelAvailabilityRequest,
) ![]const analysis.FunnelAvailabilityRow {
    try request.validate();
    var budget = deadline.Budget.init(request.timeout_ms);
    return executeFunnelAvailabilityWithBudget(
        allocator,
        event_store,
        request,
        &budget,
    );
}

fn executeFunnelAvailabilityWithBudget(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: analysis.FunnelAvailabilityRequest,
    budget: *deadline.Budget,
) ![]const analysis.FunnelAvailabilityRow {
    var result = try executePlan(
        &event_store.database,
        try compileFunnelAvailability(allocator, request),
        budget,
    );
    defer result.deinit();
    if (result.columnCount() != 2 or result.rowCount() != request.selectors.len) {
        return error.InvalidFunnelAvailability;
    }
    const rows = try allocator.alloc(
        analysis.FunnelAvailabilityRow,
        request.selectors.len,
    );
    errdefer allocator.free(rows);
    for (rows, 0..) |*row, index| {
        const step_index = result.int64(0, index);
        const matching_events = result.int64(1, index);
        if (step_index != @as(i64, @intCast(index)) or matching_events < 0) {
            return error.InvalidFunnelAvailability;
        }
        row.* = .{
            .step_index = @intCast(step_index),
            .matching_events = matching_events,
        };
    }
    return rows;
}

pub fn executeFunnelResult(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: funnel.ResultRequest,
) !funnel.Result {
    try request.validate();
    var budget = deadline.Budget.init(request.timeout_ms);
    return executeFunnelResultWithBudget(allocator, event_store, request, &budget);
}

pub fn executeFunnelPreview(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: funnel.ResultRequest,
) !funnel.PreviewResult {
    try request.validate();
    var budget = deadline.Budget.init(request.timeout_ms);
    const availability = try executeFunnelAvailabilityWithBudget(
        allocator,
        event_store,
        .{
            .site_id = request.site_id,
            .range = request.range,
            .selectors = request.selectors,
            .filters = request.filters,
            .active_goals = request.active_goals,
            .strict_traffic_mode = request.strict_traffic_mode,
            .timeout_ms = request.timeout_ms,
        },
        &budget,
    );
    return .{
        .availability = availability,
        .result = try executeFunnelResultWithBudget(
            allocator,
            event_store,
            request,
            &budget,
        ),
    };
}

pub fn profileFunnelResult(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: funnel.ResultRequest,
) ![]u8 {
    try request.validate();
    var output = std.Io.Writer.Allocating.init(allocator);
    try output.writer.writeAll("FUNNEL ORDERED RESULT STATEMENT\n");
    try profileOverviewPlan(
        allocator,
        event_store,
        try compileFunnelResult(allocator, request, request.range),
        &output.writer,
    );
    if (request.comparison_range) |range| {
        try output.writer.writeAll("FUNNEL ORDERED COMPARISON STATEMENT\n");
        try profileOverviewPlan(
            allocator,
            event_store,
            try compileFunnelResult(allocator, request, range),
            &output.writer,
        );
    }
    return output.toOwnedSlice();
}

pub fn profileFunnelAvailability(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: analysis.FunnelAvailabilityRequest,
) ![]u8 {
    try request.validate();
    var output = std.Io.Writer.Allocating.init(allocator);
    try output.writer.writeAll("FUNNEL SELECTOR AVAILABILITY STATEMENT\n");
    try profileOverviewPlan(
        allocator,
        event_store,
        try compileFunnelAvailability(allocator, request),
        &output.writer,
    );
    return output.toOwnedSlice();
}

fn executeFunnelResultWithBudget(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: funnel.ResultRequest,
    budget: *deadline.Budget,
) !funnel.Result {
    const current = try executeFunnelRun(
        allocator,
        event_store,
        request,
        request.range,
        budget,
    );
    const comparison = if (request.comparison_range) |range|
        try executeFunnelRun(allocator, event_store, request, range, budget)
    else
        null;
    return .{ .current = current, .comparison = comparison };
}

fn executeFunnelRun(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: funnel.ResultRequest,
    range: analysis.LocalDateRange,
    budget: *deadline.Budget,
) !funnel.Run {
    var result = try executePlan(
        &event_store.database,
        try compileFunnelResult(allocator, request, range),
        budget,
    );
    defer result.deinit();
    if (result.columnCount() != 7 or
        result.rowCount() != request.selectors.len)
    {
        return error.InvalidFunnelResult;
    }
    const steps = try allocator.alloc(funnel.ResultStep, request.selectors.len);
    errdefer allocator.free(steps);
    var median_total: ?i64 = null;
    var persistent: i64 = -1;
    var ephemeral: i64 = -1;
    var legacy: i64 = -1;
    for (steps, 0..) |*step, index| {
        const step_index = result.int64(0, index);
        const participants = result.int64(1, index);
        const row_persistent = result.int64(4, index);
        const row_ephemeral = result.int64(5, index);
        const row_legacy = result.int64(6, index);
        if (step_index != @as(i64, @intCast(index)) or participants < 0 or
            (index == 0 and !result.isNull(2, index)) or
            (index != 0 and participants != 0 and result.isNull(2, index)) or
            row_persistent < -1 or row_ephemeral < -1 or row_legacy < -1)
        {
            return error.InvalidFunnelResult;
        }
        if (index == 0) {
            persistent = row_persistent;
            ephemeral = row_ephemeral;
            legacy = row_legacy;
        } else if (persistent != row_persistent or ephemeral != row_ephemeral or
            legacy != row_legacy)
        {
            return error.InvalidFunnelResult;
        }
        step.* = .{
            .step_index = @intCast(step_index),
            .participants = participants,
            .median_from_prior_micros = if (result.isNull(2, index))
                null
            else
                result.int64(2, index),
        };
        if (index + 1 == steps.len) {
            median_total = if (result.isNull(3, index))
                null
            else
                result.int64(3, index);
        } else if (!result.isNull(3, index)) {
            return error.InvalidFunnelResult;
        }
    }
    const run = funnel.Run{
        .entrants = steps[0].participants,
        .completions = steps[steps.len - 1].participants,
        .median_total_micros = median_total,
        .steps = steps,
        .identity_coverage = if (request.scope == .visitors)
            .{
                .persistent_step_one = persistent,
                .ephemeral_step_one = ephemeral,
                .legacy_step_one = legacy,
            }
        else
            null,
    };
    try run.validate(request.selectors.len, request.scope);
    return run;
}

fn executeGoalResultWithBudget(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: analysis.GoalResultRequest,
    budget: *deadline.Budget,
) !analysis.GoalResult {
    var result = try executePlan(
        &event_store.database,
        try compileGoalResult(allocator, request),
        budget,
    );
    defer result.deinit();
    if (result.columnCount() != 12 or
        result.rowCount() == 0 or
        result.rowCount() > 2 + analysis.maximum_currency_series +
            analysis.maximum_goal_path_rows)
    {
        return error.InvalidGoalResult;
    }
    var summary_seen = false;
    var total_matches: i64 = 0;
    var converting_visitors: i64 = 0;
    var converting_sessions: i64 = 0;
    var eligible_visitors: i64 = 0;
    var eligible_sessions: i64 = 0;
    var persistent: i64 = 0;
    var ephemeral: i64 = 0;
    var legacy: i64 = 0;
    var path_cardinality: i64 = 0;
    var revenue: std.ArrayList(analysis.ExactAmount) = .empty;
    var paths: std.ArrayList(analysis.GoalPathRow) = .empty;
    var previous_currency: ?[]const u8 = null;
    var previous_path: ?analysis.GoalPathRow = null;
    var revenue_value_count: i64 = 0;
    var shown_path_matches: i64 = 0;
    for (0..result.rowCount()) |row| {
        const section = try result.text(allocator, 0, row);
        if (std.mem.eql(u8, section, "summary")) {
            if (summary_seen) return error.InvalidGoalResult;
            summary_seen = true;
            total_matches = result.int64(2, row);
            converting_visitors = result.int64(3, row);
            converting_sessions = result.int64(4, row);
            eligible_visitors = result.int64(5, row);
            eligible_sessions = result.int64(6, row);
            persistent = result.int64(7, row);
            ephemeral = result.int64(8, row);
            legacy = result.int64(9, row);
            path_cardinality = result.int64(10, row);
        } else if (std.mem.eql(u8, section, "revenue")) {
            const value_count = result.int64(2, row);
            const decimal = try result.text(allocator, 1, row);
            const currency = try result.text(allocator, 11, row);
            const number_type = property.numberType(decimal) catch
                return error.InvalidGoalResult;
            if (value_count <= 0 or number_type != .decimal) {
                return error.InvalidGoalResult;
            }
            domain.validateCurrency(currency) catch return error.InvalidGoalResult;
            if (previous_currency) |previous| if (std.mem.order(
                u8,
                previous,
                currency,
            ) != .lt) return error.InvalidGoalResult;
            previous_currency = currency;
            revenue_value_count = std.math.add(
                i64,
                revenue_value_count,
                value_count,
            ) catch return error.InvalidGoalResult;
            try revenue.append(allocator, .{
                .decimal = decimal,
                .currency = currency,
                .value_count = value_count,
            });
        } else if (std.mem.eql(u8, section, "path")) {
            const matches = result.int64(2, row);
            const position = result.int64(3, row);
            const path = try result.text(allocator, 1, row);
            if (matches <= 0 or path.len == 0 or
                position != @as(i64, @intCast(paths.items.len + 1)))
            {
                return error.InvalidGoalResult;
            }
            if (previous_path) |previous| if (previous.matches < matches or
                (previous.matches == matches and
                    std.mem.order(u8, previous.path, path) != .lt))
            {
                return error.InvalidGoalResult;
            };
            shown_path_matches = std.math.add(
                i64,
                shown_path_matches,
                matches,
            ) catch return error.InvalidGoalResult;
            const item = analysis.GoalPathRow{ .path = path, .matches = matches };
            try paths.append(allocator, item);
            previous_path = item;
        } else return error.InvalidGoalResult;
    }
    if (revenue.items.len > analysis.maximum_currency_series) {
        return error.TooManyAnalysisCurrencies;
    }
    if (!summary_seen or total_matches < 0 or converting_visitors < 0 or
        converting_sessions < 0 or eligible_visitors < 0 or
        eligible_sessions < 0 or persistent < 0 or ephemeral < 0 or
        legacy < 0 or path_cardinality < 0)
    {
        return error.InvalidGoalResult;
    }
    const expected_path_rows: usize = @intCast(@min(
        path_cardinality,
        @as(i64, analysis.maximum_goal_path_rows),
    ));
    if (converting_visitors > eligible_visitors or
        converting_sessions > eligible_sessions or
        converting_visitors > total_matches or
        converting_sessions > total_matches or
        persistent + ephemeral + legacy != converting_visitors or
        revenue_value_count > total_matches or
        shown_path_matches > total_matches or
        paths.items.len != expected_path_rows or
        (path_cardinality <= @as(i64, analysis.maximum_goal_path_rows) and
            shown_path_matches != total_matches) or
        ((total_matches == 0) != (path_cardinality == 0)))
    {
        return error.InvalidGoalResult;
    }
    const persistent_scaled = std.math.mul(i64, persistent, 10_000) catch
        return error.InvalidGoalResult;
    return .{
        .total_matches = total_matches,
        .converting_visitors = converting_visitors,
        .converting_sessions = converting_sessions,
        .eligible_visitors = eligible_visitors,
        .eligible_sessions = eligible_sessions,
        .converting_coverage = .{
            .total_people = converting_visitors,
            .persistent_people = persistent,
            .ephemeral_people = ephemeral,
            .legacy_people = legacy,
            .persistent_basis_points = if (converting_visitors == 0)
                0
            else
                @intCast(@divTrunc(persistent_scaled, converting_visitors)),
            .persistent_since_local_date = null,
        },
        .revenue = try revenue.toOwnedSlice(allocator),
        .paths = try paths.toOwnedSlice(allocator),
        .path_cardinality = path_cardinality,
    };
}

pub fn compileGoalDiscovery(
    allocator: std.mem.Allocator,
    request: analysis.GoalDiscoveryRequest,
) !StatementPlan {
    try request.validate();
    const query = analysis.Query{
        .site_id = request.site_id,
        .range = request.range,
        .mode = .breakdown,
        .metric = .{ .kind = if (request.kind == .page)
            .page_views
        else
            .custom_events },
        .dimension = .{ .kind = if (request.kind == .page)
            .page
        else
            .event_name },
        .sort = .value_desc,
        .limit = 50,
    };
    const execution = analysis.Execution{
        .query = query,
        .active_goals = request.active_goals,
        .strict_traffic_mode = request.strict_traffic_mode,
        .timeout_ms = request.timeout_ms,
    };
    try execution.validate();
    try validateCombination(query);
    var builder = Builder.init(allocator);
    try writeCommon(&builder, execution, request.range, false, false);
    const expression = if (request.kind == .page) "e.path" else "e.event_name";
    try builder.write(", discovered AS (SELECT ");
    try builder.write(expression);
    try builder.write(
        " AS label, count(*)::BIGINT AS eligible_count," ++
            " max(e.received_at_utc_micros)::BIGINT AS last_received" ++
            " FROM qualified e WHERE e.kind = ",
    );
    try builder.bindInteger(if (request.kind == .page) 1 else 2);
    try builder.write(" AND ");
    try builder.write(expression);
    try builder.write(" <> ''");
    if (request.search.len != 0) {
        try builder.write(" AND contains(lower(");
        try builder.write(expression);
        try builder.write("), lower(");
        try builder.bindText(request.search);
        try builder.write("))");
    }
    try builder.write(" GROUP BY ");
    try builder.write(expression);
    try builder.write(
        ") SELECT label, eligible_count, last_received FROM discovered" ++
            " ORDER BY eligible_count DESC, label ASC LIMIT 51 OFFSET ",
    );
    const offset = (@as(i64, request.page) - 1) * 50;
    try builder.bindInteger(offset);
    return builder.finish();
}

pub fn compileGoalResult(
    allocator: std.mem.Allocator,
    request: analysis.GoalResultRequest,
) !StatementPlan {
    try request.validate();
    const execution = request.execution();
    try execution.validate();
    var builder = Builder.init(allocator);
    if (execution.query.filters.clauses.len == 0) {
        try writeCompactGoalCommon(&builder, execution, request.range);
    } else {
        try writeCommon(&builder, execution, request.range, false, false);
    }
    try builder.write(
        ", matched AS MATERIALIZED (SELECT e.person_key, e.session_id," ++
            " e.identity_quality, e.path, e.value_amount, e.value_currency" ++
            " FROM qualified e WHERE ",
    );
    try writeSelector(&builder, request.selector, "e");
    try builder.write(
        "), eligible AS (SELECT count(DISTINCT person_key)::BIGINT" ++
            " AS eligible_visitors, count(DISTINCT session_id)::BIGINT" ++
            " AS eligible_sessions FROM qualified)," ++
            " matched_summary AS (SELECT count(*)::BIGINT AS total_matches," ++
            " count(DISTINCT person_key)::BIGINT AS converting_visitors," ++
            " count(DISTINCT session_id)::BIGINT AS converting_sessions," ++
            " count(DISTINCT person_key) FILTER (WHERE identity_quality = 1)" ++
            "::BIGINT AS persistent," ++
            " count(DISTINCT person_key) FILTER (WHERE identity_quality = 2)" ++
            "::BIGINT AS ephemeral," ++
            " count(DISTINCT person_key) FILTER (WHERE identity_quality = 3)" ++
            "::BIGINT AS legacy," ++
            " count(DISTINCT COALESCE(NULLIF(path, ''), '(not set)'))::BIGINT" ++
            " AS path_cardinality FROM matched)," ++
            " summary AS (SELECT matched_summary.*, eligible.*" ++
            " FROM matched_summary CROSS JOIN eligible)," ++
            " revenue_rows AS (SELECT value_currency AS currency," ++
            " CAST(sum(value_amount) AS VARCHAR) AS amount," ++
            " count(*)::BIGINT AS value_count FROM matched" ++
            " WHERE value_amount IS NOT NULL AND value_currency <> ''" ++
            " GROUP BY value_currency ORDER BY value_currency LIMIT ",
    );
    try builder.bindInteger(@as(i64, analysis.maximum_currency_series) + 1);
    try builder.write(
        "), path_counts AS (SELECT COALESCE(NULLIF(path, ''), '(not set)')" ++
            " AS path, count(*)::BIGINT AS matches FROM matched GROUP BY path)," ++
            " path_rows AS (SELECT path, matches," ++
            " row_number() OVER (ORDER BY matches DESC, path ASC)::BIGINT" ++
            " AS position FROM path_counts ORDER BY matches DESC, path ASC LIMIT ",
    );
    try builder.bindInteger(analysis.maximum_goal_path_rows);
    try builder.write(
        ") SELECT 'summary' AS section, '' AS label," ++
            " total_matches AS n1, converting_visitors AS n2," ++
            " converting_sessions AS n3, eligible_visitors AS n4," ++
            " eligible_sessions AS n5, persistent AS n6, ephemeral AS n7," ++
            " legacy AS n8, path_cardinality AS n9, '' AS currency" ++
            " FROM summary UNION ALL SELECT 'revenue', amount, value_count," ++
            " 0::BIGINT, 0::BIGINT, 0::BIGINT, 0::BIGINT, 0::BIGINT," ++
            " 0::BIGINT, 0::BIGINT, 0::BIGINT, currency FROM revenue_rows" ++
            " UNION ALL SELECT 'path', path, matches, position, 0::BIGINT," ++
            " 0::BIGINT, 0::BIGINT, 0::BIGINT, 0::BIGINT, 0::BIGINT," ++
            " 0::BIGINT, '' FROM path_rows" ++
            " ORDER BY section, currency, n2, label",
    );
    return builder.finish();
}

pub fn compileGoalPropertyCatalog(
    allocator: std.mem.Allocator,
    request: analysis.GoalResultRequest,
) !StatementPlan {
    try request.validate();
    const execution = request.execution();
    try execution.validate();
    var builder = Builder.init(allocator);
    try writeCommon(&builder, execution, request.range, false, false);
    var base_selector = request.selector;
    base_selector.predicates = &.{};
    try builder.write(
        ", property_events AS (SELECT e.properties_json AS document" ++
            " FROM qualified e WHERE ",
    );
    try writeSelector(&builder, base_selector, "e");
    try builder.write(
        " ORDER BY e.received_at_utc_micros DESC, e.event_id DESC LIMIT ",
    );
    try builder.bindInteger(analysis.maximum_property_catalog_events);
    try builder.write("), ");
    try writePropertyCatalogExpansion(&builder);
    return builder.finish();
}

pub fn compileFunnelAvailability(
    allocator: std.mem.Allocator,
    request: analysis.FunnelAvailabilityRequest,
) !StatementPlan {
    try request.validate();
    const execution = request.execution();
    try execution.validate();
    var builder = Builder.init(allocator);
    try writeCommon(&builder, execution, request.range, false, false);
    try builder.write(", availability_counts AS (SELECT [");
    for (request.selectors, 0..) |selector, index| {
        if (index != 0) try builder.write(", ");
        try builder.write("count(*) FILTER (WHERE ");
        try writeSelector(&builder, selector, "e");
        try builder.write(")::BIGINT");
    }
    try builder.write(
        "] AS counts FROM qualified e)" ++
            " SELECT (generate_subscripts(counts, 1) - 1)::BIGINT" ++
            " AS step_index, unnest(counts)::BIGINT AS matching_events" ++
            " FROM availability_counts ORDER BY step_index",
    );
    return builder.finish();
}

pub fn compileFunnelResult(
    allocator: std.mem.Allocator,
    request: funnel.ResultRequest,
    range: analysis.LocalDateRange,
) !StatementPlan {
    try request.validate();
    try range.validate();
    const execution = request.execution(range);
    try execution.validate();
    const greedy_same_session = request.order == .sequential and
        request.window == .same_session;
    const greedy_sessions = greedy_same_session and request.scope == .sessions;
    var builder = Builder.init(allocator);
    try writeCommon(&builder, execution, range, false, false);
    try builder.write(", funnel_source AS ");
    if (request.scope == .visitors) try builder.write("MATERIALIZED ");
    try builder.write(
        "(SELECT e.session_id, e.person_key, e.identity_quality, e.kind," ++
            " e.event_name, e.path, e.properties_json," ++
            " e.occurred_at_utc_micros, e.sequence," ++
            " e.received_at_utc_micros, e.event_id FROM qualified e)," ++
            " coverage AS (SELECT ",
    );
    if (request.scope == .visitors) {
        inline for (.{ @as(u8, 1), @as(u8, 2), @as(u8, 3) }, 0..) |quality, index| {
            if (index != 0) try builder.write(", ");
            try builder.write("count(DISTINCT person_key) FILTER (WHERE identity_quality = ");
            try builder.bindInteger(quality);
            try builder.write(" AND ");
            try writeSelector(&builder, request.selectors[0], "e");
            try builder.write(")::BIGINT AS ");
            try builder.write(switch (index) {
                0 => "persistent_step_one",
                1 => "ephemeral_step_one",
                2 => "legacy_step_one",
                else => unreachable,
            });
        }
        try builder.write(" FROM funnel_source e" ++
            "), funnel_events AS (SELECT e.*, ");
        if (request.window == .same_session) {
            try builder.write("e.session_id");
        } else {
            try builder.write("e.person_key");
        }
        try builder.write(" AS chain_key, e.person_key AS count_key" ++
            " FROM funnel_source e WHERE e.identity_quality = 1" ++
            " AND e.person_key IS NOT NULL)");
    } else {
        try builder.write(
            "-1::BIGINT AS persistent_step_one," ++
                " -1::BIGINT AS ephemeral_step_one," ++
                " -1::BIGINT AS legacy_step_one" ++
                "), funnel_events AS (SELECT e.*, e.session_id AS chain_key," ++
                " e.session_id AS count_key FROM funnel_source e)",
        );
    }
    try builder.write(
        ", numbered AS MATERIALIZED (SELECT e.chain_key, e.count_key," ++
            " e.occurred_at_utc_micros, e.sequence," ++
            " e.received_at_utc_micros, e.event_id," ++
            " row_number() OVER (PARTITION BY chain_key ORDER BY" ++
            " occurred_at_utc_micros, sequence, received_at_utc_micros," ++
            " event_id) AS position",
    );
    for (request.selectors, 0..) |selector, index| {
        try builder.write(", (");
        try writeSelector(&builder, selector, "e");
        try builder.write(") AS matches_");
        try builder.output.writer.print("{d}", .{index});
    }
    try builder.write(" FROM funnel_events e)");
    for (request.selectors, 0..) |_, index| {
        try builder.write(", candidate_");
        try builder.output.writer.print("{d}", .{index});
        try builder.write(
            " AS (SELECT e.chain_key, e.count_key," ++
                " e.occurred_at_utc_micros, e.sequence," ++
                " e.received_at_utc_micros, e.event_id, e.position",
        );
        try builder.write(" FROM numbered e WHERE e.matches_");
        try builder.output.writer.print("{d}", .{index});
        try builder.write(")");
    }

    for (request.selectors, 0..) |_, index| {
        try builder.write(", step_");
        try builder.output.writer.print("{d}", .{index});
        try builder.write(" AS (SELECT ");
        if (index == 0) {
            if (greedy_same_session) {
                try builder.write(
                    "e.chain_key, e.count_key," ++
                        " arg_min(e.occurred_at_utc_micros, e.position)" ++
                        " AS start_at," ++
                        " arg_min(e.sequence, e.position) AS start_sequence," ++
                        " arg_min(e.received_at_utc_micros, e.position)" ++
                        " AS start_received," ++
                        " arg_min(e.event_id, e.position) AS start_event_id," ++
                        " arg_min(e.occurred_at_utc_micros, e.position)" ++
                        " AS matched_at," ++
                        " arg_min(e.sequence, e.position) AS matched_sequence," ++
                        " arg_min(e.received_at_utc_micros, e.position)" ++
                        " AS matched_received," ++
                        " arg_min(e.event_id, e.position) AS matched_event_id," ++
                        " arg_min(e.occurred_at_utc_micros, e.position)" ++
                        " AS prior_at, min(e.position) AS matched_position" ++
                        " FROM candidate_0 e GROUP BY e.chain_key, e.count_key",
                );
            } else {
                try builder.write(
                    "e.chain_key, e.count_key," ++
                        " e.occurred_at_utc_micros AS start_at," ++
                        " e.sequence AS start_sequence," ++
                        " e.received_at_utc_micros AS start_received," ++
                        " e.event_id AS start_event_id," ++
                        " e.occurred_at_utc_micros AS matched_at," ++
                        " e.sequence AS matched_sequence," ++
                        " e.received_at_utc_micros AS matched_received," ++
                        " e.event_id AS matched_event_id," ++
                        " e.occurred_at_utc_micros AS prior_at," ++
                        " e.position AS matched_position" ++
                        " FROM candidate_0 e",
                );
            }
        } else {
            try builder.write("p.chain_key, p.count_key, p.start_at," ++
                " p.start_sequence, p.start_received, p.start_event_id,");
            if (greedy_same_session) {
                try builder.write(
                    " arg_min(n.occurred_at_utc_micros, n.position)" ++
                        " AS matched_at," ++
                        " arg_min(n.sequence, n.position) AS matched_sequence," ++
                        " arg_min(n.received_at_utc_micros, n.position)" ++
                        " AS matched_received," ++
                        " arg_min(n.event_id, n.position) AS matched_event_id," ++
                        " p.matched_at AS prior_at," ++
                        " min(n.position) AS matched_position FROM step_",
                );
            } else {
                try builder.write(
                    " n.occurred_at_utc_micros AS matched_at," ++
                        " n.sequence AS matched_sequence," ++
                        " n.received_at_utc_micros AS matched_received," ++
                        " n.event_id AS matched_event_id," ++
                        " p.matched_at AS prior_at," ++
                        " n.position AS matched_position FROM step_",
                );
            }
            try builder.output.writer.print("{d}", .{index - 1});
            try builder.write(" p ");
            if (!greedy_same_session and request.order == .sequential) {
                try builder.write("ASOF ");
            }
            try builder.write("JOIN candidate_");
            try builder.output.writer.print("{d}", .{index});
            try builder.write(" n ON n.chain_key = p.chain_key AND n.position ");
            try builder.write(if (request.order == .consecutive) "= " else "> ");
            try builder.write("p.matched_position");
            if (request.order == .consecutive) try builder.write(" + 1");
            if (request.window != .same_session) {
                const window_micros = std.math.mul(
                    i64,
                    request.window.seconds(),
                    std.time.us_per_s,
                ) catch return error.InvalidFunnelWindow;
                try builder.write(" WHERE n.occurred_at_utc_micros" ++
                    " - p.start_at BETWEEN 0 AND ");
                try builder.bindInteger(window_micros);
            }
            if (greedy_same_session) {
                try builder.write(
                    " GROUP BY p.chain_key, p.count_key, p.start_at," ++
                        " p.start_sequence, p.start_received," ++
                        " p.start_event_id, p.matched_at," ++
                        " p.matched_position",
                );
            }
        }
        try builder.write(")");
        try builder.write(", selected_");
        try builder.output.writer.print("{d}", .{index});
        if (greedy_sessions) {
            try builder.write(
                " AS (SELECT count_key, matched_at, prior_at, start_at" ++
                    " FROM step_",
            );
            try builder.output.writer.print("{d}", .{index});
            try builder.write(")");
        } else {
            try builder.write(" AS (SELECT *, row_number() OVER" ++
                " (PARTITION BY count_key ORDER BY matched_at," ++
                " matched_sequence, matched_received, matched_event_id," ++
                " start_at, start_sequence, start_received," ++
                " start_event_id) AS selected FROM step_");
            try builder.output.writer.print("{d}", .{index});
            try builder.write(")");
        }
    }

    try builder.write(" SELECT * FROM (");
    for (request.selectors, 0..) |_, index| {
        if (index != 0) try builder.write(" UNION ALL ");
        try builder.write("SELECT ");
        try builder.bindInteger(@intCast(index));
        try builder.write("::BIGINT AS step_index, count(*)::BIGINT" ++
            " AS participants, ");
        if (index == 0) {
            try builder.write("NULL::BIGINT");
        } else {
            try builder.write(
                "CAST(round(median(matched_at - prior_at)) AS BIGINT)",
            );
        }
        try builder.write(" AS median_from_prior_micros, ");
        if (index + 1 == request.selectors.len) {
            try builder.write(
                "CAST(round(median(matched_at - start_at)) AS BIGINT)",
            );
        } else {
            try builder.write("NULL::BIGINT");
        }
        try builder.write(
            " AS median_total_micros," ++
                " (SELECT persistent_step_one FROM coverage)" ++
                " AS persistent_step_one," ++
                " (SELECT ephemeral_step_one FROM coverage)" ++
                " AS ephemeral_step_one," ++
                " (SELECT legacy_step_one FROM coverage) AS legacy_step_one" ++
                " FROM selected_",
        );
        try builder.output.writer.print("{d}", .{index});
        if (!greedy_sessions) try builder.write(" WHERE selected = 1");
    }
    try builder.write(") ordered_result ORDER BY step_index");
    return builder.finish();
}

pub fn goalSelectorObserved(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    request: analysis.GoalDiscoveryRequest,
    selector: analysis.EventSelector,
) !bool {
    try request.validate();
    try selector.validate();
    if ((request.kind == .event) != (selector.kind == .exact_event) or
        selector.kind == .saved_goal)
    {
        return error.InvalidGoalDiscoverySelector;
    }
    var budget = deadline.Budget.init(request.timeout_ms);
    var result = try executePlan(
        &event_store.database,
        try compileGoalSelectorPresence(allocator, request, selector),
        &budget,
    );
    defer result.deinit();
    if (result.columnCount() != 1 or result.rowCount() != 1) {
        return error.InvalidGoalDiscoveryResult;
    }
    const count = result.int64(0, 0);
    if (count < 0) return error.InvalidGoalDiscoveryResult;
    return count != 0;
}

fn compileGoalSelectorPresence(
    allocator: std.mem.Allocator,
    request: analysis.GoalDiscoveryRequest,
    selector: analysis.EventSelector,
) !StatementPlan {
    const query = analysis.Query{
        .site_id = request.site_id,
        .range = request.range,
        .mode = .breakdown,
        .metric = .{ .kind = if (request.kind == .page)
            .page_views
        else
            .custom_events },
        .dimension = .{ .kind = if (request.kind == .page)
            .page
        else
            .event_name },
        .sort = .value_desc,
        .limit = 1,
    };
    const execution = analysis.Execution{
        .query = query,
        .active_goals = request.active_goals,
        .strict_traffic_mode = request.strict_traffic_mode,
        .timeout_ms = request.timeout_ms,
    };
    try execution.validate();
    try validateCombination(query);
    var builder = Builder.init(allocator);
    try writeCommon(&builder, execution, request.range, false, false);
    try builder.write(" SELECT count(*)::BIGINT FROM qualified e WHERE e.kind = ");
    try builder.bindInteger(if (request.kind == .page) 1 else 2);
    switch (selector.kind) {
        .exact_event => {
            try builder.write(" AND e.event_name = ");
            try builder.bindText(selector.value);
        },
        .exact_page => {
            try builder.write(" AND e.path = ");
            try builder.bindText(selector.value);
        },
        .page_prefix => {
            try builder.write(" AND starts_with(e.path, ");
            try builder.bindText(selector.value);
            try builder.write(")");
        },
        .saved_goal => unreachable,
    }
    return builder.finish();
}

pub fn compileSuggestions(
    allocator: std.mem.Allocator,
    request: analysis.SuggestionRequest,
) !StatementPlan {
    try request.validate();
    var builder = Builder.init(allocator);
    const full_session = request.scope != .event or
        hasSessionFact(request.field.kind);
    try writeCommon(
        &builder,
        request.execution,
        request.execution.query.range,
        full_session,
        request.field.kind == .user_trait,
    );
    try builder.write(", suggestion_values AS (SELECT DISTINCT ");
    const alias = switch (request.scope) {
        .event => "e",
        .session => if (hasSessionFact(request.field.kind)) "s" else "sf",
        .person => if (request.field.kind == .identity_state)
            "e"
        else if (request.field.kind == .user_trait)
            "pf"
        else
            "pf",
    };
    try writeSuggestionExpression(&builder, request, alias);
    try builder.write(" AS value FROM qualified e");
    switch (request.scope) {
        .event => {},
        .session => if (hasSessionFact(request.field.kind)) {
            try builder.write(" JOIN session_facts s USING (session_id)");
        } else {
            try builder.write(
                " JOIN base sf ON sf.session_id = e.session_id",
            );
        },
        .person => if (request.field.kind == .identity_state) {} else {
            try builder.write(" JOIN ");
            try builder.write(if (request.field.kind == .user_trait)
                "person_traits"
            else
                "base");
            try builder.write(" pf ON pf.person_key = e.person_key");
        },
    }
    try builder.write(" WHERE ");
    try writeSuggestionPresence(&builder, request, alias);
    if (request.search.len != 0) {
        try builder.write(" AND contains(lower(CAST(");
        try writeSuggestionExpression(&builder, request, alias);
        try builder.write(" AS VARCHAR)), lower(");
        try builder.bindText(request.search);
        try builder.write("))");
    }
    try builder.write(" ORDER BY value LIMIT ");
    try builder.bindInteger(analysis.maximum_suggestions + 1);
    try builder.write(") SELECT value FROM suggestion_values ORDER BY value");
    return builder.finish();
}

fn writeSuggestionPresence(
    builder: *Builder,
    request: analysis.SuggestionRequest,
    alias: []const u8,
) !void {
    if (request.field.property_ref) |reference| {
        const pointer = try property.jsonPointer(builder.allocator, reference.name);
        return writeJsonTypeGuard(
            builder,
            alias,
            if (request.field.kind == .user_trait)
                "user_traits_json"
            else
                "properties_json",
            pointer,
            reference.scalar_type,
        );
    }
    try writeSuggestionExpression(builder, request, alias);
    try builder.write(" IS NOT NULL");
    if (request.scalar_type == .string) {
        try builder.write(" AND ");
        try writeSuggestionExpression(builder, request, alias);
        try builder.write(" <> ''");
    }
}

fn writeSuggestionExpression(
    builder: *Builder,
    request: analysis.SuggestionRequest,
    alias: []const u8,
) !void {
    if (request.field.property_ref) |reference| {
        try builder.write("CAST(");
        try writeJsonValue(
            builder,
            alias,
            if (request.field.kind == .user_trait)
                "user_traits_json"
            else
                "properties_json",
            try property.jsonPointer(builder.allocator, reference.name),
            reference.scalar_type,
        );
        return builder.write(" AS VARCHAR)");
    }
    if (request.scalar_type != .string) try builder.write("CAST(");
    try writeScalarExpression(builder, request.field.kind, alias);
    if (request.scalar_type != .string) try builder.write(" AS VARCHAR)");
}

const property_catalog_cache_milliseconds: i64 = 30_000;

fn propertyCatalogCacheKey(
    allocator: std.mem.Allocator,
    execution: analysis.Execution,
) ![]const u8 {
    var key = std.Io.Writer.Allocating.init(allocator);
    errdefer key.deinit();
    try key.writer.writeAll("property-catalog-v1|metric-v2|");
    try cacheKeySlice(&key.writer, execution.query.site_id);
    try cacheKeySlice(&key.writer, execution.query.range.start);
    try cacheKeySlice(&key.writer, execution.query.range.end);
    try key.writer.print("strict={d}|goals={d}|", .{
        @intFromBool(execution.strict_traffic_mode),
        execution.active_goals.len,
    });
    for (execution.active_goals) |goal| {
        try cacheKeySlice(&key.writer, goal.id);
        try cacheKeySlice(&key.writer, @tagName(goal.selector.kind));
        try cacheKeySlice(&key.writer, goal.selector.value);
        try key.writer.print("predicates={d}|", .{goal.selector.predicates.len});
        for (goal.selector.predicates) |predicate| {
            try cacheKeySlice(&key.writer, predicate.property_ref.name);
            try cacheKeySlice(
                &key.writer,
                predicate.property_ref.scalar_type.name(),
            );
            try cacheKeySlice(&key.writer, predicate.operator.name());
            try key.writer.print("values={d}|", .{predicate.values.len});
            for (predicate.values) |value| {
                try cacheKeySlice(&key.writer, value);
            }
        }
    }
    return key.toOwnedSlice();
}

fn cachePropertyCatalog(
    event_store: *events.Store,
    key: []const u8,
    catalog: analysis.PropertyCatalog,
) !void {
    const now = monotonicNanos() orelse return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const owned_key = try allocator.dupe(u8, key);
    const owned_catalog = try clonePropertyCatalog(allocator, catalog);
    if (event_store.property_catalog_cache) |*prior| prior.deinit();
    event_store.property_catalog_cache = .{
        .arena = arena,
        .key = owned_key,
        .catalog = owned_catalog,
        .expires_at_nanos = now +
            @as(i128, property_catalog_cache_milliseconds) * std.time.ns_per_ms,
    };
}

fn clonePropertyCatalog(
    allocator: std.mem.Allocator,
    source: analysis.PropertyCatalog,
) !analysis.PropertyCatalog {
    const entries = try allocator.alloc(
        analysis.ObservedPropertyType,
        source.entries.len,
    );
    for (entries, source.entries) |*target, entry| target.* = .{
        .name = try allocator.dupe(u8, entry.name),
        .scalar_type = entry.scalar_type,
        .event_count = entry.event_count,
    };
    return .{
        .entries = entries,
        .property_count = source.property_count,
        .truncated = source.truncated,
    };
}

fn monotonicNanos() ?i128 {
    var timestamp: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(.MONOTONIC, &timestamp) != 0) return null;
    return @as(i128, timestamp.sec) * std.time.ns_per_s + timestamp.nsec;
}

pub fn executeTrendSet(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    execution: analysis.TrendSetExecution,
) !analysis.TrendSetResult {
    try execution.validate();
    if (execution.set.filters.clauses.len != 0 and
        execution.set.series.len == 1 and
        execution.set.series[0].kind == .visitors)
    {
        return executeFilteredVisitorTrendSet(allocator, event_store, execution);
    }
    var budget = deadline.Budget.init(execution.timeout_ms);
    const coverage_execution = trendSetItemExecution(
        execution,
        execution.set.series[0],
    );
    const coverage_compiled = try compile(allocator, coverage_execution);
    const completeness = try executeCoverage(
        allocator,
        &event_store.database,
        coverage_compiled.coverage,
        &budget,
    );
    const comparison_completeness = if (coverage_compiled.comparison_coverage) |plan|
        try executeCoverage(
            allocator,
            &event_store.database,
            plan,
            &budget,
        )
    else
        null;
    const series = try allocator.alloc(
        analysis.TrendResult,
        execution.set.series.len,
    );
    for (execution.set.series, series) |metric, *target| {
        target.* = try executeTrendWithCoverage(
            allocator,
            event_store,
            trendSetItemExecution(execution, metric),
            &budget,
            completeness,
            comparison_completeness,
        );
    }
    return .{ .series = series };
}

fn compileFilteredVisitorTrendSet(
    allocator: std.mem.Allocator,
    execution: analysis.TrendSetExecution,
) !StatementPlan {
    const item = trendSetItemExecution(execution, execution.set.series[0]);
    const interval = try resolveInterval(item.query);
    const selection = analysis.OverviewTrendSelection{
        .metric = .visitors,
        .interval = interval,
        .current_buckets = &.{},
        .comparison_buckets = &.{},
    };
    const overview_execution = analysis.OverviewExecution{
        .site_id = item.query.site_id,
        .range = item.query.range,
        .comparison_range = item.comparison_range,
        .active_goals = item.active_goals,
        .filters = item.query.filters,
        .strict_traffic_mode = item.strict_traffic_mode,
        .daily_event_ceiling = 1,
        .trend = selection,
    };
    var builder = Builder.init(allocator);
    try writeFilteredOverviewCommon(
        &builder,
        overview_execution,
        selection,
        false,
    );
    try builder.write(
        ", trend_rows AS (SELECT period, bucket_label," ++
            " count(DISTINCT person_key)::BIGINT AS visitors" ++
            " FROM qualified GROUP BY period, bucket_label)," ++
            " summary_values AS (SELECT period," ++
            " count(DISTINCT person_key)::BIGINT AS visitors," ++
            " count(DISTINCT CASE WHEN identity_quality = 1" ++
            " THEN person_key END)::BIGINT AS persistent," ++
            " count(DISTINCT CASE WHEN identity_quality = 2" ++
            " THEN person_key END)::BIGINT AS ephemeral," ++
            " count(DISTINCT CASE WHEN identity_quality = 3" ++
            " THEN person_key END)::BIGINT AS legacy" ++
            " FROM qualified GROUP BY period)," ++
            " period_summary AS (SELECT p.period," ++
            " COALESCE(s.visitors, 0)::BIGINT AS visitors," ++
            " COALESCE(s.persistent, 0)::BIGINT AS persistent," ++
            " COALESCE(s.ephemeral, 0)::BIGINT AS ephemeral," ++
            " COALESCE(s.legacy, 0)::BIGINT AS legacy" ++
            " FROM periods p LEFT JOIN summary_values s USING (period))," ++
            " persistent_since AS (SELECT CAST(min(site_local_date) AS VARCHAR)" ++
            " AS local_date FROM events WHERE site_id = ",
    );
    try builder.bindText(item.query.site_id);
    try builder.write(
        " AND kind IN (1, 2) AND traffic_class IN (1, 5)" ++
            " AND identity_quality = 1",
    );
    if (item.strict_traffic_mode) try builder.write(
        " AND session_id NOT IN (SELECT session_id" ++
            " FROM d34_current_suspected_sessions)",
    );
    try builder.write(
        ") SELECT 'point' AS row_kind, t.period, t.bucket_label," ++
            " t.visitors, s.persistent, s.ephemeral, s.legacy, p.local_date" ++
            " FROM trend_rows t JOIN period_summary s USING (period)" ++
            " CROSS JOIN persistent_since p" ++
            " UNION ALL SELECT 'total', s.period, '', s.visitors," ++
            " s.persistent, s.ephemeral, s.legacy, p.local_date" ++
            " FROM period_summary s CROSS JOIN persistent_since p" ++
            " ORDER BY period, row_kind, bucket_label",
    );
    return builder.finish();
}

fn executeFilteredVisitorTrendSet(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    execution: analysis.TrendSetExecution,
) !analysis.TrendSetResult {
    var budget = deadline.Budget.init(execution.timeout_ms);
    var result = try executePlan(
        &event_store.database,
        try compileFilteredVisitorTrendSet(allocator, execution),
        &budget,
    );
    defer result.deinit();
    if (result.columnCount() != 8 or
        result.rowCount() > analysis.maximum_trend_rows * 2 + 2)
    {
        return error.InvalidAnalysisResult;
    }
    var current_points: std.ArrayList(analysis.TrendPoint) = .empty;
    errdefer current_points.deinit(allocator);
    var comparison_points: std.ArrayList(analysis.TrendPoint) = .empty;
    errdefer comparison_points.deinit(allocator);
    var current_total: ?i64 = null;
    var comparison_total: ?i64 = null;
    var current_completeness: ?analysis.Completeness = null;
    var comparison_completeness: ?analysis.Completeness = null;
    for (0..result.rowCount()) |row| {
        const period = result.int64(1, row);
        const points = if (period == 1)
            &current_points
        else if (period == 2)
            &comparison_points
        else
            return error.InvalidAnalysisResult;
        const value = result.int64(3, row);
        const persistent = result.int64(4, row);
        const ephemeral = result.int64(5, row);
        const legacy = result.int64(6, row);
        if (value < 0 or persistent < 0 or ephemeral < 0 or legacy < 0) {
            return error.InvalidAnalysisResult;
        }
        const row_kind = try result.text(allocator, 0, row);
        if (std.mem.eql(u8, row_kind, "point")) {
            try points.append(allocator, .{
                .bucket = try result.text(allocator, 2, row),
                .measure = .{ .count = value },
            });
            continue;
        }
        if (!std.mem.eql(u8, row_kind, "total") or
            persistent + ephemeral + legacy != value)
        {
            return error.InvalidAnalysisResult;
        }
        const persistent_scaled = std.math.mul(i64, persistent, 10_000) catch
            return error.InvalidAnalysisResult;
        const completeness = analysis.Completeness{
            .total_people = value,
            .persistent_people = persistent,
            .ephemeral_people = ephemeral,
            .legacy_people = legacy,
            .persistent_basis_points = if (value == 0)
                0
            else
                @intCast(@divTrunc(persistent_scaled, value)),
            .persistent_since_local_date = if (result.isNull(7, row))
                null
            else
                try result.text(allocator, 7, row),
        };
        if (period == 1) {
            if (current_total != null) return error.InvalidAnalysisResult;
            current_total = value;
            current_completeness = completeness;
        } else {
            if (comparison_total != null) return error.InvalidAnalysisResult;
            comparison_total = value;
            comparison_completeness = completeness;
        }
    }
    if (current_total == null or current_completeness == null or
        (execution.comparison_range != null) != (comparison_total != null))
    {
        return error.InvalidAnalysisResult;
    }
    const totals = try allocator.alloc(analysis.Measure, 1);
    totals[0] = .{ .count = current_total.? };
    const comparison_totals = if (comparison_total) |value| block: {
        const values = try allocator.alloc(analysis.Measure, 1);
        values[0] = .{ .count = value };
        break :block values;
    } else null;
    const series = try allocator.alloc(analysis.TrendResult, 1);
    series[0] = .{
        .points = try current_points.toOwnedSlice(allocator),
        .comparison_points = if (execution.comparison_range != null)
            try comparison_points.toOwnedSlice(allocator)
        else
            null,
        .comparison_total = comparison_totals,
        .comparison_completeness = comparison_completeness,
        .total = totals,
        .interval = try resolveInterval(execution.set.query(execution.set.series[0])),
        .completeness = current_completeness.?,
    };
    return .{ .series = series };
}

fn trendSetItemExecution(
    execution: analysis.TrendSetExecution,
    metric: analysis.Metric,
) analysis.Execution {
    return .{
        .query = execution.set.query(metric),
        .comparison_range = execution.comparison_range,
        .active_goals = execution.active_goals,
        .selected_goals = execution.selected_goals,
        .strict_traffic_mode = execution.strict_traffic_mode,
        .segment_resolved = execution.segment_resolved,
        .timeout_ms = execution.timeout_ms,
    };
}

fn executeTrendWithCoverage(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    execution: analysis.Execution,
    budget: *deadline.Budget,
    completeness: analysis.Completeness,
    comparison_completeness: ?analysis.Completeness,
) !analysis.TrendResult {
    const compiled = try compile(allocator, execution);
    const primary = try executeRows(
        allocator,
        &event_store.database,
        compiled.primary_rows,
        budget,
    );
    const comparison = if (compiled.comparison_rows) |plan|
        try executeRows(allocator, &event_store.database, plan, budget)
    else
        null;
    return .{
        .points = try trendPoints(allocator, primary),
        .comparison_points = if (comparison) |rows|
            try trendPoints(allocator, rows)
        else
            null,
        .comparison_total = if (compiled.comparison_total) |plan|
            try executeTotals(allocator, &event_store.database, plan, budget)
        else
            null,
        .comparison_completeness = comparison_completeness,
        .total = try executeTotals(
            allocator,
            &event_store.database,
            compiled.primary_total.?,
            budget,
        ),
        .interval = compiled.interval,
        .completeness = completeness,
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

pub fn compileOverviewDetails(
    allocator: std.mem.Allocator,
    execution: analysis.OverviewExecution,
) !StatementPlan {
    try execution.validate();
    const selection = execution.trend orelse return error.MissingOverviewTrend;
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
    try builder.write("), trend_buckets(period, position, label) AS (VALUES ");
    var first_bucket = true;
    for (selection.current_buckets, 0..) |bucket, index| {
        if (!first_bucket) try builder.write(", ");
        first_bucket = false;
        try builder.write("(1::UTINYINT, ");
        try builder.bindInteger(@intCast(index));
        try builder.write("::UINTEGER, ");
        try builder.bindText(bucket.label);
        try builder.write(")");
    }
    for (selection.comparison_buckets, 0..) |bucket, index| {
        try builder.write(", (2::UTINYINT, ");
        try builder.bindInteger(@intCast(index));
        try builder.write("::UINTEGER, ");
        try builder.bindText(bucket.label);
        try builder.write(")");
    }
    try builder.write(
        "), range_events AS NOT MATERIALIZED (SELECT p.period, e.session_id," ++
            " e.kind, e.event_name, e.path, e.properties_json," ++
            " e.value_amount, e.value_currency, ",
    );
    try writeBucket(&builder, selection.interval, "e");
    try builder.write(
        " AS bucket_label," ++
            " struct_pack(identity_kind := CASE WHEN e.identity_quality = 1" ++
            " AND COALESCE(l.user_id, e.user_id, '') <> '' THEN 0::UTINYINT" ++
            " ELSE e.identity_quality END," ++
            " user_id := CASE WHEN e.identity_quality = 1" ++
            " AND COALESCE(l.user_id, e.user_id, '') <> ''" ++
            " THEN COALESCE(l.user_id, e.user_id) ELSE '' END," ++
            " anonymous_id := CASE WHEN e.identity_quality = 1" ++
            " AND COALESCE(l.user_id, e.user_id, '') <> ''" ++
            " THEN CAST(NULL AS UUID) ELSE e.anonymous_id END) AS person_key, ",
    );
    try writeGoalMatchCount(&builder, execution.active_goals, "e");
    try builder.write(
        " AS goal_matches FROM events e JOIN periods p" ++
            " ON e.site_local_date BETWEEN p.start_date AND p.end_date" ++
            " LEFT JOIN identity_links l ON l.site_id = e.site_id" ++
            " AND l.anonymous_id = e.anonymous_id WHERE e.site_id = ",
    );
    try builder.bindText(execution.site_id);
    try builder.write(
        " AND e.kind IN (1, 2) AND e.identity_quality IN (1, 2, 3)" ++
            " AND e.traffic_class IN (1, 5)",
    );
    if (execution.strict_traffic_mode) try builder.write(
        " AND e.session_id NOT IN (SELECT session_id" ++
            " FROM d34_current_suspected_sessions)",
    );
    try builder.write(
        "), current_sessions AS MATERIALIZED (SELECT DISTINCT session_id" ++
            " FROM range_events WHERE period = 1)," ++
            " session_facts AS MATERIALIZED (SELECT e.session_id, bool_or(",
    );
    try writeAnyGoalMatch(&builder, execution.active_goals, "e");
    try builder.write(
        ") AS converted," ++
            " COALESCE(NULLIF(first(e.referrer_host ORDER BY" ++
            " e.occurred_at_utc_micros, e.sequence," ++
            " e.received_at_utc_micros, e.event_id)" ++
            " FILTER (WHERE e.kind = 1), ''), 'Direct') AS source," ++
            " CASE WHEN first(e.country_code ORDER BY" ++
            " e.occurred_at_utc_micros, e.sequence," ++
            " e.received_at_utc_micros, e.event_id)" ++
            " FILTER (WHERE e.kind IN (1, 2)) IN ('ZZ', '')" ++
            " THEN 'Unknown' ELSE first(e.country_code ORDER BY" ++
            " e.occurred_at_utc_micros, e.sequence," ++
            " e.received_at_utc_micros, e.event_id)" ++
            " FILTER (WHERE e.kind IN (1, 2)) END AS country" ++
            " FROM events e SEMI JOIN current_sessions s" ++
            " USING (session_id) WHERE e.site_id = ",
    );
    try builder.bindText(execution.site_id);
    try builder.write(" AND e.traffic_class IN (1, 5) GROUP BY e.session_id),");

    try builder.write(" trend_values AS (");
    switch (selection.metric) {
        .visitors => {
            try builder.write(
                "SELECT e.period, e.bucket_label AS label," ++
                    " count(DISTINCT e.person_key)::BIGINT AS numerator," ++
                    " CAST(NULL AS VARCHAR) AS amount FROM range_events e" ++
                    " GROUP BY e.period, label",
            );
        },
        .sessions, .page_views, .conversions => {
            try builder.write("SELECT e.period, e.bucket_label AS label, ");
            switch (selection.metric) {
                .sessions => try builder.write("count(DISTINCT e.session_id)::BIGINT"),
                .page_views => try builder.write("count(*) FILTER (WHERE e.kind = 1)::BIGINT"),
                .conversions => try builder.write("sum(e.goal_matches)::BIGINT"),
                else => unreachable,
            }
            try builder.write(
                " AS numerator, CAST(NULL AS VARCHAR) AS amount" ++
                    " FROM range_events e GROUP BY e.period, label",
            );
        },
        .revenue => {
            try builder.write(
                "SELECT e.period, e.bucket_label AS label," ++
                    " 0::BIGINT AS numerator," ++
                    " CAST(sum(e.value_amount) AS VARCHAR) AS amount" ++
                    " FROM range_events e WHERE e.value_amount IS NOT NULL" ++
                    " AND e.value_currency = ",
            );
            try builder.bindText(selection.currency);
            try builder.write(" GROUP BY e.period, label");
        },
    }
    try builder.write(
        "), trend_rows AS (SELECT b.period, b.position, b.label," ++
            " COALESCE(v.numerator, 0)::BIGINT AS numerator," ++
            " COALESCE(v.amount, '0.000000') AS amount" ++
            " FROM trend_buckets b LEFT JOIN trend_values v" ++
            " ON v.period = b.period AND v.label = b.label)," ++
            " content_rows AS (SELECT path, count(*)::BIGINT AS page_views," ++
            " count(DISTINCT person_key)::BIGINT AS visitors" ++
            " FROM range_events WHERE period = 1 AND kind = 1 GROUP BY path)," ++
            " acquisition_rows AS (SELECT sf.source," ++
            " count(*)::BIGINT AS sessions," ++
            " count(*) FILTER (WHERE sf.converted)::BIGINT AS converting_sessions" ++
            " FROM current_sessions cs JOIN session_facts sf USING (session_id)" ++
            " GROUP BY sf.source)," ++
            " audience_rows AS (SELECT sf.country, count(*)::BIGINT AS sessions" ++
            " FROM current_sessions cs JOIN session_facts sf USING (session_id)" ++
            " GROUP BY sf.country), goal_rows AS (",
    );
    if (execution.active_goals.len == 0) {
        try builder.write(
            "SELECT '' AS goal_id, 0::UINTEGER AS goal_position," ++
                " 0::BIGINT AS converting_people WHERE FALSE",
        );
    } else {
        for (execution.active_goals, 0..) |goal, index| {
            if (index != 0) try builder.write(" UNION ALL ");
            try builder.write("SELECT ");
            try builder.bindText(goal.id);
            try builder.write(" AS goal_id, ");
            try builder.bindInteger(@intCast(index));
            try builder.write(
                "::UINTEGER AS goal_position," ++
                    " count(DISTINCT e.person_key)::BIGINT" ++
                    " AS converting_people FROM range_events e" ++
                    " WHERE e.period = 1 AND ",
            );
            try writeSelector(&builder, goal.selector, "e");
        }
    }
    try builder.write(
        "), health_days AS MATERIALIZED (SELECT site_local_date," ++
            " count(*)::BIGINT AS accepted_events," ++
            " COALESCE(max(received_at_utc_micros), 0)::BIGINT AS last_received," ++
            " count(*) FILTER (WHERE protocol_version = 1)::BIGINT AS protocol_v1," ++
            " count(*) FILTER (WHERE protocol_version = 2)::BIGINT AS protocol_v2" ++
            " FROM events WHERE site_id = ",
    );
    try builder.bindText(execution.site_id);
    try builder.write(" GROUP BY site_local_date), health_row AS (SELECT" ++
        " COALESCE(sum(accepted_events), 0)::BIGINT AS accepted_events," ++
        " COALESCE(max(last_received), 0)::BIGINT AS last_received," ++
        " COALESCE(sum(protocol_v1), 0)::BIGINT AS protocol_v1," ++
        " COALESCE(sum(protocol_v2), 0)::BIGINT AS protocol_v2," ++
        " count(*) FILTER (WHERE site_local_date BETWEEN CAST(");
    try builder.bindText(execution.range.start);
    try builder.write(" AS DATE) AND CAST(");
    try builder.bindText(execution.range.end);
    try builder.write(" AS DATE) AND accepted_events >= ");
    try builder.bindInteger(execution.daily_event_ceiling);
    try builder.write(")::BIGINT AS ceiling_reached_days FROM health_days");
    try builder.write(
        ") SELECT 'trend' AS section, t.label, t.position::BIGINT AS position," ++
            " t.numerator, 0::BIGINT AS denominator, t.amount," ++
            " ",
    );
    if (selection.metric == .revenue) {
        try builder.bindText(selection.currency);
    } else try builder.write("''");
    try builder.write(
        " AS currency, t.period::BIGINT AS aux, 0::BIGINT AS extra," ++
            " 0::BIGINT AS health_extra" ++
            " FROM trend_rows t UNION ALL SELECT * FROM (SELECT 'content', path," ++
            " row_number() OVER (ORDER BY page_views DESC, path ASC)::BIGINT," ++
            " page_views, visitors, CAST(NULL AS VARCHAR), '', 0::BIGINT, 0::BIGINT," ++
            " 0::BIGINT" ++
            " FROM content_rows ORDER BY page_views DESC, path ASC LIMIT 5)" ++
            " UNION ALL SELECT * FROM (SELECT 'acquisition', source," ++
            " row_number() OVER (ORDER BY sessions DESC, source ASC)::BIGINT," ++
            " sessions, converting_sessions, CAST(NULL AS VARCHAR), '', 0::BIGINT, 0::BIGINT," ++
            " 0::BIGINT" ++
            " FROM acquisition_rows ORDER BY sessions DESC, source ASC LIMIT 5)" ++
            " UNION ALL SELECT * FROM (SELECT 'conversion', goal_id," ++
            " row_number() OVER (ORDER BY converting_people DESC," ++
            " goal_position ASC)::BIGINT," ++
            " converting_people, 0::BIGINT, CAST(NULL AS VARCHAR), '', 0::BIGINT, 0::BIGINT," ++
            " 0::BIGINT" ++
            " FROM goal_rows ORDER BY converting_people DESC," ++
            " goal_position ASC LIMIT 5)" ++
            " UNION ALL SELECT * FROM (SELECT 'audience', country," ++
            " row_number() OVER (ORDER BY sessions DESC, country ASC)::BIGINT," ++
            " sessions, 0::BIGINT, CAST(NULL AS VARCHAR), '', 0::BIGINT, 0::BIGINT," ++
            " 0::BIGINT" ++
            " FROM audience_rows ORDER BY sessions DESC, country ASC LIMIT 5)" ++
            " UNION ALL SELECT 'health', '', 0::BIGINT, accepted_events," ++
            " last_received, CAST(NULL AS VARCHAR), '', protocol_v1, protocol_v2," ++
            " ceiling_reached_days" ++
            " FROM health_row ORDER BY section, aux, position",
    );
    return builder.finish();
}

const SessionRangeColumns = struct {
    event_name: bool = false,
    path: bool = false,
    page_title: bool = false,
    hostname: bool = false,
    referrer: bool = false,
    country: bool = false,
    language: bool = false,
    device: bool = false,
    browser: bool = false,
    operating_system: bool = false,
    utm_source: bool = false,
    utm_medium: bool = false,
    utm_campaign: bool = false,
    utm_term: bool = false,
    utm_content: bool = false,
    properties: bool = false,

    fn include(result: *SessionRangeColumns, field: analysis.FieldKind) void {
        switch (field) {
            .page => result.path = true,
            .page_title => result.page_title = true,
            .hostname => result.hostname = true,
            .referrer => result.referrer = true,
            .country => result.country = true,
            .language => result.language = true,
            .device => result.device = true,
            .browser => result.browser = true,
            .operating_system => result.operating_system = true,
            .utm_source => result.utm_source = true,
            .utm_medium => result.utm_medium = true,
            .utm_campaign => result.utm_campaign = true,
            .utm_term => result.utm_term = true,
            .utm_content => result.utm_content = true,
            .event_name => result.event_name = true,
            .event_property => result.properties = true,
            .landing_page,
            .exit_page,
            .channel,
            .user_trait,
            .identity_state,
            .session_converted,
            .session_duration_ms,
            .session_engagement_ms,
            => {},
        }
    }

    fn resolve(
        filters: analysis.FilterSet,
        selected_goal: ?analysis.EventSelector,
    ) SessionRangeColumns {
        var result = SessionRangeColumns{};
        for (filters.clauses) |clause| switch (clause.scope) {
            .event => result.include(clause.field.kind),
            .session => if (!hasSessionFact(clause.field.kind)) {
                result.include(clause.field.kind);
            },
            .person => if (clause.field.kind != .identity_state and
                clause.field.kind != .user_trait)
            {
                result.include(clause.field.kind);
            },
        };
        if (selected_goal) |selector| {
            switch (selector.kind) {
                .exact_event => result.event_name = true,
                .exact_page, .page_prefix => result.path = true,
                .saved_goal => {},
            }
            if (selector.predicates.len != 0) result.properties = true;
        }
        return result;
    }
};

const FilteredSessionColumns = struct {
    landing_page: bool = false,
    exit_page: bool = false,
    channel: bool = false,
    referrer: bool = false,
    utm_source: bool = false,
    utm_medium: bool = false,
    utm_campaign: bool = false,
    utm_term: bool = false,
    utm_content: bool = false,
    country: bool = false,
    language: bool = false,
    device: bool = false,
    browser: bool = false,
    operating_system: bool = false,

    fn include(result: *FilteredSessionColumns, field: analysis.FieldKind) void {
        switch (field) {
            .landing_page => result.landing_page = true,
            .exit_page => result.exit_page = true,
            .channel => {
                result.channel = true;
                result.referrer = true;
                result.utm_source = true;
                result.utm_medium = true;
            },
            .referrer => result.referrer = true,
            .utm_source => result.utm_source = true,
            .utm_medium => result.utm_medium = true,
            .utm_campaign => result.utm_campaign = true,
            .utm_term => result.utm_term = true,
            .utm_content => result.utm_content = true,
            .country => result.country = true,
            .language => result.language = true,
            .device => result.device = true,
            .browser => result.browser = true,
            .operating_system => result.operating_system = true,
            .session_converted,
            .session_duration_ms,
            .session_engagement_ms,
            => {},
            else => unreachable,
        }
    }

    fn resolve(filters: analysis.FilterSet, include_details: bool) FilteredSessionColumns {
        var result = FilteredSessionColumns{};
        if (include_details) {
            result.referrer = true;
            result.country = true;
        }
        for (filters.clauses) |clause| {
            if (clause.scope != .session or !hasSessionFact(clause.field.kind)) continue;
            result.include(clause.field.kind);
        }
        return result;
    }
};

fn needsFilteredEventColumns(filters: analysis.FilterSet) bool {
    for (filters.clauses) |clause| switch (clause.scope) {
        .event => return true,
        .session => if (!hasSessionFact(clause.field.kind)) return true,
        .person => if (clause.field.kind != .identity_state and
            clause.field.kind != .user_trait)
        {
            return true;
        },
    };
    return false;
}

fn usesOnlySessionFacts(filters: analysis.FilterSet) bool {
    if (filters.clauses.len == 0) return false;
    for (filters.clauses) |clause| {
        if (clause.scope != .session or !hasSessionFact(clause.field.kind)) {
            return false;
        }
    }
    return true;
}

fn writeSessionFirst(
    builder: *Builder,
    column: []const u8,
    alias: []const u8,
    default_value: []const u8,
    kinds: []const u8,
    descending: bool,
) !void {
    try builder.write(", COALESCE(first(");
    try builder.write(column);
    try builder.write(" ORDER BY occurred_at_utc_micros");
    if (descending) try builder.write(" DESC");
    try builder.write(", sequence");
    if (descending) try builder.write(" DESC");
    try builder.write(", received_at_utc_micros");
    if (descending) try builder.write(" DESC");
    try builder.write(", event_id");
    if (descending) try builder.write(" DESC");
    try builder.write(") FILTER (WHERE kind ");
    try builder.write(kinds);
    try builder.write("), ");
    try builder.write(default_value);
    try builder.write(") AS ");
    try builder.write(alias);
}

fn writeFilteredOverviewCommon(
    builder: *Builder,
    execution: analysis.OverviewExecution,
    selection: ?analysis.OverviewTrendSelection,
    include_detail_panels: bool,
) !void {
    const session_columns = FilteredSessionColumns.resolve(
        execution.filters,
        include_detail_panels,
    );
    var goal_event_name = false;
    var goal_path = false;
    var goal_properties_json = false;
    for (execution.active_goals) |goal| {
        goal_properties_json = goal_properties_json or
            goal.selector.predicates.len != 0;
        switch (goal.selector.kind) {
            .exact_event => goal_event_name = true,
            .exact_page, .page_prefix => goal_path = true,
            .saved_goal => return error.UnresolvedGoalSelector,
        }
    }
    const include_event_columns = needsFilteredEventColumns(execution.filters);
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
            builder.allocator,
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
        "), range_events AS NOT MATERIALIZED (SELECT p.period," ++
            " e.session_id, e.kind",
    );
    if (include_event_columns) {
        try builder.write(
            ", e.event_name, e.path, e.page_title, e.hostname," ++
                " e.referrer_host AS referrer," ++
                " e.utm_source, e.utm_medium, e.utm_campaign," ++
                " e.utm_term, e.utm_content, e.country_code AS country," ++
                " e.language, e.device_category AS device," ++
                " e.browser_family AS browser," ++
                " e.os_family AS operating_system, e.properties_json",
        );
    } else if (selection != null) {
        try builder.write(", e.path");
    }
    try builder.write(
        ", e.value_amount, e.value_currency," ++
            " e.identity_quality," ++
            " struct_pack(identity_kind := CASE" ++
            " WHEN e.identity_quality = 1" ++
            " AND COALESCE(l.user_id, e.user_id, '') <> ''" ++
            " THEN 0::UTINYINT ELSE e.identity_quality END," ++
            " user_id := CASE WHEN e.identity_quality = 1" ++
            " AND COALESCE(l.user_id, e.user_id, '') <> ''" ++
            " THEN COALESCE(l.user_id, e.user_id) ELSE '' END," ++
            " anonymous_id := CASE WHEN e.identity_quality = 1" ++
            " AND COALESCE(l.user_id, e.user_id, '') <> ''" ++
            " THEN CAST(NULL AS UUID) ELSE e.anonymous_id END) AS person_key," ++
            " CASE WHEN e.identity_quality = 1" ++
            " AND COALESCE(l.user_id, e.user_id, '') <> '' THEN 'identified'" ++
            " WHEN e.identity_quality = 1 THEN 'anonymous'" ++
            " WHEN e.identity_quality = 2 THEN 'ephemeral'" ++
            " ELSE 'legacy' END AS identity_state, ",
    );
    try writeGoalMatchCount(builder, execution.active_goals, "e");
    try builder.write(" AS goal_matches, ");
    try writeGoalMatchMask(builder, execution.active_goals, "e");
    try builder.write(" AS goal_mask");
    if (selection) |trend| {
        try builder.write(", ");
        try writeBucket(builder, trend.interval, "e");
        try builder.write(" AS bucket_label");
    }
    try builder.write(
        " FROM events e JOIN periods p" ++
            " ON e.site_local_date BETWEEN p.start_date AND p.end_date" ++
            " LEFT JOIN identity_links l ON l.site_id = e.site_id" ++
            " AND l.anonymous_id = e.anonymous_id" ++
            " WHERE e.site_id = ",
    );
    try builder.bindText(execution.site_id);
    try builder.write(" AND e.kind IN (1, 2) AND e.traffic_class IN (1, 5)");
    if (execution.strict_traffic_mode) try builder.write(
        " AND e.session_id NOT IN (SELECT session_id" ++
            " FROM d34_current_suspected_sessions)",
    );
    try builder.write(
        "), base AS NOT MATERIALIZED (SELECT * FROM range_events)," ++
            " range_sessions AS NOT MATERIALIZED" ++
            " (SELECT DISTINCT period, session_id FROM range_events)," ++
            " session_events AS NOT MATERIALIZED" ++
            " (SELECT rs.period, e.session_id, e.kind",
    );
    if (goal_event_name) try builder.write(", e.event_name");
    if (goal_path or session_columns.landing_page or session_columns.exit_page) {
        try builder.write(", e.path");
    }
    if (goal_properties_json) try builder.write(", e.properties_json");
    if (session_columns.referrer) try builder.write(", e.referrer_host");
    if (session_columns.utm_source) try builder.write(", e.utm_source");
    if (session_columns.utm_medium) try builder.write(", e.utm_medium");
    if (session_columns.utm_campaign) try builder.write(", e.utm_campaign");
    if (session_columns.utm_term) try builder.write(", e.utm_term");
    if (session_columns.utm_content) try builder.write(", e.utm_content");
    if (session_columns.country) try builder.write(", e.country_code");
    if (session_columns.language) try builder.write(", e.language");
    if (session_columns.device) try builder.write(", e.device_category");
    if (session_columns.browser) try builder.write(", e.browser_family");
    if (session_columns.operating_system) try builder.write(", e.os_family");
    try builder.write(
        ", e.engagement_ms," ++
            " e.occurred_at_utc_micros, e.sequence," ++
            " e.received_at_utc_micros, e.event_id" ++
            " FROM events e JOIN range_sessions rs" ++
            " ON rs.session_id = e.session_id WHERE e.site_id = ",
    );
    try builder.bindText(execution.site_id);
    try builder.write(" AND e.traffic_class IN (1, 5)");
    try builder.write(
        "), session_summary AS NOT MATERIALIZED (SELECT period, session_id",
    );
    if (session_columns.landing_page) try writeSessionFirst(
        builder,
        "path",
        "landing_page",
        "''",
        "= 1",
        false,
    );
    if (session_columns.exit_page) try writeSessionFirst(
        builder,
        "path",
        "exit_page",
        "''",
        "= 1",
        true,
    );
    if (session_columns.referrer) try writeSessionFirst(
        builder,
        "referrer_host",
        "referrer",
        "''",
        "= 1",
        false,
    );
    if (session_columns.utm_source) try writeSessionFirst(
        builder,
        "utm_source",
        "utm_source",
        "''",
        "= 1",
        false,
    );
    if (session_columns.utm_medium) try writeSessionFirst(
        builder,
        "utm_medium",
        "utm_medium",
        "''",
        "= 1",
        false,
    );
    if (session_columns.utm_campaign) try writeSessionFirst(
        builder,
        "utm_campaign",
        "utm_campaign",
        "''",
        "= 1",
        false,
    );
    if (session_columns.utm_term) try writeSessionFirst(
        builder,
        "utm_term",
        "utm_term",
        "''",
        "= 1",
        false,
    );
    if (session_columns.utm_content) try writeSessionFirst(
        builder,
        "utm_content",
        "utm_content",
        "''",
        "= 1",
        false,
    );
    if (session_columns.country) try writeSessionFirst(
        builder,
        "country_code",
        "country",
        "'ZZ'",
        "IN (1, 2)",
        false,
    );
    if (session_columns.language) try writeSessionFirst(
        builder,
        "language",
        "language",
        "''",
        "IN (1, 2)",
        false,
    );
    if (session_columns.device) try writeSessionFirst(
        builder,
        "device_category",
        "device",
        "'unknown'",
        "IN (1, 2)",
        false,
    );
    if (session_columns.browser) try writeSessionFirst(
        builder,
        "browser_family",
        "browser",
        "'Unknown'",
        "IN (1, 2)",
        false,
    );
    if (session_columns.operating_system) try writeSessionFirst(
        builder,
        "os_family",
        "operating_system",
        "'Unknown'",
        "IN (1, 2)",
        false,
    );
    try builder.write(
        ", min(occurred_at_utc_micros) AS first_at," ++
            " max(occurred_at_utc_micros) AS last_at," ++
            " count(*) FILTER (WHERE kind = 1)::BIGINT AS page_views," ++
            " sum(engagement_ms)::BIGINT AS engagement_ms," ++
            " bool_or(CASE WHEN kind IN (1, 2) THEN ",
    );
    try writeAnyGoalMatch(builder, execution.active_goals, "session_events");
    try builder.write(
        " ELSE FALSE END) AS converted" ++
            " FROM session_events GROUP BY period, session_id)," ++
            " session_facts AS (SELECT st.period, st.session_id",
    );
    if (session_columns.landing_page) try builder.write(", st.landing_page");
    if (session_columns.exit_page) try builder.write(", st.exit_page");
    if (session_columns.referrer) try builder.write(", st.referrer");
    if (session_columns.utm_source) try builder.write(", st.utm_source");
    if (session_columns.utm_medium) try builder.write(", st.utm_medium");
    if (session_columns.utm_campaign) try builder.write(", st.utm_campaign");
    if (session_columns.utm_term) try builder.write(", st.utm_term");
    if (session_columns.utm_content) try builder.write(", st.utm_content");
    if (session_columns.country) try builder.write(", st.country");
    if (session_columns.language) try builder.write(", st.language");
    if (session_columns.device) try builder.write(", st.device");
    if (session_columns.browser) try builder.write(", st.browser");
    if (session_columns.operating_system) try builder.write(", st.operating_system");
    if (session_columns.channel) try builder.write(
        ", CASE WHEN st.utm_source = ''" ++
            " AND st.utm_medium = ''" ++
            " AND st.referrer = '' THEN 'Direct'" ++
            " WHEN lower(st.utm_medium) IN ('cpc', 'ppc', 'paidsearch')" ++
            " THEN 'Paid Search'" ++
            " WHEN lower(st.utm_medium) = 'organic' THEN 'Organic Search'" ++
            " WHEN lower(st.utm_medium) IN" ++
            " ('social', 'social-network', 'social-media', 'sm') THEN 'Social'" ++
            " WHEN lower(st.utm_medium) = 'email' THEN 'Email'" ++
            " WHEN lower(st.utm_medium) = 'referral' OR" ++
            " (st.referrer <> '' AND st.utm_source = ''" ++
            " AND st.utm_medium = '') THEN 'Referral'" ++
            " ELSE 'Other / Unknown' END AS channel",
    );
    try builder.write(
        ", greatest(0, (st.last_at - st.first_at) / 1000)::BIGINT" ++
            " AS duration_ms, st.engagement_ms, st.page_views," ++
            " (st.engagement_ms >= 10000 OR st.page_views >= 2" ++
            " OR st.converted) AS engaged, st.converted" ++
            " FROM session_summary st)",
    );
    if (hasUserTraitClause(execution.filters.clauses)) {
        try writePersonTraits(
            builder,
            execution.site_id,
            execution.strict_traffic_mode,
            true,
        );
    }
    try builder.write(", qualified AS ");
    if (selection == null) try builder.write("NOT ");
    try builder.write(
        "MATERIALIZED (SELECT e.period, e.session_id," ++
            " e.kind, e.value_amount, e.value_currency, e.identity_quality," ++
            " e.person_key, e.goal_matches, e.goal_mask",
    );
    if (selection != null) try builder.write(
        ", e.path, e.bucket_label",
    );
    try builder.write(
        " FROM base e" ++
            " JOIN session_facts s USING (period, session_id) WHERE TRUE",
    );
    for (execution.filters.clauses) |clause| {
        try builder.write(" AND ");
        try writePeriodClause(builder, clause, "e", "s");
    }
    try builder.write(")");
}

fn writePeriodClause(
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
            try builder.write("EXISTS (SELECT 1 FROM base sf WHERE sf.period = ");
            try builder.write(event_alias);
            try builder.write(".period AND sf.session_id = ");
            try builder.write(event_alias);
            try builder.write(".session_id AND ");
            try writeFieldPredicate(builder, clause, "sf");
            try builder.write(")");
        },
        .person => {
            if (clause.field.kind == .identity_state) {
                return writeIdentityStatePredicate(builder, clause, event_alias);
            }
            try builder.write(event_alias);
            try builder.write(".person_key IS NOT NULL AND EXISTS (SELECT 1 FROM ");
            try builder.write(if (clause.field.kind == .user_trait)
                "person_traits"
            else
                "base");
            try builder.write(" pf WHERE pf.person_key = ");
            try builder.write(event_alias);
            try builder.write(".person_key");
            if (clause.field.kind != .user_trait) {
                try builder.write(" AND pf.period = ");
                try builder.write(event_alias);
                try builder.write(".period");
            }
            try builder.write(" AND ");
            try writeFieldPredicate(builder, clause, "pf");
            try builder.write(")");
        },
    }
}

fn writeIdentityStatePredicate(
    builder: *Builder,
    clause: analysis.Clause,
    alias: []const u8,
) !void {
    switch (clause.operator) {
        .is, .is_not => {
            try builder.write(alias);
            try builder.write(if (clause.operator == .is)
                ".identity_state IN ("
            else
                ".identity_state NOT IN (");
            for (clause.values, 0..) |value, index| {
                if (index != 0) try builder.write(", ");
                try builder.bindText(value);
            }
            try builder.write(")");
        },
        .contains, .not_contains, .starts_with => {
            try builder.write("(");
            for (clause.values, 0..) |value, index| {
                if (index != 0) try builder.write(
                    if (clause.operator == .not_contains) " AND " else " OR ",
                );
                if (clause.operator == .not_contains) try builder.write("NOT ");
                try builder.write(if (clause.operator == .starts_with)
                    "starts_with("
                else
                    "contains(");
                try builder.write(alias);
                try builder.write(".identity_state, ");
                try builder.bindText(value);
                try builder.write(")");
            }
            try builder.write(")");
        },
        .exists, .absent => {
            try builder.write(alias);
            try builder.write(if (clause.operator == .exists)
                ".identity_state <> ''"
            else
                ".identity_state = ''");
        },
        .gt, .gte, .lt, .lte, .is_true, .is_false => unreachable,
    }
}

fn writeFilteredOverviewAggregates(
    builder: *Builder,
    execution: analysis.OverviewExecution,
) !void {
    try builder.write(
        ", event_summary AS (SELECT period," ++
            " count(*) FILTER (WHERE kind = 1)::BIGINT AS page_views," ++
            " COALESCE(sum(goal_matches), 0)::BIGINT AS conversions" ++
            " FROM qualified GROUP BY period),",
    );
    if (usesOnlySessionFacts(execution.filters)) {
        try builder.write(
            " qualified_sessions AS (SELECT period, session_id" ++
                " FROM session_facts s WHERE TRUE",
        );
        for (execution.filters.clauses) |clause| {
            try builder.write(" AND ");
            try writePeriodClause(builder, clause, "s", "s");
        }
        try builder.write("),");
    } else try builder.write(
        " qualified_sessions AS (SELECT DISTINCT period, session_id" ++
            " FROM qualified),",
    );
    try builder.write(
        " engagement_summary AS (SELECT q.period," ++
            " count(*)::BIGINT AS sessions," ++
            " count(*) FILTER (WHERE s.engaged)::BIGINT AS engaged_sessions" ++
            " FROM qualified_sessions q JOIN session_facts s" ++
            " USING (period, session_id) GROUP BY q.period)," ++
            " person_rows AS MATERIALIZED (SELECT period, person_key," ++
            " max(identity_quality)::UTINYINT AS identity_quality," ++
            " bit_or(goal_mask)::UBIGINT AS goal_mask FROM qualified" ++
            " WHERE person_key IS NOT NULL GROUP BY period, person_key),",
    );
    try builder.write(
        " person_summary AS (SELECT period, count(*)::BIGINT AS visitors," ++
            " count(*) FILTER (WHERE identity_quality = 1)::BIGINT" ++
            " AS persistent," ++
            " count(*) FILTER (WHERE identity_quality = 2)::BIGINT" ++
            " AS ephemeral," ++
            " count(*) FILTER (WHERE identity_quality = 3)::BIGINT AS legacy," ++
            " count(*) FILTER (WHERE goal_mask <> 0)::BIGINT" ++
            " AS converting_visitors" ++
            " FROM person_rows GROUP BY period)," ++
            " summary_values AS (SELECT e.period, g.sessions, e.page_views," ++
            " g.engaged_sessions, e.conversions, p.visitors, p.persistent," ++
            " p.ephemeral, p.legacy, p.converting_visitors" ++
            " FROM event_summary e JOIN engagement_summary g USING (period)" ++
            " JOIN person_summary p USING (period))," ++
            " overview_summary AS MATERIALIZED (SELECT p.period," ++
            " COALESCE(v.sessions, 0)::BIGINT AS sessions," ++
            " COALESCE(v.page_views, 0)::BIGINT AS page_views," ++
            " COALESCE(v.engaged_sessions, 0)::BIGINT AS engaged_sessions," ++
            " COALESCE(v.conversions, 0)::BIGINT AS conversions," ++
            " COALESCE(v.visitors, 0)::BIGINT AS visitors," ++
            " COALESCE(v.persistent, 0)::BIGINT AS persistent," ++
            " COALESCE(v.ephemeral, 0)::BIGINT AS ephemeral," ++
            " COALESCE(v.legacy, 0)::BIGINT AS legacy," ++
            " COALESCE(v.converting_visitors, 0)::BIGINT AS converting_visitors" ++
            " FROM periods p LEFT JOIN summary_values v USING (period))," ++
            " overview_revenue AS (SELECT e.period," ++
            " e.value_currency AS currency," ++
            " CAST(sum(e.value_amount) AS VARCHAR) AS amount," ++
            " count(*)::BIGINT AS value_count," ++
            " row_number() OVER (PARTITION BY e.period" ++
            " ORDER BY e.value_currency) AS position" ++
            " FROM base e JOIN session_facts s USING (period, session_id)" ++
            " WHERE e.value_amount IS NOT NULL AND e.value_currency <> ''",
    );
    for (execution.filters.clauses) |clause| {
        try builder.write(" AND ");
        try writePeriodClause(builder, clause, "e", "s");
    }
    try builder.write(
        " GROUP BY e.period, e.value_currency)," ++
            " history_currencies AS (SELECT value_currency FROM events" ++
            " WHERE site_id = ",
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
        " GROUP BY value_currency ORDER BY value_currency LIMIT ",
    );
    try builder.bindInteger(@as(i64, analysis.maximum_currency_series) + 1);
    try builder.write(")");
}

pub fn compileFilteredOverview(
    allocator: std.mem.Allocator,
    execution: analysis.OverviewExecution,
) !StatementPlan {
    try execution.validate();
    if (execution.filters.clauses.len == 0) return error.MissingAnalysisFilters;
    var builder = Builder.init(allocator);
    try writeFilteredOverviewCommon(&builder, execution, null, false);
    try writeFilteredOverviewAggregates(&builder, execution);
    try builder.write(
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
            " ELSE 'comparison' END, 'revenue', 0::BIGINT, 0::BIGINT," ++
            " r.amount, r.currency, r.value_count, o.persistent, o.ephemeral," ++
            " o.legacy, CAST(NULL AS VARCHAR)" ++
            " FROM overview_revenue r JOIN overview_summary o USING (period)" ++
            " WHERE r.position <= ",
    );
    try builder.bindInteger(@as(i64, analysis.maximum_currency_series) + 1);
    try builder.write(
        " UNION ALL SELECT 'history', 'revenue', 0::BIGINT, 0::BIGINT," ++
            " CAST(NULL AS VARCHAR), value_currency, 0::BIGINT, 0::BIGINT," ++
            " 0::BIGINT, 0::BIGINT, CAST(NULL AS VARCHAR)" ++
            " FROM history_currencies",
    );
    return builder.finish();
}

pub fn compileFilteredOverviewDetails(
    allocator: std.mem.Allocator,
    execution: analysis.OverviewExecution,
) !StatementPlan {
    try execution.validate();
    if (execution.filters.clauses.len == 0) return error.MissingAnalysisFilters;
    const selection = execution.trend orelse return error.MissingOverviewTrend;
    var builder = Builder.init(allocator);
    try writeFilteredOverviewCommon(&builder, execution, selection, true);
    try writeFilteredOverviewAggregates(&builder, execution);
    try builder.write(", trend_buckets(period, position, label) AS (VALUES ");
    var first = true;
    for (selection.current_buckets, 0..) |bucket, index| {
        if (!first) try builder.write(", ");
        first = false;
        try builder.write("(1::UTINYINT, ");
        try builder.bindInteger(@intCast(index));
        try builder.write("::UINTEGER, ");
        try builder.bindText(bucket.label);
        try builder.write(")");
    }
    for (selection.comparison_buckets, 0..) |bucket, index| {
        if (!first) try builder.write(", ");
        first = false;
        try builder.write("(2::UTINYINT, ");
        try builder.bindInteger(@intCast(index));
        try builder.write("::UINTEGER, ");
        try builder.bindText(bucket.label);
        try builder.write(")");
    }
    if (first) return error.MissingOverviewBuckets;
    try builder.write("), trend_values AS (");
    switch (selection.metric) {
        .visitors => try builder.write(
            "SELECT period, bucket_label AS label," ++
                " count(DISTINCT person_key)::BIGINT AS numerator," ++
                " CAST(NULL AS VARCHAR) AS amount FROM qualified" ++
                " GROUP BY period, label",
        ),
        .sessions => try builder.write(
            "SELECT period, bucket_label AS label," ++
                " count(DISTINCT session_id)::BIGINT AS numerator," ++
                " CAST(NULL AS VARCHAR) AS amount FROM qualified" ++
                " GROUP BY period, label",
        ),
        .page_views => try builder.write(
            "SELECT period, bucket_label AS label," ++
                " count(*) FILTER (WHERE kind = 1)::BIGINT AS numerator," ++
                " CAST(NULL AS VARCHAR) AS amount FROM qualified" ++
                " GROUP BY period, label",
        ),
        .conversions => try builder.write(
            "SELECT period, bucket_label AS label," ++
                " COALESCE(sum(goal_matches), 0)::BIGINT AS numerator," ++
                " CAST(NULL AS VARCHAR) AS amount FROM qualified" ++
                " GROUP BY period, label",
        ),
        .revenue => {
            try builder.write(
                "SELECT period, bucket_label AS label, 0::BIGINT AS numerator," ++
                    " CAST(sum(value_amount) AS VARCHAR) AS amount" ++
                    " FROM qualified WHERE value_amount IS NOT NULL" ++
                    " AND value_currency = ",
            );
            try builder.bindText(selection.currency);
            try builder.write(" GROUP BY period, label");
        },
    }
    try builder.write(
        "), trend_rows AS (SELECT b.period, b.position, b.label," ++
            " COALESCE(v.numerator, 0)::BIGINT AS numerator," ++
            " COALESCE(v.amount, '0.000000') AS amount" ++
            " FROM trend_buckets b LEFT JOIN trend_values v" ++
            " ON v.period = b.period AND v.label = b.label)," ++
            " current_sessions AS NOT MATERIALIZED (SELECT session_id" ++
            " FROM qualified_sessions WHERE period = 1)," ++
            " content_rows AS (SELECT path, count(*)::BIGINT AS page_views," ++
            " count(DISTINCT person_key)::BIGINT AS visitors" ++
            " FROM qualified WHERE period = 1 AND kind = 1 GROUP BY path)," ++
            " acquisition_rows AS (SELECT" ++
            " COALESCE(NULLIF(sf.referrer, ''), 'Direct') AS source," ++
            " count(*)::BIGINT AS sessions," ++
            " count(*) FILTER (WHERE sf.converted)::BIGINT AS converting_sessions" ++
            " FROM current_sessions cs JOIN session_facts sf" ++
            " ON sf.period = 1 AND sf.session_id = cs.session_id" ++
            " GROUP BY source)," ++
            " audience_rows AS (SELECT sf.country, count(*)::BIGINT AS sessions" ++
            " FROM current_sessions cs JOIN session_facts sf" ++
            " ON sf.period = 1 AND sf.session_id = cs.session_id" ++
            " GROUP BY sf.country), goal_rows AS (",
    );
    if (execution.active_goals.len == 0) {
        try builder.write(
            "SELECT '' AS goal_id, 0::UINTEGER AS goal_position," ++
                " 0::BIGINT AS converting_people WHERE FALSE",
        );
    } else for (execution.active_goals, 0..) |goal, index| {
        if (index != 0) try builder.write(" UNION ALL ");
        try builder.write("SELECT ");
        try builder.bindText(goal.id);
        try builder.write(" AS goal_id, ");
        try builder.bindInteger(@intCast(index));
        try builder.write(
            "::UINTEGER AS goal_position," ++
                " count(*)::BIGINT AS converting_people" ++
                " FROM person_rows e WHERE e.period = 1" ++
                " AND (e.goal_mask & ",
        );
        try builder.bindInteger(@as(i64, 1) << @intCast(index));
        try builder.write("::UBIGINT) <> 0");
    }
    try builder.write(
        "), health_days AS MATERIALIZED (SELECT site_local_date," ++
            " count(*)::BIGINT AS accepted_events," ++
            " COALESCE(max(received_at_utc_micros), 0)::BIGINT AS last_received," ++
            " count(*) FILTER (WHERE protocol_version = 1)::BIGINT AS protocol_v1," ++
            " count(*) FILTER (WHERE protocol_version = 2)::BIGINT AS protocol_v2" ++
            " FROM events WHERE site_id = ",
    );
    try builder.bindText(execution.site_id);
    try builder.write(
        " GROUP BY site_local_date), health_row AS (SELECT" ++
            " COALESCE(sum(accepted_events), 0)::BIGINT AS accepted_events," ++
            " COALESCE(max(last_received), 0)::BIGINT AS last_received," ++
            " COALESCE(sum(protocol_v1), 0)::BIGINT AS protocol_v1," ++
            " COALESCE(sum(protocol_v2), 0)::BIGINT AS protocol_v2," ++
            " count(*) FILTER (WHERE site_local_date BETWEEN CAST(",
    );
    try builder.bindText(execution.range.start);
    try builder.write(" AS DATE) AND CAST(");
    try builder.bindText(execution.range.end);
    try builder.write(" AS DATE) AND accepted_events >= ");
    try builder.bindInteger(execution.daily_event_ceiling);
    try builder.write(
        ")::BIGINT AS ceiling_reached_days FROM health_days)" ++
            " SELECT 'detail' AS period, 'trend' AS metric," ++
            " t.position::BIGINT AS numerator, t.numerator AS denominator," ++
            " t.amount, ",
    );
    if (selection.metric == .revenue) {
        try builder.bindText(selection.currency);
    } else try builder.write("''");
    try builder.write(
        " AS currency, 0::BIGINT AS value_count," ++
            " t.period::BIGINT AS persistent, 0::BIGINT AS ephemeral," ++
            " 0::BIGINT AS legacy, t.label AS text_value FROM trend_rows t" ++
            " UNION ALL SELECT * FROM (SELECT 'detail', 'content'," ++
            " row_number() OVER (ORDER BY page_views DESC, path ASC)::BIGINT," ++
            " page_views, CAST(NULL AS VARCHAR), '', visitors," ++
            " 0::BIGINT, 0::BIGINT, 0::BIGINT, path FROM content_rows" ++
            " ORDER BY page_views DESC, path ASC LIMIT 5)" ++
            " UNION ALL SELECT * FROM (SELECT 'detail', 'acquisition'," ++
            " row_number() OVER (ORDER BY sessions DESC, source ASC)::BIGINT," ++
            " sessions, CAST(NULL AS VARCHAR), '', converting_sessions," ++
            " 0::BIGINT, 0::BIGINT, 0::BIGINT, source FROM acquisition_rows" ++
            " ORDER BY sessions DESC, source ASC LIMIT 5)" ++
            " UNION ALL SELECT * FROM (SELECT 'detail', 'conversion'," ++
            " row_number() OVER (ORDER BY converting_people DESC," ++
            " goal_position ASC)::BIGINT, converting_people," ++
            " CAST(NULL AS VARCHAR), '', 0::BIGINT," ++
            " 0::BIGINT, 0::BIGINT, 0::BIGINT, goal_id" ++
            " FROM goal_rows ORDER BY converting_people DESC," ++
            " goal_position ASC LIMIT 5)" ++
            " UNION ALL SELECT * FROM (SELECT 'detail', 'audience'," ++
            " row_number() OVER (ORDER BY sessions DESC, country ASC)::BIGINT," ++
            " sessions, CAST(NULL AS VARCHAR), '', 0::BIGINT," ++
            " 0::BIGINT, 0::BIGINT, 0::BIGINT, country FROM audience_rows" ++
            " ORDER BY sessions DESC, country ASC LIMIT 5)" ++
            " UNION ALL SELECT 'detail', 'health', 0::BIGINT," ++
            " accepted_events, CAST(NULL AS VARCHAR), '', last_received," ++
            " protocol_v1, protocol_v2, ceiling_reached_days, ''" ++
            " FROM health_row" ++
            " UNION ALL SELECT CASE o.period WHEN 1 THEN 'current'" ++
            " ELSE 'comparison' END, v.metric, v.numerator::BIGINT," ++
            " v.denominator::BIGINT, CAST(NULL AS VARCHAR), '', 0::BIGINT," ++
            " o.persistent, o.ephemeral, o.legacy, CAST(NULL AS VARCHAR)" ++
            " FROM overview_summary o CROSS JOIN LATERAL (VALUES" ++
            " ('visitors', o.visitors, 0)," ++
            " ('sessions', o.sessions, 0)," ++
            " ('page-views', o.page_views, 0)," ++
            " ('engagement-rate', o.engaged_sessions, o.sessions)," ++
            " ('conversions', o.conversions, 0)," ++
            " ('conversion-rate', o.converting_visitors, o.visitors)" ++
            ") v(metric, numerator, denominator)" ++
            " UNION ALL SELECT CASE r.period WHEN 1 THEN 'current'" ++
            " ELSE 'comparison' END, 'revenue', 0::BIGINT, 0::BIGINT," ++
            " r.amount, r.currency, r.value_count, o.persistent, o.ephemeral," ++
            " o.legacy, CAST(NULL AS VARCHAR)" ++
            " FROM overview_revenue r JOIN overview_summary o USING (period)" ++
            " WHERE r.position <= ",
    );
    try builder.bindInteger(@as(i64, analysis.maximum_currency_series) + 1);
    try builder.write(
        " UNION ALL SELECT 'history', 'revenue', 0::BIGINT, 0::BIGINT," ++
            " CAST(NULL AS VARCHAR), value_currency, 0::BIGINT, 0::BIGINT," ++
            " 0::BIGINT, 0::BIGINT, CAST(NULL AS VARCHAR)" ++
            " FROM history_currencies" ++
            " ORDER BY period, metric, persistent, numerator",
    );
    return builder.finish();
}

pub fn executeOverview(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    execution: analysis.OverviewExecution,
) !analysis.OverviewResult {
    try execution.validate();
    const cache_key = if (execution.trend != null)
        try overviewCacheKey(allocator, execution)
    else
        null;
    if (cache_key) |key| {
        if (event_store.overview_result_cache) |cache| {
            if (std.mem.eql(u8, cache.key, key)) {
                return cloneOverviewResult(allocator, cache.result);
            }
        }
    }
    const filtered = execution.filters.clauses.len != 0;
    const combined_filtered = filtered and execution.trend != null;
    const plan = if (combined_filtered)
        try compileFilteredOverviewDetails(allocator, execution)
    else if (filtered)
        try compileFilteredOverview(allocator, execution)
    else
        try compileOverview(allocator, execution);
    var budget = deadline.Budget.init(execution.timeout_ms);
    var result = try executePlan(&event_store.database, plan, &budget);
    var decoded = decodeOverview(allocator, execution, &result) catch |err| {
        result.deinit();
        return err;
    };
    if (combined_filtered) {
        decoded.details = decodeOverviewDetails(
            allocator,
            execution,
            &result,
        ) catch |err| {
            result.deinit();
            return err;
        };
        result.deinit();
        try cacheOverviewResult(event_store, cache_key.?, decoded);
        return decoded;
    }
    result.deinit();
    if (execution.trend != null) {
        const detail_plan = if (filtered)
            try compileFilteredOverviewDetails(allocator, execution)
        else
            try compileOverviewDetails(allocator, execution);
        var detail_result = try executePlan(
            &event_store.database,
            detail_plan,
            &budget,
        );
        defer detail_result.deinit();
        decoded.details = try decodeOverviewDetails(
            allocator,
            execution,
            &detail_result,
        );
        try cacheOverviewResult(
            event_store,
            cache_key.?,
            decoded,
        );
    }
    return decoded;
}

fn overviewCacheKey(
    allocator: std.mem.Allocator,
    execution: analysis.OverviewExecution,
) ![]const u8 {
    const trend = execution.trend orelse return error.MissingOverviewTrend;
    var key = std.Io.Writer.Allocating.init(allocator);
    try key.writer.writeAll("overview-result-v2|metric-v2|");
    try cacheKeySlice(&key.writer, execution.site_id);
    try cacheKeySlice(&key.writer, execution.range.start);
    try cacheKeySlice(&key.writer, execution.range.end);
    if (execution.comparison_range) |range| {
        try key.writer.writeAll("comparison|");
        try cacheKeySlice(&key.writer, range.start);
        try cacheKeySlice(&key.writer, range.end);
    } else try key.writer.writeAll("no-comparison|");
    try key.writer.print("strict={d}|ceiling={d}|metric={s}|interval={s}|", .{
        @intFromBool(execution.strict_traffic_mode),
        execution.daily_event_ceiling,
        trend.metric.name(),
        @tagName(trend.interval),
    });
    try cacheKeySlice(&key.writer, trend.currency);
    const canonical_filters = try analysis.canonicalFilterJson(
        allocator,
        execution.filters,
    );
    defer allocator.free(canonical_filters);
    try cacheKeySlice(&key.writer, canonical_filters);
    try key.writer.print("goals={d}|", .{execution.active_goals.len});
    for (execution.active_goals) |goal| {
        try cacheKeySlice(&key.writer, goal.id);
        try cacheKeySlice(&key.writer, @tagName(goal.selector.kind));
        try cacheKeySlice(&key.writer, goal.selector.value);
        try key.writer.print("predicates={d}|", .{goal.selector.predicates.len});
        for (goal.selector.predicates) |predicate| {
            try cacheKeySlice(&key.writer, predicate.property_ref.name);
            try cacheKeySlice(
                &key.writer,
                predicate.property_ref.scalar_type.name(),
            );
            try cacheKeySlice(&key.writer, predicate.operator.name());
            try key.writer.print("values={d}|", .{predicate.values.len});
            for (predicate.values) |value| {
                try cacheKeySlice(&key.writer, value);
            }
        }
    }
    try key.writer.print("current={d}|", .{trend.current_buckets.len});
    for (trend.current_buckets) |bucket| try cacheKeySlice(&key.writer, bucket.label);
    try key.writer.print("comparison={d}|", .{trend.comparison_buckets.len});
    for (trend.comparison_buckets) |bucket| try cacheKeySlice(&key.writer, bucket.label);
    return key.toOwnedSlice();
}

fn cacheKeySlice(output: *std.Io.Writer, value: []const u8) !void {
    try output.print("{d}:", .{value.len});
    try output.writeAll(value);
    try output.writeByte('|');
}

fn cacheOverviewResult(
    event_store: *events.Store,
    key: []const u8,
    result: analysis.OverviewResult,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const owned_key = try allocator.dupe(u8, key);
    const owned_result = try cloneOverviewResult(allocator, result);
    if (event_store.overview_result_cache) |*prior| prior.deinit();
    event_store.overview_result_cache = .{
        .arena = arena,
        .key = owned_key,
        .result = owned_result,
    };
}

fn cloneOverviewResult(
    allocator: std.mem.Allocator,
    source: analysis.OverviewResult,
) !analysis.OverviewResult {
    return .{
        .visitors = source.visitors,
        .sessions = source.sessions,
        .page_views = source.page_views,
        .engagement_rate = source.engagement_rate,
        .conversions = source.conversions,
        .conversion_rate = source.conversion_rate,
        .revenue = try cloneComparedAmounts(allocator, source.revenue),
        .completeness = try cloneCompleteness(allocator, source.completeness),
        .comparison_completeness = if (source.comparison_completeness) |value|
            try cloneCompleteness(allocator, value)
        else
            null,
        .details = if (source.details) |details|
            try cloneOverviewDetails(allocator, details)
        else
            null,
    };
}

fn cloneComparedAmounts(
    allocator: std.mem.Allocator,
    source: []const analysis.ComparedAmount,
) ![]const analysis.ComparedAmount {
    const output = try allocator.alloc(analysis.ComparedAmount, source.len);
    for (output, source) |*target, value| target.* = .{
        .currency = try allocator.dupe(u8, value.currency),
        .current = try cloneExactAmount(allocator, value.current),
        .comparison = if (value.comparison) |comparison|
            try cloneExactAmount(allocator, comparison)
        else
            null,
    };
    return output;
}

fn cloneExactAmount(
    allocator: std.mem.Allocator,
    source: analysis.ExactAmount,
) !analysis.ExactAmount {
    return .{
        .decimal = try allocator.dupe(u8, source.decimal),
        .currency = try allocator.dupe(u8, source.currency),
        .value_count = source.value_count,
    };
}

fn cloneCompleteness(
    allocator: std.mem.Allocator,
    source: analysis.Completeness,
) !analysis.Completeness {
    return .{
        .total_people = source.total_people,
        .persistent_people = source.persistent_people,
        .ephemeral_people = source.ephemeral_people,
        .legacy_people = source.legacy_people,
        .persistent_basis_points = source.persistent_basis_points,
        .persistent_since_local_date = if (source.persistent_since_local_date) |date|
            try allocator.dupe(u8, date)
        else
            null,
    };
}

fn cloneOverviewDetails(
    allocator: std.mem.Allocator,
    source: analysis.OverviewDetails,
) !analysis.OverviewDetails {
    return .{
        .trend = .{
            .metric = source.trend.metric,
            .currency = try allocator.dupe(u8, source.trend.currency),
            .interval = source.trend.interval,
            .current = try cloneOverviewTrendPoints(allocator, source.trend.current),
            .comparison = if (source.trend.comparison) |points|
                try cloneOverviewTrendPoints(allocator, points)
            else
                null,
        },
        .content = try cloneOverviewContent(allocator, source.content),
        .acquisition = try cloneOverviewAcquisition(allocator, source.acquisition),
        .conversions = try cloneOverviewConversions(allocator, source.conversions),
        .audience = try cloneOverviewAudience(allocator, source.audience),
        .health = source.health,
    };
}

fn cloneOverviewTrendPoints(
    allocator: std.mem.Allocator,
    source: []const analysis.OverviewTrendPoint,
) ![]const analysis.OverviewTrendPoint {
    const output = try allocator.alloc(analysis.OverviewTrendPoint, source.len);
    for (output, source) |*target, point| target.* = .{
        .label = try allocator.dupe(u8, point.label),
        .measure = switch (point.measure) {
            .count => |value| .{ .count = value },
            .ratio => |value| .{ .ratio = value },
            .amount => |value| .{ .amount = .{
                .decimal = try allocator.dupe(u8, value.decimal),
                .currency = try allocator.dupe(u8, value.currency),
                .value_count = value.value_count,
            } },
        },
    };
    return output;
}

fn cloneOverviewContent(
    allocator: std.mem.Allocator,
    source: []const analysis.OverviewContentRow,
) ![]const analysis.OverviewContentRow {
    const output = try allocator.alloc(analysis.OverviewContentRow, source.len);
    for (output, source) |*target, row| target.* = .{
        .path = try allocator.dupe(u8, row.path),
        .page_views = row.page_views,
        .visitors = row.visitors,
    };
    return output;
}

fn cloneOverviewAcquisition(
    allocator: std.mem.Allocator,
    source: []const analysis.OverviewAcquisitionRow,
) ![]const analysis.OverviewAcquisitionRow {
    const output = try allocator.alloc(analysis.OverviewAcquisitionRow, source.len);
    for (output, source) |*target, row| target.* = .{
        .source = try allocator.dupe(u8, row.source),
        .sessions = row.sessions,
        .converting_sessions = row.converting_sessions,
    };
    return output;
}

fn cloneOverviewConversions(
    allocator: std.mem.Allocator,
    source: []const analysis.OverviewConversionRow,
) ![]const analysis.OverviewConversionRow {
    const output = try allocator.alloc(analysis.OverviewConversionRow, source.len);
    for (output, source) |*target, row| target.* = .{
        .goal_id = try allocator.dupe(u8, row.goal_id),
        .converting_people = row.converting_people,
    };
    return output;
}

fn cloneOverviewAudience(
    allocator: std.mem.Allocator,
    source: []const analysis.OverviewAudienceRow,
) ![]const analysis.OverviewAudienceRow {
    const output = try allocator.alloc(analysis.OverviewAudienceRow, source.len);
    for (output, source) |*target, row| target.* = .{
        .country = try allocator.dupe(u8, row.country),
        .sessions = row.sessions,
    };
    return output;
}

fn decodeOverview(
    allocator: std.mem.Allocator,
    execution: analysis.OverviewExecution,
    result: *duckdb.Result,
) !analysis.OverviewResult {
    const maximum_rows = 64 + if (execution.filters.clauses.len != 0)
        if (execution.trend) |trend|
            trend.current_buckets.len + trend.comparison_buckets.len +
                analysis.maximum_overview_panel_rows * 4 + 1
        else
            0
    else
        0;
    if (result.columnCount() != 11 or result.rowCount() > maximum_rows) {
        return error.InvalidOverviewResult;
    }

    var current = OverviewPeriodState{};
    var comparison = OverviewPeriodState{};
    var revenues: std.ArrayList(MutableRevenue) = .empty;
    defer revenues.deinit(allocator);

    for (0..result.rowCount()) |row| {
        const period = try result.text(allocator, 0, row);
        if (std.mem.eql(u8, period, "detail")) continue;
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
        .details = null,
    };
}

fn decodeOverviewDetails(
    allocator: std.mem.Allocator,
    execution: analysis.OverviewExecution,
    result: *duckdb.Result,
) !analysis.OverviewDetails {
    const selection = execution.trend orelse return error.MissingOverviewTrend;
    const combined = result.columnCount() == 11;
    const maximum_rows: usize = selection.current_buckets.len +
        selection.comparison_buckets.len +
        analysis.maximum_overview_panel_rows * 4 + 1 +
        (if (combined) @as(usize, 64) else @as(usize, 0));
    if ((result.columnCount() != 10 and !combined) or
        result.rowCount() > maximum_rows)
    {
        return error.InvalidOverviewDetails;
    }
    var current: std.ArrayList(analysis.OverviewTrendPoint) = .empty;
    var comparison: std.ArrayList(analysis.OverviewTrendPoint) = .empty;
    var content: std.ArrayList(analysis.OverviewContentRow) = .empty;
    var acquisition: std.ArrayList(analysis.OverviewAcquisitionRow) = .empty;
    var conversions: std.ArrayList(analysis.OverviewConversionRow) = .empty;
    var audience: std.ArrayList(analysis.OverviewAudienceRow) = .empty;
    var health: ?analysis.OverviewHealth = null;

    for (0..result.rowCount()) |row| {
        if (combined and !std.mem.eql(
            u8,
            try result.text(allocator, 0, row),
            "detail",
        )) continue;
        const section = try result.text(allocator, if (combined) 1 else 0, row);
        const label = try result.text(allocator, if (combined) 10 else 1, row);
        const position = result.int64(2, row);
        const numerator = result.int64(3, row);
        const denominator = result.int64(if (combined) 6 else 4, row);
        if (position < 0 or numerator < 0 or denominator < 0) {
            return error.InvalidOverviewDetails;
        }
        if (std.mem.eql(u8, section, "trend")) {
            const period = result.int64(7, row);
            const buckets = if (period == 1)
                selection.current_buckets
            else if (period == 2)
                selection.comparison_buckets
            else
                return error.InvalidOverviewDetails;
            if (position >= buckets.len or
                !std.mem.eql(u8, label, buckets[@intCast(position)].label))
            {
                return error.InvalidOverviewDetails;
            }
            const point = analysis.OverviewTrendPoint{
                .label = label,
                .measure = if (selection.metric == .revenue)
                    .{ .amount = .{
                        .decimal = try result.text(
                            allocator,
                            if (combined) 4 else 5,
                            row,
                        ),
                        .currency = try result.text(
                            allocator,
                            if (combined) 5 else 6,
                            row,
                        ),
                        .value_count = 0,
                    } }
                else
                    .{ .count = numerator },
            };
            if (period == 1) {
                if (position != current.items.len) return error.InvalidOverviewDetails;
                try current.append(allocator, point);
            } else {
                if (position != comparison.items.len) return error.InvalidOverviewDetails;
                try comparison.append(allocator, point);
            }
        } else if (std.mem.eql(u8, section, "content")) {
            if (position != content.items.len + 1 or denominator > numerator) {
                return error.InvalidOverviewDetails;
            }
            try content.append(allocator, .{
                .path = label,
                .page_views = numerator,
                .visitors = denominator,
            });
        } else if (std.mem.eql(u8, section, "acquisition")) {
            if (position != acquisition.items.len + 1 or denominator > numerator) {
                return error.InvalidOverviewDetails;
            }
            try acquisition.append(allocator, .{
                .source = label,
                .sessions = numerator,
                .converting_sessions = denominator,
            });
        } else if (std.mem.eql(u8, section, "conversion")) {
            if (position != conversions.items.len + 1) return error.InvalidOverviewDetails;
            try conversions.append(allocator, .{
                .goal_id = label,
                .converting_people = numerator,
            });
        } else if (std.mem.eql(u8, section, "audience")) {
            if (position != audience.items.len + 1) return error.InvalidOverviewDetails;
            try audience.append(allocator, .{
                .country = label,
                .sessions = numerator,
            });
        } else if (std.mem.eql(u8, section, "health")) {
            if (health != null or label.len != 0 or position != 0) {
                return error.InvalidOverviewDetails;
            }
            health = .{
                .daily_event_ceiling = execution.daily_event_ceiling,
                .accepted_events = numerator,
                .ceiling_reached_days = result.int64(9, row),
                .last_received_at_utc_micros = denominator,
                .protocol_v1_events = result.int64(7, row),
                .protocol_v2_events = result.int64(8, row),
            };
            if (health.?.protocol_v1_events < 0 or health.?.protocol_v2_events < 0 or
                health.?.ceiling_reached_days < 0 or
                health.?.ceiling_reached_days > @as(i64, @intCast(try execution.range.days())) or
                health.?.protocol_v1_events + health.?.protocol_v2_events != numerator)
            {
                return error.InvalidOverviewDetails;
            }
        } else return error.InvalidOverviewDetails;
    }
    if (current.items.len != selection.current_buckets.len or
        comparison.items.len != selection.comparison_buckets.len or health == null or
        content.items.len > analysis.maximum_overview_panel_rows or
        acquisition.items.len > analysis.maximum_overview_panel_rows or
        conversions.items.len > analysis.maximum_overview_panel_rows or
        audience.items.len > analysis.maximum_overview_panel_rows)
    {
        return error.InvalidOverviewDetails;
    }
    return .{
        .trend = .{
            .metric = selection.metric,
            .currency = selection.currency,
            .interval = selection.interval,
            .current = try current.toOwnedSlice(allocator),
            .comparison = if (execution.comparison_range != null)
                try comparison.toOwnedSlice(allocator)
            else
                null,
        },
        .content = try content.toOwnedSlice(allocator),
        .acquisition = try acquisition.toOwnedSlice(allocator),
        .conversions = try conversions.toOwnedSlice(allocator),
        .audience = try audience.toOwnedSlice(allocator),
        .health = health.?,
    };
}

pub fn profileOverview(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    execution: analysis.OverviewExecution,
) ![]u8 {
    try execution.validate();
    const filtered = execution.filters.clauses.len != 0;
    var output = std.Io.Writer.Allocating.init(allocator);
    if (filtered and execution.trend != null) {
        try output.writer.writeAll("OVERVIEW COMBINED STATEMENT\n");
        try profileOverviewPlan(
            allocator,
            event_store,
            try compileFilteredOverviewDetails(allocator, execution),
            &output.writer,
        );
        return output.toOwnedSlice();
    }
    try output.writer.writeAll("OVERVIEW KPI STATEMENT\n");
    try profileOverviewPlan(
        allocator,
        event_store,
        if (filtered)
            try compileFilteredOverview(allocator, execution)
        else
            try compileOverview(allocator, execution),
        &output.writer,
    );
    if (execution.trend != null) {
        try output.writer.writeAll("OVERVIEW DETAILS STATEMENT\n");
        try profileOverviewPlan(
            allocator,
            event_store,
            if (filtered)
                try compileFilteredOverviewDetails(allocator, execution)
            else
                try compileOverviewDetails(allocator, execution),
            &output.writer,
        );
    }
    return output.toOwnedSlice();
}

fn profileOverviewPlan(
    allocator: std.mem.Allocator,
    event_store: *events.Store,
    plan: StatementPlan,
    output: *std.Io.Writer,
) !void {
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
    for (0..result.rowCount()) |row| {
        try output.writeAll(try result.text(allocator, 1, row));
        try output.writeByte('\n');
    }
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

fn writeGoalMatchMask(
    builder: *Builder,
    goals: []const analysis.ResolvedGoal,
    event_alias: []const u8,
) !void {
    if (goals.len == 0) return builder.write("0::UBIGINT");
    try builder.write("(");
    for (goals, 0..) |goal, index| {
        if (index != 0) try builder.write(" | ");
        try builder.write("CASE WHEN ");
        try writeSelector(builder, goal.selector, event_alias);
        try builder.write(" THEN ");
        try builder.bindInteger(@as(i64, 1) << @intCast(index));
        try builder.write("::UBIGINT ELSE 0::UBIGINT END");
    }
    try builder.write(")::UBIGINT");
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

fn executeCardinality(
    database: *duckdb.Database,
    plan: StatementPlan,
    budget: *deadline.Budget,
) !i64 {
    var result = try executePlan(database, plan, budget);
    defer result.deinit();
    if (result.columnCount() != 1 or result.rowCount() != 1) {
        return error.InvalidAnalysisResult;
    }
    const cardinality = result.int64(0, 0);
    if (cardinality < 0) return error.InvalidAnalysisResult;
    return cardinality;
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

fn executePropertyCatalog(
    allocator: std.mem.Allocator,
    database: *duckdb.Database,
    plan: StatementPlan,
    budget: *deadline.Budget,
) !analysis.PropertyCatalog {
    var result = try executePlan(database, plan, budget);
    defer result.deinit();
    if (result.columnCount() != 4) return error.InvalidPropertyCatalog;
    const entries = try allocator.alloc(
        analysis.ObservedPropertyType,
        result.rowCount(),
    );
    for (entries, 0..) |*entry, index| {
        entry.* = .{
            .name = try result.text(allocator, 0, index),
            .scalar_type = try propertyScalarType(result.int64(1, index)),
            .event_count = result.int64(2, index),
        };
    }
    const property_count = if (entries.len == 0) 0 else result.int64(3, 0);
    return .{
        .entries = entries,
        .property_count = property_count,
        .truncated = property_count > analysis.maximum_property_names,
    };
}

fn propertyScalarType(code: i64) !analysis.ScalarType {
    return switch (code) {
        1 => .string,
        2 => .integer,
        3 => .decimal,
        4 => .boolean,
        5 => .null,
        else => error.InvalidPropertyCatalog,
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
    empty_page_cardinality: ?i64,
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
    const cardinality = if (primary.len == 0)
        empty_page_cardinality orelse 0
    else
        primary[0].cardinality;
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
    return analysis.automaticInterval(query.range);
}

fn compileRows(
    allocator: std.mem.Allocator,
    execution: analysis.Execution,
    range: analysis.LocalDateRange,
    interval: analysis.Interval,
) !StatementPlan {
    var builder = Builder.init(allocator);
    try writeMetricRows(&builder, execution, range, interval);
    try builder.write(" SELECT label, measure_kind, numerator, denominator, amount, currency, count(*) OVER ()::BIGINT AS cardinality FROM metric_rows");
    if (execution.query.mode == .breakdown and execution.query.search.len != 0) {
        try writeBreakdownSearch(&builder, execution.query.search);
    }
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

fn writeMetricRows(
    builder: *Builder,
    execution: analysis.Execution,
    range: analysis.LocalDateRange,
    interval: analysis.Interval,
) !void {
    try writeCommon(builder, execution, range, false, false);
    try builder.write(", metric_rows AS (SELECT ");
    if (execution.query.mode == .trend) {
        try writeBucket(builder, interval, "e");
    } else {
        try writeDimension(builder, execution.query.dimension.?, "e", "s");
    }
    try builder.write(" AS label, ");
    try writeMeasure(builder, execution, range, "e", "s");
    try writeMetricSource(builder, execution);
    try writeMetricWhere(builder, execution, "e", "s");
    try builder.write(" GROUP BY 1");
    if (isAmount(execution.query.metric.kind)) try builder.write(", e.value_currency");
    try builder.write(")");
}

fn writeBreakdownSearch(builder: *Builder, search: []const u8) !void {
    try builder.write(" WHERE contains(lower(label), lower(");
    try builder.bindText(search);
    try builder.write("))");
}

fn compileBreakdownCardinality(
    allocator: std.mem.Allocator,
    execution: analysis.Execution,
) !StatementPlan {
    if (execution.query.mode != .breakdown) return error.InvalidBreakdownPageQuery;
    var builder = Builder.init(allocator);
    try writeMetricRows(&builder, execution, execution.query.range, .auto);
    try builder.write(" SELECT count(*)::BIGINT FROM metric_rows");
    if (execution.query.search.len != 0) {
        try writeBreakdownSearch(&builder, execution.query.search);
    }
    return builder.finish();
}

fn compileSiteEventPresence(
    allocator: std.mem.Allocator,
    site_id: []const u8,
) !StatementPlan {
    var builder = Builder.init(allocator);
    try builder.write(
        "SELECT count(*)::BIGINT FROM" ++
            " (SELECT 1 FROM events WHERE site_id = ",
    );
    try builder.bindText(site_id);
    try builder.write(" LIMIT 1)");
    return builder.finish();
}

fn compileTotal(
    allocator: std.mem.Allocator,
    execution: analysis.Execution,
    range: analysis.LocalDateRange,
) !StatementPlan {
    var builder = Builder.init(allocator);
    try writeCommon(&builder, execution, range, false, false);
    try builder.write(" SELECT '' AS label, ");
    try writeMeasure(&builder, execution, range, "e", "s");
    try builder.write(", 1::BIGINT AS cardinality");
    try writeMetricSource(&builder, execution);
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
    try writeCommon(&builder, execution, range, false, false);
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

fn compilePropertyCatalog(
    allocator: std.mem.Allocator,
    execution: analysis.Execution,
) !StatementPlan {
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
            execution.query.site_id,
            goals[0..execution.active_goals.len],
            true,
        ));
        try builder.write(", property_events AS (");
    } else {
        try builder.write("WITH property_events AS (");
    }
    try builder.write(
        "SELECT properties_json AS document FROM events e WHERE e.site_id = ",
    );
    try builder.bindText(execution.query.site_id);
    try builder.write(" AND e.site_local_date BETWEEN CAST(");
    try builder.bindText(execution.query.range.start);
    try builder.write(" AS DATE) AND CAST(");
    try builder.bindText(execution.query.range.end);
    try builder.write(
        " AS DATE) AND e.kind = 2 AND e.traffic_class IN (1, 5)",
    );
    if (execution.strict_traffic_mode) try builder.write(
        " AND e.session_id NOT IN (SELECT session_id" ++
            " FROM d34_current_suspected_sessions)",
    );
    try builder.write(
        " ORDER BY e.received_at_utc_micros DESC, e.event_id DESC LIMIT ",
    );
    try builder.bindInteger(analysis.maximum_property_catalog_events);
    try builder.write("), ");
    try writePropertyCatalogExpansion(&builder);
    return builder.finish();
}

fn writePropertyCatalogExpansion(builder: *Builder) !void {
    try builder.write(
        "expanded AS (SELECT document," ++
            " UNNEST(json_keys(document)) AS property_name" ++
            " FROM property_events), typed AS (SELECT property_name," ++
            " CASE json_type(document, '/' || property_name)" ++
            " WHEN 'VARCHAR' THEN 1 WHEN 'BIGINT' THEN 2" ++
            " WHEN 'UBIGINT' THEN 2 WHEN 'DOUBLE' THEN 3" ++
            " WHEN 'DECIMAL' THEN 3 WHEN 'BOOLEAN' THEN 4" ++
            " WHEN 'NULL' THEN 5 ELSE 0 END AS type_code" ++
            " FROM expanded), grouped AS (SELECT property_name, type_code," ++
            " count(*)::BIGINT AS event_count FROM typed" ++
            " WHERE type_code <> 0 GROUP BY property_name, type_code)," ++
            " names AS (SELECT DISTINCT property_name FROM grouped)," ++
            " selected AS (SELECT property_name," ++
            " (SELECT count(*) FROM names)::BIGINT AS property_count" ++
            " FROM names ORDER BY property_name LIMIT ",
    );
    try builder.bindInteger(analysis.maximum_property_names);
    try builder.write(
        ") SELECT grouped.property_name, grouped.type_code," ++
            " grouped.event_count, selected.property_count" ++
            " FROM grouped JOIN selected USING (property_name)" ++
            " ORDER BY grouped.property_name, grouped.type_code",
    );
}

fn writeCompactGoalCommon(
    builder: *Builder,
    execution: analysis.Execution,
    range: analysis.LocalDateRange,
) !void {
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
            builder.allocator,
            execution.query.site_id,
            goals[0..execution.active_goals.len],
            true,
        ));
        try builder.write(", ");
    } else try builder.write("WITH ");
    try builder.write(
        "range_events AS NOT MATERIALIZED (SELECT e.session_id, e.kind," ++
            " e.event_name, e.path, e.properties_json," ++
            " e.value_amount, e.value_currency, e.identity_quality," ++
            " CASE WHEN e.identity_quality IN (1, 2, 3) THEN" ++
            " struct_pack(identity_kind := CASE" ++
            " WHEN e.identity_quality = 1" ++
            " AND COALESCE(l.user_id, e.user_id, '') <> ''" ++
            " THEN 0::UTINYINT ELSE e.identity_quality END," ++
            " user_id := CASE WHEN e.identity_quality = 1" ++
            " AND COALESCE(l.user_id, e.user_id, '') <> ''" ++
            " THEN COALESCE(l.user_id, e.user_id) ELSE '' END," ++
            " anonymous_id := CASE WHEN e.identity_quality = 1" ++
            " AND COALESCE(l.user_id, e.user_id, '') <> ''" ++
            " THEN CAST(NULL AS UUID) ELSE e.anonymous_id END)" ++
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
        " AS DATE) AND e.kind IN (1, 2)" ++
            " AND e.traffic_class IN (1, 5)",
    );
    if (execution.strict_traffic_mode) try builder.write(
        " AND e.session_id NOT IN (SELECT session_id" ++
            " FROM d34_current_suspected_sessions)",
    );
    try builder.write("), qualified AS NOT MATERIALIZED (SELECT * FROM range_events)");
}

fn writeCommon(
    builder: *Builder,
    execution: analysis.Execution,
    range: analysis.LocalDateRange,
    force_session_facts: bool,
    include_user_traits: bool,
) !void {
    if (!needsSessionFacts(execution) and !force_session_facts and
        !include_user_traits)
    {
        return writeSimpleCommon(builder, execution, range);
    }
    var session_columns = FilteredSessionColumns.resolve(
        execution.query.filters,
        false,
    );
    if (force_session_facts) session_columns = .{
        .landing_page = true,
        .exit_page = true,
        .channel = true,
        .referrer = true,
        .utm_source = true,
        .utm_medium = true,
        .utm_campaign = true,
        .utm_term = true,
        .utm_content = true,
        .country = true,
        .language = true,
        .device = true,
        .browser = true,
        .operating_system = true,
    } else if (execution.query.mode == .breakdown) switch (execution.query.dimension.?.kind) {
        .landing_page => session_columns.include(.landing_page),
        .exit_page => session_columns.include(.exit_page),
        .channel => session_columns.include(.channel),
        .referrer => session_columns.include(.referrer),
        .utm_source => session_columns.include(.utm_source),
        .utm_medium => session_columns.include(.utm_medium),
        .utm_campaign => session_columns.include(.utm_campaign),
        .utm_term => session_columns.include(.utm_term),
        .utm_content => session_columns.include(.utm_content),
        .country => session_columns.include(.country),
        .language => session_columns.include(.language),
        .device => session_columns.include(.device),
        .browser => session_columns.include(.browser),
        .operating_system => session_columns.include(.operating_system),
        .page, .hostname, .event_name, .event_property => {},
    };
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
            " ELSE NULL END AS person_key",
    );
    if (needsFilteredEventColumns(execution.query.filters)) try builder.write(
        ", e.referrer_host AS referrer, e.country_code AS country," ++
            " e.device_category AS device, e.browser_family AS browser," ++
            " e.os_family AS operating_system",
    );
    try builder.write(
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
            " session_summary AS MATERIALIZED (SELECT session_id",
    );
    if (session_columns.landing_page) try writeSessionFirst(
        builder,
        "path",
        "landing_page",
        "''",
        "= 1",
        false,
    );
    if (session_columns.exit_page) try writeSessionFirst(
        builder,
        "path",
        "exit_page",
        "''",
        "= 1",
        true,
    );
    if (session_columns.referrer) try writeSessionFirst(
        builder,
        "referrer_host",
        "referrer",
        "''",
        "= 1",
        false,
    );
    if (session_columns.utm_source) try writeSessionFirst(
        builder,
        "utm_source",
        "utm_source",
        "''",
        "= 1",
        false,
    );
    if (session_columns.utm_medium) try writeSessionFirst(
        builder,
        "utm_medium",
        "utm_medium",
        "''",
        "= 1",
        false,
    );
    if (session_columns.utm_campaign) try writeSessionFirst(
        builder,
        "utm_campaign",
        "utm_campaign",
        "''",
        "= 1",
        false,
    );
    if (session_columns.utm_term) try writeSessionFirst(
        builder,
        "utm_term",
        "utm_term",
        "''",
        "= 1",
        false,
    );
    if (session_columns.utm_content) try writeSessionFirst(
        builder,
        "utm_content",
        "utm_content",
        "''",
        "= 1",
        false,
    );
    if (session_columns.country) try writeSessionFirst(
        builder,
        "country_code",
        "country",
        "'ZZ'",
        "IN (1, 2)",
        false,
    );
    if (session_columns.language) try writeSessionFirst(
        builder,
        "language",
        "language",
        "''",
        "IN (1, 2)",
        false,
    );
    if (session_columns.device) try writeSessionFirst(
        builder,
        "device_category",
        "device",
        "'unknown'",
        "IN (1, 2)",
        false,
    );
    if (session_columns.browser) try writeSessionFirst(
        builder,
        "browser_family",
        "browser",
        "'Unknown'",
        "IN (1, 2)",
        false,
    );
    if (session_columns.operating_system) try writeSessionFirst(
        builder,
        "os_family",
        "operating_system",
        "'Unknown'",
        "IN (1, 2)",
        false,
    );
    try builder.write(
        ", min(occurred_at_utc_micros) AS first_at," ++
            " max(occurred_at_utc_micros) AS last_at," ++
            " count(*) FILTER (WHERE kind = 1)::BIGINT AS page_views," ++
            " sum(engagement_ms)::BIGINT AS engagement_ms," ++
            " bool_or(CASE WHEN kind IN (1, 2) THEN ",
    );
    try writeAnyGoalMatch(builder, execution.active_goals, "session_events");
    try builder.write(
        " ELSE FALSE END) AS converted" ++
            " FROM session_events GROUP BY session_id)," ++
            " session_facts AS (SELECT st.session_id",
    );
    if (session_columns.landing_page) try builder.write(", st.landing_page");
    if (session_columns.exit_page) try builder.write(", st.exit_page");
    if (session_columns.referrer) try builder.write(", st.referrer");
    if (session_columns.utm_source) try builder.write(", st.utm_source");
    if (session_columns.utm_medium) try builder.write(", st.utm_medium");
    if (session_columns.utm_campaign) try builder.write(", st.utm_campaign");
    if (session_columns.utm_term) try builder.write(", st.utm_term");
    if (session_columns.utm_content) try builder.write(", st.utm_content");
    if (session_columns.country) try builder.write(", st.country");
    if (session_columns.language) try builder.write(", st.language");
    if (session_columns.device) try builder.write(", st.device");
    if (session_columns.browser) try builder.write(", st.browser");
    if (session_columns.operating_system) try builder.write(", st.operating_system");
    if (session_columns.channel) try builder.write(
        ", CASE WHEN st.utm_source = '' AND st.utm_medium = ''" ++
            "  AND st.referrer = '' THEN 'Direct'" ++
            " WHEN lower(st.utm_medium) IN ('cpc', 'ppc', 'paidsearch')" ++
            " THEN 'Paid Search'" ++
            " WHEN lower(st.utm_medium) = 'organic' THEN 'Organic Search'" ++
            " WHEN lower(st.utm_medium) IN" ++
            "  ('social', 'social-network', 'social-media', 'sm') THEN 'Social'" ++
            " WHEN lower(st.utm_medium) = 'email' THEN 'Email'" ++
            " WHEN lower(st.utm_medium) = 'referral'" ++
            "  OR (st.referrer <> '' AND st.utm_source = ''" ++
            "      AND st.utm_medium = '') THEN 'Referral'" ++
            " ELSE 'Other / Unknown' END AS channel",
    );
    try builder.write(
        ", greatest(0, (st.last_at - st.first_at) / 1000)::BIGINT AS duration_ms," ++
            " st.engagement_ms, st.page_views," ++
            " (st.engagement_ms >= 10000 OR st.page_views >= 2" ++
            " OR st.converted) AS engaged, st.converted" ++
            " FROM session_summary st)",
    );
    if (hasUserTraitClause(execution.query.filters.clauses) or
        include_user_traits)
    {
        try writePersonTraits(
            builder,
            execution.query.site_id,
            execution.strict_traffic_mode,
            false,
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

fn needsSessionFacts(execution: analysis.Execution) bool {
    if (execution.query.filters.clauses.len != 0) {
        return true;
    }
    if (switch (execution.query.metric.kind) {
        .engaged_sessions, .engagement_rate, .bounce_rate => true,
        else => false,
    }) return true;
    if (execution.query.mode == .trend) return false;
    return switch (execution.query.dimension.?.kind) {
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
        => true,
        .page, .hostname, .event_name, .event_property => false,
    };
}

fn writeSimpleCommon(
    builder: *Builder,
    execution: analysis.Execution,
    range: analysis.LocalDateRange,
) !void {
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
            " qualified AS (SELECT e.* FROM base e WHERE TRUE",
    );
    if (execution.strict_traffic_mode) try builder.write(
        " AND e.session_id NOT IN (SELECT session_id" ++
            " FROM d34_current_suspected_sessions)",
    );
    try builder.write(")");
}

fn writeMetricSource(builder: *Builder, execution: analysis.Execution) !void {
    if (needsSessionFacts(execution)) {
        try builder.write(" FROM qualified e JOIN session_facts s USING (session_id)");
    } else {
        try builder.write(" FROM qualified e");
    }
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
    compact_key: bool,
) !void {
    try builder.write(", person_trait_events AS (SELECT e.*, ");
    if (compact_key) {
        try builder.write(
            "struct_pack(identity_kind := CASE" ++
                " WHEN COALESCE(l.user_id, e.user_id, '') <> ''" ++
                " THEN 0::UTINYINT ELSE 1::UTINYINT END," ++
                " user_id := CASE" ++
                " WHEN COALESCE(l.user_id, e.user_id, '') <> ''" ++
                " THEN COALESCE(l.user_id, e.user_id) ELSE '' END," ++
                " anonymous_id := CASE" ++
                " WHEN COALESCE(l.user_id, e.user_id, '') <> ''" ++
                " THEN CAST(NULL AS UUID) ELSE e.anonymous_id END) AS person_key",
        );
    } else {
        try builder.write(
            "CASE WHEN COALESCE(l.user_id, e.user_id, '') <> ''" ++
                " THEN 'u:' || COALESCE(l.user_id, e.user_id)" ++
                " ELSE 'a:' || CAST(e.anonymous_id AS VARCHAR) END AS person_key",
        );
    }
    try builder.write(
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
                    const selector = (try analysis.resolvedSelectorSets(
                        metric.selector,
                        execution.active_goals,
                        execution.selected_goals,
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
            const selector = (try analysis.resolvedSelectorSets(
                metric.selector,
                execution.active_goals,
                execution.selected_goals,
            )).?;
            try builder.write(" AND ");
            try writeSelectorResolution(builder, selector, event_alias);
        },
        .revenue, .average_value => {
            try builder.write(" AND e.value_amount IS NOT NULL AND e.value_currency <> ''");
            if (try analysis.resolvedSelectorSets(
                metric.selector,
                execution.active_goals,
                execution.selected_goals,
            )) |selector| {
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

test "funnel availability compiles all selectors over one qualified relation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const adversarial = "x'); SELECT * FROM events; --";
    const values = [_][]const u8{adversarial};
    const predicates = [_]analysis.PropertyPredicate{.{
        .property_ref = .{ .name = "plan", .scalar_type = .string },
        .operator = .is,
        .values = &values,
    }};
    const selectors = [_]analysis.EventSelector{
        .{ .kind = .page_prefix, .value = "/" },
        .{
            .kind = .exact_event,
            .value = "signup",
            .predicates = &predicates,
        },
    };
    const plan = try compileFunnelAvailability(arena.allocator(), .{
        .site_id = "00000000-0000-4000-8000-000000000024",
        .range = .{ .start = "2026-01-01", .end = "2026-01-02" },
        .selectors = &selectors,
    });
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, plan.sql, "FROM qualified e"),
    );
    try std.testing.expectEqual(
        selectors.len,
        std.mem.count(u8, plan.sql, "count(*) FILTER"),
    );
    try std.testing.expect(std.mem.indexOf(u8, plan.sql, adversarial) == null);
    try std.testing.expect(planContainsText(plan, adversarial));
}

test "ordered funnel compiler binds selectors and emits bounded position links" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const adversarial = "x'); SELECT * FROM events; --";
    const values = [_][]const u8{adversarial};
    const predicates = [_]analysis.PropertyPredicate{.{
        .property_ref = .{ .name = "plan", .scalar_type = .string },
        .operator = .is,
        .values = &values,
    }};
    const selectors = [_]analysis.EventSelector{
        .{ .kind = .exact_page, .value = "/" },
        .{ .kind = .exact_event, .value = "signup", .predicates = &predicates },
        .{ .kind = .exact_event, .value = "purchase", .predicates = &predicates },
    };
    const request = funnel.ResultRequest{
        .site_id = "00000000-0000-4000-8000-000000000024",
        .range = .{ .start = "2026-01-01", .end = "2026-01-02" },
        .order = .sequential,
        .scope = .sessions,
        .window = .one_day,
        .selectors = &selectors,
    };
    const plan = try compileFunnelResult(
        arena.allocator(),
        request,
        request.range,
    );
    try std.testing.expect(plan.sql.len <= maximum_sql_bytes);
    try std.testing.expect(plan.bindings.len <= maximum_bindings);
    try std.testing.expect(std.mem.indexOf(u8, plan.sql, adversarial) == null);
    try std.testing.expect(planContainsText(plan, adversarial));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(
        u8,
        plan.sql,
        "row_number() OVER (PARTITION BY chain_key",
    ));
    try std.testing.expectEqual(selectors.len - 1, std.mem.count(
        u8,
        plan.sql,
        "n.position > p.matched_position",
    ));
    try std.testing.expectEqual(selectors.len, std.mem.count(
        u8,
        plan.sql,
        " FROM numbered e WHERE ",
    ));
    try std.testing.expectEqual(selectors.len - 1, std.mem.count(
        u8,
        plan.sql,
        " p ASOF JOIN candidate_",
    ));
    try std.testing.expect(std.mem.indexOf(u8, plan.sql, "step_2 AS") != null);

    var consecutive = request;
    consecutive.order = .consecutive;
    const consecutive_plan = try compileFunnelResult(
        arena.allocator(),
        consecutive,
        consecutive.range,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        consecutive_plan.sql,
        "n.position > p.matched_position",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        consecutive_plan.sql,
        "n.position = p.matched_position + 1",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        consecutive_plan.sql,
        " ASOF JOIN ",
    ) == null);

    var greedy = request;
    greedy.window = .same_session;
    const greedy_plan = try compileFunnelResult(
        arena.allocator(),
        greedy,
        greedy.range,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        greedy_plan.sql,
        " ASOF JOIN ",
    ) == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(
        u8,
        greedy_plan.sql,
        "row_number() OVER (PARTITION BY chain_key",
    ));
    try std.testing.expectEqual(selectors.len - 1, std.mem.count(
        u8,
        greedy_plan.sql,
        "min(n.position) AS matched_position",
    ));
    try std.testing.expect(std.mem.indexOf(
        u8,
        greedy_plan.sql,
        "FROM candidate_0 e GROUP BY e.chain_key, e.count_key",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        greedy_plan.sql,
        "row_number() OVER (PARTITION BY count_key",
    ) == null);
}

test "Breakdown search and catalog context remain bound SQL inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const adversarial = "x'); SELECT * FROM identity_links; --";
    const site = "00000000-0000-4000-8000-000000000024";
    const start = "2026-01-01";
    const end = "2026-01-02";
    const execution = analysis.Execution{ .query = .{
        .site_id = site,
        .range = .{ .start = start, .end = end },
        .mode = .breakdown,
        .metric = .{ .kind = .custom_events },
        .dimension = .{ .kind = .event_name },
        .search = adversarial,
    } };
    const compiled = try compile(allocator, execution);
    try std.testing.expect(std.mem.indexOf(
        u8,
        compiled.primary_rows.sql,
        adversarial,
    ) == null);
    try std.testing.expect(planContainsText(compiled.primary_rows, adversarial));

    const catalog = try compilePropertyCatalog(allocator, execution);
    inline for (.{ site, start, end }) |value| {
        try std.testing.expect(std.mem.indexOf(u8, catalog.sql, value) == null);
        try std.testing.expect(planContainsText(catalog, value));
    }
}

test "property catalog cache key separates every semantic input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const values_a = [_][]const u8{ "ab", "c" };
    const values_b = [_][]const u8{ "a", "bc" };
    const predicates_a = [_]analysis.PropertyPredicate{.{
        .property_ref = .{ .name = "plan", .scalar_type = .string },
        .operator = .is,
        .values = &values_a,
    }};
    const predicates_b = [_]analysis.PropertyPredicate{.{
        .property_ref = .{ .name = "plan", .scalar_type = .string },
        .operator = .is,
        .values = &values_b,
    }};
    const goals_a = [_]analysis.ResolvedGoal{.{
        .id = "00000000-0000-4000-8000-000000000029",
        .selector = .{
            .kind = .exact_event,
            .value = "purchase",
            .predicates = &predicates_a,
        },
    }};
    const goals_b = [_]analysis.ResolvedGoal{.{
        .id = "00000000-0000-4000-8000-000000000029",
        .selector = .{
            .kind = .exact_event,
            .value = "purchase",
            .predicates = &predicates_b,
        },
    }};
    const base = analysis.Execution{
        .query = .{
            .site_id = "00000000-0000-4000-8000-000000000024",
            .range = .{ .start = "2026-01-01", .end = "2026-01-02" },
            .mode = .breakdown,
            .metric = .{ .kind = .custom_events },
            .dimension = .{ .kind = .event_name },
        },
        .active_goals = &goals_a,
        .strict_traffic_mode = true,
    };
    const key = try propertyCatalogCacheKey(allocator, base);

    var changed_values = base;
    changed_values.active_goals = &goals_b;
    try std.testing.expect(!std.mem.eql(
        u8,
        key,
        try propertyCatalogCacheKey(allocator, changed_values),
    ));

    var changed_range = base;
    changed_range.query.range.end = "2026-01-03";
    try std.testing.expect(!std.mem.eql(
        u8,
        key,
        try propertyCatalogCacheKey(allocator, changed_range),
    ));

    var changed_policy = base;
    changed_policy.strict_traffic_mode = false;
    try std.testing.expect(!std.mem.eql(
        u8,
        key,
        try propertyCatalogCacheKey(allocator, changed_policy),
    ));

    var changed_site = base;
    changed_site.query.site_id = "00000000-0000-4000-8000-000000000025";
    try std.testing.expect(!std.mem.eql(
        u8,
        key,
        try propertyCatalogCacheKey(allocator, changed_site),
    ));
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

    const session_request = analysis.SessionListRequest{
        .site_id = "00000000-0000-4000-8000-000000000024",
        .range = .{ .start = "2026-01-01", .end = "2026-01-02" },
        .filters = .{ .clauses = &clauses },
        .active_goals = &goals,
        .selected_goal_index = 0,
        .strict_traffic_mode = true,
        .now_utc_micros = 1_800_000_000_000_000,
    };
    const session_keys = try compileSessionKeys(allocator, session_request);
    try std.testing.expect(session_keys.sql.len <= maximum_sql_bytes);
    try std.testing.expect(session_keys.bindings.len <= maximum_bindings);
    var page_keys: [analysis.session_page_size]SessionKey = undefined;
    for (&page_keys, 0..) |*key, index| key.* = .{
        .id = try std.fmt.allocPrint(
            allocator,
            "00000000-0000-4000-8000-{d:0>12}",
            .{index + 100},
        ),
        .started_at_utc_micros = @intCast(index),
    };
    const session_details = try compileSessionDetails(
        allocator,
        SessionSummaryRequest.fromList(session_request),
        &page_keys,
    );
    try std.testing.expect(session_details.sql.len <= maximum_sql_bytes);
    try std.testing.expect(session_details.bindings.len <= maximum_bindings);
}

test "simple empty-filter Trend plans omit unused session facts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const base = analysis.Query{
        .site_id = "00000000-0000-4000-8000-000000000024",
        .range = .{ .start = "2026-01-01", .end = "2026-01-02" },
        .mode = .trend,
        .metric = .{ .kind = .visitors },
        .interval = .day,
    };
    const simple = try compile(arena.allocator(), .{ .query = base });
    try std.testing.expect(std.mem.indexOf(
        u8,
        simple.primary_rows.sql,
        "session_facts",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        simple.primary_rows.sql,
        "FROM qualified e JOIN",
    ) == null);

    var empty_segment_query = base;
    empty_segment_query.segment_id = "00000000-0000-4000-8000-000000000030";
    const empty_segment = try compile(arena.allocator(), .{
        .query = empty_segment_query,
        .segment_resolved = true,
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        empty_segment.primary_rows.sql,
        "session_facts",
    ) == null);

    var engaged_query = base;
    engaged_query.metric = .{ .kind = .engagement_rate };
    const engaged = try compile(arena.allocator(), .{ .query = engaged_query });
    try std.testing.expect(std.mem.indexOf(
        u8,
        engaged.primary_rows.sql,
        "session_facts",
    ) != null);

    const filter = [_]analysis.Clause{.{
        .scope = .event,
        .field = .{ .kind = .page },
        .operator = .is,
        .scalar_type = .string,
        .values = &.{"/"},
    }};
    var filtered_query = base;
    filtered_query.filters = .{ .clauses = &filter };
    const filtered = try compile(arena.allocator(), .{ .query = filtered_query });
    try std.testing.expect(std.mem.indexOf(
        u8,
        filtered.primary_rows.sql,
        "session_facts",
    ) != null);
}

test "ordered funnel executes typed session and visitor results on disk" {
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
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const query_allocator = arena.allocator();
    const selectors = [_]analysis.EventSelector{
        .{ .kind = .exact_page, .value = "/pricing" },
        .{ .kind = .exact_event, .value = "purchase" },
    };
    const session_result = try executeFunnelResult(
        query_allocator,
        &event_store,
        .{
            .site_id = "00000000-0000-4000-8000-000000000024",
            .range = .{ .start = "2026-01-03", .end = "2026-01-03" },
            .order = .sequential,
            .scope = .sessions,
            .window = .same_session,
            .selectors = &selectors,
        },
    );
    try std.testing.expectEqual(@as(i64, 1), session_result.current.entrants);
    try std.testing.expectEqual(@as(i64, 1), session_result.current.completions);
    try std.testing.expectEqual(
        @as(?i64, 1_000_000),
        session_result.current.steps[1].median_from_prior_micros,
    );
    try std.testing.expectEqual(@as(?funnel.IdentityCoverage, null), session_result.current.identity_coverage);

    const repeated_pages = [_]analysis.EventSelector{
        .{ .kind = .page_prefix, .value = "/" },
        .{ .kind = .page_prefix, .value = "/" },
    };
    const visitor_result = try executeFunnelResult(
        query_allocator,
        &event_store,
        .{
            .site_id = "00000000-0000-4000-8000-000000000024",
            .range = .{ .start = "2026-01-03", .end = "2026-01-03" },
            .order = .sequential,
            .scope = .visitors,
            .window = .same_session,
            .selectors = &repeated_pages,
        },
    );
    try std.testing.expectEqual(@as(i64, 2), visitor_result.current.entrants);
    try std.testing.expectEqual(@as(i64, 0), visitor_result.current.completions);
    try std.testing.expectEqualDeep(funnel.IdentityCoverage{
        .persistent_step_one = 2,
        .ephemeral_step_one = 1,
        .legacy_step_one = 1,
    }, visitor_result.current.identity_coverage.?);
}

test "session list expands bounded full records on disk" {
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
    try event_store.database.exec(
        \\INSERT INTO events SELECT * REPLACE (
        \\  CAST('00000000-0000-4000-8000-000000000201' AS UUID) AS event_id,
        \\  1767398410000000 AS received_at_utc_micros,
        \\  1767398410000000 AS occurred_at_utc_micros,
        \\  DATE '2026-01-03' AS received_date_utc,
        \\  DATE '2026-01-03' AS site_local_date,
        \\  2 AS kind, 'custom-only' AS event_name,
        \\  '/custom-only' AS path, 'Custom only' AS page_title,
        \\  CAST('00000000-0000-4000-8000-0000000000a6' AS UUID) AS anonymous_id,
        \\  2 AS identity_quality, '' AS user_id,
        \\  CAST('00000000-0000-4000-8000-0000000000b6' AS UUID) AS session_id,
        \\  0 AS sequence, TRUE AS session_start,
        \\  'tablet' AS device_category,
        \\  CAST('00000000-0000-4000-8000-000000000201' AS BLOB) AS visitor_day_id,
        \\  TRUE AS visitor_day_start, repeat('c', 64) AS event_payload_digest
        \\) FROM events
        \\WHERE event_id = CAST('00000000-0000-4000-8000-000000000107' AS UUID);
        \\INSERT INTO events SELECT * REPLACE (
        \\  CAST('00000000-0000-4000-8000-000000000202' AS UUID) AS event_id,
        \\  '00000000-0000-4000-8000-000000000099' AS site_id,
        \\  1767398420000000 AS received_at_utc_micros,
        \\  1767398420000000 AS occurred_at_utc_micros,
        \\  CAST('00000000-0000-4000-8000-0000000000f6' AS UUID) AS anonymous_id,
        \\  CAST('00000000-0000-4000-8000-0000000000b6' AS UUID) AS session_id,
        \\  CAST('00000000-0000-4000-8000-000000000202' AS BLOB) AS visitor_day_id,
        \\  repeat('d', 64) AS event_payload_digest
        \\) FROM events
        \\WHERE event_id = CAST('00000000-0000-4000-8000-000000000201' AS UUID)
        \\  AND site_id = '00000000-0000-4000-8000-000000000024';
        \\INSERT INTO events SELECT * REPLACE (
        \\  CAST('00000000-0000-4000-8000-000000000203' AS UUID) AS event_id,
        \\  1767398411000000 AS received_at_utc_micros,
        \\  1767398411000000 AS occurred_at_utc_micros,
        \\  '/suspected' AS path, 'Suspected' AS page_title,
        \\  CAST('00000000-0000-4000-8000-0000000000a7' AS UUID) AS anonymous_id,
        \\  1 AS identity_quality, '' AS user_id,
        \\  CAST('00000000-0000-4000-8000-0000000000b7' AS UUID) AS session_id,
        \\  'desktop' AS device_category,
        \\  CAST('00000000-0000-4000-8000-000000000203' AS BLOB) AS visitor_day_id,
        \\  repeat('f', 64) AS event_payload_digest,
        \\  1 AS signal_version, FALSE AS was_visible,
        \\  1 AS viewport_bucket, 1 AS beacon_timing_bucket,
        \\  3 AS client_hint_consistency, FALSE AS accept_language_present
        \\) FROM events
        \\WHERE event_id = CAST('00000000-0000-4000-8000-000000000107' AS UUID);
        \\INSERT INTO events SELECT * REPLACE (
        \\  CAST('00000000-0000-4000-8000-000000000204' AS UUID) AS event_id,
        \\  1767398412000000 AS received_at_utc_micros,
        \\  1767398412000000 AS occurred_at_utc_micros,
        \\  '/excluded' AS path, 'Excluded' AS page_title,
        \\  CAST('00000000-0000-4000-8000-0000000000a8' AS UUID) AS anonymous_id,
        \\  CAST('00000000-0000-4000-8000-0000000000b8' AS UUID) AS session_id,
        \\  CAST('00000000-0000-4000-8000-000000000204' AS BLOB) AS visitor_day_id,
        \\  repeat('0', 64) AS event_payload_digest, 4 AS traffic_class
        \\) FROM events
        \\WHERE event_id = CAST('00000000-0000-4000-8000-000000000107' AS UUID);
    );
    try event_store.database.exec(
        \\INSERT INTO identity_links VALUES (
        \\  '00000000-0000-4000-8000-000000000024',
        \\  CAST('00000000-0000-4000-8000-0000000000a9' AS UUID),
        \\  'user-a', 1767398409000000,
        \\  CAST('00000000-0000-4000-8000-000000000219' AS UUID)
        \\);
        \\INSERT INTO events SELECT * REPLACE (
        \\  CAST('00000000-0000-4000-8000-000000000211' AS UUID) AS event_id,
        \\  1767398405100000 AS received_at_utc_micros,
        \\  1767398405100000 AS occurred_at_utc_micros,
        \\  3 AS kind, 'engagement' AS event_name,
        \\  2 AS sequence, FALSE AS session_start,
        \\  5000 AS engagement_ms, 40 AS max_scroll_depth,
        \\  CAST('00000000-0000-4000-8000-000000000211' AS BLOB) AS visitor_day_id,
        \\  FALSE AS visitor_day_start, repeat('1', 64) AS event_payload_digest
        \\) FROM events
        \\WHERE event_id = CAST('00000000-0000-4000-8000-000000000108' AS UUID);
        \\INSERT INTO events SELECT * REPLACE (
        \\  CAST('00000000-0000-4000-8000-000000000212' AS UUID) AS event_id,
        \\  1767398405200000 AS received_at_utc_micros,
        \\  1767398405200000 AS occurred_at_utc_micros,
        \\  1 AS kind, 'pageview' AS event_name, '/other' AS path,
        \\  'Other' AS page_title, 3 AS sequence, FALSE AS session_start,
        \\  0 AS engagement_ms, 0 AS max_scroll_depth,
        \\  CAST('00000000-0000-4000-8000-000000000212' AS BLOB) AS visitor_day_id,
        \\  FALSE AS visitor_day_start, repeat('2', 64) AS event_payload_digest
        \\) FROM events
        \\WHERE event_id = CAST('00000000-0000-4000-8000-000000000107' AS UUID);
        \\INSERT INTO events SELECT * REPLACE (
        \\  CAST('00000000-0000-4000-8000-000000000213' AS UUID) AS event_id,
        \\  1767398405300000 AS received_at_utc_micros,
        \\  1767398405300000 AS occurred_at_utc_micros,
        \\  3 AS kind, 'engagement' AS event_name, '/other' AS path,
        \\  'Other' AS page_title, 4 AS sequence, FALSE AS session_start,
        \\  7000 AS engagement_ms, 65 AS max_scroll_depth,
        \\  CAST('00000000-0000-4000-8000-000000000213' AS BLOB) AS visitor_day_id,
        \\  FALSE AS visitor_day_start, repeat('3', 64) AS event_payload_digest
        \\) FROM events
        \\WHERE event_id = CAST('00000000-0000-4000-8000-000000000108' AS UUID);
        \\INSERT INTO events SELECT * REPLACE (
        \\  CAST('00000000-0000-4000-8000-000000000214' AS UUID) AS event_id,
        \\  1767398405400000 AS received_at_utc_micros,
        \\  1767398405400000 AS occurred_at_utc_micros,
        \\  1 AS kind, 'pageview' AS event_name, '/' AS path,
        \\  'Home again' AS page_title, 5 AS sequence, FALSE AS session_start,
        \\  0 AS engagement_ms, 0 AS max_scroll_depth,
        \\  CAST('00000000-0000-4000-8000-000000000214' AS BLOB) AS visitor_day_id,
        \\  FALSE AS visitor_day_start, repeat('4', 64) AS event_payload_digest
        \\) FROM events
        \\WHERE event_id = CAST('00000000-0000-4000-8000-000000000107' AS UUID);
        \\INSERT INTO events SELECT * REPLACE (
        \\  CAST('00000000-0000-4000-8000-000000000215' AS UUID) AS event_id,
        \\  1767398405500000 AS received_at_utc_micros,
        \\  1767398405500000 AS occurred_at_utc_micros,
        \\  3 AS kind, 'engagement' AS event_name, '/' AS path,
        \\  'Home again' AS page_title, 6 AS sequence, FALSE AS session_start,
        \\  3000 AS engagement_ms, 80 AS max_scroll_depth,
        \\  CAST('00000000-0000-4000-8000-000000000215' AS BLOB) AS visitor_day_id,
        \\  FALSE AS visitor_day_start, repeat('5', 64) AS event_payload_digest
        \\) FROM events
        \\WHERE event_id = CAST('00000000-0000-4000-8000-000000000108' AS UUID);
        \\INSERT INTO events SELECT * REPLACE (
        \\  CAST('00000000-0000-4000-8000-000000000218' AS UUID) AS event_id,
        \\  1767398409000000 AS received_at_utc_micros,
        \\  1767398409000000 AS occurred_at_utc_micros,
        \\  1 AS kind, 'pageview' AS event_name, '/device-two' AS path,
        \\  'Device two' AS page_title,
        \\  CAST('00000000-0000-4000-8000-0000000000a9' AS UUID) AS anonymous_id,
        \\  1 AS identity_quality, '' AS user_id,
        \\  CAST('00000000-0000-4000-8000-0000000000b9' AS UUID) AS session_id,
        \\  0 AS sequence, TRUE AS session_start,
        \\  'desktop' AS device_category,
        \\  CAST('00000000-0000-4000-8000-000000000218' AS BLOB) AS visitor_day_id,
        \\  TRUE AS visitor_day_start, repeat('8', 64) AS event_payload_digest
        \\) FROM events
        \\WHERE event_id = CAST('00000000-0000-4000-8000-000000000107' AS UUID);
        \\INSERT INTO events SELECT * REPLACE (
        \\  CAST('00000000-0000-4000-8000-000000000219' AS UUID) AS event_id,
        \\  1767398410000000 AS received_at_utc_micros,
        \\  1767398410000000 AS occurred_at_utc_micros,
        \\  4 AS kind, 'identify' AS event_name, '/device-two' AS path,
        \\  'Device two' AS page_title,
        \\  CAST('00000000-0000-4000-8000-0000000000a9' AS UUID) AS anonymous_id,
        \\  1 AS identity_quality, 'user-a' AS user_id,
        \\  CAST('00000000-0000-4000-8000-0000000000b9' AS UUID) AS session_id,
        \\  1 AS sequence, FALSE AS session_start,
        \\  '{"device":"second","plan":"business"}' AS user_traits_json,
        \\  CAST('00000000-0000-4000-8000-000000000219' AS BLOB) AS visitor_day_id,
        \\  FALSE AS visitor_day_start, repeat('9', 64) AS event_payload_digest
        \\) FROM events
        \\WHERE event_id = CAST('00000000-0000-4000-8000-000000000106' AS UUID);
    );
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const goals = [_]analysis.ResolvedGoal{
        .{
            .id = "00000000-0000-4000-8000-000000000041",
            .selector = .{ .kind = .exact_event, .value = "purchase" },
        },
        .{
            .id = "00000000-0000-4000-8000-000000000042",
            .selector = .{ .kind = .exact_event, .value = "purchase" },
        },
    };
    const request = analysis.SessionListRequest{
        .site_id = "00000000-0000-4000-8000-000000000024",
        .range = .{ .start = "2026-01-03", .end = "2026-01-03" },
        .active_goals = &goals,
        .now_utc_micros = 1_767_400_209_000_000,
    };
    const page = try executeSessionList(arena.allocator(), &event_store, request);
    try std.testing.expectEqual(@as(usize, 7), page.rows.len);
    try std.testing.expect(!page.has_more);
    const identified = findSessionRow(
        page.rows,
        "00000000-0000-4000-8000-0000000000b1",
    ) orelse return error.MissingSessionFixtureRow;
    try std.testing.expectEqualStrings(
        "00000000-0000-4000-8000-0000000000b1",
        identified.session_id,
    );
    try std.testing.expectEqualStrings("u:user-a", identified.person_key);
    try std.testing.expectEqualStrings("/landing", identified.landing_page);
    try std.testing.expectEqualStrings("Paid Search", identified.channel);
    try std.testing.expectEqual(@as(i64, 2), identified.page_views);
    try std.testing.expectEqual(@as(i64, 3), identified.custom_events);
    try std.testing.expectEqual(@as(i64, 4), identified.conversions);
    try std.testing.expectEqual(@as(i64, 86_403_000), identified.duration_ms);
    try std.testing.expectEqual(@as(i64, 0), identified.engagement_ms);
    try std.testing.expectEqual(@as(usize, 2), identified.revenue.len);
    try std.testing.expectEqualStrings("EUR", identified.revenue[0].currency);
    try std.testing.expectEqualStrings("12.500000", identified.revenue[0].decimal);
    try std.testing.expectEqual(@as(i64, 1), identified.revenue[0].value_count);
    try std.testing.expectEqualStrings("USD", identified.revenue[1].currency);
    try std.testing.expectEqualStrings("7.500000", identified.revenue[1].decimal);
    try std.testing.expectEqual(@as(i64, 1), identified.revenue[1].value_count);
    try std.testing.expect(identified.current);
    const engaged_session = findSessionRow(
        page.rows,
        "00000000-0000-4000-8000-0000000000b2",
    ) orelse return error.MissingSessionFixtureRow;
    try std.testing.expectEqual(@as(i64, 1_500), engaged_session.duration_ms);
    try std.testing.expectEqual(@as(i64, 25_000), engaged_session.engagement_ms);
    const custom_only = findSessionRow(
        page.rows,
        "00000000-0000-4000-8000-0000000000b6",
    ) orelse return error.MissingSessionFixtureRow;
    try std.testing.expectEqual(@as(i64, 0), custom_only.page_views);
    try std.testing.expectEqual(@as(i64, 1), custom_only.custom_events);
    try std.testing.expectEqualStrings("", custom_only.landing_page);
    try std.testing.expect(findSessionRow(
        page.rows,
        "00000000-0000-4000-8000-0000000000b7",
    ) != null);
    try std.testing.expect(findSessionRow(
        page.rows,
        "00000000-0000-4000-8000-0000000000b8",
    ) == null);
    var strict_request = request;
    strict_request.strict_traffic_mode = true;
    const strict_page = try executeSessionList(
        arena.allocator(),
        &event_store,
        strict_request,
    );
    try std.testing.expectEqual(@as(usize, 6), strict_page.rows.len);
    try std.testing.expect(findSessionRow(
        strict_page.rows,
        "00000000-0000-4000-8000-0000000000b7",
    ) == null);

    var selected = request;
    selected.selected_goal_index = 0;
    const goal_page = try executeSessionList(
        arena.allocator(),
        &event_store,
        selected,
    );
    try std.testing.expectEqual(@as(usize, 1), goal_page.rows.len);
    try std.testing.expectEqualStrings(identified.session_id, goal_page.rows[0].session_id);

    const plan_values = [_][]const u8{"pro"};
    const plan_predicates = [_]analysis.PropertyPredicate{.{
        .property_ref = .{ .name = "plan", .scalar_type = .string },
        .operator = .is,
        .values = &plan_values,
    }};
    const predicate_goals = [_]analysis.ResolvedGoal{.{
        .id = "00000000-0000-4000-8000-000000000043",
        .selector = .{
            .kind = .exact_event,
            .value = "purchase",
            .predicates = &plan_predicates,
        },
    }};
    var predicate_goal = request;
    predicate_goal.active_goals = &predicate_goals;
    predicate_goal.selected_goal_index = 0;
    const predicate_page = try executeSessionList(
        arena.allocator(),
        &event_store,
        predicate_goal,
    );
    try std.testing.expectEqual(@as(usize, 1), predicate_page.rows.len);
    try std.testing.expectEqualStrings(identified.session_id, predicate_page.rows[0].session_id);

    const page_goal = [_]analysis.ResolvedGoal{.{
        .id = "00000000-0000-4000-8000-000000000044",
        .selector = .{ .kind = .page_prefix, .value = "/pric" },
    }};
    var selected_page_goal = request;
    selected_page_goal.active_goals = &page_goal;
    selected_page_goal.selected_goal_index = 0;
    const page_goal_page = try executeSessionList(
        arena.allocator(),
        &event_store,
        selected_page_goal,
    );
    try std.testing.expectEqual(@as(usize, 1), page_goal_page.rows.len);
    try std.testing.expectEqualStrings(
        identified.session_id,
        page_goal_page.rows[0].session_id,
    );

    const page_values = [_][]const u8{"/pric"};
    const event_values = [_][]const u8{"purch"};
    const event_filters = [_]analysis.Clause{
        .{
            .scope = .event,
            .field = .{ .kind = .page },
            .operator = .contains,
            .scalar_type = .string,
            .values = &page_values,
        },
        .{
            .scope = .event,
            .field = .{ .kind = .event_name },
            .operator = .contains,
            .scalar_type = .string,
            .values = &event_values,
        },
    };
    var page_and_event = request;
    page_and_event.filters = .{ .clauses = &event_filters };
    const page_event_page = try executeSessionList(
        arena.allocator(),
        &event_store,
        page_and_event,
    );
    try std.testing.expectEqual(@as(usize, 1), page_event_page.rows.len);
    try std.testing.expectEqualStrings(
        identified.session_id,
        page_event_page.rows[0].session_id,
    );

    const mobile_values = [_][]const u8{"mobile"};
    const mobile_filter = [_]analysis.Clause{.{
        .scope = .session,
        .field = .{ .kind = .device },
        .operator = .is,
        .scalar_type = .string,
        .values = &mobile_values,
    }};
    var mobile = request;
    mobile.filters = .{ .clauses = &mobile_filter };
    const mobile_page = try executeSessionList(
        arena.allocator(),
        &event_store,
        mobile,
    );
    try std.testing.expectEqual(@as(usize, 1), mobile_page.rows.len);
    try std.testing.expectEqualStrings(
        "00000000-0000-4000-8000-0000000000b2",
        mobile_page.rows[0].session_id,
    );

    const source_values = [_][]const u8{"google"};
    const campaign_values = [_][]const u8{"winter"};
    const acquisition_filters = [_]analysis.Clause{
        .{
            .scope = .session,
            .field = .{ .kind = .utm_source },
            .operator = .is,
            .scalar_type = .string,
            .values = &source_values,
        },
        .{
            .scope = .session,
            .field = .{ .kind = .utm_campaign },
            .operator = .is,
            .scalar_type = .string,
            .values = &campaign_values,
        },
    };
    var acquisition = request;
    acquisition.filters = .{ .clauses = &acquisition_filters };
    const acquisition_page = try executeSessionList(
        arena.allocator(),
        &event_store,
        acquisition,
    );
    try std.testing.expectEqual(@as(usize, 1), acquisition_page.rows.len);
    try std.testing.expectEqualStrings(
        identified.session_id,
        acquisition_page.rows[0].session_id,
    );

    const property_values = [_][]const u8{"pro"};
    const property_filter = [_]analysis.Clause{.{
        .scope = .event,
        .field = .{ .kind = .event_property, .property_ref = .{
            .name = "plan",
            .scalar_type = .string,
        } },
        .operator = .is,
        .scalar_type = .string,
        .values = &property_values,
    }};
    var property_event = request;
    property_event.filters = .{ .clauses = &property_filter };
    const property_page = try executeSessionList(
        arena.allocator(),
        &event_store,
        property_event,
    );
    try std.testing.expectEqual(@as(usize, 1), property_page.rows.len);
    try std.testing.expectEqualStrings(identified.session_id, property_page.rows[0].session_id);

    const trait_values = [_][]const u8{"business"};
    const trait_filter = [_]analysis.Clause{.{
        .scope = .person,
        .field = .{ .kind = .user_trait, .property_ref = .{
            .name = "plan",
            .scalar_type = .string,
        } },
        .operator = .is,
        .scalar_type = .string,
        .values = &trait_values,
    }};
    var person_trait = request;
    person_trait.filters = .{ .clauses = &trait_filter };
    const trait_page = try executeSessionList(
        arena.allocator(),
        &event_store,
        person_trait,
    );
    try std.testing.expectEqual(@as(usize, 2), trait_page.rows.len);
    try std.testing.expect(findSessionRow(
        trait_page.rows,
        identified.session_id,
    ) != null);

    const converted_filter = [_]analysis.Clause{.{
        .scope = .session,
        .field = .{ .kind = .session_converted },
        .operator = .is_true,
        .scalar_type = .boolean,
    }};
    var converted = request;
    converted.filters = .{ .clauses = &converted_filter };
    converted.active_goals = &predicate_goals;
    const converted_page = try executeSessionList(
        arena.allocator(),
        &event_store,
        converted,
    );
    try std.testing.expectEqual(@as(usize, 1), converted_page.rows.len);
    try std.testing.expectEqualStrings(identified.session_id, converted_page.rows[0].session_id);

    const engagement_values = [_][]const u8{"10000"};
    const engagement_filter = [_]analysis.Clause{.{
        .scope = .session,
        .field = .{ .kind = .session_engagement_ms },
        .operator = .gte,
        .scalar_type = .integer,
        .values = &engagement_values,
    }};
    var engaged = request;
    engaged.filters = .{ .clauses = &engagement_filter };
    const engaged_page = try executeSessionList(
        arena.allocator(),
        &event_store,
        engaged,
    );
    try std.testing.expectEqual(@as(usize, 1), engaged_page.rows.len);
    try std.testing.expectEqualStrings(
        "00000000-0000-4000-8000-0000000000b2",
        engaged_page.rows[0].session_id,
    );

    const duration_values = [_][]const u8{"86400000"};
    const duration_filter = [_]analysis.Clause{.{
        .scope = .session,
        .field = .{ .kind = .session_duration_ms },
        .operator = .gte,
        .scalar_type = .integer,
        .values = &duration_values,
    }};
    var long_session = request;
    long_session.filters = .{ .clauses = &duration_filter };
    const duration_page = try executeSessionList(
        arena.allocator(),
        &event_store,
        long_session,
    );
    try std.testing.expectEqual(@as(usize, 1), duration_page.rows.len);
    try std.testing.expectEqualStrings(
        identified.session_id,
        duration_page.rows[0].session_id,
    );

    const identified_values = [_][]const u8{"identified"};
    const identified_filter = [_]analysis.Clause{.{
        .scope = .person,
        .field = .{ .kind = .identity_state },
        .operator = .is,
        .scalar_type = .string,
        .values = &identified_values,
    }};
    var identified_only = request;
    identified_only.filters = .{ .clauses = &identified_filter };
    const identified_page = try executeSessionList(
        arena.allocator(),
        &event_store,
        identified_only,
    );
    try std.testing.expectEqual(@as(usize, 2), identified_page.rows.len);
    try std.testing.expect(findSessionRow(
        identified_page.rows,
        identified.session_id,
    ) != null);
    try std.testing.expect(findSessionRow(
        identified_page.rows,
        "00000000-0000-4000-8000-0000000000b9",
    ) != null);

    var current_edge = request;
    current_edge.now_utc_micros = identified.last_received_at_utc_micros +
        30 * 60 * 1_000_000;
    const current_edge_page = try executeSessionList(
        arena.allocator(),
        &event_store,
        current_edge,
    );
    try std.testing.expect((findSessionRow(
        current_edge_page.rows,
        identified.session_id,
    ) orelse return error.MissingSessionFixtureRow).current);
    current_edge.now_utc_micros += 1;
    const ended_edge_page = try executeSessionList(
        arena.allocator(),
        &event_store,
        current_edge,
    );
    try std.testing.expect(!(findSessionRow(
        ended_edge_page.rows,
        identified.session_id,
    ) orelse return error.MissingSessionFixtureRow).current);
    current_edge.now_utc_micros = identified.last_received_at_utc_micros - 1;
    const future_receipt_page = try executeSessionList(
        arena.allocator(),
        &event_store,
        current_edge,
    );
    try std.testing.expect(!(findSessionRow(
        future_receipt_page.rows,
        identified.session_id,
    ) orelse return error.MissingSessionFixtureRow).current);
    try std.testing.expect(
        identified.last_activity_utc_micros <
            identified.last_received_at_utc_micros,
    );

    const engaged_detail = try executeSessionDetail(
        arena.allocator(),
        &event_store,
        .{
            .site_id = request.site_id,
            .session_id = engaged_session.session_id,
            .active_goals = &goals,
            .now_utc_micros = request.now_utc_micros,
        },
    );
    try std.testing.expectEqual(@as(i64, 25_000), engaged_detail.summary.engagement_ms);
    try std.testing.expectEqual(@as(usize, 6), engaged_detail.timeline.len);
    try std.testing.expect(!engaged_detail.has_more);
    try std.testing.expectEqual(analysis.SessionTimelineKind.page, engaged_detail.timeline[0].kind);
    try std.testing.expectEqual(analysis.SessionTimelineKind.engagement, engaged_detail.timeline[1].kind);
    try std.testing.expectEqual(@as(i64, 15_000), engaged_detail.timeline[1].engagement_ms);
    try std.testing.expectEqual(@as(i64, 2), engaged_detail.timeline[1].engagement_fragments);
    try std.testing.expectEqualStrings("/", engaged_detail.timeline[1].path);
    try std.testing.expectEqual(analysis.SessionTimelineKind.page, engaged_detail.timeline[2].kind);
    try std.testing.expectEqualStrings("/other", engaged_detail.timeline[2].path);
    try std.testing.expectEqual(analysis.SessionTimelineKind.engagement, engaged_detail.timeline[3].kind);
    try std.testing.expectEqual(@as(i64, 7_000), engaged_detail.timeline[3].engagement_ms);
    try std.testing.expectEqual(@as(i64, 65), engaged_detail.timeline[3].max_scroll_depth);
    try std.testing.expectEqual(analysis.SessionTimelineKind.page, engaged_detail.timeline[4].kind);
    try std.testing.expectEqualStrings("/", engaged_detail.timeline[4].path);
    try std.testing.expectEqual(analysis.SessionTimelineKind.engagement, engaged_detail.timeline[5].kind);
    try std.testing.expectEqual(@as(i64, 3_000), engaged_detail.timeline[5].engagement_ms);
    try std.testing.expectEqual(@as(i64, 1), engaged_detail.timeline[5].engagement_fragments);

    const converted_detail = try executeSessionDetail(
        arena.allocator(),
        &event_store,
        .{
            .site_id = request.site_id,
            .session_id = identified.session_id,
            .active_goals = &goals,
            .now_utc_micros = request.now_utc_micros,
        },
    );
    var purchase_goal_rows: usize = 0;
    for (converted_detail.timeline) |entry| {
        if (std.mem.eql(u8, entry.event_name, "purchase")) {
            try std.testing.expectEqual(@as(u32, 3), entry.goal_mask);
            purchase_goal_rows += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), purchase_goal_rows);
    var empty_timeline_request = analysis.SessionDetailRequest{
        .site_id = request.site_id,
        .session_id = identified.session_id,
        .active_goals = &goals,
        .timeline_page = 2,
        .now_utc_micros = request.now_utc_micros,
    };
    const empty_timeline = try executeSessionDetail(
        arena.allocator(),
        &event_store,
        empty_timeline_request,
    );
    try std.testing.expectEqual(@as(usize, 0), empty_timeline.timeline.len);
    empty_timeline_request.site_id = "00000000-0000-4000-8000-000000000099";
    try std.testing.expectError(
        error.SessionNotFound,
        executeSessionDetail(
            arena.allocator(),
            &event_store,
            empty_timeline_request,
        ),
    );

    var user_profile_request = request;
    user_profile_request.profile_person_key = "u:user-a";
    const user_profile = try executePersonProfile(
        arena.allocator(),
        &event_store,
        user_profile_request,
    );
    try std.testing.expectEqual(@as(i64, 3), user_profile.summary.sessions);
    try std.testing.expectEqual(@as(i64, 2), user_profile.summary.linked_anonymous_ids);
    try std.testing.expectEqual(@as(i64, 4), user_profile.summary.conversions);
    try std.testing.expectEqualStrings(
        "{\"device\":\"second\",\"plan\":\"business\"}",
        user_profile.summary.latest_traits_json,
    );
    try std.testing.expectEqual(@as(usize, 3), user_profile.summary.revenue.len);
    try std.testing.expectEqual(@as(usize, 2), user_profile.sessions.rows.len);
    try std.testing.expect(findSessionRow(
        user_profile.sessions.rows,
        identified.session_id,
    ) != null);
    try std.testing.expect(findSessionRow(
        user_profile.sessions.rows,
        "00000000-0000-4000-8000-0000000000b9",
    ) != null);

    var anonymous_profile_request = request;
    anonymous_profile_request.profile_person_key =
        "a:00000000-0000-4000-8000-0000000000a2";
    const anonymous_profile = try executePersonProfile(
        arena.allocator(),
        &event_store,
        anonymous_profile_request,
    );
    try std.testing.expectEqual(@as(i64, 1), anonymous_profile.summary.sessions);
    try std.testing.expectEqual(@as(i64, 25_000), anonymous_profile.summary.engagement_ms);
    try std.testing.expectEqual(@as(i64, 0), anonymous_profile.summary.linked_anonymous_ids);
    try std.testing.expectEqual(@as(usize, 1), anonymous_profile.sessions.rows.len);
    var stale_anonymous_request = request;
    stale_anonymous_request.profile_person_key =
        "a:00000000-0000-4000-8000-0000000000a1";
    try std.testing.expectError(
        error.PersonNotFound,
        executePersonProfile(
            arena.allocator(),
            &event_store,
            stale_anonymous_request,
        ),
    );

    try event_store.database.exec(
        \\INSERT INTO events SELECT template.* REPLACE (
        \\  CAST('41000000-0000-4000-8000-' || lpad(i::VARCHAR, 12, '0') AS UUID) AS event_id,
        \\  1767484800000000 + (i // 2) * 1000000 AS received_at_utc_micros,
        \\  1767484800000000 + (i // 2) * 1000000 AS occurred_at_utc_micros,
        \\  DATE '2026-01-04' AS received_date_utc,
        \\  DATE '2026-01-04' AS site_local_date,
        \\  CAST('43000000-0000-4000-8000-' || lpad(i::VARCHAR, 12, '0') AS UUID) AS anonymous_id,
        \\  CAST('42000000-0000-4000-8000-' || lpad(i::VARCHAR, 12, '0') AS UUID) AS session_id,
        \\  0 AS sequence, TRUE AS session_start,
        \\  CAST('41000000-0000-4000-8000-' || lpad(i::VARCHAR, 12, '0') AS BLOB) AS visitor_day_id,
        \\  TRUE AS visitor_day_start, repeat('e', 64) AS event_payload_digest
        \\) FROM events template, range(27) source(i)
        \\WHERE template.event_id = CAST('00000000-0000-4000-8000-000000000107' AS UUID);
    );
    var first_page_request = request;
    first_page_request.range.end = "2026-01-04";
    const first_page = try executeSessionList(
        arena.allocator(),
        &event_store,
        first_page_request,
    );
    try std.testing.expectEqual(@as(usize, 25), first_page.rows.len);
    try std.testing.expect(first_page.has_more);
    try std.testing.expectEqualStrings(
        "42000000-0000-4000-8000-000000000026",
        first_page.rows[0].session_id,
    );
    try std.testing.expectEqualStrings(
        "42000000-0000-4000-8000-000000000024",
        first_page.rows[1].session_id,
    );
    try std.testing.expectEqualStrings(
        "42000000-0000-4000-8000-000000000025",
        first_page.rows[2].session_id,
    );
    var second_page_request = first_page_request;
    second_page_request.page = 2;
    const second_page = try executeSessionList(
        arena.allocator(),
        &event_store,
        second_page_request,
    );
    try std.testing.expectEqual(@as(usize, 9), second_page.rows.len);
    try std.testing.expect(!second_page.has_more);
    try std.testing.expectEqualStrings(
        "42000000-0000-4000-8000-000000000000",
        second_page.rows[0].session_id,
    );
    try std.testing.expectEqualStrings(
        "42000000-0000-4000-8000-000000000001",
        second_page.rows[1].session_id,
    );
    for (first_page.rows) |first| for (second_page.rows) |second| {
        try std.testing.expect(!std.mem.eql(u8, first.session_id, second.session_id));
    };
    var empty_page_request = first_page_request;
    empty_page_request.page = 3;
    const empty_page = try executeSessionList(
        arena.allocator(),
        &event_store,
        empty_page_request,
    );
    try std.testing.expectEqual(@as(usize, 0), empty_page.rows.len);
    try std.testing.expect(!empty_page.has_more);

    try event_store.database.exec(
        \\INSERT INTO events SELECT template.* REPLACE (
        \\  CAST('44000000-0000-4000-8000-' || lpad(i::VARCHAR, 12, '0') AS UUID) AS event_id,
        \\  1767398500000000 + i AS received_at_utc_micros,
        \\  1767398500000000 + i AS occurred_at_utc_micros,
        \\  100 + i AS sequence, 'value-only' AS event_name,
        \\  CAST(1 AS DECIMAL(18,6)) AS value_amount,
        \\  chr(65 + i::INTEGER) || 'AA' AS value_currency,
        \\  md5(i::VARCHAR) || md5(i::VARCHAR) AS event_payload_digest
        \\) FROM events template, range(15) source(i)
        \\WHERE template.event_id = CAST('00000000-0000-4000-8000-000000000104' AS UUID);
    );
    try std.testing.expectError(
        error.TooManyAnalysisCurrencies,
        executeSessionList(arena.allocator(), &event_store, request),
    );
}

fn findSessionRow(
    rows: []const analysis.SessionRow,
    session_id: []const u8,
) ?analysis.SessionRow {
    for (rows) |row| {
        if (std.mem.eql(u8, row.session_id, session_id)) return row;
    }
    return null;
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

    const sessions = try execute(query_allocator, &event_store, .{
        .query = .{
            .site_id = site,
            .range = range,
            .mode = .trend,
            .metric = .{ .kind = .sessions },
            .interval = .day,
        },
    });
    const page_views = try execute(query_allocator, &event_store, .{
        .query = .{
            .site_id = site,
            .range = range,
            .mode = .trend,
            .metric = .{ .kind = .page_views },
            .interval = .day,
        },
    });

    const set_metrics = [_]analysis.Metric{
        .{ .kind = .visitors },
        .{ .kind = .sessions },
        .{ .kind = .page_views },
    };
    const trend_set = try executeTrendSet(query_allocator, &event_store, .{
        .set = .{
            .site_id = site,
            .range = range,
            .interval = .day,
            .series = &set_metrics,
        },
    });
    try std.testing.expectEqual(@as(usize, 3), trend_set.series.len);
    try std.testing.expectEqual(
        visitors.trend.total[0].count,
        trend_set.series[0].total[0].count,
    );
    try std.testing.expectEqual(
        sessions.trend.total[0].count,
        trend_set.series[1].total[0].count,
    );
    try std.testing.expectEqual(
        page_views.trend.total[0].count,
        trend_set.series[2].total[0].count,
    );
    for (trend_set.series) |series| {
        try std.testing.expectEqualDeep(
            visitors.trend.completeness,
            series.completeness,
        );
    }
    inline for (.{
        analysis.Interval.auto,
        analysis.Interval.hour,
        analysis.Interval.day,
        analysis.Interval.week,
        analysis.Interval.month,
    }) |interval| {
        const manual = try execute(query_allocator, &event_store, .{
            .query = .{
                .site_id = site,
                .range = range,
                .mode = .trend,
                .metric = .{ .kind = .page_views },
                .interval = interval,
            },
        });
        try std.testing.expectEqual(
            if (interval == .auto) analysis.Interval.hour else interval,
            manual.trend.interval,
        );
    }

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

    const goal_values = [_][]const u8{"pro"};
    const goal_predicates = [_]analysis.PropertyPredicate{.{
        .property_ref = .{ .name = "plan", .scalar_type = .string },
        .operator = .is,
        .values = &goal_values,
    }};
    const goal_request = analysis.GoalResultRequest{
        .site_id = site,
        .range = range,
        .selector = .{
            .kind = .exact_event,
            .value = "purchase",
            .predicates = &goal_predicates,
        },
    };
    const goal = try executeGoalResult(query_allocator, &event_store, goal_request);
    try std.testing.expectEqual(@as(i64, 2), goal.total_matches);
    try std.testing.expectEqual(@as(i64, 1), goal.converting_visitors);
    try std.testing.expectEqual(@as(i64, 1), goal.converting_sessions);
    try std.testing.expectEqual(@as(i64, 4), goal.eligible_visitors);
    try std.testing.expectEqual(@as(i64, 4), goal.eligible_sessions);
    try std.testing.expectEqual(@as(i64, 1), goal.converting_coverage.persistent_people);
    try std.testing.expectEqual(@as(usize, 2), goal.revenue.len);
    try std.testing.expectEqualStrings("EUR", goal.revenue[0].currency);
    try std.testing.expectEqualStrings("12.500000", goal.revenue[0].decimal);
    try std.testing.expectEqualStrings("USD", goal.revenue[1].currency);
    try std.testing.expectEqual(@as(i64, 1), goal.path_cardinality);
    try std.testing.expectEqual(@as(usize, 1), goal.paths.len);
    try std.testing.expectEqualStrings("/pricing", goal.paths[0].path);
    try std.testing.expectEqual(@as(i64, 2), goal.paths[0].matches);

    var prefix_request = goal_request;
    prefix_request.selector = .{ .kind = .page_prefix, .value = "/" };
    const prefix_result = try executeGoalResult(
        query_allocator,
        &event_store,
        prefix_request,
    );
    try std.testing.expectEqual(@as(i64, 5), prefix_result.total_matches);
    try std.testing.expectEqual(@as(i64, 5), prefix_result.path_cardinality);
    try std.testing.expectEqual(@as(usize, 5), prefix_result.paths.len);
    try std.testing.expectEqualStrings("/", prefix_result.paths[0].path);
    try std.testing.expectEqualStrings("/ephemeral", prefix_result.paths[1].path);
    try std.testing.expectEqualStrings("/landing", prefix_result.paths[2].path);
    try std.testing.expectEqualStrings("/legacy", prefix_result.paths[3].path);
    try std.testing.expectEqualStrings("/pricing", prefix_result.paths[4].path);

    const preview = try executeGoalPreview(query_allocator, &event_store, goal_request);
    var plan_type_seen = false;
    var amount_type_seen = false;
    for (preview.properties.entries) |entry| {
        plan_type_seen = plan_type_seen or
            (std.mem.eql(u8, entry.name, "plan") and entry.scalar_type == .string);
        amount_type_seen = amount_type_seen or
            (std.mem.eql(u8, entry.name, "amount") and entry.scalar_type == .decimal);
    }
    try std.testing.expect(plan_type_seen);
    try std.testing.expect(amount_type_seen);

    const page_only_predicates = [_]analysis.PropertyPredicate{.{
        .property_ref = .{ .name = "page_only", .scalar_type = .string },
        .operator = .exists,
    }};
    var same_session_trap = goal_request;
    same_session_trap.selector.predicates = &page_only_predicates;
    try std.testing.expectEqual(
        @as(i64, 0),
        (try executeGoalResult(query_allocator, &event_store, same_session_trap)).total_matches,
    );

    const filter_values = [_][]const u8{"10.000000"};
    const goal_filters = [_]analysis.Clause{.{
        .scope = .event,
        .field = .{
            .kind = .event_property,
            .property_ref = .{ .name = "amount", .scalar_type = .decimal },
        },
        .operator = .gt,
        .scalar_type = .decimal,
        .values = &filter_values,
    }};
    var filtered_goal = goal_request;
    filtered_goal.filters = .{ .clauses = &goal_filters };
    const filtered_goal_result = try executeGoalResult(
        query_allocator,
        &event_store,
        filtered_goal,
    );
    try std.testing.expectEqual(@as(i64, 1), filtered_goal_result.total_matches);
    try std.testing.expectEqual(@as(usize, 1), filtered_goal_result.revenue.len);
    try std.testing.expectEqualStrings("EUR", filtered_goal_result.revenue[0].currency);

    const funnel_selectors = [_]analysis.EventSelector{
        .{
            .kind = .exact_event,
            .value = "purchase",
            .predicates = &goal_predicates,
        },
        .{ .kind = .page_prefix, .value = "/" },
        .{ .kind = .exact_page, .value = "/pricing" },
        .{ .kind = .exact_event, .value = "never" },
    };
    const funnel_availability = try executeFunnelAvailability(
        query_allocator,
        &event_store,
        .{
            .site_id = site,
            .range = range,
            .selectors = &funnel_selectors,
        },
    );
    try std.testing.expectEqual(@as(usize, 4), funnel_availability.len);
    try std.testing.expectEqual(@as(i64, 2), funnel_availability[0].matching_events);
    try std.testing.expectEqual(@as(i64, 5), funnel_availability[1].matching_events);
    try std.testing.expectEqual(@as(i64, 1), funnel_availability[2].matching_events);
    try std.testing.expectEqual(@as(i64, 0), funnel_availability[3].matching_events);

    const filtered_funnel_availability = try executeFunnelAvailability(
        query_allocator,
        &event_store,
        .{
            .site_id = site,
            .range = range,
            .selectors = &funnel_selectors,
            .filters = .{ .clauses = &goal_filters },
        },
    );
    try std.testing.expectEqual(@as(i64, 1), filtered_funnel_availability[0].matching_events);
    try std.testing.expectEqual(@as(i64, 0), filtered_funnel_availability[1].matching_events);
    try std.testing.expectEqual(@as(i64, 0), filtered_funnel_availability[2].matching_events);
    try std.testing.expectEqual(@as(i64, 0), filtered_funnel_availability[3].matching_events);
    _ = try event_store.eventCount();

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

    try event_store.database.exec(
        \\INSERT INTO events
        \\SELECT template.* REPLACE (
        \\  CAST(md5('breakdown-' || CAST(i AS VARCHAR)) AS UUID) AS event_id,
        \\  1767398500000000 + i AS received_at_utc_micros,
        \\  1767398500000000 + i AS occurred_at_utc_micros,
        \\  2 AS kind, 'property_probe' AS event_name,
        \\  CAST(i + 20 AS UINTEGER) AS sequence,
        \\  ('{"high":"Value-' || lpad(CAST(i AS VARCHAR), 3, '0') || '"' ||
        \\    CASE i WHEN 0 THEN ',"typed":"7"'
        \\      WHEN 1 THEN ',"typed":7'
        \\      WHEN 2 THEN ',"typed":7.500000'
        \\      WHEN 3 THEN ',"typed":true'
        \\      WHEN 4 THEN ',"typed":null'
        \\      ELSE '' END || '}') AS properties_json,
        \\  repeat('b', 64) AS event_payload_digest
        \\) FROM events template CROSS JOIN range(105) rows(i)
        \\WHERE template.event_id =
        \\  CAST('00000000-0000-4000-8000-000000000104' AS UUID)
    );
    const high_page = try executeBreakdownPage(
        query_allocator,
        &event_store,
        .{ .query = .{
            .site_id = site,
            .range = range,
            .mode = .breakdown,
            .metric = .{ .kind = .custom_events },
            .dimension = .{
                .kind = .event_property,
                .property_ref = .{ .name = "high", .scalar_type = .string },
            },
            .search = "value-10",
            .limit = 2,
        } },
    );
    try std.testing.expectEqual(@as(i64, 5), high_page.breakdown.cardinality);
    try std.testing.expectEqual(@as(usize, 2), high_page.breakdown.rows.len);
    try std.testing.expectEqual(@as(?u32, 2), high_page.breakdown.next_page);
    try std.testing.expect(high_page.site_has_events);
    try std.testing.expectEqualStrings(
        "Value-100",
        high_page.breakdown.rows[0].label.value,
    );
    try std.testing.expectEqualStrings(
        "Value-101",
        high_page.breakdown.rows[1].label.value,
    );
    const beyond = (try execute(
        query_allocator,
        &event_store,
        .{ .query = .{
            .site_id = site,
            .range = range,
            .mode = .breakdown,
            .metric = .{ .kind = .custom_events },
            .dimension = .{
                .kind = .event_property,
                .property_ref = .{ .name = "high", .scalar_type = .string },
            },
            .search = "value-10",
            .page = 100,
            .limit = 2,
        } },
    )).breakdown;
    try std.testing.expectEqual(@as(usize, 0), beyond.rows.len);
    try std.testing.expectEqual(@as(i64, 5), beyond.cardinality);
    try std.testing.expectEqual(@as(?u32, null), beyond.next_page);

    const no_match_page = try executeBreakdownPage(
        query_allocator,
        &event_store,
        .{ .query = .{
            .site_id = site,
            .range = range,
            .mode = .breakdown,
            .metric = .{
                .kind = .event_count,
                .selector = .{ .kind = .exact_event, .value = "never" },
            },
            .dimension = .{ .kind = .event_name },
        } },
    );
    try std.testing.expectEqual(@as(i64, 0), no_match_page.breakdown.cardinality);
    try std.testing.expect(no_match_page.site_has_events);
    try std.testing.expect(high_page.properties.property_count >= 4);
    var typed_types: usize = 0;
    for (high_page.properties.entries) |entry| {
        if (std.mem.eql(u8, entry.name, "typed")) typed_types += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), typed_types);

    const other_site = "00000000-0000-4000-8000-000000000025";
    try event_store.database.exec(
        \\INSERT INTO events
        \\SELECT template.* REPLACE (
        \\  CAST('00000000-0000-4000-8000-000000000205' AS UUID) AS event_id,
        \\  CAST('00000000-0000-4000-8000-000000000025' AS UUID) AS site_id,
        \\  'other_probe' AS event_name,
        \\  '{"other_only":"yes"}' AS properties_json,
        \\  repeat('c', 64) AS event_payload_digest
        \\) FROM events template WHERE template.event_id =
        \\  CAST('00000000-0000-4000-8000-000000000104' AS UUID)
    );
    const other_page = try executeBreakdownPage(
        query_allocator,
        &event_store,
        .{ .query = .{
            .site_id = other_site,
            .range = range,
            .mode = .breakdown,
            .metric = .{ .kind = .custom_events },
            .dimension = .{
                .kind = .event_property,
                .property_ref = .{ .name = "other_only", .scalar_type = .string },
            },
        } },
    );
    try std.testing.expectEqual(@as(i64, 1), other_page.breakdown.cardinality);
    try std.testing.expectEqual(@as(usize, 1), other_page.properties.entries.len);
    try std.testing.expectEqualStrings(
        "other_only",
        other_page.properties.entries[0].name,
    );

    const empty_page = try executeBreakdownPage(
        query_allocator,
        &event_store,
        .{ .query = .{
            .site_id = "00000000-0000-4000-8000-000000000026",
            .range = range,
            .mode = .breakdown,
            .metric = .{ .kind = .custom_events },
            .dimension = .{ .kind = .event_name },
        } },
    );
    try std.testing.expectEqual(@as(i64, 0), empty_page.breakdown.cardinality);
    try std.testing.expect(!empty_page.site_has_events);
    try std.testing.expectEqual(@as(usize, 0), empty_page.properties.entries.len);

    inline for (.{
        analysis.ScalarType.string,
        analysis.ScalarType.integer,
        analysis.ScalarType.decimal,
        analysis.ScalarType.boolean,
        analysis.ScalarType.null,
        analysis.ScalarType.missing,
    }) |scalar_type| {
        const typed = (try execute(
            query_allocator,
            &event_store,
            .{ .query = .{
                .site_id = site,
                .range = range,
                .mode = .breakdown,
                .metric = .{ .kind = .custom_events },
                .dimension = .{
                    .kind = .event_property,
                    .property_ref = .{
                        .name = "typed",
                        .scalar_type = scalar_type,
                    },
                },
            } },
        )).breakdown;
        try std.testing.expectEqual(@as(usize, 1), typed.rows.len);
        try std.testing.expectEqual(scalar_type, typed.rows[0].label.scalar_type.?);
        switch (typed.rows[0].measure) {
            .count => |count| try std.testing.expectEqual(
                if (scalar_type == .missing) @as(i64, 103) else 1,
                count,
            ),
            else => return error.InvalidAnalysisMeasure,
        }
    }
}

test "Live uses receipt windows, product traffic, full session source, and predicates" {
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
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const values = [_][]const u8{"pro"};
    const goals = [_]analysis.ResolvedGoal{
        .{
            .id = "00000000-0000-4000-8000-000000000401",
            .selector = .{
                .kind = .exact_event,
                .value = "purchase",
                .predicates = &.{.{
                    .property_ref = .{ .name = "plan", .scalar_type = .string },
                    .operator = .is,
                    .values = &values,
                }},
            },
        },
        .{
            .id = "00000000-0000-4000-8000-000000000402",
            .selector = .{ .kind = .exact_page, .value = "/pricing" },
        },
    };
    const request = analysis.LiveRequest{
        .site_id = "00000000-0000-4000-8000-000000000024",
        .active_goals = &goals,
        .now_utc_micros = 1_767_398_409_000_000,
    };
    try event_store.database.exec(
        \\INSERT INTO events SELECT * REPLACE (
        \\  CAST('00000000-0000-4000-8000-000000000113' AS UUID) AS event_id,
        \\  1767398406500000 AS received_at_utc_micros,
        \\  1767398406500000 AS occurred_at_utc_micros,
        \\  2 AS kind, 'source_probe' AS event_name,
        \\  '/source-probe' AS path,
        \\  CAST('00000000-0000-4000-8000-0000000000b6' AS UUID) AS session_id,
        \\  0 AS sequence, TRUE AS session_start,
        \\  'custom-referrer.example' AS referrer_host,
        \\  'custom-wrong' AS utm_source,
        \\  repeat('b', 64) AS event_payload_digest
        \\) FROM events
        \\WHERE event_id = CAST('00000000-0000-4000-8000-000000000107' AS UUID);
        \\INSERT INTO events SELECT * REPLACE (
        \\  CAST('00000000-0000-4000-8000-000000000114' AS UUID) AS event_id,
        \\  1767398407500000 AS received_at_utc_micros,
        \\  1767398407500000 AS occurred_at_utc_micros,
        \\  1 AS kind, 'pageview' AS event_name,
        \\  '/source-probe' AS path,
        \\  CAST('00000000-0000-4000-8000-0000000000b6' AS UUID) AS session_id,
        \\  1 AS sequence, FALSE AS session_start,
        \\  'page-referrer.example' AS referrer_host,
        \\  'page-right' AS utm_source,
        \\  repeat('c', 64) AS event_payload_digest
        \\) FROM events
        \\WHERE event_id = CAST('00000000-0000-4000-8000-000000000107' AS UUID);
    );
    const live = try executeLive(arena.allocator(), &event_store, request);
    try std.testing.expectEqual(@as(i64, 5), live.active_sessions);
    try std.testing.expectEqual(@as(i64, 5), live.page_views);
    try std.testing.expectEqual(@as(i64, 4), live.custom_events);
    try std.testing.expectEqual(@as(i64, 3), live.conversions);
    try std.testing.expectEqual(@as(usize, 5), live.pages.len);
    try std.testing.expectEqualStrings("/", live.pages[0].label);
    try std.testing.expectEqualStrings("/ephemeral", live.pages[1].label);
    try std.testing.expectEqualStrings("/legacy", live.pages[2].label);
    try std.testing.expectEqualStrings("/pricing", live.pages[3].label);
    try std.testing.expectEqualStrings("/source-probe", live.pages[4].label);
    try std.testing.expectEqual(@as(usize, 3), live.events.len);
    try std.testing.expectEqualStrings("purchase", live.events[0].label);
    try std.testing.expectEqual(@as(i64, 2), live.events[0].count);
    try std.testing.expectEqualStrings("delayed_event", live.events[1].label);
    try std.testing.expectEqual(@as(i64, 1), live.events[1].count);
    try std.testing.expectEqualStrings("source_probe", live.events[2].label);
    try std.testing.expectEqual(@as(usize, 3), live.sources.len);
    try std.testing.expectEqualStrings("Direct", live.sources[0].label);
    try std.testing.expectEqual(@as(i64, 3), live.sources[0].count);
    try std.testing.expectEqualStrings("google", live.sources[1].label);
    try std.testing.expectEqual(@as(i64, 1), live.sources[1].count);
    try std.testing.expectEqualStrings("page-right", live.sources[2].label);
    for (live.sources) |row| {
        try std.testing.expect(!std.mem.eql(u8, row.label, "custom-wrong"));
    }
    try std.testing.expectEqual(@as(usize, 2), live.goals.len);
    try std.testing.expectEqualStrings(goals[0].id, live.goals[0].goal_id);
    try std.testing.expectEqual(@as(i64, 2), live.goals[0].count);
    try std.testing.expectEqualStrings(goals[1].id, live.goals[1].goal_id);
    try std.testing.expectEqual(@as(i64, 1), live.goals[1].count);
    try std.testing.expectEqual(@as(usize, 4), live.countries.len);
    try std.testing.expectEqualStrings("US", live.countries[0].label);
    try std.testing.expectEqual(@as(i64, 2), live.countries[0].count);
    try std.testing.expectEqualStrings("DE", live.countries[1].label);
    try std.testing.expectEqualStrings("FR", live.countries[2].label);
    try std.testing.expectEqualStrings("Unknown", live.countries[3].label);
    try std.testing.expectEqual(@as(usize, 4), live.devices.len);
    try std.testing.expectEqual(@as(usize, 1), live.protocols.len);
    try std.testing.expectEqual(@as(u8, 2), live.protocols[0].version);
    try std.testing.expectEqual(@as(i64, 12), live.protocols[0].count);
    try std.testing.expectEqual(
        request.now_utc_micros,
        live.latest_accepted_at_utc_micros.?,
    );

    var strict = request;
    strict.strict_traffic_mode = true;
    const strict_live = try executeLive(arena.allocator(), &event_store, strict);
    try std.testing.expectEqual(live.active_sessions, strict_live.active_sessions);
    try std.testing.expectEqual(live.page_views, strict_live.page_views);
    try std.testing.expectEqual(live.custom_events, strict_live.custom_events);
    try std.testing.expectEqual(live.conversions, strict_live.conversions);
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
        \\ ('00000000-0000-4000-8000-000000000103',1767398400000000,'2026-01-03',60,1,'pageview','/pricing','Pricing','example.test','00000000-0000-4000-8000-0000000000a1',1,'user-a','00000000-0000-4000-8000-0000000000b1',1,'','DE','en','Chrome','Linux','desktop','','','','{"plan":"pro","page_only":"yes"}','{}','','',0,0),
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
