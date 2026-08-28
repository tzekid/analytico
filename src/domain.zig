const std = @import("std");

pub const Mode = enum { lite, session };

pub fn parseMode(value: []const u8) !Mode {
    return std.meta.stringToEnum(Mode, value) orelse error.InvalidTrackingMode;
}

pub fn modeName(mode: Mode) []const u8 {
    return @tagName(mode);
}

pub fn validateUuid(value: []const u8) !void {
    if (value.len != 36) return error.InvalidUuid;
    for (value, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return error.InvalidUuid;
        } else if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) {
            return error.InvalidUuid;
        }
    }
    if (value[14] != '4' or !(value[19] == '8' or value[19] == '9' or
        value[19] == 'a' or value[19] == 'b')) return error.InvalidUuid;
}

pub fn randomUuid(io: std.Io) ![36]u8 {
    var bytes: [16]u8 = undefined;
    try io.randomSecure(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(bytes, .lower);
    var out: [36]u8 = undefined;
    @memcpy(out[0..8], hex[0..8]);
    out[8] = '-';
    @memcpy(out[9..13], hex[8..12]);
    out[13] = '-';
    @memcpy(out[14..18], hex[12..16]);
    out[18] = '-';
    @memcpy(out[19..23], hex[16..20]);
    out[23] = '-';
    @memcpy(out[24..36], hex[20..32]);
    return out;
}

pub fn validateSlug(value: []const u8) !void {
    if (value.len == 0 or value.len > 48) return error.InvalidSlug;
    for (value, 0..) |byte, index| {
        if (std.ascii.isLower(byte) or std.ascii.isDigit(byte)) continue;
        if (byte == '-' and index != 0 and index + 1 != value.len) continue;
        return error.InvalidSlug;
    }
}

pub fn validateName(value: []const u8) !void {
    if (value.len == 0 or value.len > 64) return error.InvalidName;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or
        byte == '_' or byte == '-' or byte == '.' or byte == ':')) return error.InvalidName;
}

pub fn validatePath(value: []const u8) !void {
    if (value.len == 0 or value.len > 512 or value[0] != '/' or
        !std.unicode.utf8ValidateSlice(value) or std.mem.findScalar(u8, value, '?') != null or
        std.mem.findScalar(u8, value, '#') != null) return error.InvalidPath;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidPath;
}

pub fn normalizeOrigin(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len < 8 or value.len > 255 or std.mem.endsWith(u8, value, "/")) {
        return error.InvalidOrigin;
    }
    const uri = std.Uri.parse(value) catch return error.InvalidOrigin;
    if (!(std.mem.eql(u8, uri.scheme, "https") or std.mem.eql(u8, uri.scheme, "http")) or
        uri.host == null or uri.path.percent_encoded.len != 0 or uri.query != null or
        uri.fragment != null or uri.user != null or uri.password != null) return error.InvalidOrigin;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const parsed_host = std.Io.net.HostName.fromUri(uri, &host_buffer) catch return error.InvalidOrigin;
    const host = parsed_host.bytes;
    if (host.len == 0 or host.len > 253) return error.InvalidOrigin;
    var lower = try allocator.alloc(u8, host.len);
    for (host, 0..) |byte, index| lower[index] = std.ascii.toLower(byte);
    defer allocator.free(lower);
    const include_port = if (uri.port) |port|
        !((std.mem.eql(u8, uri.scheme, "http") and port == 80) or
            (std.mem.eql(u8, uri.scheme, "https") and port == 443))
    else
        false;
    return if (include_port)
        std.fmt.allocPrint(allocator, "{s}://{s}:{d}", .{ uri.scheme, lower, uri.port.? })
    else
        std.fmt.allocPrint(allocator, "{s}://{s}", .{ uri.scheme, lower });
}

pub fn nowSeconds() !i64 {
    var ts: std.os.linux.timespec = undefined;
    const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
    if (std.os.linux.errno(rc) != .SUCCESS or ts.sec < 0) return error.ClockUnavailable;
    return @intCast(ts.sec);
}

pub fn nowMilliseconds() !i64 {
    var ts: std.os.linux.timespec = undefined;
    const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
    if (std.os.linux.errno(rc) != .SUCCESS or ts.sec < 0) return error.ClockUnavailable;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divFloor(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

pub fn utcDate(milliseconds: i64) ![10]u8 {
    if (milliseconds < 0) return error.InvalidTimestamp;
    const seconds: u64 = @intCast(@divFloor(milliseconds, 1000));
    const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
    const yd = epoch.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    var out: [10]u8 = undefined;
    _ = try std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        yd.year, @backingInt(md.month), md.day_index + 1,
    });
    return out;
}

pub fn visitorDayId(
    key: [32]u8,
    site_id: []const u8,
    date: []const u8,
    peer_ip: []const u8,
    coarse_client: []const u8,
) [16]u8 {
    var material: [512]u8 = undefined;
    const message = std.fmt.bufPrint(&material, "analytico/visitor-day/v1\x00{s}\x00{s}\x00{s}\x00{s}", .{
        site_id, date, peer_ip, coarse_client,
    }) catch unreachable;
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, message, &key);
    return std.fmt.bytesToHex(mac[0..8].*, .lower);
}

pub fn payloadHash(body: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "canonical identifiers" {
    try validateSlug("spark-date");
    try std.testing.expectError(error.InvalidSlug, validateSlug("SparkDate"));
    try validateName("registration_started");
    try validateUuid("550e8400-e29b-41d4-a716-446655440000");
    try validatePath("/events/frankfurt");
    try std.testing.expectError(error.InvalidPath, validatePath("/x?secret=y"));
}
