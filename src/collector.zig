const std = @import("std");
const domain = @import("domain.zig");
const geo = @import("geo.zig");
const store_mod = @import("store.zig");

pub const maximum_body_bytes = 8 * 1024;
pub const maximum_records = 16;

pub const Envelope = struct {
    v: u8,
    site: []const u8,
    sent_at_ms: i64,
    records: []const Record,
};

pub const Item = struct {
    id: []const u8,
    name: []const u8,
    category: ?[]const u8 = null,
    price_minor: ?i64 = null,
    quantity: i64 = 1,
};

/// Clicks on one element, bucketed to a 5% grid inside the element.
pub const Click = struct {
    el: []const u8,
    x: i64,
    y: i64,
    n: i64 = 1,
    rage: i64 = 0,
};

/// Interaction with one form field. Never carries what was typed.
pub const FormField = struct {
    form: []const u8,
    field: []const u8,
    ms: i64 = 0,
    errors: i64 = 0,
    abandoned: bool = false,
    submitted: bool = false,
};

pub const Record = struct {
    event_id: []const u8,
    type: []const u8,
    page_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    visitor_id: ?[]const u8 = null,
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
    search_term: ?[]const u8 = null,
    search_results: ?i64 = null,
    click_id: ?[]const u8 = null,
    link: ?[]const u8 = null,

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
    clicks: ?[]const Click = null,
    attention: ?[]const i64 = null,
    form_fields: ?[]const FormField = null,

    name: ?[]const u8 = null,
    value_minor: ?i64 = null,
    currency: ?[]const u8 = null,
    properties: ?std.json.Value = null,
    order_id: ?[]const u8 = null,
    items: ?[]const Item = null,
    user_id: ?[]const u8 = null,

    state: ?[]const u8 = null,

    message: ?[]const u8 = null,
    file: ?[]const u8 = null,
    line: ?i64 = null,
    column: ?i64 = null,
};

/// The referrer stored for a page reached from the site itself.
pub const self_referrer = "(self)";

pub const Client = struct {
    peer_ip: []const u8,
    user_agent: []const u8,
    /// `Sec-GPC: 1`: the visitor stays in Lite whatever the tracker says.
    gpc: bool = false,
    /// Host of the page that sent the batch, from its validated Origin.
    page_host: []const u8 = "",
    place: ?geo.Place = null,
};

/// What a Full-mode visitor may become on this request.
pub const Decision = enum { grant, ask, never };

pub fn decide(site: store_mod.Site, client: Client) Decision {
    if (client.gpc) return .never;
    return switch (site.consent_policy) {
        .none => .grant,
        .everyone => .ask,
        .regional => if (geo.consentRegion(if (client.place) |place| place.country else null)) .ask else .grant,
    };
}

pub const Identity = struct { visitor_id: []const u8, session_id: []const u8 };

pub const Result = struct {
    accepted: usize = 0,
    duplicates: usize = 0,
    late: usize = 0,
    decision: Decision = .ask,
    /// The consented identity the batch ended with, if any.
    identity: ?Identity = null,
    /// A consented identity was removed by the server (GPC, consent required).
    dropped: bool = false,
    /// Visitors erased on request; their replays are removed after commit.
    forgotten: std.ArrayList([]const u8) = .empty,
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
    if (envelope.v != 1 and envelope.v != 2) return error.UnsupportedProtocol;
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
    const version: i64 = switch (envelope.get("v") orelse return error.InvalidJson) {
        .integer => |value| value,
        else => return error.InvalidJson,
    };
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
        while (iterator.next()) |entry| if (!fieldAllowed(kind, entry.key_ptr.*, version >= 2)) return error.UnexpectedRecordFields;
    }
}

fn oneOf(key: []const u8, comptime names: anytype) bool {
    inline for (names) |name| if (std.mem.eql(u8, key, name)) return true;
    return false;
}

fn fieldAllowed(kind: []const u8, key: []const u8, v2: bool) bool {
    if (oneOf(key, .{ "event_id", "type", "page_id", "session_id", "occurred_at_ms", "tracking_mode", "consent_mode", "tracker_version", "release_id", "internal" })) return true;
    if (v2 and std.mem.eql(u8, key, "visitor_id")) return true;
    if (std.mem.eql(u8, kind, "page_view")) {
        if (oneOf(key, .{ "path", "page_type", "content_id", "referrer_host", "utm_source", "utm_medium", "utm_campaign", "utm_content", "utm_term", "navigation_type", "viewport_class", "language" })) return true;
        return v2 and oneOf(key, .{ "search_term", "search_results", "click_id", "link" });
    }
    if (std.mem.eql(u8, kind, "page_summary")) {
        if (oneOf(key, .{
            "visible_ms", "active_ms",     "first_interaction_ms", "interaction_count", "max_scroll",
            "sections",   "last_section",  "selection_count",      "copy_count",        "outbound_clicks",
            "downloads",  "form_attempts", "ttfb_ms",              "fcp_ms",            "lcp_ms",
            "inp_ms",     "cls_milli",     "long_frame_count",     "blocking_ms",
        })) return true;
        return v2 and oneOf(key, .{ "clicks", "attention", "form_fields" });
    }
    if (std.mem.eql(u8, kind, "event")) {
        if (oneOf(key, .{ "path", "name", "value_minor", "currency", "properties" })) return true;
        return v2 and oneOf(key, .{ "order_id", "items", "user_id" });
    }
    if (!v2) return false;
    if (std.mem.eql(u8, kind, "consent")) return std.mem.eql(u8, key, "state");
    if (std.mem.eql(u8, kind, "error")) return oneOf(key, .{ "path", "message", "file", "line", "column" });
    if (std.mem.eql(u8, kind, "identify") or std.mem.eql(u8, kind, "forget")) return std.mem.eql(u8, key, "user_id");
    return false;
}

/// Stores one batch. Runs inside the caller's transaction (the server's
/// group commit), which rolls the whole batch back on error.
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
    const received_at_ms = domain.nowMs();
    if (envelope.sent_at_ms > received_at_ms + 5 * 60 * 1000 or
        envelope.sent_at_ms < received_at_ms - 90 * 24 * 60 * 60 * 1000) return error.InvalidSentAt;
    const date = try domain.utcDate(received_at_ms);
    var dimensions: Dimensions = undefined;
    var visitor_day: [16]u8 = undefined;
    if (source == .browser) {
        dimensions = classify(client.user_agent);
        var coarse_buffer: [96]u8 = undefined;
        const coarse = try std.fmt.bufPrint(&coarse_buffer, "{s}/{s}/{s}", .{
            dimensions.browser, dimensions.operating_system, dimensions.device,
        });
        visitor_day = domain.visitorDayId(master_key, site.public_id, &date, client.peer_ip, coarse);
    }
    const context: Context = .{
        .allocator = allocator,
        .store = store,
        .master_key = master_key,
        .site = site,
        .source = source,
        .client = client,
        .received_at_ms = received_at_ms,
        .date = &date,
        .visitor_day = &visitor_day,
        .dimensions = dimensions,
    };

    var result = Result{ .decision = decide(site, client) };
    for (envelope.records) |original| {
        if (envelope.v == 1 and !std.mem.eql(u8, original.type, "page_view") and
            !std.mem.eql(u8, original.type, "page_summary") and !std.mem.eql(u8, original.type, "event")) return error.UnknownRecordType;
        const digest = try recordHash(allocator, original);
        var record = original;
        if (site.mode == .full and source == .browser) {
            if (try enforceConsent(&record, result.decision, client.gpc)) result.dropped = true;
            // A visit continued from another of the site's domains must carry
            // a valid link for the identity it claims.
            if (record.link) |token| if (!linkMatches(master_key, site.public_id, record, token, received_at_ms)) {
                strip(&record, false);
                result.dropped = true;
            };
        }
        try validateRecord(allocator, record, site.mode, source, received_at_ms);
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
        const kind = record.type;
        if (std.mem.eql(u8, kind, "page_view")) {
            try insertPageView(context, record);
        } else if (std.mem.eql(u8, kind, "page_summary")) {
            try insertPageSummary(context, record);
        } else if (std.mem.eql(u8, kind, "event")) {
            try insertEvent(context, record);
        } else if (std.mem.eql(u8, kind, "consent")) {
            try applyConsent(context, record);
        } else if (std.mem.eql(u8, kind, "error")) {
            try insertError(context, record);
        } else if (std.mem.eql(u8, kind, "identify")) {
            if (record.visitor_id != null) try applyIdentify(context, record);
        } else if (std.mem.eql(u8, kind, "forget")) {
            if (record.visitor_id) |visitor_id| {
                try forgetVisitor(allocator, store, site.id, visitor_id);
                try result.forgotten.append(allocator, visitor_id);
            }
            if (record.user_id) |user_id| {
                const hash = domain.userHash(master_key, site.public_id, user_id);
                for (try forgetUser(allocator, store, site.id, &hash)) |visitor_id| try result.forgotten.append(allocator, visitor_id);
            }
        } else unreachable;
        if (record.visitor_id) |visitor_id| if (record.session_id) |session_id| {
            if (!std.mem.eql(u8, kind, "forget") and !(std.mem.eql(u8, kind, "consent") and std.mem.eql(u8, record.state.?, "denied"))) {
                result.identity = .{ .visitor_id = visitor_id, .session_id = session_id };
            }
        };
        try insertReceipt(allocator, store, site.id, record, &digest, received_at_ms);
        result.accepted += 1;
    }
    try incrementCounter(allocator, store, "accepted_records", @intCast(result.accepted));
    try incrementCounter(allocator, store, "duplicate_records", @intCast(result.duplicates));
    try incrementCounter(allocator, store, "late_events", @intCast(result.late));
    return result;
}

const Context = struct {
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    master_key: [32]u8,
    site: store_mod.Site,
    source: Source,
    client: Client,
    received_at_ms: i64,
    date: []const u8,
    visitor_day: []const u8,
    dimensions: Dimensions,
};

/// Full mode keeps identity only with consent. GPC, or a visitor the policy
/// says must be asked, turns the record back into a Lite one. Returns whether
/// an identity was removed.
fn enforceConsent(record: *Record, decision: Decision, gpc: bool) !bool {
    // Erasure is honoured whatever the consent state.
    if (std.mem.eql(u8, record.type, "forget")) return false;
    const identified = record.visitor_id != null or record.session_id != null;
    const consent_record = std.mem.eql(u8, record.type, "consent");
    const asked = consent_record and record.state != null and !std.mem.eql(u8, record.state.?, "denied");
    if (!identified and !asked) {
        if (gpc) record.consent_mode = "gpc";
        return false;
    }
    const mode = record.consent_mode;
    const keep = !gpc and (std.mem.eql(u8, mode, "granted") or
        (std.mem.eql(u8, mode, "not_required") and decision == .grant));
    if (keep) return false;
    if (!gpc and !std.mem.eql(u8, mode, "granted") and !std.mem.eql(u8, mode, "not_required")) return error.InvalidConsent;
    strip(record, gpc);
    return true;
}

fn strip(record: *Record, gpc: bool) void {
    const consent_record = std.mem.eql(u8, record.type, "consent");
    record.visitor_id = null;
    record.session_id = null;
    record.click_id = null;
    record.link = null;
    record.clicks = null;
    record.attention = null;
    record.form_fields = null;
    record.consent_mode = if (gpc) "gpc" else "pending";
    if (consent_record) record.state = if (gpc) "gpc" else "pending";
}

pub fn linkPayload(buffer: []u8, site_public_id: []const u8, visitor_id: []const u8, session_id: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}~{s}~{s}", .{ site_public_id, visitor_id, session_id });
}

fn linkMatches(master_key: [32]u8, site_public_id: []const u8, record: Record, token: []const u8, now_ms: i64) bool {
    const payload = domain.verifyToken(master_key, "link", token, now_ms) orelse return false;
    var buffer: [160]u8 = undefined;
    const expected = linkPayload(&buffer, site_public_id, record.visitor_id orelse return false, record.session_id orelse return false) catch return false;
    return std.mem.eql(u8, payload, expected);
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

pub const Dimensions = struct {
    browser: []const u8,
    operating_system: []const u8,
    device: []const u8,
    traffic_class: []const u8,
};

pub fn classify(user_agent: []const u8) Dimensions {
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

fn insertPageView(c: Context, record: Record) !void {
    const allocator = c.allocator;
    // A page reached from the site itself, with no arrival kept, is internal.
    const referrer_host = if (record.referrer_host) |host| blk: {
        const lower = try lowercaseAscii(allocator, host);
        break :blk if (c.client.page_host.len != 0 and std.ascii.eqlIgnoreCase(lower, c.client.page_host)) self_referrer else lower;
    } else null;
    const search_term = if (record.search_term) |term| try lowercaseAscii(allocator, std.mem.trim(u8, term, " ")) else null;
    const place = c.client.place;
    var statement = try c.store.database.prepare(allocator,
        \\INSERT INTO page_views(site_id,event_id,page_id,session_id,occurred_at_ms,received_at_ms,received_date,visitor_day_id,
        \\ tracking_mode,path,page_type,content_id,referrer_host,utm_source,utm_medium,utm_campaign,utm_content,utm_term,
        \\ navigation_type,viewport_class,language,release_id,tracker_version,consent_mode,internal,country,browser,
        \\ operating_system,device,traffic_class,visitor_id,region,city,search_term,search_results,click_id)
        \\VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    );
    defer statement.deinit();
    try statement.bindInt(1, c.site.id);
    try statement.bindText(2, record.event_id);
    try statement.bindText(3, record.page_id.?);
    try statement.bindOptionalText(4, record.session_id);
    try statement.bindInt(5, record.occurred_at_ms);
    try statement.bindInt(6, c.received_at_ms);
    try statement.bindText(7, c.date);
    try statement.bindText(8, c.visitor_day);
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
    try statement.bindOptionalText(26, if (place) |value| value.country else null);
    try statement.bindText(27, c.dimensions.browser);
    try statement.bindText(28, c.dimensions.operating_system);
    try statement.bindText(29, c.dimensions.device);
    try statement.bindText(30, if (record.internal) "internal" else c.dimensions.traffic_class);
    try statement.bindOptionalText(31, record.visitor_id);
    try statement.bindOptionalText(32, if (place) |value| optionalNonEmpty(value.region) else null);
    try statement.bindOptionalText(33, if (place) |value| optionalNonEmpty(value.city) else null);
    try statement.bindOptionalText(34, if (search_term) |term| optionalNonEmpty(term) else null);
    try statement.bindOptionalInt(35, if (search_term != null) record.search_results else null);
    try statement.bindOptionalText(36, if (record.visitor_id != null) record.click_id else null);
    _ = try statement.step();
    // A summary that arrived before its page view (batches can cross).
    var engagement = try c.store.database.prepare(allocator,
        \\UPDATE page_views SET active_ms=ps.active_ms,max_scroll=ps.max_scroll,interaction_count=ps.interaction_count
        \\FROM page_summaries ps WHERE ps.site_id=page_views.site_id AND ps.page_id=page_views.page_id AND page_views.site_id=? AND page_views.page_id=?
    );
    defer engagement.deinit();
    try engagement.bindInt(1, c.site.id);
    try engagement.bindText(2, record.page_id.?);
    _ = try engagement.step();
    if (record.visitor_id) |visitor_id| try touchVisitor(c, visitor_id, record.page_id.?);
}

/// First touch is kept; later visits only move `last_seen`.
fn touchVisitor(c: Context, visitor_id: []const u8, page_id: []const u8) !void {
    var statement = try c.store.database.prepare(c.allocator,
        \\INSERT INTO visitors(site_id,visitor_id,first_seen_ms,last_seen_ms,first_source,first_campaign,country)
        \\SELECT site_id,?2,received_at_ms,received_at_ms,coalesce(nullif(utm_source,''),nullif(referrer_host,''),'direct'),nullif(utm_campaign,''),country
        \\FROM page_views WHERE site_id=?1 AND page_id=?3
        \\ON CONFLICT(site_id,visitor_id) DO UPDATE SET last_seen_ms=max(last_seen_ms,excluded.last_seen_ms),country=coalesce(excluded.country,country)
    );
    defer statement.deinit();
    try statement.bindInt(1, c.site.id);
    try statement.bindText(2, visitor_id);
    try statement.bindText(3, page_id);
    _ = try statement.step();
}

fn insertPageSummary(c: Context, record: Record) !void {
    const allocator = c.allocator;
    const sections_json = try canonicalJson(allocator, record.sections.?);
    const attention_json: ?[]const u8 = if (record.attention) |values| try canonicalJson(allocator, values) else null;
    var statement = try c.store.database.prepare(allocator,
        \\INSERT INTO page_summaries(site_id,event_id,page_id,session_id,occurred_at_ms,received_at_ms,tracking_mode,visible_ms,
        \\ active_ms,first_interaction_ms,interaction_count,max_scroll,sections_json,last_section,selection_count,copy_count,
        \\ outbound_clicks,downloads,form_attempts,ttfb_ms,fcp_ms,lcp_ms,inp_ms,cls_milli,long_frame_count,blocking_ms,
        \\ tracker_version,consent_mode,release_id,internal,visitor_id,attention_json)
        \\VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    );
    defer statement.deinit();
    try statement.bindInt(1, c.site.id);
    try statement.bindText(2, record.event_id);
    try statement.bindText(3, record.page_id.?);
    try statement.bindOptionalText(4, record.session_id);
    try statement.bindInt(5, record.occurred_at_ms);
    try statement.bindInt(6, c.received_at_ms);
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
    try statement.bindOptionalText(31, record.visitor_id);
    try statement.bindOptionalText(32, attention_json);
    _ = try statement.step();
    var engagement = try c.store.database.prepare(allocator, "UPDATE page_views SET active_ms=?,max_scroll=?,interaction_count=? WHERE site_id=? AND page_id=?");
    defer engagement.deinit();
    try engagement.bindInt(1, record.active_ms.?);
    try engagement.bindInt(2, record.max_scroll.?);
    try engagement.bindInt(3, record.interaction_count.?);
    try engagement.bindInt(4, c.site.id);
    try engagement.bindText(5, record.page_id.?);
    _ = try engagement.step();
    if (record.clicks == null and record.form_fields == null) return;

    // Heatmap and form aggregates are kept per page path and day.
    var page = try c.store.database.prepare(allocator, "SELECT path,coalesce(viewport_class,'desktop') FROM page_views WHERE site_id=? AND page_id=?");
    defer page.deinit();
    try page.bindInt(1, c.site.id);
    try page.bindText(2, record.page_id.?);
    if (try page.step() != .row) return;
    const path = try allocator.dupe(u8, page.columnText(0));
    const viewport = try allocator.dupe(u8, page.columnText(1));
    if (record.clicks) |clicks| {
        var upsert = try c.store.database.prepare(allocator,
            \\INSERT INTO click_cells(site_id,path,day,viewport_class,element,x,y,clicks,rage) VALUES(?,?,?,?,?,?,?,?,?)
            \\ON CONFLICT(site_id,path,day,viewport_class,element,x,y) DO UPDATE SET clicks=clicks+excluded.clicks,rage=rage+excluded.rage
        );
        defer upsert.deinit();
        for (clicks) |click| {
            try upsert.reset();
            try upsert.bindInt(1, c.site.id);
            try upsert.bindText(2, path);
            try upsert.bindText(3, c.date);
            try upsert.bindText(4, viewport);
            try upsert.bindText(5, click.el);
            try upsert.bindInt(6, click.x);
            try upsert.bindInt(7, click.y);
            try upsert.bindInt(8, click.n);
            try upsert.bindInt(9, click.rage);
            _ = try upsert.step();
        }
    }
    if (record.form_fields) |fields| {
        var upsert = try c.store.database.prepare(allocator,
            \\INSERT INTO form_fields(site_id,path,day,form,field,starts,ms,errors,abandons,submits) VALUES(?,?,?,?,?,?,?,?,?,?)
            \\ON CONFLICT(site_id,path,day,form,field) DO UPDATE SET starts=starts+excluded.starts,ms=ms+excluded.ms,
            \\ errors=errors+excluded.errors,abandons=abandons+excluded.abandons,submits=submits+excluded.submits
        );
        defer upsert.deinit();
        // One form-level row (field "") per form: started, submitted or abandoned.
        var forms: std.StringArrayHashMapUnmanaged(struct { submitted: bool, abandoned: bool }) = .empty;
        for (fields) |field| {
            const entry = try forms.getOrPut(allocator, field.form);
            if (!entry.found_existing) entry.value_ptr.* = .{ .submitted = false, .abandoned = false };
            if (field.submitted) entry.value_ptr.submitted = true;
            if (field.abandoned) entry.value_ptr.abandoned = true;
            try upsert.reset();
            try bindFormRow(&upsert, c, path, field.form, field.field, field.ms, field.errors, field.abandoned, field.submitted);
            _ = try upsert.step();
        }
        var iterator = forms.iterator();
        while (iterator.next()) |entry| {
            try upsert.reset();
            const submitted = entry.value_ptr.submitted;
            try bindFormRow(&upsert, c, path, entry.key_ptr.*, "", 0, 0, !submitted and entry.value_ptr.abandoned, submitted);
            _ = try upsert.step();
        }
    }
}

fn bindFormRow(statement: anytype, c: Context, path: []const u8, form: []const u8, field: []const u8, ms: i64, errors: i64, abandoned: bool, submitted: bool) !void {
    try statement.bindInt(1, c.site.id);
    try statement.bindText(2, path);
    try statement.bindText(3, c.date);
    try statement.bindText(4, form);
    try statement.bindText(5, field);
    try statement.bindInt(6, 1);
    try statement.bindInt(7, ms);
    try statement.bindInt(8, errors);
    try statement.bindBool(9, abandoned);
    try statement.bindBool(10, submitted);
}

fn insertEvent(c: Context, record: Record) !void {
    const allocator = c.allocator;
    const properties = try canonicalProperties(allocator, record.properties);
    var user_hash: ?[32]u8 = null;
    if (record.user_id) |user_id| user_hash = domain.userHash(c.master_key, c.site.public_id, user_id);
    var statement = try c.store.database.prepare(allocator,
        \\INSERT INTO events(site_id,event_id,page_id,session_id,source,occurred_at_ms,received_at_ms,received_date,tracking_mode,
        \\ name,path,release_id,tracker_version,consent_mode,internal,value_minor,currency,properties_json,visitor_id,user_hash,order_id,traffic_class)
        \\VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,
        \\ CASE WHEN ?5<>'server' THEN coalesce((SELECT pv.traffic_class FROM page_views pv WHERE pv.site_id=?1 AND pv.page_id=?3),?22) END)
    );
    defer statement.deinit();
    try statement.bindInt(1, c.site.id);
    try statement.bindText(2, record.event_id);
    try statement.bindOptionalText(3, record.page_id);
    try statement.bindOptionalText(4, record.session_id);
    try statement.bindText(5, @tagName(c.source));
    try statement.bindInt(6, record.occurred_at_ms);
    try statement.bindInt(7, c.received_at_ms);
    try statement.bindText(8, c.date);
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
    try statement.bindOptionalText(19, record.visitor_id);
    if (user_hash) |*hash| try statement.bindText(20, hash) else try statement.bindNull(20);
    try statement.bindOptionalText(21, record.order_id);
    // Browser events carry their page view's traffic class (their own
    // sender's without one), so reports can leave out bots without looking
    // up each event's page view.
    if (c.source == .server) try statement.bindNull(22) else try statement.bindText(22, if (record.internal) "internal" else c.dimensions.traffic_class);
    _ = try statement.step();
    if (record.items) |items| {
        var insert = try c.store.database.prepare(allocator, "INSERT INTO event_items(site_id,event_id,position,item_id,name,category,price_minor,quantity) VALUES(?,?,?,?,?,?,?,?)");
        defer insert.deinit();
        for (items, 0..) |item, index| {
            try insert.reset();
            try insert.bindInt(1, c.site.id);
            try insert.bindText(2, record.event_id);
            try insert.bindInt(3, @intCast(index));
            try insert.bindText(4, item.id);
            try insert.bindText(5, item.name);
            try insert.bindOptionalText(6, item.category);
            try insert.bindOptionalInt(7, item.price_minor);
            try insert.bindInt(8, item.quantity);
            _ = try insert.step();
        }
    }
    if (user_hash) |*hash| if (record.visitor_id) |visitor_id| try linkVisitor(c, visitor_id, hash);
}

fn applyConsent(c: Context, record: Record) !void {
    const state = record.state.?;
    var statement = try c.store.database.prepare(c.allocator, "UPDATE page_views SET visitor_id=?3,session_id=?4,consent_mode=?5,click_id=CASE WHEN ?3 IS NULL THEN NULL ELSE click_id END WHERE site_id=?1 AND page_id=?2 AND visitor_id IS NULL");
    defer statement.deinit();
    try statement.bindInt(1, c.site.id);
    try statement.bindText(2, record.page_id.?);
    try statement.bindOptionalText(3, record.visitor_id);
    try statement.bindOptionalText(4, record.session_id);
    try statement.bindText(5, state);
    _ = try statement.step();
    if (record.visitor_id) |visitor_id| try touchVisitor(c, visitor_id, record.page_id.?);
}

fn applyIdentify(c: Context, record: Record) !void {
    const hash = domain.userHash(c.master_key, c.site.public_id, record.user_id.?);
    try linkVisitor(c, record.visitor_id.?, &hash);
}

/// A visitor belongs to the most recent identify() until reset(); links are
/// never rewritten, so earlier history stays with the user it was linked to.
fn linkVisitor(c: Context, visitor_id: []const u8, hash: []const u8) !void {
    var link = try c.store.database.prepare(c.allocator, "INSERT INTO visitor_links(site_id,user_hash,visitor_id,linked_at_ms) VALUES(?,?,?,?) ON CONFLICT DO NOTHING");
    defer link.deinit();
    try link.bindInt(1, c.site.id);
    try link.bindText(2, hash);
    try link.bindText(3, visitor_id);
    try link.bindInt(4, c.received_at_ms);
    _ = try link.step();
    var visitor = try c.store.database.prepare(c.allocator,
        \\INSERT INTO visitors(site_id,visitor_id,first_seen_ms,last_seen_ms,first_source,user_hash) VALUES(?1,?2,?3,?3,'direct',?4)
        \\ON CONFLICT(site_id,visitor_id) DO UPDATE SET user_hash=excluded.user_hash
    );
    defer visitor.deinit();
    try visitor.bindInt(1, c.site.id);
    try visitor.bindText(2, visitor_id);
    try visitor.bindInt(3, c.received_at_ms);
    try visitor.bindText(4, hash);
    _ = try visitor.step();
}

fn insertError(c: Context, record: Record) !void {
    const message = record.message.?;
    var fingerprint_source: std.Io.Writer.Allocating = .init(c.allocator);
    try fingerprint_source.writer.print("{s}\x00{s}\x00{d}", .{ message, record.file orelse "", record.line orelse 0 });
    const digest = domain.payloadHash(fingerprint_source.written());
    var statement = try c.store.database.prepare(c.allocator,
        \\INSERT INTO errors(site_id,event_id,page_id,session_id,visitor_id,occurred_at_ms,received_at_ms,path,release_id,fingerprint,
        \\ message,file,line,col,browser,internal) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    );
    defer statement.deinit();
    try statement.bindInt(1, c.site.id);
    try statement.bindText(2, record.event_id);
    try statement.bindOptionalText(3, record.page_id);
    try statement.bindOptionalText(4, record.session_id);
    try statement.bindOptionalText(5, record.visitor_id);
    try statement.bindInt(6, record.occurred_at_ms);
    try statement.bindInt(7, c.received_at_ms);
    try statement.bindText(8, record.path.?);
    try statement.bindOptionalText(9, optionalNonEmpty(record.release_id));
    try statement.bindText(10, digest[0..16]);
    try statement.bindText(11, message);
    try statement.bindOptionalText(12, record.file);
    try statement.bindOptionalInt(13, record.line);
    try statement.bindOptionalInt(14, record.column);
    try statement.bindText(15, c.dimensions.browser);
    try statement.bindBool(16, record.internal);
    _ = try statement.step();
}

/// Erases an identified user: every visitor linked to them, and server events
/// recorded for them. Returns the visitor IDs, for their replays.
pub fn forgetUser(allocator: std.mem.Allocator, store: *store_mod.Store, site_id: i64, hash: []const u8) ![]const []const u8 {
    var statement = try store.database.prepare(allocator, "SELECT visitor_id FROM visitor_links WHERE site_id=?1 AND user_hash=?2 UNION SELECT visitor_id FROM visitors WHERE site_id=?1 AND user_hash=?2");
    defer statement.deinit();
    try statement.bindInt(1, site_id);
    try statement.bindText(2, hash);
    var visitors: std.ArrayList([]const u8) = .empty;
    while (try statement.step() == .row) try visitors.append(allocator, try allocator.dupe(u8, statement.columnText(0)));
    for (visitors.items) |visitor_id| try forgetVisitor(allocator, store, site_id, visitor_id);
    inline for (.{
        "DELETE FROM event_items WHERE site_id=?1 AND event_id IN (SELECT event_id FROM events WHERE site_id=?1 AND user_hash=?2)",
        "DELETE FROM events WHERE site_id=?1 AND user_hash=?2",
        "DELETE FROM visitor_links WHERE site_id=?1 AND user_hash=?2",
    }) |sql| {
        var delete = try store.database.prepare(allocator, sql);
        defer delete.deinit();
        try delete.bindInt(1, site_id);
        try delete.bindText(2, hash);
        _ = try delete.step();
    }
    return visitors.items;
}

/// Removes everything stored about one visitor. Aggregates (click cells,
/// form fields) carry no identifier and stay.
pub fn forgetVisitor(allocator: std.mem.Allocator, store: *store_mod.Store, site_id: i64, visitor_id: []const u8) !void {
    inline for (.{
        "DELETE FROM page_summaries WHERE site_id=?1 AND (visitor_id=?2 OR page_id IN (SELECT page_id FROM page_views WHERE site_id=?1 AND visitor_id=?2))",
        "DELETE FROM event_items WHERE site_id=?1 AND event_id IN (SELECT event_id FROM events WHERE site_id=?1 AND visitor_id=?2)",
        "DELETE FROM events WHERE site_id=?1 AND visitor_id=?2",
        "DELETE FROM errors WHERE site_id=?1 AND visitor_id=?2",
        "DELETE FROM page_views WHERE site_id=?1 AND visitor_id=?2",
        "DELETE FROM visitor_links WHERE site_id=?1 AND visitor_id=?2",
        "DELETE FROM visitor_weeks WHERE site_id=?1 AND visitor_id=?2",
        "DELETE FROM visitors WHERE site_id=?1 AND visitor_id=?2",
    }) |sql| {
        var statement = try store.database.prepare(allocator, sql);
        defer statement.deinit();
        try statement.bindInt(1, site_id);
        try statement.bindText(2, visitor_id);
        _ = try statement.step();
    }
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
    try domain.validateText(record.consent_mode, 32, false);
    try domain.validateText(record.tracker_version, 32, false);
    try domain.validateText(record.release_id, 64, true);
    if (record.occurred_at_ms > received_at_ms + 5 * 60 * 1000 or
        record.occurred_at_ms < received_at_ms - 90 * 24 * 60 * 60 * 1000) return error.InvalidOccurredAt;
    if (record.session_id) |session_id| try domain.validateUuid(session_id);
    if (record.visitor_id) |visitor_id| try domain.validateUuid(visitor_id);
    switch (mode) {
        .lite => if (record.session_id != null or record.visitor_id != null) return error.SessionForbidden,
        .session => {
            if (record.visitor_id != null) return error.VisitorForbidden;
            if (source == .browser and record.session_id == null) return error.MissingSessionId;
        },
        // A consented browser record carries both, an unconsented one neither.
        .full => if (source == .browser and (record.session_id == null) != (record.visitor_id == null)) return error.PartialIdentity,
    }
    const identified = record.visitor_id != null;
    const kind = record.type;

    if (std.mem.eql(u8, kind, "page_view")) {
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
        try validateOptionalText(record.search_term, 100);
        if (record.search_results) |count| try bounded(count, 0, 1_000_000);
        if (record.search_results != null and record.search_term == null) return error.UnexpectedRecordFields;
        if (record.click_id) |value| try validateClickId(value);
        try validateOptionalText(record.link, 300);
        return;
    }
    if (std.mem.eql(u8, kind, "page_summary")) {
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
        // Behaviour detail rides on consent, like every Full-mode feature.
        if (!identified and (record.clicks != null or record.attention != null or record.form_fields != null)) return error.ConsentRequired;
        if (record.clicks) |clicks| {
            if (clicks.len > 32) return error.TooManyClicks;
            for (clicks) |click| {
                try domain.validateText(click.el, 160, false);
                try bounded(click.x, 0, 100);
                try bounded(click.y, 0, 100);
                try bounded(click.n, 1, 1000);
                try bounded(click.rage, 0, click.n);
            }
        }
        if (record.attention) |values| {
            if (values.len != 10) return error.InvalidAttention;
            for (values) |value| try bounded(value, 0, 86_400_000);
        }
        if (record.form_fields) |fields| {
            if (fields.len > 32) return error.TooManyFormFields;
            for (fields) |field| {
                try domain.validateText(field.form, 64, false);
                try domain.validateText(field.field, 64, false);
                try bounded(field.ms, 0, 86_400_000);
                try bounded(field.errors, 0, 1000);
            }
        }
        return;
    }
    if (std.mem.eql(u8, kind, "consent")) {
        if (source != .browser or mode != .full) return error.ConsentRecordForbidden;
        try domain.validateUuid(record.page_id orelse return error.MissingPageId);
        const state = record.state orelse return error.MissingConsentState;
        const granted = std.mem.eql(u8, state, "granted") or std.mem.eql(u8, state, "not_required");
        const kept_lite = std.mem.eql(u8, state, "denied") or std.mem.eql(u8, state, "pending") or std.mem.eql(u8, state, "gpc");
        if (!granted and !kept_lite) return error.InvalidConsentState;
        if (granted != identified) return error.InvalidConsentState;
        return;
    }
    if (std.mem.eql(u8, kind, "error")) {
        if (source != .browser) return error.InvalidInternalRecordType;
        try domain.validateUuid(record.page_id orelse return error.MissingPageId);
        try domain.validatePath(record.path orelse return error.MissingPath);
        try domain.validateText(record.message orelse return error.MissingMessage, 300, false);
        try validateOptionalText(record.file, 200);
        if (record.line) |value| try bounded(value, 0, 10_000_000);
        if (record.column) |value| try bounded(value, 0, 10_000_000);
        return;
    }
    if (std.mem.eql(u8, kind, "identify")) {
        if (mode != .full) return error.IdentityForbidden;
        try domain.validateText(record.user_id orelse return error.MissingUserId, 128, false);
        if (source == .server and record.visitor_id == null) return error.MissingVisitorId;
        return;
    }
    if (std.mem.eql(u8, kind, "forget")) {
        if (mode != .full) return error.InvalidForget;
        if (record.user_id) |user_id| {
            if (source != .server) return error.InvalidForget;
            try domain.validateText(user_id, 128, false);
        } else if (record.visitor_id == null) return error.InvalidForget;
        return;
    }
    if (!std.mem.eql(u8, kind, "event")) return error.UnknownRecordType;
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
    if (record.value_minor) |value| try bounded(value, -1_000_000_000_000, 1_000_000_000_000);
    try validateOptionalText(record.order_id, 64);
    if (record.user_id) |user_id| {
        if (source != .server or mode != .full) return error.IdentityForbidden;
        try domain.validateText(user_id, 128, false);
    }
    if (record.items) |items| {
        if (items.len == 0 or items.len > 32) return error.InvalidItems;
        for (items) |item| {
            try domain.validateText(item.id, 64, false);
            try domain.validateText(item.name, 128, false);
            try validateOptionalText(item.category, 64);
            if (item.price_minor) |price| try bounded(price, -1_000_000_000_000, 1_000_000_000_000);
            try bounded(item.quantity, 1, 10_000);
        }
    }
    _ = try canonicalProperties(allocator, record.properties);
}

fn validateClickId(value: []const u8) !void {
    try domain.validateText(value, 200, false);
    const split = std.mem.findScalar(u8, value, ':') orelse return error.InvalidClickId;
    const kind = value[0..split];
    if (!(std.mem.eql(u8, kind, "gclid") or std.mem.eql(u8, kind, "gbraid") or
        std.mem.eql(u8, kind, "wbraid") or std.mem.eql(u8, kind, "fbclid") or std.mem.eql(u8, kind, "msclkid"))) return error.InvalidClickId;
    for (value[split + 1 ..]) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.')) return error.InvalidClickId;
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
            .string => |text| try domain.validateText(text, 256, true),
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

fn canonicalJson(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(value, .{}, &writer.writer);
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

fn validateOptionalText(value: ?[]const u8, maximum: usize) !void {
    if (value) |text| try domain.validateText(text, maximum, true);
}

fn validateReferrerHost(value: []const u8) !void {
    try domain.validateText(value, 253, false);
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
    const now = @divFloor(domain.nowMs(), 1000);
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
