const std = @import("std");
const db_mod = @import("db.zig");
const replay = @import("replay.zig");
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
    defer paths.deinit(allocator);
    try createEmptyFile(io, paths.database);
    var database = try db_mod.Db.open(allocator, paths.database, true);
    defer database.close();
    try schema.initialize(&database);
    try createEmptyFile(io, paths.replays);
    try replay.create(allocator, paths.replays);
    var key: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    try io.randomSecure(&key);
    try writeKey(io, paths.key, &key);
    try output.print("initialized data={s} schema={d}\n", .{ directory, schema.current_version });
}

pub fn doctor(allocator: std.mem.Allocator, io: std.Io, output: *std.Io.Writer, directory: []const u8) !void {
    const paths = try store_mod.Paths.init(allocator, directory);
    defer paths.deinit(allocator);
    _ = try store_mod.readKey(io, paths.key);
    var store = try store_mod.Store.open(allocator, io, directory, false);
    defer store.close();
    try db_mod.integrity(&store.database, allocator);
    var replays = try replay.open(allocator, paths.replays, false);
    defer replays.close();
    try db_mod.integrity(&replays, allocator);
    var counts = try store.database.prepare(allocator, "SELECT (SELECT count(*) FROM sites),(SELECT count(*) FROM page_views)," ++
        "(SELECT count(*) FROM page_summaries),(SELECT count(*) FROM events)");
    defer counts.deinit();
    if (try counts.step() != .row) return error.DatabaseReadFailed;
    var replay_count = try replays.prepare(allocator, "SELECT count(*) FROM replays");
    defer replay_count.deinit();
    if (try replay_count.step() != .row) return error.DatabaseReadFailed;
    try output.print("ok schema={d} sites={d} page_views={d} summaries={d} events={d} replays={d}\n", .{
        schema.current_version, counts.columnInt(0), counts.columnInt(1), counts.columnInt(2), counts.columnInt(3), replay_count.columnInt(0),
    });
}

pub fn backup(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
    destination: []const u8,
) !void {
    var source = try store_mod.Store.open(allocator, io, directory, false);
    defer source.close();
    const key_destination = try copyVerified(allocator, io, &source.database, directory, destination);
    try output.print("backup verified database={s} key={s}\n", .{ destination, key_destination });
}

/// Writes a verified online copy of `source` plus the key companion and the
/// replay database (`<destination>.replays`). None of the destinations may
/// exist; nothing is ever overwritten.
pub fn copyVerified(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: *db_mod.Db,
    directory: []const u8,
    destination: []const u8,
) ![]const u8 {
    try requireMissing(io, destination);
    const key_destination = try std.fmt.allocPrint(allocator, "{s}.key", .{destination});
    try requireMissing(io, key_destination);
    const replay_destination = try std.fmt.allocPrint(allocator, "{s}.replays", .{destination});
    try requireMissing(io, replay_destination);
    const paths = try store_mod.Paths.init(allocator, directory);
    defer paths.deinit(allocator);
    _ = try store_mod.readKey(io, paths.key);
    try db_mod.integrity(source, allocator);
    try createEmptyFile(io, destination);
    errdefer std.Io.Dir.cwd().deleteFile(io, destination) catch {};
    var target = try db_mod.Db.open(allocator, destination, true);
    defer target.close();
    try db_mod.backup(source, &target);
    try db_mod.integrity(&target, allocator);
    try std.Io.Dir.copyFile(.cwd(), paths.key, .cwd(), key_destination, io, .{ .replace = false });
    const key_file = try std.Io.Dir.cwd().openFile(io, key_destination, .{});
    defer key_file.close(io);
    try key_file.sync(io);
    // Before `migrate` creates it, an older data directory has no replays.
    if (std.Io.Dir.cwd().statFile(io, paths.replays, .{})) |_| {
        var replays = try db_mod.Db.open(allocator, paths.replays, false);
        defer replays.close();
        try createEmptyFile(io, replay_destination);
        var replay_target = try db_mod.Db.open(allocator, replay_destination, true);
        defer replay_target.close();
        try db_mod.backup(&replays, &replay_target);
        try db_mod.integrity(&replay_target, allocator);
    } else |err| if (err != error.FileNotFound) return err;
    return key_destination;
}

/// Backs up, then applies pending numbered migrations under the writer lock.
pub fn migrate(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
    backup_path: []const u8,
) !void {
    const lock = try store_mod.acquireWriterLock(allocator, io, directory);
    defer lock.close(io);
    const paths = try store_mod.Paths.init(allocator, directory);
    defer paths.deinit(allocator);
    var database = try db_mod.Db.open(allocator, paths.database, true);
    defer database.close();
    const before = try schema.version(&database, allocator);
    const replays_present = if (std.Io.Dir.cwd().statFile(io, paths.replays, .{})) |_| true else |err| switch (err) {
        error.FileNotFound => false,
        else => return err,
    };
    if (before == schema.current_version and replays_present) {
        try output.print("schema current version={d}\n", .{before});
        return;
    }
    _ = try copyVerified(allocator, io, &database, directory, backup_path);
    const after = try schema.migrate(&database, allocator);
    try db_mod.integrity(&database, allocator);
    try database.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    if (std.Io.Dir.cwd().statFile(io, paths.replays, .{})) |_| {} else |err| {
        if (err != error.FileNotFound) return err;
        try createEmptyFile(io, paths.replays);
        try replay.create(allocator, paths.replays);
    }
    try output.print("migrated from={d} to={d} backup={s}\n", .{ before, after, backup_path });
}

pub fn restore(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    backup_path: []const u8,
    directory: []const u8,
) !void {
    const key_source = try std.fmt.allocPrint(allocator, "{s}.key", .{backup_path});
    _ = try store_mod.readKey(io, key_source);
    if (std.Io.Dir.cwd().statFile(io, directory, .{})) |_| return error.DataDirectoryAlreadyExists else |_| {}
    var source = try db_mod.Db.open(allocator, backup_path, false);
    defer source.close();
    // Older backups restore unchanged; `migrate` then upgrades the new copy.
    const source_version = try schema.version(&source, allocator);
    if (source_version < 1) return error.MissingSchemaVersion;
    if (source_version > schema.current_version) return error.NewerDatabaseSchema;
    try std.Io.Dir.cwd().createDir(io, directory, @fromBackingInt(@intCast(0o700)));
    errdefer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    const paths = try store_mod.Paths.init(allocator, directory);
    defer paths.deinit(allocator);
    try createEmptyFile(io, paths.database);
    var target = try db_mod.Db.open(allocator, paths.database, true);
    defer target.close();
    try db_mod.backup(&source, &target);
    try std.Io.Dir.copyFile(.cwd(), key_source, .cwd(), paths.key, io, .{ .replace = false });
    try db_mod.integrity(&target, allocator);
    _ = try store_mod.readKey(io, paths.key);
    const replay_source = try std.fmt.allocPrint(allocator, "{s}.replays", .{backup_path});
    if (std.Io.Dir.cwd().statFile(io, replay_source, .{})) |_| {
        var replays = try db_mod.Db.open(allocator, replay_source, false);
        defer replays.close();
        try createEmptyFile(io, paths.replays);
        var replay_target = try db_mod.Db.open(allocator, paths.replays, true);
        defer replay_target.close();
        try db_mod.backup(&replays, &replay_target);
        try db_mod.integrity(&replay_target, allocator);
    } else |err| if (err != error.FileNotFound) return err;
    try output.print("restore verified data={s}\n", .{directory});
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
    const removed = try store_mod.pruneBefore(allocator, &store.database, cutoff);
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
    try db_mod.integrity(&store.database, allocator);
    try output.print("vacuum complete backup={s}\n", .{backup_path});
}

pub fn createEmptyFile(io: std.Io, path: []const u8) !void {
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
