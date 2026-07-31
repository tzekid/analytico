const std = @import("std");

pub const Client = struct {
    browser: []const u8,
    os: []const u8,
    device: []const u8,
};

pub fn userAgent(value: []const u8) Client {
    if (containsAny(value, &.{ "bot", "Bot", "spider", "Spider", "crawler", "Crawler" })) {
        return .{ .browser = "Other", .os = "Other", .device = "bot" };
    }
    const browser = if (std.mem.find(u8, value, "Edg/") != null)
        "Edge"
    else if (std.mem.find(u8, value, "Firefox/") != null)
        "Firefox"
    else if (std.mem.find(u8, value, "Chrome/") != null or
        std.mem.find(u8, value, "Chromium/") != null)
        "Chrome"
    else if (std.mem.find(u8, value, "Safari/") != null)
        "Safari"
    else if (value.len == 0)
        "Unknown"
    else
        "Other";

    const os = if (std.mem.find(u8, value, "Android") != null)
        "Android"
    else if (containsAny(value, &.{ "iPhone", "iPad", "iPod" }))
        "iOS"
    else if (std.mem.find(u8, value, "Windows") != null)
        "Windows"
    else if (containsAny(value, &.{ "Mac OS X", "Macintosh" }))
        "macOS"
    else if (std.mem.find(u8, value, "Linux") != null)
        "Linux"
    else if (value.len == 0)
        "Unknown"
    else
        "Other";

    const device = if (containsAny(value, &.{ "iPad", "Tablet" }))
        "tablet"
    else if (containsAny(value, &.{ "Mobile", "Android", "iPhone", "iPod" }))
        "mobile"
    else if (value.len == 0)
        "unknown"
    else
        "desktop";
    return .{ .browser = browser, .os = os, .device = device };
}

pub fn country(value: ?[]const u8) [2]u8 {
    const candidate = value orelse return .{ 'Z', 'Z' };
    if (candidate.len != 2) return .{ 'Z', 'Z' };
    if (!std.ascii.isAlphabetic(candidate[0]) or
        !std.ascii.isAlphabetic(candidate[1]))
    {
        return .{ 'Z', 'Z' };
    }
    return .{ std.ascii.toUpper(candidate[0]), std.ascii.toUpper(candidate[1]) };
}

fn containsAny(value: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.find(u8, value, needle) != null) return true;
    }
    return false;
}
