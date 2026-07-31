const std = @import("std");
const turso = @import("turso");
const duckdb = @import("../store/duckdb.zig");
const meta = @import("../store/meta.zig");

const fixture_site_id = "00000000-0000-4000-8000-000000000001";

pub fn run(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
) !void {
    try turso.setup(.{});

    const meta_path = try std.fs.path.join(allocator, &.{ directory, "meta.db" });
    defer allocator.free(meta_path);
    const event_path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    defer allocator.free(event_path);

    var metadata = try meta.Store.open(allocator, meta_path);
    defer metadata.deinit();
    try metadata.migrateProbe();
    try metadata.seedProbeSite();

    var events = try duckdb.Database.open(allocator, event_path);
    defer events.deinit();
    try seedEvents(&events);

    const sites = try metadata.siteCount();
    const event_count = try scalar(&events, "SELECT COUNT(*) FROM m0_events");
    const page_views = try scalar(&events, "SELECT COUNT(*) FROM m0_events WHERE kind = 1");
    const daily_uniques = try scalar(
        &events,
        "SELECT COUNT(DISTINCT visitor_day_id) FROM m0_events WHERE kind = 1",
    );
    const entry_sessions = try scalar(
        &events,
        \\SELECT COUNT(*) FROM (
        \\  SELECT visitor_day_id,
        \\         row_number() OVER (
        \\           PARTITION BY visitor_day_id ORDER BY received_at_utc_micros, event_id
        \\         ) AS position
        \\  FROM m0_events
        \\  WHERE kind = 1
        \\) entries WHERE position = 1
        ,
    );
    const funnel_completions = try scalar(
        &events,
        \\SELECT COUNT(*) FROM (
        \\  SELECT visitor_day_id
        \\  FROM m0_events
        \\  GROUP BY visitor_day_id
        \\  HAVING min(CASE WHEN path = '/pricing' THEN received_at_utc_micros END)
        \\       < min(CASE WHEN event_name = 'signup' THEN received_at_utc_micros END)
        \\) completed
        ,
    );
    try events.checkpoint();

    try output.print(
        "{{\"turso_version\":\"{s}\",\"duckdb_version\":\"{s}\"," ++
            "\"sites\":{d},\"events\":{d},\"page_views\":{d}," ++
            "\"daily_uniques\":{d},\"entry_sessions\":{d}," ++
            "\"funnel_completions\":{d}}}\n",
        .{
            turso.runtimeVersion() catch "unknown",
            duckdb.Database.version(),
            sites,
            event_count,
            page_views,
            daily_uniques,
            entry_sessions,
            funnel_completions,
        },
    );
}

pub fn verify(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
) !void {
    try turso.setup(.{});

    const meta_path = try std.fs.path.join(allocator, &.{ directory, "meta.db" });
    defer allocator.free(meta_path);
    const event_path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    defer allocator.free(event_path);

    var metadata = try meta.Store.open(allocator, meta_path);
    defer metadata.deinit();
    var events = try duckdb.Database.open(allocator, event_path);
    defer events.deinit();

    const sites = try metadata.siteCount();
    const event_count = try scalar(&events, "SELECT COUNT(*) FROM m0_events");
    if (sites != 1 or event_count != 6) return error.ProbeVerificationFailed;
    try output.writeAll("probe restart verification passed\n");
}

pub fn benchmark(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
) !void {
    const event_path = try std.fs.path.join(allocator, &.{ directory, "benchmark.duckdb" });
    defer allocator.free(event_path);

    var events = try duckdb.Database.open(allocator, event_path);
    defer events.deinit();
    try events.exec(
        \\DROP TABLE IF EXISTS benchmark_events;
        \\CREATE TABLE benchmark_events AS
        \\SELECT
        \\  i::BIGINT AS event_id,
        \\  '00000000-0000-4000-8000-000000000001'::VARCHAR AS site_id,
        \\  (1700000000000000 + i * 1000000)::BIGINT AS received_at_utc_micros,
        \\  CASE WHEN i % 5 = 4 THEN 2 ELSE 1 END::UTINYINT AS kind,
        \\  CASE WHEN i % 5 = 4 THEN 'signup' ELSE 'pageview' END::VARCHAR AS event_name,
        \\  CASE
        \\    WHEN i % 5 = 0 THEN '/'
        \\    WHEN i % 5 = 1 THEN '/pricing'
        \\    WHEN i % 5 = 2 THEN '/docs'
        \\    ELSE '/thanks'
        \\  END::VARCHAR AS path,
        \\  ('visitor-' || ((i // 5) % 5000)::VARCHAR)::VARCHAR AS visitor_day_id
        \\FROM range(1000000) rows(i);
    );
    try events.checkpoint();

    const started = std.Io.Clock.awake.now(io).nanoseconds;
    const page_views = try scalar(
        &events,
        "SELECT COUNT(*) FROM benchmark_events WHERE kind = 1",
    );
    const unique_visitors = try scalar(
        &events,
        "SELECT COUNT(DISTINCT visitor_day_id) FROM benchmark_events WHERE kind = 1",
    );
    const funnel_completions = try scalar(
        &events,
        \\SELECT COUNT(*) FROM (
        \\  SELECT visitor_day_id
        \\  FROM benchmark_events
        \\  GROUP BY visitor_day_id
        \\  HAVING min(CASE WHEN path = '/pricing' THEN received_at_utc_micros END)
        \\       < min(CASE WHEN event_name = 'signup' THEN received_at_utc_micros END)
        \\) completed
        ,
    );
    const elapsed_ns = std.Io.Clock.awake.now(io).nanoseconds - started;

    try output.print(
        "{{\"events\":1000000,\"page_views\":{d},\"daily_uniques\":{d}," ++
            "\"funnel_completions\":{d},\"report_elapsed_ns\":{d}}}\n",
        .{ page_views, unique_visitors, funnel_completions, elapsed_ns },
    );
}

fn seedEvents(events: *duckdb.Database) !void {
    try events.exec(
        \\CREATE TABLE IF NOT EXISTS m0_events (
        \\  event_id BIGINT PRIMARY KEY,
        \\  site_id VARCHAR NOT NULL,
        \\  received_at_utc_micros BIGINT NOT NULL,
        \\  kind UTINYINT NOT NULL,
        \\  event_name VARCHAR NOT NULL,
        \\  path VARCHAR NOT NULL,
        \\  visitor_day_id VARCHAR NOT NULL
        \\);
        \\DELETE FROM m0_events;
    );

    var insert = try events.prepare(
        "INSERT INTO m0_events VALUES (?, ?, ?, ?, ?, ?, ?)",
    );
    defer insert.deinit();

    const rows = [_]struct {
        id: i64,
        timestamp: i64,
        kind: i64,
        name: []const u8,
        path: []const u8,
        visitor: []const u8,
    }{
        .{ .id = 1, .timestamp = 1_700_000_000_000_000, .kind = 1, .name = "pageview", .path = "/", .visitor = "visitor-a" },
        .{ .id = 2, .timestamp = 1_700_000_060_000_000, .kind = 1, .name = "pageview", .path = "/pricing", .visitor = "visitor-a" },
        .{ .id = 3, .timestamp = 1_700_000_120_000_000, .kind = 2, .name = "signup", .path = "/welcome", .visitor = "visitor-a" },
        .{ .id = 4, .timestamp = 1_700_000_180_000_000, .kind = 1, .name = "pageview", .path = "/blog", .visitor = "visitor-b" },
        .{ .id = 5, .timestamp = 1_700_000_240_000_000, .kind = 1, .name = "pageview", .path = "/contact", .visitor = "visitor-b" },
        .{ .id = 6, .timestamp = 1_700_000_300_000_000, .kind = 2, .name = "purchase", .path = "/thanks", .visitor = "visitor-b" },
    };

    for (rows) |row| {
        try insert.clear();
        try insert.bindInt64(1, row.id);
        try insert.bindText(2, fixture_site_id);
        try insert.bindInt64(3, row.timestamp);
        try insert.bindInt64(4, row.kind);
        try insert.bindText(5, row.name);
        try insert.bindText(6, row.path);
        try insert.bindText(7, row.visitor);
        var result = try insert.execute();
        result.deinit();
    }
}

fn scalar(events: *duckdb.Database, sql: [:0]const u8) !i64 {
    var result = try events.query(sql);
    defer result.deinit();
    if (result.rowCount() != 1 or result.columnCount() != 1) return error.ExpectedScalar;
    return result.int64(0, 0);
}
