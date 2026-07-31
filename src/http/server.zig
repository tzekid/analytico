const std = @import("std");
const domain = @import("../domain.zig");
const meta = @import("../store/meta.zig");
const events = @import("../store/events.zig");
const classify = @import("classify.zig");
const collect = @import("collect.zig");
const rate_limit = @import("rate_limit.zig");
const request_mod = @import("request.zig");
const response = @import("response.zig");

const tracker = @embedFile("tracker.min.js");
const tracker_br = @embedFile("tracker.min.js.br");
const tracker_gzip = @embedFile("tracker.min.js.gz");
const tracker_versioned_path = "/tracker.aef65945.js";
const transparent_gif =
    "GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff" ++
    "!\xf9\x04\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00" ++
    "\x00\x02\x02D\x01\x00;";

const no_store_headers =
    "Cache-Control: no-store, max-age=0\r\n" ++
    "X-Content-Type-Options: nosniff\r\n" ++
    "Referrer-Policy: no-referrer\r\n";

var shutdown_requested = std.atomic.Value(bool).init(false);
var listener_fd = std.atomic.Value(i32).init(-1);
var active_stream_fd = std.atomic.Value(i32).init(-1);

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    host: []const u8,
    port: u16,
) !void {
    if (!(std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1")))
    {
        return error.CollectorMustBindLoopback;
    }
    const meta_path = try std.fs.path.join(allocator, &.{ directory, "meta.db" });
    defer allocator.free(meta_path);
    const event_path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    defer allocator.free(event_path);
    const key_path = try std.fs.path.join(allocator, &.{ directory, "visitor.key" });
    defer allocator.free(key_path);
    const key_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        key_path,
        allocator,
        .limited(33),
    );
    defer {
        std.crypto.secureZero(u8, key_bytes);
        allocator.free(key_bytes);
    }
    if (key_bytes.len != 32) return error.InvalidKeyFile;

    var metadata = try meta.Store.open(allocator, meta_path);
    defer metadata.deinit();
    try metadata.migrate();
    var event_store = try events.Store.open(allocator, event_path);
    defer event_store.deinit();
    try event_store.migrate();
    var policy_arena = std.heap.ArenaAllocator.init(allocator);
    defer policy_arena.deinit();
    const policies = try loadPolicies(policy_arena.allocator(), &metadata);
    var context = Context{
        .allocator = allocator,
        .io = io,
        .metadata = &metadata,
        .events = &event_store,
        .policies = policies,
        .master_key = key_bytes[0..32].*,
    };
    defer std.crypto.secureZero(u8, &context.master_key);

    var address = try std.Io.net.IpAddress.parse(host, port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    shutdown_requested.store(false, .release);
    listener_fd.store(listener.socket.handle, .release);
    defer listener_fd.store(-1, .release);
    var old_term_action: std.posix.Sigaction = undefined;
    const term_action: std.posix.Sigaction = .{
        .handler = .{ .handler = requestShutdown },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &term_action, &old_term_action);
    defer std.posix.sigaction(.TERM, &old_term_action, null);

    std.debug.print("analytico serve http://{s}:{d}\n", .{ host, port });
    while (!shutdown_requested.load(.acquire)) {
        const stream = listener.accept(io) catch |err| {
            if (shutdown_requested.load(.acquire) and
                err == error.SocketNotListening)
            {
                break;
            }
            return err;
        };
        if (shutdown_requested.load(.acquire)) {
            stream.close(io);
            break;
        }
        active_stream_fd.store(stream.socket.handle, .release);
        handle(&context, stream) catch |err| {
            std.log.err("collector request failed: {s}", .{@errorName(err)});
        };
        active_stream_fd.store(-1, .release);
    }
    try event_store.checkpoint();
}

const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    metadata: *meta.Store,
    events: *events.Store,
    policies: []const meta.SitePolicy,
    master_key: [32]u8,
    limiter: rate_limit.Limiter = .{},
    events_healthy: bool = true,
};

fn requestShutdown(_: std.posix.SIG) callconv(.c) void {
    shutdown_requested.store(true, .release);
    const fd = listener_fd.load(.acquire);
    if (fd >= 0) _ = std.os.linux.shutdown(fd, std.os.linux.SHUT.RDWR);
    const stream_fd = active_stream_fd.load(.acquire);
    if (stream_fd >= 0) {
        _ = std.os.linux.shutdown(stream_fd, std.os.linux.SHUT.RDWR);
    }
}

fn handle(context: *Context, stream: std.Io.net.Stream) !void {
    defer stream.close(context.io);
    var read_buffer: [20 * 1024]u8 = undefined;
    var reader = stream.reader(context.io, &read_buffer);
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(context.io, &write_buffer);
    const output = &writer.interface;

    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const request = (request_mod.read(allocator, &reader.interface) catch |err| {
        switch (err) {
            error.PayloadTooLarge => try writeError(output, 413),
            error.UnsupportedTransferEncoding => try writeError(output, 415),
            else => try writeError(output, 400),
        }
        return;
    }) orelse return;
    const path = request.path();

    if (std.mem.eql(u8, path, "/healthz")) {
        if (!std.mem.eql(u8, request.method, "GET")) {
            try methodNotAllowed(output, "GET");
        } else {
            try response.write(output, 200, "text/plain; charset=utf-8", no_store_headers, "ok\n");
        }
        return;
    }
    if (std.mem.eql(u8, path, "/readyz")) {
        if (!std.mem.eql(u8, request.method, "GET")) {
            try methodNotAllowed(output, "GET");
            return;
        }
        if (!context.events_healthy) {
            try response.write(output, 503, "text/plain; charset=utf-8", no_store_headers, "unavailable\n");
            return;
        }
        const metadata_version = context.metadata.migrationVersion() catch {
            try response.write(output, 503, "text/plain; charset=utf-8", no_store_headers, "unavailable\n");
            return;
        };
        const event_version = context.events.migrationVersion() catch {
            try response.write(output, 503, "text/plain; charset=utf-8", no_store_headers, "unavailable\n");
            return;
        };
        if (metadata_version != meta.schema_version or
            event_version != events.schema_version)
        {
            try response.write(output, 503, "text/plain; charset=utf-8", no_store_headers, "unavailable\n");
        } else {
            try response.write(output, 200, "text/plain; charset=utf-8", no_store_headers, "ready\n");
        }
        return;
    }
    if (std.mem.eql(u8, path, "/tracker.js") or
        std.mem.eql(u8, path, tracker_versioned_path))
    {
        if (!std.mem.eql(u8, request.method, "GET")) {
            try methodNotAllowed(output, "GET");
        } else {
            const immutable = std.mem.eql(u8, path, tracker_versioned_path);
            const encoding = request.header("accept-encoding") catch null;
            const use_brotli = if (encoding) |value|
                acceptsEncoding(value, "br")
            else
                false;
            const use_gzip = !use_brotli and if (encoding) |value|
                acceptsEncoding(value, "gzip")
            else
                false;
            const tracker_headers = if (immutable and use_brotli)
                "Cache-Control: public, max-age=31536000, immutable\r\n" ++
                    "X-Content-Type-Options: nosniff\r\n" ++
                    "Vary: Accept-Encoding\r\n" ++
                    "Content-Encoding: br\r\n"
            else if (immutable and use_gzip)
                "Cache-Control: public, max-age=31536000, immutable\r\n" ++
                    "X-Content-Type-Options: nosniff\r\n" ++
                    "Vary: Accept-Encoding\r\n" ++
                    "Content-Encoding: gzip\r\n"
            else if (immutable)
                "Cache-Control: public, max-age=31536000, immutable\r\n" ++
                    "X-Content-Type-Options: nosniff\r\n" ++
                    "Vary: Accept-Encoding\r\n"
            else if (use_brotli)
                "Cache-Control: public, max-age=300\r\n" ++
                    "X-Content-Type-Options: nosniff\r\n" ++
                    "Vary: Accept-Encoding\r\n" ++
                    "Content-Encoding: br\r\n"
            else if (use_gzip)
                "Cache-Control: public, max-age=300\r\n" ++
                    "X-Content-Type-Options: nosniff\r\n" ++
                    "Vary: Accept-Encoding\r\n" ++
                    "Content-Encoding: gzip\r\n"
            else
                "Cache-Control: public, max-age=300\r\n" ++
                    "X-Content-Type-Options: nosniff\r\n" ++
                    "Vary: Accept-Encoding\r\n";
            try response.write(
                output,
                200,
                "text/javascript; charset=utf-8",
                tracker_headers,
                if (use_brotli)
                    tracker_br
                else if (use_gzip)
                    tracker_gzip
                else
                    tracker,
            );
        }
        return;
    }
    if (std.mem.eql(u8, path, "/v1/event")) {
        if (!std.mem.eql(u8, request.method, "POST")) {
            try methodNotAllowed(output, "POST");
        } else {
            postEvent(context, allocator, request, output) catch |err| switch (err) {
                error.DuplicateHeader => try writeError(output, 400),
                else => return err,
            };
        }
        return;
    }
    if (std.mem.eql(u8, path, "/v1/p.gif")) {
        if (!std.mem.eql(u8, request.method, "GET")) {
            try methodNotAllowed(output, "GET");
        } else {
            pixelEvent(context, allocator, request, output) catch |err| switch (err) {
                error.DuplicateHeader => try writeError(output, 400),
                else => return err,
            };
        }
        return;
    }
    try writeError(output, 404);
}

fn postEvent(
    context: *Context,
    allocator: std.mem.Allocator,
    request: request_mod.Request,
    output: *std.Io.Writer,
) !void {
    if (!supportedContentType(try request.header("content-type")) or
        (try request.header("content-encoding")) != null)
    {
        try writeError(output, 415);
        return;
    }
    const payload = collect.parsePost(allocator, request.body) catch {
        try writeError(output, 400);
        return;
    };
    const policy = findPolicy(context.policies, payload.site) orelse {
        try writeError(output, 404);
        return;
    };
    if (policy.disabled) {
        try writeError(output, 404);
        return;
    }
    const raw_origin = (try request.header("origin")) orelse {
        try writeError(output, 403);
        return;
    };
    const origin = domain.normalizeOrigin(allocator, raw_origin) catch {
        try writeError(output, 403);
        return;
    };
    if (!policy.allowsOrigin(origin)) {
        try writeError(output, 403);
        return;
    }
    const prepared = collect.preparePost(allocator, payload, policy) catch {
        try writeError(output, 400);
        return;
    };
    const accepted = acceptEvent(context, allocator, request, prepared) catch |err| {
        try writeError(output, if (err == error.EventWriteFailed) 500 else 400);
        return;
    };
    if (!accepted) {
        try response.write(
            output,
            429,
            "text/plain; charset=utf-8",
            no_store_headers ++ "Retry-After: 1\r\n",
            "rate limited\n",
        );
        return;
    }
    var headers = std.Io.Writer.Allocating.init(allocator);
    try headers.writer.print(
        "{s}Access-Control-Allow-Origin: {s}\r\nVary: Origin\r\n",
        .{ no_store_headers, origin },
    );
    try response.write(output, 204, "text/plain; charset=utf-8", headers.written(), "");
}

fn pixelEvent(
    context: *Context,
    allocator: std.mem.Allocator,
    request: request_mod.Request,
    output: *std.Io.Writer,
) !void {
    const pixel = collect.parsePixel(allocator, request.target) catch {
        try writeError(output, 400);
        return;
    };
    const policy = findPolicy(context.policies, pixel.site) orelse {
        try writeError(output, 404);
        return;
    };
    if (policy.disabled) {
        try writeError(output, 404);
        return;
    }
    const referer = (try request.header("referer")) orelse {
        try writeError(output, 403);
        return;
    };
    const prepared = collect.preparePixel(allocator, pixel, policy, referer) catch {
        try writeError(output, 403);
        return;
    };
    const accepted = acceptEvent(context, allocator, request, prepared) catch |err| {
        try writeError(output, if (err == error.EventWriteFailed) 500 else 400);
        return;
    };
    if (!accepted) {
        try writeError(output, 429);
        return;
    }
    try response.write(
        output,
        200,
        "image/gif",
        no_store_headers,
        transparent_gif,
    );
}

fn acceptEvent(
    context: *Context,
    allocator: std.mem.Allocator,
    request: request_mod.Request,
    prepared: collect.Prepared,
) !bool {
    const client_ip = (try request.header("x-forwarded-for")) orelse "127.0.0.1";
    if (client_ip.len == 0 or client_ip.len > 64 or
        std.mem.findScalar(u8, client_ip, ',') != null)
    {
        return error.InvalidForwardedIp;
    }
    const now = try currentTime();
    const rate_key = domain.networkPrefixHash(prepared.site_id, client_ip) catch
        return error.InvalidForwardedIp;
    if (!context.limiter.allow(rate_key, now.seconds)) return false;

    const user_agent = (try request.header("user-agent")) orelse "";
    if (user_agent.len > 1024) return error.InvalidUserAgent;
    const client = classify.userAgent(user_agent);
    const country_code = classify.country(try request.header("x-analytico-country"));
    const coarse = try std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{
        client.browser,
        client.os,
        client.device,
    });
    const visitor = try domain.deriveVisitorDayId(
        context.master_key,
        prepared.site_id,
        &now.date,
        client_ip,
        coarse,
    );
    const event_id = try domain.randomUuid(context.io);
    context.events.insert(.{
        .event_id = &event_id,
        .site_id = prepared.site_id,
        .received_at_utc_micros = now.micros,
        .received_date_utc = &now.date,
        .kind = prepared.kind,
        .event_name = prepared.event_name,
        .path = prepared.path,
        .visitor_day_id = visitor,
        .referrer_host = prepared.referrer_host,
        .country_code = &country_code,
        .browser_family = client.browser,
        .os_family = client.os,
        .device_category = client.device,
        .utm_source = prepared.utm_source,
        .utm_medium = prepared.utm_medium,
        .utm_campaign = prepared.utm_campaign,
        .utm_term = prepared.utm_term,
        .utm_content = prepared.utm_content,
        .properties_json = prepared.properties_json,
    }) catch {
        context.events_healthy = false;
        return error.EventWriteFailed;
    };
    return true;
}

const CurrentTime = struct {
    seconds: i64,
    micros: i64,
    date: [10]u8,
};

fn currentTime() !CurrentTime {
    var timestamp: std.os.linux.timespec = undefined;
    const result = std.os.linux.clock_gettime(.REALTIME, &timestamp);
    if (std.os.linux.errno(result) != .SUCCESS or timestamp.sec < 0) {
        return error.ClockUnavailable;
    }
    const seconds_micros = std.math.mul(i64, timestamp.sec, 1_000_000) catch
        return error.ClockUnavailable;
    const micros = std.math.add(
        i64,
        seconds_micros,
        @divTrunc(timestamp.nsec, 1_000),
    ) catch return error.ClockUnavailable;
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp.sec) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var date: [10]u8 = undefined;
    _ = try std.fmt.bufPrint(&date, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        @backingInt(month_day.month),
        month_day.day_index + 1,
    });
    return .{ .seconds = timestamp.sec, .micros = micros, .date = date };
}

fn supportedContentType(value: ?[]const u8) bool {
    const content_type = value orelse return false;
    return std.ascii.eqlIgnoreCase(content_type, "text/plain") or
        std.ascii.eqlIgnoreCase(content_type, "text/plain;charset=UTF-8") or
        std.ascii.eqlIgnoreCase(content_type, "text/plain; charset=UTF-8");
}

fn acceptsEncoding(value: []const u8, expected: []const u8) bool {
    var encodings = std.mem.splitScalar(u8, value, ',');
    while (encodings.next()) |raw_encoding| {
        var parts = std.mem.splitScalar(u8, raw_encoding, ';');
        const name = std.mem.trim(u8, parts.next() orelse continue, " \t");
        if (!std.ascii.eqlIgnoreCase(name, expected)) continue;
        while (parts.next()) |raw_parameter| {
            const parameter = std.mem.trim(u8, raw_parameter, " \t");
            const key, const raw_quality = std.mem.cutScalar(u8, parameter, '=') orelse
                return false;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, key, " \t"), "q")) {
                continue;
            }
            const quality = std.fmt.parseFloat(
                f32,
                std.mem.trim(u8, raw_quality, " \t"),
            ) catch return false;
            return quality > 0 and quality <= 1;
        }
        return true;
    }
    return false;
}

fn loadPolicies(
    allocator: std.mem.Allocator,
    metadata: *meta.Store,
) ![]const meta.SitePolicy {
    const ids = try metadata.siteIds(allocator);
    var policies: std.ArrayList(meta.SitePolicy) = .empty;
    for (ids) |id| {
        try policies.append(
            allocator,
            try metadata.sitePolicy(allocator, id),
        );
    }
    return policies.toOwnedSlice(allocator);
}

fn findPolicy(
    policies: []const meta.SitePolicy,
    id: []const u8,
) ?meta.SitePolicy {
    for (policies) |policy| {
        if (std.mem.eql(u8, policy.id, id)) return policy;
    }
    return null;
}

fn methodNotAllowed(output: *std.Io.Writer, allow: []const u8) !void {
    try response.write(
        output,
        405,
        "text/plain; charset=utf-8",
        if (std.mem.eql(u8, allow, "POST"))
            no_store_headers ++ "Allow: POST\r\n"
        else
            no_store_headers ++ "Allow: GET\r\n",
        "method not allowed\n",
    );
}

fn writeError(output: *std.Io.Writer, status: u16) !void {
    const body = switch (status) {
        400 => "bad request\n",
        403 => "forbidden\n",
        404 => "not found\n",
        413 => "payload too large\n",
        415 => "unsupported media type\n",
        429 => "rate limited\n",
        500 => "internal error\n",
        503 => "unavailable\n",
        else => "error\n",
    };
    try response.write(
        output,
        status,
        "text/plain; charset=utf-8",
        no_store_headers,
        body,
    );
}
