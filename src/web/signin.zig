//! Signing in: the instance's main method up front, the rest behind "Other
//! ways to sign in". Passkeys (WebAuthn), Google and ChatGPT (OpenID Connect)
//! and email + password. First run and invites use the same chooser.
const std = @import("std");
const assets = @import("../assets.zig");
const auth = @import("auth.zig");
const ctx_mod = @import("ctx.zig");
const data = @import("data.zig");
const db_mod = @import("../db.zig");
const html = @import("html.zig");
const layout = @import("layout.zig");
const oidc = @import("oidc.zig");
const passkeys = @import("passkeys.zig");

const Ctx = ctx_mod.Ctx;
const esc = html.esc;
const render = html.render;
const icon = layout.icon;

const challenge_ms = 5 * 60_000;
const oidc_ms = 10 * 60_000;
const oidc_cookie = "an_oidc";

// ---------------------------------------------------------------- policy

pub const Method = enum {
    passkey,
    google,
    chatgpt,
    password,

    pub fn label(self: Method) []const u8 {
        return switch (self) {
            .passkey => "Passkey",
            .google => "Google",
            .chatgpt => "ChatGPT",
            .password => "Email and password",
        };
    }

    pub fn provider(self: Method) ?oidc.Provider {
        return switch (self) {
            .google => .google,
            .chatgpt => .chatgpt,
            else => null,
        };
    }
};

pub const all_methods = [_]Method{ .passkey, .google, .chatgpt, .password };

pub fn configured(arena: std.mem.Allocator, db: *db_mod.Db, method: Method) !bool {
    const p = method.provider() orelse return true;
    return (try data.settingNamed(arena, db, try std.fmt.allocPrint(arena, "auth.{s}.client_id", .{@tagName(p)}))) != null;
}

pub fn enabled(arena: std.mem.Allocator, db: *db_mod.Db, method: Method) !bool {
    if (!try configured(arena, db, method)) return false;
    const value = (try data.settingNamed(arena, db, try std.fmt.allocPrint(arena, "auth.enabled.{s}", .{@tagName(method)}))) orelse "1";
    return !std.mem.eql(u8, value, "0");
}

pub fn enabledMethods(arena: std.mem.Allocator, db: *db_mod.Db) ![]Method {
    var out: std.ArrayList(Method) = .empty;
    for (all_methods) |method| if (try enabled(arena, db, method)) try out.append(arena, method);
    return out.items;
}

/// The method shown first; it falls back to the first enabled one.
pub fn primary(arena: std.mem.Allocator, db: *db_mod.Db) !?Method {
    const methods = try enabledMethods(arena, db);
    if (methods.len == 0) return null;
    const chosen = std.meta.stringToEnum(Method, (try data.setting(arena, db, .@"auth.primary")) orelse "passkey") orelse .passkey;
    for (methods) |method| if (method == chosen) return method;
    return methods[0];
}

/// How many enabled ways in a user has, optionally ignoring one method.
pub fn userMethodCount(arena: std.mem.Allocator, db: *db_mod.Db, user_id: i64, without: ?Method) !usize {
    var total: usize = 0;
    for (all_methods) |method| {
        if (without != null and without.? == method) continue;
        if (!try enabled(arena, db, method)) continue;
        total += @intCast(try methodCount(arena, db, user_id, method));
    }
    return total;
}

pub fn methodCount(arena: std.mem.Allocator, db: *db_mod.Db, user_id: i64, method: Method) !i64 {
    return switch (method) {
        .passkey => db.scalar(arena, i64, "SELECT count(*) FROM passkeys WHERE user_id=?", .{user_id}),
        .password => db.scalar(arena, i64, "SELECT count(*) FROM users WHERE id=? AND password_hash IS NOT NULL", .{user_id}),
        .google, .chatgpt => db.scalar(arena, i64, "SELECT count(*) FROM identities WHERE user_id=? AND provider=?", .{ user_id, @tagName(method) }),
    };
}

/// The origin passkeys and provider callbacks are bound to. It is pinned in
/// settings by the CLI, never taken from request headers.
pub fn pinnedOrigin(arena: std.mem.Allocator, db: *db_mod.Db) !?[]const u8 {
    return data.setting(arena, db, .public_origin);
}

fn rpId(origin: []const u8) []const u8 {
    const start = (std.mem.find(u8, origin, "://") orelse 0) + 3;
    const authority = origin[start..];
    return authority[0 .. std.mem.findScalar(u8, authority, ':') orelse authority.len];
}

// ---------------------------------------------------------------- shared markup

pub fn mark(w: *std.Io.Writer, method: Method) !void {
    switch (method) {
        .passkey => {
            try w.writeAll("<span class=\"auth-mark passkey\">");
            try icon(w, "scan-face");
            try w.writeAll("</span>");
        },
        .google => try w.writeAll("<span class=\"auth-mark google\"><svg viewBox=\"0 0 48 48\" aria-hidden=\"true\"><path fill=\"#EA4335\" d=\"M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z\"/><path fill=\"#4285F4\" d=\"M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z\"/><path fill=\"#FBBC05\" d=\"M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z\"/><path fill=\"#34A853\" d=\"M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z\"/></svg></span>"),
        .chatgpt => {
            try w.writeAll("<span class=\"auth-mark chatgpt\">");
            try icon(w, "chatgpt");
            try w.writeAll("</span>");
        },
        .password => {
            try w.writeAll("<span class=\"auth-mark password\">");
            try icon(w, "key-round");
            try w.writeAll("</span>");
        },
    }
}

fn host(origin: []const u8) []const u8 {
    return origin[(std.mem.find(u8, origin, "://") orelse 0) + 3 ..];
}

fn card(ctx: *Ctx, title: []const u8, subtitle: []const u8, problem: []const u8) !*std.Io.Writer {
    try layout.document(ctx, try std.fmt.allocPrint(ctx.arena, "{s} · Analytico", .{title}));
    const w = ctx.w();
    try render(w, "<main class=\"login\"><div class=\"login-card\"><div class=\"brand flush-pad\"><img src=\"{logo}\" alt=\"\"><span>Analytico</span></div><h1>{title}</h1><p class=\"secondary mb-24\">{subtitle}</p>", .{ .logo = assets.path("favicon.svg"), .title = title, .subtitle = subtitle });
    if (problem.len != 0) {
        try w.writeAll("<div class=\"callout callout-bad mb-16\">");
        try icon(w, "alert");
        try render(w, "<span>{problem}</span></div>", .{ .problem = problem });
    }
    return w;
}

fn cardEnd(ctx: *Ctx, footnote: []const u8) !void {
    try render(ctx.w(), "<p class=\"hint auth-foot\">{footnote}</p></div></main></body></html>", .{ .footnote = footnote });
    return ctx.html();
}

const Flow = union(enum) {
    login: []const u8, // next
    setup: []const u8, // token
    invite: []const u8, // token
};

fn passkeyButton(w: *std.Io.Writer, flow: Flow) !void {
    switch (flow) {
        .login => |next| try render(w, "<button class=\"btn btn-primary btn-l btn-block\" type=\"button\" data-passkey=\"login\" data-next=\"{next}\">", .{ .next = next }),
        .setup => |token| try render(w, "<button class=\"btn btn-primary btn-l btn-block\" type=\"button\" data-passkey=\"setup\" data-token=\"{token}\" data-email=\"#account-email\">", .{ .token = token }),
        .invite => |token| try render(w, "<button class=\"btn btn-primary btn-l btn-block\" type=\"button\" data-passkey=\"invite\" data-token=\"{token}\">", .{ .token = token }),
    }
    try icon(w, "scan-face");
    try render(w, "{label}</button><p class=\"hint auth-help\">{help}</p><div class=\"callout callout-bad mt-12\" data-passkey-error hidden></div><noscript><p class=\"hint\">Passkeys need JavaScript.</p></noscript>", .{
        .label = if (flow == .login) "Sign in with passkey" else "Create a passkey",
        .help = if (flow == .login) "Face ID, Touch ID or a security key" else "Recommended · Face ID or Touch ID, no password",
    });
}

fn providerHref(arena: std.mem.Allocator, method: Method, flow: Flow) ![]const u8 {
    return switch (flow) {
        .login => |next| std.fmt.allocPrint(arena, "/auth/{s}/start?intent=login&next={f}", .{ @tagName(method), html.url(next) }),
        .invite => |token| std.fmt.allocPrint(arena, "/auth/{s}/start?intent=invite&token={s}", .{ @tagName(method), token }),
        .setup => "",
    };
}

fn flowPath(arena: std.mem.Allocator, flow: Flow) ![]const u8 {
    return switch (flow) {
        .login => "/login",
        .setup => |token| std.fmt.allocPrint(arena, "/welcome/{s}", .{token}),
        .invite => |token| std.fmt.allocPrint(arena, "/invite/{s}", .{token}),
    };
}

fn passwordForm(ctx: *Ctx, flow: Flow, email: []const u8) !void {
    const w = ctx.w();
    switch (flow) {
        .login => |next| try render(w,
            \\<form method="post" action="/login" class="form-grid" data-native><input type="hidden" name="next" value="{next}">
            \\<label class="field">Email<input class="input" type="email" name="email" autocomplete="username" required autofocus></label>
            \\<label class="field">Password<input class="input" type="password" name="password" autocomplete="current-password" required></label>
            \\<button class="btn btn-primary btn-l">Sign in</button></form>
        , .{ .next = next }),
        .setup, .invite => try render(w,
            \\<form method="post" action="{action}" class="form-grid" data-native><input type="text" name="username" value="{email}" autocomplete="username" hidden>
            \\<label class="field">Password<input class="input" type="password" name="password" autocomplete="new-password" minlength="10" required autofocus><small>At least 10 characters. A passphrase works well.</small></label>
            \\<button class="btn btn-primary btn-l">{label}</button></form>
        , .{ .action = try flowPath(ctx.arena, flow), .email = email, .label = if (flow == .setup) "Create account" else "Continue" }),
    }
}

fn mainMethod(ctx: *Ctx, method: Method, flow: Flow, email: []const u8) !void {
    const w = ctx.w();
    switch (method) {
        .passkey => try passkeyButton(w, flow),
        .password => try passwordForm(ctx, flow, email),
        .google, .chatgpt => {
            try render(w, "<a class=\"btn btn-l btn-block btn-provider\" href=\"{href}\">", .{ .href = try providerHref(ctx.arena, method, flow) });
            try mark(w, method);
            try render(w, "Continue with {label}</a>", .{ .label = method.label() });
        },
    }
}

fn optionsDialog(ctx: *Ctx, flow: Flow, main: Method, methods: []const Method) !void {
    const w = ctx.w();
    var others: usize = 0;
    for (methods) |method| {
        if (method != main) others += 1;
    }
    const setup_providers = flow == .setup;
    if (others == 0 and !setup_providers) return;
    try w.writeAll("<button class=\"btn btn-block auth-other\" type=\"button\" data-dialog=\"other-ways\">Other ways to sign in</button>");
    try w.writeAll("<dialog class=\"dialog dialog-narrow\" id=\"other-ways\"><div class=\"dialog-head\"><div><h2>Other ways to sign in</h2></div><button class=\"btn btn-quiet btn-icon close\" type=\"button\" data-close aria-label=\"Close\">");
    try icon(w, "x");
    try w.writeAll("</button></div><div class=\"dialog-body gap-8\">");
    const path = try flowPath(ctx.arena, flow);
    for (all_methods) |method| {
        if (method == main) continue;
        const is_enabled = for (methods) |candidate| {
            if (candidate == method) break true;
        } else false;
        const provider_at_setup = setup_providers and method.provider() != null;
        if (!is_enabled and !provider_at_setup) continue;
        if (provider_at_setup) {
            try w.writeAll("<div class=\"auth-row disabled\">");
        } else {
            const href = switch (method) {
                .password, .passkey => try std.fmt.allocPrint(ctx.arena, "{s}?method={s}{s}", .{ path, @tagName(method), switch (flow) {
                    .login => |next| if (std.mem.eql(u8, next, "/")) "" else try std.fmt.allocPrint(ctx.arena, "&next={f}", .{html.url(next)}),
                    else => "",
                } }),
                .google, .chatgpt => try providerHref(ctx.arena, method, flow),
            };
            try render(w, "<a class=\"auth-row\" href=\"{href}\">", .{ .href = href });
        }
        try mark(w, method);
        const title = switch (method) {
            .passkey => if (flow == .login) "Sign in with passkey" else "Create a passkey",
            .password => if (flow == .login) "Email and password" else "Choose a password",
            .google => "Continue with Google",
            .chatgpt => "Continue with ChatGPT",
        };
        const detail = if (provider_at_setup) "Set up in Settings → Sign-in once you’re in" else switch (method) {
            .passkey => "Face ID, Touch ID or a security key",
            .password => if (flow == .login) "For accounts with a password" else "At least 10 characters",
            .google => "Use your Google account",
            .chatgpt => "Use your ChatGPT account",
        };
        try render(w, "<span class=\"grow\"><strong>{title}</strong><small>{detail}</small></span>", .{ .title = title, .detail = detail });
        try icon(w, "chevron-right");
        try w.writeAll(if (provider_at_setup) "</div>" else "</a>");
    }
    try w.writeAll("</div><div class=\"dialog-foot dialog-foot-plain\"><span class=\"hint\">Missing one? Anyone on the team can add it in Settings → Sign-in.</span></div></dialog>");
}

fn problemText(code: []const u8) []const u8 {
    const known = [_][2][]const u8{
        .{ "unlinked", "No Analytico account is linked to that sign-in yet. Sign in another way and link it in Settings → Sign-in, or ask for an invite." },
        .{ "cancelled", "Sign-in was cancelled." },
        .{ "expired", "That sign-in took too long. Please try again." },
        .{ "provider", "The sign-in provider didn’t accept the request. Check its setup in Settings → Sign-in." },
        .{ "disabled", "That way of signing in is turned off on this instance." },
        .{ "taken", "That account is already linked to someone else on this instance." },
        .{ "origin", "Open Analytico at its own address to sign in." },
        .{ "busy", "Too many sign-in attempts right now. Try again in a few minutes." },
    };
    for (known) |pair| if (std.mem.eql(u8, pair[0], code)) return pair[1];
    return "";
}

// ---------------------------------------------------------------- pages

pub fn loginPage(ctx: *Ctx, problem: []const u8) !void {
    const arena = ctx.arena;
    const next = auth.safeNext(ctx.param("next") orelse "/");
    const methods = try enabledMethods(arena, ctx.db);
    const origin = (try pinnedOrigin(arena, ctx.db)) orelse try ctx.publicOrigin();
    var main = try primary(arena, ctx.db) orelse return layout.message(ctx, .service_unavailable, "No way to sign in", "Every sign-in method is turned off. Run `analytico user invite` on the server.");
    if (ctx.param("method")) |requested| if (std.meta.stringToEnum(Method, requested)) |method| {
        for (methods) |candidate| if (candidate == method) {
            main = method;
        };
    };
    const message = if (problem.len != 0) problem else problemText(ctx.param("error") orelse "");
    if (message.len != 0) ctx.status = .unauthorized;
    const title = if (main == .password) "Sign in with password" else "Welcome back";
    _ = try card(ctx, title, try std.fmt.allocPrint(arena, "Sign in to {s}", .{host(origin)}), message);
    try mainMethod(ctx, main, .{ .login = next }, "");
    try optionsDialog(ctx, .{ .login = next }, main, methods);
    return cardEnd(ctx, "No account yet? Ask a teammate for an invite.");
}

pub fn loginPost(ctx: *Ctx) !void {
    if (!try enabled(ctx.arena, ctx.db, .password)) return loginPage(ctx, problemText("disabled"));
    if (auth.tooManyFailures(ctx)) return loginPage(ctx, "Too many attempts. Try again in 15 minutes.");
    const email = try auth.normalizeEmail(ctx.arena, try ctx.field("email"));
    const password = try ctx.field("password");
    var statement = try ctx.db.prepare(ctx.arena, "SELECT id,password_hash FROM users WHERE email=? AND password_hash IS NOT NULL");
    defer statement.deinit();
    try statement.bindText(1, email);
    var user_id: ?i64 = null;
    if (try statement.step() == .row) {
        const stored = try ctx.arena.dupe(u8, statement.columnText(1));
        if (auth.passwordMatches(ctx, stored, password)) user_id = statement.columnInt(0);
    } else {
        // Same cost either way, so timing doesn't reveal which emails exist.
        _ = try auth.hashPassword(ctx, password);
    }
    const id = user_id orelse {
        auth.recordFailure(ctx);
        ctx.query = try html.Params.parse(ctx.arena, "method=password");
        return loginPage(ctx, "That email and password don’t match.");
    };
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    try auth.startSession(ctx, db, id);
    return ctx.redirect(auth.safeNext(try ctx.field("next")));
}

pub fn setupPage(ctx: *Ctx, token: []const u8, problem: []const u8) !void {
    if (!try auth.setupLinkValid(ctx, token)) return layout.message(ctx, .not_found, "This setup link has expired", "Setup links work once and expire after an hour. Run `analytico init` or `analytico user invite` again on the server.");
    if (problem.len != 0) ctx.status = .unprocessable_entity;
    const choose_password = std.mem.eql(u8, ctx.param("method") orelse "", "password");
    const w = try card(ctx, "Create your account", "You’re the first one here. Choose how you’ll sign in — you can add more ways later.", problem);
    try render(w, "<label class=\"field mb-16\">Your email<input class=\"input\" type=\"email\" id=\"account-email\" name=\"email\" form=\"account-form\" autocomplete=\"username\" required value=\"{email}\"><small>For alerts, reports and teammates — never shared.</small></label>", .{ .email = ctx.param("email") orelse "" });
    if (choose_password) {
        try render(w,
            \\<form method="post" id="account-form" action="/welcome/{token}" class="form-grid" data-native>
            \\<label class="field">Password<input class="input" type="password" name="password" autocomplete="new-password" minlength="10" required><small>At least 10 characters. A passphrase works well.</small></label>
            \\<button class="btn btn-primary btn-l">Create account</button></form>
        , .{ .token = token });
        try optionsDialog(ctx, .{ .setup = token }, .password, &.{ .passkey, .password });
    } else {
        try passkeyButton(w, .{ .setup = token });
        try optionsDialog(ctx, .{ .setup = token }, .passkey, &.{ .passkey, .password });
    }
    return cardEnd(ctx, "This setup link works once and expires in an hour.");
}

pub fn setupPost(ctx: *Ctx, token: []const u8) !void {
    if (!try auth.setupLinkValid(ctx, token)) return setupPage(ctx, token, "");
    const email = try auth.normalizeEmail(ctx.arena, try ctx.field("email"));
    const password = try ctx.field("password");
    ctx.query = try html.Params.parse(ctx.arena, try std.fmt.allocPrint(ctx.arena, "method=password&email={f}", .{html.url(email)}));
    if (!auth.validEmail(email)) return setupPage(ctx, token, "Enter the email you’d like to use.");
    if (password.len < 10 or password.len > 512) return setupPage(ctx, token, "Use at least 10 characters.");
    const hashed_password = try auth.hashPassword(ctx, password);
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    try db.exec("BEGIN IMMEDIATE");
    errdefer db.exec("ROLLBACK") catch {};
    const user_id = try consumeSetup(ctx, db, token, email);
    try db.run(ctx.arena, "UPDATE users SET password_hash=? WHERE id=?", .{ hashed_password, user_id });
    // The first method chosen becomes the one shown first.
    try data.putSetting(ctx.arena, db, .@"auth.primary", "password");
    try auth.startSession(ctx, db, user_id);
    try db.exec("COMMIT");
    return ctx.done("You’re in. Welcome to Analytico.", "{s}", .{"/"});
}

/// Consumes a setup link and returns the owner's user id.
fn consumeSetup(ctx: *Ctx, db: *db_mod.Db, token: []const u8, email: []const u8) !i64 {
    const hashed = auth.hashToken(token);
    try db.run(ctx.arena, "DELETE FROM setup_links WHERE token_hash=? AND expires_at_ms>?", .{ &hashed, ctx.now() });
    if (db.changes() != 1) return error.SetupLinkExpired;
    try db.run(ctx.arena, "INSERT INTO users(email,role,created_at_ms) VALUES(?,'owner',?) ON CONFLICT(email) DO UPDATE SET role='owner',all_sites=1", .{ email, ctx.now() });
    return db.scalar(ctx.arena, i64, "SELECT id FROM users WHERE email=?", .{email});
}

pub fn invitePage(ctx: *Ctx, token: []const u8, problem: []const u8) !void {
    const arena = ctx.arena;
    const invite = try auth.findInvite(ctx, token) orelse return layout.message(ctx, .not_found, "This link has expired", "Invite links work once and expire after seven days. Ask for a new one.");
    if (problem.len != 0) ctx.status = .unprocessable_entity;
    const methods = try enabledMethods(arena, ctx.db);
    var main = try primary(arena, ctx.db) orelse return layout.message(ctx, .service_unavailable, "No way to sign in", "Every sign-in method is turned off on this instance.");
    if (ctx.param("method")) |requested| if (std.meta.stringToEnum(Method, requested)) |method| {
        for (methods) |candidate| if (candidate == method) {
            main = method;
        };
    };
    const origin = (try pinnedOrigin(arena, ctx.db)) orelse try ctx.publicOrigin();
    const message = if (problem.len != 0) problem else problemText(ctx.param("error") orelse "");
    const w = try card(ctx, if (invite.joined) "Choose how you sign in" else "Join the team", try std.fmt.allocPrint(arena, "You’re invited to {s}. Choose how you’ll sign in.", .{host(origin)}), message);
    try render(w, "<label class=\"field mb-16\">Email<input class=\"input\" value=\"{email}\" disabled><small>From your invite — your teammates see this.</small></label>", .{ .email = invite.email });
    try mainMethod(ctx, main, .{ .invite = token }, invite.email);
    try optionsDialog(ctx, .{ .invite = token }, main, methods);
    return cardEnd(ctx, "Invite links work once and expire after seven days.");
}

pub fn invitePost(ctx: *Ctx, token: []const u8) !void {
    const invite = try auth.findInvite(ctx, token) orelse return invitePage(ctx, token, "");
    ctx.query = try html.Params.parse(ctx.arena, "method=password");
    if (!try enabled(ctx.arena, ctx.db, .password)) return invitePage(ctx, token, problemText("disabled"));
    const password = try ctx.field("password");
    if (password.len < 10 or password.len > 512) return invitePage(ctx, token, "Use at least 10 characters.");
    const hashed_password = try auth.hashPassword(ctx, password);
    const hashed_token = auth.hashToken(token);
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    try db.exec("BEGIN IMMEDIATE");
    errdefer db.exec("ROLLBACK") catch {};
    try db.run(ctx.arena, "UPDATE users SET password_hash=? WHERE id=?", .{ hashed_password, invite.user_id });
    try db.run(ctx.arena, "DELETE FROM user_invites WHERE token_hash=?", .{&hashed_token});
    // A password reset signs out every other device.
    try db.run(ctx.arena, "DELETE FROM web_sessions WHERE user_id=?", .{invite.user_id});
    try auth.startSession(ctx, db, invite.user_id);
    try db.exec("COMMIT");
    return ctx.done("You’re in. Welcome to Analytico.", "{s}", .{"/"});
}

// ---------------------------------------------------------------- passkeys

fn jsonError(ctx: *Ctx, status: std.http.Status, message: []const u8) !void {
    ctx.status = status;
    try std.json.Stringify.value(.{ .@"error" = message }, .{}, ctx.w());
    return ctx.json();
}

fn randomUrl(ctx: *Ctx, comptime bytes: usize) ![]const u8 {
    var raw: [bytes]u8 = undefined;
    try ctx.shared.io.randomSecure(&raw);
    const out = try ctx.arena.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(bytes));
    return std.base64.url_safe_no_pad.Encoder.encode(out, &raw);
}

fn userHandle(ctx: *Ctx, user_id: i64) ![]const u8 {
    var statement = try ctx.db.prepare(ctx.arena, "SELECT coalesce(webauthn_handle,'') FROM users WHERE id=?");
    defer statement.deinit();
    try statement.bindInt(1, user_id);
    if (try statement.step() == .row and statement.columnText(0).len != 0) return ctx.arena.dupe(u8, statement.columnText(0));
    return randomUrl(ctx, 16);
}

fn readJson(ctx: *Ctx) !std.json.ObjectMap {
    const body = ctx.bodyBytes() catch return error.InvalidBody;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, body, .{}) catch return error.InvalidBody;
    if (parsed != .object) return error.InvalidBody;
    return parsed.object;
}

fn field(object: std.json.ObjectMap, key: []const u8) []const u8 {
    const value = object.get(key) orelse return "";
    return if (value == .string) value.string else "";
}

/// Passkeys only work on the pinned origin; anything else fails clearly.
fn passkeyOrigin(ctx: *Ctx) !?[]const u8 {
    const origin = try pinnedOrigin(ctx.arena, ctx.db) orelse return null;
    if (!std.mem.eql(u8, origin, try ctx.publicOrigin())) return null;
    return origin;
}

pub fn passkeyOptions(ctx: *Ctx) !void {
    const arena = ctx.arena;
    const origin = try passkeyOrigin(ctx) orelse return jsonError(ctx, .bad_request, try std.fmt.allocPrint(arena, "Passkeys work at {s}.", .{(try pinnedOrigin(arena, ctx.db)) orelse "this instance’s own address — run `analytico user invite --origin` to set it"}));
    const input = readJson(ctx) catch return jsonError(ctx, .bad_request, "The request couldn’t be read.");
    const purpose = field(input, "purpose");
    const token = field(input, "token");
    var user_id: ?i64 = null;
    var email: []const u8 = "";
    var binding: []const u8 = "";
    var handle: []const u8 = "";
    if (std.mem.eql(u8, purpose, "login")) {
        if (!try enabled(arena, ctx.db, .passkey)) return jsonError(ctx, .forbidden, problemText("disabled"));
        if (auth.tooManyFailures(ctx)) return jsonError(ctx, .too_many_requests, "Too many attempts. Try again in 15 minutes.");
    } else if (std.mem.eql(u8, purpose, "setup")) {
        if (!try auth.setupLinkValid(ctx, token)) return jsonError(ctx, .gone, "This setup link has expired.");
        email = try auth.normalizeEmail(arena, field(input, "email"));
        if (!auth.validEmail(email)) return jsonError(ctx, .bad_request, "Enter the email you’d like to use first.");
        binding = try ctx.arena.dupe(u8, &auth.hashToken(token));
        handle = try randomUrl(ctx, 16);
    } else if (std.mem.eql(u8, purpose, "invite")) {
        if (!try enabled(arena, ctx.db, .passkey)) return jsonError(ctx, .forbidden, problemText("disabled"));
        const invite = try auth.findInvite(ctx, token) orelse return jsonError(ctx, .gone, "This invite has expired.");
        user_id = invite.user_id;
        email = invite.email;
        binding = try ctx.arena.dupe(u8, &auth.hashToken(token));
        handle = try userHandle(ctx, invite.user_id);
    } else if (std.mem.eql(u8, purpose, "add")) {
        if (!try enabled(arena, ctx.db, .passkey)) return jsonError(ctx, .forbidden, problemText("disabled"));
        ctx.user = try auth.currentUser(ctx);
        const user = ctx.user orelse return jsonError(ctx, .unauthorized, "Sign in first.");
        user_id = user.id;
        email = user.email;
        handle = try userHandle(ctx, user.id);
    } else return jsonError(ctx, .bad_request, "Unknown passkey request.");

    const challenge_id = try auth.newToken(ctx.shared.io);
    const challenge = try randomUrl(ctx, 32);
    {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        if (!try challengeRoom(ctx, db)) return jsonError(ctx, .too_many_requests, "Too many sign-in attempts right now. Try again in a few minutes.");
        var statement = try db.prepare(arena, "INSERT INTO auth_challenges(id,purpose,challenge,user_id,binding,handle,email,next,expires_at_ms) VALUES(?,?,?,?,?,?,?,?,?)");
        defer statement.deinit();
        try statement.bindText(1, &challenge_id);
        try statement.bindText(2, purpose);
        try statement.bindText(3, challenge);
        try statement.bindOptionalInt(4, user_id);
        try statement.bindText(5, binding);
        try statement.bindText(6, handle);
        try statement.bindText(7, email);
        try statement.bindText(8, auth.safeNext(field(input, "next")));
        try statement.bindInt(9, ctx.now() + challenge_ms);
        _ = try statement.step();
    }
    const w = ctx.w();
    const rp = rpId(origin);
    if (std.mem.eql(u8, purpose, "login")) {
        try w.print("{{\"challenge_id\":\"{s}\",\"publicKey\":{{\"challenge\":\"{s}\",\"rpId\":", .{ &challenge_id, challenge });
        try std.json.Stringify.value(rp, .{}, w);
        try w.writeAll(",\"timeout\":300000,\"userVerification\":\"required\",\"allowCredentials\":[]}}");
        return ctx.json();
    }
    try w.print("{{\"challenge_id\":\"{s}\",\"publicKey\":{{\"challenge\":\"{s}\",\"rp\":{{\"name\":\"Analytico\",\"id\":", .{ &challenge_id, challenge });
    try std.json.Stringify.value(rp, .{}, w);
    try w.print("}},\"user\":{{\"id\":\"{s}\",\"name\":", .{handle});
    try std.json.Stringify.value(email, .{}, w);
    try w.writeAll(",\"displayName\":");
    try std.json.Stringify.value(email, .{}, w);
    try w.writeAll("},\"pubKeyCredParams\":[{\"type\":\"public-key\",\"alg\":-7},{\"type\":\"public-key\",\"alg\":-257}],\"timeout\":300000,\"attestation\":\"none\",\"authenticatorSelection\":{\"residentKey\":\"required\",\"requireResidentKey\":true,\"userVerification\":\"required\"},\"excludeCredentials\":[");
    if (user_id) |id| {
        var existing = try ctx.db.prepare(arena, "SELECT credential_id FROM passkeys WHERE user_id=?");
        defer existing.deinit();
        try existing.bindInt(1, id);
        var first = true;
        while (try existing.step() == .row) {
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("{{\"type\":\"public-key\",\"id\":\"{s}\"}}", .{existing.columnText(0)});
        }
    }
    try w.writeAll("]}}");
    return ctx.json();
}

const Challenge = struct { purpose: []const u8, challenge: []const u8, user_id: ?i64, binding: []const u8, handle: []const u8, email: []const u8, next: []const u8, verifier: []const u8, provider: []const u8, intent: []const u8 };

/// Challenges can be requested without signing in; keep their number bounded.
fn challengeRoom(ctx: *Ctx, db: *db_mod.Db) !bool {
    try db.run(ctx.arena, "DELETE FROM auth_challenges WHERE expires_at_ms<?", .{ctx.now()});
    return try db.scalar(ctx.arena, i64, "SELECT count(*) FROM auth_challenges", .{}) < 1000;
}

/// Single use: every attempt consumes the challenge, successful or not.
fn consumeChallenge(ctx: *Ctx, id: []const u8) !?Challenge {
    if (id.len != 64) return null;
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    var statement = try db.prepare(ctx.arena, "DELETE FROM auth_challenges WHERE id=? RETURNING purpose,challenge,user_id,binding,handle,email,next,verifier,provider,intent,expires_at_ms");
    defer statement.deinit();
    try statement.bindText(1, id);
    if (try statement.step() != .row) return null;
    if (statement.columnInt(10) <= ctx.now()) return null;
    const a = ctx.arena;
    return .{
        .purpose = try a.dupe(u8, statement.columnText(0)),
        .challenge = try a.dupe(u8, statement.columnText(1)),
        .user_id = if (statement.columnType(2) == db_mod.sqlite.SQLITE_NULL) null else statement.columnInt(2),
        .binding = try a.dupe(u8, statement.columnText(3)),
        .handle = try a.dupe(u8, statement.columnText(4)),
        .email = try a.dupe(u8, statement.columnText(5)),
        .next = try a.dupe(u8, statement.columnText(6)),
        .verifier = try a.dupe(u8, statement.columnText(7)),
        .provider = try a.dupe(u8, statement.columnText(8)),
        .intent = try a.dupe(u8, statement.columnText(9)),
    };
}

/// "Mac · iCloud Keychain", "Android · Google Password Manager", "Windows · Passkey".
fn passkeyLabel(arena: std.mem.Allocator, user_agent: []const u8, aaguid_b64: []const u8, synced: bool) ![]const u8 {
    const device = if (std.mem.indexOf(u8, user_agent, "iPhone") != null) "iPhone" else if (std.mem.indexOf(u8, user_agent, "iPad") != null) "iPad" else if (std.mem.indexOf(u8, user_agent, "Android") != null) "Android" else if (std.mem.indexOf(u8, user_agent, "Macintosh") != null) "Mac" else if (std.mem.indexOf(u8, user_agent, "Windows") != null) "Windows" else if (std.mem.indexOf(u8, user_agent, "Linux") != null) "Linux" else "Device";
    var raw: [16]u8 = @splat(0);
    _ = std.base64.url_safe_no_pad.Decoder.decode(&raw, aaguid_b64) catch {};
    const hex = std.fmt.bytesToHex(raw, .lower);
    const known = [_][2][]const u8{
        .{ "fbfc3007154e4ecc8c0b6e020557d7bd", "iCloud Keychain" },
        .{ "ea9b8d664d011d213ce4b6b48cb575d4", "Google Password Manager" },
        .{ "bada5566a7aa401fbd9645619a55120d", "1Password" },
        .{ "d548826e79b4db40a3d811116f7e8349", "Bitwarden" },
        .{ "08987058cadc4b81b6e130de50dcbe96", "Windows Hello" },
        .{ "9ddd1817af5a4672a2b93e3dd95000a9", "Windows Hello" },
        .{ "6028b017b1d44c02b4b3afcdafc96bb2", "Windows Hello" },
    };
    var keeper: []const u8 = if (synced) "Synced passkey" else "Passkey";
    for (known) |pair| if (std.mem.eql(u8, pair[0], &hex)) {
        keeper = pair[1];
    };
    // Apple zeroes the AAGUID; a synced passkey on an Apple device is iCloud Keychain.
    if (std.mem.eql(u8, keeper, "Synced passkey") and (std.mem.eql(u8, device, "Mac") or std.mem.eql(u8, device, "iPhone") or std.mem.eql(u8, device, "iPad"))) keeper = "iCloud Keychain";
    return std.fmt.allocPrint(arena, "{s} · {s}", .{ device, keeper });
}

pub fn passkeyVerify(ctx: *Ctx) !void {
    const arena = ctx.arena;
    const origin = try passkeyOrigin(ctx) orelse return jsonError(ctx, .bad_request, problemText("origin"));
    const input = readJson(ctx) catch return jsonError(ctx, .bad_request, "The request couldn’t be read.");
    const challenge = try consumeChallenge(ctx, field(input, "challenge_id")) orelse return jsonError(ctx, .gone, problemText("expired"));
    const now = ctx.now();
    if (std.mem.eql(u8, challenge.purpose, "login")) {
        const credential_id = field(input, "credential_id");
        var lookup = try ctx.db.prepare(arena, "SELECT p.id,p.user_id,p.public_key,p.sign_count FROM passkeys p WHERE p.credential_id=?");
        defer lookup.deinit();
        try lookup.bindText(1, credential_id);
        if (try lookup.step() != .row) {
            auth.recordFailure(ctx);
            return jsonError(ctx, .unauthorized, "This passkey isn’t registered here. It may have been removed — sign in another way.");
        }
        const passkey_id = lookup.columnInt(0);
        const user_id = lookup.columnInt(1);
        const public_key = try arena.dupe(u8, lookup.columnText(2));
        const known: u32 = @intCast(@max(0, @min(lookup.columnInt(3), std.math.maxInt(u32))));
        const verified = passkeys.verifyAuthentication(ctx.shared.gpa, .{
            .authenticator_data = field(input, "authenticator_data"),
            .client_data_json = field(input, "client_data_json"),
            .signature = field(input, "signature"),
            .public_key = public_key,
            .expected_challenge = challenge.challenge,
            .expected_origin = origin,
            .rp_id = rpId(origin),
            .known_sign_count = known,
        }) catch |err| {
            std.log.warn("passkey_login_rejected code={s}", .{@errorName(err)});
            auth.recordFailure(ctx);
            return jsonError(ctx, .unauthorized, "That passkey couldn’t be verified. Try again.");
        };
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try db.run(arena, "UPDATE passkeys SET sign_count=?,backup_state=?,last_used_at_ms=? WHERE id=?", .{ verified.recommended_sign_count, @intFromBool(verified.backup_state), now, passkey_id });
        try auth.startSession(ctx, db, user_id);
        try std.json.Stringify.value(.{ .redirect = auth.safeNext(challenge.next) }, .{}, ctx.w());
        return ctx.json();
    }
    const registration = passkeys.verifyRegistration(ctx.shared.gpa, .{
        .attestation_object = field(input, "attestation_object"),
        .client_data_json = field(input, "client_data_json"),
        .expected_challenge = challenge.challenge,
        .expected_origin = origin,
        .rp_id = rpId(origin),
    }) catch |err| {
        std.log.warn("passkey_register_rejected code={s}", .{@errorName(err)});
        return jsonError(ctx, .bad_request, "That passkey couldn’t be verified. Try again.");
    };
    defer registration.deinit(ctx.shared.gpa);
    const label = try passkeyLabel(arena, ctx.head.user_agent, registration.aaguid, registration.backup_state);
    const transports = field(input, "transports");
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    try db.exec("BEGIN IMMEDIATE");
    errdefer db.exec("ROLLBACK") catch {};
    var user_id: i64 = undefined;
    var redirect: []const u8 = "/";
    if (std.mem.eql(u8, challenge.purpose, "setup")) {
        user_id = consumeSetupHash(ctx, db, challenge.binding, challenge.email) catch {
            db.exec("ROLLBACK") catch {};
            return jsonError(ctx, .gone, "This setup link has expired.");
        };
        try data.putSetting(arena, db, .@"auth.primary", "passkey");
        try ctx.flash("You’re in. Welcome to Analytico.", "", "");
    } else if (std.mem.eql(u8, challenge.purpose, "invite")) {
        user_id = challenge.user_id.?;
        try db.run(arena, "DELETE FROM user_invites WHERE token_hash=? AND user_id=? AND expires_at_ms>?", .{ challenge.binding, user_id, now });
        if (db.changes() != 1) {
            db.exec("ROLLBACK") catch {};
            return jsonError(ctx, .gone, "This invite has expired.");
        }
        try ctx.flash("You’re in. Welcome to Analytico.", "", "");
    } else {
        user_id = challenge.user_id.?;
        ctx.user = try auth.currentUser(ctx);
        if (ctx.user == null or ctx.user.?.id != user_id) {
            db.exec("ROLLBACK") catch {};
            return jsonError(ctx, .unauthorized, "Sign in first.");
        }
        redirect = "/settings/signin";
        try ctx.flash(try std.fmt.allocPrint(arena, "Passkey added: {s}.", .{label}), "", "");
    }
    try db.run(arena, "UPDATE users SET webauthn_handle=coalesce(webauthn_handle,?) WHERE id=?", .{ challenge.handle, user_id });
    var insert = try db.prepare(arena, "INSERT INTO passkeys(user_id,credential_id,public_key,algorithm,sign_count,aaguid,transports,backup_eligible,backup_state,label,created_at_ms,last_used_at_ms) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)");
    defer insert.deinit();
    try insert.bindInt(1, user_id);
    try insert.bindText(2, registration.credential_id);
    try insert.bindText(3, registration.public_key);
    try insert.bindInt(4, registration.algorithm);
    try insert.bindInt(5, registration.sign_count);
    try insert.bindText(6, registration.aaguid);
    try insert.bindText(7, transports[0..@min(transports.len, 128)]);
    try insert.bindBool(8, registration.backup_eligible);
    try insert.bindBool(9, registration.backup_state);
    try insert.bindText(10, label);
    try insert.bindInt(11, now);
    try insert.bindInt(12, now);
    _ = insert.step() catch {
        db.exec("ROLLBACK") catch {};
        return jsonError(ctx, .conflict, "That passkey is already registered.");
    };
    if (!std.mem.eql(u8, challenge.purpose, "add")) try auth.startSession(ctx, db, user_id);
    try db.exec("COMMIT");
    try std.json.Stringify.value(.{ .redirect = redirect }, .{}, ctx.w());
    return ctx.json();
}

fn consumeSetupHash(ctx: *Ctx, db: *db_mod.Db, hashed: []const u8, email: []const u8) !i64 {
    try db.run(ctx.arena, "DELETE FROM setup_links WHERE token_hash=? AND expires_at_ms>?", .{ hashed, ctx.now() });
    if (db.changes() != 1) return error.SetupLinkExpired;
    try db.run(ctx.arena, "INSERT INTO users(email,role,created_at_ms) VALUES(?,'owner',?) ON CONFLICT(email) DO UPDATE SET role='owner',all_sites=1", .{ email, ctx.now() });
    return db.scalar(ctx.arena, i64, "SELECT id FROM users WHERE email=?", .{email});
}

// ---------------------------------------------------------------- Google and ChatGPT

fn failTo(ctx: *Ctx, intent: []const u8, code: []const u8, token: []const u8) !void {
    if (std.mem.eql(u8, intent, "link")) {
        return ctx.done(try std.fmt.allocPrint(ctx.arena, "!{s}", .{problemText(code)}), "{s}", .{"/settings/signin"});
    }
    if (std.mem.eql(u8, intent, "invite") and token.len != 0) return ctx.redirectFmt("/invite/{f}?error={s}", .{ html.url(token), code });
    return ctx.redirectFmt("/login?error={s}", .{code});
}

pub fn providerStart(ctx: *Ctx, method: Method) !void {
    const arena = ctx.arena;
    const provider = method.provider().?;
    const intent = ctx.param("intent") orelse "login";
    const token = ctx.param("token") orelse "";
    const origin = try pinnedOrigin(arena, ctx.db) orelse return failTo(ctx, intent, "origin", token);
    if (!std.mem.eql(u8, origin, try ctx.publicOrigin())) return failTo(ctx, intent, "origin", token);
    if (!try enabled(arena, ctx.db, method)) return failTo(ctx, intent, "disabled", token);
    var user_id: ?i64 = null;
    var binding: []const u8 = "";
    if (std.mem.eql(u8, intent, "link")) {
        ctx.user = try auth.currentUser(ctx);
        user_id = (ctx.user orelse return ctx.redirect("/login")).id;
    } else if (std.mem.eql(u8, intent, "invite")) {
        const invite = try auth.findInvite(ctx, token) orelse return failTo(ctx, "login", "expired", "");
        user_id = invite.user_id;
        binding = try ctx.arena.dupe(u8, &auth.hashToken(token));
    } else if (!std.mem.eql(u8, intent, "login")) return failTo(ctx, "login", "provider", "");
    const config = try oidc.load(arena, ctx.db, ctx.shared.master_key, provider) orelse return failTo(ctx, intent, "disabled", token);
    ctx.extendDeadline(30);
    const discovery = oidc.discover(arena, config.issuer) catch return failTo(ctx, intent, "provider", token);
    const state = try auth.newToken(ctx.shared.io);
    const nonce = try randomUrl(ctx, 24);
    const verifier = try randomUrl(ctx, 32);
    {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        if (!try challengeRoom(ctx, db)) return failTo(ctx, intent, "busy", token);
        var statement = try db.prepare(arena, "INSERT INTO auth_challenges(id,purpose,challenge,verifier,user_id,binding,provider,intent,next,expires_at_ms) VALUES(?,'oidc',?,?,?,?,?,?,?,?)");
        defer statement.deinit();
        const state_hash = auth.hashToken(&state);
        try statement.bindText(1, &state_hash);
        try statement.bindText(2, nonce);
        try statement.bindText(3, verifier);
        try statement.bindOptionalInt(4, user_id);
        try statement.bindText(5, binding);
        try statement.bindText(6, @tagName(provider));
        try statement.bindText(7, intent);
        try statement.bindText(8, if (std.mem.eql(u8, intent, "invite")) token else auth.safeNext(ctx.param("next") orelse "/"));
        try statement.bindInt(9, ctx.now() + oidc_ms);
        _ = try statement.step();
    }
    // The browser that starts the flow must be the one that finishes it.
    try ctx.setCookie(oidc_cookie, try arena.dupe(u8, &state), oidc_ms / 1000);
    const redirect_uri = try std.fmt.allocPrint(arena, "{s}/auth/{s}/callback", .{ origin, @tagName(provider) });
    return ctx.redirect(try oidc.authorizationUrl(arena, discovery, config, redirect_uri, &state, nonce, verifier));
}

pub fn providerCallback(ctx: *Ctx, method: Method) !void {
    const arena = ctx.arena;
    const provider = method.provider().?;
    const state = ctx.param("state") orelse "";
    const cookie = ctx.cookie(oidc_cookie) orelse "";
    try ctx.setCookie(oidc_cookie, "", 0);
    if (state.len != 64 or !std.mem.eql(u8, state, cookie)) return failTo(ctx, "login", "expired", "");
    const challenge = try consumeChallenge(ctx, &auth.hashToken(state)) orelse return failTo(ctx, "login", "expired", "");
    const token = if (std.mem.eql(u8, challenge.intent, "invite")) challenge.next else "";
    if (!std.mem.eql(u8, challenge.purpose, "oidc") or !std.mem.eql(u8, challenge.provider, @tagName(provider))) return failTo(ctx, "login", "expired", "");
    if (ctx.param("error") != null) return failTo(ctx, challenge.intent, "cancelled", token);
    const code = ctx.param("code") orelse return failTo(ctx, challenge.intent, "cancelled", token);
    const origin = try pinnedOrigin(arena, ctx.db) orelse return failTo(ctx, challenge.intent, "origin", token);
    const config = try oidc.load(arena, ctx.db, ctx.shared.master_key, provider) orelse return failTo(ctx, challenge.intent, "disabled", token);
    ctx.extendDeadline(30);
    const discovery = oidc.discover(arena, config.issuer) catch return failTo(ctx, challenge.intent, "provider", token);
    const redirect_uri = try std.fmt.allocPrint(arena, "{s}/auth/{s}/callback", .{ origin, @tagName(provider) });
    const identity = oidc.exchange(arena, discovery, config, code, redirect_uri, challenge.verifier, challenge.challenge, ctx.now()) catch |err| {
        std.log.warn("oidc_exchange_failed provider={s} code={s}", .{ @tagName(provider), @errorName(err) });
        return failTo(ctx, challenge.intent, "provider", token);
    };
    const now = ctx.now();
    const existing = try ctx.db.scalar(arena, i64, "SELECT coalesce((SELECT user_id FROM identities WHERE provider=? AND subject=?),0)", .{ @tagName(provider), identity.subject });
    if (std.mem.eql(u8, challenge.intent, "login")) {
        if (existing == 0) {
            // The Workspace domain rule: a verified account of the configured
            // Google hosted domain joins as a viewer. Existing accounts are
            // never matched by email address.
            const domain_rule = (try data.setting(arena, ctx.db, .@"auth.google.domain")) orelse "";
            const email_domain = if (std.mem.findScalar(u8, identity.email, '@')) |at| identity.email[at + 1 ..] else "";
            if (provider != .google or domain_rule.len == 0 or !std.ascii.eqlIgnoreCase(identity.hosted_domain, domain_rule) or !std.ascii.eqlIgnoreCase(email_domain, domain_rule)) return failTo(ctx, "login", "unlinked", "");
            const email = try auth.normalizeEmail(arena, identity.email);
            const db = ctx.shared.lockWrite();
            defer ctx.shared.unlockWrite();
            if (try db.scalar(arena, i64, "SELECT count(*) FROM users WHERE email=?", .{email}) != 0) return failTo(ctx, "login", "unlinked", "");
            try db.exec("BEGIN IMMEDIATE");
            errdefer db.exec("ROLLBACK") catch {};
            try db.run(arena, "INSERT INTO users(email,role,all_sites,created_at_ms) VALUES(?,'viewer',1,?)", .{ email, now });
            const user_id = db.lastInsertRowId();
            try db.run(arena, "INSERT INTO identities(provider,subject,user_id,email,created_at_ms,last_used_at_ms) VALUES('google',?,?,?,?,?)", .{ identity.subject, user_id, identity.email, now, now });
            try @import("audit.zig").recordAs(arena, db, email, null, "team.joined", try std.fmt.allocPrint(arena, "Joined as Viewer through the @{s} Google rule", .{domain_rule}), now);
            try auth.startSession(ctx, db, user_id);
            try db.exec("COMMIT");
            return ctx.done("You’re in as a viewer. Ask an admin if you need more access.", "{s}", .{"/"});
        }
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try db.run(arena, "UPDATE identities SET last_used_at_ms=? WHERE provider=? AND subject=?", .{ now, @tagName(provider), identity.subject });
        try auth.startSession(ctx, db, existing);
        return ctx.redirect(auth.safeNext(challenge.next));
    }
    const user_id = challenge.user_id orelse return failTo(ctx, challenge.intent, "expired", token);
    if (existing != 0 and existing != user_id) return failTo(ctx, challenge.intent, "taken", token);
    if (std.mem.eql(u8, challenge.intent, "link")) {
        ctx.user = try auth.currentUser(ctx);
        if (ctx.user == null or ctx.user.?.id != user_id) return failTo(ctx, "login", "expired", "");
    }
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    try db.exec("BEGIN IMMEDIATE");
    errdefer db.exec("ROLLBACK") catch {};
    if (std.mem.eql(u8, challenge.intent, "invite")) {
        try db.run(arena, "DELETE FROM user_invites WHERE token_hash=? AND user_id=? AND expires_at_ms>?", .{ challenge.binding, user_id, now });
        if (db.changes() != 1) {
            db.exec("ROLLBACK") catch {};
            return failTo(ctx, "login", "expired", "");
        }
    }
    // One account per provider and person: linking again replaces the old one.
    try db.run(arena, "DELETE FROM identities WHERE provider=? AND user_id=?", .{ @tagName(provider), user_id });
    try db.run(arena, "INSERT INTO identities(provider,subject,user_id,email,created_at_ms,last_used_at_ms) VALUES(?,?,?,?,?,?)", .{ @tagName(provider), identity.subject, user_id, identity.email, now, now });
    if (std.mem.eql(u8, challenge.intent, "invite")) {
        try auth.startSession(ctx, db, user_id);
        try db.exec("COMMIT");
        return ctx.done("You’re in. Welcome to Analytico.", "{s}", .{"/"});
    }
    try db.exec("COMMIT");
    return ctx.done(try std.fmt.allocPrint(arena, "{s} linked{s}{s}. You can sign in with it from now on.", .{ provider.label(), if (identity.email.len != 0) " as " else "", identity.email }), "{s}", .{"/settings/signin"});
}

test "passkey labels" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("Mac · iCloud Keychain", try passkeyLabel(arena, "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", "AAAAAAAAAAAAAAAAAAAAAA", true));
    try std.testing.expectEqualStrings("Android · Google Password Manager", try passkeyLabel(arena, "Mozilla/5.0 (Linux; Android 15)", "6puNZk0BHSE85La0jLV11A", true));
    try std.testing.expectEqualStrings("example.com", rpId("https://example.com"));
    try std.testing.expectEqualStrings("localhost", rpId("http://localhost:4000"));
}
