//! Customers: revenue and products, retention cohorts, and people (identified
//! users and remembered visitors) with their journeys and deletion.
const std = @import("std");
const analyze = @import("analyze.zig");
const audit = @import("audit.zig");
const behaviour = @import("behaviour.zig");
const collector = @import("../collector.zig");
const ctx_mod = @import("ctx.zig");
const data = @import("data.zig");
const db_mod = @import("../db.zig");
const domain = @import("../domain.zig");
const html = @import("html.zig");
const layout = @import("layout.zig");
const ui = @import("ui.zig");
const overview = @import("overview.zig");
const replay = @import("../replay.zig");
const rollups = @import("rollups.zig");
const server = @import("../server.zig");

const Ctx = ctx_mod.Ctx;
const esc = html.esc;
const icon = layout.icon;
const render = html.render;

pub const purchase_names = "('purchase','payment_confirmed')";
pub const refund_names = "('refund','payment_refunded','refund_confirmed')";

/// One row per order: an order ID seen from the server and the browser counts
/// once, and the server's copy wins. The visit comes from whichever copy
/// knows it, usually the browser's.
pub fn ordersCte(sql: *data.Sql, view: data.View, start: i64, end: i64) !void {
    try sql.add("WITH o AS (SELECT * FROM (SELECT coalesce(e.order_id,e.event_id) k,e.source,e.value_minor v,e.currency c,e.received_at_ms t,coalesce(e.session_id,max(e.session_id) OVER w) session_id,coalesce(e.page_id,max(e.page_id) OVER w) page_id,coalesce(e.visitor_id,max(e.visitor_id) OVER w) visitor_id,coalesce(e.user_hash,max(e.user_hash) OVER w) user_hash,e.event_id,e.properties_json,row_number() OVER (w ORDER BY e.source='server' DESC,e.received_at_ms) rn FROM events e WHERE ");
    try sql.events(view, start, end);
    try sql.add(" AND e.name IN " ++ purchase_names ++ " AND e.value_minor IS NOT NULL WINDOW w AS (PARTITION BY coalesce(e.order_id,e.event_id))) WHERE rn=1)");
}

pub const Sales = struct { revenue: i64 = 0, orders: i64 = 0, refunds: i64 = 0 };

pub fn sales(arena: std.mem.Allocator, db: *db_mod.Db, view: data.View, start: i64, end: i64) !Sales {
    var sql = data.Sql.init(arena);
    try ordersCte(&sql, view, start, end);
    try sql.add(" SELECT coalesce(sum(v),0),count(*),coalesce((SELECT sum(abs(e.value_minor)) FROM events e WHERE ");
    try sql.events(view, start, end);
    try sql.add(" AND e.name IN " ++ refund_names ++ " AND e.value_minor IS NOT NULL),0) FROM o");
    var statement = try sql.prepare(db);
    defer statement.deinit();
    _ = try statement.step();
    return .{ .revenue = statement.columnInt(0) - statement.columnInt(2), .orders = statement.columnInt(1), .refunds = statement.columnInt(2) };
}

fn conversionBase(ctx: *Ctx, view: data.View, start: i64, end: i64) !i64 {
    if (view.site.linked()) return data.visits(ctx.arena, ctx.db, view, start, end);
    return (try data.totals(ctx.arena, ctx.db, view, start, end)).visitor_days;
}

fn metricTile(w: *std.Io.Writer, arena: std.mem.Allocator, label: []const u8, value: []const u8, before: []const u8, current: f64, previous: f64, compare: bool, points: bool) !void {
    const delta = current - previous;
    const suffix = try ui.versus(arena, before);
    try ui.metric(w, arena, .{
        .label = label,
        .value = value,
        .change = if (!compare) "" else if (points)
            try std.fmt.allocPrint(arena, "<span class=\"delta {s}\">{s}{d:.1} pts</span>{s}", .{ if (@abs(delta) < 0.05) "delta-flat" else if (delta > 0) "delta-up" else "delta-down", if (delta > 0) "+" else if (delta < 0) "−" else "", @abs(delta), suffix })
        else
            try ui.change(arena, current, previous, false, suffix),
    });
}

// ---------------------------------------------------------------- Revenue

pub fn revenue(ctx: *Ctx, site: data.Site) !void {
    const arena = ctx.arena;
    const view = try analyze.start(ctx, site, .revenue, "Revenue");
    const w = ctx.w();
    const path = try std.fmt.allocPrint(arena, "/{s}/revenue", .{site.slug});
    const range = view.range;
    try layout.head(ctx, .{ .title = "Revenue", .subtitle = try std.fmt.allocPrint(arena, "Orders and products · {f} · {s}", .{ range, site.currency }), .view = view, .path = path });
    const now = try sales(ctx.arena, ctx.db, view, range.start_ms, range.end_ms);
    const before = try sales(ctx.arena, ctx.db, view, range.prev_start_ms, range.prev_end_ms);
    if (now.orders == 0 and before.orders == 0) {
        try w.writeAll("<div class=\"card\">");
        try ui.empty(w, "No orders yet", "Send a <code>purchase</code> event with an amount and items — from the browser with <code>analytico.track('purchase', {}, {value_minor, currency, order_id, items})</code>, or authoritatively from your backend to <code>/i</code>. Server orders win when both arrive.", "");
        try w.writeAll("</div>");
        return layout.end(ctx);
    }
    // Orders per visit; Lite has no visits, so per visitor there.
    const visits_now = try conversionBase(ctx, view, range.start_ms, range.end_ms);
    const visits_before = try conversionBase(ctx, view, range.prev_start_ms, range.prev_end_ms);
    const ratio = struct {
        fn of(a: i64, b: i64) f64 {
            return if (b == 0) 0 else @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b));
        }
    };
    try w.writeAll("<div class=\"metrics\">");
    try metricTile(w, arena, "Revenue", try std.fmt.allocPrint(arena, "{f}", .{html.money(now.revenue, site.currency)}), try std.fmt.allocPrint(arena, "{f}", .{html.money(before.revenue, site.currency)}), @floatFromInt(now.revenue), @floatFromInt(before.revenue), view.compare, false);
    try metricTile(w, arena, "Orders", try std.fmt.allocPrint(arena, "{f}", .{html.int(now.orders)}), try std.fmt.allocPrint(arena, "{f}", .{html.int(before.orders)}), @floatFromInt(now.orders), @floatFromInt(before.orders), view.compare, false);
    const aov_now = if (now.orders == 0) 0 else @divTrunc(now.revenue + now.refunds, now.orders);
    const aov_before = if (before.orders == 0) 0 else @divTrunc(before.revenue + before.refunds, before.orders);
    try metricTile(w, arena, "Average order", try std.fmt.allocPrint(arena, "{f}", .{html.money(aov_now, site.currency)}), try std.fmt.allocPrint(arena, "{f}", .{html.money(aov_before, site.currency)}), @floatFromInt(aov_now), @floatFromInt(aov_before), view.compare, false);
    const rate_now = ratio.of(now.orders, visits_now) * 100;
    const rate_before = ratio.of(before.orders, visits_before) * 100;
    try metricTile(w, arena, "Conversion rate", try std.fmt.allocPrint(arena, "{d:.1}%", .{rate_now}), try std.fmt.allocPrint(arena, "{d:.1}%", .{rate_before}), rate_now, rate_before, view.compare, true);
    try w.writeAll("</div>");

    try w.writeAll("<div class=\"grid split-main mt-16\">");
    try revenueChart(ctx, view);
    try checkout(ctx, view);
    try w.writeAll("</div><div class=\"grid split-main mt-16\">");
    try products(ctx, view);
    try bySource(ctx, view);
    try w.writeAll("</div>");
    return layout.end(ctx);
}

fn revenueChart(ctx: *Ctx, view: data.View) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    const range = view.range;
    const confirmed = try arena.alloc(i64, range.buckets);
    const browser = try arena.alloc(i64, range.buckets);
    @memset(confirmed, 0);
    @memset(browser, 0);
    var sql = data.Sql.init(arena);
    try ordersCte(&sql, view, range.start_ms, range.end_ms);
    try sql.add(" SELECT (t-");
    try sql.int(range.start_ms);
    try sql.add(")/");
    try sql.int(range.bucket_ms);
    try sql.add(",source,sum(v) FROM o GROUP BY 1,2");
    var statement = try sql.prepare(ctx.db);
    defer statement.deinit();
    var peak: i64 = 1;
    while (try statement.step() == .row) {
        const bucket = statement.columnInt(0);
        if (bucket < 0 or bucket >= range.buckets) continue;
        const target = if (std.mem.eql(u8, statement.columnText(1), "server")) confirmed else browser;
        target[@intCast(bucket)] += statement.columnInt(2);
    }
    for (confirmed, browser) |a, b| peak = @max(peak, a + b);
    var best: usize = 0;
    for (confirmed, browser, 0..) |a, b, index| {
        if (a + b > confirmed[best] + browser[best]) best = index;
    }
    var label_buffer: [32]u8 = undefined;
    try render(w, "<section class=\"card\"><div class=\"card-head\"><div><h2>Revenue by day</h2><p class=\"hint\">Best: {best} · {amount}</p></div><div class=\"legend\"><span><i class=\"swatch swatch-violet\"></i>Shop (confirmed)</span><span><i class=\"swatch swatch-violet-pale\"></i>Browser only</span></div></div><div class=\"barchart\">", .{
        .best = range.bucketLong(&label_buffer, best),
        .amount = html.money(confirmed[best] + browser[best], view.site.currency),
    });
    // Long periods label every few days with just the day, naming the month
    // where it starts or changes, so labels fit their narrow columns.
    const every = if (range.buckets <= 14) 1 else @max(1, range.buckets / 10);
    var last_month: u8 = 0;
    for (confirmed, browser, 0..) |a, b, index| {
        var short: [32]u8 = undefined;
        var label: []const u8 = "";
        if (index % every == 0) {
            const date = data.civil(range.start_ms + @as(i64, @intCast(index)) * range.bucket_ms);
            label = if (every == 1 or range.bucket_ms == data.hour_ms) range.bucketLabel(&short, index) else if (date.month != last_month) try std.fmt.bufPrint(&short, "{d} {s}", .{ date.day, data.month_names[date.month - 1] }) else try std.fmt.bufPrint(&short, "{d}", .{date.day});
            last_month = date.month;
        }
        var long: [32]u8 = undefined;
        try render(w, "<div class=\"barchart-col{!best}\" data-tip=\"{day} · {amount}\"><div class=\"barchart-stack\"><span class=\"bar-browser\" style=\"height:{browser:.1}%\"></span><span class=\"bar-confirmed\" style=\"height:{confirmed:.1}%\"></span></div><small>{label}</small></div>", .{
            .best = if (index == best) " best" else "",
            .day = range.bucketLong(&long, index),
            .amount = html.money(a + b, view.site.currency),
            .browser = @as(f64, @floatFromInt(b)) / @as(f64, @floatFromInt(peak)) * 100,
            .confirmed = @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(peak)) * 100,
            .label = label,
        });
    }
    try w.writeAll("</div></section>");
}

/// The standard checkout steps, counted in visits.
fn checkout(ctx: *Ctx, view: data.View) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    const steps = [_][2][]const u8{ .{ "view_item", "Viewed a product" }, .{ "add_to_cart", "Added to cart" }, .{ "begin_checkout", "Started checkout" }, .{ "add_shipping_info", "Shipping" }, .{ "purchase", "Purchased" } };
    const unit = if (view.site.linked()) "coalesce(e.session_id,e.page_id,e.event_id)" else "coalesce(e.page_id,e.event_id)";
    var counts: [steps.len]i64 = undefined;
    for (steps, 0..) |step, index| {
        var sql = data.Sql.init(arena);
        try sql.add("SELECT count(DISTINCT ");
        try sql.add(unit);
        try sql.add(") FROM events e WHERE ");
        try sql.events(view, view.range.start_ms, view.range.end_ms);
        try sql.add(" AND e.name=");
        try sql.str(step[0]);
        var statement = try sql.prepare(ctx.db);
        defer statement.deinit();
        _ = try statement.step();
        counts[index] = statement.columnInt(0);
    }
    var top: i64 = 1;
    for (counts) |value| top = @max(top, value);
    try w.writeAll("<section class=\"card\">");
    try ui.cardHead(w, "Checkout", if (view.site.linked()) "<span class=\"meta\">Sessions</span>" else "<span class=\"meta\">Page views</span>");
    try w.writeAll("<div class=\"rank\">");
    var worst: usize = 0;
    var worst_drop: f64 = 0;
    for (steps, 0..) |step, index| {
        if (index > 0 and counts[index - 1] > 0) {
            const drop = 1 - @as(f64, @floatFromInt(counts[index])) / @as(f64, @floatFromInt(counts[index - 1]));
            if (drop > worst_drop) {
                worst_drop = drop;
                worst = index;
            }
        }
        try ui.rankRow(w, arena, .{ .width = @max(8, @as(f64, @floatFromInt(counts[index])) / @as(f64, @floatFromInt(top)) * 80), .bar = "var(--violet-wash)", .name = step[1], .value = try std.fmt.allocPrint(arena, "{f}", .{html.int(counts[index])}) });
    }
    try w.writeAll("</div>");
    if (worst > 0 and counts[worst - 1] > 0) {
        try render(w, "<p class=\"hint mt-10\">Biggest drop: {from} → {to} ({drop:.0}% leave). ", .{ .from = steps[worst - 1][1], .to = steps[worst][1], .drop = worst_drop * 100 });
        if (view.site.mode == .full) try render(w, "<a class=\"link\" href=\"/{slug}/sessions?event={event}&amp;signal=recorded\">Watch sessions that reached “{step}” →</a>", .{ .slug = view.site.slug, .event = steps[worst - 1][0], .step = steps[worst - 1][1] });
        try w.writeAll("</p>");
    } else if (counts[0] == 0) try w.writeAll("<p class=\"hint mt-10\">Send <code>view_item</code>, <code>add_to_cart</code>, <code>begin_checkout</code> and <code>add_shipping_info</code> events to see where shoppers leave.</p>");
    try w.writeAll("</section>");
}

fn products(ctx: *Ctx, view: data.View) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    var sql = data.Sql.init(arena);
    try sql.add("WITH it AS (SELECT e.name,i.item_id,i.name iname,i.price_minor,i.quantity,e.event_id FROM events e JOIN event_items i ON i.site_id=e.site_id AND i.event_id=e.event_id WHERE ");
    try sql.events(view, view.range.start_ms, view.range.end_ms);
    try sql.add(") SELECT item_id,max(iname),sum(name='view_item'),sum(name='add_to_cart'),count(DISTINCT CASE WHEN name IN " ++ purchase_names ++ " THEN event_id END),coalesce(sum(CASE WHEN name IN " ++ purchase_names ++ " THEN coalesce(price_minor,0)*quantity END),0),coalesce(sum(CASE WHEN name IN " ++ refund_names ++ " THEN coalesce(price_minor,0)*quantity END),0) FROM it GROUP BY item_id ORDER BY 6 DESC,3 DESC LIMIT 20");
    var statement = try sql.prepare(ctx.db);
    defer statement.deinit();
    try w.writeAll("<section class=\"card card-flush\"><div class=\"card-head table-head\"><h2>Products</h2></div><div class=\"table-wrap\"><table class=\"table\"><thead><tr><th>Product</th><th class=\"r hide-m\">Views</th><th class=\"r hide-m\">Add to cart</th><th class=\"r\">Orders</th><th class=\"r\">Revenue</th><th class=\"r hide-m\">Refunds</th></tr></thead><tbody>");
    var any = false;
    while (try statement.step() == .row) {
        any = true;
        try render(w, "<tr><td class=\"strong\">{name}</td><td class=\"r hide-m\">{views}</td><td class=\"r hide-m\">{carts}</td><td class=\"r\">{orders}</td><td class=\"r\">{revenue}</td><td class=\"r hide-m\">", .{ .name = statement.columnText(1), .views = html.int(statement.columnInt(2)), .carts = html.int(statement.columnInt(3)), .orders = html.int(statement.columnInt(4)), .revenue = html.money(statement.columnInt(5), view.site.currency) });
        if (statement.columnInt(6) != 0) try render(w, "{refunds}", .{ .refunds = html.money(statement.columnInt(6), view.site.currency) }) else try w.writeAll("<span class=\"muted\">—</span>");
        try w.writeAll("</td></tr>");
    }
    try w.writeAll("</tbody></table></div>");
    if (!any) try w.writeAll("<p class=\"hint pad-under\">Add <code>items</code> to purchase events to see products.</p>");
    try w.writeAll("<div class=\"card-foot\"><span>Orders from your server (/i) are authoritative; browser-only orders are counted until the server confirms them</span></div></section>");
}

fn bySource(ctx: *Ctx, view: data.View) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    const site = view.site;
    var sql = data.Sql.init(arena);
    try ordersCte(&sql, view, view.range.start_ms, view.range.end_ms);
    // An order belongs to the source of the visit it happened in.
    try sql.add(", a AS (SELECT coalesce((SELECT coalesce(nullif(pv.utm_source,''),nullif(pv.referrer_host,''),'direct') FROM page_views pv WHERE pv.site_id=");
    try sql.int(site.id);
    try sql.add(" AND ((o.session_id IS NOT NULL AND pv.session_id=o.session_id) OR pv.page_id=o.page_id) ORDER BY pv.occurred_at_ms LIMIT 1),json_extract(o.properties_json,'$.source'),'direct') src,o.v FROM o) SELECT src,sum(v),coalesce((SELECT sum(amount_minor) FROM campaign_spend cs WHERE cs.site_id=");
    try sql.int(site.id);
    const from = data.dateText(view.range.start_ms);
    const to = data.dateText(view.range.end_ms - 1);
    try sql.add(" AND cs.source=a.src AND cs.spend_date>=");
    try sql.str(&from);
    try sql.add(" AND cs.spend_date<=");
    try sql.str(&to);
    try sql.add("),0) FROM a GROUP BY src ORDER BY 2 DESC LIMIT 8");
    var statement = try sql.prepare(ctx.db);
    defer statement.deinit();
    try w.writeAll("<section class=\"card\">");
    try ui.cardHead(w, "Revenue by source", "<span class=\"meta\">ROAS</span>");
    try w.writeAll("<div class=\"stack\">");
    const Money = struct { key: []const u8, value: i64, spend: i64 };
    var rows: std.ArrayList(Money) = .empty;
    while (try statement.step() == .row) try rows.append(arena, .{ .key = try arena.dupe(u8, statement.columnText(0)), .value = statement.columnInt(1), .spend = statement.columnInt(2) });
    const keys = try arena.alloc([]const u8, rows.items.len);
    for (rows.items, keys) |row, *key| key.* = row.key;
    const labels = try overview.sourceLabels(arena, keys);
    const any = rows.items.len != 0;
    const top: i64 = if (any) @max(rows.items[0].value, 1) else 1;
    for (rows.items, labels) |row, label| {
        try render(w, "<div class=\"source-money\"><div class=\"row-between\"><div><strong>{source}</strong><small>{revenue}</small></div>", .{ .source = label, .revenue = html.money(row.value, site.currency) });
        if (row.spend > 0) {
            const roas = @as(f64, @floatFromInt(row.value)) / @as(f64, @floatFromInt(row.spend));
            try render(w, "<span class=\"{class}\">{roas:.1}×</span>", .{ .class = if (roas < 2) "warn" else "", .roas = roas });
        } else try w.writeAll("<span class=\"muted\">—</span>");
        try render(w, "</div><div class=\"meter\"><i style=\"width:{width:.0}%\"></i></div></div>", .{ .width = @as(f64, @floatFromInt(row.value)) / @as(f64, @floatFromInt(top)) * 100 });
    }
    if (!any) try w.writeAll("<p class=\"hint\">No orders in this period.</p>");
    try w.writeAll("</div></section>");
}

// ---------------------------------------------------------------- Retention

const week_ms: i64 = 7 * data.day_ms;

/// Monday 00:00 UTC of the week containing `ms`.
fn weekStart(ms: i64) i64 {
    const day = ms - @mod(ms, data.day_ms);
    return day - @as(i64, @intCast(data.weekday(day))) * data.day_ms;
}

fn fullModeNotice(ctx: *Ctx, site: data.Site, what: []const u8) !void {
    const w = ctx.w();
    try w.writeAll("<div class=\"card\">");
    try ui.empty(w, try std.fmt.allocPrint(ctx.arena, "{s} need Full mode", .{what}), "Lite and Session never remember a visitor from one day to the next. Full mode does — only for visitors who consent, or don’t need to under your consent policy.", if (ctx.can(.admin)) try html.print(ctx.arena, "<a class=\"btn btn-primary\" href=\"/settings/sites?site={slug}\">Switch to Full mode</a>", .{ .slug = site.slug }) else "");
    try w.writeAll("</div>");
}

pub fn retention(ctx: *Ctx, site: data.Site) !void {
    const arena = ctx.arena;
    const view = try analyze.start(ctx, site, .retention, "Retention");
    const w = ctx.w();
    const path = try std.fmt.allocPrint(arena, "/{s}/retention", .{site.slug});
    try layout.head(ctx, .{ .title = "Retention", .subtitle = "Who comes back, and what brought them", .view = view, .path = path, .fixed_period = "Last 8 weeks · updated daily", .fixed_why = "Retention follows each week’s visitors for 8 weeks, so it doesn’t use the date range." });
    if (site.mode != .full) {
        try fullModeNotice(ctx, site, "Returning visitors and cohorts");
        return layout.end(ctx);
    }
    const now = ctx.now();
    const origin = weekStart(now) - 7 * week_ms;
    const remembered = try ctx.db.scalar(arena, i64, "SELECT count(*) FROM visitors WHERE site_id=? AND last_seen_ms>=?", .{ site.id, origin });
    const share = (try @import("app.zig").consentShare(ctx, site)) orelse 0;
    try w.writeAll("<div class=\"callout mb-16\">");
    try icon(w, "shield-check");
    try render(w, "<span>Based on {remembered} visitors who are remembered ({share:.0}% of page views in the last 7 days). Visitors in Lite, who declined or send Global Privacy Control are counted, but never followed across days.</span>", .{ .remembered = html.int(remembered), .share = share * 100 });
    if (ctx.can(.admin)) try render(w, "<a class=\"link ml-auto nobreak\" href=\"/settings/sites?site={slug}\">Consent settings →</a>", .{ .slug = site.slug });
    try w.writeAll("</div>");

    try retentionBody(arena, try retentionData(arena, ctx.shared, ctx.db, site.id, now), w);
    return layout.end(ctx);
}

/// The last eight weeks of remembered visitors: active and returning per
/// week, who comes back by first source, and weekly cohorts. Computed once a
/// day: counting every remembered visitor's weeks takes seconds on a big
/// site, and the weeks change slowly. The workspace and the apps read the
/// same cached numbers; the background job computes them just after
/// midnight, or the first view of the day does.
pub const Retention = struct {
    pub const Back = struct { label: []const u8, total: i64, back: i64 };
    /// The first week's Monday, "2026-08-17".
    first_week: []const u8,
    active: [8]i64,
    returning: [8]i64,
    sources: []const Back,
    /// cohorts[c][o]: of week c's new visitors, how many were active o weeks later.
    cohorts: [8][8]i64,
};

pub fn retentionData(arena: std.mem.Allocator, shared: *server.Shared, db: *db_mod.Db, site_id: i64, now: i64) !Retention {
    const day = data.dateText(now);
    if (try db.scalar(arena, ?[]const u8, "SELECT value FROM cache WHERE site_id=? AND name='retention' AND day=?", .{ site_id, &day })) |cached| {
        if (std.json.parseFromSliceLeaky(Retention, arena, cached, .{})) |value| return value else |_| {}
    }
    const value = try computeRetention(arena, db, site_id, now);
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(value, .{}, &out.writer);
    const write = shared.lockWrite();
    defer shared.unlockWrite();
    try write.run(arena, "INSERT INTO cache(site_id,name,day,value) VALUES(?,'retention',?,?) ON CONFLICT DO UPDATE SET day=excluded.day,value=excluded.value", .{ site_id, &day, out.written() });
    return value;
}

fn computeRetention(arena: std.mem.Allocator, db: *db_mod.Db, site_id: i64, now: i64) !Retention {
    const origin = weekStart(now) - 7 * week_ms;
    var out: Retention = .{ .first_week = try arena.dupe(u8, &data.dateText(origin)), .active = @splat(0), .returning = @splat(0), .sources = &.{}, .cohorts = @splat(@splat(0)) };
    // Active visitors per week, split into new and returning: summarised
    // weeks plus the raw rows of days not summarised yet.
    const origin_week = rollups.weekIndex(origin);
    const rolled = try data.rolledUntil(arena, db, site_id);
    const weeks_cte = "WITH w AS (SELECT week,visitor_id FROM visitor_weeks WHERE site_id=?1 AND week>=?3 UNION SELECT (received_at_ms/86400000+3)/7,visitor_id FROM page_views WHERE site_id=?1 AND received_at_ms>=max(?2,?4) AND visitor_id IS NOT NULL AND internal=0)";
    var weekly = try db.prepare(arena, weeks_cte ++
        \\ SELECT w.week-?3,count(*),sum(v.first_seen_ms<(w.week*7-3)*86400000) FROM w JOIN visitors v ON v.site_id=?1 AND v.visitor_id=w.visitor_id GROUP BY w.week
    );
    defer weekly.deinit();
    try weekly.bindAll(.{ site_id, origin, origin_week, rolled });
    while (try weekly.step() == .row) {
        const index = weekly.columnInt(0);
        if (index < 0 or index >= 8) continue;
        out.active[@intCast(index)] = weekly.columnInt(1);
        out.returning[@intCast(index)] = weekly.columnInt(2);
    }

    // Who comes back: visitors first seen 4 to 8 weeks ago (so each had the
    // full 4 weeks to return), by first source, merged by display name.
    var sources = try db.prepare(arena,
        \\SELECT v.first_source,count(*),sum(EXISTS(SELECT 1 FROM visitor_weeks x WHERE x.site_id=v.site_id AND x.visitor_id=v.visitor_id AND x.week>(v.first_seen_ms/86400000+3)/7 AND x.week<=(v.first_seen_ms/86400000+3)/7+4))
        \\FROM visitors v WHERE v.site_id=? AND v.first_seen_ms>=? AND v.first_seen_ms<? GROUP BY 1
    );
    defer sources.deinit();
    try sources.bindAll(.{ site_id, origin, now - 4 * week_ms });
    var backs: std.ArrayList(Retention.Back) = .empty;
    collect: while (try sources.step() == .row) {
        const label = try overview.sourceLabel(arena, sources.columnText(0));
        for (backs.items) |*entry| if (std.mem.eql(u8, entry.label, label)) {
            entry.total += sources.columnInt(1);
            entry.back += sources.columnInt(2);
            continue :collect;
        };
        try backs.append(arena, .{ .label = label, .total = sources.columnInt(1), .back = sources.columnInt(2) });
    }
    const byRate = struct {
        fn less(_: void, a: Retention.Back, b: Retention.Back) bool {
            if (a.back * b.total != b.back * a.total) return a.back * b.total > b.back * a.total;
            return a.total > b.total;
        }
    }.less;
    std.mem.sort(Retention.Back, backs.items, {}, byRate);
    out.sources = backs.items[0..@min(6, backs.items.len)];

    // Weekly cohorts.
    var cohorts = try db.prepare(arena, weeks_cte ++
        \\, v AS (SELECT visitor_id,(first_seen_ms/86400000+3)/7-?3 cw FROM visitors WHERE site_id=?1 AND first_seen_ms>=?2)
        \\SELECT v.cw,w.week-?3-v.cw,count(*) FROM v JOIN w ON w.visitor_id=v.visitor_id WHERE w.week-?3>=v.cw GROUP BY 1,2
    );
    defer cohorts.deinit();
    try cohorts.bindAll(.{ site_id, origin, origin_week, rolled });
    while (try cohorts.step() == .row) {
        const cohort = cohorts.columnInt(0);
        const offset = cohorts.columnInt(1);
        if (cohort < 0 or cohort >= 8 or offset < 0 or offset >= 8) continue;
        out.cohorts[@intCast(cohort)][@intCast(offset)] = cohorts.columnInt(2);
    }
    return out;
}

fn retentionBody(arena: std.mem.Allocator, numbers: Retention, w: *std.Io.Writer) !void {
    const origin = try data.parseDate(numbers.first_week);
    const active = numbers.active;
    const returning = numbers.returning;
    var peak: i64 = 1;
    for (active) |value| peak = @max(peak, value);
    const last_share = if (active[7] == 0) 0 else @as(f64, @floatFromInt(returning[7])) / @as(f64, @floatFromInt(active[7])) * 100;
    try render(w, "<div class=\"grid split-main\"><section class=\"card\"><div class=\"card-head\"><div><h2>New and returning visitors</h2><p class=\"hint\">Returning visitors are {share:.0}% of this week.</p></div><div class=\"legend\"><span><i class=\"swatch swatch-blue\"></i>Returning</span><span><i class=\"swatch swatch-blue-pale\"></i>New</span></div></div><div class=\"barchart\">", .{ .share = last_share });
    for (active, returning, 0..) |total, back, index| {
        const date = data.civil(origin + @as(i64, @intCast(index)) * week_ms);
        const percent = if (total == 0) 0 else @as(f64, @floatFromInt(back)) / @as(f64, @floatFromInt(total)) * 100;
        try render(w, "<div class=\"barchart-col{!best}\" data-tip=\"Week of {day} {month} · {total} visitors, {back} returning\"><div class=\"barchart-stack\"><span class=\"bar-new\" style=\"height:{new:.1}%\"></span><span class=\"bar-returning\" style=\"height:{returning:.1}%\">{percent}</span></div><small>{day} {month}</small></div>", .{
            .best = if (index == 7) " best" else "",
            .total = total,
            .back = back,
            .new = @as(f64, @floatFromInt(total - back)) / @as(f64, @floatFromInt(peak)) * 100,
            .returning = @as(f64, @floatFromInt(back)) / @as(f64, @floatFromInt(peak)) * 100,
            .percent = if (total > 0) try std.fmt.allocPrint(arena, "{d:.0}%", .{percent}) else "",
            .day = date.day,
            .month = data.month_names[date.month - 1],
        });
    }
    try w.writeAll("</div></section>");
    try w.writeAll("<section class=\"card\"><div class=\"card-head\"><div><h2>Who comes back</h2><p class=\"hint\">Came back within 4 weeks of their first visit, by first source</p></div></div><div class=\"stack\">");
    for (numbers.sources) |entry| {
        const rate = @as(f64, @floatFromInt(entry.back)) / @as(f64, @floatFromInt(@max(1, entry.total))) * 100;
        try render(w, "<div class=\"source-money\"><div class=\"row-between\"><strong>{label}</strong><span>{rate:.0}% <span class=\"hint\">of {total}</span></span></div><div class=\"meter blue\"><i style=\"width:{rate:.0}%\"></i></div></div>", .{ .label = entry.label, .rate = rate, .total = html.int(entry.total) });
    }
    if (numbers.sources.len == 0) try w.writeAll("<p class=\"hint\">Shows once visitors first seen at least 4 weeks ago have had time to come back.</p>");
    try w.writeAll("</div></section></div>");
    try w.writeAll("<section class=\"card mt-16\"><div class=\"card-head\"><div><h2>Weekly cohorts</h2><p class=\"hint\">Share of each week’s new visitors who came back in the weeks after</p></div></div><div class=\"table-wrap\"><table class=\"cohorts\"><thead><tr><th>Week</th><th class=\"r\">New visitors</th>");
    for (0..8) |index| try render(w, "<th>Week {n}</th>", .{ .n = index });
    try w.writeAll("</tr></thead><tbody>");
    for (numbers.cohorts, 0..) |row, cohort| {
        const date = data.civil(origin + @as(i64, @intCast(cohort)) * week_ms);
        try render(w, "<tr><td>{day} {month}</td><td class=\"r\">{new}</td>", .{ .day = date.day, .month = data.month_names[date.month - 1], .new = html.int(row[0]) });
        for (row, 0..) |value, offset| {
            if (cohort + offset > 7 or row[0] == 0) {
                try w.writeAll("<td></td>");
                continue;
            }
            if (offset == 0) {
                try w.writeAll("<td><span class=\"cell zero\">100%</span></td>");
                continue;
            }
            const rate = @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(row[0]));
            if (value == 0) {
                try w.writeAll("<td><span class=\"cell zero\">0%</span></td>");
                continue;
            }
            try render(w, "<td><span class=\"cell\" style=\"background:rgba(0,87,174,{alpha:.2})\">{rate:.0}%</span></td>", .{ .alpha = @min(0.5, 0.06 + rate * 1.2), .rate = rate * 100 });
        }
        try w.writeAll("</tr>");
    }
    try w.writeAll("</tbody></table></div></section>");
}

// ---------------------------------------------------------------- People

const Segment = enum { everyone, customers, identified, new, at_risk };

/// A person is an identified user (all their visitors) or one visitor.

pub fn people(ctx: *Ctx, site: data.Site) !void {
    const arena = ctx.arena;
    const view = try analyze.start(ctx, site, .people, "People");
    const w = ctx.w();
    const path = try std.fmt.allocPrint(arena, "/{s}/people", .{site.slug});
    if (site.mode != .full) {
        try layout.head(ctx, .{ .title = "People", .subtitle = "Identified users and remembered visitors" });
        try fullModeNotice(ctx, site, "People");
        return layout.end(ctx);
    }
    const range = view.range;
    const identified = try ctx.db.scalar(arena, i64, "SELECT count(DISTINCT user_hash) FROM visitors WHERE site_id=? AND user_hash IS NOT NULL AND last_seen_ms>=?", .{ site.id, range.start_ms });
    const remembered = try ctx.db.scalar(arena, i64, "SELECT count(*) FROM visitors WHERE site_id=? AND last_seen_ms>=?", .{ site.id, range.start_ms });
    try layout.head(ctx, .{ .title = "People", .subtitle = try std.fmt.allocPrint(arena, "{f} identified · {f} remembered visitors · {f}", .{ html.int(identified), html.int(remembered), range }), .view = view, .path = path, .compare = false, .filter = false });

    const query = std.mem.trim(u8, ctx.param("q") orelse "", " ");
    const segment = std.meta.stringToEnum(Segment, ctx.param("segment") orelse "everyone") orelse .everyone;
    try render(w, "<form class=\"row mb-14\" method=\"get\" action=\"{path}\">", .{ .path = path });
    try layout.hiddenState(ctx, view, &.{});
    try w.writeAll("<label class=\"row search-box search-box-wide\"><span class=\"search-icon\">");
    try icon(w, "search");
    try render(w, "</span><input class=\"input\" type=\"search\" name=\"q\" value=\"{query}\" placeholder=\"Find by user ID…\" aria-label=\"Find by user ID\"></label>", .{ .query = query });
    const segments = [_][2][]const u8{ .{ "everyone", "Everyone" }, .{ "customers", "Customers" }, .{ "identified", "Identified only" }, .{ "new", "New this period" }, .{ "at_risk", "At risk" } };
    for (segments) |item| try render(w, "<a class=\"chip{!plain}\" href=\"{href}\">{label}</a>", .{
        .plain = if (std.mem.eql(u8, item[0], @tagName(segment))) "" else " chip-plain",
        .href = try view.href(arena, path, &.{.{ "segment", if (std.mem.eql(u8, item[0], "everyone")) "" else item[0] }}),
        .label = item[1],
    });
    try w.writeAll("</form>");

    // People active in the period, with every visitor that is the same person
    // (by user ID); then each measure in one indexed join over those visitors.
    // CROSS JOIN keeps those visitors outermost: with the site bound as a
    // parameter, SQLite would otherwise scan every page view and event.
    // Without a search, the 2,000 visitors seen last (and their other devices)
    // are enough for the list, straight from the last-seen index.
    var sql = data.Sql.init(arena);
    if (query.len == 0) {
        try sql.add("WITH recent AS MATERIALIZED (SELECT visitor_id,user_hash FROM visitors WHERE site_id=");
        try sql.int(site.id);
        try sql.add(" AND last_seen_ms>=");
        try sql.int(range.start_ms);
        try sql.add(" ORDER BY last_seen_ms DESC LIMIT 2000),v AS MATERIALIZED (SELECT visitor_id,coalesce(user_hash,visitor_id) k,user_hash,first_seen_ms,last_seen_ms,first_source FROM visitors WHERE site_id=");
        try sql.int(site.id);
        try sql.add(" AND visitor_id IN (SELECT visitor_id FROM recent) UNION SELECT visitor_id,user_hash,user_hash,first_seen_ms,last_seen_ms,first_source FROM visitors WHERE site_id=");
        try sql.int(site.id);
        try sql.add(" AND user_hash IN (SELECT user_hash FROM recent WHERE user_hash IS NOT NULL)");
    } else {
        try sql.add("WITH v AS MATERIALIZED (SELECT visitor_id,coalesce(user_hash,visitor_id) k,user_hash,first_seen_ms,last_seen_ms,first_source FROM visitors WHERE site_id=");
        try sql.int(site.id);
        try sql.add(" AND (last_seen_ms>=");
        try sql.int(range.start_ms);
        try sql.add(" OR user_hash IN (SELECT user_hash FROM visitors WHERE site_id=");
        try sql.int(site.id);
        try sql.add(" AND last_seen_ms>=");
        try sql.int(range.start_ms);
        try sql.add(" AND user_hash IS NOT NULL))");
    }
    if (query.len != 0) {
        // People are found by the ID from your app (hashed the same way) or a visitor ID.
        const hash = domain.userHash(ctx.shared.master_key, site.public_id, query);
        try sql.add(" AND (user_hash=");
        try sql.str(try arena.dupe(u8, &hash));
        try sql.add(" OR visitor_id LIKE ");
        try sql.str(try std.fmt.allocPrint(arena, "{s}%", .{query}));
        try sql.add(")");
    }
    try sql.add("), p AS MATERIALIZED (SELECT k,max(user_hash) u,min(first_seen_ms) f,max(last_seen_ms) l,count(*) devices FROM v GROUP BY k ORDER BY l DESC LIMIT 2000)," ++
        "pv AS MATERIALIZED (SELECT v.* FROM v WHERE v.k IN (SELECT k FROM p))," ++
        "src AS (SELECT k,first_source FROM (SELECT k,first_source,row_number() OVER (PARTITION BY k ORDER BY first_seen_ms) rn FROM pv) WHERE rn=1)," ++
        "s AS (SELECT x.k,count(DISTINCT w.session_id) sessions,group_concat(DISTINCT w.operating_system) systems FROM pv x CROSS JOIN page_views w ON w.site_id=");
    try sql.int(site.id);
    // An order seen from both the browser and the server counts once.
    try sql.add(" AND w.visitor_id=x.visitor_id GROUP BY x.k),r AS (SELECT k,sum(v) revenue FROM (SELECT k,o,max(v) v FROM (SELECT x.k,coalesce(e.order_id,e.event_id) o,e.value_minor v FROM pv x CROSS JOIN events e ON e.site_id=");
    try sql.int(site.id);
    try sql.add(" AND e.visitor_id=x.visitor_id WHERE e.name IN " ++ purchase_names ++ " AND e.value_minor IS NOT NULL UNION ALL SELECT p.k,coalesce(e.order_id,e.event_id),e.value_minor FROM p CROSS JOIN events e ON e.site_id=");
    try sql.int(site.id);
    try sql.add(" AND e.user_hash=p.u WHERE p.u IS NOT NULL AND e.user_hash IS NOT NULL AND e.name IN " ++ purchase_names ++ " AND e.value_minor IS NOT NULL) GROUP BY k,o) GROUP BY k),er AS (SELECT x.k,count(*) n FROM errors e JOIN pv x ON x.visitor_id=e.visitor_id WHERE e.site_id=");
    try sql.int(site.id);
    try sql.add(" AND e.received_at_ms>=");
    try sql.int(range.start_ms);
    try sql.add(" GROUP BY x.k) SELECT p.k,coalesce(p.u,''),p.f,p.l,p.devices,coalesce(src.first_source,'direct'),coalesce(s.sessions,0) sessions,coalesce(r.revenue,0) revenue,coalesce(s.systems,''),coalesce(er.n,0) FROM p LEFT JOIN src USING(k) LEFT JOIN s USING(k) LEFT JOIN r USING(k) LEFT JOIN er USING(k) WHERE p.l>=");
    try sql.int(range.start_ms);
    switch (segment) {
        .everyone => {},
        .customers => try sql.add(" AND revenue>0"),
        .identified => try sql.add(" AND p.u IS NOT NULL"),
        .new => {
            try sql.add(" AND p.f>=");
            try sql.int(range.start_ms);
        },
        .at_risk => {
            try sql.add(" AND sessions>=3 AND p.l<");
            try sql.int(ctx.now() - 14 * data.day_ms);
        },
    }
    try sql.add(" ORDER BY p.l DESC LIMIT 100");
    var statement = try sql.prepare(ctx.db);
    defer statement.deinit();
    try w.writeAll("<section class=\"card card-flush\"><div class=\"table-wrap\"><table class=\"table\"><thead><tr><th>Person</th><th class=\"hide-m\">First seen</th><th>Last seen</th><th class=\"r hide-m\">Sessions</th><th class=\"r hide-m\">Devices</th><th class=\"r\">Revenue</th><th class=\"hide-m\">First source</th><th class=\"hide-m\">Signals</th></tr></thead><tbody>");
    var any = false;
    while (try statement.step() == .row) {
        any = true;
        const key = statement.columnText(0);
        const user = statement.columnText(1);
        const href = try std.fmt.allocPrint(arena, "/{s}/people/{s}", .{ site.slug, key });
        const label = try behaviour.personLabel(arena, key, user);
        const first = statement.columnInt(2);
        const sessions_count = statement.columnInt(6);
        const revenue_value = statement.columnInt(7);
        try render(w, "<tr data-href=\"{href}\"><td><a href=\"{href}\" class=\"row nowrap\"><span class=\"person-avatar{!anonymous}\">{initials}</span><span><strong class=\"block\">{label}</strong><small class=\"secondary\">{kind} · {systems}</small></span></a></td><td class=\"hide-m secondary\">{first}</td><td class=\"secondary\">{last}</td><td class=\"r hide-m\">{sessions}</td><td class=\"r hide-m\">{devices}</td><td class=\"r\">", .{
            .href = href,
            .anonymous = if (user.len == 0) " anonymous" else "",
            .initials = if (user.len == 0) "··" else user[0..2],
            .label = label,
            .kind = if (user.len == 0) "remembered · not identified" else "identified",
            .systems = try data.prettyList(arena, statement.columnText(8)),
            .first = data.ago(first, ctx.now()),
            .last = data.ago(statement.columnInt(3), ctx.now()),
            .sessions = sessions_count,
            .devices = statement.columnInt(4),
        });
        if (revenue_value != 0) try render(w, "{revenue}", .{ .revenue = html.money(revenue_value, site.currency) }) else try w.writeAll("<span class=\"muted\">—</span>");
        try render(w, "</td><td class=\"hide-m secondary\">{source}</td><td class=\"hide-m\">", .{ .source = try overview.sourceLabel(arena, statement.columnText(5)) });
        if (statement.columnInt(9) > 0) {
            try w.writeAll("<span class=\"pill pill-bad\">Hit an error</span>");
        } else if (sessions_count >= 3 and statement.columnInt(3) < ctx.now() - 14 * data.day_ms) {
            try w.writeAll("<span class=\"pill pill-warn\">At risk</span>");
        } else if (first >= range.start_ms) {
            try w.writeAll("<span class=\"pill pill-blue\">New</span>");
        } else if (revenue_value > 0) {
            try w.writeAll("<span class=\"pill pill-good\">Customer</span>");
        } else if (sessions_count >= 10) try w.writeAll("<span class=\"pill pill-good\">Loyal</span>");
        try w.writeAll("</td></tr>");
    }
    try w.writeAll("</tbody></table></div>");
    if (!any) try ui.empty(w, if (query.len != 0) "Nobody matches" else "Nobody here yet", if (query.len != 0) "Search by the user ID your app passes to <code>analytico.identify()</code>, or the start of a visitor ID." else "Visitors appear once they consent (or don’t need to). Call <code>analytico.identify(userId)</code> after sign-in to link their devices.", "");
    try w.writeAll("<div class=\"card-foot\"><span>User IDs are stored only as a keyed hash; names and emails are never stored</span></div></section>");
    return layout.end(ctx);
}

const Person = struct { key: []const u8, user_hash: []const u8, visitors: []const []const u8 };

fn loadPerson(ctx: *Ctx, site: data.Site, key: []const u8) !?Person {
    var statement = try ctx.db.prepare(ctx.arena, "SELECT visitor_id,coalesce(user_hash,'') FROM visitors WHERE site_id=? AND (user_hash=?2 OR (visitor_id=?2 AND user_hash IS NULL)) ORDER BY first_seen_ms");
    defer statement.deinit();
    try statement.bindInt(1, site.id);
    try statement.bindText(2, key);
    var visitors: std.ArrayList([]const u8) = .empty;
    var user_hash: []const u8 = "";
    while (try statement.step() == .row) {
        try visitors.append(ctx.arena, try ctx.arena.dupe(u8, statement.columnText(0)));
        user_hash = try ctx.arena.dupe(u8, statement.columnText(1));
    }
    if (visitors.items.len == 0) {
        // A visitor ID that has since been identified opens its person.
        var linked = try ctx.db.prepare(ctx.arena, "SELECT user_hash FROM visitors WHERE site_id=? AND visitor_id=? AND user_hash IS NOT NULL");
        defer linked.deinit();
        try linked.bindInt(1, site.id);
        try linked.bindText(2, key);
        if (try linked.step() == .row) return loadPerson(ctx, site, try ctx.arena.dupe(u8, linked.columnText(0)));
        return null;
    }
    return .{ .key = key, .user_hash = user_hash, .visitors = visitors.items };
}

/// SQL list of the person's visitor IDs, bound as text parameters.
fn visitorList(sql: *data.Sql, someone: Person) !void {
    try sql.add("(");
    for (someone.visitors, 0..) |visitor, index| {
        if (index != 0) try sql.add(",");
        try sql.str(visitor);
    }
    try sql.add(")");
}

pub fn person(ctx: *Ctx, site: data.Site, key: []const u8) !void {
    const arena = ctx.arena;
    const view = try data.View.parse(arena, site, ctx.query, ctx.now());
    const found = try loadPerson(ctx, site, key) orelse return layout.message(ctx, .not_found, "Person not found", "They may have been deleted on request, or never consented to be remembered.");
    if (ctx.param("format")) |format| if (std.mem.eql(u8, format, "json")) return exportPerson(ctx, site, found);
    const w = ctx.w();
    const label = try behaviour.personLabel(arena, found.visitors[0], found.user_hash);

    var totals_sql = data.Sql.init(arena);
    try totals_sql.add("SELECT count(DISTINCT session_id),min(received_at_ms),max(received_at_ms),max(city),max(country) FROM page_views WHERE site_id=");
    try totals_sql.int(site.id);
    try totals_sql.add(" AND visitor_id IN ");
    try visitorList(&totals_sql, found);
    var totals = try totals_sql.prepare(ctx.db);
    defer totals.deinit();
    _ = try totals.step();
    var money_sql = data.Sql.init(arena);
    // An order seen from both the browser and the server counts once.
    try money_sql.add("SELECT coalesce(sum(v),0),count(*) FROM (SELECT coalesce(order_id,event_id) o,max(value_minor) v FROM events WHERE site_id=");
    try money_sql.int(site.id);
    try money_sql.add(" AND name IN " ++ purchase_names ++ " AND (visitor_id IN ");
    try visitorList(&money_sql, found);
    if (found.user_hash.len != 0) {
        try money_sql.add(" OR user_hash=");
        try money_sql.str(found.user_hash);
    }
    try money_sql.add(") GROUP BY o)");
    var money = try money_sql.prepare(ctx.db);
    defer money.deinit();
    _ = try money.step();

    try layout.begin(ctx, try @import("app.zig").shell(ctx, site, .people, label, view));
    var extra: std.Io.Writer.Allocating = .init(arena);
    if (ctx.can(.admin)) {
        try render(&extra.writer, "<a class=\"btn\" href=\"/{slug}/people/{key}?format=json\" download>Export data</a>", .{ .slug = site.slug, .key = key });
    }
    const first = data.civil(totals.columnInt(1));
    const place = if (totals.columnText(3).len != 0) try std.fmt.allocPrint(arena, " · {s}, {s}", .{ totals.columnText(3), totals.columnText(4) }) else if (totals.columnText(4).len != 0) try std.fmt.allocPrint(arena, " · {s}", .{totals.columnText(4)}) else "";
    try layout.head(ctx, .{ .title = label, .subtitle = try std.fmt.allocPrint(arena, "Remembered since {d} {s} {d}{s} · {d} device{s}{s}", .{ first.day, data.month_names[first.month - 1], first.year, if (found.user_hash.len != 0) " · identified" else "", found.visitors.len, if (found.visitors.len == 1) "" else "s", place }), .extra = extra.written() });
    try w.writeAll("<div class=\"grid split-person\"><div class=\"stack\"><div class=\"grid grid-4\">");
    try ui.stat(w, "Sessions", try std.fmt.allocPrint(arena, "{d}", .{totals.columnInt(0)}), "");
    try ui.stat(w, "Revenue", try std.fmt.allocPrint(arena, "{f}", .{html.money(money.columnInt(0), site.currency)}), "");
    try ui.stat(w, "Orders", try std.fmt.allocPrint(arena, "{d}", .{money.columnInt(1)}), "");
    try render(w, "<div class=\"card\"><div class=\"hint ink-2\">Last seen</div><div class=\"metric-value metric-value-s\">{ago}</div></div></div>", .{ .ago = data.ago(totals.columnInt(2), ctx.now()) });

    // Journey: sessions across every device, newest first.
    var journey_sql = data.Sql.init(arena);
    try journey_sql.add("SELECT pv.session_id,min(pv.received_at_ms),max(pv.received_at_ms),max(pv.device),max(pv.browser),max(pv.operating_system),(SELECT group_concat(p,' → ') FROM (SELECT x.path p FROM page_views x WHERE x.site_id=pv.site_id AND x.session_id=pv.session_id ORDER BY x.occurred_at_ms LIMIT 4)),(SELECT coalesce(nullif(x.utm_source,''),nullif(x.referrer_host,''),'direct') FROM page_views x WHERE x.site_id=pv.site_id AND x.session_id=pv.session_id ORDER BY x.occurred_at_ms LIMIT 1),(SELECT count(*) FROM events e WHERE e.site_id=pv.site_id AND e.session_id=pv.session_id AND e.name='rage_click'),(SELECT count(*) FROM errors x WHERE x.site_id=pv.site_id AND x.session_id=pv.session_id),(SELECT sum(o.v) FROM (SELECT max(e.value_minor) v FROM events e WHERE e.site_id=pv.site_id AND e.session_id=pv.session_id AND e.name IN " ++ purchase_names ++ " GROUP BY coalesce(e.order_id,e.event_id)) o),EXISTS(SELECT 1 FROM rp.replays r WHERE r.site_id=pv.site_id AND r.session_id=pv.session_id),(SELECT g.name FROM goals g JOIN events e ON e.site_id=g.site_id AND e.name=g.match_value AND g.kind='event' WHERE g.site_id=pv.site_id AND e.session_id=pv.session_id LIMIT 1) FROM page_views pv WHERE pv.site_id=");
    try journey_sql.int(site.id);
    try journey_sql.add(" AND pv.visitor_id IN ");
    try visitorList(&journey_sql, found);
    try journey_sql.add(" AND pv.session_id IS NOT NULL GROUP BY pv.session_id ORDER BY 2 DESC LIMIT 50");
    var journey = try journey_sql.prepare(ctx.db);
    defer journey.deinit();
    try w.writeAll("<section class=\"card\">");
    try ui.cardHead(w, "Journey", "<span class=\"meta\">Across all devices · newest first</span>");
    try w.writeAll("<div class=\"journey\">");
    var first_row = true;
    while (try journey.step() == .row) {
        const sid = journey.columnText(0);
        const trouble = journey.columnInt(8) > 0 or journey.columnInt(9) > 0;
        try render(w, "<div class=\"journey-item{!trouble}\"><span class=\"journey-dot{!now}\"></span><div class=\"journey-card\"><div class=\"row-between\"><strong>{when}</strong><span class=\"hint\">{system} · {browser} · via {source} · {length}</span></div><p class=\"mono my-8\">{path}</p><div class=\"row-between\"><span class=\"row gap-6\">", .{
            .trouble = if (trouble) " trouble" else "",
            .now = if (first_row) " now" else "",
            .when = data.clock(journey.columnInt(1), ctx.now()),
            .system = capitalized(arena, journey.columnText(5)),
            .browser = capitalized(arena, journey.columnText(4)),
            .source = try overview.sourceLabel(arena, journey.columnText(7)),
            .length = html.duration(journey.columnInt(2) - journey.columnInt(1)),
            .path = journey.columnText(6),
        });
        first_row = false;
        if (journey.columnInt(8) > 0) try w.writeAll("<span class=\"pill pill-brand\">Rage click</span>");
        if (journey.columnInt(9) > 0) try w.writeAll("<span class=\"pill pill-bad\">JS error</span>");
        if (journey.columnType(10) != db_mod.sqlite.SQLITE_NULL) try render(w, "<span class=\"pill pill-good\">Purchased {amount}</span>", .{ .amount = html.money(journey.columnInt(10), site.currency) }) else if (journey.columnText(12).len != 0) try render(w, "<span class=\"pill pill-good\">{goal}</span>", .{ .goal = journey.columnText(12) });
        try w.writeAll("</span>");
        if (journey.columnBool(11)) {
            try render(w, "<a class=\"btn btn-small\" href=\"/{slug}/replays/{sid}\">", .{ .slug = site.slug, .sid = sid });
            try icon(w, "play");
            try w.writeAll("Replay</a>");
        } else try render(w, "<a class=\"link\" href=\"/{slug}/replays/{sid}\">Timeline →</a>", .{ .slug = site.slug, .sid = sid });
        try w.writeAll("</div></div></div>");
    }
    try w.writeAll("</div></section></div>");

    // Identity, consent and deletion.
    try w.writeAll("<aside class=\"card identity\"><h2>Identity</h2>");
    if (found.user_hash.len != 0) {
        try render(w, "<div class=\"field mt-12\">User ID (from your app, stored hashed)</div><div class=\"code-line\">hmac · {start}…{end}</div>", .{ .start = found.user_hash[0..4], .end = found.user_hash[found.user_hash.len - 4 ..] });
    } else try w.writeAll("<p class=\"hint mt-8\">Not identified. Your app links devices by calling <code>analytico.identify(userId)</code> after sign-in.</p>");
    try w.writeAll("<div class=\"overline mt-18\">Devices</div>");
    for (found.visitors) |visitor| {
        var device = try ctx.db.prepare(arena, "SELECT max(pv.device),max(pv.browser),max(pv.operating_system),(SELECT first_seen_ms FROM visitors v WHERE v.site_id=?1 AND v.visitor_id=?2) FROM page_views pv WHERE pv.site_id=?1 AND pv.visitor_id=?2");
        defer device.deinit();
        try device.bindInt(1, site.id);
        try device.bindText(2, visitor);
        _ = try device.step();
        const since = data.civil(device.columnInt(3));
        try render(w, "<div class=\"device\"><strong>{system} · {browser}</strong><small>visitor {visitor} · since {day} {month}</small></div>", .{ .system = capitalized(arena, device.columnText(2)), .browser = capitalized(arena, device.columnText(1)), .visitor = visitor[0..4], .day = since.day, .month = data.month_names[since.month - 1] });
    }
    try w.writeAll("<p class=\"hint\">Linked when your app called identify() on each device. History is linked, never rewritten.</p><div class=\"overline mt-18\">Consent</div>");
    var consent_sql = data.Sql.init(arena);
    try consent_sql.add("SELECT consent_mode,min(received_at_ms) FROM page_views WHERE site_id=");
    try consent_sql.int(site.id);
    try consent_sql.add(" AND visitor_id IN ");
    try visitorList(&consent_sql, found);
    try consent_sql.add(" GROUP BY consent_mode ORDER BY 2 LIMIT 1");
    var consent = try consent_sql.prepare(ctx.db);
    defer consent.deinit();
    if (try consent.step() == .row) {
        const granted = std.mem.eql(u8, consent.columnText(0), "granted");
        try w.writeAll("<div class=\"callout callout-good mt-8\">");
        try icon(w, "shield-check");
        try render(w, "<span><strong>{state}</strong> · {when}<br><small>{how}</small></span></div>", .{ .state = if (granted) "Granted" else "Not required", .when = data.clock(consent.columnInt(1), ctx.now()), .how = if (granted) "By the visitor, through your banner or consent tool" else "Under your consent policy for their region" });
    }
    try w.writeAll("<div class=\"overline mt-18\">What we keep</div><div class=\"stack-s mt-8\">");
    const recorded = blk: {
        var count_sql = data.Sql.init(arena);
        try count_sql.add("SELECT count(*) FROM rp.replays WHERE site_id=");
        try count_sql.int(site.id);
        try count_sql.add(" AND visitor_id IN ");
        try visitorList(&count_sql, found);
        var statement = try count_sql.prepare(ctx.db);
        defer statement.deinit();
        _ = try statement.step();
        break :blk statement.columnInt(0);
    };
    const keeps = [_][]const u8{ "Pages, events and orders above", try std.fmt.allocPrint(arena, "{d} replay{s} · masked · deleted after 30 days", .{ recorded, if (recorded == 1) "" else "s" }), "Country and city · never the IP", "No names, emails or typed values" };
    for (keeps) |line| {
        try w.writeAll("<div class=\"row nowrap t-13\">");
        try icon(w, "check");
        try render(w, "<span>{line}</span></div>", .{ .line = line });
    }
    try w.writeAll("</div>");
    if (ctx.can(.admin)) {
        try render(w, "<div class=\"danger-zone\"><strong>Delete this person</strong><p class=\"hint\">Removes their page views, events, errors, replays and links from every device. Aggregated heatmaps and form statistics hold no identifier and stay.</p><form method=\"post\" action=\"/{slug}/people/{key}/forget\" data-confirm=\"Delete everything stored about {label}? This cannot be undone.\"><button class=\"btn btn-danger btn-block\">Delete {label}…</button></form><p class=\"hint mt-8\">Same as a <code>forget</code> record sent to <code>/i</code> — for deletion requests from your app.</p></div>", .{ .slug = site.slug, .key = key, .label = label });
    }
    try w.writeAll("</aside></div>");
    return layout.end(ctx);
}

/// Right of access: everything stored about the person, as JSON.
fn exportPerson(ctx: *Ctx, site: data.Site, found: Person) !void {
    if (!ctx.can(.admin)) return @import("app.zig").forbidden(ctx);
    const arena = ctx.arena;
    const w = ctx.w();
    try w.print("{{\"site\":\"{s}\",\"exported_at_ms\":{d},\"user_id_hash\":", .{ site.slug, ctx.now() });
    try std.json.Stringify.value(found.user_hash, .{}, w);
    try w.writeAll(",\"visitors\":");
    try std.json.Stringify.value(found.visitors, .{}, w);
    const tables = [_][2][]const u8{
        .{ "page_views", "SELECT received_at_ms,path,referrer_host,utm_source,utm_campaign,country,region,city,browser,operating_system,device,consent_mode,session_id,visitor_id FROM page_views" },
        .{ "events", "SELECT received_at_ms,name,path,value_minor,currency,order_id,properties_json,session_id,visitor_id FROM events" },
        .{ "errors", "SELECT received_at_ms,path,message,file,line,session_id,visitor_id FROM errors" },
    };
    for (tables) |table| {
        var sql = data.Sql.init(arena);
        try sql.add(table[1]);
        try sql.add(" WHERE site_id=");
        try sql.int(site.id);
        try sql.add(" AND visitor_id IN ");
        try visitorList(&sql, found);
        try sql.add(" ORDER BY received_at_ms");
        var statement = try sql.prepare(ctx.db);
        defer statement.deinit();
        try w.print(",\"{s}\":[", .{table[0]});
        var first = true;
        while (try statement.step() == .row) {
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeByte('{');
            for (0..statement.columnCount()) |index| {
                if (index != 0) try w.writeByte(',');
                try std.json.Stringify.value(statement.columnName(index), .{}, w);
                try w.writeByte(':');
                switch (statement.columnType(index)) {
                    db_mod.sqlite.SQLITE_NULL => try w.writeAll("null"),
                    db_mod.sqlite.SQLITE_INTEGER => try w.print("{d}", .{statement.columnInt(index)}),
                    else => try std.json.Stringify.value(statement.columnText(index), .{}, w),
                }
            }
            try w.writeByte('}');
        }
        try w.writeByte(']');
    }
    try w.writeByte('}');
    {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try audit.record(ctx, db, site.id, "person.exported", try std.fmt.allocPrint(arena, "{d} visitor(s)", .{found.visitors.len}));
    }
    try ctx.header("content-disposition", try std.fmt.allocPrint(arena, "attachment; filename=\"{s}-person-{s}.json\"", .{ site.slug, found.key[0..@min(8, found.key.len)] }));
    return ctx.json();
}

pub fn forget(ctx: *Ctx, site: data.Site, key: []const u8) !void {
    const arena = ctx.arena;
    const found = try loadPerson(ctx, site, key) orelse return layout.message(ctx, .not_found, "Person not found", "They may already have been deleted.");
    const label = try behaviour.personLabel(arena, found.visitors[0], found.user_hash);
    {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try db.exec("BEGIN IMMEDIATE");
        errdefer db.exec("ROLLBACK") catch {};
        if (found.user_hash.len != 0) {
            _ = try collector.forgetUser(arena, ctx.shared.store, site.id, found.user_hash);
        }
        for (found.visitors) |visitor| try collector.forgetVisitor(arena, ctx.shared.store, site.id, visitor);
        try audit.record(ctx, db, site.id, "person.deleted", try std.fmt.allocPrint(arena, "{s} · {d} visitor(s)", .{ label, found.visitors.len }));
        try db.exec("COMMIT");
    }
    {
        const replays = ctx.shared.lockReplays();
        defer ctx.shared.unlockReplays();
        try replay.forgetVisitors(arena, replays, site.id, found.visitors);
    }
    return ctx.done(try std.fmt.allocPrint(arena, "Deleted {s}: {d} device{s}, their events and replays.", .{ label, found.visitors.len, if (found.visitors.len == 1) "" else "s" }), "/{s}/people", .{site.slug});
}

fn capitalized(arena: std.mem.Allocator, value: []const u8) []const u8 {
    return data.prettyLabel(arena, value);
}
