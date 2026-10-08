//! Add a website, Data health, Reports & alerts, Dashboards.
const std = @import("std");
const analyze = @import("analyze.zig");
const app = @import("app.zig");
const chart = @import("chart.zig");
const ctx_mod = @import("ctx.zig");
const data = @import("data.zig");
const db_mod = @import("../db.zig");
const domain = @import("../domain.zig");
const html = @import("html.zig");
const journeys = @import("journeys.zig");
const layout = @import("layout.zig");
const ui = @import("ui.zig");
const overview = @import("overview.zig");
const trackers = @import("../assets.zig");
const schema = @import("../schema.zig");

const Ctx = ctx_mod.Ctx;
const esc = html.esc;
const icon = layout.icon;
const render = html.render;

// ---------------------------------------------------------------- Add a website

fn instanceShell(ctx: *Ctx, title: []const u8, nav: layout.Nav) !layout.Shell {
    const sites = try ctx.visibleSites();
    const site: ?data.Site = if (ctx.param("site")) |slug| try data.siteBySlug(ctx.arena, ctx.db, slug) else if (sites.len != 0) sites[0] else null;
    return .{ .title = title, .nav = nav, .site = site, .sites = sites, .health = if (site) |value| try healthLevel(ctx, value) else .ok };
}

pub fn addSitePage(ctx: *Ctx, address: []const u8, problem: []const u8) !void {
    const shell = try instanceShell(ctx, "Add a website", .setup);
    try layout.begin(ctx, shell);
    const w = ctx.w();
    try w.writeAll("<div class=\"wizard wizard-wide\"><h1 class=\"title wizard-title\">Add a website</h1><p class=\"subtitle mb-28\">Takes about two minutes. Data appears here the moment it arrives.</p><form method=\"post\" action=\"/setup\" class=\"steps\"><div class=\"step\"><span class=\"step-num\">1</span><div><h3>Your website</h3>");
    if (problem.len != 0) {
        try w.writeAll("<div class=\"callout callout-bad mb-12\">");
        try icon(w, "alert");
        try render(w, "<span>{problem}</span></div>", .{ .problem = problem });
    }
    try render(w,
        \\<input class="input input-big" name="origin" type="url" required autofocus placeholder="https://example.com" value="{address}" aria-label="Website address">
        \\<label class="field mt-10"><span class="hint regular">Display name (optional)</span><input class="input" name="name" maxlength="60" placeholder="Shown in the sidebar"></label>
        \\<div class="mt-14">
    , .{ .address = address });
    try modeCards(w, .full);
    try w.writeAll(
        \\</div><div class="stack-s mt-14"><div class="field">When does Full mode switch on?</div>
        \\<label class="radio-row"><input type="radio" name="policy" value="regional" checked><span><strong>Ask visitors in the EU, UK and Switzerland</strong><small>Everyone else gets Full right away. The country is decided at collection.</small></span></label>
        \\<label class="radio-row"><input type="radio" name="policy" value="everyone"><span><strong>Ask everyone</strong><small>The safest choice if you are unsure where your visitors are.</small></span></label>
        \\<label class="radio-row"><input type="radio" name="policy" value="none"><span><strong>Don’t ask — consent isn’t required for my site</strong><small>You take responsibility. Global Privacy Control is still respected.</small></span></label>
        \\<label class="check mt-6"><input type="checkbox" name="banner" value="1" checked>Show the Analytico consent banner (or call <code>analytico.consent()</code> from your own tool)</label></div>
        \\<p class="hint mt-8">You can change this at any time — existing data is kept.</p><button class="btn btn-primary mt-14">Continue</button></div></div>
        \\<div class="step"><span class="step-num todo">2</span><div><h3 class="muted">Paste the snippet before &lt;/head&gt;</h3></div></div>
        \\<div class="step"><span class="step-num todo">3</span><div><h3 class="muted">We’ll confirm it’s working</h3></div></div></form></div>
    );
    return layout.end(ctx);
}

fn slugFromHost(arena: std.mem.Allocator, host: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const trimmed = if (std.mem.startsWith(u8, host, "www.")) host[4..] else host;
    for (trimmed) |byte| {
        const lower = std.ascii.toLower(byte);
        if (std.ascii.isAlphanumeric(lower)) {
            try out.append(arena, lower);
        } else if (out.items.len != 0 and out.items[out.items.len - 1] != '-') try out.append(arena, '-');
        if (out.items.len >= 40) break;
    }
    while (out.items.len != 0 and out.items[out.items.len - 1] == '-') _ = out.pop();
    if (out.items.len == 0) try out.appendSlice(arena, "site");
    return out.items;
}

pub fn addSitePost(ctx: *Ctx) !void {
    const raw = std.mem.trim(u8, try ctx.field("origin"), " /");
    const with_scheme = if (std.mem.startsWith(u8, raw, "http://") or std.mem.startsWith(u8, raw, "https://")) raw else try std.fmt.allocPrint(ctx.arena, "https://{s}", .{raw});
    // Paths are dropped: the origin is what the browser sends.
    const after_scheme = (std.mem.find(u8, with_scheme, "://") orelse 0) + 3;
    const path_start = std.mem.findScalarPos(u8, with_scheme, after_scheme, '/') orelse with_scheme.len;
    const origin = domain.normalizeOrigin(ctx.arena, with_scheme[0..path_start]) catch return addSitePage(ctx, raw, "That doesn’t look like a website address. Try https://example.com.");
    const mode = domain.parseMode(try ctx.field("mode")) catch .full;
    const policy = domain.parseConsentPolicy(try ctx.field("policy")) catch .regional;
    const banner = (try ctx.field("banner")).len != 0;
    const name = std.mem.trim(u8, try ctx.field("name"), " ");
    domain.validateText(name, 60, true) catch return addSitePage(ctx, raw, "Display names can’t contain control characters.");
    const host = origin[(std.mem.find(u8, origin, "://") orelse 0) + 3 ..];
    var slug = try slugFromHost(ctx.arena, host);
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    var suffix: usize = 2;
    while (data.reservedSlug(slug) or try db.scalar(ctx.arena, i64, "SELECT count(*) FROM sites WHERE slug=?", .{slug}) != 0) : (suffix += 1) {
        slug = try std.fmt.allocPrint(ctx.arena, "{s}-{d}", .{ (try slugFromHost(ctx.arena, host))[0..@min(40, host.len)], suffix });
    }
    var site = try ctx.shared.store.addSite(ctx.shared.io, slug, origin, mode);
    defer site.deinit(ctx.shared.store.allocator);
    try db.run(ctx.arena, "UPDATE sites SET name=?,consent_policy=?,consent_banner=? WHERE id=?", .{ name, @tagName(policy), @intFromBool(banner), site.id });
    try @import("audit.zig").record(ctx, db, site.id, "site.added", try std.fmt.allocPrint(ctx.arena, "Added {s} in {s} mode", .{ origin, @tagName(mode) }));
    return ctx.redirectFmt("/{s}/setup", .{slug});
}

/// The three tracking modes as option cards; `checked` is preselected.
pub fn modeCards(w: *std.Io.Writer, checked: domain.Mode) !void {
    const modes = [_]struct { domain.Mode, []const u8, []const u8, []const [2][]const u8, []const u8 }{
        .{ .full, "Full", "Everything, for visitors who agree. Everyone else is still counted, privately.", &.{ .{ "+", "Returning visitors and retention" }, .{ "+", "Replays and heatmaps" }, .{ "+", "People, cross-device and revenue" }, .{ "+", "Falls back to Lite until consent" } }, "Visitors see: a short consent banner (yours or ours), where needed" },
        .{ .session, "Session", "Paths and funnels within one visit. Nothing remembered after the tab closes.", &.{ .{ "+", "Journeys, funnels, landing and exit" }, .{ "+", "Rage clicks and errors" }, .{ "-", "No returning visitors" }, .{ "-", "No replays or heatmaps" } }, "Visitors see: nothing — usually exempt from banners" },
        .{ .lite, "Lite", "Counts and sources only. No storage in the browser at all.", &.{ .{ "+", "Page views, sources, countries" }, .{ "+", "Performance and goals" }, .{ "-", "No journeys or funnels" }, .{ "-", "No identity of any kind" } }, "Visitors see: nothing — no cookies, no storage" },
    };
    try w.writeAll("<div class=\"mode-cards\">");
    for (modes) |mode| {
        try render(w, "<label class=\"mode-card\"><input type=\"radio\" name=\"mode\" value=\"{value}\"{!checked}><span class=\"mode-title\">{title}{!recommended}</span><small>{help}</small><ul>", .{
            .value = mode[0],
            .checked = if (mode[0] == checked) " checked" else "",
            .title = mode[1],
            .recommended = if (mode[0] == .full) " <i class=\"pill pill-brand\">Recommended</i>" else "",
            .help = mode[2],
        });
        for (mode[3]) |line| try render(w, "<li class=\"{class}\">{text}</li>", .{ .class = if (line[0][0] == '+') "yes" else "no", .text = line[1] });
        try render(w, "</ul><span class=\"mode-sees\">{sees}</span></label>", .{ .sees = mode[4] });
    }
    try w.writeAll("</div>");
}

pub fn snippet(ctx: *Ctx, site: data.Site, rum: bool) ![]const u8 {
    const variant = trackers.forMode(site.mode, rum);
    const asset = trackers.scriptPath(variant);
    const origin = (try data.setting(ctx.arena, ctx.db, .collector_origin)) orelse try ctx.publicOrigin();
    return std.fmt.allocPrint(ctx.arena, "<script defer src=\"{s}{s}\" data-site=\"{s}\"></script>", .{ origin, asset, site.public_id });
}

pub fn setupPage(ctx: *Ctx, site: data.Site) !void {
    const shell = try app.shell(ctx, site, .setup, "Install", null);
    try layout.begin(ctx, shell);
    const w = ctx.w();
    const rum = ctx.param("rum") != null;
    const code = try snippet(ctx, site, rum);
    const received = try data.lastSeen(ctx.arena, ctx.db, site.id) != 0;
    try render(w,
        \\<div class="wizard"><h1 class="title wizard-title">{title}</h1><p class="subtitle mb-28">{intro}</p><div class="steps">
        \\<div class="step"><span class="step-num done">✓</span><div><h3>Your website</h3><div class="row"><span class="chip chip-plain">{origin}</span><span class="hint">Shown as “{name}” · {mode} mode · <a class="link" href="/settings/sites?site={slug}">Edit</a></span></div></div></div>
        \\<div class="step"><span class="step-num">2</span><div><h3>Paste this before &lt;/head&gt;</h3><div class="code"><button class="copy" type="button" data-copy="{code}">Copy</button>{code}<div class="snippet-note">Public site ID only — no secrets in this snippet.</div></div>
        \\<p class="hint mt-10"><a class="link" href="/{slug}/setup{rum_query}">{rum_label}</a> · Works with any CMS: paste it into the theme’s head, or a “custom code” setting.</p></div></div>
        \\<div class="step"><span class="step-num{!done}">3</span><div><h3>We’ll confirm it’s working</h3><div class="listening{!ok}" data-setup-status="/{slug}/setup.json" data-stream="/{slug}/stream"><span class="pulse"></span><div class="grow"><strong data-status-title>{status}</strong><div class="hint" data-status-detail>{detail}</div></div><a class="btn" href="{origin}" target="_blank" rel="noopener" data-status-open>Open {host} ↗</a><a class="btn btn-primary" href="/{slug}" data-status-done{!hidden}>Go to overview</a></div></div></div></div>
    , .{
        .title = if (received) "Install the snippet" else "Add a website",
        .intro = if (received) "The same snippet works on every page of this website." else "Takes about two minutes. Data appears here the moment it arrives.",
        .origin = site.origin,
        .name = site.title(),
        .mode = site.modeLabel(),
        .slug = site.slug,
        .code = code,
        .rum_query = if (rum) "" else "?rum=1",
        .rum_label = if (rum) "Use the smaller snippet without performance measurement" else "Also measure Core Web Vitals (+1 KB)",
        .done = if (received) " done" else "",
        .ok = if (received) " ok" else "",
        .status = if (received) "Data received" else "Listening for your first page view…",
        .detail = if (received) "Your site is reporting. Everything from here on shows up live." else "Open your site in another tab — this updates by itself.",
        .host = site.host(),
        .hidden = if (received) "" else " hidden",
    });
    if (!received) try render(w, "<p class=\"skip-later\"><a class=\"link ink-2\" href=\"/{slug}\">Skip for now — I’ll install later</a></p>", .{ .slug = site.slug });
    try w.writeAll("</div>");
    return layout.end(ctx);
}

pub fn setupStatus(ctx: *Ctx, site: data.Site) !void {
    var statement = try ctx.db.prepare(ctx.arena, "SELECT path,received_at_ms FROM page_views WHERE site_id=? ORDER BY received_at_ms DESC LIMIT 1");
    defer statement.deinit();
    try statement.bindInt(1, site.id);
    const w = ctx.w();
    if (try statement.step() == .row) {
        try w.writeAll("{\"received\":true,\"path\":");
        try std.json.Stringify.value(statement.columnText(0), .{}, w);
        try w.print(",\"at\":{d}}}", .{statement.columnInt(1)});
    } else try w.writeAll("{\"received\":false}");
    return ctx.json();
}

// ---------------------------------------------------------------- Data health

pub fn healthLevel(ctx: *Ctx, site: data.Site) !layout.Health {
    if (!site.enabled) return .warn;
    const last = try data.lastSeen(ctx.arena, ctx.db, site.id);
    if (last == 0) return .warn;
    if (ctx.now() - last > data.day_ms) return .warn;
    return .ok;
}

// glibc's struct statvfs on 64-bit Linux, with room to spare.
const Statvfs = extern struct { bsize: c_ulong, frsize: c_ulong, blocks: u64, bfree: u64, bavail: u64, files: u64, ffree: u64, favail: u64, fsid: c_ulong, flag: c_ulong, namemax: c_ulong, spare: [16]c_int };
extern "c" fn statvfs(path: [*:0]const u8, buf: *Statvfs) c_int;

fn freeSpacePercent(ctx: *Ctx) ?f64 {
    const path = ctx.arena.dupeSentinel(u8, ctx.shared.data, 0) catch return null;
    var stat: Statvfs = undefined;
    if (statvfs(path.ptr, &stat) != 0 or stat.blocks == 0) return null;
    return @as(f64, @floatFromInt(stat.bavail)) / @as(f64, @floatFromInt(stat.blocks)) * 100;
}

pub fn health(ctx: *Ctx, site: data.Site) !void {
    const arena = ctx.arena;
    const db = ctx.db;
    const shell = try app.shell(ctx, site, .health, "Data health", null);
    try layout.begin(ctx, shell);
    const w = ctx.w();
    try layout.head(ctx, .{ .title = "Data health", .subtitle = "Is collection complete and trustworthy?" });
    const now = ctx.now();
    const day_start = now - @mod(now, data.day_ms);
    const last = try data.lastSeen(arena, db, site.id);
    const today_views = try db.scalar(arena, i64, "SELECT count(*) FROM page_views WHERE site_id=? AND received_at_ms>=?", .{ site.id, day_start });
    const today_events = try db.scalar(arena, i64, "SELECT count(*) FROM events WHERE site_id=? AND received_at_ms>=?", .{ site.id, day_start });
    // One pass over the last 24 hours: collection health is about now, and
    // a single bounded scan stays fast at any volume.
    const window_start = now - data.day_ms;
    var recent = try db.prepare(arena,
        \\SELECT count(*),coalesce(sum(EXISTS(SELECT 1 FROM page_summaries ps WHERE ps.site_id=pv.site_id AND ps.page_id=pv.page_id)),0),
        \\ coalesce(sum(traffic_class IN ('known_bot','monitor')),0),coalesce(sum(internal=1),0),
        \\ coalesce(sum(coalesce(nullif(utm_source,''),nullif(referrer_host,''),'')='' AND internal=0 AND traffic_class IN ('human_like','unknown')),0),
        \\ coalesce(sum(internal=0 AND traffic_class IN ('human_like','unknown')),0),count(DISTINCT tracker_version),coalesce(sum(abs(received_at_ms-occurred_at_ms)>300000),0)
        \\FROM page_views pv WHERE site_id=? AND received_at_ms>=?
    );
    defer recent.deinit();
    try recent.bindInt(1, site.id);
    try recent.bindInt(2, window_start);
    _ = try recent.step();
    const views_week = recent.columnInt(0);
    const summaries_week = recent.columnInt(1);
    const bots_week = recent.columnInt(2);
    const internal_week = recent.columnInt(3);
    const direct_week = recent.columnInt(4);
    const human_week = recent.columnInt(5);
    const versions = recent.columnInt(6);
    const skewed = recent.columnInt(7);
    const page_count = try db.scalar(arena, i64, "PRAGMA page_count", .{});
    const page_size = try db.scalar(arena, i64, "PRAGMA page_size", .{});
    const last_backup = try data.setting(arena, db, .@"backup.last_at");

    const stale = last == 0 or now - last > data.day_ms;
    try render(w, "<div class=\"health-banner{!warn}\"><span class=\"pulse {!pulse}\"></span><div><strong>{status}</strong><small>", .{ .warn = if (stale) " warn" else "", .pulse = if (stale) "pulse-warn" else "pulse-ok", .status = if (!site.enabled) "Collection is paused" else if (last == 0) "Waiting for the first page view" else if (stale) "No data in the last 24 hours" else "Collecting normally" });
    if (last != 0) try render(w, "Last page view {ago} · {views} page views and {events} events today", .{ .ago = data.ago(last, now), .views = html.int(today_views), .events = html.int(today_events) }) else try render(w, "<a class=\"link\" href=\"/{slug}/setup\">Install the snippet →</a>", .{ .slug = site.slug });
    try w.writeAll("</small></div></div><div class=\"grid grid-4 mb-16\">");
    try ui.stat(w, "Engagement coverage", try std.fmt.allocPrint(arena, "{f}", .{html.share(summaries_week, views_week)}), "Page views with an engagement summary · 24 hours");
    try ui.stat(w, "Bot traffic filtered", try std.fmt.allocPrint(arena, "{f}", .{html.int(bots_week)}), try std.fmt.allocPrint(arena, "Plus {f} internal views · not counted", .{html.int(internal_week)}));
    try ui.stat(w, "Unattributed", try std.fmt.allocPrint(arena, "{f}", .{html.share(direct_week, human_week)}), "Direct / no referrer · 24 hours");
    try ui.stat(w, "Database", try std.fmt.allocPrint(arena, "{d:.1} MB", .{@as(f64, @floatFromInt(page_count * page_size)) / 1_048_576.0}), if (last_backup) |value| try std.fmt.allocPrint(arena, "Last verified backup {f}", .{data.ago(std.fmt.parseInt(i64, value, 10) catch 0, now)}) else "No backup from the workspace yet");
    try w.writeAll("</div><div class=\"grid split-main\"><section class=\"card\">");
    try ui.cardHead(w, "Checks", "<span class=\"meta\">Ran just now</span>");
    try check(w, versions <= 1, if (versions <= 1) "One tracker version" else "Several tracker versions are reporting", if (versions <= 1) "Every page runs the same tracker build" else "Some pages still load an older snippet — update the snippet to the current one", if (versions <= 1) "" else try std.fmt.allocPrint(arena, "/{s}/setup", .{site.slug}));
    const origins = try db.scalar(arena, ?[]const u8, "SELECT group_concat(origin,', ') FROM site_origins WHERE site_id=?", .{site.id});
    const rejected_origins = try db.scalar(arena, i64, "SELECT coalesce(sum(value),0) FROM ingest_counters WHERE name='invalid_origins'", .{});
    try check(w, true, "Allowed origins", origins orelse "", "");
    try check(w, skewed * 20 <= @max(views_week, 1), if (skewed * 20 <= @max(views_week, 1)) "Events arrive in time" else "Some events arrive late", try std.fmt.allocPrint(arena, "{f} of {f} page views arrived over 5 minutes after they happened", .{ html.int(skewed), html.int(views_week) }), "");
    try check(w, true, "Database schema", try std.fmt.allocPrint(arena, "Version {d} · WAL mode · one writer", .{schema.current_version}), "");
    if (freeSpacePercent(ctx)) |free| {
        try check(w, free > 15, "Storage", try std.fmt.allocPrint(arena, "{d:.0}% free on the data volume", .{free}), "");
    }
    try check(w, rejected_origins == 0, if (rejected_origins == 0) "No rejected origins" else "Requests from unknown origins were rejected", try std.fmt.allocPrint(arena, "{f} rejected since the counters were reset (all websites)", .{html.int(rejected_origins)}), if (rejected_origins == 0) "" else try std.fmt.allocPrint(arena, "/settings/sites?site={s}", .{site.slug}));
    try w.writeAll("</section><section class=\"card\"><div class=\"card-head\"><h2>Background jobs</h2></div><div class=\"stack\">");
    const jobs_run = try data.setting(arena, db, .@"jobs.last_run");
    const retention = try data.setting(arena, db, .@"retention.days");
    try render(w, "<div><strong class=\"t-13\">Alerts and scheduled emails</strong><div class=\"hint\">{jobs}</div></div><div><strong class=\"t-13\">Retention</strong><div class=\"hint\">{retention}{days}</div></div>", .{
        .jobs = if (jobs_run) |value| try std.fmt.allocPrint(arena, "Last run {f}", .{data.ago(std.fmt.parseInt(i64, value, 10) catch 0, now)}) else "Not run yet",
        .retention = retention orelse "Keep everything",
        .days = if (retention != null) " days, pruned nightly after a verified backup" else "",
    });
    try w.writeAll("<p class=\"hint\">Collection keeps running during maintenance.</p></div></section></div>");
    return layout.end(ctx);
}

fn check(w: *std.Io.Writer, ok: bool, title: []const u8, detail: []const u8, href: []const u8) !void {
    try w.writeAll("<div class=\"check-row\">");
    if (ok) {
        try w.writeAll("<span class=\"good\">");
        try icon(w, "check");
    } else {
        try w.writeAll("<span class=\"warn\">");
        try icon(w, "alert");
    }
    try render(w, "</span><div><strong>{title}</strong><small>{detail}</small></div>", .{ .title = title, .detail = detail });
    if (href.len != 0) try render(w, "<a class=\"link\" href=\"{href}\">Fix →</a>", .{ .href = href }) else try w.writeAll("<span></span>");
    try w.writeAll("</div>");
}

// ---------------------------------------------------------------- Alerts

pub const AlertSpec = struct {
    metric: []const u8,
    filters: []const u8,
};

/// Daily values of an alert metric for `days` days ending before `end_day`.
pub fn alertSeries(arena: std.mem.Allocator, db: *db_mod.Db, site: data.Site, spec: AlertSpec, end_day_ms: i64, days: usize) ![]f64 {
    const params = try html.Params.parse(arena, spec.filters);
    var view = try data.View.parse(arena, site, params, end_day_ms - 1);
    view.range.start_ms = end_day_ms - @as(i64, @intCast(days)) * data.day_ms;
    view.range.end_ms = end_day_ms;
    view.range.bucket_ms = data.day_ms;
    view.range.buckets = days;
    if (std.mem.eql(u8, spec.metric, "events")) {
        const out = try arena.alloc(f64, days);
        @memset(out, 0);
        var sql = data.Sql.init(arena);
        try sql.add("SELECT (e.received_at_ms-");
        try sql.int(view.range.start_ms);
        try sql.add(")/86400000 b,count(*) FROM events e WHERE ");
        try sql.events(view, view.range.start_ms, view.range.end_ms);
        if (params.get("event")) |name| {
            try sql.add(" AND e.name=");
            try sql.str(name);
        }
        try sql.add(" GROUP BY b");
        var statement = try sql.prepare(db);
        defer statement.deinit();
        while (try statement.step() == .row) {
            const bucket = statement.columnInt(0);
            if (bucket >= 0 and bucket < days) out[@intCast(bucket)] = @floatFromInt(statement.columnInt(1));
        }
        return out;
    }
    return data.series(arena, db, view, if (std.mem.eql(u8, spec.metric, "visitors")) .visitor_days else .views, view.range.start_ms);
}

pub fn alertTriggered(direction: []const u8, threshold: i64, previous: f64, current: f64) bool {
    if (previous <= 0) return false;
    const change = (current - previous) / previous * 100;
    const limit: f64 = @floatFromInt(threshold);
    return if (std.mem.eql(u8, direction, "drops")) change <= -limit else change >= limit;
}

pub fn alertPreview(ctx: *Ctx, site: data.Site) !void {
    const metric = ctx.param("metric") orelse "page_views";
    const direction = ctx.param("direction") orelse "drops";
    const threshold = std.math.clamp(std.fmt.parseInt(i64, ctx.param("threshold") orelse "20", 10) catch 20, 1, 1000);
    const now = ctx.now();
    const today = now - @mod(now, data.day_ms);
    const values = try alertSeries(ctx.arena, ctx.db, site, .{ .metric = metric, .filters = ctx.param("filters") orelse "" }, today, 31);
    const w = ctx.w();
    try w.writeAll("{\"values\":[");
    for (values, 0..) |value, index| {
        if (index != 0) try w.writeByte(',');
        try w.print("{d:.0}", .{value});
    }
    try w.writeAll("],\"hits\":[");
    var first = true;
    for (values, 0..) |value, index| {
        if (index == 0 or !alertTriggered(direction, threshold, values[index - 1], value)) continue;
        if (!first) try w.writeByte(',');
        first = false;
        const date = data.civil(today - @as(i64, @intCast(values.len - index)) * data.day_ms);
        try w.print("{{\"i\":{d},\"day\":\"{d} {s}\",\"change\":\"{f}\"}}", .{ index, date.day, data.month_names[date.month - 1], html.change(value, values[index - 1]) });
    }
    try w.writeAll("]}");
    return ctx.json();
}

pub fn addAlert(ctx: *Ctx, site: data.Site) !void {
    const name = std.mem.trim(u8, try ctx.field("name"), " ");
    const metric = try ctx.field("metric");
    const direction = try ctx.field("direction");
    const threshold = std.fmt.parseInt(i64, try ctx.field("threshold"), 10) catch 0;
    const filters = try ctx.field("filters");
    if (!(std.mem.eql(u8, metric, "page_views") or std.mem.eql(u8, metric, "visitors") or std.mem.eql(u8, metric, "events"))) return overview.failBack(ctx, site, "Choose what to watch.");
    if (!(std.mem.eql(u8, direction, "drops") or std.mem.eql(u8, direction, "rises"))) return overview.failBack(ctx, site, "Choose drops or rises.");
    if (threshold < 1 or threshold > 1000) return overview.failBack(ctx, site, "The threshold must be between 1 and 1000%.");
    domain.validateText(name, 80, false) catch return overview.failBack(ctx, site, "Give the alert a name.");
    if (filters.len > 2048) return overview.failBack(ctx, site, "Too many filters.");
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    try db.run(ctx.arena, "INSERT INTO alerts(site_id,name,metric,direction,threshold_percent,filters,email,created_at_ms) VALUES(?,?,?,?,?,?,?,?)", .{ site.id, name, metric, direction, threshold, filters, @intFromBool((try ctx.field("email")).len != 0), ctx.now() });
    try ctx.flash("Alert created. It checks every morning.", "View alerts", try std.fmt.allocPrint(ctx.arena, "/{s}/reports?tab=alerts", .{site.slug}));
    return ctx.redirect(overview.referer(ctx, site));
}

pub fn alertAction(ctx: *Ctx, site: data.Site, id: i64, action: []const u8) !void {
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    const binds = .{ id, site.id };
    if (std.mem.eql(u8, action, "toggle")) {
        try db.run(ctx.arena, "UPDATE alerts SET enabled=1-enabled,state=CASE WHEN enabled=1 THEN 'quiet' ELSE state END WHERE id=? AND site_id=?", binds);
    } else if (std.mem.eql(u8, action, "dismiss")) {
        try db.run(ctx.arena, "UPDATE alerts SET state='quiet',triage=NULL WHERE id=? AND site_id=?", binds);
        try ctx.flash("Alert dismissed.", "", "");
    } else if (std.mem.eql(u8, action, "delete")) {
        try db.run(ctx.arena, "DELETE FROM alerts WHERE id=? AND site_id=?", binds);
        try ctx.flash("Alert deleted.", "", "");
    } else return layout.message(ctx, .not_found, "Nothing here", "Unknown action.");
    return ctx.redirect(overview.referer(ctx, site));
}

// ---------------------------------------------------------------- Schedules

/// Next delivery strictly after `after_ms`.
pub fn nextRun(frequency: []const u8, weekday: i64, hour: i64, after_ms: i64) i64 {
    const day_start = after_ms - @mod(after_ms, data.day_ms);
    var candidate = day_start + hour * data.hour_ms;
    if (std.mem.eql(u8, frequency, "monthly")) {
        var date = data.civil(after_ms);
        var attempt: usize = 0;
        while (attempt < 3) : (attempt += 1) {
            var buffer: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "{d:0>4}-{d:0>2}-01", .{ date.year, date.month }) catch return after_ms + 30 * data.day_ms;
            const first = (data.parseDate(text) catch return after_ms + 30 * data.day_ms) + hour * data.hour_ms;
            if (first > after_ms) return first;
            date.month += 1;
            if (date.month == 13) {
                date.month = 1;
                date.year += 1;
            }
        }
        return after_ms + 30 * data.day_ms;
    }
    while (candidate <= after_ms or (std.mem.eql(u8, frequency, "weekly") and @as(i64, @intCast(data.weekday(candidate))) != weekday)) candidate += data.day_ms;
    return candidate;
}

fn validRecipients(arena: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var parts = std.mem.splitAny(u8, raw, ",; \n");
    var count: usize = 0;
    while (parts.next()) |part| {
        const email = std.mem.trim(u8, part, " \t\r");
        if (email.len == 0) continue;
        if (!@import("auth.zig").validEmail(email)) return null;
        if (out.items.len != 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, email);
        count += 1;
        if (count > 20) return null;
    }
    return if (count == 0) null else out.items;
}

pub fn addSchedule(ctx: *Ctx, site: data.Site) !void {
    const name = std.mem.trim(u8, try ctx.field("name"), " ");
    const frequency = try ctx.field("frequency");
    const weekday = std.math.clamp(std.fmt.parseInt(i64, try ctx.field("weekday"), 10) catch 0, 0, 6);
    const hour = std.math.clamp(std.fmt.parseInt(i64, try ctx.field("hour"), 10) catch 9, 0, 23);
    const view = try ctx.field("view");
    domain.validateText(name, 80, false) catch return overview.failBack(ctx, site, "Give the report a name.");
    if (!(std.mem.eql(u8, frequency, "daily") or std.mem.eql(u8, frequency, "weekly") or std.mem.eql(u8, frequency, "monthly"))) return overview.failBack(ctx, site, "Choose how often to send it.");
    if (view.len == 0 or view[0] != '/' or view.len > 2048) return overview.failBack(ctx, site, "Invalid view.");
    const recipients = try validRecipients(ctx.arena, try ctx.field("recipients")) orelse return overview.failBack(ctx, site, "Add up to 20 valid email addresses, separated by commas.");
    const next = nextRun(frequency, weekday, hour, ctx.now());
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    try db.run(ctx.arena, "INSERT INTO schedules(site_id,name,view,frequency,weekday,hour_utc,recipients,next_run_at_ms,created_at_ms) VALUES(?,?,?,?,?,?,?,?,?)", .{ site.id, name, view, frequency, weekday, hour, recipients, next, ctx.now() });
    const date = data.civil(next);
    const smtp_ready = (try data.setting(ctx.arena, db, .@"smtp.host")) != null;
    try ctx.flash(try std.fmt.allocPrint(ctx.arena, "Scheduled. First email {s} {d} {s}, {d:0>2}:00 UTC.{s}", .{ data.weekday_names[data.weekday(next)], date.day, data.month_names[date.month - 1], @as(u64, @intCast(hour)), if (smtp_ready) "" else " Set up email delivery to send it." }), if (smtp_ready) "View" else "Set up email", if (smtp_ready) try std.fmt.allocPrint(ctx.arena, "/{s}/reports?tab=schedules", .{site.slug}) else try std.fmt.allocPrint(ctx.arena, "/settings/email?site={s}", .{site.slug}));
    return ctx.redirect(overview.referer(ctx, site));
}

pub fn scheduleAction(ctx: *Ctx, site: data.Site, id: i64, action: []const u8) !void {
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    const binds = .{ id, site.id };
    if (std.mem.eql(u8, action, "toggle")) {
        try db.run(ctx.arena, "UPDATE schedules SET enabled=1-enabled WHERE id=? AND site_id=?", binds);
    } else if (std.mem.eql(u8, action, "send")) {
        // The jobs thread picks it up within a minute.
        try db.run(ctx.arena, "UPDATE schedules SET next_run_at_ms=0,enabled=1 WHERE id=? AND site_id=?", binds);
        try ctx.flash("Sending now — it arrives within a minute.", "", "");
    } else if (std.mem.eql(u8, action, "delete")) {
        try db.run(ctx.arena, "DELETE FROM schedules WHERE id=? AND site_id=?", binds);
        try ctx.flash("Scheduled email deleted.", "", "");
    } else return layout.message(ctx, .not_found, "Nothing here", "Unknown action.");
    return ctx.redirect(overview.referer(ctx, site));
}

/// "Overview · Source is Google" for a saved view path.
pub fn viewLabel(arena: std.mem.Allocator, site: data.Site, view_path: []const u8) ![]const u8 {
    const query_start = std.mem.findScalar(u8, view_path, '?') orelse view_path.len;
    const path = view_path[0..query_start];
    const rest = if (std.mem.startsWith(u8, path, "/") and std.mem.findScalarPos(u8, path, 1, '/') != null) path[std.mem.findScalarPos(u8, path, 1, '/').? + 1 ..] else "";
    var name: []const u8 = if (rest.len == 0) "Overview" else rest;
    if (rest.len != 0) {
        const copy = try arena.dupe(u8, rest);
        copy[0] = std.ascii.toUpper(copy[0]);
        name = copy;
    }
    const params = html.Params.parse(arena, if (query_start < view_path.len) view_path[query_start + 1 ..] else "") catch html.Params{};
    const filters = try data.parseFilters(arena, params);
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll(name);
    for (filters) |filter| try out.writer.print(" · {s} {s} {s}", .{ filter.dim.label(), if (filter.negate) "is not" else "is", filter.value });
    if (params.get("event")) |event| try out.writer.print(" · Event {s}", .{event});
    _ = site;
    return out.written();
}

// ---------------------------------------------------------------- Reports & alerts page

pub fn reports(ctx: *Ctx, site: data.Site) !void {
    const arena = ctx.arena;
    const db = ctx.db;
    const shell = try app.shell(ctx, site, .reports, "Reports & alerts", null);
    try layout.begin(ctx, shell);
    const w = ctx.w();
    const now = ctx.now();
    const tab = ctx.param("tab") orelse "all";
    const alert_count = try db.scalar(arena, i64, "SELECT count(*) FROM alerts WHERE site_id=?", .{site.id});
    const schedule_count = try db.scalar(arena, i64, "SELECT count(*) FROM schedules WHERE site_id=?", .{site.id});
    try layout.head(ctx, .{ .title = "Reports & alerts", .subtitle = "Create new ones from any view with the ⋯ menu" });
    const view = try data.View.parse(arena, site, .{}, now);
    const path = try std.fmt.allocPrint(arena, "/{s}/reports", .{site.slug});
    try ui.tabs(ctx.w(), ctx.arena, view, path, "tab", &.{
        .{ "all", try std.fmt.allocPrint(arena, "All · {d}", .{alert_count + schedule_count}) },
        .{ "alerts", try std.fmt.allocPrint(arena, "Alerts · {d}", .{alert_count}) },
        .{ "schedules", try std.fmt.allocPrint(arena, "Scheduled emails · {d}", .{schedule_count}) },
    }, tab);
    try w.writeAll("<section class=\"card card-flush\">");
    var rows: usize = 0;
    if (!std.mem.eql(u8, tab, "schedules")) {
        const Alert = struct { id: i64, name: []const u8, metric: []const u8, direction: []const u8, threshold: i64, filters: []const u8, enabled: bool, state: []const u8, triggered_at: ?i64, change: ?i64, triage: ?[]const u8, checked_at: ?i64, created_at: i64 };
        for (try db.all(arena, Alert, "SELECT id,name,metric,direction,threshold_percent,filters,enabled,state,triggered_at_ms,last_change_milli,triage,checked_at_ms,created_at_ms FROM alerts WHERE site_id=? ORDER BY state='triggered' DESC,enabled DESC,name", .{site.id})) |alert| {
            rows += 1;
            const triggered = alert.enabled and std.mem.eql(u8, alert.state, "triggered");
            try render(w, "<div class=\"list-row{!state}\"><span class=\"icon-tile {tone}\">", .{ .state = if (triggered) " alerting" else if (!alert.enabled) " paused" else "", .tone = if (triggered) "warn" else "brand" });
            try icon(w, "bell-plus");
            try render(w, "</span><div class=\"min-0\"><strong>{name}</strong><small>{metric} {direction} {threshold}% vs previous day · <span class=\"chip chip-plain chip-view\">{view}</span></small></div><div class=\"row nowrap\">", .{
                .name = alert.name,
                .metric = if (std.mem.eql(u8, alert.metric, "page_views")) "Page views" else if (std.mem.eql(u8, alert.metric, "visitors")) "Visitors" else "Events",
                .direction = alert.direction,
                .threshold = alert.threshold,
                .view = try viewLabel(arena, site, try std.fmt.allocPrint(arena, "/{s}?{s}", .{ site.slug, alert.filters })),
            });
            if (!alert.enabled) {
                try w.writeAll("<span class=\"muted t-13\">Paused</span>");
            } else if (triggered) {
                try render(w, "<span class=\"warn t-13 strong nobreak\">Triggered {ago} · {change}</span><a class=\"link nobreak\" href=\"/{slug}?{!filters}\">Inspect →</a>", .{ .ago = data.ago(alert.triggered_at orelse now, now), .change = html.change(1000 + @as(f64, @floatFromInt(alert.change orelse 0)), 1000), .slug = site.slug, .filters = try std.fmt.allocPrint(arena, "{f}", .{html.esc(alert.filters)}) });
            } else if (alert.checked_at == null) {
                try w.writeAll("<span class=\"secondary t-13 nobreak\">Checks daily at 06:00 UTC</span>");
            } else {
                const days = @divFloor(now - (alert.triggered_at orelse alert.created_at), data.day_ms);
                try render(w, "<span class=\"secondary t-13 nobreak\">Quiet for {days} day{plural}</span>", .{ .days = days, .plural = if (days == 1) "" else "s" });
            }
            try render(w, "</div><div class=\"row nowrap\"><form method=\"post\" action=\"/{slug}/alerts/{id}/toggle\" class=\"switch\" title=\"{title}\"><input type=\"checkbox\" aria-label=\"Enabled\" data-autosubmit{!checked}></form>", .{ .slug = site.slug, .id = alert.id, .title = if (alert.enabled) "Pause" else "Resume", .checked = if (alert.enabled) " checked" else "" });
            try rowMenu(w, try std.fmt.allocPrint(arena, "alert-{d}", .{alert.id}), &.{
                .{ "Dismiss", try std.fmt.allocPrint(arena, "/{s}/alerts/{d}/dismiss", .{ site.slug, alert.id }), "check" },
                .{ "Delete", try std.fmt.allocPrint(arena, "/{s}/alerts/{d}/delete", .{ site.slug, alert.id }), "trash" },
            });
            try w.writeAll("</div></div>");
            if (triggered) {
                try w.writeAll("<div class=\"triage\"><div class=\"row mb-6\">");
                try icon(w, "sparkles");
                try w.writeAll("<strong class=\"t-13\">Likely cause</strong></div>");
                if (alert.triage) |triage| {
                    try render(w, "<p class=\"t-13 lh-20\">{triage}</p>", .{ .triage = triage });
                } else {
                    try render(w, "<form method=\"post\" action=\"/{slug}/why\" data-why-form><input type=\"hidden\" name=\"alert\" value=\"{id}\"><p class=\"hint mb-8\">Compare the change against sources, pages and devices.</p><button class=\"btn\">", .{ .slug = site.slug, .id = alert.id });
                    try icon(w, "sparkles");
                    try w.writeAll("Explain this change</button></form>");
                }
                try w.writeAll("</div>");
            }
        }
    }
    if (!std.mem.eql(u8, tab, "alerts")) {
        const Schedule = struct { id: i64, name: []const u8, view: []const u8, frequency: []const u8, weekday: i64, hour: i64, recipients: []const u8, enabled: bool, next: i64, last_sent: ?i64, last_error: ?[]const u8 };
        for (try db.all(arena, Schedule, "SELECT id,name,view,frequency,weekday,hour_utc,recipients,enabled,next_run_at_ms,last_sent_at_ms,last_error FROM schedules WHERE site_id=? ORDER BY enabled DESC,name", .{site.id})) |schedule| {
            rows += 1;
            const hour: u64 = @intCast(schedule.hour);
            const when = if (std.mem.eql(u8, schedule.frequency, "daily"))
                try std.fmt.allocPrint(arena, "Daily {d:0>2}:00 UTC", .{hour})
            else if (std.mem.eql(u8, schedule.frequency, "weekly"))
                try std.fmt.allocPrint(arena, "{s}s {d:0>2}:00 UTC", .{ data.weekday_names[@intCast(schedule.weekday)], hour })
            else
                try std.fmt.allocPrint(arena, "1st of month {d:0>2}:00 UTC", .{hour});
            try render(w, "<div class=\"list-row{!paused}\"><span class=\"icon-tile\">", .{ .paused = if (!schedule.enabled) " paused" else "" });
            try icon(w, "mail");
            try render(w, "</span><div class=\"min-0\"><strong>{name}</strong><small>{when} · to {recipients} · <span class=\"chip chip-plain chip-view\">{view}</span></small></div><div class=\"t-13 nobreak\">", .{ .name = schedule.name, .when = when, .recipients = schedule.recipients, .view = try viewLabel(arena, site, schedule.view) });
            if (!schedule.enabled) {
                try w.writeAll("<span class=\"muted\">Paused</span>");
            } else if (schedule.last_error != null and schedule.last_error.?.len != 0) {
                try render(w, "<span class=\"bad\" title=\"{error}\">Last send failed</span> · <a class=\"link\" href=\"/settings/email?site={slug}\">Check email</a>", .{ .@"error" = schedule.last_error.?, .slug = site.slug });
            } else {
                const next = data.civil(schedule.next);
                try render(w, "<span class=\"secondary\">Next: {weekday} {day} {month}</span>", .{ .weekday = data.weekday_names[data.weekday(schedule.next)], .day = next.day, .month = data.month_names[next.month - 1] });
            }
            try render(w, "</div><div class=\"row nowrap\"><form method=\"post\" action=\"/{slug}/schedules/{id}/toggle\" class=\"switch\"><input type=\"checkbox\" aria-label=\"Enabled\" data-autosubmit{!checked}></form>", .{ .slug = site.slug, .id = schedule.id, .checked = if (schedule.enabled) " checked" else "" });
            try rowMenu(w, try std.fmt.allocPrint(arena, "schedule-{d}", .{schedule.id}), &.{
                .{ "Send now", try std.fmt.allocPrint(arena, "/{s}/schedules/{d}/send", .{ site.slug, schedule.id }), "send" },
                .{ "Delete", try std.fmt.allocPrint(arena, "/{s}/schedules/{d}/delete", .{ site.slug, schedule.id }), "trash" },
            });
            try w.writeAll("</div></div>");
        }
    }
    if (rows == 0) {
        try ui.empty(w, "Nothing scheduled yet", "Open any view, then choose <strong>⋯ → Create alert</strong> to hear about unusual changes, or <strong>Schedule email</strong> for a regular summary.", try html.print(arena, "<a class=\"btn btn-primary\" href=\"/{slug}?dialog=alert-dialog\">Create an alert</a><a class=\"btn\" href=\"/{slug}?dialog=schedule-dialog\">Schedule an email</a>", .{ .slug = site.slug }));
    }
    try w.writeAll("</section>");
    return layout.end(ctx);
}

fn rowMenu(w: *std.Io.Writer, id: []const u8, items: []const [3][]const u8) !void {
    try render(w, "<button class=\"btn btn-quiet btn-icon\" type=\"button\" popovertarget=\"{id}\" aria-label=\"More\">", .{ .id = id });
    try icon(w, "more");
    try render(w, "</button><div id=\"{id}\" popover class=\"pop\" data-anchor=\"[popovertarget={id}]\">", .{ .id = id });
    for (items) |item| {
        try render(w, "<form method=\"post\" action=\"{action}\"{!undo}><button class=\"menu-item\">", .{ .action = item[1], .undo = if (std.mem.eql(u8, item[0], "Delete")) " data-undo=\"Deleted\"" else "" });
        try icon(w, item[2]);
        try render(w, "{label}</button></form>", .{ .label = item[0] });
    }
    try w.writeAll("</div>");
}

// ---------------------------------------------------------------- Dashboards

pub const Widget = struct { key: []const u8, title: []const u8, hint: []const u8, icon: []const u8, wide: bool };
pub const widget_catalog = [_]Widget{
    .{ .key = "metrics", .title = "Headline metrics", .hint = "Four tiles", .icon = "overview", .wide = true },
    .{ .key = "trend", .title = "Trend", .hint = "Line chart", .icon = "performance", .wide = true },
    .{ .key = "pages", .title = "Top pages", .hint = "Ranked bars", .icon = "pages", .wide = false },
    .{ .key = "sources", .title = "Sources", .hint = "Ranked bars", .icon = "sources", .wide = false },
    .{ .key = "devices", .title = "Devices", .hint = "Share bars", .icon = "audience", .wide = false },
    .{ .key = "goals", .title = "Goal conversions", .hint = "Number + share", .icon = "events", .wide = false },
    .{ .key = "funnel", .title = "Funnel", .hint = "Step bars", .icon = "funnels", .wide = false },
    .{ .key = "vitals", .title = "Web vitals", .hint = "p75 values", .icon = "zap", .wide = false },
};

fn widgetInfo(key: []const u8) ?Widget {
    const base = key[0 .. std.mem.findScalar(u8, key, ':') orelse key.len];
    for (widget_catalog) |widget| if (std.mem.eql(u8, widget.key, base)) return widget;
    return null;
}

pub fn dashboards(ctx: *Ctx, site: data.Site, id: ?i64) !void {
    const arena = ctx.arena;
    const view = try data.View.parse(arena, site, ctx.query, ctx.now());
    const shell = try app.shell(ctx, site, .dashboards, "Dashboards", view);
    const Dash = struct { id: i64, name: []const u8, widgets: []const u8 };
    const all = try ctx.db.all(arena, Dash, "SELECT id,name,widgets FROM dashboards WHERE site_id=? ORDER BY id", .{site.id});
    if (id == null and all.len != 0) return ctx.redirect(try view.href(arena, try std.fmt.allocPrint(arena, "/{s}/dashboards/{d}", .{ site.slug, all[0].id }), &.{}));
    try layout.begin(ctx, shell);
    const w = ctx.w();
    if (all.len == 0) {
        try layout.head(ctx, .{ .title = "Dashboards", .subtitle = "Pin the widgets you check every day" });
        try w.writeAll("<div class=\"card\">");
        try ui.empty(w, "Build your own view", "Start from a ready-made dashboard with the essentials, then add, remove and drag widgets around.", try html.print(arena, "<form method=\"post\" action=\"/{slug}/dashboards\"><input type=\"hidden\" name=\"name\" value=\"Website pulse\"><button class=\"btn btn-primary\">Create dashboard</button></form>", .{ .slug = site.slug }));
        try w.writeAll("</div>");
        return layout.end(ctx);
    }
    var dash: ?Dash = null;
    for (all) |item| if (item.id == id.?) {
        dash = item;
    };
    const current = dash orelse return layout.message(ctx, .not_found, "Dashboard not found", "It may have been deleted.");
    const editing = ctx.param("edit") != null;
    const path = try std.fmt.allocPrint(arena, "/{s}/dashboards/{d}", .{ site.slug, current.id });
    var extra: std.Io.Writer.Allocating = .init(arena);
    if (editing) {
        try render(&extra.writer, "<span class=\"saved\" data-saved hidden>✓ Saved</span><button class=\"btn\" type=\"button\" data-copy-link>Share</button><a class=\"btn btn-primary\" href=\"{href}\">Done</a>", .{ .href = try view.href(arena, path, &.{}) });
    } else {
        try render(&extra.writer, "<a class=\"btn\" href=\"{href}\">", .{ .href = try view.href(arena, path, &.{.{ "edit", "1" }}) });
        try icon(&extra.writer, "pencil");
        try extra.writer.writeAll("<span class=\"btn-label\">Edit</span></a>");
    }
    try layout.head(ctx, .{ .title = current.name, .subtitle = if (editing) "Editing — drag to rearrange · changes save automatically" else try std.fmt.allocPrint(arena, "{f}", .{view.range}), .view = if (editing) null else view, .path = path, .extra = extra.written() });
    if (all.len > 1 or editing) {
        try w.writeAll("<nav class=\"tabs\">");
        for (all) |item| try render(w, "<a href=\"{href}\"{!current}>{name}</a>", .{ .href = try view.href(arena, try std.fmt.allocPrint(arena, "/{s}/dashboards/{d}", .{ site.slug, item.id }), &.{}), .current = if (item.id == current.id) " aria-current=\"page\"" else "", .name = item.name });
        if (editing) try w.writeAll("<a href=\"#\" data-dialog=\"dashboard-dialog\">+ New dashboard</a>");
        try w.writeAll("</nav>");
    }
    const base = try std.fmt.allocPrint(arena, "/{s}", .{site.slug});
    const totals_now = try data.totals(arena, ctx.db, view, view.range.start_ms, view.range.end_ms);
    try render(w, "<form method=\"post\" action=\"{path}/save\" data-dashboard{!editing}><input type=\"hidden\" name=\"widgets\" value=\"{widgets}\"></form><div class=\"grid grid-2\" data-tiles>", .{ .path = path, .editing = if (editing) " data-editing" else "", .widgets = current.widgets });
    var keys = std.mem.splitScalar(u8, current.widgets, ',');
    while (keys.next()) |key| {
        const info = widgetInfo(key) orelse continue;
        try render(w, "<div class=\"dash-tile{!editing}{!wide}\" data-key=\"{key}\"{!draggable}>", .{ .editing = if (editing) " editing" else "", .wide = if (info.wide) " span-all" else "", .key = key, .draggable = if (editing) " draggable=\"true\"" else "" });
        if (editing) {
            try w.writeAll("<div class=\"dash-tools\"><button type=\"button\" data-drag aria-label=\"Drag to move\">");
            try icon(w, "grip");
            try w.writeAll("</button><button type=\"button\" data-remove-tile aria-label=\"Remove widget\">");
            try icon(w, "x");
            try w.writeAll("</button></div>");
        }
        try renderWidget(ctx, view, base, key, totals_now);
        try w.writeAll("</div>");
    }
    if (editing) {
        try w.writeAll("<div class=\"add-tile span-all\"><div class=\"row\">");
        try icon(w, "plus");
        try render(w, "<strong>Add widget</strong></div><form method=\"post\" action=\"{path}/add\" class=\"widget-options\">", .{ .path = path });
        for (widget_catalog) |widget| {
            if (std.mem.eql(u8, widget.key, "funnel")) {
                for (try ctx.db.all(arena, struct { id: i64, name: []const u8 }, "SELECT id,name FROM funnels WHERE site_id=? ORDER BY name LIMIT 4", .{site.id})) |funnel| {
                    try render(w, "<button class=\"widget-option\" name=\"key\" value=\"funnel:{id}\">", .{ .id = funnel.id });
                    try icon(w, widget.icon);
                    try render(w, "<strong>{name}</strong><small>Funnel</small></button>", .{ .name = funnel.name });
                }
                continue;
            }
            try render(w, "<button class=\"widget-option\" name=\"key\" value=\"{key}\">", .{ .key = widget.key });
            try icon(w, widget.icon);
            try render(w, "<strong>{title}</strong><small>{hint}</small></button>", .{ .title = widget.title, .hint = widget.hint });
        }
        try render(w, "</form></div></div><form class=\"mt-16\" method=\"post\" action=\"{path}/delete\" data-undo=\"Dashboard deleted\"><button class=\"btn btn-quiet\">", .{ .path = path });
        try icon(w, "trash");
        try render(w, "Delete dashboard</button></form><dialog class=\"dialog\" id=\"dashboard-dialog\"><form method=\"post\" action=\"/{slug}/dashboards\"><div class=\"dialog-head\"><div><h2>New dashboard</h2><p>Starts with the essentials; edit it right after.</p></div></div><div class=\"dialog-body\"><label class=\"field\">Name<input class=\"input\" name=\"name\" required maxlength=\"60\"></label></div><div class=\"dialog-foot\"><button class=\"btn\" type=\"button\" data-close>Cancel</button><button class=\"btn btn-primary\">Create</button></div></form></dialog>", .{ .slug = site.slug });
    } else try w.writeAll("</div>");
    return layout.end(ctx);
}

fn renderWidget(ctx: *Ctx, view: data.View, base: []const u8, key: []const u8, totals_now: data.Totals) !void {
    const w = ctx.w();
    const arena = ctx.arena;
    if (std.mem.eql(u8, key, "metrics")) {
        const previous = try data.totals(arena, ctx.db, view, view.range.prev_start_ms, view.range.prev_end_ms);
        return overview.metricStrip(ctx, view, ctx.path, totals_now, previous);
    }
    if (std.mem.eql(u8, key, "trend")) return overview.trendCard(ctx, view, base);
    if (std.mem.eql(u8, key, "pages")) return overview.pagesCard(ctx, view);
    if (std.mem.eql(u8, key, "sources")) return overview.sourcesCard(ctx, view, base, totals_now.views);
    if (std.mem.eql(u8, key, "devices")) {
        try w.writeAll("<section class=\"card\">");
        try ui.cardHead(w, "Devices", "");
        try w.writeAll("<div class=\"rank\">");
        for (try data.top(arena, ctx.db, view, .device, 4)) |row| {
            const share = if (totals_now.views == 0) 0 else @as(f64, @floatFromInt(row.value)) / @as(f64, @floatFromInt(totals_now.views)) * 100;
            try ui.rankRow(w, arena, .{ .width = @max(share * 0.8, 4), .bar = "var(--brand-wash)", .name = row.key, .value = try std.fmt.allocPrint(arena, "{f}", .{html.int(row.value)}), .pct = try std.fmt.allocPrint(arena, "{d:.0}%", .{share}) });
        }
        return w.writeAll("</div></section>");
    }
    if (std.mem.eql(u8, key, "goals")) {
        const Goal = struct { name: []const u8, kind: []const u8, match: []const u8 };
        const goals = try ctx.db.all(arena, Goal, "SELECT name,kind,match_value FROM goals WHERE site_id=? ORDER BY name LIMIT 6", .{view.site.id});
        try w.writeAll("<section class=\"card\">");
        try ui.cardHead(w, "Goal conversions", "");
        try w.writeAll("<dl class=\"kv\">");
        for (goals) |goal| try render(w, "<dt>{name}</dt><dd>{count}</dd>", .{ .name = goal.name, .count = html.int((try data.goalCount(arena, ctx.db, view, goal.kind, goal.match, view.range.start_ms, view.range.end_ms, false)).completions) });
        try w.writeAll("</dl>");
        if (goals.len == 0) try render(w, "<p class=\"hint\">No goals yet. <a class=\"link\" href=\"/{slug}/events\">Track one →</a></p>", .{ .slug = view.site.slug });
        return w.writeAll("</section>");
    }
    if (std.mem.startsWith(u8, key, "funnel:")) {
        const funnel_id = std.fmt.parseInt(i64, key[7..], 10) catch return;
        const funnel = try ctx.db.one(arena, struct { name: []const u8, window: i64 }, "SELECT name,window_ms FROM funnels WHERE id=? AND site_id=?", .{ funnel_id, view.site.id }) orelse return w.writeAll("<section class=\"card\"><p class=\"hint\">This funnel was deleted.</p></section>");
        const steps = try ctx.db.all(arena, journeys.Step, "SELECT kind,match_value FROM funnel_steps WHERE funnel_id=? ORDER BY step_index", .{funnel_id});
        const counts = try journeys.computeFunnel(ctx, view, steps, funnel.window);
        try w.writeAll("<section class=\"card\">");
        try ui.cardHead(w, funnel.name, try html.print(arena, "<a class=\"link\" href=\"/{slug}/funnels/{id}\">Open →</a>", .{ .slug = view.site.slug, .id = funnel_id }));
        try w.writeAll("<div class=\"rank\">");
        for (steps, 0..) |step, index| {
            const share = if (counts[0] == 0) 0 else @as(f64, @floatFromInt(counts[index])) / @as(f64, @floatFromInt(counts[0])) * 100;
            try ui.rankRow(w, arena, .{ .width = @max(share * 0.8, 4), .bar = "var(--brand-wash)", .before = try std.fmt.allocPrint(arena, "<span class=\"n\">{d}</span>", .{index + 1}), .name = step.value, .value = try std.fmt.allocPrint(arena, "{f}", .{html.int(counts[index])}), .pct = try std.fmt.allocPrint(arena, "{d:.0}%", .{share}) });
        }
        return w.writeAll("</div></section>");
    }
    if (std.mem.eql(u8, key, "vitals")) {
        try w.writeAll("<section class=\"card\">");
        try ui.cardHead(w, "Web vitals · p75", "");
        try w.writeAll("<dl class=\"kv\">");
        const loaded = try journeys.loadSamples(ctx.arena, ctx.db, view);
        for (journeys.vitals, 0..) |vital, index| {
            const result = journeys.summarize(vital, loaded.all[index].items);
            if (result.samples == 0) {
                try render(w, "<dt>{name}</dt><dd class=\"muted\">—</dd>", .{ .name = vital.name });
            } else try render(w, "<dt>{name}</dt><dd class=\"{class}\">{value}</dd>", .{ .name = vital.name, .class = if (result.p75 <= vital.good) "good" else if (result.p75 <= vital.poor) "warn" else "bad", .value = journeys.VitalValue{ .vital = vital, .value = result.p75 } });
        }
        return w.writeAll("</dl></section>");
    }
}

const default_widgets = "metrics,trend,pages,sources";

pub fn addDashboard(ctx: *Ctx, site: data.Site) !void {
    const name = std.mem.trim(u8, try ctx.field("name"), " ");
    domain.validateText(name, 60, false) catch return overview.failBack(ctx, site, "Give the dashboard a name.");
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    db.run(ctx.arena, "INSERT INTO dashboards(site_id,name,widgets,created_at_ms,updated_at_ms) VALUES(?,?,?,?,?)", .{ site.id, name, default_widgets, ctx.now(), ctx.now() }) catch
        return overview.failBack(ctx, site, "A dashboard with that name already exists.");
    return ctx.redirectFmt("/{s}/dashboards/{d}?edit=1", .{ site.slug, db.lastInsertRowId() });
}

fn validWidgets(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var parts = std.mem.splitScalar(u8, raw, ',');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (widgetInfo(part) == null) continue;
        if (std.mem.startsWith(u8, part, "funnel") and (part.len < 8 or (std.fmt.parseInt(i64, part[7..], 10) catch null) == null)) continue;
        if (out.items.len != 0) try out.append(arena, ',');
        try out.appendSlice(arena, part);
        count += 1;
        if (count == 24) break;
    }
    return out.items;
}

pub fn dashboardAction(ctx: *Ctx, site: data.Site, id: i64, action: []const u8) !void {
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    const exists = try db.scalar(ctx.arena, i64, "SELECT count(*) FROM dashboards WHERE id=? AND site_id=?", .{ id, site.id });
    if (exists != 1) return layout.message(ctx, .not_found, "Dashboard not found", "It may have been deleted.");
    if (std.mem.eql(u8, action, "delete")) {
        try db.run(ctx.arena, "DELETE FROM dashboards WHERE id=?", .{id});
        return ctx.done("Dashboard deleted.", "/{s}/dashboards", .{site.slug});
    }
    var widgets: []const u8 = undefined;
    if (std.mem.eql(u8, action, "save")) {
        widgets = try validWidgets(ctx.arena, try ctx.field("widgets"));
    } else if (std.mem.eql(u8, action, "add")) {
        var statement = try db.prepare(ctx.arena, "SELECT widgets FROM dashboards WHERE id=?");
        defer statement.deinit();
        try statement.bindInt(1, id);
        _ = try statement.step();
        const current = statement.columnText(0);
        widgets = try validWidgets(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{s}{s}{s}", .{ current, if (current.len == 0) "" else ",", try ctx.field("key") }));
    } else return layout.message(ctx, .not_found, "Nothing here", "Unknown action.");
    try db.run(ctx.arena, "UPDATE dashboards SET widgets=?,updated_at_ms=? WHERE id=?", .{ widgets, ctx.now(), id });
    if (std.mem.eql(u8, ctx.head.accept, "application/json")) {
        try ctx.w().writeAll("{\"ok\":true}");
        return ctx.json();
    }
    return ctx.redirectFmt("/{s}/dashboards/{d}?edit=1", .{ site.slug, id });
}

test "next run" {
    const monday = try data.parseDate("2026-09-21");
    try std.testing.expectEqual(monday + 7 * data.day_ms + 9 * data.hour_ms, nextRun("weekly", 0, 9, monday + 10 * data.hour_ms));
    try std.testing.expectEqual(monday + 9 * data.hour_ms, nextRun("daily", 0, 9, monday + 8 * data.hour_ms));
    try std.testing.expectEqual(try data.parseDate("2026-10-01") + 9 * data.hour_ms, nextRun("monthly", 0, 9, monday));
}
