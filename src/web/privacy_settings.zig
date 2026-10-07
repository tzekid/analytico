//! Settings → Consent & privacy, and Settings → Recording.
const std = @import("std");
const audit = @import("audit.zig");
const ctx_mod = @import("ctx.zig");
const customers = @import("customers.zig");
const data = @import("data.zig");
const domain = @import("../domain.zig");
const html = @import("html.zig");
const layout = @import("layout.zig");
const ui = @import("ui.zig");
const replay = @import("../replay.zig");

const Ctx = ctx_mod.Ctx;
const icon = layout.icon;
const render = html.render;

fn fail(ctx: *Ctx, section: []const u8, site: data.Site, text: []const u8) !void {
    return ctx.done(try std.fmt.allocPrint(ctx.arena, "!{s}", .{text}), "/settings/{s}?site={s}", .{ section, site.slug });
}

// ---------------------------------------------------------------- Consent & privacy

pub fn consentSection(ctx: *Ctx, maybe_site: ?data.Site) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    const site = maybe_site orelse return;
    try ui.sectionHead(w, "Consent & privacy", "Who gets Full mode, how they are asked, and the promises that never change.", "");
    if (site.mode != .full) {
        try render(w,
            \\<div class="callout mb-16"><span>{mode} mode never stores anything that needs consent, so nobody is asked. Switch to Full mode under <a class="link" href="/settings/sites?site={slug}">Website &amp; tracking</a> to remember visitors who agree.</span></div>
        , .{ .mode = site.modeLabel(), .slug = site.slug });
    } else {
        // This week's visitors by consent outcome.
        const kinds = [_]struct { []const u8, []const u8, []const u8 }{
            .{ "granted", "Full · agreed", "#2f8f5b" },
            .{ "not_required", "Full · not asked (consent not required)", "#86bf9c" },
            .{ "denied", "Lite · declined", "#a0948e" },
            .{ "gpc", "Lite · Global Privacy Control", "#6a96d1" },
            .{ "pending", "Lite · no answer yet", "#d9a95e" },
        };
        var counts: [kinds.len]i64 = @splat(0);
        var total: i64 = 0;
        const Row = struct { mode: []const u8, visitors: i64 };
        for (try ctx.db.all(arena, Row, "SELECT consent_mode,count(DISTINCT coalesce(visitor_id,visitor_day_id)) FROM page_views WHERE site_id=? AND received_at_ms>=? AND internal=0 AND tracking_mode='full' GROUP BY 1", .{ site.id, ctx.now() - 7 * data.day_ms })) |row| {
            for (kinds, 0..) |kind, index| if (std.mem.eql(u8, kind[0], row.mode)) {
                counts[index] += row.visitors;
            };
            total += row.visitors;
        }
        try render(w,
            \\<section class="card mb-16"><div class="card-head"><h2>This week’s visitors, by mode</h2><span class="meta">{total} visitors</span></div><div class="share-bar consent-bar">
        , .{ .total = html.int(total) });
        for (kinds, 0..) |kind, index| if (counts[index] > 0) try render(w, "<span style=\"flex:{count};background:{color}\"></span>", .{ .count = counts[index], .color = kind[2] });
        try w.writeAll("</div><div class=\"grid grid-2 consent-legend\">");
        for (kinds, 0..) |kind, index| try render(w,
            \\<div class="row-between t-13"><span class="row nowrap"><span class="dot-mark" style="background:{color}"></span>{label}</span><strong>{share}</strong></div>
        , .{ .color = kind[2], .label = kind[1], .share = html.share(counts[index], total) });
        try w.writeAll("</div><p class=\"hint mt-12\">Everyone is counted. Only “Full” visitors are remembered across days, recorded or shown on heatmaps.</p></section>");
    }

    try render(w,
        \\<div class="grid grid-2"><form class="card form-grid" method="post" action="/settings/consent/update"><input type="hidden" name="site" value="{slug}"><h2 class="card-title">Who is asked</h2><div class="stack-s">
    , .{ .slug = site.slug });
    const policies = [_]struct { domain.ConsentPolicy, []const u8, []const u8 }{
        .{ .regional, "EU, UK and Switzerland", "Recommended. Everyone else gets Full right away; the country is decided at collection, unknown countries are asked." },
        .{ .everyone, "Everyone", "The safest choice if you are unsure where your visitors are." },
        .{ .none, "No one — consent isn’t required for my site", "You take responsibility. Global Privacy Control is still respected." },
    };
    for (policies) |policy| try render(w,
        \\<label class="radio-row"><input type="radio" name="policy" value="{value}"{!checked}><span><strong>{title}</strong><small>{help}</small></span></label>
    , .{ .value = policy[0], .checked = if (site.consent_policy == policy[0]) " checked" else "", .title = policy[1], .help = policy[2] });
    const default_text = "This site would like to measure how visitors use it, to improve it. Nothing is stored on your device unless you allow it.";
    try render(w,
        \\</div><h2 class="card-title mt-8">How you ask</h2>
        \\<label class="check"><span class="switch"><input type="checkbox" name="banner" value="1"{!banner}></span>Show the Analytico banner (small, accessible, two equal buttons)</label>
        \\<label class="field">Banner text<textarea class="input" name="banner_text" rows="3" maxlength="400" placeholder="{default_text}">{text}</textarea></label>
        \\<label class="field">Privacy policy link<input class="input" type="url" name="privacy_url" value="{privacy}" placeholder="https://example.com/privacy"></label>
        \\<div class="banner-preview" aria-hidden="true"><p>{preview} <u>Privacy policy</u></p><div class="row end"><span class="btn">No thanks</span><span class="btn">Allow</span></div></div>
        \\<p class="hint">Already have a consent tool (Cookiebot, Usercentrics, Klaro…)? Call <code>analytico.consent("granted")</code> or <code>("denied")</code> from it. Google Consent Mode’s <code>analytics_storage</code> is followed automatically.</p>
        \\<div class="row end"><button class="btn btn-primary">Save</button></div></form>
    , .{
        .banner = if (site.consent_banner) " checked" else "",
        .default_text = default_text,
        .text = site.banner_text,
        .privacy = site.privacy_url,
        .preview = if (site.banner_text.len != 0) site.banner_text else default_text,
    });

    try w.writeAll("<div class=\"stack\"><section class=\"card\"><h2 class=\"card-title\">Always true, in every mode</h2><div class=\"stack-s mt-12\">");
    const promises = [_][]const u8{
        "Global Privacy Control and Do Not Track keep a visitor in Lite",
        "IP addresses are used for the country, then discarded",
        "Typed values, passwords and card numbers are never recorded",
        "No fingerprinting, no third-party cookies, no data selling",
        "Data stays on this server; AI only ever sees aggregates",
        "Anyone can be forgotten — by you, or by your app through the API",
    };
    for (promises) |line| {
        try w.writeAll("<div class=\"row nowrap t-13\"><span class=\"good\">");
        try icon(w, "check");
        try render(w, "</span><span>{line}</span></div>", .{ .line = line });
    }
    const deletions = try ctx.db.scalar(arena, i64, "SELECT count(*) FROM audit_log WHERE site_id=? AND action='person.deleted' AND at_ms>=?", .{ site.id, ctx.now() - 30 * data.day_ms });
    try render(w,
        \\</div></section><section class="card"><h2 class="card-title">Privacy requests</h2><p class="hint">{deletions} deletion{plural} in the last 30 days</p>
        \\<form method="post" action="/settings/consent/forget" class="row nowrap mt-12" data-confirm="Delete everything stored about this person? This cannot be undone."><input type="hidden" name="site" value="{slug}">
        \\<input class="input mono" name="person" required placeholder="Your user ID, or a visitor ID" aria-label="User ID or visitor ID"><button class="btn btn-danger">Delete…</button></form>
        \\<form method="get" action="/settings/consent/export" class="row nowrap mt-8"><input type="hidden" name="site" value="{slug}"><input class="input mono" name="person" required placeholder="Your user ID, or a visitor ID" aria-label="User ID or visitor ID to export"><button class="btn">Export (JSON)</button></form>
        \\<p class="hint mt-12">A “Forget me” link on your privacy page: <code>&lt;button onclick="analytico.forget()"&gt;Forget me&lt;/button&gt;</code> — erases the visitor’s data and stops tracking them. From your backend, send a <code>forget</code> record with their user ID to <code>/i</code>.</p></section></div></div>
    , .{ .deletions = deletions, .plural = if (deletions == 1) "" else "s", .slug = site.slug });
}

/// The person key for a typed user ID or visitor ID.
fn personKey(ctx: *Ctx, site: data.Site, raw: []const u8) ![]const u8 {
    const value = std.mem.trim(u8, raw, " ");
    if (domain.validateUuid(value)) |_| return value else |_| {}
    const hash = domain.userHash(ctx.shared.master_key, site.public_id, value);
    return ctx.arena.dupe(u8, &hash);
}

pub fn consentPost(ctx: *Ctx, action: []const u8) !void {
    const arena = ctx.arena;
    const site = try ctx.visibleSite(try ctx.field("site")) orelse return layout.message(ctx, .not_found, "Unknown website", "");
    if (std.mem.eql(u8, action, "forget")) {
        const key = try personKey(ctx, site, try ctx.field("person"));
        return customers.forget(ctx, site, key);
    }
    if (!std.mem.eql(u8, action, "update")) return fail(ctx, "consent", site, "Unknown action.");
    const policy = domain.parseConsentPolicy(try ctx.field("policy")) catch return fail(ctx, "consent", site, "Choose who is asked.");
    const text = std.mem.trim(u8, try ctx.field("banner_text"), " \r\n");
    domain.validateText(text, 400, true) catch return fail(ctx, "consent", site, "The banner text can’t contain line breaks or control characters.");
    const privacy = std.mem.trim(u8, try ctx.field("privacy_url"), " ");
    if (privacy.len != 0 and !(std.mem.startsWith(u8, privacy, "https://") or std.mem.startsWith(u8, privacy, "http://"))) return fail(ctx, "consent", site, "The privacy link must start with https://.");
    if (privacy.len > 300) return fail(ctx, "consent", site, "The privacy link is too long.");
    const banner = (try ctx.field("banner")).len != 0;
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    try db.run(arena, "UPDATE sites SET consent_policy=?,consent_banner=?,banner_text=?,privacy_url=? WHERE id=?", .{ @tagName(policy), @intFromBool(banner), text, privacy, site.id });
    try audit.record(ctx, db, site.id, "consent.changed", try std.fmt.allocPrint(arena, "Ask: {s} · banner {s}", .{ switch (policy) {
        .regional => "in EU, UK, CH",
        .everyone => "everyone",
        .none => "no one",
    }, if (banner) "on" else "off" }));
    return ctx.done("Consent settings saved.", "/settings/consent?site={s}", .{site.slug});
}

pub fn consentExport(ctx: *Ctx) !void {
    const site = try ctx.visibleSite(ctx.param("site") orelse "") orelse return layout.message(ctx, .not_found, "Unknown website", "");
    const key = try personKey(ctx, site, ctx.param("person") orelse "");
    return ctx.redirectFmt("/{s}/people/{s}?format=json", .{ site.slug, key });
}

// ---------------------------------------------------------------- Recording

pub fn recordingSection(ctx: *Ctx, maybe_site: ?data.Site) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    const site = maybe_site orelse return;
    try ui.sectionHead(w, "Recording", "Replays and heatmaps — only for visitors in Full mode who agreed.", "");
    if (site.mode != .full) try render(w,
        \\<div class="callout mb-16"><span>Replays and heatmaps need Full mode. Switch under <a class="link" href="/settings/sites?site={slug}">Website &amp; tracking</a>.</span></div>
    , .{ .slug = site.slug });
    const retention = (try data.setting(arena, ctx.db, .@"replays.retention_days")) orelse "30";
    try render(w,
        \\<div class="grid split-main"><form class="card form-grid" method="post" action="/settings/recording/update"><input type="hidden" name="site" value="{slug}">
        \\<h2 class="card-title">Session replay</h2>
        \\<label class="field"><span class="row-between">Record a sample of sessions <output data-for="replay_percent">{percent}%</output></span><input type="range" name="replay_percent" min="0" max="100" step="1" value="{percent}" data-output></label>
        \\<label class="check"><input type="checkbox" name="replay_triggers" value="1"{!triggers}>And always record sessions with a rage click, a JavaScript error, a goal or a purchase</label>
        \\<p class="hint">Sessions that aren’t sampled keep about two minutes in the visitor’s browser, sent only if one of those happens.</p>
        \\<h2 class="card-title mt-6">What is hidden</h2>
        \\<label class="radio-row"><input type="radio" name="mask_text" value="1"{!mask_all}><span><strong>Mask all text</strong><small>Unmask safe areas with <code>data-analytico-unmask</code></small></span></label>
        \\<label class="radio-row"><input type="radio" name="mask_text" value="0"{!mask_inputs}><span><strong>Mask inputs only</strong><small>Shows page text as-is</small></span></label>
        \\<div class="callout"><span>Always hidden: every input value, passwords and card fields, images, video, canvases and embedded frames. Hide anything else with <code>data-analytico-block</code>.</span></div>
        \\<label class="field"><span class="row-between">Keep recordings for<select class="input input-s" name="retention">
    , .{
        .slug = site.slug,
        .percent = site.replay_percent,
        .triggers = if (site.replay_triggers) " checked" else "",
        .mask_all = if (site.mask_text) " checked" else "",
        .mask_inputs = if (!site.mask_text) " checked" else "",
    });
    for ([_][]const u8{ "7", "14", "30", "90" }) |days| try render(w, "<option value=\"{days}\"{!selected}>{days} days</option>", .{ .days = days, .selected = if (std.mem.eql(u8, days, retention)) " selected" else "" });
    try render(w,
        \\</select></span><small>Recordings stop after 30 minutes or 5 MB per session.</small></label>
        \\<label class="field">Never record these pages<textarea class="input mono" name="record_exclude" rows="4" placeholder="/account/*&#10;/checkout/payment">{exclude}</textarea><small>One path per line; <code>*</code> matches anything. Replays and heatmaps skip them; page views still count.</small></label>
        \\<div class="row end"><button class="btn btn-primary">Save</button></div></form>
    , .{ .exclude = site.record_exclude });
    const Stats = struct { count: i64, bytes: i64 };
    const stats = (try ctx.db.one(arena, Stats, "SELECT count(*),coalesce(sum(bytes),0) FROM rp.replays WHERE site_id=?", .{site.id})).?;
    const assets = @import("../assets.zig");
    try render(w,
        \\<div class="stack"><section class="card"><h2 class="card-title">Heatmaps</h2><p class="hint mt-6">Clicks, scroll depth and attention, summed per element on a grid. No mouse trails, nothing per person. On for every consented visitor except on the pages above.</p></section>
        \\<section class="card"><h2 class="card-title">Storage</h2><div class="metric-value mt-6">{megabytes:.1} MB</div><p class="hint">{count} recording{plural} in <code>replays.db</code>, separate from your analytics, with its own backups and retention.</p>
        \\<form class="mt-12" method="post" action="/settings/recording/delete-all" data-confirm="Delete every recording of this website? This cannot be undone."><input type="hidden" name="site" value="{slug}"><button class="btn btn-quiet bad">Delete all recordings…</button></form></section>
        \\<section class="card"><h2 class="card-title">How it loads</h2><p class="hint mt-6">The recorder (rrweb, open source) loads only for consented sessions that record. Everyone else downloads nothing extra.</p>
        \\<dl class="kv mt-10"><dt>Core tracker · everyone</dt><dd>{core} KB</dd><dt>Recorder · recorded sessions only</dt><dd>+{recorder} KB</dd></dl><p class="hint mt-6">Sizes before compression; served gzipped they are about a third.</p></section></div></div>
    , .{
        .megabytes = @as(f64, @floatFromInt(stats.bytes)) / 1_048_576.0,
        .count = html.int(stats.count),
        .plural = if (stats.count == 1) "" else "s",
        .slug = site.slug,
        .core = @divFloor(assets.bytes(.full).len, 1024),
        .recorder = @divFloor(assets.bytes(.replay).len, 1024),
    });
}

pub fn recordingPost(ctx: *Ctx, action: []const u8) !void {
    const arena = ctx.arena;
    const site = try ctx.visibleSite(try ctx.field("site")) orelse return layout.message(ctx, .not_found, "Unknown website", "");
    if (std.mem.eql(u8, action, "delete-all")) {
        {
            const replays = ctx.shared.lockReplays();
            defer ctx.shared.unlockReplays();
            try replays.run(arena, "DELETE FROM replay_chunks WHERE site_id=?", .{site.id});
            try replays.run(arena, "DELETE FROM replays WHERE site_id=?", .{site.id});
            try replays.exec("PRAGMA incremental_vacuum");
        }
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try audit.record(ctx, db, site.id, "replays.deleted", "Deleted all recordings");
        return ctx.done("All recordings deleted.", "/settings/recording?site={s}", .{site.slug});
    }
    if (!std.mem.eql(u8, action, "update")) return fail(ctx, "recording", site, "Unknown action.");
    const percent = std.math.clamp(std.fmt.parseInt(i64, try ctx.field("replay_percent"), 10) catch 0, 0, 100);
    const triggers = (try ctx.field("replay_triggers")).len != 0;
    const mask_text = !std.mem.eql(u8, try ctx.field("mask_text"), "0");
    const exclude = std.mem.trim(u8, try ctx.field("record_exclude"), " \r\n");
    if (exclude.len > 2000) return fail(ctx, "recording", site, "Too many excluded pages.");
    var lines = std.mem.tokenizeAny(u8, exclude, "\r\n");
    while (lines.next()) |line| {
        const pattern = std.mem.trim(u8, line, " ");
        if (pattern.len == 0) continue;
        if (pattern[0] != '/' or pattern.len > 200 or std.mem.findAny(u8, pattern, "?# ") != null) return fail(ctx, "recording", site, "Excluded pages start with / and have no query string, like /account/*.");
    }
    const retention = std.fmt.parseInt(i64, try ctx.field("retention"), 10) catch 30;
    if (retention < 1 or retention > 365) return fail(ctx, "recording", site, "Pick how long to keep recordings.");
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    try db.run(arena, "UPDATE sites SET replay_percent=?,replay_triggers=?,mask_text=?,record_exclude=? WHERE id=?", .{ percent, @intFromBool(triggers), @intFromBool(mask_text), exclude, site.id });
    try data.putSetting(arena, db, .@"replays.retention_days", try std.fmt.allocPrint(arena, "{d}", .{retention}));
    try audit.record(ctx, db, site.id, "recording.changed", try std.fmt.allocPrint(arena, "Session replay at {d}%{s} · {s} · kept {d} days", .{ percent, if (triggers) " plus triggers" else "", if (mask_text) "all text masked" else "inputs masked", retention }));
    return ctx.done("Recording settings saved.", "/settings/recording?site={s}", .{site.slug});
}

/// Nightly replay retention, on the replay database's own schedule.
pub fn pruneReplays(arena: std.mem.Allocator, shared: anytype, db: anytype, now_ms: i64) !void {
    const days = std.fmt.parseInt(i64, (try data.setting(arena, db, .@"replays.retention_days")) orelse "30", 10) catch 30;
    const replays = shared.lockReplays();
    defer shared.unlockReplays();
    const removed = try replay.prune(arena, replays, now_ms - days * data.day_ms);
    if (removed != 0) std.log.info("replays_pruned rows={d}", .{removed});
}
