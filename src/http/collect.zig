const std = @import("std");
const domain = @import("../domain.zig");
const property = @import("../property.zig");
const meta = @import("../store/meta.zig");

pub const Utm = struct {
    source: ?[]const u8 = null,
    medium: ?[]const u8 = null,
    campaign: ?[]const u8 = null,
    term: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

pub const Payload = struct {
    v: u8,
    site: []const u8,
    type: []const u8,
    name: ?[]const u8 = null,
    path: []const u8,
    referrer: ?[]const u8 = null,
    utm: ?Utm = null,
    properties: ?std.json.Value = null,
};

pub const PageV2 = struct {
    path: []const u8,
    title: ?[]const u8 = null,
    hostname: ?[]const u8 = null,
};

pub const ValueV2 = struct {
    amount: []const u8,
    currency: []const u8,
};

pub const EngagementV2 = struct {
    active_ms: u32,
    max_scroll_depth: u8,
};

pub const UserV2 = struct {
    id: []const u8,
    traits: ?std.json.Value = null,
};

pub const PayloadV2 = struct {
    v: u8,
    site: []const u8,
    event_id: []const u8,
    anonymous_id: []const u8,
    identity_quality: []const u8,
    session_id: []const u8,
    sequence: u32,
    occurred_at_ms: i64,
    self_excluded: bool = false,
    type: []const u8,
    name: ?[]const u8 = null,
    page: ?PageV2 = null,
    referrer: ?[]const u8 = null,
    utm: ?Utm = null,
    properties: ?std.json.Value = null,
    value: ?ValueV2 = null,
    engagement: ?EngagementV2 = null,
    user: ?UserV2 = null,
};

pub const Prepared = struct {
    site_id: []const u8,
    kind: u8,
    event_name: []const u8,
    path: []const u8,
    referrer_host: []const u8,
    utm_source: []const u8,
    utm_medium: []const u8,
    utm_campaign: []const u8,
    utm_term: []const u8,
    utm_content: []const u8,
    properties_json: []const u8,
};

pub const PreparedV2 = struct {
    site_id: []const u8,
    event_id: []const u8,
    anonymous_id: []const u8,
    identity_quality: u8,
    session_id: []const u8,
    sequence: u32,
    occurred_at_utc_micros: i64,
    kind: u8,
    event_name: []const u8,
    path: []const u8,
    page_title: []const u8,
    hostname: []const u8,
    referrer_host: []const u8,
    utm_source: []const u8,
    utm_medium: []const u8,
    utm_campaign: []const u8,
    utm_term: []const u8,
    utm_content: []const u8,
    properties_json: []const u8,
    identify_user_id: []const u8,
    user_traits_json: []const u8,
    value_amount: ?[]const u8,
    value_currency: []const u8,
    engagement_ms: u32,
    max_scroll_depth: u8,
    self_excluded: bool,
    event_payload_digest: [64]u8,
};

pub const Pixel = struct {
    site: []const u8,
    path: []const u8,
    utm_source: []const u8 = "",
    utm_medium: []const u8 = "",
    utm_campaign: []const u8 = "",
    utm_term: []const u8 = "",
    utm_content: []const u8 = "",
};

pub fn parsePost(
    allocator: std.mem.Allocator,
    body: []const u8,
) !Payload {
    if (!std.unicode.utf8ValidateSlice(body)) return error.InvalidUtf8;
    return std.json.parseFromSliceLeaky(Payload, allocator, body, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .max_value_len = 4096,
    }) catch return error.InvalidJson;
}

pub fn parsePostV2(
    allocator: std.mem.Allocator,
    body: []const u8,
) !PayloadV2 {
    if (!std.unicode.utf8ValidateSlice(body)) return error.InvalidUtf8;
    return std.json.parseFromSliceLeaky(PayloadV2, allocator, body, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .max_value_len = 16 * 1024,
        .parse_numbers = false,
    }) catch return error.InvalidJson;
}

pub fn preparePost(
    allocator: std.mem.Allocator,
    payload: Payload,
    policy: meta.SitePolicy,
) !Prepared {
    if (payload.v != 1 or !std.mem.eql(u8, payload.site, policy.id)) {
        return error.InvalidProtocol;
    }
    const path = try domain.normalizePath(payload.path);
    const is_pageview = std.mem.eql(u8, payload.type, "pageview");
    const is_event = std.mem.eql(u8, payload.type, "event");
    if (!is_pageview and !is_event) return error.InvalidEventType;
    if (is_pageview and (payload.name != null or payload.properties != null)) {
        return error.InvalidPageView;
    }
    const event_name = if (is_pageview)
        "pageview"
    else
        payload.name orelse return error.MissingEventName;
    try domain.validateIdentifier(event_name);

    const referrer_host = if (payload.referrer) |referrer| blk: {
        if (referrer.len > 2048) return error.ReferrerTooLong;
        break :blk try externalReferrerHost(allocator, referrer, policy.origins);
    } else "";
    const utm = payload.utm orelse Utm{};
    try validateCampaign(utm.source);
    try validateCampaign(utm.medium);
    try validateCampaign(utm.campaign);
    try validateCampaign(utm.term);
    try validateCampaign(utm.content);
    const properties_json = if (is_event)
        try canonicalProperties(
            allocator,
            payload.properties orelse .{ .object = .empty },
            policy,
        )
    else
        "{}";
    return .{
        .site_id = policy.id,
        .kind = if (is_pageview) 1 else 2,
        .event_name = event_name,
        .path = path,
        .referrer_host = referrer_host,
        .utm_source = utm.source orelse "",
        .utm_medium = utm.medium orelse "",
        .utm_campaign = utm.campaign orelse "",
        .utm_term = utm.term orelse "",
        .utm_content = utm.content orelse "",
        .properties_json = properties_json,
    };
}

pub fn preparePostV2(
    allocator: std.mem.Allocator,
    payload: PayloadV2,
    policy: meta.SitePolicy,
    received_at_utc_micros: i64,
) !PreparedV2 {
    if (payload.v != 2 or !std.mem.eql(u8, payload.site, policy.id)) {
        return error.InvalidProtocol;
    }
    try domain.validateUuid(payload.event_id);
    try domain.validateUuid(payload.anonymous_id);
    try domain.validateUuid(payload.session_id);
    if (payload.occurred_at_ms < 0) return error.InvalidOccurrenceTime;
    const occurred_at_utc_micros = std.math.mul(
        i64,
        payload.occurred_at_ms,
        1_000,
    ) catch return error.InvalidOccurrenceTime;
    const past_limit = std.math.sub(
        i64,
        received_at_utc_micros,
        7 * 24 * 60 * 60 * 1_000_000,
    ) catch return error.InvalidOccurrenceTime;
    const future_limit = std.math.add(
        i64,
        received_at_utc_micros,
        24 * 60 * 60 * 1_000_000,
    ) catch return error.InvalidOccurrenceTime;
    if (occurred_at_utc_micros < past_limit or
        occurred_at_utc_micros > future_limit)
    {
        return error.InvalidOccurrenceTime;
    }

    const identity_quality: u8 = if (std.mem.eql(
        u8,
        payload.identity_quality,
        "persistent",
    ))
        1
    else if (std.mem.eql(u8, payload.identity_quality, "ephemeral"))
        2
    else
        return error.InvalidIdentityQuality;
    const is_pageview = std.mem.eql(u8, payload.type, "pageview");
    const is_event = std.mem.eql(u8, payload.type, "event");
    const is_engagement = std.mem.eql(u8, payload.type, "engagement");
    const is_identify = std.mem.eql(u8, payload.type, "identify");
    if (!is_pageview and !is_event and !is_engagement and !is_identify) {
        return error.InvalidEventType;
    }
    if (is_pageview and (payload.name != null or payload.properties != null or
        payload.value != null or payload.engagement != null or payload.user != null))
    {
        return error.InvalidPageView;
    }
    if (is_event and (payload.name == null or payload.engagement != null or
        payload.user != null))
    {
        return error.InvalidCustomEvent;
    }
    if (is_engagement and (payload.page == null or payload.engagement == null or
        payload.name != null or payload.referrer != null or payload.utm != null or
        payload.properties != null or payload.value != null or payload.user != null))
    {
        return error.InvalidEngagement;
    }
    if (is_identify and (identity_quality != 1 or payload.user == null or
        payload.name != null or payload.referrer != null or payload.utm != null or
        payload.properties != null or payload.value != null or
        payload.engagement != null))
    {
        return error.InvalidIdentify;
    }
    if (is_pageview and payload.page == null) return error.MissingPage;

    const event_name = if (is_pageview)
        "page_view"
    else if (is_event)
        payload.name.?
    else if (is_engagement)
        "engagement"
    else
        "identify";
    try domain.validateIdentifier(event_name);

    const page = payload.page;
    const path = if (page) |value|
        try normalizeV2Path(value.path)
    else
        "";
    const page_title = if (page) |value| if (value.title) |title| blk: {
        try validateV2Text(title, 512, true);
        break :blk title;
    } else "" else "";
    const hostname = if (page) |value| if (value.hostname) |host| blk: {
        try validateV2Text(host, 253, false);
        break :blk try lowercaseHost(allocator, host);
    } else "" else "";
    const referrer_host = if (payload.referrer) |referrer|
        try externalReferrerHostV2(allocator, referrer, policy.origins)
    else
        "";
    const utm = payload.utm orelse Utm{};
    try validateCampaignV2(utm.source);
    try validateCampaignV2(utm.medium);
    try validateCampaignV2(utm.campaign);
    try validateCampaignV2(utm.term);
    try validateCampaignV2(utm.content);

    const properties_json = if (payload.properties) |properties|
        try canonicalFlatV2(allocator, properties)
    else
        "{}";
    const user = payload.user;
    const identify_user_id = if (user) |value| blk: {
        try validateV2Text(value.id, 160, false);
        break :blk value.id;
    } else "";
    const user_traits_json = if (user) |value| if (value.traits) |traits|
        try canonicalFlatV2(allocator, traits)
    else
        "{}" else "{}";
    const value_amount = if (payload.value) |value|
        try canonicalDecimal(allocator, value.amount)
    else
        null;
    const value_currency = if (payload.value) |value| blk: {
        try validateCurrency(value.currency);
        break :blk value.currency;
    } else "";
    const engagement_ms = if (payload.engagement) |engagement| blk: {
        if (engagement.active_ms > 60_000 or engagement.max_scroll_depth > 100) {
            return error.InvalidEngagement;
        }
        break :blk engagement.active_ms;
    } else 0;
    const max_scroll_depth = if (payload.engagement) |engagement|
        engagement.max_scroll_depth
    else
        0;

    var prepared = PreparedV2{
        .site_id = policy.id,
        .event_id = payload.event_id,
        .anonymous_id = payload.anonymous_id,
        .identity_quality = identity_quality,
        .session_id = payload.session_id,
        .sequence = payload.sequence,
        .occurred_at_utc_micros = occurred_at_utc_micros,
        .kind = if (is_pageview) 1 else if (is_event) 2 else if (is_engagement) 3 else 4,
        .event_name = event_name,
        .path = path,
        .page_title = page_title,
        .hostname = hostname,
        .referrer_host = referrer_host,
        .utm_source = utm.source orelse "",
        .utm_medium = utm.medium orelse "",
        .utm_campaign = utm.campaign orelse "",
        .utm_term = utm.term orelse "",
        .utm_content = utm.content orelse "",
        .properties_json = properties_json,
        .identify_user_id = identify_user_id,
        .user_traits_json = user_traits_json,
        .value_amount = value_amount,
        .value_currency = value_currency,
        .engagement_ms = engagement_ms,
        .max_scroll_depth = max_scroll_depth,
        .self_excluded = payload.self_excluded,
        .event_payload_digest = undefined,
    };
    prepared.event_payload_digest = digestPreparedV2(prepared);
    return prepared;
}

pub fn parsePixel(
    allocator: std.mem.Allocator,
    target: []const u8,
) !Pixel {
    const marker = std.mem.findScalar(u8, target, '?') orelse
        return error.MissingQuery;
    var result = Pixel{ .site = "", .path = "" };
    var seen: u8 = 0;
    var pairs = std.mem.splitScalar(u8, target[marker + 1 ..], '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) return error.InvalidQuery;
        const key, const encoded = std.mem.cutScalar(u8, pair, '=') orelse
            return error.InvalidQuery;
        const value = try percentDecode(allocator, encoded);
        const index: u3 = if (std.mem.eql(u8, key, "site"))
            0
        else if (std.mem.eql(u8, key, "path"))
            1
        else if (std.mem.eql(u8, key, "utm_source"))
            2
        else if (std.mem.eql(u8, key, "utm_medium"))
            3
        else if (std.mem.eql(u8, key, "utm_campaign"))
            4
        else if (std.mem.eql(u8, key, "utm_term"))
            5
        else if (std.mem.eql(u8, key, "utm_content"))
            6
        else
            return error.UnknownQueryKey;
        const bit: u8 = @as(u8, 1) << index;
        if (seen & bit != 0) return error.DuplicateQueryKey;
        seen |= bit;
        switch (index) {
            0 => result.site = value,
            1 => result.path = value,
            2 => result.utm_source = value,
            3 => result.utm_medium = value,
            4 => result.utm_campaign = value,
            5 => result.utm_term = value,
            6 => result.utm_content = value,
            else => unreachable,
        }
    }
    if (result.site.len == 0 or result.path.len == 0) return error.MissingQuery;
    try domain.validateUuid(result.site);
    _ = try domain.normalizePath(result.path);
    try validateCampaign(result.utm_source);
    try validateCampaign(result.utm_medium);
    try validateCampaign(result.utm_campaign);
    try validateCampaign(result.utm_term);
    try validateCampaign(result.utm_content);
    return result;
}

pub fn preparePixel(
    allocator: std.mem.Allocator,
    pixel: Pixel,
    policy: meta.SitePolicy,
    referer: []const u8,
) !Prepared {
    if (!std.mem.eql(u8, pixel.site, policy.id)) return error.InvalidProtocol;
    const origin = try urlOrigin(allocator, referer);
    if (!policy.allowsOrigin(origin)) return error.OriginDenied;
    return .{
        .site_id = policy.id,
        .kind = 1,
        .event_name = "pageview",
        .path = try domain.normalizePath(pixel.path),
        .referrer_host = "",
        .utm_source = pixel.utm_source,
        .utm_medium = pixel.utm_medium,
        .utm_campaign = pixel.utm_campaign,
        .utm_term = pixel.utm_term,
        .utm_content = pixel.utm_content,
        .properties_json = "{}",
    };
}

pub fn urlOrigin(
    allocator: std.mem.Allocator,
    value: []const u8,
) ![]u8 {
    if (value.len == 0 or value.len > 2048 or
        !std.unicode.utf8ValidateSlice(value))
    {
        return error.InvalidUrl;
    }
    const uri = std.Uri.parse(value) catch return error.InvalidUrl;
    if (!(std.mem.eql(u8, uri.scheme, "http") or
        std.mem.eql(u8, uri.scheme, "https")) or uri.host == null or
        uri.user != null or uri.password != null)
    {
        return error.InvalidUrl;
    }
    const host = try rawHost(uri);
    const normalized_host = try lowercaseHost(allocator, host);
    const include_port = if (uri.port) |port|
        !((std.mem.eql(u8, uri.scheme, "http") and port == 80) or
            (std.mem.eql(u8, uri.scheme, "https") and port == 443))
    else
        false;
    return if (include_port)
        std.fmt.allocPrint(allocator, "{s}://{s}:{d}", .{
            uri.scheme,
            normalized_host,
            uri.port.?,
        })
    else
        std.fmt.allocPrint(allocator, "{s}://{s}", .{
            uri.scheme,
            normalized_host,
        });
}

fn externalReferrerHost(
    allocator: std.mem.Allocator,
    value: []const u8,
    origins: []const []u8,
) ![]const u8 {
    const origin = urlOrigin(allocator, value) catch return "";
    for (origins) |allowed| {
        if (std.mem.eql(u8, allowed, origin)) return "";
    }
    const uri = std.Uri.parse(value) catch return "";
    return lowercaseHost(allocator, rawHost(uri) catch return "");
}

fn externalReferrerHostV2(
    allocator: std.mem.Allocator,
    value: []const u8,
    origins: []const []u8,
) ![]const u8 {
    const origin = try urlOrigin(allocator, value);
    for (origins) |allowed| {
        if (std.mem.eql(u8, allowed, origin)) return "";
    }
    const uri = std.Uri.parse(value) catch return error.InvalidUrl;
    return lowercaseHost(allocator, try rawHost(uri));
}

fn normalizeV2Path(value: []const u8) ![]const u8 {
    try validateV2Text(value, 1024, false);
    return domain.normalizePath(value);
}

fn canonicalFlatV2(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ![]const u8 {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidProperties,
    };
    if (object.count() > 16) return error.TooManyProperties;
    var keys: std.ArrayList([]const u8) = .empty;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        try domain.validateIdentifier(key);
        try validateV2Scalar(entry.value_ptr.*);
        try keys.append(allocator, key);
    }
    insertionSort(keys.items);

    var output = std.Io.Writer.Allocating.init(allocator);
    try output.writer.writeByte('{');
    for (keys.items, 0..) |key, index| {
        if (index != 0) try output.writer.writeByte(',');
        try std.json.Stringify.value(key, .{}, &output.writer);
        try output.writer.writeByte(':');
        const scalar = object.get(key).?;
        switch (scalar) {
            .number_string => |number| try property.writeCanonicalNumber(
                &output.writer,
                number,
            ),
            else => try std.json.Stringify.value(scalar, .{}, &output.writer),
        }
    }
    try output.writer.writeByte('}');
    if (output.written().len > 16 * 1024) return error.PropertiesTooLarge;
    return output.toOwnedSlice();
}

fn validateV2Scalar(value: std.json.Value) !void {
    switch (value) {
        .null, .bool, .integer => {},
        .number_string => |number| _ = try property.numberType(number),
        .string => |string| try validateV2Text(string, 512, true),
        else => return error.InvalidPropertyValue,
    }
}

fn validateV2Text(value: []const u8, maximum: usize, allow_empty: bool) !void {
    if ((!allow_empty and value.len == 0) or value.len > maximum or
        !std.unicode.utf8ValidateSlice(value))
    {
        return error.InvalidText;
    }
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        const byte = value[index];
        if (byte < 0x20 or byte == 0x7f) return error.InvalidText;
        if (byte == 0xc2 and index + 1 < value.len and
            value[index + 1] >= 0x80 and value[index + 1] <= 0x9f)
        {
            return error.InvalidText;
        }
    }
}

fn validateCampaignV2(value: ?[]const u8) !void {
    const candidate = value orelse return;
    try validateV2Text(candidate, 256, true);
}

fn validateCurrency(value: []const u8) !void {
    if (value.len != 3) return error.InvalidCurrency;
    for (value) |byte| {
        if (byte < 'A' or byte > 'Z') return error.InvalidCurrency;
    }
}

fn canonicalDecimal(
    allocator: std.mem.Allocator,
    value: []const u8,
) ![]const u8 {
    if (value.len == 0 or value.len > 20) return error.InvalidDecimal;
    var start: usize = 0;
    const negative = value[0] == '-';
    if (negative) start = 1;
    if (start == value.len or value[start] == '+') return error.InvalidDecimal;
    const dot = std.mem.findScalar(u8, value[start..], '.') orelse value.len - start;
    const dot_index = start + dot;
    const integer = value[start..dot_index];
    const fraction = if (dot_index < value.len) value[dot_index + 1 ..] else "";
    if (integer.len == 0 or integer.len > 12 or fraction.len > 6 or
        (dot_index < value.len and fraction.len == 0) or
        (integer.len > 1 and integer[0] == '0'))
    {
        return error.InvalidDecimal;
    }
    for (integer) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidDecimal;
    }
    for (fraction) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidDecimal;
    }
    var nonzero = false;
    for (integer) |byte| nonzero = nonzero or byte != '0';
    for (fraction) |byte| nonzero = nonzero or byte != '0';

    var output = std.Io.Writer.Allocating.init(allocator);
    if (negative and nonzero) try output.writer.writeByte('-');
    try output.writer.writeAll(integer);
    try output.writer.writeByte('.');
    try output.writer.writeAll(fraction);
    for (fraction.len..6) |_| try output.writer.writeByte('0');
    return output.toOwnedSlice();
}

fn digestPreparedV2(prepared: PreparedV2) [64]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("analytico/event-payload/v2\x00");
    hashField(&hasher, "site", prepared.site_id);
    hashField(&hasher, "event", prepared.event_id);
    hashField(&hasher, "anonymous", prepared.anonymous_id);
    hashInteger(&hasher, "identity_quality", prepared.identity_quality);
    hashField(&hasher, "session", prepared.session_id);
    hashInteger(&hasher, "sequence", prepared.sequence);
    hashInteger(&hasher, "occurred", prepared.occurred_at_utc_micros);
    hashInteger(&hasher, "kind", prepared.kind);
    hashField(&hasher, "name", prepared.event_name);
    hashField(&hasher, "path", prepared.path);
    hashField(&hasher, "title", prepared.page_title);
    hashField(&hasher, "hostname", prepared.hostname);
    hashField(&hasher, "referrer", prepared.referrer_host);
    hashField(&hasher, "utm_source", prepared.utm_source);
    hashField(&hasher, "utm_medium", prepared.utm_medium);
    hashField(&hasher, "utm_campaign", prepared.utm_campaign);
    hashField(&hasher, "utm_term", prepared.utm_term);
    hashField(&hasher, "utm_content", prepared.utm_content);
    hashField(&hasher, "properties", prepared.properties_json);
    hashField(&hasher, "user", prepared.identify_user_id);
    hashField(&hasher, "traits", prepared.user_traits_json);
    hashField(&hasher, "amount", prepared.value_amount orelse "");
    hashField(&hasher, "currency", prepared.value_currency);
    hashInteger(&hasher, "engagement", prepared.engagement_ms);
    hashInteger(&hasher, "scroll", prepared.max_scroll_depth);
    // Preserve the pre-D31 digest for absent/false so an unchanged event
    // remains idempotent across the schema-4 upgrade. A true flag adds a new
    // component and therefore conflicts with an already stored unflagged row.
    if (prepared.self_excluded) hashInteger(&hasher, "self_excluded", 1);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn hashField(
    hasher: *std.crypto.hash.Blake3,
    name: []const u8,
    value: []const u8,
) void {
    hasher.update(name);
    hasher.update("\x00");
    var length_buffer: [32]u8 = undefined;
    const length = std.fmt.bufPrint(&length_buffer, "{d}", .{value.len}) catch
        unreachable;
    hasher.update(length);
    hasher.update(":");
    hasher.update(value);
    hasher.update("\x00");
}

fn hashInteger(
    hasher: *std.crypto.hash.Blake3,
    name: []const u8,
    value: anytype,
) void {
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
    hashField(hasher, name, text);
}

fn canonicalProperties(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    policy: meta.SitePolicy,
) ![]const u8 {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidProperties,
    };
    if (object.count() > 16) return error.TooManyProperties;
    var keys: std.ArrayList([]const u8) = .empty;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        try domain.validateIdentifier(key);
        if (!policy.allowsProperty(key)) return error.PropertyDenied;
        try validatePropertyValue(entry.value_ptr.*);
        try keys.append(allocator, key);
    }
    insertionSort(keys.items);

    var output = std.Io.Writer.Allocating.init(allocator);
    try output.writer.writeByte('{');
    for (keys.items, 0..) |key, index| {
        if (index != 0) try output.writer.writeByte(',');
        try std.json.Stringify.value(key, .{}, &output.writer);
        try output.writer.writeByte(':');
        try std.json.Stringify.value(object.get(key).?, .{}, &output.writer);
    }
    try output.writer.writeByte('}');
    if (output.written().len > 4096) return error.PropertiesTooLarge;
    return output.toOwnedSlice();
}

fn validatePropertyValue(value: std.json.Value) !void {
    switch (value) {
        .null, .bool, .integer => {},
        .string => |string| {
            if (string.len > 256) return error.PropertyValueTooLarge;
        },
        else => return error.InvalidPropertyValue,
    }
}

fn validateCampaign(value: ?[]const u8) !void {
    const candidate = value orelse return;
    if (candidate.len > 256 or !std.unicode.utf8ValidateSlice(candidate)) {
        return error.InvalidCampaign;
    }
}

fn percentDecode(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) ![]u8 {
    var output = try allocator.alloc(u8, encoded.len);
    var source: usize = 0;
    var target: usize = 0;
    while (source < encoded.len) {
        if (encoded[source] == '%') {
            if (encoded.len - source < 3) return error.InvalidPercentEncoding;
            output[target] = std.fmt.parseInt(u8, encoded[source + 1 .. source + 3], 16) catch
                return error.InvalidPercentEncoding;
            source += 3;
        } else {
            output[target] = if (encoded[source] == '+') ' ' else encoded[source];
            source += 1;
        }
        target += 1;
    }
    const result = output[0..target];
    if (!std.unicode.utf8ValidateSlice(result)) return error.InvalidUtf8;
    return result;
}

fn rawHost(uri: std.Uri) ![]const u8 {
    return switch (uri.host.?) {
        .raw => |host| host,
        .percent_encoded => |host| if (std.mem.findScalar(u8, host, '%') == null)
            host
        else
            error.InvalidHost,
    };
}

fn lowercaseHost(
    allocator: std.mem.Allocator,
    host: []const u8,
) ![]u8 {
    if (host.len == 0 or host.len > 253) return error.InvalidHost;
    const result = try allocator.dupe(u8, host);
    for (result) |*byte| {
        if (byte.* >= 'A' and byte.* <= 'Z') byte.* = std.ascii.toLower(byte.*);
        if (!(std.ascii.isAlphanumeric(byte.*) or byte.* == '.' or
            byte.* == '-' or byte.* == ':' or byte.* == '[' or byte.* == ']'))
        {
            return error.InvalidHost;
        }
    }
    return result;
}

fn insertionSort(keys: [][]const u8) void {
    var index: usize = 1;
    while (index < keys.len) : (index += 1) {
        const value = keys[index];
        var position = index;
        while (position > 0 and
            std.mem.order(u8, value, keys[position - 1]) == .lt)
        {
            keys[position] = keys[position - 1];
            position -= 1;
        }
        keys[position] = value;
    }
}
