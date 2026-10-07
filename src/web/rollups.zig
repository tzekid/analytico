//! Daily rollups. A UTC day's page views never change once the day is over
//! (acceptance uses server receipt time), so each closed day is summarised
//! once per dimension. Visitor-day pseudonyms are per day, so summed visitor
//! counts stay exact. The current day is summarised up to a recent cut every
//! few minutes; reports read raw rows only after that cut and leave out
//! people the partial summary already counted. Filtered views with more than
//! one condition read raw rows. Deleting a person leaves these anonymous
//! totals, like heatmap cells.
const std = @import("std");
const data = @import("data.zig");
const db_mod = @import("../db.zig");
const server = @import("../server.zig");

const dims = data.rollup_dims;

const Row = struct { key: []const u8, values: [7]i64 };

/// How often today's partial summary is refreshed, and how far its cut stays
/// behind the clock so batches still being written are not skipped.
const partial_every_ms = 5 * 60_000;
const partial_lag_ms = 30_000;

/// Summarises closed days oldest first, then refreshes today's partial
/// summary, for at most `budget_ms`.
pub fn run(arena: std.mem.Allocator, shared: *server.Shared, db: *db_mod.Db, now_ms: i64, budget_ms: i64) !void {
    const started = now_ms;
    const today = now_ms - @mod(now_ms, data.day_ms);
    var sites = try db.prepare(arena,
        \\SELECT s.id,(SELECT min(received_at_ms) FROM page_views pv WHERE pv.site_id=s.id),
        \\ (SELECT max(day) FROM rollup_days r WHERE r.site_id=s.id AND r.until_ms%86400000=0),
        \\ (SELECT max(received_at_ms) FROM page_views pv WHERE pv.site_id=s.id),
        \\ (SELECT max(until_ms) FROM rollup_days r WHERE r.site_id=s.id)
        \\FROM sites s
    );
    defer sites.deinit();
    const Pending = struct { site_id: i64, next: i64, partial: bool };
    var pending: std.ArrayList(Pending) = .empty;
    while (try sites.step() == .row) {
        if (sites.columnType(1) == db_mod.sqlite.SQLITE_NULL) continue;
        const first = sites.columnInt(1);
        const next = if (sites.columnType(2) == db_mod.sqlite.SQLITE_NULL) first - @mod(first, data.day_ms) else (try data.parseDate(sites.columnText(2))) + data.day_ms;
        const partial = sites.columnInt(3) >= today and sites.columnInt(4) < now_ms - partial_every_ms;
        if (next < today or partial) try pending.append(arena, .{ .site_id = sites.columnInt(0), .next = next, .partial = partial });
    }
    for (pending.items) |item| {
        var day = item.next;
        while (day < today) : (day += data.day_ms) {
            try summarise(arena, shared, db, item.site_id, day, day + data.day_ms);
            if (overBudget(started, budget_ms)) return;
        }
        if (item.partial and now_ms - partial_lag_ms > today) {
            try summarise(arena, shared, db, item.site_id, today, now_ms - partial_lag_ms);
            if (overBudget(started, budget_ms)) return;
        }
    }
}

fn overBudget(started: i64, budget_ms: i64) bool {
    return @import("../domain.zig").nowMs() - started > budget_ms;
}

/// Summarises the day's rows received before `until_ms`, replacing any
/// earlier summary of that day.
fn summarise(arena: std.mem.Allocator, shared: *server.Shared, db: *db_mod.Db, site_id: i64, day_ms: i64, until_ms: i64) !void {
    // One pass over the day's rows into a temporary table, then one cheap
    // GROUP BY per dimension over it.
    try db.exec("DROP TABLE IF EXISTS temp.rollup_day");
    var copy = try db.prepare(arena,
        \\CREATE TEMP TABLE rollup_day AS SELECT pv.* FROM page_views pv
        \\WHERE pv.site_id=?1 AND pv.received_at_ms>=?2 AND pv.received_at_ms<?3 AND pv.internal=0 AND pv.traffic_class IN ('human_like','unknown')
    );
    try copy.bindInt(1, site_id);
    try copy.bindInt(2, day_ms);
    try copy.bindInt(3, until_ms);
    _ = copy.step() catch |err| {
        copy.deinit();
        return err;
    };
    copy.deinit();
    defer db.exec("DROP TABLE IF EXISTS temp.rollup_day") catch {};
    // Weekly activity of remembered visitors, for retention cohorts.
    var weeks = try db.prepare(arena, "SELECT DISTINCT visitor_id FROM temp.rollup_day WHERE visitor_id IS NOT NULL");
    defer weeks.deinit();
    var active: std.ArrayList([]const u8) = .empty;
    while (try weeks.step() == .row) try active.append(arena, try arena.dupe(u8, weeks.columnText(0)));
    var rows: std.ArrayList(struct { dim: []const u8, row: Row }) = .empty;
    for (dims) |dim| {
        var statement = try db.prepare(arena, try std.fmt.allocPrint(arena,
            \\SELECT {s} k,count(*),count(DISTINCT pv.visitor_day_id),count(DISTINCT pv.session_id),count(pv.active_ms),coalesce(sum(pv.active_ms),0),
            \\ coalesce(sum(pv.active_ms>=10000 OR pv.max_scroll>=50 OR pv.interaction_count>0),0),coalesce(sum(pv.max_scroll),0)
            \\FROM temp.rollup_day pv GROUP BY k
        , .{dim[1]}));
        defer statement.deinit();
        while (try statement.step() == .row) {
            var row: Row = .{ .key = try arena.dupe(u8, statement.columnText(0)), .values = undefined };
            for (&row.values, 1..) |*value, index| value.* = statement.columnInt(index);
            try rows.append(arena, .{ .dim = dim[0], .row = row });
        }
    }
    const day = data.dateText(day_ms);
    const write = shared.lockWrite();
    defer shared.unlockWrite();
    try write.exec("BEGIN IMMEDIATE");
    errdefer write.exec("ROLLBACK") catch {};
    try write.run(arena, "DELETE FROM rollups WHERE site_id=? AND day=?", .{ site_id, &day });
    var insert = try write.prepare(arena, "INSERT INTO rollups(site_id,day,dim,key,views,visitors,sessions,summaries,active_ms,engaged,scroll_sum) VALUES(?,?,?,?,?,?,?,?,?,?,?)");
    defer insert.deinit();
    for (rows.items) |entry| {
        try insert.reset();
        try insert.bindInt(1, site_id);
        try insert.bindText(2, &day);
        try insert.bindText(3, entry.dim);
        try insert.bindText(4, entry.row.key);
        for (entry.row.values, 5..) |value, index| try insert.bindInt(index, value);
        _ = try insert.step();
    }
    var week_insert = try write.prepare(arena, "INSERT INTO visitor_weeks(site_id,week,visitor_id) VALUES(?,?,?) ON CONFLICT DO NOTHING");
    defer week_insert.deinit();
    for (active.items) |visitor_id| {
        try week_insert.reset();
        try week_insert.bindInt(1, site_id);
        try week_insert.bindInt(2, weekIndex(day_ms));
        try week_insert.bindText(3, visitor_id);
        _ = try week_insert.step();
    }
    try write.run(arena, "INSERT INTO rollup_days(site_id,day,until_ms) VALUES(?,?,?) ON CONFLICT DO UPDATE SET until_ms=excluded.until_ms", .{ site_id, &day, until_ms });
    try write.exec("COMMIT");
}

/// Monday-based week number since the epoch (1970-01-01 was a Thursday).
pub fn weekIndex(ms: i64) i64 {
    return @divFloor(@divFloor(ms, data.day_ms) + 3, 7);
}

test "weeks start on Monday" {
    const monday = try data.parseDate("2026-09-28");
    try std.testing.expectEqual(weekIndex(monday), weekIndex(monday + 6 * data.day_ms + data.day_ms - 1));
    try std.testing.expectEqual(weekIndex(monday) - 1, weekIndex(monday - 1));
}
