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
    if (std.fs.path.dirname(directory)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
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

/// `quick` (the service's pre-start) runs SQLite's quick check, which skips
/// the index and foreign-key cross-checks that make a full check slow on a
/// large database; plain `doctor` checks everything.
pub fn doctor(allocator: std.mem.Allocator, io: std.Io, output: *std.Io.Writer, directory: []const u8, quick: bool) !void {
    const paths = try store_mod.Paths.init(allocator, directory);
    defer paths.deinit(allocator);
    _ = try store_mod.readKey(io, paths.key);
    var store = try store_mod.Store.open(allocator, io, directory, false);
    defer store.close();
    if (quick) try db_mod.quickCheck(&store.database, allocator) else try db_mod.integrity(&store.database, allocator);
    var replays = try replay.open(allocator, paths.replays, false);
    defer replays.close();
    if (quick) try db_mod.quickCheck(&replays, allocator) else try db_mod.integrity(&replays, allocator);
    // The pre-start check stops here: counting rows reads whole tables.
    if (quick) return output.print("ok schema={d} quick\n", .{schema.current_version});
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
    // A copy that fails leaves nothing behind, journals included, but only
    // what it made itself: the exclusive create below is what makes a file
    // this copy's (another one may have taken the name meanwhile).
    try createEmptyFile(io, destination);
    errdefer removeCopy(allocator, io, destination);
    var made_replays = false;
    errdefer if (made_replays) removeCopy(allocator, io, replay_destination);
    var target = try db_mod.Db.open(allocator, destination, true);
    defer target.close();
    // Written straight into the file: through a write-ahead log the copy
    // would first need its whole size again in free space.
    try target.exec("PRAGMA journal_mode=OFF");
    try db_mod.backup(source, &target);
    try db_mod.integrity(&target, allocator);
    // Before `migrate` creates it, an older data directory has no replays.
    if (std.Io.Dir.cwd().statFile(io, paths.replays, .{})) |_| {
        var replays = try db_mod.Db.open(allocator, paths.replays, false);
        defer replays.close();
        try createEmptyFile(io, replay_destination);
        made_replays = true;
        var replay_target = try db_mod.Db.open(allocator, replay_destination, true);
        defer replay_target.close();
        try replay_target.exec("PRAGMA journal_mode=OFF");
        try db_mod.backup(&replays, &replay_target);
        try db_mod.integrity(&replay_target, allocator);
    } else |err| if (err != error.FileNotFound) return err;
    // The key comes last: a backup with its key is complete, and one cut off
    // (the process stopped mid-copy) is never offered for restoring.
    try std.Io.Dir.copyFile(.cwd(), paths.key, .cwd(), key_destination, io, .{ .replace = false });
    const key_file = try std.Io.Dir.cwd().openFile(io, key_destination, .{});
    defer key_file.close(io);
    try key_file.sync(io);
    return key_destination;
}

/// Removes a database copy with its journals.
fn removeCopy(allocator: std.mem.Allocator, io: std.Io, path: []const u8) void {
    inline for (.{ "", "-wal", "-shm" }) |suffix| {
        if (std.fmt.allocPrint(allocator, "{s}" ++ suffix, .{path})) |file| {
            std.Io.Dir.cwd().deleteFile(io, file) catch {};
        } else |_| {}
    }
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
        // An empty file left behind would read as present on the next run.
        errdefer std.Io.Dir.cwd().deleteFile(io, paths.replays) catch {};
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
    if (std.fs.path.dirname(directory)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
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
    // Backups leave out the location database, which is re-importable; without
    // it every visitor's country is unknown and the regional policy asks all.
    try output.print("copy geo.bin from the old data directory (or run analytico geo import) before serving\n", .{});
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
    const removed = try store_mod.pruneBefore(allocator, store_mod.Unlocked{ .database = &store.database }, cutoff);
    try @import("web/audit.zig").recordAs(allocator, &store.database, "cli", null, "retention.pruned", try std.fmt.allocPrint(allocator, "Removed {d} records received before {s}", .{ removed, before }), @import("domain.zig").nowMs());
    try store.checkpoint();
    // The daily export's files of those days go too, as with nightly retention.
    try @import("web/integrations.zig").pruneExports(allocator, io, directory, cutoff);
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
    // VACUUM builds its copy as a temporary database: on disk, not in memory,
    // or a database larger than free memory could never be vacuumed.
    try store.database.exec("PRAGMA temp_store=FILE");
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
