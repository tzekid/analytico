const std = @import("std");
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
};

pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

pub const DateRange = struct {
    start: []const u8,
    end: []const u8,
};

pub fn formDateRange(form: Form) !DateRange {
    const start = try form.required("start");
    const end = try form.required("end");
    try domain.validateDate(start);
    try domain.validateDate(end);
    const start_day = try report.dateDay(start);
    const end_day = try report.dateDay(end);
    if (end_day < start_day or end_day - start_day + 1 > report.maximum_range_days) {
        return error.InvalidReportRange;
    }
    return .{ .start = start, .end = end };
}

pub fn parseQuery(
    allocator: std.mem.Allocator,
    target: []const u8,
    default_start: []const u8,
    default_end: []const u8,
) !model.Query {
    var query = model.Query{
        .start_date = default_start,
        .end_date = default_end,
    };
    const marker = std.mem.findScalar(u8, target, '?') orelse return query;
    const encoded = target[marker + 1 ..];
    if (encoded.len > 4096) return error.QueryTooLarge;
    var seen: std.ArrayList([]const u8) = .empty;
    var pairs = std.mem.splitScalar(u8, encoded, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        if (seen.items.len >= 12) return error.TooManyQueryFields;
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
        } else if (std.mem.eql(u8, name, "start")) {
            query.start_date = value;
        } else if (std.mem.eql(u8, name, "end")) {
            query.end_date = value;
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
        } else if (!std.mem.eql(u8, name, "notice")) {
            return error.UnknownQueryField;
        }
    }
    return query;
}

pub fn loadPage(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    event_store: *events.Store,
    query_input: model.Query,
    csrf_token: []const u8,
    notice: []const u8,
    report_timeout_ms: u32,
) !model.Page {
    var query = query_input;
    const sites = try metadata.listSites(allocator);
    if (sites.len == 0) {
        return .{
            .sites = sites,
            .selected_site = null,
            .query = query,
            .result = null,
            .goals = &.{},
            .funnels = &.{},
            .csrf_token = csrf_token,
            .notice = notice,
        };
    }
    const selected = if (query.site.len == 0)
        firstActive(sites) orelse sites[0]
    else
        findSite(sites, query.site) orelse return error.SiteNotFound;
    query.site = selected.slug;
    try validateQuery(query);

    const goals = try metadata.listGoals(allocator, selected.slug);
    const funnels = try metadata.listFunnels(allocator, selected.slug);
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
        .start_date = query.start_date,
        .end_date = query.end_date,
        .start_day = try report.dateDay(query.start_date),
        .end_day = try report.dateDay(query.end_date),
        .kind = query.kind,
        .subject = query.subject,
        .campaign_dimension = query.campaign_dimension,
        .sort = query.sort,
        .limit = query.limit,
        .page = query.page,
    };
    const result: ?report.Result = if (has_subject)
        try reports.runWithTimeout(
            allocator,
            event_store,
            request,
            selected.id,
            selected_goal,
            selected_steps,
            report_timeout_ms,
        )
    else
        null;
    var quality_request = request;
    quality_request.kind = .traffic_quality;
    quality_request.limit = report.maximum_limit;
    quality_request.page = 1;
    const overview_quality: ?report.TrafficQuality = if (query.kind == .overview)
        try reports.trafficQuality(
            allocator,
            event_store,
            quality_request,
            selected.id,
            report_timeout_ms,
        )
    else
        null;
    return .{
        .sites = sites,
        .selected_site = selected,
        .query = query,
        .result = result,
        .overview_quality = overview_quality,
        .goals = goals,
        .funnels = funnels,
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

pub fn verifyCsrf(form: Form, expected: []const u8) !void {
    const actual = try form.required("csrf");
    if (actual.len < 32 or actual.len > 128 or actual.len != expected.len) {
        return error.InvalidCsrfToken;
    }
    var difference: u8 = 0;
    for (actual, expected) |left, right| difference |= left ^ right;
    if (difference != 0) return error.InvalidCsrfToken;
}

fn validateQuery(query: model.Query) !void {
    try domain.validateSlug(query.site);
    try domain.validateDate(query.start_date);
    try domain.validateDate(query.end_date);
    const start_day = try report.dateDay(query.start_date);
    const end_day = try report.dateDay(query.end_date);
    if (end_day < start_day or end_day - start_day + 1 > report.maximum_range_days) {
        return error.InvalidReportRange;
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
