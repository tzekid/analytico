//! The push relay, run by the app publisher: instances hand it a device's
//! push token and a notification already encrypted to that device, and it
//! forwards them to Apple with the publisher's APNs key. It stores nothing
//! and never logs payloads.
//!
//!   analytico-relay --listen 127.0.0.1:4395 --key AuthKey.p8 --key-id ABC123
//!     --team JVVN972Y79 --topic ru.plosca.analytico [--apns http://…]
//!
//! POST /v1/apns {"token":"<hex>","environment":"production"|"development",
//! "payload":"<base64>"} answers 200 when Apple took it, 410 when the device
//! is gone (the instance forgets it) and 502 otherwise.
const std = @import("std");

const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const max_body = 8 * 1024;

const Config = struct {
    key: Ecdsa.KeyPair,
    key_id: []const u8,
    team: []const u8,
    topic: []const u8,
    /// Replaces Apple's hosts, for tests against a stand-in.
    apns: ?[]const u8,
};

var config: Config = undefined;
var io: std.Io = undefined;
var gpa: std.mem.Allocator = undefined;

pub fn main(init: std.process.Init) !void {
    io = init.io;
    gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const listen = option(args, "--listen") orelse "127.0.0.1:4395";
    const key_path = option(args, "--key") orelse return usage();
    const pem = try std.Io.Dir.cwd().readFileAlloc(io, key_path, init.arena.allocator(), .limited(4096));
    config = .{
        .key = try Ecdsa.KeyPair.fromSecretKey(try Ecdsa.SecretKey.fromBytes(try privateKey(init.arena.allocator(), pem))),
        .key_id = option(args, "--key-id") orelse return usage(),
        .team = option(args, "--team") orelse return usage(),
        .topic = option(args, "--topic") orelse return usage(),
        .apns = option(args, "--apns"),
    };
    const colon = std.mem.findScalarLast(u8, listen, ':') orelse return usage();
    const address = try std.Io.net.IpAddress.parse(listen[0..colon], try std.fmt.parseInt(u16, listen[colon + 1 ..], 10));
    var server = try address.listen(io, .{ .reuse_address = true });
    std.log.info("relay_started listen={s} topic={s}", .{ listen, config.topic });
    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.warn("accept_failed code={s}", .{@errorName(err)});
            continue;
        };
        const thread = std.Thread.spawn(.{}, serve, .{stream}) catch {
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn usage() error{Usage} {
    std.log.err("usage: analytico-relay --listen host:port --key AuthKey.p8 --key-id ID --team TEAM --topic BUNDLE_ID [--apns URL]", .{});
    return error.Usage;
}

fn option(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args, 0..) |arg, index| if (std.mem.eql(u8, arg, name) and index + 1 < args.len) return args[index + 1];
    return null;
}

fn serve(stream: std.Io.net.Stream) void {
    defer stream.close(io);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    handle(arena_state.allocator(), stream) catch |err| std.log.warn("request_failed code={s}", .{@errorName(err)});
}

fn handle(arena: std.mem.Allocator, stream: std.Io.net.Stream) !void {
    var read_buffer: [16 * 1024]u8 = undefined;
    var write_buffer: [4 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = try server.receiveHead();
    if (request.head.method == .GET and std.mem.eql(u8, request.head.target, "/healthz")) return reply(&request, .ok, "ok");
    if (request.head.method != .POST or !std.mem.eql(u8, request.head.target, "/v1/apns")) return reply(&request, .not_found, "{\"error\":\"not_found\"}");
    const length = request.head.content_length orelse return reply(&request, .length_required, "{\"error\":\"length_required\"}");
    if (length > max_body) return reply(&request, .payload_too_large, "{\"error\":\"too_large\"}");
    const body = try arena.alloc(u8, @intCast(length));
    var body_buffer: [max_body]u8 = undefined;
    try (try request.readerExpectContinue(&body_buffer)).readSliceAll(body);
    const push = std.json.parseFromSliceLeaky(struct { token: []const u8, environment: []const u8, payload: []const u8 }, arena, body, .{ .ignore_unknown_fields = true }) catch return reply(&request, .bad_request, "{\"error\":\"invalid_json\"}");
    if (push.token.len < 32 or push.token.len > 200 or !allOf(push.token, std.ascii.isHex)) return reply(&request, .bad_request, "{\"error\":\"invalid_token\"}");
    if (push.payload.len == 0 or push.payload.len > 3000 or !allOf(push.payload, isBase64)) return reply(&request, .bad_request, "{\"error\":\"invalid_payload\"}");
    const production = std.mem.eql(u8, push.environment, "production");
    if (!production and !std.mem.eql(u8, push.environment, "development")) return reply(&request, .bad_request, "{\"error\":\"invalid_environment\"}");

    const apple = try apns(arena, push.token, production, push.payload);
    const token_hint = push.token[0..8];
    if (apple.status == 200) return reply(&request, .ok, "{}");
    std.log.info("apns_rejected token={s} status={d} reason={s}", .{ token_hint, apple.status, apple.reason });
    // A device that uninstalled the app or changed environment is gone for good.
    if (apple.status == 410 or std.mem.eql(u8, apple.reason, "BadDeviceToken") or std.mem.eql(u8, apple.reason, "DeviceTokenNotForTopic")) return reply(&request, .gone, "{\"error\":\"gone\"}");
    return reply(&request, .bad_gateway, "{\"error\":\"apns_failed\"}");
}

fn reply(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try request.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}

fn allOf(text: []const u8, comptime check: fn (u8) bool) bool {
    for (text) |byte| if (!check(byte)) return false;
    return true;
}

fn isBase64(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '/' or byte == '=';
}

// ---------------------------------------------------------------- Apple

const Answer = struct { status: u16, reason: []const u8 };

/// One APNs request over HTTP/2 through curl, which brings HTTP/2 and TLS.
/// The notification shows a placeholder until the app's extension decrypts
/// it; `mutable-content` lets the extension run.
fn apns(arena: std.mem.Allocator, token: []const u8, production: bool, payload: []const u8) !Answer {
    const base = config.apns orelse if (production) "https://api.push.apple.com" else "https://api.sandbox.push.apple.com";
    const body = try std.fmt.allocPrint(arena, "{{\"aps\":{{\"alert\":{{\"title\":\"Analytico\",\"body\":\"New notification\"}},\"sound\":\"default\",\"mutable-content\":1}},\"p\":\"{s}\"}}", .{payload});
    // The request goes in curl's config on stdin, so the signing token never
    // shows in the process list.
    var curl_config: std.Io.Writer.Allocating = .init(arena);
    const w = &curl_config.writer;
    try w.print("url = \"{s}/3/device/{s}\"\n", .{ base, token });
    try w.writeAll(if (std.mem.startsWith(u8, base, "http://")) "http2-prior-knowledge\n" else "http2\n");
    try w.print("header = \"authorization: bearer {s}\"\n", .{try signingToken(arena)});
    try w.print("header = \"apns-topic: {s}\"\n", .{config.topic});
    try w.writeAll("header = \"apns-push-type: alert\"\nheader = \"apns-priority: 10\"\nheader = \"content-type: application/json\"\n");
    try w.writeAll("data-binary = \"");
    for (body) |byte| {
        if (byte == '"' or byte == '\\') try w.writeByte('\\');
        try w.writeByte(byte);
    }
    try w.writeAll("\"\nsilent\nmax-time = 15\nwrite-out = \"\\n%{http_code}\"\n");

    var child = try std.process.spawn(io, .{ .argv = &.{ "curl", "-K", "-" }, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
    defer child.kill(io);
    try child.stdin.?.writeStreamingAll(io, curl_config.written());
    child.stdin.?.close(io);
    child.stdin = null;
    var out_buffer: [1024]u8 = undefined;
    var out = child.stdout.?.readerStreaming(io, &out_buffer);
    const output = try out.interface.allocRemaining(arena, .limited(64 * 1024));
    _ = try child.wait(io);
    const newline = std.mem.findScalarLast(u8, output, '\n') orelse return .{ .status = 0, .reason = "curl_failed" };
    const status = std.fmt.parseInt(u16, output[newline + 1 ..], 10) catch 0;
    const reason = if (std.json.parseFromSliceLeaky(struct { reason: []const u8 = "" }, arena, output[0..newline], .{ .ignore_unknown_fields = true })) |parsed| parsed.reason else |_| "";
    return .{ .status = status, .reason = reason };
}

var token_mutex: std.Io.Mutex = .init;
var token_cache: [512]u8 = undefined;
var token_len: usize = 0;
var token_at: i64 = 0;

/// Apple's provider token: ES256 over {kid}/{iss, iat}, reused for 30
/// minutes (Apple refuses a new one more often than every 20).
fn signingToken(arena: std.mem.Allocator) ![]const u8 {
    token_mutex.lockUncancelable(io);
    defer token_mutex.unlock(io);
    const now = std.Io.Clock.real.now(io).toSeconds();
    if (token_len == 0 or now - token_at > 30 * 60) {
        const jwt = try sign(arena, now);
        @memcpy(token_cache[0..jwt.len], jwt);
        token_len = jwt.len;
        token_at = now;
    }
    return arena.dupe(u8, token_cache[0..token_len]);
}

fn sign(arena: std.mem.Allocator, now: i64) ![]const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const header = try std.fmt.allocPrint(arena, "{{\"alg\":\"ES256\",\"kid\":\"{s}\"}}", .{config.key_id});
    const claims = try std.fmt.allocPrint(arena, "{{\"iss\":\"{s}\",\"iat\":{d}}}", .{ config.team, now });
    const signing_input = try std.fmt.allocPrint(arena, "{s}.{s}", .{ try encode(arena, header), try encode(arena, claims) });
    const signature = (try config.key.sign(signing_input, null)).toBytes();
    const out = try arena.alloc(u8, encoder.calcSize(signature.len));
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ signing_input, encoder.encode(out, &signature) });
}

fn encode(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    return encoder.encode(try arena.alloc(u8, encoder.calcSize(text.len)), text);
}

/// The 32-byte scalar inside Apple's PKCS#8 `.p8` key: the ECPrivateKey's
/// version (INTEGER 1) is followed by the key as a 32-byte OCTET STRING.
fn privateKey(arena: std.mem.Allocator, pem: []const u8) ![32]u8 {
    var base64_text: std.ArrayList(u8) = .empty;
    var lines = std.mem.tokenizeAny(u8, pem, "\r\n");
    while (lines.next()) |line| if (!std.mem.startsWith(u8, line, "-----")) try base64_text.appendSlice(arena, std.mem.trim(u8, line, " "));
    const der = try arena.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(base64_text.items));
    try std.base64.standard.Decoder.decode(der, base64_text.items);
    const marker = [_]u8{ 0x02, 0x01, 0x01, 0x04, 0x20 };
    const at = std.mem.find(u8, der, &marker) orelse return error.InvalidKey;
    if (der.len < at + marker.len + 32) return error.InvalidKey;
    return der[at + marker.len ..][0..32].*;
}

test "PKCS#8 key and token signature" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A throwaway key from `openssl genpkey -algorithm EC -pkeyopt
    // ec_paramgen_curve:P-256`, in the PKCS#8 form Apple issues.
    const pem =
        \\-----BEGIN PRIVATE KEY-----
        \\MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgyazm87RyY3P+MqNO
        \\98IamTbeuaPQCkZxAH+XZiwy4/ahRANCAAQDpX2eiiU+9gHAhGMl2hV+WELwZmfG
        \\63vrBwQddYl6aZy89swEkKr3VvzbMRw/8q4lmrZVA6ruzgL33A2RpnRU
        \\-----END PRIVATE KEY-----
    ;
    const secret = try privateKey(arena, pem);
    try std.testing.expectEqualStrings("c9ace6f3b4726373fe32a34ef7c21a9936deb9a3d00a4671007f97662c32e3f6", &std.fmt.bytesToHex(secret, .lower));
    config = .{ .key = try Ecdsa.KeyPair.fromSecretKey(try Ecdsa.SecretKey.fromBytes(secret)), .key_id = "KEY123", .team = "TEAM123", .topic = "test", .apns = null };
    const jwt = try sign(arena, 1700000000);
    const dot = std.mem.findScalarLast(u8, jwt, '.').?;
    var signature: [64]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&signature, jwt[dot + 1 ..]);
    try Ecdsa.Signature.fromBytes(signature).verify(jwt[0..dot], config.key.public_key);
    try std.testing.expect(std.mem.startsWith(u8, jwt, "eyJhbGciOiJFUzI1NiIsImtpZCI6IktFWTEyMyJ9."));
}
