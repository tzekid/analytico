//! Analytico as a read-only MCP connector for Claude and ChatGPT
//! subscriptions: OAuth 2.1 (PKCE, dynamic client registration) and a
//! stateless Streamable HTTP JSON-RPC endpoint.
const std = @import("std");
const catalog = @import("catalog.zig");
const ai = @import("ai.zig");
const agent = @import("agent.zig");
const assets = @import("../assets.zig");
const auth = @import("auth.zig");
const ctx_mod = @import("ctx.zig");
const data = @import("data.zig");
const db_mod = @import("../db.zig");
const html = @import("html.zig");
const layout = @import("layout.zig");

const Ctx = ctx_mod.Ctx;
const esc = html.esc;
const render = html.render;

const code_ms = 10 * 60_000;
const access_ms = 60 * 60_000;
const refresh_ms = 30 * data.day_ms;
const protocol_versions = [_][]const u8{ "2025-06-18", "2025-03-26", "2024-11-05" };

fn is(value: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, value, expected);
}

/// Handles connector routes; returns false for everything else.
pub fn route(ctx: *Ctx, parts: []const []const u8) !bool {
    if (parts.len == 0) return false;
    if (is(parts[0], ".well-known") and parts.len >= 2 and ctx.method == .GET) {
        if (is(parts[1], "oauth-protected-resource")) {
            try protectedResource(ctx);
            return true;
        }
        if (is(parts[1], "oauth-authorization-server") or is(parts[1], "openid-configuration")) {
            try authorizationServer(ctx);
            return true;
        }
        if (is(parts[1], "analytico")) {
            try discovery(ctx);
            return true;
        }
        return false;
    }
    if (is(parts[0], "oauth") and parts.len == 2) {
        if (is(parts[1], "register") and ctx.method == .POST) try register(ctx) else if (is(parts[1], "token") and ctx.method == .POST) try token(ctx) else if (is(parts[1], "authorize")) try authorize(ctx) else return false;
        return true;
    }
    if (is(parts[0], "mcp") and parts.len == 1) {
        if (ctx.method == .POST) try mcp(ctx) else {
            ctx.status = .method_not_allowed;
            try ctx.header("allow", "POST");
            try ctx.w().writeAll("{\"error\":\"use POST\"}");
            try ctx.json();
        }
        return true;
    }
    return false;
}

/// The client API level native apps check before signing in. Raised only
/// when an app-facing endpoint changes incompatibly.
pub const api_level = 1;

/// Built-in OAuth clients of the native apps ("analytico-apple"), created
/// by the schema. Their tokens read `/api/v1`; MCP tokens read `/mcp` only.
pub fn isApp(client_id: []const u8) bool {
    return std.mem.startsWith(u8, client_id, "analytico-");
}

/// What a native app checks before it offers sign-in: that this is
/// Analytico, which version, and whether anyone can sign in yet. Nothing
/// here goes beyond what the public sign-in page shows.
fn discovery(ctx: *Ctx) !void {
    const arena = ctx.arena;
    const origin = try ctx.publicOrigin();
    const host = if (std.mem.find(u8, origin, "://")) |index| origin[index + 3 ..] else origin;
    var sign_in: std.ArrayList([]const u8) = .empty;
    for (try @import("signin.zig").enabledMethods(arena, ctx.db)) |method| try sign_in.append(arena, @tagName(method));
    const people = try ctx.db.scalar(arena, i64, "SELECT count(*) FROM users u WHERE " ++ auth.joined_sql, .{});
    try ctx.header("cache-control", "public, max-age=60");
    try std.json.Stringify.value(.{
        .product = "analytico",
        .name = host,
        .version = @import("../cli.zig").version,
        .api = .{ .level = api_level, .base = "/api/v1" },
        .oauth = .{
            .issuer = origin,
            .authorization_endpoint = try std.fmt.allocPrint(arena, "{s}/oauth/authorize", .{origin}),
            .token_endpoint = try std.fmt.allocPrint(arena, "{s}/oauth/token", .{origin}),
        },
        .sign_in = sign_in.items,
        .setup_complete = people != 0,
    }, .{}, ctx.w());
    return ctx.json();
}

fn protectedResource(ctx: *Ctx) !void {
    const origin = try ctx.publicOrigin();
    try std.json.Stringify.value(.{
        .resource = try std.fmt.allocPrint(ctx.arena, "{s}/mcp", .{origin}),
        .authorization_servers = &[_][]const u8{origin},
        .scopes_supported = &[_][]const u8{"analytics:read"},
        .bearer_methods_supported = &[_][]const u8{"header"},
        .resource_name = "Analytico",
    }, .{}, ctx.w());
    return ctx.json();
}

fn authorizationServer(ctx: *Ctx) !void {
    const origin = try ctx.publicOrigin();
    try std.json.Stringify.value(.{
        .issuer = origin,
        .authorization_endpoint = try std.fmt.allocPrint(ctx.arena, "{s}/oauth/authorize", .{origin}),
        .token_endpoint = try std.fmt.allocPrint(ctx.arena, "{s}/oauth/token", .{origin}),
        .registration_endpoint = try std.fmt.allocPrint(ctx.arena, "{s}/oauth/register", .{origin}),
        .response_types_supported = &[_][]const u8{"code"},
        .grant_types_supported = &[_][]const u8{ "authorization_code", "refresh_token" },
        .code_challenge_methods_supported = &[_][]const u8{"S256"},
        .token_endpoint_auth_methods_supported = &[_][]const u8{"none"},
        .scopes_supported = &[_][]const u8{"analytics:read"},
    }, .{}, ctx.w());
    return ctx.json();
}

fn oauthError(ctx: *Ctx, status: std.http.Status, code: []const u8, description: []const u8) !void {
    ctx.status = status;
    try std.json.Stringify.value(.{ .@"error" = code, .error_description = description }, .{}, ctx.w());
    return ctx.json();
}

fn validRedirect(uri: []const u8) bool {
    if (uri.len > 512) return false;
    for (uri) |byte| if (byte <= 0x20 or byte >= 0x7f or byte == '"' or byte == '<' or byte == '>' or byte == '#' or byte == '\\') return false;
    if (std.mem.startsWith(u8, uri, "https://")) return uri.len > 8;
    // Loopback for native clients: the host must end right after the prefix.
    for ([_][]const u8{ "http://localhost", "http://127.0.0.1" }) |prefix| {
        if (std.mem.startsWith(u8, uri, prefix) and (uri.len == prefix.len or uri[prefix.len] == ':' or uri[prefix.len] == '/')) return true;
    }
    return false;
}

test validRedirect {
    try std.testing.expect(validRedirect("https://chatgpt.com/connector_platform_oauth_redirect"));
    try std.testing.expect(validRedirect("http://localhost:6274/callback"));
    for ([_][]const u8{ "http://localhost@evil.test/", "http://localhost.evil.test/", "http://evil.test/", "https://x\r\nset-cookie: a", "https://x/\\evil", "javascript:alert(1)" }) |bad| {
        try std.testing.expect(!validRedirect(bad));
    }
}

fn register(ctx: *Ctx) !void {
    const arena = ctx.arena;
    const body = ctx.bodyBytes() catch return oauthError(ctx, .bad_request, "invalid_client_metadata", "Body too large.");
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return oauthError(ctx, .bad_request, "invalid_client_metadata", "Expected JSON.");
    if (parsed != .object) return oauthError(ctx, .bad_request, "invalid_client_metadata", "Expected an object.");
    const uris_value = parsed.object.get("redirect_uris") orelse return oauthError(ctx, .bad_request, "invalid_redirect_uri", "redirect_uris is required.");
    if (uris_value != .array or uris_value.array.items.len == 0 or uris_value.array.items.len > 8) return oauthError(ctx, .bad_request, "invalid_redirect_uri", "Provide 1–8 redirect URIs.");
    var uris: std.ArrayList([]const u8) = .empty;
    for (uris_value.array.items) |item| {
        if (item != .string or !validRedirect(item.string)) return oauthError(ctx, .bad_request, "invalid_redirect_uri", "Redirect URIs must be https (or http://localhost).");
        try uris.append(arena, item.string);
    }
    var name: []const u8 = "MCP client";
    if (parsed.object.get("client_name")) |value| if (value == .string and value.string.len != 0 and value.string.len <= 80) {
        name = value.string;
    };
    @import("../domain.zig").validateText(name, 80, false) catch {
        name = "MCP client";
    };
    var id_bytes: [16]u8 = undefined;
    try ctx.shared.io.randomSecure(&id_bytes);
    const client_id = std.fmt.bytesToHex(id_bytes, .lower);
    var uris_json: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(uris.items, .{}, &uris_json.writer);
    {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        // Unauthenticated registration stays bounded: drop old unused clients.
        try db.run(arena, "DELETE FROM oauth_clients WHERE client_id IN (SELECT client_id FROM oauth_clients c WHERE client_id NOT LIKE 'analytico-%' AND NOT EXISTS(SELECT 1 FROM oauth_grants g WHERE g.client_id=c.client_id) ORDER BY created_at_ms LIMIT max(0,(SELECT count(*) FROM oauth_clients)-200))", .{});
        try db.run(arena, "INSERT INTO oauth_clients(client_id,name,redirect_uris,created_at_ms) VALUES(?,?,?,?)", .{ &client_id, name, uris_json.written(), ctx.now() });
    }
    ctx.status = .created;
    try std.json.Stringify.value(.{
        .client_id = &client_id,
        .client_name = name,
        .redirect_uris = uris.items,
        .token_endpoint_auth_method = "none",
        .grant_types = &[_][]const u8{ "authorization_code", "refresh_token" },
        .response_types = &[_][]const u8{"code"},
        .client_id_issued_at = @divFloor(ctx.now(), 1000),
    }, .{}, ctx.w());
    return ctx.json();
}

const Client = struct { name: []const u8, redirect_uris: []const u8 };

fn findClient(ctx: *Ctx, client_id: []const u8) !?Client {
    var statement = try ctx.db.prepare(ctx.arena, "SELECT name,redirect_uris FROM oauth_clients WHERE client_id=?");
    defer statement.deinit();
    try statement.bindText(1, client_id);
    if (try statement.step() != .row) return null;
    return .{ .name = try ctx.arena.dupe(u8, statement.columnText(0)), .redirect_uris = try ctx.arena.dupe(u8, statement.columnText(1)) };
}

fn registeredRedirect(arena: std.mem.Allocator, client: Client, uri: []const u8) bool {
    const parsed = std.json.parseFromSliceLeaky([]const []const u8, arena, client.redirect_uris, .{}) catch return false;
    for (parsed) |item| if (std.mem.eql(u8, item, uri)) return true;
    return false;
}

fn authorize(ctx: *Ctx) !void {
    const arena = ctx.arena;
    const params = if (ctx.method == .POST) try ctx.form() else ctx.query;
    const client_id = params.get("client_id") orelse "";
    const redirect_uri = params.get("redirect_uri") orelse "";
    const client = try findClient(ctx, client_id) orelse return layout.message(ctx, .bad_request, "Unknown app", "This connection request came from an app that isn’t registered. Start the connection again from Claude or ChatGPT.");
    // Native apps return through their own scheme, registered by the schema.
    const app = isApp(client_id);
    if (!(validRedirect(redirect_uri) or app) or !registeredRedirect(arena, client, redirect_uri)) return layout.message(ctx, .bad_request, "Unexpected redirect", "The app asked to return to an address it didn’t register. Nothing was shared.");
    const state = params.get("state") orelse "";
    const challenge = params.get("code_challenge") orelse "";
    if (!is(params.get("response_type") orelse "", "code") or challenge.len < 43 or challenge.len > 128 or !is(params.get("code_challenge_method") orelse "", "S256")) {
        return ctx.redirectFmt("{s}{s}error=invalid_request&state={f}", .{ redirect_uri, if (std.mem.findScalar(u8, redirect_uri, '?') == null) "?" else "&", html.url(state) });
    }
    ctx.user = try auth.currentUser(ctx);
    const user = ctx.user orelse return ctx.redirectFmt("/login?next={f}", .{html.url(ctx.target)});
    const sites = try ctx.visibleSites();
    if (ctx.method == .POST) {
        if (!ctx.sameOrigin()) return ctx.text(.forbidden, "cross-origin request refused\n");
        const separator = if (std.mem.findScalar(u8, redirect_uri, '?') == null) "?" else "&";
        if (!is(try ctx.field("decision"), "allow")) return ctx.redirectFmt("{s}{s}error=access_denied&state={f}", .{ redirect_uri, separator, html.url(state) });
        var allowed: std.ArrayList(u8) = .empty;
        // "*" means every website, including ones added later.
        if (is(try ctx.field("all"), "1")) try allowed.append(arena, '*');
        if (allowed.items.len == 0) for (try (try ctx.form()).all(arena, "site")) |value| {
            const id = std.fmt.parseInt(i64, value, 10) catch continue;
            for (sites) |site| if (site.id == id) {
                if (allowed.items.len != 0) try allowed.append(arena, ',');
                try allowed.print(arena, "{d}", .{id});
            };
        };
        if (allowed.items.len == 0) return layout.message(ctx, .bad_request, "Choose at least one website", "Go back and pick which websites the app may read, or allow all of them.");
        const code = try auth.newToken(ctx.shared.io);
        const hashed = auth.hashToken(&code);
        // An app's sign-in is one device, kept across token refreshes.
        var device_bytes: [16]u8 = undefined;
        try ctx.shared.io.randomSecure(&device_bytes);
        const device_id = std.fmt.bytesToHex(device_bytes, .lower);
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try db.run(arena, "DELETE FROM oauth_grants WHERE expires_at_ms<?", .{ctx.now()});
        try db.run(arena, "INSERT INTO oauth_grants(token_hash,kind,client_id,user_id,sites,redirect_uri,code_challenge,expires_at_ms,created_at_ms,device_id,device_name) VALUES(?,'code',?,?,?,?,?,?,?,?,?)", .{ &hashed, client_id, user.id, allowed.items, redirect_uri, challenge, ctx.now() + code_ms, ctx.now(), if (app) @as(?[]const u8, &device_id) else null, if (app) @as(?[]const u8, deviceName(params)) else null });
        return ctx.redirectFmt("{s}{s}code={s}&state={f}", .{ redirect_uri, separator, &code, html.url(state) });
    }
    // Consent screen. Its form redirects to the client, which CSP must allow.
    const uri = std.Uri.parse(redirect_uri) catch return layout.message(ctx, .bad_request, "Unexpected redirect", "The app’s return address is invalid.");
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = (std.Io.net.HostName.fromUri(uri, &host_buffer) catch return layout.message(ctx, .bad_request, "Unexpected redirect", "The app’s return address is invalid.")).bytes;
    ctx.form_action = if (uri.port) |port| try std.fmt.allocPrint(arena, "{s}://{s}:{d}", .{ uri.scheme, host, port }) else try std.fmt.allocPrint(arena, "{s}://{s}", .{ uri.scheme, host });
    try layout.document(ctx, "Allow access · Analytico");
    const w = ctx.w();
    const is_claude = std.ascii.findIgnoreCase(client.name, "claude") != null;
    const is_chatgpt = std.ascii.findIgnoreCase(client.name, "chatgpt") != null or std.ascii.findIgnoreCase(client.name, "openai") != null;
    // Anyone can register an app under any name; where it returns is the
    // tell. The native app is Analytico itself, so it shows just the logo.
    if (app) {
        try render(w, "<main class=\"login\"><div class=\"login-card login-card-wide\"><div class=\"row gap-12\"><img src=\"{logo}\" width=\"36\" height=\"36\" alt=\"\"></div>", .{ .logo = assets.path("favicon.svg") });
    } else {
        try render(w,
            \\<main class="login"><div class="login-card login-card-wide"><div class="row gap-12"><span class="mark" style="background:{color}">{letter}
        , .{ .color = if (is_claude) "#C96442" else if (is_chatgpt) "#000" else "#6F625D", .letter = if (is_claude) "C" else if (is_chatgpt) "" else "A" });
        if (is_chatgpt) try layout.icon(w, "chatgpt");
        try render(w,
            \\</span><span class="muted">→</span><img src="{logo}" width="36" height="36" alt=""></div>
        , .{ .logo = assets.path("favicon.svg") });
    }
    if (app) {
        try render(w,
            \\<h1>Sign in to the Analytico app on {device}</h1><p class="secondary">Signed in as {email}. The app shows the reports you see here and can add chart notes. It can’t change settings.</p><p class="hint">After you allow it, you go back to the app. Sign it out any time in Settings → Sign-in.</p><form method="post" action="/oauth/authorize" class="form-grid mt-20" data-native>
        , .{ .device = deviceName(params), .email = user.email });
    } else try render(w,
        \\<h1>{client} wants to read your analytics</h1><p class="secondary">Signed in as {email}. Read-only — it can’t change settings or see visitors.</p><p class="hint">After you allow it, you go back to <strong>{host}</strong>.</p><form method="post" action="/oauth/authorize" class="form-grid mt-20" data-native>
    , .{ .client = client.name, .email = user.email, .host = host });
    const keep = [_][]const u8{ "client_id", "redirect_uri", "state", "code_challenge", "code_challenge_method", "response_type", "scope", "resource", "device_name" };
    for (keep) |key| if (params.get(key)) |value| try render(w, "<input type=\"hidden\" name=\"{key}\" value=\"{value}\">", .{ .key = key, .value = value });
    try w.writeAll("<div class=\"card consent-sites\"><div class=\"menu-label flush-left\">Websites it can read</div><label class=\"check consent-all\"><input type=\"checkbox\" name=\"all\" value=\"1\" checked><span><strong class=\"strong\">All websites</strong> <span class=\"hint\">including ones you add later</span></span></label><div class=\"consent-picks\">");
    for (sites) |site| try render(w, "<label class=\"check consent-pick\"><input type=\"checkbox\" name=\"site\" value=\"{id}\" checked>{title} <span class=\"hint\">{host}</span></label>", .{ .id = site.id, .title = site.title(), .host = site.host() });
    try w.writeAll("</div>");
    if (app) {
        try w.writeAll("</div><div class=\"row end\"><button class=\"btn\" name=\"decision\" value=\"deny\">Cancel</button><button class=\"btn btn-primary\" name=\"decision\" value=\"allow\">Sign in</button></div></form></div></main></body></html>");
        return ctx.html();
    }
    const paths = try ai.sharePaths(arena, ctx.db);
    const sources = try ai.shareSources(arena, ctx.db);
    try w.print("</div><p class=\"hint\">It sees aggregated numbers{s}{s}. Never IP addresses, session IDs or raw events. Disconnect any time in Settings → AI.</p>", .{ if (paths) ", page paths" else "", if (sources) ", referrers and campaign names" else "" });
    try w.writeAll("<div class=\"row end\"><button class=\"btn\" name=\"decision\" value=\"deny\">Cancel</button><button class=\"btn btn-primary\" name=\"decision\" value=\"allow\">Allow read access</button></div></form></div></main></body></html>");
    return ctx.html();
}

/// The name an app gives its device ("MacBook Pro"), shown in Settings.
fn deviceName(params: html.Params) []const u8 {
    const name = std.mem.trim(u8, params.get("device_name") orelse "", " ");
    @import("../domain.zig").validateText(name, 60, false) catch return "Unnamed device";
    return if (name.len == 0) "Unnamed device" else name;
}

fn base64url(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out = try arena.alloc(u8, encoder.calcSize(bytes.len));
    return encoder.encode(out, bytes);
}

const Device = struct { id: ?[]const u8, name: ?[]const u8 };

fn issueTokens(ctx: *Ctx, db: anytype, client_id: []const u8, user_id: i64, sites: []const u8, device: Device) !void {
    const access = try auth.newToken(ctx.shared.io);
    const refresh = try auth.newToken(ctx.shared.io);
    const now = ctx.now();
    try db.run(ctx.arena, "INSERT INTO oauth_grants(token_hash,kind,client_id,user_id,sites,expires_at_ms,created_at_ms,device_id,device_name) VALUES(?,'access',?,?,?,?,?,?,?)", .{ &auth.hashToken(&access), client_id, user_id, sites, now + access_ms, now, device.id, device.name });
    try db.run(ctx.arena, "INSERT INTO oauth_grants(token_hash,kind,client_id,user_id,sites,expires_at_ms,created_at_ms,device_id,device_name) VALUES(?,'refresh',?,?,?,?,?,?,?)", .{ &auth.hashToken(&refresh), client_id, user_id, sites, now + refresh_ms, now, device.id, device.name });
    try ctx.header("cache-control", "no-store");
    try std.json.Stringify.value(.{ .access_token = &access, .token_type = "Bearer", .expires_in = access_ms / 1000, .refresh_token = &refresh, .scope = if (isApp(client_id)) "app:read app:notes" else "analytics:read" }, .{}, ctx.w());
}

fn optionalText(arena: std.mem.Allocator, statement: anytype, index: usize) !?[]const u8 {
    if (statement.columnType(index) == db_mod.sqlite.SQLITE_NULL) return null;
    return try arena.dupe(u8, statement.columnText(index));
}

fn token(ctx: *Ctx) !void {
    const arena = ctx.arena;
    const form = ctx.form() catch return oauthError(ctx, .bad_request, "invalid_request", "Expected a form body.");
    const grant_type = form.get("grant_type") orelse "";
    const client_id = form.get("client_id") orelse "";
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    const now = ctx.now();
    if (is(grant_type, "authorization_code")) {
        const code = form.get("code") orelse "";
        const hashed = auth.hashToken(code);
        var statement = try db.prepare(arena, "SELECT client_id,user_id,sites,redirect_uri,code_challenge,device_id,device_name FROM oauth_grants WHERE token_hash=? AND kind='code' AND expires_at_ms>?");
        defer statement.deinit();
        try statement.bindText(1, &hashed);
        try statement.bindInt(2, now);
        if (try statement.step() != .row) return oauthError(ctx, .bad_request, "invalid_grant", "The code is invalid or expired.");
        const grant_client = try arena.dupe(u8, statement.columnText(0));
        const user_id = statement.columnInt(1);
        const sites = try arena.dupe(u8, statement.columnText(2));
        const redirect_uri = try arena.dupe(u8, statement.columnText(3));
        const challenge = try arena.dupe(u8, statement.columnText(4));
        const device: Device = .{ .id = try optionalText(arena, &statement, 5), .name = try optionalText(arena, &statement, 6) };
        // Codes are single-use whatever happens next.
        try db.run(arena, "DELETE FROM oauth_grants WHERE token_hash=?", .{&hashed});
        if (!is(grant_client, client_id) or !is(redirect_uri, form.get("redirect_uri") orelse "")) return oauthError(ctx, .bad_request, "invalid_grant", "Client or redirect URI mismatch.");
        const verifier = form.get("code_verifier") orelse "";
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
        if (verifier.len < 43 or !is(try base64url(arena, &digest), challenge)) return oauthError(ctx, .bad_request, "invalid_grant", "PKCE verification failed.");
        try issueTokens(ctx, db, client_id, user_id, sites, device);
        return ctx.json();
    }
    if (is(grant_type, "refresh_token")) {
        const refresh = form.get("refresh_token") orelse "";
        const hashed = auth.hashToken(refresh);
        var statement = try db.prepare(arena, "SELECT client_id,user_id,sites,device_id,device_name FROM oauth_grants WHERE token_hash=? AND kind='refresh' AND expires_at_ms>?");
        defer statement.deinit();
        try statement.bindText(1, &hashed);
        try statement.bindInt(2, now);
        if (try statement.step() != .row) return oauthError(ctx, .bad_request, "invalid_grant", "The refresh token is invalid or expired.");
        const grant_client = try arena.dupe(u8, statement.columnText(0));
        const user_id = statement.columnInt(1);
        const sites = try arena.dupe(u8, statement.columnText(2));
        const device: Device = .{ .id = try optionalText(arena, &statement, 3), .name = try optionalText(arena, &statement, 4) };
        if (client_id.len != 0 and !is(grant_client, client_id)) return oauthError(ctx, .bad_request, "invalid_grant", "Client mismatch.");
        try db.run(arena, "DELETE FROM oauth_grants WHERE token_hash=?", .{&hashed});
        try db.run(arena, "DELETE FROM oauth_grants WHERE expires_at_ms<?", .{now});
        try issueTokens(ctx, db, grant_client, user_id, sites, device);
        return ctx.json();
    }
    return oauthError(ctx, .bad_request, "unsupported_grant_type", "Use authorization_code or refresh_token.");
}

// ---------------------------------------------------------------- MCP

const Grant = struct { client_name: []const u8, sites: []const u8 };

fn bearer(ctx: *Ctx) !?Grant {
    const header = ctx.head.authorization;
    if (!std.ascii.startsWithIgnoreCase(header, "bearer ")) return null;
    const value = std.mem.trim(u8, header[7..], " ");
    const hashed = auth.hashToken(value);
    var statement = try ctx.db.prepare(ctx.arena, "SELECT c.name,g.sites,u.id,u.email,u.role,u.all_sites FROM oauth_grants g JOIN oauth_clients c ON c.client_id=g.client_id JOIN users u ON u.id=g.user_id WHERE g.token_hash=? AND g.kind='access' AND g.expires_at_ms>? AND g.client_id NOT LIKE 'analytico-%'");
    defer statement.deinit();
    try statement.bindText(1, &hashed);
    try statement.bindInt(2, ctx.now());
    if (try statement.step() != .row) return null;
    // The connection reads with the access of the person who allowed it.
    ctx.user = .{
        .id = statement.columnInt(2),
        .email = try ctx.arena.dupe(u8, statement.columnText(3)),
        .role = std.meta.stringToEnum(ctx_mod.Role, statement.columnText(4)) orelse return null,
        .all_sites = statement.columnBool(5),
    };
    return .{ .client_name = try ctx.arena.dupe(u8, statement.columnText(0)), .sites = try ctx.arena.dupe(u8, statement.columnText(1)) };
}

/// A native app's access token: who signed in, which sites, which device.
pub const AppGrant = struct { sites: []const u8, device_id: []const u8 };

pub fn appBearer(ctx: *Ctx) !?AppGrant {
    const header = ctx.head.authorization;
    if (!std.ascii.startsWithIgnoreCase(header, "bearer ")) return null;
    const hashed = auth.hashToken(std.mem.trim(u8, header[7..], " "));
    var statement = try ctx.db.prepare(ctx.arena, "SELECT g.sites,g.device_id,u.id,u.email,u.role,u.all_sites FROM oauth_grants g JOIN users u ON u.id=g.user_id WHERE g.token_hash=? AND g.kind='access' AND g.expires_at_ms>? AND g.client_id LIKE 'analytico-%' AND g.device_id IS NOT NULL");
    defer statement.deinit();
    try statement.bindText(1, &hashed);
    try statement.bindInt(2, ctx.now());
    if (try statement.step() != .row) return null;
    // The app reads with the access of the person who signed in.
    ctx.user = .{
        .id = statement.columnInt(2),
        .email = try ctx.arena.dupe(u8, statement.columnText(3)),
        .role = std.meta.stringToEnum(ctx_mod.Role, statement.columnText(4)) orelse return null,
        .all_sites = statement.columnBool(5),
    };
    return .{ .sites = try ctx.arena.dupe(u8, statement.columnText(0)), .device_id = try ctx.arena.dupe(u8, statement.columnText(1)) };
}

/// Whether a grant's site list ("*" or "3,7") includes a site.
pub fn grantAllows(sites: []const u8, site_id: i64) bool {
    if (std.mem.eql(u8, sites, "*")) return true;
    var parts = std.mem.splitScalar(u8, sites, ',');
    while (parts.next()) |part| if ((std.fmt.parseInt(i64, part, 10) catch continue) == site_id) return true;
    return false;
}

fn rpcError(ctx: *Ctx, id: ?std.json.Value, code: i64, message: []const u8) !void {
    try std.json.Stringify.value(.{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } }, .{}, ctx.w());
    return ctx.json();
}

/// list_sites and site_overview, then every report in the catalog.
fn toolList(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\[{"name":"list_sites","title":"List websites","description":"Websites this connection may read, with their slugs.","inputSchema":{"type":"object","properties":{}},"annotations":{"readOnlyHint":true}},
        \\{"name":"site_overview","title":"Website overview","description":"A summary of a website for a period in one call: totals vs the previous period, daily series, top pages, sources, devices, campaigns, events and goals.","inputSchema":{"type":"object","properties":{"site":{"type":"string","description":"Site slug from list_sites"},"range":{"type":"string","enum":["24h","7d","30d","90d"],"default":"7d"},"from":{"type":"string","description":"Custom start date YYYY-MM-DD (with to)"},"to":{"type":"string","description":"Custom end date YYYY-MM-DD, inclusive"},"filters":{"type":"array","items":{"type":"string"},"description":"Optional filters like source:google, page:/pricing, device:mobile, campaign:spring"}},"required":["site"]},"annotations":{"readOnlyHint":true}}
    );
    for (&catalog.reports) |*report| {
        try w.writeAll(",{\"name\":");
        try std.json.Stringify.value(report.name, .{}, w);
        try w.writeAll(",\"title\":");
        try std.json.Stringify.value(report.title, .{}, w);
        try w.writeAll(",\"description\":");
        try std.json.Stringify.value(report.description, .{}, w);
        try w.writeAll(",\"inputSchema\":");
        try catalog.schema(w, report, true);
        try w.writeAll(",\"annotations\":{\"readOnlyHint\":true}}");
    }
    try w.writeByte(']');
}

fn mcp(ctx: *Ctx) !void {
    const arena = ctx.arena;
    const grant = try bearer(ctx) orelse {
        ctx.status = .unauthorized;
        try ctx.header("www-authenticate", try std.fmt.allocPrint(arena, "Bearer resource_metadata=\"{s}/.well-known/oauth-protected-resource\"", .{try ctx.publicOrigin()}));
        try ctx.w().writeAll("{\"error\":\"invalid_token\"}");
        return ctx.json();
    };
    const body = ctx.bodyBytes() catch return rpcError(ctx, null, -32700, "Body too large");
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return rpcError(ctx, null, -32700, "Parse error");
    if (parsed != .object) return rpcError(ctx, null, -32600, "Invalid request");
    const method_value = parsed.object.get("method") orelse return rpcError(ctx, null, -32600, "Invalid request");
    if (method_value != .string) return rpcError(ctx, null, -32600, "Invalid request");
    const method = method_value.string;
    const id = parsed.object.get("id");
    if (id == null) {
        // Notifications get no body.
        ctx.status = .accepted;
        return ctx.finish("application/json");
    }
    const params: ?std.json.ObjectMap = if (parsed.object.get("params")) |value| if (value == .object) value.object else null else null;
    const w = ctx.w();
    if (is(method, "initialize")) {
        var version: []const u8 = protocol_versions[0];
        if (params) |object| if (object.get("protocolVersion")) |requested| if (requested == .string) {
            for (protocol_versions) |supported| if (is(supported, requested.string)) {
                version = supported;
            };
        };
        try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try std.json.Stringify.value(id.?, .{}, w);
        try w.print(",\"result\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"analytico\",\"title\":\"Analytico\",\"version\":\"1.0\"}},\"instructions\":\"Read-only, privacy-first web analytics. Call list_sites first, then site_overview for a period. Visitor-days count unique visitors per day; only consented Full-mode visitors are remembered across days, and no personal data is ever shared. Times are UTC.\"}}}}", .{version});
        return ctx.json();
    }
    if (is(method, "ping")) {
        try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try std.json.Stringify.value(id.?, .{}, w);
        try w.writeAll(",\"result\":{}}");
        return ctx.json();
    }
    if (is(method, "tools/list")) {
        try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try std.json.Stringify.value(id.?, .{}, w);
        try w.writeAll(",\"result\":{\"tools\":");
        try toolList(w);
        try w.writeAll("}}");
        return ctx.json();
    }
    if (!is(method, "tools/call")) return rpcError(ctx, id, -32601, "Method not found");
    const object = params orelse return rpcError(ctx, id, -32602, "Missing params");
    const name_value = object.get("name") orelse return rpcError(ctx, id, -32602, "Missing tool name");
    if (name_value != .string) return rpcError(ctx, id, -32602, "Invalid tool name");
    const arguments: std.json.ObjectMap = if (object.get("arguments")) |value| if (value == .object) value.object else .empty else .empty;
    const result = runTool(ctx, grant, name_value.string, arguments) catch |err| switch (err) {
        error.UnknownTool => return rpcError(ctx, id, -32602, "Unknown tool"),
        error.UnknownSite => return toolResult(ctx, id.?, "Unknown or unauthorised site. Call list_sites for the slugs this connection may read.", true),
        else => return err,
    };
    {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        var arguments_text: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(std.json.Value{ .object = arguments }, .{}, &arguments_text.writer);
        _ = try ai.log(arena, db, ctx.now(), .{ .origin = grant.client_name, .site_id = result.site_id, .question = try std.fmt.allocPrint(arena, "{s} {s}", .{ name_value.string, arguments_text.written() }), .data_used = result.used, .model = "your plan", .payload = result.text, .answer = "" });
        try db.run(arena, "UPDATE oauth_grants SET last_used_at_ms=? WHERE token_hash=?", .{ ctx.now(), &auth.hashToken(std.mem.trim(u8, ctx.head.authorization[7..], " ")) });
    }
    return toolResult(ctx, id.?, result.text, false);
}

fn toolResult(ctx: *Ctx, id: std.json.Value, text: []const u8, is_error: bool) !void {
    try std.json.Stringify.value(.{ .jsonrpc = "2.0", .id = id, .result = .{ .content = &[_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = text }}, .isError = is_error } }, .{}, ctx.w());
    return ctx.json();
}

const ToolOutput = struct { text: []const u8, used: []const u8, site_id: ?i64 };

const argString = agent.argString;

/// The website a tool call names, if this connection may read it.
fn toolSite(ctx: *Ctx, grant: Grant, arguments: std.json.ObjectMap) !data.Site {
    const site = try data.siteBySlug(ctx.arena, ctx.db, argString(arguments, "site") orelse return error.UnknownSite) orelse return error.UnknownSite;
    var allowed = std.mem.eql(u8, grant.sites, "*");
    var ids = std.mem.splitScalar(u8, grant.sites, ',');
    while (ids.next()) |value| if ((std.fmt.parseInt(i64, value, 10) catch -1) == site.id) {
        allowed = true;
    };
    if (!allowed or !try ctx.canSee(site.id)) return error.UnknownSite;
    return site;
}

fn runTool(ctx: *Ctx, grant: Grant, name: []const u8, arguments: std.json.ObjectMap) !ToolOutput {
    const arena = ctx.arena;
    const paths = try ai.sharePaths(arena, ctx.db);
    const sources = try ai.shareSources(arena, ctx.db);
    if (is(name, "list_sites")) {
        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.writeAll("slug | name | host | mode\n");
        var ids = std.mem.splitScalar(u8, grant.sites, ',');
        const sites = try ctx.visibleSites();
        if (std.mem.eql(u8, grant.sites, "*")) {
            for (sites) |site| try out.writer.print("{s} | {s} | {s} | {s}\n", .{ site.slug, site.title(), site.host(), @tagName(site.mode) });
        } else while (ids.next()) |value| {
            const id = std.fmt.parseInt(i64, value, 10) catch continue;
            for (sites) |site| if (site.id == id) try out.writer.print("{s} | {s} | {s} | {s}\n", .{ site.slug, site.title(), site.host(), @tagName(site.mode) });
        }
        return .{ .text = out.written(), .used = "Website list", .site_id = null };
    }
    if (!is(name, "site_overview") and catalog.find(name) == null) return error.UnknownTool;
    const site = try toolSite(ctx, grant, arguments);
    const output = try agent.tool(arena, ctx.db, site, name, arguments, paths, sources, ctx.now());
    return .{ .text = output.text, .used = output.used, .site_id = site.id };
}
