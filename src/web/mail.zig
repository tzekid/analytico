//! Minimal SMTP submission client: implicit TLS (465), STARTTLS (587) or a
//! plain local relay, with AUTH PLAIN. Used for invites, alerts and reports.
const std = @import("std");
const data = @import("data.zig");
const db_mod = @import("../db.zig");
const secret = @import("secret.zig");

pub const Security = enum { starttls, tls, none };

pub const Config = struct {
    host: []const u8,
    port: u16,
    security: Security,
    username: []const u8,
    password: []const u8,
    from: []const u8,
};

pub fn load(arena: std.mem.Allocator, db: *db_mod.Db, master: [32]u8) !?Config {
    const host = try data.setting(arena, db, .@"smtp.host") orelse return null;
    const sealed = try data.setting(arena, db, .@"smtp.password");
    return .{
        .host = host,
        .port = std.fmt.parseInt(u16, (try data.setting(arena, db, .@"smtp.port")) orelse "587", 10) catch 587,
        .security = std.meta.stringToEnum(Security, (try data.setting(arena, db, .@"smtp.security")) orelse "starttls") orelse .starttls,
        .username = (try data.setting(arena, db, .@"smtp.username")) orelse "",
        .password = if (sealed) |value| secret.open(arena, master, value) catch "" else "",
        .from = (try data.setting(arena, db, .@"smtp.from")) orelse "",
    };
}

pub const Message = struct {
    to: []const []const u8,
    subject: []const u8,
    html: []const u8,
    text: []const u8,
};

const Session = struct {
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    /// The socket under TLS: encrypted records only leave when it is flushed.
    socket: *std.Io.Writer,
    last: []const u8 = "",

    fn expect(self: *Session, code: []const u8) !void {
        while (true) {
            const raw = self.reader.takeDelimiterInclusive('\n') catch |err| {
                std.log.warn("smtp_read_failed expected={s} code={s}", .{ code, @errorName(err) });
                return error.SmtpConnectionLost;
            };
            const line = std.mem.trimEnd(u8, raw, "\r\n");
            self.last = line;
            if (line.len < 3) return error.SmtpProtocol;
            if (line.len > 3 and line[3] == '-') continue;
            if (!std.mem.eql(u8, line[0..3], code)) {
                std.log.warn("smtp_unexpected expected={s} got={s}", .{ code, line[0..@min(line.len, 120)] });
                return error.SmtpRejected;
            }
            return;
        }
    }

    fn command(self: *Session, comptime fmt: []const u8, args: anytype, code: []const u8) !void {
        self.writer.print(fmt ++ "\r\n", args) catch |err| {
            std.log.warn("smtp_write_failed code={s}", .{@errorName(err)});
            return error.SmtpConnectionLost;
        };
        self.writer.flush() catch |err| {
            std.log.warn("smtp_flush_failed code={s}", .{@errorName(err)});
            return error.SmtpConnectionLost;
        };
        self.socket.flush() catch |err| {
            std.log.warn("smtp_flush_failed code={s}", .{@errorName(err)});
            return error.SmtpConnectionLost;
        };
        try self.expect(code);
    }
};

fn setTimeouts(stream: std.Io.net.Stream) void {
    const timeout = std.posix.timeval{ .sec = 20, .usec = 0 };
    const bytes = std.mem.asBytes(&timeout);
    _ = std.os.linux.setsockopt(stream.socket.handle, std.os.linux.SOL.SOCKET, std.os.linux.SO.RCVTIMEO, bytes.ptr, bytes.len);
    _ = std.os.linux.setsockopt(stream.socket.handle, std.os.linux.SOL.SOCKET, std.os.linux.SO.SNDTIMEO, bytes.ptr, bytes.len);
}

fn headerSafe(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, "\r\n") == null;
}

pub fn send(arena: std.mem.Allocator, io: std.Io, config: Config, message: Message) !void {
    if (config.from.len == 0 or !headerSafe(config.from) or !headerSafe(message.subject)) return error.SmtpInvalidMessage;
    for (message.to) |to| if (!headerSafe(to) or std.mem.indexOfAny(u8, to, "<>") != null) return error.SmtpInvalidMessage;
    const host_name = std.Io.net.HostName.init(config.host) catch return error.SmtpInvalidHost;
    // Zig 0.17's threaded I/O has no connect timeout; the kernel's applies,
    // and socket timeouts below bound every read and write after that.
    const stream = host_name.connect(io, config.port, .{ .mode = .stream }) catch return error.SmtpConnectFailed;
    defer stream.close(io);
    setTimeouts(stream);
    const socket_read = try arena.alloc(u8, std.crypto.tls.max_ciphertext_record_len);
    const socket_write = try arena.alloc(u8, std.crypto.tls.max_ciphertext_record_len);
    var stream_reader = stream.reader(io, socket_read);
    var stream_writer = stream.writer(io, socket_write);
    var session: Session = .{ .reader = &stream_reader.interface, .writer = &stream_writer.interface, .socket = &stream_writer.interface };

    var bundle: std.crypto.Certificate.Bundle = .empty;
    var bundle_lock: std.Io.RwLock = .init;
    var tls_client: std.crypto.tls.Client = undefined;
    const tls_read = try arena.alloc(u8, std.crypto.tls.max_ciphertext_record_len + 4096);
    const tls_write = try arena.alloc(u8, std.crypto.tls.max_ciphertext_record_len);
    const Upgrade = struct {
        fn run(a: std.mem.Allocator, i: std.Io, c: *std.crypto.tls.Client, b: *std.crypto.Certificate.Bundle, l: *std.Io.RwLock, r: *std.Io.Reader, w: *std.Io.Writer, host: []const u8, rb: []u8, wb: []u8) !void {
            const now = std.Io.Clock.real.now(i);
            b.rescan(a, i, now) catch return error.SmtpCertificates;
            var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
            i.random(&entropy);
            c.* = std.crypto.tls.Client.init(r, w, .{
                .host = .{ .explicit = host },
                .ca = .{ .bundle = .{ .gpa = a, .io = i, .lock = l, .bundle = b } },
                .read_buffer = rb,
                .write_buffer = wb,
                .entropy = &entropy,
                .realtime_now = now,
            }) catch return error.SmtpTlsFailed;
        }
    };
    if (config.security == .tls) {
        try Upgrade.run(arena, io, &tls_client, &bundle, &bundle_lock, &stream_reader.interface, &stream_writer.interface, config.host, tls_read, tls_write);
        session = .{ .reader = &tls_client.reader, .writer = &tls_client.writer, .socket = &stream_writer.interface };
    }
    try session.expect("220");
    try session.command("EHLO analytico", .{}, "250");
    if (config.security == .starttls) {
        try session.command("STARTTLS", .{}, "220");
        try Upgrade.run(arena, io, &tls_client, &bundle, &bundle_lock, &stream_reader.interface, &stream_writer.interface, config.host, tls_read, tls_write);
        session = .{ .reader = &tls_client.reader, .writer = &tls_client.writer, .socket = &stream_writer.interface };
        try session.command("EHLO analytico", .{}, "250");
    }
    if (config.username.len != 0) {
        const plain = try std.fmt.allocPrint(arena, "\x00{s}\x00{s}", .{ config.username, config.password });
        const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(plain.len));
        _ = std.base64.standard.Encoder.encode(encoded, plain);
        try session.command("AUTH PLAIN {s}", .{encoded}, "235");
    }
    const from_address = addressOf(config.from);
    try session.command("MAIL FROM:<{s}>", .{from_address}, "250");
    for (message.to) |to| try session.command("RCPT TO:<{s}>", .{to}, "250");
    try session.command("DATA", .{}, "354");
    const boundary = "analytico-boundary-7f2c";
    var date_buffer: [40]u8 = undefined;
    const now_ms = @import("../domain.zig").nowMs();
    const date = data.civil(now_ms);
    const seconds = @divFloor(@mod(now_ms, data.day_ms), 1000);
    const date_text = std.fmt.bufPrint(&date_buffer, "{s}, {d} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} +0000", .{
        data.weekday_names[data.weekday(now_ms)],     date.day,                                             data.month_names[date.month - 1],      date.year,
        @as(u64, @intCast(@divFloor(seconds, 3600))), @as(u64, @intCast(@mod(@divFloor(seconds, 60), 60))), @as(u64, @intCast(@mod(seconds, 60))),
    }) catch "";
    var id_bytes: [12]u8 = undefined;
    io.random(&id_bytes);
    const w = session.writer;
    w.print("From: {s}\r\nTo: ", .{config.from}) catch return error.SmtpConnectionLost;
    for (message.to, 0..) |to, index| w.print("{s}{s}", .{ if (index == 0) "" else ", ", to }) catch return error.SmtpConnectionLost;
    w.print("\r\nSubject: =?UTF-8?B?", .{}) catch return error.SmtpConnectionLost;
    const subject = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(message.subject.len));
    _ = std.base64.standard.Encoder.encode(subject, message.subject);
    w.print("{s}?=\r\nDate: {s}\r\nMessage-ID: <{x}@{s}>\r\nMIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=\"{s}\"\r\n\r\n", .{ subject, date_text, &id_bytes, domainOf(from_address), boundary }) catch return error.SmtpConnectionLost;
    w.print("--{s}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n", .{boundary}) catch return error.SmtpConnectionLost;
    try writeBase64(arena, w, message.text);
    w.print("--{s}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n", .{boundary}) catch return error.SmtpConnectionLost;
    try writeBase64(arena, w, message.html);
    // Base64 lines never start with ".", so no dot-stuffing is needed.
    try session.command("--{s}--\r\n.", .{boundary}, "250");
    session.command("QUIT", .{}, "221") catch {};
    if (config.security != .none) {
        tls_client.end() catch {};
        stream_writer.interface.flush() catch {};
    }
}

fn writeBase64(arena: std.mem.Allocator, w: *std.Io.Writer, value: []const u8) !void {
    const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(value.len));
    _ = std.base64.standard.Encoder.encode(encoded, value);
    var index: usize = 0;
    while (index < encoded.len) : (index += 76) {
        w.print("{s}\r\n", .{encoded[index..@min(encoded.len, index + 76)]}) catch return error.SmtpConnectionLost;
    }
}

/// "Analytico <a@b.c>" -> "a@b.c".
pub fn addressOf(value: []const u8) []const u8 {
    const open = std.mem.lastIndexOfScalar(u8, value, '<') orelse return std.mem.trim(u8, value, " ");
    const close = std.mem.lastIndexOfScalar(u8, value, '>') orelse return std.mem.trim(u8, value, " ");
    if (close <= open) return value;
    return value[open + 1 .. close];
}

fn domainOf(address: []const u8) []const u8 {
    const at = std.mem.lastIndexOfScalar(u8, address, '@') orelse return "analytico";
    return address[at + 1 ..];
}

test "address parsing" {
    try std.testing.expectEqualStrings("a@b.c", addressOf("Analytico <a@b.c>"));
    try std.testing.expectEqualStrings("a@b.c", addressOf(" a@b.c "));
}
