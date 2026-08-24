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

pub fn submitSite(
    allocator: std.mem.Allocator,
    io: std.Io,
    metadata: *meta.Store,
    form: Form,
    csrf_token: []const u8,
    zoneinfo_root: []const u8,
    now_utc_micros: i64,
) !model.SiteSubmission {
    const draft = model.SiteDraft{
        .name = form.optional("name") orelse "",
        .slug = form.optional("slug") orelse "",
        .origin = form.optional("origin") orelse "",
        .timezone = form.optional("timezone") orelse "",
        .currency = form.optional("currency") orelse "",
    };
    var errors = model.SiteFormErrors{};
    const name = std.mem.trim(u8, draft.name, " \t\r\n");
    domain.validateName(name, 120) catch {
        errors.name = "Enter a display name between 1 and 120 UTF-8 bytes.";
    };

    const raw_slug = std.mem.trim(u8, draft.slug, " \t\r\n");
    const slug = if (raw_slug.len != 0)
        try allocator.dupe(u8, raw_slug)
    else if (errors.name.len == 0)
        try generatedSlug(allocator, name)
    else
        try allocator.dupe(u8, "");
    if (slug.len != 0) {
        domain.validateSlug(slug) catch {
            errors.slug = "Use 1–48 lowercase letters, numbers, or hyphens.";
        };
    }

    const raw_origin = std.mem.trim(u8, draft.origin, " \t\r\n");
    const origin = domain.normalizeOrigin(allocator, raw_origin) catch value: {
        errors.origin = "Enter an exact HTTPS origin, or loopback HTTP for development.";
        break :value try allocator.dupe(u8, "");
    };
    if (errors.origin.len == 0 and !secureOrLoopbackOrigin(origin)) {
        errors.origin = "Use HTTPS unless the origin is localhost, 127.0.0.1, or [::1].";
    }

    const timezone_name = std.mem.trim(u8, draft.timezone, " \t\r\n");
    if (!validSiteTimezone(
        allocator,
        io,
        zoneinfo_root,
        timezone_name,
        @divFloor(now_utc_micros, 1_000_000),
    )) {
        errors.timezone = "Choose an installed IANA timezone such as UTC or Europe/Berlin.";
    }

    const currency = std.mem.trim(u8, draft.currency, " \t\r\n");
    domain.validateCurrency(currency) catch {
        errors.currency = "Use three uppercase letters such as EUR, or leave this empty.";
    };
    if (errors.any()) {
        return .{ .invalid = .{
            .csrf_token = csrf_token,
            .draft = draft,
            .errors = errors,
        } };
    }

    const id = try domain.randomUuid(io);
    _ = metadata.createSite(allocator, .{
        .id = &id,
        .slug = slug,
        .name = name,
        .origin = origin,
        .timezone_name = timezone_name,
        .default_currency = currency,
        .created_at_utc_micros = now_utc_micros,
    }) catch |err| switch (err) {
        error.SiteSlugConflict => return .{ .invalid = .{
            .csrf_token = csrf_token,
            .draft = draft,
            .errors = .{ .slug = "That slug already belongs to a different site configuration." },
        } },
        error.SiteOriginConflict => return .{ .invalid = .{
            .csrf_token = csrf_token,
            .draft = draft,
            .errors = .{ .origin = "That exact origin already belongs to another site or outcome." },
        } },
        error.SiteTimezoneConflict => return .{ .invalid = .{
            .csrf_token = csrf_token,
            .draft = draft,
            .errors = .{ .timezone = "That site already has a different reporting timezone." },
        } },
        error.SiteCurrencyConflict => return .{ .invalid = .{
            .csrf_token = csrf_token,
            .draft = draft,
            .errors = .{ .currency = "That site already has a different default currency." },
        } },
        else => return err,
    };
    return .{ .stored = .{ .slug = slug } };
}

fn generatedSlug(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var separator_pending = false;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte)) {
            if (separator_pending and output.items.len != 0) {
                if (output.items.len >= 47) break;
                try output.append(allocator, '-');
            }
            separator_pending = false;
            if (output.items.len >= 48) break;
            try output.append(allocator, std.ascii.toLower(byte));
        } else {
            separator_pending = true;
        }
    }
    if (output.items.len == 0) return allocator.dupe(u8, "site");
    return output.toOwnedSlice(allocator);
}

fn secureOrLoopbackOrigin(origin: []const u8) bool {
    if (std.mem.startsWith(u8, origin, "https://")) return true;
    if (!std.mem.startsWith(u8, origin, "http://")) return false;
    const authority = origin["http://".len..];
    return exactHostOrPort(authority, "localhost") or
        exactHostOrPort(authority, "127.0.0.1") or
        exactHostOrPort(authority, "[::1]");
}

fn exactHostOrPort(authority: []const u8, host: []const u8) bool {
    return std.mem.eql(u8, authority, host) or
        authority.len > host.len + 1 and
            std.mem.startsWith(u8, authority, host) and
            authority[host.len] == ':';
}

test "site creation permits only exact HTTP loopback origins" {
    inline for (.{
        "http://localhost",
        "http://localhost:8080",
        "http://127.0.0.1",
        "http://127.0.0.1:8080",
        "http://[::1]",
        "http://[::1]:8080",
    }) |origin| {
        try std.testing.expect(secureOrLoopbackOrigin(origin));
    }
    inline for (.{
        "http://localhost.evil",
        "http://localhost.evil:8080",
        "http://127.0.0.1.evil",
        "http://[::1].evil",
    }) |origin| {
        try std.testing.expect(!secureOrLoopbackOrigin(origin));
    }
}

fn validSiteTimezone(
    allocator: std.mem.Allocator,
    io: std.Io,
    zoneinfo_root: []const u8,
    name: []const u8,
    now_utc_seconds: i64,
) bool {
    var zone = timezone.load(allocator, io, zoneinfo_root, name) catch return false;
    defer zone.deinit(allocator);
    _ = zone.localAt(now_utc_seconds) catch return false;
    return true;
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
    report_set: bool = false,
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
            query.report_set = true;
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

pub fn translateOverviewTrendHandoff(
    allocator: std.mem.Allocator,
    parsed: ParsedQuery,
) !?ParsedTrendQuery {
    if (!parsed.overview_selection_set or parsed.site.len != 0 or
        parsed.kind != .pages or parsed.subject.len != 0 or
        parsed.campaign_dimension != .all or parsed.sort != .count or
        parsed.limit != report.default_limit or parsed.page != 1)
    {
        return null;
    }
    const kind: analysis.MetricKind = switch (parsed.overview_metric) {
        .visitors => .visitors,
        .sessions => .sessions,
        .page_views => .page_views,
        .conversions, .revenue => return null,
    };
    const series = try allocator.alloc(analysis.Metric, 1);
    series[0] = .{ .kind = kind };
    return .{
        .from = parsed.from,
        .to = parsed.to,
        .comparison = parsed.comparison,
        .series = series,
        .highlighted_interval = parsed.highlighted_interval,
    };
}

pub const ParsedTrendQuery = struct {
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    comparison: ?analysis.Comparison = null,
    interval: analysis.Interval = .auto,
    series: []const analysis.Metric = &.{},
    highlighted_interval: []const u8 = "",
};

pub fn parseTrendQuery(
    allocator: std.mem.Allocator,
    target: []const u8,
) !ParsedTrendQuery {
    const marker = std.mem.findScalar(u8, target, '?') orelse
        return .{ .series = try defaultTrendSeries(allocator) };
    const encoded = target[marker + 1 ..];
    if (encoded.len == 0) {
        return .{ .series = try defaultTrendSeries(allocator) };
    }
    if (encoded.len > analysis.maximum_url_bytes) return error.QueryTooLarge;

    var parsed = ParsedTrendQuery{};
    var version: ?[]const u8 = null;
    var mode: ?[]const u8 = null;
    var interval_seen = false;
    var highlight_seen = false;
    var canonical_series: std.ArrayList(analysis.Metric) = .empty;
    var builder_metric: [analysis.maximum_series]?[]const u8 = @splat(null);
    var builder_event: [analysis.maximum_series]?[]const u8 = @splat(null);
    var builder_goal: [analysis.maximum_series]?[]const u8 = @splat(null);
    var builder_seen = false;
    var canonical_seen = false;
    var parameter_count: usize = 0;
    var parameters = std.mem.splitScalar(u8, encoded, '&');
    while (parameters.next()) |parameter| {
        if (parameter.len == 0) return error.InvalidTrendQuery;
        parameter_count += 1;
        if (parameter_count > analysis.maximum_url_parameters) {
            return error.TooManyQueryFields;
        }
        const raw_name, const raw_value = std.mem.cutScalar(u8, parameter, '=') orelse
            return error.InvalidTrendQuery;
        if (raw_name.len == 0) return error.InvalidTrendQuery;
        const name = try decodeComponent(allocator, raw_name);
        if (std.mem.eql(u8, name, "series")) {
            canonical_seen = true;
            if (canonical_series.items.len >= analysis.maximum_series) {
                return error.InvalidTrendSeriesCount;
            }
            try canonical_series.append(
                allocator,
                try analysis.parseTrendSeries(allocator, raw_value),
            );
            continue;
        }
        const value = try decodeComponent(allocator, raw_value);
        if (std.mem.eql(u8, name, "v")) {
            canonical_seen = true;
            try setParsedOnce(&version, value);
        } else if (std.mem.eql(u8, name, "mode")) {
            canonical_seen = true;
            try setParsedOnce(&mode, value);
        } else if (std.mem.eql(u8, name, "from")) {
            try setParsedOnce(&parsed.from, value);
        } else if (std.mem.eql(u8, name, "to")) {
            try setParsedOnce(&parsed.to, value);
        } else if (std.mem.eql(u8, name, "compare")) {
            if (parsed.comparison != null) return error.DuplicateQueryField;
            parsed.comparison = try analysis.Comparison.parse(value);
        } else if (std.mem.eql(u8, name, "interval")) {
            if (interval_seen) return error.DuplicateQueryField;
            parsed.interval = try analysis.Interval.parse(value);
            interval_seen = true;
        } else if (std.mem.eql(u8, name, "highlight")) {
            if (highlight_seen) return error.DuplicateQueryField;
            highlight_seen = true;
            if (!validOverviewHighlight(value)) {
                return error.InvalidOverviewHighlight;
            }
            parsed.highlighted_interval = value;
        } else if (builderField(name, "metric-")) |slot| {
            builder_seen = true;
            try setParsedOnce(&builder_metric[slot], value);
        } else if (builderField(name, "event-")) |slot| {
            builder_seen = true;
            try setParsedOnce(&builder_event[slot], value);
        } else if (builderField(name, "goal-")) |slot| {
            builder_seen = true;
            try setParsedOnce(&builder_goal[slot], value);
        } else {
            return error.UnknownQueryField;
        }
    }
    if (canonical_seen and builder_seen) return error.MixedTrendQueryShape;
    if (canonical_seen) {
        if (!std.mem.eql(u8, version orelse return error.IncompleteTrendQuery, "1") or
            !std.mem.eql(u8, mode orelse return error.IncompleteTrendQuery, "trend") or
            parsed.from == null or parsed.to == null or parsed.comparison == null or
            !interval_seen or canonical_series.items.len == 0)
        {
            return error.IncompleteTrendQuery;
        }
        parsed.series = try canonical_series.toOwnedSlice(allocator);
        return parsed;
    }

    var series: std.ArrayList(analysis.Metric) = .empty;
    for (0..analysis.maximum_series) |slot| {
        const metric_name = builder_metric[slot] orelse "";
        const event_name = builder_event[slot] orelse "";
        const goal_id = builder_goal[slot] orelse "";
        if (metric_name.len == 0) {
            if (event_name.len != 0 or goal_id.len != 0) {
                return error.TrendSubjectWithoutMetric;
            }
            continue;
        }
        try series.append(
            allocator,
            try browserTrendMetric(metric_name, event_name, goal_id),
        );
    }
    parsed.series = if (series.items.len == 0)
        try defaultTrendSeries(allocator)
    else
        try series.toOwnedSlice(allocator);
    return parsed;
}

pub fn finishTrendQuery(
    parsed: ParsedTrendQuery,
    site_slug: []const u8,
    site_id: []const u8,
    default_range: *const calendar.Range,
    default_comparison: analysis.Comparison,
) !model.Query {
    if ((parsed.from == null) != (parsed.to == null)) {
        return error.IncompleteQueryRange;
    }
    const range = if (parsed.from) |start|
        analysis.LocalDateRange{ .start = start, .end = parsed.to.? }
    else
        default_range.view();
    const comparison = parsed.comparison orelse default_comparison;
    try (analysis.TrendSet{
        .site_id = site_id,
        .range = range,
        .comparison = comparison,
        .interval = parsed.interval,
        .series = parsed.series,
    }).validate();
    const query = model.Query{
        .site = site_slug,
        .analysis_site_id = site_id,
        .range = range,
        .comparison = comparison,
        .kind = .overview,
        .highlighted_interval = parsed.highlighted_interval,
        .analysis_interval = parsed.interval,
        .analysis_series = parsed.series,
    };
    try validateQuery(query);
    return query;
}

fn defaultTrendSeries(allocator: std.mem.Allocator) ![]const analysis.Metric {
    const series = try allocator.alloc(analysis.Metric, 1);
    series[0] = .{ .kind = .visitors };
    return series;
}

fn browserTrendMetric(
    metric_name: []const u8,
    event_name: []const u8,
    goal_id: []const u8,
) !analysis.Metric {
    const kind = try analysis.MetricKind.parse(metric_name);
    const metric: analysis.Metric = switch (kind) {
        .event_count, .event_visitors => if (event_name.len != 0 and goal_id.len == 0)
            .{
                .kind = kind,
                .selector = .{ .kind = .exact_event, .value = event_name },
            }
        else
            return error.InvalidTrendSubject,
        .conversions, .conversion_rate => if (goal_id.len != 0 and event_name.len == 0)
            .{
                .kind = kind,
                .selector = .{ .kind = .saved_goal, .value = goal_id },
                .conversion_basis = .visitor,
            }
        else
            return error.InvalidTrendSubject,
        .revenue, .average_value => if (event_name.len != 0 and goal_id.len == 0)
            .{
                .kind = kind,
                .selector = .{ .kind = .exact_event, .value = event_name },
            }
        else if (goal_id.len != 0 and event_name.len == 0)
            .{
                .kind = kind,
                .selector = .{ .kind = .saved_goal, .value = goal_id },
            }
        else if (goal_id.len == 0 and event_name.len == 0)
            .{ .kind = kind }
        else
            return error.InvalidTrendSubject,
        else => if (event_name.len == 0 and goal_id.len == 0)
            .{ .kind = kind }
        else
            return error.InvalidTrendSubject,
    };
    try analysis.validateTrendSeries(metric);
    return metric;
}

fn builderField(name: []const u8, prefix: []const u8) ?usize {
    if (!std.mem.startsWith(u8, name, prefix) or name.len != prefix.len + 1) {
        return null;
    }
    const digit = name[prefix.len];
    if (digit < '1' or digit > '0' + analysis.maximum_series) return null;
    return digit - '1';
}

fn setParsedOnce(target: *?[]const u8, value: []const u8) !void {
    if (target.* != null) return error.DuplicateQueryField;
    target.* = value;
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
    query.analysis_site_id = selected.id;
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

pub fn loadTrendPage(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    event_store: *events.Store,
    query_input: model.Query,
    calendar_context: calendar.Context,
    site_zone: timezone.Zone,
    csrf_token: []const u8,
    report_timeout_ms: u32,
) !model.Page {
    var query = query_input;
    const sites = try metadata.listSites(allocator);
    if (sites.len == 0) return error.SiteNotFound;
    const selected = try resolveSite(sites, query.site);
    query.site = selected.slug;
    query.analysis_site_id = selected.id;
    try validateQuery(query);

    const goals = try metadata.listGoals(allocator, selected.slug);
    const funnels = try metadata.listFunnels(allocator, selected.slug);
    const policy = try metadata.sitePolicy(allocator, selected.id);
    for (query.analysis_series) |metric| if (metric.selector) |selector| {
        if (selector.kind == .saved_goal and goalById(goals, selector.value) == null) {
            return error.GoalNotFound;
        }
    };
    const resolved_goals = try resolveAnalysisGoals(allocator, goals);
    const execution = analysis.TrendSetExecution{
        .set = .{
            .site_id = selected.id,
            .range = query.range,
            .comparison = query.comparison,
            .interval = query.analysis_interval,
            .series = query.analysis_series,
        },
        .comparison_range = if (calendar_context.comparison_range) |*range|
            range.view()
        else
            null,
        .active_goals = resolved_goals,
        .strict_traffic_mode = policy.strict_mode,
        .timeout_ms = report_timeout_ms,
    };
    const executed = analysis_store.executeTrendSet(
        allocator,
        event_store,
        execution,
    ) catch |err| {
        if (err == error.AnalysisTimeout) return error.ReportTimeout;
        if (err == error.TooManyAnalysisCurrencies or
            err == error.TooManyAnalysisTrendRows)
        {
            return error.TooManyAnalyzeTrendSeries;
        }
        return err;
    };
    if (executed.series.len != query.analysis_series.len or
        executed.series.len == 0)
    {
        return error.InvalidAnalyzeTrendResult;
    }
    const interval = executed.series[0].interval;
    for (executed.series[1..]) |result| if (result.interval != interval) {
        return error.InvalidAnalyzeTrendResult;
    };
    const current_buckets = try buildOverviewBuckets(
        allocator,
        site_zone,
        query.range,
        calendar_context.utc_range,
        interval,
        if (interval == .hour and calendar_context.includes_incomplete_today)
            calendar_context.now_utc_seconds
        else
            null,
    );
    const comparison_buckets = if (calendar_context.comparison_range) |*range|
        try buildOverviewBuckets(
            allocator,
            site_zone,
            range.view(),
            calendar_context.comparison_utc_range orelse
                return error.MissingCalendarContext,
            interval,
            null,
        )
    else
        &.{};
    if (query.highlighted_interval.len != 0 and
        !bucketContains(current_buckets, query.highlighted_interval) and
        !bucketContains(comparison_buckets, query.highlighted_interval))
    {
        return error.InvalidOverviewHighlight;
    }
    const bounds = try event_store.siteEventBounds(selected.id);
    const incomplete_bucket = if (calendar_context.includes_incomplete_today)
        try currentAnalyzeBucketLabel(
            allocator,
            site_zone,
            calendar_context.now_utc_seconds,
            interval,
        )
    else
        "";
    const view = try buildAnalyzeTrend(
        allocator,
        query.analysis_series,
        executed,
        goals,
        current_buckets,
        comparison_buckets,
        incomplete_bucket,
        query.highlighted_interval,
        bounds.count == 0,
    );
    return .{
        .destination = .analyze,
        .sites = sites,
        .selected_site = selected,
        .query = query,
        .calendar_context = calendar_context,
        .report_time_basis = .none,
        .result = null,
        .analyze_trend = view,
        .goals = goals,
        .funnels = funnels,
        .self_exclusion_origins = policy.origins,
        .excluded_networks = policy.excluded_networks,
        .strict_mode = policy.strict_mode,
        .daily_event_ceiling = policy.daily_event_ceiling,
        .csrf_token = csrf_token,
    };
}

pub fn validateTrendHighlight(
    allocator: std.mem.Allocator,
    query: model.Query,
    context: calendar.Context,
    zone: timezone.Zone,
) !void {
    if (query.highlighted_interval.len == 0) return;
    const interval = if (query.analysis_interval == .auto)
        try analysis.automaticInterval(query.range)
    else
        query.analysis_interval;
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
    if (bucketContains(current, query.highlighted_interval)) return;
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
        if (bucketContains(comparison, query.highlighted_interval)) return;
    }
    return error.InvalidOverviewHighlight;
}

fn buildAnalyzeTrend(
    allocator: std.mem.Allocator,
    metrics: []const analysis.Metric,
    executed: analysis.TrendSetResult,
    goals: []const meta.Goal,
    current_buckets: []const analysis.OverviewBucket,
    comparison_buckets: []const analysis.OverviewBucket,
    incomplete_bucket: []const u8,
    highlight: []const u8,
    no_events_ever: bool,
) !model.AnalyzeTrend {
    var output: std.ArrayList(model.AnalyzeTrendSeries) = .empty;
    var any_rows = false;
    for (metrics, executed.series) |metric, result| {
        any_rows = any_rows or result.points.len != 0 or
            (result.comparison_points != null and
                result.comparison_points.?.len != 0);
        if (metric.kind == .revenue or metric.kind == .average_value) {
            const currencies = try trendCurrencies(allocator, result);
            if (currencies.len == 0) {
                if (output.items.len >= analysis.maximum_series) {
                    return error.TooManyAnalyzeTrendSeries;
                }
                try output.append(allocator, try buildAnalyzeSeries(
                    allocator,
                    metric,
                    result,
                    goals,
                    current_buckets,
                    comparison_buckets,
                    incomplete_bucket,
                    if (output.items.len == 0) highlight else "",
                    "",
                ));
            } else for (currencies) |currency| {
                if (output.items.len >= analysis.maximum_series) {
                    return error.TooManyAnalyzeTrendSeries;
                }
                try output.append(allocator, try buildAnalyzeSeries(
                    allocator,
                    metric,
                    result,
                    goals,
                    current_buckets,
                    comparison_buckets,
                    incomplete_bucket,
                    if (output.items.len == 0) highlight else "",
                    currency,
                ));
            }
        } else {
            if (output.items.len >= analysis.maximum_series) {
                return error.TooManyAnalyzeTrendSeries;
            }
            try output.append(allocator, try buildAnalyzeSeries(
                allocator,
                metric,
                result,
                goals,
                current_buckets,
                comparison_buckets,
                incomplete_bucket,
                if (output.items.len == 0) highlight else "",
                "",
            ));
        }
    }
    return .{
        .series = try output.toOwnedSlice(allocator),
        .no_events_ever = no_events_ever,
        .no_matches = !no_events_ever and !any_rows,
    };
}

fn currentAnalyzeBucketLabel(
    allocator: std.mem.Allocator,
    zone: timezone.Zone,
    now_utc_seconds: i64,
    interval: analysis.Interval,
) ![]const u8 {
    const local = try zone.localAt(now_utc_seconds);
    return switch (interval) {
        .hour => value: {
            const label = try zone.localHourLabel(now_utc_seconds);
            break :value try allocator.dupe(u8, &label);
        },
        .day => try allocator.dupe(u8, &local.date),
        .week => value: {
            var date = try timezone.Date.parse(&local.date);
            const days_since_monday = @mod(date.dayNumber() + 3, 7);
            date = try date.addDays(-days_since_monday);
            const label = try date.format();
            break :value try allocator.dupe(u8, &label);
        },
        .month => try allocator.dupe(u8, local.date[0..7]),
        .auto => error.InvalidOverviewInterval,
    };
}

fn buildAnalyzeSeries(
    allocator: std.mem.Allocator,
    metric: analysis.Metric,
    result: analysis.TrendResult,
    goals: []const meta.Goal,
    current_buckets: []const analysis.OverviewBucket,
    comparison_buckets: []const analysis.OverviewBucket,
    incomplete_bucket: []const u8,
    highlight: []const u8,
    currency: []const u8,
) !model.AnalyzeTrendSeries {
    const count = @max(current_buckets.len, comparison_buckets.len);
    const highlight_is_current = bucketContains(current_buckets, highlight);
    const points = try allocator.alloc(model.AnalyzeTrendPoint, count);
    for (points, 0..) |*point, index| {
        const current_label = if (index < current_buckets.len)
            current_buckets[index].label
        else
            "";
        const comparison_label = if (index < comparison_buckets.len)
            comparison_buckets[index].label
        else
            "";
        point.* = .{
            .current_label = current_label,
            .comparison_label = comparison_label,
            .current = if (current_label.len == 0)
                null
            else
                try denseTrendMeasure(
                    result.points,
                    current_label,
                    metric.kind,
                    currency,
                ),
            .comparison = if (comparison_label.len == 0 or
                result.comparison_points == null)
                null
            else
                try denseTrendMeasure(
                    result.comparison_points.?,
                    comparison_label,
                    metric.kind,
                    currency,
                ),
            .current_incomplete = current_label.len != 0 and
                std.mem.eql(u8, current_label, incomplete_bucket),
            .current_highlighted = current_label.len != 0 and
                std.mem.eql(u8, current_label, highlight),
            .comparison_highlighted = !highlight_is_current and
                comparison_label.len != 0 and
                std.mem.eql(u8, comparison_label, highlight),
        };
    }
    return .{
        .metric = metric,
        .title = try trendTitle(allocator, metric, goals, currency),
        .points = points,
        .current_total = try trendTotal(result.total, metric.kind, currency),
        .comparison_total = if (result.comparison_total) |totals|
            try trendTotal(totals, metric.kind, currency)
        else
            null,
        .current_coverage = try coverageText(allocator, result.completeness, "Current"),
        .comparison_coverage = if (result.comparison_completeness) |coverage|
            try coverageText(allocator, coverage, "Comparison")
        else
            null,
    };
}

fn trendCurrencies(
    allocator: std.mem.Allocator,
    result: analysis.TrendResult,
) ![]const []const u8 {
    var output: std.ArrayList([]const u8) = .empty;
    for (result.total) |measure| try appendMeasureCurrency(allocator, &output, measure);
    if (result.comparison_total) |totals| for (totals) |measure| {
        try appendMeasureCurrency(allocator, &output, measure);
    };
    for (result.points) |point| try appendMeasureCurrency(allocator, &output, point.measure);
    if (result.comparison_points) |points| for (points) |point| {
        try appendMeasureCurrency(allocator, &output, point.measure);
    };
    std.mem.sort([]const u8, output.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    return output.toOwnedSlice(allocator);
}

fn appendMeasureCurrency(
    allocator: std.mem.Allocator,
    currencies: *std.ArrayList([]const u8),
    measure: analysis.Measure,
) !void {
    const currency = switch (measure) {
        .amount => |amount| amount.currency,
        else => return error.InvalidAnalyzeTrendResult,
    };
    if (currency.len != 3) return error.InvalidAnalyzeTrendResult;
    for (currency) |byte| if (byte < 'A' or byte > 'Z') {
        return error.InvalidAnalyzeTrendResult;
    };
    for (currencies.items) |existing| {
        if (std.mem.eql(u8, existing, currency)) return;
    }
    try currencies.append(allocator, currency);
}

fn denseTrendMeasure(
    points: []const analysis.TrendPoint,
    label: []const u8,
    kind: analysis.MetricKind,
    currency: []const u8,
) !?analysis.Measure {
    for (points) |point| {
        if (!std.mem.eql(u8, point.bucket, label)) continue;
        switch (point.measure) {
            .amount => |amount| {
                if (std.mem.eql(u8, amount.currency, currency)) return point.measure;
            },
            else => {
                if (currency.len != 0) return error.InvalidAnalyzeTrendResult;
                return point.measure;
            },
        }
    }
    return switch (kind) {
        .engagement_rate, .bounce_rate, .conversion_rate => null,
        .revenue, .average_value => if (currency.len == 0)
            null
        else
            .{ .amount = .{
                .decimal = "0.000000",
                .currency = currency,
                .value_count = 0,
            } },
        else => .{ .count = 0 },
    };
}

fn trendTotal(
    totals: []const analysis.Measure,
    kind: analysis.MetricKind,
    currency: []const u8,
) !?analysis.Measure {
    for (totals) |measure| switch (measure) {
        .amount => |amount| {
            if (std.mem.eql(u8, amount.currency, currency)) return measure;
        },
        else => {
            if (currency.len != 0 or totals.len != 1) {
                return error.InvalidAnalyzeTrendResult;
            }
            return measure;
        },
    };
    return switch (kind) {
        .revenue, .average_value => if (currency.len == 0)
            null
        else
            .{ .amount = .{
                .decimal = "0.000000",
                .currency = currency,
                .value_count = 0,
            } },
        else => error.InvalidAnalyzeTrendResult,
    };
}

fn trendTitle(
    allocator: std.mem.Allocator,
    metric: analysis.Metric,
    goals: []const meta.Goal,
    currency: []const u8,
) ![]const u8 {
    const label = metricLabel(metric.kind);
    if (metric.selector) |selector| switch (selector.kind) {
        .exact_event => return if (currency.len == 0)
            std.fmt.allocPrint(allocator, "{s} · event {s}", .{ label, selector.value })
        else
            std.fmt.allocPrint(
                allocator,
                "{s} · event {s} · {s}",
                .{ label, selector.value, currency },
            ),
        .saved_goal => {
            const goal = goalById(goals, selector.value) orelse return error.GoalNotFound;
            return if (currency.len == 0)
                std.fmt.allocPrint(allocator, "{s} · goal {s}", .{ label, goal.name })
            else
                std.fmt.allocPrint(
                    allocator,
                    "{s} · goal {s} · {s}",
                    .{ label, goal.name, currency },
                );
        },
        else => return error.InvalidTrendSubject,
    };
    return if (currency.len == 0)
        allocator.dupe(u8, label)
    else
        std.fmt.allocPrint(allocator, "{s} · {s}", .{ label, currency });
}

fn metricLabel(kind: analysis.MetricKind) []const u8 {
    return switch (kind) {
        .visitors => "Visitors",
        .new_visitors => "New visitors",
        .returning_visitors => "Returning visitors",
        .sessions => "Sessions",
        .engaged_sessions => "Engaged sessions",
        .engagement_rate => "Engagement rate",
        .bounce_rate => "Bounce rate",
        .page_views => "Page views",
        .custom_events => "Custom events",
        .conversions => "Conversions",
        .conversion_rate => "Conversion rate",
        .revenue => "Revenue",
        .average_value => "Average value",
        .event_count => "Event count",
        .event_visitors => "Event visitors",
    };
}

fn bucketContains(
    buckets: []const analysis.OverviewBucket,
    label: []const u8,
) bool {
    for (buckets) |bucket| if (std.mem.eql(u8, bucket.label, label)) return true;
    return false;
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
        .{ .kind = .visitors },
    ));
    try cards.append(allocator, try countKpi(
        allocator,
        "Sessions",
        overview.sessions,
        unavailable,
        "Distinct sessions with meaningful activity in this site-local range.",
        .analyze,
        .{ .kind = .sessions },
    ));
    try cards.append(allocator, try countKpi(
        allocator,
        "Page views",
        overview.page_views,
        unavailable,
        "Accepted page-view events in this site-local range.",
        .analyze,
        .{ .kind = .page_views },
    ));
    try cards.append(allocator, try ratioKpiModel(
        allocator,
        "Engagement rate",
        overview.engagement_rate,
        unavailable,
        "Sessions with 10 seconds of active engagement, two page views, or an active-goal match, divided by sessions.",
        .analyze,
        .{ .kind = .engagement_rate },
    ));
    try cards.append(allocator, try countKpi(
        allocator,
        "Conversions",
        overview.conversions,
        unavailable,
        "Matches across all active goals; one event can match more than one distinct goal.",
        .goals,
        null,
    ));
    try cards.append(allocator, try ratioKpiModel(
        allocator,
        "Conversion rate",
        overview.conversion_rate,
        unavailable,
        "Distinct visitors with any active-goal match divided by all visitors in the same range.",
        .goals,
        null,
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
            .legacy_focus_currency = revenue.currency,
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
    analysis_metric: ?analysis.Metric,
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
        .analysis_metric = analysis_metric,
    };
}

fn ratioKpiModel(
    allocator: std.mem.Allocator,
    label: []const u8,
    ratio: analysis.ComparedRatio,
    unavailable: []const u8,
    definition: []const u8,
    target: model.KpiTarget,
    analysis_metric: ?analysis.Metric,
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
        .analysis_metric = analysis_metric,
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
    if (query.analysis_series.len != 0) {
        domain.validateUuid(query.analysis_site_id) catch
            return error.InvalidAnalysisSite;
        if (query.kind != .overview or query.subject.len != 0 or
            query.campaign_dimension != .all or query.sort != .count or
            query.limit != report.default_limit or query.page != 1 or
            query.overview_metric != .visitors or
            query.overview_currency.len != 0 or
            query.analysis_series.len > analysis.maximum_series)
        {
            return error.AnalysisOptionsNotApplicable;
        }
        for (query.analysis_series, 0..) |metric, index| {
            try analysis.validateTrendSeries(metric);
            for (query.analysis_series[0..index]) |prior| {
                if (analysis.metricsEqual(metric, prior)) {
                    return error.DuplicateTrendSeries;
                }
            }
        }
        if (query.highlighted_interval.len != 0 and
            !validOverviewHighlight(query.highlighted_interval))
        {
            return error.InvalidOverviewHighlight;
        }
        return;
    }
    if (query.analysis_interval != .auto) {
        return error.AnalysisOptionsNotApplicable;
    }
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

test "Analyze Trend canonical and builder query shapes remain closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const site_id = "00000000-0000-4000-8000-000000000028";
    const default_range = calendar.Range{
        .start = "2025-01-01".*,
        .end = "2025-01-30".*,
    };
    const goal_id = "00000000-0000-4000-8000-000000000029";
    const canonical = try parseTrendQuery(
        allocator,
        "/admin/sites/example/analyze?v=1&from=2025-01-01&to=2025-01-02&compare=previous&mode=trend&interval=day&series=visitors&series=event-count~event~signup&series=conversions~visitor~goal~" ++ goal_id,
    );
    const query = try finishTrendQuery(
        canonical,
        "example",
        site_id,
        &default_range,
        .previous,
    );
    try std.testing.expectEqual(@as(usize, 3), query.analysis_series.len);
    try std.testing.expectEqual(analysis.Interval.day, query.analysis_interval);
    try std.testing.expectEqual(analysis.MetricKind.event_count, query.analysis_series[1].kind);
    try std.testing.expectEqualStrings("signup", query.analysis_series[1].selector.?.value);

    const builder = try parseTrendQuery(
        allocator,
        "/admin/sites/example/analyze?from=2025-01-01&to=2025-01-02&compare=none&interval=week&metric-1=event-visitors&event-1=signup&metric-2=average-value&goal-2=" ++ goal_id,
    );
    try std.testing.expectEqual(@as(usize, 2), builder.series.len);
    try std.testing.expectEqual(analysis.MetricKind.event_visitors, builder.series[0].kind);
    try std.testing.expectEqual(analysis.MetricKind.average_value, builder.series[1].kind);

    try std.testing.expectError(
        error.MixedTrendQueryShape,
        parseTrendQuery(
            allocator,
            "/admin/sites/example/analyze?v=1&from=2025-01-01&to=2025-01-02&compare=none&mode=trend&interval=day&series=visitors&metric-1=sessions",
        ),
    );
    try std.testing.expectError(
        error.UnknownQueryField,
        parseTrendQuery(allocator, "/admin/sites/example/analyze?metric-1=visitors&filter=hidden"),
    );
    try std.testing.expectError(
        error.InvalidTrendSeriesCount,
        parseTrendQuery(
            allocator,
            "/admin/sites/example/analyze?v=1&from=2025-01-01&to=2025-01-02&compare=none&mode=trend&interval=day&series=visitors&series=sessions&series=page-views&series=custom-events",
        ),
    );
    try std.testing.expectError(
        error.InvalidOverviewHighlight,
        parseTrendQuery(
            allocator,
            "/admin/sites/example/analyze?v=1&from=2025-01-01&to=2025-01-02&compare=none&mode=trend&interval=day&series=visitors&highlight=",
        ),
    );
    try std.testing.expectError(
        error.DuplicateQueryField,
        parseTrendQuery(
            allocator,
            "/admin/sites/example/analyze?v=1&from=2025-01-01&to=2025-01-02&compare=none&mode=trend&interval=day&series=visitors&highlight=2025-01-01&highlight=2025-01-02",
        ),
    );
    try std.testing.expectError(
        error.InvalidOverviewHighlight,
        parseTrendQuery(
            allocator,
            "/admin/sites/example/analyze?v=1&from=2025-01-01&to=2025-01-02&compare=none&mode=trend&interval=day&series=visitors&highlight=&highlight=2025-01-01",
        ),
    );

    const legacy = try parseQuery(
        allocator,
        "/admin/sites/example/analyze?from=2025-01-01&to=2025-01-02&compare=previous&report=pages&sort=count&limit=25&page=1&focus=sessions&highlight=2025-01-01",
        .pages,
    );
    const translated = (try translateOverviewTrendHandoff(allocator, legacy)).?;
    try std.testing.expectEqual(analysis.MetricKind.sessions, translated.series[0].kind);
    var conversion = legacy;
    conversion.overview_metric = .conversions;
    try std.testing.expect((try translateOverviewTrendHandoff(allocator, conversion)) == null);
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

test "Analyze amount rows split by exact currency before the visual cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metrics = [_]analysis.Metric{.{ .kind = .revenue }};
    const totals = [_]analysis.Measure{
        .{ .amount = .{ .decimal = "1.000000", .currency = "AUD", .value_count = 1 } },
        .{ .amount = .{ .decimal = "1.000000", .currency = "EUR", .value_count = 1 } },
        .{ .amount = .{ .decimal = "1.000000", .currency = "GBP", .value_count = 1 } },
        .{ .amount = .{ .decimal = "1.000000", .currency = "USD", .value_count = 1 } },
    };
    const results = [_]analysis.TrendResult{.{
        .points = &.{},
        .comparison_points = null,
        .comparison_total = null,
        .comparison_completeness = null,
        .total = &totals,
        .interval = .day,
        .completeness = .{
            .total_people = 0,
            .persistent_people = 0,
            .ephemeral_people = 0,
            .legacy_people = 0,
            .persistent_basis_points = 0,
            .persistent_since_local_date = null,
        },
    }};
    const buckets = [_]analysis.OverviewBucket{.{ .label = "2025-01-01" }};
    try std.testing.expectError(
        error.TooManyAnalyzeTrendSeries,
        buildAnalyzeTrend(
            allocator,
            &metrics,
            .{ .series = &results },
            &.{},
            &buckets,
            &.{},
            "",
            "",
            false,
        ),
    );
}

test "Analyze known comparison currency gives an exact zero current total" {
    const comparison_totals = [_]analysis.Measure{.{ .amount = .{
        .decimal = "2.000000",
        .currency = "EUR",
        .value_count = 2,
    } }};
    const current = (try trendTotal(&.{}, .revenue, "EUR")).?.amount;
    try std.testing.expectEqualStrings("0.000000", current.decimal);
    try std.testing.expectEqualStrings("EUR", current.currency);
    try std.testing.expectEqual(@as(i64, 0), current.value_count);
    const comparison = (try trendTotal(
        &comparison_totals,
        .average_value,
        "EUR",
    )).?.amount;
    try std.testing.expectEqualStrings("2.000000", comparison.decimal);
    try std.testing.expectEqual(@as(i64, 2), comparison.value_count);
    try std.testing.expect((try trendTotal(&.{}, .revenue, "")) == null);
}

test "Analyze highlight gives an overlapping label current precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const current = [_]analysis.TrendPoint{.{
        .bucket = "2025-01-01",
        .measure = .{ .count = 1 },
    }};
    const comparison = [_]analysis.TrendPoint{.{
        .bucket = "2025-01-01",
        .measure = .{ .count = 2 },
    }};
    const totals = [_]analysis.Measure{.{ .count = 1 }};
    const comparison_totals = [_]analysis.Measure{.{ .count = 2 }};
    const coverage = analysis.Completeness{
        .total_people = 0,
        .persistent_people = 0,
        .ephemeral_people = 0,
        .legacy_people = 0,
        .persistent_basis_points = 0,
        .persistent_since_local_date = null,
    };
    const buckets = [_]analysis.OverviewBucket{.{ .label = "2025-01-01" }};
    const series = try buildAnalyzeSeries(
        arena.allocator(),
        .{ .kind = .page_views },
        .{
            .points = &current,
            .comparison_points = &comparison,
            .comparison_total = &comparison_totals,
            .comparison_completeness = coverage,
            .total = &totals,
            .interval = .day,
            .completeness = coverage,
        },
        &.{},
        &buckets,
        &buckets,
        "",
        "2025-01-01",
        "",
    );
    try std.testing.expect(series.points[0].current_highlighted);
    try std.testing.expect(!series.points[0].comparison_highlighted);
}

test "Analyze marks the real current interval rather than a future final bucket" {
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

    const now_utc_seconds: i64 = 1_735_776_000; // 2025-01-02T00:00:00Z
    try std.testing.expectEqualStrings(
        "2025-01-02T00:00",
        try currentAnalyzeBucketLabel(allocator, utc, now_utc_seconds, .hour),
    );
    try std.testing.expectEqualStrings(
        "2025-01-02",
        try currentAnalyzeBucketLabel(allocator, utc, now_utc_seconds, .day),
    );
    try std.testing.expectEqualStrings(
        "2024-12-30",
        try currentAnalyzeBucketLabel(allocator, utc, now_utc_seconds, .week),
    );
    try std.testing.expectEqualStrings(
        "2025-01",
        try currentAnalyzeBucketLabel(allocator, utc, now_utc_seconds, .month),
    );

    const coverage = analysis.Completeness{
        .total_people = 0,
        .persistent_people = 0,
        .ephemeral_people = 0,
        .legacy_people = 0,
        .persistent_basis_points = 0,
        .persistent_since_local_date = null,
    };
    const totals = [_]analysis.Measure{.{ .count = 0 }};
    const cases = [_]struct {
        interval: analysis.Interval,
        current: []const u8,
        future: []const u8,
    }{
        .{ .interval = .day, .current = "2025-01-02", .future = "2025-01-03" },
        .{ .interval = .week, .current = "2024-12-30", .future = "2025-01-06" },
        .{ .interval = .month, .current = "2025-01", .future = "2025-02" },
    };
    for (cases) |case| {
        const buckets = [_]analysis.OverviewBucket{
            .{ .label = case.current },
            .{ .label = case.future },
        };
        const series = try buildAnalyzeSeries(
            allocator,
            .{ .kind = .page_views },
            .{
                .points = &.{},
                .comparison_points = null,
                .comparison_total = null,
                .comparison_completeness = null,
                .total = &totals,
                .interval = case.interval,
                .completeness = coverage,
            },
            &.{},
            &buckets,
            &.{},
            try currentAnalyzeBucketLabel(
                allocator,
                utc,
                now_utc_seconds,
                case.interval,
            ),
            "",
            "",
        );
        try std.testing.expect(series.points[0].current_incomplete);
        try std.testing.expect(!series.points[1].current_incomplete);
    }
}

test "Overview accepted-event receipt formatting preserves the Unix epoch" {
    const value = try formatUtcMicros(std.testing.allocator, 0);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings(
        "1970-01-01 00:00 UTC",
        value,
    );
}
