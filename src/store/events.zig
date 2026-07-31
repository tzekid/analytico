const std = @import("std");
const domain = @import("../domain.zig");
const duckdb = @import("duckdb.zig");

pub const schema_version: i64 = 1;

pub const Store = struct {
    database: duckdb.Database,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Store {
        return .{ .database = try duckdb.Database.open(allocator, path) };
    }

    pub fn deinit(self: *Store) void {
        self.database.deinit();
    }

    pub fn migrate(self: *Store) !void {
        try self.database.exec(
            \\CREATE TABLE IF NOT EXISTS event_migrations (
            \\  version INTEGER PRIMARY KEY,
            \\  name VARCHAR NOT NULL,
            \\  applied_at_utc_micros BIGINT NOT NULL
            \\)
        );
        const current = try self.scalar(
            "SELECT COALESCE(MAX(version), 0) FROM event_migrations",
        );
        if (current > schema_version) return error.NewerEventSchema;
        if (current == schema_version) return;

        try self.database.exec(
            \\BEGIN TRANSACTION;
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
            \\COMMIT;
        );
        try self.database.checkpoint();
    }

    pub fn insert(self: *Store, event: domain.Event) !void {
        try domain.validateUuid(event.event_id);
        try domain.validateUuid(event.site_id);
        try domain.validateDate(event.received_date_utc);
        try domain.validateIdentifier(event.event_name);
        _ = try domain.normalizePath(event.path);
        if (event.kind != 1 and event.kind != 2) return error.InvalidEventKind;

        var statement = try self.database.prepare(
            \\INSERT INTO events VALUES (
            \\  1, ?, ?, ?, CAST(? AS DATE), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
            \\)
        );
        defer statement.deinit();
        try statement.bindText(1, event.event_id);
        try statement.bindText(2, event.site_id);
        try statement.bindInt64(3, event.received_at_utc_micros);
        try statement.bindText(4, event.received_date_utc);
        try statement.bindInt64(5, event.kind);
        try statement.bindText(6, event.event_name);
        try statement.bindText(7, event.path);
        try statement.bindBlob(8, &event.visitor_day_id);
        try statement.bindText(9, event.referrer_host);
        try statement.bindText(10, event.country_code);
        try statement.bindText(11, event.browser_family);
        try statement.bindText(12, event.os_family);
        try statement.bindText(13, event.device_category);
        try statement.bindText(14, event.utm_source);
        try statement.bindText(15, event.utm_medium);
        try statement.bindText(16, event.utm_campaign);
        try statement.bindText(17, event.utm_term);
        try statement.bindText(18, event.utm_content);
        try statement.bindText(19, event.properties_json);
        var result = try statement.execute();
        result.deinit();
    }

    pub fn eventCount(self: *Store) !i64 {
        return self.scalar("SELECT COUNT(*) FROM events");
    }

    pub fn migrationVersion(self: *Store) !i64 {
        return self.scalar("SELECT COALESCE(MAX(version), 0) FROM event_migrations");
    }

    pub fn checkpoint(self: *Store) !void {
        try self.database.checkpoint();
    }

    fn scalar(self: *Store, sql: [:0]const u8) !i64 {
        var result = try self.database.query(sql);
        defer result.deinit();
        if (result.rowCount() != 1 or result.columnCount() != 1) {
            return error.ExpectedScalar;
        }
        return result.int64(0, 0);
    }
};
