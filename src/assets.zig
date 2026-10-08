//! Embedded assets. The workspace's files are served immutable under
//! content-hashed `/_/` paths (hashed once at startup, after the stylesheet
//! is pointed at the hashed fonts). The collector's scripts are served under
//! `/t/`, with hashes computed at build time by tools/gen_trackers.zig.
const std = @import("std");

// ---------------------------------------------------------------- workspace

pub const Asset = struct {
    name: []const u8,
    extension: []const u8,
    content_type: []const u8,
    bytes: []const u8,
};

const list = [_]Asset{
    .{ .name = "app", .extension = "css", .content_type = "text/css; charset=utf-8", .bytes = @embedFile("web_css") },
    .{ .name = "app", .extension = "js", .content_type = "text/javascript; charset=utf-8", .bytes = @embedFile("web_js") },
    .{ .name = "icons", .extension = "svg", .content_type = "image/svg+xml", .bytes = @embedFile("web_icons") },
    .{ .name = "quando", .extension = "woff2", .content_type = "font/woff2", .bytes = @embedFile("font_quando") },
    .{ .name = "quicksand", .extension = "woff2", .content_type = "font/woff2", .bytes = @embedFile("font_quicksand") },
    .{ .name = "favicon", .extension = "svg", .content_type = "image/svg+xml", .bytes = @embedFile("web_favicon") },
    // The session replay player (rrweb, MIT), loaded only on replay pages.
    .{ .name = "player", .extension = "js", .content_type = "text/javascript; charset=utf-8", .bytes = @embedFile("web_player_js") },
    .{ .name = "player", .extension = "css", .content_type = "text/css; charset=utf-8", .bytes = @embedFile("web_player_css") },
};

/// Served bytes; the stylesheet's are rewritten by init.
var contents: [list.len][]const u8 = blk: {
    var out: [list.len][]const u8 = undefined;
    for (list, 0..) |asset, index| out[index] = asset.bytes;
    break :blk out;
};
var paths: [list.len][64]u8 = undefined;
var path_lengths: [list.len]usize = undefined;
/// Called once at startup, before any worker thread reads asset paths.
pub fn init() void {
    // The stylesheet names fonts by file; point it at their hashed paths, and
    // only then hash the stylesheet itself.
    for (list, 0..) |asset, index| if (!std.mem.eql(u8, asset.extension, "css")) hash(index);
    for (list, 0..) |css, index| {
        if (!std.mem.eql(u8, css.extension, "css")) continue;
        for (list, 0..) |font, font_index| {
            if (!std.mem.eql(u8, font.extension, "woff2")) continue;
            var needle: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&needle, "url(\"{s}.{s}\")", .{ font.name, font.extension }) catch unreachable;
            var buffer: [80]u8 = undefined;
            const hashed = std.fmt.bufPrint(&buffer, "url(\"{s}\")", .{paths[font_index][0..path_lengths[font_index]]}) catch unreachable;
            if (std.mem.find(u8, contents[index], name) == null) continue;
            contents[index] = std.mem.replaceOwned(u8, std.heap.page_allocator, contents[index], name, hashed) catch @panic("out of memory");
        }
        hash(index);
    }
}

fn hash(index: usize) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contents[index], &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..5].*, .lower);
    const written = std.fmt.bufPrint(&paths[index], "/_/{s}.{s}.{s}", .{ list[index].name, hex, list[index].extension }) catch unreachable;
    path_lengths[index] = written.len;
}

/// Hashed public path for an asset name such as "app.css".
pub fn path(comptime file: []const u8) []const u8 {
    const index = comptime indexOf(file);
    return paths[index][0..path_lengths[index]];
}

fn indexOf(comptime file: []const u8) usize {
    for (list, 0..) |asset, index| {
        if (file.len == asset.name.len + 1 + asset.extension.len and
            std.mem.startsWith(u8, file, asset.name) and std.mem.endsWith(u8, file, asset.extension)) return index;
    }
    @compileError("unknown asset " ++ file);
}

pub fn find(request_path: []const u8) ?Asset {
    for (list, 0..) |asset, index| {
        if (std.mem.eql(u8, request_path, paths[index][0..path_lengths[index]])) return .{ .name = asset.name, .extension = asset.extension, .content_type = asset.content_type, .bytes = contents[index] };
    }
    return null;
}

test "stylesheet loads fonts by their hashed paths" {
    init();
    const css = find(path("app.css")).?.bytes;
    try std.testing.expect(std.mem.find(u8, css, path("quando.woff2")) != null);
    try std.testing.expect(std.mem.find(u8, css, "url(\"quando.woff2\")") == null);
}

// ---------------------------------------------------------------- collector scripts

const hashes = @import("tracker_hashes");

/// Collector-served scripts: the trackers, plus the lazily loaded replay
/// recorder and heatmap overlay. All immutable under content-hashed paths.
pub const Variant = enum { lite, lite_rum, session, session_rum, full, full_rum, replay, overlay };

pub fn bytes(variant: Variant) []const u8 {
    return switch (variant) {
        .lite => @embedFile("tracker_lite"),
        .lite_rum => @embedFile("tracker_lite_rum"),
        .session => @embedFile("tracker_session"),
        .session_rum => @embedFile("tracker_session_rum"),
        .full => @embedFile("tracker_full"),
        .full_rum => @embedFile("tracker_full_rum"),
        .replay => @embedFile("tracker_replay"),
        .overlay => @embedFile("tracker_overlay"),
    };
}

fn label(variant: Variant) []const u8 {
    return switch (variant) {
        .lite => "lite",
        .lite_rum => "lite-rum",
        .session => "session",
        .session_rum => "session-rum",
        .full => "full",
        .full_rum => "full-rum",
        .replay => "replay",
        .overlay => "overlay",
    };
}

/// The served path, a compile-time constant.
pub fn scriptPath(variant: Variant) []const u8 {
    return switch (variant) {
        inline else => |known| comptime "/t/" ++ label(known) ++ "." ++ @field(hashes, switch (known) {
            .replay => "replay",
            .overlay => "overlay",
            else => "tracker_" ++ @tagName(known),
        }) ++ ".js",
    };
}

/// The tracker for a site's mode.
pub fn forMode(mode: @import("domain.zig").Mode, rum: bool) Variant {
    return switch (mode) {
        .lite => if (rum) .lite_rum else .lite,
        .session => if (rum) .session_rum else .session,
        .full => if (rum) .full_rum else .full,
    };
}

pub fn parseScript(value: []const u8) ?Variant {
    inline for (comptime std.enums.values(Variant)) |variant| {
        if (std.mem.eql(u8, value, comptime scriptPath(variant))) return variant;
    }
    return null;
}

/// Snippets pasted before a tracker update name an older hash of the same
/// variant. They get the current tracker, cached briefly instead of forever,
/// so deployed sites keep collecting and pick up updates on their own.
pub fn parseOlder(value: []const u8) ?Variant {
    if (!std.mem.startsWith(u8, value, "/t/") or !std.mem.endsWith(u8, value, ".js")) return null;
    const name = value[3 .. value.len - 3];
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    const digest = name[dot + 1 ..];
    if (digest.len != 12) return null;
    for (digest) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
    inline for (comptime std.enums.values(Variant)) |variant| {
        if (std.mem.eql(u8, name[0..dot], label(variant))) return variant;
    }
    return null;
}

test "older tracker hashes still resolve" {
    try std.testing.expectEqual(Variant.session, parseOlder("/t/session.0123456789ab.js").?);
    try std.testing.expect(parseOlder("/t/session.xyz.js") == null);
    try std.testing.expect(parseOlder("/t/unknown.0123456789ab.js") == null);
}

test "script paths match their content" {
    for (std.enums.values(Variant)) |variant| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes(variant), &digest, .{});
        const hex = std.fmt.bytesToHex(digest[0..6].*, .lower);
        try std.testing.expect(std.mem.endsWith(u8, scriptPath(variant), &hex ++ ".js"));
        try std.testing.expectEqual(variant, parseScript(scriptPath(variant)).?);
    }
}

test "trackers reference the replay and overlay scripts they load" {
    try std.testing.expect(std.mem.find(u8, bytes(.full), scriptPath(.replay)) != null);
    try std.testing.expect(std.mem.find(u8, bytes(.lite), scriptPath(.overlay)) != null);
    try std.testing.expect(std.mem.find(u8, bytes(.lite), "visitor_id") == null);
}
