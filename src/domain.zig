const std = @import("std");

pub const MatchKind = enum(i64) {
    event = 1,
    path = 2,
    prefix = 3,

    pub fn parse(text: []const u8) !MatchKind {
        if (std.mem.eql(u8, text, "event")) return .event;
        if (std.mem.eql(u8, text, "path")) return .path;
        if (std.mem.eql(u8, text, "prefix")) return .prefix;
        return error.InvalidMatchKind;
    }
};

pub const Event = struct {
    event_id: []const u8,
    site_id: []const u8,
    received_at_utc_micros: i64,
    received_date_utc: []const u8,
    kind: u8,
    event_name: []const u8,
    path: []const u8,
    visitor_day_id: [16]u8,
    referrer_host: []const u8 = "",
    country_code: []const u8 = "ZZ",
    browser_family: []const u8 = "Unknown",
    os_family: []const u8 = "Unknown",
    device_category: []const u8 = "unknown",
    utm_source: []const u8 = "",
    utm_medium: []const u8 = "",
    utm_campaign: []const u8 = "",
    utm_term: []const u8 = "",
    utm_content: []const u8 = "",
    properties_json: []const u8 = "{}",
};

pub fn validateSlug(value: []const u8) !void {
    if (value.len == 0 or value.len > 48) return error.InvalidSlug;
    if (!std.ascii.isAlphanumeric(value[0]) or
        !std.ascii.isAlphanumeric(value[value.len - 1]))
    {
        return error.InvalidSlug;
    }
    for (value) |byte| {
        if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-')) {
            return error.InvalidSlug;
        }
    }
}

pub fn validateName(value: []const u8, maximum: usize) !void {
    if (value.len == 0 or value.len > maximum or !std.unicode.utf8ValidateSlice(value)) {
        return error.InvalidName;
    }
}

pub fn validateIdentifier(value: []const u8) !void {
    if (value.len == 0 or value.len > 64) return error.InvalidIdentifier;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or
            byte == '_' or byte == '-' or byte == '.' or byte == ':'))
        {
            return error.InvalidIdentifier;
        }
    }
}

pub fn validateUuid(value: []const u8) !void {
    if (value.len != 36) return error.InvalidUuid;
    for (value, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return error.InvalidUuid;
        } else if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) {
            return error.InvalidUuid;
        }
    }
}

pub fn validateDate(value: []const u8) !void {
    if (value.len != 10 or value[4] != '-' or value[7] != '-') {
        return error.InvalidDate;
    }
    const year = std.fmt.parseInt(u16, value[0..4], 10) catch return error.InvalidDate;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return error.InvalidDate;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return error.InvalidDate;
    if (year < 1970 or month == 0 or month > 12 or day == 0) return error.InvalidDate;
    const month_lengths = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var maximum = month_lengths[month - 1];
    if (month == 2 and isLeapYear(year)) maximum = 29;
    if (day > maximum) return error.InvalidDate;
}

pub fn normalizePath(value: []const u8) ![]const u8 {
    if (value.len == 0 or value.len > 1024 or value[0] != '/' or
        !std.unicode.utf8ValidateSlice(value))
    {
        return error.InvalidPath;
    }
    const query = std.mem.findScalar(u8, value, '?') orelse value.len;
    const fragment = std.mem.findScalar(u8, value[0..query], '#') orelse query;
    const normalized = value[0..fragment];
    if (normalized.len == 0) return error.InvalidPath;
    return normalized;
}

pub fn normalizeOrigin(
    allocator: std.mem.Allocator,
    value: []const u8,
) ![]u8 {
    if (value.len == 0 or value.len > 512 or !std.unicode.utf8ValidateSlice(value)) {
        return error.InvalidOrigin;
    }
    const uri = std.Uri.parse(value) catch return error.InvalidOrigin;
    if (!(std.mem.eql(u8, uri.scheme, "http") or std.mem.eql(u8, uri.scheme, "https")) or
        uri.host == null or uri.user != null or uri.password != null or
        uri.query != null or uri.fragment != null or !uri.path.isEmpty() and
        !std.mem.eql(u8, try uri.path.toRaw(&[_]u8{}), "/"))
    {
        return error.InvalidOrigin;
    }

    var host_buffer: [512]u8 = undefined;
    const host = uri.host.?.toRaw(&host_buffer) catch return error.InvalidOrigin;
    if (host.len == 0 or host.len > 253) return error.InvalidOrigin;
    const normalized_host = try allocator.dupe(u8, host);
    errdefer allocator.free(normalized_host);
    for (normalized_host) |*byte| {
        if (byte.* >= 'A' and byte.* <= 'Z') byte.* = std.ascii.toLower(byte.*);
        if (!(std.ascii.isAlphanumeric(byte.*) or
            byte.* == '.' or byte.* == '-' or byte.* == ':' or
            byte.* == '[' or byte.* == ']'))
        {
            return error.InvalidOrigin;
        }
    }
    defer allocator.free(normalized_host);

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
        std.fmt.allocPrint(allocator, "{s}://{s}", .{ uri.scheme, normalized_host });
}

pub fn randomUuid(io: std.Io) ![36]u8 {
    var bytes: [16]u8 = undefined;
    try io.randomSecure(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const encoded = std.fmt.bytesToHex(bytes, .lower);
    var output: [36]u8 = undefined;
    @memcpy(output[0..8], encoded[0..8]);
    output[8] = '-';
    @memcpy(output[9..13], encoded[8..12]);
    output[13] = '-';
    @memcpy(output[14..18], encoded[12..16]);
    output[18] = '-';
    @memcpy(output[19..23], encoded[16..20]);
    output[23] = '-';
    @memcpy(output[24..36], encoded[20..32]);
    return output;
}

pub fn deriveVisitorDayId(
    master_key: [32]u8,
    site_id: []const u8,
    utc_date: []const u8,
    ip_text: []const u8,
    coarse_client_key: []const u8,
) ![16]u8 {
    try validateUuid(site_id);
    try validateDate(utc_date);
    if (coarse_client_key.len == 0 or coarse_client_key.len > 128) {
        return error.InvalidClientKey;
    }
    const prefix = try networkPrefix(ip_text);

    const Blake3 = std.crypto.hash.Blake3;
    var day_hasher = Blake3.init(.{ .key = master_key });
    day_hasher.update("analytico/day/v1\x00");
    day_hasher.update(site_id);
    day_hasher.update("\x00");
    day_hasher.update(utc_date);
    var day_key: [32]u8 = undefined;
    day_hasher.final(&day_key);
    defer @memset(&day_key, 0);

    var visitor_hasher = Blake3.init(.{ .key = day_key });
    visitor_hasher.update(prefix.bytes[0..prefix.len]);
    visitor_hasher.update("\x00");
    visitor_hasher.update(coarse_client_key);
    var output: [16]u8 = undefined;
    visitor_hasher.final(&output);
    return output;
}

pub fn parseKeyHex(value: []const u8) ![32]u8 {
    if (value.len != 64) return error.InvalidKey;
    var output: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&output, value) catch return error.InvalidKey;
    return output;
}

fn networkPrefix(value: []const u8) !struct { bytes: [16]u8, len: usize } {
    const address = std.Io.net.IpAddress.parse(value, 0) catch return error.InvalidIpAddress;
    var output: [16]u8 = @splat(0);
    return switch (address) {
        .ip4 => |ip4| result: {
            @memcpy(output[0..3], ip4.bytes[0..3]);
            break :result .{ .bytes = output, .len = 3 };
        },
        .ip6 => |ip6| result: {
            @memcpy(output[0..6], ip6.bytes[0..6]);
            break :result .{ .bytes = output, .len = 6 };
        },
    };
}

fn isLeapYear(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}
