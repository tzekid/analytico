//! Heatmaps: per-page click, scroll and attention aggregates, the list of
//! pages in the workspace, and the data the live overlay draws on the site.
const std = @import("std");
const db_mod = @import("../db.zig");
const data = @import("data.zig");

/// Overlay data computed in the last minute, so a page warmed from the
/// workspace (hover on "Open on site") opens with its heatmap at once.
pub const Cache = struct {
    const ttl_ms = 60_000;
    const Entry = struct { site_id: i64 = 0, key: []u8 = &.{}, body: []u8 = &.{}, at_ms: i64 = 0 };
    mutex: std.Io.Mutex = .init,
    entries: [32]Entry = @splat(.{}),
    next: usize = 0,

    fn keyFor(buffer: []u8, path: []const u8, viewport: []const u8, days: i64) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}|{s}|{d}", .{ path, viewport, days });
    }

    pub fn get(self: *Cache, io: std.Io, arena: std.mem.Allocator, site_id: i64, path: []const u8, viewport: []const u8, days: i64, now_ms: i64) !?[]const u8 {
        var buffer: [600]u8 = undefined;
        const key = keyFor(&buffer, path, viewport, days) catch return null;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.entries) |entry| if (entry.site_id == site_id and now_ms - entry.at_ms < ttl_ms and std.mem.eql(u8, entry.key, key)) return try arena.dupe(u8, entry.body);
        return null;
    }

    pub fn put(self: *Cache, io: std.Io, gpa: std.mem.Allocator, site_id: i64, path: []const u8, viewport: []const u8, days: i64, body: []const u8, now_ms: i64) !void {
        var buffer: [600]u8 = undefined;
        const key = keyFor(&buffer, path, viewport, days) catch return;
        const owned_key = try gpa.dupe(u8, key);
        errdefer gpa.free(owned_key);
        const owned_body = try gpa.dupe(u8, body);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const slot = &self.entries[self.next];
        self.next = (self.next + 1) % self.entries.len;
        gpa.free(slot.key);
        gpa.free(slot.body);
        slot.* = .{ .site_id = site_id, .key = owned_key, .body = owned_body, .at_ms = now_ms };
    }

    pub fn deinit(self: *Cache, gpa: std.mem.Allocator) void {
        for (&self.entries) |*entry| {
            gpa.free(entry.key);
            gpa.free(entry.body);
            entry.* = .{};
        }
    }
};

/// The overlay's data, from the cache when it was warmed in the last minute.
pub fn cachedAggregates(arena: std.mem.Allocator, shared: *@import("../server.zig").Shared, db: *db_mod.Db, site_id: i64, path: []const u8, viewport: []const u8, days: i64, now_ms: i64) ![]const u8 {
    if (try shared.heat_cache.get(shared.io, arena, site_id, path, viewport, days, now_ms)) |body| return body;
    const body = try aggregatesJson(arena, db, site_id, path, viewport, days, now_ms);
    try shared.heat_cache.put(shared.io, shared.gpa, site_id, path, viewport, days, body, now_ms);
    return body;
}

/// The overlay's data for one page and viewport class over `days` days.
pub fn aggregatesJson(arena: std.mem.Allocator, db: *db_mod.Db, site_id: i64, path: []const u8, viewport: []const u8, days: i64, now_ms: i64) ![]const u8 {
    const since_ms = now_ms - days * data.day_ms;
    const since_day = data.dateText(since_ms);
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;

    var views = try db.prepare(arena, "SELECT count(*) FROM page_views WHERE site_id=? AND path=? AND coalesce(viewport_class,'desktop')=? AND received_at_ms>=? AND internal=0 AND traffic_class IN ('human_like','unknown')");
    defer views.deinit();
    try views.bindInt(1, site_id);
    try views.bindText(2, path);
    try views.bindText(3, viewport);
    try views.bindInt(4, since_ms);
    _ = try views.step();
    try w.print("{{\"views\":{d},\"clicks\":[", .{views.columnInt(0)});

    var clicks = try db.prepare(arena, "SELECT element,x,y,sum(clicks),sum(rage) FROM click_cells WHERE site_id=? AND path=? AND viewport_class=? AND day>=? GROUP BY element,x,y ORDER BY 4 DESC LIMIT 3000");
    defer clicks.deinit();
    try clicks.bindInt(1, site_id);
    try clicks.bindText(2, path);
    try clicks.bindText(3, viewport);
    try clicks.bindText(4, &since_day);
    var first = true;
    while (try clicks.step() == .row) {
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"el\":");
        try std.json.Stringify.value(clicks.columnText(0), .{}, w);
        try w.print(",\"x\":{d},\"y\":{d},\"n\":{d},\"rage\":{d}}}", .{ clicks.columnInt(1), clicks.columnInt(2), clicks.columnInt(3), clicks.columnInt(4) });
    }

    // Scroll reach: share of views reaching each 5% step of the page.
    var scroll = try db.prepare(arena,
        \\SELECT pv.max_scroll FROM page_views pv
        \\WHERE pv.site_id=? AND pv.path=? AND coalesce(pv.viewport_class,'desktop')=? AND pv.received_at_ms>=? AND pv.internal=0 AND pv.max_scroll IS NOT NULL
    );
    defer scroll.deinit();
    try scroll.bindInt(1, site_id);
    try scroll.bindText(2, path);
    try scroll.bindText(3, viewport);
    try scroll.bindInt(4, since_ms);
    var reached: [21]i64 = @splat(0);
    var samples: i64 = 0;
    var total_scroll: i64 = 0;
    while (try scroll.step() == .row) {
        const depth = std.math.clamp(scroll.columnInt(0), 0, 100);
        samples += 1;
        total_scroll += depth;
        for (&reached, 0..) |*slot, step| {
            if (depth >= @as(i64, @intCast(step)) * 5) slot.* += 1;
        }
    }
    try w.writeAll("],\"scroll\":[");
    for (reached, 0..) |count, index| {
        if (index != 0) try w.writeByte(',');
        try w.print("{d:.3}", .{if (samples == 0) 0 else @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(samples))});
    }
    try w.print("],\"average_scroll\":{d:.1},\"attention\":[", .{if (samples == 0) 0 else @as(f64, @floatFromInt(total_scroll)) / @as(f64, @floatFromInt(samples))});

    var attention = try db.prepare(arena,
        \\SELECT coalesce(avg(json_extract(ps.attention_json,'$[0]')),0),coalesce(avg(json_extract(ps.attention_json,'$[1]')),0),
        \\ coalesce(avg(json_extract(ps.attention_json,'$[2]')),0),coalesce(avg(json_extract(ps.attention_json,'$[3]')),0),
        \\ coalesce(avg(json_extract(ps.attention_json,'$[4]')),0),coalesce(avg(json_extract(ps.attention_json,'$[5]')),0),
        \\ coalesce(avg(json_extract(ps.attention_json,'$[6]')),0),coalesce(avg(json_extract(ps.attention_json,'$[7]')),0),
        \\ coalesce(avg(json_extract(ps.attention_json,'$[8]')),0),coalesce(avg(json_extract(ps.attention_json,'$[9]')),0)
        \\FROM page_views pv JOIN page_summaries ps ON ps.site_id=pv.site_id AND ps.page_id=pv.page_id
        \\WHERE pv.site_id=? AND pv.path=? AND coalesce(pv.viewport_class,'desktop')=? AND pv.received_at_ms>=? AND ps.attention_json IS NOT NULL
    );
    defer attention.deinit();
    try attention.bindInt(1, site_id);
    try attention.bindText(2, path);
    try attention.bindText(3, viewport);
    try attention.bindInt(4, since_ms);
    _ = try attention.step();
    for (0..10) |index| {
        if (index != 0) try w.writeByte(',');
        try w.print("{d:.0}", .{attention.columnFloat(index)});
    }
    try w.writeAll("]}");
    return out.written();
}

// ---------------------------------------------------------------- workspace

const analyze = @import("analyze.zig");
const ctx_mod = @import("ctx.zig");
const domain = @import("../domain.zig");
const html = @import("html.zig");
const layout = @import("layout.zig");
const ui = @import("ui.zig");

const Ctx = ctx_mod.Ctx;
const esc = html.esc;
const icon = layout.icon;
const render = html.render;

/// A readable name for an element selector: the marked action, the element's
/// id, or "Link 3 in nav" from its position.
pub fn prettyElement(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    const action_prefix = "[data-analytics-action=\"";
    if (std.mem.startsWith(u8, key, action_prefix) and key.len > action_prefix.len + 2) return key[action_prefix.len .. key.len - 2];
    var steps = std.mem.splitBackwardsScalar(u8, key, '>');
    const last = steps.next() orelse key;
    if (last.len != 0 and last[0] == '#') return last;
    const colon = std.mem.findScalar(u8, last, ':') orelse last.len;
    const tag = last[0..colon];
    const kinds = [_][2][]const u8{ .{ "a", "Link" }, .{ "button", "Button" }, .{ "input", "Field" }, .{ "select", "Menu" }, .{ "textarea", "Text box" }, .{ "label", "Label" }, .{ "summary", "Toggle" }, .{ "img", "Image" } };
    var noun: []const u8 = tag;
    for (kinds) |entry| if (std.mem.eql(u8, entry[0], tag)) {
        noun = entry[1];
    };
    const number = if (std.mem.find(u8, last, "nth-of-type(")) |at| last[at + 12 .. last.len - 1] else "1";
    const parent_step = steps.next() orelse return std.fmt.allocPrint(arena, "{s} {s}", .{ noun, number });
    const parent = if (std.mem.findScalar(u8, parent_step, ':')) |index| parent_step[0..index] else parent_step;
    return std.fmt.allocPrint(arena, "{s} {s} in {s}", .{ noun, number, parent });
}

test "element names" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("buy", try prettyElement(arena, "[data-analytics-action=\"buy\"]"));
    try std.testing.expectEqualStrings("Link 3 in nav", try prettyElement(arena, "body>nav:nth-of-type(1)>a:nth-of-type(3)"));
    try std.testing.expectEqualStrings("#signup", try prettyElement(arena, "#signup"));
}

const Kind = enum { clicks, scroll, attention };

pub fn page(ctx: *Ctx, site: data.Site) !void {
    const arena = ctx.arena;
    const view = try analyze.start(ctx, site, .heatmaps, "Heatmaps");
    const w = ctx.w();
    const path = try std.fmt.allocPrint(arena, "/{s}/heatmaps", .{site.slug});
    try layout.head(ctx, .{ .title = "Heatmaps", .subtitle = try std.fmt.allocPrint(ctx.arena, "Where people click, how far they scroll, what holds their attention · {f}", .{view.range}), .view = view, .path = path, .compare = false, .filter = false });
    if (site.mode != .full) {
        try w.writeAll("<div class=\"card\">");
        try ui.empty(w, "Heatmaps need Full mode", "Clicks, scroll reach and attention are collected from visitors who consent in Full mode — aggregated per element, never per person.", if (ctx.can(.admin)) try html.print(arena, "<a class=\"btn btn-primary\" href=\"/settings/sites?site={slug}\">Switch to Full mode</a>", .{ .slug = site.slug }) else "");
        try w.writeAll("</div>");
        return layout.end(ctx);
    }
    const kind = std.meta.stringToEnum(Kind, ctx.param("kind") orelse "clicks") orelse .clicks;
    const viewport = ctx.param("vp") orelse "desktop";
    const viewport_ok = std.mem.eql(u8, viewport, "desktop") or std.mem.eql(u8, viewport, "tablet") or std.mem.eql(u8, viewport, "phone");
    const vp = if (viewport_ok) viewport else "desktop";
    try w.writeAll("<div class=\"row-between mb-16\"><div class=\"row\">");
    try segmented(ctx, view, path, "kind", &.{ .{ "clicks", "Clicks" }, .{ "scroll", "Scroll" }, .{ "attention", "Attention" } }, @tagName(kind));
    try segmented(ctx, view, path, "vp", &.{ .{ "desktop", "Desktop" }, .{ "tablet", "Tablet" }, .{ "phone", "Phone" } }, vp);
    try w.writeAll("</div><span class=\"hint\">Clicks are kept per element, rounded to a grid — never per person</span></div>");

    const from_day = data.dateText(view.range.start_ms);
    const to_day = data.dateText(view.range.end_ms - 1);
    var pages = try ctx.db.prepare(arena,
        \\SELECT pv.path,count(*),coalesce(avg(ps.max_scroll),0),
        \\ coalesce((SELECT sum(c.clicks) FROM click_cells c WHERE c.site_id=pv.site_id AND c.path=pv.path AND c.viewport_class=?3 AND c.day>=?5 AND c.day<=?6),0) clicks_n,
        \\ coalesce((SELECT sum(c.rage) FROM click_cells c WHERE c.site_id=pv.site_id AND c.path=pv.path AND c.viewport_class=?3 AND c.day>=?5 AND c.day<=?6),0),
        \\ coalesce(sum(ps.max_scroll>=50),0),count(ps.page_id)
        \\FROM page_views pv LEFT JOIN page_summaries ps ON ps.site_id=pv.site_id AND ps.page_id=pv.page_id
        \\WHERE pv.site_id=?1 AND pv.received_at_ms>=?2 AND pv.received_at_ms<?4 AND coalesce(pv.viewport_class,'desktop')=?3 AND pv.internal=0
        \\ AND pv.traffic_class IN ('human_like','unknown') AND pv.visitor_id IS NOT NULL
        \\GROUP BY pv.path ORDER BY CASE WHEN ?7 THEN clicks_n ELSE 0 END DESC,2 DESC LIMIT 12
    );
    defer pages.deinit();
    try pages.bindInt(1, site.id);
    try pages.bindInt(2, view.range.start_ms);
    try pages.bindText(3, vp);
    try pages.bindInt(4, view.range.end_ms);
    try pages.bindText(5, &from_day);
    try pages.bindText(6, &to_day);
    try pages.bindInt(7, @intFromBool(kind == .clicks));
    try w.writeAll("<div class=\"grid grid-3\">");
    var any = false;
    while (try pages.step() == .row) {
        any = true;
        const page_path = try arena.dupe(u8, pages.columnText(0));
        const views = pages.columnInt(1);
        const clicks = pages.columnInt(3);
        const rage = pages.columnInt(4);
        const summaries = pages.columnInt(6);
        const half = if (summaries == 0) 0 else @as(f64, @floatFromInt(pages.columnInt(5))) / @as(f64, @floatFromInt(summaries)) * 100;
        try w.writeAll("<section class=\"card heat-card\"><div class=\"heat-preview\">");
        switch (kind) {
            .clicks => try topElements(ctx, site.id, page_path, vp, &from_day, &to_day, clicks),
            .scroll => try scrollPreview(ctx, site.id, page_path, vp, view.range.start_ms),
            .attention => try attentionPreview(ctx, site.id, page_path, vp, view.range.start_ms),
        }
        try render(w, "</div><div class=\"heat-body\"><strong class=\"mono t-14\">{path}</strong><p class=\"hint\">", .{ .path = page_path });
        switch (kind) {
            .clicks => try w.print("{f} clicks · {f} views", .{ html.int(clicks), html.int(views) }),
            .scroll => try w.print("Scroll · {d:.0}% reach the middle · average {d:.0}%", .{ half, pages.columnFloat(2) }),
            .attention => try w.print("Attention · {f} views", .{html.int(views)}),
        }
        try w.writeAll("</p><div class=\"row-between\">");
        if (kind == .clicks and rage > 0) {
            try w.print("<span class=\"pill pill-brand\">{d} rage click{s}</span>", .{ rage, if (rage == 1) "" else "s" });
        } else if (kind == .scroll and half < 40 and summaries >= 5) {
            try w.writeAll("<span class=\"pill pill-warn\">Most leave before the middle</span>");
        } else if ((kind == .clicks and clicks >= 10) or (kind != .clicks and summaries >= 5)) {
            try w.writeAll("<span class=\"pill pill-good\">Healthy</span>");
        } else try w.writeAll("<span class=\"hint\">Not enough data yet</span>");
        try render(w, "<a class=\"link\" href=\"/{slug}/heatmaps/open?path={path}\" target=\"_blank\" rel=\"noopener\">Open on site ↗</a></div></div></section>", .{ .slug = site.slug, .path = html.url(page_path) });
    }
    try w.writeAll("</div>");
    if (!any) {
        try w.writeAll("<div class=\"card\">");
        try ui.empty(w, "No heatmap data yet", "Heatmaps fill in as consented visitors click and scroll. Try another screen size or a longer period.", "");
        try w.writeAll("</div>");
    }
    return layout.end(ctx);
}

fn segmented(ctx: *Ctx, view: data.View, path: []const u8, key: []const u8, items: []const [2][]const u8, active: []const u8) !void {
    const w = ctx.w();
    try w.writeAll("<nav class=\"seg seg-wide\">");
    for (items) |item| try render(w, "<a href=\"{href}\"{!current}>{label}</a>", .{ .href = try view.href(ctx.arena, path, &.{.{ key, item[0] }}), .current = if (std.mem.eql(u8, item[0], active)) " aria-current=\"true\"" else "", .label = item[1] });
    try w.writeAll("</nav>");
}

fn topElements(ctx: *Ctx, site_id: i64, path: []const u8, viewport: []const u8, from: []const u8, to: []const u8, total: i64) !void {
    const w = ctx.w();
    var statement = try ctx.db.prepare(ctx.arena, "SELECT element,sum(clicks),sum(rage) FROM click_cells WHERE site_id=? AND path=? AND viewport_class=? AND day>=? AND day<=? GROUP BY element ORDER BY 2 DESC LIMIT 4");
    defer statement.deinit();
    try statement.bindInt(1, site_id);
    try statement.bindText(2, path);
    try statement.bindText(3, viewport);
    try statement.bindText(4, from);
    try statement.bindText(5, to);
    var any = false;
    while (try statement.step() == .row) {
        any = true;
        const share = @as(f64, @floatFromInt(statement.columnInt(1))) / @as(f64, @floatFromInt(@max(total, 1))) * 100;
        try render(w, "<div class=\"heat-row\"><span class=\"heat-blob\" style=\"opacity:{opacity:.2}\"></span><span class=\"grow\" title=\"{selector}\">{label}</span><strong>{share:.0}%</strong></div>", .{ .opacity = 0.35 + share / 150, .selector = statement.columnText(0), .label = try prettyElement(ctx.arena, statement.columnText(0)), .share = share });
    }
    if (!any) try w.writeAll("<p class=\"hint\">No clicks on this screen size.</p>");
}

fn scrollPreview(ctx: *Ctx, site_id: i64, path: []const u8, viewport: []const u8, since: i64) !void {
    const json = try aggregatesJson(ctx.arena, ctx.db, site_id, path, viewport, @divFloor(ctx.now() - since, data.day_ms) + 1, ctx.now());
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, json, .{});
    const steps = parsed.object.get("scroll").?.array.items;
    const w = ctx.w();
    try w.writeAll("<div class=\"scroll-strip\">");
    for (steps[1..], 1..) |step, index| {
        const share = switch (step) {
            .float => |value| value,
            .integer => |value| @as(f64, @floatFromInt(value)),
            else => 0,
        };
        try w.print("<i style=\"background:rgba(214,73,55,{d:.2})\" title=\"{d:.0}% reach {d}%\"></i>", .{ 0.08 + share * 0.7, share * 100, index * 5 });
    }
    try w.writeAll("</div>");
}

fn attentionPreview(ctx: *Ctx, site_id: i64, path: []const u8, viewport: []const u8, since: i64) !void {
    const json = try aggregatesJson(ctx.arena, ctx.db, site_id, path, viewport, @divFloor(ctx.now() - since, data.day_ms) + 1, ctx.now());
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, json, .{});
    const bands = parsed.object.get("attention").?.array.items;
    var peak: f64 = 1;
    for (bands) |band| peak = @max(peak, jsonNumber(band));
    const w = ctx.w();
    try w.writeAll("<div class=\"attention-strip\">");
    for (bands, 0..) |band, index| {
        const value = jsonNumber(band);
        try w.print("<div><span style=\"width:{d:.0}%\"></span><small>{d}0%</small><b>{d:.0} s</b></div>", .{ value / peak * 100, index, value / 1000 });
    }
    try w.writeAll("</div>");
}

fn jsonNumber(value: std.json.Value) f64 {
    return switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => 0,
    };
}

/// Opens the live page with a two-hour overlay token in the fragment, so it
/// never reaches the site's server logs or referrers.
/// Computes the overlay's data for every screen size ahead of opening the
/// page, so the heatmap draws as soon as the site loads.
pub fn warm(ctx: *Ctx, site: data.Site) !void {
    const path = ctx.param("path") orelse "/";
    domain.validatePath(path) catch return ctx.text(.bad_request, "unknown page\n");
    for ([_][]const u8{ "desktop", "tablet", "phone" }) |viewport| _ = try cachedAggregates(ctx.arena, ctx.shared, ctx.db, site.id, path, viewport, 30, ctx.now());
    ctx.status = .no_content;
    return ctx.finish("text/plain; charset=utf-8");
}

pub fn open(ctx: *Ctx, site: data.Site) !void {
    const path = ctx.param("path") orelse "/";
    domain.validatePath(path) catch return layout.message(ctx, .bad_request, "Unknown page", "Pages start with / and have no query string.");
    var buffer: [300]u8 = undefined;
    const token = try domain.signToken(&buffer, ctx.shared.master_key, "overlay", site.public_id, ctx.now() + 2 * data.hour_ms);
    return ctx.redirectFmt("{s}{s}#analytico-heatmap={s}", .{ site.origin, path, token });
}
