const std = @import("std");
const analysis = @import("../analysis.zig");
const calendar = @import("../calendar.zig");
const domain = @import("../domain.zig");
const report = @import("../report.zig");
const timezone = @import("../timezone.zig");
const events = @import("../store/events.zig");
const meta = @import("../store/meta.zig");
const analysis_store = @import("../store/analysis.zig");
const reports = @import("../store/reports.zig");
const model = @import("model.zig");

pub const Form = struct {
    fields: []const Field,

    pub fn parse(
        allocator: std.mem.Allocator,
        body: []const u8,
    ) !Form {
        if (body.len > 8 * 1024) return error.FormTooLarge;
        var fields: std.ArrayList(Field) = .empty;
        var pairs = std.mem.splitScalar(u8, body, '&');
        while (pairs.next()) |pair| {
            if (fields.items.len >= 24) return error.TooManyFormFields;
            const raw_name, const raw_value = std.mem.cutScalar(u8, pair, '=') orelse
                return error.InvalidFormEncoding;
            const name = try decodeComponent(allocator, raw_name);
            const value = try decodeComponent(allocator, raw_value);
            if (name.len == 0) return error.InvalidFormEncoding;
            for (fields.items) |existing| {
                if (std.mem.eql(u8, existing.name, name)) {
                    return error.DuplicateFormField;
                }
            }
            try fields.append(allocator, .{ .name = name, .value = value });
        }
        return .{ .fields = try fields.toOwnedSlice(allocator) };
    }

    pub fn required(self: Form, name: []const u8) ![]const u8 {
        for (self.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return field.value;
        }
        return error.MissingFormField;
    }

    pub fn optional(self: Form, name: []const u8) ?[]const u8 {
        for (self.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return field.value;
        }
        return null;
    }
};

pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

pub const FormContext = struct {
    range: analysis.LocalDateRange,
    comparison: analysis.Comparison,
};

pub fn formContext(form: Form) !FormContext {
    const range = analysis.LocalDateRange{
        .start = try form.required("from"),
        .end = try form.required("to"),
    };
    try range.validate();
    return .{
        .range = range,
        .comparison = try analysis.Comparison.parse(try form.required("compare")),
    };
}

pub const ParsedQuery = struct {
    site: []const u8 = "",
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    comparison: ?analysis.Comparison = null,
    legacy_from_name: bool = false,
    legacy_to_name: bool = false,
    notice: []const u8 = "",
    kind: report.Kind,
    subject: []const u8 = "",
    campaign_dimension: report.CampaignDimension = .all,
    sort: report.Sort = .count,
    limit: u16 = report.default_limit,
    page: u32 = 1,
    overview_metric: analysis.OverviewTrendMetric = .visitors,
    overview_currency: []const u8 = "",
    overview_selection_set: bool = false,
    highlighted_interval: []const u8 = "",
};

pub fn parseQuery(
    allocator: std.mem.Allocator,
    target: []const u8,
    default_kind: report.Kind,
) !ParsedQuery {
    var query = ParsedQuery{
        .kind = default_kind,
    };
    const marker = std.mem.findScalar(u8, target, '?') orelse return query;
    const encoded = target[marker + 1 ..];
    if (encoded.len > analysis.maximum_url_bytes) return error.QueryTooLarge;
    var parameter_count: usize = 0;
    var count_pairs = std.mem.splitScalar(u8, encoded, '&');
    while (count_pairs.next()) |pair| {
        if (pair.len == 0) continue;
        parameter_count += 1;
        if (parameter_count > analysis.maximum_url_parameters) {
            return error.TooManyQueryFields;
        }
    }
    var seen: std.ArrayList([]const u8) = .empty;
    var pairs = std.mem.splitScalar(u8, encoded, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        const raw_name, const raw_value = std.mem.cutScalar(u8, pair, '=') orelse
            return error.InvalidQuery;
        const name = try decodeComponent(allocator, raw_name);
        const value = try decodeComponent(allocator, raw_value);
        for (seen.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return error.DuplicateQueryField;
        }
        try seen.append(allocator, name);
        if (std.mem.eql(u8, name, "site")) {
            query.site = value;
        } else if (std.mem.eql(u8, name, "from") or
            std.mem.eql(u8, name, "start"))
        {
            if (query.from != null) return error.DuplicateQueryField;
            query.from = value;
            query.legacy_from_name = std.mem.eql(u8, name, "start");
        } else if (std.mem.eql(u8, name, "to") or
            std.mem.eql(u8, name, "end"))
        {
            if (query.to != null) return error.DuplicateQueryField;
            query.to = value;
            query.legacy_to_name = std.mem.eql(u8, name, "end");
        } else if (std.mem.eql(u8, name, "compare")) {
            query.comparison = try analysis.Comparison.parse(value);
        } else if (std.mem.eql(u8, name, "report")) {
            query.kind = try report.Kind.parse(value);
        } else if (std.mem.eql(u8, name, "subject")) {
            query.subject = value;
        } else if (std.mem.eql(u8, name, "campaign")) {
            query.campaign_dimension = try report.CampaignDimension.parse(value);
        } else if (std.mem.eql(u8, name, "sort")) {
            query.sort = try report.Sort.parse(value);
        } else if (std.mem.eql(u8, name, "limit")) {
            query.limit = std.fmt.parseInt(u16, value, 10) catch
                return error.InvalidReportLimit;
            if (query.limit == 0 or query.limit > report.maximum_limit) {
                return error.InvalidReportLimit;
            }
        } else if (std.mem.eql(u8, name, "page")) {
            query.page = std.fmt.parseInt(u32, value, 10) catch
                return error.InvalidReportPage;
            if (query.page == 0 or query.page > 1_000_000) {
                return error.InvalidReportPage;
            }
        } else if (std.mem.eql(u8, name, "notice")) {
            if (!validNotice(value)) return error.InvalidNotice;
            query.notice = value;
        } else if (std.mem.eql(u8, name, "metric") or
            std.mem.eql(u8, name, "focus"))
        {
            if (query.overview_selection_set) return error.DuplicateQueryField;
            const selection = try parseOverviewMetric(value);
            query.overview_metric = selection.metric;
            query.overview_currency = selection.currency;
            query.overview_selection_set = true;
        } else if (std.mem.eql(u8, name, "highlight")) {
            if (!validOverviewHighlight(value)) return error.InvalidOverviewHighlight;
            query.highlighted_interval = value;
        } else {
            return error.UnknownQueryField;
        }
    }
    return query;
}

pub fn finishQuery(
    parsed: ParsedQuery,
    selected_site: []const u8,
    default_range: *const calendar.Range,
    default_comparison: analysis.Comparison,
) !model.Query {
    if ((parsed.from == null) != (parsed.to == null)) {
        return error.IncompleteQueryRange;
    }
    if (parsed.from != null and parsed.legacy_from_name != parsed.legacy_to_name) {
        return error.MixedQueryRangeNames;
    }
    const range = if (parsed.from) |start|
        analysis.LocalDateRange{ .start = start, .end = parsed.to.? }
    else
        default_range.view();
    const query = model.Query{
        .site = selected_site,
        .range = range,
        .comparison = parsed.comparison orelse default_comparison,
        .kind = parsed.kind,
        .subject = parsed.subject,
        .campaign_dimension = parsed.campaign_dimension,
        .sort = parsed.sort,
        .limit = parsed.limit,
        .page = parsed.page,
        .overview_metric = parsed.overview_metric,
        .overview_currency = parsed.overview_currency,
        .highlighted_interval = parsed.highlighted_interval,
    };
    try validateQuery(query);
    return query;
}

pub fn loadPage(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    event_store: *events.Store,
    destination: model.Destination,
    query_input: model.Query,
    calendar_context: ?calendar.Context,
    site_zone: ?timezone.Zone,
    csrf_token: []const u8,
    notice: []const u8,
    report_timeout_ms: u32,
) !model.Page {
    var query = query_input;
    const sites = try metadata.listSites(allocator);
    if (sites.len == 0) {
        return .{
            .destination = destination,
            .sites = sites,
            .selected_site = null,
            .query = query,
            .calendar_context = null,
            .report_time_basis = .none,
            .result = null,
            .goals = &.{},
            .funnels = &.{},
            .self_exclusion_origins = &.{},
            .excluded_networks = &.{},
            .csrf_token = csrf_token,
            .notice = notice,
        };
    }
    const selected = try resolveSite(sites, query.site);
    query.site = selected.slug;
    try validateQuery(query);
    if (query.highlighted_interval.len != 0) {
        try validateGeneratedOverviewHighlight(
            allocator,
            query,
            calendar_context orelse return error.MissingCalendarContext,
            site_zone orelse return error.MissingCalendarZone,
        );
    }

    const goals = try metadata.listGoals(allocator, selected.slug);
    const funnels = try metadata.listFunnels(allocator, selected.slug);
    const collection_policy = try metadata.sitePolicy(allocator, selected.id);
    if (query.kind == .goal and query.subject.len == 0 and goals.len != 0) {
        query.subject = goals[0].name;
    }
    if (query.kind == .funnel and query.subject.len == 0 and funnels.len != 0) {
        query.subject = funnels[0].name;
    }

    const selected_goal: ?meta.Goal = if (query.kind == .goal and
        query.subject.len != 0)
        try metadata.goalByName(allocator, selected.slug, query.subject)
    else
        null;
    const selected_steps: ?[]const meta.FunnelStep = if (query.kind == .funnel and
        query.subject.len != 0)
        try metadata.funnelSteps(allocator, selected.slug, query.subject)
    else
        null;
    const has_subject = switch (query.kind) {
        .goal => selected_goal != null,
        .funnel => selected_steps != null,
        else => true,
    };
    const request = report.Request{
        .directory = "",
        .site_slug = selected.slug,
        .start_date = query.range.start,
        .end_date = query.range.end,
        .start_day = try report.dateDay(query.range.start),
        .end_day = try report.dateDay(query.range.end),
        .kind = query.kind,
        .subject = query.subject,
        .campaign_dimension = query.campaign_dimension,
        .sort = query.sort,
        .limit = query.limit,
        .page = query.page,
    };
    const result: ?report.Result = if (destination.runsReport() and
        destination != .overview and has_subject)
        try reports.runWithTimeout(
            allocator,
            event_store,
            request,
            selected.id,
            selected_goal,
            selected_steps,
            .{
                .strict_mode = collection_policy.strict_mode,
                .daily_event_ceiling = collection_policy.daily_event_ceiling,
                .active_goals = goals,
                .heuristic_available = goals.len <= meta.maximum_active_goals,
            },
            report_timeout_ms,
        )
    else
        null;
    var overview_details: ?model.OverviewDetails = null;
    const overview_kpis: ?model.OverviewKpis = if (destination == .overview) value: {
        const context = calendar_context orelse return error.MissingCalendarContext;
        const zone = site_zone orelse return error.MissingCalendarZone;
        const resolved_goals = try resolveAnalysisGoals(allocator, goals);
        const interval = try analysis.automaticInterval(query.range);
        const current_buckets = try buildOverviewBuckets(
            allocator,
            zone,
            query.range,
            context.utc_range,
            interval,
            if (interval == .hour and context.includes_incomplete_today)
                context.now_utc_seconds
            else
                null,
        );
        const comparison_buckets = if (context.comparison_range) |*range|
            try buildOverviewBuckets(
                allocator,
                zone,
                range.view(),
                context.comparison_utc_range.?,
                interval,
                null,
            )
        else
            &.{};
        const overview = analysis_store.executeOverview(
            allocator,
            event_store,
            .{
                .site_id = selected.id,
                .range = query.range,
                .comparison_range = if (context.comparison_range) |*range|
                    range.view()
                else
                    null,
                .active_goals = resolved_goals,
                .strict_traffic_mode = collection_policy.strict_mode,
                .daily_event_ceiling = collection_policy.daily_event_ceiling,
                .timeout_ms = report_timeout_ms,
                .trend = .{
                    .metric = query.overview_metric,
                    .currency = query.overview_currency,
                    .interval = interval,
                    .current_buckets = current_buckets,
                    .comparison_buckets = comparison_buckets,
                },
            },
        ) catch |err| {
            if (err == error.AnalysisTimeout) return error.ReportTimeout;
            return err;
        };
        overview_details = try buildOverviewDetails(
            allocator,
            overview,
            goals,
        );
        break :value try buildOverviewKpis(
            allocator,
            overview,
            query.comparison,
            context.includes_incomplete_today,
        );
    } else null;
    return .{
        .destination = destination,
        .sites = sites,
        .selected_site = selected,
        .query = query,
        .calendar_context = calendar_context,
        .report_time_basis = if (result != null) .metric_v1_utc else .none,
        .result = result,
        .overview_kpis = overview_kpis,
        .overview_details = overview_details,
        .goals = goals,
        .funnels = funnels,
        .self_exclusion_origins = collection_policy.origins,
        .excluded_networks = collection_policy.excluded_networks,
        .strict_mode = collection_policy.strict_mode,
        .daily_event_ceiling = collection_policy.daily_event_ceiling,
        .csrf_token = csrf_token,
        .notice = notice,
    };
}

fn resolveAnalysisGoals(
    allocator: std.mem.Allocator,
    goals: []const meta.Goal,
) ![]const analysis.ResolvedGoal {
    const resolved = try allocator.alloc(analysis.ResolvedGoal, goals.len);
    for (resolved, goals) |*target, goal| {
        target.* = .{
            .id = goal.id,
            .selector = .{
                .kind = switch (goal.match_kind) {
                    .event => .exact_event,
                    .path => .exact_page,
                    .prefix => .page_prefix,
                },
                .value = goal.match_value,
            },
        };
    }
    return resolved;
}

fn buildOverviewKpis(
    allocator: std.mem.Allocator,
    overview: analysis.OverviewResult,
    comparison_mode: analysis.Comparison,
    includes_incomplete_today: bool,
) !model.OverviewKpis {
    var cards: std.ArrayList(model.OverviewKpi) = .empty;
    const unavailable = if (comparison_mode == .none)
        "No comparison selected"
    else
        "Comparison unavailable";
    try cards.append(allocator, try countKpi(
        allocator,
        "Visitors",
        overview.visitors,
        unavailable,
        "Distinct modeled people with a page view or custom event in this site-local range.",
        .analyze,
    ));
    try cards.append(allocator, try countKpi(
        allocator,
        "Sessions",
        overview.sessions,
        unavailable,
        "Distinct sessions with meaningful activity in this site-local range.",
        .analyze,
    ));
    try cards.append(allocator, try countKpi(
        allocator,
        "Page views",
        overview.page_views,
        unavailable,
        "Accepted page-view events in this site-local range.",
        .analyze,
    ));
    try cards.append(allocator, try ratioKpiModel(
        allocator,
        "Engagement rate",
        overview.engagement_rate,
        unavailable,
        "Sessions with 10 seconds of active engagement, two page views, or an active-goal match, divided by sessions.",
        .analyze,
    ));
    try cards.append(allocator, try countKpi(
        allocator,
        "Conversions",
        overview.conversions,
        unavailable,
        "Matches across all active goals; one event can match more than one distinct goal.",
        .goals,
    ));
    try cards.append(allocator, try ratioKpiModel(
        allocator,
        "Conversion rate",
        overview.conversion_rate,
        unavailable,
        "Distinct visitors with any active-goal match divided by all visitors in the same range.",
        .goals,
    ));
    for (overview.revenue) |revenue| {
        const label = try std.fmt.allocPrint(
            allocator,
            "Revenue ({s})",
            .{revenue.currency},
        );
        const value = try std.fmt.allocPrint(
            allocator,
            "{s} {s}",
            .{ revenue.currency, revenue.current.decimal },
        );
        const delta = if (revenue.comparison) |prior|
            try amountDelta(
                allocator,
                revenue.current.decimal,
                prior.decimal,
            )
        else
            Delta{ .text = unavailable };
        try cards.append(allocator, .{
            .label = label,
            .value = value,
            .comparison = delta.text,
            .direction = delta.direction,
            .definition = "Exact accepted value total for this currency; currencies are never combined or converted.",
            .target = .analyze,
        });
    }
    return .{
        .cards = try cards.toOwnedSlice(allocator),
        .coverage = try coverageText(allocator, overview.completeness, "Current"),
        .comparison_coverage = if (overview.comparison_completeness) |coverage|
            try coverageText(allocator, coverage, "Comparison")
        else
            null,
        .includes_incomplete_today = includes_incomplete_today,
    };
}

fn buildOverviewDetails(
    allocator: std.mem.Allocator,
    overview: analysis.OverviewResult,
    goals: []const meta.Goal,
) !model.OverviewDetails {
    const details = overview.details orelse return error.MissingOverviewDetails;
    if (details.trend.metric == .revenue) {
        var observed = false;
        for (overview.revenue) |revenue| {
            observed = observed or std.mem.eql(
                u8,
                revenue.currency,
                details.trend.currency,
            );
        }
        if (!observed) return error.InvalidOverviewMetric;
    }
    const revenue_options = try allocator.alloc([]const u8, overview.revenue.len);
    for (revenue_options, overview.revenue) |*currency, revenue| {
        currency.* = revenue.currency;
    }

    const comparison = details.trend.comparison orelse &.{};
    const point_count = @max(details.trend.current.len, comparison.len);
    const points = try allocator.alloc(model.OverviewTrendPoint, point_count);
    for (points, 0..) |*point, index| {
        const current = if (index < details.trend.current.len)
            details.trend.current[index]
        else
            null;
        const prior = if (index < comparison.len) comparison[index] else null;
        point.* = .{
            .current_label = if (current) |value| value.label else null,
            .comparison_label = if (prior) |value| value.label else null,
            .current = if (current) |value| value.measure else null,
            .comparison = if (prior) |value| value.measure else null,
        };
    }

    const content = try allocator.alloc(model.OverviewContentRow, details.content.len);
    for (content, details.content) |*target, source| {
        if (source.page_views < 0 or source.visitors < 0 or
            source.visitors > source.page_views)
        {
            return error.InvalidOverviewDetails;
        }
        target.* = .{
            .label = source.path,
            .page_views = source.page_views,
            .visitors = source.visitors,
            .share_basis_points = if (overview.page_views.current == 0)
                0
            else
                @intCast(@divTrunc(
                    @as(i128, source.page_views) * 10_000,
                    overview.page_views.current,
                )),
        };
    }

    const acquisition = try allocator.alloc(
        model.OverviewAcquisitionRow,
        details.acquisition.len,
    );
    for (acquisition, details.acquisition) |*target, source| {
        target.* = .{
            .label = source.source,
            .sessions = source.sessions,
            .conversion = .{
                .numerator = source.converting_sessions,
                .denominator = source.sessions,
            },
        };
    }

    const conversions = try allocator.alloc(
        model.OverviewConversionRow,
        details.conversions.len,
    );
    for (conversions, details.conversions) |*target, source| {
        const goal = goalById(goals, source.goal_id) orelse
            return error.InvalidOverviewDetails;
        if (source.converting_people > overview.visitors.current) {
            return error.InvalidOverviewDetails;
        }
        target.* = .{
            .goal_name = goal.name,
            .converting_people = source.converting_people,
            .conversion = .{
                .numerator = source.converting_people,
                .denominator = overview.visitors.current,
            },
        };
    }

    const audience = try allocator.alloc(model.OverviewAudienceRow, details.audience.len);
    for (audience, details.audience) |*target, source| target.* = .{
        .label = source.country,
        .sessions = source.sessions,
    };
    return .{
        .trend = .{
            .metric = details.trend.metric,
            .currency = details.trend.currency,
            .points = points,
            .revenue_options = revenue_options,
        },
        .content = content,
        .acquisition = acquisition,
        .conversions = conversions,
        .audience = audience,
        .daily_event_ceiling = details.health.daily_event_ceiling,
        .accepted_events = details.health.accepted_events,
        .ceiling_reached_days = details.health.ceiling_reached_days,
        .last_event_utc = if (details.health.accepted_events == 0)
            "Never"
        else
            try formatUtcMicros(
                allocator,
                details.health.last_received_at_utc_micros,
            ),
        .protocol_v1_events = details.health.protocol_v1_events,
        .protocol_v2_events = details.health.protocol_v2_events,
    };
}

fn goalById(goals: []const meta.Goal, id: []const u8) ?meta.Goal {
    for (goals) |goal| if (std.mem.eql(u8, goal.id, id)) return goal;
    return null;
}

fn formatUtcMicros(allocator: std.mem.Allocator, micros: i64) ![]const u8 {
    if (micros < 0) return error.InvalidOverviewDetails;
    const seconds: u64 = @intCast(@divFloor(micros, 1_000_000));
    const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = seconds % std.time.s_per_day;
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC",
        .{
            year_day.year,
            @backingInt(month_day.month),
            month_day.day_index + 1,
            day_seconds / std.time.s_per_hour,
            day_seconds % std.time.s_per_hour / std.time.s_per_min,
        },
    );
}

const Delta = struct {
    text: []const u8,
    direction: model.KpiDirection = .neutral,
};

fn countKpi(
    allocator: std.mem.Allocator,
    label: []const u8,
    count: analysis.ComparedCount,
    unavailable: []const u8,
    definition: []const u8,
    target: model.KpiTarget,
) !model.OverviewKpi {
    if (count.current < 0) return error.InvalidOverviewCount;
    const delta = if (count.comparison) |prior|
        try countDelta(allocator, count.current, prior)
    else
        Delta{ .text = unavailable };
    return .{
        .label = label,
        .value = try std.fmt.allocPrint(allocator, "{d}", .{count.current}),
        .comparison = delta.text,
        .direction = delta.direction,
        .definition = definition,
        .target = target,
    };
}

fn ratioKpiModel(
    allocator: std.mem.Allocator,
    label: []const u8,
    ratio: analysis.ComparedRatio,
    unavailable: []const u8,
    definition: []const u8,
    target: model.KpiTarget,
) !model.OverviewKpi {
    try validateRatio(ratio.current);
    const current_available = ratio.current.denominator != 0;
    const current_basis_points = if (current_available)
        ratioBasisPoints(ratio.current)
    else
        0;
    const delta = if (!current_available)
        Delta{ .text = "Current rate unavailable" }
    else if (ratio.comparison) |prior| value: {
        try validateRatio(prior);
        if (prior.denominator == 0) {
            break :value Delta{ .text = "Comparison unavailable" };
        }
        break :value try rateDelta(
            allocator,
            @as(i32, current_basis_points) - ratioBasisPoints(prior),
        );
    } else Delta{ .text = unavailable };
    return .{
        .label = label,
        .value = if (current_available)
            try basisPointsText(allocator, current_basis_points, "%")
        else
            "Unavailable",
        .comparison = delta.text,
        .direction = delta.direction,
        .definition = definition,
        .target = target,
    };
}

fn countDelta(allocator: std.mem.Allocator, current: i64, prior: i64) !Delta {
    if (current < 0 or prior < 0) return error.InvalidOverviewCount;
    const difference = @as(i128, current) - @as(i128, prior);
    if (difference == 0) return .{ .text = "No change" };
    const direction: model.KpiDirection = if (difference > 0) .positive else .negative;
    const word = if (difference > 0) "Up" else "Down";
    if (prior == 0) return .{
        .text = try std.fmt.allocPrint(
            allocator,
            "{s} {d} · new",
            .{ word, try magnitude(difference) },
        ),
        .direction = direction,
    };
    const tenths = @divTrunc(
        (try magnitude(difference)) * 1_000,
        @as(u128, @intCast(prior)),
    );
    return .{
        .text = try std.fmt.allocPrint(
            allocator,
            "{s} {d}.{d}%",
            .{ word, tenths / 10, tenths % 10 },
        ),
        .direction = direction,
    };
}

fn rateDelta(allocator: std.mem.Allocator, basis_points: i32) !Delta {
    if (basis_points == 0) return .{ .text = "No change" };
    const direction: model.KpiDirection = if (basis_points > 0) .positive else .negative;
    const word = if (basis_points > 0) "Up" else "Down";
    const absolute: u32 = @intCast(@abs(basis_points));
    return .{
        .text = try std.fmt.allocPrint(
            allocator,
            "{s} {d}.{d:0>2} pp",
            .{ word, absolute / 100, absolute % 100 },
        ),
        .direction = direction,
    };
}

fn amountDelta(
    allocator: std.mem.Allocator,
    current_text: []const u8,
    prior_text: []const u8,
) !Delta {
    const current = try decimalMicros(current_text);
    const prior = try decimalMicros(prior_text);
    const difference = std.math.sub(i128, current, prior) catch
        return error.InvalidOverviewAmount;
    if (difference == 0) return .{ .text = "No change" };
    const direction: model.KpiDirection = if (difference > 0) .positive else .negative;
    const word = if (difference > 0) "Up" else "Down";
    if (prior == 0) return .{
        .text = try std.fmt.allocPrint(
            allocator,
            "{s} {s} · new",
            .{ word, if (current_text[0] == '-') current_text[1..] else current_text },
        ),
        .direction = direction,
    };
    const tenths = @divTrunc(
        std.math.mul(u128, try magnitude(difference), 1_000) catch
            return error.InvalidOverviewAmount,
        try magnitude(prior),
    );
    return .{
        .text = try std.fmt.allocPrint(
            allocator,
            "{s} {d}.{d}%",
            .{ word, tenths / 10, tenths % 10 },
        ),
        .direction = direction,
    };
}

fn magnitude(value: i128) !u128 {
    if (value >= 0) return @intCast(value);
    return @as(u128, @intCast(-(value + 1))) + 1;
}

fn decimalMicros(value: []const u8) !i128 {
    if (value.len == 0) return error.InvalidOverviewAmount;
    const negative = value[0] == '-';
    const unsigned = if (negative) value[1..] else value;
    const whole, const fraction = std.mem.cutScalar(u8, unsigned, '.') orelse
        return error.InvalidOverviewAmount;
    if (whole.len == 0 or fraction.len != 6) return error.InvalidOverviewAmount;
    const whole_value = std.fmt.parseInt(i128, whole, 10) catch
        return error.InvalidOverviewAmount;
    const fraction_value = std.fmt.parseInt(i128, fraction, 10) catch
        return error.InvalidOverviewAmount;
    const scaled = std.math.add(
        i128,
        std.math.mul(i128, whole_value, 1_000_000) catch
            return error.InvalidOverviewAmount,
        fraction_value,
    ) catch return error.InvalidOverviewAmount;
    return if (negative) -scaled else scaled;
}

fn validateRatio(ratio: analysis.Ratio) !void {
    if (ratio.numerator < 0 or ratio.denominator < 0 or
        ratio.numerator > ratio.denominator)
    {
        return error.InvalidOverviewRate;
    }
}

fn ratioBasisPoints(ratio: analysis.Ratio) u16 {
    std.debug.assert(ratio.denominator > 0);
    return @intCast(@divTrunc(
        @as(u128, @intCast(ratio.numerator)) * 10_000,
        @as(u128, @intCast(ratio.denominator)),
    ));
}

fn basisPointsText(
    allocator: std.mem.Allocator,
    basis_points: u16,
    suffix: []const u8,
) ![]const u8 {
    if (basis_points > 10_000) return error.InvalidOverviewRate;
    return std.fmt.allocPrint(allocator, "{d}.{d:0>2}{s}", .{
        basis_points / 100,
        basis_points % 100,
        suffix,
    });
}

fn coverageText(
    allocator: std.mem.Allocator,
    coverage: analysis.Completeness,
    label: []const u8,
) ![]const u8 {
    if (coverage.total_people < 0 or coverage.persistent_people < 0 or
        coverage.ephemeral_people < 0 or coverage.legacy_people < 0 or
        coverage.persistent_basis_points > 10_000)
    {
        return error.InvalidOverviewCoverage;
    }
    const percent = try basisPointsText(
        allocator,
        coverage.persistent_basis_points,
        "%",
    );
    return std.fmt.allocPrint(
        allocator,
        "{s} identity coverage: {s} persistent ({d} persistent, {d} ephemeral, {d} legacy daily).",
        .{
            label,
            percent,
            coverage.persistent_people,
            coverage.ephemeral_people,
            coverage.legacy_people,
        },
    );
}

pub fn addGoal(
    allocator: std.mem.Allocator,
    io: std.Io,
    metadata: *meta.Store,
    form: Form,
    now_micros: i64,
) !void {
    const site = try form.required("site");
    const name = try form.required("name");
    const kind = try domain.MatchKind.parse(try form.required("kind"));
    const value = try form.required("value");
    try domain.validateSlug(site);
    const id = try domain.randomUuid(io);
    try metadata.addGoal(allocator, &id, site, name, kind, value, now_micros);
}

pub fn deleteGoal(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    form: Form,
) !void {
    try metadata.deleteGoal(
        allocator,
        try form.required("site"),
        try form.required("name"),
    );
}

pub fn addFunnel(
    allocator: std.mem.Allocator,
    io: std.Io,
    metadata: *meta.Store,
    form: Form,
    now_micros: i64,
) !void {
    const site = try form.required("site");
    const name = try form.required("name");
    const encoded_steps = try form.required("steps");
    try domain.validateSlug(site);
    var steps: std.ArrayList(meta.FunnelStepInput) = .empty;
    var lines = std.mem.splitScalar(u8, encoded_steps, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (steps.items.len >= 8) return error.InvalidFunnelLength;
        const kind_text, const value = std.mem.cutScalar(u8, line, '=') orelse
            return error.InvalidFunnelStep;
        const trimmed_kind = std.mem.trim(u8, kind_text, " \t");
        const trimmed_value = std.mem.trim(u8, value, " \t");
        try steps.append(allocator, .{
            .name = trimmed_value,
            .match_kind = try domain.MatchKind.parse(trimmed_kind),
            .match_value = trimmed_value,
        });
    }
    if (steps.items.len < 2) return error.InvalidFunnelLength;
    const id = try domain.randomUuid(io);
    try metadata.addFunnel(
        allocator,
        &id,
        site,
        name,
        steps.items,
        now_micros,
    );
}

pub fn deleteFunnel(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    form: Form,
) !void {
    try metadata.deleteFunnel(
        allocator,
        try form.required("site"),
        try form.required("name"),
    );
}

pub fn addExcludedNetwork(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    form: Form,
    now_micros: i64,
) !void {
    try metadata.addExcludedNetwork(
        allocator,
        try form.required("site"),
        try form.required("network"),
        now_micros,
    );
}

pub fn deleteExcludedNetwork(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    form: Form,
) !void {
    try metadata.deleteExcludedNetwork(
        allocator,
        try form.required("site"),
        try form.required("network"),
    );
}

pub fn updateTrafficPolicy(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    form: Form,
    now_micros: i64,
) !void {
    const strict_mode = if (form.optional("strict")) |value|
        std.mem.eql(u8, value, "on") or return error.InvalidStrictMode
    else
        false;
    const ceiling = std.fmt.parseInt(
        i64,
        try form.required("daily_event_ceiling"),
        10,
    ) catch return error.InvalidDailyEventCeiling;
    try metadata.updateTrafficPolicy(
        allocator,
        try form.required("site"),
        strict_mode,
        ceiling,
        now_micros,
    );
}

pub fn verifyCsrf(form: Form, expected: []const u8) !void {
    const actual = try form.required("csrf");
    if (actual.len < 32 or actual.len > 128 or actual.len != expected.len) {
        return error.InvalidCsrfToken;
    }
    var difference: u8 = 0;
    for (actual, expected) |left, right| difference |= left ^ right;
    if (difference != 0) return error.InvalidCsrfToken;
}

pub fn validateQuery(query: model.Query) !void {
    try domain.validateSlug(query.site);
    query.range.validate() catch return error.InvalidReportRange;
    if (!query.kind.isPaginated() and
        (query.sort != .count or query.limit != report.default_limit or
            query.page != 1))
    {
        return error.ReportOptionsNotApplicable;
    }
    if (query.kind == .traffic_quality and query.sort != .count) {
        return error.ReportOptionsNotApplicable;
    }
    if (query.kind == .goal or query.kind == .funnel) {
        if (query.subject.len != 0) try domain.validateName(query.subject, 120);
    } else if (query.subject.len != 0) {
        return error.ReportSubjectNotApplicable;
    }
    if (query.kind != .overview and !query.kind.isList() and
        (query.overview_metric != .visitors or query.overview_currency.len != 0))
    {
        return error.OverviewMetricNotApplicable;
    }
    if (!query.kind.isList() and query.highlighted_interval.len != 0) {
        return error.OverviewHighlightNotApplicable;
    }
}

const ParsedOverviewMetric = struct {
    metric: analysis.OverviewTrendMetric,
    currency: []const u8 = "",
};

fn parseOverviewMetric(value: []const u8) !ParsedOverviewMetric {
    inline for (.{
        analysis.OverviewTrendMetric.visitors,
        analysis.OverviewTrendMetric.sessions,
        analysis.OverviewTrendMetric.page_views,
        analysis.OverviewTrendMetric.conversions,
    }) |metric| {
        if (std.mem.eql(u8, value, metric.name())) return .{ .metric = metric };
    }
    const prefix = "revenue-";
    if (!std.mem.startsWith(u8, value, prefix)) {
        return error.InvalidOverviewMetric;
    }
    const currency = value[prefix.len..];
    if (currency.len != 3) return error.InvalidOverviewMetric;
    for (currency) |byte| {
        if (byte < 'A' or byte > 'Z') return error.InvalidOverviewMetric;
    }
    return .{ .metric = .revenue, .currency = currency };
}

fn validOverviewHighlight(value: []const u8) bool {
    if (value.len == 10) {
        domain.validateDate(value) catch return false;
        return true;
    }
    if (value.len == 7 and value[4] == '-') {
        const year = std.fmt.parseInt(u16, value[0..4], 10) catch return false;
        const month = std.fmt.parseInt(u8, value[5..7], 10) catch return false;
        return year >= 1970 and month >= 1 and month <= 12;
    }
    if (value.len == 16 and value[10] == 'T' and value[13] == ':' and
        std.mem.eql(u8, value[14..16], "00"))
    {
        domain.validateDate(value[0..10]) catch return false;
        const hour = std.fmt.parseInt(u8, value[11..13], 10) catch return false;
        return hour <= 23;
    }
    return false;
}

fn validateGeneratedOverviewHighlight(
    allocator: std.mem.Allocator,
    query: model.Query,
    context: calendar.Context,
    zone: timezone.Zone,
) !void {
    const interval = try analysis.automaticInterval(query.range);
    const current = try buildOverviewBuckets(
        allocator,
        zone,
        query.range,
        context.utc_range,
        interval,
        if (interval == .hour and context.includes_incomplete_today)
            context.now_utc_seconds
        else
            null,
    );
    for (current) |bucket| {
        if (std.mem.eql(u8, query.highlighted_interval, bucket.label)) return;
    }
    if (context.comparison_range) |*range| {
        const comparison = try buildOverviewBuckets(
            allocator,
            zone,
            range.view(),
            context.comparison_utc_range orelse
                return error.MissingCalendarContext,
            interval,
            null,
        );
        for (comparison) |bucket| {
            if (std.mem.eql(u8, query.highlighted_interval, bucket.label)) return;
        }
    }
    return error.InvalidOverviewHighlight;
}

fn buildOverviewBuckets(
    allocator: std.mem.Allocator,
    zone: timezone.Zone,
    range: analysis.LocalDateRange,
    utc_range: timezone.Range,
    interval: analysis.Interval,
    hourly_cutoff_utc_seconds: ?i64,
) ![]const analysis.OverviewBucket {
    var output: std.ArrayList(analysis.OverviewBucket) = .empty;
    errdefer output.deinit(allocator);
    switch (interval) {
        .hour => {
            var second = utc_range.start_utc_seconds;
            while (second < utc_range.end_utc_seconds) : (second += 3_600) {
                if (hourly_cutoff_utc_seconds) |cutoff| {
                    if (second > cutoff) break;
                }
                const label = try zone.localHourLabel(second);
                if (output.items.len != 0 and std.mem.eql(
                    u8,
                    output.items[output.items.len - 1].label,
                    &label,
                )) continue;
                try output.append(allocator, .{
                    .label = try allocator.dupe(u8, &label),
                });
            }
        },
        .day => {
            var date = try timezone.Date.parse(range.start);
            const end = try timezone.Date.parse(range.end);
            while (date.dayNumber() <= end.dayNumber()) : (date = try date.addDays(1)) {
                const label = try date.format();
                try output.append(allocator, .{
                    .label = try allocator.dupe(u8, &label),
                });
            }
        },
        .week => {
            var date = try timezone.Date.parse(range.start);
            const end = try timezone.Date.parse(range.end);
            const days_since_monday = @mod(date.dayNumber() + 3, 7);
            date = try date.addDays(-days_since_monday);
            while (date.dayNumber() <= end.dayNumber()) : (date = try date.addDays(7)) {
                const label = try date.format();
                try output.append(allocator, .{
                    .label = try allocator.dupe(u8, &label),
                });
            }
        },
        .month => {
            var date = (try timezone.Date.parse(range.start)).firstOfMonth();
            const end = try timezone.Date.parse(range.end);
            while (date.dayNumber() <= end.dayNumber()) {
                const label = try std.fmt.allocPrint(
                    allocator,
                    "{d:0>4}-{d:0>2}",
                    .{ date.year, date.month },
                );
                try output.append(allocator, .{ .label = label });
                const next = if (date.month == 12)
                    timezone.Date{ .year = date.year + 1, .month = 1, .day = 1 }
                else
                    timezone.Date{ .year = date.year, .month = date.month + 1, .day = 1 };
                date = next;
            }
        },
        .auto => return error.InvalidOverviewInterval,
    }
    if (output.items.len == 0 or output.items.len > analysis.maximum_range_days) {
        return error.InvalidOverviewBuckets;
    }
    return output.toOwnedSlice(allocator);
}

fn validNotice(value: []const u8) bool {
    inline for (.{
        "goal-added",
        "goal-deleted",
        "funnel-added",
        "funnel-deleted",
        "network-exclusion-added",
        "network-exclusion-deleted",
        "traffic-policy-updated",
    }) |notice| {
        if (std.mem.eql(u8, value, notice)) return true;
    }
    return false;
}

fn firstActive(sites: []const meta.Site) ?meta.Site {
    for (sites) |site| if (!site.disabled) return site;
    return null;
}

fn findSite(sites: []const meta.Site, slug: []const u8) ?meta.Site {
    for (sites) |site| {
        if (std.mem.eql(u8, site.slug, slug)) return site;
    }
    return null;
}

pub fn resolveSite(sites: []const meta.Site, slug: []const u8) !meta.Site {
    if (sites.len == 0) return error.SiteNotFound;
    if (slug.len == 0) return firstActive(sites) orelse sites[0];
    return findSite(sites, slug) orelse error.SiteNotFound;
}

fn decodeComponent(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) ![]const u8 {
    const decoded = try allocator.alloc(u8, encoded.len);
    var input: usize = 0;
    var output: usize = 0;
    while (input < encoded.len) {
        if (encoded[input] == '+') {
            decoded[output] = ' ';
            input += 1;
        } else if (encoded[input] == '%') {
            if (input + 2 >= encoded.len) return error.InvalidUrlEncoding;
            decoded[output] = std.fmt.parseInt(
                u8,
                encoded[input + 1 .. input + 3],
                16,
            ) catch return error.InvalidUrlEncoding;
            input += 3;
        } else {
            decoded[output] = encoded[input];
            input += 1;
        }
        output += 1;
    }
    if (!std.unicode.utf8ValidateSlice(decoded[0..output])) {
        return error.InvalidUrlEncoding;
    }
    return decoded[0..output];
}

test "calendar query parsing finalizes canonical state and known aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const default_range = calendar.Range{
        .start = "2025-01-01".*,
        .end = "2025-01-30".*,
    };

    const canonical = try parseQuery(
        allocator,
        "/admin/sites/example/overview?from=2024-02-01&to=2024-02-29&compare=previous-year&notice=goal-added",
        .overview,
    );
    const query = try finishQuery(canonical, "example", &default_range, .previous);
    try std.testing.expectEqualStrings("2024-02-01", query.range.start);
    try std.testing.expectEqualStrings("2024-02-29", query.range.end);
    try std.testing.expectEqual(analysis.Comparison.previous_year, query.comparison);
    try std.testing.expectEqualStrings("goal-added", canonical.notice);
    try std.testing.expect(!canonical.legacy_from_name);
    try std.testing.expect(!canonical.legacy_to_name);

    const legacy = try parseQuery(
        allocator,
        "/admin/sites/example/overview?start=2025-01-01&end=2025-01-02",
        .overview,
    );
    const legacy_query = try finishQuery(legacy, "example", &default_range, .previous);
    try std.testing.expect(legacy.legacy_from_name);
    try std.testing.expect(legacy.legacy_to_name);
    try std.testing.expectEqualStrings("2025-01-01", legacy_query.range.start);
    try std.testing.expectEqual(analysis.Comparison.previous, legacy_query.comparison);

    const defaults = try finishQuery(
        try parseQuery(allocator, "/admin/sites/example/overview", .overview),
        "example",
        &default_range,
        .previous,
    );
    try std.testing.expectEqualStrings("2025-01-01", defaults.range.start);
    try std.testing.expectEqual(analysis.Comparison.previous, defaults.comparison);
}

test "calendar query parsing rejects ambiguity partial ranges and unknown state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const default_range = calendar.Range{
        .start = "2025-01-01".*,
        .end = "2025-01-30".*,
    };
    try std.testing.expectError(
        error.DuplicateQueryField,
        parseQuery(
            allocator,
            "/admin?from=2025-01-01&start=2025-01-01&to=2025-01-02",
            .overview,
        ),
    );
    try std.testing.expectError(
        error.IncompleteQueryRange,
        finishQuery(
            try parseQuery(allocator, "/admin?from=2025-01-01", .overview),
            "example",
            &default_range,
            .previous,
        ),
    );
    try std.testing.expectError(
        error.MixedQueryRangeNames,
        finishQuery(
            try parseQuery(
                allocator,
                "/admin?start=2025-01-01&to=2025-01-02",
                .overview,
            ),
            "example",
            &default_range,
            .previous,
        ),
    );
    try std.testing.expectError(
        error.MixedQueryRangeNames,
        finishQuery(
            try parseQuery(
                allocator,
                "/admin?from=2025-01-01&end=2025-01-02",
                .overview,
            ),
            "example",
            &default_range,
            .previous,
        ),
    );
    try std.testing.expectError(
        error.InvalidAnalysisComparison,
        parseQuery(allocator, "/admin?compare=year-ish", .overview),
    );
    try std.testing.expectError(
        error.InvalidNotice,
        parseQuery(allocator, "/admin?notice=made-up", .overview),
    );
    try std.testing.expectError(
        error.UnknownQueryField,
        parseQuery(allocator, "/admin?timezone=server-local", .overview),
    );

    var oversized: [analysis.maximum_url_bytes + 2]u8 = @splat('a');
    oversized[0] = '?';
    try std.testing.expectError(
        error.QueryTooLarge,
        parseQuery(allocator, &oversized, .overview),
    );
    var parameters = std.Io.Writer.Allocating.init(allocator);
    for (0..analysis.maximum_url_parameters + 1) |index| {
        try parameters.writer.print("{s}x{d}=1", .{
            if (index == 0) "?" else "&",
            index,
        });
    }
    try std.testing.expectError(
        error.TooManyQueryFields,
        parseQuery(allocator, parameters.written(), .overview),
    );
}

test "Overview metric and Analyze highlight query state is closed and contextual" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const default_range = calendar.Range{
        .start = "2025-01-01".*,
        .end = "2025-01-02".*,
    };
    const overview = try finishQuery(
        try parseQuery(
            allocator,
            "/admin/sites/example/overview?metric=sessions",
            .overview,
        ),
        "example",
        &default_range,
        .previous,
    );
    try std.testing.expectEqual(analysis.OverviewTrendMetric.sessions, overview.overview_metric);

    const handoff = try finishQuery(
        try parseQuery(
            allocator,
            "/admin/sites/example/analyze?report=pages&focus=revenue-EUR&highlight=2025-01-01T12%3A00",
            .pages,
        ),
        "example",
        &default_range,
        .previous,
    );
    try std.testing.expectEqual(analysis.OverviewTrendMetric.revenue, handoff.overview_metric);
    try std.testing.expectEqualStrings("EUR", handoff.overview_currency);
    try std.testing.expectEqualStrings("2025-01-01T12:00", handoff.highlighted_interval);

    try std.testing.expectError(
        error.DuplicateQueryField,
        parseQuery(allocator, "/admin?metric=sessions&focus=page-views", .overview),
    );
    try std.testing.expectError(
        error.InvalidOverviewMetric,
        parseQuery(allocator, "/admin?metric=revenue-eur", .overview),
    );
    try std.testing.expectError(
        error.InvalidOverviewHighlight,
        parseQuery(allocator, "/admin?highlight=2025-01-01%20all", .pages),
    );
    try std.testing.expectError(
        error.InvalidOverviewHighlight,
        parseQuery(allocator, "/admin?highlight=2025-02-30", .pages),
    );
    try std.testing.expectError(
        error.InvalidOverviewHighlight,
        parseQuery(allocator, "/admin?highlight=2025-01-01T12%3A30", .pages),
    );
    try std.testing.expectError(
        error.OverviewHighlightNotApplicable,
        finishQuery(
            try parseQuery(allocator, "/admin?highlight=2025-01-01", .overview),
            "example",
            &default_range,
            .previous,
        ),
    );
    try std.testing.expectError(
        error.OverviewMetricNotApplicable,
        finishQuery(
            try parseQuery(allocator, "/admin?metric=sessions", .traffic_quality),
            "example",
            &default_range,
            .previous,
        ),
    );
}

test "Overview highlight is one exact generated current or comparison bucket" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var utc = try timezone.load(
        allocator,
        std.testing.io,
        timezone.default_zoneinfo_root,
        "UTC",
    );
    defer utc.deinit(allocator);
    const context = try calendar.resolve(
        utc,
        "UTC",
        1_735_776_000,
        .{ .start = "2025-01-01", .end = "2025-01-02" },
        .previous,
    );
    var query = model.Query{
        .site = "example",
        .range = .{ .start = "2025-01-01", .end = "2025-01-02" },
        .comparison = .previous,
        .kind = .pages,
        .highlighted_interval = "2025-01-01T12:00",
    };
    try validateGeneratedOverviewHighlight(allocator, query, context, utc);
    query.highlighted_interval = "2024-12-31T12:00";
    try validateGeneratedOverviewHighlight(allocator, query, context, utc);
    query.highlighted_interval = "2025-01-03T00:00";
    try std.testing.expectError(
        error.InvalidOverviewHighlight,
        validateGeneratedOverviewHighlight(allocator, query, context, utc),
    );
}

test "current hourly Overview buckets stop at now and retain DST semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var utc = try timezone.load(
        allocator,
        std.testing.io,
        timezone.default_zoneinfo_root,
        "UTC",
    );
    defer utc.deinit(allocator);
    const utc_context = try calendar.resolve(
        utc,
        "UTC",
        1_735_821_296,
        .{ .start = "2025-01-01", .end = "2025-01-02" },
        .previous,
    );
    const current = try buildOverviewBuckets(
        allocator,
        utc,
        .{ .start = "2025-01-01", .end = "2025-01-02" },
        utc_context.utc_range,
        .hour,
        utc_context.now_utc_seconds,
    );
    try std.testing.expectEqual(@as(usize, 37), current.len);
    try std.testing.expectEqualStrings("2025-01-02T12:00", current[current.len - 1].label);
    const comparison = try buildOverviewBuckets(
        allocator,
        utc,
        utc_context.comparison_range.?.view(),
        utc_context.comparison_utc_range.?,
        .hour,
        null,
    );
    try std.testing.expectEqual(@as(usize, 48), comparison.len);

    var berlin = try timezone.load(
        allocator,
        std.testing.io,
        timezone.default_zoneinfo_root,
        "Europe/Berlin",
    );
    defer berlin.deinit(allocator);
    const spring_range = try berlin.rangeForInclusiveDates("2024-03-31", "2024-03-31");
    const spring = try buildOverviewBuckets(
        allocator,
        berlin,
        .{ .start = "2024-03-31", .end = "2024-03-31" },
        spring_range,
        .hour,
        1_711_848_600,
    );
    try std.testing.expectEqual(@as(usize, 3), spring.len);
    try std.testing.expectEqualStrings("2024-03-31T03:00", spring[2].label);
    for (spring) |bucket| {
        try std.testing.expect(!std.mem.eql(u8, bucket.label, "2024-03-31T02:00"));
    }
    const autumn_range = try berlin.rangeForInclusiveDates("2024-10-27", "2024-10-27");
    const autumn = try buildOverviewBuckets(
        allocator,
        berlin,
        .{ .start = "2024-10-27", .end = "2024-10-27" },
        autumn_range,
        .hour,
        1_729_992_600,
    );
    try std.testing.expectEqual(@as(usize, 3), autumn.len);
    try std.testing.expectEqualStrings("2024-10-27T02:00", autumn[2].label);
}

test "modifying form requires and preserves typed calendar context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try Form.parse(
        arena.allocator(),
        "from=2024-02-01&to=2024-02-29&compare=previous-year",
    );
    const context = try formContext(parsed);
    try std.testing.expectEqualStrings("2024-02-01", context.range.start);
    try std.testing.expectEqualStrings("2024-02-29", context.range.end);
    try std.testing.expectEqual(analysis.Comparison.previous_year, context.comparison);
    try std.testing.expectError(
        error.MissingFormField,
        formContext(try Form.parse(arena.allocator(), "from=2024-02-01&to=2024-02-29")),
    );
}

test "Overview KPI view model formats exact deltas coverage and currencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const revenue = [_]analysis.ComparedAmount{
        .{
            .currency = "EUR",
            .current = .{ .decimal = "10.000000", .currency = "EUR", .value_count = 2 },
            .comparison = .{ .decimal = "5.000000", .currency = "EUR", .value_count = 1 },
        },
        .{
            .currency = "USD",
            .current = .{ .decimal = "-5.250000", .currency = "USD", .value_count = 1 },
            .comparison = .{ .decimal = "0.000000", .currency = "USD", .value_count = 0 },
        },
    };
    const coverage = analysis.Completeness{
        .total_people = 4,
        .persistent_people = 2,
        .ephemeral_people = 1,
        .legacy_people = 1,
        .persistent_basis_points = 5_000,
        .persistent_since_local_date = "2026-01-01",
    };
    const view = try buildOverviewKpis(
        arena.allocator(),
        .{
            .visitors = .{ .current = 4, .comparison = 1 },
            .sessions = .{ .current = 0, .comparison = 0 },
            .page_views = .{ .current = 0, .comparison = 5 },
            .engagement_rate = .{
                .current = .{ .numerator = 1, .denominator = 4 },
                .comparison = .{ .numerator = 3, .denominator = 4 },
            },
            .conversions = .{ .current = 2, .comparison = 0 },
            .conversion_rate = .{
                .current = .{ .numerator = 1, .denominator = 4 },
                .comparison = .{ .numerator = 0, .denominator = 4 },
            },
            .revenue = &revenue,
            .completeness = coverage,
            .comparison_completeness = coverage,
        },
        .previous,
        false,
    );
    try std.testing.expectEqual(@as(usize, 8), view.cards.len);
    try std.testing.expectEqualStrings("Up 300.0%", view.cards[0].comparison);
    try std.testing.expectEqualStrings("No change", view.cards[1].comparison);
    try std.testing.expectEqualStrings("Down 100.0%", view.cards[2].comparison);
    try std.testing.expectEqualStrings("25.00%", view.cards[3].value);
    try std.testing.expectEqualStrings("Down 50.00 pp", view.cards[3].comparison);
    try std.testing.expectEqualStrings("Up 2 · new", view.cards[4].comparison);
    try std.testing.expectEqualStrings("Up 25.00 pp", view.cards[5].comparison);
    try std.testing.expectEqualStrings("Revenue (EUR)", view.cards[6].label);
    try std.testing.expectEqualStrings("EUR 10.000000", view.cards[6].value);
    try std.testing.expectEqualStrings("Up 100.0%", view.cards[6].comparison);
    try std.testing.expectEqualStrings("USD -5.250000", view.cards[7].value);
    try std.testing.expectEqualStrings("Down 5.250000 · new", view.cards[7].comparison);
    try std.testing.expectEqualStrings(
        "Current identity coverage: 50.00% persistent (2 persistent, 1 ephemeral, 1 legacy daily).",
        view.coverage,
    );

    const no_comparison = try buildOverviewKpis(
        arena.allocator(),
        .{
            .visitors = .{ .current = 0, .comparison = null },
            .sessions = .{ .current = 0, .comparison = null },
            .page_views = .{ .current = 0, .comparison = null },
            .engagement_rate = .{
                .current = .{ .numerator = 0, .denominator = 0 },
                .comparison = null,
            },
            .conversions = .{ .current = 0, .comparison = null },
            .conversion_rate = .{
                .current = .{ .numerator = 0, .denominator = 0 },
                .comparison = null,
            },
            .revenue = &.{},
            .completeness = .{
                .total_people = 0,
                .persistent_people = 0,
                .ephemeral_people = 0,
                .legacy_people = 0,
                .persistent_basis_points = 0,
                .persistent_since_local_date = null,
            },
            .comparison_completeness = null,
        },
        .none,
        true,
    );
    try std.testing.expectEqualStrings("Unavailable", no_comparison.cards[3].value);
    try std.testing.expectEqualStrings(
        "Current rate unavailable",
        no_comparison.cards[3].comparison,
    );
    try std.testing.expectEqualStrings(
        "No comparison selected",
        no_comparison.cards[0].comparison,
    );
    try std.testing.expect(no_comparison.comparison_coverage == null);
    try std.testing.expect(no_comparison.includes_incomplete_today);
}

test "Overview accepted-event receipt formatting preserves the Unix epoch" {
    const value = try formatUtcMicros(std.testing.allocator, 0);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings(
        "1970-01-01 00:00 UTC",
        value,
    );
}
