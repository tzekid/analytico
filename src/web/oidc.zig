//! OpenID Connect sign-in for Google and ChatGPT: authorization code with
//! PKCE (S256) and a nonce, confidential client (client_secret_basic).
//! ID tokens are checked against the issuer's published keys (RS256), then
//! for issuer, audience, expiry and nonce.
const std = @import("std");
const net = @import("../net.zig");
const data = @import("data.zig");
const db_mod = @import("../db.zig");
const secret = @import("secret.zig");

pub const Provider = enum {
    google,
    chatgpt,

    pub fn label(self: Provider) []const u8 {
        return switch (self) {
            .google => "Google",
            .chatgpt => "ChatGPT",
        };
    }

    pub fn defaultIssuer(self: Provider) []const u8 {
        return switch (self) {
            .google => "https://accounts.google.com",
            .chatgpt => "https://auth.openai.com",
        };
    }
};

pub const Config = struct { client_id: []const u8, client_secret: []const u8, issuer: []const u8 };

pub fn load(arena: std.mem.Allocator, db: *db_mod.Db, master: [32]u8, provider: Provider) !?Config {
    const prefix = @tagName(provider);
    const client_id = try data.settingNamed(arena, db, try std.fmt.allocPrint(arena, "auth.{s}.client_id", .{prefix})) orelse return null;
    const sealed = try data.settingNamed(arena, db, try std.fmt.allocPrint(arena, "auth.{s}.secret", .{prefix})) orelse "";
    return .{
        .client_id = client_id,
        .client_secret = if (sealed.len == 0) "" else try secret.open(arena, master, sealed),
        .issuer = (try data.settingNamed(arena, db, try std.fmt.allocPrint(arena, "auth.{s}.issuer", .{prefix}))) orelse provider.defaultIssuer(),
    };
}

/// Issuers are https, except loopback hosts used for local development.
pub fn validIssuer(issuer: []const u8) bool {
    if (issuer.len > 255 or std.mem.endsWith(u8, issuer, "/")) return false;
    if (std.mem.startsWith(u8, issuer, "https://")) return issuer.len > 8;
    return std.mem.startsWith(u8, issuer, "http://localhost") or std.mem.startsWith(u8, issuer, "http://127.0.0.1");
}

pub const Discovery = struct { issuer: []const u8, authorization_endpoint: []const u8, token_endpoint: []const u8, jwks_uri: []const u8 = "", revocation_endpoint: []const u8 = "" };

fn request(arena: std.mem.Allocator, url: []const u8, payload: ?[]const u8, headers: []const std.http.Header) !net.Response {
    return net.send(arena, url, .{ .method = if (payload == null) .GET else .POST, .body = payload, .content_type = "application/x-www-form-urlencoded", .headers = headers }) catch error.ProviderUnreachable;
}

const jsonString = net.string;
const formPart = net.formPart;

pub fn discover(arena: std.mem.Allocator, issuer: []const u8) !Discovery {
    const response = try request(arena, try std.fmt.allocPrint(arena, "{s}/.well-known/openid-configuration", .{issuer}), null, &.{});
    if (response.status != .ok) return error.ProviderDiscoveryFailed;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, response.body, .{}) catch return error.ProviderDiscoveryFailed;
    if (parsed != .object) return error.ProviderDiscoveryFailed;
    const out: Discovery = .{
        .issuer = jsonString(parsed.object, "issuer"),
        .authorization_endpoint = jsonString(parsed.object, "authorization_endpoint"),
        .token_endpoint = jsonString(parsed.object, "token_endpoint"),
        .jwks_uri = jsonString(parsed.object, "jwks_uri"),
        .revocation_endpoint = jsonString(parsed.object, "revocation_endpoint"),
    };
    // The document must describe the issuer we were configured with.
    if (!std.mem.eql(u8, out.issuer, issuer) or out.authorization_endpoint.len == 0 or out.token_endpoint.len == 0 or out.jwks_uri.len == 0) return error.ProviderDiscoveryFailed;
    return out;
}

pub fn authorizationUrl(arena: std.mem.Allocator, discovery: Discovery, config: Config, redirect_uri: []const u8, state: []const u8, nonce: []const u8, verifier: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    var challenge: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&challenge, &digest);
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("{s}{s}response_type=code&scope=openid%20email%20profile&client_id=", .{ discovery.authorization_endpoint, if (std.mem.findScalar(u8, discovery.authorization_endpoint, '?') == null) "?" else "&" });
    try formPart(w, config.client_id);
    try w.writeAll("&redirect_uri=");
    try formPart(w, redirect_uri);
    try w.print("&state={s}&nonce={s}&code_challenge={s}&code_challenge_method=S256", .{ state, nonce, &challenge });
    return out.written();
}

/// `hosted_domain` is Google's `hd` claim: the verified Workspace domain.
pub const Identity = struct { subject: []const u8, email: []const u8, hosted_domain: []const u8 = "" };

/// client_secret_basic: both parts form-encoded, then base64.
fn basicAuthorization(arena: std.mem.Allocator, config: Config) ![]const u8 {
    var basic: std.Io.Writer.Allocating = .init(arena);
    try formPart(&basic.writer, config.client_id);
    try basic.writer.writeByte(':');
    try formPart(&basic.writer, config.client_secret);
    const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(basic.written().len));
    _ = std.base64.standard.Encoder.encode(encoded, basic.written());
    return std.fmt.allocPrint(arena, "Basic {s}", .{encoded});
}

/// A token endpoint call (code exchange or refresh) returning the JSON body.
pub fn tokenRequest(arena: std.mem.Allocator, token_endpoint: []const u8, config: Config, form: []const u8) !std.json.ObjectMap {
    const response = try request(arena, token_endpoint, form, &.{ .{ .name = "authorization", .value = try basicAuthorization(arena, config) }, .{ .name = "accept", .value = "application/json" } });
    if (response.status != .ok) {
        std.log.warn("oauth_token_rejected status={d}", .{@backingInt(response.status)});
        return error.ProviderRejectedCode;
    }
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, response.body, .{}) catch return error.ProviderRejectedCode;
    if (parsed != .object) return error.ProviderRejectedCode;
    return parsed.object;
}

pub fn exchange(arena: std.mem.Allocator, discovery: Discovery, config: Config, code: []const u8, redirect_uri: []const u8, verifier: []const u8, nonce: []const u8, now_ms: i64) !Identity {
    var form: std.Io.Writer.Allocating = .init(arena);
    try form.writer.writeAll("grant_type=authorization_code&code=");
    try formPart(&form.writer, code);
    try form.writer.writeAll("&redirect_uri=");
    try formPart(&form.writer, redirect_uri);
    try form.writer.writeAll("&code_verifier=");
    try formPart(&form.writer, verifier);
    const tokens = try tokenRequest(arena, discovery.token_endpoint, config, form.written());
    const id_token = jsonString(tokens, "id_token");
    try verifySignature(arena, discovery.jwks_uri, id_token);
    return claims(arena, id_token, discovery.issuer, config.client_id, nonce, now_ms);
}

/// Checks an ID token's RS256 signature against the issuer's published keys.
pub fn verifySignature(arena: std.mem.Allocator, jwks_uri: []const u8, id_token: []const u8) !void {
    var parts = std.mem.splitScalar(u8, id_token, '.');
    const head_text = parts.next() orelse return error.InvalidIdToken;
    const body_text = parts.next() orelse return error.InvalidIdToken;
    const signature_text = parts.next() orelse return error.InvalidIdToken;
    const head = net.parseObject(arena, try b64url(arena, head_text)) orelse return error.InvalidIdToken;
    if (!std.mem.eql(u8, jsonString(head, "alg"), "RS256")) return error.InvalidIdToken;
    const kid = jsonString(head, "kid");
    const response = try request(arena, jwks_uri, null, &.{});
    if (response.status != .ok) return error.ProviderUnreachable;
    const document = net.parseObject(arena, response.body) orelse return error.ProviderUnreachable;
    for (net.array(document, "keys")) |key_value| {
        if (key_value != .object) continue;
        const key = key_value.object;
        if (!std.mem.eql(u8, jsonString(key, "kty"), "RSA")) continue;
        if (kid.len != 0 and !std.mem.eql(u8, jsonString(key, "kid"), kid)) continue;
        const modulus = try b64url(arena, jsonString(key, "n"));
        const exponent = try b64url(arena, jsonString(key, "e"));
        const signature = try b64url(arena, signature_text);
        const signed = id_token[0 .. head_text.len + 1 + body_text.len];
        const rsa = std.crypto.Certificate.rsa;
        const public_key = rsa.PublicKey.fromBytes(exponent, modulus) catch return error.InvalidIdToken;
        if (signature.len != modulus.len) return error.InvalidIdToken;
        switch (modulus.len) {
            inline 256, 384, 512 => |size| rsa.PKCS1v1_5Signature.verify(size, signature[0..size], signed, public_key, std.crypto.hash.sha2.Sha256) catch return error.InvalidIdToken,
            else => return error.InvalidIdToken,
        }
        return;
    }
    return error.InvalidIdToken;
}

fn b64url(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const out = try arena.alloc(u8, decoder.calcSizeForSlice(text) catch return error.InvalidIdToken);
    decoder.decode(out, text) catch return error.InvalidIdToken;
    return out;
}

pub fn claims(arena: std.mem.Allocator, id_token: []const u8, issuer: []const u8, client_id: []const u8, nonce: []const u8, now_ms: i64) !Identity {
    var parts = std.mem.splitScalar(u8, id_token, '.');
    _ = parts.next() orelse return error.InvalidIdToken;
    const payload = parts.next() orelse return error.InvalidIdToken;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(payload) catch return error.InvalidIdToken;
    const json = try arena.alloc(u8, size);
    decoder.decode(json, payload) catch return error.InvalidIdToken;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return error.InvalidIdToken;
    if (parsed != .object) return error.InvalidIdToken;
    const object = parsed.object;
    if (!std.mem.eql(u8, jsonString(object, "iss"), issuer)) return error.InvalidIdToken;
    const audience_ok = if (object.get("aud")) |aud| switch (aud) {
        .string => |value| std.mem.eql(u8, value, client_id),
        .array => |list| blk: {
            for (list.items) |item| if (item == .string and std.mem.eql(u8, item.string, client_id)) break :blk true;
            break :blk false;
        },
        else => false,
    } else false;
    if (!audience_ok) return error.InvalidIdToken;
    const expires = if (object.get("exp")) |exp| switch (exp) {
        .integer => |value| value,
        else => 0,
    } else 0;
    if ((std.math.mul(i64, expires, 1000) catch std.math.maxInt(i64)) <= now_ms) return error.InvalidIdToken;
    if (!std.mem.eql(u8, jsonString(object, "nonce"), nonce)) return error.InvalidIdToken;
    const subject = jsonString(object, "sub");
    if (subject.len == 0 or subject.len > 255) return error.InvalidIdToken;
    // Only verified addresses are kept, and only to label the link.
    const verified = if (object.get("email_verified")) |value| value == .bool and value.bool else false;
    return .{ .subject = subject, .email = if (verified) jsonString(object, "email") else "", .hosted_domain = if (verified) jsonString(object, "hd") else "" };
}

test "id token claims" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const payload = "{\"iss\":\"https://accounts.google.com\",\"aud\":\"client\",\"exp\":4102444800,\"nonce\":\"n1\",\"sub\":\"42\",\"email\":\"a@b.c\",\"email_verified\":true}";
    const encoded = try arena.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(payload.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, payload);
    const token = try std.fmt.allocPrint(arena, "e30.{s}.sig", .{encoded});
    const identity = try claims(arena, token, "https://accounts.google.com", "client", "n1", 0);
    try std.testing.expectEqualStrings("42", identity.subject);
    try std.testing.expectError(error.InvalidIdToken, claims(arena, token, "https://accounts.google.com", "client", "other", 0));
    try std.testing.expectError(error.InvalidIdToken, claims(arena, token, "https://accounts.google.com", "someone-else", "n1", 0));
}
