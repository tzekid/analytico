const std = @import("std");
const domain = @import("../domain.zig");
const duckdb = @import("duckdb.zig");
const timezone = @import("../timezone.zig");

pub const schema_version: i64 = 3;

pub const InsertV2Outcome = enum {
    inserted,
    duplicate,
};

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

pub const InspectedV2Event = struct {
    event_schema_version: i64,
    protocol_version: i64,
    tracker_version: i64,
    event_id: []u8,
    occurred_at_utc_micros: i64,
    received_date_utc: []u8,
    site_local_date: []u8,
    site_utc_offset_minutes: i64,
    kind: i64,
    event_name: []u8,
    path: []u8,
    page_title: []u8,
    hostname: []u8,
    anonymous_id: []u8,
    identity_quality: i64,
    user_id: []u8,
    session_id: []u8,
    sequence: i64,
    session_start: bool,
    referrer_host: []u8,
    country_code: []u8,
    language: []u8,
    browser_family: []u8,
    os_family: []u8,
    device_category: []u8,
    utm_source: []u8,
    utm_medium: []u8,
    utm_campaign: []u8,
    utm_term: []u8,
    utm_content: []u8,
    properties_json: []u8,
    user_traits_json: []u8,
    value_amount: ?[]u8,
    value_currency: []u8,
    engagement_ms: i64,
    max_scroll_depth: i64,
    linked_user_id: []u8,
};

pub const ResolvedPerson = struct {
    canonical_key: []u8,
    user_id: []u8,
    latest_traits_json: []u8,
    linked_anonymous_ids: i64,
};

pub const SiteEventBounds = struct {
    count: i64,
    minimum_utc_micros: i64,
    maximum_utc_micros: i64,
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
        if (current < 3) {
            try self.database.exec(
                \\BEGIN TRANSACTION;
                \\CREATE TABLE events_v3 (
                \\  event_schema_version UTINYINT NOT NULL,
                \\  protocol_version UTINYINT NOT NULL,
                \\  tracker_version UTINYINT NOT NULL,
                \\  event_id UUID NOT NULL,
                \\  site_id VARCHAR NOT NULL,
                \\  received_at_utc_micros BIGINT NOT NULL,
                \\  occurred_at_utc_micros BIGINT NOT NULL,
                \\  received_date_utc DATE NOT NULL,
                \\  site_local_date DATE NOT NULL,
                \\  site_utc_offset_minutes SMALLINT NOT NULL,
                \\  kind UTINYINT NOT NULL,
                \\  event_name VARCHAR NOT NULL,
                \\  path VARCHAR NOT NULL,
                \\  page_title VARCHAR NOT NULL,
                \\  hostname VARCHAR NOT NULL,
                \\  anonymous_id UUID NOT NULL,
                \\  identity_quality UTINYINT NOT NULL,
                \\  user_id VARCHAR NOT NULL,
                \\  session_id UUID NOT NULL,
                \\  sequence UINTEGER NOT NULL,
                \\  session_start BOOLEAN NOT NULL,
                \\  referrer_host VARCHAR NOT NULL,
                \\  country_code VARCHAR NOT NULL,
                \\  language VARCHAR NOT NULL,
                \\  browser_family VARCHAR NOT NULL,
                \\  os_family VARCHAR NOT NULL,
                \\  device_category VARCHAR NOT NULL,
                \\  utm_source VARCHAR NOT NULL,
                \\  utm_medium VARCHAR NOT NULL,
                \\  utm_campaign VARCHAR NOT NULL,
                \\  utm_term VARCHAR NOT NULL,
                \\  utm_content VARCHAR NOT NULL,
                \\  properties_json VARCHAR NOT NULL,
                \\  user_traits_json VARCHAR NOT NULL,
                \\  value_amount DECIMAL(18,6),
                \\  value_currency VARCHAR NOT NULL,
                \\  engagement_ms UINTEGER NOT NULL,
                \\  max_scroll_depth UTINYINT NOT NULL,
                \\  visitor_day_id BLOB NOT NULL,
                \\  visitor_day_start BOOLEAN NOT NULL,
                \\  event_payload_digest VARCHAR NOT NULL
                \\);
                \\CREATE TABLE identity_links (
                \\  site_id VARCHAR NOT NULL,
                \\  anonymous_id UUID NOT NULL,
                \\  user_id VARCHAR NOT NULL,
                \\  linked_at_utc_micros BIGINT NOT NULL,
                \\  event_id UUID NOT NULL,
                \\  PRIMARY KEY (site_id, anonymous_id)
                \\);
                \\INSERT INTO events_v3
                \\WITH sequenced AS (
                \\  SELECT *,
                \\    first_value(event_id) OVER (
                \\      PARTITION BY site_id, received_date_utc, visitor_day_id
                \\      ORDER BY received_at_utc_micros, event_id
                \\    ) AS legacy_anonymous_id,
                \\    row_number() OVER (
                \\      PARTITION BY site_id, session_id
                \\      ORDER BY received_at_utc_micros, event_id
                \\    ) - 1 AS legacy_sequence
                \\  FROM events
                \\)
                \\SELECT
                \\  3, 1, 1, event_id, site_id,
                \\  received_at_utc_micros, received_at_utc_micros,
                \\  received_date_utc, received_date_utc, 0,
                \\  kind, event_name, path, '', '', legacy_anonymous_id,
                \\  3, '', session_id, CAST(legacy_sequence AS UINTEGER),
                \\  session_start, referrer_host, country_code, '',
                \\  browser_family, os_family, device_category,
                \\  utm_source, utm_medium, utm_campaign, utm_term, utm_content,
                \\  properties_json, '{}', CAST(NULL AS DECIMAL(18,6)), '',
                \\  0, 0, visitor_day_id, visitor_day_start, ''
                \\FROM sequenced;
                \\DROP TABLE events;
                \\ALTER TABLE events_v3 RENAME TO events;
                \\INSERT INTO event_migrations VALUES (
                \\  3, 'protocol-v2-event-foundation', 0
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
        try domain.validateDate(event.site_local_date);
        try domain.validateIdentifier(event.event_name);
        _ = try domain.normalizePath(event.path);
        if (event.kind != 1 and event.kind != 2) return error.InvalidEventKind;

        var statement = try self.database.prepare(
            \\INSERT INTO events
            \\WITH incoming (
            \\  event_id, site_id, received_at_utc_micros, received_date_utc,
            \\  site_local_date, site_utc_offset_minutes,
            \\  kind, event_name, path, visitor_day_id, referrer_host,
            \\  country_code, browser_family, os_family, device_category,
            \\  utm_source, utm_medium, utm_campaign, utm_term, utm_content,
            \\  properties_json
            \\) AS (
            \\  SELECT ?, ?, ?, CAST(? AS DATE), CAST(? AS DATE), ?,
            \\         ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
            \\),
            \\resolved AS (
            \\  SELECT i.*, p.session_id AS prior_session_id,
            \\         p.received_at_utc_micros AS prior_at,
            \\         p.sequence AS prior_sequence,
            \\         a.anonymous_id AS prior_anonymous_id
            \\  FROM incoming i
            \\  LEFT JOIN LATERAL (
            \\    SELECT e.session_id, e.received_at_utc_micros, e.sequence
            \\    FROM events e
            \\    WHERE e.site_id = i.site_id
            \\      AND e.received_date_utc = i.received_date_utc
            \\      AND e.visitor_day_id = i.visitor_day_id
            \\      AND e.received_at_utc_micros <= i.received_at_utc_micros
            \\    ORDER BY e.received_at_utc_micros DESC, e.event_id DESC
            \\    LIMIT 1
            \\  ) p ON true
            \\  LEFT JOIN LATERAL (
            \\    SELECT e.anonymous_id
            \\    FROM events e
            \\    WHERE e.site_id = i.site_id
            \\      AND e.received_date_utc = i.received_date_utc
            \\      AND e.visitor_day_id = i.visitor_day_id
            \\    LIMIT 1
            \\  ) a ON true
            \\)
            \\SELECT
            \\  3, 1, 1, CAST(i.event_id AS UUID), i.site_id,
            \\  i.received_at_utc_micros, i.received_at_utc_micros,
            \\  i.received_date_utc, i.site_local_date,
            \\  i.site_utc_offset_minutes,
            \\  i.kind, i.event_name, i.path, '', '',
            \\  COALESCE(i.prior_anonymous_id, CAST(i.event_id AS UUID)), 3, '',
            \\  CASE
            \\    WHEN i.received_at_utc_micros - i.prior_at <= 1800000000
            \\    THEN i.prior_session_id
            \\    ELSE CAST(i.event_id AS UUID)
            \\  END,
            \\  CASE
            \\    WHEN i.received_at_utc_micros - i.prior_at <= 1800000000
            \\    THEN i.prior_sequence + 1
            \\    ELSE 0
            \\  END,
            \\  i.prior_session_id IS NULL
            \\    OR i.received_at_utc_micros - i.prior_at > 1800000000,
            \\  i.referrer_host, i.country_code, '', i.browser_family, i.os_family,
            \\  i.device_category, i.utm_source, i.utm_medium, i.utm_campaign,
            \\  i.utm_term, i.utm_content, i.properties_json
            \\  , '{}', CAST(NULL AS DECIMAL(18,6)), '', 0, 0,
            \\  i.visitor_day_id, i.prior_session_id IS NULL, ''
            \\FROM resolved i
        );
        defer statement.deinit();
        try statement.bindText(1, event.event_id);
        try statement.bindText(2, event.site_id);
        try statement.bindInt64(3, event.received_at_utc_micros);
        try statement.bindText(4, event.received_date_utc);
        try statement.bindText(5, event.site_local_date);
        try statement.bindInt64(6, event.site_utc_offset_minutes);
        try statement.bindInt64(7, event.kind);
        try statement.bindText(8, event.event_name);
        try statement.bindText(9, event.path);
        try statement.bindBlob(10, &event.visitor_day_id);
        try statement.bindText(11, event.referrer_host);
        try statement.bindText(12, event.country_code);
        try statement.bindText(13, event.browser_family);
        try statement.bindText(14, event.os_family);
        try statement.bindText(15, event.device_category);
        try statement.bindText(16, event.utm_source);
        try statement.bindText(17, event.utm_medium);
        try statement.bindText(18, event.utm_campaign);
        try statement.bindText(19, event.utm_term);
        try statement.bindText(20, event.utm_content);
        try statement.bindText(21, event.properties_json);
        var result = try statement.execute();
        result.deinit();
    }

    pub fn insertV2(
        self: *Store,
        allocator: std.mem.Allocator,
        event: domain.EventV2,
    ) !InsertV2Outcome {
        try domain.validateUuid(event.event_id);
        try domain.validateUuid(event.site_id);
        try domain.validateUuid(event.anonymous_id);
        try domain.validateUuid(event.session_id);
        try domain.validateDate(event.received_date_utc);
        try domain.validateDate(event.site_local_date);
        try domain.validateIdentifier(event.event_name);
        if (event.path.len != 0) _ = try domain.normalizePath(event.path);
        if (event.kind < 1 or event.kind > 4 or
            event.identity_quality < 1 or event.identity_quality > 2 or
            event.event_payload_digest.len != 64)
        {
            return error.InvalidV2Event;
        }

        const existing_digest = try self.eventDigest(
            allocator,
            event.site_id,
            event.event_id,
        );
        if (existing_digest) |digest| {
            if (std.mem.eql(u8, digest, event.event_payload_digest)) {
                return .duplicate;
            }
            return error.EventIdConflict;
        }

        const linked_user = try self.linkedUser(
            allocator,
            event.site_id,
            event.anonymous_id,
        );
        if (event.identity_quality == 2 and linked_user != null) {
            return error.IdentityQualityConflict;
        }
        if (event.identify_user_id.len != 0) {
            if (linked_user) |existing_user| {
                if (!std.mem.eql(u8, existing_user, event.identify_user_id)) {
                    return error.IdentityConflict;
                }
            }
        }
        const stored_user_id = if (event.identify_user_id.len != 0)
            event.identify_user_id
        else if (event.identity_quality == 1)
            linked_user orelse ""
        else
            "";

        try self.database.exec("BEGIN TRANSACTION");
        errdefer self.database.exec("ROLLBACK") catch {};
        if (event.identify_user_id.len != 0 and linked_user == null) {
            var link_statement = try self.database.prepare(
                \\INSERT INTO identity_links (
                \\  site_id, anonymous_id, user_id,
                \\  linked_at_utc_micros, event_id
                \\) VALUES (?, CAST(? AS UUID), ?, ?, CAST(? AS UUID))
            );
            defer link_statement.deinit();
            try link_statement.bindText(1, event.site_id);
            try link_statement.bindText(2, event.anonymous_id);
            try link_statement.bindText(3, event.identify_user_id);
            try link_statement.bindInt64(4, event.received_at_utc_micros);
            try link_statement.bindText(5, event.event_id);
            var link_result = try link_statement.execute();
            link_result.deinit();
        }

        var statement = try self.database.prepare(
            \\INSERT INTO events
            \\WITH incoming (
            \\  event_id, site_id, received_at, occurred_at, received_date,
            \\  site_local_date, site_utc_offset_minutes,
            \\  kind, event_name, path, page_title, hostname,
            \\  anonymous_id, identity_quality, user_id, session_id, sequence,
            \\  referrer_host, country_code, language, browser_family,
            \\  os_family, device_category, utm_source, utm_medium,
            \\  utm_campaign, utm_term, utm_content, properties_json,
            \\  user_traits_json, value_amount, value_currency, engagement_ms,
            \\  max_scroll_depth, visitor_day_id, payload_digest
            \\) AS (
            \\  SELECT ?, ?, ?, ?, CAST(? AS DATE), CAST(? AS DATE), ?,
            \\         ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
            \\         ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
            \\)
            \\SELECT
            \\  3, 2, 2, CAST(i.event_id AS UUID), i.site_id,
            \\  i.received_at, i.occurred_at, i.received_date,
            \\  i.site_local_date, i.site_utc_offset_minutes,
            \\  i.kind, i.event_name, i.path,
            \\  i.page_title, i.hostname, CAST(i.anonymous_id AS UUID),
            \\  i.identity_quality, i.user_id, CAST(i.session_id AS UUID),
            \\  i.sequence,
            \\  NOT EXISTS (
            \\    SELECT 1 FROM events e
            \\    WHERE e.site_id = i.site_id
            \\      AND e.session_id = CAST(i.session_id AS UUID)
            \\  ),
            \\  i.referrer_host, i.country_code, i.language,
            \\  i.browser_family, i.os_family, i.device_category,
            \\  i.utm_source, i.utm_medium, i.utm_campaign,
            \\  i.utm_term, i.utm_content, i.properties_json,
            \\  i.user_traits_json,
            \\  CASE WHEN i.value_amount = ''
            \\    THEN CAST(NULL AS DECIMAL(18,6))
            \\    ELSE CAST(i.value_amount AS DECIMAL(18,6))
            \\  END,
            \\  i.value_currency, i.engagement_ms, i.max_scroll_depth,
            \\  i.visitor_day_id,
            \\  NOT EXISTS (
            \\    SELECT 1 FROM events e
            \\    WHERE e.site_id = i.site_id
            \\      AND e.received_date_utc = i.received_date
            \\      AND e.visitor_day_id = i.visitor_day_id
            \\  ),
            \\  i.payload_digest
            \\FROM incoming i
        );
        defer statement.deinit();
        try statement.bindText(1, event.event_id);
        try statement.bindText(2, event.site_id);
        try statement.bindInt64(3, event.received_at_utc_micros);
        try statement.bindInt64(4, event.occurred_at_utc_micros);
        try statement.bindText(5, event.received_date_utc);
        try statement.bindText(6, event.site_local_date);
        try statement.bindInt64(7, event.site_utc_offset_minutes);
        try statement.bindInt64(8, event.kind);
        try statement.bindText(9, event.event_name);
        try statement.bindText(10, event.path);
        try statement.bindText(11, event.page_title);
        try statement.bindText(12, event.hostname);
        try statement.bindText(13, event.anonymous_id);
        try statement.bindInt64(14, event.identity_quality);
        try statement.bindText(15, stored_user_id);
        try statement.bindText(16, event.session_id);
        try statement.bindInt64(17, event.sequence);
        try statement.bindText(18, event.referrer_host);
        try statement.bindText(19, event.country_code);
        try statement.bindText(20, event.language);
        try statement.bindText(21, event.browser_family);
        try statement.bindText(22, event.os_family);
        try statement.bindText(23, event.device_category);
        try statement.bindText(24, event.utm_source);
        try statement.bindText(25, event.utm_medium);
        try statement.bindText(26, event.utm_campaign);
        try statement.bindText(27, event.utm_term);
        try statement.bindText(28, event.utm_content);
        try statement.bindText(29, event.properties_json);
        try statement.bindText(30, event.user_traits_json);
        try statement.bindText(31, event.value_amount orelse "");
        try statement.bindText(32, event.value_currency);
        try statement.bindInt64(33, event.engagement_ms);
        try statement.bindInt64(34, event.max_scroll_depth);
        try statement.bindBlob(35, &event.visitor_day_id);
        try statement.bindText(36, event.event_payload_digest);
        var result = try statement.execute();
        result.deinit();
        try self.database.exec("COMMIT");
        return .inserted;
    }

    pub fn requireCurrent(self: *Store) !void {
        const current = try self.migrationVersion();
        if (current > schema_version) return error.NewerEventSchema;
        if (current < schema_version) return error.EventMigrationRequired;
    }

    pub fn siteEventBounds(self: *Store, site_id: []const u8) !SiteEventBounds {
        try domain.validateUuid(site_id);
        var statement = try self.database.prepare(
            \\SELECT count(*),
            \\       COALESCE(min(received_at_utc_micros), 0),
            \\       COALESCE(max(received_at_utc_micros), 0)
            \\FROM events WHERE site_id = ?
        );
        defer statement.deinit();
        try statement.bindText(1, site_id);
        var result = try statement.execute();
        defer result.deinit();
        if (result.rowCount() != 1 or result.columnCount() != 3) {
            return error.InvalidSiteEventBounds;
        }
        return .{
            .count = result.int64(0, 0),
            .minimum_utc_micros = result.int64(1, 0),
            .maximum_utc_micros = result.int64(2, 0),
        };
    }

    pub fn rebucketSite(
        self: *Store,
        site_id: []const u8,
        intervals: []const timezone.RebucketInterval,
        expected_count: i64,
    ) !void {
        if (expected_count <= 0 or intervals.len == 0) return error.InvalidRebucket;
        var index: usize = 0;
        while (index < intervals.len) : (index += 1) {
            const interval = intervals[index];
            const expected_start = if (index == 0)
                interval.start_utc_micros
            else
                std.math.add(
                    i64,
                    intervals[index - 1].end_utc_micros,
                    1,
                ) catch return error.InvalidRebucketIntervals;
            if (interval.end_utc_micros < interval.start_utc_micros or
                interval.start_utc_micros != expected_start)
            {
                return error.InvalidRebucketIntervals;
            }
        }
        try self.database.exec(
            \\CREATE TEMP TABLE IF NOT EXISTS timezone_rebucket_intervals (
            \\  start_utc_micros BIGINT NOT NULL,
            \\  end_utc_micros BIGINT NOT NULL,
            \\  offset_minutes SMALLINT NOT NULL
            \\)
        );
        defer self.database.exec("DROP TABLE timezone_rebucket_intervals") catch {};
        var interval_statement = try self.database.prepare(
            \\INSERT INTO timezone_rebucket_intervals VALUES (?, ?, ?)
        );
        defer interval_statement.deinit();
        for (intervals) |interval| {
            try interval_statement.bindInt64(1, interval.start_utc_micros);
            try interval_statement.bindInt64(2, interval.end_utc_micros);
            try interval_statement.bindInt64(3, interval.offset_minutes);
            var result = try interval_statement.execute();
            result.deinit();
            try interval_statement.clear();
        }
        var coverage_statement = try self.database.prepare(
            \\SELECT count(*)
            \\FROM events e
            \\JOIN timezone_rebucket_intervals i
            \\  ON e.received_at_utc_micros BETWEEN
            \\     i.start_utc_micros AND i.end_utc_micros
            \\WHERE e.site_id = ?
        );
        defer coverage_statement.deinit();
        try coverage_statement.bindText(1, site_id);
        var coverage = try coverage_statement.execute();
        defer coverage.deinit();
        if (coverage.rowCount() != 1 or coverage.int64(0, 0) != expected_count) {
            return error.IncompleteRebucketCoverage;
        }

        try self.database.exec("BEGIN TRANSACTION");
        errdefer self.database.exec("ROLLBACK") catch {};
        var update = try self.database.prepare(
            \\UPDATE events AS e
            \\SET site_utc_offset_minutes = i.offset_minutes,
            \\    site_local_date = DATE '1970-01-01' + CAST(
            \\      CASE WHEN
            \\        CAST(e.received_at_utc_micros AS HUGEINT) +
            \\        CAST(i.offset_minutes AS HUGEINT) * 60000000 >= 0
            \\      THEN (
            \\        CAST(e.received_at_utc_micros AS HUGEINT) +
            \\        CAST(i.offset_minutes AS HUGEINT) * 60000000
            \\      ) // 86400000000
            \\      ELSE -((-(
            \\        CAST(e.received_at_utc_micros AS HUGEINT) +
            \\        CAST(i.offset_minutes AS HUGEINT) * 60000000
            \\      ) + 86399999999) // 86400000000) END
            \\    AS INTEGER)
            \\FROM timezone_rebucket_intervals i
            \\WHERE e.site_id = ?
            \\  AND e.received_at_utc_micros BETWEEN
            \\      i.start_utc_micros AND i.end_utc_micros
        );
        defer update.deinit();
        try update.bindText(1, site_id);
        var update_result = try update.execute();
        update_result.deinit();
        var validation = try self.database.prepare(
            \\SELECT count(*)
            \\FROM events e
            \\JOIN timezone_rebucket_intervals i
            \\  ON e.received_at_utc_micros BETWEEN
            \\     i.start_utc_micros AND i.end_utc_micros
            \\WHERE e.site_id = ? AND (
            \\  e.site_utc_offset_minutes != i.offset_minutes OR
            \\  e.site_local_date != DATE '1970-01-01' + CAST(
            \\    CASE WHEN
            \\      CAST(e.received_at_utc_micros AS HUGEINT) +
            \\      CAST(i.offset_minutes AS HUGEINT) * 60000000 >= 0
            \\    THEN (
            \\      CAST(e.received_at_utc_micros AS HUGEINT) +
            \\      CAST(i.offset_minutes AS HUGEINT) * 60000000
            \\    ) // 86400000000
            \\    ELSE -((-(
            \\      CAST(e.received_at_utc_micros AS HUGEINT) +
            \\      CAST(i.offset_minutes AS HUGEINT) * 60000000
            \\    ) + 86399999999) // 86400000000) END
            \\  AS INTEGER)
            \\)
        );
        defer validation.deinit();
        try validation.bindText(1, site_id);
        var validation_result = try validation.execute();
        defer validation_result.deinit();
        if (validation_result.rowCount() != 1 or
            validation_result.int64(0, 0) != 0)
        {
            return error.RebucketValidationFailed;
        }
        const after = try self.siteEventBounds(site_id);
        if (after.count != expected_count) return error.RebucketCountChanged;
        try self.database.exec("COMMIT");
    }

    pub fn deleteBefore(self: *Store, cutoff_date: []const u8) !i64 {
        try domain.validateDate(cutoff_date);
        const count = try self.countBound(
            "SELECT count(*) FROM events WHERE received_date_utc < CAST(? AS DATE)",
            cutoff_date,
        );
        try self.database.exec("BEGIN TRANSACTION");
        errdefer self.database.exec("ROLLBACK") catch {};
        var statement = try self.database.prepare(
            "DELETE FROM events WHERE received_date_utc < CAST(? AS DATE)",
        );
        defer statement.deinit();
        try statement.bindText(1, cutoff_date);
        var result = try statement.execute();
        result.deinit();
        try self.database.exec(
            \\DELETE FROM identity_links l
            \\WHERE NOT EXISTS (
            \\  SELECT 1 FROM events e
            \\  WHERE e.site_id = l.site_id AND e.anonymous_id = l.anonymous_id
            \\)
        );
        try self.database.exec("COMMIT");
        return count;
    }

    pub fn deleteSite(self: *Store, site_id: []const u8) !i64 {
        try domain.validateUuid(site_id);
        const count = try self.countBound(
            "SELECT count(*) FROM events WHERE site_id = ?",
            site_id,
        );
        try self.database.exec("BEGIN TRANSACTION");
        errdefer self.database.exec("ROLLBACK") catch {};
        var link_statement = try self.database.prepare(
            "DELETE FROM identity_links WHERE site_id = ?",
        );
        defer link_statement.deinit();
        try link_statement.bindText(1, site_id);
        var link_result = try link_statement.execute();
        link_result.deinit();
        var statement = try self.database.prepare(
            "DELETE FROM events WHERE site_id = ?",
        );
        defer statement.deinit();
        try statement.bindText(1, site_id);
        var result = try statement.execute();
        result.deinit();
        try self.database.exec("COMMIT");
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

    pub fn sessionTimelineIds(
        self: *Store,
        allocator: std.mem.Allocator,
        site_id: []const u8,
        session_id: []const u8,
    ) ![][]const u8 {
        try domain.validateUuid(site_id);
        try domain.validateUuid(session_id);
        var statement = try self.database.prepare(
            \\SELECT CAST(event_id AS VARCHAR)
            \\FROM events
            \\WHERE site_id = ? AND session_id = CAST(? AS UUID)
            \\ORDER BY occurred_at_utc_micros, sequence, received_at_utc_micros,
            \\         CAST(event_id AS VARCHAR)
        );
        defer statement.deinit();
        try statement.bindText(1, site_id);
        try statement.bindText(2, session_id);
        var result = try statement.execute();
        defer result.deinit();
        if (result.columnCount() != 1) return error.InvalidSessionTimeline;
        const ids = try allocator.alloc([]const u8, result.rowCount());
        for (ids, 0..) |*id, index| {
            id.* = try result.text(allocator, 0, index);
        }
        return ids;
    }

    pub fn inspectV2(
        self: *Store,
        allocator: std.mem.Allocator,
        site_id: []const u8,
        event_id: []const u8,
    ) !InspectedV2Event {
        try domain.validateUuid(site_id);
        try domain.validateUuid(event_id);
        var statement = try self.database.prepare(
            \\SELECT
            \\  e.event_schema_version, e.protocol_version, e.tracker_version,
            \\  CAST(e.event_id AS VARCHAR), e.occurred_at_utc_micros,
            \\  CAST(e.received_date_utc AS VARCHAR),
            \\  CAST(e.site_local_date AS VARCHAR), e.site_utc_offset_minutes,
            \\  e.kind, e.event_name, e.path, e.page_title, e.hostname,
            \\  CAST(e.anonymous_id AS VARCHAR), e.identity_quality, e.user_id,
            \\  CAST(e.session_id AS VARCHAR), e.sequence, e.session_start,
            \\  e.referrer_host, e.country_code, e.language,
            \\  e.browser_family, e.os_family, e.device_category,
            \\  e.utm_source, e.utm_medium, e.utm_campaign,
            \\  e.utm_term, e.utm_content, e.properties_json,
            \\  e.user_traits_json, CAST(e.value_amount AS VARCHAR),
            \\  e.value_currency, e.engagement_ms, e.max_scroll_depth,
            \\  COALESCE(l.user_id, '')
            \\FROM events e
            \\LEFT JOIN identity_links l
            \\  ON l.site_id = e.site_id AND l.anonymous_id = e.anonymous_id
            \\WHERE e.site_id = ? AND e.event_id = CAST(? AS UUID)
        );
        defer statement.deinit();
        try statement.bindText(1, site_id);
        try statement.bindText(2, event_id);
        var result = try statement.execute();
        defer result.deinit();
        if (result.rowCount() != 1 or result.columnCount() != 37) {
            return error.EventNotFound;
        }
        return .{
            .event_schema_version = result.int64(0, 0),
            .protocol_version = result.int64(1, 0),
            .tracker_version = result.int64(2, 0),
            .event_id = try result.text(allocator, 3, 0),
            .occurred_at_utc_micros = result.int64(4, 0),
            .received_date_utc = try result.text(allocator, 5, 0),
            .site_local_date = try result.text(allocator, 6, 0),
            .site_utc_offset_minutes = result.int64(7, 0),
            .kind = result.int64(8, 0),
            .event_name = try result.text(allocator, 9, 0),
            .path = try result.text(allocator, 10, 0),
            .page_title = try result.text(allocator, 11, 0),
            .hostname = try result.text(allocator, 12, 0),
            .anonymous_id = try result.text(allocator, 13, 0),
            .identity_quality = result.int64(14, 0),
            .user_id = try result.text(allocator, 15, 0),
            .session_id = try result.text(allocator, 16, 0),
            .sequence = result.int64(17, 0),
            .session_start = result.int64(18, 0) != 0,
            .referrer_host = try result.text(allocator, 19, 0),
            .country_code = try result.text(allocator, 20, 0),
            .language = try result.text(allocator, 21, 0),
            .browser_family = try result.text(allocator, 22, 0),
            .os_family = try result.text(allocator, 23, 0),
            .device_category = try result.text(allocator, 24, 0),
            .utm_source = try result.text(allocator, 25, 0),
            .utm_medium = try result.text(allocator, 26, 0),
            .utm_campaign = try result.text(allocator, 27, 0),
            .utm_term = try result.text(allocator, 28, 0),
            .utm_content = try result.text(allocator, 29, 0),
            .properties_json = try result.text(allocator, 30, 0),
            .user_traits_json = try result.text(allocator, 31, 0),
            .value_amount = if (result.isNull(32, 0))
                null
            else
                try result.text(allocator, 32, 0),
            .value_currency = try result.text(allocator, 33, 0),
            .engagement_ms = result.int64(34, 0),
            .max_scroll_depth = result.int64(35, 0),
            .linked_user_id = try result.text(allocator, 36, 0),
        };
    }

    pub fn resolvePerson(
        self: *Store,
        allocator: std.mem.Allocator,
        site_id: []const u8,
        anonymous_id: []const u8,
    ) !ResolvedPerson {
        try domain.validateUuid(site_id);
        try domain.validateUuid(anonymous_id);
        var identity_statement = try self.database.prepare(
            \\SELECT e.identity_quality, COALESCE(l.user_id, '')
            \\FROM events e
            \\LEFT JOIN identity_links l
            \\  ON l.site_id = e.site_id AND l.anonymous_id = e.anonymous_id
            \\WHERE e.site_id = ? AND e.anonymous_id = CAST(? AS UUID)
            \\ORDER BY e.occurred_at_utc_micros DESC, e.sequence DESC,
            \\         e.received_at_utc_micros DESC, e.event_id DESC
            \\LIMIT 1
        );
        defer identity_statement.deinit();
        try identity_statement.bindText(1, site_id);
        try identity_statement.bindText(2, anonymous_id);
        var identity = try identity_statement.execute();
        defer identity.deinit();
        if (identity.rowCount() != 1 or identity.columnCount() != 2) {
            return error.PersonNotFound;
        }
        const identity_quality: u8 = @intCast(identity.int64(0, 0));
        const user_id = try identity.text(allocator, 1, 0);
        const canonical_key = try domain.canonicalPersonKey(
            allocator,
            identity_quality,
            anonymous_id,
            user_id,
        );
        if (user_id.len == 0) {
            return .{
                .canonical_key = canonical_key,
                .user_id = user_id,
                .latest_traits_json = try allocator.dupe(u8, "{}"),
                .linked_anonymous_ids = 0,
            };
        }

        var profile_statement = try self.database.prepare(
            \\SELECT
            \\  COALESCE((
            \\    SELECT e.user_traits_json
            \\    FROM events e
            \\    WHERE e.site_id = ? AND e.kind = 4 AND e.user_id = ?
            \\    ORDER BY e.occurred_at_utc_micros DESC, e.sequence DESC,
            \\             e.received_at_utc_micros DESC, e.event_id DESC
            \\    LIMIT 1
            \\  ), '{}'),
            \\  (SELECT count(*) FROM identity_links l
            \\   WHERE l.site_id = ? AND l.user_id = ?)
        );
        defer profile_statement.deinit();
        try profile_statement.bindText(1, site_id);
        try profile_statement.bindText(2, user_id);
        try profile_statement.bindText(3, site_id);
        try profile_statement.bindText(4, user_id);
        var profile = try profile_statement.execute();
        defer profile.deinit();
        if (profile.rowCount() != 1 or profile.columnCount() != 2) {
            return error.InvalidPersonProfile;
        }
        return .{
            .canonical_key = canonical_key,
            .user_id = user_id,
            .latest_traits_json = try profile.text(allocator, 0, 0),
            .linked_anonymous_ids = profile.int64(1, 0),
        };
    }

    pub fn checkpoint(self: *Store) !void {
        try self.database.checkpoint();
    }

    fn eventDigest(
        self: *Store,
        allocator: std.mem.Allocator,
        site_id: []const u8,
        event_id: []const u8,
    ) !?[]u8 {
        var statement = try self.database.prepare(
            \\SELECT event_payload_digest
            \\FROM events
            \\WHERE site_id = ? AND event_id = CAST(? AS UUID)
        );
        defer statement.deinit();
        try statement.bindText(1, site_id);
        try statement.bindText(2, event_id);
        var result = try statement.execute();
        defer result.deinit();
        if (result.rowCount() == 0) return null;
        if (result.rowCount() != 1) return error.DuplicateStoredEventId;
        return try result.text(allocator, 0, 0);
    }

    fn linkedUser(
        self: *Store,
        allocator: std.mem.Allocator,
        site_id: []const u8,
        anonymous_id: []const u8,
    ) !?[]u8 {
        var statement = try self.database.prepare(
            \\SELECT user_id
            \\FROM identity_links
            \\WHERE site_id = ? AND anonymous_id = CAST(? AS UUID)
        );
        defer statement.deinit();
        try statement.bindText(1, site_id);
        try statement.bindText(2, anonymous_id);
        var result = try statement.execute();
        defer result.deinit();
        if (result.rowCount() == 0) return null;
        if (result.rowCount() != 1) return error.DuplicateIdentityLink;
        return try result.text(allocator, 0, 0);
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
