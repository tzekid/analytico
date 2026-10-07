//! Sign in with ChatGPT for plan usage: each person runs Analytico's AI on
//! their own ChatGPT plan, through OpenAI's program for open-source apps.
//! Each person's first sign-in registers a client for them
//! (`dynamic_agent_client`); the issued client is kept for later sign-ins.
//!
//! OpenAI only redirects to `http://127.0.0.1:<port>/auth/callback`. A
//! temporary loopback listener completes the sign-in when the browser runs
//! on this machine (or through an SSH tunnel); otherwise the person pastes
//! the address the browser could not open. Either way the code is useless
//! without the PKCE verifier, which never leaves the server.
const std = @import("std");
const net = @import("../net.zig");
const server = @import("../server.zig");
const auth = @import("auth.zig");
const ctx_mod = @import("ctx.zig");
const data = @import("data.zig");
const db_mod = @import("../db.zig");
const html = @import("html.zig");
const layout = @import("layout.zig");
const oidc = @import("oidc.zig");
const secret = @import("secret.zig");

const Ctx = ctx_mod.Ctx;
const Shared = ctx_mod.Shared;
const esc = html.esc;
const render = html.render;
const icon = layout.icon;

const resource = "https://api.openai.com/v1";
const scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";
const plan_scope = "chatgpt.tokens.use.direct";
const dynamic_client = "dynamic_agent_client";
const attempt_ms = 10 * 60_000;
pub const usage_url = "https://chatgpt.com/settings/usage";

const nowMs = @import("../domain.zig").nowMs;

/// OpenAI's addresses; tests point them at stand-ins.
fn issuer(arena: std.mem.Allocator, db: *db_mod.Db) ![]const u8 {
    return (try data.setting(arena, db, .@"chatgpt.auth_origin")) orelse "https://auth.openai.com";
}

pub fn apiBase(arena: std.mem.Allocator, db: *db_mod.Db) ![]const u8 {
    return (try data.setting(arena, db, .@"chatgpt.api_base")) orelse "https://api.openai.com/v1";
}

pub const Tokens = struct { access: []const u8, refresh: []const u8, id_token: []const u8, expires_ms: i64 };

pub const Account = struct {
    client_id: []const u8,
    subject: []const u8,
    email: []const u8,
    model: []const u8,
    /// "slug<TAB>name" lines, as listed for the plan.
    models: []const u8,
    background: bool,
    welcomed: bool,
    /// Null after signing out; the issued client stays for the next sign-in.
    tokens: ?Tokens,

    /// The chosen model, or the plan's first one.
    pub fn activeModel(self: Account) []const u8 {
        if (self.model.len != 0) return self.model;
        const line = self.models[0 .. std.mem.findScalar(u8, self.models, '\n') orelse self.models.len];
        return line[0 .. std.mem.findScalar(u8, line, '\t') orelse line.len];
    }
};

pub fn account(arena: std.mem.Allocator, db: *db_mod.Db, master: [32]u8, user_id: i64) !?Account {
    const Row = struct { client_id: []const u8, subject: []const u8, email: []const u8, model: []const u8, models: []const u8, background: bool, welcomed: bool, tokens: ?[]const u8 };
    const row = try db.one(arena, Row, "SELECT client_id,subject,email,model,models,background,welcomed,tokens FROM chatgpt_accounts WHERE user_id=?", .{user_id}) orelse return null;
    var tokens: ?Tokens = null;
    if (row.tokens) |sealed| {
        const plain = try secret.open(arena, master, sealed);
        tokens = try std.json.parseFromSliceLeaky(Tokens, arena, plain, .{});
    }
    return .{ .client_id = row.client_id, .subject = row.subject, .email = row.email, .model = row.model, .models = row.models, .background = row.background, .welcomed = row.welcomed, .tokens = tokens };
}

fn seal(arena: std.mem.Allocator, io: std.Io, master: [32]u8, tokens: Tokens) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(tokens, .{}, &out.writer);
    return secret.seal(arena, io, master, out.written());
}

// ---------------------------------------------------------------- sign-in

/// Why a sign-in did not complete; shown on Settings → AI.
pub const Problem = enum {
    expired,
    denied,
    rejected,
    unverified,
    no_plan,
    offline,

    pub fn text(self: Problem) []const u8 {
        return switch (self) {
            .expired => "That sign-in expired or was already used. Start again with Continue with ChatGPT.",
            .denied => "ChatGPT didn’t grant access.",
            .rejected => "OpenAI rejected the sign-in. Start again with Continue with ChatGPT.",
            .unverified => "OpenAI’s answer couldn’t be verified, so nothing was saved.",
            .no_plan => "This ChatGPT account can’t share its plan with other apps.",
            .offline => "Couldn’t reach OpenAI from this server. Check its network and try again.",
        };
    }
};

fn problemOf(err: anyerror) ?Problem {
    return switch (err) {
        error.Expired => .expired,
        error.Denied => .denied,
        error.Rejected => .rejected,
        error.InvalidIdToken => .unverified,
        error.NoPlan => .no_plan,
        error.ProviderUnreachable, error.ProviderDiscoveryFailed, error.Unreachable => .offline,
        else => null,
    };
}

/// GET /settings/ai/chatgpt/start: a new attempt, then OpenAI's consent page.
fn start(ctx: *Ctx) !void {
    const arena = ctx.arena;
    const user_id = ctx.user.?.id;
    const existing = try account(arena, ctx.db, ctx.shared.master_key, user_id);
    // "Use another account" needs a new registration: a client belongs to one ChatGPT account.
    const client_id = if (existing != null and ctx.param("another") == null) existing.?.client_id else dynamic_client;
    ctx.extendDeadline(30);
    const discovery = oidc.discover(arena, try issuer(arena, ctx.db)) catch return back(ctx, .offline);
    const port = try loopback(ctx.shared);
    const redirect_uri = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/auth/callback", .{port});
    const state = try auth.newToken(ctx.shared.io);
    const nonce = try auth.newToken(ctx.shared.io);
    var verifier_bytes: [32]u8 = undefined;
    try ctx.shared.io.randomSecure(&verifier_bytes);
    var verifier: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&verifier, &verifier_bytes);
    var host_id: []const u8 = undefined;
    {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        // One Analytico instance is one agent host.
        host_id = try data.setting(arena, db, .@"chatgpt.host_id") orelse id: {
            var bytes: [16]u8 = undefined;
            try ctx.shared.io.randomSecure(&bytes);
            bytes[6] = (bytes[6] & 0x0f) | 0x40;
            bytes[8] = (bytes[8] & 0x3f) | 0x80;
            const hex = std.fmt.bytesToHex(bytes, .lower);
            const value = try std.fmt.allocPrint(arena, "urn:uuid:{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
            try data.putSetting(arena, db, .@"chatgpt.host_id", value);
            break :id value;
        };
        const state_hash = auth.hashToken(&state);
        try db.run(arena, "INSERT INTO auth_challenges(id,purpose,challenge,verifier,user_id,provider,intent,expires_at_ms) VALUES(?,'oidc',?,?,?,'chatgpt',?,?)", .{ &state_hash, &nonce, &verifier, user_id, try std.fmt.allocPrint(arena, "{s} {s}", .{ client_id, redirect_uri }), ctx.now() + attempt_ms });
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&verifier, &digest, .{});
    var challenge: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&challenge, &digest);
    var url: std.Io.Writer.Allocating = .init(arena);
    const w = &url.writer;
    try w.print("{s}{s}response_type=code&client_id=", .{ discovery.authorization_endpoint, if (std.mem.findScalar(u8, discovery.authorization_endpoint, '?') == null) "?" else "&" });
    try net.formPart(w, client_id);
    try w.writeAll("&redirect_uri=");
    try net.formPart(w, redirect_uri);
    try w.writeAll("&scope=");
    try net.formPart(w, scopes);
    try w.writeAll("&resource=");
    try net.formPart(w, resource);
    try w.print("&state={s}&nonce={s}&code_challenge={s}&code_challenge_method=S256", .{ &state, &nonce, &challenge });
    if (std.mem.eql(u8, client_id, dynamic_client)) {
        try w.writeAll("&agent_name_hint=Analytico&ext_agent_host_id=");
        try net.formPart(w, host_id);
    }
    return ctx.redirect(url.written());
}

/// Finishes an attempt from the callback's query: by the loopback listener
/// (no session; the state proves the attempt) or pasted by its owner.
fn complete(shared: *Shared, arena: std.mem.Allocator, owner: ?i64, query: html.Params) !void {
    const now = nowMs();
    const state = query.get("state") orelse return error.Expired;
    if (state.len != 64) return error.Expired;
    const state_hash = auth.hashToken(state);
    const Attempt = struct { nonce: []const u8, verifier: []const u8, user_id: i64, intent: []const u8 };
    const attempt = blk: {
        const db = shared.lockWrite();
        defer shared.unlockWrite();
        break :blk try db.one(arena, Attempt, "DELETE FROM auth_challenges WHERE id=? AND purpose='oidc' AND provider='chatgpt' AND expires_at_ms>? AND (?3 IS NULL OR user_id=?3) RETURNING challenge,verifier,user_id,intent", .{ &state_hash, now, owner });
    } orelse return error.Expired;
    if (query.get("error") != null) return error.Denied;
    const code = query.get("code") orelse return error.Denied;
    const split = std.mem.findScalar(u8, attempt.intent, ' ') orelse return error.Expired;
    const redirect_uri = attempt.intent[split + 1 ..];
    var client_id = attempt.intent[0..split];
    const returned = query.get("client_id") orelse "";
    if (std.mem.eql(u8, client_id, dynamic_client)) {
        // A new registration: the callback carries the issued client.
        if (returned.len == 0 or std.mem.eql(u8, returned, dynamic_client)) return error.Rejected;
        client_id = returned;
    } else if (returned.len != 0 and !std.mem.eql(u8, returned, client_id)) return error.Rejected;

    const read = blk: {
        const db = shared.lockWrite();
        defer shared.unlockWrite();
        break :blk .{ try issuer(arena, db), try apiBase(arena, db), try account(arena, db, shared.master_key, attempt.user_id) };
    };
    const discovery = try oidc.discover(arena, read[0]);
    var form: std.Io.Writer.Allocating = .init(arena);
    try form.writer.writeAll("grant_type=authorization_code&client_id=");
    try net.formPart(&form.writer, client_id);
    try form.writer.writeAll("&code=");
    try net.formPart(&form.writer, code);
    try form.writer.writeAll("&code_verifier=");
    try net.formPart(&form.writer, attempt.verifier);
    try form.writer.writeAll("&redirect_uri=");
    try net.formPart(&form.writer, redirect_uri);
    try form.writer.writeAll("&resource=");
    try net.formPart(&form.writer, resource);
    const response = try net.send(arena, discovery.token_endpoint, .{ .method = .POST, .body = form.written(), .content_type = "application/x-www-form-urlencoded" });
    if (response.status != .ok) {
        std.log.warn("chatgpt_token_rejected status={d}", .{@backingInt(response.status)});
        return error.Rejected;
    }
    const body = net.parseObject(arena, response.body) orelse return error.Rejected;
    const id_token = net.string(body, "id_token");
    try oidc.verifySignature(arena, discovery.jwks_uri, id_token);
    const identity = try oidc.claims(arena, id_token, discovery.issuer, client_id, attempt.nonce, now);
    if (!hasScope(net.string(body, "scope"), plan_scope)) return error.NoPlan;
    const tokens: Tokens = .{
        .access = net.string(body, "access_token"),
        .refresh = net.string(body, "refresh_token"),
        .id_token = id_token,
        .expires_ms = now + std.math.clamp(net.int(body, "expires_in"), 60, 86_400) * 1000,
    };
    if (tokens.access.len == 0 or tokens.refresh.len == 0) return error.Rejected;
    const models = try listModels(arena, read[1], tokens.access);
    const previous = read[2];
    {
        const db = shared.lockWrite();
        defer shared.unlockWrite();
        try db.run(arena,
            \\INSERT INTO chatgpt_accounts(user_id,client_id,subject,email,tokens,models,created_at_ms,updated_at_ms) VALUES(?1,?2,?3,?4,?5,?6,?7,?7)
            \\ON CONFLICT(user_id) DO UPDATE SET client_id=excluded.client_id,email=excluded.email,tokens=excluded.tokens,models=excluded.models,
            \\  model=CASE WHEN subject=excluded.subject THEN model ELSE '' END,subject=excluded.subject,updated_at_ms=excluded.updated_at_ms
        , .{ attempt.user_id, client_id, identity.subject, identity.email, try seal(arena, shared.io, shared.master_key, tokens), models, now });
    }
    // Signing in again replaces the previous session; let it go at OpenAI too.
    if (previous) |old| if (old.tokens) |old_tokens| if (!std.mem.eql(u8, old_tokens.refresh, tokens.refresh)) revoke(arena, discovery, old.client_id, old_tokens.refresh);
}

fn hasScope(granted: []const u8, wanted: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, granted, ' ');
    while (it.next()) |scope| if (std.mem.eql(u8, scope, wanted)) return true;
    return false;
}

/// The plan's models, as "slug<TAB>name" lines.
fn listModels(arena: std.mem.Allocator, api: []const u8, access: []const u8) ![]const u8 {
    const response = try net.send(arena, try std.fmt.allocPrint(arena, "{s}/models", .{api}), .{ .headers = &.{.{ .name = "authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{access}) }} });
    if (response.status != .ok) return error.Rejected;
    const body = net.parseObject(arena, response.body) orelse return error.Rejected;
    var out: std.Io.Writer.Allocating = .init(arena);
    for (net.array(body, "models")) |item| {
        if (item != .object or !std.mem.eql(u8, net.string(item.object, "visibility"), "list")) continue;
        const slug = net.string(item.object, "slug");
        const name = net.string(item.object, "display_name");
        if (slug.len == 0 or std.mem.findAny(u8, slug, "\t\n") != null or std.mem.findAny(u8, name, "\t\n") != null) continue;
        try out.writer.print("{s}\t{s}\n", .{ slug, if (name.len == 0) slug else name });
    }
    return out.written();
}

fn revoke(arena: std.mem.Allocator, discovery: oidc.Discovery, client_id: []const u8, refresh: []const u8) void {
    if (discovery.revocation_endpoint.len == 0) return;
    var form: std.Io.Writer.Allocating = .init(arena);
    form.writer.writeAll("token_type_hint=refresh_token&token=") catch return;
    net.formPart(&form.writer, refresh) catch return;
    form.writer.writeAll("&client_id=") catch return;
    net.formPart(&form.writer, client_id) catch return;
    const response = net.send(arena, discovery.revocation_endpoint, .{ .method = .POST, .body = form.written(), .content_type = "application/x-www-form-urlencoded" }) catch return;
    if (response.status != .ok) std.log.warn("chatgpt_revoke_failed status={d}", .{@backingInt(response.status)});
}

// ---------------------------------------------------------------- tokens

/// Refresh tokens rotate: two refreshes racing would sign the person out.
var refresh_lock: std.Io.Mutex = .init;

/// A current access token for this person, refreshed near expiry.
pub fn accessToken(arena: std.mem.Allocator, shared: *Shared, db: *db_mod.Db, user_id: i64) ![]const u8 {
    const now = nowMs();
    const current = try account(arena, db, shared.master_key, user_id) orelse return error.AiNotConfigured;
    const tokens = current.tokens orelse return error.AiSignInAgain;
    if (tokens.expires_ms > now + 2 * 60_000) return tokens.access;
    refresh_lock.lockUncancelable(shared.io);
    defer refresh_lock.unlock(shared.io);
    // Another request may have refreshed while this one waited.
    const read = blk: {
        const write = shared.lockWrite();
        defer shared.unlockWrite();
        break :blk .{ try account(arena, write, shared.master_key, user_id), try issuer(arena, write), try apiBase(arena, write) };
    };
    const latest = read[0] orelse return error.AiNotConfigured;
    const old = latest.tokens orelse return error.AiSignInAgain;
    if (old.expires_ms > now + 2 * 60_000) return old.access;
    const discovery = oidc.discover(arena, read[1]) catch return error.AiUnreachable;
    var form: std.Io.Writer.Allocating = .init(arena);
    try form.writer.writeAll("grant_type=refresh_token&client_id=");
    try net.formPart(&form.writer, latest.client_id);
    try form.writer.writeAll("&refresh_token=");
    try net.formPart(&form.writer, old.refresh);
    try form.writer.writeAll("&resource=");
    try net.formPart(&form.writer, resource);
    const response = net.send(arena, discovery.token_endpoint, .{ .method = .POST, .body = form.written(), .content_type = "application/x-www-form-urlencoded" }) catch return error.AiUnreachable;
    const body = net.parseObject(arena, response.body);
    if (response.status != .ok) {
        const code = if (body) |object| net.string(object, "error") else "";
        std.log.warn("chatgpt_refresh_failed status={d} code={s}", .{ @backingInt(response.status), code });
        if (response.status.class() == .server_error) return error.AiUnreachable;
        // The grant is gone (expired, revoked or reused): sign in again.
        const write = shared.lockWrite();
        defer shared.unlockWrite();
        try write.run(arena, "UPDATE chatgpt_accounts SET tokens=NULL,updated_at_ms=? WHERE user_id=?", .{ now, user_id });
        return error.AiSignInAgain;
    }
    const object = body orelse return error.AiUnreachable;
    const fresh: Tokens = .{
        .access = net.string(object, "access_token"),
        .refresh = if (net.string(object, "refresh_token").len != 0) net.string(object, "refresh_token") else old.refresh,
        .id_token = if (net.string(object, "id_token").len != 0) net.string(object, "id_token") else old.id_token,
        .expires_ms = now + std.math.clamp(net.int(object, "expires_in"), 60, 86_400) * 1000,
    };
    if (fresh.access.len == 0) return error.AiUnreachable;
    // The model list changes rarely; picking it up hourly is plenty.
    const models = listModels(arena, read[2], fresh.access) catch latest.models;
    const write = shared.lockWrite();
    defer shared.unlockWrite();
    try write.run(arena, "UPDATE chatgpt_accounts SET tokens=?,models=?,updated_at_ms=? WHERE user_id=?", .{ try seal(arena, shared.io, shared.master_key, fresh), models, now, user_id });
    return fresh.access;
}

// ---------------------------------------------------------------- loopback listener

var listener_lock: std.Io.Mutex = .init;
var listener_port: u16 = 0;
var listener_until_ms: i64 = 0;

/// The loopback port waiting for OpenAI's redirect: 1455 when free, as
/// OpenAI's own tools use, otherwise any. One listener serves every attempt
/// and stops ten minutes after the last one started.
fn loopback(shared: *Shared) !u16 {
    const io = shared.io;
    listener_lock.lockUncancelable(io);
    defer listener_lock.unlock(io);
    listener_until_ms = nowMs() + attempt_ms;
    if (listener_port != 0) return listener_port;
    var listener = (std.Io.net.IpAddress.parse("127.0.0.1", 1455) catch unreachable).listen(io, .{ .reuse_address = true }) catch
        try (std.Io.net.IpAddress.parse("127.0.0.1", 0) catch unreachable).listen(io, .{});
    errdefer listener.deinit(io);
    const port = listener.socket.address.getPort();
    const thread = try std.Thread.spawn(.{}, serveLoopback, .{ shared, listener });
    thread.detach();
    listener_port = port;
    return port;
}

fn serveLoopback(shared: *Shared, listener_value: std.Io.net.Server) void {
    var listener = listener_value;
    const io = shared.io;
    while (true) {
        var fds = [_]std.posix.pollfd{.{ .fd = listener.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.c.poll(&fds, 1, 1000);
        {
            listener_lock.lockUncancelable(io);
            defer listener_lock.unlock(io);
            if (nowMs() > listener_until_ms) {
                listener.deinit(io);
                listener_port = 0;
                return;
            }
        }
        if (ready <= 0) continue;
        const stream = listener.accept(io) catch continue;
        defer stream.close(io);
        callback(shared, stream) catch |err| std.log.warn("chatgpt_callback_failed code={s}", .{@errorName(err)});
    }
}

fn callback(shared: *Shared, stream: std.Io.net.Stream) !void {
    var arena_state = std.heap.ArenaAllocator.init(shared.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var read_buffer: [8 * 1024]u8 = undefined;
    var write_buffer: [4 * 1024]u8 = undefined;
    var connection = server.Connection.init(shared.io, stream, &read_buffer, &write_buffer);
    connection.deadline = .fromNow(shared.io, .{ .raw = .fromSeconds(30), .clock = .awake });
    var http = std.http.Server.init(&connection.reader, &connection.writer);
    var request = try http.receiveHead();
    const target = try arena.dupe(u8, request.head.target);
    const query_start = std.mem.findScalar(u8, target, '?') orelse target.len;
    if (request.head.method != .GET or !std.mem.eql(u8, target[0..query_start], "/auth/callback")) {
        return request.respond("not found\n", .{ .status = .not_found, .keep_alive = false });
    }
    const query = html.Params.parse(arena, if (query_start < target.len) target[query_start + 1 ..] else "") catch html.Params{};
    const outcome: ?Problem = if (complete(shared, arena, null, query)) null else |err| problemOf(err) orelse return err;
    const origin = blk: {
        const db = shared.lockWrite();
        defer shared.unlockWrite();
        break :blk try data.setting(arena, db, .public_origin);
    };
    if (origin) |value| {
        const location = try std.fmt.allocPrint(arena, "{s}/settings/ai?chatgpt={s}", .{ value, if (outcome) |problem| @tagName(problem) else "connected" });
        return request.respond("", .{ .status = .see_other, .keep_alive = false, .extra_headers = &.{.{ .name = "location", .value = location }} });
    }
    return request.respond(if (outcome) |problem| problem.text() else "Signed in to ChatGPT. You can close this tab.", .{ .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }} });
}

// ---------------------------------------------------------------- routes

/// /settings/ai/chatgpt/...: everyone manages their own plan.
pub fn route(ctx: *Ctx, action: []const u8) !void {
    const is = struct {
        fn f(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.f;
    if (ctx.method == .GET) {
        if (is(action, "start")) return start(ctx);
        if (is(action, "status.json")) {
            const current = try account(ctx.arena, ctx.db, ctx.shared.master_key, ctx.user.?.id);
            try ctx.w().print("{{\"connected\":{}}}", .{current != null and current.?.tokens != null});
            return ctx.json();
        }
        return layout.message(ctx, .not_found, "Nothing here", "");
    }
    const arena = ctx.arena;
    const user_id = ctx.user.?.id;
    if (is(action, "paste")) {
        // The whole address from the browser's bar, or just its query.
        const address = std.mem.trim(u8, try ctx.field("address"), " \n\r\t");
        const query_text = if (std.mem.findScalar(u8, address, '?')) |index| address[index + 1 ..] else address;
        const query = html.Params.parse(arena, query_text) catch html.Params{};
        ctx.extendDeadline(60);
        complete(ctx.shared, arena, user_id, query) catch |err| return back(ctx, problemOf(err) orelse return err);
        return ctx.redirect("/settings/ai?chatgpt=connected");
    }
    const db = ctx.shared.lockWrite();
    if (is(action, "welcomed")) {
        defer ctx.shared.unlockWrite();
        try db.run(arena, "UPDATE chatgpt_accounts SET welcomed=1 WHERE user_id=?", .{user_id});
        return ctx.redirect("/settings/ai");
    }
    if (is(action, "options")) {
        defer ctx.shared.unlockWrite();
        const current = try account(arena, db, ctx.shared.master_key, user_id) orelse return ctx.redirect("/settings/ai");
        const model = try ctx.field("model");
        if (model.len != 0 and !listed(current.models, model)) return ctx.done("!That model isn’t available on your plan.", "/settings/ai", .{});
        // Only admins' plans may run alerts and scheduled emails.
        const background = ctx.can(.admin) and (try ctx.field("background")).len != 0;
        try db.run(arena, "UPDATE chatgpt_accounts SET model=?,background=?,updated_at_ms=? WHERE user_id=?", .{ model, background, ctx.now(), user_id });
        return ctx.done("Saved.", "/settings/ai", .{});
    }
    if (is(action, "sign-out")) {
        const current = try account(arena, db, ctx.shared.master_key, user_id);
        const auth_issuer = try issuer(arena, db);
        try db.run(arena, "UPDATE chatgpt_accounts SET tokens=NULL,background=0,updated_at_ms=? WHERE user_id=?", .{ ctx.now(), user_id });
        ctx.shared.unlockWrite();
        if (current) |value| if (value.tokens) |tokens| {
            ctx.extendDeadline(30);
            if (oidc.discover(arena, auth_issuer)) |discovery| revoke(arena, discovery, value.client_id, tokens.refresh) else |_| {}
        };
        return ctx.done("Signed out of ChatGPT. AI features use the instance’s API key, if there is one.", "/settings/ai", .{});
    }
    ctx.shared.unlockWrite();
    return layout.message(ctx, .not_found, "Nothing here", "");
}

fn listed(models: []const u8, slug: []const u8) bool {
    var lines = std.mem.tokenizeScalar(u8, models, '\n');
    while (lines.next()) |line| if (std.mem.eql(u8, line[0 .. std.mem.findScalar(u8, line, '\t') orelse line.len], slug)) return true;
    return false;
}

fn back(ctx: *Ctx, problem: Problem) !void {
    return ctx.redirectFmt("/settings/ai?chatgpt={s}", .{@tagName(problem)});
}

// ---------------------------------------------------------------- Settings → AI

/// The person's own ChatGPT plan, at the top of Settings → AI.
pub fn card(ctx: *Ctx) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    const current = try account(arena, ctx.db, ctx.shared.master_key, ctx.user.?.id);
    if (ctx.param("chatgpt")) |outcome| if (std.meta.stringToEnum(Problem, outcome)) |problem| {
        try render(w, "<div class=\"callout callout-warn mb-16\"><span>{problem}</span></div>", .{ .problem = problem.text() });
    };
    try w.writeAll("<section class=\"card mb-16\"><div class=\"row-between top\"><div class=\"row nowrap gap-12\"><span class=\"mark mark-chatgpt\">");
    try icon(w, "chatgpt");
    try w.writeAll("</span><div>");
    if (current == null or current.?.tokens == null) {
        try w.writeAll(
            \\<strong class="t-15">Use your ChatGPT plan</strong><div class="hint">Ask and Why? run on your own ChatGPT plan, within its usage limits — no API key. Only you use it.</div></div></div>
            \\<div class="row nowrap"><a class="btn btn-chatgpt" href="/settings/ai/chatgpt/start" target="_blank" data-chatgpt-start>
        );
        try icon(w, "chatgpt");
        try w.writeAll("Continue with ChatGPT</a></div></div>");
        if (current != null) try w.writeAll("<p class=\"hint mt-10\"><a class=\"link\" href=\"/settings/ai/chatgpt/start?another=1\" target=\"_blank\" data-chatgpt-start>Use another ChatGPT account</a></p>");
        try w.writeAll("</section>");
        return waitingDialog(w);
    }
    const value = current.?;
    try render(w,
        \\<strong class="t-15">Using ChatGPT plan</strong><div class="hint">{email} · Ask and Why? use your plan’s usage limits</div></div></div><div class="row nowrap"><a class="btn" href="{usage}" target="_blank" rel="noopener">Manage usage ↗</a><form method="post" action="/settings/ai/chatgpt/sign-out" data-confirm="Sign out of ChatGPT? Analytico forgets its tokens and asks OpenAI to revoke them."><button class="btn">Sign out</button></form></div></div>
        \\<form class="row mt-14 gap-16" method="post" action="/settings/ai/chatgpt/options"><label class="row nowrap"><span class="secondary">Model</span><select class="input" name="model" data-autosubmit aria-label="Model">
    , .{ .email = if (value.email.len != 0) value.email else "Signed in", .usage = usage_url });
    var lines = std.mem.tokenizeScalar(u8, value.models, '\n');
    const active = value.activeModel();
    while (lines.next()) |line| {
        const tab = std.mem.findScalar(u8, line, '\t') orelse continue;
        try render(w, "<option value=\"{slug}\"{!selected}>{name}</option>", .{ .slug = line[0..tab], .selected = if (std.mem.eql(u8, line[0..tab], active)) " selected" else "", .name = line[tab + 1 ..] });
    }
    try w.writeAll("</select></label>");
    if (ctx.can(.admin)) try render(w, "<label class=\"row nowrap\"><input type=\"checkbox\" name=\"background\" value=\"1\" data-autosubmit{!checked}><span>Use my plan for alerts and scheduled emails when there’s no API key</span></label>", .{ .checked = if (value.background) " checked" else "" });
    try w.writeAll("</form></section>");
    if (!value.welcomed) {
        try w.writeAll("<dialog class=\"dialog\" data-open><form method=\"post\" action=\"/settings/ai/chatgpt/welcomed\"><div class=\"dialog-head\"><div><span class=\"mark mark-chatgpt mb-10\">");
        try icon(w, "chatgpt");
        try w.writeAll(
            \\</span><h2>You’re using your ChatGPT plan</h2><p>Ask and Why? in Analytico now run on your ChatGPT plan and count toward its usage limits. Only aggregated numbers are sent, as set under “What the AI can see”.</p></div></div><div class="dialog-foot"><button class="btn btn-primary">Got it</button></div></form></dialog>
        );
    }
}

fn waitingDialog(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\<dialog class="dialog" id="chatgpt-dialog" data-chatgpt-status="/settings/ai/chatgpt/status.json"><div class="dialog-head"><div><h2>Continue in the new tab</h2><p>Approve Analytico in ChatGPT. This window finishes by itself when ChatGPT returns here.</p></div><button class="btn btn-quiet btn-icon close" type="button" data-close aria-label="Close">×</button></div>
        \\<form class="dialog-body" method="post" action="/settings/ai/chatgpt/paste" data-busy="Signing in…"><p class="hint ink-2">Analytico runs on another computer? After you approve, the tab stops at a page that can’t be reached (its address starts with <code>http://127.0.0.1</code>). Copy that address and paste it here.</p><div class="row nowrap"><input class="input mono" name="address" placeholder="http://127.0.0.1:1455/auth/callback?code=…" autocomplete="off" required aria-label="Address from the tab"><button class="btn" type="button" data-paste-address>Paste</button><button class="btn btn-primary">Continue</button></div></form></dialog>
    );
}
