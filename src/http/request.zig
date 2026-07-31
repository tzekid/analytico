const std = @import("std");

pub const max_target_bytes = 4096;
pub const max_header_count = 32;
pub const max_header_bytes = 16 * 1024;
pub const max_body_bytes = 8 * 1024;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: []const u8,
    target: []const u8,
    headers: []const Header,
    body: []const u8,

    pub fn path(self: Request) []const u8 {
        const index = std.mem.findScalar(u8, self.target, '?') orelse
            return self.target;
        return self.target[0..index];
    }

    pub fn header(self: Request, name: []const u8) !?[]const u8 {
        var result: ?[]const u8 = null;
        for (self.headers) |item| {
            if (!std.ascii.eqlIgnoreCase(item.name, name)) continue;
            if (result != null) return error.DuplicateHeader;
            result = item.value;
        }
        return result;
    }
};

pub const ReadError = error{
    BadRequest,
    PayloadTooLarge,
    UnsupportedTransferEncoding,
} || std.mem.Allocator.Error || std.Io.Reader.Error;

pub fn read(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) ReadError!?Request {
    const line = (reader.takeDelimiter('\n') catch |err| return mapReadError(err)) orelse
        return null;
    const request_line = parseRequestLine(line) orelse return error.BadRequest;
    if (request_line.target.len > max_target_bytes) return error.PayloadTooLarge;

    var headers: std.ArrayList(Header) = .empty;
    var header_bytes: usize = 0;
    var content_length: ?usize = null;
    var chunked = false;
    while (true) {
        const raw = (reader.takeDelimiter('\n') catch |err| return mapReadError(err)) orelse
            return error.BadRequest;
        header_bytes = std.math.add(usize, header_bytes, raw.len + 1) catch
            return error.PayloadTooLarge;
        if (header_bytes > max_header_bytes) return error.PayloadTooLarge;
        const line_trimmed = trimLine(raw);
        if (line_trimmed.len == 0) break;
        if (headers.items.len >= max_header_count) return error.PayloadTooLarge;
        const colon = std.mem.findScalar(u8, line_trimmed, ':') orelse
            return error.BadRequest;
        const name = std.mem.trim(u8, line_trimmed[0..colon], " \t");
        const value = std.mem.trim(u8, line_trimmed[colon + 1 ..], " \t");
        if (name.len == 0 or !validHeaderName(name) or containsCtl(value)) {
            return error.BadRequest;
        }
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (content_length != null) return error.BadRequest;
            content_length = std.fmt.parseInt(usize, value, 10) catch
                return error.BadRequest;
            if (content_length.? > max_body_bytes) return error.PayloadTooLarge;
        }
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (!std.ascii.eqlIgnoreCase(value, "chunked") or chunked) {
                return error.UnsupportedTransferEncoding;
            }
            chunked = true;
        }
        try headers.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .value = try allocator.dupe(u8, value),
        });
    }
    if (chunked and content_length != null) return error.BadRequest;

    const body = if (chunked)
        try readChunked(allocator, reader)
    else if (content_length) |length|
        try reader.readAlloc(allocator, length)
    else
        "";
    return .{
        .method = try allocator.dupe(u8, request_line.method),
        .target = try allocator.dupe(u8, request_line.target),
        .headers = try allocator.dupe(Header, headers.items),
        .body = body,
    };
}

const RequestLine = struct {
    method: []const u8,
    target: []const u8,
};

fn parseRequestLine(line: []const u8) ?RequestLine {
    const trimmed = trimLine(line);
    var parts = std.mem.splitScalar(u8, trimmed, ' ');
    const method = parts.next() orelse return null;
    const target = parts.next() orelse return null;
    const version = parts.next() orelse return null;
    if (parts.next() != null or method.len == 0 or target.len == 0 or
        !std.mem.eql(u8, version, "HTTP/1.1"))
    {
        return null;
    }
    return .{ .method = method, .target = target };
}

fn readChunked(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) ReadError![]const u8 {
    var body: std.ArrayList(u8) = .empty;
    while (true) {
        const raw_size = (reader.takeDelimiter('\n') catch |err| return mapReadError(err)) orelse
            return error.BadRequest;
        const size_text = trimLine(raw_size);
        if (size_text.len == 0 or std.mem.findScalar(u8, size_text, ';') != null) {
            return error.BadRequest;
        }
        const size = std.fmt.parseInt(usize, size_text, 16) catch
            return error.BadRequest;
        if (size == 0) {
            const end = (reader.takeDelimiter('\n') catch |err| return mapReadError(err)) orelse
                return error.BadRequest;
            if (trimLine(end).len != 0) return error.BadRequest;
            return body.toOwnedSlice(allocator);
        }
        if (size > max_body_bytes - body.items.len) return error.PayloadTooLarge;
        const chunk = try reader.readAlloc(allocator, size);
        if (chunk.len != size) return error.BadRequest;
        try body.appendSlice(allocator, chunk);
        const ending = (reader.takeDelimiter('\n') catch |err| return mapReadError(err)) orelse
            return error.BadRequest;
        if (ending.len != 1 or ending[0] != '\r') return error.BadRequest;
    }
}

fn trimLine(line: []const u8) []const u8 {
    if (line.len != 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

fn validHeaderName(name: []const u8) bool {
    for (name) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or
            std.mem.findScalar(u8, "!#$%&'*+-.^_`|~", byte) != null))
        {
            return false;
        }
    }
    return true;
}

fn containsCtl(value: []const u8) bool {
    for (value) |byte| {
        if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return true;
    }
    return false;
}

fn mapReadError(err: anyerror) ReadError {
    return switch (err) {
        error.StreamTooLong => error.PayloadTooLarge,
        else => @errorCast(err),
    };
}
