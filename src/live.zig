//! Live updates for open workspace pages (server-sent events). A worker
//! checks access, then hands the connection to this one broadcaster thread,
//! so an open stream never holds a worker. Every two seconds each stream gets
//! its site's visitors online and newest page view when they changed, and a
//! comment otherwise to keep proxies from timing it out.
const std = @import("std");
const linux = std.os.linux;
const db_mod = @import("db.zig");
const store_mod = @import("store.zig");
const server = @import("server.zig");
const data = @import("web/data.zig");

pub const max_streams = 64;
const interval_ms = 2_000;
const ping_every = 10;

const Stream = struct { stream: std.Io.net.Stream, site_id: i64, sent: [64]u8 = undefined, sent_len: usize = 0 };

pub const Hub = struct {
    mutex: std.Io.Mutex = .init,
    streams: [max_streams]?Stream = @splat(null),

    /// Takes ownership of `stream` after writing the response head; false when full.
    pub fn add(self: *Hub, io: std.Io, stream: std.Io.net.Stream, site_id: i64) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (&self.streams) |*slot| if (slot.* == null) {
            const head = "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncache-control: no-store, no-transform\r\nx-accel-buffering: no\r\nconnection: close\r\n\r\nretry: 5000\n\n";
            if (!send(stream, head)) return false;
            slot.* = .{ .stream = stream, .site_id = site_id };
            return true;
        };
        return false;
    }
};

/// Non-blocking write of the whole message; a client that cannot take it is dropped.
fn send(stream: std.Io.net.Stream, bytes: []const u8) bool {
    const rc = linux.sendto(stream.socket.handle, bytes.ptr, bytes.len, linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL, null, 0);
    return linux.errno(rc) == .SUCCESS and rc == bytes.len;
}

pub fn run(shared: *server.Shared) void {
    var read_store = store_mod.Store.open(shared.gpa, shared.io, shared.data, false) catch |err| {
        std.log.err("live_open_failed code={s}", .{@errorName(err)});
        return;
    };
    defer read_store.close();
    const hub = &shared.live;
    var tick: u32 = 0;
    while (!shared.stopping()) {
        std.Io.sleep(shared.io, .fromMilliseconds(interval_ms), .awake) catch {};
        tick += 1;
        var arena_state = std.heap.ArenaAllocator.init(shared.gpa);
        defer arena_state.deinit();
        broadcast(arena_state.allocator(), shared, &read_store.database, tick % ping_every == 0) catch |err| std.log.warn("live_broadcast_failed code={s}", .{@errorName(err)});
    }
    hub.mutex.lockUncancelable(shared.io);
    defer hub.mutex.unlock(shared.io);
    for (&hub.streams) |*slot| if (slot.*) |entry| {
        entry.stream.close(shared.io);
        slot.* = null;
    };
}

fn broadcast(arena: std.mem.Allocator, shared: *server.Shared, db: *db_mod.Db, ping: bool) !void {
    const hub = &shared.live;
    hub.mutex.lockUncancelable(shared.io);
    defer hub.mutex.unlock(shared.io);
    var payloads: std.AutoHashMapUnmanaged(i64, []const u8) = .empty;
    const now = @import("domain.zig").nowMs();
    for (&hub.streams) |*slot| {
        const entry = &(slot.* orelse continue);
        const payload = payloads.get(entry.site_id) orelse blk: {
            const text = try std.fmt.allocPrint(arena, "{{\"online\":{d},\"last\":{d}}}", .{ try data.online(arena, db, entry.site_id, now), try data.lastSeen(arena, db, entry.site_id) });
            try payloads.put(arena, entry.site_id, text);
            break :blk text;
        };
        const changed = !std.mem.eql(u8, entry.sent[0..entry.sent_len], payload);
        const message = if (changed) try std.fmt.allocPrint(arena, "data: {s}\n\n", .{payload}) else if (ping) ": ping\n\n" else continue;
        if (!send(entry.stream, message)) {
            entry.stream.close(shared.io);
            slot.* = null;
            continue;
        }
        if (changed and payload.len <= entry.sent.len) {
            @memcpy(entry.sent[0..payload.len], payload);
            entry.sent_len = payload.len;
        }
    }
}
