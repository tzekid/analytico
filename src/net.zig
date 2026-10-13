//! Outbound HTTPS for the whole process: one client, so connections are
//! pooled and the system certificates load once. Used for AI providers,
//! sign-in providers and integrations.
const std = @import("std");

var client: std.http.Client = undefined;
var stopping: std.atomic.Value(bool) = .init(false);

/// Called once at startup, before any request.
pub fn init(gpa: std.mem.Allocator, io: std.Io) void {
    stopping.store(false, .release);
    client = .{ .allocator = gpa, .io = io };
}

/// Stop outstanding outbound work before the server joins its threads.
pub fn beginShutdown() void {
    stopping.store(true, .release);
}

/// Closes pooled connections; called once every request has finished.
pub fn deinit() void {
    client.deinit();
}

pub const Request = struct {
    method: std.http.Method = .GET,
    body: ?[]const u8 = null,
    content_type: []const u8 = "application/json",
    headers: []const std.http.Header = &.{},
};

pub const Response = struct { status: std.http.Status, body: []const u8 };

/// Requests use their configured endpoint directly. Redirects are returned
/// to the caller, so credentials never leave that endpoint.
pub fn send(arena: std.mem.Allocator, url: []const u8, request: Request) !Response {
    return bounded(sendRequest, .{ arena, url, request }, 30_000);
}

fn sendRequest(arena: std.mem.Allocator, url: []const u8, request: Request) !Response {
    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        return fetchRequest(arena, url, request) catch |err| {
            // A pooled connection the other side closed while idle fails
            // before anything was processed: one fresh attempt.
            if (attempt == 0 and !stopping.load(.acquire) and stale(err)) continue;
            std.log.warn("http_request_failed host={s} code={s}", .{ host(url), @errorName(err) });
            return error.Unreachable;
        };
    }
}

fn fetchRequest(arena: std.mem.Allocator, url: []const u8, request: Request) !Response {
    const uri = try std.Uri.parse(url);
    var http_request = try client.request(request.method, uri, .{
        .headers = .{
            .user_agent = .{ .override = "Analytico" },
            .content_type = if (request.body == null) .default else .{ .override = request.content_type },
        },
        .extra_headers = request.headers,
        .redirect_behavior = .unhandled,
    });
    defer http_request.deinit();
    errdefer if (http_request.connection) |connection| {
        connection.closing = true;
    };
    if (request.body) |body| {
        try http_request.sendBodyComplete(try arena.dupe(u8, body));
    } else try http_request.sendBodiless();
    var response = try http_request.receiveHead(&.{});
    const size: usize = switch (response.head.content_encoding) {
        .identity => 0,
        .zstd => std.compress.zstd.default_window_len,
        .deflate, .gzip => std.compress.flate.max_window_len,
        .compress => return error.UnsupportedCompressionMethod,
    };
    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, try arena.alloc(u8, size));
    var out: std.Io.Writer.Allocating = .init(arena);
    // Cancellation can leave bodyErr null in Zig 0.17; return an error
    // instead of the convenience fetch's unchecked optional access.
    _ = reader.streamRemaining(&out.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        else => |e| return e,
    };
    return .{ .status = response.head.status, .body = out.written() };
}

/// A request answered with server-sent events: `handler.event(name, data)`
/// runs for each event as it arrives. A non-200 answer comes back whole.
pub fn stream(arena: std.mem.Allocator, url: []const u8, request: Request, handler: anytype) !Response {
    const Handler = @TypeOf(handler);
    const Call = struct {
        fn run(a: std.mem.Allocator, u: []const u8, r: Request, h: Handler) !Response {
            return streamRequest(a, u, r, h);
        }
    };
    return bounded(Call.run, .{ arena, url, request, handler }, 90_000);
}

fn streamRequest(arena: std.mem.Allocator, url: []const u8, request: Request, handler: anytype) !Response {
    const uri = std.Uri.parse(url) catch return error.Unreachable;
    var http_request = client.request(request.method, uri, .{
        .headers = .{
            .user_agent = .{ .override = "Analytico" },
            .content_type = .{ .override = request.content_type },
            .accept_encoding = .omit,
        },
        .extra_headers = request.headers,
        .redirect_behavior = .unhandled,
    }) catch |err| {
        std.log.warn("http_request_failed host={s} code={s}", .{ host(url), @errorName(err) });
        return error.Unreachable;
    };
    defer http_request.deinit();
    errdefer if (http_request.connection) |connection| {
        connection.closing = true;
    };
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

fn Payload(comptime function: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?).error_union.payload;
}

/// One deadline and shutdown cancellation for HTTP and SMTP work.
pub fn bounded(function: anytype, args: std.meta.ArgsTuple(@TypeOf(function)), milliseconds: u32) anyerror!Payload(function) {
    if (stopping.load(.acquire)) return error.Unreachable;
    const Event = union(enum) { response: anyerror!Payload(function), elapsed: std.Io.Cancelable!void };
    var buffer: [2]Event = undefined;
    var pending = std.Io.Select(Event).init(client.io, &buffer);
    defer pending.cancelDiscard();
    try pending.concurrent(.response, function, args);
    try pending.concurrent(.elapsed, waitUntilDeadline, .{ client.io, milliseconds });
    return switch (try pending.await()) {
        .response => |response| response,
        .elapsed => error.Unreachable,
    };
}

fn waitUntilDeadline(io: std.Io, milliseconds: u32) std.Io.Cancelable!void {
    var elapsed: u32 = 0;
    while (elapsed < milliseconds and !stopping.load(.acquire)) : (elapsed += 100) {
        try std.Io.sleep(io, .fromMilliseconds(100), .awake);
    }
}

fn stale(err: anyerror) bool {
    // ReadFailed and WriteFailed also represent cancellation. Retrying them
    // would start uncancelable I/O after the task acknowledged cancellation.
    return err == error.ConnectionResetByPeer or err == error.BrokenPipe or err == error.EndOfStream or err == error.HttpConnectionClosing;
}

fn host(url: []const u8) []const u8 {
    const start = (std.mem.find(u8, url, "://") orelse return "?") + 3;
    const end = std.mem.findAnyPos(u8, url, start, "/?#") orelse url.len;
    const authority = url[start..end];
    return if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority[at + 1 ..] else authority;
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
        .float => |number| if (std.math.isFinite(number) and number >= -9223372036854775808.0 and number < 9223372036854775808.0) @intFromFloat(number) else 0,
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
    try std.testing.expectEqualStrings("example.com", host("https://u:p@example.com/path"));
}

test "provider numbers stay within integer bounds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const payload = parseObject(arena_state.allocator(), "{\"large\":1e300,\"negative\":-1e300,\"fraction\":12.5}").?;
    try std.testing.expectEqual(@as(i64, 0), int(payload, "large"));
    try std.testing.expectEqual(@as(i64, 0), int(payload, "negative"));
    try std.testing.expectEqual(@as(i64, 12), int(payload, "fraction"));
}
