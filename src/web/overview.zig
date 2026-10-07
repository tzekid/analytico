//! Overview page plus the small JSON endpoints the client runtime polls, and
//! view-level writes (notes, segments) and CSV export.
const std = @import("std");
const app = @import("app.zig");
const chart = @import("chart.zig");
const ctx_mod = @import("ctx.zig");
const auth = @import("auth.zig");
const data = @import("data.zig");
const html = @import("html.zig");
const layout = @import("layout.zig");
const ui = @import("ui.zig");
const domain = @import("../domain.zig");

const Ctx = ctx_mod.Ctx;
const esc = html.esc;
const icon = layout.icon;
const render = html.render;

pub const Tone = ui.Tone;
const tones = ui.tones;

/// Friendly names for common referrers; everything else shows its host.
pub fn sourceLabel(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    if (std.mem.eql(u8, key, "direct")) return "Direct / no referrer";
    // Keys come from visitors (utm_source); a bare "www." must still label something.
    const host = if (std.mem.startsWith(u8, key, "www.") and key.len > 4) key[4..] else key;
    const known = [_][2][]const u8{
        .{ "google.", "Google" },                   .{ "bing.com", "Bing" },             .{ "duckduckgo.com", "DuckDuckGo" },
        .{ "t.co", "X" },                           .{ "x.com", "X" },                   .{ "twitter.com", "X" },
        .{ "facebook.com", "Facebook" },            .{ "l.facebook.com", "Facebook" },   .{ "m.facebook.com", "Facebook" },
        .{ "instagram.com", "Instagram" },          .{ "l.instagram.com", "Instagram" }, .{ "linkedin.com", "LinkedIn" },
        .{ "lnkd.in", "LinkedIn" },                 .{ "reddit.com", "Reddit" },         .{ "old.reddit.com", "Reddit" },
        .{ "news.ycombinator.com", "Hacker News" }, .{ "github.com", "GitHub" },         .{ "youtube.com", "YouTube" },
        .{ "chatgpt.com", "ChatGPT" },              .{ "perplexity.ai", "Perplexity" },  .{ "yandex.ru", "Yandex" },
        .{ "ecosia.org", "Ecosia" },                .{ "mastodon.social", "Mastodon" },  .{ "bsky.app", "Bluesky" },
    };
    for (known) |pair| {
        if (pair[0][pair[0].len - 1] == '.') {
            if (std.mem.startsWith(u8, host, pair[0])) return pair[1];
        } else if (std.mem.eql(u8, host, pair[0])) return pair[1];
    }
    if (std.mem.findScalar(u8, host, '.') == null and host.len != 0) {
        const out = try arena.dupe(u8, host);
        out[0] = std.ascii.toUpper(out[0]);
        return out;
    }
    return host;
}

pub fn toneFor(key: []const u8) Tone {
    if (std.mem.indexOf(u8, key, "google") != null) return tones[1];
    if (std.mem.indexOf(u8, key, "instagram") != null or std.mem.indexOf(u8, key, "facebook") != null) return tones[2];
    if (std.mem.indexOf(u8, key, "newsletter") != null or std.mem.indexOf(u8, key, "mail") != null) return tones[0];
    return tones[@intCast(std.hash.Wyhash.hash(7, key) % tones.len)];
}

pub fn sourceRow(ctx: *Ctx, w: *std.Io.Writer, key: []const u8, value: i64, total: i64, largest: i64, href: []const u8) !void {
    const arena = ctx.arena;
    const label = try sourceLabel(arena, key);
    const direct = std.mem.eql(u8, key, "direct");
    const tone = if (direct) Tone{ .color = "#6F625D", .wash = "#F3EFED" } else toneFor(key);
    var avatar: std.Io.Writer.Allocating = .init(arena);
    if (direct) {
        try avatar.writer.writeAll("<span class=\"avatar avatar-direct\">");
        try icon(&avatar.writer, "arrow-up-right");
        try avatar.writer.writeAll("</span>");
    } else try render(&avatar.writer, "<span class=\"avatar\" style=\"background:{color}\">{initial}</span>", .{ .color = tone.color, .initial = &[_]u8{if (label.len == 0) '?' else std.ascii.toUpper(label[0])} });
    try ui.rankRow(w, arena, .{
        .href = href,
        .title = try std.fmt.allocPrint(arena, "Filter by {s}", .{label}),
        .width = if (largest == 0) 0 else @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(largest)) * 72.0 + 10.0,
        .bar = tone.wash,
        .edge = tone.color,
        .before = avatar.written(),
        .name = label,
        .value = try std.fmt.allocPrint(arena, "{f}", .{html.int(value)}),
        .pct = try std.fmt.allocPrint(arena, "{f}", .{html.share(value, total)}),
    });
}

pub fn pageRow(w: *std.Io.Writer, arena: std.mem.Allocator, index: usize, row: data.Row, largest: i64, href: []const u8) !void {
    const change = html.changeValue(@floatFromInt(row.value), @floatFromInt(row.previous));
    try ui.rankRow(w, arena, .{
        .href = href,
        .width = if (largest == 0) 0 else @as(f64, @floatFromInt(row.value)) / @as(f64, @floatFromInt(largest)) * 80.0 + 8.0,
        .lead = index == 0,
        .before = try std.fmt.allocPrint(arena, "<span class=\"n\">{d}</span>", .{index + 1}),
        .name = row.key,
        .after = if (row.value >= 10 and (std.math.isNan(change) or change >= 50)) "<i class=\"pill pill-brand\">Rising</i>" else "",
        .value = try std.fmt.allocPrint(arena, "{f}", .{html.int(row.value)}),
    });
}

pub fn page(ctx: *Ctx, site: data.Site) !void {
    const view = try data.View.parse(ctx.arena, site, ctx.query, ctx.now());
    const arena = ctx.arena;
    const db = ctx.db;
    const range = view.range;
    const base = try std.fmt.allocPrint(arena, "/{s}", .{site.slug});
    // The insights card loads after the page, when it scrolls into view.
    if (std.mem.eql(u8, ctx.param("part") orelse "", "insights")) {
        try data.prefetch(ctx.shared, ctx.db, arena, view, &.{
            .{ .totals = .{ .start = range.start_ms, .end = range.end_ms } },
            .{ .totals = .{ .start = range.prev_start_ms, .end = range.prev_end_ms } },
            .{ .top = .{ .dim = .source, .limit = 12 } },
            .{ .top = .{ .dim = .page, .limit = 20 } },
            .{ .key_sums = .{ .dim = "page", .start = range.start_ms, .end = range.end_ms, .limit = 40 } },
            .{ .key_sums = .{ .dim = "device", .start = range.start_ms, .end = range.end_ms, .limit = 20 } },
            .{ .key_sums = .{ .dim = "device", .start = range.prev_start_ms, .end = range.prev_end_ms, .limit = 20 } },
        });
        try insights(ctx, view, try data.totals(arena, db, view, range.start_ms, range.end_ms), try data.totals(arena, db, view, range.prev_start_ms, range.prev_end_ms));
        return ctx.html();
    }
    try layout.begin(ctx, try app.shell(ctx, site, .overview, "Overview", view));
    const w = ctx.w();

    const last_seen = try data.lastSeen(arena, db, site.id);
    const online = try data.online(arena, db, site.id, ctx.now());
    const badge = try std.fmt.allocPrint(arena, "<span class=\"live\" data-live data-stream=\"/{s}/stream\">{d} online now</span>", .{ site.slug, online });
    const subtitle = try std.fmt.allocPrint(arena, "{f}{s}{s}{s}", .{ range, if (view.compare) " · compared with " else "", if (view.compare) range.comparisonLabel() else "", if (try data.hasImported(arena, db, view)) " · includes imported Google Analytics history" else "" });
    try layout.head(ctx, .{ .title = "Overview", .badge = if (last_seen != 0) badge else "", .subtitle = subtitle, .view = view, .path = base });

    if (last_seen == 0 and !try data.hasImported(arena, db, view)) {
        try w.writeAll("<div class=\"card\">");
        try ui.empty(w, "Waiting for your first visitor", "Add the snippet to your site and open it in another tab — this page fills in by itself the moment data arrives.", try html.print(arena, "<a class=\"btn btn-primary\" href=\"/{slug}/setup\">Show the snippet</a>", .{ .slug = site.slug }));
        try w.writeAll("</div>");
        return layout.end(ctx);
    }

    try data.prefetch(ctx.shared, ctx.db, arena, view, try overviewCalls(arena, view));
    const current = try data.totals(arena, db, view, range.start_ms, range.end_ms);
    const previous = try data.totals(arena, db, view, range.prev_start_ms, range.prev_end_ms);
    try metricStrip(ctx, view, base, current, previous);
    if (ctx.can(.editor)) try draftNotes(ctx, site);
    try trendCard(ctx, view, base);
    try w.writeAll("<div class=\"grid grid-3 overview-cards mt-16\">");
    try sourcesCard(ctx, view, base, current.views);
    try placesCard(ctx, view, base, current.views);
    const customers = @import("customers.zig");
    if ((try customers.sales(ctx.arena, ctx.db, view, range.start_ms, range.end_ms)).orders > 0) try sellsCard(ctx, view) else try pagesCard(ctx, view);
    try w.writeAll("</div>");
    try render(w, "<div data-lazy=\"{href}\"></div>", .{ .href = try view.href(arena, base, &.{.{ "part", "insights" }}) });
    return layout.end(ctx);
}

/// Notes the daily check drafted for days that broke the trend: kept, they
/// join the chart; dismissed, they go.
fn draftNotes(ctx: *Ctx, site: data.Site) !void {
    const drafts = try ctx.db.all(ctx.arena, struct { id: i64, day: []const u8, label: []const u8 }, "SELECT id,day,label FROM annotations WHERE site_id=? AND draft=1 ORDER BY day DESC LIMIT 3", .{site.id});
    for (drafts) |note| try render(ctx.w(),
        \\<div class="callout mb-14" data-draft-note><span class="grow">Noticed on {day}: <strong>{label}</strong></span><form method="post" action="/{slug}/annotations/{id}/keep"><button class="btn">Keep as a note</button></form><form method="post" action="/{slug}/annotations/{id}/delete"><button class="btn btn-quiet">Dismiss</button></form></div>
    , .{ .day = note.day, .label = note.label, .slug = site.slug, .id = note.id });
}

/// The independent queries the overview makes, run ahead in parallel.
fn overviewCalls(arena: std.mem.Allocator, view: data.View) ![]const data.Call {
    const range = view.range;
    var calls: std.ArrayList(data.Call) = .empty;
    for ([_][2]i64{ .{ range.start_ms, range.end_ms }, .{ range.prev_start_ms, range.prev_end_ms } }) |span| {
        try calls.append(arena, .{ .totals = .{ .start = span[0], .end = span[1] } });
        if (view.site.mode == .full) try calls.append(arena, .{ .key_sums = .{ .dim = "visitor_type", .start = span[0], .end = span[1], .limit = 10 } });
    }
    for ([_]data.Metric{ .visitors, .visitor_days, .views, .active }) |metric| {
        if (metric == .visitor_days and view.site.mode == .full) continue;
        try calls.append(arena, .{ .series = .{ .metric = metric, .start = range.start_ms } });
    }
    const trend = if (view.metric == .visitors) data.Metric.visitor_days else view.metric;
    if (view.site.mode == .full or trend != .visitor_days) try calls.append(arena, .{ .series = .{ .metric = trend, .start = range.start_ms } });
    if (view.compare) try calls.append(arena, .{ .series = .{ .metric = trend, .start = range.prev_start_ms } });
    for ([_]struct { data.Dim, usize }{ .{ .source, 5 }, .{ .country, 6 }, .{ .device, 4 }, .{ .page, 5 } }) |entry| {
        try calls.append(arena, .{ .top = .{ .dim = entry[0], .limit = entry[1] } });
    }
    return calls.items;
}

/// The four headline metrics; each tile switches the trend chart.
pub fn metricStrip(ctx: *Ctx, view: data.View, base: []const u8, current: data.Totals, previous: data.Totals) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    const range = view.range;
    try w.writeAll("<div class=\"metrics\">");
    const metrics = [_]struct { data.Metric, []const u8, Tone }{
        .{ .visitors, "audience", tones[0] },
        .{ .visitor_days, "calendar", tones[1] },
        .{ .views, "pages", tones[2] },
        .{ .active, "performance", tones[3] },
    };
    const customers = @import("customers.zig");
    const sold = try customers.sales(ctx.arena, ctx.db, view, range.start_ms, range.end_ms);
    for (metrics) |entry| {
        const metric = entry[0];
        // Full mode remembers visitors: show who came back instead of visitor-days.
        if (metric == .visitor_days and view.site.mode == .full) {
            const now_share = try returningShare(ctx, view, range.start_ms, range.end_ms);
            const before_share = try returningShare(ctx, view, range.prev_start_ms, range.prev_end_ms);
            const delta = (now_share - before_share) * 100;
            try ui.metric(w, arena, .{
                .href = try view.href(arena, try std.fmt.allocPrint(arena, "/{s}/retention", .{view.site.slug}), &.{.{ "m", "" }}),
                .tone = entry[2],
                .icon = "retention",
                .label = "Returning visitors",
                .value = try std.fmt.allocPrint(arena, "{d:.0}%", .{now_share * 100}),
                .change = if (!view.compare) "&nbsp;" else try std.fmt.allocPrint(arena, "<span class=\"delta {s}\">{s}{d:.0} pts</span>{s}", .{ if (@abs(delta) < 0.5) "delta-flat" else if (delta > 0) "delta-up" else "delta-down", if (delta >= 0.5) "+" else if (delta <= -0.5) "−" else "", @abs(delta), range.shortComparison() }),
            });
            continue;
        }
        if (metric == .active and sold.orders > 0) {
            const before = try customers.sales(ctx.arena, ctx.db, view, range.prev_start_ms, range.prev_end_ms);
            try ui.metric(w, arena, .{
                .href = try view.href(arena, try std.fmt.allocPrint(arena, "/{s}/revenue", .{view.site.slug}), &.{.{ "m", "" }}),
                .tone = entry[2],
                .icon = "revenue",
                .label = "Revenue",
                .value = try std.fmt.allocPrint(arena, "{f}", .{html.money(sold.revenue, view.site.currency)}),
                .change = if (view.compare) try ui.change(arena, @floatFromInt(sold.revenue), @floatFromInt(before.revenue), false, range.shortComparison()) else "&nbsp;",
            });
            continue;
        }
        const value = current.metric(metric, range);
        try ui.metric(w, arena, .{
            .href = try view.href(arena, base, &.{.{ "m", @tagName(metric) }}),
            .current = view.metric == metric,
            .tone = entry[2],
            .icon = entry[1],
            .label = metric.label(),
            .value = if (metric == .active)
                try std.fmt.allocPrint(arena, "{f}", .{html.duration(current.active_ms)})
            else if (value < 10 and value != @round(value))
                try std.fmt.allocPrint(arena, "{d:.1}", .{value})
            else
                try std.fmt.allocPrint(arena, "{f}", .{html.int(@intFromFloat(@round(value)))}),
            .spark = try data.series(arena, ctx.db, view, metric, range.start_ms),
            .change = if (view.compare) try ui.change(arena, value, previous.metric(metric, range), false, range.shortComparison()) else "&nbsp;",
        });
    }
    try w.writeAll("</div>");
}

/// Share of remembered visitor-days whose visitor was first seen on an
/// earlier day.
fn returningShare(ctx: *Ctx, view: data.View, start: i64, end: i64) !f64 {
    const sums = try data.keySums(ctx.arena, ctx.db, view, "visitor_type", start, end, 10);
    const returning = data.keySum(sums, "returning").visitors;
    const total = returning + data.keySum(sums, "new").visitors;
    return if (total == 0) 0 else @as(f64, @floatFromInt(returning)) / @as(f64, @floatFromInt(total));
}

/// Where visitors are: countries when places are known, devices otherwise.
pub fn placesCard(ctx: *Ctx, view: data.View, base: []const u8, total_views: i64) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    const rows = try data.top(arena, ctx.db, view, .country, 6);
    var known = false;
    for (rows) |row| {
        if (!std.mem.eql(u8, row.key, "unknown")) known = true;
    }
    if (!known) {
        const devices = try data.top(arena, ctx.db, view, .device, 4);
        try w.writeAll("<section class=\"card\">");
        try ui.cardHead(w, "Devices", "<span class=\"meta\">Page views</span>");
        try w.writeAll("<div class=\"rank\">");
        for (devices) |row| try ui.rankRow(w, arena, .{
            .href = try view.href(arena, base, &.{.{ "f+", try std.fmt.allocPrint(arena, "device:{s}", .{row.key}) }}),
            .width = @as(f64, @floatFromInt(row.value)) / @as(f64, @floatFromInt(@max(total_views, 1))) * 80 + 8,
            .bar = "var(--brand-wash)",
            .name = row.key,
            .value = try std.fmt.allocPrint(arena, "{f}", .{html.int(row.value)}),
            .pct = try std.fmt.allocPrint(arena, "{f}", .{html.share(row.value, total_views)}),
        });
        if (devices.len == 0) try w.writeAll("<p class=\"hint\">No page views match this view.</p>");
        try w.writeAll("</div><p class=\"hint mt-12\">Countries appear once a location database is installed (<code>analytico geo import</code>).</p></section>");
        return;
    }
    try w.writeAll("<section class=\"card\">");
    try ui.cardHead(w, "Where they are", try html.print(arena, "<a class=\"link\" href=\"{href}\">All countries →</a>", .{ .href = try view.href(arena, try std.fmt.allocPrint(arena, "/{s}/audience", .{view.site.slug}), &.{}) }));
    try w.writeAll("<div class=\"stack-s\">");
    for (rows) |row| {
        if (std.mem.eql(u8, row.key, "unknown")) continue;
        try ui.countryRow(w, arena, try view.href(arena, base, &.{.{ "f+", try std.fmt.allocPrint(arena, "country:{s}", .{row.key}) }}), row.key, @as(f64, @floatFromInt(row.value)) / @as(f64, @floatFromInt(@max(total_views, 1))) * 100);
    }
    try w.writeAll("</div><p class=\"hint mt-12\">Country from the address at collection · never stored · <a class=\"link\" href=\"https://db-ip.com\" rel=\"noopener\">IP location by DB-IP</a></p></section>");
}

/// Best-selling products by revenue.
pub fn sellsCard(ctx: *Ctx, view: data.View) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    const customers = @import("customers.zig");
    var sql = data.Sql.init(arena);
    try sql.add("SELECT max(i.name),count(DISTINCT e.event_id),sum(coalesce(i.price_minor,0)*i.quantity) FROM events e JOIN event_items i ON i.site_id=e.site_id AND i.event_id=e.event_id WHERE ");
    try sql.events(view, view.range.start_ms, view.range.end_ms);
    try sql.add(" AND e.name IN " ++ customers.purchase_names ++ " GROUP BY i.item_id ORDER BY 3 DESC LIMIT 4");
    var statement = try sql.prepare(ctx.db);
    defer statement.deinit();
    try w.writeAll("<section class=\"card\">");
    try ui.cardHead(w, "What sells", try html.print(arena, "<a class=\"link\" href=\"{href}\">Open revenue →</a>", .{ .href = try view.href(arena, try std.fmt.allocPrint(arena, "/{s}/revenue", .{view.site.slug}), &.{}) }));
    try w.writeAll("<div class=\"stack-s\">");
    var index: usize = 0;
    while (try statement.step() == .row) : (index += 1) {
        const orders = statement.columnInt(1);
        try render(w, "<div class=\"product-row\"><span class=\"n\">{n}</span><span class=\"grow\"><strong>{name}</strong><small>{orders} order{plural}</small></span><strong>{revenue}</strong></div>", .{ .n = index + 1, .name = statement.columnText(0), .orders = orders, .plural = if (orders == 1) "" else "s", .revenue = html.money(statement.columnInt(2), view.site.currency) });
    }
    if (index == 0) try w.writeAll("<p class=\"hint\">Orders arrived without items. Add <code>items</code> to purchase events to see products.</p>");
    try w.writeAll("</div></section>");
}

pub fn pagesCard(ctx: *Ctx, view: data.View) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    const pages_path = try std.fmt.allocPrint(arena, "/{s}/pages", .{view.site.slug});
    const pages = try data.top(arena, ctx.db, view, .page, 5);
    try w.writeAll("<section class=\"card\">");
    try ui.cardHead(w, "Top pages", try html.print(arena, "<a class=\"link\" href=\"{href}\">View all →</a>", .{ .href = try view.href(arena, pages_path, &.{}) }));
    try w.writeAll("<div class=\"rank\">");
    for (pages, 0..) |row, index| try pageRow(w, arena, index, row, pages[0].value, try view.href(arena, pages_path, &.{.{ "page", row.key }}));
    if (pages.len == 0) try w.writeAll("<p class=\"hint\">No page views match this view.</p>");
    try w.writeAll("</div></section>");
}

pub fn sourcesCard(ctx: *Ctx, view: data.View, base: []const u8, total_views: i64) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    const sources = try data.top(arena, ctx.db, view, .source, 5);
    try w.writeAll("<section class=\"card\">");
    try ui.cardHead(w, "Where visitors come from", "<span class=\"meta\">Page views</span>");
    try w.writeAll("<div class=\"rank\">");
    for (sources) |row| try sourceRow(ctx, w, row.key, row.value, total_views, sources[0].value, try view.href(arena, base, &.{.{ "f+", try std.fmt.allocPrint(arena, "source:{s}", .{row.key}) }}));
    if (sources.len == 0) try w.writeAll("<p class=\"hint\">No sources match this view.</p>");
    try w.writeAll("</div></section>");
}

fn finish(ctx: *Ctx) !void {
    return layout.end(ctx);
}

pub fn annotationMarks(ctx: *Ctx, view: data.View) ![]chart.Mark {
    var statement = try ctx.db.prepare(ctx.arena, "SELECT day,label FROM annotations WHERE site_id=? AND day>=? AND day<=? AND draft=0 ORDER BY day LIMIT 6");
    defer statement.deinit();
    const from = data.dateText(view.range.start_ms);
    const to = data.dateText(view.range.end_ms - 1);
    try statement.bindInt(1, view.site.id);
    try statement.bindText(2, &from);
    try statement.bindText(3, &to);
    var out: std.ArrayList(chart.Mark) = .empty;
    while (try statement.step() == .row) {
        if (view.range.bucketOfDay(statement.columnText(0))) |index| {
            try out.append(ctx.arena, .{ .index = if (view.range.bucket_ms == data.hour_ms) 0 else index, .label = try ctx.arena.dupe(u8, statement.columnText(1)) });
        } else if (view.range.bucket_ms == data.hour_ms) {
            const day_start = data.parseDate(statement.columnText(0)) catch continue;
            if (day_start >= view.range.start_ms and day_start < view.range.end_ms) {
                try out.append(ctx.arena, .{ .index = @intCast(@divFloor(day_start - view.range.start_ms, data.hour_ms)), .label = try ctx.arena.dupe(u8, statement.columnText(1)) });
            }
        }
    }
    return out.items;
}

pub fn labels(arena: std.mem.Allocator, range: data.Range) !struct { []const []const u8, []const []const u8 } {
    const short = try arena.alloc([]const u8, range.buckets);
    const long = try arena.alloc([]const u8, range.buckets);
    for (0..range.buckets) |index| {
        var buffer: [48]u8 = undefined;
        short[index] = try arena.dupe(u8, range.bucketLabel(&buffer, index));
        long[index] = try arena.dupe(u8, range.bucketLong(&buffer, index));
    }
    return .{ short, long };
}

fn bucketDays(arena: std.mem.Allocator, range: data.Range) ![]const []const u8 {
    const out = try arena.alloc([]const u8, range.buckets);
    for (out, 0..) |*day, index| day.* = try arena.dupe(u8, &data.dateText(range.start_ms + @as(i64, @intCast(index)) * data.day_ms));
    return out;
}

pub fn trendCard(ctx: *Ctx, view: data.View, base: []const u8) !void {
    _ = base;
    const arena = ctx.arena;
    const w = ctx.w();
    const range = view.range;
    const metric = if (view.metric == .visitors) data.Metric.visitor_days else view.metric;
    const current = try data.series(arena, ctx.db, view, metric, range.start_ms);
    const previous = if (view.compare) try data.series(arena, ctx.db, view, metric, range.prev_start_ms) else null;
    const marks = try annotationMarks(ctx, view);
    const names = try labels(arena, range);
    // The headline: the strongest bucket, and a note just before it if any.
    var best: usize = 0;
    for (current, 0..) |value, index| if (value > current[best]) {
        best = index;
    };
    try render(w, "<section class=\"card chart-card\"><div class=\"chart-head\"><div><h2>{title}</h2>", .{ .title = view.metric.chartTitle() });
    if (current.len != 0 and current[best] > 0) {
        try w.print("<p class=\"insight\">{s} was the busiest {s} — {f} {s}", .{ names[1][best], if (range.bucket_ms == data.hour_ms) "hour" else "day", if (metric == .active) html.Int{ .value = @intFromFloat(current[best] / 60_000) } else html.int(@intFromFloat(current[best])), if (metric == .active) "active minutes" else metric.unit() });
        for (marks) |mark| if (mark.index + 1 == best or mark.index == best) {
            try w.print(", {s} “{f}”", .{ if (mark.index == best) "the day of" else "one day after", esc(mark.label) });
            break;
        };
        if (previous) |prev| if (prev[best] > 0 and @abs(html.changeValue(current[best], prev[best])) >= 1) try w.print(" ({f} vs the same {s} before)", .{ html.change(current[best], prev[best]), if (range.bucket_ms == data.hour_ms) "hour" else "day" });
        try w.writeAll(".</p>");
    }
    try w.writeAll("</div><div class=\"legend\"><span class=\"this\">This period</span>");
    if (view.compare) try w.writeAll("<span class=\"prev\">Previous period</span>");
    try w.writeAll("</div></div>");
    try chart.trend(arena, w, .{
        .current = current,
        .previous = previous,
        .labels = names[0],
        .long_labels = names[1],
        .marks = marks,
        .unit = if (metric == .active) "active" else metric.unit(),
        .duration = metric == .active,
        .emphasis = best,
        .why = try std.fmt.allocPrint(arena, "/{s}/why", .{view.site.slug}),
        .days = if (range.bucket_ms == data.day_ms) try bucketDays(arena, range) else &.{},
    });
    try w.writeAll("</section>");
}

const Insight = struct { tone: Tone, icon: []const u8, big: []const u8, what: []const u8, text: []const u8, link: []const u8, href: []const u8 };

fn insights(ctx: *Ctx, view: data.View, current: data.Totals, previous: data.Totals) !void {
    const arena = ctx.arena;
    const site = view.site;
    var list: std.ArrayList(Insight) = .empty;
    const base = try std.fmt.allocPrint(arena, "/{s}", .{site.slug});
    // Fastest-growing source.
    const sources = try data.top(arena, ctx.db, view, .source, 12);
    var best_source: ?data.Row = null;
    var best_change: f64 = 15;
    for (sources) |row| {
        if (row.value < 5) continue;
        const change = if (row.previous == 0) 999 else html.changeValue(@floatFromInt(row.value), @floatFromInt(row.previous));
        if (change > best_change) {
            best_change = change;
            best_source = row;
        }
    }
    if (best_source) |row| {
        const label = try sourceLabel(arena, row.key);
        try list.append(arena, .{
            .tone = toneFor(row.key),
            .icon = "sources",
            .big = if (row.previous == 0) "New" else try std.fmt.allocPrint(arena, "{f}", .{html.change(@floatFromInt(row.value), @floatFromInt(row.previous))}),
            .what = try std.fmt.allocPrint(arena, "{s} visits", .{label}),
            .text = if (row.previous == 0)
                try std.fmt.allocPrint(arena, "{f} page views from a source that sent nothing the period before.", .{html.int(row.value)})
            else
                try std.fmt.allocPrint(arena, "{f} page views, up from {f}.", .{ html.int(row.value), html.int(row.previous) }),
            .link = try std.fmt.allocPrint(arena, "See {s} traffic →", .{label}),
            .href = try view.href(arena, base, &.{.{ "f+", try std.fmt.allocPrint(arena, "source:{s}", .{row.key}) }}),
        });
    }
    // Fastest-growing page, with scroll depth.
    const pages = try data.top(arena, ctx.db, view, .page, 20);
    var best_page: ?data.Row = null;
    best_change = 15;
    for (pages) |row| {
        if (row.value < 5 or row.previous == 0) continue;
        const change = html.changeValue(@floatFromInt(row.value), @floatFromInt(row.previous));
        if (change > best_change) {
            best_change = change;
            best_page = row;
        }
    }
    if (best_page) |row| {
        const page_sums = data.keySum(try data.keySums(arena, ctx.db, view, "page", view.range.start_ms, view.range.end_ms, 40), row.key);
        const scroll: f64 = if (page_sums.summaries == 0) 0 else @as(f64, @floatFromInt(page_sums.scroll_sum)) / @as(f64, @floatFromInt(page_sums.summaries));
        try list.append(arena, .{
            .tone = tones[1],
            .icon = "pages",
            .big = try std.fmt.allocPrint(arena, "{f}", .{html.change(@floatFromInt(row.value), @floatFromInt(row.previous))}),
            .what = row.key,
            .text = if (scroll > 0)
                try std.fmt.allocPrint(arena, "{f} views; readers scroll {d:.0}% of the way on average.", .{ html.int(row.value), scroll })
            else
                try std.fmt.allocPrint(arena, "{f} views, up from {f}.", .{ html.int(row.value), html.int(row.previous) }),
            .link = "Open page →",
            .href = try view.href(arena, try std.fmt.allocPrint(arena, "/{s}/pages", .{site.slug}), &.{.{ "page", row.key }}),
        });
    }
    // Mobile share.
    if (view.hasFilter(.device) == null and current.views >= 20) {
        const mobile = try deviceShare(ctx, view, view.range.start_ms, view.range.end_ms);
        const before = try deviceShare(ctx, view, view.range.prev_start_ms, view.range.prev_end_ms);
        if (mobile > 0) {
            try list.append(arena, .{
                .tone = tones[2],
                .icon = "audience",
                .big = try std.fmt.allocPrint(arena, "{d:.0}%", .{mobile * 100}),
                .what = "of visits are on mobile",
                .text = if (previous.views > 0)
                    try std.fmt.allocPrint(arena, "{s} from {d:.0}% the period before.", .{ if (mobile >= before) "Up" else "Down", before * 100 })
                else
                    "Phones and tablets combined.",
                .link = "Check performance →",
                .href = try view.href(arena, try std.fmt.allocPrint(arena, "/{s}/performance", .{site.slug}), &.{}),
            });
        }
    }
    if (list.items.len == 0) return;
    const w = ctx.w();
    try w.writeAll("<h2 class=\"section-title\">");
    try icon(w, "sparkles");
    try w.writeAll("What stood out<span class=\"note\">From your numbers · updates with the view</span></h2><div class=\"insights\">");
    for (list.items) |item| {
        try render(w, "<article class=\"insight-card\" style=\"--tone:{color}\"><div class=\"top\"><span class=\"badge\" style=\"background:{wash};color:{color}\">", .{ .color = item.tone.color, .wash = item.tone.wash });
        try icon(w, item.icon);
        try render(w, "</span><span class=\"big\">{big}</span><span class=\"what\">{what}</span></div><p>{text}</p><a href=\"{href}\">{link}</a></article>", .{ .big = item.big, .what = item.what, .text = item.text, .href = item.href, .link = item.link });
    }
    try w.writeAll("</div>");
}

fn deviceShare(ctx: *Ctx, view: data.View, start: i64, end: i64) !f64 {
    const sums = try data.keySums(ctx.arena, ctx.db, view, "device", start, end, 20);
    var total: i64 = 0;
    for (sums) |entry| total += entry.sums.views;
    if (total == 0) return 0;
    return @as(f64, @floatFromInt(data.keySum(sums, "mobile").views + data.keySum(sums, "tablet").views)) / @as(f64, @floatFromInt(total));
}

// ---------------------------------------------------------------- JSON endpoints

/// Visitors matching a filter set, for the filter popover's live count.
pub fn match(ctx: *Ctx, site: data.Site) !void {
    const view = try data.View.parse(ctx.arena, site, ctx.query, ctx.now());
    const matched = try data.totals(ctx.arena, ctx.db, view, view.range.start_ms, view.range.end_ms);
    var unfiltered = view;
    unfiltered.filters = &.{};
    const all = try data.totals(ctx.arena, ctx.db, unfiltered, view.range.start_ms, view.range.end_ms);
    try ctx.w().print("{{\"visitors\":{d},\"total\":{d}}}", .{ matched.visitor_days, all.visitor_days });
    return ctx.json();
}

/// Suggestions for a filter dimension's value box.
pub fn values(ctx: *Ctx, site: data.Site) !void {
    const dim = std.meta.stringToEnum(data.Dim, ctx.param("dim") orelse "") orelse return ctx.text(.bad_request, "unknown dimension\n");
    var view = try data.View.parse(ctx.arena, site, ctx.query, ctx.now());
    view.filters = &.{};
    const rows = try data.top(ctx.arena, ctx.db, view, dim, 40);
    const w = ctx.w();
    try w.writeByte('[');
    for (rows, 0..) |row, index| {
        if (index != 0) try w.writeByte(',');
        try std.json.Stringify.value(row.key, .{}, w);
    }
    try w.writeByte(']');
    return ctx.json();
}

pub fn palette(ctx: *Ctx, site: data.Site) !void {
    const arena = ctx.arena;
    var view = try data.View.parse(arena, site, .{}, ctx.now());
    view.range = data.Range.parse(try html.Params.parse(arena, "range=30d"), ctx.now());
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    var first = true;
    const Item = struct {
        fn write(writer: *std.Io.Writer, is_first: *bool, group: []const u8, item_icon: []const u8, title: []const u8, hint: []const u8, href: []const u8) !void {
            if (!is_first.*) try writer.writeByte(',');
            is_first.* = false;
            try std.json.Stringify.value(.{ .g = group, .i = item_icon, .t = title, .h = hint, .u = href }, .{}, writer);
        }
    };
    try w.writeByte('[');
    const s = site.slug;
    const nav = [_][3][]const u8{
        .{ "Overview", "overview", "" },                   .{ "Dashboards", "dashboards", "/dashboards" },
        .{ "Reports & alerts", "reports", "/reports" },    .{ "Pages", "pages", "/pages" },
        .{ "Acquisition", "sources", "/acquisition" },     .{ "Campaigns", "sources", "/acquisition?tab=campaigns" },
        .{ "Events & goals", "events", "/events" },        .{ "Funnels", "funnels", "/funnels" },
        .{ "Sessions & paths", "paths", "/sessions" },     .{ "Audience", "audience", "/audience" },
        .{ "Performance", "performance", "/performance" }, .{ "Data health", "quality", "/health" },
    };
    for (nav) |entry| try Item.write(w, &first, "Go to", entry[1], entry[0], site.title(), try std.fmt.allocPrint(arena, "/{s}{s}", .{ s, entry[2] }));
    const settings_items = [_][3][]const u8{
        .{ "Website & tracking", "sites", "sites" }, .{ "Team & access", "team", "team" },           .{ "Email delivery", "mail", "email" },
        .{ "Backups", "database", "backups" },       .{ "Data retention", "calendar", "retention" }, .{ "Diagnostics", "stethoscope", "diagnostics" },
        .{ "AI", "sparkles", "ai" },
    };
    for (settings_items) |entry| try Item.write(w, &first, "Settings", entry[1], entry[0], "Settings", try std.fmt.allocPrint(arena, "/settings/{s}?site={s}", .{ entry[2], s }));
    try Item.write(w, &first, "Actions", "plus", "Add a website", "Setup", "/setup");
    try Item.write(w, &first, "Actions", "pin", "Add a note to the chart", "Overview", try std.fmt.allocPrint(arena, "/{s}?dialog=note-dialog", .{s}));
    try Item.write(w, &first, "Actions", "bell-plus", "Create an alert", "Overview", try std.fmt.allocPrint(arena, "/{s}?dialog=alert-dialog", .{s}));
    try Item.write(w, &first, "Actions", "mail", "Schedule an email report", "Overview", try std.fmt.allocPrint(arena, "/{s}?dialog=schedule-dialog", .{s}));
    for (try ctx.visibleSites()) |other| {
        if (other.id == site.id) continue;
        try Item.write(w, &first, "Websites", "sites", other.title(), other.host(), try std.fmt.allocPrint(arena, "/{s}", .{other.slug}));
    }
    for (try data.top(arena, ctx.db, view, .page, 60)) |row| {
        try Item.write(w, &first, "Pages", "pages", row.key, try std.fmt.allocPrint(arena, "{f} views · 30 days", .{html.int(row.value)}), try std.fmt.allocPrint(arena, "/{s}/pages?range=30d&page={f}", .{ s, html.url(row.key) }));
    }
    for (try data.top(arena, ctx.db, view, .source, 20)) |row| {
        try Item.write(w, &first, "Sources", "sources", try sourceLabel(arena, row.key), try std.fmt.allocPrint(arena, "{f} views · 30 days", .{html.int(row.value)}), try std.fmt.allocPrint(arena, "/{s}?range=30d&f=source%3A{f}", .{ s, html.url(row.key) }));
    }
    var statement = try ctx.db.prepare(arena, "SELECT 'Segments','bookmark',name,'Segment','?'||filters FROM segments WHERE site_id=?1 UNION ALL SELECT 'Dashboards','dashboards',name,'Dashboard','/dashboards/'||id FROM dashboards WHERE site_id=?1 UNION ALL SELECT 'Funnels','funnels',name,'Funnel','/funnels/'||id FROM funnels WHERE site_id=?1");
    defer statement.deinit();
    try statement.bindInt(1, site.id);
    while (try statement.step() == .row) {
        try Item.write(w, &first, statement.columnText(0), statement.columnText(1), statement.columnText(2), statement.columnText(3), try std.fmt.allocPrint(arena, "/{s}{s}", .{ s, statement.columnText(4) }));
    }
    try w.writeByte(']');
    try ctx.header("cache-control", "private, max-age=60");
    try ctx.body.writer.writeAll(out.written());
    return ctx.json();
}

// ---------------------------------------------------------------- export

fn csvField(w: *std.Io.Writer, value: []const u8) !void {
    // Leading formula characters are neutralised for spreadsheet safety.
    const risky = value.len != 0 and (value[0] == '=' or value[0] == '+' or value[0] == '-' or value[0] == '@' or value[0] == '\t' or value[0] == '\r');
    if (!risky and std.mem.indexOfAny(u8, value, ",\"\n\r") == null) return w.writeAll(value);
    try w.writeByte('"');
    if (risky) try w.writeByte('\'');
    for (value) |byte| {
        if (byte == '"') try w.writeByte('"');
        try w.writeByte(byte);
    }
    try w.writeByte('"');
}

pub fn exportCsv(ctx: *Ctx, site: data.Site) !void {
    const arena = ctx.arena;
    const view = try data.View.parse(arena, site, ctx.query, ctx.now());
    const source_path = ctx.param("view") orelse "";
    const w = ctx.w();
    const which: data.Dim = if (std.mem.endsWith(u8, source_path, "/pages")) .page else if (std.mem.endsWith(u8, source_path, "/acquisition")) .source else if (std.mem.endsWith(u8, source_path, "/audience")) .device else .page;
    const daily = !(std.mem.endsWith(u8, source_path, "/pages") or std.mem.endsWith(u8, source_path, "/acquisition") or std.mem.endsWith(u8, source_path, "/audience"));
    if (daily) {
        try w.writeAll("period,page_views,visitors,active_seconds\n");
        const views = try data.series(arena, ctx.db, view, .views, view.range.start_ms);
        const visitors = try data.series(arena, ctx.db, view, .visitor_days, view.range.start_ms);
        const active = try data.series(arena, ctx.db, view, .active, view.range.start_ms);
        for (views, 0..) |_, index| {
            const at = view.range.start_ms + @as(i64, @intCast(index)) * view.range.bucket_ms;
            const date = data.dateText(at);
            if (view.range.bucket_ms == data.hour_ms) {
                try w.print("{s}T{d:0>2}:00Z", .{ &date, @as(u64, @intCast(@divFloor(@mod(at, data.day_ms), data.hour_ms))) });
            } else try w.writeAll(&date);
            try w.print(",{d:.0},{d:.0},{d:.0}\n", .{ views[index], visitors[index], active[index] / 1000 });
        }
    } else {
        try w.print("{s},page_views,visitors,previous_page_views\n", .{@tagName(which)});
        for (try data.top(arena, ctx.db, view, which, 1000)) |row| {
            try csvField(w, row.key);
            try w.print(",{d},{d},{d}\n", .{ row.value, row.extra, row.previous });
        }
    }
    const from = data.dateText(view.range.start_ms);
    const to = data.dateText(view.range.end_ms - 1);
    try ctx.header("content-disposition", try std.fmt.allocPrint(arena, "attachment; filename=\"{s}-{s}-{s}.csv\"", .{ site.slug, &from, &to }));
    try ctx.header("cache-control", "no-store");
    return ctx.finish("text/csv; charset=utf-8");
}

// ---------------------------------------------------------------- writes

pub fn addAnnotation(ctx: *Ctx, site: data.Site) !void {
    const day = try ctx.field("day");
    const label = std.mem.trim(u8, try ctx.field("label"), " ");
    _ = data.parseDate(day) catch return failBack(ctx, site, "Pick a valid day for the note.");
    domain.validateText(label, 60, false) catch return failBack(ctx, site, "Notes need a short label (up to 60 characters).");
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    try db.run(ctx.arena, "INSERT INTO annotations(site_id,day,label,created_at_ms) VALUES(?,?,?,?)", .{ site.id, day, label, ctx.now() });
    const id = db.lastInsertRowId();
    try ctx.flash("Note added to the chart.", "Undo", try std.fmt.allocPrint(ctx.arena, "post:/{s}/annotations/{d}/delete", .{ site.slug, id }));
    return ctx.redirect(referer(ctx, site));
}

pub fn keepAnnotation(ctx: *Ctx, site: data.Site, id: i64) !void {
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    try db.run(ctx.arena, "UPDATE annotations SET draft=0 WHERE id=? AND site_id=?", .{ id, site.id });
    return ctx.done("Note kept on the chart.", "{s}", .{referer(ctx, site)});
}

pub fn deleteAnnotation(ctx: *Ctx, site: data.Site, id: i64) !void {
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    try db.run(ctx.arena, "DELETE FROM annotations WHERE id=? AND site_id=?", .{ id, site.id });
    return ctx.done("Note removed.", "{s}", .{referer(ctx, site)});
}

pub fn addSegment(ctx: *Ctx, site: data.Site) !void {
    const name = std.mem.trim(u8, try ctx.field("name"), " ");
    const filters = try ctx.field("filters");
    domain.validateText(name, 60, false) catch return failBack(ctx, site, "Segments need a name.");
    if (filters.len == 0 or filters.len > 2048) return failBack(ctx, site, "Add a filter before saving a segment.");
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    db.run(ctx.arena, "INSERT INTO segments(site_id,name,filters,created_at_ms) VALUES(?,?,?,?) ON CONFLICT(site_id,name) DO UPDATE SET filters=excluded.filters", .{ site.id, name, filters, ctx.now() }) catch return failBack(ctx, site, "That segment could not be saved.");
    return ctx.done(try std.fmt.allocPrint(ctx.arena, "Saved “{s}”. Find it in Filter and ⌘K.", .{name}), "{s}", .{referer(ctx, site)});
}

pub fn deleteSegment(ctx: *Ctx, site: data.Site, id: i64) !void {
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    try db.run(ctx.arena, "DELETE FROM segments WHERE id=? AND site_id=?", .{ id, site.id });
    return ctx.done("Segment deleted.", "{s}", .{referer(ctx, site)});
}

/// Same-origin page the form was posted from, so actions return in place.
pub fn referer(ctx: *Ctx, site: data.Site) []const u8 {
    const value = ctx.field("back") catch "";
    if (value.len != 0 and auth.safeNext(value).ptr == value.ptr) return value;
    if (ctx.head.referer) |raw| {
        if (std.mem.find(u8, raw, "://")) |scheme_end| {
            const rest = raw[scheme_end + 3 ..];
            const slash = std.mem.findScalar(u8, rest, '/') orelse rest.len;
            if (std.ascii.eqlIgnoreCase(rest[0..slash], ctx.head.host) and slash < rest.len) return rest[slash..];
        }
    }
    return std.fmt.allocPrint(ctx.arena, "/{s}", .{site.slug}) catch "/";
}

pub fn failBack(ctx: *Ctx, site: data.Site, text: []const u8) !void {
    return ctx.done(try std.fmt.allocPrint(ctx.arena, "!{s}", .{text}), "{s}", .{referer(ctx, site)});
}
