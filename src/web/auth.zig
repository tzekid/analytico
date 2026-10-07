//! Operator accounts: sessions, one-time links, password hashing and sign-in
//! rate limits. Tokens are random 256-bit values; only their SHA-256 is stored.
//! The sign-in screens and ceremonies live in signin.zig.
const std = @import("std");
const ctx_mod = @import("ctx.zig");
const data = @import("data.zig");
const db_mod = @import("../db.zig");

const Ctx = ctx_mod.Ctx;

pub const session_cookie = "an_s";
const session_days = 30;
const invite_days = 7;
pub const setup_ms = 60 * 60_000;
const failure_window_ms = 15 * 60_000;
const failure_limit = 10;

pub fn newToken(io: std.Io) ![64]u8 {
    var bytes: [32]u8 = undefined;
    try io.randomSecure(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

pub fn hashToken(token: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn validEmail(email: []const u8) bool {
    if (email.len < 3 or email.len > 254) return false;
    const at = std.mem.findScalar(u8, email, '@') orelse return false;
    if (at == 0 or at + 1 >= email.len or std.mem.findScalar(u8, email[at + 1 ..], '.') == null) return false;
    for (email) |byte| if (byte <= 0x20 or byte == 0x7f or byte == '<' or byte == '>' or byte == ',' or byte == '"') return false;
    return true;
}

pub fn normalizeEmail(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    return std.ascii.allocLowerString(arena, std.mem.trim(u8, raw, " "));
}

/// Creates the user when needed and a fresh one-time invite. Returns the token.
pub fn createInvite(arena: std.mem.Allocator, io: std.Io, db: *db_mod.Db, email_raw: []const u8, now_ms: i64) ![64]u8 {
    const email = try normalizeEmail(arena, email_raw);
    if (!validEmail(email)) return error.InvalidEmail;
    // The first person on an instance without an owner (invited from the CLI) becomes the owner.
    try db.run(arena, "INSERT INTO users(email,role,created_at_ms) VALUES(?,CASE WHEN EXISTS(SELECT 1 FROM users WHERE role='owner') THEN 'admin' ELSE 'owner' END,?) ON CONFLICT(email) DO NOTHING", .{ email, now_ms });
    const user_id = try db.scalar(arena, i64, "SELECT id FROM users WHERE email=?", .{email});
    const token = try newToken(io);
    const hashed = hashToken(&token);
    try db.run(arena, "DELETE FROM user_invites WHERE user_id=? OR expires_at_ms<?", .{ user_id, now_ms });
    try db.run(arena, "INSERT INTO user_invites(token_hash,user_id,expires_at_ms) VALUES(?,?,?)", .{ &hashed, user_id, now_ms + invite_days * data.day_ms });
    return token;
}

/// A one-hour link that lets the first person create the owner account.
pub fn createSetupLink(arena: std.mem.Allocator, io: std.Io, db: *db_mod.Db, now_ms: i64) ![64]u8 {
    const token = try newToken(io);
    const hashed = hashToken(&token);
    try db.run(arena, "DELETE FROM setup_links WHERE expires_at_ms<?", .{now_ms});
    try db.run(arena, "INSERT INTO setup_links(token_hash,expires_at_ms) VALUES(?,?)", .{ &hashed, now_ms + setup_ms });
    return token;
}

pub fn setupLinkValid(ctx: *Ctx, token: []const u8) !bool {
    if (token.len != 64) return false;
    const hashed = hashToken(token);
    return try ctx.db.scalar(ctx.arena, i64, "SELECT count(*) FROM setup_links WHERE token_hash=? AND expires_at_ms>?", .{ &hashed, ctx.now() }) == 1;
}

/// SQL: user `u` has some way in (password, passkey or a linked account).
pub const joined_sql = "(u.password_hash IS NOT NULL OR EXISTS(SELECT 1 FROM passkeys p WHERE p.user_id=u.id) OR EXISTS(SELECT 1 FROM identities x WHERE x.user_id=u.id))";

pub const Invite = struct { user_id: i64, email: []const u8, joined: bool };

pub fn findInvite(ctx: *Ctx, token: []const u8) !?Invite {
    if (token.len != 64) return null;
    const hashed = hashToken(token);
    var statement = try ctx.db.prepare(ctx.arena, "SELECT u.id,u.email," ++ joined_sql ++ " FROM user_invites i JOIN users u ON u.id=i.user_id WHERE i.token_hash=? AND i.expires_at_ms>?");
    defer statement.deinit();
    try statement.bindText(1, &hashed);
    try statement.bindInt(2, ctx.now());
    if (try statement.step() != .row) return null;
    return .{ .user_id = statement.columnInt(0), .email = try ctx.arena.dupe(u8, statement.columnText(1)), .joined = statement.columnBool(2) };
}

pub fn currentUser(ctx: *Ctx) !?ctx_mod.User {
    const token = ctx.cookie(session_cookie) orelse return null;
    if (token.len != 64) return null;
    const hashed = hashToken(token);
    var statement = try ctx.db.prepare(ctx.arena, "SELECT u.id,u.email,u.role,u.all_sites FROM web_sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=? AND s.expires_at_ms>?");
    defer statement.deinit();
    try statement.bindText(1, &hashed);
    try statement.bindInt(2, ctx.now());
    if (try statement.step() != .row) return null;
    return .{
        .id = statement.columnInt(0),
        .email = try ctx.arena.dupe(u8, statement.columnText(1)),
        .role = std.meta.stringToEnum(ctx_mod.Role, statement.columnText(2)) orelse return error.CorruptRole,
        .all_sites = statement.columnBool(3),
    };
}

/// Starts a session on `db`, which must be the write connection.
pub fn startSession(ctx: *Ctx, db: *db_mod.Db, user_id: i64) !void {
    const token = try newToken(ctx.shared.io);
    const hashed = hashToken(&token);
    const now = ctx.now();
    try db.run(ctx.arena, "DELETE FROM web_sessions WHERE expires_at_ms<?", .{now});
    try db.run(ctx.arena, "DELETE FROM auth_challenges WHERE expires_at_ms<?", .{now});
    try db.run(ctx.arena, "INSERT INTO web_sessions(token_hash,user_id,created_at_ms,expires_at_ms) VALUES(?,?,?,?)", .{ &hashed, user_id, now, now + session_days * data.day_ms });
    try ctx.setCookie(session_cookie, try ctx.arena.dupe(u8, &token), session_days * 86_400);
}

pub fn hashPassword(ctx: *Ctx, password: []const u8) ![]const u8 {
    const buffer = try ctx.arena.alloc(u8, 128);
    return std.crypto.pwhash.argon2.strHash(password, .{
        .allocator = ctx.arena,
        .params = std.crypto.pwhash.argon2.Params.owasp_2id,
    }, buffer, ctx.shared.io);
}

pub fn passwordMatches(ctx: *Ctx, stored: []const u8, password: []const u8) bool {
    std.crypto.pwhash.argon2.strVerify(stored, password, .{ .allocator = ctx.arena }, ctx.shared.io) catch return false;
    return true;
}

/// A same-site path to return to. Browsers drop tabs and newlines from URLs and
/// read "\\" as "/", so either could turn "/x" into "//elsewhere"; CR/LF would
/// also break the Location header.
pub fn safeNext(next: []const u8) []const u8 {
    if (next.len == 0 or next[0] != '/' or (next.len > 1 and next[1] == '/')) return "/";
    for (next) |byte| if (byte < 0x20 or byte == 0x7f or byte == '\\') return "/";
    return next;
}

test safeNext {
    try std.testing.expectEqualStrings("/shop?range=30d", safeNext("/shop?range=30d"));
    for ([_][]const u8{ "", "shop", "//evil.test", "/\\evil.test", "/\t/evil.test", "/x\r\nset-cookie: a=b", "https://evil.test" }) |bad| {
        try std.testing.expectEqualStrings("/", safeNext(bad));
    }
}

fn ipHash(ip: []const u8) u64 {
    return std.hash.Wyhash.hash(0x616e616c, ip);
}

pub fn tooManyFailures(ctx: *Ctx) bool {
    const shared = ctx.shared;
    const key = ipHash(ctx.clientIp());
    const now = ctx.now();
    shared.login_lock.lockUncancelable(shared.io);
    defer shared.login_lock.unlock(shared.io);
    for (&shared.login_failures) |*entry| {
        if (entry.ip_hash == key and now - entry.window_start_ms < failure_window_ms) return entry.count >= failure_limit;
    }
    return false;
}

pub fn recordFailure(ctx: *Ctx) void {
    const shared = ctx.shared;
    const key = ipHash(ctx.clientIp());
    const now = ctx.now();
    shared.login_lock.lockUncancelable(shared.io);
    defer shared.login_lock.unlock(shared.io);
    var oldest: *@TypeOf(shared.login_failures[0]) = &shared.login_failures[0];
    for (&shared.login_failures) |*entry| {
        if (entry.ip_hash == key) {
            if (now - entry.window_start_ms >= failure_window_ms) entry.* = .{ .ip_hash = key, .count = 0, .window_start_ms = now };
            entry.count += 1;
            return;
        }
        if (entry.window_start_ms < oldest.window_start_ms) oldest = entry;
    }
    oldest.* = .{ .ip_hash = key, .count = 1, .window_start_ms = now };
}

pub fn logout(ctx: *Ctx) !void {
    if (ctx.cookie(session_cookie)) |token| {
        const hashed = hashToken(token);
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try db.run(ctx.arena, "DELETE FROM web_sessions WHERE token_hash=?", .{&hashed});
    }
    try ctx.setCookie(session_cookie, "", 0);
    return ctx.redirect("/login");
}
