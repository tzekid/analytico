const std = @import("std");
const db_mod = @import("db.zig");
const schema = @import("schema.zig");
const store_mod = @import("store.zig");

pub fn init(allocator: std.mem.Allocator, io: std.Io, output: *std.Io.Writer, directory: []const u8) !void {
    if (directory.len == 0) return error.InvalidDataDirectory;
    _ = std.Io.Dir.cwd().statFile(io, directory, .{}) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    if (std.Io.Dir.cwd().statFile(io, directory, .{})) |_| return error.DataDirectoryAlreadyExists else |_| {}
    try std.Io.Dir.cwd().createDir(io, directory, @fromBackingInt(@intCast(0o700)));
    errdefer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    const paths = try store_mod.Paths.init(allocator, directory);
    try createEmptyFile(io, paths.database);
    var database = try db_mod.Db.open(allocator, paths.database, true);
    defer database.close();
    try schema.initialize(&database);
    var key: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    try io.randomSecure(&key);
    try writeKey(io, paths.key, &key);
    try output.print("initialized data={s} schema={d}\n", .{ directory, schema.current_version });
}

pub fn migrate(allocator: std.mem.Allocator, io: std.Io, output: *std.Io.Writer, directory: []const u8) !void {
    const lock_path = try std.fs.path.join(allocator, &.{ directory, "writer.lock" });
    const writer_lock = std.Io.Dir.cwd().createFile(io, lock_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = @fromBackingInt(@intCast(0o600)),
    }) catch |err| switch (err) {
        error.WouldBlock => return error.WriterAlreadyRunning,
        else => return err,
    };
    defer writer_lock.close(io);
    const paths = try store_mod.Paths.init(allocator, directory);
    var database = try db_mod.Db.open(allocator, paths.database, true);
    defer database.close();
    const actual = try schema.version(&database, allocator);
    if (actual == schema.current_version) {
        try output.print("schema already current version={d}\n", .{actual});
        return;
    }
    if (actual == 0) {
        try schema.initialize(&database);
        try output.print("migrated schema=0->{d}\n", .{schema.current_version});
        return;
    }
    if (actual > schema.current_version) return error.NewerDatabaseSchema;
    return error.UnsupportedMigrationPath;
}

pub fn doctor(allocator: std.mem.Allocator, io: std.Io, output: *std.Io.Writer, directory: []const u8) !void {
    const paths = try store_mod.Paths.init(allocator, directory);
    _ = try readKey(io, paths.key);
    var store = try store_mod.Store.open(allocator, io, directory, false);
    defer store.close();
    try store.integrity();
    var counts = try store.database.prepare(allocator, "SELECT (SELECT count(*) FROM sites),(SELECT count(*) FROM page_views)," ++
        "(SELECT count(*) FROM page_summaries),(SELECT count(*) FROM events)");
    defer counts.deinit();
    if (try counts.step() != .row) return error.DatabaseReadFailed;
    try output.print("ok schema={d} sites={d} page_views={d} summaries={d} events={d}\n", .{
        schema.current_version, counts.columnInt(0), counts.columnInt(1), counts.columnInt(2), counts.columnInt(3),
    });
}

pub fn backup(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
    destination: []const u8,
) !void {
    try requireMissing(io, destination);
    const key_destination = try std.fmt.allocPrint(allocator, "{s}.key", .{destination});
    try requireMissing(io, key_destination);
    const paths = try store_mod.Paths.init(allocator, directory);
    _ = try readKey(io, paths.key);
    var source = try store_mod.Store.open(allocator, io, directory, false);
    defer source.close();
    try source.integrity();
    try createEmptyFile(io, destination);
    errdefer std.Io.Dir.cwd().deleteFile(io, destination) catch {};
    var target = try db_mod.Db.open(allocator, destination, true);
    defer target.close();
    try db_mod.backup(&source.database, &target);
    try schema.requireCurrent(&target, allocator);
    try integrityDb(allocator, &target);
    try std.Io.Dir.copyFile(.cwd(), paths.key, .cwd(), key_destination, io, .{ .replace = false });
    const key_file = try std.Io.Dir.cwd().openFile(io, key_destination, .{});
    defer key_file.close(io);
    try key_file.sync(io);
    try output.print("backup verified database={s} key={s}\n", .{ destination, key_destination });
}

pub fn restore(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    backup_path: []const u8,
    directory: []const u8,
) !void {
    const key_source = try std.fmt.allocPrint(allocator, "{s}.key", .{backup_path});
    _ = try readKey(io, key_source);
    if (std.Io.Dir.cwd().statFile(io, directory, .{})) |_| return error.DataDirectoryAlreadyExists else |_| {}
    var source = try db_mod.Db.open(allocator, backup_path, false);
    defer source.close();
    try schema.requireCurrent(&source, allocator);
    try std.Io.Dir.cwd().createDir(io, directory, @fromBackingInt(@intCast(0o700)));
    errdefer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    const paths = try store_mod.Paths.init(allocator, directory);
    try createEmptyFile(io, paths.database);
    var target = try db_mod.Db.open(allocator, paths.database, true);
    defer target.close();
    try db_mod.backup(&source, &target);
    try std.Io.Dir.copyFile(.cwd(), key_source, .cwd(), paths.key, io, .{ .replace = false });
    try integrityDb(allocator, &target);
    _ = try readKey(io, paths.key);
    try output.print("restore verified data={s}\n", .{directory});
}

pub fn integrity(allocator: std.mem.Allocator, io: std.Io, output: *std.Io.Writer, directory: []const u8) !void {
    var store = try store_mod.Store.open(allocator, io, directory, false);
    defer store.close();
    try store.integrity();
    try output.writeAll("integrity ok\n");
}

pub fn prune(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
    before: []const u8,
    backup_path: []const u8,
) !void {
    try backup(allocator, io, output, directory, backup_path);
    var store = try store_mod.Store.open(allocator, io, directory, true);
    defer store.close();
    var cutoff_query = try store.database.prepare(allocator, "SELECT unixepoch(?)*1000");
    defer cutoff_query.deinit();
    try cutoff_query.bindText(1, before);
    if (try cutoff_query.step() != .row or cutoff_query.columnType(0) == db_mod.sqlite.SQLITE_NULL) return error.InvalidDate;
    const cutoff = cutoff_query.columnInt(0);
    try store.database.exec("BEGIN IMMEDIATE");
    errdefer store.database.exec("ROLLBACK") catch {};
    var removed: usize = 0;
    inline for (.{
        "DELETE FROM page_summaries WHERE received_at_ms<?",
        "DELETE FROM page_views WHERE received_at_ms<?",
        "DELETE FROM events WHERE received_at_ms<?",
        "DELETE FROM record_receipts WHERE received_at_ms<?",
    }) |sql| {
        var statement = try store.database.prepare(allocator, sql);
        defer statement.deinit();
        try statement.bindInt(1, cutoff);
        _ = try statement.step();
        removed += store.database.changes();
    }
    try store.database.exec("COMMIT");
    try store.checkpoint();
    try output.print("prune complete before={s} removed={d} backup={s}\n", .{ before, removed, backup_path });
}

pub fn vacuum(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
    backup_path: []const u8,
) !void {
    try backup(allocator, io, output, directory, backup_path);
    var store = try store_mod.Store.open(allocator, io, directory, true);
    defer store.close();
    try store.checkpoint();
    try store.database.exec("VACUUM");
    try store.integrity();
    try output.print("vacuum complete backup={s}\n", .{backup_path});
}

pub fn readKey(io: std.Io, path: []const u8) ![32]u8 {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.size != 32) return error.InvalidKeyFile;
    if (stat.permissions.toMode() & 0o777 != 0o600) return error.InsecureKeyPermissions;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [32]u8 = undefined;
    var reader_buffer: [32]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    try reader.interface.readSliceAll(&buffer);
    return buffer;
}

fn createEmptyFile(io: std.Io, path: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .exclusive = true,
        .permissions = @fromBackingInt(@intCast(0o600)),
    });
    defer file.close(io);
    try file.sync(io);
}

fn writeKey(io: std.Io, path: []const u8, key: *const [32]u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .exclusive = true,
        .permissions = @fromBackingInt(@intCast(0o600)),
    });
    defer file.close(io);
    var buffer: [32]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(key);
    try writer.flush();
    try file.sync(io);
}

fn requireMissing(io: std.Io, path: []const u8) !void {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.DestinationAlreadyExists;
}

fn integrityDb(allocator: std.mem.Allocator, database: *db_mod.Db) !void {
    var statement = try database.prepare(allocator, "PRAGMA integrity_check");
    defer statement.deinit();
    if (try statement.step() != .row or !std.mem.eql(u8, statement.columnText(0), "ok")) return error.IntegrityCheckFailed;
    var foreign_keys = try database.prepare(allocator, "PRAGMA foreign_key_check");
    defer foreign_keys.deinit();
    if (try foreign_keys.step() == .row) return error.ForeignKeyCheckFailed;
}
