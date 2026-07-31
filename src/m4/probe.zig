const std = @import("std");
const events = @import("../store/events.zig");
const meta = @import("../store/meta.zig");

pub fn legacyMillion(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
) !void {
    const event_path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, event_path);
    defer store.deinit();
    try store.database.exec(
        \\CREATE TABLE event_migrations (
        \\  version INTEGER PRIMARY KEY,
        \\  name VARCHAR NOT NULL,
        \\  applied_at_utc_micros BIGINT NOT NULL
        \\);
        \\CREATE TABLE events (
        \\  schema_version UTINYINT NOT NULL,
        \\  event_id VARCHAR NOT NULL,
        \\  site_id VARCHAR NOT NULL,
        \\  received_at_utc_micros BIGINT NOT NULL,
        \\  received_date_utc DATE NOT NULL,
        \\  kind UTINYINT NOT NULL,
        \\  event_name VARCHAR NOT NULL,
        \\  path VARCHAR NOT NULL,
        \\  visitor_day_id BLOB NOT NULL,
        \\  referrer_host VARCHAR NOT NULL,
        \\  country_code VARCHAR NOT NULL,
        \\  browser_family VARCHAR NOT NULL,
        \\  os_family VARCHAR NOT NULL,
        \\  device_category VARCHAR NOT NULL,
        \\  utm_source VARCHAR NOT NULL,
        \\  utm_medium VARCHAR NOT NULL,
        \\  utm_campaign VARCHAR NOT NULL,
        \\  utm_term VARCHAR NOT NULL,
        \\  utm_content VARCHAR NOT NULL,
        \\  properties_json VARCHAR NOT NULL
        \\);
        \\INSERT INTO event_migrations VALUES (1, 'initial-events', 0);
        \\INSERT INTO events
        \\SELECT
        \\  1,
        \\  '00000000-0000-4000-8000-' || lpad(i::VARCHAR, 12, '0'),
        \\  '00000000-0000-4000-8000-000000000001',
        \\  1735689600000000 + i * 1000000,
        \\  DATE '2025-01-01' + ((i // 86400)::INTEGER),
        \\  CASE WHEN i % 5 = 4 THEN 2 ELSE 1 END,
        \\  CASE WHEN i % 5 = 4 THEN 'signup' ELSE 'pageview' END,
        \\  CASE WHEN i % 2 = 0 THEN '/' ELSE '/pricing' END,
        \\  CAST(lpad(((i // 5) % 5000)::VARCHAR, 16, '0') AS BLOB),
        \\  '', 'US', 'Chrome', 'Linux', 'desktop',
        \\  '', '', '', '', '', '{}'
        \\FROM range(1000000) rows(i);
        \\CHECKPOINT
    );
    try output.writeAll("legacy million-event schema v1 fixture committed\n");
}

pub fn poisonNewer(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    target: []const u8,
) !void {
    if (std.mem.eql(u8, target, "events")) {
        const path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
        var store = try events.Store.open(allocator, path);
        defer store.deinit();
        try store.requireCurrent();
        try store.database.exec(
            "INSERT INTO event_migrations VALUES (999, 'future', 0)",
        );
        try store.checkpoint();
    } else if (std.mem.eql(u8, target, "metadata")) {
        const path = try std.fs.path.join(allocator, &.{ directory, "meta.db" });
        var store = try meta.Store.open(allocator, path);
        defer store.deinit();
        try store.requireCurrent();
        _ = try store.connection.execParams(
            "INSERT INTO meta_migrations VALUES (999, 'future', 0)",
            .{},
            .{},
        );
        try store.checkpoint();
    } else {
        return error.InvalidPoisonTarget;
    }
    try output.print("newer schema fixture target={s}\n", .{target});
}
