const std = @import("std");
const turso = @import("turso");

pub const Store = struct {
    database: turso.Database,
    connection: turso.Connection,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Store {
        var database = try turso.Database.open(allocator, .{ .path = path });
        errdefer database.deinit();
        const connection = try database.connect(.{ .busy_timeout_ms = 2_000 });
        return .{
            .database = database,
            .connection = connection,
        };
    }

    pub fn deinit(self: *Store) void {
        self.connection.deinit();
        self.database.deinit();
    }

    pub fn migrateProbe(self: *Store) !void {
        _ = try self.connection.execBatch(
            \\CREATE TABLE IF NOT EXISTS meta_migrations (
            \\  version INTEGER PRIMARY KEY,
            \\  name TEXT NOT NULL,
            \\  applied_at_utc_micros INTEGER NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS sites (
            \\  id TEXT PRIMARY KEY,
            \\  slug TEXT NOT NULL UNIQUE,
            \\  name TEXT NOT NULL
            \\);
            \\INSERT OR IGNORE INTO meta_migrations
            \\  (version, name, applied_at_utc_micros)
            \\VALUES (0, 'm0-probe', 0);
        , .{});
    }

    pub fn seedProbeSite(self: *Store) !void {
        _ = try self.connection.execParams(
            \\INSERT INTO sites (id, slug, name)
            \\VALUES (?1, ?2, ?3)
            \\ON CONFLICT(id) DO UPDATE SET slug = excluded.slug, name = excluded.name
        ,
            .{
                "00000000-0000-4000-8000-000000000001",
                "probe",
                "M0 Probe",
            },
            .{},
        );
    }

    pub fn siteCount(self: *Store) !i64 {
        var rows = try self.connection.query(
            "SELECT COUNT(*) AS count FROM sites",
            &.{},
            .{},
        );
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.MissingCount;
        return row.get(i64, 0);
    }
};
