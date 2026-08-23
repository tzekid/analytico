const std = @import("std");
const analysis = @import("../analysis.zig");
const calendar = @import("../calendar.zig");
const domain = @import("../domain.zig");
const report = @import("../report.zig");
const events = @import("../store/events.zig");
const meta = @import("../store/meta.zig");
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
    const result: ?report.Result = if (destination.runsReport() and has_subject)
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
    var quality_request = request;
    quality_request.kind = .traffic_quality;
    quality_request.limit = report.maximum_limit;
    quality_request.page = 1;
    const overview_quality: ?report.TrafficQuality = if (destination == .overview)
        try reports.trafficQuality(
            allocator,
            event_store,
            quality_request,
            selected.id,
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
    return .{
        .destination = destination,
        .sites = sites,
        .selected_site = selected,
        .query = query,
        .calendar_context = calendar_context,
        .report_time_basis = if (result != null) .metric_v1_utc else .none,
        .result = result,
        .overview_quality = overview_quality,
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
