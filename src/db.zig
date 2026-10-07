const std = @import("std");
const c = @import("sqlite_c");

pub const sqlite = c;

pub const Db = struct {
    handle: *c.sqlite3,
    /// Prepared statements kept for reuse, by SQL text. A connection is used
    /// by one thread at a time, so the cache needs no lock.
    cache: std.StringHashMapUnmanaged(Cached) = .empty,

    const Cached = struct { handle: *c.sqlite3_stmt, busy: bool };
    const cache_limit = 256;

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
        var entries = self.cache.iterator();
        while (entries.next()) |entry| {
            _ = c.sqlite3_finalize(entry.value_ptr.handle);
            std.heap.c_allocator.free(entry.key_ptr.*);
        }
        self.cache.deinit(std.heap.c_allocator);
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

    /// A prepared statement, reused from this connection's cache when the
    /// same SQL ran before. `deinit` returns it to the cache.
    pub fn prepare(self: *Db, allocator: std.mem.Allocator, sql: []const u8) !Statement {
        if (self.cache.getPtr(sql)) |cached| if (!cached.busy) {
            cached.busy = true;
            return .{ .db = self, .handle = cached.handle, .cached = true };
        };
        const zsql = try allocator.dupeSentinel(u8, sql, 0);
        defer allocator.free(zsql);
        var raw: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v3(self.handle, zsql.ptr, @intCast(sql.len), c.SQLITE_PREPARE_PERSISTENT, &raw, null) != c.SQLITE_OK or raw == null) {
            std.log.err("sqlite prepare failed message={s}", .{self.errorMessage()});
            return error.SqlitePrepareFailed;
        }
        // The first use of a SQL text is cached; a second, concurrent use of
        // the same text (nested iteration) gets its own statement.
        if (!self.cache.contains(sql) and self.cache.count() < cache_limit) {
            const key = try std.heap.c_allocator.dupe(u8, sql);
            try self.cache.put(std.heap.c_allocator, key, .{ .handle = raw.?, .busy = true });
            return .{ .db = self, .handle = raw.?, .cached = true };
        }
        return .{ .db = self, .handle = raw.? };
    }

    // ---- typed queries: arguments bind by type, rows read into structs by
    // column position (`i64`, `f64`, `bool`, `[]const u8`, enums, optionals).

    /// Every row as a `Row`.
    pub fn all(self: *Db, arena: std.mem.Allocator, comptime Row: type, sql: []const u8, args: anytype) ![]Row {
        var statement = try self.prepare(arena, sql);
        defer statement.deinit();
        try statement.bindAll(args);
        var out: std.ArrayList(Row) = .empty;
        while (try statement.step() == .row) try out.append(arena, try statement.read(Row, arena));
        return out.items;
    }

    /// The first row, if any.
    pub fn one(self: *Db, arena: std.mem.Allocator, comptime Row: type, sql: []const u8, args: anytype) !?Row {
        var statement = try self.prepare(arena, sql);
        defer statement.deinit();
        try statement.bindAll(args);
        if (try statement.step() != .row) return null;
        return try statement.read(Row, arena);
    }

    /// The first column of the first row; 0, false or "" when there is none.
    pub fn scalar(self: *Db, arena: std.mem.Allocator, comptime T: type, sql: []const u8, args: anytype) !T {
        var statement = try self.prepare(arena, sql);
        defer statement.deinit();
        try statement.bindAll(args);
        if (try statement.step() != .row) return std.mem.zeroes(T);
        return try statement.column(T, arena, 0);
    }

    /// Runs a statement that returns no rows.
    pub fn run(self: *Db, arena: std.mem.Allocator, sql: []const u8, args: anytype) !void {
        var statement = try self.prepare(arena, sql);
        defer statement.deinit();
        try statement.bindAll(args);
        _ = try statement.step();
    }

    pub fn changes(self: *Db) usize {
        return @intCast(c.sqlite3_changes64(self.handle));
    }

    pub fn lastInsertRowId(self: *Db) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }
};

pub const Step = enum { row, done };

/// Time this thread spent inside SQLite and the statements it finished, for
/// the workspace's Server-Timing header. Requests reset them.
pub threadlocal var thread_ns: u64 = 0;
pub threadlocal var thread_statements: u32 = 0;

/// Statements slower than this are logged with their SQL text. Values are
/// always bound, never part of the text, so nothing personal is logged.
pub const slow_statement_ms = 250;

pub fn monotonicNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub const Statement = struct {
    db: *Db,
    handle: *c.sqlite3_stmt,
    /// Time spent in sqlite3_step for this statement.
    ns: u64 = 0,
    /// Owned by the connection's cache: reset on deinit instead of finalized.
    cached: bool = false,

    pub fn deinit(self: *Statement) void {
        thread_ns += self.ns;
        thread_statements += 1;
        if (self.ns > slow_statement_ms * std.time.ns_per_ms) {
            const sql = std.mem.span(c.sqlite3_sql(self.handle));
            std.log.warn("slow_statement ms={d} sql={s}", .{ self.ns / std.time.ns_per_ms, sql[0..@min(sql.len, 400)] });
        }
        if (self.cached) {
            _ = c.sqlite3_reset(self.handle);
            _ = c.sqlite3_clear_bindings(self.handle);
            if (self.db.cache.getPtr(std.mem.span(c.sqlite3_sql(self.handle)))) |entry| entry.busy = false;
        } else _ = c.sqlite3_finalize(self.handle);
        self.* = undefined;
    }

    pub fn bindAll(self: *Statement, args: anytype) !void {
        inline for (args, 1..) |arg, index| try self.bindValue(index, arg);
    }

    fn bindValue(self: *Statement, index: usize, arg: anytype) !void {
        const T = @TypeOf(arg);
        switch (@typeInfo(T)) {
            .int, .comptime_int => try self.bindInt(index, @intCast(arg)),
            .float, .comptime_float => if (c.sqlite3_bind_double(self.handle, @intCast(index), arg) != c.SQLITE_OK) return error.SqliteBindFailed,
            .bool => try self.bindBool(index, arg),
            .null => try self.bindNull(index),
            .optional => if (arg) |present| try self.bindValue(index, present) else try self.bindNull(index),
            .@"enum", .enum_literal => try self.bindText(index, @tagName(arg)),
            .pointer => |pointer| switch (@typeInfo(pointer.child)) {
                .array => try self.bindText(index, arg),
                else => try self.bindText(index, arg),
            },
            else => @compileError("cannot bind " ++ @typeName(T)),
        }
    }

    /// The current row as a `Row`, field by column position.
    pub fn read(self: *Statement, comptime Row: type, arena: std.mem.Allocator) !Row {
        var row: Row = undefined;
        const info = @typeInfo(Row).@"struct";
        inline for (info.field_names, info.field_types, 0..) |name, Field, index| @field(row, name) = try self.column(Field, arena, index);
        return row;
    }

    pub fn column(self: *Statement, comptime T: type, arena: std.mem.Allocator, index: usize) !T {
        if (@typeInfo(T) == .optional) {
            if (self.columnType(index) == c.SQLITE_NULL) return null;
            return try self.column(@typeInfo(T).optional.child, arena, index);
        }
        return switch (T) {
            i64 => self.columnInt(index),
            i32, u32, usize, u16, u8 => @intCast(self.columnInt(index)),
            f64 => self.columnFloat(index),
            bool => self.columnBool(index),
            []const u8 => try arena.dupe(u8, self.columnText(index)),
            else => switch (@typeInfo(T)) {
                .@"enum" => std.meta.stringToEnum(T, self.columnText(index)) orelse return error.UnexpectedValue,
                else => @compileError("cannot read " ++ @typeName(T)),
            },
        };
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
        const started = monotonicNs();
        const rc = c.sqlite3_step(self.handle);
        self.ns += monotonicNs() - started;
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

    pub fn columnBlob(self: *Statement, index: usize) []const u8 {
        const ptr = c.sqlite3_column_blob(self.handle, @intCast(index));
        const len: usize = @intCast(c.sqlite3_column_bytes(self.handle, @intCast(index)));
        if (ptr == null or len == 0) return "";
        return @as([*]const u8, @ptrCast(ptr))[0..len];
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

test "typed queries and the statement cache" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var db = try Db.open(std.testing.allocator, ":memory:", true);
    defer db.close();
    try db.exec("CREATE TABLE t(a INTEGER, b TEXT, c REAL)");
    try db.run(arena, "INSERT INTO t VALUES(?,?,?)", .{ 1, "x", 1.5 });
    try db.run(arena, "INSERT INTO t VALUES(?,?,?)", .{ 2, null, 2.5 });
    const Row = struct { a: i64, b: ?[]const u8, c: f64 };
    const rows = try db.all(arena, Row, "SELECT a,b,c FROM t ORDER BY a", .{});
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("x", rows[0].b.?);
    try std.testing.expect(rows[1].b == null);
    // The same SQL used again while it is still being iterated gets its own statement.
    var outer = try db.prepare(arena, "SELECT a,b,c FROM t ORDER BY a");
    defer outer.deinit();
    var seen: usize = 0;
    while (try outer.step() == .row) {
        seen += 1;
        try std.testing.expectEqual(@as(usize, 2), (try db.all(arena, Row, "SELECT a,b,c FROM t ORDER BY a", .{})).len);
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
    try std.testing.expectEqual(@as(i64, 2), try db.scalar(arena, i64, "SELECT count(*) FROM t", .{}));
    try std.testing.expectEqual(@as(i64, 0), try db.scalar(arena, i64, "SELECT a FROM t WHERE a>?", .{9}));
}
