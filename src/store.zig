const std = @import("std");
const db_mod = @import("db.zig");
const domain = @import("domain.zig");
const schema = @import("schema.zig");

pub const Paths = struct {
    database: []const u8,
    key: []const u8,
    /// Session replays: big, short-lived, pruned on their own schedule.
    replays: []const u8,
    geo: []const u8,

    pub fn init(allocator: std.mem.Allocator, directory: []const u8) !Paths {
        const database = try std.fs.path.join(allocator, &.{ directory, "analytico.db" });
        errdefer allocator.free(database);
        const key = try std.fs.path.join(allocator, &.{ directory, "secret.key" });
        errdefer allocator.free(key);
        const replays = try std.fs.path.join(allocator, &.{ directory, "replays.db" });
        errdefer allocator.free(replays);
        return .{
            .database = database,
            .key = key,
            .replays = replays,
            .geo = try std.fs.path.join(allocator, &.{ directory, @import("geo.zig").file_name }),
        };
    }

    pub fn deinit(self: Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.database);
        allocator.free(self.key);
        allocator.free(self.replays);
        allocator.free(self.geo);
    }
};

pub fn readKey(io: std.Io, path: []const u8) ![32]u8 {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.size != 32) return error.InvalidKeyFile;
    if (stat.permissions.toMode() & 0o777 != 0o600) return error.InsecureKeyPermissions;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var key: [32]u8 = undefined;
    var reader_buffer: [32]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    try reader.interface.readSliceAll(&key);
    return key;
}

/// One process owns writes. The lock is held for the life of the returned file.
pub fn acquireWriterLock(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) !std.Io.File {
    const lock_path = try std.fs.path.join(allocator, &.{ directory, "writer.lock" });
    defer allocator.free(lock_path);
    return std.Io.Dir.cwd().createFile(io, lock_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = @fromBackingInt(@intCast(0o600)),
    }) catch |err| switch (err) {
        error.WouldBlock => return error.WriterAlreadyRunning,
        else => return err,
    };
}

pub const Site = struct {
    id: i64,
    public_id: []u8,
    slug: []u8,
    mode: domain.Mode,
    enabled: bool,
    internal_secret: [32]u8,
    consent_policy: domain.ConsentPolicy = .regional,
    consent_banner: bool = false,
    banner_text: []u8 = &.{},
    privacy_url: []u8 = &.{},
    replay_percent: i64 = 0,
    replay_triggers: bool = false,
    mask_text: bool = true,
    /// Newline-separated path patterns (`*` matches anything) never recorded.
    record_exclude: []u8 = &.{},

    pub fn deinit(self: *Site, allocator: std.mem.Allocator) void {
        allocator.free(self.public_id);
        allocator.free(self.slug);
        allocator.free(self.banner_text);
        allocator.free(self.privacy_url);
        allocator.free(self.record_exclude);
        std.crypto.secureZero(u8, &self.internal_secret);
        self.* = undefined;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    database: db_mod.Db,
    writer_lock: ?std.Io.File,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, write: bool) !Store {
        const paths = try Paths.init(allocator, directory);
        defer paths.deinit(allocator);
        const writer_lock: ?std.Io.File = if (write) try acquireWriterLock(allocator, io, directory) else null;
        errdefer if (writer_lock) |file| file.close(io);
        var database = try db_mod.Db.open(allocator, paths.database, write);
        errdefer database.close();
        try schema.requireCurrent(&database, allocator);
        return .{ .allocator = allocator, .io = io, .database = database, .writer_lock = writer_lock };
    }

    pub fn close(self: *Store) void {
        self.database.close();
        if (self.writer_lock) |file| file.close(self.io);
        self.* = undefined;
    }

    pub fn addSite(self: *Store, io: std.Io, slug: []const u8, origin_value: []const u8, mode: domain.Mode) !Site {
        try domain.validateSlug(slug);
        const origin = try domain.normalizeOrigin(self.allocator, origin_value);
        defer self.allocator.free(origin);
        const public_id = try domain.randomUuid(io);
        var internal_secret: [32]u8 = undefined;
        try io.randomSecure(&internal_secret);
        defer std.crypto.secureZero(u8, &internal_secret);
        const now = domain.nowMs();
        try self.database.exec("BEGIN IMMEDIATE");
        errdefer self.database.exec("ROLLBACK") catch {};
        var insert = try self.database.prepare(self.allocator, "INSERT INTO sites(public_id,slug,tracking_mode,internal_secret,created_at_ms) VALUES(?,?,?,?,?)");
        defer insert.deinit();
        try insert.bindText(1, &public_id);
        try insert.bindText(2, slug);
        try insert.bindText(3, domain.modeName(mode));
        try insert.bindBlob(4, &internal_secret);
        try insert.bindInt(5, now);
        if (try insert.step() != .done) unreachable;
        const site_id = self.database.lastInsertRowId();
        var add_origin = try self.database.prepare(self.allocator, "INSERT INTO site_origins(site_id,origin) VALUES(?,?)");
        defer add_origin.deinit();
        try add_origin.bindInt(1, site_id);
        try add_origin.bindText(2, origin);
        if (try add_origin.step() != .done) unreachable;
        try self.database.exec("COMMIT");
        return .{
            .id = site_id,
            .public_id = try self.allocator.dupe(u8, &public_id),
            .slug = try self.allocator.dupe(u8, slug),
            .mode = mode,
            .enabled = true,
            .internal_secret = internal_secret,
            .banner_text = try self.allocator.dupe(u8, ""),
            .privacy_url = try self.allocator.dupe(u8, ""),
            .record_exclude = try self.allocator.dupe(u8, ""),
        };
    }

    pub fn siteBySlug(self: *Store, slug: []const u8) !Site {
        return self.siteBy("slug", slug);
    }

    pub fn siteByPublicId(self: *Store, public_id: []const u8) !Site {
        return self.siteBy("public_id", public_id);
    }

    fn siteBy(self: *Store, comptime column: []const u8, value: []const u8) !Site {
        var statement = try self.database.prepare(self.allocator, "SELECT id,public_id,slug,tracking_mode,enabled,internal_secret,consent_policy,consent_banner,banner_text,privacy_url,replay_percent,replay_triggers,mask_text,record_exclude FROM sites WHERE " ++ column ++ "=?");
        defer statement.deinit();
        try statement.bindText(1, value);
        if (try statement.step() != .row) return error.UnknownSite;
        const secret_text = statement.columnText(5);
        if (secret_text.len != 32) return error.CorruptSiteSecret;
        return .{
            .id = statement.columnInt(0),
            .public_id = try self.allocator.dupe(u8, statement.columnText(1)),
            .slug = try self.allocator.dupe(u8, statement.columnText(2)),
            .mode = try domain.parseMode(statement.columnText(3)),
            .enabled = statement.columnBool(4),
            .internal_secret = secret_text[0..32].*,
            .consent_policy = try domain.parseConsentPolicy(statement.columnText(6)),
            .consent_banner = statement.columnBool(7),
            .banner_text = try self.allocator.dupe(u8, statement.columnText(8)),
            .privacy_url = try self.allocator.dupe(u8, statement.columnText(9)),
            .replay_percent = statement.columnInt(10),
            .replay_triggers = statement.columnBool(11),
            .mask_text = statement.columnBool(12),
            .record_exclude = try self.allocator.dupe(u8, statement.columnText(13)),
        };
    }

    /// The site's other origins, for the cross-domain linker.
    pub fn origins(self: *Store, allocator: std.mem.Allocator, site_id: i64) ![]const []const u8 {
        var statement = try self.database.prepare(allocator, "SELECT origin FROM site_origins WHERE site_id=? ORDER BY origin");
        defer statement.deinit();
        try statement.bindInt(1, site_id);
        var out: std.ArrayList([]const u8) = .empty;
        while (try statement.step() == .row) try out.append(allocator, try allocator.dupe(u8, statement.columnText(0)));
        return out.items;
    }

    pub fn allowsOrigin(self: *Store, site_id: i64, origin: []const u8) !bool {
        var statement = try self.database.prepare(self.allocator, "SELECT 1 FROM site_origins WHERE site_id=? AND origin=?");
        defer statement.deinit();
        try statement.bindInt(1, site_id);
        try statement.bindText(2, origin);
        return try statement.step() == .row;
    }

    pub fn addOrigin(self: *Store, slug: []const u8, origin_value: []const u8) !void {
        var site = try self.siteBySlug(slug);
        defer site.deinit(self.allocator);
        const origin = try domain.normalizeOrigin(self.allocator, origin_value);
        defer self.allocator.free(origin);
        var statement = try self.database.prepare(self.allocator, "INSERT INTO site_origins(site_id,origin) VALUES(?,?)");
        defer statement.deinit();
        try statement.bindInt(1, site.id);
        try statement.bindText(2, origin);
        _ = try statement.step();
    }

    pub fn disableSite(self: *Store, slug: []const u8) !void {
        var statement = try self.database.prepare(self.allocator, "UPDATE sites SET enabled=0 WHERE slug=? AND enabled=1");
        defer statement.deinit();
        try statement.bindText(1, slug);
        _ = try statement.step();
        if (self.database.changes() != 1) return error.UnknownOrDisabledSite;
    }

    pub fn checkpoint(self: *Store) !void {
        try self.database.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    }
};

/// How long the tracker keeps a visitor ID (`storedVisitor`).
const visitor_id_lifetime_ms: i64 = 395 * 86_400_000;

/// Retention: removes detailed records received before the cutoff, plus the
/// aggregates and remembered visitors that only describe that time. Callers
/// back up first. It runs as many short transactions so collection keeps
/// going: `writer` (the server's shared state, or `Unlocked` from the CLI)
/// holds the write lock for one at a time.
pub fn pruneBefore(allocator: std.mem.Allocator, writer: anytype, cutoff_ms: i64) !usize {
    const now_ms = domain.nowMs();
    var removed: usize = 0;
    var sites: std.ArrayList(i64) = .empty;
    defer sites.deinit(allocator);
    {
        const database = writer.lockWrite();
        defer writer.unlockWrite();
        var statement = try database.prepare(allocator, "SELECT id FROM sites ORDER BY id");
        defer statement.deinit();
        while (try statement.step() == .row) try sites.append(allocator, statement.columnInt(0));
    }
    for (sites.items) |site_id| {
        while (true) {
            const database = writer.lockWrite();
            defer writer.unlockWrite();
            removed += try pruneSlice(allocator, database, site_id, cutoff_ms) orelse break;
        }
        // Remembered visitors with their identity links, a batch at a time.
        while (true) {
            const database = writer.lockWrite();
            defer writer.unlockWrite();
            try database.exec("BEGIN IMMEDIATE");
            errdefer database.exec("ROLLBACK") catch {};
            const oldest = "(SELECT visitor_id FROM visitors WHERE site_id=?1 AND last_seen_ms<?2 ORDER BY last_seen_ms,visitor_id LIMIT ?3)";
            // A withdrawal outlives the visitor's data: their ID stays
            // refused while a browser may still hold it (see below).
            try database.run(allocator, "INSERT INTO forgotten_visitors(site_id,visitor_id,forgotten_at_ms,refused) SELECT site_id,visitor_id,?4,1 FROM visitors WHERE site_id=?1 AND visitor_id IN " ++ oldest ++ " AND consent_state IN ('denied','gpc') ON CONFLICT DO UPDATE SET refused=1", .{ site_id, cutoff_ms, prune_batch, now_ms });
            try database.run(allocator, "DELETE FROM visitor_links WHERE site_id=?1 AND visitor_id IN " ++ oldest, .{ site_id, cutoff_ms, prune_batch });
            removed += database.changes();
            try database.run(allocator, "DELETE FROM visitors WHERE site_id=?1 AND visitor_id IN " ++ oldest, .{ site_id, cutoff_ms, prune_batch });
            const visitors = database.changes();
            try database.exec("COMMIT");
            removed += visitors;
            if (visitors < prune_batch) break;
        }
    }
    // What is left only describes that time: receipts and daily aggregates.
    inline for (.{
        .{ "DELETE FROM record_receipts WHERE (site_id,event_id) IN (SELECT site_id,event_id FROM record_receipts WHERE received_at_ms<?1 LIMIT ?2)", cutoff_ms },
        .{ "DELETE FROM click_cells WHERE (site_id,path,day,viewport_class,element,x,y) IN (SELECT site_id,path,day,viewport_class,element,x,y FROM click_cells WHERE day<strftime('%Y-%m-%d',?1/1000,'unixepoch') LIMIT ?2)", cutoff_ms },
        .{ "DELETE FROM form_fields WHERE (site_id,path,day,form,field) IN (SELECT site_id,path,day,form,field FROM form_fields WHERE day<strftime('%Y-%m-%d',?1/1000,'unixepoch') LIMIT ?2)", cutoff_ms },
        .{ "DELETE FROM visitor_weeks WHERE (site_id,week,visitor_id) IN (SELECT site_id,week,visitor_id FROM visitor_weeks WHERE week<(?1/86400000+3)/7 LIMIT ?2)", cutoff_ms },
        .{ "DELETE FROM rollups WHERE (site_id,dim,day,key) IN (SELECT site_id,dim,day,key FROM rollups WHERE day<strftime('%Y-%m-%d',?1/1000,'unixepoch') LIMIT ?2)", cutoff_ms },
        .{ "DELETE FROM rollup_days WHERE (site_id,day) IN (SELECT site_id,day FROM rollup_days WHERE day<strftime('%Y-%m-%d',?1/1000,'unixepoch') LIMIT ?2)", cutoff_ms },
        .{ "DELETE FROM vitals_daily WHERE (site_id,metric,day,path,value) IN (SELECT site_id,metric,day,path,value FROM vitals_daily WHERE day<strftime('%Y-%m-%d',?1/1000,'unixepoch') LIMIT ?2)", cutoff_ms },
        // Refused IDs follow the browser's 13 months, not the data: one
        // cannot be held anywhere longer than that after it was refused.
        .{ "DELETE FROM forgotten_visitors WHERE (site_id,visitor_id) IN (SELECT site_id,visitor_id FROM forgotten_visitors WHERE forgotten_at_ms<?1 LIMIT ?2)", now_ms - visitor_id_lifetime_ms },
    }) |entry| {
        while (true) {
            const database = writer.lockWrite();
            defer writer.unlockWrite();
            try database.run(allocator, entry[0], .{ entry[1], prune_batch });
            const changed = database.changes();
            removed += changed;
            if (changed < prune_batch) break;
        }
    }
    const database = writer.lockWrite();
    defer writer.unlockWrite();
    try database.exec("DELETE FROM cache");
    return removed;
}

/// For the CLI, which has the database to itself.
pub const Unlocked = struct {
    database: *db_mod.Db,

    pub fn lockWrite(self: Unlocked) *db_mod.Db {
        return self.database;
    }

    pub fn unlockWrite(_: Unlocked) void {}
};

const prune_batch = 5000;

/// One transaction: a website's oldest records before the cutoff, at most
/// `prune_batch` rows per table. The tables are kept in time order, so this
/// is one contiguous read each, and a slice's events go with their items.
/// Null once nothing before the cutoff is left.
fn pruneSlice(allocator: std.mem.Allocator, database: *db_mod.Db, site_id: i64, cutoff_ms: i64) !?usize {
    try database.exec("BEGIN IMMEDIATE");
    errdefer database.exec("ROLLBACK") catch {};
    const first = try database.scalar(allocator, ?i64,
        \\SELECT min(m) FROM (SELECT min(received_at_ms) m FROM page_views WHERE site_id=?1 UNION ALL SELECT min(received_at_ms) FROM page_summaries WHERE site_id=?1
        \\ UNION ALL SELECT min(received_at_ms) FROM events WHERE site_id=?1 UNION ALL SELECT min(received_at_ms) FROM errors WHERE site_id=?1)
    , .{site_id});
    if (first == null or first.? >= cutoff_ms) {
        try database.exec("COMMIT");
        return null;
    }
    // The slice ends at whichever table reaches the batch size first.
    const next = try database.scalar(allocator, ?i64,
        \\SELECT min(m) FROM (SELECT (SELECT received_at_ms FROM page_views WHERE site_id=?1 AND received_at_ms<?2 ORDER BY received_at_ms LIMIT 1 OFFSET ?3) m
        \\ UNION ALL SELECT (SELECT received_at_ms FROM page_summaries WHERE site_id=?1 AND received_at_ms<?2 ORDER BY received_at_ms LIMIT 1 OFFSET ?3)
        \\ UNION ALL SELECT (SELECT received_at_ms FROM events WHERE site_id=?1 AND received_at_ms<?2 ORDER BY received_at_ms LIMIT 1 OFFSET ?3)
        \\ UNION ALL SELECT (SELECT received_at_ms FROM errors WHERE site_id=?1 AND received_at_ms<?2 ORDER BY received_at_ms LIMIT 1 OFFSET ?3))
    , .{ site_id, cutoff_ms, prune_batch });
    // Rows that share the first timestamp go together.
    const end = if (next) |value| @max(value, first.? + 1) else cutoff_ms;
    var removed: usize = 0;
    inline for (.{
        "DELETE FROM page_summaries WHERE site_id=?1 AND received_at_ms<?2",
        "DELETE FROM page_views WHERE site_id=?1 AND received_at_ms<?2",
        "DELETE FROM event_items WHERE site_id=?1 AND event_id IN (SELECT event_id FROM events WHERE site_id=?1 AND received_at_ms<?2)",
        "DELETE FROM events WHERE site_id=?1 AND received_at_ms<?2",
        "DELETE FROM errors WHERE site_id=?1 AND received_at_ms<?2",
    }) |sql| {
        try database.run(allocator, sql, .{ site_id, end });
        removed += database.changes();
    }
    try database.exec("COMMIT");
    return removed;
}
