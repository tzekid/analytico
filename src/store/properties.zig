const std = @import("std");
const domain = @import("../domain.zig");
const property = @import("../property.zig");
const duckdb = @import("duckdb.zig");

pub const Source = enum {
    event,
    user_trait,
};

pub const Window = struct {
    source: Source,
    site_id: []const u8,
    start_utc_micros: i64,
    end_utc_micros: i64,
    event_name: ?[]const u8 = null,
};

pub const Query = struct {
    window: Window,
    property_name: []const u8,
};

pub const ObservedProperty = struct {
    name: []u8,
    scalar_type: property.ScalarType,
    event_count: i64,
};

pub const Catalog = struct {
    entries: []ObservedProperty,
    property_count: i64,
    truncated: bool,
};

pub const BreakdownRow = struct {
    scalar_type: property.ScalarType,
    value: []u8,
    event_count: i64,
};

pub const Breakdown = struct {
    rows: []BreakdownRow,
    bucket_count: i64,
    truncated: bool,
};

pub fn discover(
    allocator: std.mem.Allocator,
    database: *duckdb.Database,
    window: Window,
    limit: u16,
) !Catalog {
    try validateWindow(window);
    try validateLimit(limit);
    const source = sourceParts(window.source);
    const event_clause = if (window.event_name != null) "AND event_name = ?" else "";
    var sql_buffer: [4096]u8 = undefined;
    const sql = try std.fmt.bufPrintSentinel(
        &sql_buffer,
        \\WITH base AS (
        \\  SELECT {s} AS document
        \\  FROM events
        \\  WHERE site_id = ?
        \\    AND occurred_at_utc_micros >= ?
        \\    AND occurred_at_utc_micros < ?
        \\    AND kind = {d}
        \\    AND traffic_class IN (1, 5)
        \\    {s}
        \\), expanded AS (
        \\  SELECT document, UNNEST(json_keys(document)) AS property_name
        \\  FROM base
        \\), grouped AS (
        \\  SELECT property_name,
        \\         json_type(document, '/' || property_name) AS json_kind,
        \\         count(*)::BIGINT AS event_count
        \\  FROM expanded
        \\  GROUP BY property_name, json_kind
        \\), names AS (
        \\  SELECT DISTINCT property_name FROM grouped
        \\), selected AS (
        \\  SELECT property_name, (SELECT count(*) FROM names)::BIGINT AS property_count
        \\  FROM names
        \\  ORDER BY property_name
        \\  LIMIT ?
        \\)
        \\SELECT grouped.property_name,
        \\       CASE grouped.json_kind
        \\         WHEN 'VARCHAR' THEN 1
        \\         WHEN 'BIGINT' THEN 2
        \\         WHEN 'UBIGINT' THEN 2
        \\         WHEN 'DOUBLE' THEN 3
        \\         WHEN 'DECIMAL' THEN 3
        \\         WHEN 'BOOLEAN' THEN 4
        \\         WHEN 'NULL' THEN 5
        \\         ELSE 0
        \\       END AS type_code,
        \\       grouped.event_count,
        \\       selected.property_count
        \\FROM grouped
        \\JOIN selected USING (property_name)
        \\ORDER BY grouped.property_name, type_code
    ,
        .{ source.column, source.kind, event_clause },
        0,
    );
    var statement = try database.prepare(sql);
    defer statement.deinit();
    const index = try bindWindow(&statement, window, 1);
    try statement.bindInt64(index, limit);
    var result = try statement.execute();
    defer result.deinit();
    if (result.columnCount() != 4) return error.InvalidPropertyCatalog;

    var entries: std.ArrayList(ObservedProperty) = .empty;
    for (0..result.rowCount()) |row| {
        try entries.append(allocator, .{
            .name = try result.text(allocator, 0, row),
            .scalar_type = try scalarType(result.int64(1, row)),
            .event_count = result.int64(2, row),
        });
    }
    const property_count = if (result.rowCount() == 0)
        0
    else
        result.int64(3, 0);
    return .{
        .entries = try entries.toOwnedSlice(allocator),
        .property_count = property_count,
        .truncated = property_count > limit,
    };
}

pub fn countMatching(
    allocator: std.mem.Allocator,
    database: *duckdb.Database,
    query: Query,
    predicate: property.Predicate,
) !i64 {
    try validateQuery(query);
    var canonical_decimal: ?[]u8 = null;
    defer if (canonical_decimal) |value| allocator.free(value);
    switch (predicate) {
        .string => |value| try validateString(value),
        .decimal => |value| canonical_decimal = try property.canonicalDecimal(
            allocator,
            value,
        ),
        else => {},
    }
    const source = sourceParts(query.window.source);
    const event_clause = if (query.window.event_name != null) "AND event_name = ?" else "";
    const predicate_sql: []const u8 = switch (predicate) {
        .string =>
        \\json_type({column}, ?) = 'VARCHAR'
        \\AND json_extract_string({column}, ?) = ?
        ,
        .integer =>
        \\json_type({column}, ?) IN ('BIGINT', 'UBIGINT')
        \\AND TRY_CAST(json_extract_string({column}, ?) AS BIGINT) = ?
        ,
        .decimal =>
        \\json_type({column}, ?) IN ('DOUBLE', 'DECIMAL')
        \\AND TRY_CAST(json_extract_string({column}, ?) AS DECIMAL(18,6)) =
        \\    CAST(? AS DECIMAL(18,6))
        ,
        .boolean =>
        \\json_type({column}, ?) = 'BOOLEAN'
        \\AND json_extract_string({column}, ?) = ?
        ,
        .null => "json_type({column}, ?) = 'NULL'",
        .missing => "json_type({column}, ?) IS NULL",
    };
    const rendered_predicate = try std.mem.replaceOwned(
        u8,
        allocator,
        predicate_sql,
        "{column}",
        source.column,
    );
    defer allocator.free(rendered_predicate);

    var sql_buffer: [3072]u8 = undefined;
    const sql = try std.fmt.bufPrintSentinel(
        &sql_buffer,
        \\SELECT count(*)::BIGINT
        \\FROM events
        \\WHERE site_id = ?
        \\  AND occurred_at_utc_micros >= ?
        \\  AND occurred_at_utc_micros < ?
        \\  AND kind = {d}
        \\  AND traffic_class IN (1, 5)
        \\  {s}
        \\  AND {s}
    ,
        .{ source.kind, event_clause, rendered_predicate },
        0,
    );
    var statement = try database.prepare(sql);
    defer statement.deinit();
    var index = try bindWindow(&statement, query.window, 1);
    const pointer = try property.jsonPointer(allocator, query.property_name);
    defer allocator.free(pointer);
    try statement.bindText(index, pointer);
    index += 1;
    switch (predicate) {
        .string => |value| {
            try statement.bindText(index, pointer);
            try statement.bindText(index + 1, value);
        },
        .integer => |value| {
            try statement.bindText(index, pointer);
            try statement.bindInt64(index + 1, value);
        },
        .decimal => {
            try statement.bindText(index, pointer);
            try statement.bindText(index + 1, canonical_decimal.?);
        },
        .boolean => |value| {
            try statement.bindText(index, pointer);
            try statement.bindText(index + 1, if (value) "true" else "false");
        },
        .null, .missing => {},
    }
    var result = try statement.execute();
    defer result.deinit();
    if (result.rowCount() != 1 or result.columnCount() != 1) {
        return error.InvalidPropertyCount;
    }
    return result.int64(0, 0);
}

pub fn breakdown(
    allocator: std.mem.Allocator,
    database: *duckdb.Database,
    query: Query,
    limit: u16,
) !Breakdown {
    try validateQuery(query);
    try validateLimit(limit);
    const source = sourceParts(query.window.source);
    const event_clause = if (query.window.event_name != null) "AND event_name = ?" else "";
    var sql_buffer: [4096]u8 = undefined;
    const sql = try std.fmt.bufPrintSentinel(
        &sql_buffer,
        \\WITH extracted AS (
        \\  SELECT json_extract({s}, ?) AS json_value
        \\  FROM events
        \\  WHERE site_id = ?
        \\    AND occurred_at_utc_micros >= ?
        \\    AND occurred_at_utc_micros < ?
        \\    AND kind = {d}
        \\    AND traffic_class IN (1, 5)
        \\    {s}
        \\), typed AS (
        \\  SELECT json_type(json_value) AS json_kind,
        \\         json_extract_string(json_value, '$') AS raw_value
        \\  FROM extracted
        \\), normalized AS (
        \\  SELECT CASE
        \\           WHEN json_kind IS NULL THEN 6
        \\           WHEN json_kind = 'VARCHAR' THEN 1
        \\           WHEN json_kind IN ('BIGINT', 'UBIGINT') THEN 2
        \\           WHEN json_kind IN ('DOUBLE', 'DECIMAL') THEN 3
        \\           WHEN json_kind = 'BOOLEAN' THEN 4
        \\           WHEN json_kind = 'NULL' THEN 5
        \\           ELSE 0
        \\         END AS type_code,
        \\         CASE
        \\           WHEN json_kind IS NULL OR json_kind = 'NULL' THEN ''
        \\           WHEN json_kind IN ('DOUBLE', 'DECIMAL') THEN
        \\             CAST(TRY_CAST(raw_value AS DECIMAL(18,6)) AS VARCHAR)
        \\           ELSE raw_value
        \\         END AS normalized_value
        \\  FROM typed
        \\), grouped AS (
        \\  SELECT type_code, normalized_value, count(*)::BIGINT AS event_count
        \\  FROM normalized
        \\  GROUP BY type_code, normalized_value
        \\)
        \\SELECT type_code, normalized_value, event_count,
        \\       count(*) OVER ()::BIGINT AS bucket_count
        \\FROM grouped
        \\ORDER BY event_count DESC, type_code, normalized_value
        \\LIMIT ?
    ,
        .{ source.column, source.kind, event_clause },
        0,
    );
    var statement = try database.prepare(sql);
    defer statement.deinit();
    const pointer = try property.jsonPointer(allocator, query.property_name);
    defer allocator.free(pointer);
    try statement.bindText(1, pointer);
    const index = try bindWindow(&statement, query.window, 2);
    try statement.bindInt64(index, limit);
    var result = try statement.execute();
    defer result.deinit();
    if (result.columnCount() != 4) return error.InvalidPropertyBreakdown;

    var rows: std.ArrayList(BreakdownRow) = .empty;
    for (0..result.rowCount()) |row| {
        try rows.append(allocator, .{
            .scalar_type = try scalarType(result.int64(0, row)),
            .value = try result.text(allocator, 1, row),
            .event_count = result.int64(2, row),
        });
    }
    const bucket_count = if (result.rowCount() == 0)
        0
    else
        result.int64(3, 0);
    return .{
        .rows = try rows.toOwnedSlice(allocator),
        .bucket_count = bucket_count,
        .truncated = bucket_count > limit,
    };
}

const SourceParts = struct {
    column: []const u8,
    kind: u8,
};

fn sourceParts(source: Source) SourceParts {
    return switch (source) {
        .event => .{ .column = "properties_json", .kind = 2 },
        .user_trait => .{ .column = "user_traits_json", .kind = 4 },
    };
}

fn validateWindow(window: Window) !void {
    try domain.validateUuid(window.site_id);
    if (window.start_utc_micros < 0 or
        window.end_utc_micros <= window.start_utc_micros or
        window.end_utc_micros - window.start_utc_micros >
            property.max_query_range_micros)
    {
        return error.InvalidPropertyRange;
    }
    if (window.event_name) |event_name| {
        if (window.source != .event) return error.InvalidPropertyScope;
        try domain.validateIdentifier(event_name);
    }
}

fn validateQuery(query: Query) !void {
    try validateWindow(query.window);
    try domain.validateIdentifier(query.property_name);
}

fn validateLimit(limit: u16) !void {
    if (limit == 0 or limit > property.max_result_rows) {
        return error.InvalidPropertyLimit;
    }
}

fn validateString(value: []const u8) !void {
    if (value.len > 512 or !std.unicode.utf8ValidateSlice(value)) {
        return error.InvalidPropertyString;
    }
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        const byte = value[index];
        if (byte < 0x20 or byte == 0x7f) return error.InvalidPropertyString;
        if (byte == 0xc2 and index + 1 < value.len and
            value[index + 1] >= 0x80 and value[index + 1] <= 0x9f)
        {
            return error.InvalidPropertyString;
        }
    }
}

fn bindWindow(
    statement: *duckdb.Statement,
    window: Window,
    first_index: usize,
) !usize {
    var index = first_index;
    try statement.bindText(index, window.site_id);
    index += 1;
    try statement.bindInt64(index, window.start_utc_micros);
    index += 1;
    try statement.bindInt64(index, window.end_utc_micros);
    index += 1;
    if (window.event_name) |event_name| {
        try statement.bindText(index, event_name);
        index += 1;
    }
    return index;
}

fn scalarType(code: i64) !property.ScalarType {
    if (code < @backingInt(property.ScalarType.string) or
        code > @backingInt(property.ScalarType.missing))
    {
        return error.InvalidStoredPropertyType;
    }
    return @fromBackingInt(@intCast(code));
}

test "property query inputs are bounded before DuckDB" {
    const valid = Window{
        .source = .event,
        .site_id = "00000000-0000-4000-8000-000000000001",
        .start_utc_micros = 1,
        .end_utc_micros = 1 + property.max_query_range_micros,
        .event_name = "purchase",
    };
    try validateWindow(valid);
    try validateLimit(property.max_result_rows);
    try std.testing.expectError(
        error.InvalidPropertyRange,
        validateWindow(.{
            .source = .event,
            .site_id = valid.site_id,
            .start_utc_micros = 1,
            .end_utc_micros = 2 + property.max_query_range_micros,
        }),
    );
    try std.testing.expectError(error.InvalidPropertyLimit, validateLimit(0));
    try std.testing.expectError(error.InvalidPropertyLimit, validateLimit(101));
    try std.testing.expectError(
        error.InvalidPropertyScope,
        validateWindow(.{
            .source = .user_trait,
            .site_id = valid.site_id,
            .start_utc_micros = 1,
            .end_utc_micros = 2,
            .event_name = "identify",
        }),
    );
    try std.testing.expectError(
        error.InvalidIdentifier,
        validateQuery(.{
            .window = valid,
            .property_name = "not/a/pointer",
        }),
    );
}
