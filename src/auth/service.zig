const std = @import("std");
const passkeys = @import("passkeys.zig");
const store_mod = @import("store.zig");

const Allocator = std.mem.Allocator;

pub const default_bootstrap_seconds: u32 = 10 * 60;
pub const max_bootstrap_seconds: u32 = 60 * 60;
pub const challenge_seconds: i64 = 5 * 60;
pub const session_seconds: i64 = 12 * 60 * 60;
pub const max_label_bytes: usize = 64;

pub const Context = struct {
    io: std.Io,
    allocator: Allocator,
    store: store_mod.Store,
    origin: []const u8,
    rp_id: []const u8,
};

pub const Status = struct {
    configured: bool,
    credential_count: i64,
    active_session_count: i64,
    bootstrap_active: bool,
};

pub const Bootstrap = struct {
    setup_url: []u8,
    expires_at: i64,

    pub fn deinit(self: Bootstrap, allocator: Allocator) void {
        allocator.free(self.setup_url);
    }
};

pub const Session = struct {
    token: []u8,
    csrf_token: []u8,
    user_id: []u8,
    expires_at: i64,

    pub fn deinit(self: Session, allocator: Allocator) void {
        secureFree(allocator, self.token);
        secureFree(allocator, self.csrf_token);
        allocator.free(self.user_id);
    }
};

pub const RegistrationFinish = struct {
    challenge_id: []const u8,
    bootstrap_token: ?[]const u8 = null,
    session_token: ?[]const u8 = null,
    attestation_object: []const u8,
    client_data_json: []const u8,
    transports: []const u8 = "",
    label: []const u8 = "Passkey",
};

pub const AuthenticationFinish = struct {
    challenge_id: []const u8,
    credential_id: []const u8,
    authenticator_data: []const u8,
    client_data_json: []const u8,
    signature: []const u8,
};

pub const DerivedPolicy = struct {
    origin: []u8,
    rp_id: []u8,

    pub fn deinit(self: DerivedPolicy, allocator: Allocator) void {
        allocator.free(self.origin);
        allocator.free(self.rp_id);
    }
};

pub fn derivePolicy(allocator: Allocator, raw_origin: []const u8) !DerivedPolicy {
    if (raw_origin.len == 0 or raw_origin.len > 255 or
        std.mem.endsWith(u8, raw_origin, "/"))
    {
        return error.InvalidAuthPolicy;
    }
    const uri = std.Uri.parse(raw_origin) catch return error.InvalidAuthPolicy;
    if (uri.host == null or uri.user != null or uri.password != null or
        uri.query != null or uri.fragment != null or !uri.path.isEmpty())
    {
        return error.InvalidAuthPolicy;
    }
    const secure = std.mem.eql(u8, uri.scheme, "https");
    const local_http = std.mem.eql(u8, uri.scheme, "http");
    if (!secure and !local_http) return error.InvalidAuthPolicy;

    var host_buffer: [256]u8 = undefined;
    const raw_host = uri.host.?.toRaw(&host_buffer) catch
        return error.InvalidAuthPolicy;
    if (raw_host.len == 0 or raw_host.len > 253) return error.InvalidAuthPolicy;
    const rp_id = try allocator.dupe(u8, raw_host);
    errdefer allocator.free(rp_id);
    for (rp_id) |*byte| {
        byte.* = std.ascii.toLower(byte.*);
        if (!std.ascii.isLower(byte.*) and !std.ascii.isDigit(byte.*) and
            byte.* != '-' and byte.* != '.')
        {
            return error.InvalidAuthPolicy;
        }
    }
    if (std.mem.startsWith(u8, rp_id, ".") or
        std.mem.endsWith(u8, rp_id, ".") or
        std.mem.indexOf(u8, rp_id, "..") != null)
    {
        return error.InvalidAuthPolicy;
    }
    if (!secure and !std.mem.eql(u8, rp_id, "localhost") and
        !std.mem.eql(u8, rp_id, "127.0.0.1"))
    {
        return error.InsecureAuthOrigin;
    }

    var origin = std.Io.Writer.Allocating.init(allocator);
    errdefer origin.deinit();
    try origin.writer.print("{s}://{s}", .{ uri.scheme, rp_id });
    if (uri.port) |port| {
        const default = (secure and port == 443) or (!secure and port == 80);
        if (!default) try origin.writer.print(":{d}", .{port});
    }
    return .{ .origin = try origin.toOwnedSlice(), .rp_id = rp_id };
}

pub fn validatePolicy(origin: []const u8, rp_id: []const u8) !void {
    const policy = try derivePolicy(std.heap.page_allocator, origin);
    defer policy.deinit(std.heap.page_allocator);
    if (!std.mem.eql(u8, policy.origin, origin) or
        !std.mem.eql(u8, policy.rp_id, rp_id))
    {
        return error.InvalidAuthPolicy;
    }
}

pub fn status(ctx: Context) !Status {
    try validatePolicy(ctx.origin, ctx.rp_id);
    const now = try nowSeconds();
    const credential_count = try ctx.store.activeCredentialCount();
    return .{
        .configured = credential_count > 0,
        .credential_count = credential_count,
        .active_session_count = try ctx.store.activeSessionCount(now),
        .bootstrap_active = try ctx.store.bootstrapActive(now),
    };
}

pub fn createBootstrap(ctx: Context, ttl_seconds: u32) !Bootstrap {
    try validatePolicy(ctx.origin, ctx.rp_id);
    if (ttl_seconds == 0 or ttl_seconds > max_bootstrap_seconds) {
        return error.InvalidBootstrapTtl;
    }
    if (try ctx.store.activeCredentialCount() != 0) {
        return error.AuthAlreadyConfigured;
    }
    const now = try nowSeconds();
    const token = try randomToken(ctx.io, ctx.allocator);
    defer secureFree(ctx.allocator, token);
    const token_hash = hashToken(token);
    const expires_at = now + ttl_seconds;
    try ctx.store.putBootstrap(&token_hash, now, expires_at);
    return .{
        .setup_url = try std.fmt.allocPrint(
            ctx.allocator,
            "{s}/admin/setup#token={s}",
            .{ ctx.origin, token },
        ),
        .expires_at = expires_at,
    };
}

pub fn writeSetupOptions(
    ctx: Context,
    bootstrap_token: []const u8,
    writer: *std.Io.Writer,
) !void {
    const now = try nowSeconds();
    const bootstrap_hash = hashToken(bootstrap_token);
    if (!try ctx.store.bootstrapMatches(&bootstrap_hash, now)) {
        return error.InvalidBootstrap;
    }
    if (try ctx.store.activeCredentialCount() != 0) {
        return error.AuthAlreadyConfigured;
    }
    const user_id = try randomToken(ctx.io, ctx.allocator);
    defer ctx.allocator.free(user_id);
    try writeRegistrationOptions(
        ctx,
        "setup",
        user_id,
        &bootstrap_hash,
        writer,
    );
}

pub fn writeAdditionalRegistrationOptions(
    ctx: Context,
    user_id: []const u8,
    session_token: []const u8,
    writer: *std.Io.Writer,
) !void {
    const session_hash = hashToken(session_token);
    try writeRegistrationOptions(ctx, "register", user_id, &session_hash, writer);
}

pub fn writeLoginOptions(ctx: Context, writer: *std.Io.Writer) !void {
    if (try ctx.store.activeCredentialCount() == 0) {
        return error.AuthNotConfigured;
    }
    const now = try nowSeconds();
    const challenge_id = try randomToken(ctx.io, ctx.allocator);
    defer ctx.allocator.free(challenge_id);
    const challenge = try randomToken(ctx.io, ctx.allocator);
    defer ctx.allocator.free(challenge);
    try ctx.store.putChallenge(
        challenge_id,
        "login",
        challenge,
        "",
        "",
        now,
        now + challenge_seconds,
    );
    try writer.writeAll("{\"challenge_id\":");
    try writeJsonString(writer, challenge_id);
    try writer.writeAll(",\"publicKey\":{\"challenge\":");
    try writeJsonString(writer, challenge);
    try writer.writeAll(",\"rpId\":");
    try writeJsonString(writer, ctx.rp_id);
    try writer.writeAll(
        ",\"timeout\":300000,\"userVerification\":\"required\"," ++
            "\"allowCredentials\":[]}}\n",
    );
}

pub fn finishRegistration(
    ctx: Context,
    input: RegistrationFinish,
) !?Session {
    try validateLabel(input.label);
    try validateTransports(input.transports);
    const now = try nowSeconds();
    const challenge = (try ctx.store.findChallenge(
        ctx.allocator,
        input.challenge_id,
    )) orelse return error.InvalidChallenge;
    defer challenge.deinit(ctx.allocator);
    const setup = std.mem.eql(u8, challenge.purpose, "setup");
    if (!setup and !std.mem.eql(u8, challenge.purpose, "register")) {
        return error.InvalidChallenge;
    }
    if (challenge.used_at != null or challenge.expires_at <= now) {
        return error.InvalidChallenge;
    }

    var bootstrap_hash: [64]u8 = undefined;
    if (setup) {
        if (input.session_token != null) return error.InvalidChallenge;
        const token = input.bootstrap_token orelse return error.InvalidBootstrap;
        bootstrap_hash = hashToken(token);
        if (!constantTimeEqual(challenge.binding_hash, &bootstrap_hash) or
            !try ctx.store.bootstrapMatches(&bootstrap_hash, now))
        {
            return error.InvalidBootstrap;
        }
    } else {
        if (input.bootstrap_token != null) return error.InvalidBootstrap;
        const token = input.session_token orelse return error.InvalidChallenge;
        const session_hash = hashToken(token);
        if (!constantTimeEqual(challenge.binding_hash, &session_hash)) {
            return error.InvalidChallenge;
        }
    }

    if (!try ctx.store.consumeChallenge(
        input.challenge_id,
        challenge.purpose,
        now,
    )) return error.InvalidChallenge;

    const verified = passkeys.verifyRegistration(ctx.allocator, .{
        .attestation_object = input.attestation_object,
        .client_data_json = input.client_data_json,
        .expected_challenge = challenge.challenge,
        .expected_origin = ctx.origin,
        .rp_id = ctx.rp_id,
    }) catch return error.InvalidPasskeyResponse;
    defer verified.deinit(ctx.allocator);

    if (setup) {
        if (try ctx.store.activeCredentialCount() != 0 or
            !try ctx.store.consumeBootstrap(&bootstrap_hash, now))
        {
            return error.InvalidBootstrap;
        }
        try ctx.store.ensureOwner(challenge.user_id, "Analytico owner", now);
    }
    ctx.store.insertCredential(.{
        .credential_id = @constCast(verified.credential_id),
        .user_id = challenge.user_id,
        .public_key = @constCast(verified.public_key),
        .algorithm = verified.algorithm,
        .sign_count = verified.sign_count,
        .transports = @constCast(input.transports),
        .aaguid = @constCast(verified.aaguid),
        .backup_eligible = verified.backup_eligible,
        .backup_state = verified.backup_state,
        .label = @constCast(input.label),
        .created_at = now,
        .last_used_at = null,
        .revoked_at = null,
    }) catch return error.CredentialAlreadyRegistered;

    return if (setup) try issueSession(ctx, challenge.user_id, now) else null;
}

pub fn finishAuthentication(
    ctx: Context,
    input: AuthenticationFinish,
) !Session {
    const now = try nowSeconds();
    const challenge = (try ctx.store.findChallenge(
        ctx.allocator,
        input.challenge_id,
    )) orelse return error.InvalidChallenge;
    defer challenge.deinit(ctx.allocator);
    if (!std.mem.eql(u8, challenge.purpose, "login") or
        challenge.used_at != null or challenge.expires_at <= now)
    {
        return error.InvalidChallenge;
    }
    if (!try ctx.store.consumeChallenge(input.challenge_id, "login", now)) {
        return error.InvalidChallenge;
    }
    const credential = (try ctx.store.findCredential(
        ctx.allocator,
        input.credential_id,
    )) orelse return error.InvalidPasskeyResponse;
    defer credential.deinit(ctx.allocator);
    if (credential.revoked_at != null) return error.InvalidPasskeyResponse;

    const verified = passkeys.verifyAuthentication(ctx.allocator, .{
        .authenticator_data = input.authenticator_data,
        .client_data_json = input.client_data_json,
        .signature = input.signature,
        .public_key = credential.public_key,
        .expected_challenge = challenge.challenge,
        .expected_origin = ctx.origin,
        .rp_id = ctx.rp_id,
        .known_sign_count = credential.sign_count,
    }) catch return error.InvalidPasskeyResponse;
    try ctx.store.updateCredentialUse(
        credential.credential_id,
        verified.recommended_sign_count,
        verified.backup_state,
        now,
    );
    if (verified.sign_count_regressed) {
        std.debug.print(
            "{{\"level\":\"warning\",\"code\":\"passkey_counter_regressed\"}}\n",
            .{},
        );
    }
    return issueSession(ctx, credential.user_id, now);
}

pub fn validateSession(ctx: Context, raw_token: []const u8) !?Session {
    if (raw_token.len < 32 or raw_token.len > 128) return null;
    const now = try nowSeconds();
    const token_hash = hashToken(raw_token);
    const stored = (try ctx.store.findSession(
        ctx.allocator,
        &token_hash,
    )) orelse return null;
    defer stored.deinit(ctx.allocator);
    if (stored.revoked_at != null or stored.expires_at <= now) return null;
    try ctx.store.touchSession(&token_hash, now);
    return .{
        .token = try ctx.allocator.dupe(u8, raw_token),
        .csrf_token = try ctx.allocator.dupe(u8, stored.csrf_token),
        .user_id = try ctx.allocator.dupe(u8, stored.user_id),
        .expires_at = stored.expires_at,
    };
}

pub fn revokeSession(ctx: Context, raw_token: []const u8) !void {
    const token_hash = hashToken(raw_token);
    _ = try ctx.store.revokeSession(&token_hash, try nowSeconds());
}

pub fn updateCredentialLabel(
    ctx: Context,
    credential_id: []const u8,
    label: []const u8,
) !void {
    try validateLabel(label);
    if (!try ctx.store.updateCredentialLabel(credential_id, label)) {
        return error.CredentialNotFound;
    }
}

pub fn revokeCredential(ctx: Context, credential_id: []const u8) !void {
    if (try ctx.store.activeCredentialCount() <= 1) return error.LastCredential;
    if (!try ctx.store.revokeCredential(credential_id, try nowSeconds())) {
        return error.CredentialNotFound;
    }
}

pub fn revokeOtherSession(
    ctx: Context,
    current_raw_token: []const u8,
    selected_hash: []const u8,
) !void {
    if (selected_hash.len != 64) return error.SessionNotFound;
    const current_hash = hashToken(current_raw_token);
    if (constantTimeEqual(&current_hash, selected_hash)) {
        return error.CannotRevokeCurrentSessionHere;
    }
    if (!try ctx.store.revokeSession(selected_hash, try nowSeconds())) {
        return error.SessionNotFound;
    }
}

pub fn reset(ctx: Context) !void {
    try ctx.store.reset();
}

fn writeRegistrationOptions(
    ctx: Context,
    purpose: []const u8,
    user_id: []const u8,
    binding_hash: []const u8,
    writer: *std.Io.Writer,
) !void {
    const now = try nowSeconds();
    const challenge_id = try randomToken(ctx.io, ctx.allocator);
    defer ctx.allocator.free(challenge_id);
    const challenge = try randomToken(ctx.io, ctx.allocator);
    defer ctx.allocator.free(challenge);
    try ctx.store.putChallenge(
        challenge_id,
        purpose,
        challenge,
        user_id,
        binding_hash,
        now,
        now + challenge_seconds,
    );
    const credentials = try ctx.store.listCredentials(ctx.allocator);
    defer {
        for (credentials) |item| item.deinit(ctx.allocator);
        ctx.allocator.free(credentials);
    }

    try writer.writeAll("{\"challenge_id\":");
    try writeJsonString(writer, challenge_id);
    try writer.writeAll(",\"publicKey\":{\"challenge\":");
    try writeJsonString(writer, challenge);
    try writer.writeAll(",\"rp\":{\"name\":\"Analytico\",\"id\":");
    try writeJsonString(writer, ctx.rp_id);
    try writer.writeAll("},\"user\":{\"id\":");
    try writeJsonString(writer, user_id);
    try writer.writeAll(
        ",\"name\":\"owner\",\"displayName\":\"Analytico owner\"}," ++
            "\"pubKeyCredParams\":[{\"type\":\"public-key\",\"alg\":-7}," ++
            "{\"type\":\"public-key\",\"alg\":-257}],\"timeout\":300000," ++
            "\"attestation\":\"none\",\"authenticatorSelection\":{" ++
            "\"residentKey\":\"required\",\"requireResidentKey\":true," ++
            "\"userVerification\":\"required\"},\"excludeCredentials\":[",
    );
    var first = true;
    for (credentials) |credential| {
        if (credential.revoked_at != null) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.writeAll("{\"type\":\"public-key\",\"id\":");
        try writeJsonString(writer, credential.credential_id);
        try writer.writeAll(",\"transports\":");
        try writeTransportsArray(writer, credential.transports);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}}\n");
}

fn issueSession(ctx: Context, user_id: []const u8, now: i64) !Session {
    const token = try randomToken(ctx.io, ctx.allocator);
    errdefer secureFree(ctx.allocator, token);
    const csrf_token = try randomToken(ctx.io, ctx.allocator);
    errdefer secureFree(ctx.allocator, csrf_token);
    const token_hash = hashToken(token);
    const expires_at = now + session_seconds;
    try ctx.store.putSession(
        &token_hash,
        user_id,
        csrf_token,
        now,
        expires_at,
    );
    return .{
        .token = token,
        .csrf_token = csrf_token,
        .user_id = try ctx.allocator.dupe(u8, user_id),
        .expires_at = expires_at,
    };
}

pub fn randomToken(io: std.Io, allocator: Allocator) ![]u8 {
    var bytes: [32]u8 = undefined;
    try io.randomSecure(&bytes);
    defer std.crypto.secureZero(u8, &bytes);
    const size = std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len);
    const encoded = try allocator.alloc(u8, size);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, &bytes);
    return encoded;
}

pub fn hashToken(token: []const u8) [64]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn constantTimeEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    var difference: u8 = 0;
    for (left, right) |a, b| difference |= a ^ b;
    return difference == 0;
}

pub fn validateLabel(label: []const u8) !void {
    if (label.len == 0 or label.len > max_label_bytes or
        !std.unicode.utf8ValidateSlice(label))
    {
        return error.InvalidCredentialLabel;
    }
    for (label) |byte| {
        if (byte < 0x20 or byte == 0x7f) return error.InvalidCredentialLabel;
    }
}

fn validateTransports(value: []const u8) !void {
    if (value.len > 128) return error.InvalidTransports;
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (!std.mem.eql(u8, part, "internal") and
            !std.mem.eql(u8, part, "hybrid") and
            !std.mem.eql(u8, part, "usb") and
            !std.mem.eql(u8, part, "nfc") and
            !std.mem.eql(u8, part, "ble"))
        {
            return error.InvalidTransports;
        }
    }
}

fn writeTransportsArray(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('[');
    var first = true;
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writeJsonString(writer, part);
    }
    try writer.writeByte(']');
}

pub fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20)
            try writer.print("\\u00{x:0>2}", .{byte})
        else
            try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

pub fn nowSeconds() !i64 {
    var timestamp: std.os.linux.timespec = undefined;
    const result = std.os.linux.clock_gettime(.REALTIME, &timestamp);
    if (std.os.linux.errno(result) != .SUCCESS or timestamp.sec < 0) {
        return error.ClockUnavailable;
    }
    return timestamp.sec;
}

fn secureFree(allocator: Allocator, value: []u8) void {
    std.crypto.secureZero(u8, value);
    allocator.free(value);
}
