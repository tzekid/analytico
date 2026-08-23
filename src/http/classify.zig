const std = @import("std");
const domain = @import("../domain.zig");

pub const Client = struct {
    browser: []const u8,
    os: []const u8,
    device: []const u8,
    traffic: domain.TrafficClassification,
};

pub fn userAgent(value: []const u8) Client {
    const traffic = classifyTraffic(value);
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
    return .{
        .browser = browser,
        .os = os,
        .device = device,
        .traffic = traffic,
    };
}

const MatchMode = enum {
    prefix,
    substring,
    token,
};

const Rule = struct {
    id: []const u8,
    class: domain.TrafficClass,
    mode: MatchMode,
    pattern: []const u8,
};

const rules = [_]Rule{
    .{ .id = "crawler.google", .class = .declared_bot, .mode = .token, .pattern = "Googlebot" },
    .{ .id = "crawler.google", .class = .declared_bot, .mode = .token, .pattern = "Google-InspectionTool" },
    .{ .id = "crawler.google", .class = .declared_bot, .mode = .token, .pattern = "AdsBot-Google" },
    .{ .id = "crawler.bing", .class = .declared_bot, .mode = .token, .pattern = "bingbot" },
    .{ .id = "crawler.bing", .class = .declared_bot, .mode = .token, .pattern = "BingPreview" },
    .{ .id = "crawler.bing", .class = .declared_bot, .mode = .token, .pattern = "adidxbot" },
    .{ .id = "crawler.yahoo", .class = .declared_bot, .mode = .token, .pattern = "Slurp" },
    .{ .id = "crawler.baidu", .class = .declared_bot, .mode = .token, .pattern = "Baiduspider" },
    .{ .id = "crawler.yandex", .class = .declared_bot, .mode = .token, .pattern = "YandexBot" },
    .{ .id = "crawler.yandex", .class = .declared_bot, .mode = .token, .pattern = "YandexImages" },
    .{ .id = "crawler.yandex", .class = .declared_bot, .mode = .token, .pattern = "YandexMobileBot" },
    .{ .id = "crawler.duckduckgo", .class = .declared_bot, .mode = .token, .pattern = "DuckDuckBot" },
    .{ .id = "crawler.apple", .class = .declared_bot, .mode = .token, .pattern = "Applebot" },
    .{ .id = "crawler.majestic", .class = .declared_bot, .mode = .token, .pattern = "MJ12bot" },
    .{ .id = "crawler.ahrefs", .class = .declared_bot, .mode = .token, .pattern = "AhrefsBot" },
    .{ .id = "crawler.facebook", .class = .declared_bot, .mode = .token, .pattern = "facebookexternalhit" },
    .{ .id = "crawler.facebook", .class = .declared_bot, .mode = .token, .pattern = "Facebot" },
    .{ .id = "crawler.openai", .class = .declared_bot, .mode = .token, .pattern = "GPTBot" },
    .{ .id = "crawler.openai", .class = .declared_bot, .mode = .token, .pattern = "ChatGPT-User" },
    .{ .id = "crawler.openai", .class = .declared_bot, .mode = .token, .pattern = "OAI-SearchBot" },
    .{ .id = "crawler.commoncrawl", .class = .declared_bot, .mode = .token, .pattern = "CCBot" },
    .{ .id = "crawler.semrush", .class = .declared_bot, .mode = .token, .pattern = "SemrushBot" },
    .{ .id = "crawler.dotbot", .class = .declared_bot, .mode = .token, .pattern = "DotBot" },
    .{ .id = "monitor.uptimerobot", .class = .automation, .mode = .token, .pattern = "UptimeRobot" },
    .{ .id = "monitor.statuscake", .class = .automation, .mode = .token, .pattern = "StatusCake" },
    .{ .id = "monitor.site24x7", .class = .automation, .mode = .token, .pattern = "Site24x7" },
    .{ .id = "headless.chrome", .class = .automation, .mode = .token, .pattern = "HeadlessChrome" },
    .{ .id = "headless.phantomjs", .class = .automation, .mode = .token, .pattern = "PhantomJS" },
    .{ .id = "client.curl", .class = .automation, .mode = .prefix, .pattern = "curl/" },
    .{ .id = "client.wget", .class = .automation, .mode = .prefix, .pattern = "Wget/" },
    .{ .id = "client.python_requests", .class = .automation, .mode = .substring, .pattern = "python-requests/" },
    .{ .id = "client.python_urllib", .class = .automation, .mode = .substring, .pattern = "Python-urllib/" },
    .{ .id = "client.go_http", .class = .automation, .mode = .prefix, .pattern = "Go-http-client/" },
    .{ .id = "client.scrapy", .class = .automation, .mode = .substring, .pattern = "Scrapy/" },
    .{ .id = "client.okhttp", .class = .automation, .mode = .substring, .pattern = "okhttp/" },
    .{ .id = "client.libwww_perl", .class = .automation, .mode = .substring, .pattern = "libwww-perl/" },
    .{ .id = "generic.bot", .class = .declared_bot, .mode = .token, .pattern = "bot" },
    .{ .id = "generic.crawler", .class = .declared_bot, .mode = .token, .pattern = "crawler" },
    .{ .id = "generic.spider", .class = .declared_bot, .mode = .token, .pattern = "spider" },
};

comptime {
    if (rules.len > 64) @compileError("UA classifier v1 exceeds 64 rules");
    for (rules) |rule| {
        if (rule.id.len == 0 or rule.id.len > 64) {
            @compileError("UA classifier v1 rule ID is out of bounds");
        }
        if (rule.pattern.len == 0 or rule.pattern.len > 64) {
            @compileError("UA classifier v1 pattern is out of bounds");
        }
    }
}

fn classifyTraffic(value: []const u8) domain.TrafficClassification {
    if (value.len == 0) {
        return .{
            .class = .declared_bot,
            .classifier_version = 1,
            .rule = "ua.empty",
        };
    }
    for (rules) |rule| {
        if (matches(value, rule)) {
            return .{
                .class = rule.class,
                .classifier_version = 1,
                .rule = rule.id,
            };
        }
    }
    return .{
        .class = .human_presumed,
        .classifier_version = 1,
        .rule = "",
    };
}

pub fn clientHintConsistency(
    user_agent: []const u8,
    value: ?[]const u8,
) domain.ClientHintConsistency {
    const ua_chromium = containsAnyIgnoreCase(user_agent, &.{
        "Chrome/", "Chromium/", "Edg/", "HeadlessChrome/",
    });
    const hint = value orelse return if (ua_chromium)
        .absent_when_expected
    else
        .consistent;
    if (hint.len > 512) return .mismatch;
    if (containsIgnoreCase(hint, "\"HeadlessChrome\"")) return .mismatch;
    const hint_chromium = containsAnyIgnoreCase(hint, &.{
        "\"Chromium\"", "\"Google Chrome\"", "\"Microsoft Edge\"",
    });
    return if (ua_chromium == hint_chromium) .consistent else .mismatch;
}

pub fn applySignals(
    base: domain.TrafficClassification,
    signals: domain.ClientSignals,
    hint: domain.ClientHintConsistency,
) domain.TrafficClassification {
    var result = base;
    result.classifier_version = 2;
    if (result.class.isClassifierBot()) return result;
    if (signals.navigator_webdriver) {
        result.class = .automation;
        result.rule = "signal.webdriver";
    } else if (hint == .mismatch) {
        result.class = .automation;
        result.rule = "signal.client-hint-mismatch";
    }
    return result;
}

fn matches(value: []const u8, rule: Rule) bool {
    return switch (rule.mode) {
        .prefix => value.len >= rule.pattern.len and
            std.ascii.eqlIgnoreCase(value[0..rule.pattern.len], rule.pattern),
        .substring => containsIgnoreCase(value, rule.pattern),
        .token => containsTokenIgnoreCase(value, rule.pattern),
    };
}

fn containsIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len > value.len) return false;
    for (0..value.len - needle.len + 1) |index| {
        if (std.ascii.eqlIgnoreCase(value[index..][0..needle.len], needle)) {
            return true;
        }
    }
    return false;
}

fn containsAnyIgnoreCase(value: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsIgnoreCase(value, needle)) return true;
    }
    return false;
}

fn containsTokenIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len > value.len) return false;
    for (0..value.len - needle.len + 1) |index| {
        if (!std.ascii.eqlIgnoreCase(value[index..][0..needle.len], needle)) {
            continue;
        }
        const starts_token = index == 0 or !std.ascii.isAlphanumeric(value[index - 1]);
        const after = index + needle.len;
        const ends_token = after == value.len or !std.ascii.isAlphanumeric(value[after]);
        if (starts_token and ends_token) return true;
    }
    return false;
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

test "UA classifier v1 covers rules modes case and false-positive traps" {
    const Case = struct {
        value: []const u8,
        class: domain.TrafficClass,
        rule: []const u8,
    };
    const cases = [_]Case{
        .{ .value = "", .class = .declared_bot, .rule = "ua.empty" },
        .{ .value = "Mozilla/5.0 compatible; Googlebot/2.1", .class = .declared_bot, .rule = "crawler.google" },
        .{ .value = "MOZILLA/5.0 BINGBOT/2.0", .class = .declared_bot, .rule = "crawler.bing" },
        .{ .value = "slurp", .class = .declared_bot, .rule = "crawler.yahoo" },
        .{ .value = "Mozilla/5.0 HeadlessChrome/151.0", .class = .automation, .rule = "headless.chrome" },
        .{ .value = "CURL/8.12.1", .class = .automation, .rule = "client.curl" },
        .{ .value = "prefix python-REQUESTS/2.32", .class = .automation, .rule = "client.python_requests" },
        .{ .value = "Mozilla bot test", .class = .declared_bot, .rule = "generic.bot" },
        .{ .value = "Mozilla/5.0 (Linux; Android 14; Cubot X70) AppleWebKit Chrome/120 Mobile", .class = .human_presumed, .rule = "" },
        .{ .value = "Abbott robotics SpiderMonkey", .class = .human_presumed, .rule = "" },
        .{ .value = "NotGooglebotLike", .class = .human_presumed, .rule = "" },
        .{ .value = "MyUptimeRobotTool", .class = .human_presumed, .rule = "" },
        .{ .value = "Mozilla/5.0 Safari/605.1.15", .class = .human_presumed, .rule = "" },
    };
    for (cases) |expected| {
        const actual = userAgent(expected.value);
        try std.testing.expectEqual(expected.class, actual.traffic.class);
        try std.testing.expectEqualStrings(expected.rule, actual.traffic.rule);
    }

    const cubot = userAgent(cases[8].value);
    try std.testing.expectEqualStrings("mobile", cubot.device);
    try std.testing.expectEqualStrings("Chrome", cubot.browser);
    try std.testing.expectEqualStrings("Android", cubot.os);
}

test "operator exclusion overrides UA evidence" {
    const google = userAgent("Googlebot/2.1");
    const excluded = google.traffic.withExclusion(.tracker);
    try std.testing.expectEqual(domain.TrafficClass.excluded, excluded.class);
    try std.testing.expectEqualStrings("exclude.tracker", excluded.rule);
}

test "classifier v2 applies bounded client hints and hard signal precedence" {
    const chrome = "Mozilla/5.0 Chrome/140.0 Safari/537.36";
    try std.testing.expectEqual(
        domain.ClientHintConsistency.consistent,
        clientHintConsistency(chrome, "\"Chromium\";v=\"140\""),
    );
    try std.testing.expectEqual(
        domain.ClientHintConsistency.absent_when_expected,
        clientHintConsistency(chrome, null),
    );
    try std.testing.expectEqual(
        domain.ClientHintConsistency.mismatch,
        clientHintConsistency(chrome, "\"Firefox\";v=\"140\""),
    );
    try std.testing.expectEqual(
        domain.ClientHintConsistency.mismatch,
        clientHintConsistency(chrome, "\"HeadlessChrome\";v=\"140\""),
    );
    try std.testing.expectEqual(
        domain.ClientHintConsistency.consistent,
        clientHintConsistency("Mozilla/5.0 Firefox/140.0", null),
    );
    var hint_at_limit: [512]u8 = undefined;
    var hint_over_limit: [513]u8 = undefined;
    @memset(&hint_at_limit, 'x');
    @memset(&hint_over_limit, 'x');
    try std.testing.expectEqual(
        domain.ClientHintConsistency.consistent,
        clientHintConsistency("Mozilla/5.0 Firefox/140.0", &hint_at_limit),
    );
    try std.testing.expectEqual(
        domain.ClientHintConsistency.mismatch,
        clientHintConsistency("Mozilla/5.0 Firefox/140.0", &hint_over_limit),
    );

    const base = userAgent(chrome).traffic;
    const webdriver = applySignals(base, .{ .version = 1, .navigator_webdriver = true }, .mismatch);
    try std.testing.expectEqual(domain.TrafficClass.automation, webdriver.class);
    try std.testing.expectEqual(@as(u16, 2), webdriver.classifier_version);
    try std.testing.expectEqualStrings("signal.webdriver", webdriver.rule);

    const mismatch = applySignals(base, .{}, .mismatch);
    try std.testing.expectEqual(domain.TrafficClass.automation, mismatch.class);
    try std.testing.expectEqualStrings("signal.client-hint-mismatch", mismatch.rule);

    const google = applySignals(
        userAgent("Googlebot/2.1").traffic,
        .{ .version = 1, .navigator_webdriver = true },
        .mismatch,
    );
    try std.testing.expectEqual(domain.TrafficClass.declared_bot, google.class);
    try std.testing.expectEqualStrings("crawler.google", google.rule);
}

test "UA classifier v1 table families are all reachable" {
    for (rules) |rule| {
        const value = switch (rule.mode) {
            .prefix => rule.pattern,
            .substring => try std.fmt.allocPrint(std.testing.allocator, "x{s}x", .{rule.pattern}),
            .token => try std.fmt.allocPrint(std.testing.allocator, "x {s} x", .{rule.pattern}),
        };
        defer if (rule.mode != .prefix) std.testing.allocator.free(value);
        const actual = userAgent(value);
        try std.testing.expectEqual(rule.class, actual.traffic.class);
        try std.testing.expectEqualStrings(rule.id, actual.traffic.rule);
    }
}
