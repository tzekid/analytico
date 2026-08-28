const std = @import("std");

pub const Variant = enum { lite, lite_rum, session, session_rum };

pub fn bytes(variant: Variant) []const u8 {
    return switch (variant) {
        .lite => @embedFile("tracker_lite"),
        .lite_rum => @embedFile("tracker_lite_rum"),
        .session => @embedFile("tracker_session"),
        .session_rum => @embedFile("tracker_session_rum"),
    };
}

pub fn label(variant: Variant) []const u8 {
    return switch (variant) {
        .lite => "lite",
        .lite_rum => "lite-rum",
        .session => "session",
        .session_rum => "session-rum",
    };
}

pub fn hash(variant: Variant) [12]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes(variant), &digest, .{});
    return std.fmt.bytesToHex(digest[0..6].*, .lower);
}

pub fn path(buffer: []u8, variant: Variant) ![]const u8 {
    return std.fmt.bufPrint(buffer, "/t/{s}.{s}.js", .{ label(variant), hash(variant) });
}

pub fn parsePath(value: []const u8) ?Variant {
    inline for (std.enums.values(Variant)) |variant| {
        var buffer: [64]u8 = undefined;
        const expected = path(&buffer, variant) catch unreachable;
        if (std.mem.eql(u8, value, expected)) return variant;
    }
    return null;
}
