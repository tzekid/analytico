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
    // Paths: each visit's first and last page and every step between pages
    // within the day ("next" keys are the page, char 31, the next page or
    // nothing when the visit ended there).
    var paths = try db.prepare(arena,
        \\WITH f AS (SELECT path,lead(path) OVER w nxt,row_number() OVER w rn FROM temp.rollup_day WHERE session_id IS NOT NULL
        \\ WINDOW w AS (PARTITION BY session_id ORDER BY occurred_at_ms,received_at_ms))
        \\SELECT 'entry',path,count(*) FROM f WHERE rn=1 GROUP BY path
        \\UNION ALL SELECT 'exit',path,count(*) FROM f WHERE nxt IS NULL GROUP BY path
        \\UNION ALL SELECT 'next',path||char(31)||coalesce(nxt,''),count(*) FROM f GROUP BY 2
    );
    defer paths.deinit();
    while (try paths.step() == .row) {
        var row: Row = .{ .key = try arena.dupe(u8, paths.columnText(1)), .values = @splat(0) };
        row.values[0] = paths.columnInt(2);
        try rows.append(arena, .{ .dim = if (std.mem.eql(u8, paths.columnText(0), "entry")) "entry" else if (std.mem.eql(u8, paths.columnText(0), "exit")) "exit" else "next", .row = row });
    }
    // Sections each page's readers reached ("section" keys are the page,
    // char 31, the section; with no section, all of the page's summaries).
    var sections = try db.prepare(arena,
        \\WITH s AS MATERIALIZED (SELECT pv.path,ps.sections_json FROM temp.rollup_day pv JOIN page_summaries ps ON ps.site_id=pv.site_id AND ps.page_id=pv.page_id)
        \\SELECT path||char(31),count(*) FROM s GROUP BY path
        \\UNION ALL SELECT s.path||char(31)||j.value,count(*) FROM s, json_each(s.sections_json) j GROUP BY 1
    );
    defer sections.deinit();
    while (try sections.step() == .row) {
        var row: Row = .{ .key = try arena.dupe(u8, sections.columnText(0)), .values = @splat(0) };
        row.values[0] = sections.columnInt(1);
        try rows.append(arena, .{ .dim = "section", .row = row });
    }
    // Web Vitals per page as counts of values rounded up to two significant
    // figures: percentiles stay within a step, and the good and poor
    // thresholds (all multiples of a step) still sort every sample exactly.
    const Vital = struct { metric: []const u8, path: []const u8, value: i64, samples: i64 };
    var vitals: std.ArrayList(Vital) = .empty;
    var vital_rows = try db.prepare(arena, comptime "WITH s AS MATERIALIZED (SELECT pv.path,ps.lcp_ms lcp,ps.inp_ms inp,ps.cls_milli cls,ps.ttfb_ms ttfb,ps.fcp_ms fcp FROM temp.rollup_day pv JOIN page_summaries ps ON ps.site_id=pv.site_id AND ps.page_id=pv.page_id) " ++
        vitalSelect("lcp") ++ " UNION ALL " ++ vitalSelect("inp") ++ " UNION ALL " ++ vitalSelect("cls") ++ " UNION ALL " ++ vitalSelect("ttfb") ++ " UNION ALL " ++ vitalSelect("fcp"));
    defer vital_rows.deinit();
    while (try vital_rows.step() == .row) try vitals.append(arena, .{
        .metric = try arena.dupe(u8, vital_rows.columnText(0)),
        .path = try arena.dupe(u8, vital_rows.columnText(1)),
        .value = vital_rows.columnInt(2),
        .samples = vital_rows.columnInt(3),
    });
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
    try write.run(arena, "DELETE FROM vitals_daily WHERE site_id=? AND day=?", .{ site_id, &day });
    var vital_insert = try write.prepare(arena, "INSERT INTO vitals_daily(site_id,day,metric,path,value,samples) VALUES(?,?,?,?,?,?)");
    defer vital_insert.deinit();
    for (vitals.items) |vital| {
        try vital_insert.reset();
        try vital_insert.bindAll(.{ site_id, &day, vital.metric, vital.path, vital.value, vital.samples });
        _ = try vital_insert.step();
    }
    try write.run(arena, "INSERT INTO rollup_days(site_id,day,until_ms) VALUES(?,?,?) ON CONFLICT DO UPDATE SET until_ms=excluded.until_ms", .{ site_id, &day, until_ms });
    try write.exec("COMMIT");
}

fn vitalSelect(comptime metric: []const u8) []const u8 {
    const v = metric;
    return "SELECT '" ++ metric ++ "',path,CASE WHEN " ++ v ++ "<100 THEN " ++ v ++ " WHEN " ++ v ++ "<1000 THEN (" ++ v ++ "+9)/10*10 WHEN " ++ v ++ "<10000 THEN (" ++ v ++ "+99)/100*100 WHEN " ++ v ++
        "<100000 THEN (" ++ v ++ "+999)/1000*1000 ELSE (" ++ v ++ "+9999)/10000*10000 END r,count(*) FROM s WHERE " ++ v ++ " IS NOT NULL GROUP BY path,r";
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
