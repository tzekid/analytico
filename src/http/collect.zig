const std = @import("std");
const domain = @import("../domain.zig");
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
