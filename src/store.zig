const std = @import("std");
const db_mod = @import("db.zig");
const domain = @import("domain.zig");
const schema = @import("schema.zig");

pub const Paths = struct {
    database: []const u8,
    key: []const u8,

    pub fn init(allocator: std.mem.Allocator, directory: []const u8) !Paths {
        return .{
            .database = try std.fs.path.join(allocator, &.{ directory, "analytico.db" }),
            .key = try std.fs.path.join(allocator, &.{ directory, "secret.key" }),
        };
    }
};

pub const Site = struct {
    id: i64,
    public_id: []u8,
    slug: []u8,
    mode: domain.Mode,
    enabled: bool,
    internal_secret: [32]u8,

    pub fn deinit(self: *Site, allocator: std.mem.Allocator) void {
        allocator.free(self.public_id);
        allocator.free(self.slug);
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
        const writer_lock: ?std.Io.File = if (write) block: {
            const lock_path = try std.fs.path.join(allocator, &.{ directory, "writer.lock" });
            break :block std.Io.Dir.cwd().createFile(io, lock_path, .{
                .read = true,
                .truncate = false,
                .lock = .exclusive,
                .lock_nonblocking = true,
                .permissions = @fromBackingInt(@intCast(0o600)),
            }) catch |err| switch (err) {
                error.WouldBlock => return error.WriterAlreadyRunning,
                else => return err,
            };
        } else null;
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
        const now = try domain.nowMilliseconds();
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
        };
    }

    pub fn siteBySlug(self: *Store, slug: []const u8) !Site {
        return self.siteBy("slug", slug);
    }

    pub fn siteByPublicId(self: *Store, public_id: []const u8) !Site {
        return self.siteBy("public_id", public_id);
    }

    fn siteBy(self: *Store, comptime column: []const u8, value: []const u8) !Site {
        var statement = try self.database.prepare(self.allocator, "SELECT id,public_id,slug,tracking_mode,enabled,internal_secret FROM sites WHERE " ++ column ++ "=?");
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
        };
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

    pub fn integrity(self: *Store) !void {
        var statement = try self.database.prepare(self.allocator, "PRAGMA integrity_check");
        defer statement.deinit();
        if (try statement.step() != .row or !std.mem.eql(u8, statement.columnText(0), "ok")) {
            return error.IntegrityCheckFailed;
        }
        var fk = try self.database.prepare(self.allocator, "PRAGMA foreign_key_check");
        defer fk.deinit();
        if (try fk.step() == .row) return error.ForeignKeyCheckFailed;
    }
};
