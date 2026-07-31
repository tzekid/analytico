const std = @import("std");
const domain = @import("../domain.zig");
const duckdb = @import("duckdb.zig");

pub const schema_version: i64 = 2;

pub const StoredEvent = struct {
    event_name: []u8,
    path: []u8,
    referrer_host: []u8,
    country_code: []u8,
    browser_family: []u8,
    os_family: []u8,
    device_category: []u8,
    utm_source: []u8,
    properties_json: []u8,
};

pub const ExportEvent = struct {
    received_at_utc_micros: i64,
    received_date_utc: []u8,
    event_name: []u8,
    path: []u8,
    referrer_host: []u8,
    country_code: []u8,
    browser_family: []u8,
    os_family: []u8,
    device_category: []u8,
    utm_source: []u8,
    utm_medium: []u8,
    utm_campaign: []u8,
    utm_term: []u8,
    utm_content: []u8,
    properties_json: []u8,
};

pub const Store = struct {
    database: duckdb.Database,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Store {
        return .{ .database = try duckdb.Database.open(allocator, path) };
    }

    pub fn openWithTemp(
        allocator: std.mem.Allocator,
        path: []const u8,
        temp_directory: []const u8,
    ) !Store {
        return .{
            .database = try duckdb.Database.openWithTemp(
                allocator,
                path,
                temp_directory,
            ),
        };
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
        if (current < 1) {
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
        }
        if (current < 2) {
            try self.database.exec(
                \\BEGIN TRANSACTION;
                \\CREATE TABLE events_v2 (
                \\  schema_version UTINYINT NOT NULL,
                \\  event_id UUID NOT NULL,
                \\  site_id VARCHAR NOT NULL,
                \\  received_at_utc_micros BIGINT NOT NULL,
                \\  received_date_utc DATE NOT NULL,
                \\  kind UTINYINT NOT NULL,
                \\  event_name VARCHAR NOT NULL,
                \\  path VARCHAR NOT NULL,
                \\  visitor_day_id BLOB NOT NULL,
                \\  session_id UUID NOT NULL,
                \\  visitor_day_start BOOLEAN NOT NULL,
                \\  session_start BOOLEAN NOT NULL,
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
                \\INSERT INTO events_v2
                \\WITH lagged AS (
                \\  SELECT *,
                \\    lag(received_at_utc_micros) OVER (
                \\      PARTITION BY site_id, received_date_utc, visitor_day_id
                \\      ORDER BY received_at_utc_micros, event_id
                \\    ) AS previous_at,
                \\    row_number() OVER (
                \\      PARTITION BY site_id, received_date_utc, visitor_day_id
                \\      ORDER BY received_at_utc_micros, event_id
                \\    ) AS visitor_position
                \\  FROM events
                \\),
                \\marked AS (
                \\  SELECT *,
                \\    previous_at IS NULL
                \\      OR received_at_utc_micros - previous_at > 1800000000
                \\      AS is_session_start
                \\  FROM lagged
                \\),
                \\assigned AS (
                \\  SELECT *,
                \\    last_value(
                \\      CASE WHEN is_session_start THEN event_id ELSE NULL END
                \\      IGNORE NULLS
                \\    ) OVER (
                \\      PARTITION BY site_id, received_date_utc, visitor_day_id
                \\      ORDER BY received_at_utc_micros, event_id
                \\      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                \\    ) AS derived_session_id
                \\  FROM marked
                \\)
                \\SELECT schema_version, CAST(event_id AS UUID), site_id,
                \\  received_at_utc_micros, received_date_utc, kind, event_name,
                \\  path, visitor_day_id, CAST(derived_session_id AS UUID),
                \\  visitor_position = 1, is_session_start, referrer_host,
                \\  country_code, browser_family, os_family, device_category,
                \\  utm_source, utm_medium, utm_campaign, utm_term, utm_content,
                \\  properties_json
                \\FROM assigned;
                \\DROP TABLE events;
                \\ALTER TABLE events_v2 RENAME TO events;
                \\INSERT INTO event_migrations VALUES (
                \\  2, 'persist-session-boundaries', 0
                \\);
                \\COMMIT;
            );
        }
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
            \\INSERT INTO events
            \\WITH incoming (
            \\  event_id, site_id, received_at_utc_micros, received_date_utc,
            \\  kind, event_name, path, visitor_day_id, referrer_host,
            \\  country_code, browser_family, os_family, device_category,
            \\  utm_source, utm_medium, utm_campaign, utm_term, utm_content,
            \\  properties_json
            \\) AS (
            \\  SELECT ?, ?, ?, CAST(? AS DATE), ?, ?, ?, ?, ?, ?, ?, ?, ?,
            \\         ?, ?, ?, ?, ?, ?
            \\),
            \\resolved AS (
            \\  SELECT i.*, p.session_id AS prior_session_id,
            \\         p.received_at_utc_micros AS prior_at
            \\  FROM incoming i
            \\  LEFT JOIN LATERAL (
            \\    SELECT e.session_id, e.received_at_utc_micros
            \\    FROM events e
            \\    WHERE e.site_id = i.site_id
            \\      AND e.received_date_utc = i.received_date_utc
            \\      AND e.visitor_day_id = i.visitor_day_id
            \\      AND e.received_at_utc_micros <= i.received_at_utc_micros
            \\    ORDER BY e.received_at_utc_micros DESC, e.event_id DESC
            \\    LIMIT 1
            \\  ) p ON true
            \\)
            \\SELECT
            \\  1, CAST(i.event_id AS UUID), i.site_id, i.received_at_utc_micros,
            \\  i.received_date_utc, i.kind, i.event_name, i.path,
            \\  i.visitor_day_id,
            \\  CASE
            \\    WHEN i.received_at_utc_micros - i.prior_at <= 1800000000
            \\    THEN i.prior_session_id
            \\    ELSE CAST(i.event_id AS UUID)
            \\  END,
            \\  i.prior_session_id IS NULL,
            \\  i.prior_session_id IS NULL
            \\    OR i.received_at_utc_micros - i.prior_at > 1800000000,
            \\  i.referrer_host, i.country_code, i.browser_family, i.os_family,
            \\  i.device_category, i.utm_source, i.utm_medium, i.utm_campaign,
            \\  i.utm_term, i.utm_content, i.properties_json
            \\FROM resolved i
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

    pub fn requireCurrent(self: *Store) !void {
        const current = try self.migrationVersion();
        if (current > schema_version) return error.NewerEventSchema;
        if (current < schema_version) return error.EventMigrationRequired;
    }

    pub fn deleteBefore(self: *Store, cutoff_date: []const u8) !i64 {
        try domain.validateDate(cutoff_date);
        const count = try self.countBound(
            "SELECT count(*) FROM events WHERE received_date_utc < CAST(? AS DATE)",
            cutoff_date,
        );
        var statement = try self.database.prepare(
            "DELETE FROM events WHERE received_date_utc < CAST(? AS DATE)",
        );
        defer statement.deinit();
        try statement.bindText(1, cutoff_date);
        var result = try statement.execute();
        result.deinit();
        return count;
    }

    pub fn deleteSite(self: *Store, site_id: []const u8) !i64 {
        try domain.validateUuid(site_id);
        const count = try self.countBound(
            "SELECT count(*) FROM events WHERE site_id = ?",
            site_id,
        );
        var statement = try self.database.prepare(
            "DELETE FROM events WHERE site_id = ?",
        );
        defer statement.deinit();
        try statement.bindText(1, site_id);
        var result = try statement.execute();
        result.deinit();
        return count;
    }

    pub fn exportPage(
        self: *Store,
        allocator: std.mem.Allocator,
        site_id: []const u8,
        start_date: []const u8,
        end_date: []const u8,
        offset: i64,
        limit: i64,
    ) ![]ExportEvent {
        try domain.validateUuid(site_id);
        try domain.validateDate(start_date);
        try domain.validateDate(end_date);
        if (offset < 0 or limit < 1 or limit > 1_000) {
            return error.InvalidExportPage;
        }
        var statement = try self.database.prepare(
            \\SELECT received_at_utc_micros,
            \\       CAST(received_date_utc AS VARCHAR),
            \\       event_name, path, referrer_host, country_code,
            \\       browser_family, os_family, device_category,
            \\       utm_source, utm_medium, utm_campaign, utm_term,
            \\       utm_content, properties_json
            \\FROM events
            \\WHERE site_id = ?
            \\  AND received_date_utc BETWEEN CAST(? AS DATE) AND CAST(? AS DATE)
            \\ORDER BY received_at_utc_micros, event_id
            \\LIMIT ? OFFSET ?
        );
        defer statement.deinit();
        try statement.bindText(1, site_id);
        try statement.bindText(2, start_date);
        try statement.bindText(3, end_date);
        try statement.bindInt64(4, limit);
        try statement.bindInt64(5, offset);
        var result = try statement.execute();
        defer result.deinit();
        if (result.columnCount() != 15) return error.InvalidExportResult;
        const output = try allocator.alloc(ExportEvent, result.rowCount());
        for (output, 0..) |*event, index| {
            event.* = .{
                .received_at_utc_micros = result.int64(0, index),
                .received_date_utc = try result.text(allocator, 1, index),
                .event_name = try result.text(allocator, 2, index),
                .path = try result.text(allocator, 3, index),
                .referrer_host = try result.text(allocator, 4, index),
                .country_code = try result.text(allocator, 5, index),
                .browser_family = try result.text(allocator, 6, index),
                .os_family = try result.text(allocator, 7, index),
                .device_category = try result.text(allocator, 8, index),
                .utm_source = try result.text(allocator, 9, index),
                .utm_medium = try result.text(allocator, 10, index),
                .utm_campaign = try result.text(allocator, 11, index),
                .utm_term = try result.text(allocator, 12, index),
                .utm_content = try result.text(allocator, 13, index),
                .properties_json = try result.text(allocator, 14, index),
            };
        }
        return output;
    }

    pub fn eventCount(self: *Store) !i64 {
        return self.scalar("SELECT COUNT(*) FROM events");
    }

    pub fn migrationVersion(self: *Store) !i64 {
        return self.scalar("SELECT COALESCE(MAX(version), 0) FROM event_migrations");
    }

    pub fn latest(
        self: *Store,
        allocator: std.mem.Allocator,
    ) !StoredEvent {
        var result = try self.database.query(
            \\SELECT event_name, path, referrer_host, country_code,
            \\       browser_family, os_family, device_category,
            \\       utm_source, properties_json
            \\FROM events
            \\ORDER BY received_at_utc_micros DESC, event_id DESC
            \\LIMIT 1
        );
        defer result.deinit();
        if (result.rowCount() != 1) return error.EventNotFound;
        return .{
            .event_name = try result.text(allocator, 0, 0),
            .path = try result.text(allocator, 1, 0),
            .referrer_host = try result.text(allocator, 2, 0),
            .country_code = try result.text(allocator, 3, 0),
            .browser_family = try result.text(allocator, 4, 0),
            .os_family = try result.text(allocator, 5, 0),
            .device_category = try result.text(allocator, 6, 0),
            .utm_source = try result.text(allocator, 7, 0),
            .properties_json = try result.text(allocator, 8, 0),
        };
    }

    pub fn latestNamed(
        self: *Store,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !StoredEvent {
        try domain.validateIdentifier(name);
        var statement = try self.database.prepare(
            \\SELECT event_name, path, referrer_host, country_code,
            \\       browser_family, os_family, device_category,
            \\       utm_source, properties_json
            \\FROM events
            \\WHERE event_name = ?
            \\ORDER BY received_at_utc_micros DESC, event_id DESC
            \\LIMIT 1
        );
        defer statement.deinit();
        try statement.bindText(1, name);
        var result = try statement.execute();
        defer result.deinit();
        if (result.rowCount() != 1) return error.EventNotFound;
        return decodeStoredEvent(allocator, &result);
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

    fn countBound(
        self: *Store,
        sql: [:0]const u8,
        value: []const u8,
    ) !i64 {
        var statement = try self.database.prepare(sql);
        defer statement.deinit();
        try statement.bindText(1, value);
        var result = try statement.execute();
        defer result.deinit();
        if (result.rowCount() != 1 or result.columnCount() != 1) {
            return error.ExpectedScalar;
        }
        return result.int64(0, 0);
    }
};

fn decodeStoredEvent(
    allocator: std.mem.Allocator,
    result: *duckdb.Result,
) !StoredEvent {
    return .{
        .event_name = try result.text(allocator, 0, 0),
        .path = try result.text(allocator, 1, 0),
        .referrer_host = try result.text(allocator, 2, 0),
        .country_code = try result.text(allocator, 3, 0),
        .browser_family = try result.text(allocator, 4, 0),
        .os_family = try result.text(allocator, 5, 0),
        .device_category = try result.text(allocator, 6, 0),
        .utm_source = try result.text(allocator, 7, 0),
        .properties_json = try result.text(allocator, 8, 0),
    };
}
