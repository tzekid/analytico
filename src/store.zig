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

/// Retention: removes detailed records received before the cutoff, plus the
/// aggregates and remembered visitors that only describe that time. One
/// transaction; callers back up first.
pub fn pruneBefore(allocator: std.mem.Allocator, database: *db_mod.Db, cutoff_ms: i64) !usize {
    try database.exec("BEGIN IMMEDIATE");
    errdefer database.exec("ROLLBACK") catch {};
    var removed: usize = 0;
    inline for (.{
        "DELETE FROM page_summaries WHERE received_at_ms<?1",
        "DELETE FROM page_views WHERE received_at_ms<?1",
        "DELETE FROM event_items WHERE (site_id,event_id) IN (SELECT site_id,event_id FROM events WHERE received_at_ms<?1)",
        "DELETE FROM events WHERE received_at_ms<?1",
        "DELETE FROM errors WHERE received_at_ms<?1",
        "DELETE FROM record_receipts WHERE received_at_ms<?1",
        "DELETE FROM click_cells WHERE day<strftime('%Y-%m-%d',?1/1000,'unixepoch')",
        "DELETE FROM form_fields WHERE day<strftime('%Y-%m-%d',?1/1000,'unixepoch')",
        "DELETE FROM visitor_links WHERE (site_id,visitor_id) IN (SELECT site_id,visitor_id FROM visitors WHERE last_seen_ms<?1)",
        "DELETE FROM visitor_weeks WHERE week<(?1/86400000+3)/7",
        "DELETE FROM visitors WHERE last_seen_ms<?1",
        "DELETE FROM rollups WHERE day<strftime('%Y-%m-%d',?1/1000,'unixepoch')",
        "DELETE FROM rollup_days WHERE day<strftime('%Y-%m-%d',?1/1000,'unixepoch')",
    }) |sql| {
        var statement = try database.prepare(allocator, sql);
        defer statement.deinit();
        try statement.bindInt(1, cutoff_ms);
        _ = try statement.step();
        removed += database.changes();
    }
    try database.exec("COMMIT");
    return removed;
}
