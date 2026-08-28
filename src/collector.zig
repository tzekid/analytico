const std = @import("std");
const domain = @import("domain.zig");
const store_mod = @import("store.zig");

pub const maximum_body_bytes = 8 * 1024;
pub const maximum_records = 16;

pub const Envelope = struct {
    v: u8,
    site: []const u8,
    sent_at_ms: i64,
    records: []const Record,
};

pub const Record = struct {
    event_id: []const u8,
    type: []const u8,
    page_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    occurred_at_ms: i64,
    tracking_mode: []const u8,
    consent_mode: []const u8,
    tracker_version: []const u8,
    release_id: []const u8,
    internal: bool,

    path: ?[]const u8 = null,
    page_type: ?[]const u8 = null,
    content_id: ?[]const u8 = null,
    referrer_host: ?[]const u8 = null,
    utm_source: ?[]const u8 = null,
    utm_medium: ?[]const u8 = null,
    utm_campaign: ?[]const u8 = null,
    utm_content: ?[]const u8 = null,
    utm_term: ?[]const u8 = null,
    navigation_type: ?[]const u8 = null,
    viewport_class: ?[]const u8 = null,
    language: ?[]const u8 = null,

    visible_ms: ?i64 = null,
    active_ms: ?i64 = null,
    first_interaction_ms: ?i64 = null,
    interaction_count: ?i64 = null,
    max_scroll: ?i64 = null,
    sections: ?[]const []const u8 = null,
    last_section: ?[]const u8 = null,
    selection_count: ?i64 = null,
    copy_count: ?i64 = null,
    outbound_clicks: ?i64 = null,
    downloads: ?i64 = null,
    form_attempts: ?i64 = null,
    ttfb_ms: ?i64 = null,
    fcp_ms: ?i64 = null,
    lcp_ms: ?i64 = null,
    inp_ms: ?i64 = null,
    cls_milli: ?i64 = null,
    long_frame_count: ?i64 = null,
    blocking_ms: ?i64 = null,

    name: ?[]const u8 = null,
    value_minor: ?i64 = null,
    currency: ?[]const u8 = null,
    properties: ?std.json.Value = null,
};

pub const Client = struct {
    peer_ip: []const u8,
    user_agent: []const u8,
};

pub const Result = struct {
    accepted: usize = 0,
    duplicates: usize = 0,
    late: usize = 0,
};

pub const Source = enum { browser, server };

pub fn parse(allocator: std.mem.Allocator, body: []const u8) !Envelope {
    if (body.len == 0 or body.len > maximum_body_bytes) return error.InvalidBodySize;
    if (!std.unicode.utf8ValidateSlice(body)) return error.InvalidUtf8;
    const raw = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = maximum_body_bytes,
    }) catch return error.InvalidJson;
    try validateFieldSets(raw);
    const envelope = std.json.parseFromSliceLeaky(Envelope, allocator, body, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .max_value_len = maximum_body_bytes,
    }) catch return error.InvalidJson;
    if (envelope.v != 1) return error.UnsupportedProtocol;
    try domain.validateUuid(envelope.site);
    if (envelope.records.len == 0 or envelope.records.len > maximum_records) return error.InvalidRecordCount;
    return envelope;
}

fn validateFieldSets(raw: std.json.Value) !void {
    const envelope = switch (raw) {
        .object => |object| object,
        else => return error.InvalidJson,
    };
    var envelope_iterator = envelope.iterator();
    while (envelope_iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!(std.mem.eql(u8, key, "v") or std.mem.eql(u8, key, "site") or
            std.mem.eql(u8, key, "sent_at_ms") or std.mem.eql(u8, key, "records")))
        {
            return error.UnknownEnvelopeField;
        }
    }
    const records_value = envelope.get("records") orelse return error.InvalidJson;
    const records = switch (records_value) {
        .array => |array| array,
        else => return error.InvalidJson,
    };
    for (records.items) |item| {
        const object = switch (item) {
            .object => |value| value,
            else => return error.InvalidJson,
        };
        const type_value = object.get("type") orelse return error.InvalidJson;
        const kind = switch (type_value) {
            .string => |value| value,
            else => return error.InvalidJson,
        };
        var iterator = object.iterator();
        while (iterator.next()) |entry| if (!fieldAllowed(kind, entry.key_ptr.*)) return error.UnexpectedRecordFields;
    }
}

fn fieldAllowed(kind: []const u8, key: []const u8) bool {
    inline for (.{
        "event_id",     "type",            "page_id",    "session_id", "occurred_at_ms", "tracking_mode",
        "consent_mode", "tracker_version", "release_id", "internal",
    }) |common| if (std.mem.eql(u8, key, common)) return true;
    if (std.mem.eql(u8, kind, "page_view")) {
        inline for (.{
            "path",         "page_type",   "content_id", "referrer_host",   "utm_source",     "utm_medium",
            "utm_campaign", "utm_content", "utm_term",   "navigation_type", "viewport_class", "language",
        }) |field| if (std.mem.eql(u8, key, field)) return true;
        return false;
    }
    if (std.mem.eql(u8, kind, "page_summary")) {
        inline for (.{
            "visible_ms", "active_ms",     "first_interaction_ms", "interaction_count", "max_scroll",
            "sections",   "last_section",  "selection_count",      "copy_count",        "outbound_clicks",
            "downloads",  "form_attempts", "ttfb_ms",              "fcp_ms",            "lcp_ms",
            "inp_ms",     "cls_milli",     "long_frame_count",     "blocking_ms",
        }) |field| if (std.mem.eql(u8, key, field)) return true;
        return false;
    }
    if (std.mem.eql(u8, kind, "event")) {
        inline for (.{ "path", "name", "value_minor", "currency", "properties" }) |field| {
            if (std.mem.eql(u8, key, field)) return true;
        }
    }
    return false;
}

pub fn ingest(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    master_key: [32]u8,
    site: store_mod.Site,
    envelope: Envelope,
    source: Source,
    client: Client,
) !Result {
    if (!site.enabled) return error.SiteDisabled;
    const received_at_ms = try domain.nowMilliseconds();
    if (envelope.sent_at_ms > received_at_ms + 5 * 60 * 1000 or
        envelope.sent_at_ms < received_at_ms - 90 * 24 * 60 * 60 * 1000) return error.InvalidSentAt;
    const date = try domain.utcDate(received_at_ms);
    var dimensions: Dimensions = undefined;
    var visitor_id: [16]u8 = undefined;
    if (source == .browser) {
        dimensions = classify(client.user_agent);
        var coarse_buffer: [96]u8 = undefined;
        const coarse = try std.fmt.bufPrint(&coarse_buffer, "{s}/{s}/{s}", .{
            dimensions.browser, dimensions.operating_system, dimensions.device,
        });
        visitor_id = domain.visitorDayId(master_key, site.public_id, &date, client.peer_ip, coarse);
    }

    try store.database.exec("BEGIN IMMEDIATE");
    errdefer store.database.exec("ROLLBACK") catch {};
    var result = Result{};
    for (envelope.records) |record| {
        try validateRecord(allocator, record, site.mode, source, received_at_ms);
        const digest = try recordHash(allocator, record);
        const receipt = try receiptState(allocator, store, site.id, record.event_id, &digest);
        switch (receipt) {
            .duplicate => {
                result.duplicates += 1;
                continue;
            },
            .conflict => return error.EventIdConflict,
            .new => {},
        }
        if (received_at_ms - record.occurred_at_ms > 24 * 60 * 60 * 1000) result.late += 1;
        if (std.mem.eql(u8, record.type, "page_view")) {
            try insertPageView(allocator, store, site, record, received_at_ms, &date, &visitor_id, dimensions);
        } else if (std.mem.eql(u8, record.type, "page_summary")) {
            try insertPageSummary(allocator, store, site, record, received_at_ms);
        } else {
            try insertEvent(allocator, store, site, record, source, received_at_ms, &date);
        }
        try insertReceipt(allocator, store, site.id, record, &digest, received_at_ms);
        result.accepted += 1;
    }
    try incrementCounter(allocator, store, "accepted_records", @intCast(result.accepted));
    try incrementCounter(allocator, store, "duplicate_records", @intCast(result.duplicates));
    try incrementCounter(allocator, store, "late_events", @intCast(result.late));
    try store.database.exec("COMMIT");
    return result;
}

const ReceiptState = enum { new, duplicate, conflict };

fn receiptState(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    site_id: i64,
    event_id: []const u8,
    digest: []const u8,
) !ReceiptState {
    var statement = try store.database.prepare(allocator, "SELECT payload_hash FROM record_receipts WHERE site_id=? AND event_id=?");
    defer statement.deinit();
    try statement.bindInt(1, site_id);
    try statement.bindText(2, event_id);
    if (try statement.step() == .done) return .new;
    return if (std.mem.eql(u8, statement.columnText(0), digest)) .duplicate else .conflict;
}

fn insertReceipt(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    site_id: i64,
    record: Record,
    digest: []const u8,
    received_at_ms: i64,
) !void {
    var statement = try store.database.prepare(allocator, "INSERT INTO record_receipts(site_id,event_id,payload_hash,record_kind,received_at_ms) VALUES(?,?,?,?,?)");
    defer statement.deinit();
    try statement.bindInt(1, site_id);
    try statement.bindText(2, record.event_id);
    try statement.bindText(3, digest);
    try statement.bindText(4, record.type);
    try statement.bindInt(5, received_at_ms);
    _ = try statement.step();
}

const Dimensions = struct {
    browser: []const u8,
    operating_system: []const u8,
    device: []const u8,
    traffic_class: []const u8,
};

fn classify(user_agent: []const u8) Dimensions {
    const monitor = containsIgnoreCase(user_agent, "monitor") or containsIgnoreCase(user_agent, "uptime") or containsIgnoreCase(user_agent, "statuscake");
    const bot = containsIgnoreCase(user_agent, "bot") or containsIgnoreCase(user_agent, "crawler") or
        containsIgnoreCase(user_agent, "spider") or containsIgnoreCase(user_agent, "headless") or
        containsIgnoreCase(user_agent, "slurp");
    const browser = if (containsIgnoreCase(user_agent, "edg/")) "edge" else if (containsIgnoreCase(user_agent, "firefox/")) "firefox" else if (containsIgnoreCase(user_agent, "chrome/") or containsIgnoreCase(user_agent, "crios/")) "chrome" else if (containsIgnoreCase(user_agent, "safari/")) "safari" else "unknown";
    const os = if (containsIgnoreCase(user_agent, "android")) "android" else if (containsIgnoreCase(user_agent, "iphone") or containsIgnoreCase(user_agent, "ipad")) "ios" else if (containsIgnoreCase(user_agent, "windows")) "windows" else if (containsIgnoreCase(user_agent, "mac os")) "macos" else if (containsIgnoreCase(user_agent, "linux")) "linux" else "unknown";
    const device = if (containsIgnoreCase(user_agent, "mobile") or containsIgnoreCase(user_agent, "iphone") or containsIgnoreCase(user_agent, "android")) "mobile" else if (user_agent.len == 0) "unknown" else "desktop";
    return .{
        .browser = browser,
        .operating_system = os,
        .device = device,
        .traffic_class = if (monitor) "monitor" else if (bot) "known_bot" else if (user_agent.len == 0) "unknown" else "human_like",
    };
}

fn insertPageView(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    site: store_mod.Site,
    record: Record,
    received_at_ms: i64,
    date: []const u8,
    visitor_id: []const u8,
    dimensions: Dimensions,
) !void {
    const referrer_host = if (record.referrer_host) |host| try lowercaseAscii(allocator, host) else null;
    var statement = try store.database.prepare(allocator, "INSERT INTO page_views VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)");
    defer statement.deinit();
    try statement.bindInt(1, site.id);
    try statement.bindText(2, record.event_id);
    try statement.bindText(3, record.page_id.?);
    try statement.bindOptionalText(4, record.session_id);
    try statement.bindInt(5, record.occurred_at_ms);
    try statement.bindInt(6, received_at_ms);
    try statement.bindText(7, date);
    try statement.bindText(8, visitor_id);
    try statement.bindText(9, record.tracking_mode);
    try statement.bindText(10, record.path.?);
    try statement.bindOptionalText(11, record.page_type);
    try statement.bindOptionalText(12, record.content_id);
    try statement.bindOptionalText(13, referrer_host);
    try statement.bindOptionalText(14, record.utm_source);
    try statement.bindOptionalText(15, record.utm_medium);
    try statement.bindOptionalText(16, record.utm_campaign);
    try statement.bindOptionalText(17, record.utm_content);
    try statement.bindOptionalText(18, record.utm_term);
    try statement.bindOptionalText(19, record.navigation_type);
    try statement.bindOptionalText(20, record.viewport_class);
    try statement.bindOptionalText(21, record.language);
    try statement.bindOptionalText(22, optionalNonEmpty(record.release_id));
    try statement.bindText(23, record.tracker_version);
    try statement.bindText(24, record.consent_mode);
    try statement.bindBool(25, record.internal);
    try statement.bindNull(26);
    try statement.bindText(27, dimensions.browser);
    try statement.bindText(28, dimensions.operating_system);
    try statement.bindText(29, dimensions.device);
    try statement.bindText(30, if (record.internal) "internal" else dimensions.traffic_class);
    _ = try statement.step();
}

fn insertPageSummary(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    site: store_mod.Site,
    record: Record,
    received_at_ms: i64,
) !void {
    const sections_json = try canonicalSections(allocator, record.sections.?);
    var statement = try store.database.prepare(allocator, "INSERT INTO page_summaries VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)");
    defer statement.deinit();
    try statement.bindInt(1, site.id);
    try statement.bindText(2, record.event_id);
    try statement.bindText(3, record.page_id.?);
    try statement.bindOptionalText(4, record.session_id);
    try statement.bindInt(5, record.occurred_at_ms);
    try statement.bindInt(6, received_at_ms);
    try statement.bindText(7, record.tracking_mode);
    try statement.bindInt(8, record.visible_ms.?);
    try statement.bindInt(9, record.active_ms.?);
    try statement.bindOptionalInt(10, record.first_interaction_ms);
    try statement.bindInt(11, record.interaction_count.?);
    try statement.bindInt(12, record.max_scroll.?);
    try statement.bindText(13, sections_json);
    try statement.bindOptionalText(14, record.last_section);
    try statement.bindInt(15, record.selection_count.?);
    try statement.bindInt(16, record.copy_count.?);
    try statement.bindInt(17, record.outbound_clicks.?);
    try statement.bindInt(18, record.downloads.?);
    try statement.bindInt(19, record.form_attempts.?);
    try statement.bindOptionalInt(20, record.ttfb_ms);
    try statement.bindOptionalInt(21, record.fcp_ms);
    try statement.bindOptionalInt(22, record.lcp_ms);
    try statement.bindOptionalInt(23, record.inp_ms);
    try statement.bindOptionalInt(24, record.cls_milli);
    try statement.bindOptionalInt(25, record.long_frame_count);
    try statement.bindOptionalInt(26, record.blocking_ms);
    try statement.bindText(27, record.tracker_version);
    try statement.bindText(28, record.consent_mode);
    try statement.bindOptionalText(29, optionalNonEmpty(record.release_id));
    try statement.bindBool(30, record.internal);
    _ = try statement.step();
}

fn insertEvent(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    site: store_mod.Site,
    record: Record,
    source: Source,
    received_at_ms: i64,
    date: []const u8,
) !void {
    const properties = try canonicalProperties(allocator, record.properties);
    var statement = try store.database.prepare(allocator, "INSERT INTO events VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)");
    defer statement.deinit();
    try statement.bindInt(1, site.id);
    try statement.bindText(2, record.event_id);
    try statement.bindOptionalText(3, record.page_id);
    try statement.bindOptionalText(4, record.session_id);
    try statement.bindText(5, @tagName(source));
    try statement.bindInt(6, record.occurred_at_ms);
    try statement.bindInt(7, received_at_ms);
    try statement.bindText(8, date);
    try statement.bindText(9, record.tracking_mode);
    try statement.bindText(10, record.name.?);
    try statement.bindOptionalText(11, record.path);
    try statement.bindOptionalText(12, optionalNonEmpty(record.release_id));
    try statement.bindText(13, record.tracker_version);
    try statement.bindText(14, record.consent_mode);
    try statement.bindBool(15, record.internal);
    try statement.bindOptionalInt(16, record.value_minor);
    try statement.bindOptionalText(17, record.currency);
    try statement.bindText(18, properties);
    _ = try statement.step();
}

fn validateRecord(
    allocator: std.mem.Allocator,
    record: Record,
    mode: domain.Mode,
    source: Source,
    received_at_ms: i64,
) !void {
    try domain.validateUuid(record.event_id);
    try domain.validateName(record.type);
    if (!std.mem.eql(u8, record.tracking_mode, domain.modeName(mode))) return error.TrackingModeMismatch;
    try validateText(record.consent_mode, 32, false);
    try validateText(record.tracker_version, 32, false);
    try validateText(record.release_id, 64, true);
    if (record.occurred_at_ms > received_at_ms + 5 * 60 * 1000 or
        record.occurred_at_ms < received_at_ms - 90 * 24 * 60 * 60 * 1000) return error.InvalidOccurredAt;
    if (mode == .session and source == .browser) {
        try domain.validateUuid(record.session_id orelse return error.MissingSessionId);
    } else if (record.session_id) |session_id| {
        if (mode == .lite) return error.SessionForbidden;
        try domain.validateUuid(session_id);
    }

    if (std.mem.eql(u8, record.type, "page_view")) {
        if (source != .browser) return error.InvalidInternalRecordType;
        try domain.validateUuid(record.page_id orelse return error.MissingPageId);
        try domain.validatePath(record.path orelse return error.MissingPath);
        try validateOptionalText(record.page_type, 64);
        try validateOptionalText(record.content_id, 128);
        if (record.referrer_host) |host| try validateReferrerHost(host);
        inline for (.{ record.utm_source, record.utm_medium, record.utm_campaign, record.utm_content, record.utm_term }) |value| try validateOptionalText(value, 128);
        try validateOptionalText(record.navigation_type, 24);
        try validateOptionalText(record.viewport_class, 24);
        try validateOptionalText(record.language, 32);
        if (record.name != null or record.visible_ms != null) return error.UnexpectedRecordFields;
        return;
    }
    if (std.mem.eql(u8, record.type, "page_summary")) {
        if (source != .browser) return error.InvalidInternalRecordType;
        try domain.validateUuid(record.page_id orelse return error.MissingPageId);
        if (record.visible_ms == null or record.active_ms == null or record.interaction_count == null or
            record.max_scroll == null or record.sections == null or record.selection_count == null or
            record.copy_count == null or record.outbound_clicks == null or record.downloads == null or
            record.form_attempts == null) return error.MissingSummaryField;
        try bounded(record.visible_ms.?, 0, 86_400_000);
        try bounded(record.active_ms.?, 0, 86_400_000);
        try bounded(record.interaction_count.?, 0, 10_000);
        try bounded(record.max_scroll.?, 0, 100);
        inline for (.{ record.selection_count.?, record.copy_count.?, record.outbound_clicks.?, record.downloads.?, record.form_attempts.? }) |value| try bounded(value, 0, 10_000);
        try validateMetric(record.first_interaction_ms, 86_400_000);
        inline for (.{ record.ttfb_ms, record.fcp_ms, record.lcp_ms, record.inp_ms, record.blocking_ms }) |value| try validateMetric(value, 600_000);
        try validateMetric(record.cls_milli, 100_000);
        try validateMetric(record.long_frame_count, 100_000);
        if (record.sections.?.len > 32) return error.TooManySections;
        for (record.sections.?) |section| try domain.validateName(section);
        try validateOptionalText(record.last_section, 64);
        if (record.name != null or record.path != null) return error.UnexpectedRecordFields;
        return;
    }
    if (!std.mem.eql(u8, record.type, "event")) return error.UnknownRecordType;
    const name = record.name orelse return error.MissingEventName;
    try domain.validateName(name);
    if (source == .browser and authoritative(name)) return error.AuthoritativeEventRequired;
    if (source == .server and record.page_id != null) return error.ServerPageIdForbidden;
    if (record.page_id) |page_id| try domain.validateUuid(page_id);
    if (record.path) |path| try domain.validatePath(path);
    if ((record.value_minor == null) != (record.currency == null)) return error.InvalidMoney;
    if (record.currency) |currency| {
        if (currency.len != 3) return error.InvalidCurrency;
        for (currency) |byte| if (!std.ascii.isUpper(byte)) return error.InvalidCurrency;
    }
    _ = try canonicalProperties(allocator, record.properties);
}

fn authoritative(name: []const u8) bool {
    inline for (.{
        "registration_confirmed", "payment_confirmed", "payment_refunded",        "refund_confirmed",
        "attendance_confirmed",   "match_created",     "registration_waitlisted", "registration_cancelled",
    }) |item| if (std.mem.eql(u8, name, item)) return true;
    return false;
}

fn recordHash(allocator: std.mem.Allocator, record: Record) ![64]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try std.json.Stringify.value(record, .{}, &writer.writer);
    return domain.payloadHash(writer.writer.buffered());
}

fn canonicalProperties(allocator: std.mem.Allocator, optional: ?std.json.Value) ![]const u8 {
    const value = optional orelse return "{}";
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidProperties,
    };
    if (object.count() > 8) return error.TooManyProperties;
    var keys: std.ArrayList([]const u8) = .empty;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        try domain.validateName(entry.key_ptr.*);
        switch (entry.value_ptr.*) {
            .null, .bool, .integer => {},
            .string => |text| try validateText(text, 256, true),
            else => return error.InvalidPropertyValue,
        }
        try keys.append(allocator, entry.key_ptr.*);
    }
    std.mem.sortUnstable([]const u8, keys.items, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.less);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    try writer.writer.writeByte('{');
    for (keys.items, 0..) |key, index| {
        if (index != 0) try writer.writer.writeByte(',');
        try std.json.Stringify.value(key, .{}, &writer.writer);
        try writer.writer.writeByte(':');
        try std.json.Stringify.value(object.get(key).?, .{}, &writer.writer);
    }
    try writer.writer.writeByte('}');
    if (writer.writer.buffered().len > 2048) return error.PropertiesTooLarge;
    return writer.toOwnedSlice();
}

fn canonicalSections(allocator: std.mem.Allocator, sections: []const []const u8) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(sections, .{}, &writer.writer);
    return writer.toOwnedSlice();
}

fn incrementCounter(allocator: std.mem.Allocator, store: *store_mod.Store, name: []const u8, amount: i64) !void {
    if (amount == 0) return;
    var statement = try store.database.prepare(allocator, "INSERT INTO ingest_counters(name,value) VALUES(?,?) ON CONFLICT(name) DO UPDATE SET value=value+excluded.value");
    defer statement.deinit();
    try statement.bindText(1, name);
    try statement.bindInt(2, amount);
    _ = try statement.step();
}

fn validateText(value: []const u8, maximum: usize, allow_empty: bool) !void {
    if ((!allow_empty and value.len == 0) or value.len > maximum or !std.unicode.utf8ValidateSlice(value)) return error.InvalidText;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidText;
}

fn validateOptionalText(value: ?[]const u8, maximum: usize) !void {
    if (value) |text| try validateText(text, maximum, true);
}

fn validateReferrerHost(value: []const u8) !void {
    try validateText(value, 253, false);
    if (std.mem.findAny(u8, value, "/?#@") != null) return error.InvalidReferrerHost;
}

fn bounded(value: i64, minimum: i64, maximum: i64) !void {
    if (value < minimum or value > maximum) return error.MetricOutOfRange;
}

fn validateMetric(value: ?i64, maximum: i64) !void {
    if (value) |integer| try bounded(integer, 0, maximum);
}

fn optionalNonEmpty(value: []const u8) ?[]const u8 {
    return if (value.len == 0) null else value;
}

fn lowercaseAscii(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, value.len);
    for (value, 0..) |byte, index| out[index] = std.ascii.toLower(byte);
    return out;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

pub fn verifySignature(secret: [32]u8, timestamp_text: []const u8, signature_text: []const u8, body: []const u8) !void {
    const timestamp = std.fmt.parseInt(i64, timestamp_text, 10) catch return error.InvalidSignatureTimestamp;
    const now = try domain.nowSeconds();
    if (timestamp < now - 300 or timestamp > now + 300) return error.StaleSignature;
    if (signature_text.len != 64) return error.InvalidSignature;
    var candidate: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&candidate, signature_text) catch return error.InvalidSignature;
    var writer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer writer.deinit();
    try writer.writer.print("{d}.", .{timestamp});
    try writer.writer.writeAll(body);
    var expected: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&expected, writer.writer.buffered(), &secret);
    if (!std.crypto.timing_safe.eql([32]u8, expected, candidate)) return error.InvalidSignature;
}
