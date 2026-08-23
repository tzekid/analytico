const std = @import("std");
const domain = @import("../domain.zig");
const meta = @import("../store/meta.zig");
const events = @import("../store/events.zig");
const classify = @import("classify.zig");
const collect = @import("collect.zig");
const rate_limit = @import("rate_limit.zig");
const request_mod = @import("request.zig");
const response = @import("response.zig");
const dashboard = @import("../web/dashboard.zig");
const dashboard_render = @import("../web/render.zig");
const auth_http = @import("../auth/http.zig");
const auth_store = @import("../auth/store.zig");
const timezone = @import("../timezone.zig");

const tracker_v1 = @embedFile("tracker.v1.min.js");
const tracker_v1_br = @embedFile("tracker.v1.min.js.br");
const tracker_v1_gzip = @embedFile("tracker.v1.min.js.gz");
const tracker = @embedFile("tracker.min.js");
const tracker_br = @embedFile("tracker.min.js.br");
const tracker_gzip = @embedFile("tracker.min.js.gz");
const tracker_v2_anonymous = @embedFile("tracker.fb64c486.min.js");
const tracker_v2_anonymous_br = @embedFile("tracker.fb64c486.min.js.br");
const tracker_v2_anonymous_gzip = @embedFile("tracker.fb64c486.min.js.gz");
const tracker_v2_sessions = @embedFile("tracker.78135195.min.js");
const tracker_v2_sessions_br = @embedFile("tracker.78135195.min.js.br");
const tracker_v2_sessions_gzip = @embedFile("tracker.78135195.min.js.gz");
const tracker_v2_identify = @embedFile("tracker.d9e94247.min.js");
const tracker_v2_identify_br = @embedFile("tracker.d9e94247.min.js.br");
const tracker_v2_identify_gzip = @embedFile("tracker.d9e94247.min.js.gz");
const tracker_v1_path = "/tracker.aef65945.js";
const tracker_v2_anonymous_path = "/tracker.fb64c486.js";
const tracker_v2_sessions_path = "/tracker.78135195.js";
const tracker_v2_identify_path = "/tracker.d9e94247.js";
const tracker_v2_path = "/tracker.81c3b777.js";
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

pub const Options = struct {
    host: []const u8,
    port: u16,
    meta_path: []const u8,
    event_path: []const u8,
    temp_directory: []const u8,
    key_path: []const u8,
    zoneinfo_root: []const u8 = timezone.default_zoneinfo_root,
    report_timeout_ms: u32 = 2_000,
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
) !void {
    if (!(std.mem.eql(u8, options.host, "127.0.0.1") or
        std.mem.eql(u8, options.host, "::1")))
    {
        return error.CollectorMustBindLoopback;
    }
    inline for (.{
        options.meta_path,
        options.event_path,
        options.temp_directory,
        options.key_path,
        options.zoneinfo_root,
    }) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.ProductionPathMustBeAbsolute;
    }
    const key_stat = try std.Io.Dir.cwd().statFile(
        io,
        options.key_path,
        .{ .follow_symlinks = false },
    );
    if (key_stat.kind != .file or key_stat.size != 32) {
        return error.InvalidKeyFile;
    }
    if (key_stat.permissions.toMode() & 0o777 != 0o600) {
        return error.InsecureKeyPermissions;
    }
    const meta_stat = try std.Io.Dir.cwd().statFile(io, options.meta_path, .{});
    const event_stat = try std.Io.Dir.cwd().statFile(io, options.event_path, .{});
    const temp_stat = try std.Io.Dir.cwd().statFile(io, options.temp_directory, .{});
    const zoneinfo_stat = try std.Io.Dir.cwd().statFile(io, options.zoneinfo_root, .{});
    if (meta_stat.kind != .file or event_stat.kind != .file or
        temp_stat.kind != .directory or zoneinfo_stat.kind != .directory)
    {
        return error.InvalidProductionPath;
    }
    const key_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        options.key_path,
        allocator,
        .limited(33),
    );
    defer {
        std.crypto.secureZero(u8, key_bytes);
        allocator.free(key_bytes);
    }
    if (key_bytes.len != 32) return error.InvalidKeyFile;

    var metadata = try meta.Store.open(allocator, options.meta_path);
    defer metadata.deinit();
    try metadata.requireCurrent();
    var event_store = try events.Store.openWithTemp(
        allocator,
        options.event_path,
        options.temp_directory,
    );
    defer event_store.deinit();
    try event_store.requireCurrent();
    var policy_arena = std.heap.ArenaAllocator.init(allocator);
    defer policy_arena.deinit();
    const policies = try loadPolicies(
        policy_arena.allocator(),
        io,
        &metadata,
        options.zoneinfo_root,
    );
    const auth_policy = try (auth_store.Store{ .metadata = &metadata }).policy(
        policy_arena.allocator(),
    );
    var context = Context{
        .allocator = allocator,
        .io = io,
        .metadata = &metadata,
        .events = &event_store,
        .policies = policies,
        .master_key = key_bytes[0..32].*,
        .meta_path = options.meta_path,
        .event_path = options.event_path,
        .key_path = options.key_path,
        .report_timeout_ms = options.report_timeout_ms,
        .auth_policy = auth_policy,
    };
    defer std.crypto.secureZero(u8, &context.master_key);

    var address = try std.Io.net.IpAddress.parse(options.host, options.port);
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

    std.debug.print(
        "{{\"level\":\"info\",\"code\":\"serve_started\",\"host\":\"{s}\"," ++
            "\"port\":{d}}}\n",
        .{ options.host, options.port },
    );
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
            context.counters.request_failures += 1;
            std.debug.print(
                "{{\"level\":\"error\",\"code\":\"request_failed\"," ++
                    "\"category\":\"{s}\"}}\n",
                .{@errorName(err)},
            );
        };
        active_stream_fd.store(-1, .release);
    }
    if (context.events_healthy) try event_store.checkpoint();
    std.debug.print(
        "{{\"level\":\"info\",\"code\":\"serve_stopped\",\"accepted\":{d}," ++
            "\"rejected\":{d},\"rate_limited\":{d},\"bots\":{d}," ++
            "\"unknown_country\":{d},\"unknown_client\":{d}," ++
            "\"duplicates\":{d},\"conflicts\":{d},\"write_failures\":{d}," ++
            "\"request_failures\":{d}}}\n",
        .{
            context.counters.accepted,
            context.counters.rejected,
            context.counters.rate_limited,
            context.counters.bots,
            context.counters.unknown_country,
            context.counters.unknown_client,
            context.counters.duplicates,
            context.counters.conflicts,
            context.counters.write_failures,
            context.counters.request_failures,
        },
    );
}

const Counters = struct {
    accepted: u64 = 0,
    rejected: u64 = 0,
    rate_limited: u64 = 0,
    bots: u64 = 0,
    unknown_country: u64 = 0,
    unknown_client: u64 = 0,
    duplicates: u64 = 0,
    conflicts: u64 = 0,
    write_failures: u64 = 0,
    request_failures: u64 = 0,
};

const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    metadata: *meta.Store,
    events: *events.Store,
    policies: []const RuntimePolicy,
    master_key: [32]u8,
    meta_path: []const u8,
    event_path: []const u8,
    key_path: []const u8,
    report_timeout_ms: u32,
    auth_policy: ?auth_store.Policy,
    auth_limiter: auth_http.Limiter = .{},
    limiter: rate_limit.Limiter = .{},
    events_healthy: bool = true,
    counters: Counters = .{},
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
        context.counters.rejected += 1;
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
        if (!context.events_healthy or !pathsReady(context)) {
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
    if (std.mem.startsWith(u8, path, "/admin")) {
        const policy = context.auth_policy orelse {
            try writeError(output, 503);
            return;
        };
        const auth_dependencies = auth_http.Dependencies{
            .allocator = allocator,
            .io = context.io,
            .metadata = context.metadata,
            .policy = policy,
            .limiter = &context.auth_limiter,
        };
        const auth_handled = auth_http.handlePublic(
            auth_dependencies,
            request,
            output,
        ) catch |err| switch (err) {
            error.DuplicateHeader => {
                try writeError(output, 400);
                return;
            },
            else => return err,
        };
        if (auth_handled) return;
        if (std.mem.eql(u8, path, dashboard_render.stylesheet_path)) {
            const handled = try dashboard.handle(.{
                .allocator = allocator,
                .io = context.io,
                .metadata = context.metadata,
                .events = context.events,
                .csrf_token = "",
                .origin = policy.origin,
                .report_timeout_ms = context.report_timeout_ms,
            }, request, output);
            if (handled) return;
        }
        const session_value = try auth_http.requestSession(auth_dependencies, request);
        if (session_value == null) {
            try auth_http.denyAnonymous(allocator, request, output);
            return;
        }
        var session = session_value.?;
        defer session.deinit(allocator);
        if (try auth_http.handlePrivate(auth_dependencies, request, session, output)) return;
        const handled = dashboard.handle(.{
            .allocator = allocator,
            .io = context.io,
            .metadata = context.metadata,
            .events = context.events,
            .csrf_token = session.csrf_token,
            .origin = policy.origin,
            .report_timeout_ms = context.report_timeout_ms,
        }, request, output) catch |err| switch (err) {
            error.DuplicateHeader => {
                try writeError(output, 400);
                return;
            },
            else => return err,
        };
        if (handled) return;
    }
    if (std.mem.eql(u8, path, "/tracker.js") or
        std.mem.eql(u8, path, tracker_v1_path) or
        std.mem.eql(u8, path, tracker_v2_anonymous_path) or
        std.mem.eql(u8, path, tracker_v2_sessions_path) or
        std.mem.eql(u8, path, tracker_v2_identify_path) or
        std.mem.eql(u8, path, tracker_v2_path))
    {
        if (!std.mem.eql(u8, request.method, "GET")) {
            try methodNotAllowed(output, "GET");
        } else {
            const immutable = std.mem.eql(u8, path, tracker_v1_path) or
                std.mem.eql(u8, path, tracker_v2_anonymous_path) or
                std.mem.eql(u8, path, tracker_v2_sessions_path) or
                std.mem.eql(u8, path, tracker_v2_identify_path) or
                std.mem.eql(u8, path, tracker_v2_path);
            const use_v1 = std.mem.eql(u8, path, tracker_v1_path);
            const use_v2_anonymous = std.mem.eql(u8, path, tracker_v2_anonymous_path);
            const use_v2_sessions = std.mem.eql(u8, path, tracker_v2_sessions_path);
            const use_v2_identify = std.mem.eql(u8, path, tracker_v2_identify_path);
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
                if (use_v1)
                    if (use_brotli) tracker_v1_br else if (use_gzip) tracker_v1_gzip else tracker_v1
                else if (use_v2_anonymous)
                    if (use_brotli) tracker_v2_anonymous_br else if (use_gzip) tracker_v2_anonymous_gzip else tracker_v2_anonymous
                else if (use_v2_sessions)
                    if (use_brotli) tracker_v2_sessions_br else if (use_gzip) tracker_v2_sessions_gzip else tracker_v2_sessions
                else if (use_v2_identify)
                    if (use_brotli) tracker_v2_identify_br else if (use_gzip) tracker_v2_identify_gzip else tracker_v2_identify
                else if (use_brotli)
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
    if (std.mem.eql(u8, path, "/v2/event")) {
        if (!std.mem.eql(u8, request.method, "POST")) {
            try methodNotAllowed(output, "POST");
        } else {
            postEventV2(context, allocator, request, output) catch |err| switch (err) {
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
    if (!context.events_healthy) {
        try reject(context, output, 503);
        return;
    }
    if (!supportedContentType(try request.header("content-type")) or
        (try request.header("content-encoding")) != null)
    {
        try reject(context, output, 415);
        return;
    }
    const payload = collect.parsePost(allocator, request.body) catch {
        try reject(context, output, 400);
        return;
    };
    const policy = findPolicy(context.policies, payload.site) orelse {
        try reject(context, output, 404);
        return;
    };
    if (policy.metadata.disabled) {
        try reject(context, output, 404);
        return;
    }
    const raw_origin = (try request.header("origin")) orelse {
        try reject(context, output, 403);
        return;
    };
    const origin = domain.normalizeOrigin(allocator, raw_origin) catch {
        try reject(context, output, 403);
        return;
    };
    if (!policy.metadata.allowsOrigin(origin)) {
        try reject(context, output, 403);
        return;
    }
    const prepared = collect.preparePost(allocator, payload, policy.metadata) catch {
        try reject(context, output, 400);
        return;
    };
    const accepted = acceptEvent(
        context,
        allocator,
        request,
        prepared,
        policy.timezone,
    ) catch |err| {
        try reject(
            context,
            output,
            if (err == error.EventWriteFailed or
                err == error.TimezoneUnavailable) 500 else 400,
        );
        return;
    };
    if (!accepted) {
        context.counters.rate_limited += 1;
        context.counters.rejected += 1;
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

fn postEventV2(
    context: *Context,
    allocator: std.mem.Allocator,
    request: request_mod.Request,
    output: *std.Io.Writer,
) !void {
    if (!context.events_healthy) {
        try reject(context, output, 503);
        return;
    }
    if (!supportedContentType(try request.header("content-type")) or
        (try request.header("content-encoding")) != null)
    {
        try reject(context, output, 415);
        return;
    }
    const payload = collect.parsePostV2(allocator, request.body) catch {
        try reject(context, output, 400);
        return;
    };
    const policy = findPolicy(context.policies, payload.site) orelse {
        try reject(context, output, 404);
        return;
    };
    if (policy.metadata.disabled) {
        try reject(context, output, 404);
        return;
    }
    const raw_origin = (try request.header("origin")) orelse {
        try reject(context, output, 403);
        return;
    };
    const origin = domain.normalizeOrigin(allocator, raw_origin) catch {
        try reject(context, output, 403);
        return;
    };
    if (!policy.metadata.allowsOrigin(origin)) {
        try reject(context, output, 403);
        return;
    }
    const now = currentTime() catch {
        try reject(context, output, 500);
        return;
    };
    if (!(eventRateAllowed(
        context,
        request,
        policy.metadata.id,
        now.seconds,
    ) catch {
        try reject(context, output, 400);
        return;
    })) {
        context.counters.rate_limited += 1;
        context.counters.rejected += 1;
        try response.write(
            output,
            429,
            "text/plain; charset=utf-8",
            no_store_headers ++ "Retry-After: 1\r\n",
            "rate limited\n",
        );
        return;
    }
    const prepared = collect.preparePostV2(
        allocator,
        payload,
        policy.metadata,
        now.micros,
    ) catch {
        try reject(context, output, 400);
        return;
    };
    acceptEventV2(
        context,
        allocator,
        request,
        prepared,
        now,
        policy.timezone,
    ) catch |err| {
        const status: u16 = switch (err) {
            error.EventIdConflict,
            error.IdentityConflict,
            error.IdentityQualityConflict,
            => 409,
            error.EventWriteFailed, error.TimezoneUnavailable => 500,
            else => 400,
        };
        if (err == error.IdentityConflict) {
            try rejectIdentityConflict(context, output);
        } else {
            try reject(context, output, status);
        }
        return;
    };
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
    if (!context.events_healthy) {
        try reject(context, output, 503);
        return;
    }
    const pixel = collect.parsePixel(allocator, request.target) catch {
        try reject(context, output, 400);
        return;
    };
    const policy = findPolicy(context.policies, pixel.site) orelse {
        try reject(context, output, 404);
        return;
    };
    if (policy.metadata.disabled) {
        try reject(context, output, 404);
        return;
    }
    const referer = (try request.header("referer")) orelse {
        try reject(context, output, 403);
        return;
    };
    const prepared = collect.preparePixel(
        allocator,
        pixel,
        policy.metadata,
        referer,
    ) catch {
        try reject(context, output, 403);
        return;
    };
    const accepted = acceptEvent(
        context,
        allocator,
        request,
        prepared,
        policy.timezone,
    ) catch |err| {
        try reject(
            context,
            output,
            if (err == error.EventWriteFailed or
                err == error.TimezoneUnavailable) 500 else 400,
        );
        return;
    };
    if (!accepted) {
        context.counters.rate_limited += 1;
        try reject(context, output, 429);
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
    site_timezone: timezone.Zone,
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
    if (std.mem.eql(u8, client.device, "bot")) context.counters.bots += 1;
    if (std.mem.eql(u8, country_code[0..], "ZZ")) {
        context.counters.unknown_country += 1;
    }
    if (std.mem.eql(u8, client.browser, "Unknown") or
        std.mem.eql(u8, client.browser, "Other"))
    {
        context.counters.unknown_client += 1;
    }
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
    const local = site_timezone.localAt(now.seconds) catch
        return error.TimezoneUnavailable;
    context.events.insert(.{
        .event_id = &event_id,
        .site_id = prepared.site_id,
        .received_at_utc_micros = now.micros,
        .received_date_utc = &now.date,
        .site_local_date = &local.date,
        .site_utc_offset_minutes = local.offset_minutes,
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
        context.counters.write_failures += 1;
        return error.EventWriteFailed;
    };
    context.counters.accepted += 1;
    return true;
}

fn acceptEventV2(
    context: *Context,
    allocator: std.mem.Allocator,
    request: request_mod.Request,
    prepared: collect.PreparedV2,
    now: CurrentTime,
    site_timezone: timezone.Zone,
) !void {
    const user_agent = (try request.header("user-agent")) orelse "";
    if (user_agent.len > 1024) return error.InvalidUserAgent;
    const client = classify.userAgent(user_agent);
    const country_code = classify.country(try request.header("x-analytico-country"));
    if (std.mem.eql(u8, client.device, "bot")) context.counters.bots += 1;
    if (std.mem.eql(u8, country_code[0..], "ZZ")) {
        context.counters.unknown_country += 1;
    }
    if (std.mem.eql(u8, client.browser, "Unknown") or
        std.mem.eql(u8, client.browser, "Other"))
    {
        context.counters.unknown_client += 1;
    }
    const visitor_day_id = try domain.deriveVisitorDayCompatibilityId(
        prepared.site_id,
        &now.date,
        prepared.anonymous_id,
    );
    const local = site_timezone.localAt(now.seconds) catch
        return error.TimezoneUnavailable;
    const outcome = context.events.insertV2(allocator, .{
        .event_id = prepared.event_id,
        .site_id = prepared.site_id,
        .received_at_utc_micros = now.micros,
        .occurred_at_utc_micros = prepared.occurred_at_utc_micros,
        .received_date_utc = &now.date,
        .site_local_date = &local.date,
        .site_utc_offset_minutes = local.offset_minutes,
        .kind = prepared.kind,
        .event_name = prepared.event_name,
        .path = prepared.path,
        .page_title = prepared.page_title,
        .hostname = prepared.hostname,
        .anonymous_id = prepared.anonymous_id,
        .identity_quality = prepared.identity_quality,
        .session_id = prepared.session_id,
        .sequence = prepared.sequence,
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
        .identify_user_id = prepared.identify_user_id,
        .user_traits_json = prepared.user_traits_json,
        .value_amount = prepared.value_amount,
        .value_currency = prepared.value_currency,
        .engagement_ms = prepared.engagement_ms,
        .max_scroll_depth = prepared.max_scroll_depth,
        .visitor_day_id = visitor_day_id,
        .event_payload_digest = &prepared.event_payload_digest,
    }) catch |err| switch (err) {
        error.EventIdConflict,
        error.IdentityConflict,
        error.IdentityQualityConflict,
        => {
            context.counters.conflicts += 1;
            return err;
        },
        else => {
            context.events_healthy = false;
            context.counters.write_failures += 1;
            return error.EventWriteFailed;
        },
    };
    switch (outcome) {
        .inserted => context.counters.accepted += 1,
        .duplicate => context.counters.duplicates += 1,
    }
}

fn eventRateAllowed(
    context: *Context,
    request: request_mod.Request,
    site_id: []const u8,
    now_seconds: i64,
) !bool {
    const client_ip = (try request.header("x-forwarded-for")) orelse "127.0.0.1";
    if (client_ip.len == 0 or client_ip.len > 64 or
        std.mem.findScalar(u8, client_ip, ',') != null)
    {
        return error.InvalidForwardedIp;
    }
    const rate_key = domain.networkPrefixHash(site_id, client_ip) catch
        return error.InvalidForwardedIp;
    return context.limiter.allow(rate_key, now_seconds);
}

fn pathsReady(context: *Context) bool {
    const meta_stat = std.Io.Dir.cwd().statFile(
        context.io,
        context.meta_path,
        .{},
    ) catch return false;
    const event_stat = std.Io.Dir.cwd().statFile(
        context.io,
        context.event_path,
        .{},
    ) catch return false;
    const key_stat = std.Io.Dir.cwd().statFile(
        context.io,
        context.key_path,
        .{ .follow_symlinks = false },
    ) catch return false;
    return meta_stat.kind == .file and meta_stat.size > 0 and
        event_stat.kind == .file and event_stat.size > 0 and
        key_stat.kind == .file and key_stat.size == 32 and
        key_stat.permissions.toMode() & 0o777 == 0o600;
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

const RuntimePolicy = struct {
    metadata: meta.SitePolicy,
    timezone: timezone.Zone,
};

fn loadPolicies(
    allocator: std.mem.Allocator,
    io: std.Io,
    metadata: *meta.Store,
    zoneinfo_root: []const u8,
) ![]const RuntimePolicy {
    const ids = try metadata.siteIds(allocator);
    var policies: std.ArrayList(RuntimePolicy) = .empty;
    const now = try currentTime();
    for (ids) |id| {
        const policy = try metadata.sitePolicy(allocator, id);
        const site_timezone = try timezone.load(
            allocator,
            io,
            zoneinfo_root,
            policy.timezone_name,
        );
        _ = try site_timezone.localAt(now.seconds);
        try policies.append(
            allocator,
            .{
                .metadata = policy,
                .timezone = site_timezone,
            },
        );
    }
    return policies.toOwnedSlice(allocator);
}

fn findPolicy(
    policies: []const RuntimePolicy,
    id: []const u8,
) ?RuntimePolicy {
    for (policies) |policy| {
        if (std.mem.eql(u8, policy.metadata.id, id)) return policy;
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
        409 => "conflict\n",
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

fn reject(context: *Context, output: *std.Io.Writer, status: u16) !void {
    context.counters.rejected += 1;
    try writeError(output, status);
}

fn rejectIdentityConflict(
    context: *Context,
    output: *std.Io.Writer,
) !void {
    context.counters.rejected += 1;
    try response.write(
        output,
        409,
        "text/plain; charset=utf-8",
        no_store_headers ++ "X-Analytico-Code: identity_conflict\r\n",
        "conflict\n",
    );
}
