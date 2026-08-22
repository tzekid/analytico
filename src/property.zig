const std = @import("std");
const domain = @import("domain.zig");

pub const max_query_range_micros: i64 = 400 * 24 * 60 * 60 * 1_000_000;
pub const max_result_rows: u16 = 100;

pub const ScalarType = enum(u8) {
    string = 1,
    integer = 2,
    decimal = 3,
    boolean = 4,
    null = 5,
    missing = 6,
};

pub const Predicate = union(enum) {
    string: []const u8,
    integer: i64,
    decimal: []const u8,
    boolean: bool,
    null: void,
    missing: void,
};

pub fn numberType(value: []const u8) !ScalarType {
    if (std.mem.findScalar(u8, value, '.') == null) {
        if (value.len == 0 or value[0] == '+') {
            return error.InvalidPropertyNumber;
        }
        const digits = if (value[0] == '-') value[1..] else value;
        if (digits.len == 0 or (digits.len > 1 and digits[0] == '0')) {
            return error.InvalidPropertyNumber;
        }
        _ = std.fmt.parseInt(i64, value, 10) catch
            return error.InvalidPropertyNumber;
        return .integer;
    }
    _ = try decimalParts(value);
    return .decimal;
}

pub fn writeCanonicalNumber(
    writer: *std.Io.Writer,
    value: []const u8,
) !void {
    switch (try numberType(value)) {
        .integer => {
            const parsed = std.fmt.parseInt(i64, value, 10) catch
                return error.InvalidPropertyNumber;
            try writer.print("{d}", .{parsed});
        },
        .decimal => try writeCanonicalDecimal(writer, value),
        else => unreachable,
    }
}

pub fn canonicalDecimal(
    allocator: std.mem.Allocator,
    value: []const u8,
) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    try writeCanonicalDecimal(&output.writer, value);
    return output.toOwnedSlice();
}

pub fn jsonPointer(
    allocator: std.mem.Allocator,
    property_name: []const u8,
) ![]u8 {
    try domain.validateIdentifier(property_name);
    return std.fmt.allocPrint(allocator, "/{s}", .{property_name});
}

fn writeCanonicalDecimal(
    writer: *std.Io.Writer,
    value: []const u8,
) !void {
    const parts = try decimalParts(value);
    if (parts.negative and parts.nonzero) try writer.writeByte('-');
    try writer.writeAll(parts.integer);
    try writer.writeByte('.');
    try writer.writeAll(parts.fraction);
    for (parts.fraction.len..6) |_| try writer.writeByte('0');
}

const DecimalParts = struct {
    negative: bool,
    nonzero: bool,
    integer: []const u8,
    fraction: []const u8,
};

fn decimalParts(value: []const u8) !DecimalParts {
    if (value.len == 0 or value.len > 20) {
        return error.InvalidPropertyNumber;
    }
    const negative = value[0] == '-';
    const start: usize = if (negative) 1 else 0;
    if (start == value.len or value[start] == '+') {
        return error.InvalidPropertyNumber;
    }
    const relative_dot = std.mem.findScalar(u8, value[start..], '.') orelse
        return error.InvalidPropertyNumber;
    const dot = start + relative_dot;
    const integer = value[start..dot];
    const fraction = value[dot + 1 ..];
    if (integer.len == 0 or integer.len > 12 or fraction.len == 0 or
        fraction.len > 6 or (integer.len > 1 and integer[0] == '0'))
    {
        return error.InvalidPropertyNumber;
    }
    var nonzero = false;
    for (integer) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidPropertyNumber;
        nonzero = nonzero or byte != '0';
    }
    for (fraction) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidPropertyNumber;
        nonzero = nonzero or byte != '0';
    }
    return .{
        .negative = negative,
        .nonzero = nonzero,
        .integer = integer,
        .fraction = fraction,
    };
}

test "property numbers retain integer and exact decimal types" {
    const allocator = std.testing.allocator;

    try std.testing.expectEqual(ScalarType.integer, try numberType("14"));
    try std.testing.expectEqual(ScalarType.integer, try numberType("-0"));
    try std.testing.expectEqual(ScalarType.decimal, try numberType("14.25"));

    const decimal = try canonicalDecimal(allocator, "-14.25");
    defer allocator.free(decimal);
    try std.testing.expectEqualStrings("-14.250000", decimal);

    const negative_zero = try canonicalDecimal(allocator, "-0.0");
    defer allocator.free(negative_zero);
    try std.testing.expectEqualStrings("0.000000", negative_zero);
}

test "property number bounds reject approximation and overflow" {
    for ([_][]const u8{
        "",
        "+1",
        "1e2",
        "1.2345678",
        "1234567890123.0",
        "01.0",
        "9223372036854775808",
    }) |value| {
        try std.testing.expectError(error.InvalidPropertyNumber, numberType(value));
    }
    try std.testing.expectEqual(
        ScalarType.integer,
        try numberType("-9223372036854775808"),
    );
    const maximum = try canonicalDecimal(std.testing.allocator, "999999999999.999999");
    defer std.testing.allocator.free(maximum);
    try std.testing.expectEqualStrings("999999999999.999999", maximum);
}

test "property JSON pointers preserve allowed punctuation only" {
    const pointer = try jsonPointer(std.testing.allocator, "plan.tier:v2");
    defer std.testing.allocator.free(pointer);
    try std.testing.expectEqualStrings("/plan.tier:v2", pointer);
    try std.testing.expectError(
        error.InvalidIdentifier,
        jsonPointer(std.testing.allocator, "plan/tier"),
    );
}
