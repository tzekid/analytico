const std = @import("std");
const rate_limit = @import("../http/rate_limit.zig");
const events = @import("../store/events.zig");

pub fn rateTable(output: *std.Io.Writer) !void {
    var limiter = rate_limit.Limiter{};
    var accepted: usize = 0;
    var rejected: usize = 0;
    for (0..100_000) |index| {
        if (limiter.allow(@intCast(index + 1), 1_800_000_000)) {
            accepted += 1;
        } else {
            rejected += 1;
        }
    }
    if (accepted != rate_limit.max_buckets or
        rejected != 100_000 - rate_limit.max_buckets)
    {
        return error.RateTableInvariantFailed;
    }
    try output.print(
        "{{\"attempted\":100000,\"capacity\":{d},\"accepted\":{d},\"rejected\":{d}}}\n",
        .{ rate_limit.max_buckets, accepted, rejected },
    );
}

pub fn inspectV2(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    site_id: []const u8,
    event_id: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, path);
    defer store.deinit();
    try store.requireCurrent();
    const inspected = try store.inspectV2(allocator, site_id, event_id);
    try std.json.Stringify.value(inspected, .{}, output);
    try output.writeByte('\n');
}

pub fn sessionTimeline(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    site_id: []const u8,
    session_id: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, path);
    defer store.deinit();
    try store.requireCurrent();
    const ids = try store.sessionTimelineIds(allocator, site_id, session_id);
    try std.json.Stringify.value(ids, .{}, output);
    try output.writeByte('\n');
}

pub fn identityLinkCount(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, path);
    defer store.deinit();
    try store.requireCurrent();
    var result = try store.database.query("SELECT count(*) FROM identity_links");
    defer result.deinit();
    if (result.rowCount() != 1 or result.columnCount() != 1) {
        return error.InvalidIdentityLinkCount;
    }
    try output.print("{d}\n", .{result.int64(0, 0)});
}

pub fn inspectPerson(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    site_id: []const u8,
    anonymous_id: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, path);
    defer store.deinit();
    try store.requireCurrent();
    const person = try store.resolvePerson(allocator, site_id, anonymous_id);
    try std.json.Stringify.value(person, .{}, output);
    try output.writeByte('\n');
}

pub fn timeBuckets(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    site_id: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, path);
    defer store.deinit();
    try store.requireCurrent();
    var statement = try store.database.prepare(
        \\SELECT received_at_utc_micros, CAST(received_date_utc AS VARCHAR),
        \\       CAST(site_local_date AS VARCHAR), site_utc_offset_minutes
        \\FROM events WHERE site_id = ?
        \\ORDER BY received_at_utc_micros, event_id
    );
    defer statement.deinit();
    try statement.bindText(1, site_id);
    var result = try statement.execute();
    defer result.deinit();
    if (result.columnCount() != 4) return error.InvalidTimeBuckets;
    for (0..result.rowCount()) |row| {
        const utc_date = try result.text(allocator, 1, row);
        const local_date = try result.text(allocator, 2, row);
        try output.print("{d}\t{s}\t{s}\t{d}\n", .{
            result.int64(0, row),
            utc_date,
            local_date,
            result.int64(3, row),
        });
    }
}
