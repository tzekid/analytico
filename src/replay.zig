//! Session replay storage: a second SQLite file next to the analytics
//! database. Replays are big and short-lived, so they get their own file,
//! write lock and retention; analytics backups and queries stay small.
//! Chunks are rrweb event arrays exactly as the recorder sent them (gzip, or
//! plain JSON from a closing page), already masked in the browser.
const std = @import("std");
const db_mod = @import("db.zig");

pub const current_version: i64 = 1;
pub const maximum_chunk_bytes = 256 * 1024;
pub const maximum_session_bytes = 5 * 1024 * 1024;
pub const maximum_session_ms: i64 = 30 * 60_000;

const schema_sql =
    \\PRAGMA auto_vacuum=INCREMENTAL;
    \\BEGIN IMMEDIATE;
    \\CREATE TABLE replays (
    \\  site_id INTEGER NOT NULL,
    \\  session_id TEXT NOT NULL,
    \\  visitor_id TEXT NOT NULL,
    \\  started_at_ms INTEGER NOT NULL,
    \\  last_at_ms INTEGER NOT NULL,
    \\  received_at_ms INTEGER NOT NULL,
    \\  bytes INTEGER NOT NULL,
    \\  chunks INTEGER NOT NULL,
    \\  entry_path TEXT NOT NULL,
    \\  device TEXT NOT NULL,
    \\  browser TEXT NOT NULL,
    \\  country TEXT,
    \\  PRIMARY KEY(site_id,session_id)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE INDEX replays_time ON replays(site_id,started_at_ms);
    \\CREATE INDEX replays_visitor ON replays(site_id,visitor_id);
    \\CREATE TABLE replay_chunks (
    \\  site_id INTEGER NOT NULL,
    \\  session_id TEXT NOT NULL,
    \\  page_id TEXT NOT NULL,
    \\  seq INTEGER NOT NULL CHECK(seq BETWEEN 0 AND 100000),
    \\  first_ms INTEGER NOT NULL,
    \\  received_at_ms INTEGER NOT NULL,
    \\  data BLOB NOT NULL,
    \\  PRIMARY KEY(site_id,session_id,page_id,seq)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE replay_meta (name TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT, WITHOUT ROWID;
    \\PRAGMA user_version=1;
    \\COMMIT;
;

/// Creates an empty replay database. Callers make sure the file is new.
pub fn create(allocator: std.mem.Allocator, path: []const u8) !void {
    var database = try db_mod.Db.open(allocator, path, true);
    defer database.close();
    if (try version(&database, allocator) != 0) return error.DatabaseAlreadyInitialized;
    try database.exec(schema_sql);
}

/// Opens the replay database, which must exist and be current.
pub fn open(allocator: std.mem.Allocator, path: []const u8, write: bool) !db_mod.Db {
    var database = try db_mod.Db.open(allocator, path, write);
    errdefer database.close();
    const actual = try version(&database, allocator);
    if (actual < current_version) return error.ReplayMigrationRequired;
    if (actual > current_version) return error.NewerReplaySchema;
    return database;
}

fn version(database: *db_mod.Db, allocator: std.mem.Allocator) !i64 {
    var statement = try database.prepare(allocator, "PRAGMA user_version");
    defer statement.deinit();
    if (try statement.step() != .row) return error.MissingSchemaVersion;
    return statement.columnInt(0);
}

pub const Chunk = struct {
    site_id: i64,
    session_id: []const u8,
    visitor_id: []const u8,
    page_id: []const u8,
    seq: i64,
    first_ms: i64,
    last_ms: i64,
    received_at_ms: i64,
    data: []const u8,
    entry_path: []const u8,
    device: []const u8,
    browser: []const u8,
    country: ?[]const u8,
};

/// Stores one chunk. Sessions are capped by size and length; a chunk past
/// either cap is refused rather than truncating the recording silently.
pub fn addChunk(allocator: std.mem.Allocator, database: *db_mod.Db, chunk: Chunk) !void {
    if (chunk.data.len == 0 or chunk.data.len > maximum_chunk_bytes) return error.InvalidChunkSize;
    // gzip, or a plain JSON array sent while the page was closing.
    const gzipped = chunk.data.len >= 2 and chunk.data[0] == 0x1f and chunk.data[1] == 0x8b;
    if (!gzipped and chunk.data[0] != '[') return error.InvalidChunkEncoding;
    if (chunk.last_ms < chunk.first_ms) return error.InvalidChunkTime;
    try database.exec("BEGIN IMMEDIATE");
    errdefer database.exec("ROLLBACK") catch {};
    var existing = try database.prepare(allocator, "SELECT visitor_id,started_at_ms,bytes FROM replays WHERE site_id=? AND session_id=?");
    defer existing.deinit();
    try existing.bindInt(1, chunk.site_id);
    try existing.bindText(2, chunk.session_id);
    if (try existing.step() == .row) {
        if (!std.mem.eql(u8, existing.columnText(0), chunk.visitor_id)) return error.ReplayVisitorMismatch;
        if (existing.columnInt(2) + @as(i64, @intCast(chunk.data.len)) > maximum_session_bytes) return error.ReplayTooLarge;
        if (chunk.last_ms - @min(existing.columnInt(1), chunk.first_ms) > maximum_session_ms + 60_000) return error.ReplayTooLong;
    }
    var duplicate = try database.prepare(allocator, "SELECT 1 FROM replay_chunks WHERE site_id=? AND session_id=? AND page_id=? AND seq=?");
    defer duplicate.deinit();
    try duplicate.bindInt(1, chunk.site_id);
    try duplicate.bindText(2, chunk.session_id);
    try duplicate.bindText(3, chunk.page_id);
    try duplicate.bindInt(4, chunk.seq);
    // A retried upload of a chunk already stored.
    if (try duplicate.step() == .row) return database.exec("ROLLBACK");
    var insert = try database.prepare(allocator, "INSERT INTO replay_chunks(site_id,session_id,page_id,seq,first_ms,received_at_ms,data) VALUES(?,?,?,?,?,?,?)");
    defer insert.deinit();
    try insert.bindInt(1, chunk.site_id);
    try insert.bindText(2, chunk.session_id);
    try insert.bindText(3, chunk.page_id);
    try insert.bindInt(4, chunk.seq);
    try insert.bindInt(5, chunk.first_ms);
    try insert.bindInt(6, chunk.received_at_ms);
    try insert.bindBlob(7, chunk.data);
    _ = try insert.step();
    var upsert = try database.prepare(allocator,
        \\INSERT INTO replays(site_id,session_id,visitor_id,started_at_ms,last_at_ms,received_at_ms,bytes,chunks,entry_path,device,browser,country)
        \\VALUES(?1,?2,?3,?4,?5,?6,?7,1,?8,?9,?10,?11)
        \\ON CONFLICT(site_id,session_id) DO UPDATE SET started_at_ms=min(started_at_ms,excluded.started_at_ms),
        \\ last_at_ms=max(last_at_ms,excluded.last_at_ms),bytes=bytes+excluded.bytes,chunks=chunks+1
    );
    defer upsert.deinit();
    try upsert.bindInt(1, chunk.site_id);
    try upsert.bindText(2, chunk.session_id);
    try upsert.bindText(3, chunk.visitor_id);
    try upsert.bindInt(4, chunk.first_ms);
    try upsert.bindInt(5, chunk.last_ms);
    try upsert.bindInt(6, chunk.received_at_ms);
    try upsert.bindInt(7, @intCast(chunk.data.len));
    try upsert.bindText(8, chunk.entry_path);
    try upsert.bindText(9, chunk.device);
    try upsert.bindText(10, chunk.browser);
    try upsert.bindOptionalText(11, chunk.country);
    _ = try upsert.step();
    try database.exec("COMMIT");
}

/// Deletes the replays of visitors erased on request.
pub fn forgetVisitors(allocator: std.mem.Allocator, database: *db_mod.Db, site_id: i64, visitor_ids: []const []const u8) !void {
    if (visitor_ids.len == 0) return;
    try database.exec("BEGIN IMMEDIATE");
    errdefer database.exec("ROLLBACK") catch {};
    for (visitor_ids) |visitor_id| {
        inline for (.{
            "DELETE FROM replay_chunks WHERE site_id=?1 AND session_id IN (SELECT session_id FROM replays WHERE site_id=?1 AND visitor_id=?2)",
            "DELETE FROM replays WHERE site_id=?1 AND visitor_id=?2",
        }) |sql| {
            var statement = try database.prepare(allocator, sql);
            defer statement.deinit();
            try statement.bindInt(1, site_id);
            try statement.bindText(2, visitor_id);
            _ = try statement.step();
        }
    }
    try database.exec("COMMIT");
}

/// Retention: whole sessions older than the cutoff go, then free pages are
/// returned to the file system.
pub fn prune(allocator: std.mem.Allocator, database: *db_mod.Db, cutoff_ms: i64) !usize {
    try database.exec("BEGIN IMMEDIATE");
    errdefer database.exec("ROLLBACK") catch {};
    var removed: usize = 0;
    inline for (.{
        "DELETE FROM replay_chunks WHERE (site_id,session_id) IN (SELECT site_id,session_id FROM replays WHERE received_at_ms<?1)",
        "DELETE FROM replays WHERE received_at_ms<?1",
    }) |sql| {
        var statement = try database.prepare(allocator, sql);
        defer statement.deinit();
        try statement.bindInt(1, cutoff_ms);
        _ = try statement.step();
        removed += database.changes();
    }
    try database.exec("COMMIT");
    try database.exec("PRAGMA incremental_vacuum");
    return removed;
}

/// Writes every chunk of one session as length-prefixed (u32, big-endian)
/// gzip members or JSON arrays in recording order, for the workspace player.
pub fn writeChunks(allocator: std.mem.Allocator, database: *db_mod.Db, site_id: i64, session_id: []const u8, w: *std.Io.Writer) !usize {
    var statement = try database.prepare(allocator, "SELECT data FROM rp.replay_chunks WHERE site_id=? AND session_id=? ORDER BY first_ms,seq");
    defer statement.deinit();
    try statement.bindInt(1, site_id);
    try statement.bindText(2, session_id);
    var count: usize = 0;
    while (try statement.step() == .row) : (count += 1) {
        const bytes = statement.columnBlob(0);
        try w.writeInt(u32, @intCast(bytes.len), .big);
        try w.writeAll(bytes);
    }
    return count;
}
