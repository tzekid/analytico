const std = @import("std");
const domain = @import("../domain.zig");
const events = @import("../store/events.zig");
const reports = @import("../store/reports.zig");

const day_one_micros: i64 = 1_735_689_600_000_000;
const day_two_micros: i64 = day_one_micros + 86_400_000_000;

pub fn seed(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    site_id: []const u8,
) !void {
    try domain.validateUuid(site_id);
    const event_path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, event_path);
    defer store.deinit();
    try store.migrate();
    try store.database.exec("DELETE FROM identity_links; DELETE FROM events");

    const visitor_a: [16]u8 = @splat(0x0a);
    const visitor_a_day_two: [16]u8 = @splat(0x1a);
    const visitor_b: [16]u8 = @splat(0x0b);
    const visitor_c: [16]u8 = @splat(0x0c);
    const visitor_bot: [16]u8 = @splat(0xff);
    const rows = [_]FixtureEvent{
        .{
            .id = "00000000-0000-4000-8000-000000000001",
            .at = day_one_micros,
            .date = "2025-01-01",
            .kind = 1,
            .name = "pageview",
            .path = "/",
            .visitor = visitor_a,
            .referrer = "search.example",
            .country = "US",
            .browser = "Chrome",
            .os = "Linux",
            .device = "desktop",
            .utm_source = "newsletter",
            .utm_medium = "email",
            .utm_campaign = "winter",
        },
        .{
            .id = "00000000-0000-4000-8000-000000000002",
            .at = day_one_micros + 1_800_000_000,
            .date = "2025-01-01",
            .kind = 1,
            .name = "pageview",
            .path = "/pricing",
            .visitor = visitor_a,
            .country = "US",
            .browser = "Chrome",
            .os = "Linux",
            .device = "desktop",
        },
        .{
            .id = "00000000-0000-4000-8000-000000000003",
            .at = day_one_micros + 1_800_000_000,
            .date = "2025-01-01",
            .kind = 2,
            .name = "signup",
            .path = "/welcome",
            .visitor = visitor_a,
            .country = "US",
            .browser = "Chrome",
            .os = "Linux",
            .device = "desktop",
        },
        .{
            .id = "00000000-0000-4000-8000-000000000004",
            .at = day_one_micros + 1_800_000_001,
            .date = "2025-01-01",
            .kind = 2,
            .name = "signup",
            .path = "/welcome",
            .visitor = visitor_a,
            .country = "US",
            .browser = "Chrome",
            .os = "Linux",
            .device = "desktop",
        },
        .{
            .id = "00000000-0000-4000-8000-000000000005",
            .at = day_one_micros + 3_600_000_002,
            .date = "2025-01-01",
            .kind = 1,
            .name = "pageview",
            .path = "/exit-a",
            .visitor = visitor_a,
            .country = "CA",
            .browser = "Firefox",
            .os = "Linux",
            .device = "desktop",
        },
        .{
            .id = "00000000-0000-4000-8000-000000000010",
            .at = day_one_micros + 60_000_000,
            .date = "2025-01-01",
            .kind = 1,
            .name = "pageview",
            .path = "/landing",
            .visitor = visitor_b,
            .country = "ZZ",
            .browser = "Unknown",
            .os = "Unknown",
            .device = "unknown",
            .utm_source = "=SUM(\"x\")\nnext",
        },
        .{
            .id = "00000000-0000-4000-8000-000000000011",
            .at = day_one_micros + 120_000_000,
            .date = "2025-01-01",
            .kind = 2,
            .name = "download",
            .path = "/landing",
            .visitor = visitor_b,
            .country = "ZZ",
            .browser = "Unknown",
            .os = "Unknown",
            .device = "unknown",
        },
        .{
            .id = "00000000-0000-4000-8000-000000000012",
            .at = day_one_micros + 180_000_000,
            .date = "2025-01-01",
            .kind = 1,
            .name = "pageview",
            .path = "/docs",
            .visitor = visitor_b,
            .country = "ZZ",
            .browser = "Unknown",
            .os = "Unknown",
            .device = "unknown",
        },
        .{
            .id = "00000000-0000-4000-8000-000000000020",
            .at = day_one_micros + 300_000_000,
            .date = "2025-01-01",
            .kind = 2,
            .name = "signup",
            .path = "/pre",
            .visitor = visitor_c,
            .country = "DE",
            .browser = "Safari",
            .os = "macOS",
            .device = "mobile",
        },
        .{
            .id = "00000000-0000-4000-8000-000000000021",
            .at = day_one_micros + 360_000_000,
            .date = "2025-01-01",
            .kind = 1,
            .name = "pageview",
            .path = "/pricing",
            .visitor = visitor_c,
            .referrer = "social.example",
            .country = "DE",
            .browser = "Safari",
            .os = "macOS",
            .device = "mobile",
            .utm_source = "social",
        },
        .{
            .id = "00000000-0000-4000-8000-000000000030",
            .at = day_two_micros,
            .date = "2025-01-02",
            .kind = 1,
            .name = "pageview",
            .path = "/",
            .visitor = visitor_a_day_two,
            .referrer = "search.example",
            .country = "US",
            .browser = "Chrome",
            .os = "Linux",
            .device = "desktop",
            .utm_source = "newsletter",
            .utm_medium = "email",
            .utm_campaign = "winter",
        },
        .{
            .id = "00000000-0000-4000-8000-000000000031",
            .at = day_two_micros + 60_000_000,
            .date = "2025-01-02",
            .kind = 1,
            .name = "pageview",
            .path = "/pricing",
            .visitor = visitor_a_day_two,
            .country = "US",
            .browser = "Chrome",
            .os = "Linux",
            .device = "desktop",
        },
        .{
            .id = "00000000-0000-4000-8000-000000000032",
            .at = day_two_micros + 120_000_000,
            .date = "2025-01-02",
            .kind = 2,
            .name = "signup",
            .path = "/welcome",
            .visitor = visitor_a_day_two,
            .country = "US",
            .browser = "Chrome",
            .os = "Linux",
            .device = "desktop",
        },
        .{
            .id = "00000000-0000-4000-8000-000000000040",
            .at = day_one_micros + 10_000_000,
            .date = "2025-01-01",
            .kind = 1,
            .name = "pageview",
            .path = "/bot",
            .visitor = visitor_bot,
            .country = "ZZ",
            .browser = "Other",
            .os = "Other",
            .device = "bot",
        },
    };
    for (rows) |row| try insertFixture(&store, site_id, row);
    try store.checkpoint();
    try output.print("M3 fixture committed events={d}\n", .{rows.len});
}

pub fn million(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    site_id: []const u8,
) !void {
    try domain.validateUuid(site_id);
    const event_path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, event_path);
    defer store.deinit();
    try store.migrate();
    try store.database.exec("DELETE FROM identity_links; DELETE FROM events");
    var statement = try store.database.prepare(
        \\INSERT INTO events (
        \\  event_schema_version, protocol_version, tracker_version,
        \\  event_id, site_id, received_at_utc_micros,
        \\  occurred_at_utc_micros, received_date_utc, site_local_date,
        \\  site_utc_offset_minutes, kind, event_name, path, page_title,
        \\  hostname, anonymous_id, identity_quality, user_id, session_id,
        \\  sequence, session_start, referrer_host, country_code, language,
        \\  browser_family, os_family, device_category, utm_source,
        \\  utm_medium, utm_campaign, utm_term, utm_content,
        \\  properties_json, user_traits_json, value_amount, value_currency,
        \\  engagement_ms, max_scroll_depth, visitor_day_id,
        \\  visitor_day_start, event_payload_digest, traffic_class,
        \\  classifier_version, bot_rule, signal_version,
        \\  navigator_webdriver, trusted_interactions, was_visible,
        \\  was_prerendered, viewport_bucket, beacon_timing_bucket,
        \\  client_hint_consistency, accept_language_present, network_day_id
        \\)
        \\WITH generated AS (
        \\  SELECT
        \\    i,
        \\    params.site_id,
        \\    CAST(
        \\      '00000000-0000-4000-8000-' || lpad(i::VARCHAR, 12, '0')
        \\      AS UUID
        \\    ) AS event_id,
        \\    1735689600000000 + i * 1000000 AS received_at,
        \\    DATE '2025-01-01' + ((i // 86400)::INTEGER) AS received_date,
        \\    CAST(lpad(((i // 10) % 5000)::VARCHAR, 16, '0') AS BLOB)
        \\      AS visitor_day_id,
        \\    CAST(lpad((i // 10)::VARCHAR, 32, '0') AS UUID) AS session_id,
        \\    CASE WHEN i % 10 >= 8 THEN 2 ELSE 1 END AS kind,
        \\    CASE
        \\      WHEN i % 10 = 8 THEN 'signup'
        \\      WHEN i % 10 = 9 THEN 'purchase'
        \\      ELSE 'pageview'
        \\    END AS event_name,
        \\    CASE
        \\      WHEN i % 10 = 0 THEN '/'
        \\      WHEN i % 10 = 1 THEN '/pricing'
        \\      WHEN i % 10 = 2 THEN '/docs'
        \\      WHEN i % 10 = 3 THEN '/features'
        \\      WHEN i % 10 = 4 THEN '/download'
        \\      WHEN i % 10 = 5 THEN '/install'
        \\      WHEN i % 10 = 6 THEN '/account'
        \\      WHEN i % 10 = 7 THEN '/checkout'
        \\      WHEN i % 10 = 8 THEN '/welcome'
        \\      ELSE '/receipt'
        \\    END AS path
        \\  FROM range(1000000) source(i)
        \\  CROSS JOIN (SELECT ?::VARCHAR AS site_id) params
        \\), sequenced AS (
        \\  SELECT *,
        \\    md5(
        \\      'analytico/legacy-daily/v1|' || site_id || '|' ||
        \\      CAST(received_date AS VARCHAR) || '|' || hex(visitor_day_id)
        \\    ) AS identity_hash,
        \\    row_number() OVER (
        \\      PARTITION BY received_date, visitor_day_id ORDER BY i
        \\    ) = 1 AS visitor_day_start
        \\  FROM generated
        \\)
        \\SELECT
        \\  7, 1, 1, event_id, site_id,
        \\  received_at, received_at, received_date, received_date, 0,
        \\  kind, event_name, path, '', '', CAST(
        \\    substr(identity_hash, 1, 8) || '-' ||
        \\    substr(identity_hash, 9, 4) || '-5' ||
        \\    substr(identity_hash, 14, 3) || '-a' ||
        \\    substr(identity_hash, 18, 3) || '-' ||
        \\    substr(identity_hash, 21, 12) AS UUID
        \\  ),
        \\  3, '', session_id, CAST(i % 10 AS UINTEGER), i % 10 = 0,
        \\  '', 'US', '', 'Chrome', 'Linux', 'desktop',
        \\  '', '', '', '', '', '{}', '{}', CAST(NULL AS DECIMAL(18,6)), '',
        \\  0, 0, visitor_day_id, visitor_day_start, '', 1, 0, '',
        \\  0, FALSE, 0, FALSE, FALSE, 0, 0, 0, FALSE,
        \\  from_hex('00000000000000000000000000000000')
        \\FROM sequenced
    );
    defer statement.deinit();
    try statement.bindText(1, site_id);
    var result = try statement.execute();
    result.deinit();
    try store.checkpoint();
    try output.writeAll("M3 million-event fixture committed events=1000000\n");
}

pub fn timeout(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
) !void {
    const event_path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, event_path);
    defer store.deinit();
    try store.migrate();
    try reports.timeoutProbe(&store);
    try output.writeAll("report timeout interrupted and connection reused\n");
}

pub fn legacyCreate(
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
        \\INSERT INTO events VALUES
        \\  (1, '00000000-0000-4000-8000-000000000101',
        \\   '00000000-0000-4000-8000-000000000001',
        \\   1735689600000000, DATE '2025-01-01', 1, 'pageview', '/',
        \\   CAST('legacy-visitor-1' AS BLOB),
        \\   '', 'US', 'Chrome', 'Linux', 'desktop', '', '', '', '', '', '{}'),
        \\  (1, '00000000-0000-4000-8000-000000000102',
        \\   '00000000-0000-4000-8000-000000000001',
        \\   1735691400000000, DATE '2025-01-01', 1, 'pageview', '/boundary',
        \\   CAST('legacy-visitor-1' AS BLOB),
        \\   '', 'US', 'Chrome', 'Linux', 'desktop', '', '', '', '', '', '{}'),
        \\  (1, '00000000-0000-4000-8000-000000000103',
        \\   '00000000-0000-4000-8000-000000000001',
        \\   1735693200000001, DATE '2025-01-01', 2, 'signup', '/done',
        \\   CAST('legacy-visitor-1' AS BLOB),
        \\   '', 'US', 'Chrome', 'Linux', 'desktop', '', '', '', '', '', '{}');
        \\CHECKPOINT
    );
    try output.writeAll("legacy event schema v1 fixture committed\n");
}

pub fn legacyVerify(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
) !void {
    const event_path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, event_path);
    defer store.deinit();
    try store.migrate();
    if (try store.migrationVersion() != 7) return error.LegacyMigrationVersion;
    var result = try store.database.query(
        \\SELECT count(*), count(DISTINCT session_id),
        \\       count(*) FILTER (WHERE visitor_day_start),
        \\       count(*) FILTER (WHERE session_start),
        \\       count(*) FILTER (
        \\         WHERE event_schema_version = 7
        \\           AND protocol_version = 1 AND tracker_version = 1
        \\           AND identity_quality = 3
        \\           AND occurred_at_utc_micros = received_at_utc_micros
        \\           AND site_local_date = received_date_utc
        \\           AND site_utc_offset_minutes = 0
        \\           AND user_id = '' AND page_title = '' AND hostname = ''
        \\           AND language = '' AND user_traits_json = '{}'
        \\           AND value_amount IS NULL AND value_currency = ''
        \\           AND engagement_ms = 0 AND max_scroll_depth = 0
        \\           AND traffic_class = 1 AND classifier_version = 0
        \\           AND bot_rule = '' AND signal_version = 0
        \\           AND NOT navigator_webdriver AND trusted_interactions = 0
        \\           AND NOT was_visible AND NOT was_prerendered
        \\           AND viewport_bucket = 0 AND beacon_timing_bucket = 0
        \\           AND client_hint_consistency = 0
        \\           AND NOT accept_language_present
        \\           AND network_day_id =
        \\             from_hex('00000000000000000000000000000000')
        \\       ),
        \\       count(DISTINCT anonymous_id), sum(sequence)
        \\FROM events
    );
    defer result.deinit();
    if (result.rowCount() != 1 or result.columnCount() != 7 or
        result.int64(0, 0) != 3 or result.int64(1, 0) != 2 or
        result.int64(2, 0) != 1 or result.int64(3, 0) != 2 or
        result.int64(4, 0) != 3 or result.int64(5, 0) != 1 or
        result.int64(6, 0) != 1)
    {
        return error.LegacyMigrationSemantics;
    }
    var links = try store.database.query("SELECT count(*) FROM identity_links");
    defer links.deinit();
    if (links.rowCount() != 1 or links.columnCount() != 1 or
        links.int64(0, 0) != 0)
    {
        return error.LegacyIdentityLink;
    }
    try output.writeAll("legacy event schema v1 migrated to v7\n");
}

pub fn legacyEvidence(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
) !void {
    const event_path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, event_path);
    defer store.deinit();
    try std.json.Stringify.value(
        try store.legacyMigrationEvidence(allocator),
        .{},
        output,
    );
    try output.writeByte('\n');
}

pub fn identityCoverage(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    site_id: []const u8,
    start_local_date: []const u8,
    end_local_date: []const u8,
) !void {
    const event_path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, event_path);
    defer store.deinit();
    try store.requireCurrent();
    try std.json.Stringify.value(
        try reports.identityCoverage(
            allocator,
            &store,
            site_id,
            start_local_date,
            end_local_date,
            .{},
            2_000,
        ),
        .{},
        output,
    );
    try output.writeByte('\n');
}

const FixtureEvent = struct {
    id: []const u8,
    at: i64,
    date: []const u8,
    kind: u8,
    name: []const u8,
    path: []const u8,
    visitor: [16]u8,
    referrer: []const u8 = "",
    country: []const u8,
    browser: []const u8,
    os: []const u8,
    device: []const u8,
    utm_source: []const u8 = "",
    utm_medium: []const u8 = "",
    utm_campaign: []const u8 = "",
};

fn insertFixture(
    store: *events.Store,
    site_id: []const u8,
    row: FixtureEvent,
) !void {
    const is_bot = std.mem.eql(u8, row.device, "bot");
    try store.insert(.{
        .event_id = row.id,
        .site_id = site_id,
        .received_at_utc_micros = row.at,
        .received_date_utc = row.date,
        .site_local_date = row.date,
        .site_utc_offset_minutes = 0,
        .kind = row.kind,
        .event_name = row.name,
        .path = row.path,
        .visitor_day_id = row.visitor,
        .referrer_host = row.referrer,
        .country_code = row.country,
        .browser_family = row.browser,
        .os_family = row.os,
        .device_category = if (is_bot) "unknown" else row.device,
        .utm_source = row.utm_source,
        .utm_medium = row.utm_medium,
        .utm_campaign = row.utm_campaign,
        .traffic_class = if (is_bot) .declared_bot else .human_presumed,
        .bot_rule = if (is_bot) "generic.bot" else "",
    });
}
