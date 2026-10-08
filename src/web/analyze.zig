//! Pages (with the page detail sheet), Acquisition, Events & goals.
const std = @import("std");
const app = @import("app.zig");
const chart = @import("chart.zig");
const ctx_mod = @import("ctx.zig");
const customers = @import("customers.zig");
const data = @import("data.zig");
const domain = @import("../domain.zig");
const html = @import("html.zig");
const layout = @import("layout.zig");
const ui = @import("ui.zig");
const overview = @import("overview.zig");

const Ctx = ctx_mod.Ctx;
const esc = html.esc;
const icon = layout.icon;
const render = html.render;

pub fn start(ctx: *Ctx, site: data.Site, nav: layout.Nav, title: []const u8) !data.View {
    const view = try data.View.parse(ctx.arena, site, ctx.query, ctx.now());
    try layout.begin(ctx, try app.shell(ctx, site, nav, title, view));
    return view;
}

pub fn finish(ctx: *Ctx) !void {
    return layout.end(ctx);
}

pub fn sitePath(arena: std.mem.Allocator, site: data.Site, suffix: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "/{s}{s}", .{ site.slug, suffix });
}

fn sheetOpen(w: *std.Io.Writer, overline: []const u8, title: []const u8, close_href: []const u8) !void {
    try render(w,
        \\<dialog class="sheet" data-sheet data-close-href="{close}" autofocus><div class="sheet-head"><div class="min-0"><div class="overline">{overline}</div><h2>{title}</h2></div><a class="sheet-close" href="{close}" data-close aria-label="Close">
    , .{ .close = close_href, .overline = overline, .title = title });
    try icon(w, "x");
    try w.writeAll("</a></div>");
}

/// A small heading inside a sheet or card.
fn subhead(w: *std.Io.Writer, title: []const u8) !void {
    try render(w, "<h3 class=\"subhead\">{title}</h3>", .{ .title = title });
}

// ---------------------------------------------------------------- Pages

const PageRow = struct { path: []const u8, views: i64, visitors: i64, active_ms: i64, scroll: i64, previous: i64 };

pub fn pages(ctx: *Ctx, site: data.Site) !void {
    const arena = ctx.arena;
    const view = try start(ctx, site, .pages, "Pages");
    const w = ctx.w();
    const path = try sitePath(arena, site, "/pages");
    const search = std.mem.trim(u8, ctx.param("q") orelse "", " ");
    const sort = ctx.param("sort") orelse "views";
    try data.prefetch(ctx.shared, ctx.db, arena, view, &.{
        .{ .key_sums = .{ .dim = "page", .start = view.range.start_ms, .end = view.range.end_ms, .limit = 100_000 } },
        .{ .key_sums = .{ .dim = "page", .start = view.range.prev_start_ms, .end = view.range.prev_end_ms, .limit = 100_000 } },
    });
    const current_sums = try data.keySums(arena, ctx.db, view, "page", view.range.start_ms, view.range.end_ms, 100_000);
    const previous_sums = try data.keySums(arena, ctx.db, view, "page", view.range.prev_start_ms, view.range.prev_end_ms, 100_000);
    var previous_by_path: std.StringHashMapUnmanaged(i64) = .empty;
    for (previous_sums) |entry| try previous_by_path.put(arena, entry.key, entry.sums.views);
    var rows: std.ArrayList(PageRow) = .empty;
    const total: i64 = @intCast(current_sums.len);
    for (current_sums) |entry| {
        if (search.len != 0 and std.ascii.findIgnoreCase(entry.key, search) == null) continue;
        const summaries = @max(entry.sums.summaries, 1);
        try rows.append(arena, .{
            .path = entry.key,
            .views = entry.sums.views,
            .visitors = entry.sums.visitors,
            .active_ms = @divFloor(entry.sums.active_ms, summaries),
            .scroll = @divFloor(entry.sums.scroll_sum, summaries),
            .previous = previous_by_path.get(entry.key) orelse 0,
        });
    }
    const Sort = enum { views, visitors, time, scroll };
    const order = std.meta.stringToEnum(Sort, sort) orelse .views;
    std.mem.sort(PageRow, rows.items, order, struct {
        fn less(by: Sort, left: PageRow, right: PageRow) bool {
            const a = switch (by) {
                .views => left.views,
                .visitors => left.visitors,
                .time => left.active_ms,
                .scroll => left.scroll,
            };
            const b = switch (by) {
                .views => right.views,
                .visitors => right.visitors,
                .time => right.active_ms,
                .scroll => right.scroll,
            };
            if (a != b) return a > b;
            return std.mem.lessThan(u8, left.path, right.path);
        }
    }.less);
    if (rows.items.len > 200) rows.shrinkRetainingCapacity(200);

    try layout.head(ctx, .{ .title = "Pages", .subtitle = try std.fmt.allocPrint(arena, "{f} pages · {f}", .{ html.int(total), view.range }), .view = view, .path = path });
    const tab = ctx.param("tab") orelse "pages";
    try ui.tabs(ctx.w(), ctx.arena, view, path, "tab", &.{ .{ "pages", "Pages" }, .{ "outbound", "Outbound links" }, .{ "downloads", "Downloads" } }, tab);
    if (!std.mem.eql(u8, tab, "pages")) {
        try linkTable(ctx, view, if (std.mem.eql(u8, tab, "outbound")) "outbound_click" else "file_download", if (std.mem.eql(u8, tab, "outbound")) "host" else "file");
        return layout.end(ctx);
    }
    try render(w, "<section class=\"card card-flush\"><form class=\"card-head search-head\" method=\"get\" action=\"{path}\" data-live-search>", .{ .path = path });
    try layout.hiddenState(ctx, view, &.{});
    try w.writeAll("<label class=\"row search-box\"><span class=\"search-icon\">");
    try icon(w, "search");
    try render(w, "</span><input class=\"input\" type=\"search\" name=\"q\" value=\"{search}\" placeholder=\"Filter pages…\" aria-label=\"Filter pages\"></label><input type=\"hidden\" name=\"sort\" value=\"{sort}\"></form>", .{ .search = search, .sort = sort });
    try w.writeAll("<div class=\"table-wrap\"><table class=\"table\"><thead><tr><th>Page</th>");
    const columns = [_][3][]const u8{ .{ "views", "Views", "" }, .{ "visitors", "Visitors", "" }, .{ "time", "Avg. active time", "hide-m" }, .{ "scroll", "Scroll depth", "hide-m" } };
    for (columns) |column| {
        try render(w, "<th class=\"r {class}\"><a href=\"{href}\">{label}{arrow}</a></th>", .{ .class = column[2], .href = try view.href(arena, path, &.{ .{ "sort", column[0] }, .{ "q", search } }), .label = column[1], .arrow = if (std.mem.eql(u8, sort, column[0])) " ↓" else "" });
    }
    try w.writeAll("<th class=\"r hide-m\">Change</th></tr></thead><tbody>");
    const selected = ctx.param("page");
    for (rows.items) |row| {
        const href = try view.href(arena, path, &.{ .{ "page", row.path }, .{ "sort", if (std.mem.eql(u8, sort, "views")) "" else sort }, .{ "q", search } });
        try render(w, "<tr data-href=\"{href}\"{!selected}><td class=\"strong\"><a href=\"{href}\">{path}</a></td><td class=\"r\">{views}</td><td class=\"r\">{visitors}</td><td class=\"r hide-m\">{time}</td><td class=\"r hide-m\">{scroll}%</td><td class=\"r hide-m\">", .{
            .href = href, .selected = if (selected != null and std.mem.eql(u8, selected.?, row.path)) " aria-selected=\"true\"" else "", .path = row.path, .views = html.int(row.views), .visitors = html.int(row.visitors), .time = html.duration(row.active_ms), .scroll = row.scroll,
        });
        try ui.delta(w, @floatFromInt(row.views), @floatFromInt(row.previous), false);
        try w.writeAll("</td></tr>");
    }
    try w.writeAll("</tbody></table></div>");
    if (rows.items.len == 0) {
        try ui.empty(w, if (search.len != 0) "No pages match" else "No page views yet", if (search.len != 0) "Try a shorter part of the path." else "Pages appear here as soon as the tracker reports them.", "");
    }
    try render(w, "<div class=\"card-foot\"><span>Showing {shown} of {total} pages</span><span class=\"hint\">Click a row for details</span></div></section>", .{ .shown = rows.items.len, .total = html.int(total) });
    if (selected) |page_path| try pageSheet(ctx, view, path, page_path);
    return layout.end(ctx);
}

/// Which external sites and files visitors went to: the host or file name
/// only, never full URLs.
fn linkTable(ctx: *Ctx, view: data.View, event_name: []const u8, key: []const u8) !void {
    const w = ctx.w();
    var sql = data.Sql.init(ctx.arena);
    try sql.add("SELECT coalesce(json_extract(e.properties_json,'$.");
    try sql.add(key);
    try sql.add("'),'unknown') k,count(*),count(DISTINCT coalesce(e.session_id,e.page_id)),(SELECT x.path FROM events x WHERE x.site_id=e.site_id AND x.name=e.name AND json_extract(x.properties_json,'$.");
    try sql.add(key);
    try sql.add("')=json_extract(e.properties_json,'$.");
    try sql.add(key);
    try sql.add("') GROUP BY x.path ORDER BY count(*) DESC LIMIT 1) FROM events e WHERE ");
    try sql.events(view, view.range.start_ms, view.range.end_ms);
    try sql.add(" AND e.name=");
    try sql.str(event_name);
    try sql.add(" GROUP BY k ORDER BY 2 DESC LIMIT 100");
    var statement = try sql.prepare(ctx.db);
    defer statement.deinit();
    const outbound = std.mem.eql(u8, key, "host");
    try render(w, "<section class=\"card card-flush\"><div class=\"table-wrap\"><table class=\"table\"><thead><tr><th>{what}</th><th class=\"r\">Clicks</th><th class=\"r\">Visits</th><th class=\"hide-m\">Most from</th></tr></thead><tbody>", .{ .what = if (outbound) "Site" else "File" });
    var any = false;
    while (try statement.step() == .row) {
        any = true;
        try render(w, "<tr><td class=\"strong\">{name}</td><td class=\"r\">{clicks}</td><td class=\"r\">{visits}</td><td class=\"hide-m mono secondary\">{from}</td></tr>", .{ .name = statement.columnText(0), .clicks = html.int(statement.columnInt(1)), .visits = html.int(statement.columnInt(2)), .from = statement.columnText(3) });
    }
    try w.writeAll("</tbody></table></div>");
    if (!any) try ui.empty(w, if (outbound) "No outbound clicks yet" else "No downloads yet", if (outbound) "Clicks on links to other websites appear here — the host only, never the full address." else "Clicks on PDFs, archives, spreadsheets and other files appear here — the file name only.", "");
    try w.writeAll("</section>");
}

fn pageSheet(ctx: *Ctx, base_view: data.View, path: []const u8, page_path: []const u8) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    var view = base_view;
    var with_page: std.ArrayList(data.Filter) = .empty;
    try with_page.appendSlice(arena, base_view.filters);
    try with_page.append(arena, .{ .dim = .page, .value = page_path });
    view.filters = with_page.items;
    view.any = false;
    const close = try base_view.href(arena, path, &.{ .{ "q", ctx.param("q") orelse "" }, .{ "sort", ctx.param("sort") orelse "" } });
    try sheetOpen(w, try std.fmt.allocPrint(arena, "Page · {f}", .{base_view.range.text(.this)}), page_path, close);
    const tab = ctx.param("pt") orelse "overview";
    try w.writeAll("<nav class=\"seg seg-sheet\" aria-label=\"Page details\">");
    for ([_][2][]const u8{ .{ "overview", "Overview" }, .{ "sections", "Sections" }, .{ "actions", "Actions" }, .{ "paths", "Paths" } }) |item| try render(w, "<a href=\"{href}\"{!current}>{label}</a>", .{
        .href = try base_view.href(arena, path, &.{ .{ "page", page_path }, .{ "pt", item[0] } }),
        .current = if (std.mem.eql(u8, tab, item[0])) " aria-current=\"true\"" else "",
        .label = item[1],
    });
    try w.writeAll("</nav><div class=\"sheet-body\">");
    if (std.mem.eql(u8, tab, "sections")) {
        try sectionsList(ctx, view, 40);
    } else if (std.mem.eql(u8, tab, "actions")) {
        try pageActions(ctx, view);
    } else if (std.mem.eql(u8, tab, "paths")) {
        try pagePaths(ctx, base_view, page_path);
    } else {
        // Overview: four mini metrics with change, trend, next pages, sections.
        const now_values = try pageFigures(ctx, view, view.range.start_ms, view.range.end_ms);
        const prev_values = try pageFigures(ctx, view, view.range.prev_start_ms, view.range.prev_end_ms);
        try w.writeAll("<div class=\"metrics metrics-sheet\">");
        const labels = [_][]const u8{ "Views", "Visitors", "Avg. active", "Scroll" };
        for (labels, 0..) |label, index| {
            const current = now_values[index];
            const previous = prev_values[index];
            const value = switch (index) {
                0, 1 => try std.fmt.allocPrint(arena, "{f}", .{html.int(@intFromFloat(current))}),
                2 => try std.fmt.allocPrint(arena, "{f}", .{html.duration(@intFromFloat(current))}),
                else => try std.fmt.allocPrint(arena, "{d:.0}%", .{current}),
            };
            // Scroll depth changes in points, like the overview's returning share.
            const change = if (!view.compare) "&nbsp;" else if (index == 3) try points(arena, current, previous) else try ui.change(arena, current, previous, false, "");
            try ui.metric(w, arena, .{ .label = label, .value = value, .change = change });
        }
        try w.writeAll("</div><div class=\"card\">");
        try subhead(w, "Views by day");
        const names = try overview.labels(arena, view.range);
        try chart.trend(arena, w, .{ .current = try data.series(arena, ctx.db, view, .views, view.range.start_ms), .labels = names[0], .long_labels = names[1], .unit = "views", .height = 140 });
        try w.writeAll("</div>");
        if (view.site.mode != .lite) try nextPages(ctx, base_view, page_path, 4);
        try w.writeAll("<div>");
        try subhead(w, "Sections reached");
        try sectionsList(ctx, view, 6);
        try w.writeAll("</div>");
    }
    // The page's way out, on every tab: filter everything by it, then its sessions and the page itself.
    const filtered = try base_view.href(arena, path, &.{.{ "f+", try std.fmt.allocPrint(arena, "page:{s}", .{page_path}) }});
    try render(w, "<div class=\"sheet-actions\"><a class=\"btn btn-primary btn-wide\" href=\"{filtered}\">Filter every report by this page</a>", .{ .filtered = filtered });
    if (view.site.mode != .lite) {
        try render(w, "<a class=\"link\" href=\"{href}\">See sessions that viewed this page →</a>", .{ .href = try base_view.href(arena, try sitePath(arena, view.site, "/sessions"), &.{.{ "f+", try std.fmt.allocPrint(arena, "page:{s}", .{page_path}) }}) });
    }
    try render(w, "<a class=\"link\" href=\"{origin}{path}\" target=\"_blank\" rel=\"noopener\">Open the page on {host} ↗</a></div>", .{ .origin = base_view.site.origin, .path = page_path, .host = base_view.site.host() });
    try w.writeAll("</div></dialog>");
}

/// "+4 pts", "−1 pt": a change between two percentages.
fn points(arena: std.mem.Allocator, current: f64, previous: f64) ![]const u8 {
    const delta = current - previous;
    const class = if (@abs(delta) < 0.5) "delta-flat" else if (delta > 0) "delta-up" else "delta-down";
    return std.fmt.allocPrint(arena, "<span class=\"delta {s}\">{s}{d:.0} {s}</span>", .{ class, if (delta >= 0.5) "+" else if (delta <= -0.5) "−" else "", @abs(delta), if (@round(@abs(delta)) == 1) "pt" else "pts" });
}

/// Views, visitors, average active time and average scroll of a page's
/// view: the daily summaries up to their cut, raw rows after it.
fn pageFigures(ctx: *Ctx, view: data.View, from: i64, to: i64) ![4]f64 {
    const split = try data.rollupSplit(ctx.arena, ctx.db, view, from, to);
    var sql = data.Sql.init(ctx.arena);
    try sql.add("SELECT count(*),");
    try sql.distinctAfter(view, "visitor_day_id", "''", from, split);
    try sql.add(",count(pv.active_ms),coalesce(sum(pv.active_ms),0),coalesce(sum(pv.max_scroll),0) FROM page_views pv WHERE ");
    try sql.pageViews(view, split, to);
    var statement = try sql.prepare(ctx.db);
    defer statement.deinit();
    _ = try statement.step();
    var sums: data.RollupSums = .{ .views = statement.columnInt(0), .visitors = statement.columnInt(1), .summaries = statement.columnInt(2), .active_ms = statement.columnInt(3), .scroll_sum = statement.columnInt(4) };
    if (split > from) {
        const rolled = try data.rollupSums(ctx.arena, ctx.db, view, from, split);
        sums.views += rolled.views;
        sums.visitors += rolled.visitors;
        sums.summaries += rolled.summaries;
        sums.active_ms += rolled.active_ms;
        sums.scroll_sum += rolled.scroll_sum;
    }
    // Active time and scroll come together from a page's summary.
    const measured: f64 = @floatFromInt(@max(1, sums.summaries));
    return .{ @floatFromInt(sums.views), @floatFromInt(sums.visitors), @as(f64, @floatFromInt(sums.active_ms)) / measured, @as(f64, @floatFromInt(sums.scroll_sum)) / measured };
}

/// How many of a page's summaries reached each section: the daily summaries
/// for a page on its own, raw rows for the rest.
fn sectionsList(ctx: *Ctx, view: data.View, limit: i64) !void {
    const w = ctx.w();
    const arena = ctx.arena;
    const range = view.range;
    const scope = data.rollupScope(view);
    const page: ?[]const u8 = if (scope != null and std.mem.eql(u8, scope.?.dim, "page")) scope.?.key else null;
    const split = if (page != null) try data.rollupSplit(arena, ctx.db, view, range.start_ms, range.end_ms) else range.start_ms;
    var sql = data.Sql.init(arena);
    try sql.add("WITH s AS (SELECT ps.sections_json FROM page_views pv JOIN page_summaries ps ON ps.site_id=pv.site_id AND ps.page_id=pv.page_id WHERE ");
    try sql.pageViews(view, split, range.end_ms);
    try sql.add("), r AS (SELECT j.value k,count(*) n FROM s, json_each(s.sections_json) j GROUP BY 1");
    if (split > range.start_ms) {
        try sql.add(" UNION ALL SELECT substr(key,length(");
        try sql.str(page.?);
        try sql.add(")+2),sum(views)");
        try data.rollupWhere(&sql, view.site.id, .{ .dim = "section", .key = null }, range.start_ms, split);
        try sql.add(" AND key>=");
        try sql.str(try std.fmt.allocPrint(arena, "{s}\x1f", .{page.?}));
        try sql.add(" AND key<");
        try sql.str(try std.fmt.allocPrint(arena, "{s}\x20", .{page.?}));
        try sql.add(" GROUP BY key");
    }
    // Out of every summary of the page, summarised ones under the empty key.
    try sql.add(") SELECT k,sum(n),(SELECT count(*) FROM s)+(SELECT coalesce(sum(n),0) FROM r WHERE k='') FROM r WHERE k<>'' GROUP BY k ORDER BY 2 DESC,1 LIMIT ");
    try sql.int(limit);
    var statement = try sql.prepare(ctx.db);
    defer statement.deinit();
    var any = false;
    try w.writeAll("<div class=\"stack-s\">");
    while (try statement.step() == .row) {
        any = true;
        const share = @as(f64, @floatFromInt(statement.columnInt(1))) / @as(f64, @floatFromInt(@max(1, statement.columnInt(2)))) * 100;
        try render(w, "<div class=\"row nowrap t-13\"><span class=\"grow secondary ellipsis\">{name}</span><span class=\"reach\"><span style=\"width:{share:.0}%\"></span></span><strong class=\"reach-pct\">{share:.0}%</strong></div>", .{ .name = statement.columnText(0), .share = share });
    }
    try w.writeAll("</div>");
    if (!any) try w.writeAll("<p class=\"hint\">No sections reported. Mark sections with <code>data-analytico-section</code> to see how far readers get.</p>");
}

fn nextPages(ctx: *Ctx, view: data.View, page_path: []const u8, limit: i64) !void {
    const w = ctx.w();
    const next = try journeys.nextSteps(ctx.arena, ctx.db, view, page_path, limit);
    try w.writeAll("<div>");
    try subhead(w, "Where visitors go next");
    try w.writeAll("<div class=\"rank\">");
    for (next.steps) |step| {
        const share = @as(f64, @floatFromInt(step.count)) / @as(f64, @floatFromInt(@max(1, next.total))) * 100;
        try render(w, "<div class=\"rank-row\"><span class=\"bar\" style=\"width:{width:.0}%;background:{bar}\"></span><span class=\"rank-name\"><span>{name}</span></span><span></span><span class=\"rank-pct strong-pct\">{share:.0}%</span></div>", .{ .width = @max(share * 0.8, 8), .bar = if (step.path.len == 0) "var(--subtle)" else "var(--brand-wash)", .name = if (step.path.len == 0) "Left the site" else step.path, .share = share });
    }
    if (next.steps.len == 0) try w.writeAll("<p class=\"hint\">Not enough sessions yet.</p>");
    try w.writeAll("</div></div>");
}

fn pagePaths(ctx: *Ctx, view: data.View, page_path: []const u8) !void {
    const w = ctx.w();
    if (view.site.mode == .lite) {
        try w.writeAll("<div class=\"callout\">");
        try icon(w, "info");
        try w.writeAll("<span>Paths need <strong>session mode</strong>, which links page views within one visit. Lite mode never links them.</span></div>");
        return;
    }
    try nextPages(ctx, view, page_path, 8);
    try w.writeAll("<div>");
    try subhead(w, "Where visitors came from");
    try w.writeAll("<dl class=\"kv\">");
    for (try journeys.previousSteps(ctx.arena, ctx.db, view, page_path, 8)) |step| {
        try render(w, "<dt>{name}</dt><dd>{count}</dd>", .{ .name = if (step.path.len == 0) "Entered here" else step.path, .count = html.int(step.count) });
    }
    try w.writeAll("</dl></div>");
}

fn pageActions(ctx: *Ctx, view: data.View) !void {
    const w = ctx.w();
    var sql = data.Sql.init(ctx.arena);
    try sql.add("SELECT coalesce(sum(ps.outbound_clicks),0),coalesce(sum(ps.downloads),0),coalesce(sum(ps.copy_count),0),coalesce(sum(ps.form_attempts),0),coalesce(sum(ps.interaction_count),0) FROM page_views pv JOIN page_summaries ps ON ps.site_id=pv.site_id AND ps.page_id=pv.page_id WHERE ");
    try sql.pageViews(view, view.range.start_ms, view.range.end_ms);
    var statement = try sql.prepare(ctx.db);
    defer statement.deinit();
    _ = try statement.step();
    try w.writeAll("<div class=\"mini-metrics\">");
    const labels = [_][]const u8{ "Outbound clicks", "Downloads", "Copies", "Form attempts" };
    for (labels, 0..) |label, index| try render(w, "<div class=\"mini\"><small>{label}</small><div class=\"row-between\"><strong>{count}</strong></div></div>", .{ .label = label, .count = html.int(statement.columnInt(index)) });
    try w.writeAll("</div>");
    var events_sql = data.Sql.init(ctx.arena);
    try events_sql.add("SELECT e.name,count(*) FROM events e WHERE ");
    try events_sql.events(view, view.range.start_ms, view.range.end_ms);
    try events_sql.add(" GROUP BY e.name ORDER BY 2 DESC LIMIT 12");
    var events_statement = try events_sql.prepare(ctx.db);
    defer events_statement.deinit();
    try w.writeAll("<div>");
    try subhead(w, "Events on this page");
    try w.writeAll("<dl class=\"kv\">");
    var any = false;
    while (try events_statement.step() == .row) {
        any = true;
        try render(w, "<dt class=\"mono\">{name}</dt><dd>{count}</dd>", .{ .name = events_statement.columnText(0), .count = html.int(events_statement.columnInt(1)) });
    }
    try w.writeAll("</dl>");
    if (!any) try w.writeAll("<p class=\"hint\">No custom events on this page in this period.</p>");
    try w.writeAll("</div>");
}

// ---------------------------------------------------------------- Acquisition

pub fn acquisition(ctx: *Ctx, site: data.Site) !void {
    const arena = ctx.arena;
    const view = try start(ctx, site, .acquisition, "Acquisition");
    const path = try sitePath(arena, site, "/acquisition");
    const tab = ctx.param("tab") orelse "sources";
    try layout.head(ctx, .{ .title = "Acquisition", .subtitle = try std.fmt.allocPrint(arena, "Where visitors come from, and what campaigns earn · {f}", .{view.range}), .view = view, .path = path });
    try ui.tabs(ctx.w(), ctx.arena, view, path, "tab", &.{ .{ "sources", "Sources" }, .{ "campaigns", "Campaigns" }, .{ "channels", "Channels" } }, tab);
    if (std.mem.eql(u8, tab, "campaigns")) {
        try campaigns(ctx, view, path);
    } else if (std.mem.eql(u8, tab, "channels")) {
        try channels(ctx, view);
    } else {
        try sources(ctx, view);
    }
    return layout.end(ctx);
}

fn sources(ctx: *Ctx, view: data.View) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    const current_sums = try data.keySums(arena, ctx.db, view, "source", view.range.start_ms, view.range.end_ms, 100);
    const previous_sums = try data.keySums(arena, ctx.db, view, "source", view.range.prev_start_ms, view.range.prev_end_ms, 1000);
    const base = try sitePath(arena, view.site, "");
    try w.writeAll("<section class=\"card card-flush\"><div class=\"table-wrap\"><table class=\"table\"><thead><tr><th>Source</th><th class=\"r\">Page views</th><th class=\"r\">Visitors</th><th class=\"r hide-m\">Engaged</th><th class=\"r hide-m\">Change</th><th class=\"bar-cell hide-m\"></th></tr></thead><tbody>");
    var largest: i64 = 0;
    var any = false;
    const keys = try arena.alloc([]const u8, current_sums.len);
    for (current_sums, keys) |entry, *key| key.* = entry.key;
    const labels = try overview.sourceLabels(arena, keys);
    for (current_sums, labels) |entry, label| {
        any = true;
        const key = entry.key;
        const views = entry.sums.views;
        if (largest == 0) largest = views;
        const href = try view.href(arena, base, &.{.{ "f+", try std.fmt.allocPrint(arena, "source:{s}", .{key}) }});
        try render(w, "<tr data-href=\"{href}\"><td class=\"strong\"><a href=\"{href}\" class=\"row nowrap\">", .{ .href = href });
        try overview.sourceAvatar(w, key, label);
        try render(w, "{label}</a></td><td class=\"r\">{views}</td><td class=\"r\">{visitors}</td><td class=\"r hide-m\">{engaged}</td><td class=\"r hide-m\">", .{
            .label = label,
            .views = html.int(views),
            .visitors = html.int(entry.sums.visitors),
            .engaged = html.share(entry.sums.engaged, views),
        });
        try ui.delta(w, @floatFromInt(views), @floatFromInt(data.keySum(previous_sums, key).views), false);
        try render(w, "</td><td class=\"bar-cell hide-m\"><div class=\"mini-bar\" style=\"width:{width:.0}%\"></div></td></tr>", .{ .width = @as(f64, @floatFromInt(views)) / @as(f64, @floatFromInt(@max(largest, 1))) * 100 });
    }
    try w.writeAll("</tbody></table></div>");
    if (!any) try ui.empty(w, "No visits in this period", "Sources appear as soon as visitors arrive.", "");
    try w.writeAll("<div class=\"card-foot\"><span>Engaged: at least 10 s active, half the page scrolled, or an interaction.</span><span>Click a source to filter every page</span></div></section>");
}

fn channels(ctx: *Ctx, view: data.View) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    var sql = data.Sql.init(arena);
    try sql.add("SELECT ");
    try sql.add(data.Dim.source.column());
    try sql.add(",lower(coalesce(pv.utm_medium,'')),count(*),count(DISTINCT pv.visitor_day_id) FROM page_views pv WHERE ");
    try sql.pageViews(view, view.range.start_ms, view.range.end_ms);
    try sql.add(" GROUP BY 1,2");
    var statement = try sql.prepare(ctx.db);
    defer statement.deinit();
    const names = [_][]const u8{ "Direct", "Search", "Social", "Email", "Paid", "AI assistants", "Referral", "Within the site" };
    var views: [names.len]i64 = @splat(0);
    var visitors: [names.len]i64 = @splat(0);
    var total: i64 = 0;
    while (try statement.step() == .row) {
        const channel = overview.channel(statement.columnText(0), statement.columnText(1));
        for (names, 0..) |name, index| if (std.mem.eql(u8, name, channel)) {
            views[index] += statement.columnInt(2);
            visitors[index] += statement.columnInt(3);
        };
        total += statement.columnInt(2);
    }
    var colors: [names.len][]const u8 = undefined;
    for (names, &colors) |name, *color| color.* = overview.channelTone(name).color;
    try w.writeAll("<div class=\"grid grid-2\"><section class=\"card\">");
    try ui.cardHead(w, "Channel mix", "<span class=\"meta\">Share of page views</span>");
    try w.writeAll("<div class=\"share-bar mb-16\">");
    for (names, 0..) |_, index| if (views[index] > 0) {
        try render(w, "<span style=\"flex:{value};background:{color}\"></span>", .{ .value = views[index], .color = colors[index] });
    };
    try w.writeAll("</div><div class=\"rank\">");
    for (names, 0..) |name, index| {
        if (views[index] == 0) continue;
        try render(w, "<div class=\"rank-row\"><span class=\"rank-name\"><span class=\"avatar avatar-dot\" style=\"background:{color}\"></span><span>{name}</span></span><span class=\"rank-value\">{views}</span><span class=\"rank-pct\">{share}</span></div>", .{ .color = colors[index], .name = name, .views = html.int(views[index]), .share = html.share(views[index], total) });
    }
    try w.writeAll("</div></section><section class=\"card\"><div class=\"card-head\"><h2>How channels are grouped</h2></div><p class=\"hint hint-13\">Search, social and AI assistants are recognised by referrer. Email and paid traffic come from <code>utm_medium</code> (email, newsletter, cpc, paid). Everything else with a referrer is Referral; no referrer is Direct. Pages reached from the site itself carry the visit's source; in Lite mode, which keeps nothing between pages, they show as Within the site.</p></section></div>");
    if (total == 0) try ui.empty(w, "No visits in this period", "Channels appear as soon as visitors arrive.", "");
}

const Campaign = struct { name: []const u8, visitors: i64, conversions: i64, revenue: i64, spend: i64, currency: []const u8 };

fn campaigns(ctx: *Ctx, view: data.View, path: []const u8) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    const site = view.site;
    const from = data.dateText(view.range.start_ms);
    const to = data.dateText(view.range.end_ms - 1);
    var sql = data.Sql.init(arena);
    // Each set once, then joined by campaign. Revenue is orders (one per order
    // ID, whether seen from the browser, the server or both) minus refunds.
    try sql.add("WITH cv AS MATERIALIZED (SELECT pv.utm_campaign c,pv.session_id,pv.page_id,pv.visitor_day_id FROM page_views pv WHERE ");
    try sql.pageViews(view, view.range.start_ms, view.range.end_ms);
    try sql.add(" AND pv.utm_campaign>''), cs AS MATERIALIZED (SELECT session_id,max(c) c FROM cv WHERE session_id IS NOT NULL GROUP BY session_id), ev AS MATERIALIZED (SELECT coalesce(json_extract(e.properties_json,'$.campaign'),cs.c,cv.c) c,e.name,e.value_minor,e.currency,coalesce(e.order_id,e.event_id) o FROM events e LEFT JOIN cs ON cs.session_id=e.session_id LEFT JOIN cv ON cv.page_id=e.page_id WHERE ");
    try sql.events(view, view.range.start_ms, view.range.end_ms);
    try sql.add("), sp AS (SELECT campaign c,sum(amount_minor) a,max(currency) cur FROM campaign_spend WHERE site_id=");
    try sql.int(site.id);
    try sql.add(" AND spend_date>=");
    try sql.str(&from);
    try sql.add(" AND spend_date<=");
    try sql.str(&to);
    try sql.add(" GROUP BY campaign), k AS (SELECT c FROM cv UNION SELECT c FROM sp), vis AS (SELECT c,count(DISTINCT visitor_day_id) n FROM cv GROUP BY c), conv AS (SELECT c,sum(name IN (SELECT match_value FROM goals WHERE kind='event' AND site_id=");
    try sql.int(site.id);
    try sql.add(")) n,max(currency) cur FROM ev GROUP BY c), orders AS (SELECT c,sum(v) v FROM (SELECT c,o,max(value_minor) v FROM ev WHERE name IN " ++ customers.purchase_names ++ " AND value_minor IS NOT NULL GROUP BY c,o) GROUP BY c), refunds AS (SELECT c,sum(abs(value_minor)) v FROM ev WHERE name IN " ++ customers.refund_names ++ " AND value_minor IS NOT NULL GROUP BY c) SELECT k.c,coalesce(vis.n,0),coalesce(conv.n,0),coalesce(orders.v,0)-coalesce(refunds.v,0),coalesce(sp.a,0),coalesce(sp.cur,conv.cur,'') FROM k LEFT JOIN vis ON vis.c=k.c LEFT JOIN conv ON conv.c=k.c LEFT JOIN orders ON orders.c=k.c LEFT JOIN refunds ON refunds.c=k.c LEFT JOIN sp ON sp.c=k.c ORDER BY 4 DESC,2 DESC LIMIT 100");
    var statement = try sql.prepare(ctx.db);
    defer statement.deinit();
    var rows: std.ArrayList(Campaign) = .empty;
    var spend: i64 = 0;
    var revenue: i64 = 0;
    var conversions: i64 = 0;
    var currency: []const u8 = (try data.setting(arena, ctx.db, .currency)) orelse "EUR";
    while (try statement.step() == .row) {
        const row: Campaign = .{
            .name = try arena.dupe(u8, statement.columnText(0)),
            .visitors = statement.columnInt(1),
            .conversions = statement.columnInt(2),
            .revenue = statement.columnInt(3),
            .spend = statement.columnInt(4),
            .currency = try arena.dupe(u8, statement.columnText(5)),
        };
        if (row.currency.len == 3) currency = row.currency;
        spend += row.spend;
        revenue += row.revenue;
        conversions += row.conversions;
        try rows.append(arena, row);
    }
    try w.writeAll("<div class=\"grid grid-4 mb-16\">");
    const figures = [_]struct { []const u8, ?[]const u8 }{
        .{ "Spend", try std.fmt.allocPrint(arena, "{f}", .{html.money(spend, currency)}) },
        .{ "Confirmed revenue", try std.fmt.allocPrint(arena, "{f}", .{html.money(revenue, currency)}) },
        .{ "Return on ad spend", if (spend > 0) try std.fmt.allocPrint(arena, "{d:.1}×", .{@as(f64, @floatFromInt(revenue)) / @as(f64, @floatFromInt(spend))}) else null },
        .{ "Cost per conversion", if (conversions > 0 and spend > 0) try std.fmt.allocPrint(arena, "{f}", .{html.money(@divTrunc(spend, conversions), currency)}) else null },
    };
    for (figures) |figure| try ui.stat(w, figure[0], figure[1] orelse "—", "");
    try w.writeAll("</div><section class=\"card card-flush\"><div class=\"card-head campaigns-head\"><h2>Campaigns</h2><button class=\"btn\" type=\"button\" data-dialog=\"import-dialog\">");
    try icon(w, "upload");
    try w.writeAll("Import spend (CSV)</button></div><div class=\"table-wrap\"><table class=\"table\"><thead><tr><th>Campaign</th><th class=\"r\">Visitors</th><th class=\"r\">Conversions</th><th class=\"r\">Revenue</th><th class=\"r\">Spend</th><th class=\"r\">ROAS</th></tr></thead><tbody>");
    for (rows.items) |row| {
        const row_currency = if (row.currency.len == 3) row.currency else currency;
        try render(w,
            \\<tr><td class="strong">{name}</td><td class="r">{visitors}</td><td class="r">{conversions}</td><td class="r">{revenue}</td><td class="r"><form method="post" action="/{slug}/spend" data-inline-edit><input type="hidden" name="campaign" value="{name}"><input type="hidden" name="from" value="{from}"><input type="hidden" name="to" value="{to}"><input type="hidden" name="currency" value="{currency}">
            \\<button type="button" class="edit-cell" data-edit>{spend}
        , .{ .name = row.name, .visitors = html.int(row.visitors), .conversions = html.int(row.conversions), .revenue = html.money(row.revenue, row_currency), .slug = site.slug, .from = &from, .to = &to, .currency = row_currency, .spend = html.money(row.spend, row_currency) });
        try icon(w, "pencil");
        try render(w, "</button><input class=\"input inline-input\" name=\"amount\" inputmode=\"decimal\" value=\"{whole}.{cents}\" hidden aria-label=\"Spend for {name}\"></form></td><td class=\"r\">", .{ .whole = @divTrunc(row.spend, 100), .cents = try std.fmt.allocPrint(arena, "{d:0>2}", .{@as(u64, @intCast(@mod(row.spend, 100)))}), .name = row.name });
        if (row.spend > 0) {
            const roas = @as(f64, @floatFromInt(row.revenue)) / @as(f64, @floatFromInt(row.spend));
            try render(w, "<span class=\"{class}\">{roas:.1}×</span>", .{ .class = if (roas < 3) "warn" else "", .roas = roas });
        } else try w.writeAll("<span class=\"muted\">—</span>");
        try w.writeAll("</td></tr>");
    }
    try w.writeAll("</tbody></table></div>");
    if (rows.items.len == 0) try ui.empty(w, "No campaigns yet", "Tag links with <code>utm_campaign</code> — campaigns show up here with visitors, conversions and revenue. Add spend to see return on ad spend.", "");
    try w.writeAll("<div class=\"card-foot\"><span>Click any spend to edit · it applies to the selected period · Esc cancels</span><span>Conversions count event goals</span></div></section>");
    try render(w,
        \\<dialog class="dialog" id="import-dialog"><form method="post" action="/{slug}/spend-import"><input type="hidden" name="back" value="{back}">
        \\<div class="dialog-head"><div><h2>Import spend</h2><p>Paste rows or choose a CSV export from your ad platform.</p></div><button class="btn btn-quiet btn-icon close" type="button" data-close aria-label="Close">
    , .{ .slug = site.slug, .back = try view.href(arena, path, &.{.{ "tab", "campaigns" }}) });
    try icon(w, "x");
    try w.writeAll(
        \\</button></div><div class="dialog-body"><label class="btn self-start"><input type="file" accept=".csv,text/csv" data-file-to="#spend-csv" hidden>Choose CSV file…</label>
        \\<textarea class="input mono" id="spend-csv" name="csv" rows="7" required placeholder="date,source,campaign,content,amount_minor,currency&#10;2026-09-21,meta,summer-workshop,reel-a,120000,EUR"></textarea>
        \\<p class="hint">Columns: date, source, campaign, content, amount in cents, currency. Rows for the same day and campaign add up.</p></div>
        \\<div class="dialog-foot"><button class="btn" type="button" data-close>Cancel</button><button class="btn btn-primary">Import</button></div></form></dialog>
    );
}

fn parseMoney(text: []const u8) !i64 {
    const trimmed = std.mem.trim(u8, text, " ");
    if (trimmed.len == 0 or trimmed.len > 16) return error.InvalidAmount;
    var whole: i64 = 0;
    var cents: i64 = 0;
    var decimals: u8 = 0;
    var seen_point = false;
    for (trimmed) |byte| {
        if (byte == ',' and !seen_point) continue;
        if (byte == '.') {
            if (seen_point) return error.InvalidAmount;
            seen_point = true;
            continue;
        }
        if (!std.ascii.isDigit(byte)) return error.InvalidAmount;
        if (seen_point) {
            if (decimals == 2) return error.InvalidAmount;
            cents = cents * 10 + (byte - '0');
            decimals += 1;
        } else whole = whole * 10 + (byte - '0');
    }
    if (decimals == 1) cents *= 10;
    return whole * 100 + cents;
}

pub fn setSpend(ctx: *Ctx, site: data.Site) !void {
    const campaign = try ctx.field("campaign");
    const amount = parseMoney(try ctx.field("amount")) catch return overview.failBack(ctx, site, "Spend must be a number like 1200 or 1200.50.");
    const from = try ctx.field("from");
    const to = try ctx.field("to");
    const currency = try ctx.field("currency");
    _ = data.parseDate(from) catch return overview.failBack(ctx, site, "Invalid period.");
    _ = data.parseDate(to) catch return overview.failBack(ctx, site, "Invalid period.");
    domain.validateText(campaign, 128, false) catch return overview.failBack(ctx, site, "Invalid campaign.");
    if (currency.len != 3) return overview.failBack(ctx, site, "Invalid currency.");
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    // The edited number is the period's total: replace that period's rows.
    try db.exec("BEGIN IMMEDIATE");
    errdefer db.exec("ROLLBACK") catch {};
    try db.run(ctx.arena, "DELETE FROM campaign_spend WHERE site_id=? AND campaign=? AND spend_date>=? AND spend_date<=?", .{ site.id, campaign, from, to });
    if (amount > 0) try db.run(ctx.arena, "INSERT INTO campaign_spend(site_id,spend_date,source,campaign,content,amount_minor,currency,created_at_ms) VALUES(?,?,'',?,'',?,?,?)", .{ site.id, to, campaign, amount, currency, ctx.now() });
    try db.exec("COMMIT");
    return ctx.done(try std.fmt.allocPrint(ctx.arena, "Spend for {s} saved.", .{campaign}), "{s}", .{overview.referer(ctx, site)});
}

pub fn importSpend(ctx: *Ctx, site: data.Site) !void {
    const csv = try ctx.field("csv");
    if (!std.unicode.utf8ValidateSlice(csv)) return overview.failBack(ctx, site, "The file isn’t valid UTF-8 text.");
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    try db.exec("BEGIN IMMEDIATE");
    errdefer db.exec("ROLLBACK") catch {};
    var lines = std.mem.splitScalar(u8, csv, '\n');
    var imported: usize = 0;
    var line_number: usize = 0;
    // Rows repeated within this file add up; rows from an earlier import are
    // replaced, so importing the same export twice doesn't double the spend.
    const stamp = ctx.now();
    while (lines.next()) |raw| {
        line_number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or (line_number == 1 and std.mem.startsWith(u8, line, "date,"))) continue;
        var fields: [6][]const u8 = undefined;
        var parts = std.mem.splitScalar(u8, line, ',');
        var count: usize = 0;
        while (parts.next()) |part| : (count += 1) {
            if (count >= fields.len) break;
            fields[count] = std.mem.trim(u8, part, " \t\"");
        }
        const bad = count != 6 or (data.parseDate(fields[0]) catch null) == null or fields[2].len == 0 or fields[5].len != 3;
        const amount = if (bad) -1 else std.fmt.parseInt(i64, fields[4], 10) catch -1;
        if (bad or amount < 0) {
            db.exec("ROLLBACK") catch {};
            return overview.failBack(ctx, site, try std.fmt.allocPrint(ctx.arena, "Line {d} doesn’t match date,source,campaign,content,amount_minor,currency.", .{line_number}));
        }
        const upper = try std.ascii.allocUpperString(ctx.arena, fields[5]);
        try db.run(ctx.arena, "INSERT INTO campaign_spend(site_id,spend_date,source,campaign,content,amount_minor,currency,created_at_ms) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(site_id,spend_date,source,campaign,content,currency) DO UPDATE SET amount_minor=CASE WHEN created_at_ms=excluded.created_at_ms THEN amount_minor+excluded.amount_minor ELSE excluded.amount_minor END,created_at_ms=excluded.created_at_ms", .{ site.id, fields[0], fields[1], fields[2], fields[3], amount, upper, stamp });
        imported += 1;
    }
    try db.exec("COMMIT");
    return ctx.done(try std.fmt.allocPrint(ctx.arena, "Imported {d} spend rows.", .{imported}), "{s}", .{overview.referer(ctx, site)});
}

// ---------------------------------------------------------------- Events & goals

pub fn events(ctx: *Ctx, site: data.Site) !void {
    const arena = ctx.arena;
    const view = try start(ctx, site, .events, "Events & goals");
    const path = try sitePath(arena, site, "/events");
    const tab = ctx.param("tab") orelse "events";
    const goal_count = try ctx.db.scalar(arena, i64, "SELECT count(*) FROM goals WHERE site_id=?", .{site.id});
    try layout.head(ctx, .{ .title = "Events & goals", .subtitle = try std.fmt.allocPrint(arena, "{f} · {s} mode", .{ view.range, switch (site.mode) {
        .lite => "Lite",
        .session => "Session",
        .full => "Full",
    } }), .view = view, .path = path });
    try ui.tabs(ctx.w(), ctx.arena, view, path, "tab", &.{ .{ "events", "Events" }, .{ "goals", try std.fmt.allocPrint(arena, "Goals · {d}", .{goal_count}) }, .{ "experiments", "Experiments" } }, tab);
    if (std.mem.eql(u8, tab, "goals")) try goals(ctx, view) else if (std.mem.eql(u8, tab, "experiments")) try experiments(ctx, view, path) else try eventTable(ctx, view);
    try goalDialog(ctx, site, ctx.param("goal") orelse "");
    return layout.end(ctx);
}

fn eventTable(ctx: *Ctx, view: data.View) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    const site = view.site;
    var sql = data.Sql.init(arena);
    try sql.add("SELECT e.name,group_concat(DISTINCT e.source),count(*),count(DISTINCT e.session_id),max(e.received_at_ms),(SELECT name FROM goals g WHERE g.site_id=e.site_id AND g.kind='event' AND g.match_value=e.name LIMIT 1) FROM events e WHERE ");
    try sql.events(view, view.range.start_ms, view.range.end_ms);
    try sql.add(" GROUP BY e.name ORDER BY 3 DESC LIMIT 200");
    var statement = try sql.prepare(ctx.db);
    defer statement.deinit();
    try w.writeAll("<section class=\"card card-flush\"><div class=\"table-wrap\"><table class=\"table\"><thead><tr><th>Event</th><th class=\"hide-m\">Source</th><th class=\"r\">Count</th>");
    if (site.mode != .lite) try w.writeAll("<th class=\"r hide-m\">Sessions</th>");
    try w.writeAll("<th class=\"hide-m\">Goal</th><th class=\"r hide-m\">Last seen</th><th class=\"col-menu\"></th></tr></thead><tbody>");
    var index: usize = 0;
    while (try statement.step() == .row) : (index += 1) {
        const name = statement.columnText(0);
        const source_list = statement.columnText(1);
        const goal = statement.columnText(5);
        try render(w, "<tr><td class=\"strong mono t-13\">{name}</td><td class=\"secondary hide-m\">{source}</td><td class=\"r\">{count}</td>", .{ .name = name, .source = if (std.mem.eql(u8, source_list, "server")) "Server" else if (std.mem.indexOf(u8, source_list, "server") != null) "Browser + server" else "Browser", .count = html.int(statement.columnInt(2)) });
        if (site.mode != .lite) try render(w, "<td class=\"r hide-m\">{sessions}</td>", .{ .sessions = html.int(statement.columnInt(3)) });
        try w.writeAll("<td class=\"hide-m\">");
        if (goal.len != 0) try render(w, "<span class=\"pill pill-good\">{goal}</span>", .{ .goal = goal });
        try render(w, "</td><td class=\"r secondary hide-m\">{ago}</td><td><button class=\"btn btn-quiet btn-icon\" type=\"button\" popovertarget=\"ev-{index}\" aria-label=\"Actions for {name}\">", .{ .ago = data.ago(statement.columnInt(4), ctx.now()), .index = index, .name = name });
        try icon(w, "more");
        try render(w, "</button><div id=\"ev-{index}\" popover class=\"pop\" data-anchor=\"[popovertarget=ev-{index}]\"><a class=\"menu-item\" href=\"{href}\">", .{ .index = index, .href = try view.href(arena, try sitePath(arena, site, "/events"), &.{ .{ "goal", name }, .{ "tab", ctx.param("tab") orelse "" } }) });
        try icon(w, "events");
        try render(w, "Track as goal…</a><a class=\"menu-item\" href=\"/{slug}/funnels?step=event%3A{step}\">", .{ .slug = site.slug, .step = html.url(name) });
        try icon(w, "funnels");
        try w.writeAll("Add to a funnel</a>");
        if (site.mode != .lite) {
            try render(w, "<a class=\"menu-item\" href=\"{href}\">", .{ .href = try view.href(arena, try sitePath(arena, site, "/sessions"), &.{.{ "event", name }}) });
            try icon(w, "paths");
            try w.writeAll("View sessions</a>");
        }
        try render(w, "<a class=\"menu-item\" href=\"{href}\">", .{ .href = try view.href(arena, try sitePath(arena, site, "/events"), &.{ .{ "dialog", "alert-dialog" }, .{ "event", name } }) });
        try icon(w, "bell-plus");
        try w.writeAll("Alert on this event…</a></div></td></tr>");
    }
    try w.writeAll("</tbody></table></div>");
    if (index == 0) try ui.empty(w, "No events in this period", "Send custom events with <code>analytico.track('signup')</code> in the browser, or signed server events to <code>/i</code>.", "");
    try w.writeAll("</section>");
}

fn goals(ctx: *Ctx, view: data.View) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    const site = view.site;
    // Conversions: visitor-days that completed the goal, over all visitor-days.
    var total_sql = data.Sql.init(arena);
    try total_sql.add("SELECT count(DISTINCT pv.visitor_day_id) FROM page_views pv WHERE ");
    try total_sql.pageViews(view, view.range.start_ms, view.range.end_ms);
    var total_statement = try total_sql.prepare(ctx.db);
    defer total_statement.deinit();
    const visitors: i64 = if (try total_statement.step() == .row) total_statement.columnInt(0) else 0;
    var statement = try ctx.db.prepare(arena, "SELECT id,name,kind,match_value FROM goals WHERE site_id=? ORDER BY name");
    defer statement.deinit();
    try statement.bindInt(1, site.id);
    try render(w, "<div class=\"row-between mb-12\"><p class=\"hint\">A goal is an event or a page that counts as success. Goals power conversion rates, funnels and campaign results.</p><a class=\"btn btn-primary\" href=\"{href}\">", .{ .href = try view.href(arena, try sitePath(arena, site, "/events"), &.{ .{ "tab", "goals" }, .{ "goal", "+" } }) });
    try icon(w, "plus");
    try w.writeAll("New goal</a></div><section class=\"card card-flush\"><div class=\"table-wrap\"><table class=\"table\"><thead><tr><th>Goal</th><th class=\"hide-m\">Matches</th><th class=\"r\">Completions</th><th class=\"r\">Conversion</th><th class=\"col-menu\"></th></tr></thead><tbody>");
    var any = false;
    while (try statement.step() == .row) {
        any = true;
        const kind = statement.columnText(2);
        const match_value = statement.columnText(3);
        const counts = try data.goalCount(arena, ctx.db, view, kind, match_value, view.range.start_ms, view.range.end_ms, true);
        try render(w, "<tr><td class=\"strong\">{name}</td><td class=\"hide-m secondary\">{kind} <span class=\"mono\">{match}</span></td><td class=\"r\">{count}</td><td class=\"r\">{share}</td><td><form method=\"post\" action=\"/{slug}/goals/{id}/delete\" data-undo=\"Goal deleted\"><button class=\"btn btn-quiet btn-icon\" aria-label=\"Delete goal\">", .{
            .name = statement.columnText(1), .kind = if (std.mem.eql(u8, kind, "event")) "Event" else "Page", .match = match_value, .count = html.int(counts.completions), .share = html.share(counts.visitor_days, visitors), .slug = site.slug, .id = statement.columnInt(0),
        });
        try icon(w, "trash");
        try w.writeAll("</button></form></td></tr>");
    }
    try w.writeAll("</tbody></table></div>");
    if (!any) try ui.empty(w, "No goals yet", "Pick an event from the Events tab and choose “Track as goal”, or add a page like <code>/thanks</code>.", "");
    try w.writeAll("</section>");
}

/// Two-sided p-value of a two-proportion z-test.
fn pValue(control_hits: f64, control_n: f64, hits: f64, n: f64) f64 {
    if (control_n == 0 or n == 0) return 1;
    const pooled = (control_hits + hits) / (control_n + n);
    const spread = @sqrt(pooled * (1 - pooled) * (1 / control_n + 1 / n));
    if (spread == 0) return 1;
    const z = @abs(hits / n - control_hits / control_n) / spread;
    // erfc(z/√2) by the Abramowitz–Stegun 7.1.26 approximation.
    const x = z / std.math.sqrt2;
    const t = 1 / (1 + 0.3275911 * x);
    const erfc = t * (0.254829592 + t * (-0.284496736 + t * (1.421413741 + t * (-1.453152027 + t * 1.061405429)))) * @exp(-x * x);
    return std.math.clamp(erfc, 0, 1);
}

/// Experiments: variants come from the site (`analytico.variant(name, variant)`);
/// conversion is reaching the chosen goal after the first exposure, per visit.
fn experiments(ctx: *Ctx, view: data.View, path: []const u8) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    const site = view.site;
    if (!site.linked()) {
        try w.writeAll("<div class=\"card\">");
        try ui.empty(w, "Experiments need Full or Session mode", "Conversions are counted per visit, so page views must be linked into visits.", "");
        try w.writeAll("</div>");
        return;
    }
    const Goal = struct { name: []const u8, event: []const u8 };
    const goal_names = try ctx.db.all(arena, Goal, "SELECT name,match_value FROM goals WHERE site_id=? AND kind='event' ORDER BY name", .{site.id});
    if (goal_names.len == 0) {
        try w.writeAll("<div class=\"card\">");
        try ui.empty(w, "Add an event goal first", "An experiment compares how often each variant reaches a goal. Call <code>analytico.variant('pricing-test', 'b')</code> where the variant is shown.", "");
        try w.writeAll("</div>");
        return;
    }
    const goal_event = ctx.param("goal") orelse goal_names[0].event;
    try render(w, "<form class=\"row mb-14\" method=\"get\" action=\"{path}\"><input type=\"hidden\" name=\"tab\" value=\"experiments\">", .{ .path = path });
    try layout.hiddenState(ctx, view, &.{});
    try w.writeAll("<label class=\"row nowrap\"><span class=\"secondary\">Converts when reaching</span><select class=\"input input-xl\" name=\"goal\" data-autosubmit>");
    for (goal_names) |goal| try render(w, "<option value=\"{value}\"{!selected}>{name}</option>", .{ .value = goal.event, .selected = if (std.mem.eql(u8, goal.event, goal_event)) " selected" else "", .name = goal.name });
    try w.writeAll("</select></label></form>");
    var sql = data.Sql.init(arena);
    try sql.add("WITH x AS (SELECT json_extract(e.properties_json,'$.experiment') ex,json_extract(e.properties_json,'$.variant') va,e.session_id sid,min(e.occurred_at_ms) at FROM events e WHERE ");
    try sql.events(view, view.range.start_ms, view.range.end_ms);
    try sql.add(" AND e.name='experiment_viewed' AND e.session_id IS NOT NULL GROUP BY 1,2,3) SELECT ex,va,count(*),sum(EXISTS(SELECT 1 FROM events g WHERE g.site_id=");
    try sql.int(site.id);
    try sql.add(" AND g.session_id=x.sid AND g.name=");
    try sql.str(goal_event);
    try sql.add(" AND g.occurred_at_ms>=x.at)) FROM x WHERE ex IS NOT NULL AND va IS NOT NULL GROUP BY 1,2 ORDER BY 1,2");
    var statement = try sql.prepare(ctx.db);
    defer statement.deinit();
    const Variant = struct { experiment: []const u8, variant: []const u8, visits: i64, hits: i64 };
    var variants: std.ArrayList(Variant) = .empty;
    while (try statement.step() == .row) try variants.append(arena, .{ .experiment = try arena.dupe(u8, statement.columnText(0)), .variant = try arena.dupe(u8, statement.columnText(1)), .visits = statement.columnInt(2), .hits = statement.columnInt(3) });
    if (variants.items.len == 0) {
        try w.writeAll("<div class=\"card\">");
        try ui.empty(w, "No experiments in this period", "Call <code>analytico.variant('pricing-test', 'b')</code> when a visitor sees a variant. Assigning variants stays in your code; Analytico only measures.", "");
        try w.writeAll("</div>");
        return;
    }
    var index: usize = 0;
    while (index < variants.items.len) {
        const experiment = variants.items[index].experiment;
        var end = index;
        while (end < variants.items.len and std.mem.eql(u8, variants.items[end].experiment, experiment)) end += 1;
        const group = variants.items[index..end];
        const control = group[0];
        try render(w, "<section class=\"card card-flush mb-16\"><div class=\"card-head table-head\"><h2 class=\"mono\">{experiment}</h2><span class=\"meta\">Control: {control}</span></div><div class=\"table-wrap\"><table class=\"table\"><thead><tr><th>Variant</th><th class=\"r\">Visits</th><th class=\"r\">Converted</th><th class=\"r\">Rate</th><th class=\"r\">vs control</th><th class=\"r\">Confidence</th></tr></thead><tbody>", .{ .experiment = experiment, .control = control.variant });
        for (group, 0..) |variant, position| {
            const rate = @as(f64, @floatFromInt(variant.hits)) / @as(f64, @floatFromInt(@max(variant.visits, 1))) * 100;
            const control_rate = @as(f64, @floatFromInt(control.hits)) / @as(f64, @floatFromInt(@max(control.visits, 1))) * 100;
            try render(w, "<tr><td class=\"strong\">{variant}</td><td class=\"r\">{visits}</td><td class=\"r\">{hits}</td><td class=\"r\">{rate:.1}%</td><td class=\"r\">", .{ .variant = variant.variant, .visits = html.int(variant.visits), .hits = html.int(variant.hits), .rate = rate });
            if (position == 0) {
                try w.writeAll("<span class=\"muted\">—</span></td><td class=\"r\"><span class=\"muted\">—</span>");
            } else {
                try ui.delta(w, rate, control_rate, false);
                const p = pValue(@floatFromInt(control.hits), @floatFromInt(control.visits), @floatFromInt(variant.hits), @floatFromInt(variant.visits));
                const confidence = (1 - p) * 100;
                try render(w, "</td><td class=\"r\"><span class=\"pill {class}\">{confidence:.0}%{note}</span>", .{ .class = if (confidence >= 95) "pill-good" else "pill-plain", .confidence = confidence, .note = if (confidence >= 95) " · significant" else "" });
            }
            try w.writeAll("</td></tr>");
        }
        try w.writeAll("</tbody></table></div><div class=\"card-foot\"><span>Two-proportion z-test against the first variant; 95% or more is treated as a real difference</span></div></section>");
        index = end;
    }
}

fn goalDialog(ctx: *Ctx, site: data.Site, preset: []const u8) !void {
    if (preset.len == 0) return;
    const w = ctx.w();
    const is_new = std.mem.eql(u8, preset, "+");
    const is_path = !is_new and preset[0] == '/';
    var suggested: std.ArrayList(u8) = .empty;
    if (!is_new) for (preset) |byte| {
        try suggested.append(ctx.arena, if (byte == '_' or byte == '-') ' ' else byte);
    };
    if (suggested.items.len != 0) suggested.items[0] = std.ascii.toUpper(suggested.items[0]);
    try render(w, "<dialog class=\"dialog\" id=\"goal-dialog\" data-open data-close-href=\"/{slug}/events?tab=goals\"><form method=\"post\" action=\"/{slug}/goals\"><div class=\"dialog-head\"><div><h2>Track as goal</h2><p>Count this as a conversion everywhere: overview, funnels and campaigns.</p></div><button class=\"btn btn-quiet btn-icon close\" type=\"button\" data-close aria-label=\"Close\">", .{ .slug = site.slug });
    try icon(w, "x");
    try render(w,
        \\</button></div><div class="dialog-body"><label class="field">Goal name<input class="input" name="label" value="{name}" required maxlength="64" placeholder="Newsletter signup"></label>
        \\<div class="option-cards"><label class="option-card"><input type="radio" name="kind" value="event"{!event}><strong>Event</strong><small>A custom event, e.g. signup</small></label><label class="option-card"><input type="radio" name="kind" value="path"{!page}><strong>Page visit</strong><small>Reaching a page, e.g. /thanks</small></label></div>
        \\<label class="field">Matches<input class="input mono" name="match" value="{match}" required maxlength="512"></label></div>
        \\<div class="dialog-foot"><button class="btn" type="button" data-close>Cancel</button><button class="btn btn-primary">Track goal</button></div></form></dialog>
    , .{ .name = suggested.items, .event = if (!is_path) " checked" else "", .page = if (is_path) " checked" else "", .match = if (is_new) "" else preset });
}

/// Goal names are display labels; the stored identifier is derived from them.
fn goalIdentifier(arena: std.mem.Allocator, label: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (label) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.' or byte == ':') {
            try out.append(arena, byte);
        } else if (byte == ' ' and out.items.len != 0 and out.items[out.items.len - 1] != ' ') try out.append(arena, ' ');
        if (out.items.len == 64) break;
    }
    return std.mem.trim(u8, out.items, " ");
}

pub fn addGoal(ctx: *Ctx, site: data.Site) !void {
    const label = try goalIdentifier(ctx.arena, std.mem.trim(u8, try ctx.field("label"), " "));
    const kind = try ctx.field("kind");
    const match_value = std.mem.trim(u8, try ctx.field("match"), " ");
    if (label.len == 0) return overview.failBack(ctx, site, "Give the goal a name.");
    if (std.mem.eql(u8, kind, "event")) {
        domain.validateName(match_value) catch return overview.failBack(ctx, site, "Event names use letters, numbers, _ - . and :.");
    } else if (std.mem.eql(u8, kind, "path")) {
        domain.validatePath(match_value) catch return overview.failBack(ctx, site, "Pages start with / and have no query string.");
    } else return overview.failBack(ctx, site, "Choose an event or a page.");
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    db.run(ctx.arena, "INSERT INTO goals(site_id,name,kind,match_value,created_at_ms) VALUES(?,?,?,?,?)", .{ site.id, label, kind, match_value, ctx.now() }) catch
        return overview.failBack(ctx, site, "A goal with that name already exists.");
    try ctx.flash(try std.fmt.allocPrint(ctx.arena, "Tracking “{s}” as a goal.", .{label}), "View goals", try std.fmt.allocPrint(ctx.arena, "/{s}/events?tab=goals", .{site.slug}));
    return ctx.redirectFmt("/{s}/events?tab=goals", .{site.slug});
}

pub fn deleteGoal(ctx: *Ctx, site: data.Site, id: i64) !void {
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    try db.run(ctx.arena, "DELETE FROM goals WHERE id=? AND site_id=?", .{ id, site.id });
    return ctx.done("Goal deleted.", "/{s}/events?tab=goals", .{site.slug});
}

// Funnels, sessions, audience and performance live in journeys.zig.
const journeys = @import("journeys.zig");
pub const funnels = journeys.funnels;
pub const addFunnel = journeys.addFunnel;
pub const deleteFunnel = journeys.deleteFunnel;
pub const funnelAction = journeys.funnelAction;
pub const sessions = @import("behaviour.zig").sessions;
pub const audience = journeys.audience;
pub const performance = journeys.performance;

test "experiment significance" {
    try std.testing.expect(pValue(100, 1000, 150, 1000) < 0.01);
    try std.testing.expect(pValue(100, 1000, 102, 1000) > 0.5);
}

test "money parsing" {
    try std.testing.expectEqual(@as(i64, 120050), try parseMoney("1,200.5"));
    try std.testing.expectEqual(@as(i64, 600), try parseMoney("6"));
    try std.testing.expectError(error.InvalidAmount, parseMoney("1.234"));
}
