//! Encrypts operator secrets (API keys, SMTP password) at rest with a key
//! derived from the instance master key. Stored as hex(nonce || ciphertext || tag).
const std = @import("std");

const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;

fn derive(master: [32]u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&out, "analytico/settings-secret/v1", &master);
    return out;
}

pub fn seal(arena: std.mem.Allocator, io: std.Io, master: [32]u8, plain: []const u8) ![]const u8 {
    var nonce: [Aead.nonce_length]u8 = undefined;
    try io.randomSecure(&nonce);
    const sealed = try arena.alloc(u8, nonce.len + plain.len + Aead.tag_length);
    @memcpy(sealed[0..nonce.len], &nonce);
    var tag: [Aead.tag_length]u8 = undefined;
    Aead.encrypt(sealed[nonce.len..][0..plain.len], &tag, plain, "", nonce, derive(master));
    @memcpy(sealed[nonce.len + plain.len ..], &tag);
    const hex = try arena.alloc(u8, sealed.len * 2);
    const charset = "0123456789abcdef";
    for (sealed, 0..) |byte, index| {
        hex[index * 2] = charset[byte >> 4];
        hex[index * 2 + 1] = charset[byte & 15];
    }
    return hex;
}

pub fn open(arena: std.mem.Allocator, master: [32]u8, hex: []const u8) ![]const u8 {
    if (hex.len % 2 != 0 or hex.len < (Aead.nonce_length + Aead.tag_length) * 2) return error.InvalidSecret;
    const sealed = try arena.alloc(u8, hex.len / 2);
    _ = std.fmt.hexToBytes(sealed, hex) catch return error.InvalidSecret;
    const nonce = sealed[0..Aead.nonce_length].*;
    const body = sealed[Aead.nonce_length .. sealed.len - Aead.tag_length];
    const tag = sealed[sealed.len - Aead.tag_length ..][0..Aead.tag_length].*;
    const plain = try arena.alloc(u8, body.len);
    Aead.decrypt(plain, body, tag, "", nonce, derive(master)) catch return error.InvalidSecret;
    return plain;
}

/// "sk-ant-…7f2c": enough to recognise a key, never enough to use it.
pub fn hint(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (value.len <= 8) return "••••";
    const dash = std.mem.lastIndexOfScalar(u8, value[0..@min(value.len, 8)], '-');
    const prefix = if (dash) |index| value[0 .. index + 1] else "";
    return std.fmt.allocPrint(arena, "{s}••••{s}", .{ prefix, value[value.len - 4 ..] });
}
