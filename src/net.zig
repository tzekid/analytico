//! Outbound HTTPS for the whole process: one client, so connections are
//! pooled and the system certificates load once. Used for AI providers,
//! sign-in providers and integrations.
const std = @import("std");

var client: std.http.Client = undefined;

/// Called once at startup, before any request.
pub fn init(gpa: std.mem.Allocator, io: std.Io) void {
    client = .{ .allocator = gpa, .io = io };
}

pub const Request = struct {
    method: std.http.Method = .GET,
    body: ?[]const u8 = null,
    content_type: []const u8 = "application/json",
    headers: []const std.http.Header = &.{},
};

pub const Response = struct { status: std.http.Status, body: []const u8 };

/// A complete request and response. POSTs never follow redirects, so
/// credentials only reach the host they were meant for.
pub fn send(arena: std.mem.Allocator, url: []const u8, request: Request) !Response {
    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        var out: std.Io.Writer.Allocating = .init(arena);
        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = request.method,
            .payload = request.body,
            .headers = .{
                .user_agent = .{ .override = "Analytico" },
                .content_type = if (request.body == null) .default else .{ .override = request.content_type },
            },
            .extra_headers = request.headers,
            .response_writer = &out.writer,
        }) catch |err| {
            // A pooled connection the other side closed while idle fails
            // before anything was processed: one fresh attempt.
            if (attempt == 0 and stale(err)) continue;
            std.log.warn("http_request_failed host={s} code={s}", .{ host(url), @errorName(err) });
            return error.Unreachable;
        };
        return .{ .status = result.status, .body = out.written() };
    }
}

/// A request answered with server-sent events: `handler.event(name, data)`
/// runs for each event as it arrives. A non-200 answer comes back whole.
pub fn stream(arena: std.mem.Allocator, url: []const u8, request: Request, handler: anytype) !Response {
    const uri = std.Uri.parse(url) catch return error.Unreachable;
    var http_request = client.request(request.method, uri, .{
        .headers = .{
            .user_agent = .{ .override = "Analytico" },
            .content_type = .{ .override = request.content_type },
            .accept_encoding = .omit,
        },
        .extra_headers = request.headers,
    }) catch |err| {
        std.log.warn("http_request_failed host={s} code={s}", .{ host(url), @errorName(err) });
        return error.Unreachable;
    };
    defer http_request.deinit();
    http_request.sendBodyComplete(try arena.dupe(u8, request.body orelse "")) catch return error.Unreachable;
    var redirect_buffer: [2048]u8 = undefined;
    var response = http_request.receiveHead(&redirect_buffer) catch return error.Unreachable;
    var transfer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer);
    if (response.head.status != .ok) {
        var body: std.Io.Writer.Allocating = .init(arena);
        _ = reader.streamRemaining(&body.writer) catch {};
        return .{ .status = response.head.status, .body = body.written() };
    }
    var line: std.Io.Writer.Allocating = .init(arena);
    var name: std.ArrayList(u8) = .empty;
    var data: std.ArrayList(u8) = .empty;
    while (true) {
        line.writer.end = 0;
        _ = reader.streamDelimiter(&line.writer, '\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return error.Unreachable,
        };
        reader.toss(1);
        const text = std.mem.trimEnd(u8, line.written(), "\r");
        if (text.len == 0) {
            if (data.items.len != 0) try handler.event(name.items, data.items);
            name.clearRetainingCapacity();
            data.clearRetainingCapacity();
        } else if (std.mem.startsWith(u8, text, "data:")) {
            if (data.items.len != 0) try data.append(arena, '\n');
            try data.appendSlice(arena, std.mem.trimStart(u8, text[5..], " "));
        } else if (std.mem.startsWith(u8, text, "event:")) {
            name.clearRetainingCapacity();
            try name.appendSlice(arena, std.mem.trim(u8, text[6..], " "));
        }
    }
    if (data.items.len != 0) try handler.event(name.items, data.items);
    return .{ .status = .ok, .body = "" };
}

fn stale(err: anyerror) bool {
    return err == error.ConnectionResetByPeer or err == error.BrokenPipe or err == error.EndOfStream or err == error.HttpConnectionClosing or err == error.ReadFailed or err == error.WriteFailed;
}

fn host(url: []const u8) []const u8 {
    const start = (std.mem.find(u8, url, "://") orelse return "?") + 3;
    const end = std.mem.findAnyPos(u8, url, start, "/?#") orelse url.len;
    return url[start..end];
}

/// Form-encodes one value (RFC 3986 unreserved characters kept).
pub fn formPart(w: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') try w.writeByte(byte) else try w.print("%{X:0>2}", .{byte});
    }
}

// ---------------------------------------------------------------- JSON

pub fn parseObject(arena: std.mem.Allocator, text: []const u8) ?std.json.ObjectMap {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return null;
    return if (parsed == .object) parsed.object else null;
}

pub fn string(map: std.json.ObjectMap, key: []const u8) []const u8 {
    const value = map.get(key) orelse return "";
    return if (value == .string) value.string else "";
}

pub fn int(map: std.json.ObjectMap, key: []const u8) i64 {
    const value = map.get(key) orelse return 0;
    return switch (value) {
        .integer => |number| number,
        .float => |number| @intFromFloat(number),
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch 0,
        .string => |text| std.fmt.parseInt(i64, text, 10) catch 0,
        else => 0,
    };
}

pub fn object(parent: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = parent.get(key) orelse return null;
    return if (value == .object) value.object else null;
}

pub fn array(parent: std.json.ObjectMap, key: []const u8) []const std.json.Value {
    const value = parent.get(key) orelse return &.{};
    return if (value == .array) value.array.items else &.{};
}

test "url host for logs" {
    try std.testing.expectEqualStrings("api.openai.com", host("https://api.openai.com/v1/responses"));
    try std.testing.expectEqualStrings("example.com", host("https://example.com?x=1"));
}
