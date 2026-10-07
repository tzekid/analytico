//! Escaping and value formatting for server-rendered HTML.
const std = @import("std");

pub const Writer = std.Io.Writer;

/// HTML text and attribute escaping: `{f}` with `esc(value)`.
pub const Esc = struct {
    text: []const u8,

    pub fn format(self: Esc, w: *Writer) Writer.Error!void {
        var start: usize = 0;
        for (self.text, 0..) |byte, index| {
            const replacement: []const u8 = switch (byte) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                '\'' => "&#39;",
                else => continue,
            };
            try w.writeAll(self.text[start..index]);
            try w.writeAll(replacement);
            start = index + 1;
        }
        try w.writeAll(self.text[start..]);
    }
};

pub fn esc(text: []const u8) Esc {
    return .{ .text = text };
}

/// Writes a template. `{name}` slots are escaped and `{!name}` slots are
/// written as they are (HTML built elsewhere); `{name:.1}` gives a number's
/// precision. Every slot must be a field of `args` and every field a slot,
/// checked at compile time. Strings are text, numbers print in full, enums
/// by name, and values with a `format` method (`int`, `money`, …) format
/// themselves. A `{` that doesn't open a slot is plain text.
pub fn render(w: *Writer, comptime template: []const u8, args: anytype) Writer.Error!void {
    const parts = comptime parse(template);
    comptime {
        for (@typeInfo(@TypeOf(args)).@"struct".field_names) |field| {
            for (parts) |part| {
                if (part.slot and std.mem.eql(u8, part.name, field)) break;
            } else @compileError("unused template value: " ++ field);
        }
    }
    inline for (parts) |part| {
        if (!part.slot) {
            try w.writeAll(part.text);
        } else {
            try slot(w, @field(args, part.name), part.raw, part.spec);
        }
    }
}

/// `render` into a new string.
pub fn print(allocator: std.mem.Allocator, comptime template: []const u8, args: anytype) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    try render(&out.writer, template, args);
    return out.written();
}

const Part = struct { text: []const u8 = "", name: []const u8 = "", spec: []const u8 = "", raw: bool = false, slot: bool = false };

fn parse(comptime template: []const u8) []const Part {
    comptime {
        @setEvalBranchQuota(template.len * 50 + 1000);
        var parts: []const Part = &.{};
        var start = 0;
        var index = 0;
        while (index < template.len) : (index += 1) {
            if (template[index] != '{') continue;
            var cursor = index + 1;
            const raw = cursor < template.len and template[cursor] == '!';
            if (raw) cursor += 1;
            const name_start = cursor;
            while (cursor < template.len and (std.ascii.isAlphanumeric(template[cursor]) or template[cursor] == '_')) cursor += 1;
            if (cursor == name_start or !std.ascii.isAlphabetic(template[name_start])) continue;
            const name_end = cursor;
            var spec: []const u8 = "";
            if (cursor < template.len and template[cursor] == ':') {
                const spec_start = cursor;
                while (cursor < template.len and template[cursor] != '}' and template[cursor] != '{') cursor += 1;
                spec = template[spec_start..cursor];
            }
            if (cursor >= template.len or template[cursor] != '}') continue;
            parts = parts ++ [_]Part{ .{ .text = template[start..index] }, .{ .slot = true, .raw = raw, .name = template[name_start..name_end], .spec = spec } };
            start = cursor + 1;
            index = cursor;
        }
        parts = parts ++ [_]Part{.{ .text = template[start..] }};
        const final: [parts.len]Part = parts[0..parts.len].*;
        return &final;
    }
}

fn slot(w: *Writer, value: anytype, comptime raw: bool, comptime spec: []const u8) Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int, .comptime_int, .float, .comptime_float => return w.print("{d" ++ spec ++ "}", .{value}),
        .@"enum" => return slot(w, @tagName(value), raw, spec),
        .pointer => |pointer| {
            if (pointer.size == .one and @typeInfo(pointer.child) == .array) return slot(w, @as([]const u8, value), raw, spec);
            if (pointer.child != u8) @compileError("cannot render " ++ @typeName(T));
            return if (raw) w.writeAll(value) else (Esc{ .text = value }).format(w);
        },
        .array => return slot(w, @as([]const u8, &value), raw, spec),
        .@"struct" => return w.print("{f}", .{value}),
        else => @compileError("cannot render " ++ @typeName(T)),
    }
}

/// Percent-encoding for one query component.
pub const UrlPart = struct {
    text: []const u8,

    pub fn format(self: UrlPart, w: *Writer) Writer.Error!void {
        for (self.text) |byte| {
            if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~' or byte == '/' or byte == ':') {
                try w.writeByte(byte);
            } else {
                try w.print("%{X:0>2}", .{byte});
            }
        }
    }
};

pub fn url(text: []const u8) UrlPart {
    return .{ .text = text };
}

/// Integer with thousands separators: 18420 -> "18,420".
pub const Int = struct {
    value: i64,

    pub fn format(self: Int, w: *Writer) Writer.Error!void {
        var buffer: [32]u8 = undefined;
        const magnitude: u64 = @abs(self.value);
        const digits = std.fmt.bufPrint(&buffer, "{d}", .{magnitude}) catch unreachable;
        if (self.value < 0) try w.writeAll("−");
        for (digits, 0..) |digit, index| {
            if (index != 0 and (digits.len - index) % 3 == 0) try w.writeByte(',');
            try w.writeByte(digit);
        }
    }
};

pub fn int(value: i64) Int {
    return .{ .value = value };
}

/// Compact durations: 42s, 1m 42s, 3h 05m, 521h 54m.
pub const Duration = struct {
    ms: i64,

    pub fn format(self: Duration, w: *Writer) Writer.Error!void {
        const seconds = @divFloor(@max(self.ms, 0) + 500, 1000);
        if (seconds < 60) return w.print("{d}s", .{seconds});
        const minutes = @divFloor(seconds, 60);
        if (minutes < 60) return w.print("{d}m {d:0>2}s", .{ minutes, @mod(seconds, 60) });
        return w.print("{d}h {d:0>2}m", .{ @divFloor(minutes, 60), @mod(minutes, 60) });
    }
};

pub fn duration(ms: i64) Duration {
    return .{ .ms = ms };
}

/// Millisecond metrics: 340 ms, 1.8 s.
pub const Millis = struct {
    ms: i64,

    pub fn format(self: Millis, w: *Writer) Writer.Error!void {
        if (self.ms < 1000) return w.print("{d} ms", .{self.ms});
        return w.print("{d:.1} s", .{@as(f64, @floatFromInt(self.ms)) / 1000.0});
    }
};

pub fn millis(ms: i64) Millis {
    return .{ .ms = ms };
}

/// Signed percentage change with one decimal: +12.4%, −2.1%. From three
/// times the previous value up it reads as a multiple: 6.0×, 22×.
pub const Change = struct {
    value: f64,

    pub fn format(self: Change, w: *Writer) Writer.Error!void {
        if (std.math.isNan(self.value)) return w.writeAll("new");
        const times = 1 + self.value / 100.0;
        if (times >= 10) return w.print("{d:.0}×", .{times});
        if (times >= 3) return w.print("{d:.1}×", .{times});
        const rounded = @round(self.value * 10.0) / 10.0;
        if (rounded > 0) return w.print("+{d:.1}%", .{rounded});
        if (rounded < 0) return w.print("−{d:.1}%", .{-rounded});
        return w.writeAll("0.0%");
    }

    pub fn isMultiple(self: Change) bool {
        return !std.math.isNan(self.value) and 1 + self.value / 100.0 >= 3;
    }
};

pub fn change(current: f64, previous: f64) Change {
    if (previous == 0) return .{ .value = if (current == 0) 0 else std.math.nan(f64) };
    return .{ .value = (current - previous) / previous * 100.0 };
}

pub fn changeValue(current: f64, previous: f64) f64 {
    if (previous == 0) return if (current == 0) 0 else std.math.nan(f64);
    return (current - previous) / previous * 100.0;
}

/// Share of a total: 23%, or one decimal below 10%.
pub const Share = struct {
    part: f64,
    total: f64,

    pub fn format(self: Share, w: *Writer) Writer.Error!void {
        if (self.total <= 0) return w.writeAll("0%");
        const value = self.part / self.total * 100.0;
        if (value < 10 and value != 0) return w.print("{d:.1}%", .{value});
        return w.print("{d:.0}%", .{value});
    }
};

pub fn share(part: anytype, total: anytype) Share {
    return .{ .part = toFloat(part), .total = toFloat(total) };
}

/// Money in minor units with an ISO currency: €1,200, $2.31, CHF 40.
pub const Money = struct {
    minor: i64,
    currency: []const u8,

    pub fn format(self: Money, w: *Writer) Writer.Error!void {
        const symbols = [_][2][]const u8{ .{ "EUR", "€" }, .{ "USD", "$" }, .{ "GBP", "£" }, .{ "JPY", "¥" }, .{ "INR", "₹" } };
        var symbol: ?[]const u8 = null;
        for (symbols) |entry| if (std.mem.eql(u8, entry[0], self.currency)) {
            symbol = entry[1];
        };
        if (symbol) |value| try w.writeAll(value) else if (self.currency.len != 0) try w.print("{s} ", .{self.currency});
        const whole = @divTrunc(self.minor, 100);
        const cents = @abs(@rem(self.minor, 100));
        try int(whole).format(w);
        if (cents != 0 or (whole < 10 and whole > -10)) try w.print(".{d:0>2}", .{cents});
    }
};

pub fn money(minor: i64, currency: []const u8) Money {
    return .{ .minor = minor, .currency = currency };
}

pub fn toFloat(value: anytype) f64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError("number expected"),
    };
}

/// Decodes one application/x-www-form-urlencoded component into `allocator`.
pub fn decodeComponent(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, raw.len);
    var length: usize = 0;
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        const byte = raw[index];
        if (byte == '+') {
            out[length] = ' ';
        } else if (byte == '%' and index + 2 < raw.len) {
            out[length] = std.fmt.parseInt(u8, raw[index + 1 .. index + 3], 16) catch return error.InvalidEncoding;
            index += 2;
        } else if (byte == '%') {
            return error.InvalidEncoding;
        } else {
            out[length] = byte;
        }
        length += 1;
    }
    if (!std.unicode.utf8ValidateSlice(out[0..length])) return error.InvalidEncoding;
    return out[0..length];
}

/// Ordered key/value pairs from a query string or urlencoded body.
pub const Params = struct {
    keys: []const []const u8 = &.{},
    values: []const []const u8 = &.{},

    pub fn parse(allocator: std.mem.Allocator, raw: []const u8) !Params {
        var keys: std.ArrayList([]const u8) = .empty;
        var values: std.ArrayList([]const u8) = .empty;
        var parts = std.mem.splitScalar(u8, raw, '&');
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            const split = std.mem.findScalar(u8, part, '=') orelse part.len;
            try keys.append(allocator, try decodeComponent(allocator, part[0..split]));
            try values.append(allocator, try decodeComponent(allocator, if (split < part.len) part[split + 1 ..] else ""));
        }
        return .{ .keys = keys.items, .values = values.items };
    }

    pub fn get(self: Params, key: []const u8) ?[]const u8 {
        for (self.keys, self.values) |k, v| if (std.mem.eql(u8, k, key)) return v;
        return null;
    }

    pub fn all(self: Params, allocator: std.mem.Allocator, key: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (self.keys, self.values) |k, v| if (std.mem.eql(u8, k, key)) try out.append(allocator, v);
        return out.items;
    }
};

test "templates" {
    var buffer: [256]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try render(&w, "<a href=\"{href}\" title=\"{title}\">{!label} {count} {share:.1}% {n} { x } {\"j\":1}</a>", .{ .href = "/a?b=1&c", .title = "\"q\"", .label = "<b>x</b>", .count = 3, .share = 12.345, .n = int(1200) });
    try std.testing.expectEqualStrings("<a href=\"/a?b=1&amp;c\" title=\"&quot;q&quot;\"><b>x</b> 3 12.3% 1,200 { x } {\"j\":1}</a>", w.buffered());
}

test "money" {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try w.print("{f}|{f}|{f}", .{ money(138000, "EUR"), money(231, "USD"), money(4000, "CHF") });
    try std.testing.expectEqualStrings("€1,380|$2.31|CHF 40", w.buffered());
}

test "escaping and formatting" {
    var buffer: [128]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try w.print("{f}|{f}|{f}|{f}|{f}|{f}", .{ esc("<a href=\"x\">&'"), int(18420), duration(102_000), change(110, 100), change(640, 100), change(2246, 100) });
    try std.testing.expectEqualStrings("&lt;a href=&quot;x&quot;&gt;&amp;&#39;|18,420|1m 42s|+10.0%|6.4×|22×", w.buffered());
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const params = try Params.parse(arena.allocator(), "f=source%3Agoogle&range=7d&f=page%3A%2Fa+b");
    try std.testing.expectEqualStrings("7d", params.get("range").?);
    const filters = try params.all(arena.allocator(), "f");
    try std.testing.expectEqualStrings("page:/a b", filters[1]);
}
