const std = @import("std");
const collector = @import("collector.zig");
const domain = @import("domain.zig");
const store_mod = @import("store.zig");
const trackers = @import("tracker_assets.zig");

var stop_requested: std.atomic.Value(bool) = .init(false);
var listener_handle: std.posix.socket_t = -1;

fn handleStopSignal(_: std.posix.SIG) callconv(.c) void {
    stop_requested.store(true, .release);
    if (listener_handle >= 0) _ = std.os.linux.shutdown(listener_handle, std.os.linux.SHUT.RDWR);
}

pub const Options = struct {
    data: []const u8,
    host: []const u8,
    port: u16,
};

const Headers = struct {
    origin: ?[]const u8 = null,
    user_agent: []const u8 = "",
    forwarded_for: ?[]const u8 = null,
    signature_timestamp: ?[]const u8 = null,
    signature: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    if (!(std.mem.eql(u8, options.host, "127.0.0.1") or std.mem.eql(u8, options.host, "::1"))) {
        return error.ListenerMustBeLoopback;
    }
    const paths = try store_mod.Paths.init(allocator, options.data);
    var master_key = try store_mod.readKey(io, paths.key);
    defer std.crypto.secureZero(u8, &master_key);
    var store = try store_mod.Store.open(allocator, io, options.data, true);
    defer store.close();
    const address = try std.Io.net.IpAddress.parse(options.host, options.port);
    var listener = try address.listen(io, .{ .reuse_address = true, .kernel_backlog = 128 });
    defer listener.deinit(io);
    listener_handle = listener.socket.handle;
    defer listener_handle = -1;
    stop_requested.store(false, .release);
    const stop_action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleStopSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &stop_action, null);
    std.posix.sigaction(.INT, &stop_action, null);
    std.log.info("serve_started host={s} port={d}", .{ options.host, options.port });

    while (!stop_requested.load(.acquire)) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => if (stop_requested.load(.acquire)) break else return err,
        };
        defer stream.close(io);
        serveConnection(allocator, io, &store, master_key, stream) catch |err| {
            std.log.warn("request_failed code={s}", .{@errorName(err)});
        };
    }
    try store.checkpoint();
    std.log.info("serve_stopped", .{});
}

fn serveConnection(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *store_mod.Store,
    master_key: [32]u8,
    stream: std.Io.net.Stream,
) !void {
    var read_buffer: [20 * 1024]u8 = undefined;
    var write_buffer: [16 * 1024]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buffer);
    var stream_writer = stream.writer(io, &write_buffer);
    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
    var request = http_server.receiveHead() catch return error.InvalidHttpRequest;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const method = request.head.method;
    const target = try arena.dupe(u8, request.head.target);
    const headers = try copyHeaders(arena, &request);
    const path = target[0 .. std.mem.findScalar(u8, target, '?') orelse target.len];

    if (method == .GET and std.mem.eql(u8, path, "/healthz")) {
        return respond(&request, .ok, "text/plain; charset=utf-8", "no-store", "ok\n", null);
    }
    if (method == .GET and std.mem.eql(u8, path, "/readyz")) {
        ready(arena, store) catch return respond(&request, .service_unavailable, "text/plain; charset=utf-8", "no-store", "not ready\n", null);
        return respond(&request, .ok, "text/plain; charset=utf-8", "no-store", "ready\n", null);
    }
    if (method == .GET) {
        if (trackers.parsePath(path)) |variant| {
            return respond(&request, .ok, "text/javascript; charset=utf-8", "public, max-age=31536000, immutable", trackers.bytes(variant), null);
        }
    }
    if ((std.mem.eql(u8, path, "/e") or std.mem.eql(u8, path, "/i")) and method == .POST) {
        const content_length = request.head.content_length orelse return respondError(&request, .length_required, "length_required", headers.origin);
        if (content_length == 0 or content_length > collector.maximum_body_bytes) {
            try rejection(arena, store, "oversized_batches");
            return respondError(&request, .payload_too_large, "body_too_large", headers.origin);
        }
        if (headers.content_type) |content_type| {
            if (!(std.mem.startsWith(u8, content_type, "application/json") or
                std.mem.startsWith(u8, content_type, "text/plain")))
            {
                return respondError(&request, .unsupported_media_type, "unsupported_media_type", headers.origin);
            }
        }
        const body = try arena.alloc(u8, @intCast(content_length));
        var body_buffer: [collector.maximum_body_bytes]u8 = undefined;
        const reader = request.readerExpectContinue(&body_buffer) catch return error.InvalidExpectation;
        reader.readSliceAll(body) catch return error.InvalidBody;
        const envelope = collector.parse(arena, body) catch |err| {
            try rejection(arena, store, "invalid_payloads");
            return respondError(&request, .unprocessable_entity, safeCode(err), headers.origin);
        };
        var site = store.siteByPublicId(envelope.site) catch |err| {
            if (storageError(err)) {
                try rejection(arena, store, "storage_failures");
                return respondError(&request, .service_unavailable, safeCode(err), headers.origin);
            }
            try rejection(arena, store, "unknown_sites");
            return respondError(&request, .not_found, safeCode(err), headers.origin);
        };
        defer site.deinit(store.allocator);

        const source: collector.Source = if (std.mem.eql(u8, path, "/e")) .browser else .server;
        if (source == .browser) {
            const raw_origin = headers.origin orelse {
                try rejection(arena, store, "invalid_origins");
                return respondError(&request, .forbidden, "missing_origin", null);
            };
            const normalized_origin = domain.normalizeOrigin(arena, raw_origin) catch {
                try rejection(arena, store, "invalid_origins");
                return respondError(&request, .forbidden, "invalid_origin", null);
            };
            const allowed = store.allowsOrigin(site.id, normalized_origin) catch |err| {
                try rejection(arena, store, "storage_failures");
                return respondError(&request, .service_unavailable, safeCode(err), null);
            };
            if (!allowed) {
                try rejection(arena, store, "invalid_origins");
                return respondError(&request, .forbidden, "origin_denied", null);
            }
        } else {
            collector.verifySignature(
                site.internal_secret,
                headers.signature_timestamp orelse return respondError(&request, .unauthorized, "missing_signature", null),
                headers.signature orelse return respondError(&request, .unauthorized, "missing_signature", null),
                body,
            ) catch |err| {
                try rejection(arena, store, "invalid_signatures");
                return respondError(&request, .unauthorized, safeCode(err), null);
            };
        }

        const client: collector.Client = if (source == .browser) .{
            .peer_ip = clientIp(headers.forwarded_for) catch {
                try rejection(arena, store, "invalid_client_addresses");
                return respondError(&request, .bad_request, "invalid_client_address", headers.origin);
            },
            .user_agent = headers.user_agent,
        } else .{ .peer_ip = "", .user_agent = "" };
        const result = collector.ingest(arena, store, master_key, site, envelope, source, client) catch |err| {
            const status: std.http.Status = if (storageError(err)) .service_unavailable else if (err == error.EventIdConflict) .conflict else if (err == error.SiteDisabled) .forbidden else .unprocessable_entity;
            if (storageError(err)) try rejection(arena, store, "storage_failures") else if (err == error.EventIdConflict) try rejection(arena, store, "conflicts") else try rejection(arena, store, "rejected_records");
            return respondError(&request, status, safeCode(err), if (source == .browser) headers.origin else null);
        };
        std.log.info("batch_accepted accepted={d} duplicates={d} late={d} source={s}", .{
            result.accepted, result.duplicates, result.late, @tagName(source),
        });
        return respond(&request, .no_content, "text/plain; charset=utf-8", "no-store", "", if (source == .browser) headers.origin else null);
    }
    return respondError(&request, .not_found, "not_found", null);
}

fn ready(allocator: std.mem.Allocator, store: *store_mod.Store) !void {
    var statement = try store.database.prepare(allocator, "SELECT 1");
    defer statement.deinit();
    if (try statement.step() != .row or statement.columnInt(0) != 1) return error.DatabaseNotReady;
}

fn copyHeaders(allocator: std.mem.Allocator, request: *const std.http.Server.Request) !Headers {
    var out = Headers{};
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "origin")) {
            if (out.origin != null) return error.DuplicateHeader;
            out.origin = try allocator.dupe(u8, header.value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "user-agent")) {
            out.user_agent = try allocator.dupe(u8, header.value[0..@min(header.value.len, 512)]);
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-forwarded-for")) {
            if (out.forwarded_for != null) return error.DuplicateHeader;
            out.forwarded_for = try allocator.dupe(u8, header.value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-analytico-timestamp")) {
            if (out.signature_timestamp != null) return error.DuplicateHeader;
            out.signature_timestamp = try allocator.dupe(u8, header.value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-analytico-signature")) {
            if (out.signature != null) return error.DuplicateHeader;
            out.signature = try allocator.dupe(u8, header.value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
            out.content_type = try allocator.dupe(u8, header.value);
        }
    }
    return out;
}

fn respond(
    request: *std.http.Server.Request,
    status: std.http.Status,
    content_type: []const u8,
    cache_control: []const u8,
    body: []const u8,
    origin: ?[]const u8,
) !void {
    var headers: [6]std.http.Header = undefined;
    var count: usize = 0;
    headers[count] = .{ .name = "content-type", .value = content_type };
    count += 1;
    headers[count] = .{ .name = "cache-control", .value = cache_control };
    count += 1;
    headers[count] = .{ .name = "x-content-type-options", .value = "nosniff" };
    count += 1;
    headers[count] = .{ .name = "cross-origin-resource-policy", .value = "cross-origin" };
    count += 1;
    if (origin) |value| {
        headers[count] = .{ .name = "access-control-allow-origin", .value = value };
        count += 1;
        headers[count] = .{ .name = "vary", .value = "Origin" };
        count += 1;
    }
    try request.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = headers[0..count] });
}

fn respondError(request: *std.http.Server.Request, status: std.http.Status, code: []const u8, origin: ?[]const u8) !void {
    var buffer: [160]u8 = undefined;
    const body = try std.fmt.bufPrint(&buffer, "{{\"error\":\"{s}\"}}\n", .{code});
    return respond(request, status, "application/json; charset=utf-8", "no-store", body, origin);
}

fn rejection(allocator: std.mem.Allocator, store: *store_mod.Store, name: []const u8) !void {
    var statement = try store.database.prepare(allocator, "INSERT INTO ingest_counters(name,value) VALUES(?,1) ON CONFLICT(name) DO UPDATE SET value=value+1");
    defer statement.deinit();
    try statement.bindText(1, name);
    _ = try statement.step();
}

fn clientIp(forwarded: ?[]const u8) ![]const u8 {
    const raw = forwarded orelse return error.MissingClientAddress;
    if (std.mem.findScalar(u8, raw, ',') != null) return error.InvalidClientAddress;
    const address = std.mem.trim(u8, raw, " \t");
    if (address.len == 0 or address.len > 64) return error.InvalidClientAddress;
    _ = std.Io.net.IpAddress.parse(address, 0) catch return error.InvalidClientAddress;
    return address;
}

fn safeCode(err: anyerror) []const u8 {
    if (storageError(err)) return "storage_unavailable";
    return switch (err) {
        error.InvalidJson, error.InvalidUtf8 => "invalid_json",
        error.EventIdConflict => "event_id_conflict",
        error.UnknownSite => "unknown_site",
        error.SiteDisabled => "site_disabled",
        error.InvalidSignature, error.StaleSignature, error.InvalidSignatureTimestamp => "invalid_signature",
        else => "invalid_record",
    };
}

fn storageError(err: anyerror) bool {
    return err == error.SqliteStepFailed or err == error.SqliteExecFailed or
        err == error.SqlitePrepareFailed or err == error.DatabaseNotReady;
}
