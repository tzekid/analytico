//! Push notifications for the native apps. Each notification is encrypted
//! to the device's own key (RFC 8291, `aes128gcm`, as Web Push does) and
//! handed to the app publisher's relay, which forwards it to Apple. Only the
//! device can read it; the relay sees ciphertext and a push token.
const std = @import("std");
const db_mod = @import("../db.zig");
const data = @import("data.zig");
const net = @import("../net.zig");
const domain = @import("../domain.zig");
const Shared = @import("../server.zig").Shared;

const P256 = std.crypto.ecc.P256;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const base64 = std.base64.url_safe_no_pad;

pub const default_relay = "https://push.analytico.plosca.ru";

/// What a device asked to be told about.
pub const Kind = enum { alert, goal, note };

pub const Message = struct { kind: Kind, site_id: i64, site: []const u8, title: []const u8, body: []const u8 };

/// Encrypts to every device that wants this kind and may see the site; a
/// device the relay reports as gone is forgotten.
pub fn send(arena: std.mem.Allocator, shared: *Shared, db: *db_mod.Db, message: Message) !void {
    const Device = struct { device_id: []const u8, token: []const u8, environment: []const u8, public_key: []const u8, auth_secret: []const u8 };
    // A device delivers only while its sign-in lives, so signing out or
    // revoking the app stops notifications without further bookkeeping.
    const devices = try db.all(arena, Device,
        \\SELECT d.device_id,d.token,d.environment,d.public_key,d.auth_secret FROM devices d JOIN users u ON u.id=d.user_id
        \\WHERE instr(','||d.kinds||',', ','||?1||',')>0
        \\AND (u.all_sites=1 OR u.role IN ('admin','owner') OR EXISTS(SELECT 1 FROM user_sites WHERE user_id=u.id AND site_id=?2))
        \\AND EXISTS(SELECT 1 FROM oauth_grants g WHERE g.device_id=d.device_id AND g.kind='refresh' AND g.expires_at_ms>?3 AND (g.sites='*' OR instr(','||g.sites||',', ','||?2||',')>0))
    , .{ @tagName(message.kind), message.site_id, domain.nowMs() });
    if (devices.len == 0) return;
    const relay = (try data.setting(arena, db, .@"push.relay")) orelse default_relay;
    const url = try std.fmt.allocPrint(arena, "{s}/v1/apns", .{relay});
    var plaintext: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{ .title = message.title, .body = message.body, .site = message.site, .kind = @tagName(message.kind) }, .{}, &plaintext.writer);
    for (devices) |device| {
        var public_key: [65]u8 = undefined;
        var auth_secret: [16]u8 = undefined;
        base64.Decoder.decode(&public_key, device.public_key) catch continue;
        base64.Decoder.decode(&auth_secret, device.auth_secret) catch continue;
        var salt: [16]u8 = undefined;
        shared.io.randomSecure(&salt) catch continue;
        const sealed = try encrypt(arena, plaintext.written(), public_key, auth_secret, P256.scalar.random(shared.io, .big), salt);
        var body: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(.{ .token = device.token, .environment = device.environment, .payload = try std.fmt.allocPrint(arena, "{b64}", .{sealed}) }, .{}, &body.writer);
        const outcome: []const u8 = if (net.send(arena, url, .{ .method = .POST, .body = body.written() })) |response| switch (response.status) {
            .ok, .no_content => "",
            .gone => "gone",
            else => try std.fmt.allocPrint(arena, "relay answered {d}", .{@intFromEnum(response.status)}),
        } else |_| "relay unreachable";
        const write = shared.lockWrite();
        defer shared.unlockWrite();
        if (std.mem.eql(u8, outcome, "gone")) {
            try write.run(arena, "DELETE FROM devices WHERE device_id=?", .{device.device_id});
        } else {
            try write.run(arena, "UPDATE devices SET last_sent_at_ms=?,last_error=? WHERE device_id=?", .{ domain.nowMs(), outcome, device.device_id });
        }
        if (outcome.len != 0) std.log.warn("push_failed device={s} reason={s}", .{ device.device_id[0..@min(8, device.device_id.len)], outcome });
    }
}

/// RFC 8291: salt, record size and the sender's public key, then a single
/// record (the plaintext and its 0x02 delimiter) sealed with AES-128-GCM.
pub fn encrypt(arena: std.mem.Allocator, plaintext: []const u8, ua_public: [65]u8, auth_secret: [16]u8, as_secret: [32]u8, salt: [16]u8) ![]u8 {
    const as_public = (try P256.basePoint.mul(as_secret, .big)).toUncompressedSec1();
    const ecdh = (try (try P256.fromSec1(&ua_public)).mul(as_secret, .big)).affineCoordinates().x.toBytes(.big);
    const key_info = "WebPush: info\x00" ++ ua_public ++ as_public;
    var ikm: [32]u8 = undefined;
    Hkdf.expand(&ikm, key_info, Hkdf.extract(&auth_secret, &ecdh));
    const prk = Hkdf.extract(&salt, &ikm);
    var key: [16]u8 = undefined;
    Hkdf.expand(&key, "Content-Encoding: aes128gcm\x00", prk);
    var nonce: [12]u8 = undefined;
    Hkdf.expand(&nonce, "Content-Encoding: nonce\x00", prk);

    const header = 16 + 4 + 1 + 65;
    const out = try arena.alloc(u8, header + plaintext.len + 1 + Aes128Gcm.tag_length);
    out[0..16].* = salt;
    std.mem.writeInt(u32, out[16..20], 4096, .big);
    out[20] = 65;
    out[21..header].* = as_public;
    const record = try arena.alloc(u8, plaintext.len + 1);
    @memcpy(record[0..plaintext.len], plaintext);
    record[plaintext.len] = 0x02;
    const sealed = out[header..];
    Aes128Gcm.encrypt(sealed[0..record.len], sealed[record.len..][0..Aes128Gcm.tag_length], record, "", nonce, key);
    return out;
}

/// Checks a device's base64url P-256 public key and auth secret.
pub fn validKeys(public_key: []const u8, auth_secret: []const u8) bool {
    var key: [65]u8 = undefined;
    var secret: [16]u8 = undefined;
    if ((base64.Decoder.calcSizeForSlice(public_key) catch return false) != 65) return false;
    if ((base64.Decoder.calcSizeForSlice(auth_secret) catch return false) != 16) return false;
    base64.Decoder.decode(&key, public_key) catch return false;
    base64.Decoder.decode(&secret, auth_secret) catch return false;
    _ = P256.fromSec1(&key) catch return false;
    return true;
}

test "RFC 8291 example message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ua_public: [65]u8 = undefined;
    try base64.Decoder.decode(&ua_public, "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4");
    var auth_secret: [16]u8 = undefined;
    try base64.Decoder.decode(&auth_secret, "BTBZMqHH6r4Tts7J_aSIgg");
    var as_secret: [32]u8 = undefined;
    try base64.Decoder.decode(&as_secret, "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw");
    var salt: [16]u8 = undefined;
    try base64.Decoder.decode(&salt, "DGv6ra1nlYgDCS1FRnbzlw");
    const sealed = try encrypt(arena, "When I grow up, I want to be a watermelon", ua_public, auth_secret, as_secret, salt);
    const expected = "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN";
    const encoded = try arena.alloc(u8, base64.Encoder.calcSize(sealed.len));
    try std.testing.expectEqualStrings(expected, base64.Encoder.encode(encoded, sealed));
}
