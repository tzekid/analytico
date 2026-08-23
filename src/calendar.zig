const std = @import("std");
const analysis = @import("analysis.zig");
const timezone = @import("timezone.zig");

pub const Preset = enum {
    today,
    yesterday,
    last_7_days,
    last_30_days,
    month_to_date,
    last_90_days,
    custom,

    pub fn label(self: Preset) []const u8 {
        return switch (self) {
            .today => "Today",
            .yesterday => "Yesterday",
            .last_7_days => "Last 7 days",
            .last_30_days => "Last 30 days",
            .month_to_date => "Month to date",
            .last_90_days => "Last 90 days",
            .custom => "Custom",
        };
    }
};

pub const Range = struct {
    start: [10]u8,
    end: [10]u8,

    pub fn view(self: *const Range) analysis.LocalDateRange {
        return .{ .start = &self.start, .end = &self.end };
    }
};

pub const PresetOption = struct {
    preset: Preset,
    range: ?Range,
};

pub const ComparisonUnavailable = enum {
    before_supported_calendar,
};

pub const Context = struct {
    timezone_name: []const u8,
    utc_range: timezone.Range,
    comparison: analysis.Comparison,
    comparison_range: ?Range,
    comparison_utc_range: ?timezone.Range,
    comparison_unavailable: ?ComparisonUnavailable,
    includes_incomplete_today: bool,
    selected_preset: Preset,
    presets: [7]PresetOption,
};

pub fn rangeForPreset(
    zone: timezone.Zone,
    now_utc_seconds: i64,
    preset: Preset,
) !Range {
    if (preset == .custom) return error.CustomPresetNeedsRange;
    const today_text = (try zone.localAt(now_utc_seconds)).date;
    const today = try timezone.Date.parse(&today_text);
    const start = switch (preset) {
        .today => today,
        .yesterday => try today.addDays(-1),
        .last_7_days => try today.addDays(-6),
        .last_30_days => try today.addDays(-29),
        .month_to_date => today.firstOfMonth(),
        .last_90_days => try today.addDays(-89),
        .custom => unreachable,
    };
    const end = if (preset == .yesterday) start else today;
    return .{ .start = try start.format(), .end = try end.format() };
}

pub fn resolve(
    zone: timezone.Zone,
    timezone_name: []const u8,
    now_utc_seconds: i64,
    requested: analysis.LocalDateRange,
    comparison: analysis.Comparison,
) !Context {
    try requested.validate();
    const requested_start = try timezone.Date.parse(requested.start);
    const requested_end = try timezone.Date.parse(requested.end);
    const current = Range{
        .start = try requested_start.format(),
        .end = try requested_end.format(),
    };
    const today_text = (try zone.localAt(now_utc_seconds)).date;
    const today = try timezone.Date.parse(&today_text);

    var options: [7]PresetOption = undefined;
    inline for (std.meta.tags(Preset), 0..) |preset, index| {
        options[index] = .{
            .preset = preset,
            .range = if (preset == .custom)
                current
            else
                rangeForPreset(zone, now_utc_seconds, preset) catch |err| switch (err) {
                    error.DateOutOfRange => null,
                    else => return err,
                },
        };
    }

    var selected: Preset = .custom;
    for (options[0 .. options.len - 1]) |option| {
        if (option.range != null and rangesEqual(current, option.range.?)) {
            selected = option.preset;
            break;
        }
    }

    const comparison_resolution = try resolveComparison(
        requested_start,
        requested_end,
        comparison,
    );
    const comparison_utc = if (comparison_resolution.range) |range|
        try zone.rangeForInclusiveDates(&range.start, &range.end)
    else
        null;
    return .{
        .timezone_name = timezone_name,
        .utc_range = try zone.rangeForInclusiveDates(&current.start, &current.end),
        .comparison = comparison,
        .comparison_range = comparison_resolution.range,
        .comparison_utc_range = comparison_utc,
        .comparison_unavailable = comparison_resolution.unavailable,
        .includes_incomplete_today = requested_start.dayNumber() <= today.dayNumber() and
            requested_end.dayNumber() >= today.dayNumber(),
        .selected_preset = selected,
        .presets = options,
    };
}

const ComparisonResolution = struct {
    range: ?Range = null,
    unavailable: ?ComparisonUnavailable = null,
};

fn resolveComparison(
    start: timezone.Date,
    end: timezone.Date,
    comparison: analysis.Comparison,
) !ComparisonResolution {
    if (comparison == .none) return .{};
    const dates = end.dayNumber() - start.dayNumber() + 1;
    const resolved_start, const resolved_end = switch (comparison) {
        .none => unreachable,
        .previous => values: {
            const comparison_end = start.addDays(-1) catch
                return .{ .unavailable = .before_supported_calendar };
            const comparison_start = comparison_end.addDays(-(dates - 1)) catch
                return .{ .unavailable = .before_supported_calendar };
            break :values .{ comparison_start, comparison_end };
        },
        .previous_year => values: {
            const comparison_start = start.previousYear() catch
                return .{ .unavailable = .before_supported_calendar };
            const comparison_end = end.previousYear() catch
                return .{ .unavailable = .before_supported_calendar };
            break :values .{ comparison_start, comparison_end };
        },
    };
    return .{ .range = .{
        .start = try resolved_start.format(),
        .end = try resolved_end.format(),
    } };
}

fn rangesEqual(left: Range, right: Range) bool {
    return std.mem.eql(u8, &left.start, &right.start) and
        std.mem.eql(u8, &left.end, &right.end);
}

test "site-local presets comparisons and incomplete metadata are exact" {
    const allocator = std.testing.allocator;
    var berlin = try timezone.load(
        allocator,
        std.testing.io,
        timezone.default_zoneinfo_root,
        "Europe/Berlin",
    );
    defer berlin.deinit(allocator);

    const leap_now = 1_709_208_000; // 2024-02-29T12:00:00Z
    const last_30 = try rangeForPreset(berlin, leap_now, .last_30_days);
    try std.testing.expectEqualStrings("2024-01-31", &last_30.start);
    try std.testing.expectEqualStrings("2024-02-29", &last_30.end);
    const context = try resolve(
        berlin,
        "Europe/Berlin",
        leap_now,
        last_30.view(),
        .previous,
    );
    try std.testing.expectEqual(.last_30_days, context.selected_preset);
    try std.testing.expect(context.includes_incomplete_today);
    try std.testing.expectEqualStrings("2024-01-01", &context.comparison_range.?.start);
    try std.testing.expectEqualStrings("2024-01-30", &context.comparison_range.?.end);
    try std.testing.expectEqual(@as(i64, 30), (try timezone.Date.parse(&context.comparison_range.?.end)).dayNumber() -
        (try timezone.Date.parse(&context.comparison_range.?.start)).dayNumber() + 1);
    try std.testing.expectEqual(
        @as(i64, 30 * std.time.s_per_day),
        context.comparison_utc_range.?.end_utc_seconds -
            context.comparison_utc_range.?.start_utc_seconds,
    );
}

test "previous year is calendar aligned and leap ranges may differ in length" {
    const allocator = std.testing.allocator;
    var utc = try timezone.load(
        allocator,
        std.testing.io,
        timezone.default_zoneinfo_root,
        "UTC",
    );
    defer utc.deinit(allocator);
    const context = try resolve(
        utc,
        "UTC",
        1_709_208_000,
        .{ .start = "2024-02-01", .end = "2024-02-29" },
        .previous_year,
    );
    try std.testing.expectEqualStrings("2023-02-01", &context.comparison_range.?.start);
    try std.testing.expectEqualStrings("2023-02-28", &context.comparison_range.?.end);
    try std.testing.expectEqual(@as(i64, 29), (try timezone.Date.parse("2024-02-29")).dayNumber() -
        (try timezone.Date.parse("2024-02-01")).dayNumber() + 1);
    try std.testing.expectEqual(@as(i64, 28), (try timezone.Date.parse(&context.comparison_range.?.end)).dayNumber() -
        (try timezone.Date.parse(&context.comparison_range.?.start)).dayNumber() + 1);
}

test "DST UTC bounds and calendar lower-bound unavailability remain typed" {
    const allocator = std.testing.allocator;
    var berlin = try timezone.load(
        allocator,
        std.testing.io,
        timezone.default_zoneinfo_root,
        "Europe/Berlin",
    );
    defer berlin.deinit(allocator);
    const spring = try resolve(
        berlin,
        "Europe/Berlin",
        1_711_886_400,
        .{ .start = "2024-03-31", .end = "2024-03-31" },
        .none,
    );
    try std.testing.expectEqual(@as(i64, 23 * 3600), spring.utc_range.end_utc_seconds - spring.utc_range.start_utc_seconds);
    const autumn = try resolve(
        berlin,
        "Europe/Berlin",
        1_730_030_400,
        .{ .start = "2024-10-27", .end = "2024-10-27" },
        .none,
    );
    try std.testing.expectEqual(@as(i64, 25 * 3600), autumn.utc_range.end_utc_seconds - autumn.utc_range.start_utc_seconds);
    const unavailable = try resolve(
        berlin,
        "Europe/Berlin",
        43_200,
        .{ .start = "1970-01-01", .end = "1970-01-01" },
        .previous,
    );
    try std.testing.expectEqual(@as(?Range, null), unavailable.comparison_range);
    try std.testing.expectEqual(
        ComparisonUnavailable.before_supported_calendar,
        unavailable.comparison_unavailable.?,
    );
}

test "month and century rules stay bounded" {
    const allocator = std.testing.allocator;
    var utc = try timezone.load(
        allocator,
        std.testing.io,
        timezone.default_zoneinfo_root,
        "UTC",
    );
    defer utc.deinit(allocator);
    const month = try rangeForPreset(utc, 4_107_585_600, .month_to_date);
    try std.testing.expectEqualStrings("2100-03-01", &month.start);
    try std.testing.expectEqualStrings("2100-03-01", &month.end);
    const prior_year = try (try timezone.Date.parse("2100-02-28")).previousYear();
    try std.testing.expectEqualStrings(
        "2099-02-28",
        &(try prior_year.format()),
    );
    try std.testing.expectError(
        error.InvalidAnalysisRange,
        resolve(
            utc,
            "UTC",
            1_709_208_000,
            .{ .start = "2023-01-01", .end = "2024-02-29" },
            .none,
        ),
    );
}

test "every moving preset uses the selected site local date" {
    const allocator = std.testing.allocator;
    var utc = try timezone.load(
        allocator,
        std.testing.io,
        timezone.default_zoneinfo_root,
        "UTC",
    );
    defer utc.deinit(allocator);
    const now = 1_709_208_000; // 2024-02-29T12:00:00Z
    const expected = [_]struct {
        preset: Preset,
        start: []const u8,
        end: []const u8,
    }{
        .{ .preset = .today, .start = "2024-02-29", .end = "2024-02-29" },
        .{ .preset = .yesterday, .start = "2024-02-28", .end = "2024-02-28" },
        .{ .preset = .last_7_days, .start = "2024-02-23", .end = "2024-02-29" },
        .{ .preset = .last_30_days, .start = "2024-01-31", .end = "2024-02-29" },
        .{ .preset = .month_to_date, .start = "2024-02-01", .end = "2024-02-29" },
        .{ .preset = .last_90_days, .start = "2023-12-02", .end = "2024-02-29" },
    };
    for (expected) |item| {
        const range = try rangeForPreset(utc, now, item.preset);
        try std.testing.expectEqualStrings(item.start, &range.start);
        try std.testing.expectEqualStrings(item.end, &range.end);
    }
    try std.testing.expectError(
        error.CustomPresetNeedsRange,
        rangeForPreset(utc, now, .custom),
    );
}

test "preset date follows the site timezone across a UTC date boundary" {
    const allocator = std.testing.allocator;
    var utc = try timezone.load(
        allocator,
        std.testing.io,
        timezone.default_zoneinfo_root,
        "UTC",
    );
    defer utc.deinit(allocator);
    var berlin = try timezone.load(
        allocator,
        std.testing.io,
        timezone.default_zoneinfo_root,
        "Europe/Berlin",
    );
    defer berlin.deinit(allocator);

    const now = 1_704_151_800; // 2024-01-01T23:30:00Z
    const utc_today = try rangeForPreset(utc, now, .today);
    const berlin_today = try rangeForPreset(berlin, now, .today);
    try std.testing.expectEqualStrings("2024-01-01", &utc_today.start);
    try std.testing.expectEqualStrings("2024-01-02", &berlin_today.start);
    try std.testing.expectEqualStrings(&berlin_today.start, &berlin_today.end);
}

test "future custom range remains complete rather than inventing current data" {
    const allocator = std.testing.allocator;
    var utc = try timezone.load(
        allocator,
        std.testing.io,
        timezone.default_zoneinfo_root,
        "UTC",
    );
    defer utc.deinit(allocator);
    const context = try resolve(
        utc,
        "UTC",
        1_709_208_000,
        .{ .start = "2025-01-01", .end = "2025-01-02" },
        .none,
    );
    try std.testing.expect(!context.includes_incomplete_today);
    try std.testing.expectEqual(Preset.custom, context.selected_preset);
    try std.testing.expectEqual(@as(?Range, null), context.comparison_range);
    try std.testing.expectEqual(@as(?ComparisonUnavailable, null), context.comparison_unavailable);
}
