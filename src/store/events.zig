const std = @import("std");
const analysis = @import("../analysis.zig");
const domain = @import("../domain.zig");
const duckdb = @import("duckdb.zig");
const timezone = @import("../timezone.zig");

pub const schema_version: i64 = 7;

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
    traffic_class: i64,
    classifier_version: i64,
    bot_rule: []u8,
    signals: domain.ClientSignals,
    client_hint_consistency: i64,
    accept_language_present: bool,
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
    traffic_class: i64,
    classifier_version: i64,
    bot_rule: []u8,
    signals: domain.ClientSignals,
    client_hint_consistency: i64,
    accept_language_present: bool,
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
    traffic_class: i64,
    classifier_version: i64,
    bot_rule: []u8,
    signals: domain.ClientSignals,
    client_hint_consistency: i64,
    accept_language_present: bool,
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

pub const InstallationWatermark = struct {
    event_count: i64,
    received_at_utc_micros: i64,
    event_id: []const u8,
};

pub const InstallationEvent = struct {
    protocol_version: i64,
    kind: i64,
    event_name: []u8,
    path: []u8,
    received_at_utc_micros: i64,
};

pub const LegacyMigrationEvidence = struct {
    event_migration_version: i64,
    rows: i64,
    preserved_fingerprint: []u8,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    database: duckdb.Database,
    overview_result_cache: ?OverviewResultCache = null,
    property_catalog_cache: ?PropertyCatalogCache = null,
    session_detail_template: ?SessionDetailTemplate = null,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Store {
        return .{
            .allocator = allocator,
            .database = try duckdb.Database.open(allocator, path),
        };
    }

    pub fn openWithTemp(
        allocator: std.mem.Allocator,
        path: []const u8,
        temp_directory: []const u8,
    ) !Store {
        return .{
            .allocator = allocator,
            .database = try duckdb.Database.openWithTemp(
                allocator,
                path,
                temp_directory,
            ),
        };
    }

    pub fn deinit(self: *Store) void {
        if (self.overview_result_cache) |*cache| cache.deinit();
        if (self.property_catalog_cache) |*cache| cache.deinit();
        self.discardSessionDetailTemplate();
        self.database.deinit();
    }

    pub fn sessionDetailStatement(
        self: *Store,
        sql: [:0]const u8,
    ) !*duckdb.Statement {
        if (self.session_detail_template) |*template| {
            if (std.mem.eql(u8, template.sql, sql)) {
                template.statement.clear() catch |err| {
                    self.discardSessionDetailTemplate();
                    return err;
                };
                return &template.statement;
            }
        }
        self.discardSessionDetailTemplate();
        const owned_sql = try self.allocator.dupeSentinel(u8, sql, 0);
        errdefer self.allocator.free(owned_sql);
        var statement = try self.database.prepare(owned_sql);
        errdefer statement.deinit();
        self.session_detail_template = .{
            .sql = owned_sql,
            .statement = statement,
        };
        return &self.session_detail_template.?.statement;
    }

    pub fn discardSessionDetailTemplate(self: *Store) void {
        if (self.session_detail_template) |*template| {
            template.statement.deinit();
            self.allocator.free(template.sql);
        }
        self.session_detail_template = null;
    }

    pub fn migrate(self: *Store) !void {
        self.discardSessionDetailTemplate();
        try self.migrateThrough(schema_version);
        self.invalidateAnalysisCache();
        self.invalidatePropertyCatalogCache();
    }

    pub fn migrateFixtureV4(self: *Store) !void {
        self.discardSessionDetailTemplate();
        try self.migrateThrough(4);
        self.invalidateAnalysisCache();
        self.invalidatePropertyCatalogCache();
    }

    pub fn migrateFixtureV5(self: *Store) !void {
        self.discardSessionDetailTemplate();
        try self.migrateThrough(5);
        self.invalidateAnalysisCache();
        self.invalidatePropertyCatalogCache();
    }

    pub fn migrateFixtureV6(self: *Store) !void {
        self.discardSessionDetailTemplate();
        try self.migrateThrough(6);
        self.invalidateAnalysisCache();
        self.invalidatePropertyCatalogCache();
    }

    fn migrateThrough(self: *Store, target: i64) !void {
        if (target < 1 or target > schema_version) return error.InvalidEventSchema;
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
        if (current > target) return error.NewerEventSchema;
        if (current < 1 and target >= 1) {
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
        if (current < 2 and target >= 2) {
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
        if (current < 3 and target >= 3) {
            try self.migrateV3();
        }
        if (current < 4 and target >= 4) {
            try self.migrateV4();
        }
        if (current < 5 and target >= 5) {
            try self.migrateV5();
        }
        if (current < 6 and target >= 6) {
            try self.migrateV6();
        }
        if (current < 7 and target >= 7) {
            try self.migrateV7();
        }
        try self.database.checkpoint();
    }

    fn migrateV3(self: *Store) !void {
        try self.database.exec("BEGIN TRANSACTION");
        errdefer self.database.exec("ROLLBACK") catch {};
        try self.database.exec(
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
            \\    md5(
            \\      'analytico/legacy-daily/v1|' || site_id || '|' ||
            \\      CAST(received_date_utc AS VARCHAR) || '|' ||
            \\      hex(visitor_day_id)
            \\    ) AS legacy_identity_hash,
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
            \\  kind, event_name, path, '', '', CAST(
            \\    substr(legacy_identity_hash, 1, 8) || '-' ||
            \\    substr(legacy_identity_hash, 9, 4) || '-5' ||
            \\    substr(legacy_identity_hash, 14, 3) || '-a' ||
            \\    substr(legacy_identity_hash, 18, 3) || '-' ||
            \\    substr(legacy_identity_hash, 21, 12) AS UUID
            \\  ),
            \\  3, '', session_id, CAST(legacy_sequence AS UINTEGER),
            \\  session_start, referrer_host, country_code, '',
            \\  browser_family, os_family, device_category,
            \\  utm_source, utm_medium, utm_campaign, utm_term, utm_content,
            \\  properties_json, '{}', CAST(NULL AS DECIMAL(18,6)), '',
            \\  0, 0, visitor_day_id, visitor_day_start, ''
            \\FROM sequenced;
        );

        const preserved_mismatches = try self.scalar(
            \\SELECT count(*) FROM (
            \\  (SELECT CAST(event_id AS VARCHAR), site_id,
            \\          received_at_utc_micros, CAST(received_date_utc AS VARCHAR),
            \\          kind, event_name, path, visitor_day_id,
            \\          CAST(session_id AS VARCHAR), visitor_day_start,
            \\          session_start, referrer_host, country_code,
            \\          browser_family, os_family, device_category,
            \\          utm_source, utm_medium, utm_campaign, utm_term,
            \\          utm_content, properties_json
            \\   FROM events
            \\   EXCEPT ALL
            \\   SELECT CAST(event_id AS VARCHAR), site_id,
            \\          received_at_utc_micros, CAST(received_date_utc AS VARCHAR),
            \\          kind, event_name, path, visitor_day_id,
            \\          CAST(session_id AS VARCHAR), visitor_day_start,
            \\          session_start, referrer_host, country_code,
            \\          browser_family, os_family, device_category,
            \\          utm_source, utm_medium, utm_campaign, utm_term,
            \\          utm_content, properties_json
            \\   FROM events_v3)
            \\  UNION ALL
            \\  (SELECT CAST(event_id AS VARCHAR), site_id,
            \\          received_at_utc_micros, CAST(received_date_utc AS VARCHAR),
            \\          kind, event_name, path, visitor_day_id,
            \\          CAST(session_id AS VARCHAR), visitor_day_start,
            \\          session_start, referrer_host, country_code,
            \\          browser_family, os_family, device_category,
            \\          utm_source, utm_medium, utm_campaign, utm_term,
            \\          utm_content, properties_json
            \\   FROM events_v3
            \\   EXCEPT ALL
            \\   SELECT CAST(event_id AS VARCHAR), site_id,
            \\          received_at_utc_micros, CAST(received_date_utc AS VARCHAR),
            \\          kind, event_name, path, visitor_day_id,
            \\          CAST(session_id AS VARCHAR), visitor_day_start,
            \\          session_start, referrer_host, country_code,
            \\          browser_family, os_family, device_category,
            \\          utm_source, utm_medium, utm_campaign, utm_term,
            \\          utm_content, properties_json
            \\   FROM events)
            \\) differences
        );
        const mapping_mismatches = try self.scalar(
            \\SELECT count(*) FROM events_v3 WHERE
            \\  event_schema_version != 3 OR protocol_version != 1 OR
            \\  tracker_version != 1 OR
            \\  occurred_at_utc_micros != received_at_utc_micros OR
            \\  site_local_date != received_date_utc OR
            \\  site_utc_offset_minutes != 0 OR identity_quality != 3 OR
            \\  user_id != '' OR page_title != '' OR hostname != '' OR
            \\  language != '' OR user_traits_json != '{}' OR
            \\  value_amount IS NOT NULL OR value_currency != '' OR
            \\  engagement_ms != 0 OR max_scroll_depth != 0 OR
            \\  event_payload_digest != ''
        );
        const identity_mismatches = try self.scalar(
            \\WITH group_reuse AS (
            \\  SELECT 1 FROM events_v3
            \\  GROUP BY site_id, received_date_utc, visitor_day_id
            \\  HAVING count(DISTINCT anonymous_id) != 1
            \\), identity_reuse AS (
            \\  SELECT 1 FROM events_v3
            \\  GROUP BY anonymous_id
            \\  HAVING count(DISTINCT
            \\    site_id || '|' || CAST(received_date_utc AS VARCHAR) || '|' ||
            \\    hex(visitor_day_id)
            \\  ) != 1
            \\)
            \\SELECT (SELECT count(*) FROM group_reuse) +
            \\       (SELECT count(*) FROM identity_reuse)
        );
        const links = try self.scalar("SELECT count(*) FROM identity_links");
        if (preserved_mismatches != 0 or mapping_mismatches != 0 or
            identity_mismatches != 0 or links != 0)
        {
            return error.LegacyMigrationValidationFailed;
        }

        try self.database.exec(
            \\DROP TABLE events;
            \\ALTER TABLE events_v3 RENAME TO events;
            \\INSERT INTO event_migrations VALUES (
            \\  3, 'protocol-v2-event-foundation', 0
            \\)
        );
        try self.database.exec("COMMIT");
    }

    fn migrateV4(self: *Store) !void {
        try self.database.exec("BEGIN TRANSACTION");
        errdefer self.database.exec("ROLLBACK") catch {};
        try self.database.exec(
            \\CREATE TABLE events_v4 (
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
            \\  event_payload_digest VARCHAR NOT NULL,
            \\  exclusion_source UTINYINT NOT NULL,
            \\  CHECK (exclusion_source BETWEEN 0 AND 3)
            \\);
            \\INSERT INTO events_v4 SELECT
            \\  4, protocol_version, tracker_version, event_id, site_id,
            \\  received_at_utc_micros, occurred_at_utc_micros,
            \\  received_date_utc, site_local_date, site_utc_offset_minutes,
            \\  kind, event_name, path, page_title, hostname, anonymous_id,
            \\  identity_quality, user_id, session_id, sequence, session_start,
            \\  referrer_host, country_code, language, browser_family, os_family,
            \\  device_category, utm_source, utm_medium, utm_campaign, utm_term,
            \\  utm_content, properties_json, user_traits_json, value_amount,
            \\  value_currency, engagement_ms, max_scroll_depth, visitor_day_id,
            \\  visitor_day_start, event_payload_digest, 0
            \\FROM events;
        );
        const preserved_mismatches = try self.scalar(
            \\WITH source_rows AS (
            \\  SELECT hash(protocol_version, tracker_version, event_id, site_id,
            \\    received_at_utc_micros, occurred_at_utc_micros,
            \\    received_date_utc, site_local_date, site_utc_offset_minutes,
            \\    kind, event_name, path, page_title, hostname, anonymous_id,
            \\    identity_quality, user_id, session_id, sequence, session_start,
            \\    referrer_host, country_code, language, browser_family, os_family,
            \\    device_category, utm_source, utm_medium, utm_campaign, utm_term,
            \\    utm_content, properties_json, user_traits_json, value_amount,
            \\    value_currency, engagement_ms, max_scroll_depth, visitor_day_id,
            \\    visitor_day_start, event_payload_digest) AS row_hash
            \\  FROM events
            \\), target_rows AS (
            \\  SELECT hash(protocol_version, tracker_version, event_id, site_id,
            \\    received_at_utc_micros, occurred_at_utc_micros,
            \\    received_date_utc, site_local_date, site_utc_offset_minutes,
            \\    kind, event_name, path, page_title, hostname, anonymous_id,
            \\    identity_quality, user_id, session_id, sequence, session_start,
            \\    referrer_host, country_code, language, browser_family, os_family,
            \\    device_category, utm_source, utm_medium, utm_campaign, utm_term,
            \\    utm_content, properties_json, user_traits_json, value_amount,
            \\    value_currency, engagement_ms, max_scroll_depth, visitor_day_id,
            \\    visitor_day_start, event_payload_digest) AS row_hash
            \\  FROM events_v4
            \\), source AS (
            \\  SELECT count(*) AS rows, bit_xor(row_hash) AS xor_hash,
            \\    sum(CAST(row_hash AS UHUGEINT)) AS sum_hash,
            \\    min(row_hash) AS min_hash, max(row_hash) AS max_hash
            \\  FROM source_rows
            \\), target AS (
            \\  SELECT count(*) AS rows, bit_xor(row_hash) AS xor_hash,
            \\    sum(CAST(row_hash AS UHUGEINT)) AS sum_hash,
            \\    min(row_hash) AS min_hash, max(row_hash) AS max_hash
            \\  FROM target_rows
            \\)
            \\SELECT count(*) FROM source s, target t
            \\WHERE s.rows != t.rows OR s.xor_hash IS DISTINCT FROM t.xor_hash
            \\  OR s.sum_hash IS DISTINCT FROM t.sum_hash
            \\  OR s.min_hash IS DISTINCT FROM t.min_hash
            \\  OR s.max_hash IS DISTINCT FROM t.max_hash
        );
        const invalid = try self.scalar(
            "SELECT count(*) FROM events_v4 " ++
                "WHERE event_schema_version != 4 OR exclusion_source != 0",
        );
        if (preserved_mismatches != 0 or invalid != 0) {
            return error.ExclusionMigrationValidationFailed;
        }
        try self.database.exec(
            \\DROP TABLE events;
            \\ALTER TABLE events_v4 RENAME TO events;
            \\INSERT INTO event_migrations VALUES (
            \\  4, 'stored-self-exclusion', 0
            \\)
        );
        try self.database.exec("COMMIT");
    }

    fn migrateV5(self: *Store) !void {
        const links_before = try self.scalar(
            "SELECT count(*) FROM identity_links",
        );
        const links_hash_before = try self.scalar(
            \\SELECT CAST(COALESCE(bit_xor(
            \\  hash(site_id, anonymous_id, user_id, linked_at_utc_micros, event_id)
            \\  & 9223372036854775807
            \\), 0) AS BIGINT) FROM identity_links
        );
        try self.database.exec("BEGIN TRANSACTION");
        errdefer self.database.exec("ROLLBACK") catch {};
        try self.database.exec(
            \\CREATE TABLE events_v5 (
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
            \\  event_payload_digest VARCHAR NOT NULL,
            \\  traffic_class UTINYINT NOT NULL,
            \\  classifier_version USMALLINT NOT NULL,
            \\  bot_rule VARCHAR NOT NULL,
            \\  legacy_bot_verdict BOOLEAN NOT NULL,
            \\  CHECK (traffic_class BETWEEN 1 AND 5),
            \\  CHECK (length(bot_rule) <= 64)
            \\);
            \\INSERT INTO events_v5 SELECT
            \\  5, protocol_version, tracker_version, event_id, site_id,
            \\  received_at_utc_micros, occurred_at_utc_micros,
            \\  received_date_utc, site_local_date, site_utc_offset_minutes,
            \\  kind, event_name, path, page_title, hostname, anonymous_id,
            \\  identity_quality, user_id, session_id, sequence, session_start,
            \\  referrer_host, country_code, language, browser_family, os_family,
            \\  CASE WHEN device_category = 'bot'
            \\    THEN 'unknown' ELSE device_category END,
            \\  utm_source, utm_medium, utm_campaign, utm_term, utm_content,
            \\  properties_json, user_traits_json, value_amount, value_currency,
            \\  engagement_ms, max_scroll_depth, visitor_day_id,
            \\  visitor_day_start, event_payload_digest,
            \\  CASE WHEN exclusion_source != 0 THEN 4
            \\    WHEN device_category = 'bot' THEN 2 ELSE 1 END,
            \\  CASE WHEN exclusion_source != 0 THEN 1 ELSE 0 END,
            \\  CASE exclusion_source
            \\    WHEN 1 THEN 'exclude.tracker'
            \\    WHEN 2 THEN 'exclude.network'
            \\    WHEN 3 THEN 'exclude.both'
            \\    ELSE CASE WHEN device_category = 'bot'
            \\      THEN 'legacy-device-bot' ELSE '' END
            \\  END,
            \\  exclusion_source = 0 AND device_category = 'bot'
            \\FROM events;
        );
        const preserved_mismatches = try self.scalar(
            \\WITH source_rows AS (
            \\  SELECT hash(protocol_version, tracker_version, event_id, site_id,
            \\    received_at_utc_micros, occurred_at_utc_micros,
            \\    received_date_utc, site_local_date, site_utc_offset_minutes,
            \\    kind, event_name, path, page_title, hostname, anonymous_id,
            \\    identity_quality, user_id, session_id, sequence, session_start,
            \\    referrer_host, country_code, language, browser_family, os_family,
            \\    CASE WHEN device_category = 'bot'
            \\      THEN 'unknown' ELSE device_category END,
            \\    utm_source, utm_medium, utm_campaign, utm_term, utm_content,
            \\    properties_json, user_traits_json, value_amount, value_currency,
            \\    engagement_ms, max_scroll_depth, visitor_day_id,
            \\    visitor_day_start, event_payload_digest) AS row_hash
            \\  FROM events
            \\), target_rows AS (
            \\  SELECT hash(protocol_version, tracker_version, event_id, site_id,
            \\    received_at_utc_micros, occurred_at_utc_micros,
            \\    received_date_utc, site_local_date, site_utc_offset_minutes,
            \\    kind, event_name, path, page_title, hostname, anonymous_id,
            \\    identity_quality, user_id, session_id, sequence, session_start,
            \\    referrer_host, country_code, language, browser_family, os_family,
            \\    device_category, utm_source, utm_medium, utm_campaign, utm_term,
            \\    utm_content, properties_json, user_traits_json, value_amount,
            \\    value_currency, engagement_ms, max_scroll_depth, visitor_day_id,
            \\    visitor_day_start, event_payload_digest) AS row_hash
            \\  FROM events_v5
            \\), source AS (
            \\  SELECT count(*) AS rows, bit_xor(row_hash) AS xor_hash,
            \\    sum(CAST(row_hash AS UHUGEINT)) AS sum_hash,
            \\    min(row_hash) AS min_hash, max(row_hash) AS max_hash
            \\  FROM source_rows
            \\), target AS (
            \\  SELECT count(*) AS rows, bit_xor(row_hash) AS xor_hash,
            \\    sum(CAST(row_hash AS UHUGEINT)) AS sum_hash,
            \\    min(row_hash) AS min_hash, max(row_hash) AS max_hash
            \\  FROM target_rows
            \\)
            \\SELECT count(*) FROM source s, target t
            \\WHERE s.rows != t.rows OR s.xor_hash IS DISTINCT FROM t.xor_hash
            \\  OR s.sum_hash IS DISTINCT FROM t.sum_hash
            \\  OR s.min_hash IS DISTINCT FROM t.min_hash
            \\  OR s.max_hash IS DISTINCT FROM t.max_hash
        );
        const mapping_mismatches = try self.scalar(
            \\SELECT count(*)
            \\FROM events s
            \\FULL OUTER JOIN events_v5 t
            \\  ON s.site_id = t.site_id AND s.event_id = t.event_id
            \\WHERE s.event_id IS NULL OR t.event_id IS NULL
            \\  OR t.event_schema_version != 5
            \\  OR t.device_category != CASE
            \\    WHEN s.device_category = 'bot'
            \\    THEN 'unknown' ELSE s.device_category END
            \\  OR t.traffic_class != CASE WHEN s.exclusion_source != 0 THEN 4
            \\    WHEN s.device_category = 'bot' THEN 2 ELSE 1 END
            \\  OR t.classifier_version != CASE
            \\    WHEN s.exclusion_source != 0 THEN 1 ELSE 0 END
            \\  OR t.bot_rule != CASE s.exclusion_source
            \\    WHEN 1 THEN 'exclude.tracker'
            \\    WHEN 2 THEN 'exclude.network'
            \\    WHEN 3 THEN 'exclude.both'
            \\    ELSE CASE WHEN s.device_category = 'bot'
            \\      THEN 'legacy-device-bot' ELSE '' END END
            \\  OR t.legacy_bot_verdict !=
            \\    (s.exclusion_source = 0 AND s.device_category = 'bot')
        );
        const temporary_columns = try self.scalar(
            \\SELECT count(*) FROM information_schema.columns
            \\WHERE table_name = 'events_v5' AND column_name = 'exclusion_source'
        );
        const links_after = try self.scalar("SELECT count(*) FROM identity_links");
        const links_hash_after = try self.scalar(
            \\SELECT CAST(COALESCE(bit_xor(
            \\  hash(site_id, anonymous_id, user_id, linked_at_utc_micros, event_id)
            \\  & 9223372036854775807
            \\), 0) AS BIGINT) FROM identity_links
        );
        if (preserved_mismatches != 0 or mapping_mismatches != 0 or
            temporary_columns != 0 or links_before != links_after or
            links_hash_before != links_hash_after)
        {
            return error.TrafficClassMigrationValidationFailed;
        }
        try self.database.exec(
            \\DROP TABLE events;
            \\ALTER TABLE events_v5 RENAME TO events;
            \\INSERT INTO event_migrations VALUES (
            \\  5, 'traffic-class-v1-shadow', 0
            \\)
        );
        try self.database.exec("COMMIT");
    }

    fn migrateV6(self: *Store) !void {
        const links_before = try self.scalar(
            "SELECT count(*) FROM identity_links",
        );
        const links_hash_before = try self.scalar(
            \\SELECT CAST(COALESCE(bit_xor(
            \\  hash(site_id, anonymous_id, user_id, linked_at_utc_micros, event_id)
            \\  & 9223372036854775807
            \\), 0) AS BIGINT) FROM identity_links
        );
        try self.database.exec("BEGIN TRANSACTION");
        errdefer self.database.exec("ROLLBACK") catch {};
        try self.database.exec(
            \\CREATE TABLE events_v6 (
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
            \\  event_payload_digest VARCHAR NOT NULL,
            \\  traffic_class UTINYINT NOT NULL,
            \\  classifier_version USMALLINT NOT NULL,
            \\  bot_rule VARCHAR NOT NULL,
            \\  signal_version UTINYINT NOT NULL,
            \\  navigator_webdriver BOOLEAN NOT NULL,
            \\  trusted_interactions UTINYINT NOT NULL,
            \\  was_visible BOOLEAN NOT NULL,
            \\  was_prerendered BOOLEAN NOT NULL,
            \\  viewport_bucket UTINYINT NOT NULL,
            \\  beacon_timing_bucket UTINYINT NOT NULL,
            \\  client_hint_consistency UTINYINT NOT NULL,
            \\  accept_language_present BOOLEAN NOT NULL,
            \\  CHECK (traffic_class BETWEEN 1 AND 5),
            \\  CHECK (length(bot_rule) <= 64),
            \\  CHECK (signal_version BETWEEN 0 AND 1),
            \\  CHECK (trusted_interactions BETWEEN 0 AND 15),
            \\  CHECK (viewport_bucket BETWEEN 0 AND 4),
            \\  CHECK (beacon_timing_bucket BETWEEN 0 AND 4),
            \\  CHECK (client_hint_consistency BETWEEN 0 AND 3)
            \\);
            \\INSERT INTO events_v6 SELECT
            \\  6, protocol_version, tracker_version, event_id, site_id,
            \\  received_at_utc_micros, occurred_at_utc_micros,
            \\  received_date_utc, site_local_date, site_utc_offset_minutes,
            \\  kind, event_name, path, page_title, hostname, anonymous_id,
            \\  identity_quality, user_id, session_id, sequence, session_start,
            \\  referrer_host, country_code, language, browser_family, os_family,
            \\  device_category, utm_source, utm_medium, utm_campaign, utm_term,
            \\  utm_content, properties_json, user_traits_json, value_amount,
            \\  value_currency, engagement_ms, max_scroll_depth, visitor_day_id,
            \\  visitor_day_start, event_payload_digest, traffic_class,
            \\  classifier_version, bot_rule,
            \\  0, FALSE, 0, FALSE, FALSE, 0, 0, 0, FALSE
            \\FROM events;
        );
        const preserved_mismatches = try self.scalar(
            \\WITH source_rows AS (
            \\  SELECT hash(protocol_version, tracker_version, event_id, site_id,
            \\    received_at_utc_micros, occurred_at_utc_micros,
            \\    received_date_utc, site_local_date, site_utc_offset_minutes,
            \\    kind, event_name, path, page_title, hostname, anonymous_id,
            \\    identity_quality, user_id, session_id, sequence, session_start,
            \\    referrer_host, country_code, language, browser_family, os_family,
            \\    device_category, utm_source, utm_medium, utm_campaign, utm_term,
            \\    utm_content, properties_json, user_traits_json, value_amount,
            \\    value_currency, engagement_ms, max_scroll_depth, visitor_day_id,
            \\    visitor_day_start, event_payload_digest, traffic_class,
            \\    classifier_version, bot_rule) AS row_hash
            \\  FROM events
            \\), target_rows AS (
            \\  SELECT hash(protocol_version, tracker_version, event_id, site_id,
            \\    received_at_utc_micros, occurred_at_utc_micros,
            \\    received_date_utc, site_local_date, site_utc_offset_minutes,
            \\    kind, event_name, path, page_title, hostname, anonymous_id,
            \\    identity_quality, user_id, session_id, sequence, session_start,
            \\    referrer_host, country_code, language, browser_family, os_family,
            \\    device_category, utm_source, utm_medium, utm_campaign, utm_term,
            \\    utm_content, properties_json, user_traits_json, value_amount,
            \\    value_currency, engagement_ms, max_scroll_depth, visitor_day_id,
            \\    visitor_day_start, event_payload_digest, traffic_class,
            \\    classifier_version, bot_rule) AS row_hash
            \\  FROM events_v6
            \\), source AS (
            \\  SELECT count(*) AS rows, bit_xor(row_hash) AS xor_hash,
            \\    sum(CAST(row_hash AS UHUGEINT)) AS sum_hash,
            \\    min(row_hash) AS min_hash, max(row_hash) AS max_hash
            \\  FROM source_rows
            \\), target AS (
            \\  SELECT count(*) AS rows, bit_xor(row_hash) AS xor_hash,
            \\    sum(CAST(row_hash AS UHUGEINT)) AS sum_hash,
            \\    min(row_hash) AS min_hash, max(row_hash) AS max_hash
            \\  FROM target_rows
            \\)
            \\SELECT count(*) FROM source s, target t
            \\WHERE s.rows != t.rows OR s.xor_hash IS DISTINCT FROM t.xor_hash
            \\  OR s.sum_hash IS DISTINCT FROM t.sum_hash
            \\  OR s.min_hash IS DISTINCT FROM t.min_hash
            \\  OR s.max_hash IS DISTINCT FROM t.max_hash
        );
        const mapping_mismatches = try self.scalar(
            \\SELECT count(*) FROM events_v6
            \\WHERE event_schema_version != 6 OR signal_version != 0
            \\  OR navigator_webdriver OR trusted_interactions != 0
            \\  OR was_visible OR was_prerendered OR viewport_bucket != 0
            \\  OR beacon_timing_bucket != 0 OR client_hint_consistency != 0
            \\  OR accept_language_present
        );
        const shadow_columns = try self.scalar(
            \\SELECT count(*) FROM information_schema.columns
            \\WHERE table_name = 'events_v6'
            \\  AND column_name = 'legacy_bot_verdict'
        );
        const links_after = try self.scalar("SELECT count(*) FROM identity_links");
        const links_hash_after = try self.scalar(
            \\SELECT CAST(COALESCE(bit_xor(
            \\  hash(site_id, anonymous_id, user_id, linked_at_utc_micros, event_id)
            \\  & 9223372036854775807
            \\), 0) AS BIGINT) FROM identity_links
        );
        if (preserved_mismatches != 0 or mapping_mismatches != 0 or
            shadow_columns != 0 or links_before != links_after or
            links_hash_before != links_hash_after)
        {
            return error.BotSignalMigrationValidationFailed;
        }
        try self.database.exec(
            \\DROP TABLE events;
            \\ALTER TABLE events_v6 RENAME TO events;
            \\INSERT INTO event_migrations VALUES (
            \\  6, 'bounded-bot-signals', 0
            \\)
        );
        try self.database.exec("COMMIT");
    }

    fn migrateV7(self: *Store) !void {
        const links_before = try self.scalar("SELECT count(*) FROM identity_links");
        const links_hash_before = try self.scalar(
            \\SELECT CAST(COALESCE(bit_xor(
            \\  hash(site_id, anonymous_id, user_id, linked_at_utc_micros, event_id)
            \\  & 9223372036854775807
            \\), 0) AS BIGINT) FROM identity_links
        );
        try self.database.exec("BEGIN TRANSACTION");
        errdefer self.database.exec("ROLLBACK") catch {};
        try self.database.exec(
            \\CREATE TABLE events_v7 (
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
            \\  event_payload_digest VARCHAR NOT NULL,
            \\  traffic_class UTINYINT NOT NULL,
            \\  classifier_version USMALLINT NOT NULL,
            \\  bot_rule VARCHAR NOT NULL,
            \\  signal_version UTINYINT NOT NULL,
            \\  navigator_webdriver BOOLEAN NOT NULL,
            \\  trusted_interactions UTINYINT NOT NULL,
            \\  was_visible BOOLEAN NOT NULL,
            \\  was_prerendered BOOLEAN NOT NULL,
            \\  viewport_bucket UTINYINT NOT NULL,
            \\  beacon_timing_bucket UTINYINT NOT NULL,
            \\  client_hint_consistency UTINYINT NOT NULL,
            \\  accept_language_present BOOLEAN NOT NULL,
            \\  network_day_id BLOB NOT NULL,
            \\  CHECK (traffic_class BETWEEN 1 AND 5),
            \\  CHECK (length(bot_rule) <= 64),
            \\  CHECK (signal_version BETWEEN 0 AND 1),
            \\  CHECK (trusted_interactions BETWEEN 0 AND 15),
            \\  CHECK (viewport_bucket BETWEEN 0 AND 4),
            \\  CHECK (beacon_timing_bucket BETWEEN 0 AND 4),
            \\  CHECK (client_hint_consistency BETWEEN 0 AND 3),
            \\  CHECK (octet_length(network_day_id) = 16)
            \\);
            \\INSERT INTO events_v7 SELECT
            \\  7, protocol_version, tracker_version, event_id, site_id,
            \\  received_at_utc_micros, occurred_at_utc_micros,
            \\  received_date_utc, site_local_date, site_utc_offset_minutes,
            \\  kind, event_name, path, page_title, hostname, anonymous_id,
            \\  identity_quality, user_id, session_id, sequence, session_start,
            \\  referrer_host, country_code, language, browser_family, os_family,
            \\  device_category, utm_source, utm_medium, utm_campaign, utm_term,
            \\  utm_content, properties_json, user_traits_json, value_amount,
            \\  value_currency, engagement_ms, max_scroll_depth, visitor_day_id,
            \\  visitor_day_start, event_payload_digest, traffic_class,
            \\  classifier_version, bot_rule, signal_version, navigator_webdriver,
            \\  trusted_interactions, was_visible, was_prerendered,
            \\  viewport_bucket, beacon_timing_bucket, client_hint_consistency,
            \\  accept_language_present,
            \\  from_hex('00000000000000000000000000000000')
            \\FROM events;
        );
        const preserved_mismatches = try self.scalar(
            \\WITH source_rows AS (
            \\  SELECT hash(protocol_version, tracker_version, event_id, site_id,
            \\    received_at_utc_micros, occurred_at_utc_micros,
            \\    received_date_utc, site_local_date, site_utc_offset_minutes,
            \\    kind, event_name, path, page_title, hostname, anonymous_id,
            \\    identity_quality, user_id, session_id, sequence, session_start,
            \\    referrer_host, country_code, language, browser_family, os_family,
            \\    device_category, utm_source, utm_medium, utm_campaign, utm_term,
            \\    utm_content, properties_json, user_traits_json, value_amount,
            \\    value_currency, engagement_ms, max_scroll_depth, visitor_day_id,
            \\    visitor_day_start, event_payload_digest, traffic_class,
            \\    classifier_version, bot_rule, signal_version, navigator_webdriver,
            \\    trusted_interactions, was_visible, was_prerendered,
            \\    viewport_bucket, beacon_timing_bucket, client_hint_consistency,
            \\    accept_language_present) AS row_hash FROM events
            \\), target_rows AS (
            \\  SELECT hash(protocol_version, tracker_version, event_id, site_id,
            \\    received_at_utc_micros, occurred_at_utc_micros,
            \\    received_date_utc, site_local_date, site_utc_offset_minutes,
            \\    kind, event_name, path, page_title, hostname, anonymous_id,
            \\    identity_quality, user_id, session_id, sequence, session_start,
            \\    referrer_host, country_code, language, browser_family, os_family,
            \\    device_category, utm_source, utm_medium, utm_campaign, utm_term,
            \\    utm_content, properties_json, user_traits_json, value_amount,
            \\    value_currency, engagement_ms, max_scroll_depth, visitor_day_id,
            \\    visitor_day_start, event_payload_digest, traffic_class,
            \\    classifier_version, bot_rule, signal_version, navigator_webdriver,
            \\    trusted_interactions, was_visible, was_prerendered,
            \\    viewport_bucket, beacon_timing_bucket, client_hint_consistency,
            \\    accept_language_present) AS row_hash FROM events_v7
            \\), source AS (
            \\  SELECT count(*) AS row_count, bit_xor(row_hash) AS xor_hash,
            \\    sum(CAST(row_hash AS UHUGEINT)) sum_hash,
            \\    min(row_hash) min_hash, max(row_hash) max_hash FROM source_rows
            \\), target AS (
            \\  SELECT count(*) AS row_count, bit_xor(row_hash) AS xor_hash,
            \\    sum(CAST(row_hash AS UHUGEINT)) sum_hash,
            \\    min(row_hash) min_hash, max(row_hash) max_hash FROM target_rows
            \\)
            \\SELECT count(*) FROM source s, target t
            \\WHERE s.row_count != t.row_count OR s.xor_hash IS DISTINCT FROM t.xor_hash
            \\  OR s.sum_hash IS DISTINCT FROM t.sum_hash
            \\  OR s.min_hash IS DISTINCT FROM t.min_hash
            \\  OR s.max_hash IS DISTINCT FROM t.max_hash
        );
        const mapping_mismatches = try self.scalar(
            \\SELECT count(*) FROM events_v7
            \\WHERE event_schema_version != 7 OR
            \\  network_day_id != from_hex('00000000000000000000000000000000') OR
            \\  octet_length(network_day_id) != 16
        );
        const links_after = try self.scalar("SELECT count(*) FROM identity_links");
        const links_hash_after = try self.scalar(
            \\SELECT CAST(COALESCE(bit_xor(
            \\  hash(site_id, anonymous_id, user_id, linked_at_utc_micros, event_id)
            \\  & 9223372036854775807
            \\), 0) AS BIGINT) FROM identity_links
        );
        if (preserved_mismatches != 0 or mapping_mismatches != 0 or
            links_before != links_after or links_hash_before != links_hash_after)
        {
            return error.NetworkDayMigrationValidationFailed;
        }
        try self.database.exec(
            \\DROP TABLE events;
            \\ALTER TABLE events_v7 RENAME TO events;
            \\INSERT INTO event_migrations VALUES (
            \\  7, 'keyed-network-day-evidence', 0
            \\)
        );
        try self.database.exec("COMMIT");
    }

    pub fn insert(self: *Store, event: domain.Event) !void {
        return self.insertWithCeiling(event, 10_000_000);
    }

    pub fn insertWithCeiling(
        self: *Store,
        event: domain.Event,
        daily_event_ceiling: i64,
    ) !void {
        try domain.validateUuid(event.event_id);
        try domain.validateUuid(event.site_id);
        try domain.validateDate(event.received_date_utc);
        try domain.validateDate(event.site_local_date);
        try domain.validateIdentifier(event.event_name);
        _ = try domain.normalizePath(event.path);
        if (event.kind != 1 and event.kind != 2) return error.InvalidEventKind;
        try validateTrafficClassification(
            event.traffic_class,
            event.classifier_version,
            event.bot_rule,
        );
        try validateSignals(event.signals, event.client_hint_consistency);
        if (std.mem.eql(u8, event.device_category, "bot")) {
            return error.InvalidDeviceCategory;
        }

        try self.database.exec("BEGIN TRANSACTION");
        errdefer self.database.exec("ROLLBACK") catch {};
        try self.enforceDailyCeiling(
            event.site_id,
            event.site_local_date,
            daily_event_ceiling,
        );

        var statement = try self.database.prepare(
            \\INSERT INTO events
            \\WITH incoming (
            \\  event_id, site_id, received_at_utc_micros, received_date_utc,
            \\  site_local_date, site_utc_offset_minutes,
            \\  kind, event_name, path, visitor_day_id, referrer_host,
            \\  country_code, browser_family, os_family, device_category,
            \\  utm_source, utm_medium, utm_campaign, utm_term, utm_content,
            \\  properties_json, traffic_class, classifier_version, bot_rule,
            \\  signal_version, navigator_webdriver, trusted_interactions,
            \\  was_visible, was_prerendered, viewport_bucket,
            \\  beacon_timing_bucket, client_hint_consistency,
            \\  accept_language_present, network_day_id
            \\) AS (
            \\  SELECT ?, ?, ?, CAST(? AS DATE), CAST(? AS DATE), ?,
            \\         ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
            \\         ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
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
            \\      AND e.traffic_class IN (1, 5)
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
            \\      AND e.traffic_class IN (1, 5)
            \\    LIMIT 1
            \\  ) a ON true
            \\)
            \\SELECT
            \\  7, 1, 1, CAST(i.event_id AS UUID), i.site_id,
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
            \\  i.traffic_class IN (1, 5)
            \\    AND (i.prior_session_id IS NULL
            \\    OR i.received_at_utc_micros - i.prior_at > 1800000000),
            \\  i.referrer_host, i.country_code, '', i.browser_family, i.os_family,
            \\  i.device_category, i.utm_source, i.utm_medium, i.utm_campaign,
            \\  i.utm_term, i.utm_content, i.properties_json
            \\  , '{}', CAST(NULL AS DECIMAL(18,6)), '', 0, 0,
            \\  i.visitor_day_id,
            \\  i.traffic_class IN (1, 5)
            \\    AND i.prior_session_id IS NULL, '',
            \\  i.traffic_class, i.classifier_version, i.bot_rule,
            \\  i.signal_version, i.navigator_webdriver,
            \\  i.trusted_interactions, i.was_visible, i.was_prerendered,
            \\  i.viewport_bucket, i.beacon_timing_bucket,
            \\  i.client_hint_consistency, i.accept_language_present,
            \\  i.network_day_id
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
        try statement.bindInt64(22, @backingInt(event.traffic_class));
        try statement.bindInt64(23, event.classifier_version);
        try statement.bindText(24, event.bot_rule);
        try statement.bindInt64(25, event.signals.version);
        try statement.bindInt64(26, @intFromBool(event.signals.navigator_webdriver));
        try statement.bindInt64(27, event.signals.trusted_interactions);
        try statement.bindInt64(28, @intFromBool(event.signals.was_visible));
        try statement.bindInt64(29, @intFromBool(event.signals.was_prerendered));
        try statement.bindInt64(30, event.signals.viewport_bucket);
        try statement.bindInt64(31, event.signals.beacon_timing_bucket);
        try statement.bindInt64(32, @backingInt(event.client_hint_consistency));
        try statement.bindInt64(33, @intFromBool(event.accept_language_present));
        try statement.bindBlob(34, &event.network_day_id);
        var result = try statement.execute();
        result.deinit();
        try self.database.exec("COMMIT");
        self.invalidateAnalysisCache();
    }

    pub fn insertV2(
        self: *Store,
        allocator: std.mem.Allocator,
        event: domain.EventV2,
    ) !InsertV2Outcome {
        return self.insertV2WithCeiling(allocator, event, 10_000_000);
    }

    pub fn insertV2WithCeiling(
        self: *Store,
        allocator: std.mem.Allocator,
        event: domain.EventV2,
        daily_event_ceiling: i64,
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
        try validateTrafficClassification(
            event.traffic_class,
            event.classifier_version,
            event.bot_rule,
        );
        try validateSignals(event.signals, event.client_hint_consistency);
        if (std.mem.eql(u8, event.device_category, "bot")) {
            return error.InvalidDeviceCategory;
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
        try self.enforceDailyCeiling(
            event.site_id,
            event.site_local_date,
            daily_event_ceiling,
        );
        if (event.identify_user_id.len != 0 and linked_user == null and
            event.traffic_class.productEligible())
        {
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
            \\  max_scroll_depth, visitor_day_id, payload_digest,
            \\  traffic_class, classifier_version, bot_rule,
            \\  signal_version, navigator_webdriver, trusted_interactions,
            \\  was_visible, was_prerendered, viewport_bucket,
            \\  beacon_timing_bucket, client_hint_consistency,
            \\  accept_language_present, network_day_id
            \\) AS (
            \\  SELECT ?, ?, ?, ?, CAST(? AS DATE), CAST(? AS DATE), ?,
            \\         ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
            \\         ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
            \\         ?, ?, ?, ?, ?, ?, ?, ?
            \\)
            \\SELECT
            \\  7, 2, 2, CAST(i.event_id AS UUID), i.site_id,
            \\  i.received_at, i.occurred_at, i.received_date,
            \\  i.site_local_date, i.site_utc_offset_minutes,
            \\  i.kind, i.event_name, i.path,
            \\  i.page_title, i.hostname, CAST(i.anonymous_id AS UUID),
            \\  i.identity_quality, i.user_id, CAST(i.session_id AS UUID),
            \\  i.sequence,
            \\  i.traffic_class IN (1, 5)
            \\  AND NOT EXISTS (
            \\    SELECT 1 FROM events e
            \\    WHERE e.site_id = i.site_id
            \\      AND e.session_id = CAST(i.session_id AS UUID)
            \\      AND e.traffic_class IN (1, 5)
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
            \\  i.traffic_class IN (1, 5)
            \\  AND NOT EXISTS (
            \\    SELECT 1 FROM events e
            \\    WHERE e.site_id = i.site_id
            \\      AND e.received_date_utc = i.received_date
            \\      AND e.visitor_day_id = i.visitor_day_id
            \\      AND e.traffic_class IN (1, 5)
            \\  ),
            \\  i.payload_digest, i.traffic_class, i.classifier_version,
            \\  i.bot_rule, i.signal_version, i.navigator_webdriver,
            \\  i.trusted_interactions, i.was_visible, i.was_prerendered,
            \\  i.viewport_bucket, i.beacon_timing_bucket,
            \\  i.client_hint_consistency, i.accept_language_present,
            \\  i.network_day_id
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
        try statement.bindInt64(37, @backingInt(event.traffic_class));
        try statement.bindInt64(38, event.classifier_version);
        try statement.bindText(39, event.bot_rule);
        try statement.bindInt64(40, event.signals.version);
        try statement.bindInt64(41, @intFromBool(event.signals.navigator_webdriver));
        try statement.bindInt64(42, event.signals.trusted_interactions);
        try statement.bindInt64(43, @intFromBool(event.signals.was_visible));
        try statement.bindInt64(44, @intFromBool(event.signals.was_prerendered));
        try statement.bindInt64(45, event.signals.viewport_bucket);
        try statement.bindInt64(46, event.signals.beacon_timing_bucket);
        try statement.bindInt64(47, @backingInt(event.client_hint_consistency));
        try statement.bindInt64(48, @intFromBool(event.accept_language_present));
        try statement.bindBlob(49, &event.network_day_id);
        var result = try statement.execute();
        result.deinit();
        try self.database.exec("COMMIT");
        self.invalidateAnalysisCache();
        return .inserted;
    }

    fn enforceDailyCeiling(
        self: *Store,
        site_id: []const u8,
        site_local_date: []const u8,
        daily_event_ceiling: i64,
    ) !void {
        if (daily_event_ceiling < 1 or daily_event_ceiling > 10_000_000) {
            return error.InvalidDailyEventCeiling;
        }
        var statement = try self.database.prepare(
            \\SELECT count(*) FROM events
            \\WHERE site_id = ? AND site_local_date = CAST(? AS DATE)
        );
        defer statement.deinit();
        try statement.bindText(1, site_id);
        try statement.bindText(2, site_local_date);
        var result = try statement.execute();
        defer result.deinit();
        if (result.rowCount() != 1 or result.columnCount() != 1) {
            return error.InvalidDailyEventCount;
        }
        const count = result.int64(0, 0);
        if (count < 0) return error.InvalidDailyEventCount;
        if (count >= daily_event_ceiling) return error.DailyEventCeilingReached;
    }

    pub fn requireCurrent(self: *Store) !void {
        const current = try self.migrationVersion();
        if (current > schema_version) return error.NewerEventSchema;
        if (current < schema_version) return error.EventMigrationRequired;
    }

    pub fn legacyMigrationEvidence(
        self: *Store,
        allocator: std.mem.Allocator,
    ) !LegacyMigrationEvidence {
        const current = try self.migrationVersion();
        const source_sql: [:0]const u8 =
            \\SELECT count(*), to_hex(COALESCE(bit_xor(hash(
            \\  event_id, site_id, received_at_utc_micros, received_date_utc,
            \\  kind, event_name, path, visitor_day_id, session_id,
            \\  visitor_day_start, session_start, referrer_host, country_code,
            \\  browser_family, os_family, device_category, utm_source,
            \\  utm_medium, utm_campaign, utm_term, utm_content, properties_json
            \\)), 0::UBIGINT))
            \\FROM events
        ;
        const migrated_sql: [:0]const u8 =
            \\SELECT count(*), to_hex(COALESCE(bit_xor(hash(
            \\  event_id, site_id, received_at_utc_micros, received_date_utc,
            \\  kind, event_name, path, visitor_day_id, session_id,
            \\  visitor_day_start, session_start, referrer_host, country_code,
            \\  browser_family, os_family, device_category, utm_source,
            \\  utm_medium, utm_campaign, utm_term, utm_content, properties_json
            \\)), 0::UBIGINT))
            \\FROM events WHERE identity_quality = 3
        ;
        var result = try self.database.query(switch (current) {
            2 => source_sql,
            3, 4, 5, 6, 7 => migrated_sql,
            else => return error.UnsupportedLegacyEvidenceSchema,
        });
        defer result.deinit();
        if (result.rowCount() != 1 or result.columnCount() != 2) {
            return error.InvalidLegacyEvidence;
        }
        return .{
            .event_migration_version = current,
            .rows = result.int64(0, 0),
            .preserved_fingerprint = try result.text(allocator, 1, 0),
        };
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

    pub fn installationWatermark(
        self: *Store,
        allocator: std.mem.Allocator,
        site_id: []const u8,
    ) !InstallationWatermark {
        try domain.validateUuid(site_id);
        const bounds = try self.siteEventBounds(site_id);
        if (bounds.count == 0) return .{
            .event_count = 0,
            .received_at_utc_micros = 0,
            .event_id = try allocator.dupe(
                u8,
                "00000000-0000-0000-0000-000000000000",
            ),
        };
        var statement = try self.database.prepare(
            \\SELECT received_at_utc_micros, CAST(event_id AS VARCHAR)
            \\FROM events
            \\WHERE site_id = ? AND protocol_version IN (1, 2)
            \\  AND received_at_utc_micros = ?
            \\ORDER BY event_id DESC
            \\LIMIT 1
        );
        defer statement.deinit();
        try statement.bindText(1, site_id);
        try statement.bindInt64(2, bounds.maximum_utc_micros);
        var result = try statement.execute();
        defer result.deinit();
        if (result.columnCount() != 2 or result.rowCount() > 1) {
            return error.InvalidInstallationWatermark;
        }
        if (result.rowCount() == 0) return error.InvalidInstallationWatermark;
        const event_id = try result.text(allocator, 1, 0);
        errdefer allocator.free(event_id);
        try domain.validateUuid(event_id);
        const received_at_utc_micros = result.int64(0, 0);
        if (received_at_utc_micros < 0) return error.InvalidInstallationWatermark;
        return .{
            .event_count = bounds.count,
            .received_at_utc_micros = received_at_utc_micros,
            .event_id = event_id,
        };
    }

    pub fn firstInstallationEventAfter(
        self: *Store,
        allocator: std.mem.Allocator,
        site_id: []const u8,
        watermark: InstallationWatermark,
    ) !?InstallationEvent {
        try domain.validateUuid(site_id);
        try domain.validateUuid(watermark.event_id);
        if (watermark.event_count < 0 or watermark.received_at_utc_micros < 0) {
            return error.InvalidInstallationWatermark;
        }
        const current_count = try self.siteEventCount(site_id);
        if (current_count <= watermark.event_count) return null;

        var tie_statement = try self.database.prepare(
            \\SELECT protocol_version, kind, event_name, path,
            \\       received_at_utc_micros
            \\FROM events
            \\WHERE site_id = ? AND protocol_version IN (1, 2)
            \\  AND received_at_utc_micros = ?
            \\  AND event_id > CAST(? AS UUID)
            \\ORDER BY event_id
            \\LIMIT 1
        );
        defer tie_statement.deinit();
        try tie_statement.bindText(1, site_id);
        try tie_statement.bindInt64(2, watermark.received_at_utc_micros);
        try tie_statement.bindText(3, watermark.event_id);
        if (try executeInstallationEvent(allocator, &tie_statement)) |event| {
            return event;
        }

        var later_statement = try self.database.prepare(
            \\SELECT protocol_version, kind, event_name, path,
            \\       received_at_utc_micros
            \\FROM events
            \\WHERE site_id = ? AND protocol_version IN (1, 2)
            \\  AND received_at_utc_micros > ?
            \\ORDER BY received_at_utc_micros, event_id
            \\LIMIT 1
        );
        defer later_statement.deinit();
        try later_statement.bindText(1, site_id);
        try later_statement.bindInt64(2, watermark.received_at_utc_micros);
        return executeInstallationEvent(allocator, &later_statement);
    }

    fn siteEventCount(self: *Store, site_id: []const u8) !i64 {
        var statement = try self.database.prepare(
            "SELECT count(*) FROM events WHERE site_id = ?",
        );
        defer statement.deinit();
        try statement.bindText(1, site_id);
        var result = try statement.execute();
        defer result.deinit();
        if (result.columnCount() != 1 or result.rowCount() != 1) {
            return error.InvalidInstallationEventCount;
        }
        const count = result.int64(0, 0);
        if (count < 0) return error.InvalidInstallationEventCount;
        return count;
    }

    fn executeInstallationEvent(
        allocator: std.mem.Allocator,
        statement: *duckdb.Statement,
    ) !?InstallationEvent {
        var result = try statement.execute();
        defer result.deinit();
        if (result.columnCount() != 5 or result.rowCount() > 1) {
            return error.InvalidInstallationEvent;
        }
        if (result.rowCount() == 0) return null;
        const protocol_version = result.int64(0, 0);
        const kind = result.int64(1, 0);
        const received_at_utc_micros = result.int64(4, 0);
        if ((protocol_version != 1 and protocol_version != 2) or
            kind < 1 or kind > 4 or received_at_utc_micros < 0)
        {
            return error.InvalidInstallationEvent;
        }
        return .{
            .protocol_version = protocol_version,
            .kind = kind,
            .event_name = try result.text(allocator, 2, 0),
            .path = try result.text(allocator, 3, 0),
            .received_at_utc_micros = received_at_utc_micros,
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
        self.invalidateAnalysisCache();
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
        self.invalidateAnalysisCache();
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
        self.invalidateAnalysisCache();
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
            \\       utm_content, properties_json, traffic_class,
            \\       classifier_version, bot_rule, signal_version,
            \\       navigator_webdriver, trusted_interactions, was_visible,
            \\       was_prerendered, viewport_bucket, beacon_timing_bucket,
            \\       client_hint_consistency, accept_language_present
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
        if (result.columnCount() != 27) return error.InvalidExportResult;
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
                .traffic_class = result.int64(15, index),
                .classifier_version = result.int64(16, index),
                .bot_rule = try result.text(allocator, 17, index),
                .signals = .{
                    .version = @intCast(result.int64(18, index)),
                    .navigator_webdriver = result.int64(19, index) != 0,
                    .trusted_interactions = @intCast(result.int64(20, index)),
                    .was_visible = result.int64(21, index) != 0,
                    .was_prerendered = result.int64(22, index) != 0,
                    .viewport_bucket = @intCast(result.int64(23, index)),
                    .beacon_timing_bucket = @intCast(result.int64(24, index)),
                },
                .client_hint_consistency = result.int64(25, index),
                .accept_language_present = result.int64(26, index) != 0,
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
            \\       utm_source, properties_json, traffic_class,
            \\       classifier_version, bot_rule, signal_version,
            \\       navigator_webdriver, trusted_interactions, was_visible,
            \\       was_prerendered, viewport_bucket, beacon_timing_bucket,
            \\       client_hint_consistency, accept_language_present
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
            .traffic_class = result.int64(9, 0),
            .classifier_version = result.int64(10, 0),
            .bot_rule = try result.text(allocator, 11, 0),
            .signals = .{
                .version = @intCast(result.int64(12, 0)),
                .navigator_webdriver = result.int64(13, 0) != 0,
                .trusted_interactions = @intCast(result.int64(14, 0)),
                .was_visible = result.int64(15, 0) != 0,
                .was_prerendered = result.int64(16, 0) != 0,
                .viewport_bucket = @intCast(result.int64(17, 0)),
                .beacon_timing_bucket = @intCast(result.int64(18, 0)),
            },
            .client_hint_consistency = result.int64(19, 0),
            .accept_language_present = result.int64(20, 0) != 0,
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
            \\       utm_source, properties_json, traffic_class,
            \\       classifier_version, bot_rule, signal_version,
            \\       navigator_webdriver, trusted_interactions, was_visible,
            \\       was_prerendered, viewport_bucket, beacon_timing_bucket,
            \\       client_hint_consistency, accept_language_present
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
            \\  COALESCE(l.user_id, ''), e.traffic_class,
            \\  e.classifier_version, e.bot_rule, e.signal_version,
            \\  e.navigator_webdriver, e.trusted_interactions, e.was_visible,
            \\  e.was_prerendered, e.viewport_bucket, e.beacon_timing_bucket,
            \\  e.client_hint_consistency, e.accept_language_present
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
        if (result.rowCount() != 1 or result.columnCount() != 49) {
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
            .traffic_class = result.int64(37, 0),
            .classifier_version = result.int64(38, 0),
            .bot_rule = try result.text(allocator, 39, 0),
            .signals = .{
                .version = @intCast(result.int64(40, 0)),
                .navigator_webdriver = result.int64(41, 0) != 0,
                .trusted_interactions = @intCast(result.int64(42, 0)),
                .was_visible = result.int64(43, 0) != 0,
                .was_prerendered = result.int64(44, 0) != 0,
                .viewport_bucket = @intCast(result.int64(45, 0)),
                .beacon_timing_bucket = @intCast(result.int64(46, 0)),
            },
            .client_hint_consistency = result.int64(47, 0),
            .accept_language_present = result.int64(48, 0) != 0,
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
            \\  AND e.traffic_class IN (1, 5)
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
            \\      AND e.traffic_class IN (1, 5)
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

    fn invalidateAnalysisCache(self: *Store) void {
        if (self.overview_result_cache) |*cache| cache.deinit();
        self.overview_result_cache = null;
    }

    fn invalidatePropertyCatalogCache(self: *Store) void {
        if (self.property_catalog_cache) |*cache| cache.deinit();
        self.property_catalog_cache = null;
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

pub const OverviewResultCache = struct {
    arena: std.heap.ArenaAllocator,
    key: []const u8,
    result: analysis.OverviewResult,

    pub fn deinit(self: *OverviewResultCache) void {
        self.arena.deinit();
    }
};

pub const PropertyCatalogCache = struct {
    arena: std.heap.ArenaAllocator,
    key: []const u8,
    catalog: analysis.PropertyCatalog,
    expires_at_nanos: i128,

    pub fn deinit(self: *PropertyCatalogCache) void {
        self.arena.deinit();
    }
};

pub const SessionDetailTemplate = struct {
    sql: [:0]u8,
    statement: duckdb.Statement,
};

fn validateTrafficClassification(
    traffic_class: domain.TrafficClass,
    classifier_version: u16,
    bot_rule: []const u8,
) !void {
    if (bot_rule.len > 64) {
        return error.InvalidTrafficClassification;
    }
    for (bot_rule) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or
            byte == '_' or byte == '-'))
        {
            return error.InvalidTrafficClassification;
        }
    }
    switch (traffic_class) {
        .human_presumed => if (classifier_version != 2 or bot_rule.len != 0)
            return error.InvalidTrafficClassification,
        .declared_bot, .automation => if (classifier_version != 2 or
            bot_rule.len == 0 or
            std.mem.startsWith(u8, bot_rule, "exclude."))
        {
            return error.InvalidTrafficClassification;
        },
        .excluded => if (classifier_version != 1 or
            !(std.mem.eql(u8, bot_rule, "exclude.tracker") or
                std.mem.eql(u8, bot_rule, "exclude.network") or
                std.mem.eql(u8, bot_rule, "exclude.both")))
        {
            return error.InvalidTrafficClassification;
        },
        .suspected => return error.InvalidTrafficClassification,
    }
}

fn validateSignals(
    signals: domain.ClientSignals,
    client_hint_consistency: domain.ClientHintConsistency,
) !void {
    _ = client_hint_consistency;
    if (signals.version > 1 or signals.trusted_interactions > 15 or
        signals.viewport_bucket > 4 or signals.beacon_timing_bucket > 4)
    {
        return error.InvalidBotSignals;
    }
    if (signals.version == 0 and (signals.navigator_webdriver or
        signals.trusted_interactions != 0 or signals.was_visible or
        signals.was_prerendered or signals.viewport_bucket != 0 or
        signals.beacon_timing_bucket != 0))
    {
        return error.InvalidBotSignals;
    }
}

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
        .traffic_class = result.int64(9, 0),
        .classifier_version = result.int64(10, 0),
        .bot_rule = try result.text(allocator, 11, 0),
        .signals = .{
            .version = @intCast(result.int64(12, 0)),
            .navigator_webdriver = result.int64(13, 0) != 0,
            .trusted_interactions = @intCast(result.int64(14, 0)),
            .was_visible = result.int64(15, 0) != 0,
            .was_prerendered = result.int64(16, 0) != 0,
            .viewport_bucket = @intCast(result.int64(17, 0)),
            .beacon_timing_bucket = @intCast(result.int64(18, 0)),
        },
        .client_hint_consistency = result.int64(19, 0),
        .accept_language_present = result.int64(20, 0) != 0,
    };
}

test "session detail template rebinds exact SQL and clears for migration" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/events.duckdb",
        .{temporary.sub_path},
    );
    defer allocator.free(path);
    var store = try Store.open(allocator, path);
    defer store.deinit();
    try store.migrate();

    const first = try store.sessionDetailStatement("SELECT ?::BIGINT");
    try first.bindInt64(1, 1);
    var first_result = try first.execute();
    try std.testing.expectEqual(@as(i64, 1), first_result.int64(0, 0));
    first_result.deinit();

    const rebound = try store.sessionDetailStatement("SELECT ?::BIGINT");
    try rebound.bindInt64(1, 2);
    var rebound_result = try rebound.execute();
    try std.testing.expectEqual(@as(i64, 2), rebound_result.int64(0, 0));
    rebound_result.deinit();

    const replaced = try store.sessionDetailStatement(
        "SELECT (?::BIGINT) + 1",
    );
    try replaced.bindInt64(1, 3);
    var replaced_result = try replaced.execute();
    try std.testing.expectEqual(@as(i64, 4), replaced_result.int64(0, 0));
    replaced_result.deinit();
    try std.testing.expectEqualStrings(
        "SELECT (?::BIGINT) + 1",
        store.session_detail_template.?.sql,
    );

    try store.migrate();
    try std.testing.expect(store.session_detail_template == null);
}

test "installation watermark orders higher ties and fails closed otherwise" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const backing_allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(
        backing_allocator,
        ".zig-cache/tmp/{s}/events.duckdb",
        .{temporary.sub_path},
    );
    defer backing_allocator.free(path);
    var store = try Store.open(backing_allocator, path);
    defer store.deinit();
    try store.migrate();

    const site = "00000000-0000-4000-8000-000000000020";
    const base = domain.Event{
        .event_id = "00000000-0000-4000-8000-000000000010",
        .site_id = site,
        .received_at_utc_micros = 100,
        .received_date_utc = "2026-08-24",
        .site_local_date = "2026-08-24",
        .site_utc_offset_minutes = 0,
        .kind = 1,
        .event_name = "page_view",
        .path = "/before",
        .visitor_day_id = @splat(1),
    };
    try store.insert(base);
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const watermark = try store.installationWatermark(allocator, site);
    try std.testing.expectEqual(@as(i64, 1), watermark.event_count);

    var tied = base;
    tied.event_id = "00000000-0000-4000-8000-000000000011";
    tied.path = "/tied";
    tied.visitor_day_id = @splat(2);
    try store.insert(tied);
    const tied_result = (try store.firstInstallationEventAfter(
        allocator,
        site,
        watermark,
    )).?;
    try std.testing.expectEqualStrings("/tied", tied_result.path);

    const tied_watermark = try store.installationWatermark(allocator, site);
    var lower_tied = base;
    lower_tied.event_id = "00000000-0000-4000-8000-00000000000f";
    lower_tied.path = "/lower-tied";
    lower_tied.visitor_day_id = @splat(3);
    try store.insert(lower_tied);
    try std.testing.expect(
        try store.firstInstallationEventAfter(
            allocator,
            site,
            tied_watermark,
        ) == null,
    );

    var clock_rollback = base;
    clock_rollback.event_id = "00000000-0000-4000-8000-000000000012";
    clock_rollback.received_at_utc_micros = 99;
    clock_rollback.path = "/clock-rollback";
    clock_rollback.visitor_day_id = @splat(4);
    try store.insert(clock_rollback);
    try std.testing.expect(
        try store.firstInstallationEventAfter(
            allocator,
            site,
            tied_watermark,
        ) == null,
    );

    var other_site = base;
    other_site.event_id = "00000000-0000-4000-8000-000000000014";
    other_site.site_id = "00000000-0000-4000-8000-000000000021";
    other_site.received_at_utc_micros = 102;
    other_site.path = "/other-site";
    other_site.visitor_day_id = @splat(5);
    try store.insert(other_site);

    var later = base;
    later.event_id = "00000000-0000-4000-8000-000000000013";
    later.received_at_utc_micros = 101;
    later.path = "/later";
    later.visitor_day_id = @splat(6);
    try store.insert(later);
    const later_result = (try store.firstInstallationEventAfter(
        allocator,
        site,
        tied_watermark,
    )).?;
    try std.testing.expectEqualStrings("/later", later_result.path);
}
