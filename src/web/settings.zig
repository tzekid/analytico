//! Instance settings: websites, team, email, backups, retention, diagnostics, AI.
const std = @import("std");
const ai = @import("ai.zig");
const auth = @import("auth.zig");
const ctx_mod = @import("ctx.zig");
const data = @import("data.zig");
const db_mod = @import("../db.zig");
const domain = @import("../domain.zig");
const html = @import("html.zig");
const layout = @import("layout.zig");
const ui = @import("ui.zig");
const mail = @import("mail.zig");
const manage = @import("manage.zig");
const ops = @import("../ops.zig");
const schema = @import("../schema.zig");
const secret = @import("secret.zig");
const server = @import("../server.zig");

const Ctx = ctx_mod.Ctx;
const icon = layout.icon;
const render = html.render;

const sections = [_][3][]const u8{
    .{ "sites", "Website & tracking", "sites" },
    .{ "consent", "Consent & privacy", "shield-check" },
    .{ "recording", "Recording", "play-circle" },
    .{ "team", "Team & roles", "team" },
    .{ "signin", "Sign-in", "lock" },
    .{ "integrations", "Integrations", "plug" },
    .{ "api", "API & public links", "key" },
    .{ "email", "Email delivery", "mail" },
    .{ "backups", "Backups", "download" },
    .{ "retention", "Data retention", "calendar" },
    .{ "audit", "Audit log", "history" },
    .{ "diagnostics", "Diagnostics", "stethoscope" },
    .{ "ai", "AI", "sparkles" },
};

const privacy = @import("privacy_settings.zig");
const team_settings = @import("team_settings.zig");
const integrations = @import("integrations.zig");

/// Everyone manages their own sign-in methods and ChatGPT plan; the rest
/// is for admins.
fn allowed(ctx: *Ctx, section: []const u8) bool {
    return is(section, "signin") or is(section, "ai") or ctx.can(.admin);
}

/// An API-key provider named in a URL or form (a plan is not a key).
fn keyProvider(name: []const u8) ai.Provider {
    const provider = std.meta.stringToEnum(ai.Provider, name) orelse return .anthropic;
    return if (provider == .chatgpt) .anthropic else provider;
}

fn is(value: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, value, expected);
}

pub fn route(ctx: *Ctx, parts: []const []const u8) !void {
    const section = if (parts.len == 0) "" else parts[0];
    const site_query = if (ctx.param("site")) |slug| try std.fmt.allocPrint(ctx.arena, "?site={f}", .{html.url(slug)}) else "";
    if (section.len == 0) return ctx.redirectFmt("/settings/{s}{s}", .{ if (ctx.can(.admin)) "sites" else "signin", site_query });
    if (!allowed(ctx, section)) return @import("app.zig").forbidden(ctx);
    if (ctx.method == .POST) {
        const action = if (parts.len >= 2) parts[1] else "";
        if (is(section, "sites")) return sitePost(ctx, action);
        if (is(section, "consent")) return privacy.consentPost(ctx, action);
        if (is(section, "recording")) return privacy.recordingPost(ctx, action);
        if (is(section, "api")) return team_settings.apiPost(ctx, action, page);
        if (is(section, "team")) return team_settings.teamPost(ctx, action, if (parts.len >= 3) parts[2] else "", page);
        if (is(section, "signin")) return @import("signin_settings.zig").post(ctx, action);
        if (is(section, "email")) return emailPost(ctx, action);
        if (is(section, "backups")) return backupPost(ctx, action);
        if (is(section, "retention")) return retentionPost(ctx);
        if (is(section, "ai") and is(action, "chatgpt") and parts.len == 3) return @import("chatgpt.zig").route(ctx, parts[2]);
        if (is(section, "ai")) {
            if (!ctx.can(.admin)) return @import("app.zig").forbidden(ctx);
            return aiPost(ctx, action);
        }
    } else {
        if (is(section, "consent") and parts.len == 2 and is(parts[1], "export")) return privacy.consentExport(ctx);
        if (is(section, "ai") and parts.len == 3 and is(parts[1], "chatgpt")) return @import("chatgpt.zig").route(ctx, parts[2]);
        if (is(section, "ai") and parts.len >= 2 and !ctx.can(.admin)) return @import("app.zig").forbidden(ctx);
        if (is(section, "ai") and parts.len == 2 and is(parts[1], "status.json")) return aiStatus(ctx);
        if (is(section, "ai") and parts.len == 2 and is(parts[1], "preview")) return aiPreview(ctx);
        if (is(section, "ai") and parts.len == 3 and is(parts[1], "log")) return aiLogEntry(ctx, std.fmt.parseInt(i64, parts[2], 10) catch 0);
        if (parts.len == 1) for (sections) |entry| if (is(entry[0], section)) return page(ctx, section, "");
    }
    return layout.message(ctx, .not_found, "Nothing here", "That settings page doesn’t exist.");
}

fn currentSite(ctx: *Ctx) !?data.Site {
    if (ctx.param("site")) |slug| if (try data.siteBySlug(ctx.arena, ctx.db, slug)) |site| return site;
    const sites = try ctx.visibleSites();
    return if (sites.len == 0) null else sites[0];
}

fn page(ctx: *Ctx, section: []const u8, notice: []const u8) !void {
    const arena = ctx.arena;
    const sites = try ctx.visibleSites();
    const site = try currentSite(ctx);
    const shell: layout.Shell = .{ .title = "Settings", .nav = .settings, .site = site, .sites = sites, .health = if (site) |value| try manage.healthLevel(ctx, value) else .ok };
    try layout.begin(ctx, shell);
    const w = ctx.w();
    try layout.head(ctx, .{ .title = "Settings", .subtitle = if (site) |value| try std.fmt.allocPrint(arena, "{s} · self-hosted instance", .{value.title()}) else "Self-hosted instance" });
    try w.writeAll("<div class=\"settings\"><nav class=\"subnav\" aria-label=\"Settings\">");
    const query = if (site) |value| try std.fmt.allocPrint(arena, "?site={s}", .{value.slug}) else "";
    for (sections) |entry| {
        if (!allowed(ctx, entry[0])) continue;
        try render(w, "<a class=\"nav\" href=\"/settings/{section}{query}\"{!current}>", .{ .section = entry[0], .query = query, .current = if (is(entry[0], section)) " aria-current=\"page\"" else "" });
        try icon(w, entry[2]);
        try render(w, "<span>{label}</span></a>", .{ .label = entry[1] });
    }
    try w.writeAll("<form method=\"post\" action=\"/logout\"><button class=\"nav\">");
    try icon(w, "logout");
    try render(w, "<span>Sign out</span></button></form><p class=\"hint subnav-who\">{email}</p></nav><div class=\"min-0\">", .{ .email = if (ctx.user) |user| user.email else "" });
    if (notice.len != 0 and !is(section, "team") and !is(section, "api")) try w.print("{s}", .{notice});
    if (is(section, "sites")) try sitesSection(ctx, site) else if (is(section, "consent")) try privacy.consentSection(ctx, site) else if (is(section, "recording")) try privacy.recordingSection(ctx, site) else if (is(section, "integrations")) try integrations.section(ctx, site) else if (is(section, "api")) try team_settings.apiSection(ctx, site, notice) else if (is(section, "audit")) try team_settings.auditSection(ctx) else if (is(section, "team")) try team_settings.teamSection(ctx, notice) else if (is(section, "signin")) try @import("signin_settings.zig").section(ctx) else if (is(section, "email")) try emailSection(ctx) else if (is(section, "backups")) try backupsSection(ctx) else if (is(section, "retention")) try retentionSection(ctx) else if (is(section, "diagnostics")) try diagnosticsSection(ctx) else if (is(section, "ai")) try aiSection(ctx, site);
    try w.writeAll("</div></div>");
    return layout.end(ctx);
}

fn backTo(ctx: *Ctx, section: []const u8) ![]const u8 {
    const slug = (ctx.field("site") catch "");
    if (slug.len != 0) return std.fmt.allocPrint(ctx.arena, "/settings/{s}?site={f}", .{ section, html.url(slug) });
    return std.fmt.allocPrint(ctx.arena, "/settings/{s}", .{section});
}

fn fail(ctx: *Ctx, section: []const u8, text: []const u8) !void {
    return ctx.done(try std.fmt.allocPrint(ctx.arena, "!{s}", .{text}), "{s}", .{try backTo(ctx, section)});
}

// ---------------------------------------------------------------- Website & tracking

fn sitesSection(ctx: *Ctx, maybe_site: ?data.Site) !void {
    const w = ctx.w();
    const arena = ctx.arena;
    const site = maybe_site orelse {
        try ui.empty(w, "No websites yet", "Add your first website to start collecting.", "<a class=\"btn btn-primary\" href=\"/setup\">Add a website</a>");
        return;
    };
    try ui.sectionHead(w, "Website & tracking", "How this website is identified and what the tracker collects.", "<a class=\"btn\" href=\"/setup\">Add a website</a>");
    try render(w,
        \\<form class="card form-grid" method="post" action="/settings/sites/update"><input type="hidden" name="site" value="{slug}">
        \\<label class="field">Display name<input class="input" name="name" value="{name}" maxlength="60" placeholder="{host}"></label><div><div class="field mb-8">Tracking mode</div>
    , .{ .slug = site.slug, .name = site.name, .host = site.host() });
    try manage.modeCards(w, site.mode);
    try render(w,
        \\<p class="hint mt-6">Switching changes the snippet — update it on your site. Existing data is kept. Full mode’s consent rules are under <a class="link" href="/settings/consent?site={slug}">Consent &amp; privacy</a>.</p></div>
        \\<label class="check"><span class="switch"><input type="checkbox" name="enabled" value="1"{!enabled}></span>Collect data for this website</label>
        \\<div class="row end"><button class="btn btn-primary">Save changes</button></div></form>
        \\<h3 class="section-title">Allowed origins<span class="note">Browser events from other origins are rejected</span></h3><section class="card card-flush">
    , .{ .slug = site.slug, .enabled = if (site.enabled) " checked" else "" });
    for (try ctx.db.all(arena, struct { origin: []const u8 }, "SELECT origin FROM site_origins WHERE site_id=? ORDER BY origin", .{site.id})) |row| {
        try render(w,
            \\<div class="list-row list-row-2"><span class="mono">{origin}</span><form method="post" action="/settings/sites/origin-remove" data-confirm="Stop accepting events from this origin?"><input type="hidden" name="site" value="{slug}"><input type="hidden" name="origin" value="{origin}"><button class="btn btn-quiet btn-icon" aria-label="Remove origin">
        , .{ .origin = row.origin, .slug = site.slug });
        try icon(w, "trash");
        try w.writeAll("</button></form></div>");
    }
    const code = try manage.snippet(ctx, site, false);
    try render(w,
        \\<form class="card-foot start" method="post" action="/settings/sites/origin-add"><input type="hidden" name="site" value="{slug}"><input class="input mono input-m" name="origin" placeholder="https://staging.example.com" required><button class="btn">Add origin</button></form></section>
        \\<h3 class="section-title">Snippet</h3><div class="code"><button class="copy" type="button" data-copy="{code}">Copy</button>{code}</div>
    , .{ .slug = site.slug, .code = code });
    const raw_secret = try ctx.db.scalar(arena, []const u8, "SELECT internal_secret FROM sites WHERE id=?", .{site.id});
    if (raw_secret.len == 32) {
        const hex = std.fmt.bytesToHex(raw_secret[0..32].*, .lower);
        try render(w,
            \\<h3 class="section-title">Server events<span class="note">Signed POSTs to /i from your backend</span></h3><details class="card"><summary class="t-13 strong">Show signing secret</summary><p class="hint mt-10 mb-10">HMAC-SHA256 key for the <code>x-analytico-signature</code> header. Keep it on your server.</p><div class="code"><button class="copy" type="button" data-copy="{secret}">Copy</button>{secret}</div><p class="hint mt-10">Site ID: <span class="mono">{id}</span></p></details>
        , .{ .secret = &hex, .id = site.public_id });
    }
}

fn sitePost(ctx: *Ctx, action: []const u8) !void {
    const arena = ctx.arena;
    const site = try data.siteBySlug(arena, ctx.db, try ctx.field("site")) orelse return fail(ctx, "sites", "Unknown website.");
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    if (is(action, "update")) {
        const name = std.mem.trim(u8, try ctx.field("name"), " ");
        domain.validateText(name, 60, true) catch return fail(ctx, "sites", "Names can’t contain control characters.");
        const mode = domain.parseMode(try ctx.field("mode")) catch site.mode;
        const enabled = (try ctx.field("enabled")).len != 0;
        try db.run(arena, "UPDATE sites SET name=?,tracking_mode=?,enabled=? WHERE id=?", .{ name, @tagName(mode), @intFromBool(enabled), site.id });
        try @import("audit.zig").record(ctx, db, site.id, "site.changed", try std.fmt.allocPrint(arena, "{s} mode · {s}", .{ @tagName(mode), if (enabled) "collecting" else "paused" }));
        try ctx.flash(if (mode != site.mode) "Saved. Update the snippet on your site to switch modes." else "Saved.", "", "");
    } else if (is(action, "origin-add")) {
        const origin = domain.normalizeOrigin(arena, std.mem.trim(u8, try ctx.field("origin"), " /")) catch return fail(ctx, "sites", "Origins look like https://example.com — no path.");
        db.run(arena, "INSERT INTO site_origins(site_id,origin) VALUES(?,?)", .{ site.id, origin }) catch return fail(ctx, "sites", "That origin is already allowed.");
        try ctx.flash("Origin added.", "", "");
    } else if (is(action, "origin-remove")) {
        if (try db.scalar(arena, i64, "SELECT count(*) FROM site_origins WHERE site_id=?", .{site.id}) <= 1) return fail(ctx, "sites", "Keep at least one origin.");
        try db.run(arena, "DELETE FROM site_origins WHERE site_id=? AND origin=?", .{ site.id, try ctx.field("origin") });
        try ctx.flash("Origin removed.", "", "");
    } else return fail(ctx, "sites", "Unknown action.");
    return ctx.redirect(try backTo(ctx, "sites"));
}

// ---------------------------------------------------------------- Email delivery

fn emailSection(ctx: *Ctx) !void {
    const w = ctx.w();
    const arena = ctx.arena;
    const db = ctx.db;
    try ui.sectionHead(w, "Email delivery", "Used for alerts, scheduled reports and invites. Any SMTP provider works.", "");
    const host = (try data.setting(arena, db, .@"smtp.host")) orelse "";
    const security = (try data.setting(arena, db, .@"smtp.security")) orelse "starttls";
    const has_password = (try data.setting(arena, db, .@"smtp.password")) != null;
    try render(w,
        \\<form class="card form-grid" method="post" action="/settings/email/save"><div class="grid grid-port"><label class="field">SMTP server<input class="input" name="host" value="{host}" placeholder="smtp.example.com"></label><label class="field">Port<input class="input" name="port" inputmode="numeric" value="{port}"></label></div>
        \\<label class="field">Security<select class="input" name="security"><option value="starttls"{!starttls}>STARTTLS (port 587)</option><option value="tls"{!tls}>TLS (port 465)</option><option value="none"{!none}>None — local relay only</option></select></label>
        \\<div class="grid grid-2 gap-12"><label class="field">Username<input class="input" name="username" value="{username}" autocomplete="off"></label><label class="field">Password<input class="input" type="password" name="password" autocomplete="new-password" placeholder="{password}"></label></div>
        \\<label class="field">From<input class="input" name="from" value="{from}" placeholder="Analytico &lt;analytics@example.com&gt;"></label>
        \\<div class="row-between"><span class="hint">The password is encrypted on this server.</span><div class="row">
    , .{
        .host = host,
        .port = (try data.setting(arena, db, .@"smtp.port")) orelse "587",
        .starttls = if (is(security, "starttls")) " selected" else "",
        .tls = if (is(security, "tls")) " selected" else "",
        .none = if (is(security, "none")) " selected" else "",
        .username = (try data.setting(arena, db, .@"smtp.username")) orelse "",
        .password = if (has_password) "Saved — leave empty to keep" else "",
        .from = (try data.setting(arena, db, .@"smtp.from")) orelse "",
    });
    if (host.len != 0) try w.writeAll("<button class=\"btn\" formaction=\"/settings/email/test\">Send test email</button>");
    try w.writeAll("<button class=\"btn btn-primary\">Save</button></div></div></form>");
    if (host.len != 0) try w.writeAll("<form class=\"mt-12\" method=\"post\" action=\"/settings/email/clear\" data-confirm=\"Remove the email settings?\"><button class=\"btn btn-quiet\">Remove email settings</button></form>");
}

fn emailPost(ctx: *Ctx, action: []const u8) !void {
    const arena = ctx.arena;
    if (is(action, "clear")) {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        inline for (.{ .@"smtp.host", .@"smtp.port", .@"smtp.security", .@"smtp.username", .@"smtp.password", .@"smtp.from" }) |name| try data.putSetting(arena, db, name, null);
        return ctx.done("Email settings removed.", "{s}", .{"/settings/email"});
    }
    if (!is(action, "save") and !is(action, "test")) return fail(ctx, "email", "Unknown action.");
    const host = std.mem.trim(u8, try ctx.field("host"), " ");
    const port = std.fmt.parseInt(u16, std.mem.trim(u8, try ctx.field("port"), " "), 10) catch return fail(ctx, "email", "The port is a number like 587.");
    const security = std.meta.stringToEnum(mail.Security, try ctx.field("security")) orelse .starttls;
    const from = std.mem.trim(u8, try ctx.field("from"), " ");
    if (host.len == 0 or host.len > 253) return fail(ctx, "email", "Enter the SMTP server name.");
    if (!auth.validEmail(mail.addressOf(from))) return fail(ctx, "email", "The From address needs a valid email, e.g. Analytico <analytics@example.com>.");
    const password = try ctx.field("password");
    {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try data.putSetting(arena, db, .@"smtp.host", host);
        try data.putSetting(arena, db, .@"smtp.port", try std.fmt.allocPrint(arena, "{d}", .{port}));
        try data.putSetting(arena, db, .@"smtp.security", @tagName(security));
        try data.putSetting(arena, db, .@"smtp.username", std.mem.trim(u8, try ctx.field("username"), " "));
        try data.putSetting(arena, db, .@"smtp.from", from);
        if (password.len != 0) try data.putSetting(arena, db, .@"smtp.password", try secret.seal(arena, ctx.shared.io, ctx.shared.master_key, password));
    }
    if (is(action, "test")) {
        const config = try mail.load(arena, ctx.db, ctx.shared.master_key) orelse return fail(ctx, "email", "Email settings were removed meanwhile.");
        ctx.extendDeadline(45);
        mail.send(arena, ctx.shared.io, config, .{
            .to = &.{ctx.user.?.email},
            .subject = "Analytico test email",
            .text = "Email delivery works. Alerts and scheduled reports will arrive from this address.",
            .html = "<p>Email delivery works. Alerts and scheduled reports will arrive from this address.</p>",
        }) catch |err| return fail(ctx, "email", try std.fmt.allocPrint(arena, "Saved, but the test failed ({s}). Check server, port and security.", .{@errorName(err)}));
        try ctx.flash(try std.fmt.allocPrint(arena, "Saved. Test email sent to {s}.", .{ctx.user.?.email}), "", "");
    } else return ctx.done("Email settings saved.", "{s}", .{"/settings/email"});
}

// ---------------------------------------------------------------- Backups

pub fn backupDirectory(arena: std.mem.Allocator, data_dir: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ data_dir, "backups" });
}

/// Creates a verified online copy in the backups directory and records it.
pub fn backupNow(arena: std.mem.Allocator, io: std.Io, data_dir: []const u8, source: *db_mod.Db, label: []const u8, now_ms: i64) ![]const u8 {
    const directory = try backupDirectory(arena, data_dir);
    std.Io.Dir.cwd().createDirPath(io, directory) catch {};
    const date = data.civil(now_ms);
    const seconds = @divFloor(@mod(now_ms, data.day_ms), 1000);
    const name = try std.fmt.allocPrint(arena, "analytico-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}{s}{s}.db", .{ date.year, date.month, date.day, @as(u64, @intCast(@divFloor(seconds, 3600))), @as(u64, @intCast(@mod(@divFloor(seconds, 60), 60))), @as(u64, @intCast(@mod(seconds, 60))), if (label.len == 0) "" else "-", label });
    const destination = try std.fs.path.join(arena, &.{ directory, name });
    _ = try ops.copyVerified(arena, io, source, data_dir, destination);
    return destination;
}

pub const BackupFile = struct { name: []const u8, size: u64 };

pub fn listBackups(arena: std.mem.Allocator, io: std.Io, data_dir: []const u8) ![]BackupFile {
    var out: std.ArrayList(BackupFile) = .empty;
    const directory = try backupDirectory(arena, data_dir);
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".db")) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        try out.append(arena, .{ .name = try arena.dupe(u8, entry.name), .size = stat.size });
    }
    std.mem.sort(BackupFile, out.items, {}, struct {
        fn less(_: void, a: BackupFile, b: BackupFile) bool {
            return std.mem.order(u8, a.name, b.name) == .gt;
        }
    }.less);
    return out.items;
}

/// Keeps the newest `keep` automatic backups; manual and pre-retention copies stay.
pub fn pruneBackups(arena: std.mem.Allocator, io: std.Io, data_dir: []const u8, keep: usize) !void {
    const files = try listBackups(arena, io, data_dir);
    var automatic: usize = 0;
    const directory = try backupDirectory(arena, data_dir);
    for (files) |file| {
        if (!std.mem.endsWith(u8, file.name, "-daily.db")) continue;
        automatic += 1;
        if (automatic <= keep) continue;
        const path = try std.fs.path.join(arena, &.{ directory, file.name });
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        std.Io.Dir.cwd().deleteFile(io, try std.fmt.allocPrint(arena, "{s}.key", .{path})) catch {};
        std.Io.Dir.cwd().deleteFile(io, try std.fmt.allocPrint(arena, "{s}.replays", .{path})) catch {};
    }
}

fn backupsSection(ctx: *Ctx) !void {
    const w = ctx.w();
    const arena = ctx.arena;
    try ui.sectionHead(w, "Backups", "Verified copies of your database. Restores never overwrite current data.", "<form method=\"post\" action=\"/settings/backups/now\" data-busy=\"Backing up…\"><button class=\"btn btn-primary\">Back up now</button></form>");
    const daily = !is((try data.setting(arena, ctx.db, .@"backup.daily")) orelse "1", "0");
    const now = ctx.now();
    const next = now - @mod(now, data.day_ms) + 3 * data.hour_ms + (if (@mod(now, data.day_ms) >= 3 * data.hour_ms) data.day_ms else 0);
    try render(w,
        \\<form class="card row-between mb-16" method="post" action="/settings/backups/daily"><div><strong>Automatic daily backup</strong><div class="hint">Every day at 03:00 UTC · keeps the last 14{next}</div></div><span class="switch"><input type="checkbox" name="enabled" value="1" data-autosubmit aria-label="Automatic daily backup"{!checked}></span></form>
        \\<section class="card card-flush"><div class="table-wrap"><table class="table"><thead><tr><th>Backup</th><th class="r">Size</th><th>Status</th><th></th></tr></thead><tbody>
    , .{ .next = if (daily) try std.fmt.allocPrint(arena, " · next in {d} h", .{@divFloor(next - now + data.hour_ms - 1, data.hour_ms)}) else "", .checked = if (daily) " checked" else "" });
    const files = try listBackups(arena, ctx.shared.io, ctx.shared.data);
    for (files[0..@min(files.len, 30)]) |file| try render(w,
        \\<tr><td class="strong mono t-13">{name}</td><td class="r secondary">{megabytes:.1} MB</td><td><span class="pill pill-good">✓ Verified</span></td><td class="r"><button class="link" type="button" data-dialog="restore-dialog" data-restore="{name}">Restore…</button></td></tr>
    , .{ .name = file.name, .megabytes = @as(f64, @floatFromInt(file.size)) / 1_048_576.0 });
    try w.writeAll("</tbody></table></div>");
    if (files.len == 0) try ui.empty(w, "No backups yet", "Back up now, or keep automatic daily backups on. Each copy is integrity-checked before it’s listed.", "");
    try render(w,
        \\</section><dialog class="dialog dialog-wide" id="restore-dialog"><div class="dialog-head"><div><h2>Restore a backup</h2><p>Restoring creates a fresh data directory, so your current data stays untouched until you switch.</p></div><button class="btn btn-quiet btn-icon close" type="button" data-close aria-label="Close">×</button></div>
        \\<div class="dialog-body"><ol class="stack steps-list"><li>Restore into a new directory (works while Analytico runs):<div class="code mt-8"><span data-restore-command>analytico restore {directory}/<b data-restore-name>backup.db</b> {data}-restored</span></div></li>
        \\<li>Stop the service, point it at the new directory (or swap the directories), and start it again. Collection pauses for a few seconds.</li></ol>
        \\<p class="hint">The backup’s <code>.key</code> companion is copied automatically — it holds the visitor pseudonym key.</p></div><div class="dialog-foot"><button class="btn" type="button" data-close>Done</button></div></dialog>
    , .{ .directory = try backupDirectory(arena, ctx.shared.data), .data = ctx.shared.data });
}

fn backupPost(ctx: *Ctx, action: []const u8) !void {
    const arena = ctx.arena;
    if (is(action, "daily")) {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        const enabled = (try ctx.field("enabled")).len != 0;
        try data.putSetting(arena, db, .@"backup.daily", if (enabled) "1" else "0");
        return ctx.done(if (enabled) "Daily backups on." else "Daily backups off.", "{s}", .{"/settings/backups"});
    }
    if (!is(action, "now")) return fail(ctx, "backups", "Unknown action.");
    ctx.extendDeadline(300);
    const path = backupNow(arena, ctx.shared.io, ctx.shared.data, ctx.db, "manual", ctx.now()) catch |err| return fail(ctx, "backups", try std.fmt.allocPrint(arena, "Backup failed: {s}.", .{@errorName(err)}));
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    try data.putSetting(arena, db, .@"backup.last_at", try std.fmt.allocPrint(arena, "{d}", .{ctx.now()}));
    return ctx.done(try std.fmt.allocPrint(arena, "Backup verified: {s}", .{std.fs.path.basename(path)}), "{s}", .{"/settings/backups"});
}

// ---------------------------------------------------------------- Retention

pub fn prune(arena: std.mem.Allocator, db: *db_mod.Db, cutoff_ms: i64) !usize {
    return @import("../store.zig").pruneBefore(arena, db, cutoff_ms);
}

const retention_options = [_]struct { []const u8, []const u8 }{ .{ "90", "3 months" }, .{ "180", "6 months" }, .{ "365", "12 months" }, .{ "730", "24 months" }, .{ "", "Forever" } };

fn retentionSection(ctx: *Ctx) !void {
    const w = ctx.w();
    const arena = ctx.arena;
    try ui.sectionHead(w, "Data retention", "How long detailed records are kept. Older ones are deleted after a verified backup.", "");
    const current = (try data.setting(arena, ctx.db, .@"retention.days")) orelse "";
    const chosen = ctx.param("keep") orelse current;
    var current_label: []const u8 = "Forever";
    for (retention_options) |option| if (is(option[0], current)) {
        current_label = option[1];
    };
    try w.writeAll("<section class=\"card\"><div class=\"field mb-10\">Keep detailed records for</div><div class=\"row\"><nav class=\"seg\">");
    for (retention_options) |option| try render(w, "<a href=\"/settings/retention?keep={keep}\"{!current}>{label}</a>", .{
        .keep = if (option[0].len == 0) "forever" else option[0],
        .current = if (is(option[0], chosen) or (option[0].len == 0 and is(chosen, "forever"))) " aria-current=\"true\"" else "",
        .label = option[1],
    });
    try render(w, "</nav><span class=\"hint\">Currently: {label}</span></div>", .{ .label = current_label });
    const days = std.fmt.parseInt(i64, chosen, 10) catch 0;
    if (days > 0 and !is(chosen, current)) {
        const cutoff = ctx.now() - days * data.day_ms;
        const affected = try ctx.db.scalar(arena, i64, "SELECT (SELECT count(*) FROM page_views WHERE received_at_ms<?1)+(SELECT count(*) FROM events WHERE received_at_ms<?1)", .{cutoff});
        const date = data.civil(cutoff);
        try render(w,
            \\<div class="callout callout-warn callout-block mt-16"><strong>This removes {affected} records received before {day} {month} {year}</strong><div class="stack-s mt-8">
        , .{ .affected = html.int(affected), .day = date.day, .month = data.month_names[date.month - 1], .year = date.year });
        for ([_][]const u8{ "A verified backup is created first", "Older records are then deleted; nightly runs keep it that way", "Collection keeps running the whole time" }) |line| {
            try w.writeAll("<div class=\"row nowrap\">");
            try icon(w, "check");
            try render(w, "<span>{line}</span></div>", .{ .line = line });
        }
        try render(w,
            \\</div></div><form method="post" action="/settings/retention" class="row mt-16" data-busy="Backing up…"><input type="hidden" name="days" value="{days}"><button class="btn btn-primary">Back up and apply</button><a class="btn btn-quiet" href="/settings/retention">Keep “{label}”</a></form>
        , .{ .days = days, .label = current_label });
    } else if (is(chosen, "forever") and current.len != 0) {
        try w.writeAll("<form method=\"post\" action=\"/settings/retention\" class=\"row mt-16\"><input type=\"hidden\" name=\"days\" value=\"0\"><button class=\"btn btn-primary\">Keep everything from now on</button></form>");
    }
    try w.writeAll("</section>");
}

fn retentionPost(ctx: *Ctx) !void {
    const arena = ctx.arena;
    const days = std.fmt.parseInt(i64, try ctx.field("days"), 10) catch 0;
    if (days == 0) {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try data.putSetting(arena, db, .@"retention.days", null);
        return ctx.done("Keeping everything.", "{s}", .{"/settings/retention"});
    }
    if (days < 30 or days > 3650) return fail(ctx, "retention", "Pick one of the options.");
    ctx.extendDeadline(600);
    const path = backupNow(arena, ctx.shared.io, ctx.shared.data, ctx.db, "pre-retention", ctx.now()) catch |err| return fail(ctx, "retention", try std.fmt.allocPrint(arena, "Nothing deleted: the backup failed ({s}).", .{@errorName(err)}));
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    const removed = try prune(arena, db, ctx.now() - days * data.day_ms);
    try data.putSetting(arena, db, .@"retention.days", try std.fmt.allocPrint(arena, "{d}", .{days}));
    try data.putSetting(arena, db, .@"backup.last_at", try std.fmt.allocPrint(arena, "{d}", .{ctx.now()}));
    return ctx.done(try std.fmt.allocPrint(arena, "Removed {d} old rows after backup {s}.", .{ removed, std.fs.path.basename(path) }), "{s}", .{"/settings/retention"});
}

// ---------------------------------------------------------------- Diagnostics

fn diagnosticsSection(ctx: *Ctx) !void {
    const w = ctx.w();
    const arena = ctx.arena;
    const db = ctx.db;
    try ui.sectionHead(w, "Diagnostics", "What to include when something looks wrong. Nothing here identifies visitors.", "");
    const page_count = try db.scalar(arena, i64, "PRAGMA page_count", .{});
    const page_size = try db.scalar(arena, i64, "PRAGMA page_size", .{});
    try render(w,
        \\<section class="card"><dl class="kv"><dt>Version</dt><dd>{version}</dd><dt>Schema</dt><dd>v{schema}</dd><dt>SQLite</dt><dd>{sqlite}</dd><dt>Database size</dt><dd>{megabytes:.1} MB</dd><dt>Data directory</dt><dd class="mono">{directory}</dd><dt>Request workers</dt><dd>{workers}</dd><dt>Page views stored</dt><dd>{views}</dd><dt>Events stored</dt><dd>{events}</dd></dl></section>
        \\<h3 class="section-title">Collector counters<span class="note">Since the database was created</span></h3><section class="card"><dl class="kv">
    , .{
        .version = @import("../cli.zig").version,
        .schema = schema.current_version,
        .sqlite = std.mem.span(db_mod.sqlite.sqlite3_libversion()),
        .megabytes = @as(f64, @floatFromInt(page_count * page_size)) / 1_048_576.0,
        .directory = ctx.shared.data,
        .workers = server.worker_count,
        .views = html.int(try db.scalar(arena, i64, "SELECT count(*) FROM page_views", .{})),
        .events = html.int(try db.scalar(arena, i64, "SELECT count(*) FROM events", .{})),
    });
    const Count = struct { name: []const u8, value: i64 };
    const counters = try db.all(arena, Count, "SELECT name,value FROM ingest_counters ORDER BY name", .{});
    for (counters) |row| try render(w, "<dt>{name}</dt><dd>{value}</dd>", .{ .name = row.name, .value = html.int(row.value) });
    try w.writeAll("</dl>");
    if (counters.len == 0) try w.writeAll("<p class=\"hint\">No rejected requests recorded.</p>");
    try w.writeAll("</section><h3 class=\"section-title\">Tracker versions<span class=\"note\">Last 7 days</span></h3><section class=\"card\"><dl class=\"kv\">");
    for (try db.all(arena, Count, "SELECT tracker_version,count(*) FROM page_views WHERE received_at_ms>=? GROUP BY 1 ORDER BY 2 DESC", .{ctx.now() - 7 * data.day_ms})) |row| try render(w, "<dt class=\"mono\">{name}</dt><dd>{value}</dd>", .{ .name = row.name, .value = html.int(row.value) });
    try w.writeAll("</dl></section>");
}

// ---------------------------------------------------------------- AI

fn aiSection(ctx: *Ctx, site: ?data.Site) !void {
    const w = ctx.w();
    const arena = ctx.arena;
    const db = ctx.db;
    const slug = if (site) |value| value.slug else "";
    try ui.sectionHead(w, "AI", "Ask questions in plain language, get “why did this happen?” answers and written summaries. Optional — everything works without it.", "");
    try @import("chatgpt.zig").card(ctx);
    if (!ctx.can(.admin)) return;
    const config = try ai.load(arena, db, ctx.shared.master_key);
    try w.writeAll("<h3 class=\"section-title\">For the whole team</h3>");
    // Connected apps (MCP clients with live refresh tokens).
    const Connection = struct { name: []const u8, last: i64, week: i64 };
    const connections = try db.all(arena, Connection, "SELECT c.name,max(coalesce(g.last_used_at_ms,g.created_at_ms)),(SELECT count(*) FROM ai_log l WHERE l.origin=c.name AND l.at_ms>=?) FROM oauth_grants g JOIN oauth_clients c ON c.client_id=g.client_id WHERE g.kind='refresh' AND g.expires_at_ms>? GROUP BY c.name", .{ ctx.now() - 7 * data.day_ms, ctx.now() });
    const providers = [_]struct { []const u8, []const u8, []const u8, []const u8, ai.Provider, []const u8 }{
        .{ "Claude", "by Anthropic", "#C96442", "C", .anthropic, "claude" },
        .{ "ChatGPT", "by OpenAI", "#000", "", .openai, "chatgpt" },
    };
    try w.writeAll("<div class=\"grid grid-2\">");
    for (providers) |provider| {
        try render(w,
            \\<section class="card provider-card"><div class="row provider-title"><span class="mark" style="background:{color}">{letter}
        , .{ .color = provider[2], .letter = provider[3] });
        if (provider[4] == .openai) try icon(w, "chatgpt");
        try render(w,
            \\</span><div><strong class="t-15">{name}</strong><div class="hint">{by}</div></div></div><div class="provider">
        , .{ .name = provider[0], .by = provider[1] });
        var connected: ?Connection = null;
        for (connections) |item| if (std.ascii.findIgnoreCase(item.name, provider[5]) != null or (provider[4] == .openai and std.ascii.findIgnoreCase(item.name, "openai") != null)) {
            connected = item;
        };
        if (connected) |item| {
            try w.writeAll("<div class=\"provider-row connected\">");
            try icon(w, "plug");
            try render(w,
                \\<div><strong>{name} subscription</strong><small><span class="good">●</span> Last question {last} · {week} this week</small></div><form method="post" action="/settings/ai/disconnect"><input type="hidden" name="client" value="{client}"><input type="hidden" name="site" value="{slug}"><button class="btn">Disconnect</button></form></div>
            , .{ .name = provider[0], .last = data.ago(item.last, ctx.now()), .week = item.week, .client = item.name, .slug = slug });
        } else {
            try w.writeAll("<div class=\"provider-row recommended\">");
            try icon(w, "plug");
            try render(w,
                \\<div><strong>Use Analytico inside {name}</strong><small>Ask from {name} itself · no extra cost</small></div><button class="btn btn-primary" type="button" data-dialog="connect-dialog" data-connect="{name}">Connect</button></div>
            , .{ .name = provider[0] });
        }
        const vendor = if (provider[4] == .anthropic) "Anthropic" else "OpenAI";
        try w.writeAll("<div class=\"provider-row\">");
        try icon(w, "key");
        if (config != null and config.?.provider == provider[4]) {
            const spent = try ai.monthSpentMicro(arena, db, ctx.now());
            const budget = config.?.budget_cents;
            try render(w,
                \\<div><strong>{vendor} API key <span class="mono regular">{hint}</span></strong><small>{model} · ≈${spent:.2} of ${budget} this month</small><div class="meter-line"><div style="width:{used:.0}%"></div></div></div><a class="btn" href="/settings/ai?site={slug}&amp;key={provider}">Edit</a></div>
            , .{
                .vendor = vendor,
                .hint = try secret.hint(arena, config.?.key),
                .model = ai.modelLabel(config.?.model),
                .spent = @as(f64, @floatFromInt(spent)) / 1_000_000,
                .budget = @divFloor(budget, 100),
                .used = if (budget == 0) 0 else @min(100, @as(f64, @floatFromInt(spent)) / @as(f64, @floatFromInt(budget * 10_000)) * 100),
                .slug = slug,
                .provider = provider[4],
            });
        } else try render(w,
            \\<div><strong>Use an {vendor} API key</strong><small>Powers the AI features inside Analytico</small></div><a class="btn" href="/settings/ai?site={slug}&amp;key={provider}">Add key</a></div>
        , .{ .vendor = vendor, .slug = slug, .provider = provider[4] });
        try w.writeAll("</div></section>");
    }
    try w.writeAll("</div><section class=\"card row-between mt-16\"><div class=\"row nowrap\">");
    try icon(w, "plug");
    const compatible = config != null and config.?.provider == .compatible;
    try render(w,
        \\<div><strong class="t-13">{title}</strong><div class="hint">{detail}</div></div></div><a class="btn" href="/settings/ai?site={slug}&amp;key=compatible">{action}</a></section>
    , .{
        .title = if (compatible) try std.fmt.allocPrint(arena, "OpenAI-compatible endpoint · {s}", .{config.?.model}) else "Any OpenAI-compatible endpoint",
        .detail = if (compatible) config.?.base_url else "Ollama, LM Studio, OpenRouter, vLLM — run a local model and keep every byte on your server.",
        .slug = slug,
        .action = if (compatible) "Edit" else "Add endpoint",
    });
    if (config != null) try render(w,
        \\<form class="mt-8" method="post" action="/settings/ai/remove-key" data-confirm="Remove the API key? AI features pause until you add one."><input type="hidden" name="site" value="{slug}"><button class="btn btn-quiet">Remove API key</button></form>
    , .{ .slug = slug });
    try render(w,
        \\<h3 class="section-title">What the AI can see<a class="link ml-auto" href="/settings/ai/preview?site={slug}">Preview exactly what’s sent →</a></h3><form class="card card-flush" method="post" action="/settings/ai/sharing"><input type="hidden" name="site" value="{slug}">
        \\<div class="list-row list-row-2"><div><strong>Aggregated numbers</strong><small>Counts, rates and trends — the basis of every answer</small></div><span class="pill pill-good">Always</span></div>
        \\<div class="list-row list-row-2"><div><strong>Page paths</strong><small>So answers can name your pages</small></div><span class="switch"><input type="checkbox" name="paths" value="1" data-autosubmit aria-label="Share page paths"{!paths}></span></div>
        \\<div class="list-row list-row-2"><div><strong>Referrers and campaign names</strong><small>So answers can explain where traffic came from</small></div><span class="switch"><input type="checkbox" name="sources" value="1" data-autosubmit aria-label="Share referrers"{!sources}></span></div>
        \\<div class="list-row list-row-2"><div><strong>IP addresses, session IDs, raw events</strong><small>Never leave your instance — Analytico doesn’t even store IPs</small></div><span class="pill pill-plain">Never</span></div></form>
        \\<h3 class="section-title">Recent AI activity</h3><section class="card card-flush"><div class="table-wrap"><table class="table"><thead><tr><th>When</th><th>Where</th><th>Question</th><th class="hide-m">Data used</th><th class="r">Cost</th></tr></thead><tbody>
    , .{ .slug = slug, .paths = if (try ai.sharePaths(arena, db)) " checked" else "", .sources = if (try ai.shareSources(arena, db)) " checked" else "" });
    const Entry = struct { id: i64, at: i64, origin: []const u8, question: []const u8, used: []const u8, cost: i64, model: []const u8 };
    const entries = try db.all(arena, Entry, "SELECT id,at_ms,origin,question,data_used,cost_micro,model FROM ai_log ORDER BY at_ms DESC LIMIT 12", .{});
    for (entries) |entry| {
        // Tool calls from a connected app run on that app's plan.
        const app = is(entry.model, "your plan");
        try render(w,
            \\<tr data-href="/settings/ai/log/{id}?site={slug}"><td class="secondary">{when}</td><td class="strong"><span style="color:{color}">●</span> {origin}</td><td class="wrap cell-wide">{question}</td><td class="secondary hide-m">{used}</td><td class="r">
        , .{
            .id = entry.id,
            .slug = slug,
            .when = data.clock(entry.at, ctx.now()),
            .color = if (app) "#C96442" else "#0057AE",
            .origin = if (app) try std.fmt.allocPrint(arena, "{s} app", .{entry.origin}) else entry.origin,
            .question = entry.question[0..@min(entry.question.len, 120)],
            .used = entry.used,
        });
        if (app or std.mem.endsWith(u8, entry.model, "ChatGPT plan")) {
            try w.writeAll("<span class=\"secondary\">plan</span>");
        } else if (entry.cost > 0) try render(w, "≈${cost:.3}", .{ .cost = @as(f64, @floatFromInt(entry.cost)) / 1_000_000 }) else try w.writeAll("<span class=\"secondary\">—</span>");
        try w.writeAll("</td></tr>");
    }
    try w.writeAll("</tbody></table></div>");
    if (entries.len == 0) try w.writeAll("<p class=\"hint card-pad\">No AI activity yet. Every question asked — here or from a connected app — is listed with what was sent.</p>");
    try w.writeAll("</section>");
    try connectDialog(ctx);
    if (ctx.param("key")) |which| try keyDialog(ctx, keyProvider(which), config, slug, ctx.param("error") orelse "");
}

fn connectDialog(ctx: *Ctx) !void {
    try render(ctx.w(),
        \\<dialog class="dialog dialog-wide" id="connect-dialog" data-connect-status="/settings/ai/status.json"><div class="dialog-head"><span class="mark" style="background:#C96442" data-connect-mark>C</span><div><h2>Use Analytico inside <span data-connect-name>Claude</span></h2><p>Read-only. Runs on your <span data-connect-name>Claude</span> plan. Disconnect any time.</p></div><button class="btn btn-quiet btn-icon close" type="button" data-close aria-label="Close">×</button></div>
        \\<div class="dialog-body"><div class="steps steps-loose"><div class="step"><span class="step-num">1</span><div><h3>Copy your connector URL</h3><div class="row nowrap"><input class="input mono" value="{url}" readonly><button class="btn" type="button" data-copy="{url}">Copy</button></div></div></div>
        \\<div class="step"><span class="step-num">2</span><div><h3>Add it in <span data-connect-name>Claude</span></h3><p class="hint step-help" data-connect-help>Settings → Connectors → Add custom connector, then paste the URL.</p><a class="btn" href="https://claude.ai/settings/connectors" target="_blank" rel="noopener" data-connect-open>Open <span data-connect-name>Claude</span> ↗</a></div></div>
        \\<div class="step"><span class="step-num">3</span><div><h3>Approve access when <span data-connect-name>Claude</span> asks</h3><div class="listening" data-connect-waiting><span class="pulse"></span><div><strong data-connect-title>Waiting for <span data-connect-name>Claude</span> to connect…</strong><div class="hint">This updates by itself — no need to come back and click.</div></div></div></div></div></div></div>
        \\<div class="dialog-foot start"><span class="hint">You choose which websites it can read when you approve. It sees the same aggregates as “What the AI can see”.</span></div></dialog>
    , .{ .url = try std.fmt.allocPrint(ctx.arena, "{s}/mcp", .{try ctx.publicOrigin()}) });
}

/// What was typed into the key dialog, when a failed check re-renders it.
fn posted(ctx: *Ctx, name: []const u8) ?[]const u8 {
    if (ctx.method != .POST) return null;
    return (ctx.form() catch return null).get(name);
}

fn keyDialog(ctx: *Ctx, provider: ai.Provider, config: ?ai.Config, slug: []const u8, problem: []const u8) !void {
    const w = ctx.w();
    const active = config != null and config.?.provider == provider;
    const model = posted(ctx, "model") orelse if (active) config.?.model else if (provider == .anthropic) "claude-sonnet-5-5" else "";
    try render(w,
        \\<dialog class="dialog" id="key-dialog" data-open data-close-href="/settings/ai?site={slug}"><form method="post" action="/settings/ai/key" data-busy="Checking the key…"><input type="hidden" name="site" value="{slug}"><input type="hidden" name="provider" value="{provider}"><div class="dialog-head"><div><h2>{title}</h2><p>Stored encrypted on this server. You’re billed by the provider directly.</p></div><a class="btn btn-quiet btn-icon close" href="/settings/ai?site={slug}" data-close aria-label="Close">×</a></div><div class="dialog-body"><nav class="seg seg-fill">
    , .{ .slug = slug, .provider = provider, .title = if (provider == .compatible) "Add an endpoint" else "Add an API key" });
    for ([_]struct { ai.Provider, []const u8 }{ .{ .anthropic, "Anthropic" }, .{ .openai, "OpenAI" }, .{ .compatible, "OpenAI-compatible" } }) |option| try render(w,
        \\<a href="/settings/ai?site={slug}&amp;key={provider}"{!current}>{label}</a>
    , .{ .slug = slug, .provider = option[0], .current = if (option[0] == provider) " aria-current=\"true\"" else "", .label = option[1] });
    try w.writeAll("</nav>");
    if (problem.len != 0) {
        try w.writeAll("<div class=\"callout callout-bad\">");
        try icon(w, "alert");
        try render(w, "<span>{problem}</span></div>", .{ .problem = problem });
    }
    if (provider == .compatible) try render(w,
        \\<label class="field">Base URL<input class="input mono" name="base_url" value="{url}" placeholder="http://127.0.0.1:11434/v1" required><small>The part before /chat/completions.</small></label>
    , .{ .url = posted(ctx, "base_url") orelse if (active) config.?.base_url else "" });
    try render(w,
        \\<label class="field">API key{optional}<input class="input mono" name="key" type="password" autocomplete="off" value="{key}" placeholder="{placeholder}"{!required}></label>
    , .{
        .optional = if (provider == .compatible) " (optional)" else "",
        .key = posted(ctx, "key") orelse "",
        .placeholder = if (active) "Saved — leave empty to keep" else if (provider == .anthropic) "sk-ant-…" else "sk-…",
        .required = if (provider != .compatible and !active) " required" else "",
    });
    if (provider == .anthropic) {
        try w.writeAll("<label class=\"field\">Model<select class=\"input\" name=\"model\">");
        for (ai.anthropic_models, 0..) |entry, index| try render(w, "<option value=\"{value}\"{!selected}>{label}{note}</option>", .{ .value = entry[0], .selected = if (is(entry[0], model)) " selected" else "", .label = entry[1], .note = if (index == 0) " — recommended" else "" });
        try w.writeAll("</select><small>Sonnet is fast and accurate for analytics questions; Haiku is cheaper.</small></label>");
    } else try render(w,
        \\<label class="field">Model<input class="input mono" name="model" value="{model}" required placeholder="{placeholder}"></label>
    , .{ .model = model, .placeholder = if (provider == .openai) "gpt-5-mini" else "llama3.1" });
    try render(w,
        \\<label class="field">Monthly limit<div class="row nowrap"><span class="secondary">$</span><input class="input input-xs" name="budget" inputmode="numeric" value="{budget}"><span class="hint">At the limit, AI pauses — analytics keep working. 0 = no limit.</span></div></label>
        \\</div><div class="dialog-foot"><a class="btn" href="/settings/ai?site={slug}" data-close>Cancel</a><button class="btn btn-primary">Check and save</button></div></form></dialog>
    , .{ .budget = posted(ctx, "budget") orelse try std.fmt.allocPrint(ctx.arena, "{d}", .{if (active) @divFloor(config.?.budget_cents, 100) else 10}), .slug = slug });
}

fn aiPost(ctx: *Ctx, action: []const u8) !void {
    const arena = ctx.arena;
    const slug = try ctx.field("site");
    const back = try std.fmt.allocPrint(arena, "/settings/ai?site={f}", .{html.url(slug)});
    if (is(action, "sharing")) {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try data.putSetting(arena, db, .@"ai.share_paths", if ((try ctx.field("paths")).len != 0) "1" else "0");
        try data.putSetting(arena, db, .@"ai.share_sources", if ((try ctx.field("sources")).len != 0) "1" else "0");
        return ctx.done("Saved. Answers and connected apps use the new setting right away.", "{s}", .{back});
    }
    if (is(action, "disconnect")) {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try db.run(arena, "DELETE FROM oauth_grants WHERE client_id IN (SELECT client_id FROM oauth_clients WHERE name=?)", .{try ctx.field("client")});
        return ctx.done("Disconnected. The app can no longer read your analytics.", "{s}", .{back});
    }
    if (is(action, "remove-key")) {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        inline for (.{ .@"ai.provider", .@"ai.key", .@"ai.model", .@"ai.base_url" }) |name| try data.putSetting(arena, db, name, null);
        return ctx.done("API key removed.", "{s}", .{back});
    }
    if (!is(action, "key")) return fail(ctx, "ai", "Unknown action.");
    const provider = keyProvider(try ctx.field("provider"));
    const existing = try ai.load(arena, ctx.db, ctx.shared.master_key);
    var key = std.mem.trim(u8, try ctx.field("key"), " ");
    if (key.len == 0 and existing != null and existing.?.provider == provider) key = existing.?.key;
    const model = std.mem.trim(u8, try ctx.field("model"), " ");
    const base_url = std.mem.trimEnd(u8, std.mem.trim(u8, try ctx.field("base_url"), " "), "/");
    const budget = std.fmt.parseInt(i64, std.mem.trim(u8, try ctx.field("budget"), " $"), 10) catch 10;
    const retry = struct {
        // Re-render in place so nothing typed is lost (the key stays out of URLs).
        fn go(c: *Ctx, s: []const u8, p: ai.Provider, message: []const u8) !void {
            c.query = try html.Params.parse(c.arena, try std.fmt.allocPrint(c.arena, "site={f}&key={s}&error={f}", .{ html.url(s), @tagName(p), html.url(message) }));
            c.status = .unprocessable_entity;
            return page(c, "ai", "");
        }
    };
    if (provider != .compatible and key.len < 10) return retry.go(ctx, slug, provider, "Paste the API key from your provider’s console.");
    if (model.len == 0 or model.len > 100) return retry.go(ctx, slug, provider, "Choose a model.");
    if (provider == .compatible and !(std.mem.startsWith(u8, base_url, "http://") or std.mem.startsWith(u8, base_url, "https://"))) return retry.go(ctx, slug, provider, "The base URL starts with http:// or https://.");
    const config: ai.Config = .{ .provider = provider, .model = model, .base_url = base_url, .key = key, .budget_cents = std.math.clamp(budget, 0, 100_000) * 100, .share_paths = true, .share_sources = true };
    ctx.extendDeadline(60);
    const reply = ai.call(arena, ctx.shared.io, config, "Reply with the single word OK.", "Connection check from Analytico.", 16) catch |err| return retry.go(ctx, slug, provider, ai.errorText(err));
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    try data.putSetting(arena, db, .@"ai.provider", @tagName(provider));
    try data.putSetting(arena, db, .@"ai.model", model);
    try data.putSetting(arena, db, .@"ai.base_url", if (provider == .compatible) base_url else null);
    try data.putSetting(arena, db, .@"ai.key", if (key.len == 0) null else try secret.seal(arena, ctx.shared.io, ctx.shared.master_key, key));
    try data.putSetting(arena, db, .@"ai.budget_cents", try std.fmt.allocPrint(arena, "{d}", .{config.budget_cents}));
    return ctx.done(try std.fmt.allocPrint(arena, "Works · answered in {d} ms. Press ⌘K and ask away.", .{reply.elapsed_ms}), "{s}", .{back});
}

fn aiStatus(ctx: *Ctx) !void {
    const since = std.fmt.parseInt(i64, ctx.param("since") orelse "0", 10) catch 0;
    var statement = try ctx.db.prepare(ctx.arena, "SELECT c.name FROM oauth_grants g JOIN oauth_clients c ON c.client_id=g.client_id WHERE g.kind='refresh' AND g.created_at_ms>? ORDER BY g.created_at_ms DESC LIMIT 1");
    defer statement.deinit();
    try statement.bindInt(1, since);
    const w = ctx.w();
    if (try statement.step() == .row) {
        try w.writeAll("{\"connected\":true,\"name\":");
        try std.json.Stringify.value(statement.columnText(0), .{}, w);
        try w.print(",\"now\":{d}}}", .{ctx.now()});
    } else try w.print("{{\"connected\":false,\"now\":{d}}}", .{ctx.now()});
    return ctx.json();
}

fn aiPreview(ctx: *Ctx) !void {
    const arena = ctx.arena;
    const site = try currentSite(ctx) orelse return ctx.redirect("/settings/ai");
    const view = try data.View.parse(arena, site, try html.Params.parse(arena, "range=30d"), ctx.now());
    const text = try ai.packet(arena, ctx.db, view, try ai.sharePaths(arena, ctx.db), try ai.shareSources(arena, ctx.db));
    return logPage(ctx, site, "What the AI sees", try std.fmt.allocPrint(arena, "This is the exact text sent with a question about {s} for the last 30 days. Nothing else leaves the server.", .{site.title()}), text, "");
}

fn aiLogEntry(ctx: *Ctx, id: i64) !void {
    const arena = ctx.arena;
    var statement = try ctx.db.prepare(arena, "SELECT origin,question,payload,answer,model,at_ms FROM ai_log WHERE id=?");
    defer statement.deinit();
    try statement.bindInt(1, id);
    if (try statement.step() != .row) return layout.message(ctx, .not_found, "Not found", "That AI log entry doesn’t exist.");
    const site = try currentSite(ctx) orelse return ctx.redirect("/settings/ai");
    const date = data.civil(statement.columnInt(5));
    return logPage(ctx, site, try arena.dupe(u8, statement.columnText(1)), try std.fmt.allocPrint(arena, "{s} · {s} · {d} {s} {d}", .{ statement.columnText(0), ai.modelLabel(statement.columnText(4)), date.day, data.month_names[date.month - 1], date.year }), try arena.dupe(u8, statement.columnText(2)), try arena.dupe(u8, statement.columnText(3)));
}

fn logPage(ctx: *Ctx, site: data.Site, title: []const u8, subtitle: []const u8, sent: []const u8, answer: []const u8) !void {
    const shell: layout.Shell = .{ .title = "AI", .nav = .settings, .site = site, .sites = try ctx.visibleSites() };
    try layout.begin(ctx, shell);
    const w = ctx.w();
    try layout.head(ctx, .{ .title = title, .subtitle = subtitle, .extra = try html.print(ctx.arena, "<a class=\"btn\" href=\"/settings/ai?site={slug}\">Back to AI settings</a>", .{ .slug = site.slug }) });
    try render(w, "<h3 class=\"section-title\">Sent to the model</h3><pre class=\"code flush\">{sent}</pre>", .{ .sent = sent });
    if (answer.len != 0) try render(w, "<h3 class=\"section-title\">Reply</h3><pre class=\"code flush code-plain\">{answer}</pre>", .{ .answer = answer });
    return layout.end(ctx);
}
