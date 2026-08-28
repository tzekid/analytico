const std = @import("std");
const c = @import("sqlite_c");

pub const sqlite = c;

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open(allocator: std.mem.Allocator, path: []const u8, write: bool) !Db {
        const zpath = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(zpath);
        var raw: ?*c.sqlite3 = null;
        const flags: c_int = if (write)
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX
        else
            c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_FULLMUTEX;
        const rc = c.sqlite3_open_v2(zpath.ptr, &raw, flags, null);
        if (rc != c.SQLITE_OK or raw == null) {
            if (raw) |value| _ = c.sqlite3_close(value);
            return error.DatabaseOpenFailed;
        }
        var out = Db{ .handle = raw.? };
        errdefer out.close();
        _ = c.sqlite3_extended_result_codes(out.handle, 1);
        _ = c.sqlite3_busy_timeout(out.handle, 2_000);
        try out.exec("PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF;");
        if (write) try out.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;");
        return out;
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
        self.* = undefined;
    }

    pub fn errorMessage(self: *Db) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.handle));
    }

    pub fn exec(self: *Db, sql: []const u8) !void {
        var message: [*c]u8 = null;
        const zsql = try std.heap.c_allocator.dupeSentinel(u8, sql, 0);
        defer std.heap.c_allocator.free(zsql);
        const rc = c.sqlite3_exec(self.handle, zsql.ptr, null, null, &message);
        if (message != null) c.sqlite3_free(message);
        if (rc != c.SQLITE_OK) {
            std.log.err("sqlite exec failed rc={d} message={s}", .{ rc, self.errorMessage() });
            return error.SqliteExecFailed;
        }
    }

    pub fn prepare(self: *Db, allocator: std.mem.Allocator, sql: []const u8) !Statement {
        const zsql = try allocator.dupeSentinel(u8, sql, 0);
        defer allocator.free(zsql);
        var raw: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, zsql.ptr, @intCast(sql.len), &raw, null) != c.SQLITE_OK or raw == null) {
            std.log.err("sqlite prepare failed message={s}", .{self.errorMessage()});
            return error.SqlitePrepareFailed;
        }
        return .{ .db = self, .handle = raw.? };
    }

    pub fn changes(self: *Db) usize {
        return @intCast(c.sqlite3_changes64(self.handle));
    }

    pub fn lastInsertRowId(self: *Db) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }
};

pub const Step = enum { row, done };

pub const Statement = struct {
    db: *Db,
    handle: *c.sqlite3_stmt,

    pub fn deinit(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
        self.* = undefined;
    }

    pub fn reset(self: *Statement) !void {
        if (c.sqlite3_reset(self.handle) != c.SQLITE_OK or c.sqlite3_clear_bindings(self.handle) != c.SQLITE_OK) {
            return error.SqliteResetFailed;
        }
    }

    pub fn bindText(self: *Statement, index: usize, value: []const u8) !void {
        if (c.sqlite3_bind_text(self.handle, @intCast(index), value.ptr, @intCast(value.len), null) != c.SQLITE_OK) {
            return error.SqliteBindFailed;
        }
    }

    pub fn bindOptionalText(self: *Statement, index: usize, value: ?[]const u8) !void {
        if (value) |text| return self.bindText(index, text);
        try self.bindNull(index);
    }

    pub fn bindBlob(self: *Statement, index: usize, value: []const u8) !void {
        if (c.sqlite3_bind_blob(self.handle, @intCast(index), value.ptr, @intCast(value.len), null) != c.SQLITE_OK) {
            return error.SqliteBindFailed;
        }
    }

    pub fn bindInt(self: *Statement, index: usize, value: i64) !void {
        if (c.sqlite3_bind_int64(self.handle, @intCast(index), value) != c.SQLITE_OK) return error.SqliteBindFailed;
    }

    pub fn bindOptionalInt(self: *Statement, index: usize, value: ?i64) !void {
        if (value) |integer| return self.bindInt(index, integer);
        try self.bindNull(index);
    }

    pub fn bindBool(self: *Statement, index: usize, value: bool) !void {
        return self.bindInt(index, @intFromBool(value));
    }

    pub fn bindNull(self: *Statement, index: usize) !void {
        if (c.sqlite3_bind_null(self.handle, @intCast(index)) != c.SQLITE_OK) return error.SqliteBindFailed;
    }

    pub fn step(self: *Statement) !Step {
        const rc = c.sqlite3_step(self.handle);
        return switch (rc) {
            c.SQLITE_ROW => .row,
            c.SQLITE_DONE => .done,
            else => {
                std.log.err("sqlite step failed message={s}", .{self.db.errorMessage()});
                if (rc & 0xff == c.SQLITE_CONSTRAINT) return error.SqliteConstraint;
                return error.SqliteStepFailed;
            },
        };
    }

    pub fn columnInt(self: *Statement, index: usize) i64 {
        return c.sqlite3_column_int64(self.handle, @intCast(index));
    }

    pub fn columnBool(self: *Statement, index: usize) bool {
        return self.columnInt(index) != 0;
    }

    pub fn columnText(self: *Statement, index: usize) []const u8 {
        const len: usize = @intCast(c.sqlite3_column_bytes(self.handle, @intCast(index)));
        const ptr = c.sqlite3_column_text(self.handle, @intCast(index));
        if (ptr == null or len == 0) return "";
        return @as([*]const u8, @ptrCast(ptr))[0..len];
    }

    pub fn columnOptionalText(self: *Statement, index: usize) ?[]const u8 {
        if (c.sqlite3_column_type(self.handle, @intCast(index)) == c.SQLITE_NULL) return null;
        return self.columnText(index);
    }

    pub fn columnFloat(self: *Statement, index: usize) f64 {
        return c.sqlite3_column_double(self.handle, @intCast(index));
    }

    pub fn columnType(self: *Statement, index: usize) c_int {
        return c.sqlite3_column_type(self.handle, @intCast(index));
    }

    pub fn columnCount(self: *Statement) usize {
        return @intCast(c.sqlite3_column_count(self.handle));
    }

    pub fn columnName(self: *Statement, index: usize) []const u8 {
        return std.mem.span(c.sqlite3_column_name(self.handle, @intCast(index)));
    }
};

pub fn backup(source: *Db, destination: *Db) !void {
    const handle = c.sqlite3_backup_init(destination.handle, "main", source.handle, "main") orelse
        return error.SqliteBackupInitFailed;
    const rc = c.sqlite3_backup_step(handle, -1);
    const finish_rc = c.sqlite3_backup_finish(handle);
    if (rc != c.SQLITE_DONE or finish_rc != c.SQLITE_OK) return error.SqliteBackupFailed;
}

pub fn integrity(database: *Db, allocator: std.mem.Allocator) !void {
    var statement = try database.prepare(allocator, "PRAGMA integrity_check");
    defer statement.deinit();
    if (try statement.step() != .row or !std.mem.eql(u8, statement.columnText(0), "ok")) {
        return error.IntegrityCheckFailed;
    }
    var foreign_keys = try database.prepare(allocator, "PRAGMA foreign_key_check");
    defer foreign_keys.deinit();
    if (try foreign_keys.step() == .row) return error.ForeignKeyCheckFailed;
}

test "vendored sqlite is linked" {
    try std.testing.expectEqualStrings("3.53.4", std.mem.span(c.sqlite3_libversion()));
}
