const std = @import("std");
const analysis = @import("../analysis.zig");
const calendar = @import("../calendar.zig");
const diagnostics = @import("../diagnostics.zig");
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
        return parseBounded(allocator, body, 8 * 1024, 24);
    }

    pub fn parseSavedState(
        allocator: std.mem.Allocator,
        body: []const u8,
    ) !Form {
        return parseBounded(allocator, body, 64 * 1024, 32);
    }

    fn parseBounded(
        allocator: std.mem.Allocator,
        body: []const u8,
        maximum_bytes: usize,
        maximum_fields: usize,
    ) !Form {
        if (body.len > maximum_bytes) return error.FormTooLarge;
        var fields: std.ArrayList(Field) = .empty;
        var pairs = std.mem.splitScalar(u8, body, '&');
        while (pairs.next()) |pair| {
            if (fields.items.len >= maximum_fields) return error.TooManyFormFields;
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

pub const InstallQuery = struct {
    started_at_utc_micros: i64,
    event_count: i64,
    after_received_at_utc_micros: i64,
    after_event_id: []const u8,
    signature: []const u8,
    fragment: bool,
};

pub fn parseInstallQuery(
    allocator: std.mem.Allocator,
    target: []const u8,
) !?InstallQuery {
    const marker = std.mem.findScalar(u8, target, '?') orelse return null;
    const encoded = target[marker + 1 ..];
    if (encoded.len == 0 or encoded.len > analysis.maximum_url_bytes) {
        return error.InvalidInstallQuery;
    }
    var started: ?[]const u8 = null;
    var event_count: ?[]const u8 = null;
    var after: ?[]const u8 = null;
    var event: ?[]const u8 = null;
    var signature: ?[]const u8 = null;
    var fragment = false;
    var count: usize = 0;
    var parameters = std.mem.splitScalar(u8, encoded, '&');
    while (parameters.next()) |parameter| {
        if (parameter.len == 0) return error.InvalidInstallQuery;
        count += 1;
        if (count > 6) return error.TooManyInstallQueryFields;
        const raw_name, const raw_value = std.mem.cutScalar(u8, parameter, '=') orelse
            return error.InvalidInstallQuery;
        const name = try decodeComponent(allocator, raw_name);
        const value = try decodeComponent(allocator, raw_value);
        if (value.len == 0) return error.InvalidInstallQuery;
        if (std.mem.eql(u8, name, "started")) {
            if (started != null) return error.DuplicateInstallQueryField;
            started = value;
        } else if (std.mem.eql(u8, name, "count")) {
            if (event_count != null) return error.DuplicateInstallQueryField;
            event_count = value;
        } else if (std.mem.eql(u8, name, "after")) {
            if (after != null) return error.DuplicateInstallQueryField;
            after = value;
        } else if (std.mem.eql(u8, name, "event")) {
            if (event != null) return error.DuplicateInstallQueryField;
            event = value;
        } else if (std.mem.eql(u8, name, "sig")) {
            if (signature != null) return error.DuplicateInstallQueryField;
            signature = value;
        } else if (std.mem.eql(u8, name, "fragment")) {
            if (fragment) return error.DuplicateInstallQueryField;
            if (!std.mem.eql(u8, value, "verification")) {
                return error.InvalidInstallFragment;
            }
            fragment = true;
        } else {
            return error.UnknownInstallQueryField;
        }
    }
    if (started == null or event_count == null or after == null or event == null or
        signature == null)
    {
        return error.IncompleteInstallQuery;
    }
    const started_at_utc_micros = std.fmt.parseInt(i64, started.?, 10) catch
        return error.InvalidInstallTimestamp;
    const parsed_event_count = std.fmt.parseInt(i64, event_count.?, 10) catch
        return error.InvalidInstallEventCount;
    const after_received_at_utc_micros = std.fmt.parseInt(i64, after.?, 10) catch
        return error.InvalidInstallTimestamp;
    if (started_at_utc_micros <= 0 or parsed_event_count < 0 or
        after_received_at_utc_micros < 0)
    {
        return error.InvalidInstallTimestamp;
    }
    try domain.validateUuid(event.?);
    if (signature.?.len != 64) return error.InvalidInstallSignature;
    for (signature.?) |byte| {
        if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) {
            return error.InvalidInstallSignature;
        }
    }
    return .{
        .started_at_utc_micros = started_at_utc_micros,
        .event_count = parsed_event_count,
        .after_received_at_utc_micros = after_received_at_utc_micros,
        .after_event_id = event.?,
        .signature = signature.?,
        .fragment = fragment,
    };
}

pub fn signInstallWatermark(
    site_id: []const u8,
    csrf_token: []const u8,
    started_at_utc_micros: i64,
    event_count: i64,
    after_received_at_utc_micros: i64,
    after_event_id: []const u8,
) ![64]u8 {
    try domain.validateUuid(site_id);
    try domain.validateUuid(after_event_id);
    if (csrf_token.len == 0 or started_at_utc_micros <= 0 or event_count < 0 or
        after_received_at_utc_micros < 0)
    {
        return error.InvalidInstallWatermark;
    }
    var message_buffer: [192]u8 = undefined;
    const message = try std.fmt.bufPrint(
        &message_buffer,
        "analytico-install-v1\n{s}\n{d}\n{d}\n{d}\n{s}",
        .{
            site_id,
            started_at_utc_micros,
            event_count,
            after_received_at_utc_micros,
            after_event_id,
        },
    );
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    var digest: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&digest, message, csrf_token);
    defer std.crypto.secureZero(u8, &digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn verifyInstallWatermark(
    query: InstallQuery,
    site_id: []const u8,
    csrf_token: []const u8,
) !void {
    const expected = try signInstallWatermark(
        site_id,
        csrf_token,
        query.started_at_utc_micros,
        query.event_count,
        query.after_received_at_utc_micros,
        query.after_event_id,
    );
    var actual: [64]u8 = undefined;
    if (query.signature.len != actual.len) return error.InvalidInstallSignature;
    @memcpy(&actual, query.signature);
    if (!std.crypto.timing_safe.eql([64]u8, expected, actual)) {
        return error.InvalidInstallSignature;
    }
}

pub fn installEvent(
    allocator: std.mem.Allocator,
    source: events.InstallationEvent,
) !model.InstallEvent {
    if (source.protocol_version != 1 and source.protocol_version != 2) {
        return error.InvalidInstallationEvent;
    }
    const event_type: []const u8 = switch (source.kind) {
        1 => "Page view",
        2 => "Custom event",
        3 => "Engagement",
        4 => "Identify",
        else => return error.InvalidInstallationEvent,
    };
    return .{
        .protocol_version = @intCast(source.protocol_version),
        .event_type = event_type,
        .event_name = source.event_name,
        .path = source.path,
        .received_at_utc = try formatUtcMicros(
            allocator,
            source.received_at_utc_micros,
        ),
    };
}

pub fn installGuidance(
    summary: diagnostics.Summary,
) ?model.InstallGuidance {
    if (summary.outcome == .accepted) return null;
    if (summary.outcome == .duplicate) return .{
        .category = "Duplicate event",
        .consequence = "The collector recognized an event already stored, so no new row confirmed this verification session.",
        .correction = "Reload the tracked page or send a new event with a fresh event ID.",
    };
    if (summary.outcome == .store_failure) return .{
        .category = "Collector storage unavailable",
        .consequence = "The attempt reached this site but could not be committed.",
        .correction = "Restore event-store readiness, then reload the tracked page and check again.",
    };
    return switch (summary.rejection_code) {
        .origin_missing, .origin_not_allowed => .{
            .category = "Origin not allowed",
            .consequence = "The collector rejected the request before storing an event.",
            .correction = "Match the tracked page's exact scheme, host, and port to one configured origin.",
        },
        .site_unknown, .site_disabled => .{
            .category = "Site unavailable",
            .consequence = "The collector did not accept the supplied site configuration.",
            .correction = "Copy the exact Site ID from this page and confirm the site is enabled.",
        },
        .protocol_unsupported => .{
            .category = "Unsupported protocol",
            .consequence = "The request format cannot be accepted by this collector route.",
            .correction = "Use the generated content-hashed tracker and do not compress its event request.",
        },
        .payload_too_large, .payload_invalid, .event_invalid => .{
            .category = "Invalid payload",
            .consequence = "The collector rejected malformed, oversized, or unsupported event data.",
            .correction = "Use the generated tracker or the bounded v2 examples and remove unknown or oversized fields.",
        },
        .property_invalid, .property_type_conflict => .{
            .category = "Invalid properties",
            .consequence = "The event was not stored because its properties exceeded the flat typed contract.",
            .correction = "Send at most 16 scalar properties with valid keys and bounded string values.",
        },
        .identity_invalid, .identity_conflict, .session_invalid => .{
            .category = "Invalid identity or session",
            .consequence = "The v2 identity/session envelope was rejected and no event was committed.",
            .correction = "Use the generated tracker; call reset before switching a browser to another identified user.",
        },
        .timestamp_invalid => .{
            .category = "Invalid event time",
            .consequence = "The event time fell outside the collector's accepted receipt window.",
            .correction = "Correct the tracked device clock and send a new event.",
        },
        .value_invalid => .{
            .category = "Invalid value",
            .consequence = "The exact amount/currency pair was rejected and no event was stored.",
            .correction = "Send a bounded decimal-string amount together with a three-letter uppercase currency.",
        },
        .event_id_conflict => .{
            .category = "Event ID conflict",
            .consequence = "An existing event ID was reused with different normalized data.",
            .correction = "Send the event once with a fresh UUID; do not reuse IDs across different events.",
        },
        .rate_limited => .{
            .category = "Collection limit reached",
            .consequence = "The collector refused this attempt without storing a new event.",
            .correction = "Wait briefly or review the site's configured daily accepted-event ceiling.",
        },
        .store_unavailable, .disk_full => .{
            .category = "Collector storage unavailable",
            .consequence = "The collector could not durably commit the event.",
            .correction = "Restore readiness and disk capacity, then send a new event.",
        },
        .none => null,
    };
}

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

test "Breakdown builder and legacy lists produce one typed query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = try parseBreakdownBuilder(
        allocator,
        "/admin/sites/example/analyze?builder=1&mode=breakdown&from=2026-01-01&to=2026-01-02&metric=event-count&event=signup&goal=&dimension=event-property&property=plan&property-type=string&search=Pro+plan&sort=label-asc&limit=50&p=plan%7Eis%7Estring%7EPro&segment=00000000-0000-4000-8000-000000000030&f=event%7Epage%7Eis%7Estring%7E%252Fpricing",
    );
    const built = try finishBreakdownBuilder(
        parsed,
        "example",
        "00000000-0000-4000-8000-000000000024",
    );
    try std.testing.expectEqualStrings(
        "Pro plan",
        built.analysis_breakdown.?.search,
    );
    try std.testing.expectEqual(
        analysis.DimensionKind.event_property,
        built.analysis_breakdown.?.dimension.?.kind,
    );
    try std.testing.expectEqual(
        analysis.Sort.label_asc,
        built.analysis_breakdown.?.sort,
    );
    try std.testing.expectEqual(@as(u16, 50), built.analysis_breakdown.?.limit);
    try std.testing.expectEqual(
        @as(usize, 1),
        built.analysis_breakdown.?.metric.selector.?.predicates.len,
    );
    try std.testing.expectEqualStrings(
        "plan",
        built.analysis_breakdown.?.metric.selector.?.predicates[0].property_ref.name,
    );
    try std.testing.expectEqualStrings(
        "00000000-0000-4000-8000-000000000030",
        built.analysis_breakdown.?.segment_id.?,
    );
    try std.testing.expectEqualStrings(
        "/pricing",
        built.analysis_breakdown.?.filters.clauses[0].values[0],
    );
    const standard = try finishBreakdownBuilder(
        try parseBreakdownBuilder(
            allocator,
            "/admin/sites/example/analyze?builder=1&mode=breakdown&from=2026-01-01&to=2026-01-02&metric=sessions&event=&goal=&dimension=device&property=&property-type=string&search=&sort=value-desc&limit=25",
        ),
        "example",
        "00000000-0000-4000-8000-000000000024",
    );
    try std.testing.expectEqual(
        analysis.DimensionKind.device,
        standard.analysis_breakdown.?.dimension.?.kind,
    );
    try std.testing.expectError(
        error.InvalidAnalysisScalarType,
        finishBreakdownBuilder(
            try parseBreakdownBuilder(
                allocator,
                "/admin/sites/example/analyze?builder=1&mode=breakdown&from=2026-01-01&to=2026-01-02&metric=sessions&event=&goal=&dimension=device&property=&property-type=wat&search=&sort=value-desc&limit=25",
            ),
            "example",
            "00000000-0000-4000-8000-000000000024",
        ),
    );
    try std.testing.expectError(
        error.InvalidAnalysisPercentEncoding,
        parseBreakdownBuilder(
            allocator,
            "/admin/sites/example/analyze?builder=1&mode=breakdown&from=2026-01-01&to=2026-01-02&metric=event-count&event=signup&goal=&dimension=event-property&property=plan&property-type=string&search=&sort=value-desc&limit=25&p=plan%7eis%7estring%7ePro",
        ),
    );

    const translated = try translateLegacyBreakdown(.{
        .site = "example",
        .range = .{ .start = "2026-01-01", .end = "2026-01-02" },
        .comparison = .previous,
        .kind = .campaigns,
        .campaign_dimension = .all,
        .sort = .label,
        .limit = 10,
        .page = 3,
    }, "00000000-0000-4000-8000-000000000024");
    try std.testing.expectEqual(
        analysis.DimensionKind.utm_campaign,
        translated.analysis_breakdown.?.dimension.?.kind,
    );
    try std.testing.expectEqual(analysis.Comparison.none, translated.comparison);
    try std.testing.expectEqual(analysis.Sort.label_asc, translated.analysis_breakdown.?.sort);
    try std.testing.expectEqual(@as(u32, 3), translated.analysis_breakdown.?.page);

    var filtered = built.analysis_breakdown.?;
    const filter_values = [_][]const u8{"signup"};
    const filters = [_]analysis.Clause{.{
        .scope = .event,
        .field = .{ .kind = .event_name },
        .operator = .is,
        .scalar_type = .string,
        .values = &filter_values,
    }};
    filtered.filters = .{ .clauses = &filters };
    const filtered_query = try finishBreakdownQuery(filtered, "example");
    try std.testing.expect(analysis.filterSetsEqual(
        filtered_query.analysis_filters,
        filtered.filters,
    ));

    var segmented = filtered;
    segmented.segment_id = "00000000-0000-4000-8000-000000000030";
    const segmented_query = try finishBreakdownQuery(segmented, "example");
    try std.testing.expectEqualStrings(
        segmented.segment_id.?,
        segmented_query.analysis_segment_id.?,
    );
    var inconsistent = segmented_query;
    inconsistent.analysis_filters = .{};
    try std.testing.expectError(
        error.AnalysisOptionsNotApplicable,
        validateQuery(inconsistent),
    );

    var page_selector = built.analysis_breakdown.?;
    page_selector.metric = .{
        .kind = .revenue,
        .selector = .{ .kind = .exact_page, .value = "/pricing" },
    };
    try std.testing.expectError(
        error.InvalidBreakdownMetric,
        finishBreakdownQuery(page_selector, "example"),
    );

    var session_conversion = built.analysis_breakdown.?;
    session_conversion.metric = .{
        .kind = .conversion_rate,
        .selector = .{
            .kind = .saved_goal,
            .value = "00000000-0000-4000-8000-000000000030",
        },
        .conversion_basis = .session,
    };
    try std.testing.expectError(
        error.InvalidBreakdownMetric,
        finishBreakdownQuery(session_conversion, "example"),
    );
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
    filters: analysis.FilterSet = .{},
    segment_id: ?[]const u8 = null,
    goal_page: u32 = 1,
    goal_entity_kind: analysis.GoalEntityKind = .page,
    goal_search: []const u8 = "",
    goal_entity_page: u32 = 1,
    goal_fields_set: bool = false,
    goal_entity_set: bool = false,
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
    var filters: std.ArrayList(analysis.Clause) = .empty;
    var pairs = std.mem.splitScalar(u8, encoded, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        const raw_name, const raw_value = std.mem.cutScalar(u8, pair, '=') orelse
            return error.InvalidQuery;
        if (std.mem.eql(u8, raw_name, "f")) {
            if (filters.items.len >= analysis.maximum_clauses) {
                return error.TooManyAnalysisClauses;
            }
            try filters.append(
                allocator,
                try analysis.parseFormClause(allocator, raw_value),
            );
            continue;
        }
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
        } else if (std.mem.eql(u8, name, "v")) {
            if (!std.mem.eql(u8, value, "1")) {
                return error.UnsupportedAnalysisQueryVersion;
            }
        } else if (std.mem.eql(u8, name, "segment")) {
            try domain.validateUuid(value);
            query.segment_id = value;
        } else if (std.mem.eql(u8, name, "goal-page")) {
            query.goal_fields_set = true;
            query.goal_page = std.fmt.parseInt(u32, value, 10) catch
                return error.InvalidGoalPage;
            if (query.goal_page == 0 or query.goal_page > 1_000_000) {
                return error.InvalidGoalPage;
            }
        } else if (std.mem.eql(u8, name, "entity")) {
            query.goal_fields_set = true;
            query.goal_entity_set = true;
            query.goal_entity_kind = if (std.mem.eql(u8, value, "page"))
                .page
            else if (std.mem.eql(u8, value, "event"))
                .event
            else
                return error.InvalidGoalEntityKind;
        } else if (std.mem.eql(u8, name, "search")) {
            query.goal_fields_set = true;
            try validateGoalSearch(value);
            query.goal_search = value;
        } else if (std.mem.eql(u8, name, "entity-page")) {
            query.goal_fields_set = true;
            query.goal_entity_page = std.fmt.parseInt(u32, value, 10) catch
                return error.InvalidGoalDiscoveryPage;
            if (query.goal_entity_page == 0 or
                query.goal_entity_page > 1_000_000)
            {
                return error.InvalidGoalDiscoveryPage;
            }
        } else {
            return error.UnknownQueryField;
        }
    }
    query.filters = .{ .clauses = try filters.toOwnedSlice(allocator) };
    try query.filters.validate();
    return query;
}

fn validateGoalSearch(value: []const u8) !void {
    if (value.len > analysis.maximum_search_bytes or
        !std.unicode.utf8ValidateSlice(value))
    {
        return error.InvalidGoalSearch;
    }
    for (value, 0..) |byte, index| {
        if (byte < 0x20 or byte == 0x7f) return error.InvalidGoalSearch;
        if (byte == 0xc2 and index + 1 < value.len and
            value[index + 1] >= 0x80 and value[index + 1] <= 0x9f)
        {
            return error.InvalidGoalSearch;
        }
    }
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
        .analysis_filters = parsed.filters,
        .analysis_segment_id = parsed.segment_id,
        .goal_page = parsed.goal_page,
        .goal_entity_kind = parsed.goal_entity_kind,
        .goal_search = parsed.goal_search,
        .goal_entity_page = parsed.goal_entity_page,
        .goal_entity_set = parsed.goal_entity_set,
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
        .filters = parsed.filters,
        .segment_id = parsed.segment_id,
    };
}

pub const ParsedTrendQuery = struct {
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    comparison: ?analysis.Comparison = null,
    interval: analysis.Interval = .auto,
    series: []const analysis.Metric = &.{},
    highlighted_interval: []const u8 = "",
    filters: analysis.FilterSet = .{},
    segment_id: ?[]const u8 = null,
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
    var filters: std.ArrayList(analysis.Clause) = .empty;
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
        if (std.mem.eql(u8, raw_name, "f")) {
            if (filters.items.len >= analysis.maximum_clauses) {
                return error.TooManyAnalysisClauses;
            }
            try filters.append(
                allocator,
                try analysis.parseFormClause(allocator, raw_value),
            );
            continue;
        }
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
        } else if (std.mem.eql(u8, name, "segment")) {
            try setParsedOnce(&parsed.segment_id, value);
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
    parsed.filters = .{ .clauses = try filters.toOwnedSlice(allocator) };
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
            try browserMetric(metric_name, event_name, goal_id),
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
        .analysis_filters = parsed.filters,
        .analysis_segment_id = parsed.segment_id,
    };
    try validateQuery(query);
    return query;
}

fn defaultTrendSeries(allocator: std.mem.Allocator) ![]const analysis.Metric {
    const series = try allocator.alloc(analysis.Metric, 1);
    series[0] = .{ .kind = .visitors };
    return series;
}

fn browserMetric(
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

pub const ParsedBreakdownBuilder = struct {
    from: []const u8,
    to: []const u8,
    metric: []const u8,
    event: []const u8 = "",
    goal: []const u8 = "",
    dimension: []const u8,
    property_name: []const u8 = "",
    property_type: []const u8 = "",
    predicates: []const analysis.PropertyPredicate = &.{},
    filters: analysis.FilterSet = .{},
    segment_id: ?[]const u8 = null,
    search: []const u8 = "",
    sort: analysis.Sort = .value_desc,
    limit: u16 = 25,
};

pub fn parseBreakdownBuilder(
    allocator: std.mem.Allocator,
    target: []const u8,
) !ParsedBreakdownBuilder {
    const marker = std.mem.findScalar(u8, target, '?') orelse
        return error.IncompleteBreakdownBuilder;
    const encoded = target[marker + 1 ..];
    if (encoded.len == 0 or encoded.len > analysis.maximum_url_bytes) {
        return error.InvalidBreakdownBuilder;
    }
    var builder: ?[]const u8 = null;
    var mode: ?[]const u8 = null;
    var from: ?[]const u8 = null;
    var to: ?[]const u8 = null;
    var metric: ?[]const u8 = null;
    var event: ?[]const u8 = null;
    var goal: ?[]const u8 = null;
    var dimension: ?[]const u8 = null;
    var property_name: ?[]const u8 = null;
    var property_type: ?[]const u8 = null;
    var predicates: std.ArrayList(analysis.PropertyPredicate) = .empty;
    var filters: std.ArrayList(analysis.Clause) = .empty;
    var segment_id: ?[]const u8 = null;
    var search: ?[]const u8 = null;
    var sort: ?[]const u8 = null;
    var limit: ?[]const u8 = null;
    var count: usize = 0;
    var parameters = std.mem.splitScalar(u8, encoded, '&');
    while (parameters.next()) |parameter| {
        if (parameter.len == 0) return error.InvalidBreakdownBuilder;
        count += 1;
        if (count > analysis.maximum_url_parameters) {
            return error.TooManyQueryFields;
        }
        const raw_name, const raw_value = std.mem.cutScalar(u8, parameter, '=') orelse
            return error.InvalidBreakdownBuilder;
        if (std.mem.eql(u8, raw_name, "f")) {
            if (filters.items.len >= analysis.maximum_clauses) {
                return error.TooManyAnalysisClauses;
            }
            try filters.append(
                allocator,
                try analysis.parseFormClause(allocator, raw_value),
            );
            continue;
        }
        const name = try decodeComponent(allocator, raw_name);
        const value = try decodeComponent(allocator, raw_value);
        if (std.mem.eql(u8, name, "builder")) {
            try setParsedOnce(&builder, value);
        } else if (std.mem.eql(u8, name, "mode")) {
            try setParsedOnce(&mode, value);
        } else if (std.mem.eql(u8, name, "from")) {
            try setParsedOnce(&from, value);
        } else if (std.mem.eql(u8, name, "to")) {
            try setParsedOnce(&to, value);
        } else if (std.mem.eql(u8, name, "metric")) {
            try setParsedOnce(&metric, value);
        } else if (std.mem.eql(u8, name, "event")) {
            try setParsedOnce(&event, value);
        } else if (std.mem.eql(u8, name, "goal")) {
            try setParsedOnce(&goal, value);
        } else if (std.mem.eql(u8, name, "dimension")) {
            try setParsedOnce(&dimension, value);
        } else if (std.mem.eql(u8, name, "property")) {
            try setParsedOnce(&property_name, value);
        } else if (std.mem.eql(u8, name, "property-type")) {
            try setParsedOnce(&property_type, value);
        } else if (std.mem.eql(u8, name, "p")) {
            if (predicates.items.len >= analysis.maximum_selector_predicates) {
                return error.TooManySelectorPredicates;
            }
            try predicates.append(
                allocator,
                try analysis.parseFormPredicate(allocator, raw_value),
            );
        } else if (std.mem.eql(u8, name, "segment")) {
            try setParsedOnce(&segment_id, value);
        } else if (std.mem.eql(u8, name, "search")) {
            try setParsedOnce(&search, value);
        } else if (std.mem.eql(u8, name, "sort")) {
            try setParsedOnce(&sort, value);
        } else if (std.mem.eql(u8, name, "limit")) {
            try setParsedOnce(&limit, value);
        } else {
            return error.UnknownQueryField;
        }
    }
    if (!std.mem.eql(u8, builder orelse return error.IncompleteBreakdownBuilder, "1") or
        !std.mem.eql(u8, mode orelse return error.IncompleteBreakdownBuilder, "breakdown"))
    {
        return error.InvalidBreakdownBuilder;
    }
    const parsed_limit = if (limit) |value|
        std.fmt.parseInt(u16, value, 10) catch return error.InvalidAnalysisLimit
    else
        25;
    return .{
        .from = from orelse return error.IncompleteBreakdownBuilder,
        .to = to orelse return error.IncompleteBreakdownBuilder,
        .metric = metric orelse return error.IncompleteBreakdownBuilder,
        .event = event orelse "",
        .goal = goal orelse "",
        .dimension = dimension orelse return error.IncompleteBreakdownBuilder,
        .property_name = property_name orelse "",
        .property_type = property_type orelse "",
        .predicates = try predicates.toOwnedSlice(allocator),
        .filters = .{ .clauses = try filters.toOwnedSlice(allocator) },
        .segment_id = segment_id,
        .search = search orelse "",
        .sort = if (sort) |value| try analysis.Sort.parse(value) else .value_desc,
        .limit = parsed_limit,
    };
}

pub fn finishBreakdownBuilder(
    parsed: ParsedBreakdownBuilder,
    site_slug: []const u8,
    site_id: []const u8,
) !model.Query {
    const dimension_kind = try analysis.DimensionKind.parse(parsed.dimension);
    const property_ref: ?analysis.PropertyRef = if (dimension_kind == .event_property)
        .{
            .name = parsed.property_name,
            .scalar_type = try analysis.ScalarType.parse(parsed.property_type),
        }
    else value: {
        if (parsed.property_name.len != 0) {
            return error.UnexpectedAnalysisProperty;
        }
        if (parsed.property_type.len != 0) {
            _ = try analysis.ScalarType.parse(parsed.property_type);
        }
        break :value null;
    };
    var metric = try browserMetric(parsed.metric, parsed.event, parsed.goal);
    if (parsed.predicates.len != 0) {
        var selector = metric.selector orelse return error.UnexpectedSelectorValue;
        selector.predicates = parsed.predicates;
        metric.selector = selector;
    }
    const breakdown = analysis.Query{
        .site_id = site_id,
        .range = .{ .start = parsed.from, .end = parsed.to },
        .comparison = .none,
        .mode = .breakdown,
        .metric = metric,
        .dimension = .{ .kind = dimension_kind, .property_ref = property_ref },
        .filters = parsed.filters,
        .segment_id = parsed.segment_id,
        .search = parsed.search,
        .sort = parsed.sort,
        .limit = parsed.limit,
    };
    try breakdown.validate();
    const query = model.Query{
        .site = site_slug,
        .analysis_site_id = site_id,
        .range = breakdown.range,
        .comparison = .none,
        .analysis_breakdown = breakdown,
        .analysis_filters = breakdown.filters,
        .analysis_segment_id = breakdown.segment_id,
    };
    try validateQuery(query);
    return query;
}

pub fn finishBreakdownQuery(
    breakdown: analysis.Query,
    site_slug: []const u8,
) !model.Query {
    try breakdown.validate();
    const query = model.Query{
        .site = site_slug,
        .analysis_site_id = breakdown.site_id,
        .range = breakdown.range,
        .comparison = .none,
        .analysis_breakdown = breakdown,
        .analysis_filters = breakdown.filters,
        .analysis_segment_id = breakdown.segment_id,
    };
    try validateQuery(query);
    return query;
}

pub fn translateLegacyBreakdown(
    legacy: model.Query,
    site_id: []const u8,
) !model.Query {
    if (!legacy.kind.isList()) return error.InvalidLegacyBreakdown;
    const mapped = analysis.presetForCurrentReport(
        legacy.kind,
        legacy.campaign_dimension,
    );
    const preset: analysis.Preset = switch (mapped) {
        .analysis => |value| value,
        .campaign_tuple => .campaigns_campaign,
        else => return error.InvalidLegacyBreakdown,
    };
    var breakdown = analysis.presetQuery(preset, site_id, legacy.range);
    breakdown.sort = switch (legacy.sort) {
        .count => .value_desc,
        .label => .label_asc,
    };
    breakdown.page = legacy.page;
    breakdown.limit = legacy.limit;
    return finishBreakdownQuery(breakdown, legacy.site);
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
    var goal_management: ?model.GoalManagement = null;
    if (query.goal_screen != .none) {
        const definitions = if (query.goal_screen == .list)
            try metadata.listGoalDefinitions(
                allocator,
                selected.slug,
                query.goal_page,
            )
        else
            meta.GoalPage{
                .goals = &.{},
                .has_more = false,
                .active_count = 0,
            };
        const selected_definition: ?meta.Goal = switch (query.goal_screen) {
            .detail, .edit => try metadata.goalById(
                allocator,
                selected.slug,
                query.goal_id,
            ),
            .none, .list, .new => null,
        };
        const effective_entity_kind: analysis.GoalEntityKind = if (query.goal_screen == .edit and
            !query.goal_entity_set)
            if (selected_definition.?.match_kind == .event) .event else .page
        else
            query.goal_entity_kind;
        var entities: []const model.GoalEntityOption = &.{};
        var entities_have_more = false;
        if (query.goal_screen == .new or query.goal_screen == .edit) {
            const resolved_active = if (collection_policy.strict_mode)
                try resolveAnalysisGoals(allocator, goals)
            else
                &.{};
            const discovered = analysis_store.executeGoalDiscovery(
                allocator,
                event_store,
                .{
                    .site_id = selected.id,
                    .range = query.range,
                    .kind = effective_entity_kind,
                    .search = query.goal_search,
                    .page = query.goal_entity_page,
                    .active_goals = resolved_active,
                    .strict_traffic_mode = collection_policy.strict_mode,
                    .timeout_ms = report_timeout_ms,
                },
            ) catch |err| {
                if (err == error.AnalysisTimeout) return error.ReportTimeout;
                return err;
            };
            entities = try goalEntityOptions(allocator, discovered.entities);
            entities_have_more = discovered.has_more;
        }
        goal_management = .{
            .screen = query.goal_screen,
            .definitions = try goalDefinitionViews(
                allocator,
                query,
                definitions.goals,
            ),
            .active_count = definitions.active_count,
            .selected = if (selected_definition) |goal|
                try goalDefinitionView(allocator, query, goal)
            else
                null,
            .entity_kind = effective_entity_kind,
            .search = query.goal_search,
            .entities = entities,
            .list_url = try goalManagementUrl(allocator, query, .list, ""),
            .new_url = try goalManagementUrl(allocator, query, .new, ""),
            .previous_definitions_url = if (query.goal_page > 1)
                try goalDefinitionsPageUrl(allocator, query, query.goal_page - 1)
            else
                null,
            .next_definitions_url = if (definitions.has_more)
                try goalDefinitionsPageUrl(allocator, query, query.goal_page + 1)
            else
                null,
            .previous_entities_url = if ((query.goal_screen == .new or
                query.goal_screen == .edit) and query.goal_entity_page > 1)
                try goalEntitiesPageUrl(
                    allocator,
                    query,
                    effective_entity_kind,
                    query.goal_entity_page - 1,
                )
            else
                null,
            .next_entities_url = if ((query.goal_screen == .new or
                query.goal_screen == .edit) and entities_have_more)
                try goalEntitiesPageUrl(
                    allocator,
                    query,
                    effective_entity_kind,
                    query.goal_entity_page + 1,
                )
            else
                null,
        };
        if (query.goal_screen == .detail) query.subject = selected_definition.?.name;
    }
    const segments: []const meta.Segment = if (destination == .overview)
        try metadata.listSegments(allocator, selected.slug)
    else
        &.{};
    const resolved_filters = if (destination == .overview)
        try resolveFilters(
            allocator,
            metadata,
            collection_policy,
            selected.slug,
            query.analysis_filters,
            query.analysis_segment_id,
        )
    else
        ResolvedFilters{
            .filters = query.analysis_filters,
            .segment_resolved = false,
        };
    const state = if (destination == .overview)
        try analysisState(allocator, destination, query)
    else
        AnalysisState{ .kind = "", .json = "" };
    const grammar = if (destination == .overview)
        try analysisGrammarParameters(allocator, query)
    else
        AnalysisGrammarParameters{ .filters = &.{}, .predicates = &.{} };
    const filter_navigation = if (destination == .overview)
        try buildFilterNavigation(allocator, destination, query, segments)
    else
        FilterNavigation{ .chips = &.{}, .segments = &.{} };
    if (query.goal_screen == .none and query.kind == .goal and
        query.subject.len == 0 and goals.len != 0)
    {
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
                .filters = resolved_filters.filters,
                .segment_id = query.analysis_segment_id,
                .segment_resolved = resolved_filters.segment_resolved,
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
            query,
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
        .goal_management = goal_management,
        .goals = goals,
        .funnels = funnels,
        .selected_segment_name = resolved_filters.segment_name,
        .analysis_state_kind = state.kind,
        .analysis_state_json = state.json,
        .analysis_filter_parameters = grammar.filters,
        .analysis_predicate_parameters = grammar.predicates,
        .filter_chips = filter_navigation.chips,
        .segment_options = filter_navigation.segments,
        .clear_segment_url = filter_navigation.clear_segment_url,
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
    const segments = try metadata.listSegments(allocator, selected.slug);
    const saved_views = try metadata.listSavedViews(allocator, selected.slug);
    const policy = try metadata.sitePolicy(allocator, selected.id);
    const resolved_filters = try resolveFilters(
        allocator,
        metadata,
        policy,
        selected.slug,
        query.analysis_filters,
        query.analysis_segment_id,
    );
    const state = try analysisState(allocator, .analyze, query);
    const grammar = try analysisGrammarParameters(allocator, query);
    const filter_navigation = try buildFilterNavigation(
        allocator,
        .analyze,
        query,
        segments,
    );
    const selected_goal_rows = try selectedGoalsForMetrics(
        allocator,
        metadata,
        selected.slug,
        goals,
        query.analysis_series,
    );
    const display_goals = try mergeGoalRows(allocator, goals, selected_goal_rows);
    const resolved_goals = try resolveAnalysisGoals(allocator, goals);
    const resolved_selected_goals = try resolveAnalysisGoals(
        allocator,
        selected_goal_rows,
    );
    const execution = analysis.TrendSetExecution{
        .set = .{
            .site_id = selected.id,
            .range = query.range,
            .comparison = query.comparison,
            .interval = query.analysis_interval,
            .series = query.analysis_series,
            .filters = resolved_filters.filters,
            .segment_id = query.analysis_segment_id,
        },
        .comparison_range = if (calendar_context.comparison_range) |*range|
            range.view()
        else
            null,
        .active_goals = resolved_goals,
        .selected_goals = resolved_selected_goals,
        .strict_traffic_mode = policy.strict_mode,
        .segment_resolved = resolved_filters.segment_resolved,
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
        display_goals,
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
        .saved_views = saved_views,
        .selected_segment_name = resolved_filters.segment_name,
        .analysis_state_kind = state.kind,
        .analysis_state_json = state.json,
        .analysis_filter_parameters = grammar.filters,
        .analysis_predicate_parameters = grammar.predicates,
        .filter_chips = filter_navigation.chips,
        .segment_options = filter_navigation.segments,
        .clear_segment_url = filter_navigation.clear_segment_url,
        .self_exclusion_origins = policy.origins,
        .excluded_networks = policy.excluded_networks,
        .strict_mode = policy.strict_mode,
        .daily_event_ceiling = policy.daily_event_ceiling,
        .csrf_token = csrf_token,
    };
}

pub fn loadBreakdownPage(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    event_store: *events.Store,
    query_input: model.Query,
    calendar_context: calendar.Context,
    csrf_token: []const u8,
    report_timeout_ms: u32,
) !model.Page {
    var query = query_input;
    const sites = try metadata.listSites(allocator);
    if (sites.len == 0) return error.SiteNotFound;
    const selected = try resolveSite(sites, query.site);
    query.site = selected.slug;
    query.analysis_site_id = selected.id;
    var breakdown = query.analysis_breakdown orelse
        return error.MissingAnalyzeBreakdown;
    if (!std.mem.eql(u8, breakdown.site_id, selected.id)) {
        return error.InvalidAnalysisSite;
    }
    try validateQuery(query);

    const goals = try metadata.listGoals(allocator, selected.slug);
    const funnels = try metadata.listFunnels(allocator, selected.slug);
    const segments = try metadata.listSegments(allocator, selected.slug);
    const saved_views = try metadata.listSavedViews(allocator, selected.slug);
    const policy = try metadata.sitePolicy(allocator, selected.id);
    const resolved_filters = try resolveFilters(
        allocator,
        metadata,
        policy,
        selected.slug,
        breakdown.filters,
        breakdown.segment_id,
    );
    const state = try analysisState(allocator, .analyze, query);
    const grammar = try analysisGrammarParameters(allocator, query);
    const filter_navigation = try buildFilterNavigation(
        allocator,
        .analyze,
        query,
        segments,
    );
    const selected_goal_rows = try selectedGoalsForMetrics(
        allocator,
        metadata,
        selected.slug,
        goals,
        &.{breakdown.metric},
    );
    const display_goals = try mergeGoalRows(allocator, goals, selected_goal_rows);
    const resolved_goals = try resolveAnalysisGoals(allocator, goals);
    const resolved_selected_goals = try resolveAnalysisGoals(
        allocator,
        selected_goal_rows,
    );
    breakdown.filters = resolved_filters.filters;
    breakdown.site_id = selected.id;
    const executed = analysis_store.executeBreakdownPage(
        allocator,
        event_store,
        .{
            .query = breakdown,
            .active_goals = resolved_goals,
            .selected_goals = resolved_selected_goals,
            .strict_traffic_mode = policy.strict_mode,
            .segment_resolved = resolved_filters.segment_resolved,
            .timeout_ms = report_timeout_ms,
        },
    ) catch |err| {
        if (err == error.AnalysisTimeout) return error.ReportTimeout;
        return err;
    };
    return .{
        .destination = .analyze,
        .sites = sites,
        .selected_site = selected,
        .query = query,
        .calendar_context = calendar_context,
        .report_time_basis = .none,
        .result = null,
        .analyze_breakdown = .{
            .rows = try buildBreakdownRows(
                allocator,
                query,
                executed.breakdown.rows,
            ),
            .next_page = executed.breakdown.next_page,
            .cardinality = executed.breakdown.cardinality,
            .coverage = try coverageText(
                allocator,
                executed.breakdown.completeness,
                "Current",
            ),
            .properties = executed.properties.entries,
            .property_count = executed.properties.property_count,
            .properties_truncated = executed.properties.truncated,
            .no_events_ever = !executed.site_has_events,
        },
        .goals = display_goals,
        .funnels = funnels,
        .saved_views = saved_views,
        .selected_segment_name = resolved_filters.segment_name,
        .analysis_state_kind = state.kind,
        .analysis_state_json = state.json,
        .analysis_filter_parameters = grammar.filters,
        .analysis_predicate_parameters = grammar.predicates,
        .filter_chips = filter_navigation.chips,
        .segment_options = filter_navigation.segments,
        .clear_segment_url = filter_navigation.clear_segment_url,
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

fn selectedGoalsForMetrics(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    site_slug: []const u8,
    active_goals: []const meta.Goal,
    metrics: []const analysis.Metric,
) ![]const meta.Goal {
    var result: std.ArrayList(meta.Goal) = .empty;
    for (metrics) |metric| {
        const selector = metric.selector orelse continue;
        if (selector.kind != .saved_goal) continue;
        if (goalById(active_goals, selector.value) != null) continue;
        if (goalById(result.items, selector.value) != null) continue;
        if (result.items.len >= analysis.maximum_series) {
            return error.TooManySelectedGoals;
        }
        try result.append(
            allocator,
            try metadata.goalById(allocator, site_slug, selector.value),
        );
    }
    return result.toOwnedSlice(allocator);
}

fn mergeGoalRows(
    allocator: std.mem.Allocator,
    active: []const meta.Goal,
    selected: []const meta.Goal,
) ![]const meta.Goal {
    var result: std.ArrayList(meta.Goal) = .empty;
    try result.ensureTotalCapacity(allocator, active.len + selected.len);
    try result.appendSlice(allocator, active);
    for (selected) |goal| {
        if (goalById(result.items, goal.id) == null) {
            try result.append(allocator, goal);
        }
    }
    return result.toOwnedSlice(allocator);
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
    query: model.Query,
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
        const urls = try filterUrlsForClause(allocator, .overview, query, .{
            .scope = .event,
            .field = .{ .kind = .page },
            .operator = .is,
            .scalar_type = .string,
            .values = &.{source.path},
        });
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
            .filter_url = urls.filter,
            .exclude_url = urls.exclude,
        };
    }

    const acquisition = try allocator.alloc(
        model.OverviewAcquisitionRow,
        details.acquisition.len,
    );
    for (acquisition, details.acquisition) |*target, source| {
        const clause = analysis.Clause{
            .scope = .session,
            .field = .{ .kind = .referrer },
            .operator = if (std.mem.eql(u8, source.source, "Direct"))
                .absent
            else
                .is,
            .scalar_type = .string,
            .values = if (std.mem.eql(u8, source.source, "Direct"))
                &.{}
            else
                &.{source.source},
        };
        const urls = try filterUrlsForClause(allocator, .overview, query, clause);
        target.* = .{
            .label = source.source,
            .sessions = source.sessions,
            .conversion = .{
                .numerator = source.converting_sessions,
                .denominator = source.sessions,
            },
            .filter_url = urls.filter,
            .exclude_url = urls.exclude,
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
    for (audience, details.audience) |*target, source| {
        const urls = try filterUrlsForClause(allocator, .overview, query, .{
            .scope = .session,
            .field = .{ .kind = .country },
            .operator = .is,
            .scalar_type = .string,
            .values = &.{source.country},
        });
        target.* = .{
            .label = source.country,
            .sessions = source.sessions,
            .filter_url = urls.filter,
            .exclude_url = urls.exclude,
        };
    }
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

fn goalEntityOptions(
    allocator: std.mem.Allocator,
    entities: []const analysis.DiscoveredGoalEntity,
) ![]const model.GoalEntityOption {
    const result = try allocator.alloc(model.GoalEntityOption, entities.len);
    for (result, entities) |*target, entity| target.* = .{
        .label = entity.label,
        .eligible_count = entity.eligible_count,
        .last_seen = try formatUtcMicros(
            allocator,
            entity.last_received_at_utc_micros,
        ),
    };
    return result;
}

fn goalDefinitionViews(
    allocator: std.mem.Allocator,
    query: model.Query,
    goals: []const meta.Goal,
) ![]const model.GoalDefinitionView {
    const result = try allocator.alloc(model.GoalDefinitionView, goals.len);
    for (result, goals) |*target, goal| {
        target.* = try goalDefinitionView(allocator, query, goal);
    }
    return result;
}

fn goalDefinitionView(
    allocator: std.mem.Allocator,
    query: model.Query,
    goal: meta.Goal,
) !model.GoalDefinitionView {
    return .{
        .id = goal.id,
        .name = goal.name,
        .entity_kind = if (goal.match_kind == .event) .event else .page,
        .match_mode = if (goal.match_kind == .prefix) .prefix else .exact,
        .match_value = goal.match_value,
        .archived = goal.archived_at_utc_micros != null,
        .created_at = try formatUtcMicros(allocator, goal.created_at_utc_micros),
        .updated_at = try formatUtcMicros(allocator, goal.updated_at_utc_micros),
        .updated_at_utc_micros = goal.updated_at_utc_micros,
        .detail_url = try goalManagementUrl(allocator, query, .detail, goal.id),
        .edit_url = try goalManagementUrl(allocator, query, .edit, goal.id),
    };
}

fn goalManagementUrl(
    allocator: std.mem.Allocator,
    query: model.Query,
    screen: model.GoalScreen,
    goal_id: []const u8,
) ![]const u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    try output.writer.print(
        "/admin/sites/{s}/journeys/goals",
        .{query.site},
    );
    switch (screen) {
        .none, .list => {},
        .new => try output.writer.writeAll("/new"),
        .detail, .edit => {
            try domain.validateUuid(goal_id);
            try output.writer.print("/{s}", .{goal_id});
            if (screen == .edit) try output.writer.writeAll("/edit");
        },
    }
    try output.writer.print(
        "?from={s}&to={s}&compare={s}",
        .{ query.range.start, query.range.end, query.comparison.name() },
    );
    return output.toOwnedSlice();
}

fn goalDefinitionsPageUrl(
    allocator: std.mem.Allocator,
    query: model.Query,
    page: u32,
) ![]const u8 {
    if (page == 0 or page > 1_000_000) return error.InvalidGoalPage;
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    try output.writer.print(
        "/admin/sites/{s}/journeys/goals?from={s}&to={s}&compare={s}",
        .{ query.site, query.range.start, query.range.end, query.comparison.name() },
    );
    if (page != 1) try output.writer.print("&goal-page={d}", .{page});
    return output.toOwnedSlice();
}

fn goalEntitiesPageUrl(
    allocator: std.mem.Allocator,
    query: model.Query,
    entity_kind: analysis.GoalEntityKind,
    page: u32,
) ![]const u8 {
    if (page == 0 or page > 1_000_000 or
        (query.goal_screen != .new and query.goal_screen != .edit))
    {
        return error.InvalidGoalDiscoveryPage;
    }
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    const base = try goalManagementUrl(
        allocator,
        query,
        query.goal_screen,
        query.goal_id,
    );
    defer allocator.free(base);
    try output.writer.writeAll(base);
    try output.writer.writeAll(if (entity_kind == .event)
        "&entity=event"
    else
        "&entity=page");
    if (query.goal_search.len != 0) {
        try output.writer.writeAll("&search=");
        try goalUrlComponent(&output.writer, query.goal_search);
    }
    if (page != 1) try output.writer.print("&entity-page={d}", .{page});
    return output.toOwnedSlice();
}

fn goalUrlComponent(output: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or
            byte == '-' or byte == '_' or byte == '.' or byte == '~')
        {
            try output.writeByte(byte);
        } else {
            try output.writeByte('%');
            try output.writeByte(hex[byte >> 4]);
            try output.writeByte(hex[byte & 0x0f]);
        }
    }
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
    event_store: *events.Store,
    form: Form,
    now_micros: i64,
    report_timeout_ms: u32,
) !void {
    const site = try form.required("site");
    try domain.validateSlug(site);
    const input = try goalInput(form);
    try requireObservedGoal(
        allocator,
        metadata,
        event_store,
        site,
        try formContext(form),
        input,
        report_timeout_ms,
    );
    const id = try domain.randomUuid(io);
    try metadata.addGoal(
        allocator,
        &id,
        site,
        input.name,
        input.match_kind,
        input.match_value,
        now_micros,
    );
}

pub fn editGoal(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    event_store: *events.Store,
    form: Form,
    now_micros: i64,
    report_timeout_ms: u32,
) !void {
    const site = try form.required("site");
    const input = try goalInput(form);
    try requireObservedGoal(
        allocator,
        metadata,
        event_store,
        site,
        try formContext(form),
        input,
        report_timeout_ms,
    );
    try metadata.editGoal(
        allocator,
        site,
        try form.required("id"),
        try goalTimestamp(form),
        input.name,
        input.match_kind,
        input.match_value,
        now_micros,
    );
}

pub fn duplicateGoal(
    allocator: std.mem.Allocator,
    io: std.Io,
    metadata: *meta.Store,
    form: Form,
    now_micros: i64,
) !void {
    const site = try form.required("site");
    const id = try domain.randomUuid(io);
    try metadata.duplicateGoal(
        allocator,
        &id,
        site,
        try form.required("id"),
        try goalTimestamp(form),
        try form.required("name"),
        now_micros,
    );
}

pub fn archiveGoal(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    form: Form,
    now_micros: i64,
) !void {
    try metadata.archiveGoal(
        allocator,
        try form.required("site"),
        try form.required("id"),
        try goalTimestamp(form),
        now_micros,
    );
}

pub fn reactivateGoal(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    form: Form,
    now_micros: i64,
) !void {
    try metadata.reactivateGoal(
        allocator,
        try form.required("site"),
        try form.required("id"),
        try goalTimestamp(form),
        now_micros,
    );
}

pub fn deleteGoal(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    form: Form,
) !void {
    try metadata.deleteGoalById(
        allocator,
        try form.required("site"),
        try form.required("id"),
        try goalTimestamp(form),
        try form.required("name"),
    );
}

const GoalInput = struct {
    name: []const u8,
    entity_kind: analysis.GoalEntityKind,
    match_kind: domain.MatchKind,
    match_value: []const u8,
    confirm_unseen: bool,
};

fn goalInput(form: Form) !GoalInput {
    const entity = try form.required("entity");
    const match = try form.required("match");
    const entity_kind: analysis.GoalEntityKind = if (std.mem.eql(u8, entity, "page"))
        .page
    else if (std.mem.eql(u8, entity, "event"))
        .event
    else
        return error.InvalidGoalEntityKind;
    const match_kind: domain.MatchKind = switch (entity_kind) {
        .event => if (std.mem.eql(u8, match, "exact"))
            .event
        else
            return error.InvalidGoalMatch,
        .page => if (std.mem.eql(u8, match, "exact"))
            .path
        else if (std.mem.eql(u8, match, "prefix"))
            .prefix
        else
            return error.InvalidGoalMatch,
    };
    return .{
        .name = try form.required("name"),
        .entity_kind = entity_kind,
        .match_kind = match_kind,
        .match_value = try form.required("value"),
        .confirm_unseen = if (form.optional("confirm_unseen")) |value|
            std.mem.eql(u8, value, "on")
        else
            false,
    };
}

fn goalTimestamp(form: Form) !i64 {
    const value = std.fmt.parseInt(
        i64,
        try form.required("updated_at"),
        10,
    ) catch return error.InvalidGoalTimestamp;
    if (value < 0) return error.InvalidGoalTimestamp;
    return value;
}

fn requireObservedGoal(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    event_store: *events.Store,
    site_slug: []const u8,
    context: FormContext,
    input: GoalInput,
    report_timeout_ms: u32,
) !void {
    try domain.validateName(input.name, 120);
    const selector = analysis.EventSelector{
        .kind = switch (input.match_kind) {
            .event => .exact_event,
            .path => .exact_page,
            .prefix => .page_prefix,
        },
        .value = input.match_value,
    };
    try selector.validate();
    const site = try metadata.siteConfigurationBySlug(allocator, site_slug);
    const policy = try metadata.sitePolicy(allocator, site.id);
    const active = if (policy.strict_mode)
        try resolveAnalysisGoals(
            allocator,
            try metadata.listGoals(allocator, site_slug),
        )
    else
        &.{};
    const observed = analysis_store.goalSelectorObserved(
        allocator,
        event_store,
        .{
            .site_id = site.id,
            .range = context.range,
            .kind = input.entity_kind,
            .active_goals = active,
            .strict_traffic_mode = policy.strict_mode,
            .timeout_ms = report_timeout_ms,
        },
        selector,
    ) catch |err| {
        if (err == error.AnalysisTimeout) return error.ReportTimeout;
        return err;
    };
    if (!observed and !input.confirm_unseen) return error.GoalNotObserved;
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
    if (query.goal_screen != .none) {
        if (query.kind != .goal or query.subject.len != 0 or
            query.goal_page == 0 or query.goal_page > 1_000_000 or
            query.goal_entity_page == 0 or query.goal_entity_page > 1_000_000)
        {
            return error.InvalidGoalManagementState;
        }
        try validateGoalSearch(query.goal_search);
        switch (query.goal_screen) {
            .list => if (query.goal_id.len != 0 or query.goal_entity_set or
                query.goal_search.len != 0 or query.goal_entity_page != 1)
            {
                return error.InvalidGoalManagementState;
            },
            .new => if (query.goal_id.len != 0 or query.goal_page != 1) {
                return error.InvalidGoalManagementState;
            },
            .detail => {
                try domain.validateUuid(query.goal_id);
                if (query.goal_page != 1 or query.goal_entity_set or
                    query.goal_search.len != 0 or query.goal_entity_page != 1)
                {
                    return error.InvalidGoalManagementState;
                }
            },
            .edit => {
                try domain.validateUuid(query.goal_id);
                if (query.goal_page != 1) {
                    return error.InvalidGoalManagementState;
                }
            },
            .none => unreachable,
        }
    }
    if (query.analysis_breakdown) |breakdown| {
        if (query.analysis_series.len != 0 or
            query.kind != .overview or query.subject.len != 0 or
            query.campaign_dimension != .all or query.sort != .count or
            query.limit != report.default_limit or query.page != 1 or
            query.overview_metric != .visitors or
            query.overview_currency.len != 0 or
            query.highlighted_interval.len != 0 or
            query.analysis_interval != .auto or
            !std.mem.eql(u8, query.analysis_site_id, breakdown.site_id) or
            !std.mem.eql(u8, query.range.start, breakdown.range.start) or
            !std.mem.eql(u8, query.range.end, breakdown.range.end) or
            query.comparison != .none or breakdown.comparison != .none or
            breakdown.mode != .breakdown or
            !analysis.filterSetsEqual(query.analysis_filters, breakdown.filters) or
            !optionalSlicesEqual(query.analysis_segment_id, breakdown.segment_id))
        {
            return error.AnalysisOptionsNotApplicable;
        }
        try breakdown.validate();
        try analysis.validateBrowserBreakdownMetric(breakdown.metric);
        return;
    }
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
        try query.analysis_filters.validate();
        if (query.analysis_segment_id) |id| try domain.validateUuid(id);
        return;
    }
    if (query.analysis_interval != .auto) {
        return error.AnalysisOptionsNotApplicable;
    }
    try query.analysis_filters.validate();
    if (query.analysis_segment_id) |id| try domain.validateUuid(id);
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

fn optionalSlicesEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if ((left == null) != (right == null)) return false;
    if (left) |value| return std.mem.eql(u8, value, right.?);
    return true;
}

const ResolvedFilters = struct {
    filters: analysis.FilterSet,
    segment_resolved: bool,
    segment_name: []const u8 = "",
};

const AnalysisState = struct {
    kind: []const u8,
    json: []const u8,
};

const AnalysisGrammarParameters = struct {
    filters: []const []const u8,
    predicates: []const []const u8,
};

fn analysisGrammarParameters(
    allocator: std.mem.Allocator,
    query: model.Query,
) !AnalysisGrammarParameters {
    const filters = targetFilters(query).clauses;
    const encoded_filters = try allocator.alloc([]const u8, filters.len);
    for (filters, 0..) |filter, index| {
        encoded_filters[index] = try analysis.canonicalClause(allocator, filter);
    }
    const predicates = if (query.analysis_breakdown) |breakdown|
        if (breakdown.metric.selector) |selector| selector.predicates else &.{}
    else
        &.{};
    const encoded_predicates = try allocator.alloc([]const u8, predicates.len);
    for (predicates, 0..) |predicate, index| {
        encoded_predicates[index] = try analysis.canonicalPredicate(
            allocator,
            predicate,
        );
    }
    return .{
        .filters = encoded_filters,
        .predicates = encoded_predicates,
    };
}

fn analysisState(
    allocator: std.mem.Allocator,
    destination: model.Destination,
    query: model.Query,
) !AnalysisState {
    if (destination == .overview) return .{
        .kind = "overview",
        .json = try analysis.canonicalFilterJson(
            allocator,
            query.analysis_filters,
        ),
    };
    if (destination == .analyze and query.analysis_breakdown != null) {
        return .{
            .kind = "breakdown",
            .json = try analysis.canonicalJson(
                allocator,
                query.analysis_breakdown.?,
            ),
        };
    }
    if (destination == .analyze and query.analysis_series.len != 0) {
        return .{
            .kind = "trend",
            .json = try analysis.canonicalTrendSetJson(allocator, .{
                .site_id = query.analysis_site_id,
                .range = query.range,
                .comparison = query.comparison,
                .interval = query.analysis_interval,
                .series = query.analysis_series,
                .filters = query.analysis_filters,
                .segment_id = query.analysis_segment_id,
            }),
        };
    }
    return .{ .kind = "", .json = "" };
}

const FilterNavigation = struct {
    chips: []const model.FilterChip,
    segments: []const model.SegmentOption,
    clear_segment_url: []const u8 = "",
};

fn buildFilterNavigation(
    allocator: std.mem.Allocator,
    destination: model.Destination,
    query: model.Query,
    saved_segments: []const meta.Segment,
) !FilterNavigation {
    const filters = targetFilters(query);
    const chips = try allocator.alloc(model.FilterChip, filters.clauses.len);
    for (chips, filters.clauses, 0..) |*chip, clause, removed_index| {
        var label = std.Io.Writer.Allocating.init(allocator);
        errdefer label.deinit();
        try label.writer.print("{s} · {s}", .{
            clause.scope.name(),
            clause.field.kind.name(),
        });
        if (clause.field.property_ref) |reference| {
            try label.writer.print(":{s}:{s}", .{
                reference.name,
                reference.scalar_type.name(),
            });
        }
        try label.writer.print(" · {s}", .{clause.operator.name()});
        if (clause.values.len != 0) {
            try label.writer.writeAll(" · ");
            for (clause.values, 0..) |value, index| {
                if (index != 0) try label.writer.writeAll(" or ");
                try label.writer.writeAll(value);
            }
        }
        const remaining = try allocator.alloc(
            analysis.Clause,
            filters.clauses.len - 1,
        );
        @memcpy(remaining[0..removed_index], filters.clauses[0..removed_index]);
        @memcpy(
            remaining[removed_index..],
            filters.clauses[removed_index + 1 ..],
        );
        var adjusted = query;
        setTargetFilters(&adjusted, .{ .clauses = remaining });
        chip.* = .{
            .label = try label.toOwnedSlice(),
            .remove_url = try canonicalAnalysisUrl(
                allocator,
                destination,
                adjusted,
            ),
        };
    }
    const segments = try allocator.alloc(
        model.SegmentOption,
        saved_segments.len,
    );
    for (segments, saved_segments) |*option, segment| {
        var adjusted = query;
        setTargetSegment(&adjusted, segment.id);
        const url = canonicalAnalysisUrl(
            allocator,
            destination,
            adjusted,
        ) catch |err| switch (err) {
            error.AnalysisUrlTooLong => "",
            else => return err,
        };
        option.* = .{
            .id = segment.id,
            .name = segment.name,
            .url = url,
            .updated_at_utc = try formatUtcMicros(
                allocator,
                segment.updated_at_utc_micros,
            ),
            .selected = if (query.analysis_segment_id) |selected|
                std.mem.eql(u8, selected, segment.id)
            else
                false,
        };
    }
    const clear = if (query.analysis_segment_id != null) clear: {
        var adjusted = query;
        setTargetSegment(&adjusted, null);
        break :clear try canonicalAnalysisUrl(allocator, destination, adjusted);
    } else "";
    return .{
        .chips = chips,
        .segments = segments,
        .clear_segment_url = clear,
    };
}

fn canonicalAnalysisUrl(
    allocator: std.mem.Allocator,
    destination: model.Destination,
    query: model.Query,
) ![]const u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    try output.writer.print("/admin/sites/{s}/", .{query.site});
    if (destination == .overview) {
        try output.writer.writeAll("overview?");
        const parameters = try analysis.canonicalOverviewUrl(
            allocator,
            query.range,
            query.comparison,
            query.overview_metric,
            query.overview_currency,
            query.analysis_segment_id,
            query.analysis_filters,
        );
        defer allocator.free(parameters);
        try output.writer.writeAll(parameters);
        return output.toOwnedSlice();
    }
    if (destination != .analyze) return error.InvalidFilterDestination;
    try output.writer.writeAll("analyze?");
    if (query.analysis_breakdown) |breakdown| {
        const parameters = try analysis.canonicalUrl(allocator, breakdown);
        defer allocator.free(parameters);
        try output.writer.writeAll(parameters);
    } else {
        const parameters = try analysis.canonicalTrendSetUrl(
            allocator,
            .{
                .site_id = query.analysis_site_id,
                .range = query.range,
                .comparison = query.comparison,
                .interval = query.analysis_interval,
                .series = query.analysis_series,
                .filters = query.analysis_filters,
                .segment_id = query.analysis_segment_id,
            },
            query.highlighted_interval,
        );
        defer allocator.free(parameters);
        try output.writer.writeAll(parameters);
    }
    return output.toOwnedSlice();
}

const FilterUrls = struct {
    filter: []const u8,
    exclude: []const u8,
};

fn filterUrlsForClause(
    allocator: std.mem.Allocator,
    destination: model.Destination,
    query: model.Query,
    filter_clause: analysis.Clause,
) !FilterUrls {
    if (targetFilters(query).clauses.len >= analysis.maximum_clauses) {
        return .{ .filter = "", .exclude = "" };
    }
    try filter_clause.validate();
    var exclude_clause = filter_clause;
    exclude_clause.operator = switch (filter_clause.operator) {
        .is => .is_not,
        .is_not => .is,
        .absent => .exists,
        .exists => .absent,
        .is_true => .is_false,
        .is_false => .is_true,
        .contains => .not_contains,
        .not_contains => .contains,
        else => return error.UnsupportedClickFilterOperator,
    };
    try exclude_clause.validate();
    var filtered = query;
    setTargetFilters(&filtered, try analysis.composeFilterSets(
        allocator,
        targetFilters(query),
        .{ .clauses = &.{filter_clause} },
    ));
    if (filtered.analysis_breakdown) |*breakdown| breakdown.page = 1;
    var excluded = query;
    setTargetFilters(&excluded, try analysis.composeFilterSets(
        allocator,
        targetFilters(query),
        .{ .clauses = &.{exclude_clause} },
    ));
    if (excluded.analysis_breakdown) |*breakdown| breakdown.page = 1;
    const filter_url = canonicalAnalysisUrl(
        allocator,
        destination,
        filtered,
    ) catch |err| switch (err) {
        error.AnalysisUrlTooLong => return .{ .filter = "", .exclude = "" },
        else => return err,
    };
    const exclude_url = canonicalAnalysisUrl(
        allocator,
        destination,
        excluded,
    ) catch |err| switch (err) {
        error.AnalysisUrlTooLong => {
            allocator.free(filter_url);
            return .{ .filter = "", .exclude = "" };
        },
        else => {
            allocator.free(filter_url);
            return err;
        },
    };
    return .{ .filter = filter_url, .exclude = exclude_url };
}

fn buildBreakdownRows(
    allocator: std.mem.Allocator,
    query: model.Query,
    rows: []const analysis.BreakdownRow,
) ![]const model.AnalyzeBreakdownRow {
    const breakdown = query.analysis_breakdown orelse
        return error.MissingAnalyzeBreakdown;
    const dimension = breakdown.dimension.?;
    const field_kind: analysis.FieldKind = switch (dimension.kind) {
        .page => .page,
        .hostname => .hostname,
        .event_name => .event_name,
        .landing_page => .landing_page,
        .exit_page => .exit_page,
        .channel => .channel,
        .referrer => .referrer,
        .utm_source => .utm_source,
        .utm_medium => .utm_medium,
        .utm_campaign => .utm_campaign,
        .utm_term => .utm_term,
        .utm_content => .utm_content,
        .country => .country,
        .language => .language,
        .device => .device,
        .browser => .browser,
        .operating_system => .operating_system,
        .event_property => .event_property,
    };
    const scope: analysis.Scope = switch (dimension.kind) {
        .page, .hostname, .event_name, .event_property => .event,
        else => .session,
    };
    const result = try allocator.alloc(model.AnalyzeBreakdownRow, rows.len);
    for (result, rows) |*target, row| {
        const scalar_type = row.label.scalar_type orelse .string;
        const missing = std.mem.eql(u8, row.label.value, "(not set)") or
            std.mem.eql(u8, row.label.value, "(missing)");
        const is_null = std.mem.eql(u8, row.label.value, "(null)");
        const clause = analysis.Clause{
            .scope = scope,
            .field = .{
                .kind = field_kind,
                .property_ref = if (dimension.property_ref) |reference| .{
                    .name = reference.name,
                    .scalar_type = if (missing) .missing else if (is_null) .null else scalar_type,
                } else null,
            },
            .operator = if (missing and dimension.property_ref == null)
                .absent
            else
                .is,
            .scalar_type = if (missing and dimension.property_ref != null)
                .missing
            else if (is_null)
                .null
            else
                scalar_type,
            .values = if (missing or is_null) &.{} else &.{row.label.value},
        };
        const urls = try filterUrlsForClause(allocator, .analyze, query, clause);
        target.* = .{
            .data = row,
            .filter_url = urls.filter,
            .exclude_url = urls.exclude,
        };
    }
    return result;
}

fn resolveFilters(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    policy: meta.SitePolicy,
    site_slug: []const u8,
    ad_hoc: analysis.FilterSet,
    segment_id: ?[]const u8,
) !ResolvedFilters {
    try ad_hoc.validate();
    for (ad_hoc.clauses) |clause| {
        if (clause.field.property_ref) |reference| {
            if (!policy.allowsProperty(reference.name)) {
                return error.StaleFilterProperty;
            }
        }
    }
    const id = segment_id orelse return .{
        .filters = ad_hoc,
        .segment_resolved = false,
    };
    const segment = try metadata.segmentById(allocator, site_slug, id);
    const stored = analysis.parseExactCanonicalFilterJson(
        allocator,
        segment.canonical_filter_json,
    ) catch return error.StaleSegmentState;
    for (stored.clauses) |clause| {
        if (clause.field.property_ref) |reference| {
            if (!policy.allowsProperty(reference.name)) {
                return error.StaleSegmentProperty;
            }
        }
    }
    return .{
        .filters = try analysis.composeFilterSets(allocator, stored, ad_hoc),
        .segment_resolved = true,
        .segment_name = segment.name,
    };
}

pub const AnalysisTarget = struct {
    destination: model.Destination,
    query: model.Query,
};

pub fn analysisTargetFromForm(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    form: Form,
) !AnalysisTarget {
    const site_slug = try form.required("site");
    const configuration = try metadata.siteConfigurationBySlug(
        allocator,
        site_slug,
    );
    const kind = try form.required("state_kind");
    const encoded = try form.required("state");
    if (std.mem.eql(u8, kind, "overview")) {
        const filters = try analysis.parseExactCanonicalFilterJson(
            allocator,
            encoded,
        );
        const selection = try parseOverviewMetric(try form.required("metric"));
        const segment_value = form.optional("segment") orelse "";
        const query = model.Query{
            .site = site_slug,
            .analysis_site_id = configuration.id,
            .range = .{
                .start = try form.required("from"),
                .end = try form.required("to"),
            },
            .comparison = try analysis.Comparison.parse(
                try form.required("compare"),
            ),
            .overview_metric = selection.metric,
            .overview_currency = selection.currency,
            .analysis_filters = filters,
            .analysis_segment_id = if (segment_value.len == 0)
                null
            else
                segment_value,
        };
        try validateQuery(query);
        return .{ .destination = .overview, .query = query };
    }
    if (std.mem.eql(u8, kind, "trend")) {
        const set = try analysis.parseExactCanonicalTrendSetJson(
            allocator,
            encoded,
        );
        if (!std.mem.eql(u8, set.site_id, configuration.id)) {
            return error.InvalidAnalysisSite;
        }
        const query = model.Query{
            .site = site_slug,
            .analysis_site_id = configuration.id,
            .range = set.range,
            .comparison = set.comparison,
            .analysis_interval = set.interval,
            .analysis_series = set.series,
            .analysis_filters = set.filters,
            .analysis_segment_id = set.segment_id,
        };
        try validateQuery(query);
        return .{ .destination = .analyze, .query = query };
    }
    if (std.mem.eql(u8, kind, "breakdown")) {
        const breakdown = try analysis.parseExactCanonicalJson(
            allocator,
            encoded,
        );
        if (!std.mem.eql(u8, breakdown.site_id, configuration.id) or
            breakdown.mode != .breakdown)
        {
            return error.InvalidAnalysisSite;
        }
        return .{
            .destination = .analyze,
            .query = try finishBreakdownQuery(breakdown, site_slug),
        };
    }
    return error.InvalidAnalysisStateKind;
}

pub fn applyFilterFromForm(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    form: Form,
) !AnalysisTarget {
    var target = try analysisTargetFromForm(allocator, metadata, form);
    const clause = try clauseFromForm(allocator, form);
    const addition = analysis.FilterSet{ .clauses = &.{clause} };
    const filters = try analysis.composeFilterSets(
        allocator,
        targetFilters(target.query),
        addition,
    );
    setTargetFilters(&target.query, filters);
    try validateQuery(target.query);
    return target;
}

pub fn suggestionsFromForm(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    event_store: *events.Store,
    form: Form,
    timeout_ms: u32,
) !struct { target: AnalysisTarget, suggestions: model.FilterSuggestions } {
    const target = try analysisTargetFromForm(allocator, metadata, form);
    const scope = try analysis.Scope.parse(try form.required("scope"));
    const scalar_type = try analysis.ScalarType.parse(
        try form.required("scalar_type"),
    );
    const field_kind = try analysis.FieldKind.parse(try form.required("field"));
    const property_name = form.optional("property") orelse "";
    const field = analysis.Field{
        .kind = field_kind,
        .property_ref = if (field_kind.requiresProperty()) .{
            .name = property_name,
            .scalar_type = scalar_type,
        } else null,
    };
    if (!field_kind.requiresProperty() and property_name.len != 0) {
        return error.UnexpectedAnalysisProperty;
    }
    const policy = try metadata.sitePolicy(
        allocator,
        target.query.analysis_site_id,
    );
    if (field.property_ref) |reference| {
        if (!policy.allowsProperty(reference.name)) {
            return error.StaleFilterProperty;
        }
    }
    const resolved = try resolveFilters(
        allocator,
        metadata,
        policy,
        target.query.site,
        targetFilters(target.query),
        target.query.analysis_segment_id,
    );
    const goals = try metadata.listGoals(allocator, target.query.site);
    const resolved_goals = try resolveAnalysisGoals(allocator, goals);
    var query = if (target.query.analysis_breakdown) |breakdown|
        breakdown
    else if (target.query.analysis_series.len != 0)
        (analysis.TrendSet{
            .site_id = target.query.analysis_site_id,
            .range = target.query.range,
            .comparison = target.query.comparison,
            .interval = target.query.analysis_interval,
            .series = target.query.analysis_series,
        }).query(target.query.analysis_series[0])
    else
        analysis.Query{
            .site_id = target.query.analysis_site_id,
            .range = target.query.range,
            .comparison = target.query.comparison,
            .mode = .trend,
            .metric = .{ .kind = .visitors },
            .interval = .auto,
        };
    query.comparison = .none;
    query.filters = resolved.filters;
    query.segment_id = target.query.analysis_segment_id;
    const search = form.optional("search") orelse "";
    const operator = try analysis.Operator.parse(try form.required("operator"));
    const builder_values = form.optional("values") orelse "";
    if (builder_values.len >
        @as(usize, analysis.maximum_values) * analysis.maximum_filter_value_bytes or
        !std.unicode.utf8ValidateSlice(builder_values))
    {
        return error.InvalidAnalysisValue;
    }
    const result = try analysis_store.executeSuggestions(
        allocator,
        event_store,
        .{
            .execution = .{
                .query = query,
                .active_goals = resolved_goals,
                .strict_traffic_mode = policy.strict_mode,
                .segment_resolved = resolved.segment_resolved,
                .timeout_ms = timeout_ms,
            },
            .scope = scope,
            .field = field,
            .scalar_type = scalar_type,
            .search = search,
        },
    );
    const options = try allocator.alloc(model.FilterSuggestion, result.values.len);
    for (options, result.values) |*option, value| {
        const urls = try filterUrlsForClause(
            allocator,
            target.destination,
            target.query,
            .{
                .scope = scope,
                .field = field,
                .operator = .is,
                .scalar_type = scalar_type,
                .values = &.{value},
            },
        );
        option.* = .{
            .value = value,
            .filter_url = urls.filter,
            .exclude_url = urls.exclude,
        };
    }
    return .{
        .target = target,
        .suggestions = .{
            .values = options,
            .has_more = result.has_more,
            .scope = scope,
            .field = field,
            .scalar_type = scalar_type,
            .operator = operator,
            .search = search,
            .builder_values = builder_values,
        },
    };
}

pub fn removeFilterFromForm(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    form: Form,
) !AnalysisTarget {
    var target = try analysisTargetFromForm(allocator, metadata, form);
    if (form.optional("remove_segment")) |value| {
        if (!std.mem.eql(u8, value, "1") or target.query.analysis_segment_id == null) {
            return error.InvalidSegmentRemoval;
        }
        setTargetSegment(&target.query, null);
        return target;
    }
    const removed = try analysis.parseCanonicalClause(
        allocator,
        try form.required("clause"),
    );
    const current = targetFilters(target.query);
    var found = false;
    const clauses = try allocator.alloc(
        analysis.Clause,
        if (current.clauses.len == 0) 0 else current.clauses.len - 1,
    );
    var index: usize = 0;
    for (current.clauses) |clause| {
        if (!found and analysis.clausesEqual(clause, removed)) {
            found = true;
            continue;
        }
        if (index >= clauses.len) return error.FilterClauseNotFound;
        clauses[index] = clause;
        index += 1;
    }
    if (!found or index != clauses.len) return error.FilterClauseNotFound;
    setTargetFilters(&target.query, .{ .clauses = clauses });
    try validateQuery(target.query);
    return target;
}

pub fn createSegmentFromForm(
    allocator: std.mem.Allocator,
    io: std.Io,
    metadata: *meta.Store,
    form: Form,
    now_micros: i64,
) !void {
    const target = try analysisTargetFromForm(allocator, metadata, form);
    const policy = try metadata.sitePolicy(
        allocator,
        target.query.analysis_site_id,
    );
    const resolved = try resolveFilters(
        allocator,
        metadata,
        policy,
        target.query.site,
        targetFilters(target.query),
        target.query.analysis_segment_id,
    );
    const encoded = try analysis.canonicalFilterJson(allocator, resolved.filters);
    const id = try domain.randomUuid(io);
    try metadata.addSegment(
        allocator,
        &id,
        target.query.site,
        try form.required("name"),
        encoded,
        now_micros,
    );
}

pub fn updateSegmentFromForm(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    form: Form,
    now_micros: i64,
) !void {
    const target = try analysisTargetFromForm(allocator, metadata, form);
    const policy = try metadata.sitePolicy(
        allocator,
        target.query.analysis_site_id,
    );
    const resolved = try resolveFilters(
        allocator,
        metadata,
        policy,
        target.query.site,
        targetFilters(target.query),
        target.query.analysis_segment_id,
    );
    try metadata.updateSegmentState(
        allocator,
        target.query.site,
        try form.required("id"),
        try analysis.canonicalFilterJson(allocator, resolved.filters),
        now_micros,
    );
}

pub fn renameSegmentFromForm(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    form: Form,
    now_micros: i64,
) !void {
    try metadata.renameSegment(
        allocator,
        try form.required("site"),
        try form.required("id"),
        try form.required("name"),
        now_micros,
    );
}

pub fn duplicateSegmentFromForm(
    allocator: std.mem.Allocator,
    io: std.Io,
    metadata: *meta.Store,
    form: Form,
    now_micros: i64,
) !void {
    const site = try form.required("site");
    const source = try metadata.segmentById(
        allocator,
        site,
        try form.required("id"),
    );
    _ = try analysis.parseExactCanonicalFilterJson(
        allocator,
        source.canonical_filter_json,
    );
    const id = try domain.randomUuid(io);
    try metadata.addSegment(
        allocator,
        &id,
        site,
        try form.required("name"),
        source.canonical_filter_json,
        now_micros,
    );
}

pub fn deleteSegmentFromForm(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    form: Form,
) !?AnalysisTarget {
    var target: ?AnalysisTarget = if (form.optional("state") != null)
        try analysisTargetFromForm(allocator, metadata, form)
    else
        null;
    const id = try form.required("id");
    try metadata.deleteSegment(
        allocator,
        try form.required("site"),
        id,
        try form.required("name"),
    );
    if (target) |*resolved| {
        if (resolved.query.analysis_segment_id) |selected| {
            if (std.mem.eql(u8, selected, id)) {
                setTargetSegment(&resolved.query, null);
            }
        }
    }
    return target;
}

pub fn createSavedViewFromForm(
    allocator: std.mem.Allocator,
    io: std.Io,
    metadata: *meta.Store,
    form: Form,
    now_micros: i64,
) !void {
    const target = try analysisTargetFromForm(allocator, metadata, form);
    try validateSavedTargetState(
        allocator,
        metadata,
        target.query.analysis_site_id,
        target.query,
    );
    const encoded = try savedViewJson(allocator, target);
    const id = try domain.randomUuid(io);
    try metadata.addSavedView(
        allocator,
        &id,
        target.query.site,
        try form.required("name"),
        encoded,
        now_micros,
    );
}

pub fn duplicateSavedViewFromForm(
    allocator: std.mem.Allocator,
    io: std.Io,
    metadata: *meta.Store,
    form: Form,
    now_micros: i64,
) !void {
    const site = try form.required("site");
    const source = try metadata.savedViewById(
        allocator,
        site,
        try form.required("id"),
    );
    _ = try loadSavedView(allocator, metadata, site, source.id);
    const id = try domain.randomUuid(io);
    try metadata.addSavedView(
        allocator,
        &id,
        site,
        try form.required("name"),
        source.canonical_query_json,
        now_micros,
    );
}

pub fn renameSavedViewFromForm(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    form: Form,
    now_micros: i64,
) !void {
    try metadata.renameSavedView(
        allocator,
        try form.required("site"),
        try form.required("id"),
        try form.required("name"),
        now_micros,
    );
}

pub fn deleteSavedViewFromForm(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    form: Form,
) !void {
    try metadata.deleteSavedView(
        allocator,
        try form.required("site"),
        try form.required("id"),
        try form.required("name"),
    );
}

pub fn loadSavedView(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    site_slug: []const u8,
    id: []const u8,
) !AnalysisTarget {
    const configuration = try metadata.siteConfigurationBySlug(
        allocator,
        site_slug,
    );
    const view = try metadata.savedViewById(allocator, site_slug, id);
    const parsed = try parseSavedViewJson(allocator, view.canonical_query_json);
    switch (parsed) {
        .trend => |set| {
            if (!std.mem.eql(u8, set.site_id, configuration.id)) {
                return error.StaleSavedViewSite;
            }
            const query = model.Query{
                .site = site_slug,
                .analysis_site_id = configuration.id,
                .range = set.range,
                .comparison = set.comparison,
                .analysis_interval = set.interval,
                .analysis_series = set.series,
                .analysis_filters = set.filters,
                .analysis_segment_id = set.segment_id,
            };
            try validateQuery(query);
            try validateSavedTargetState(
                allocator,
                metadata,
                configuration.id,
                query,
            );
            return .{ .destination = .analyze, .query = query };
        },
        .breakdown => |query| {
            if (!std.mem.eql(u8, query.site_id, configuration.id)) {
                return error.StaleSavedViewSite;
            }
            const finished = try finishBreakdownQuery(query, site_slug);
            try validateSavedTargetState(
                allocator,
                metadata,
                configuration.id,
                finished,
            );
            return .{
                .destination = .analyze,
                .query = finished,
            };
        },
    }
}

fn validateSavedTargetState(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
    site_id: []const u8,
    query: model.Query,
) !void {
    const policy = try metadata.sitePolicy(allocator, site_id);
    _ = try resolveFilters(
        allocator,
        metadata,
        policy,
        query.site,
        targetFilters(query),
        query.analysis_segment_id,
    );
    if (query.analysis_breakdown) |breakdown| {
        if (breakdown.metric.selector) |selector| {
            try validateSavedSelectorProperties(policy, selector);
            if (selector.kind == .saved_goal) _ = try metadata.goalById(
                allocator,
                query.site,
                selector.value,
            );
        }
    }
    for (query.analysis_series) |metric| {
        if (metric.selector) |selector| {
            try validateSavedSelectorProperties(policy, selector);
            if (selector.kind == .saved_goal) _ = try metadata.goalById(
                allocator,
                query.site,
                selector.value,
            );
        }
    }
}

fn validateSavedSelectorProperties(
    policy: meta.SitePolicy,
    selector: analysis.EventSelector,
) !void {
    for (selector.predicates) |predicate| {
        if (!policy.allowsProperty(predicate.property_ref.name)) {
            return error.StaleFilterProperty;
        }
    }
}

const SavedViewState = union(enum) {
    trend: analysis.TrendSet,
    breakdown: analysis.Query,
};

fn parseSavedViewJson(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) !SavedViewState {
    if (analysis.parseExactCanonicalTrendSetJson(allocator, encoded)) |set| {
        return .{ .trend = set };
    } else |_| {}
    const query = try analysis.parseExactCanonicalJson(allocator, encoded);
    if (query.mode != .breakdown) return error.InvalidSavedViewState;
    return .{ .breakdown = query };
}

fn savedViewJson(
    allocator: std.mem.Allocator,
    target: AnalysisTarget,
) ![]const u8 {
    if (target.destination != .analyze) return error.UnsupportedSavedViewSurface;
    if (target.query.analysis_breakdown) |query| {
        return analysis.canonicalJson(allocator, query);
    }
    return analysis.canonicalTrendSetJson(allocator, .{
        .site_id = target.query.analysis_site_id,
        .range = target.query.range,
        .comparison = target.query.comparison,
        .interval = target.query.analysis_interval,
        .series = target.query.analysis_series,
        .filters = target.query.analysis_filters,
        .segment_id = target.query.analysis_segment_id,
    });
}

fn clauseFromForm(
    allocator: std.mem.Allocator,
    form: Form,
) !analysis.Clause {
    const scalar_type = try analysis.ScalarType.parse(
        try form.required("scalar_type"),
    );
    const field_kind = try analysis.FieldKind.parse(try form.required("field"));
    const property_name = form.optional("property") orelse "";
    const field = analysis.Field{
        .kind = field_kind,
        .property_ref = if (field_kind.requiresProperty()) .{
            .name = property_name,
            .scalar_type = scalar_type,
        } else null,
    };
    if (!field_kind.requiresProperty() and property_name.len != 0) {
        return error.UnexpectedAnalysisProperty;
    }
    var values: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(
        u8,
        form.optional("values") orelse "",
        '\n',
    );
    while (lines.next()) |raw| {
        const value = std.mem.trim(u8, raw, " \t\r");
        if (value.len == 0) continue;
        if (values.items.len >= analysis.maximum_values) {
            return error.TooManyAnalysisValues;
        }
        try values.append(allocator, value);
    }
    const clause = analysis.Clause{
        .scope = try analysis.Scope.parse(try form.required("scope")),
        .field = field,
        .operator = try analysis.Operator.parse(try form.required("operator")),
        .scalar_type = scalar_type,
        .values = try values.toOwnedSlice(allocator),
    };
    try clause.validate();
    return clause;
}

fn targetFilters(query: model.Query) analysis.FilterSet {
    if (query.analysis_breakdown) |breakdown| return breakdown.filters;
    return query.analysis_filters;
}

fn setTargetFilters(query: *model.Query, filters: analysis.FilterSet) void {
    query.analysis_filters = filters;
    if (query.analysis_breakdown) |*breakdown| breakdown.filters = filters;
}

fn setTargetSegment(query: *model.Query, segment_id: ?[]const u8) void {
    query.analysis_segment_id = segment_id;
    if (query.analysis_breakdown) |*breakdown| breakdown.segment_id = segment_id;
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
        "goal-updated",
        "goal-duplicated",
        "goal-archived",
        "goal-reactivated",
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

test "goal management query fields remain screen specific" {
    const base = model.Query{
        .site = "example",
        .range = .{ .start = "2025-01-01", .end = "2025-01-02" },
        .kind = .goal,
        .goal_screen = .list,
    };
    try validateQuery(base);

    var invalid_list = base;
    invalid_list.goal_entity_set = true;
    try std.testing.expectError(
        error.InvalidGoalManagementState,
        validateQuery(invalid_list),
    );

    var valid_new = base;
    valid_new.goal_screen = .new;
    valid_new.goal_entity_set = true;
    valid_new.goal_entity_kind = .event;
    valid_new.goal_search = "signup";
    try validateQuery(valid_new);

    var invalid_new = valid_new;
    invalid_new.goal_page = 2;
    try std.testing.expectError(
        error.InvalidGoalManagementState,
        validateQuery(invalid_new),
    );

    var valid_detail = base;
    valid_detail.goal_screen = .detail;
    valid_detail.goal_id = "00000000-0000-4000-8000-000000000033";
    try validateQuery(valid_detail);

    var invalid_detail = valid_detail;
    invalid_detail.goal_entity_page = 2;
    try std.testing.expectError(
        error.InvalidGoalManagementState,
        validateQuery(invalid_detail),
    );
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

    const filtered = try finishQuery(
        try parseQuery(
            allocator,
            "/admin/sites/example/overview?v=1&from=2024-02-01&to=2024-02-29&compare=previous&metric=visitors&segment=00000000-0000-4000-8000-000000000030&f=event%7Epage%7Eis%7Estring%7E%252Fpricing",
            .overview,
        ),
        "example",
        &default_range,
        .previous,
    );
    try std.testing.expectEqualStrings(
        "00000000-0000-4000-8000-000000000030",
        filtered.analysis_segment_id.?,
    );
    try std.testing.expectEqualStrings(
        "/pricing",
        filtered.analysis_filters.clauses[0].values[0],
    );

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
        "/admin/sites/example/analyze?from=2025-01-01&to=2025-01-02&compare=none&interval=week&metric-1=event-visitors&event-1=signup&metric-2=average-value&goal-2=" ++ goal_id ++
            "&segment=" ++ goal_id ++
            "&f=event%7Epage%7Eis%7Estring%7E%252Fpricing",
    );
    try std.testing.expectEqual(@as(usize, 2), builder.series.len);
    try std.testing.expectEqual(analysis.MetricKind.event_visitors, builder.series[0].kind);
    try std.testing.expectEqual(analysis.MetricKind.average_value, builder.series[1].kind);
    try std.testing.expectEqualStrings(goal_id, builder.segment_id.?);
    try std.testing.expectEqual(@as(usize, 1), builder.filters.clauses.len);
    try std.testing.expectEqualStrings(
        "/pricing",
        builder.filters.clauses[0].values[0],
    );

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

test "Install query is closed canonical and session-bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const site = "00000000-0000-4000-8000-000000000020";
    const event = "00000000-0000-4000-8000-000000000021";
    const signature = try signInstallWatermark(
        site,
        "fixture-csrf",
        30,
        2,
        20,
        event,
    );
    const target = try std.fmt.allocPrint(
        allocator,
        "/admin/sites/example/install?started=30&count=2&after=20&event={s}&sig={s}&fragment=verification",
        .{ event, signature },
    );
    const parsed = (try parseInstallQuery(allocator, target)).?;
    try std.testing.expectEqual(@as(i64, 30), parsed.started_at_utc_micros);
    try std.testing.expectEqual(@as(i64, 2), parsed.event_count);
    try std.testing.expectEqual(@as(i64, 20), parsed.after_received_at_utc_micros);
    try std.testing.expectEqualStrings(event, parsed.after_event_id);
    try std.testing.expect(parsed.fragment);
    try verifyInstallWatermark(parsed, site, "fixture-csrf");
    try std.testing.expectError(
        error.InvalidInstallSignature,
        verifyInstallWatermark(
            parsed,
            "00000000-0000-4000-8000-000000000022",
            "fixture-csrf",
        ),
    );
    try std.testing.expectError(
        error.InvalidInstallSignature,
        verifyInstallWatermark(parsed, site, "rotated-csrf"),
    );

    var tampered = parsed;
    tampered.after_received_at_utc_micros += 1;
    try std.testing.expectError(
        error.InvalidInstallSignature,
        verifyInstallWatermark(tampered, site, "fixture-csrf"),
    );
    try std.testing.expectError(
        error.DuplicateInstallQueryField,
        parseInstallQuery(
            allocator,
            "/admin/sites/example/install?started=1&started=2&count=0&after=0&event=00000000-0000-0000-0000-000000000000&sig=0000000000000000000000000000000000000000000000000000000000000000",
        ),
    );
    try std.testing.expectError(
        error.InvalidInstallQuery,
        parseInstallQuery(
            allocator,
            "/admin/sites/example/install?started=&count=0&after=0&event=00000000-0000-0000-0000-000000000000&sig=0000000000000000000000000000000000000000000000000000000000000000",
        ),
    );
    try std.testing.expectError(
        error.UnknownInstallQueryField,
        parseInstallQuery(
            allocator,
            "/admin/sites/example/install?started=1&count=0&after=0&event=00000000-0000-0000-0000-000000000000&sig=0000000000000000000000000000000000000000000000000000000000000000&private=yes",
        ),
    );
}

test "Install rejection guidance covers origin property and payload corrections" {
    const cases = [_]struct {
        code: diagnostics.RejectionCode,
        category: []const u8,
    }{
        .{ .code = .origin_not_allowed, .category = "Origin not allowed" },
        .{ .code = .property_invalid, .category = "Invalid properties" },
        .{ .code = .payload_too_large, .category = "Invalid payload" },
    };
    for (cases) |case| {
        var summary = diagnostics.Summary.init(.v2, 1);
        summary.outcome = .rejected;
        summary.rejection_code = case.code;
        const guidance = installGuidance(summary).?;
        try std.testing.expectEqualStrings(case.category, guidance.category);
        try std.testing.expect(guidance.consequence.len != 0);
        try std.testing.expect(guidance.correction.len != 0);
    }
}

test "analysis form state applies filters and persists site-scoped segments and views" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const backing = std.testing.allocator;
    const path = try std.fmt.allocPrint(
        backing,
        ".zig-cache/tmp/{s}/meta.db",
        .{temporary.sub_path},
    );
    defer backing.free(path);
    var metadata = try meta.Store.open(backing, path);
    defer metadata.deinit();
    try metadata.migrate();
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();
    const site_id = "00000000-0000-4000-8000-000000000024";
    try metadata.addSite(
        allocator,
        site_id,
        "alpha",
        "Alpha",
        "https://alpha.example",
        "UTC",
        1,
    );
    try metadata.addProperty(allocator, "alpha", "plan");
    try metadata.addSite(
        allocator,
        "00000000-0000-4000-8000-000000000025",
        "beta",
        "Beta",
        "https://beta.example",
        "UTC",
        2,
    );

    const empty_state = try analysis.canonicalFilterJson(allocator, .{});
    const apply_fields = [_]Field{
        .{ .name = "site", .value = "alpha" },
        .{ .name = "state_kind", .value = "overview" },
        .{ .name = "state", .value = empty_state },
        .{ .name = "from", .value = "2026-01-01" },
        .{ .name = "to", .value = "2026-01-02" },
        .{ .name = "compare", .value = "previous" },
        .{ .name = "metric", .value = "visitors" },
        .{ .name = "segment", .value = "" },
        .{ .name = "scope", .value = "event" },
        .{ .name = "field", .value = "event-property" },
        .{ .name = "property", .value = "plan" },
        .{ .name = "scalar_type", .value = "string" },
        .{ .name = "operator", .value = "is" },
        .{ .name = "values", .value = "Pro\nEnterprise" },
    };
    const applied = try applyFilterFromForm(
        allocator,
        &metadata,
        .{ .fields = &apply_fields },
    );
    try std.testing.expectEqual(@as(usize, 1), applied.query.analysis_filters.clauses.len);
    try std.testing.expectEqual(@as(usize, 2), applied.query.analysis_filters.clauses[0].values.len);
    const filtered_state = try analysis.canonicalFilterJson(
        allocator,
        applied.query.analysis_filters,
    );
    const segment_fields = [_]Field{
        .{ .name = "site", .value = "alpha" },
        .{ .name = "state_kind", .value = "overview" },
        .{ .name = "state", .value = filtered_state },
        .{ .name = "from", .value = "2026-01-01" },
        .{ .name = "to", .value = "2026-01-02" },
        .{ .name = "compare", .value = "previous" },
        .{ .name = "metric", .value = "visitors" },
        .{ .name = "segment", .value = "" },
        .{ .name = "name", .value = "Paying plans" },
    };
    try createSegmentFromForm(
        allocator,
        std.testing.io,
        &metadata,
        .{ .fields = &segment_fields },
        10,
    );
    const segments = try metadata.listSegments(allocator, "alpha");
    try std.testing.expectEqual(@as(usize, 1), segments.len);
    const parsed_segment = try analysis.parseExactCanonicalFilterJson(
        allocator,
        segments[0].canonical_filter_json,
    );
    try std.testing.expect(analysis.filterSetsEqual(
        applied.query.analysis_filters,
        parsed_segment,
    ));

    const trend_series = [_]analysis.Metric{.{ .kind = .visitors }};
    const trend_state = try analysis.canonicalTrendSetJson(allocator, .{
        .site_id = site_id,
        .range = .{ .start = "2026-01-01", .end = "2026-01-02" },
        .comparison = .previous,
        .interval = .day,
        .series = &trend_series,
        .filters = applied.query.analysis_filters,
        .segment_id = segments[0].id,
    });
    const view_fields = [_]Field{
        .{ .name = "site", .value = "alpha" },
        .{ .name = "state_kind", .value = "trend" },
        .{ .name = "state", .value = trend_state },
        .{ .name = "name", .value = "Plan trend" },
    };
    try createSavedViewFromForm(
        allocator,
        std.testing.io,
        &metadata,
        .{ .fields = &view_fields },
        20,
    );
    const views = try metadata.listSavedViews(allocator, "alpha");
    try std.testing.expectEqual(@as(usize, 1), views.len);
    const loaded = try loadSavedView(
        allocator,
        &metadata,
        "alpha",
        views[0].id,
    );
    try std.testing.expectEqual(model.Destination.analyze, loaded.destination);
    try std.testing.expectEqualStrings(segments[0].id, loaded.query.analysis_segment_id.?);
    try std.testing.expect(analysis.filterSetsEqual(
        applied.query.analysis_filters,
        loaded.query.analysis_filters,
    ));
    const missing_goal_series = [_]analysis.Metric{.{
        .kind = .conversion_rate,
        .selector = .{
            .kind = .saved_goal,
            .value = "00000000-0000-4000-8000-000000000099",
        },
        .conversion_basis = .visitor,
    }};
    const missing_goal_state = try analysis.canonicalTrendSetJson(allocator, .{
        .site_id = site_id,
        .range = .{ .start = "2026-01-01", .end = "2026-01-02" },
        .comparison = .none,
        .interval = .day,
        .series = &missing_goal_series,
    });
    try metadata.addSavedView(
        allocator,
        "00000000-0000-4000-8000-000000000098",
        "alpha",
        "Removed goal",
        missing_goal_state,
        21,
    );
    try std.testing.expectError(
        error.GoalNotFound,
        loadSavedView(
            allocator,
            &metadata,
            "alpha",
            "00000000-0000-4000-8000-000000000098",
        ),
    );
    try std.testing.expectError(
        error.SavedViewNotFound,
        loadSavedView(allocator, &metadata, "beta", views[0].id),
    );
    const predicate_values = [_][]const u8{"Pro"};
    const selector_predicates = [_]analysis.PropertyPredicate{.{
        .property_ref = .{ .name = "plan", .scalar_type = .string },
        .operator = .is,
        .values = &predicate_values,
    }};
    const predicate_view_state = try analysis.canonicalJson(allocator, .{
        .site_id = site_id,
        .range = .{ .start = "2026-01-01", .end = "2026-01-02" },
        .mode = .breakdown,
        .metric = .{
            .kind = .event_count,
            .selector = .{
                .kind = .exact_event,
                .value = "purchase",
                .predicates = &selector_predicates,
            },
        },
        .dimension = .{ .kind = .event_name },
    });
    try metadata.addSavedView(
        allocator,
        "00000000-0000-4000-8000-000000000097",
        "alpha",
        "Predicate property",
        predicate_view_state,
        22,
    );
    _ = try loadSavedView(
        allocator,
        &metadata,
        "alpha",
        "00000000-0000-4000-8000-000000000097",
    );
    _ = try metadata.connection.execBatch(
        "DELETE FROM site_event_properties WHERE site_id = '" ++
            "00000000-0000-4000-8000-000000000024' AND property_name = 'plan'",
        .{},
    );
    const stale_policy = try metadata.sitePolicy(allocator, site_id);
    try std.testing.expectError(
        error.StaleFilterProperty,
        loadSavedView(allocator, &metadata, "alpha", views[0].id),
    );
    try std.testing.expectError(
        error.StaleFilterProperty,
        loadSavedView(
            allocator,
            &metadata,
            "alpha",
            "00000000-0000-4000-8000-000000000097",
        ),
    );
    try std.testing.expectError(
        error.StaleFilterProperty,
        resolveFilters(
            allocator,
            &metadata,
            stale_policy,
            "alpha",
            loaded.query.analysis_filters,
            loaded.query.analysis_segment_id,
        ),
    );
}
