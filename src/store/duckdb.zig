const std = @import("std");
const c = @import("duckdb_c");

pub const Error = error{
    OpenFailed,
    ConnectFailed,
    ConfigFailed,
    QueryFailed,
    PrepareFailed,
    BindFailed,
};

pub const Database = struct {
    handle: c.duckdb_database,
    connection: c.duckdb_connection,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) (Error || std.mem.Allocator.Error)!Database {
        return openWithTemp(allocator, path, null);
    }

    pub fn openWithTemp(
        allocator: std.mem.Allocator,
        path: []const u8,
        temp_directory: ?[]const u8,
    ) (Error || std.mem.Allocator.Error)!Database {
        var config: c.duckdb_config = null;
        if (c.duckdb_create_config(&config) != c.DuckDBSuccess) return error.ConfigFailed;
        defer c.duckdb_destroy_config(&config);

        if (temp_directory) |directory| {
            const directory_z = try allocator.dupeSentinel(u8, directory, 0);
            defer allocator.free(directory_z);
            if (c.duckdb_set_config(
                config,
                "temp_directory",
                directory_z.ptr,
            ) != c.DuckDBSuccess) {
                return error.ConfigFailed;
            }
        }
        inline for (.{
            .{ "threads", "1" },
            .{ "memory_limit", "128MB" },
            .{ "max_temp_directory_size", "256MB" },
            .{ "allocator_flush_threshold", "8MiB" },
            .{ "preserve_insertion_order", "false" },
            .{ "allow_community_extensions", "false" },
            .{ "enable_external_access", "false" },
        }) |setting| {
            if (c.duckdb_set_config(config, setting[0], setting[1]) != c.DuckDBSuccess) {
                std.log.err("DuckDB rejected startup setting {s}={s}", setting);
                return error.ConfigFailed;
            }
        }
        const path_z = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(path_z);

        var handle: c.duckdb_database = null;
        var native_error: [*c]u8 = null;
        if (c.duckdb_open_ext(path_z.ptr, &handle, config, &native_error) != c.DuckDBSuccess) {
            defer if (native_error != null) c.duckdb_free(native_error);
            logNativeError("open", native_error);
            return error.OpenFailed;
        }
        errdefer c.duckdb_close(&handle);

        var connection: c.duckdb_connection = null;
        if (c.duckdb_connect(handle, &connection) != c.DuckDBSuccess) {
            return error.ConnectFailed;
        }
        errdefer c.duckdb_disconnect(&connection);
        var database = Database{
            .handle = handle,
            .connection = connection,
        };
        database.exec("SET lock_configuration = true") catch
            return error.ConfigFailed;
        return database;
    }

    pub fn deinit(self: *Database) void {
        c.duckdb_disconnect(&self.connection);
        c.duckdb_close(&self.handle);
    }

    pub fn version() []const u8 {
        return std.mem.span(c.duckdb_library_version());
    }

    pub fn exec(self: *Database, sql: [:0]const u8) Error!void {
        var result = try self.query(sql);
        result.deinit();
    }

    pub fn query(self: *Database, sql: [:0]const u8) Error!Result {
        var raw = std.mem.zeroes(c.duckdb_result);
        if (c.duckdb_query(self.connection, sql.ptr, &raw) != c.DuckDBSuccess) {
            defer c.duckdb_destroy_result(&raw);
            logResultError(&raw);
            return error.QueryFailed;
        }
        return .{ .raw = raw };
    }

    pub fn prepare(self: *Database, sql: [:0]const u8) Error!Statement {
        var handle: c.duckdb_prepared_statement = null;
        if (c.duckdb_prepare(self.connection, sql.ptr, &handle) != c.DuckDBSuccess) {
            defer c.duckdb_destroy_prepare(&handle);
            const message = c.duckdb_prepare_error(handle);
            if (message != null) {
                std.log.err("DuckDB prepare failed: {s}", .{std.mem.span(message)});
            } else {
                std.log.err("DuckDB prepare failed without a native message", .{});
            }
            return error.PrepareFailed;
        }
        return .{ .handle = handle };
    }

    pub fn checkpoint(self: *Database) Error!void {
        try self.exec("CHECKPOINT");
    }

    pub fn interrupt(self: *Database) void {
        c.duckdb_interrupt(self.connection);
    }
};

pub const Result = struct {
    raw: c.duckdb_result,

    pub fn deinit(self: *Result) void {
        c.duckdb_destroy_result(&self.raw);
    }

    pub fn rowCount(self: *Result) usize {
        return @intCast(c.duckdb_row_count(&self.raw));
    }

    pub fn columnCount(self: *Result) usize {
        return @intCast(c.duckdb_column_count(&self.raw));
    }

    pub fn int64(self: *Result, column: usize, row: usize) i64 {
        return c.duckdb_value_int64(&self.raw, column, row);
    }

    pub fn isNull(self: *Result, column: usize, row: usize) bool {
        return c.duckdb_value_is_null(&self.raw, column, row);
    }

    pub fn text(
        self: *Result,
        allocator: std.mem.Allocator,
        column: usize,
        row: usize,
    ) (std.mem.Allocator.Error || error{NullValue})![]u8 {
        if (self.isNull(column, row)) return error.NullValue;
        const native = c.duckdb_value_varchar(&self.raw, column, row);
        if (native == null) return error.NullValue;
        defer c.duckdb_free(native);
        return allocator.dupe(u8, std.mem.span(native));
    }
};

pub const Statement = struct {
    handle: c.duckdb_prepared_statement,

    pub fn deinit(self: *Statement) void {
        c.duckdb_destroy_prepare(&self.handle);
    }

    pub fn clear(self: *Statement) Error!void {
        if (c.duckdb_clear_bindings(self.handle) != c.DuckDBSuccess) return error.BindFailed;
    }

    pub fn bindInt64(self: *Statement, index: usize, value: i64) Error!void {
        if (c.duckdb_bind_int64(self.handle, index, value) != c.DuckDBSuccess) {
            return error.BindFailed;
        }
    }

    pub fn bindText(self: *Statement, index: usize, value: []const u8) Error!void {
        if (c.duckdb_bind_varchar_length(self.handle, index, value.ptr, value.len) != c.DuckDBSuccess) {
            return error.BindFailed;
        }
    }

    pub fn bindBlob(self: *Statement, index: usize, value: []const u8) Error!void {
        if (c.duckdb_bind_blob(self.handle, index, value.ptr, value.len) != c.DuckDBSuccess) {
            return error.BindFailed;
        }
    }

    pub fn execute(self: *Statement) Error!Result {
        var raw = std.mem.zeroes(c.duckdb_result);
        if (c.duckdb_execute_prepared(self.handle, &raw) != c.DuckDBSuccess) {
            defer c.duckdb_destroy_result(&raw);
            logResultError(&raw);
            return error.QueryFailed;
        }
        return .{ .raw = raw };
    }
};

fn logNativeError(operation: []const u8, message: [*c]const u8) void {
    if (message != null) {
        std.log.err("DuckDB {s} failed: {s}", .{ operation, std.mem.span(message) });
    } else {
        std.log.err("DuckDB {s} failed without a native message", .{operation});
    }
}

fn logResultError(result: *c.duckdb_result) void {
    const message = c.duckdb_result_error(result);
    if (message != null) {
        std.log.err("DuckDB query failed: {s}", .{std.mem.span(message)});
    } else {
        std.log.err("DuckDB query failed without a native message", .{});
    }
}

test "production allocator threshold is exact and locked" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/events.duckdb",
        .{temporary.sub_path},
    );
    defer allocator.free(path);
    var database = try Database.open(allocator, path);
    defer database.deinit();
    var result = try database.query(
        "SELECT" ++
            " current_setting('allocator_flush_threshold')::VARCHAR," ++
            " current_setting('lock_configuration')::BOOLEAN",
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.rowCount());
    const first = try result.text(allocator, 0, 0);
    defer allocator.free(first);
    try std.testing.expectEqualStrings("8.0 MiB", first);
    try std.testing.expectEqual(@as(i64, 1), result.int64(1, 0));
}
