//! Settings → Sign-in: your own ways in, and which ways the instance allows.
const std = @import("std");
const auth = @import("auth.zig");
const ctx_mod = @import("ctx.zig");
const data = @import("data.zig");
const db_mod = @import("../db.zig");
const html = @import("html.zig");
const layout = @import("layout.zig");
const ui = @import("ui.zig");
const oidc = @import("oidc.zig");
const secret = @import("secret.zig");
const signin = @import("signin.zig");

const Ctx = ctx_mod.Ctx;
const Method = signin.Method;
const icon = layout.icon;
const render = html.render;

fn fail(ctx: *Ctx, text: []const u8) !void {
    return ctx.done(try std.fmt.allocPrint(ctx.arena, "!{s}", .{text}), "{s}", .{"/settings/signin"});
}

fn row(w: *std.Io.Writer, method: Method, title: []const u8, detail: []const u8) !void {
    try w.writeAll("<div class=\"method-row\">");
    try signin.mark(w, method);
    try render(w, "<div class=\"grow\"><strong>{title}</strong><small>{detail}</small></div><div class=\"row nowrap\">", .{ .title = title, .detail = detail });
}

fn people(arena: std.mem.Allocator, count: i64) ![]const u8 {
    return std.fmt.allocPrint(arena, "{d} {s}", .{ count, if (count == 1) "person" else "people" });
}

/// The Analytico apps signed in as you, one row per device, newest use
/// first. Signing one out deletes its tokens; the app asks to sign in again.
fn devices(ctx: *Ctx) !void {
    const w = ctx.w();
    const Device = struct { id: []const u8, name: []const u8, client: []const u8, first: i64, last: i64 };
    const rows = try ctx.db.all(ctx.arena, Device, "SELECT g.device_id,max(g.device_name),max(c.name),min(g.created_at_ms),max(coalesce(g.last_used_at_ms,g.created_at_ms)) FROM oauth_grants g JOIN oauth_clients c ON c.client_id=g.client_id WHERE g.user_id=? AND g.device_id IS NOT NULL AND g.kind='refresh' AND g.expires_at_ms>? GROUP BY g.device_id ORDER BY 5 DESC", .{ ctx.user.?.id, ctx.now() });
    if (rows.len == 0) return;
    try w.writeAll("<h3 class=\"section-title mt-32\">Signed-in apps<span class=\"note\">The Analytico app on your devices</span></h3><section class=\"card card-flush\" data-devices><div class=\"method-list\">");
    for (rows) |device| {
        try w.writeAll("<div class=\"method-row\"><span class=\"auth-mark passkey\">");
        try icon(w, "sites");
        try render(w,
            \\</span><div class="grow"><strong>{name}</strong><small>{client} · last used {last}</small></div><div class="row nowrap"><form method="post" action="/settings/signin/sign-out-device" data-confirm="Sign out {name}? The app asks to sign in again."><input type="hidden" name="device" value="{id}"><button class="btn">Sign out</button></form></div></div>
        , .{ .name = device.name, .client = device.client, .last = data.ago(device.last, ctx.now()), .id = device.id });
    }
    try w.writeAll("</div></section>");
}

pub fn section(ctx: *Ctx) !void {
    const arena = ctx.arena;
    const db = ctx.db;
    const w = ctx.w();
    const user = ctx.user.?;
    const now = ctx.now();
    try ui.sectionHead(w, "Sign-in", "How you and your team get in. Passkeys use Face ID or Touch ID — nothing to remember, nothing to leak.", "");
    const origin = try signin.pinnedOrigin(arena, db);
    if (ctx.param("linking")) |name| if (std.meta.stringToEnum(oidc.Provider, name)) |provider| try render(w,
        \\<meta http-equiv="refresh" content="0;url=/auth/{name}/start?intent=link"><div class="callout mb-16"><span>{label} is set up. Taking you there to link your account… <a class="link" href="/auth/{name}/start?intent=link">Continue</a></span></div>
    , .{ .name = provider, .label = provider.label() });
    if (origin == null) {
        try w.writeAll("<div class=\"callout callout-warn mb-16\">");
        try icon(w, "alert");
        try w.writeAll("<span>This instance doesn’t know its public address yet, so passkeys and Google/ChatGPT can’t work. Run <code>analytico user invite you@example.com --origin https://your-analytics.example</code> once on the server.</span></div>");
    }

    // ---- your methods
    try render(w, "<section class=\"card card-flush\"><div class=\"card-head method-head\"><h2>Your sign-in methods</h2><span class=\"meta\">{email}</span></div><div class=\"method-list\">", .{ .email = user.email });
    const Passkey = struct { id: i64, label: []const u8, created: i64, used: ?i64 };
    for (try db.all(arena, Passkey, "SELECT id,label,created_at_ms,last_used_at_ms FROM passkeys WHERE user_id=? ORDER BY created_at_ms", .{user.id})) |passkey| {
        const created = data.civil(passkey.created);
        const detail = if (passkey.used) |at|
            try std.fmt.allocPrint(arena, "Added {d} {s} · used {f}", .{ created.day, data.month_names[created.month - 1], data.ago(at, now) })
        else
            try std.fmt.allocPrint(arena, "Added {d} {s}", .{ created.day, data.month_names[created.month - 1] });
        try row(w, .passkey, passkey.label, detail);
        try render(w, "<button class=\"btn btn-quiet btn-icon\" type=\"button\" popovertarget=\"pk-{id}\" aria-label=\"Passkey actions\">", .{ .id = passkey.id });
        try icon(w, "more");
        try render(w,
            \\</button><div id="pk-{id}" popover class="pop pop-280" data-anchor="[popovertarget=pk-{id}]"><form method="post" action="/settings/signin/rename-passkey" class="pop-section form-grid pad-10"><input type="hidden" name="id" value="{id}"><label class="field">Name<input class="input" name="label" value="{label}" maxlength="64" required></label><button class="btn">Rename</button></form><div class="menu-sep"></div><form method="post" action="/settings/signin/remove-passkey" data-confirm="Remove this passkey? That device can no longer sign you in."><input type="hidden" name="id" value="{id}"><button class="menu-item">
        , .{ .id = passkey.id, .label = passkey.label });
        try icon(w, "trash");
        try w.writeAll("Remove passkey</button></form></div></div></div>");
    }
    var linked: [2]bool = .{ false, false };
    const Identity = struct { provider: []const u8, email: []const u8, created: i64 };
    for (try db.all(arena, Identity, "SELECT provider,email,created_at_ms FROM identities WHERE user_id=? ORDER BY provider", .{user.id})) |identity| {
        const method = std.meta.stringToEnum(Method, identity.provider) orelse continue;
        if (method == .google) linked[0] = true;
        if (method == .chatgpt) linked[1] = true;
        const title = if (identity.email.len != 0) try std.fmt.allocPrint(arena, "{s} · {s}", .{ method.label(), identity.email }) else method.label();
        const created = data.civil(identity.created);
        try row(w, method, title, try std.fmt.allocPrint(arena, "Linked {d} {s}{s}", .{ created.day, data.month_names[created.month - 1], if (try signin.enabled(arena, db, method)) "" else " · turned off for this instance" }));
        try render(w,
            \\<form method="post" action="/settings/signin/unlink" data-confirm="Unlink {label}? You can link it again any time."><input type="hidden" name="provider" value="{name}"><button class="btn">Unlink</button></form></div></div>
        , .{ .label = method.label(), .name = method });
    }
    const has_password = try signin.methodCount(arena, db, user.id, .password) != 0;
    if (has_password or try signin.enabled(arena, db, .password)) {
        try row(w, .password, "Password", if (has_password) "Set · used with your email" else "Not set — your other methods are enough");
        try render(w, "<button class=\"btn\" type=\"button\" data-dialog=\"password-dialog\">{label}</button>", .{ .label = if (has_password) "Change" else "Set a password" });
        if (has_password and try signin.userMethodCount(arena, db, user.id, .password) != 0) try w.writeAll("<form method=\"post\" action=\"/settings/signin/remove-password\" data-confirm=\"Remove your password? You’ll sign in with your other methods.\"><button class=\"btn btn-quiet\">Remove</button></form>");
        try w.writeAll("</div></div>");
    }
    try w.writeAll("</div><div class=\"card-foot on-canvas\"><div class=\"row\">");
    if (try signin.enabled(arena, db, .passkey) and origin != null) {
        try w.writeAll("<button class=\"btn btn-primary\" type=\"button\" data-passkey=\"add\">");
        try icon(w, "plus");
        try w.writeAll("Add a passkey</button>");
    }
    if (!linked[0] and try signin.enabled(arena, db, .google)) try w.writeAll("<a class=\"btn\" href=\"/auth/google/start?intent=link\">Link Google</a>");
    if (!linked[1] and try signin.enabled(arena, db, .chatgpt)) try w.writeAll("<a class=\"btn\" href=\"/auth/chatgpt/start?intent=link\">Link ChatGPT</a>");
    try render(w,
        \\</div><span class="hint">Keep at least one way in — the last one can’t be removed.</span></div><div class="callout callout-bad passkey-error" data-passkey-error hidden></div></section>
        \\<dialog class="dialog" id="password-dialog"><form method="post" action="/settings/signin/password"><div class="dialog-head"><div><h2>{title}</h2><p>Signs out your other devices.</p></div><button class="btn btn-quiet btn-icon close" type="button" data-close aria-label="Close">×</button></div>
        \\<div class="dialog-body"><input type="text" name="username" value="{email}" autocomplete="username" hidden><label class="field">New password<input class="input" type="password" name="password" autocomplete="new-password" minlength="10" required><small>At least 10 characters.</small></label></div>
        \\<div class="dialog-foot"><button class="btn" type="button" data-close>Cancel</button><button class="btn btn-primary">Save password</button></div></form></dialog>
    , .{ .title = if (has_password) "Change your password" else "Set a password", .email = user.email });
    try devices(ctx);
    try w.writeAll("<h3 class=\"section-title mt-32\">Ways to sign in for everyone<span class=\"note\">Turning one off never locks anyone out</span></h3><section class=\"card card-flush\"><div class=\"method-list\">");

    // ---- the instance
    const main = try signin.primary(arena, db);
    for (signin.all_methods) |method| {
        const is_configured = try signin.configured(arena, db, method);
        const is_enabled = try signin.enabled(arena, db, method);
        const count = switch (method) {
            .passkey => try db.scalar(arena, i64, "SELECT count(DISTINCT user_id) FROM passkeys", .{}),
            .password => try db.scalar(arena, i64, "SELECT count(*) FROM users WHERE password_hash IS NOT NULL", .{}),
            .google, .chatgpt => try db.scalar(arena, i64, "SELECT count(*) FROM identities WHERE provider=?", .{@tagName(method)}),
        };
        const detail = switch (method) {
            .passkey => try std.fmt.allocPrint(arena, "Face ID, Touch ID, Windows Hello or a security key · {s}", .{try people(arena, count)}),
            .password => try std.fmt.allocPrint(arena, "Hashed with argon2id · 10 attempts per 15 minutes · {s}", .{try people(arena, count)}),
            .google => if (is_configured) try std.fmt.allocPrint(arena, "Client {s} · {s}", .{ try clientHint(arena, db, "google"), try people(arena, count) }) else "Needs an OAuth client from Google Cloud — about two minutes",
            .chatgpt => if (is_configured) try std.fmt.allocPrint(arena, "Client {s} · {s}", .{ try clientHint(arena, db, "chatgpt"), try people(arena, count) }) else "Needs a client ID from OpenAI — currently a limited trial",
        };
        try row(w, method, if (method == .passkey) "Passkeys" else method.label(), detail);
        if (main != null and main.? == method) try w.writeAll("<span class=\"pill pill-brand\">Shown first</span>");
        if (method.provider() != null) try render(w, "<a class=\"btn\" href=\"/settings/signin?provider={name}\">{action}</a>", .{ .name = method, .action = if (is_configured) "Edit" else "Set up" });
        if (is_configured) try render(w,
            \\<form method="post" action="/settings/signin/toggle" class="switch" title="{title}"><input type="hidden" name="method" value="{name}"><input type="checkbox" name="enabled" value="1" aria-label="Allow {label}" data-autosubmit{!checked}></form>
        , .{ .title = if (is_enabled) "Turn off" else "Turn on", .name = method, .label = method.label(), .checked = if (is_enabled) " checked" else "" });
        try w.writeAll("</div></div>");
    }
    try w.writeAll("</div><form class=\"card-foot on-canvas start flex-wrap\" method=\"post\" action=\"/settings/signin/primary\"><label class=\"row\"><strong class=\"t-13\">Shown first on the sign-in page</strong><select class=\"input input-l\" name=\"method\" data-autosubmit>");
    for (try signin.enabledMethods(arena, db)) |method| try render(w, "<option value=\"{name}\"{!selected}>{label}</option>", .{ .name = method, .selected = if (main != null and main.? == method) " selected" else "", .label = method.label() });
    try w.writeAll("</select></label><span class=\"hint\">Everything else sits behind “Other ways to sign in”.</span></form></section>");

    if (ctx.param("provider")) |name| if (std.meta.stringToEnum(oidc.Provider, name)) |provider| try providerDialog(ctx, provider, origin);
}

fn clientHint(arena: std.mem.Allocator, db: *db_mod.Db, provider: []const u8) ![]const u8 {
    const id = (try data.settingNamed(arena, db, try std.fmt.allocPrint(arena, "auth.{s}.client_id", .{provider}))) orelse return "";
    if (id.len <= 14) return id;
    return std.fmt.allocPrint(arena, "{s}…{s}", .{ id[0..4], id[id.len - 10 ..] });
}

fn providerDialog(ctx: *Ctx, provider: oidc.Provider, origin: ?[]const u8) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    const existing = try oidc.load(arena, ctx.db, ctx.shared.master_key, provider);
    const redirect = try std.fmt.allocPrint(arena, "{s}/auth/{s}/callback", .{ origin orelse "https://your-analytics.example", @tagName(provider) });
    try render(w, "<dialog class=\"dialog dialog-wide\" id=\"provider-dialog\" data-open data-close-href=\"/settings/signin\"><form method=\"post\" action=\"/settings/signin/provider\" data-native><input type=\"hidden\" name=\"provider\" value=\"{name}\"><div class=\"dialog-head\">", .{ .name = provider });
    try signin.mark(w, if (provider == .google) .google else .chatgpt);
    try render(w,
        \\<div><h2>Set up {label} sign-in</h2><p>{intro}</p></div><a class="btn btn-quiet btn-icon close" href="/settings/signin" data-close aria-label="Close">×</a></div><div class="dialog-body"><div class="steps steps-20">
    , .{ .label = provider.label(), .intro = if (provider == .google) "About two minutes in Google Cloud, once for the whole team." else "OpenAI issues client IDs to approved apps — it’s a limited trial today." });
    if (provider == .google) {
        try w.writeAll("<div class=\"step\"><span class=\"step-num\">1</span><div><h3>Create an OAuth client</h3><p class=\"hint step-help-6\">APIs &amp; Services → Credentials → Create credentials → OAuth client ID → Web application.</p><a class=\"btn\" href=\"https://console.cloud.google.com/apis/credentials\" target=\"_blank\" rel=\"noopener\">Open Google Cloud ↗</a></div></div>");
    } else {
        try w.writeAll("<div class=\"step\"><span class=\"step-num\">1</span><div><h3>Get a client ID from OpenAI</h3><p class=\"hint step-help-6\">Sign in with ChatGPT for websites needs an approved client (it starts with <code>oaiapp_</code>).</p><a class=\"btn\" href=\"https://developers.openai.com/siwc/website\" target=\"_blank\" rel=\"noopener\">OpenAI docs ↗</a></div></div>");
    }
    try render(w,
        \\<div class="step"><span class="step-num">2</span><div><h3>Add this redirect URI</h3><div class="row nowrap"><input class="input mono" value="{redirect}" readonly><button class="btn" type="button" data-copy="{redirect}">Copy</button></div></div></div>
        \\<div class="step"><span class="step-num">3</span><div class="form-grid gap-12"><h3 class="flush">Paste the client details</h3>
        \\<label class="field">Client ID<input class="input mono" name="client_id" value="{client_id}" required maxlength="255" autocomplete="off"></label>
        \\<label class="field">Client secret<input class="input mono" type="password" name="client_secret" autocomplete="off" placeholder="{placeholder}"{!required}></label>
        \\<details><summary class="hint">Advanced</summary><label class="field mt-8">Issuer<input class="input mono" name="issuer" value="{issuer}" required><small>Leave as is unless you know you need another OpenID provider.</small></label></details></div></div></div></div>
        \\<div class="dialog-foot"><span class="hint grow">Encrypted on this server. {label} then asks you to sign in once to link you.</span><a class="btn" href="/settings/signin" data-close>Cancel</a><button class="btn btn-primary">Save and link {label}</button></div></form></dialog>
    , .{
        .redirect = redirect,
        .client_id = if (existing) |config| config.client_id else "",
        .placeholder = if (existing != null) "Saved — leave empty to keep" else "",
        .required = if (existing != null) "" else " required",
        .issuer = if (existing) |config| config.issuer else provider.defaultIssuer(),
        .label = provider.label(),
    });
}

pub fn post(ctx: *Ctx, action: []const u8) !void {
    const arena = ctx.arena;
    const user = ctx.user.?;
    const is = struct {
        fn eq(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.eq;
    if (is(action, "provider")) return saveProvider(ctx);
    // Argon2 takes a while; never hold the write lock for it.
    var new_hash: []const u8 = "";
    if (is(action, "password")) {
        const password = try ctx.field("password");
        if (password.len < 10 or password.len > 512) return fail(ctx, "Use at least 10 characters.");
        new_hash = try auth.hashPassword(ctx, password);
    }
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    if (is(action, "sign-out-device")) {
        try db.run(arena, "DELETE FROM oauth_grants WHERE device_id=? AND user_id=?", .{ try ctx.field("device"), user.id });
        try db.run(arena, "DELETE FROM devices WHERE device_id=? AND user_id=?", .{ try ctx.field("device"), user.id });
        try ctx.flash("Signed out. The app asks to sign in again.", "", "");
    } else if (is(action, "rename-passkey")) {
        const label = std.mem.trim(u8, try ctx.field("label"), " ");
        @import("../domain.zig").validateText(label, 64, false) catch return fail(ctx, "Give the passkey a short name.");
        try db.run(arena, "UPDATE passkeys SET label=? WHERE id=? AND user_id=?", .{ label, std.fmt.parseInt(i64, try ctx.field("id"), 10) catch 0, user.id });
        try ctx.flash("Passkey renamed.", "", "");
    } else if (is(action, "remove-passkey")) {
        const id = std.fmt.parseInt(i64, try ctx.field("id"), 10) catch 0;
        const others = try signin.userMethodCount(arena, db, user.id, null);
        const counts = try signin.enabled(arena, db, .passkey);
        if (counts and others <= 1) return fail(ctx, "That’s your last way in. Add another method first.");
        try db.run(arena, "DELETE FROM passkeys WHERE id=? AND user_id=?", .{ id, user.id });
        try ctx.flash("Passkey removed.", "", "");
    } else if (is(action, "unlink")) {
        const method = std.meta.stringToEnum(Method, try ctx.field("provider")) orelse return fail(ctx, "Unknown provider.");
        if (method.provider() == null) return fail(ctx, "Unknown provider.");
        if (try signin.enabled(arena, db, method) and try signin.userMethodCount(arena, db, user.id, method) == 0) return fail(ctx, "That’s your last way in. Add another method first.");
        try db.run(arena, "DELETE FROM identities WHERE provider=? AND user_id=?", .{ @tagName(method), user.id });
        try ctx.flash(try std.fmt.allocPrint(arena, "{s} unlinked.", .{method.label()}), "", "");
    } else if (is(action, "password")) {
        try db.run(arena, "UPDATE users SET password_hash=? WHERE id=?", .{ new_hash, user.id });
        try db.run(arena, "DELETE FROM web_sessions WHERE user_id=?", .{user.id});
        try auth.startSession(ctx, db, user.id);
        try ctx.flash("Password saved. Other devices were signed out.", "", "");
    } else if (is(action, "remove-password")) {
        if (try signin.enabled(arena, db, .password) and try signin.userMethodCount(arena, db, user.id, .password) == 0) return fail(ctx, "That’s your last way in. Add another method first.");
        try db.run(arena, "UPDATE users SET password_hash=NULL WHERE id=?", .{user.id});
        try ctx.flash("Password removed.", "", "");
    } else if (is(action, "toggle")) {
        const method = std.meta.stringToEnum(Method, try ctx.field("method")) orelse return fail(ctx, "Unknown method.");
        const turn_on = (try ctx.field("enabled")).len != 0;
        if (!turn_on) {
            // Nobody may be left without an enabled way in.
            var stranded: i64 = 0;
            var users = try db.prepare(arena, "SELECT id FROM users");
            defer users.deinit();
            while (try users.step() == .row) {
                const id = users.columnInt(0);
                if (try signin.methodCount(arena, db, id, method) != 0 and try signin.userMethodCount(arena, db, id, method) == 0) stranded += 1;
            }
            if (stranded != 0) return fail(ctx, try std.fmt.allocPrint(arena, "{d} {s} only sign in with {s}. Ask them to add another method first.", .{ stranded, if (stranded == 1) "person can" else "people can", method.label() }));
        }
        try data.putSettingNamed(arena, db, try std.fmt.allocPrint(arena, "auth.enabled.{s}", .{@tagName(method)}), if (turn_on) "1" else "0");
        try ctx.flash(try std.fmt.allocPrint(arena, "{s} {s} for everyone.", .{ method.label(), if (turn_on) "turned on" else "turned off" }), "", "");
    } else if (is(action, "primary")) {
        const method = std.meta.stringToEnum(Method, try ctx.field("method")) orelse return fail(ctx, "Unknown method.");
        if (!try signin.enabled(arena, db, method)) return fail(ctx, "Turn that method on first.");
        try data.putSetting(arena, db, .@"auth.primary", @tagName(method));
        try ctx.flash(try std.fmt.allocPrint(arena, "{s} is now shown first.", .{method.label()}), "", "");
    } else return fail(ctx, "Unknown action.");
    return ctx.redirect("/settings/signin");
}

fn saveProvider(ctx: *Ctx) !void {
    const arena = ctx.arena;
    const provider = std.meta.stringToEnum(oidc.Provider, try ctx.field("provider")) orelse return fail(ctx, "Unknown provider.");
    const client_id = std.mem.trim(u8, try ctx.field("client_id"), " ");
    const client_secret = std.mem.trim(u8, try ctx.field("client_secret"), " ");
    const issuer = std.mem.trimEnd(u8, std.mem.trim(u8, try ctx.field("issuer"), " "), "/");
    const retry = try std.fmt.allocPrint(arena, "/settings/signin?provider={s}", .{@tagName(provider)});
    @import("../domain.zig").validateText(client_id, 255, false) catch {
        return ctx.done("!Paste the client ID.", "{s}", .{retry});
    };
    if (!oidc.validIssuer(issuer)) {
        return ctx.done("!The issuer must be an https:// address.", "{s}", .{retry});
    }
    const existing = try oidc.load(arena, ctx.db, ctx.shared.master_key, provider);
    if (client_secret.len == 0 and existing == null) {
        return ctx.done("!Paste the client secret.", "{s}", .{retry});
    }
    // Check the issuer answers before anyone relies on it.
    ctx.extendDeadline(30);
    _ = oidc.discover(arena, issuer) catch {
        return ctx.done("!That issuer didn’t answer with an OpenID configuration.", "{s}", .{retry});
    };
    const prefix = @tagName(provider);
    {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try data.putSettingNamed(arena, db, try std.fmt.allocPrint(arena, "auth.{s}.client_id", .{prefix}), client_id);
        if (client_secret.len != 0) try data.putSettingNamed(arena, db, try std.fmt.allocPrint(arena, "auth.{s}.secret", .{prefix}), try secret.seal(arena, ctx.shared.io, ctx.shared.master_key, client_secret));
        try data.putSettingNamed(arena, db, try std.fmt.allocPrint(arena, "auth.{s}.issuer", .{prefix}), if (std.mem.eql(u8, issuer, provider.defaultIssuer())) null else issuer);
        try data.putSettingNamed(arena, db, try std.fmt.allocPrint(arena, "auth.enabled.{s}", .{prefix}), "1");
    }
    // A form's redirects may not leave the site (CSP form-action), so the
    // hand-off to the provider starts from a page of our own.
    return ctx.redirectFmt("/settings/signin?linking={s}", .{prefix});
}
