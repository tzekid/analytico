const std = @import("std");
const collector = @import("collector.zig");
const db_mod = @import("db.zig");
const domain = @import("domain.zig");
const geo_mod = @import("geo.zig");
const replay = @import("replay.zig");
const store_mod = @import("store.zig");
const trackers = @import("assets.zig");
const web = @import("web/app.zig");
const jobs = @import("web/jobs.zig");
const live = @import("live.zig");

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

/// Bounded concurrency: each worker owns one read connection and serves one
/// connection at a time. Writes share one connection behind `write_lock`.
pub const worker_count = 12;

/// Extra read connections for running one page's independent queries in
/// parallel; see `data.prefetch`.
pub const pool_size = 4;

pub const ReadPool = struct {
    mutex: std.Io.Mutex = .init,
    released: std.Io.Condition = .init,
    stores: [pool_size]store_mod.Store = undefined,
    free: [pool_size]bool = @splat(true),

    pub fn acquire(self: *ReadPool, io: std.Io) *db_mod.Db {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (true) {
            for (&self.free, 0..) |*free, index| if (free.*) {
                free.* = false;
                return &self.stores[index].database;
            };
            self.released.waitUncancelable(io, &self.mutex);
        }
    }

    pub fn release(self: *ReadPool, io: std.Io, db: *db_mod.Db) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (&self.stores, &self.free) |*store, *free| if (&store.database == db) {
            free.* = true;
        };
        self.released.signal(io);
    }
};

pub const Shared = struct {
    gpa: std.mem.Allocator,
    readers: *ReadPool,
    io: std.Io,
    data: []const u8,
    master_key: [32]u8,
    store: *store_mod.Store,
    /// Optional: without `geo.bin`, places stay unknown and the regional
    /// consent policy asks everyone.
    geo: ?*const geo_mod.Geo = null,
    replays: *db_mod.Db,
    replay_path: []const u8,
    /// Replay writes have their own file and lock, so recordings never hold
    /// up analytics ingestion.
    replay_lock: std.Io.Mutex = .init,
    write_lock: std.Io.Mutex = .init,
    /// Group commit for tracker batches; see `commitInGroup`.
    ingest_lock: std.Io.Mutex = .init,
    ingest_done: std.Io.Condition = .init,
    ingest_head: ?*IngestJob = null,
    ingest_tail: ?*IngestJob = null,
    ingest_leading: bool = false,
    live: live.Hub = .{},
    heat_cache: @import("web/heatmaps.zig").Cache = .{},
    login_lock: std.Io.Mutex = .init,
    login_failures: [64]LoginFailure = @splat(.{}),

    pub const LoginFailure = struct { ip_hash: u64 = 0, count: u32 = 0, window_start_ms: i64 = 0 };

    pub fn lockWrite(self: *Shared) *db_mod.Db {
        self.write_lock.lockUncancelable(self.io);
        return &self.store.database;
    }

    pub fn unlockWrite(self: *Shared) void {
        self.write_lock.unlock(self.io);
    }

    pub fn lockReplays(self: *Shared) *db_mod.Db {
        self.replay_lock.lockUncancelable(self.io);
        return self.replays;
    }

    pub fn unlockReplays(self: *Shared) void {
        self.replay_lock.unlock(self.io);
    }

    pub fn stopping(_: *Shared) bool {
        return stop_requested.load(.acquire);
    }
};

const Headers = struct {
    origin: ?[]const u8 = null,
    user_agent: []const u8 = "",
    forwarded_for: ?[]const u8 = null,
    signature_timestamp: ?[]const u8 = null,
    signature: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    gpc: bool = false,
};

// One deadline covers all network I/O for a connection. Receiving another byte
// must not let a stalled client keep the single collector indefinitely.
// Database work stays synchronous and is never canceled by this deadline.
pub const Connection = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    deadline: std.Io.Clock.Timestamp,
    reader: std.Io.Reader,
    writer: std.Io.Writer,

    pub fn init(io: std.Io, stream: std.Io.net.Stream, read_buffer: []u8, write_buffer: []u8) Connection {
        return .{
            .io = io,
            .stream = stream,
            .deadline = .fromNow(io, .{ .raw = .fromSeconds(2), .clock = .awake }),
            .reader = .{ .vtable = &.{ .stream = read }, .buffer = read_buffer, .seek = 0, .end = 0 },
            .writer = .{ .vtable = &.{ .drain = write }, .buffer = write_buffer },
        };
    }

    fn wait(self: *Connection, events: i16) error{NetworkTimeout}!void {
        var fds = [_]std.posix.pollfd{.{ .fd = self.stream.socket.handle, .events = events, .revents = 0 }};
        while (true) {
            const remaining = self.deadline.durationFromNow(self.io).raw.toMilliseconds();
            if (remaining <= 0) return error.NetworkTimeout;
            const rc = std.c.poll(&fds, fds.len, @intCast(remaining));
            switch (std.posix.errno(rc)) {
                .SUCCESS => if (rc > 0) return else return error.NetworkTimeout,
                .INTR => continue,
                else => return error.NetworkTimeout,
            }
        }
    }

    fn read(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Connection = @alignCast(@fieldParentPtr("reader", reader));
        const data = limit.slice(try writer.writableSliceGreedy(1));
        while (true) {
            self.wait(std.posix.POLL.IN) catch return error.ReadFailed;
            const rc = std.c.recv(self.stream.socket.handle, data.ptr, data.len, std.posix.MSG.DONTWAIT);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return error.EndOfStream;
                    const n: usize = @intCast(rc);
                    writer.advance(n);
                    return n;
                },
                .INTR, .AGAIN => continue,
                else => return error.ReadFailed,
            }
        }
    }

    fn write(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Connection = @alignCast(@fieldParentPtr("writer", writer));
        const bytes = bytes: {
            if (writer.end != 0) break :bytes writer.buffered();
            for (data[0 .. data.len - @intFromBool(splat == 0)]) |part| {
                if (part.len != 0) break :bytes part;
            }
            return 0;
        };
        while (true) {
            self.wait(std.posix.POLL.OUT) catch return error.WriteFailed;
            // Poll readiness alone cannot bound a blocking send. Keep the
            // syscall nonblocking and recheck the same deadline on retry.
            const rc = std.c.send(self.stream.socket.handle, bytes.ptr, bytes.len, std.posix.MSG.DONTWAIT | std.posix.MSG.NOSIGNAL);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return error.WriteFailed;
                    return writer.consume(@intCast(rc));
                },
                .INTR, .AGAIN => continue,
                else => return error.WriteFailed,
            }
        }
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    if (!(std.mem.eql(u8, options.host, "127.0.0.1") or std.mem.eql(u8, options.host, "::1"))) {
        return error.ListenerMustBeLoopback;
    }
    const paths = try store_mod.Paths.init(allocator, options.data);
    defer paths.deinit(allocator);
    var master_key = try store_mod.readKey(io, paths.key);
    defer std.crypto.secureZero(u8, &master_key);
    var store = try store_mod.Store.open(allocator, io, options.data, true);
    defer store.close();
    // Statistics for the planner, limited so a large database starts quickly;
    // the nightly job refreshes them in full.
    try store.database.exec("PRAGMA optimize=0x10002");
    var replays = try replay.open(allocator, paths.replays, true);
    defer replays.close();
    var geo: ?geo_mod.Geo = geo_mod.Geo.open(io, paths.geo) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (geo) |*value| value.close(io);
    var pool: ReadPool = .{};
    var pooled: usize = 0;
    defer for (pool.stores[0..pooled]) |*reader| reader.close();
    while (pooled < pool_size) : (pooled += 1) pool.stores[pooled] = try store_mod.Store.open(allocator, io, options.data, false);
    var shared: Shared = .{
        .gpa = allocator,
        .readers = &pool,
        .io = io,
        .data = options.data,
        .master_key = master_key,
        .store = &store,
        .geo = if (geo) |*value| value else null,
        .replays = &replays,
        .replay_path = paths.replays,
    };
    for (&pool.stores) |*reader| try attachReplays(&shared, &reader.database);
    @import("assets.zig").init();
    const address = try std.Io.net.IpAddress.parse(options.host, options.port);
    var listener = try address.listen(io, .{ .reuse_address = true, .kernel_backlog = 256 });
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

    var threads: [worker_count + 2]std.Thread = undefined;
    var started: usize = 0;
    errdefer {
        stopAll();
        for (threads[0..started]) |thread| thread.join();
    }
    while (started < worker_count) : (started += 1) {
        threads[started] = try std.Thread.spawn(.{}, worker, .{ &shared, &listener });
    }
    threads[started] = try std.Thread.spawn(.{}, jobs.run, .{&shared});
    started += 1;
    threads[started] = try std.Thread.spawn(.{}, live.run, .{&shared});
    started += 1;
    std.log.info("serve_started host={s} port={d} workers={d} geo={s}", .{ options.host, options.port, worker_count, if (geo != null) "on" else "off" });
    while (!stop_requested.load(.acquire)) std.Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
    // Shutting the listener down ends every accept loop; active requests and
    // their transactions finish before the joins return.
    stopAll();
    for (threads[0..started]) |thread| thread.join();
    try store.checkpoint();
    std.log.info("serve_stopped", .{});
}

fn stopAll() void {
    stop_requested.store(true, .release);
    if (listener_handle >= 0) _ = std.os.linux.shutdown(listener_handle, std.os.linux.SHUT.RDWR);
}

fn worker(shared: *Shared, listener: *std.Io.net.Server) void {
    var read_store = store_mod.Store.open(shared.gpa, shared.io, shared.data, false) catch |err| {
        std.log.err("worker_open_failed code={s}", .{@errorName(err)});
        stopAll();
        return;
    };
    defer read_store.close();
    attachReplays(shared, &read_store.database) catch |err| {
        std.log.err("worker_attach_failed code={s}", .{@errorName(err)});
        stopAll();
        return;
    };
    while (!stop_requested.load(.acquire)) {
        const stream = listener.accept(shared.io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => if (stop_requested.load(.acquire)) break else {
                std.log.warn("accept_failed code={s}", .{@errorName(err)});
                continue;
            },
        };
        // A live stream is handed to the broadcaster, which closes it later.
        var handed_over = false;
        serveConnection(shared, &read_store.database, stream, &handed_over) catch |err| {
            std.log.warn("request_failed code={s}", .{@errorName(err)});
        };
        if (!handed_over) stream.close(shared.io);
    }
}

/// Read connections see the replay database as `rp`.
pub fn attachReplays(shared: *Shared, database: *db_mod.Db) !void {
    var statement = try database.prepare(shared.gpa, "ATTACH DATABASE ? AS rp");
    defer statement.deinit();
    try statement.bindText(1, shared.replay_path);
    _ = try statement.step();
}

/// Sets `handed_over` when the connection now belongs to the live broadcaster.
fn serveConnection(shared: *Shared, read_db: *db_mod.Db, stream: std.Io.net.Stream, handed_over: *bool) !void {
    const allocator = shared.gpa;
    const io = shared.io;
    var read_buffer: [24 * 1024]u8 = undefined;
    var write_buffer: [16 * 1024]u8 = undefined;
    var connection = Connection.init(io, stream, &read_buffer, &write_buffer);
    var http_server = std.http.Server.init(&connection.reader, &connection.writer);
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
        ready(arena, read_db) catch return respond(&request, .service_unavailable, "text/plain; charset=utf-8", "no-store", "not ready\n", null);
        return respond(&request, .ok, "text/plain; charset=utf-8", "no-store", "ready\n", null);
    }
    if (method == .GET) {
        if (trackers.parseScript(path)) |variant| {
            return respond(&request, .ok, "text/javascript; charset=utf-8", "public, max-age=31536000, immutable", trackers.bytes(variant), null);
        }
        if (trackers.parseOlder(path)) |variant| {
            return respond(&request, .ok, "text/javascript; charset=utf-8", "public, max-age=3600", trackers.bytes(variant), null);
        }
    }
    if (method == .POST and std.mem.eql(u8, path, "/r")) return replayChunk(arena, shared, read_db, &request, headers, target);
    // POST so browsers always send Origin, even when the collector shares the site's origin.
    if (method == .POST and std.mem.eql(u8, path, "/h")) return heatmap(arena, shared, read_db, &request, headers, target);
    if (!((std.mem.eql(u8, path, "/e") or std.mem.eql(u8, path, "/i")) and method == .POST)) {
        // The workspace has its own, longer deadline; reads stay bounded by
        // the body limit and the deadline still caps stalled clients.
        connection.deadline = .fromNow(io, .{ .raw = .fromSeconds(30), .clock = .awake });
        const live_site = try web.handle(arena, shared, read_db, &request, &connection.deadline, target, path);
        if (live_site) |site_id| {
            handed_over.* = shared.live.add(io, stream, site_id);
            if (!handed_over.*) return respond(&request, .service_unavailable, "text/plain; charset=utf-8", "no-store", "too many live streams\n", null);
        }
        return;
    }
    const content_length = request.head.content_length orelse return respondError(&request, .length_required, "length_required", headers.origin);
    if (content_length == 0 or content_length > collector.maximum_body_bytes) {
        try rejection(arena, shared, "oversized_batches");
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
        try rejection(arena, shared, "invalid_payloads");
        return respondError(&request, .unprocessable_entity, safeCode(err), headers.origin);
    };
    // Network reads are complete; the batch joins the next shared commit.
    var job: IngestJob = .{ .arena = arena, .shared = shared, .headers = headers, .path = path, .body = body, .envelope = envelope };
    commitInGroup(shared, &job);
    const outcome = job.outcome;
    if (outcome.forgotten.len != 0) {
        const replays = shared.lockReplays();
        defer shared.unlockReplays();
        replay.forgetVisitors(arena, replays, outcome.site_id, outcome.forgotten) catch |err| std.log.err("replay_forget_failed code={s}", .{@errorName(err)});
    }
    if (outcome.json) |json| return respond(&request, outcome.status, "application/json", "no-store", json, outcome.origin);
    if (outcome.status == .no_content) return respond(&request, .no_content, "text/plain; charset=utf-8", "no-store", "", outcome.origin);
    return respondError(&request, outcome.status, outcome.code, outcome.origin);
}

/// One tracker or server batch waiting for the shared ingest transaction.
pub const IngestJob = struct {
    arena: std.mem.Allocator,
    shared: *Shared,
    headers: Headers,
    path: []const u8,
    body: []const u8,
    envelope: collector.Envelope,
    outcome: Outcome = .{ .status = .service_unavailable, .code = "storage_unavailable" },
    finished: bool = false,
    next: ?*IngestJob = null,
};

/// The response a batch gets once its transaction committed.
const Outcome = struct {
    status: std.http.Status,
    /// Error code for the JSON error body.
    code: []const u8 = "",
    /// The full response body for Full-mode decisions.
    json: ?[]const u8 = null,
    origin: ?[]const u8 = null,
    site_id: i64 = 0,
    forgotten: []const []const u8 = &.{},
};

/// Group commit: concurrent batches share one transaction and one disk sync.
/// A batch arriving while no commit runs leads: it takes every queued batch,
/// runs each in its own savepoint, commits once and wakes the others. A lone
/// batch commits at once, so light traffic waits for nothing.
fn commitInGroup(shared: *Shared, job: *IngestJob) void {
    const io = shared.io;
    shared.ingest_lock.lockUncancelable(io);
    defer shared.ingest_lock.unlock(io);
    if (shared.ingest_tail) |tail| tail.next = job else shared.ingest_head = job;
    shared.ingest_tail = job;
    while (!job.finished) {
        if (shared.ingest_leading) {
            shared.ingest_done.waitUncancelable(io, &shared.ingest_lock);
            continue;
        }
        shared.ingest_leading = true;
        const group = shared.ingest_head;
        shared.ingest_head = null;
        shared.ingest_tail = null;
        shared.ingest_lock.unlock(io);
        runGroup(shared, group);
        shared.ingest_lock.lockUncancelable(io);
        var cursor = group;
        while (cursor) |member| {
            cursor = member.next;
            member.finished = true;
        }
        shared.ingest_leading = false;
        shared.ingest_done.broadcast(io);
    }
}

fn runGroup(shared: *Shared, group: ?*IngestJob) void {
    const db = shared.lockWrite();
    defer shared.unlockWrite();
    const failed: Outcome = .{ .status = .service_unavailable, .code = "storage_unavailable" };
    db.exec("BEGIN IMMEDIATE") catch {
        var cursor = group;
        while (cursor) |member| : (cursor = member.next) member.outcome = failed;
        return;
    };
    var cursor = group;
    while (cursor) |member| : (cursor = member.next) {
        db.exec("SAVEPOINT batch") catch {
            member.outcome = failed;
            continue;
        };
        member.outcome = ingestBatch(member) catch |err| blk: {
            db.exec("ROLLBACK TO batch") catch {};
            break :blk .{ .status = .service_unavailable, .code = safeCode(err), .origin = member.headers.origin };
        };
        db.exec("RELEASE batch") catch {};
    }
    db.exec("COMMIT") catch {
        db.exec("ROLLBACK") catch {};
        cursor = group;
        while (cursor) |member| : (cursor = member.next) member.outcome = failed;
    };
}

/// "https://shop.example:8443" → "shop.example".
fn originHost(origin: []const u8) []const u8 {
    const start = if (std.mem.find(u8, origin, "://")) |index| index + 3 else 0;
    const rest = origin[start..];
    return rest[0 .. std.mem.findScalar(u8, rest, ':') orelse rest.len];
}

/// Validates and stores one batch inside the group transaction. Rejections
/// are counted after rolling the batch's own changes back.
fn ingestBatch(job: *IngestJob) !Outcome {
    const arena = job.arena;
    const shared = job.shared;
    const store = shared.store;
    const headers = job.headers;
    const envelope = job.envelope;
    var site = store.siteByPublicId(envelope.site) catch |err| {
        if (storageError(err)) return err;
        try rejectionLocked(arena, store, "unknown_sites");
        return .{ .status = .not_found, .code = safeCode(err), .origin = headers.origin };
    };
    defer site.deinit(store.allocator);

    const source: collector.Source = if (std.mem.eql(u8, job.path, "/e")) .browser else .server;
    if (source == .browser) {
        const raw_origin = headers.origin orelse {
            try rejectionLocked(arena, store, "invalid_origins");
            return .{ .status = .forbidden, .code = "missing_origin" };
        };
        const normalized_origin = domain.normalizeOrigin(arena, raw_origin) catch {
            try rejectionLocked(arena, store, "invalid_origins");
            return .{ .status = .forbidden, .code = "invalid_origin" };
        };
        if (!try store.allowsOrigin(site.id, normalized_origin)) {
            try rejectionLocked(arena, store, "invalid_origins");
            return .{ .status = .forbidden, .code = "origin_denied" };
        }
    } else {
        collector.verifySignature(
            site.internal_secret,
            headers.signature_timestamp orelse return .{ .status = .unauthorized, .code = "missing_signature" },
            headers.signature orelse return .{ .status = .unauthorized, .code = "missing_signature" },
            job.body,
        ) catch |err| {
            try rejectionLocked(arena, store, "invalid_signatures");
            return .{ .status = .unauthorized, .code = safeCode(err) };
        };
    }

    const reply_origin = if (source == .browser) headers.origin else null;
    var client: collector.Client = if (source == .browser) .{
        .peer_ip = clientIp(headers.forwarded_for) catch {
            try rejectionLocked(arena, store, "invalid_client_addresses");
            return .{ .status = .bad_request, .code = "invalid_client_address", .origin = headers.origin };
        },
        .user_agent = headers.user_agent,
        .gpc = headers.gpc,
        .page_host = originHost(domain.normalizeOrigin(arena, headers.origin orelse "") catch ""),
    } else .{ .peer_ip = "", .user_agent = "" };
    // The address is used for the place and the day pseudonym, then dropped.
    if (source == .browser) if (shared.geo) |geo| {
        client.place = geo.lookup(client.peer_ip);
    };
    const result = collector.ingest(arena, store, shared.master_key, site, envelope, source, client) catch |err| {
        if (storageError(err)) return err;
        try store.database.exec("ROLLBACK TO batch");
        const status: std.http.Status = if (err == error.EventIdConflict) .conflict else if (err == error.SiteDisabled) .forbidden else .unprocessable_entity;
        try rejectionLocked(arena, store, if (err == error.EventIdConflict) "conflicts" else "rejected_records");
        return .{ .status = status, .code = safeCode(err), .origin = reply_origin };
    };
    std.log.info("batch_accepted accepted={d} duplicates={d} late={d} source={s}", .{
        result.accepted, result.duplicates, result.late, @tagName(source),
    });
    var outcome: Outcome = .{ .status = .no_content, .origin = reply_origin, .site_id = site.id, .forgotten = result.forgotten.items };
    // Full-mode trackers read the consent decision for this visitor.
    if (source == .browser and envelope.v >= 2 and site.mode == .full) {
        outcome.status = .ok;
        outcome.json = try decisionJson(arena, shared, site, result);
    }
    return outcome;
}

/// What a Full-mode tracker should do next: stay Lite ("never"), ask
/// ("ask", with the banner if the site shows one) or keep or start identity
/// ("grant"). Consented visitors also get the cross-domain link and replay
/// settings.
fn decisionJson(arena: std.mem.Allocator, shared: *Shared, site: store_mod.Site, result: collector.Result) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("{{\"upgrade\":\"{s}\"", .{@tagName(result.decision)});
    if (result.dropped) try w.writeAll(",\"drop\":true");
    if (result.decision == .ask and site.consent_banner) {
        try w.writeAll(",\"banner\":{\"text\":");
        try std.json.Stringify.value(site.banner_text, .{}, w);
        try w.writeAll(",\"privacy_url\":");
        try std.json.Stringify.value(site.privacy_url, .{}, w);
        try w.writeByte('}');
    }
    if (result.identity) |identity| if (result.decision != .never) {
        // Pages never recorded: no replay, no heatmap clicks.
        var patterns: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.tokenizeAny(u8, site.record_exclude, "\r\n");
        while (lines.next()) |line| try patterns.append(arena, std.mem.trim(u8, line, " "));
        try w.writeAll(",\"exclude\":");
        try std.json.Stringify.value(patterns.items, .{}, w);
        const origins = try shared.store.origins(arena, site.id);
        if (origins.len > 1) {
            var payload_buffer: [160]u8 = undefined;
            const payload = try collector.linkPayload(&payload_buffer, site.public_id, identity.visitor_id, identity.session_id);
            var token_buffer: [300]u8 = undefined;
            const token = try domain.signToken(&token_buffer, shared.master_key, "link", payload, domain.nowMs() + 30 * 60_000);
            try w.writeAll(",\"link\":");
            try std.json.Stringify.value(token, .{}, w);
            try w.writeAll(",\"domains\":");
            try std.json.Stringify.value(origins, .{}, w);
        }
        if (site.replay_percent > 0 or site.replay_triggers) {
            try w.print(",\"replay\":{{\"rate\":{d},\"triggers\":{},\"mask_text\":{},\"goals\":[", .{ site.replay_percent, site.replay_triggers, site.mask_text });
            var goals = try shared.store.database.prepare(arena, "SELECT match_value FROM goals WHERE site_id=? AND kind='event' ORDER BY name LIMIT 32");
            defer goals.deinit();
            try goals.bindInt(1, site.id);
            var first = true;
            while (try goals.step() == .row) {
                if (!first) try w.writeByte(',');
                first = false;
                try std.json.Stringify.value(goals.columnText(0), .{}, w);
            }
            try w.writeAll("]}");
        }
    };
    try w.writeByte('}');
    return out.written();
}

fn queryValue(arena: std.mem.Allocator, target: []const u8, key: []const u8) ?[]const u8 {
    const start = std.mem.findScalar(u8, target, '?') orelse return null;
    const params = @import("web/html.zig").Params.parse(arena, target[start + 1 ..]) catch return null;
    return params.get(key);
}

/// Origin check shared by /r and /h: the request must come from one of the
/// site's configured origins.
fn siteOrigin(arena: std.mem.Allocator, read_db: *db_mod.Db, site_id: i64, raw: ?[]const u8) !?[]const u8 {
    const origin = domain.normalizeOrigin(arena, raw orelse return null) catch return null;
    var statement = try read_db.prepare(arena, "SELECT 1 FROM site_origins WHERE site_id=? AND origin=?");
    defer statement.deinit();
    try statement.bindInt(1, site_id);
    try statement.bindText(2, origin);
    return if (try statement.step() == .row) raw.? else null;
}

const ReplaySite = struct { id: i64, mode: []const u8, enabled: bool, recording: bool };

fn replaySite(arena: std.mem.Allocator, read_db: *db_mod.Db, public_id: []const u8) !?ReplaySite {
    var statement = try read_db.prepare(arena, "SELECT id,tracking_mode,enabled,replay_percent>0 OR replay_triggers=1 FROM sites WHERE public_id=?");
    defer statement.deinit();
    try statement.bindText(1, public_id);
    if (try statement.step() != .row) return null;
    return .{ .id = statement.columnInt(0), .mode = try arena.dupe(u8, statement.columnText(1)), .enabled = statement.columnBool(2), .recording = statement.columnBool(3) };
}

/// POST /r: one gzip-compressed chunk of rrweb events for a consented,
/// identified session that the site records. Metadata travels in the query.
fn replayChunk(arena: std.mem.Allocator, shared: *Shared, read_db: *db_mod.Db, request: *std.http.Server.Request, headers: Headers, target: []const u8) !void {
    const public_id = queryValue(arena, target, "site") orelse return respondError(request, .bad_request, "invalid_replay", null);
    domain.validateUuid(public_id) catch return respondError(request, .bad_request, "invalid_replay", null);
    const site = (try replaySite(arena, read_db, public_id)) orelse return respondError(request, .not_found, "unknown_site", null);
    const origin = (try siteOrigin(arena, read_db, site.id, headers.origin)) orelse return respondError(request, .forbidden, "origin_denied", null);
    if (!site.enabled or !std.mem.eql(u8, site.mode, "full") or !site.recording) return respondError(request, .forbidden, "replay_disabled", origin);
    if (headers.gpc) return respondError(request, .forbidden, "gpc", origin);
    const session_id = queryValue(arena, target, "session") orelse "";
    const visitor_id = queryValue(arena, target, "visitor") orelse "";
    const page_id = queryValue(arena, target, "page") orelse "";
    domain.validateUuid(session_id) catch return respondError(request, .bad_request, "invalid_replay", origin);
    domain.validateUuid(visitor_id) catch return respondError(request, .bad_request, "invalid_replay", origin);
    domain.validateUuid(page_id) catch return respondError(request, .bad_request, "invalid_replay", origin);
    const seq = std.fmt.parseInt(i64, queryValue(arena, target, "seq") orelse "", 10) catch return respondError(request, .bad_request, "invalid_replay", origin);
    const first = std.fmt.parseInt(i64, queryValue(arena, target, "first") orelse "", 10) catch return respondError(request, .bad_request, "invalid_replay", origin);
    const last = std.fmt.parseInt(i64, queryValue(arena, target, "last") orelse "", 10) catch return respondError(request, .bad_request, "invalid_replay", origin);
    const length = request.head.content_length orelse return respondError(request, .length_required, "length_required", origin);
    if (length == 0 or length > replay.maximum_chunk_bytes) return respondError(request, .payload_too_large, "body_too_large", origin);
    // Only sessions with a consented page view on this site can record.
    var session = try read_db.prepare(arena, "SELECT path,device,browser,country FROM page_views WHERE site_id=? AND session_id=? AND visitor_id=? ORDER BY received_at_ms LIMIT 1");
    defer session.deinit();
    try session.bindInt(1, site.id);
    try session.bindText(2, session_id);
    try session.bindText(3, visitor_id);
    if (try session.step() != .row) return respondError(request, .forbidden, "unknown_session", origin);
    const body = try arena.alloc(u8, @intCast(length));
    var body_buffer: [16 * 1024]u8 = undefined;
    const reader = request.readerExpectContinue(&body_buffer) catch return error.InvalidExpectation;
    reader.readSliceAll(body) catch return error.InvalidBody;
    const chunk: replay.Chunk = .{
        .site_id = site.id,
        .session_id = session_id,
        .visitor_id = visitor_id,
        .page_id = page_id,
        .seq = seq,
        .first_ms = first,
        .last_ms = last,
        .received_at_ms = domain.nowMs(),
        .data = body,
        .entry_path = try arena.dupe(u8, session.columnText(0)),
        .device = try arena.dupe(u8, session.columnText(1)),
        .browser = try arena.dupe(u8, session.columnText(2)),
        .country = if (session.columnType(3) == db_mod.sqlite.SQLITE_NULL) null else try arena.dupe(u8, session.columnText(3)),
    };
    {
        const replays = shared.lockReplays();
        defer shared.unlockReplays();
        replay.addChunk(arena, replays, chunk) catch |err| switch (err) {
            error.ReplayTooLarge, error.ReplayTooLong => return respondError(request, .payload_too_large, "replay_limit", origin),
            error.InvalidChunkSize, error.InvalidChunkEncoding, error.InvalidChunkTime, error.ReplayVisitorMismatch => return respondError(request, .unprocessable_entity, "invalid_replay", origin),
            else => return err,
        };
    }
    return respond(request, .no_content, "text/plain; charset=utf-8", "no-store", "", origin);
}

/// POST /h: heatmap aggregates for the live overlay, behind a short-lived
/// token from the workspace and readable only from the site's own origins.
fn heatmap(arena: std.mem.Allocator, shared: *Shared, read_db: *db_mod.Db, request: *std.http.Server.Request, headers: Headers, target: []const u8) !void {
    const public_id = queryValue(arena, target, "site") orelse return respondError(request, .bad_request, "invalid_request", null);
    domain.validateUuid(public_id) catch return respondError(request, .bad_request, "invalid_request", null);
    const site = (try replaySite(arena, read_db, public_id)) orelse return respondError(request, .not_found, "unknown_site", null);
    const origin = (try siteOrigin(arena, read_db, site.id, headers.origin)) orelse return respondError(request, .forbidden, "origin_denied", null);
    const token = queryValue(arena, target, "token") orelse "";
    const payload = domain.verifyToken(shared.master_key, "overlay", token, domain.nowMs()) orelse
        return respondError(request, .unauthorized, "token_expired", origin);
    if (!std.mem.eql(u8, payload, public_id)) return respondError(request, .unauthorized, "token_expired", origin);
    const path = queryValue(arena, target, "path") orelse "/";
    domain.validatePath(path) catch return respondError(request, .bad_request, "invalid_request", origin);
    const viewport = queryValue(arena, target, "vp") orelse "desktop";
    if (!(std.mem.eql(u8, viewport, "desktop") or std.mem.eql(u8, viewport, "tablet") or std.mem.eql(u8, viewport, "phone"))) return respondError(request, .bad_request, "invalid_request", origin);
    const days = std.math.clamp(std.fmt.parseInt(i64, queryValue(arena, target, "days") orelse "30", 10) catch 30, 1, 366);
    const body = try @import("web/heatmaps.zig").cachedAggregates(arena, shared, read_db, site.id, path, viewport, days, domain.nowMs());
    return respond(request, .ok, "application/json", "no-store", body, origin);
}

fn ready(allocator: std.mem.Allocator, database: *db_mod.Db) !void {
    var statement = try database.prepare(allocator, "SELECT 1");
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
        } else if (std.ascii.eqlIgnoreCase(header.name, "sec-gpc") or std.ascii.eqlIgnoreCase(header.name, "dnt")) {
            // Global Privacy Control and Do Not Track both keep a visitor in Lite.
            if (std.mem.eql(u8, std.mem.trim(u8, header.value, " "), "1")) out.gpc = true;
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

fn rejection(allocator: std.mem.Allocator, shared: *Shared, name: []const u8) !void {
    _ = shared.lockWrite();
    defer shared.unlockWrite();
    return rejectionLocked(allocator, shared.store, name);
}

fn rejectionLocked(allocator: std.mem.Allocator, store: *store_mod.Store, name: []const u8) !void {
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
        error.InvalidConsent, error.ConsentRequired, error.InvalidConsentState => "consent_required",
        else => "invalid_record",
    };
}

fn storageError(err: anyerror) bool {
    return err == error.SqliteStepFailed or err == error.SqliteExecFailed or
        err == error.SqlitePrepareFailed or err == error.DatabaseNotReady;
}
