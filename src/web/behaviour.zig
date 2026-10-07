//! Sessions & replays, the replay player, and JavaScript errors.
const std = @import("std");
const analyze = @import("analyze.zig");
const ctx_mod = @import("ctx.zig");
const customers = @import("customers.zig");
const data = @import("data.zig");
const db_mod = @import("../db.zig");
const html = @import("html.zig");
const journeys = @import("journeys.zig");
const layout = @import("layout.zig");
const ui = @import("ui.zig");
const overview = @import("overview.zig");
const replay = @import("../replay.zig");
const assets = @import("../assets.zig");

const Ctx = ctx_mod.Ctx;
const esc = html.esc;
const icon = layout.icon;
const render = html.render;

/// "user 7f3a" for identified people, "Visitor 7f3a" for consented visitors.
pub fn personLabel(arena: std.mem.Allocator, visitor_id: []const u8, user_hash: []const u8) ![]const u8 {
    if (user_hash.len >= 4) return std.fmt.allocPrint(arena, "user {s}", .{user_hash[0..4]});
    if (visitor_id.len >= 4) return std.fmt.allocPrint(arena, "Visitor {s}", .{visitor_id[0..4]});
    return "Lite visitor";
}

/// m:ss from milliseconds.
pub const Offset = struct {
    ms: i64,

    pub fn format(self: Offset, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const seconds = @divFloor(@max(self.ms, 0), 1000);
        return w.print("{d}:{d:0>2}", .{ @divFloor(seconds, 60), @as(u64, @intCast(@mod(seconds, 60))) });
    }
};

// ---------------------------------------------------------------- Sessions & replays

const Signal = enum { recorded, rage, errors, goal };

pub fn sessions(ctx: *Ctx, site: data.Site) !void {
    const arena = ctx.arena;
    const view = try analyze.start(ctx, site, .sessions, "Sessions & replays");
    const path = try std.fmt.allocPrint(arena, "/{s}/sessions", .{site.slug});
    if (!site.linked()) {
        try layout.head(ctx, .{ .title = "Sessions & replays", .subtitle = "Follow single visits from landing to exit" });
        try journeys.sessionModeNotice(ctx, site, "Sessions and replays");
        return layout.end(ctx);
    }
    const tab = ctx.param("tab") orelse "sessions";
    // Without filters the total comes from the daily summaries and each
    // signal from its own small table; filters need the sessions themselves.
    var counts_sql = data.Sql.init(arena);
    if (view.filters.len == 0) {
        try counts_sql.add("SELECT ");
        try counts_sql.int((try data.totals(arena, ctx.db, view, view.range.start_ms, view.range.end_ms)).sessions);
        try counts_sql.add(",(SELECT count(*) FROM rp.replays r WHERE r.site_id=");
        try counts_sql.int(site.id);
        try counts_sql.add(" AND r.started_at_ms>=");
        try counts_sql.int(view.range.start_ms);
        try counts_sql.add(" AND r.started_at_ms<");
        try counts_sql.int(view.range.end_ms);
        try counts_sql.add(")");
        for ([_]Signal{ .rage, .errors, .goal }) |signal| {
            try counts_sql.add(",(SELECT count(DISTINCT session_id) FROM ");
            try signalSet(&counts_sql, view, signal);
            try counts_sql.add(")");
        }
    } else {
        try sessionsCte(&counts_sql, view);
        try counts_sql.add(" SELECT count(*)");
        for ([_]Signal{ .recorded, .rage, .errors, .goal }) |signal| {
            try counts_sql.add(",coalesce(sum(s.sid IN ");
            try signalSet(&counts_sql, view, signal);
            try counts_sql.add("),0)");
        }
        try counts_sql.add(" FROM s");
    }
    var counts = try counts_sql.prepare(ctx.db);
    defer counts.deinit();
    _ = try counts.step();
    const total = counts.columnInt(0);
    const online = try data.online(arena, ctx.db, site.id, ctx.now());
    const subtitle = if (site.mode == .full)
        try std.fmt.allocPrint(arena, "{f} sessions · {f} recorded · {f}", .{ html.int(total), html.int(counts.columnInt(1)), view.range })
    else
        try std.fmt.allocPrint(arena, "{f} sessions · {f}", .{ html.int(total), view.range });
    try layout.head(ctx, .{ .title = "Sessions & replays", .subtitle = subtitle, .view = view, .path = path });
    try ui.tabs(ctx.w(), ctx.arena, view, path, "tab", &.{ .{ "sessions", "Sessions" }, .{ "paths", "Paths" }, .{ "live", try std.fmt.allocPrint(arena, "Live · {d}", .{online}) } }, tab);
    if (std.mem.eql(u8, tab, "paths")) {
        try journeys.pathsTab(ctx, view, path);
    } else if (std.mem.eql(u8, tab, "live")) {
        try journeys.liveTab(ctx, view);
    } else {
        const signal = std.meta.stringToEnum(Signal, ctx.param("signal") orelse "");
        const w = ctx.w();
        try w.writeAll("<div class=\"chips chips-bar\">");
        const chips = [_]struct { Signal, []const u8, usize, []const u8 }{
            .{ .recorded, "Recorded", 1, "var(--brand)" },
            .{ .rage, "Rage clicks", 2, "var(--brand)" },
            .{ .errors, "JS errors", 3, "var(--error)" },
            .{ .goal, "Reached a goal", 4, "var(--success)" },
        };
        for (chips) |chip| {
            if (chip[0] == .recorded and site.mode != .full) continue;
            const active = signal != null and signal.? == chip[0];
            try render(w, "<a class=\"chip{!plain}\" href=\"{href}\"><span class=\"dot-mark\" style=\"background:{color}\"></span>{label} · {count}</a>", .{
                .plain = if (active) "" else " chip-plain", .href = try view.href(arena, path, &.{.{ "signal", if (active) "" else @tagName(chip[0]) }}), .color = chip[3], .label = chip[1], .count = html.int(counts.columnInt(chip[2])),
            });
        }
        if (ctx.param("event")) |name| try render(w, "<span class=\"chip\">Has event {name}<a href=\"{href}\" aria-label=\"Remove\">×</a></span>", .{ .name = name, .href = try view.href(arena, path, &.{}) });
        if (ctx.param("error")) |fingerprint| try render(w, "<span class=\"chip\">Hit error {fingerprint}<a href=\"{href}\" aria-label=\"Remove\">×</a></span>", .{ .fingerprint = fingerprint[0..@min(8, fingerprint.len)], .href = try view.href(arena, path, &.{}) });
        try w.writeAll("</div>");
        try sessionTable(ctx, view, signal);
    }
    return layout.end(ctx);
}

fn sessionsCte(sql: *data.Sql, view: data.View) !void {
    try sql.add("WITH s AS (SELECT pv.session_id sid,min(pv.received_at_ms) started,max(pv.received_at_ms) ended,count(*) pages,max(pv.visitor_id) visitor FROM page_views pv WHERE ");
    try sql.pageViews(view, view.range.start_ms, view.range.end_ms);
    try sql.add(" AND pv.session_id IS NOT NULL GROUP BY pv.session_id)");
}

/// The sessions in the period that have a signal, computed once as a set.
fn signalSet(sql: *data.Sql, view: data.View, signal: Signal) !void {
    const id = view.site.id;
    switch (signal) {
        .recorded => {
            try sql.add("(SELECT r.session_id FROM rp.replays r WHERE r.site_id=");
            try sql.int(id);
            try sql.add(")");
            return;
        },
        .rage => {
            try sql.add("(SELECT e.session_id FROM events e WHERE e.site_id=");
            try sql.int(id);
            try sql.add(" AND e.name='rage_click'");
        },
        .errors => {
            try sql.add("(SELECT e.session_id FROM errors e WHERE e.site_id=");
            try sql.int(id);
        },
        .goal => {
            try sql.add("(SELECT e.session_id FROM events e WHERE e.site_id=");
            try sql.int(id);
            try sql.add(" AND e.name IN (SELECT g.match_value FROM goals g WHERE g.site_id=");
            try sql.int(id);
            try sql.add(" AND g.kind='event')");
        },
    }
    try sql.add(" AND e.received_at_ms>=");
    try sql.int(view.range.start_ms);
    try sql.add(" AND e.received_at_ms<");
    try sql.int(view.range.end_ms);
    try sql.add(" AND e.session_id IS NOT NULL)");
}

const SessionRow = struct {
    sid: []const u8,
    started: i64,
    ended: i64,
    pages: i64,
    visitor: []const u8,
    journey: []const u8,
    rage: i64,
    errors: i64,
    goal: []const u8,
    purchase: ?i64,
    currency: []const u8,
    replay_ms: ?i64,
    user_hash: []const u8,
};

/// Sessions that may be among the last 100 started. A signal, event or error
/// narrows them to its own (small) set; otherwise they are the sessions of the
/// `window` most recent page views.
fn sessionCandidates(ctx: *Ctx, sql: *data.Sql, view: data.View, signal: ?Signal, window: i64) !bool {
    const id = view.site.id;
    var narrowed = false;
    if (signal) |value| {
        try sql.add("SELECT session_id FROM ");
        try signalSet(sql, view, value);
        narrowed = true;
    }
    if (ctx.param("event")) |name| {
        try sql.add(if (narrowed) " INTERSECT " else "");
        try sql.add("SELECT e.session_id FROM events e WHERE e.site_id=");
        try sql.int(id);
        try sql.add(" AND e.name=");
        try sql.str(name);
        try sql.add(" AND e.session_id IS NOT NULL");
        narrowed = true;
    }
    if (ctx.param("error")) |fingerprint| {
        try sql.add(if (narrowed) " INTERSECT " else "");
        try sql.add("SELECT x.session_id FROM errors x WHERE x.site_id=");
        try sql.int(id);
        try sql.add(" AND x.fingerprint=");
        try sql.str(fingerprint);
        try sql.add(" AND x.session_id IS NOT NULL");
        narrowed = true;
    }
    if (narrowed) return true;
    try sql.add("SELECT DISTINCT session_id FROM (SELECT pv.session_id FROM page_views pv WHERE ");
    try sql.pageViews(view, view.range.start_ms, view.range.end_ms);
    try sql.add(" AND pv.session_id IS NOT NULL ORDER BY pv.received_at_ms DESC LIMIT ");
    try sql.int(window);
    try sql.add(")");
    return false;
}

fn sessionTable(ctx: *Ctx, view: data.View, signal: ?Signal) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    const site = view.site;
    const id = site.id;
    // The 100 sessions that started last, without summarising every session
    // of the period: candidates first, then their pages through the session
    // index. Candidates from recent page views are exact once the 100th
    // session started after the oldest page view looked at; until then the
    // window grows.
    var rows: std.ArrayList(SessionRow) = .empty;
    var window: i64 = 4000;
    while (true) {
        rows.clearRetainingCapacity();
        var sql = data.Sql.init(arena);
        try sql.add("WITH c(sid) AS MATERIALIZED (");
        const narrowed = try sessionCandidates(ctx, &sql, view, signal, window);
        try sql.add("),s AS (SELECT pv.session_id sid,min(pv.received_at_ms) started,max(pv.received_at_ms) ended,count(*) pages,max(pv.visitor_id) visitor FROM c CROSS JOIN page_views pv ON pv.site_id=");
        try sql.int(id);
        try sql.add(" AND pv.session_id=c.sid WHERE ");
        try sql.pageViews(view, view.range.start_ms, view.range.end_ms);
        try sql.add(" AND pv.session_id IS NOT NULL GROUP BY pv.session_id),t AS MATERIALIZED (SELECT * FROM s ORDER BY s.started DESC LIMIT 100) SELECT t.sid,t.started,max(t.ended,coalesce((SELECT max(e.received_at_ms) FROM events e WHERE e.site_id=");
        try sql.int(id);
        try sql.add(" AND e.session_id=t.sid),0)),t.pages,coalesce(t.visitor,''),(SELECT group_concat(p,' → ') FROM (SELECT x.path p FROM page_views x WHERE x.site_id=");
        try sql.int(id);
        try sql.add(" AND x.session_id=t.sid ORDER BY x.occurred_at_ms LIMIT 3)),(SELECT count(*) FROM events e WHERE e.site_id=");
        try sql.int(id);
        try sql.add(" AND e.session_id=t.sid AND e.name='rage_click'),(SELECT count(*) FROM errors x WHERE x.site_id=");
        try sql.int(id);
        try sql.add(" AND x.session_id=t.sid),(SELECT g.name FROM goals g JOIN events e ON e.site_id=g.site_id AND e.name=g.match_value AND g.kind='event' WHERE g.site_id=");
        try sql.int(id);
        try sql.add(" AND e.session_id=t.sid LIMIT 1),(SELECT sum(o.v) FROM (SELECT max(e.value_minor) v FROM events e WHERE e.site_id=");
        try sql.int(id);
        try sql.add(" AND e.session_id=t.sid AND e.name IN " ++ customers.purchase_names ++ " GROUP BY coalesce(e.order_id,e.event_id)) o),(SELECT max(e.currency) FROM events e WHERE e.site_id=");
        try sql.int(id);
        try sql.add(" AND e.session_id=t.sid AND e.name IN " ++ customers.purchase_names ++ "),(SELECT r.last_at_ms-r.started_at_ms FROM rp.replays r WHERE r.site_id=");
        try sql.int(id);
        try sql.add(" AND r.session_id=t.sid),coalesce((SELECT v.user_hash FROM visitors v WHERE v.site_id=");
        try sql.int(id);
        try sql.add(" AND v.visitor_id=t.visitor),''),(SELECT pv.received_at_ms FROM page_views pv WHERE ");
        try sql.pageViews(view, view.range.start_ms, view.range.end_ms);
        try sql.add(" AND pv.session_id IS NOT NULL ORDER BY pv.received_at_ms DESC LIMIT 1 OFFSET ");
        try sql.int(window - 1);
        try sql.add(") FROM t ORDER BY t.started DESC");
        var statement = try sql.prepare(ctx.db);
        defer statement.deinit();
        var oldest: ?i64 = null;
        while (try statement.step() == .row) {
            try rows.append(arena, .{
                .sid = try arena.dupe(u8, statement.columnText(0)),
                .started = statement.columnInt(1),
                .ended = statement.columnInt(2),
                .pages = statement.columnInt(3),
                .visitor = try arena.dupe(u8, statement.columnText(4)),
                .journey = try arena.dupe(u8, statement.columnText(5)),
                .rage = statement.columnInt(6),
                .errors = statement.columnInt(7),
                .goal = try arena.dupe(u8, statement.columnText(8)),
                .purchase = if (statement.columnType(9) == db_mod.sqlite.SQLITE_NULL) null else statement.columnInt(9),
                .currency = try arena.dupe(u8, statement.columnText(10)),
                .replay_ms = if (statement.columnType(11) == db_mod.sqlite.SQLITE_NULL) null else statement.columnInt(11),
                .user_hash = try arena.dupe(u8, statement.columnText(12)),
            });
            if (statement.columnType(13) != db_mod.sqlite.SQLITE_NULL) oldest = statement.columnInt(13);
        }
        // Exact when every page view of the period was looked at, or when
        // the 100th session started after the oldest one that was.
        if (narrowed or oldest == null or (rows.items.len == 100 and rows.items[99].started >= oldest.?)) break;
        window *= 4;
    }
    try w.writeAll("<section class=\"card card-flush\"><div class=\"table-wrap\"><table class=\"table\"><thead><tr><th>When</th><th class=\"hide-m\">Visitor</th><th>Journey</th><th class=\"r hide-m\">Pages</th><th class=\"r hide-m\">Length</th><th class=\"hide-m\">Signals</th>");
    if (site.mode == .full) try w.writeAll("<th>Replay</th>");
    try w.writeAll("</tr></thead><tbody>");
    for (rows.items) |row| {
        const href = try std.fmt.allocPrint(arena, "/{s}/replays/{s}", .{ site.slug, row.sid });
        const label = if (site.mode == .full) try personLabel(arena, row.visitor, row.user_hash) else try std.fmt.allocPrint(arena, "Session {s}", .{row.sid[0..4]});
        try render(w, "<tr data-href=\"{href}\"><td class=\"secondary\">{when}</td><td class=\"hide-m {class}\">{visitor}</td><td class=\"strong journey\"><a href=\"{href}\">{journey}</a></td><td class=\"r hide-m\">{pages}</td><td class=\"r hide-m\">{length}</td><td class=\"hide-m\"><span class=\"row gap-6\">", .{
            .href = href, .when = data.clock(row.started, ctx.now()), .class = if (row.user_hash.len != 0) "strong" else "secondary", .visitor = label, .journey = row.journey, .pages = row.pages, .length = html.duration(row.ended - row.started),
        });
        if (row.rage > 0) try w.writeAll("<span class=\"pill pill-brand\">Rage click</span>");
        if (row.errors > 0) try w.writeAll("<span class=\"pill pill-bad\">JS error</span>");
        if (row.purchase) |amount| {
            try w.print("<span class=\"pill pill-good\">Purchased {f}</span>", .{html.money(amount, row.currency)});
        } else if (row.goal.len != 0) try w.print("<span class=\"pill pill-good\">Goal: {f}</span>", .{esc(row.goal)});
        try w.writeAll("</span></td>");
        if (site.mode == .full) {
            if (row.replay_ms) |length| {
                try w.print("<td><a class=\"btn btn-replay\" href=\"{f}\">", .{esc(href)});
                try icon(w, "play");
                try w.print("{f}</a></td>", .{Offset{ .ms = length }});
            } else try w.print("<td class=\"hint\">{s}</td>", .{if (row.visitor.len == 0) "Lite — no replay" else "Not recorded"});
        }
        try w.writeAll("</tr>");
    }
    try w.writeAll("</tbody></table></div>");
    if (rows.items.len == 0) try ui.empty(w, "No sessions match", "Sessions appear as soon as visitors arrive. Try another signal or a longer period.", "");
    try w.writeAll("<div class=\"card-foot\"><span>Most recent 100 sessions</span>");
    if (site.mode == .full) {
        if (site.recording()) {
            try w.print("<span>Recording {d}% of consented sessions{s} · text and inputs masked</span>", .{ site.replay_percent, if (site.replay_triggers) ", plus every session with a rage click, error or goal" else "" });
        } else try w.print("<a class=\"link\" href=\"/settings/recording?site={s}\">Turn on session replay →</a>", .{site.slug});
    } else try w.writeAll("<span>Session IDs live in one browser tab and are never linked across visits</span>");
    try w.writeAll("</div></section>");
}

// ---------------------------------------------------------------- Replay player

pub const Moment = struct { at: i64, kind: []const u8, title: []const u8, detail: []const u8 };

/// Everything that happened in a session, in order: pages, events (rage
/// clicks and payments marked) and errors. Never anything typed.
pub fn momentsOf(ctx: *Ctx, site_id: i64, session_id: []const u8) ![]Moment {
    return ctx.db.all(ctx.arena, Moment,
        \\SELECT at,kind,title,detail FROM (
        \\ SELECT occurred_at_ms at,'page' kind,path title,'' detail FROM page_views WHERE site_id=?1 AND session_id=?2
        \\ UNION ALL SELECT occurred_at_ms,CASE WHEN name='rage_click' THEN 'rage' WHEN value_minor IS NOT NULL THEN 'money' ELSE 'event' END,name,
        \\   coalesce(json_extract(properties_json,'$.element'),json_extract(properties_json,'$.action'),json_extract(properties_json,'$.host'),json_extract(properties_json,'$.file'),'') ||
        \\   CASE WHEN value_minor IS NOT NULL THEN ' · ' || currency || ' ' || printf('%.2f',value_minor/100.0) ELSE '' END
        \\   FROM events WHERE site_id=?1 AND session_id=?2
        \\ UNION ALL SELECT occurred_at_ms,'error',message,coalesce(file,'') || coalesce(':' || line,'') FROM errors WHERE site_id=?1 AND session_id=?2
        \\) ORDER BY at LIMIT 300
    , .{ site_id, session_id });
}

/// When the replay's clock starts: the recording, else the first moment.
pub fn startOf(ctx: *Ctx, site_id: i64, session_id: []const u8, moments: []const Moment) !i64 {
    const recorded = try ctx.db.scalar(ctx.arena, ?i64, "SELECT started_at_ms FROM rp.replays WHERE site_id=? AND session_id=?", .{ site_id, session_id });
    return recorded orelse if (moments.len != 0) moments[0].at else 0;
}

pub fn player(ctx: *Ctx, site: data.Site, session_id: []const u8) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    const view = try data.View.parse(arena, site, ctx.query, ctx.now());
    var meta = try ctx.db.prepare(arena,
        \\SELECT min(received_at_ms),max(received_at_ms),count(*),max(browser),max(operating_system),max(device),max(country),max(city),
        \\ coalesce(max(visitor_id),''),(SELECT coalesce(nullif(utm_source,''),nullif(referrer_host,''),'direct') FROM page_views x WHERE x.site_id=?1 AND x.session_id=?2 ORDER BY occurred_at_ms LIMIT 1)
        \\FROM page_views WHERE site_id=?1 AND session_id=?2
    );
    defer meta.deinit();
    try meta.bindInt(1, site.id);
    try meta.bindText(2, session_id);
    if (try meta.step() != .row or meta.columnInt(2) == 0) return layout.message(ctx, .not_found, "Session not found", "It may be older than the retention period, or the visitor asked to be forgotten.");
    const visitor = try arena.dupe(u8, meta.columnText(8));
    const user_hash = if (visitor.len != 0) (try scalarText(ctx, "SELECT coalesce(user_hash,'') FROM visitors WHERE site_id=? AND visitor_id=?", site.id, visitor)) else "";
    const label = try personLabel(arena, visitor, user_hash);
    var recording = try ctx.db.prepare(arena, "SELECT started_at_ms,last_at_ms,bytes FROM rp.replays WHERE site_id=? AND session_id=?");
    defer recording.deinit();
    try recording.bindInt(1, site.id);
    try recording.bindText(2, session_id);
    const recorded = try recording.step() == .row;
    const started = if (recorded) recording.columnInt(0) else meta.columnInt(0);
    const length = if (recorded) recording.columnInt(1) - recording.columnInt(0) else meta.columnInt(1) - meta.columnInt(0);

    // Everything that happened, positioned on the replay's clock.
    const moments = try momentsOf(ctx, site.id, session_id);
    var errors_count: usize = 0;
    var first_error: ?Moment = null;
    for (moments) |moment| if (std.mem.eql(u8, moment.kind, "error")) {
        errors_count += 1;
        if (first_error == null) first_error = moment;
    };

    const title = if (first_error) |value| try std.fmt.allocPrint(arena, "{s} · {s}", .{ label, value.title[0..@min(value.title.len, 48)] }) else label;
    try layout.begin(ctx, try @import("app.zig").shell(ctx, site, .sessions, "Replay", view));
    const place = if (meta.columnText(7).len != 0) try std.fmt.allocPrint(arena, " · {s}, {s}", .{ meta.columnText(7), meta.columnText(6) }) else if (meta.columnText(6).len != 0) try std.fmt.allocPrint(arena, " · {s}", .{meta.columnText(6)}) else "";
    const subtitle = try std.fmt.allocPrint(arena, "{f} · {f} · {d} page{s} · {s} on {s}{s} · via {s}", .{
        data.clock(started, ctx.now()), html.duration(length), meta.columnInt(2), if (meta.columnInt(2) == 1) "" else "s", capitalized(arena, meta.columnText(3)), capitalized(arena, meta.columnText(5)), place, try overview.sourceLabel(arena, meta.columnText(9)),
    });
    var extra: std.Io.Writer.Allocating = .init(arena);
    if (visitor.len != 0) try extra.writer.print("<a class=\"btn\" href=\"/{s}/people/{s}\">Open person →</a>", .{ site.slug, visitor });
    try extra.writer.print("<button class=\"btn\" type=\"button\" data-copy=\"{f}/{s}/replays/{s}\">Copy link</button>", .{ esc(try ctx.publicOrigin()), site.slug, session_id });
    try layout.head(ctx, .{ .title = title, .subtitle = subtitle, .extra = extra.written() });

    try w.writeAll("<div class=\"grid split-player\"><div class=\"stack\">");
    if (recorded) {
        try render(w, "<link rel=\"stylesheet\" href=\"{css}\"><section class=\"player\" data-replay=\"/{slug}/replays/{session}/events\" data-player-src=\"{js}\"><div class=\"player-stage\"><span class=\"player-badge\">Text and inputs masked</span><div class=\"player-frame\" data-stage></div><p class=\"player-status\" data-status>Loading the recording…</p></div>", .{ .css = assets.path("player.css"), .slug = site.slug, .session = session_id, .js = assets.path("player.js") });
        try w.writeAll("<div class=\"player-controls\"><button class=\"btn btn-icon player-play\" type=\"button\" data-play aria-label=\"Play\">");
        try icon(w, "play");
        try w.writeAll("</button><button class=\"btn btn-quiet btn-icon\" type=\"button\" data-restart aria-label=\"Back to start\">");
        try icon(w, "skip-back");
        try w.print("</button><span class=\"player-time\" data-time>0:00 / {f}</span><div class=\"player-track\" data-track><div class=\"player-progress\" data-progress></div>", .{Offset{ .ms = length }});
        for (moments) |moment| {
            if (std.mem.eql(u8, moment.kind, "event")) continue;
            const position = if (length <= 0) 0 else std.math.clamp(@as(f64, @floatFromInt(moment.at - started)) / @as(f64, @floatFromInt(length)) * 100, 0, 100);
            try render(w, "<span class=\"player-mark {kind}\" style=\"left:{position:.2}%\" title=\"{title}\"></span>", .{ .kind = moment.kind, .position = position, .title = moment.title });
        }
        try w.writeAll("</div><button class=\"btn btn-quiet\" type=\"button\" data-speed>1×</button><label class=\"check t-13\"><input type=\"checkbox\" data-skip checked>Skip idle</label></div></section>");
    } else {
        try w.writeAll("<section class=\"card\">");
        try ui.empty(w, "This session wasn’t recorded", if (site.recording()) "It wasn’t sampled and nothing triggered a recording. The timeline still shows everything that happened." else "Session replay is off for this website. The timeline still shows everything that happened.", if (site.recording() or !ctx.can(.admin)) "" else try std.fmt.allocPrint(arena, "<a class=\"btn btn-primary\" href=\"/settings/recording?site={s}\">Turn on session replay</a>", .{site.slug}));
        try w.writeAll("</section>");
    }
    try render(w, "<section class=\"card\" data-summary=\"/{slug}/replays/{session}/summary\"><div class=\"card-head\"><h2>What happened?</h2><button class=\"btn\" type=\"button\" data-summarize>Summarise</button></div><div class=\"timeline\" data-summary-out hidden></div></section>", .{ .slug = site.slug, .session = session_id });
    if (first_error) |value| {
        try render(w, "<section class=\"card callout-card\"><div class=\"card-head\"><h2>What went wrong</h2><span class=\"meta\">From the error log — never from what was typed</span></div><p class=\"t-14 lh-22\"><strong class=\"bad\">{title}</strong> at {at}{in}{detail}. {count} error{plural} in this session.</p><div class=\"row mt-12\"><a class=\"btn btn-primary\" href=\"/{slug}/errors?error={fingerprint}\">Open the error →</a></div></section>", .{
            .title = value.title, .at = Offset{ .ms = value.at - started }, .in = if (value.detail.len != 0) " in " else "", .detail = value.detail, .count = errors_count, .plural = if (errors_count == 1) "" else "s", .slug = site.slug, .fingerprint = try fingerprintOf(ctx, site, session_id),
        });
    }
    try render(w, "</div><aside class=\"card card-flush player-side\"><div class=\"card-head side-head\"><h2>Timeline</h2><span class=\"meta\">{count} moments</span></div><div class=\"timeline player-timeline\">", .{ .count = moments.len });
    for (moments) |moment| {
        const offset = moment.at - started;
        const dot = if (std.mem.eql(u8, moment.kind, "error")) "bad" else if (std.mem.eql(u8, moment.kind, "rage")) "brand" else if (std.mem.eql(u8, moment.kind, "money")) "good" else if (std.mem.eql(u8, moment.kind, "page")) "" else "blue";
        const heading = if (std.mem.eql(u8, moment.kind, "page")) try std.fmt.allocPrint(arena, "Opened {s}", .{moment.title}) else if (std.mem.eql(u8, moment.kind, "rage")) "Rage click" else moment.title;
        try render(w, "<button class=\"tl-row tl-seek{!alert}\" type=\"button\" data-seek=\"{offset}\"><span class=\"tl-time\">{time}</span><span class=\"tl-dot {dot}\"></span><div><strong>{heading}</strong><small>{detail}</small></div></button>", .{
            .alert = if (std.mem.eql(u8, moment.kind, "error")) " tl-alert" else "", .offset = @max(offset, 0), .time = Offset{ .ms = offset }, .dot = dot, .heading = heading, .detail = moment.detail,
        });
    }
    try w.writeAll("</div><div class=\"card-foot\"><span>Values typed into forms are never recorded</span></div></aside></div>");
    return layout.end(ctx);
}

fn fingerprintOf(ctx: *Ctx, site: data.Site, session_id: []const u8) ![]const u8 {
    return scalarText(ctx, "SELECT fingerprint FROM errors WHERE site_id=? AND session_id=? ORDER BY occurred_at_ms LIMIT 1", site.id, session_id);
}

fn scalarText(ctx: *Ctx, sql: []const u8, site_id: i64, value: []const u8) ![]const u8 {
    var statement = try ctx.db.prepare(ctx.arena, sql);
    defer statement.deinit();
    try statement.bindInt(1, site_id);
    try statement.bindText(2, value);
    if (try statement.step() != .row) return "";
    return ctx.arena.dupe(u8, statement.columnText(0));
}

fn capitalized(arena: std.mem.Allocator, value: []const u8) []const u8 {
    return data.prettyLabel(arena, value);
}

/// The recording: every chunk as a length-prefixed gzip member.
pub fn replayEvents(ctx: *Ctx, site: data.Site, session_id: []const u8) !void {
    domain_validate: {
        @import("../domain.zig").validateUuid(session_id) catch break :domain_validate;
        const count = try replay.writeChunks(ctx.arena, ctx.db, site.id, session_id, ctx.w());
        if (count == 0) return ctx.text(.not_found, "not recorded\n");
        try ctx.header("cache-control", "private, max-age=300");
        return ctx.finish("application/octet-stream");
    }
    return ctx.text(.not_found, "not recorded\n");
}

// ---------------------------------------------------------------- Errors

pub fn errorScope(sql: *data.Sql, view: data.View, start: i64, end: i64) !void {
    try sql.add("x.internal=0 AND x.site_id=");
    try sql.int(view.site.id);
    try sql.add(" AND x.received_at_ms>=");
    try sql.int(start);
    try sql.add(" AND x.received_at_ms<");
    try sql.int(end);
    if (view.filters.len != 0) {
        try sql.add(" AND EXISTS(SELECT 1 FROM page_views pv WHERE pv.site_id=x.site_id AND pv.page_id=x.page_id");
        try sql.filters(view.filters, view.any);
        try sql.add(")");
    }
}

/// New in the period, quiet for a week (probably fixed), or still happening.
fn errorStatus(arena: std.mem.Allocator, row: ErrorRow, range: data.Range, now_ms: i64, long: bool) ![]const u8 {
    if (row.first >= range.start_ms) {
        if (!long) return "New";
        return if (row.release.len != 0) try std.fmt.allocPrint(arena, "New since release {s}", .{row.release}) else "New this period";
    }
    const quiet_days = @divFloor(now_ms - row.last, data.day_ms);
    if (quiet_days >= 7) return try std.fmt.allocPrint(arena, "Not seen for {d} days", .{quiet_days});
    return "Ongoing";
}

const ErrorRow = struct { fingerprint: []const u8, message: []const u8, file: []const u8, line: i64, path: []const u8, count: i64, visits: i64, first: i64, last: i64, browsers: []const u8, release: []const u8 };

pub fn errors(ctx: *Ctx, site: data.Site) !void {
    const arena = ctx.arena;
    const view = try analyze.start(ctx, site, .errors, "Errors");
    const w = ctx.w();
    const path = try std.fmt.allocPrint(arena, "/{s}/errors", .{site.slug});
    const range = view.range;
    try layout.head(ctx, .{ .title = "Errors", .subtitle = try std.fmt.allocPrint(arena, "JavaScript errors visitors ran into, grouped · {f}", .{range}), .view = view, .path = path });

    // Visits: sessions where pages are linked, page views otherwise.
    const unit = if (site.linked()) "coalesce(x.session_id,x.page_id)" else "x.page_id";
    var rows_sql = data.Sql.init(arena);
    try rows_sql.add("SELECT x.fingerprint,max(x.message),coalesce(max(x.file),''),coalesce(max(x.line),0),(SELECT y.path FROM errors y WHERE y.site_id=x.site_id AND y.fingerprint=x.fingerprint GROUP BY y.path ORDER BY count(*) DESC LIMIT 1),count(*),count(DISTINCT ");
    try rows_sql.add(unit);
    try rows_sql.add("),(SELECT min(y.received_at_ms) FROM errors y WHERE y.site_id=x.site_id AND y.fingerprint=x.fingerprint),max(x.received_at_ms),group_concat(DISTINCT x.browser),coalesce((SELECT y.release_id FROM errors y WHERE y.site_id=x.site_id AND y.fingerprint=x.fingerprint ORDER BY y.received_at_ms LIMIT 1),'') FROM errors x WHERE ");
    try errorScope(&rows_sql, view, range.start_ms, range.end_ms);
    try rows_sql.add(" GROUP BY x.fingerprint ORDER BY 7 DESC,6 DESC LIMIT 100");
    var statement = try rows_sql.prepare(ctx.db);
    defer statement.deinit();
    var rows: std.ArrayList(ErrorRow) = .empty;
    while (try statement.step() == .row) try rows.append(arena, .{
        .fingerprint = try arena.dupe(u8, statement.columnText(0)),
        .message = try arena.dupe(u8, statement.columnText(1)),
        .file = try arena.dupe(u8, statement.columnText(2)),
        .line = statement.columnInt(3),
        .path = try arena.dupe(u8, statement.columnText(4)),
        .count = statement.columnInt(5),
        .visits = statement.columnInt(6),
        .first = statement.columnInt(7),
        .last = statement.columnInt(8),
        .browsers = try arena.dupe(u8, statement.columnText(9)),
        .release = try arena.dupe(u8, statement.columnText(10)),
    });

    // Headline: share of visits with an error, distinct errors, new ones.
    const visits = try data.visits(arena, ctx.db, view, range.start_ms, range.end_ms);
    var hit_sql = data.Sql.init(arena);
    try hit_sql.add("SELECT count(DISTINCT ");
    try hit_sql.add(unit);
    try hit_sql.add(") FROM errors x WHERE ");
    try errorScope(&hit_sql, view, range.start_ms, range.end_ms);
    var hit = try hit_sql.prepare(ctx.db);
    defer hit.deinit();
    _ = try hit.step();
    var fresh: usize = 0;
    for (rows.items) |row| {
        if (row.first >= range.start_ms) fresh += 1;
    }
    try w.writeAll("<div class=\"grid grid-3 mb-16\">");
    try ui.stat(w, if (site.linked()) "Sessions with an error" else "Page views with an error", try std.fmt.allocPrint(arena, "{f}", .{html.share(hit.columnInt(0), visits)}), try std.fmt.allocPrint(arena, "{f} of {f}", .{ html.int(hit.columnInt(0)), html.int(visits) }));
    try ui.stat(w, "Distinct errors", try std.fmt.allocPrint(arena, "{d}", .{rows.items.len}), try std.fmt.allocPrint(arena, "{d} new this period", .{fresh}));
    try render(w, "<div class=\"card\"><div class=\"hint ink-2\">Most affected page</div><div class=\"metric-value metric-value-path\">{path}</div><div class=\"hint\">by visits with an error</div></div></div>", .{ .path = if (rows.items.len != 0) rows.items[0].path else "—" });

    if (rows.items.len == 0) {
        try w.writeAll("<div class=\"card\">");
        try ui.empty(w, "No errors in this period", "The tracker reports uncaught JavaScript errors and rejected promises — message, file and line only, never what visitors typed.", "");
        try w.writeAll("</div>");
        return layout.end(ctx);
    }
    const selected_key = ctx.param("error") orelse rows.items[0].fingerprint;
    var selected: ErrorRow = rows.items[0];
    for (rows.items) |row| if (std.mem.eql(u8, row.fingerprint, selected_key)) {
        selected = row;
    };
    try w.writeAll("<div class=\"grid split-detail\"><section class=\"card card-flush\"><div class=\"table-wrap\"><table class=\"table\"><thead><tr><th>Error</th><th class=\"r\">");
    try w.writeAll(if (site.linked()) "Sessions" else "Views");
    try w.writeAll("</th><th class=\"hide-m\">Trend</th><th class=\"hide-m\">Status</th></tr></thead><tbody>");
    for (rows.items) |row| {
        const href = try view.href(arena, path, &.{.{ "error", row.fingerprint }});
        const is_new = row.first >= range.start_ms;
        try render(w, "<tr data-href=\"{href}\"{!selected}><td class=\"wrap\"><a href=\"{href}\" class=\"block medium {class}\">{message}</a><span class=\"mono secondary\">{file}{line} · {path}</span></td><td class=\"r\">{visits}</td><td class=\"hide-m\">", .{
            .href = href,
            .selected = if (std.mem.eql(u8, row.fingerprint, selected.fingerprint)) " aria-selected=\"true\"" else "",
            .class = if (is_new) "bad" else "",
            .message = row.message,
            .file = if (row.file.len != 0) row.file else "inline",
            .line = if (row.line > 0) try std.fmt.allocPrint(arena, ":{d}", .{row.line}) else "",
            .path = row.path,
            .visits = html.int(row.visits),
        });
        try errorBars(ctx, view, row.fingerprint);
        try render(w, "</td><td class=\"hide-m\"><span class=\"status-dot {class}\"></span>{status}</td></tr>", .{ .class = if (is_new) "bad" else "", .status = try errorStatus(arena, row, range, ctx.now(), false) });
    }
    try w.writeAll("</tbody></table></div></section>");

    // Detail of the selected error.
    try render(w, "<aside class=\"card error-detail\"><div class=\"overline\">{status}</div><h2 class=\"bad error-title\">{message}</h2><dl class=\"kv\">", .{ .status = try errorStatus(arena, selected, range, ctx.now(), true), .message = selected.message });
    try render(w, "<dt>First seen</dt><dd>{first}</dd><dt>Last seen</dt><dd>{last}</dd><dt>{unit}</dt><dd>{visits} · {count} errors</dd><dt>Browsers</dt><dd>{browsers}</dd><dt>Where</dt><dd class=\"mono\">{path}</dd><dt>Location</dt><dd class=\"mono\">{file}{line}</dd></dl>", .{
        .first = data.clock(selected.first, ctx.now()),
        .last = data.ago(selected.last, ctx.now()),
        .unit = if (site.linked()) "Sessions" else "Views",
        .visits = html.int(selected.visits),
        .count = html.int(selected.count),
        .browsers = try data.prettyList(arena, selected.browsers),
        .path = selected.path,
        .file = if (selected.file.len != 0) selected.file else "inline script",
        .line = if (selected.line > 0) try std.fmt.allocPrint(arena, ":{d}", .{selected.line}) else "",
    });
    try w.writeAll("<p class=\"hint error-note\">Error text and location only — no form values, cookies or URLs with queries.</p>");
    if (site.mode == .full) {
        const recorded = try ctx.db.scalar(arena, i64, "SELECT count(*) FROM rp.replays r WHERE r.site_id=? AND r.session_id IN (SELECT session_id FROM errors WHERE site_id=? AND fingerprint=?)", .{ site.id, site.id, selected.fingerprint });
        if (recorded > 0) {
            try render(w, "<a class=\"btn btn-dark btn-block\" href=\"{href}\">", .{ .href = try view.href(arena, try std.fmt.allocPrint(arena, "/{s}/sessions", .{site.slug}), &.{ .{ "error", selected.fingerprint }, .{ "signal", "recorded" } }) });
            try icon(w, "play-circle");
            try w.print("Watch {d} replay{s} of it</a>", .{ recorded, if (recorded == 1) "" else "s" });
        }
    }
    if (site.linked()) try render(w, "<a class=\"btn btn-block mt-8\" href=\"{href}\">See the sessions</a>", .{ .href = try view.href(arena, try std.fmt.allocPrint(arena, "/{s}/sessions", .{site.slug}), &.{.{ "error", selected.fingerprint }}) });
    try w.writeAll("</aside></div>");
    return layout.end(ctx);
}

/// Daily counts as small bars across the selected range (at most 14 bars).
fn errorBars(ctx: *Ctx, view: data.View, fingerprint: []const u8) !void {
    const w = ctx.w();
    const range = view.range;
    const bars: usize = @min(range.buckets, 14);
    const width = @divFloor(range.end_ms - range.start_ms, @as(i64, @intCast(bars)));
    var sql = data.Sql.init(ctx.arena);
    try sql.add("SELECT (x.received_at_ms-");
    try sql.int(range.start_ms);
    try sql.add(")/");
    try sql.int(width);
    try sql.add(",count(*) FROM errors x WHERE ");
    try errorScope(&sql, view, range.start_ms, range.end_ms);
    try sql.add(" AND x.fingerprint=");
    try sql.str(fingerprint);
    try sql.add(" GROUP BY 1");
    var statement = try sql.prepare(ctx.db);
    defer statement.deinit();
    var values: [14]i64 = @splat(0);
    var peak: i64 = 1;
    while (try statement.step() == .row) {
        const index = statement.columnInt(0);
        if (index >= 0 and index < bars) {
            values[@intCast(index)] = statement.columnInt(1);
            peak = @max(peak, statement.columnInt(1));
        }
    }
    try w.writeAll("<span class=\"bars\">");
    for (values[0..bars]) |value| try w.print("<i style=\"height:{d}%\"></i>", .{if (value == 0) 6 else @max(14, @divFloor(value * 100, peak))});
    try w.writeAll("</span>");
}
