//! Workspace shell: document head, sidebar, mobile tab bar, page head and the
//! shared view controls (range, compare, filter, actions).
const std = @import("std");
const assets = @import("../assets.zig");
const ctx_mod = @import("ctx.zig");
const data = @import("data.zig");
const html = @import("html.zig");

const Ctx = ctx_mod.Ctx;
const esc = html.esc;
const render = html.render;

pub const Nav = enum { overview, dashboards, reports, pages, acquisition, search, audience, events, funnels, sessions, heatmaps, revenue, retention, people, performance, errors, health, settings, setup, none };

pub const Shell = struct {
    title: []const u8,
    nav: Nav = .none,
    site: ?data.Site = null,
    sites: []const data.Site = &.{},
    /// Query string carried by navigation links (range, compare, filters).
    carry: []const u8 = "",
    /// The page shows a range and filters (the browser remembers them).
    has_view: bool = false,
    health: Health = .ok,
    /// Full mode: share of the last 7 days' page views with consent.
    consented: ?f64 = null,
};

pub const Health = enum { ok, warn, bad };

pub fn icon(w: *std.Io.Writer, name: []const u8) !void {
    try render(w, "<svg class=\"i\" aria-hidden=\"true\"><use href=\"{sprite}#{name}\"/></svg>", .{ .sprite = assets.path("icons.svg"), .name = name });
}

pub fn document(ctx: *Ctx, title: []const u8) !void {
    try render(ctx.w(),
        \\<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        \\<title>{title}</title><meta name="theme-color" content="#F7F5F4"><link rel="icon" href="{favicon}" type="image/svg+xml">
        \\<link rel="preload" href="{roboto}" as="font" type="font/woff2" crossorigin><link rel="preload" href="{quando}" as="font" type="font/woff2" crossorigin>
        \\<link rel="stylesheet" href="{css}"><script src="{js}" defer></script></head><body>
    , .{ .title = title, .favicon = assets.path("favicon.svg"), .roboto = assets.path("roboto.woff2"), .quando = assets.path("quando.woff2"), .css = assets.path("app.css"), .js = assets.path("app.js") });
}

pub fn begin(ctx: *Ctx, shell: Shell) !void {
    ctx.shell = shell;
    const w = ctx.w();
    var title_buffer: [256]u8 = undefined;
    const full_title = if (shell.site) |site|
        std.fmt.bufPrint(&title_buffer, "{s} · {s} · Analytico", .{ shell.title, site.title() }) catch shell.title
    else
        std.fmt.bufPrint(&title_buffer, "{s} · Analytico", .{shell.title}) catch shell.title;
    try document(ctx, full_title);
    try render(w, "<div class=\"app\" id=\"app\"><nav class=\"sidebar\" aria-label=\"Workspace\"><a class=\"brand\" href=\"/\"><img src=\"{logo}\" alt=\"\"><span>Analytico</span></a>", .{ .logo = assets.path("favicon.svg") });
    if (shell.site) |site| {
        try render(w,
            \\<button class="site-switch" popovertarget="site-menu" aria-label="Switch website"><span class="site-avatar">{initial}</span><div><strong>{title}</strong><small>{host}</small></div>
        , .{ .initial = &[_]u8{site.initial()}, .title = site.title(), .host = site.host() });
        try icon(w, "chevrons-up-down");
        try w.writeAll("</button><div id=\"site-menu\" popover class=\"pop\" data-anchor=\".site-switch\"><div class=\"menu-label\">Websites</div>");
        for (shell.sites) |other| {
            try render(w, "<a class=\"menu-item\" href=\"/{slug}\"><span class=\"site-avatar site-avatar-s\">{initial}</span>{title}", .{ .slug = other.slug, .initial = &[_]u8{other.initial()}, .title = other.title() });
            if (other.id == site.id) try icon(w, "check");
            try w.writeAll("</a>");
        }
        try w.writeAll("<div class=\"menu-sep\"></div><a class=\"menu-item\" href=\"/setup\">");
        try icon(w, "plus");
        try w.writeAll("Add a website</a></div><button class=\"search-trigger\" data-palette type=\"button\">");
        try icon(w, "sparkles");
        try w.writeAll("<span>Search or ask…</span><kbd>⌘K</kbd></button>");
        const groups = [_]struct { []const u8, []const struct { Nav, []const u8, []const u8, []const u8 } }{
            .{ "", &.{ .{ .overview, "", "overview", "Overview" }, .{ .dashboards, "/dashboards", "dashboards", "Dashboards" }, .{ .reports, "/reports", "reports", "Reports & alerts" } } },
            .{ "Traffic", &.{ .{ .pages, "/pages", "pages", "Pages" }, .{ .acquisition, "/acquisition", "sources", "Acquisition" }, .{ .search, "/search", "search", "Search" }, .{ .audience, "/audience", "map-pin", "Audience" } } },
            .{ "Behaviour", &.{ .{ .events, "/events", "events", "Events & goals" }, .{ .funnels, "/funnels", "funnels", "Funnels" }, .{ .sessions, "/sessions", "play-circle", "Sessions & replays" }, .{ .heatmaps, "/heatmaps", "heatmap", "Heatmaps" } } },
            .{ "Customers", &.{ .{ .revenue, "/revenue", "revenue", "Revenue" }, .{ .retention, "/retention", "retention", "Retention" }, .{ .people, "/people", "people", "People" } } },
            .{ "Quality", &.{ .{ .performance, "/performance", "performance", "Performance" }, .{ .errors, "/errors", "bug", "Errors" } } },
        };
        for (groups) |group| {
            if (group[0].len != 0) try render(w, "<div class=\"nav-group\">{name}</div>", .{ .name = group[0] });
            for (group[1]) |item| {
                try render(w, "<a class=\"nav\" href=\"/{slug}{suffix}{!carry}\"{!current}>", .{ .slug = site.slug, .suffix = item[1], .carry = try std.fmt.allocPrint(ctx.arena, "{f}", .{esc(shell.carry)}), .current = current(shell.nav == item[0]) });
                try icon(w, item[2]);
                try render(w, "<span>{label}</span></a>", .{ .label = item[3] });
            }
        }
    }
    try w.writeAll("<div class=\"sidebar-foot\">");
    if (shell.site) |site| {
        try render(w, "<a class=\"nav\" href=\"/{slug}/health\"{!current}>", .{ .slug = site.slug, .current = current(shell.nav == .health) });
        try icon(w, "quality");
        try render(w, "<span>Data health</span><i class=\"dot {state}\"></i></a>", .{ .state = switch (shell.health) {
            .ok => "",
            .warn => "warn",
            .bad => "bad",
        } });
    }
    try render(w, "<a class=\"nav\" href=\"/settings{query}\"{!current}>", .{ .query = if (shell.site) |site| try std.fmt.allocPrint(ctx.arena, "?site={s}", .{site.slug}) else "", .current = current(shell.nav == .settings) });
    try icon(w, "settings");
    try w.writeAll("<span>Settings</span></a>");
    if (shell.site) |site| {
        if (!site.enabled) {
            try render(w, "<div class=\"sidebar-meta\">{mode} · Paused · UTC</div>", .{ .mode = site.modeLabel() });
        } else if (shell.consented) |share| {
            try render(w, "<div class=\"sidebar-meta\" title=\"Page views with consent in the last 7 days\">Full · {share:.0}% consented · UTC</div>", .{ .share = share * 100 });
        } else try render(w, "<div class=\"sidebar-meta\">{mode} · UTC · Collecting</div>", .{ .mode = site.modeLabel() });
    }
    try w.writeAll("</div></nav>");
    if (shell.site) |site| {
        try render(w, "<main class=\"main\" data-site=\"{slug}\"{!view}>", .{ .slug = site.slug, .view = if (shell.has_view) try html.print(ctx.arena, " data-view=\"{carry}\"", .{ .carry = shell.carry }) else "" });
    } else try w.writeAll("<main class=\"main\">");
    try w.writeAll("<div class=\"panel\" id=\"panel\">");
}

fn current(yes: bool) []const u8 {
    return if (yes) " aria-current=\"page\"" else "";
}

/// Closes the page opened by `begin`, with the same shell, and sends it.
pub fn end(ctx: *Ctx) !void {
    const shell = ctx.shell.?;
    const w = ctx.w();
    try w.writeAll("</div></main>");
    if (shell.site) |site| {
        try w.writeAll("<nav class=\"tabbar\" aria-label=\"Sections\">");
        const Tab = struct { Nav, []const u8, []const u8, []const u8 };
        // Full mode puts replays and people within reach; other modes keep sources and alerts.
        const tabs: []const Tab = if (site.mode == .full) &.{
            .{ .overview, "", "overview", "Overview" },
            .{ .pages, "/pages", "pages", "Pages" },
            .{ .sessions, "/sessions", "play-circle", "Replays" },
            .{ .people, "/people", "people", "People" },
            .{ .settings, "", "menu", "More" },
        } else &.{
            .{ .overview, "", "overview", "Overview" },
            .{ .pages, "/pages", "pages", "Pages" },
            .{ .acquisition, "/acquisition", "sources", "Sources" },
            .{ .reports, "/reports", "reports", "Alerts" },
            .{ .settings, "", "menu", "More" },
        };
        for (tabs) |tab| {
            try render(w, "<a href=\"{href}\"{!current}>", .{
                .href = if (tab[0] == .settings) try std.fmt.allocPrint(ctx.arena, "/settings?site={s}", .{site.slug}) else try std.fmt.allocPrint(ctx.arena, "/{s}{s}{s}", .{ site.slug, tab[1], shell.carry }),
                .current = current(shell.nav == tab[0]),
            });
            try icon(w, tab[2]);
            try render(w, "{label}</a>", .{ .label = tab[3] });
        }
        try w.writeAll("</nav>");
    }
    if (shell.site) |site| if (ctx.param("ask")) |id| try @import("ai.zig").askSheet(ctx, site, id);
    try w.writeAll("</div><div id=\"toasts\" aria-live=\"polite\">");
    if (try ctx.takeFlash()) |flash| try toast(w, flash);
    try w.writeAll("</div>");
    if (shell.site) |site| {
        try render(w,
            \\<dialog class="palette" id="palette" data-source="/{slug}/palette.json" data-ask="/{slug}/ask" aria-label="Search or ask"><div class="palette-input">
        , .{ .slug = site.slug });
        try icon(w, "search");
        try w.writeAll(
            \\<input type="text" placeholder="Search pages, sources, settings — or ask a question" autocomplete="off" spellcheck="false" aria-label="Search or ask"><kbd>esc</kbd></div><div class="palette-list" role="listbox" aria-label="Results"></div>
            \\<div class="palette-foot">↑↓ to move · ↵ to open · questions go to your AI provider</div></dialog>
        );
    }
    try w.writeAll("</body></html>");
    return ctx.html();
}

pub fn toast(w: *std.Io.Writer, flash: Ctx.Flash) !void {
    const is_error = std.mem.startsWith(u8, flash.message, "!");
    try render(w, "<div class=\"toast{!error}\" role=\"status\">", .{ .@"error" = if (is_error) " error" else "" });
    try icon(w, if (is_error) "alert" else "check");
    try render(w, "<span>{text}</span>", .{ .text = if (is_error) flash.message[1..] else flash.message });
    if (flash.action_label.len != 0 and flash.action_href.len != 0) {
        if (std.mem.startsWith(u8, flash.action_href, "post:")) {
            try render(w, "<form method=\"post\" action=\"{action}\"><button>{label}</button></form>", .{ .action = flash.action_href[5..], .label = flash.action_label });
        } else try render(w, "<a href=\"{href}\">{label}</a>", .{ .href = flash.action_href, .label = flash.action_label });
    }
    try w.writeAll("</div>");
}

/// Title row. `controls` draws the range/compare/filter/actions cluster.
pub const Head = struct {
    title: []const u8,
    /// Raw HTML (already escaped) after the title, e.g. the live pill.
    badge: []const u8 = "",
    /// Text, escaped here.
    subtitle: []const u8 = "",
    view: ?data.View = null,
    path: []const u8 = "",
    filter: bool = true,
    compare: bool = true,
    actions: bool = true,
    /// Raw HTML for extra buttons placed before the view controls.
    extra: []const u8 = "",
};

pub fn head(ctx: *Ctx, options: Head) !void {
    const w = ctx.w();
    try render(w, "<header class=\"head\"><div class=\"head-text\"><div class=\"title-row\"><h1 class=\"title\">{title}</h1>{!badge}</div>", .{ .title = options.title, .badge = options.badge });
    if (options.subtitle.len != 0) try render(w, "<p class=\"subtitle\">{subtitle}</p>", .{ .subtitle = options.subtitle });
    try w.writeAll("</div><div class=\"controls\">");
    try w.writeAll(options.extra);
    if (options.view) |view| try controls(ctx, view, options);
    try w.writeAll("</div></header>");
    if (options.view) |view| try chips(ctx, view, options.path);
}

fn controls(ctx: *Ctx, view: data.View, options: Head) !void {
    const w = ctx.w();
    const arena = ctx.arena;
    try w.writeAll("<nav class=\"seg\" aria-label=\"Date range\">");
    for ([_]data.RangeKind{ .@"24h", .@"7d", .@"30d", .@"90d" }) |kind| try render(w, "<a href=\"{href}\"{!current}>{label}</a>", .{
        .href = try view.href(arena, options.path, &.{ .{ "range", @tagName(kind) }, .{ "from", "" }, .{ "to", "" } }),
        .current = if (view.range.kind == kind) " aria-current=\"true\"" else "",
        .label = kind,
    });
    try render(w, "<button type=\"button\" popovertarget=\"range-pop\" aria-label=\"Custom range\"{!current}>", .{ .current = if (view.range.kind == .custom) " aria-current=\"true\"" else "" });
    try icon(w, "calendar");
    try render(w,
        \\</button></nav><div id="range-pop" popover class="pop" data-anchor="[popovertarget=range-pop]"><form method="get" action="{path}" class="pop-section form-grid pop-280">
        \\<input type="hidden" name="range" value="custom">
    , .{ .path = options.path });
    try hiddenState(ctx, view, &.{ "range", "from", "to" });
    try render(w,
        \\<label class="field">From<input class="input" type="date" name="from" value="{from}" required></label>
        \\<label class="field">To<input class="input" type="date" name="to" value="{to}" required></label>
        \\<button class="btn btn-primary">Apply range</button></form></div>
    , .{ .from = &data.dateText(view.range.start_ms), .to = &data.dateText(view.range.end_ms - 1) });
    if (options.compare) {
        try render(w, "<a class=\"btn\" href=\"{href}\" role=\"button\" aria-label=\"Compare\" aria-pressed=\"{pressed}\">", .{ .href = try view.href(arena, options.path, &.{.{ "cmp", if (view.compare) "0" else "" }}), .pressed = if (view.compare) "true" else "false" });
        try icon(w, "compare");
        try w.writeAll("<span class=\"btn-label\">Compare</span></a>");
    }
    if (options.filter) try filterPopover(ctx, view, options.path);
    if (options.actions) try actionsMenu(ctx, view, options.path);
}

/// Hidden inputs that keep view state across a GET form.
pub fn hiddenState(ctx: *Ctx, view: data.View, skip: []const []const u8) !void {
    const w = ctx.w();
    const keys = [_][]const u8{ "range", "from", "to", "cmp", "m", "fm" };
    outer: for (keys) |key| {
        for (skip) |name| if (std.mem.eql(u8, name, key)) continue :outer;
        if (view.params.get(key)) |value| try render(w, "<input type=\"hidden\" name=\"{key}\" value=\"{value}\">", .{ .key = key, .value = value });
    }
    for (skip) |name| if (std.mem.eql(u8, name, "f")) return;
    for (view.filters) |filter| try render(w, "<input type=\"hidden\" name=\"f\" value=\"{filter}\">", .{ .filter = try std.fmt.allocPrint(ctx.arena, "{f}", .{filter}) });
}

fn filterPopover(ctx: *Ctx, view: data.View, path: []const u8) !void {
    const w = ctx.w();
    try render(w, "<button class=\"btn\" type=\"button\" popovertarget=\"filter-pop\" aria-label=\"Filter\"{!pressed}>", .{ .pressed = if (view.filters.len != 0) " aria-pressed=\"true\"" else "" });
    try icon(w, "filter");
    try render(w,
        \\<span class="btn-label">Filter</span></button><div id="filter-pop" popover class="pop pop-wide" data-anchor="[popovertarget=filter-pop]"><form method="get" action="{path}" data-filter-form data-match="/{slug}/match.json">
    , .{ .path = path, .slug = view.site.slug });
    try hiddenState(ctx, view, &.{ "f", "fm" });
    try render(w,
        \\<div class="pop-section" data-describe="/{slug}/describe"><div class="row nowrap"><input class="input grow" data-describe-q maxlength="200" autocomplete="off" placeholder="Describe them: mobile visitors from Germany last month" aria-label="Describe the visitors"><button type="button" class="btn" data-describe-go>Go</button></div><div class="mt-10" data-describe-out hidden></div></div>
    , .{ .slug = view.site.slug });
    try render(w,
        \\<div class="pop-section"><div class="row-between mb-14"><strong class="t-13">Show visitors where</strong>
        \\<div class="seg"><label class="contents"><input class="sr" type="radio" name="fm" value="all"{!all}><span data-seg>all</span></label><label class="contents"><input class="sr" type="radio" name="fm" value="any"{!any}><span data-seg>any</span></label></div></div>
        \\<div class="form-grid gap-8" data-conditions>
    , .{ .all = if (!view.any) " checked" else "", .any = if (view.any) " checked" else "" });
    const rows = if (view.filters.len == 0) &[_]data.Filter{.{ .dim = .source, .value = "" }} else view.filters;
    for (rows) |filter| try conditionRow(w, filter);
    try w.writeAll("</div><button type=\"button\" class=\"link add-condition\" data-add-condition>");
    try icon(w, "plus");
    try w.writeAll(
        \\Add condition</button><div class="callout mt-10" data-match-out hidden></div></div>
        \\<datalist id="filter-values"></datalist><div class="pop-section row-between">
    );
    if (view.filters.len != 0) {
        try w.writeAll("<button class=\"btn btn-quiet\" type=\"button\" data-dialog=\"segment-dialog\">");
        try icon(w, "bookmark");
        try w.writeAll("Save as segment</button>");
    } else {
        try segmentLinks(ctx, view, path);
    }
    try w.writeAll("<button class=\"btn btn-primary\">Apply</button></div></form></div>");
}

fn segmentLinks(ctx: *Ctx, view: data.View, path: []const u8) !void {
    const w = ctx.w();
    try w.writeAll("<div class=\"row gap-6\">");
    const segments = try ctx.db.all(ctx.arena, struct { name: []const u8, filters: []const u8 }, "SELECT name,filters FROM segments WHERE site_id=? ORDER BY name LIMIT 6", .{view.site.id});
    if (segments.len != 0) try w.writeAll("<span class=\"hint\">Segments:</span>");
    for (segments) |segment| try render(w, "<a class=\"chip chip-plain\" href=\"{path}{separator}{filters}\">{name}</a>", .{ .path = path, .separator = if (std.mem.findScalar(u8, path, '?') == null) "?" else "&", .filters = segment.filters, .name = segment.name });
    try w.writeAll("</div>");
}

pub fn conditionRow(w: *std.Io.Writer, filter: data.Filter) !void {
    try w.writeAll("<div class=\"cond\" data-condition><select class=\"input\" data-dim aria-label=\"Dimension\">");
    for (std.enums.values(data.Dim)) |dim| try render(w, "<option value=\"{value}\"{!selected}>{label}</option>", .{ .value = dim, .selected = if (dim == filter.dim) " selected" else "", .label = dim.label() });
    try render(w,
        \\</select><div class="row nowrap"><select class="input input-op" data-op aria-label="Comparison"><option value=""{!is}>is</option><option value="!"{!not}>is not</option></select>
        \\<input class="input" data-value list="filter-values" value="{value}" placeholder="Value" autocomplete="off"></div>
        \\<button type="button" class="btn btn-quiet btn-icon" data-remove-condition aria-label="Remove condition">
    , .{ .is = if (!filter.negate) " selected" else "", .not = if (filter.negate) " selected" else "", .value = filter.value });
    try icon(w, "x");
    try w.writeAll("</button><input type=\"hidden\" name=\"f\" data-encoded></div>");
}

fn actionsMenu(ctx: *Ctx, view: data.View, path: []const u8) !void {
    const w = ctx.w();
    const site = view.site;
    try w.writeAll("<button class=\"btn btn-icon\" type=\"button\" popovertarget=\"actions-pop\" aria-label=\"More actions\">");
    try icon(w, "more");
    try w.writeAll("</button><div id=\"actions-pop\" popover class=\"pop\" data-anchor=\"[popovertarget=actions-pop]\"><button class=\"menu-item accent\" type=\"button\" data-palette data-ask-view>");
    try icon(w, "sparkles");
    try render(w, "Ask about this view…<kbd>⌘J</kbd></button><div class=\"menu-sep\"></div><a class=\"menu-item\" href=\"{href}\" download>", .{ .href = try view.href(ctx.arena, try std.fmt.allocPrint(ctx.arena, "/{s}/export.csv", .{site.slug}), &.{.{ "view", path }}) });
    try icon(w, "download");
    try w.writeAll("Download CSV</a><button class=\"menu-item\" type=\"button\" data-print>");
    try icon(w, "print");
    try w.writeAll("Download PDF</button><div class=\"menu-sep\"></div><button class=\"menu-item\" type=\"button\" data-dialog=\"schedule-dialog\">");
    try icon(w, "mail");
    try w.writeAll("Schedule email…</button><button class=\"menu-item\" type=\"button\" data-dialog=\"alert-dialog\">");
    try icon(w, "bell-plus");
    try w.writeAll("Create alert…</button><button class=\"menu-item\" type=\"button\" data-dialog=\"note-dialog\">");
    try icon(w, "pin");
    try w.writeAll("Add a note…</button>");
    const on_overview = std.mem.eql(u8, path, try std.fmt.allocPrint(ctx.arena, "/{s}", .{site.slug}));
    if (ctx.can(.admin) and on_overview) {
        try w.writeAll("<div class=\"menu-sep\"></div><button class=\"menu-item\" type=\"button\" data-dialog=\"share-dialog\">");
        try icon(w, "share");
        try w.writeAll("Share publicly…</button>");
    }
    if (view.filters.len != 0) {
        try w.writeAll("<button class=\"menu-item\" type=\"button\" data-dialog=\"segment-dialog\">");
        try icon(w, "bookmark");
        try w.writeAll("Save as segment…</button>");
    }
    try w.writeAll("</div>");
    try viewDialogs(ctx, view, path);
    if (ctx.can(.admin) and on_overview) try @import("share.zig").dialog(ctx, site, null, try std.fmt.allocPrint(ctx.arena, "{s} overview", .{site.title()}));
}

/// Human description of the view: "Last 7 days · Source is Google".
pub fn viewSummary(arena: std.mem.Allocator, view: data.View) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    switch (view.range.kind) {
        .@"24h" => try w.writeAll("Last 24 hours"),
        .@"7d" => try w.writeAll("Last 7 days"),
        .@"30d" => try w.writeAll("Last 30 days"),
        .@"90d" => try w.writeAll("Last 90 days"),
        .custom => try w.print("{f}", .{view.range}),
    }
    for (view.filters, 0..) |filter, index| {
        try w.writeAll(if (index == 0) " · " else if (view.any) " or " else " and ");
        try w.print("{s} {s} {s}", .{ filter.dim.label(), if (filter.negate) "is not" else "is", filter.value });
    }
    return out.written();
}

fn dialogHead(w: *std.Io.Writer, title: []const u8, subtitle: []const u8) !void {
    try render(w, "<div class=\"dialog-head\"><div><h2>{title}</h2><p>{subtitle}</p></div><button class=\"btn btn-quiet btn-icon close\" type=\"button\" data-close aria-label=\"Close\">", .{ .title = title, .subtitle = subtitle });
    try icon(w, "x");
    try w.writeAll("</button></div>");
}

fn viewDialogs(ctx: *Ctx, view: data.View, path: []const u8) !void {
    const w = ctx.w();
    const site = view.site;
    const summary = try viewSummary(ctx.arena, view);
    const view_query = try view.href(ctx.arena, path, &.{});
    // Schedule this view.
    try render(w, "<dialog class=\"dialog\" id=\"schedule-dialog\"><form method=\"post\" action=\"/{slug}/schedules\">", .{ .slug = site.slug });
    try dialogHead(w, "Schedule this view", "A summary of exactly this view, delivered by email.");
    try render(w,
        \\<div class="dialog-body"><span class="chip self-start">{summary}</span><input type="hidden" name="view" value="{view}">
        \\<label class="field">Name<input class="input" name="name" value="{name} weekly" required maxlength="80"></label>
        \\<div class="grid grid-3 gap-8"><label class="field">Every<select class="input" name="frequency"><option value="weekly" selected>Week</option><option value="daily">Day</option><option value="monthly">Month</option></select></label>
        \\<label class="field">On<select class="input" name="weekday"><option value="0">Monday</option><option value="1">Tuesday</option><option value="2">Wednesday</option><option value="3">Thursday</option><option value="4">Friday</option><option value="5">Saturday</option><option value="6">Sunday</option></select></label>
        \\<label class="field">At (UTC)<select class="input" name="hour">
    , .{ .summary = summary, .view = view_query, .name = site.title() });
    for (0..24) |hour| try render(w, "<option value=\"{hour}\"{!selected}>{label}:00</option>", .{ .hour = hour, .selected = if (hour == 9) " selected" else "", .label = try std.fmt.allocPrint(ctx.arena, "{d:0>2}", .{hour}) });
    try render(w,
        \\</select></label></div><label class="field">Send to<input class="input" name="recipients" value="{email}" required placeholder="name@example.com, team@example.com"><small>Separate addresses with commas.</small></label></div>
        \\<div class="dialog-foot"><button class="btn" type="button" data-close>Cancel</button><button class="btn btn-primary">Schedule</button></div></form></dialog>
        \\<dialog class="dialog" id="alert-dialog"><form method="post" action="/{slug}/alerts" data-alert-form data-preview="/{slug}/alert-preview.json">
    , .{ .email = if (ctx.user) |user| user.email else "", .slug = site.slug });
    // Create alert.
    try dialogHead(w, "Create alert", "Get notified when this view changes unexpectedly.");
    const event = view.params.get("event");
    const alert_filters = if (event) |name| try std.fmt.allocPrint(ctx.arena, "{s}{s}event={f}", .{ try filterQuery(ctx.arena, view), if (view.filters.len == 0) "" else "&", html.url(name) }) else try filterQuery(ctx.arena, view);
    try render(w,
        \\<div class="dialog-body"><span class="chip self-start">{summary}</span><input type="hidden" name="filters" value="{filters}">
        \\<div><div class="field mb-6">Notify me when</div><div class="row nowrap">
        \\<select class="input" name="metric"><option value="page_views">Page views</option><option value="visitors">Visitors</option><option value="events"{!event}>{events}</option></select>
        \\<select class="input" name="direction"><option value="drops">drops by</option><option value="rises">rises by</option></select>
        \\<input class="input input-number" name="threshold" type="number" min="1" max="1000" value="20" aria-label="Percent"><span class="secondary nobreak">% vs previous day</span></div></div>
        \\<div class="card on-canvas" data-alert-preview><div class="hint">PREVIEW · LAST 30 DAYS</div><svg class="spark spark-preview" viewBox="0 0 300 60" preserveAspectRatio="none"></svg><p class="hint ink" data-alert-verdict>Checking the last 30 days…</p></div>
        \\<input class="input" name="name" value="{name}" aria-label="Alert name" required maxlength="80">
        \\<div><div class="field mb-8">Send to</div><div class="row gap-24"><label class="check"><input type="checkbox" checked disabled>In-app inbox</label><label class="check"><input type="checkbox" name="email" value="1" checked>Email the team</label></div></div></div>
        \\<div class="dialog-foot"><button class="btn" type="button" data-close>Cancel</button><button class="btn btn-primary">Create alert</button></div></form></dialog>
        \\<dialog class="dialog" id="note-dialog"><form method="post" action="/{slug}/annotations">
    , .{
        .summary = if (event) |name| try std.fmt.allocPrint(ctx.arena, "{s} · Event {s}", .{ summary, name }) else summary,
        .filters = alert_filters,
        .event = if (event != null) " selected" else "",
        .events = if (event != null) "This event" else "Events",
        .name = try alertName(ctx.arena, view, event),
        .slug = site.slug,
    });
    // Note (annotation).
    try dialogHead(w, "Add a note", "Notes appear on every chart — launches, newsletters, outages.");
    try render(w,
        \\<div class="dialog-body"><label class="field">Day<input class="input" type="date" name="day" value="{today}" required></label>
        \\<label class="field">Note<input class="input" name="label" required maxlength="60" placeholder="Newsletter sent"></label></div>
        \\<div class="dialog-foot"><button class="btn" type="button" data-close>Cancel</button><button class="btn btn-primary">Add note</button></div></form></dialog>
    , .{ .today = &data.dateText(view.range.now_ms) });
    if (view.filters.len != 0) {
        try render(w, "<dialog class=\"dialog\" id=\"segment-dialog\"><form method=\"post\" action=\"/{slug}/segments\">", .{ .slug = site.slug });
        try dialogHead(w, "Save as segment", "Reuse these filters from the filter menu on every page.");
        try render(w,
            \\<div class="dialog-body"><span class="chip self-start">{summary}</span><input type="hidden" name="filters" value="{filters}"><input type="hidden" name="back" value="{back}">
            \\<label class="field">Name<input class="input" name="name" required maxlength="60" placeholder="Mobile visitors from Germany"></label></div>
            \\<div class="dialog-foot"><button class="btn" type="button" data-close>Cancel</button><button class="btn btn-primary">Save segment</button></div></form></dialog>
        , .{ .summary = summary, .filters = try filterQuery(ctx.arena, view), .back = view_query });
    }
}

fn alertName(arena: std.mem.Allocator, view: data.View, event: ?[]const u8) ![]const u8 {
    if (event) |name| return std.fmt.allocPrint(arena, "{s} changes", .{name});
    if (view.filters.len == 0) return "Traffic change";
    const filter = view.filters[0];
    return std.fmt.allocPrint(arena, "Traffic change · {s} {s} {s}", .{ filter.dim.label(), if (filter.negate) "is not" else "is", filter.value });
}

/// "f=source%3Agoogle&fm=any" — the filter part of a view as a query string.
pub fn filterQuery(arena: std.mem.Allocator, view: data.View) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (view.filters, 0..) |filter, index| {
        try out.writer.print("{s}f={f}", .{ if (index == 0) "" else "&", html.url(try std.fmt.allocPrint(arena, "{f}", .{filter})) });
    }
    if (view.any and view.filters.len > 1) try out.writer.writeAll("&fm=any");
    return out.written();
}

fn chips(ctx: *Ctx, view: data.View, path: []const u8) !void {
    if (view.filters.len == 0) return;
    const w = ctx.w();
    try w.writeAll("<div class=\"chips\">");
    for (view.filters, 0..) |filter, index| {
        if (index != 0) try render(w, "<span class=\"hint\">{joint}</span>", .{ .joint = if (view.any) "or" else "and" });
        try render(w, "<span class=\"chip\">{dim} {op} {value}<a href=\"{href}\" aria-label=\"Remove filter\">", .{ .dim = filter.dim.label(), .op = if (filter.negate) "is not" else "is", .value = filter.value, .href = try view.href(ctx.arena, path, &.{.{ "f-", filter.value }}) });
        try icon(w, "x");
        try w.writeAll("</a></span>");
    }
    try render(w, "<a class=\"btn btn-quiet\" href=\"{href}\">Clear</a></div>", .{ .href = try view.href(ctx.arena, path, &.{ .{ "f!", "" }, .{ "fm", "" } }) });
}

/// Simple full-page message for errors and the signed-out pages.
pub fn message(ctx: *Ctx, status: std.http.Status, title: []const u8, body: []const u8) !void {
    ctx.status = status;
    ctx.body.writer.end = 0;
    try document(ctx, title);
    const w = ctx.w();
    try render(w, "<main class=\"login\"><div class=\"login-card\"><img src=\"{logo}\" width=\"32\" height=\"32\" alt=\"\"><h1>{title}</h1><p class=\"secondary\">{body}</p><p class=\"mt-20\"><a class=\"btn\" href=\"/\">Back to Analytico</a></p></div></main></body></html>", .{ .logo = assets.path("favicon.svg"), .title = title, .body = body });
    try ctx.html();
}
