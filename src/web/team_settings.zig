//! Settings → Team & roles, API & public links, and the audit log.
const std = @import("std");
const audit = @import("audit.zig");
const auth = @import("auth.zig");
const ctx_mod = @import("ctx.zig");
const data = @import("data.zig");
const db_mod = @import("../db.zig");
const html = @import("html.zig");
const layout = @import("layout.zig");
const ui = @import("ui.zig");
const mail = @import("mail.zig");

const Ctx = ctx_mod.Ctx;
const Role = ctx_mod.Role;
const esc = html.esc;
const icon = layout.icon;
const render = html.render;

fn fail(ctx: *Ctx, section: []const u8, text: []const u8) !void {
    return ctx.done(try std.fmt.allocPrint(ctx.arena, "!{s}", .{text}), "/settings/{s}", .{section});
}

// ---------------------------------------------------------------- Team & roles

pub fn teamSection(ctx: *Ctx, notice: []const u8) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    try ui.sectionHead(w, "Team & roles", "Who can see which websites, and who can change things.", "");
    try w.writeAll(notice);
    const sites = try data.sites(arena, ctx.db);
    try w.writeAll("<section class=\"card card-flush\"><div class=\"table-wrap\"><table class=\"table team\"><thead><tr><th>Person</th><th>Role</th><th class=\"hide-m\">Websites</th><th class=\"hide-m\">Last active</th><th></th></tr></thead><tbody>");
    const Person = struct { id: i64, email: []const u8, role: []const u8, all_sites: bool, joined: bool, active: ?i64, providers: []const u8, passkey: bool, password: bool };
    for (try ctx.db.all(arena, Person, "SELECT u.id,u.email,u.role,u.all_sites," ++ auth.joined_sql ++ ",(SELECT max(created_at_ms) FROM web_sessions s WHERE s.user_id=u.id),coalesce((SELECT group_concat(provider) FROM identities i WHERE i.user_id=u.id),''),EXISTS(SELECT 1 FROM passkeys p WHERE p.user_id=u.id),u.password_hash IS NOT NULL FROM users u ORDER BY u.role='owner' DESC,u.created_at_ms", .{})) |person| {
        const role = std.meta.stringToEnum(Role, person.role) orelse .viewer;
        const me = ctx.user.?.id == person.id;
        var methods: std.ArrayList([]const u8) = .empty;
        if (person.passkey) try methods.append(arena, "passkey");
        if (person.providers.len != 0) try methods.append(arena, person.providers);
        if (person.password) try methods.append(arena, "password");
        try render(w,
            \\<tr><td><div class="row nowrap"><span class="person-avatar">{initial}</span><div><strong>{email}</strong><small class="secondary block">{you}{status}</small></div></div></td><td>
        , .{
            .initial = &[_]u8{if (person.email.len == 0) '?' else std.ascii.toUpper(person.email[0])},
            .email = person.email,
            .you = if (me) "You · " else "",
            .status = if (!person.joined) "invited — hasn’t joined yet" else if (methods.items.len == 0) "joined" else try std.mem.join(arena, " + ", methods.items),
        });
        if (role == .owner or me or !ctx.can(.admin)) {
            try render(w, "<span class=\"pill pill-plain\">{role}</span>", .{ .role = role.label() });
        } else {
            try render(w, "<form method=\"post\" action=\"/settings/team/role/{id}\"><select class=\"input input-xs\" name=\"role\" data-autosubmit aria-label=\"Role of {email}\">", .{ .id = person.id, .email = person.email });
            for ([_]Role{ .admin, .editor, .viewer }) |option| try render(w, "<option value=\"{value}\"{!selected}>{label}</option>", .{ .value = option, .selected = if (option == role) " selected" else "", .label = option.label() });
            try w.writeAll("</select></form>");
        }
        try w.writeAll("</td><td class=\"hide-m\">");
        if (role.atLeast(.admin) or person.all_sites) {
            try w.writeAll("All websites");
        } else {
            const granted = try ctx.db.scalar(arena, ?[]const u8, "SELECT group_concat(coalesce(nullif(s.name,''),s.slug),', ') FROM user_sites us JOIN sites s ON s.id=us.site_id WHERE us.user_id=?", .{person.id});
            try render(w, "{names}", .{ .names = granted orelse "No websites yet" });
        }
        if (!role.atLeast(.admin) and !me) {
            try render(w,
                \\ <button class="link" type="button" data-dialog="sites-{id}">Change</button><dialog class="dialog" id="sites-{id}"><form method="post" action="/settings/team/sites/{id}"><div class="dialog-head"><div><h2>Websites for {email}</h2><p>They see only these, everywhere: reports, replays, the API and AI connectors.</p></div></div><div class="dialog-body"><label class="check"><input type="checkbox" name="all" value="1"{!all}>All websites, including ones added later</label>
            , .{ .id = person.id, .email = person.email, .all = if (person.all_sites) " checked" else "" });
            for (sites) |site| {
                const has = try ctx.db.scalar(arena, i64, "SELECT count(*) FROM user_sites WHERE user_id=? AND site_id=?", .{ person.id, site.id }) != 0;
                try render(w, "<label class=\"check\"><input type=\"checkbox\" name=\"site\" value=\"{id}\"{!checked}>{title}</label>", .{ .id = site.id, .checked = if (has) " checked" else "", .title = site.title() });
            }
            try w.writeAll("</div><div class=\"dialog-foot\"><button class=\"btn\" type=\"button\" data-close>Cancel</button><button class=\"btn btn-primary\">Save</button></div></form></dialog>");
        }
        try w.writeAll("</td><td class=\"hide-m secondary\">");
        if (person.active) |at| try render(w, "{ago}", .{ .ago = data.ago(at, ctx.now()) }) else try w.writeAll("—");
        try w.writeAll("</td><td class=\"r nobreak\">");
        if (ctx.can(.admin)) {
            try render(w,
                \\<form class="inline" method="post" action="/settings/team/invite"><input type="hidden" name="email" value="{email}"><button class="btn btn-quiet">{label}</button></form>
            , .{ .email = person.email, .label = if (person.joined) "Sign-in link" else "New invite link" });
            if (!me and role != .owner) {
                try render(w,
                    \\<form class="inline" method="post" action="/settings/team/remove/{id}" data-confirm="Remove {email}? They are signed out everywhere."><button class="btn btn-quiet btn-icon" aria-label="Remove">
                , .{ .id = person.id, .email = person.email });
                try icon(w, "trash");
                try w.writeAll("</button></form>");
            }
        }
        try w.writeAll("</td></tr>");
    }
    try w.writeAll("</tbody></table></div>");
    if (ctx.can(.admin)) {
        try w.writeAll("<form class=\"card-foot invite start flex-wrap\" method=\"post\" action=\"/settings/team/invite\"><input class=\"input input-email\" type=\"email\" name=\"email\" placeholder=\"name@example.com\" required><select class=\"input input-xs\" name=\"role\" aria-label=\"Role\"><option value=\"editor\" selected>Editor</option><option value=\"viewer\">Viewer</option><option value=\"admin\">Admin</option></select><select class=\"input input-l\" name=\"site\" aria-label=\"Websites\"><option value=\"\">All websites</option>");
        for (sites) |site| try render(w, "<option value=\"{id}\">Only {title}</option>", .{ .id = site.id, .title = site.title() });
        try w.writeAll("</select><button class=\"btn btn-primary\">Invite</button></form>");
    }
    try w.writeAll("</section><p class=\"hint mt-12\">Invite links work once and expire after 7 days. Viewers can also get a public link instead of an account — see Share on the overview.</p><div class=\"grid grid-4 mt-16\">");
    const roles = [_][2][]const u8{
        .{ "Owner", "Everything: instance settings, backups, sign-in methods, websites." },
        .{ "Admin", "Everything except removing the owner. Manages people, privacy and integrations." },
        .{ "Editor", "Builds dashboards, goals, funnels, alerts and notes on their websites." },
        .{ "Viewer", "Reads reports and replays on their websites. Can’t change or export people." },
    };
    for (roles) |role| try render(w, "<div class=\"card\"><strong>{name}</strong><p class=\"hint mt-6\">{help}</p></div>", .{ .name = role[0], .help = role[1] });
    try w.writeAll("</div>");
    const domain_rule = (try data.setting(arena, ctx.db, .@"auth.google.domain")) orelse "";
    if (ctx.can(.admin)) try render(w,
        \\<form class="card form-grid mt-16" method="post" action="/settings/team/domain"><div><strong>Join with your company’s Google account</strong><p class="hint mt-4">Anyone signing in with a verified Google Workspace account at this domain joins as Viewer of all websites. You can still change their role. Existing accounts are never matched by email.</p></div>
        \\<div class="row nowrap"><span class="secondary">@</span><input class="input mono input-domain" name="domain" value="{domain}" placeholder="example.com" aria-label="Google Workspace domain"><button class="btn">{action}</button></div></form>
    , .{ .domain = domain_rule, .action = if (domain_rule.len == 0) "Turn on" else "Save" });
}

/// A secret shown once after it is created: the invite link or the API key.
fn shownOnce(arena: std.mem.Allocator, title: []const u8, label: []const u8, value: []const u8, copy: []const u8, help: []const u8) ![]const u8 {
    return html.print(arena,
        \\<div class="callout callout-good callout-block mb-16"><strong>{title}</strong><div class="row nowrap mt-10"><input class="input mono on-white" value="{value}" readonly aria-label="{label}"><button class="btn" type="button" data-copy="{value}">{copy}</button></div><p class="hint mt-6">{help}</p></div>
    , .{ .title = title, .label = label, .value = value, .copy = copy, .help = help });
}

pub fn teamPost(ctx: *Ctx, action: []const u8, target: []const u8, page: anytype) !void {
    const arena = ctx.arena;
    if (!ctx.can(.admin)) return @import("app.zig").forbidden(ctx);
    if (std.mem.eql(u8, action, "domain")) {
        const value = std.mem.trim(u8, try std.ascii.allocLowerString(arena, try ctx.field("domain")), " @");
        if (value.len != 0 and (std.mem.findScalar(u8, value, '.') == null or value.len > 253 or std.mem.findAny(u8, value, " /@:") != null)) return fail(ctx, "team", "That doesn’t look like a domain.");
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try data.putSetting(arena, db, .@"auth.google.domain", if (value.len == 0) null else value);
        try audit.record(ctx, db, null, "team.domain", if (value.len == 0) "Turned off the Google domain rule" else try std.fmt.allocPrint(arena, "Anyone at @{s} joins as Viewer", .{value}));
        return ctx.done(if (value.len == 0) "Domain rule off." else "Domain rule on.", "{s}", .{"/settings/team"});
    }
    if (std.mem.eql(u8, action, "role") or std.mem.eql(u8, action, "sites") or std.mem.eql(u8, action, "remove")) {
        const id = std.fmt.parseInt(i64, target, 10) catch return fail(ctx, "team", "Unknown person.");
        if (ctx.user.?.id == id) return fail(ctx, "team", "You can’t change your own access.");
        var person = try ctx.db.prepare(arena, "SELECT email,role FROM users WHERE id=?");
        defer person.deinit();
        try person.bindInt(1, id);
        if (try person.step() != .row) return fail(ctx, "team", "Unknown person.");
        const email = try arena.dupe(u8, person.columnText(0));
        if (std.mem.eql(u8, person.columnText(1), "owner")) return fail(ctx, "team", "The owner’s access can’t be changed.");
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        if (std.mem.eql(u8, action, "remove")) {
            try db.run(arena, "DELETE FROM users WHERE id=?", .{id});
            try audit.record(ctx, db, null, "team.removed", try std.fmt.allocPrint(arena, "Removed {s}", .{email}));
            try ctx.flash("Removed from the team.", "", "");
        } else if (std.mem.eql(u8, action, "role")) {
            const role = std.meta.stringToEnum(Role, try ctx.field("role")) orelse return fail(ctx, "team", "Unknown role.");
            if (role == .owner) return fail(ctx, "team", "There is one owner.");
            try db.run(arena, "UPDATE users SET role=? WHERE id=?", .{ @tagName(role), id });
            try audit.record(ctx, db, null, "team.role", try std.fmt.allocPrint(arena, "{s} is now {s}", .{ email, role.label() }));
            try ctx.flash(try std.fmt.allocPrint(arena, "{s} is now {s}.", .{ email, role.label() }), "", "");
        } else {
            const all = (try ctx.field("all")).len != 0;
            try db.exec("BEGIN IMMEDIATE");
            errdefer db.exec("ROLLBACK") catch {};
            try db.run(arena, "UPDATE users SET all_sites=? WHERE id=?", .{ @intFromBool(all), id });
            try db.run(arena, "DELETE FROM user_sites WHERE user_id=?", .{id});
            var names: std.ArrayList(u8) = .empty;
            for (try (try ctx.form()).all(arena, "site")) |value| {
                const site_id = std.fmt.parseInt(i64, value, 10) catch continue;
                if (try db.scalar(arena, i64, "SELECT count(*) FROM sites WHERE id=?", .{site_id}) == 0) continue;
                try db.run(arena, "INSERT INTO user_sites(user_id,site_id) VALUES(?,?) ON CONFLICT DO NOTHING", .{ id, site_id });
                try names.print(arena, "{s}{d}", .{ if (names.items.len == 0) "" else ",", site_id });
            }
            try audit.record(ctx, db, null, "team.sites", try std.fmt.allocPrint(arena, "{s} sees {s}", .{ email, if (all) "all websites" else if (names.items.len == 0) "no websites" else names.items }));
            try db.exec("COMMIT");
            try ctx.flash("Access saved.", "", "");
        }
        return ctx.redirect("/settings/team");
    }
    if (!std.mem.eql(u8, action, "invite")) return fail(ctx, "team", "Unknown action.");
    const email = std.mem.trim(u8, try ctx.field("email"), " ");
    if (!auth.validEmail(email)) return fail(ctx, "team", "That doesn’t look like an email address.");
    const role = std.meta.stringToEnum(Role, try ctx.field("role")) orelse .editor;
    if (role == .owner) return fail(ctx, "team", "There is one owner.");
    const site_id: ?i64 = std.fmt.parseInt(i64, try ctx.field("site"), 10) catch null;
    const token = blk: {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try db.exec("BEGIN IMMEDIATE");
        errdefer db.exec("ROLLBACK") catch {};
        const normalized = try auth.normalizeEmail(arena, email);
        const is_new = try db.scalar(arena, i64, "SELECT count(*) FROM users WHERE email=?", .{normalized}) == 0;
        const token = try auth.createInvite(arena, ctx.shared.io, db, email, ctx.now());
        // A new invite carries a role and websites; a fresh link for an
        // existing person never changes their access.
        if (is_new) {
            try db.run(arena, "UPDATE users SET role=?,all_sites=? WHERE email=?", .{ @tagName(role), @intFromBool(site_id == null), normalized });
            if (site_id) |value| try db.run(arena, "INSERT INTO user_sites(user_id,site_id) SELECT id,? FROM users WHERE email=?", .{ value, normalized });
            try audit.record(ctx, db, site_id, "team.invited", try std.fmt.allocPrint(arena, "Invited {s} as {s}", .{ normalized, role.label() }));
        }
        try db.exec("COMMIT");
        break :blk token;
    };
    const origin = (try @import("signin.zig").pinnedOrigin(arena, ctx.db)) orelse try ctx.publicOrigin();
    const link = try std.fmt.allocPrint(arena, "{s}/invite/{s}", .{ origin, &token });
    var mailed = false;
    if (try mail.load(arena, ctx.db, ctx.shared.master_key)) |config| {
        ctx.extendDeadline(45);
        mail.send(arena, ctx.shared.io, config, .{
            .to = &.{email},
            .subject = "You’re invited to Analytico",
            .text = try std.fmt.allocPrint(arena, "{s} invited you to their Analytico instance.\n\nChoose how you’ll sign in here (the link works once and expires in 7 days):\n{s}\n", .{ ctx.user.?.email, link }),
            .html = try std.fmt.allocPrint(arena, "<p>{f} invited you to their Analytico instance.</p><p><a href=\"{f}\">Choose how you’ll sign in</a> — the link works once and expires in 7 days.</p>", .{ esc(ctx.user.?.email), esc(link) }),
        }) catch |err| std.log.warn("invite_mail_failed code={s}", .{@errorName(err)});
        mailed = true;
    }
    const title = try std.fmt.allocPrint(arena, "Invite ready for {s}{s}", .{ email, if (mailed) " — also sent by email." else "." });
    return page(ctx, "team", try shownOnce(arena, title, "Invite link", link, "Copy link", "Shown once. It works once and expires in 7 days."));
}

// ---------------------------------------------------------------- API & public links

pub fn apiSection(ctx: *Ctx, maybe_site: ?data.Site, notice: []const u8) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    try ui.sectionHead(w, "API & public links", "Read your numbers from other tools. Keys are read-only and scoped to websites.", "");
    try w.writeAll(notice);
    try w.writeAll("<div class=\"grid split-main\"><section class=\"card\"><div class=\"card-head\"><h2>API keys</h2></div><div class=\"stack-s\">");
    const Key = struct { id: i64, name: []const u8, prefix: []const u8, scope: []const u8, used: ?i64, by: []const u8 };
    const keys = try ctx.db.all(arena, Key, "SELECT k.id,k.name,k.prefix,coalesce((SELECT coalesce(nullif(s.name,''),s.slug) FROM sites s WHERE s.id=k.site_id),'All websites'),k.last_used_at_ms,u.email FROM api_keys k JOIN users u ON u.id=k.user_id ORDER BY k.created_at_ms DESC", .{});
    for (keys) |key| try render(w,
        \\<div class="key-row"><div><strong>{name}</strong><small>an_…{prefix} · {scope} · read · by {by}</small></div><span class="hint">{used}</span><form method="post" action="/settings/api/revoke" data-confirm="Revoke this key? Tools using it stop working."><input type="hidden" name="id" value="{id}"><button class="btn btn-quiet">Revoke</button></form></div>
    , .{ .name = key.name, .prefix = key.prefix, .scope = key.scope, .by = key.by, .used = if (key.used) |at| try std.fmt.allocPrint(arena, "used {f}", .{data.ago(at, ctx.now())}) else "never used", .id = key.id });
    if (keys.len == 0) try w.writeAll("<p class=\"hint\">No keys yet.</p>");
    try w.writeAll("</div><form method=\"post\" action=\"/settings/api/create\" class=\"row mt-14\"><input class=\"input input-name\" name=\"name\" required maxlength=\"60\" placeholder=\"Looker Studio\" aria-label=\"Key name\"><select class=\"input input-l\" name=\"site\" aria-label=\"Website\"><option value=\"\">All websites</option>");
    for (try ctx.visibleSites()) |site| try render(w, "<option value=\"{id}\">Only {title}</option>", .{ .id = site.id, .title = site.title() });
    try render(w,
        \\</select><button class="btn btn-primary">Create key</button></form>
        \\<div class="field example-label">Example</div><div class="code">curl {origin}/api/v1/sites/{slug}/breakdown?dimension=page&amp;range=30d \<br>&nbsp;&nbsp;-H "Authorization: Bearer an_…"</div>
        \\<p class="hint mt-8">Endpoints: <code>/api/v1/sites</code>, <code>…/overview</code>, <code>…/breakdown?dimension=page|source|campaign|device|browser|os|country&amp;format=csv</code>, <code>…/timeseries?metric=views|visitors|active</code>. Same ranges as the workspace.</p></section>
        \\<section class="card"><div class="card-head"><h2>Public links</h2></div><div class="stack-s">
    , .{ .origin = (try @import("signin.zig").pinnedOrigin(arena, ctx.db)) orelse try ctx.publicOrigin(), .slug = if (maybe_site) |site| site.slug else "your-site" });
    const Link = struct { id: i64, label: []const u8, slug: []const u8, site: []const u8, views: i64, expires: ?i64 };
    const links = try ctx.db.all(arena, Link, "SELECT l.id,l.label,s.slug,coalesce(nullif(s.name,''),s.slug),l.views,l.expires_at_ms FROM share_links l JOIN sites s ON s.id=l.site_id ORDER BY l.created_at_ms DESC LIMIT 20", .{});
    for (links) |link| try render(w,
        \\<div class="key-row"><div><strong>{label}</strong><small>{site} · opened {views}×{expired}</small></div><form method="post" action="/{slug}/shares/{id}/revoke"><button class="btn btn-quiet">Revoke</button></form></div>
    , .{ .label = link.label, .site = link.site, .views = link.views, .expired = if (link.expires != null and link.expires.? < ctx.now()) " · expired" else "", .slug = link.slug, .id = link.id });
    if (links.len == 0) try w.writeAll("<p class=\"hint\">Share a read-only view from the overview’s ••• menu.</p>");
    try w.writeAll("</div></section></div>");
}

pub fn apiPost(ctx: *Ctx, action: []const u8, page: anytype) !void {
    const arena = ctx.arena;
    if (!ctx.can(.admin)) return @import("app.zig").forbidden(ctx);
    if (std.mem.eql(u8, action, "revoke")) {
        const id = std.fmt.parseInt(i64, try ctx.field("id"), 10) catch 0;
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try db.run(arena, "DELETE FROM api_keys WHERE id=?", .{id});
        try audit.record(ctx, db, null, "api.revoked", try std.fmt.allocPrint(arena, "Revoked API key {d}", .{id}));
        return ctx.done("Key revoked.", "{s}", .{"/settings/api"});
    }
    if (!std.mem.eql(u8, action, "create")) return fail(ctx, "api", "Unknown action.");
    const name = std.mem.trim(u8, try ctx.field("name"), " ");
    @import("../domain.zig").validateText(name, 60, false) catch return fail(ctx, "api", "Give the key a name.");
    const site_id: ?i64 = std.fmt.parseInt(i64, try ctx.field("site"), 10) catch null;
    if (site_id) |id| if (!try ctx.canSee(id)) return fail(ctx, "api", "Unknown website.");
    const random = try auth.newToken(ctx.shared.io);
    const token = try std.fmt.allocPrint(arena, "an_{s}", .{&random});
    const hashed = auth.hashToken(token);
    {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        var statement = try db.prepare(arena, "INSERT INTO api_keys(name,token_hash,prefix,user_id,site_id,created_at_ms) VALUES(?,?,?,?,?,?)");
        defer statement.deinit();
        try statement.bindText(1, name);
        try statement.bindText(2, &hashed);
        try statement.bindText(3, token[token.len - 4 ..]);
        try statement.bindInt(4, ctx.user.?.id);
        try statement.bindOptionalInt(5, site_id);
        try statement.bindInt(6, ctx.now());
        _ = try statement.step();
        try audit.record(ctx, db, site_id, "api.created", try std.fmt.allocPrint(arena, "Created API key “{s}”", .{name}));
    }
    return page(ctx, "api", try shownOnce(arena, try std.fmt.allocPrint(arena, "Key “{s}” created", .{name}), "New API key", token, "Copy", "Shown once. It reads with your access."));
}

// ---------------------------------------------------------------- Audit log

pub fn auditSection(ctx: *Ctx) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    try ui.sectionHead(w, "Audit log", "Who changed what: settings, people, privacy, keys, links and exports.", "");
    try w.writeAll("<section class=\"card card-flush\"><div class=\"table-wrap\"><table class=\"table\"><thead><tr><th>When</th><th>Who</th><th>What</th><th class=\"hide-m\">Website</th></tr></thead><tbody>");
    const Entry = struct { at: i64, actor: []const u8, site: []const u8, action: []const u8, detail: []const u8 };
    const entries = try ctx.db.all(arena, Entry, "SELECT a.at_ms,a.actor,coalesce((SELECT coalesce(nullif(s.name,''),s.slug) FROM sites s WHERE s.id=a.site_id),''),a.action,a.detail FROM audit_log a ORDER BY a.at_ms DESC,a.id DESC LIMIT 200", .{});
    for (entries) |entry| try render(w,
        \\<tr><td class="secondary nobreak">{when}</td><td>{actor}</td><td class="wrap">{detail}</td><td class="hide-m secondary">{site}</td></tr>
    , .{ .when = data.clock(entry.at, ctx.now()), .actor = entry.actor, .detail = entry.detail, .site = entry.site });
    try w.writeAll("</tbody></table></div>");
    if (entries.len == 0) try ui.empty(w, "Nothing logged yet", "Changes to settings, people, privacy, keys and links show up here.", "");
    try w.writeAll("<div class=\"card-foot\"><span>Most recent 200 entries · kept with your data</span></div></section>");
}
