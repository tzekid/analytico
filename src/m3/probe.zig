const std = @import("std");
const builtin = @import("builtin");
const analysis = @import("../analysis.zig");
const domain = @import("../domain.zig");
const funnel = @import("../funnel.zig");
const report = @import("../report.zig");
const timezone = @import("../timezone.zig");
const events = @import("../store/events.zig");
const meta = @import("../store/meta.zig");
const reports = @import("../store/reports.zig");
const analysis_store = @import("../store/analysis.zig");

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

pub fn goalPredicatesFixture(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    site_id: []const u8,
) !void {
    try domain.validateUuid(site_id);
    const event_path = try std.fs.path.join(
        allocator,
        &.{ directory, "events.duckdb" },
    );
    var store = try events.Store.open(allocator, event_path);
    defer store.deinit();
    try store.requireCurrent();
    const sql_template =
        \\INSERT INTO events
        \\SELECT template.* REPLACE (
        \\  7 AS event_schema_version, 2 AS protocol_version,
        \\  2 AS tracker_version, CAST(v.event_id AS UUID) AS event_id,
        \\  v.received_at AS received_at_utc_micros,
        \\  v.received_at AS occurred_at_utc_micros,
        \\  CAST('2025-01-01' AS DATE) AS received_date_utc,
        \\  CAST('2025-01-01' AS DATE) AS site_local_date,
        \\  0 AS site_utc_offset_minutes, v.kind AS kind,
        \\  v.event_name AS event_name, v.path AS path,
        \\  'Goal fixture' AS page_title, 'alpha.example' AS hostname,
        \\  CAST(v.anonymous_id AS UUID) AS anonymous_id,
        \\  1 AS identity_quality, '' AS user_id,
        \\  CAST(v.session_id AS UUID) AS session_id, v.sequence AS sequence,
        \\  v.sequence = 0 AS session_start, '' AS referrer_host,
        \\  'DE' AS country_code, 'en' AS language,
        \\  'Chrome' AS browser_family, 'Linux' AS os_family,
        \\  'desktop' AS device_category, '' AS utm_source,
        \\  '' AS utm_medium, '' AS utm_campaign,
        \\  '' AS utm_term, '' AS utm_content,
        \\  v.properties AS properties_json, '{}' AS user_traits_json,
        \\  CASE WHEN v.amount = '' THEN CAST(NULL AS DECIMAL(18, 6))
        \\       ELSE CAST(v.amount AS DECIMAL(18, 6)) END AS value_amount,
        \\  v.currency AS value_currency, 0 AS engagement_ms,
        \\  0 AS max_scroll_depth,
        \\  from_hex(md5(v.anonymous_id)) AS visitor_day_id,
        \\  v.sequence = 0 AS visitor_day_start,
        \\  repeat('9', 64) AS event_payload_digest,
        \\  1 AS traffic_class, 2 AS classifier_version, '' AS bot_rule,
        \\  0 AS signal_version, FALSE AS navigator_webdriver,
        \\  0 AS trusted_interactions, FALSE AS was_visible,
        \\  FALSE AS was_prerendered, 0 AS viewport_bucket,
        \\  0 AS beacon_timing_bucket, 0 AS client_hint_consistency,
        \\  FALSE AS accept_language_present,
        \\  from_hex('99999999999999999999999999999999') AS network_day_id
        \\) FROM events template CROSS JOIN (VALUES
        \\ ('00000000-0000-4000-8000-000000000501',1735689600000000,1,'pageview','/pricing','00000000-0000-4000-8000-0000000005a1','00000000-0000-4000-8000-0000000005b1',0,'{"plan":"pro","page_only":"yes"}','',''),
        \\ ('00000000-0000-4000-8000-000000000502',1735689601000000,2,'purchase','/pricing','00000000-0000-4000-8000-0000000005a1','00000000-0000-4000-8000-0000000005b1',1,'{"plan":"pro","amount":14.25}','12.500000','EUR'),
        \\ ('00000000-0000-4000-8000-000000000503',1735689602000000,2,'purchase','/pricing','00000000-0000-4000-8000-0000000005a1','00000000-0000-4000-8000-0000000005b1',2,'{"plan":"pro","amount":"7.5"}','7.500000','USD'),
        \\ ('00000000-0000-4000-8000-000000000504',1735689603000000,1,'pageview','/welcome','00000000-0000-4000-8000-0000000005a2','00000000-0000-4000-8000-0000000005b2',0,'{"page_only":"yes"}','',''),
        \\ ('00000000-0000-4000-8000-000000000505',1735689604000000,2,'signup','/welcome','00000000-0000-4000-8000-0000000005a2','00000000-0000-4000-8000-0000000005b2',1,'{"plan":"free"}','','')
        \\) v(event_id,received_at,kind,event_name,path,anonymous_id,session_id,
        \\    sequence,properties,amount,currency)
        \\WHERE template.site_id = '__SITE__'
        \\  AND template.event_id = CAST(
        \\    '00000000-0000-4000-8000-000000000001' AS UUID)
    ;
    const rendered_sql = try std.mem.replaceOwned(
        u8,
        allocator,
        sql_template,
        "__SITE__",
        site_id,
    );
    defer allocator.free(rendered_sql);
    const sql = try allocator.dupeSentinel(u8, rendered_sql, 0);
    defer allocator.free(sql);
    try store.database.exec(sql);
    try store.checkpoint();
    try output.writeAll("goal predicate fixture committed events=5\n");
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
        \\    CASE WHEN i >= 999000 AND i % 10 = 9
        \\      THEN CAST(lpad(i::VARCHAR, 32, '0') AS UUID)
        \\      ELSE CAST(lpad((i // 10)::VARCHAR, 32, '0') AS UUID)
        \\    END AS session_id,
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
        \\  CASE WHEN i >= 999000 AND i % 10 = 9 THEN 1 ELSE 0 END,
        \\  FALSE, 0, FALSE, FALSE,
        \\  CASE WHEN i >= 999000 AND i % 10 = 9 THEN 1 ELSE 0 END,
        \\  CASE WHEN i >= 999000 AND i % 10 = 9 THEN 1 ELSE 0 END,
        \\  0, FALSE,
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

pub fn liveScaleFixture(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    site_id: []const u8,
    now_text: []const u8,
) !void {
    try domain.validateUuid(site_id);
    const now_utc_micros = std.fmt.parseInt(i64, now_text, 10) catch
        return error.InvalidLiveClock;
    if (now_utc_micros < analysis.live_window_micros) {
        return error.InvalidLiveClock;
    }
    const event_path = try std.fs.path.join(
        allocator,
        &.{ directory, "events.duckdb" },
    );
    var store = try events.Store.open(allocator, event_path);
    defer store.deinit();
    try store.requireCurrent();
    if (try store.eventCount() != 1_000_000) {
        return error.InvalidLiveScaleFixture;
    }
    const original_max_utc_micros: i64 = 1_736_689_599_000_000;
    const delta = std.math.sub(
        i64,
        now_utc_micros,
        original_max_utc_micros,
    ) catch return error.InvalidLiveClock;
    const sql = try std.fmt.allocPrintSentinel(
        allocator,
        "UPDATE events SET " ++
            "received_date_utc = CAST(to_timestamp((received_at_utc_micros + {d}) / 1000000.0) AS DATE), " ++
            "site_local_date = CAST(to_timestamp((received_at_utc_micros + {d}) / 1000000.0) AS DATE), " ++
            "received_at_utc_micros = received_at_utc_micros + {d}, " ++
            "occurred_at_utc_micros = occurred_at_utc_micros + {d} " ++
            "WHERE site_id = '{s}'",
        .{ delta, delta, delta, delta, site_id },
        0,
    );
    defer allocator.free(sql);
    try store.database.exec(sql);
    var check = try store.database.query(
        "SELECT count(*), min(received_at_utc_micros), " ++
            "max(received_at_utc_micros) FROM events",
    );
    defer check.deinit();
    if (check.rowCount() != 1 or check.int64(0, 0) != 1_000_000 or
        check.int64(2, 0) != now_utc_micros or
        check.int64(1, 0) != now_utc_micros - 999_999 * std.time.us_per_s)
    {
        return error.InvalidLiveScaleFixture;
    }
    try store.checkpoint();
    try output.print(
        "Live scale fixture retained events=1000000 latest_receipt={d}\n",
        .{now_utc_micros},
    );
}

pub fn sessionsFixture(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    site_id: []const u8,
) !void {
    try domain.validateUuid(site_id);
    const event_path = try std.fs.path.join(
        allocator,
        &.{ directory, "events.duckdb" },
    );
    var store = try events.Store.open(allocator, event_path);
    defer store.deinit();
    try store.requireCurrent();
    const template =
        \\INSERT INTO events SELECT template.* REPLACE (
        \\  CAST('00000000-0000-4000-8000-000000000201' AS UUID) AS event_id,
        \\  '__SITE__' AS site_id,
        \\  1767398410000000 AS received_at_utc_micros,
        \\  1767398410000000 AS occurred_at_utc_micros,
        \\  DATE '2026-01-03' AS received_date_utc,
        \\  DATE '2026-01-03' AS site_local_date,
        \\  2 AS kind, 'custom-only' AS event_name,
        \\  '/custom-only' AS path, 'Custom only' AS page_title,
        \\  CAST('00000000-0000-4000-8000-0000000000a6' AS UUID) AS anonymous_id,
        \\  1 AS identity_quality, '' AS user_id,
        \\  CAST('00000000-0000-4000-8000-0000000000b6' AS UUID) AS session_id,
        \\  0 AS sequence, TRUE AS session_start, 'tablet' AS device_category,
        \\  CAST('00000000-0000-4000-8000-000000000201' AS BLOB) AS visitor_day_id,
        \\  TRUE AS visitor_day_start, repeat('c', 64) AS event_payload_digest
        \\) FROM events template
        \\WHERE template.site_id = '__SITE__'
        \\  AND template.event_id = CAST('00000000-0000-4000-8000-000000000107' AS UUID);
        \\INSERT INTO events SELECT template.* REPLACE (
        \\  CAST('41000000-0000-4000-8000-' || lpad(i::VARCHAR, 12, '0') AS UUID) AS event_id,
        \\  '__SITE__' AS site_id,
        \\  1767484800000000 + (i // 2) * 1000000 AS received_at_utc_micros,
        \\  1767484800000000 + (i // 2) * 1000000 AS occurred_at_utc_micros,
        \\  DATE '2026-01-04' AS received_date_utc,
        \\  DATE '2026-01-04' AS site_local_date,
        \\  CAST('43000000-0000-4000-8000-' || lpad(i::VARCHAR, 12, '0') AS UUID) AS anonymous_id,
        \\  CAST('42000000-0000-4000-8000-' || lpad(i::VARCHAR, 12, '0') AS UUID) AS session_id,
        \\  0 AS sequence, TRUE AS session_start,
        \\  CAST('41000000-0000-4000-8000-' || lpad(i::VARCHAR, 12, '0') AS BLOB) AS visitor_day_id,
        \\  TRUE AS visitor_day_start, repeat('e', 64) AS event_payload_digest
        \\) FROM events template, range(27) source(i)
        \\WHERE template.site_id = '__SITE__'
        \\  AND template.event_id = CAST('00000000-0000-4000-8000-000000000107' AS UUID);
        \\INSERT INTO events SELECT template.* REPLACE (
        \\  CAST('44000000-0000-4000-8000-' || lpad(i::VARCHAR, 12, '0') AS UUID) AS event_id,
        \\  '__SITE__' AS site_id,
        \\  1767484800000000 + i * 1000 AS received_at_utc_micros,
        \\  1767484800000000 + i * 1000 AS occurred_at_utc_micros,
        \\  DATE '2026-01-04' AS received_date_utc,
        \\  DATE '2026-01-04' AS site_local_date,
        \\  2 AS kind, 'timeline-' || lpad(i::VARCHAR, 2, '0') AS event_name,
        \\  '/timeline-heavy' AS path, 'Timeline heavy' AS page_title,
        \\  CAST('43000000-0000-4000-8000-000000000000' AS UUID) AS anonymous_id,
        \\  1 AS identity_quality, '' AS user_id,
        \\  CAST('42000000-0000-4000-8000-000000000000' AS UUID) AS session_id,
        \\  i AS sequence, FALSE AS session_start,
        \\  from_hex(md5('timeline-' || CAST(i AS VARCHAR))) AS visitor_day_id,
        \\  FALSE AS visitor_day_start, repeat('f', 64) AS event_payload_digest
        \\) FROM events template, range(1, 52) source(i)
        \\WHERE template.site_id = '__SITE__'
        \\  AND template.event_id = CAST('00000000-0000-4000-8000-000000000107' AS UUID);
    ;
    const rendered = try std.mem.replaceOwned(
        u8,
        allocator,
        template,
        "__SITE__",
        site_id,
    );
    defer allocator.free(rendered);
    const sql = try allocator.dupeSentinel(u8, rendered, 0);
    defer allocator.free(sql);
    try store.database.exec(sql);
    try store.checkpoint();
    try output.writeAll("Sessions fixture committed custom=1 paginated=27\n");
}

pub fn sessionsScaleFixture(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    site_id: []const u8,
) !void {
    try domain.validateUuid(site_id);
    const event_path = try std.fs.path.join(
        allocator,
        &.{ directory, "events.duckdb" },
    );
    var store = try events.Store.open(allocator, event_path);
    defer store.deinit();
    try store.requireCurrent();
    if (try store.eventCount() != 1_000_000) {
        return error.InvalidSessionsScaleFixture;
    }
    const template =
        \\UPDATE events SET
        \\  anonymous_id = CAST(v.anonymous_id AS UUID),
        \\  identity_quality = 1, user_id = v.user_id,
        \\  session_id = CAST(v.session_id AS UUID), sequence = v.sequence,
        \\  session_start = v.sequence = 0, kind = v.kind,
        \\  event_name = v.event_name, path = v.path,
        \\  page_title = v.page_title, properties_json = v.properties,
        \\  user_traits_json = v.traits,
        \\  traffic_class = 1, classifier_version = 2, bot_rule = ''
        \\FROM (VALUES
        \\  ('00000000-0000-4000-8000-000000999990','00000000-0000-4000-8000-00000000fa01','00000000-0000-4000-8000-00000000fb01',0,1,'pageview','/scale-profile','Scale profile','{}','{}',''),
        \\  ('00000000-0000-4000-8000-000000999991','00000000-0000-4000-8000-00000000fa01','00000000-0000-4000-8000-00000000fb01',1,2,'purchase','/scale-profile','Scale profile','{"plan":"scale"}','{}',''),
        \\  ('00000000-0000-4000-8000-000000999992','00000000-0000-4000-8000-00000000fa02','00000000-0000-4000-8000-00000000fb02',0,1,'pageview','/scale-second','Scale second','{}','{}',''),
        \\  ('00000000-0000-4000-8000-000000999993','00000000-0000-4000-8000-00000000fa02','00000000-0000-4000-8000-00000000fb02',1,4,'identify','/account','Account','{}','{"plan":"scale"}','scale-user'),
        \\  ('00000000-0000-4000-8000-000000999994','00000000-0000-4000-8000-00000000fa03','00000000-0000-4000-8000-00000000fb03',0,1,'pageview','/scale-anonymous','Scale anonymous','{}','{}','')
        \\) v(event_id,anonymous_id,session_id,sequence,kind,event_name,path,
        \\    page_title,properties,traits,user_id)
        \\WHERE events.site_id = '__SITE__'
        \\  AND events.event_id = CAST(v.event_id AS UUID);
        \\INSERT INTO identity_links VALUES
        \\  ('__SITE__', CAST('00000000-0000-4000-8000-00000000fa01' AS UUID),
        \\   'scale-user', 1736689593000000,
        \\   CAST('00000000-0000-4000-8000-000000999993' AS UUID)),
        \\  ('__SITE__', CAST('00000000-0000-4000-8000-00000000fa02' AS UUID),
        \\   'scale-user', 1736689593000000,
        \\   CAST('00000000-0000-4000-8000-000000999993' AS UUID));
    ;
    const rendered = try std.mem.replaceOwned(
        u8,
        allocator,
        template,
        "__SITE__",
        site_id,
    );
    defer allocator.free(rendered);
    const sql = try allocator.dupeSentinel(u8, rendered, 0);
    defer allocator.free(sql);
    try store.database.exec(sql);
    if (try store.eventCount() != 1_000_000) {
        return error.InvalidSessionsScaleFixture;
    }
    try store.checkpoint();
    try output.writeAll(
        "Sessions scale fixture retained events=1000000 identified_profiles=1 anonymous_profiles=1\n",
    );
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

pub fn goalDiscovery(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    site_slug: []const u8,
    start_date: []const u8,
    end_date: []const u8,
) !void {
    try domain.validateSlug(site_slug);
    const range = analysis.LocalDateRange{
        .start = start_date,
        .end = end_date,
    };
    try range.validate();
    const metadata_path = try std.fs.path.join(
        allocator,
        &.{ directory, "meta.db" },
    );
    var metadata = try meta.Store.open(allocator, metadata_path);
    defer metadata.deinit();
    try metadata.requireCurrent();
    const site_id = try metadata.siteIdBySlug(allocator, site_slug);
    const policy = try metadata.sitePolicy(allocator, site_id);
    const goals = try metadata.listGoals(allocator, site_slug);
    const resolved = try allocator.alloc(analysis.ResolvedGoal, goals.len);
    for (resolved, goals) |*target, goal| target.* = .{
        .id = goal.id,
        .selector = .{
            .kind = switch (goal.match_kind) {
                .event => .exact_event,
                .path => .exact_page,
                .prefix => .page_prefix,
            },
            .value = goal.match_value,
            .predicates = goal.predicates,
        },
    };
    const event_path = try std.fs.path.join(
        allocator,
        &.{ directory, "events.duckdb" },
    );
    var store = try events.Store.open(allocator, event_path);
    defer store.deinit();
    try store.requireCurrent();
    const request = analysis.GoalDiscoveryRequest{
        .site_id = site_id,
        .range = range,
        .kind = .page,
        .active_goals = resolved,
        .strict_traffic_mode = policy.strict_mode,
        .timeout_ms = analysis.maximum_timeout_ms,
    };
    const pages = try analysis_store.executeGoalDiscovery(
        allocator,
        &store,
        request,
    );
    if (pages.entities.len == 0 or pages.entities.len > 50) {
        return error.InvalidGoalDiscoveryProbe;
    }
    for (pages.entities[1..], pages.entities[0 .. pages.entities.len - 1]) |
        current,
        prior,
    | {
        if (current.eligible_count > prior.eligible_count or
            (current.eligible_count == prior.eligible_count and
                std.mem.order(u8, current.label, prior.label) == .lt))
        {
            return error.InvalidGoalDiscoveryOrder;
        }
    }
    var event_request = request;
    event_request.kind = .event;
    const custom_events = try analysis_store.executeGoalDiscovery(
        allocator,
        &store,
        event_request,
    );
    var signup_count: ?i64 = null;
    var purchase_count: ?i64 = null;
    for (custom_events.entities) |entity| {
        if (std.mem.eql(u8, entity.label, "signup")) {
            signup_count = entity.eligible_count;
        } else if (std.mem.eql(u8, entity.label, "purchase")) {
            purchase_count = entity.eligible_count;
        }
    }
    var purchase_goal_base_evidence = false;
    for (goals) |goal| {
        if (goal.match_kind == .event and
            std.mem.eql(u8, goal.match_value, "purchase"))
        {
            purchase_goal_base_evidence = true;
        }
    }
    if (policy.strict_mode) {
        if (custom_events.entities.len != 2 or
            signup_count != 100_000 or
            purchase_count != if (purchase_goal_base_evidence)
                @as(i64, 100_000)
            else
                99_900)
        {
            return error.InvalidGoalDiscoveryKinds;
        }
    } else if (custom_events.entities.len != 2 or
        !std.mem.eql(u8, custom_events.entities[0].label, "purchase") or
        !std.mem.eql(u8, custom_events.entities[1].label, "signup"))
    {
        return error.InvalidGoalDiscoveryKinds;
    }
    if (!try analysis_store.goalSelectorObserved(
        allocator,
        &store,
        request,
        .{ .kind = .page_prefix, .value = "/pri" },
    ) or try analysis_store.goalSelectorObserved(
        allocator,
        &store,
        request,
        .{ .kind = .exact_page, .value = "/not-observed" },
    )) {
        return error.InvalidGoalDiscoveryPresence;
    }
    var timeout_request = request;
    timeout_request.timeout_ms = 1;
    if (analysis_store.executeGoalDiscovery(
        allocator,
        &store,
        timeout_request,
    )) |_| {
        return error.ExpectedGoalDiscoveryTimeout;
    } else |err| if (err != error.AnalysisTimeout) return err;

    var reuse_request = request;
    reuse_request.search = "/pricing";
    const reused = try analysis_store.executeGoalDiscovery(
        allocator,
        &store,
        reuse_request,
    );
    if (reused.entities.len != 1 or
        !std.mem.eql(u8, reused.entities[0].label, "/pricing"))
    {
        return error.InvalidGoalDiscoveryReuse;
    }
    try std.json.Stringify.value(.{
        .strict_mode = policy.strict_mode,
        .page_entities = pages.entities.len,
        .custom_event_entities = custom_events.entities.len,
        .strict_signup_count = signup_count.?,
        .strict_purchase_count = purchase_count.?,
        .purchase_goal_base_evidence = purchase_goal_base_evidence,
        .timeout_interrupted = true,
        .connection_reused = true,
        .search_value = reused.entities[0].label,
        .search_count = reused.entities[0].eligible_count,
    }, .{}, output);
    try output.writeByte('\n');
}

pub fn goalPredicatesProfile(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
    site_slug: []const u8,
    start_date: []const u8,
    end_date: []const u8,
    explain: bool,
) !void {
    try domain.validateSlug(site_slug);
    const range = analysis.LocalDateRange{
        .start = start_date,
        .end = end_date,
    };
    try range.validate();
    const metadata_path = try std.fs.path.join(
        allocator,
        &.{ directory, "meta.db" },
    );
    var metadata = try meta.Store.open(allocator, metadata_path);
    defer metadata.deinit();
    try metadata.requireCurrent();
    const site_id = try metadata.siteIdBySlug(allocator, site_slug);
    const policy = try metadata.sitePolicy(allocator, site_id);
    const goals = try metadata.listGoals(allocator, site_slug);
    const resolved = try allocator.alloc(analysis.ResolvedGoal, goals.len);
    for (resolved, goals) |*target, goal| target.* = .{
        .id = goal.id,
        .selector = .{
            .kind = switch (goal.match_kind) {
                .event => .exact_event,
                .path => .exact_page,
                .prefix => .page_prefix,
            },
            .value = goal.match_value,
            .predicates = goal.predicates,
        },
    };
    const event_path = try std.fs.path.join(
        allocator,
        &.{ directory, "events.duckdb" },
    );
    var store = try events.Store.open(allocator, event_path);
    defer store.deinit();
    try store.requireCurrent();
    const predicates = [_]analysis.PropertyPredicate{.{
        .property_ref = .{ .name = "plan", .scalar_type = .missing },
        .operator = .is,
    }};
    const request = analysis.GoalResultRequest{
        .site_id = site_id,
        .range = range,
        .selector = .{
            .kind = .exact_event,
            .value = "purchase",
            .predicates = &predicates,
        },
        .active_goals = resolved,
        .strict_traffic_mode = policy.strict_mode,
        .timeout_ms = analysis.maximum_timeout_ms,
    };
    if (explain) {
        try output.writeAll(try analysis_store.profileGoalResult(
            allocator,
            &store,
            request,
        ));
        return;
    }
    if (builtin.mode == .debug) {
        try std.json.Stringify.value(.{
            .strict_mode = policy.strict_mode,
            .selector = "purchase where plan is missing",
            .performance_enforced = false,
            .total_matches = @as(?i64, null),
            .path_cardinality = @as(?i64, null),
            .sample_micros = &[_]i64{},
            .p50_micros = @as(?i64, null),
            .p95_micros = @as(?i64, null),
            .preview_micros = @as(?i64, null),
            .preview_property_count = @as(?i64, null),
            .preview_timeout_interrupted = false,
            .connection_reused = false,
        }, .{}, output);
        try output.writeByte('\n');
        return;
    }
    var timeout_request = request;
    timeout_request.timeout_ms = 1;
    if (analysis_store.executeGoalPreview(
        allocator,
        &store,
        timeout_request,
    )) |_| {
        return error.ExpectedGoalPreviewTimeout;
    } else |err| if (err != error.AnalysisTimeout) return err;
    _ = try analysis_store.executeGoalResult(allocator, &store, request);
    var samples: [10]i64 = undefined;
    var last: analysis.GoalResult = undefined;
    for (&samples) |*elapsed| {
        const started = std.Io.Clock.awake.now(io).nanoseconds;
        last = try analysis_store.executeGoalResult(allocator, &store, request);
        elapsed.* = @intCast(@divTrunc(
            std.Io.Clock.awake.now(io).nanoseconds - started,
            std.time.ns_per_us,
        ));
    }
    std.mem.sort(i64, &samples, {}, std.sort.asc(i64));
    const preview_started = std.Io.Clock.awake.now(io).nanoseconds;
    const preview = try analysis_store.executeGoalPreview(
        allocator,
        &store,
        request,
    );
    const preview_micros: i64 = @intCast(@divTrunc(
        std.Io.Clock.awake.now(io).nanoseconds - preview_started,
        std.time.ns_per_us,
    ));
    try std.json.Stringify.value(.{
        .strict_mode = policy.strict_mode,
        .selector = "purchase where plan is missing",
        .performance_enforced = true,
        .total_matches = last.total_matches,
        .path_cardinality = last.path_cardinality,
        .sample_micros = samples,
        .p50_micros = samples[4],
        .p95_micros = samples[9],
        .preview_micros = preview_micros,
        .preview_property_count = preview.properties.property_count,
        .preview_timeout_interrupted = true,
        .connection_reused = true,
    }, .{}, output);
    try output.writeByte('\n');
}

pub fn funnelAvailabilityProfile(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
    site_slug: []const u8,
    start_date: []const u8,
    end_date: []const u8,
    explain: bool,
) !void {
    try domain.validateSlug(site_slug);
    const range = analysis.LocalDateRange{
        .start = start_date,
        .end = end_date,
    };
    try range.validate();
    const metadata_path = try std.fs.path.join(
        allocator,
        &.{ directory, "meta.db" },
    );
    var metadata = try meta.Store.open(allocator, metadata_path);
    defer metadata.deinit();
    try metadata.requireCurrent();
    const site_id = try metadata.siteIdBySlug(allocator, site_slug);
    const policy = try metadata.sitePolicy(allocator, site_id);
    const goals = try metadata.listGoals(allocator, site_slug);
    const resolved = try allocator.alloc(analysis.ResolvedGoal, goals.len);
    for (resolved, goals) |*target, goal| target.* = .{
        .id = goal.id,
        .selector = .{
            .kind = switch (goal.match_kind) {
                .event => .exact_event,
                .path => .exact_page,
                .prefix => .page_prefix,
            },
            .value = goal.match_value,
            .predicates = goal.predicates,
        },
    };
    const event_path = try std.fs.path.join(
        allocator,
        &.{ directory, "events.duckdb" },
    );
    var store = try events.Store.open(allocator, event_path);
    defer store.deinit();
    try store.requireCurrent();
    const missing_plan = [_]analysis.PropertyPredicate{.{
        .property_ref = .{ .name = "plan", .scalar_type = .missing },
        .operator = .is,
    }};
    const selectors = [_]analysis.EventSelector{
        .{ .kind = .exact_event, .value = "signup" },
        .{ .kind = .exact_event, .value = "purchase" },
        .{ .kind = .exact_page, .value = "/pricing" },
        .{ .kind = .page_prefix, .value = "/" },
        .{ .kind = .exact_event, .value = "purchase", .predicates = &missing_plan },
        .{ .kind = .exact_page, .value = "/" },
        .{ .kind = .exact_event, .value = "download" },
        .{ .kind = .exact_event, .value = "never" },
    };
    const request = analysis.FunnelAvailabilityRequest{
        .site_id = site_id,
        .range = range,
        .selectors = &selectors,
        .active_goals = resolved,
        .strict_traffic_mode = policy.strict_mode,
        .timeout_ms = analysis.maximum_timeout_ms,
    };
    if (explain) {
        try output.writeAll(try analysis_store.profileFunnelAvailability(
            allocator,
            &store,
            request,
        ));
        return;
    }
    if (builtin.mode == .debug) {
        try std.json.Stringify.value(.{
            .strict_mode = policy.strict_mode,
            .selector_count = selectors.len,
            .performance_enforced = false,
            .sample_micros = &[_]i64{},
            .p95_micros = @as(?i64, null),
            .timeout_interrupted = false,
            .connection_reused = false,
        }, .{}, output);
        try output.writeByte('\n');
        return;
    }
    var timeout_request = request;
    timeout_request.timeout_ms = 1;
    if (analysis_store.executeFunnelAvailability(
        allocator,
        &store,
        timeout_request,
    )) |_| {
        return error.ExpectedFunnelAvailabilityTimeout;
    } else |err| if (err != error.AnalysisTimeout) return err;
    _ = try analysis_store.executeFunnelAvailability(allocator, &store, request);
    var samples: [10]i64 = undefined;
    var last: []const analysis.FunnelAvailabilityRow = &.{};
    for (&samples) |*elapsed| {
        const started = std.Io.Clock.awake.now(io).nanoseconds;
        last = try analysis_store.executeFunnelAvailability(
            allocator,
            &store,
            request,
        );
        elapsed.* = @intCast(@divTrunc(
            std.Io.Clock.awake.now(io).nanoseconds - started,
            std.time.ns_per_us,
        ));
    }
    if (last.len != selectors.len) return error.InvalidFunnelAvailability;
    std.mem.sort(i64, &samples, {}, std.sort.asc(i64));
    try std.json.Stringify.value(.{
        .strict_mode = policy.strict_mode,
        .selector_count = selectors.len,
        .performance_enforced = true,
        .sample_micros = samples,
        .p95_micros = samples[9],
        .timeout_interrupted = true,
        .connection_reused = true,
    }, .{}, output);
    try output.writeByte('\n');
}

pub fn funnelResultSemantics(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    site_id: []const u8,
) !void {
    try domain.validateUuid(site_id);
    const event_path = try std.fs.path.join(
        allocator,
        &.{ directory, "events.duckdb" },
    );
    var store = try events.Store.open(allocator, event_path);
    defer store.deinit();
    try store.requireCurrent();
    const sql_template =
        \\INSERT INTO identity_links VALUES
        \\ ('__SITE__', CAST('00000000-0000-4000-8000-0000000007a7' AS UUID),
        \\  'funnel-cross-user', 1738368000000000,
        \\  CAST('00000000-0000-4000-8000-000000000719' AS UUID)),
        \\ ('__SITE__', CAST('00000000-0000-4000-8000-0000000007a8' AS UUID),
        \\  'funnel-cross-user', 1738369800000000,
        \\  CAST('00000000-0000-4000-8000-000000000720' AS UUID));
        \\INSERT INTO events
        \\SELECT template.* REPLACE (
        \\  7 AS event_schema_version, 2 AS protocol_version,
        \\  2 AS tracker_version, CAST(v.event_id AS UUID) AS event_id,
        \\  v.received_at AS received_at_utc_micros,
        \\  v.occurred_at AS occurred_at_utc_micros,
        \\  CAST(v.local_date AS DATE) AS received_date_utc,
        \\  CAST(v.local_date AS DATE) AS site_local_date,
        \\  0 AS site_utc_offset_minutes, v.kind AS kind,
        \\  v.event_name AS event_name, '/funnel-fixture' AS path,
        \\  'Funnel fixture' AS page_title, 'alpha.example' AS hostname,
        \\  CAST(v.anonymous_id AS UUID) AS anonymous_id,
        \\  v.identity_quality AS identity_quality, '' AS user_id,
        \\  CAST(v.session_id AS UUID) AS session_id, v.sequence AS sequence,
        \\  v.sequence = 0 AS session_start, '' AS referrer_host,
        \\  v.country AS country_code, 'en' AS language,
        \\  'Chrome' AS browser_family, 'Linux' AS os_family,
        \\  'desktop' AS device_category, '' AS utm_source,
        \\  '' AS utm_medium, '' AS utm_campaign,
        \\  '' AS utm_term, '' AS utm_content,
        \\  v.properties AS properties_json, '{}' AS user_traits_json,
        \\  CAST(NULL AS DECIMAL(18, 6)) AS value_amount,
        \\  '' AS value_currency, 0 AS engagement_ms,
        \\  0 AS max_scroll_depth,
        \\  from_hex(md5(v.anonymous_id)) AS visitor_day_id,
        \\  v.sequence = 0 AS visitor_day_start,
        \\  repeat('f', 64) AS event_payload_digest,
        \\  1 AS traffic_class, 2 AS classifier_version, '' AS bot_rule,
        \\  0 AS signal_version, FALSE AS navigator_webdriver,
        \\  0 AS trusted_interactions, FALSE AS was_visible,
        \\  FALSE AS was_prerendered, 0 AS viewport_bucket,
        \\  0 AS beacon_timing_bucket, 0 AS client_hint_consistency,
        \\  FALSE AS accept_language_present,
        \\  from_hex('77777777777777777777777777777777') AS network_day_id
        \\) FROM events template CROSS JOIN (VALUES
        \\ ('00000000-0000-4000-8000-000000000701',1738368000000000,1738368000000000,'2025-02-01',2,'start','00000000-0000-4000-8000-0000000007a1',1,'00000000-0000-4000-8000-0000000007b1',0,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000702',1738368001000000,1738368001000000,'2025-02-01',2,'detour','00000000-0000-4000-8000-0000000007a1',1,'00000000-0000-4000-8000-0000000007b1',1,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000703',1738368002000000,1738368002000000,'2025-02-01',2,'finish','00000000-0000-4000-8000-0000000007a1',1,'00000000-0000-4000-8000-0000000007b1',2,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000704',1738368010000000,1738368010000000,'2025-02-01',2,'internal_start','00000000-0000-4000-8000-0000000007a2',1,'00000000-0000-4000-8000-0000000007b2',0,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000705',1738368011000000,1738368011000000,'2025-02-01',2,'detour','00000000-0000-4000-8000-0000000007a2',1,'00000000-0000-4000-8000-0000000007b2',1,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000706',1738368012000000,1738368012000000,'2025-02-01',2,'internal_start','00000000-0000-4000-8000-0000000007a2',1,'00000000-0000-4000-8000-0000000007b2',2,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000707',1738368013000000,1738368013000000,'2025-02-01',4,'identify','00000000-0000-4000-8000-0000000007a2',1,'00000000-0000-4000-8000-0000000007b2',3,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000708',1738368014000000,1738368014000000,'2025-02-01',3,'engagement','00000000-0000-4000-8000-0000000007a2',1,'00000000-0000-4000-8000-0000000007b2',4,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000709',1738368015000000,1738368015000000,'2025-02-01',2,'internal_finish','00000000-0000-4000-8000-0000000007a2',1,'00000000-0000-4000-8000-0000000007b2',5,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000710',1738368020000000,1738368020000000,'2025-02-01',2,'same','00000000-0000-4000-8000-0000000007a3',1,'00000000-0000-4000-8000-0000000007b3',0,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000711',1738368030000000,1738368030000000,'2025-02-01',2,'same','00000000-0000-4000-8000-0000000007a4',1,'00000000-0000-4000-8000-0000000007b4',0,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000712',1738368030000000,1738368030000000,'2025-02-01',2,'same','00000000-0000-4000-8000-0000000007a4',1,'00000000-0000-4000-8000-0000000007b4',1,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000713',1738368040000000,1738368040000000,'2025-02-01',2,'tie_start','00000000-0000-4000-8000-0000000007a5',1,'00000000-0000-4000-8000-0000000007b5',0,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000714',1738368040000000,1738368040000000,'2025-02-01',2,'tie_finish','00000000-0000-4000-8000-0000000007a5',1,'00000000-0000-4000-8000-0000000007b5',1,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000715',1738368050000000,1738368050000000,'2025-02-01',2,'window_start','00000000-0000-4000-8000-0000000007a6',1,'00000000-0000-4000-8000-0000000007b6',0,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000716',1738375250000000,1738375250000000,'2025-02-01',2,'window_finish','00000000-0000-4000-8000-0000000007a6',1,'00000000-0000-4000-8000-0000000007b6',1,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000717',1738378850000000,1738378850000000,'2025-02-01',2,'window_start','00000000-0000-4000-8000-0000000007a6',1,'00000000-0000-4000-8000-0000000007b6',2,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000718',1738380650000000,1738380650000000,'2025-02-01',2,'window_finish','00000000-0000-4000-8000-0000000007a6',1,'00000000-0000-4000-8000-0000000007b6',3,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000719',1738368060000000,1738368060000000,'2025-02-01',2,'start','00000000-0000-4000-8000-0000000007a7',1,'00000000-0000-4000-8000-0000000007b7',0,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000720',1738369860000000,1738369860000000,'2025-02-01',2,'finish','00000000-0000-4000-8000-0000000007a8',1,'00000000-0000-4000-8000-0000000007b8',0,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000721',1738368070000000,1738368070000000,'2025-02-01',2,'start','00000000-0000-4000-8000-0000000007a9',3,'00000000-0000-4000-8000-0000000007b9',0,'{}','ZZ'),
        \\ ('00000000-0000-4000-8000-000000000722',1738368071000000,1738368071000000,'2025-02-01',2,'finish','00000000-0000-4000-8000-0000000007a9',3,'00000000-0000-4000-8000-0000000007b9',1,'{}','ZZ'),
        \\ ('00000000-0000-4000-8000-000000000723',1738368080000000,1738368080000000,'2025-02-01',2,'start','00000000-0000-4000-8000-0000000007aa',2,'00000000-0000-4000-8000-0000000007ba',0,'{}','FR'),
        \\ ('00000000-0000-4000-8000-000000000724',1738368081000000,1738368081000000,'2025-02-01',2,'finish','00000000-0000-4000-8000-0000000007aa',2,'00000000-0000-4000-8000-0000000007ba',1,'{}','FR'),
        \\ ('00000000-0000-4000-8000-000000000725',1738368090000000,1738368090000000,'2025-02-01',2,'start','00000000-0000-4000-8000-0000000007ab',1,'00000000-0000-4000-8000-0000000007bb',0,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000726',1738368091000000,1738368091000000,'2025-02-01',2,'finish','00000000-0000-4000-8000-0000000007ab',1,'00000000-0000-4000-8000-0000000007bb',1,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000727',1738368100000000,1738368100000000,'2025-02-01',2,'start','00000000-0000-4000-8000-0000000007ac',1,'00000000-0000-4000-8000-0000000007bc',0,'{}','DE'),
        \\ ('00000000-0000-4000-8000-000000000728',1738368101000000,1738368101000000,'2025-02-01',2,'finish','00000000-0000-4000-8000-0000000007ac',1,'00000000-0000-4000-8000-0000000007bc',1,'{}','DE'),
        \\ ('00000000-0000-4000-8000-000000000729',1738368110000000,1738368110000000,'2025-02-01',2,'buy','00000000-0000-4000-8000-0000000007ad',1,'00000000-0000-4000-8000-0000000007bd',0,'{"plan":"pro"}','US'),
        \\ ('00000000-0000-4000-8000-000000000730',1738368111000000,1738368111000000,'2025-02-01',2,'done','00000000-0000-4000-8000-0000000007ad',1,'00000000-0000-4000-8000-0000000007bd',1,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000731',1738281600000000,1738281600000000,'2025-01-31',2,'start','00000000-0000-4000-8000-0000000007ae',1,'00000000-0000-4000-8000-0000000007be',0,'{}','US'),
        \\ ('00000000-0000-4000-8000-000000000732',1738281601000000,1738281601000000,'2025-01-31',2,'finish','00000000-0000-4000-8000-0000000007ae',1,'00000000-0000-4000-8000-0000000007be',1,'{}','US')
        \\) v(event_id,occurred_at,received_at,local_date,kind,event_name,
        \\    anonymous_id,identity_quality,session_id,sequence,properties,country)
        \\WHERE template.site_id = '__SITE__'
        \\  AND template.event_id = CAST(
        \\    '00000000-0000-4000-8000-000000000001' AS UUID);
    ;
    const rendered_sql = try std.mem.replaceOwned(
        u8,
        allocator,
        sql_template,
        "__SITE__",
        site_id,
    );
    defer allocator.free(rendered_sql);
    const sql = try allocator.dupeSentinel(u8, rendered_sql, 0);
    defer allocator.free(sql);
    try store.database.exec(sql);
    try store.checkpoint();

    const base_selectors = [_]analysis.EventSelector{
        .{ .kind = .exact_event, .value = "start" },
        .{ .kind = .exact_event, .value = "finish" },
    };
    const base = funnel.ResultRequest{
        .site_id = site_id,
        .range = .{ .start = "2025-02-01", .end = "2025-02-01" },
        .comparison_range = .{ .start = "2025-01-31", .end = "2025-01-31" },
        .order = .sequential,
        .scope = .sessions,
        .window = .same_session,
        .selectors = &base_selectors,
    };
    const sequential = try analysis_store.executeFunnelResult(
        allocator,
        &store,
        base,
    );
    if (sequential.current.entrants != 6 or
        sequential.current.completions != 5 or
        sequential.comparison.?.entrants != 1 or
        sequential.comparison.?.completions != 1)
    {
        return error.InvalidFunnelSemanticFixture;
    }
    var consecutive_request = base;
    consecutive_request.order = .consecutive;
    const consecutive = try analysis_store.executeFunnelResult(
        allocator,
        &store,
        consecutive_request,
    );
    if (consecutive.current.entrants != 6 or
        consecutive.current.completions != 4)
    {
        return error.InvalidFunnelSemanticFixture;
    }

    const internal_selectors = [_]analysis.EventSelector{
        .{ .kind = .exact_event, .value = "internal_start" },
        .{ .kind = .exact_event, .value = "internal_finish" },
    };
    var internal_request = base;
    internal_request.order = .consecutive;
    internal_request.comparison_range = null;
    internal_request.selectors = &internal_selectors;
    const internal = try analysis_store.executeFunnelResult(
        allocator,
        &store,
        internal_request,
    );
    if (internal.current.entrants != 1 or internal.current.completions != 1) {
        return error.InvalidFunnelSemanticFixture;
    }

    const repeated_selectors = [_]analysis.EventSelector{
        .{ .kind = .exact_event, .value = "same" },
        .{ .kind = .exact_event, .value = "same" },
    };
    var repeated_request = base;
    repeated_request.comparison_range = null;
    repeated_request.selectors = &repeated_selectors;
    const repeated = try analysis_store.executeFunnelResult(
        allocator,
        &store,
        repeated_request,
    );
    if (repeated.current.entrants != 2 or
        repeated.current.completions != 1 or
        repeated.current.steps[1].median_from_prior_micros != 0)
    {
        return error.InvalidFunnelSemanticFixture;
    }

    const tie_selectors = [_]analysis.EventSelector{
        .{ .kind = .exact_event, .value = "tie_start" },
        .{ .kind = .exact_event, .value = "tie_finish" },
    };
    var tie_request = base;
    tie_request.comparison_range = null;
    tie_request.order = .consecutive;
    tie_request.selectors = &tie_selectors;
    const tie = try analysis_store.executeFunnelResult(
        allocator,
        &store,
        tie_request,
    );
    if (tie.current.completions != 1 or
        tie.current.steps[1].median_from_prior_micros != 0)
    {
        return error.InvalidFunnelSemanticFixture;
    }

    const window_selectors = [_]analysis.EventSelector{
        .{ .kind = .exact_event, .value = "window_start" },
        .{ .kind = .exact_event, .value = "window_finish" },
    };
    var window_request = base;
    window_request.comparison_range = null;
    window_request.window = .one_hour;
    window_request.selectors = &window_selectors;
    const window_result = try analysis_store.executeFunnelResult(
        allocator,
        &store,
        window_request,
    );
    if (window_result.current.entrants != 1 or
        window_result.current.completions != 1 or
        window_result.current.median_total_micros != 1_800_000_000)
    {
        return error.InvalidFunnelSemanticFixture;
    }

    const cross_selectors = [_]analysis.EventSelector{
        .{ .kind = .exact_event, .value = "start" },
        .{ .kind = .exact_event, .value = "finish" },
    };
    var visitor_request = base;
    visitor_request.comparison_range = null;
    visitor_request.scope = .visitors;
    visitor_request.selectors = &cross_selectors;
    const same_session = try analysis_store.executeFunnelResult(
        allocator,
        &store,
        visitor_request,
    );
    if (same_session.current.entrants != 4 or
        same_session.current.completions != 3)
    {
        return error.InvalidFunnelSemanticFixture;
    }
    inline for (.{
        funnel.Window.one_hour,
        funnel.Window.one_day,
        funnel.Window.seven_days,
        funnel.Window.thirty_days,
    }) |window| {
        visitor_request.window = window;
        const result = try analysis_store.executeFunnelResult(
            allocator,
            &store,
            visitor_request,
        );
        if (result.current.entrants != 4 or result.current.completions != 4 or
            result.current.identity_coverage.?.ephemeral_step_one != 1 or
            result.current.identity_coverage.?.legacy_step_one != 1)
        {
            return error.InvalidFunnelSemanticFixture;
        }
    }

    const filter = [_]analysis.Clause{.{
        .scope = .event,
        .field = .{ .kind = .country },
        .operator = .is,
        .scalar_type = .string,
        .values = &.{"DE"},
    }};
    var filtered_request = base;
    filtered_request.filters = .{ .clauses = &filter };
    const filtered = try analysis_store.executeFunnelResult(
        allocator,
        &store,
        filtered_request,
    );
    if (filtered.current.entrants != 1 or filtered.current.completions != 1 or
        filtered.comparison == null or
        filtered.comparison.?.entrants != 0 or
        filtered.comparison.?.completions != 0)
    {
        return error.InvalidFunnelSemanticFixture;
    }

    const plan_values = [_][]const u8{"pro"};
    const plan_predicates = [_]analysis.PropertyPredicate{.{
        .property_ref = .{ .name = "plan", .scalar_type = .string },
        .operator = .is,
        .values = &plan_values,
    }};
    const property_selectors = [_]analysis.EventSelector{
        .{
            .kind = .exact_event,
            .value = "buy",
            .predicates = &plan_predicates,
        },
        .{ .kind = .exact_event, .value = "done" },
    };
    var property_request = base;
    property_request.comparison_range = null;
    property_request.selectors = &property_selectors;
    const property_result = try analysis_store.executeFunnelResult(
        allocator,
        &store,
        property_request,
    );
    if (property_result.current.entrants != 1 or
        property_result.current.completions != 1)
    {
        return error.InvalidFunnelSemanticFixture;
    }

    var zero_request = base;
    zero_request.comparison_range = null;
    zero_request.selectors = &.{
        .{ .kind = .exact_event, .value = "never_start" },
        .{ .kind = .exact_event, .value = "never_finish" },
    };
    const zero = try analysis_store.executeFunnelResult(
        allocator,
        &store,
        zero_request,
    );
    if (zero.current.entrants != 0 or zero.current.completions != 0 or
        zero.current.median_total_micros != null)
    {
        return error.InvalidFunnelSemanticFixture;
    }

    try std.json.Stringify.value(.{
        .sequential = true,
        .consecutive = true,
        .restart_and_internal_events = true,
        .repeated_one_event_trap = true,
        .same_timestamp_sequence = true,
        .window_retry = true,
        .visitor_identity_links = true,
        .all_windows = true,
        .legacy_ephemeral_coverage = true,
        .event_filter = true,
        .property_goal_selector = true,
        .comparison = true,
        .zero = true,
    }, .{}, output);
    try output.writeByte('\n');
}

pub fn funnelResultProfile(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
    site_slug: []const u8,
    current_start: []const u8,
    current_end: []const u8,
    comparison_start: []const u8,
    comparison_end: []const u8,
    explain: bool,
) !void {
    try domain.validateSlug(site_slug);
    const metadata_path = try std.fs.path.join(
        allocator,
        &.{ directory, "meta.db" },
    );
    var metadata = try meta.Store.open(allocator, metadata_path);
    defer metadata.deinit();
    try metadata.requireCurrent();
    const site_id = try metadata.siteIdBySlug(allocator, site_slug);
    const policy = try metadata.sitePolicy(allocator, site_id);
    const goals = try metadata.listGoals(allocator, site_slug);
    const resolved = try allocator.alloc(analysis.ResolvedGoal, goals.len);
    for (resolved, goals) |*target, goal| target.* = .{
        .id = goal.id,
        .selector = .{
            .kind = switch (goal.match_kind) {
                .event => .exact_event,
                .path => .exact_page,
                .prefix => .page_prefix,
            },
            .value = goal.match_value,
            .predicates = goal.predicates,
        },
    };
    const event_path = try std.fs.path.join(
        allocator,
        &.{ directory, "events.duckdb" },
    );
    var store = try events.Store.open(allocator, event_path);
    defer store.deinit();
    try store.requireCurrent();
    const selectors = [_]analysis.EventSelector{
        .{ .kind = .exact_page, .value = "/" },
        .{ .kind = .exact_page, .value = "/pricing" },
        .{ .kind = .exact_page, .value = "/docs" },
        .{ .kind = .exact_page, .value = "/features" },
        .{ .kind = .exact_page, .value = "/download" },
        .{ .kind = .exact_page, .value = "/install" },
        .{ .kind = .exact_page, .value = "/account" },
        .{ .kind = .exact_page, .value = "/checkout" },
    };
    const request = funnel.ResultRequest{
        .site_id = site_id,
        .range = .{ .start = current_start, .end = current_end },
        .comparison_range = .{
            .start = comparison_start,
            .end = comparison_end,
        },
        .order = .sequential,
        .scope = .sessions,
        .window = .same_session,
        .selectors = &selectors,
        .active_goals = if (policy.strict_mode) resolved else &.{},
        .strict_traffic_mode = policy.strict_mode,
        .timeout_ms = analysis.maximum_timeout_ms,
    };
    if (explain) {
        try output.writeAll(try analysis_store.profileFunnelResult(
            allocator,
            &store,
            request,
        ));
        return;
    }
    if (builtin.mode == .debug) {
        try std.json.Stringify.value(.{
            .strict_mode = policy.strict_mode,
            .active_goal_count = goals.len,
            .selector_count = selectors.len,
            .comparison_populated = false,
            .performance_enforced = false,
            .preview_availability_rows = 0,
            .current_entrants = @as(?i64, null),
            .comparison_entrants = @as(?i64, null),
            .current_sample_micros = &[_]i64{},
            .comparison_sample_micros = &[_]i64{},
            .sample_micros = &[_]i64{},
            .current_p95_micros = @as(?i64, null),
            .comparison_p95_micros = @as(?i64, null),
            .p95_micros = @as(?i64, null),
            .timeout_interrupted = false,
            .connection_reused = false,
        }, .{}, output);
        try output.writeByte('\n');
        return;
    }
    var timeout_request = request;
    timeout_request.timeout_ms = 1;
    if (analysis_store.executeFunnelPreview(
        allocator,
        &store,
        timeout_request,
    )) |_| {
        return error.ExpectedFunnelResultTimeout;
    } else |err| if (err != error.AnalysisTimeout) return err;
    const preview = try analysis_store.executeFunnelPreview(
        allocator,
        &store,
        request,
    );
    const last = preview.result;
    var current_request = request;
    current_request.comparison_range = null;
    var comparison_request = request;
    comparison_request.range = request.comparison_range.?;
    comparison_request.comparison_range = null;
    _ = try analysis_store.executeFunnelResult(
        allocator,
        &store,
        current_request,
    );
    _ = try analysis_store.executeFunnelResult(
        allocator,
        &store,
        comparison_request,
    );
    var current_samples: [10]i64 = undefined;
    var comparison_samples: [10]i64 = undefined;
    var combined_samples: [10]i64 = undefined;
    for (&current_samples, &comparison_samples, &combined_samples) |
        *current_elapsed,
        *comparison_elapsed,
        *combined_elapsed,
    | {
        const started = std.Io.Clock.awake.now(io).nanoseconds;
        _ = try analysis_store.executeFunnelResult(
            allocator,
            &store,
            current_request,
        );
        current_elapsed.* = @intCast(@divTrunc(
            std.Io.Clock.awake.now(io).nanoseconds - started,
            std.time.ns_per_us,
        ));
        const comparison_started = std.Io.Clock.awake.now(io).nanoseconds;
        _ = try analysis_store.executeFunnelResult(
            allocator,
            &store,
            comparison_request,
        );
        comparison_elapsed.* = @intCast(@divTrunc(
            std.Io.Clock.awake.now(io).nanoseconds - comparison_started,
            std.time.ns_per_us,
        ));
        combined_elapsed.* = std.math.add(
            i64,
            current_elapsed.*,
            comparison_elapsed.*,
        ) catch return error.InvalidFunnelProfileResult;
    }
    std.mem.sort(i64, &current_samples, {}, std.sort.asc(i64));
    std.mem.sort(i64, &comparison_samples, {}, std.sort.asc(i64));
    std.mem.sort(i64, &combined_samples, {}, std.sort.asc(i64));
    if (preview.availability.len != selectors.len or
        last.current.steps.len != selectors.len or last.comparison == null or
        last.comparison.?.steps.len != selectors.len or
        last.current.entrants == 0 or last.current.completions == 0 or
        last.comparison.?.entrants == 0 or last.comparison.?.completions == 0)
    {
        return error.InvalidFunnelProfileResult;
    }
    try std.json.Stringify.value(.{
        .strict_mode = policy.strict_mode,
        .active_goal_count = goals.len,
        .selector_count = selectors.len,
        .comparison_populated = true,
        .performance_enforced = true,
        .preview_availability_rows = preview.availability.len,
        .current_entrants = last.current.entrants,
        .current_completions = last.current.completions,
        .comparison_entrants = last.comparison.?.entrants,
        .comparison_completions = last.comparison.?.completions,
        .current_sample_micros = current_samples,
        .comparison_sample_micros = comparison_samples,
        .sample_micros = combined_samples,
        .current_p95_micros = current_samples[9],
        .comparison_p95_micros = comparison_samples[9],
        .p50_micros = combined_samples[4],
        .p95_micros = combined_samples[9],
        .timeout_interrupted = true,
        .connection_reused = true,
    }, .{}, output);
    try output.writeByte('\n');
}

pub fn goalCapacityRecovery(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    site_slug: []const u8,
) !void {
    try domain.validateSlug(site_slug);
    const metadata_path = try std.fs.path.join(
        allocator,
        &.{ directory, "meta.db" },
    );
    var metadata = try meta.Store.open(allocator, metadata_path);
    defer metadata.deinit();
    try metadata.requireCurrent();

    const initial = try metadata.listGoalDefinitions(allocator, site_slug, 1);
    if (initial.has_more or initial.active_count != 34 or
        initial.goals.len != 34)
    {
        return error.InvalidGoalCapacityFixture;
    }
    var next_timestamp: i64 = 1;
    for (initial.goals) |goal| {
        next_timestamp = @max(next_timestamp, goal.updated_at_utc_micros);
    }
    next_timestamp = std.math.add(i64, next_timestamp, 1) catch
        return error.InvalidGoalTimestamp;
    if (next_timestamp > std.math.maxInt(i64) - 6) {
        return error.InvalidGoalTimestamp;
    }

    const probe_id = "50000000-0000-4000-8000-000000000001";
    try requireTooMany(metadata.addGoal(
        allocator,
        probe_id,
        site_slug,
        "Capacity probe",
        .event,
        "capacity_probe",
        &.{},
        next_timestamp,
    ));

    const first = initial.goals[0];
    const second = initial.goals[1];
    const third = initial.goals[2];
    const fourth = initial.goals[3];
    try metadata.archiveGoal(
        allocator,
        site_slug,
        first.id,
        first.updated_at_utc_micros,
        next_timestamp,
    );
    try requireTooMany(metadata.reactivateGoal(
        allocator,
        site_slug,
        first.id,
        next_timestamp,
        next_timestamp + 1,
    ));
    try requireTooMany(metadata.addGoal(
        allocator,
        probe_id,
        site_slug,
        "Capacity probe",
        .event,
        "capacity_probe",
        &.{},
        next_timestamp + 1,
    ));

    try metadata.archiveGoal(
        allocator,
        site_slug,
        second.id,
        second.updated_at_utc_micros,
        next_timestamp + 1,
    );
    try requireTooMany(metadata.reactivateGoal(
        allocator,
        site_slug,
        first.id,
        next_timestamp,
        next_timestamp + 2,
    ));
    try requireTooMany(metadata.addGoal(
        allocator,
        probe_id,
        site_slug,
        "Capacity probe",
        .event,
        "capacity_probe",
        &.{},
        next_timestamp + 2,
    ));

    try metadata.archiveGoal(
        allocator,
        site_slug,
        third.id,
        third.updated_at_utc_micros,
        next_timestamp + 2,
    );
    try metadata.reactivateGoal(
        allocator,
        site_slug,
        first.id,
        next_timestamp,
        next_timestamp + 3,
    );
    try metadata.archiveGoal(
        allocator,
        site_slug,
        fourth.id,
        fourth.updated_at_utc_micros,
        next_timestamp + 4,
    );
    try metadata.addGoal(
        allocator,
        probe_id,
        site_slug,
        "Capacity probe",
        .event,
        "capacity_probe",
        &.{},
        next_timestamp + 5,
    );
    try metadata.deleteGoalById(
        allocator,
        site_slug,
        probe_id,
        next_timestamp + 5,
        "Capacity probe",
    );
    try metadata.reactivateGoal(
        allocator,
        site_slug,
        second.id,
        next_timestamp + 1,
        next_timestamp + 6,
    );

    const final = try metadata.listGoalDefinitions(allocator, site_slug, 1);
    if (final.has_more or final.active_count != 32 or final.goals.len != 34) {
        return error.InvalidGoalCapacityRecovery;
    }
    try std.json.Stringify.value(.{
        .initial_active = initial.active_count,
        .new_blocked_at_34_33_32 = true,
        .reactivation_blocked_at_33_32 = true,
        .new_succeeded_at_31 = true,
        .reactivation_succeeded_at_31 = true,
        .final_active = final.active_count,
        .definitions_preserved = final.goals.len,
    }, .{}, output);
    try output.writeByte('\n');
}

fn requireTooMany(result: anyerror!void) !void {
    _ = result catch |err| {
        if (err == error.TooManyActiveGoals) return;
        return err;
    };
    return error.ExpectedTooManyActiveGoals;
}

pub fn trafficQualityProfile(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    site_slug: []const u8,
    start_date: []const u8,
    end_date: []const u8,
) !void {
    try domain.validateSlug(site_slug);
    try domain.validateDate(start_date);
    try domain.validateDate(end_date);
    const start_day = try report.dateDay(start_date);
    const end_day = try report.dateDay(end_date);
    if (end_day < start_day or end_day - start_day + 1 > report.maximum_range_days) {
        return error.InvalidReportRange;
    }
    const metadata_path = try std.fs.path.join(allocator, &.{ directory, "meta.db" });
    var metadata = try meta.Store.open(allocator, metadata_path);
    defer metadata.deinit();
    try metadata.requireCurrent();
    const site_id = try metadata.siteIdBySlug(allocator, site_slug);
    const active_goals = try metadata.listGoals(allocator, site_slug);
    const policy = try metadata.sitePolicy(allocator, site_id);

    const event_path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, event_path);
    defer store.deinit();
    try store.requireCurrent();
    const request: report.Request = .{
        .directory = directory,
        .site_slug = site_slug,
        .start_date = start_date,
        .end_date = end_date,
        .start_day = start_day,
        .end_day = end_day,
        .kind = .traffic_quality,
    };
    const profile = try reports.trafficQualityProfile(
        allocator,
        &store,
        request,
        site_id,
        .{
            .strict_mode = policy.strict_mode,
            .daily_event_ceiling = policy.daily_event_ceiling,
            .active_goals = active_goals,
            .heuristic_available = active_goals.len <= meta.maximum_active_goals,
        },
    );
    try output.writeAll(profile);
}

pub fn liveProfile(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
    site_slug: []const u8,
    now_text: []const u8,
    mode: []const u8,
    explain: bool,
) !void {
    try domain.validateSlug(site_slug);
    const now_utc_micros = std.fmt.parseInt(i64, now_text, 10) catch
        return error.InvalidLiveClock;
    const strict_mode = if (std.mem.eql(u8, mode, "normal"))
        false
    else if (std.mem.eql(u8, mode, "strict"))
        true
    else
        return error.InvalidLiveMode;
    const metadata_path = try std.fs.path.join(
        allocator,
        &.{ directory, "meta.db" },
    );
    var metadata = try meta.Store.open(allocator, metadata_path);
    defer metadata.deinit();
    try metadata.requireCurrent();
    const site_id = try metadata.siteIdBySlug(allocator, site_slug);
    const goals = try metadata.listGoals(allocator, site_slug);
    const resolved = try allocator.alloc(analysis.ResolvedGoal, goals.len);
    for (resolved, goals) |*target, goal| target.* = .{
        .id = goal.id,
        .selector = .{
            .kind = switch (goal.match_kind) {
                .event => .exact_event,
                .path => .exact_page,
                .prefix => .page_prefix,
            },
            .value = goal.match_value,
            .predicates = goal.predicates,
        },
    };
    const event_path = try std.fs.path.join(
        allocator,
        &.{ directory, "events.duckdb" },
    );
    var store = try events.Store.open(allocator, event_path);
    defer store.deinit();
    try store.requireCurrent();
    const request = analysis.LiveRequest{
        .site_id = site_id,
        .active_goals = resolved,
        .strict_traffic_mode = strict_mode,
        .now_utc_micros = now_utc_micros,
    };
    if (explain) {
        try output.writeAll(try analysis_store.profileLive(
            allocator,
            &store,
            request,
        ));
        return;
    }

    var timeout_request = request;
    timeout_request.timeout_ms = 1;
    if (analysis_store.executeLive(allocator, &store, timeout_request)) |_| {
        return error.ExpectedLiveTimeout;
    } else |err| if (err != error.AnalysisTimeout) return err;
    const after_timeout = try analysis_store.executeLive(
        allocator,
        &store,
        request,
    );
    if (builtin.mode == .debug) {
        try writeLiveEvidence(
            output,
            strict_mode,
            after_timeout,
            false,
            &.{},
            true,
            true,
        );
        return;
    }
    _ = try analysis_store.executeLive(allocator, &store, request);
    var samples: [10]i64 = undefined;
    var last = after_timeout;
    for (&samples) |*elapsed| {
        const started = std.Io.Clock.awake.now(io).nanoseconds;
        last = try analysis_store.executeLive(allocator, &store, request);
        elapsed.* = @intCast(@divTrunc(
            std.Io.Clock.awake.now(io).nanoseconds - started,
            std.time.ns_per_us,
        ));
    }
    std.mem.sort(i64, &samples, {}, std.sort.asc(i64));
    try writeLiveEvidence(
        output,
        strict_mode,
        last,
        true,
        &samples,
        true,
        true,
    );
    if (samples[9] >= 150_000) return error.LivePerformanceBudgetExceeded;
}

fn writeLiveEvidence(
    output: *std.Io.Writer,
    strict_mode: bool,
    result: analysis.LiveResult,
    performance_enforced: bool,
    samples: []const i64,
    timeout_interrupted: bool,
    connection_reused: bool,
) !void {
    try std.json.Stringify.value(.{
        .strict_mode = strict_mode,
        .active_sessions = result.active_sessions,
        .page_views = result.page_views,
        .custom_events = result.custom_events,
        .conversions = result.conversions,
        .page_rows = result.pages.len,
        .source_rows = result.sources.len,
        .event_rows = result.events.len,
        .goal_rows = result.goals.len,
        .country_rows = result.countries.len,
        .device_rows = result.devices.len,
        .protocol_rows = result.protocols.len,
        .latest_receipt = result.latest_accepted_at_utc_micros,
        .performance_enforced = performance_enforced,
        .sample_micros = samples,
        .p50_micros = if (samples.len == 0) @as(?i64, null) else samples[4],
        .p95_micros = if (samples.len == 0) @as(?i64, null) else samples[9],
        .p99_micros = if (samples.len == 0) @as(?i64, null) else samples[9],
        .timeout_interrupted = timeout_interrupted,
        .connection_reused = connection_reused,
    }, .{}, output);
    try output.writeByte('\n');
}

pub fn overviewV2(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
    site_slug: []const u8,
    current_start: []const u8,
    current_end: []const u8,
    comparison_start: []const u8,
    comparison_end: []const u8,
    profile: bool,
) !void {
    try domain.validateSlug(site_slug);
    const current = analysis.LocalDateRange{
        .start = current_start,
        .end = current_end,
    };
    const comparison = analysis.LocalDateRange{
        .start = comparison_start,
        .end = comparison_end,
    };
    try current.validate();
    try comparison.validate();
    const metadata_path = try std.fs.path.join(allocator, &.{ directory, "meta.db" });
    var metadata = try meta.Store.open(allocator, metadata_path);
    defer metadata.deinit();
    try metadata.requireCurrent();
    const site_id = try metadata.siteIdBySlug(allocator, site_slug);
    const goals = try metadata.listGoals(allocator, site_slug);
    const policy = try metadata.sitePolicy(allocator, site_id);
    const resolved = try allocator.alloc(analysis.ResolvedGoal, goals.len);
    for (resolved, goals) |*target, goal| target.* = .{
        .id = goal.id,
        .selector = .{
            .kind = switch (goal.match_kind) {
                .event => .exact_event,
                .path => .exact_page,
                .prefix => .page_prefix,
            },
            .value = goal.match_value,
            .predicates = goal.predicates,
        },
    };
    const event_path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, event_path);
    defer store.deinit();
    try store.requireCurrent();
    const current_buckets = try overviewDayBuckets(allocator, current);
    const comparison_buckets = try overviewDayBuckets(allocator, comparison);
    const execution = analysis.OverviewExecution{
        .site_id = site_id,
        .range = current,
        .comparison_range = comparison,
        .active_goals = resolved,
        .strict_traffic_mode = policy.strict_mode,
        .daily_event_ceiling = policy.daily_event_ceiling,
        .trend = .{
            .metric = .visitors,
            .interval = .day,
            .current_buckets = current_buckets,
            .comparison_buckets = comparison_buckets,
        },
    };
    if (profile) {
        try output.writeAll(try analysis_store.profileOverview(
            allocator,
            &store,
            execution,
        ));
        return;
    }
    _ = try analysis_store.executeOverview(allocator, &store, execution);
    var durations: [10]i64 = undefined;
    var last: analysis.OverviewResult = undefined;
    for (&durations) |*duration| {
        const started = std.Io.Clock.awake.now(io).nanoseconds;
        last = try analysis_store.executeOverview(allocator, &store, execution);
        duration.* = @intCast(@divTrunc(
            std.Io.Clock.awake.now(io).nanoseconds - started,
            std.time.ns_per_us,
        ));
    }
    std.mem.sort(i64, &durations, {}, std.sort.asc(i64));
    try writeOverviewEvidence(
        output,
        policy.strict_mode,
        last,
        durations[4],
        durations[9],
        durations[9],
        &durations,
    );
}

pub fn filtersV2(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
    site_slug: []const u8,
    current_start: []const u8,
    current_end: []const u8,
    comparison_start: []const u8,
    comparison_end: []const u8,
    profile: bool,
) !void {
    try domain.validateSlug(site_slug);
    const current = analysis.LocalDateRange{
        .start = current_start,
        .end = current_end,
    };
    const comparison = analysis.LocalDateRange{
        .start = comparison_start,
        .end = comparison_end,
    };
    try current.validate();
    try comparison.validate();
    const metadata_path = try std.fs.path.join(allocator, &.{ directory, "meta.db" });
    var metadata = try meta.Store.open(allocator, metadata_path);
    defer metadata.deinit();
    try metadata.requireCurrent();
    const site_id = try metadata.siteIdBySlug(allocator, site_slug);
    const goals = try metadata.listGoals(allocator, site_slug);
    const policy = try metadata.sitePolicy(allocator, site_id);
    const resolved = try allocator.alloc(analysis.ResolvedGoal, goals.len);
    for (resolved, goals) |*target, goal| target.* = .{
        .id = goal.id,
        .selector = .{
            .kind = switch (goal.match_kind) {
                .event => .exact_event,
                .path => .exact_page,
                .prefix => .page_prefix,
            },
            .value = goal.match_value,
            .predicates = goal.predicates,
        },
    };
    const event_path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, event_path);
    defer store.deinit();
    try store.requireCurrent();

    const filter_values = [_][]const u8{"desktop"};
    const filter_clauses = [_]analysis.Clause{.{
        .scope = .session,
        .field = .{ .kind = .device },
        .operator = .is,
        .scalar_type = .string,
        .values = &filter_values,
    }};
    const filters = analysis.FilterSet{ .clauses = &filter_clauses };
    const current_buckets = try overviewDayBuckets(allocator, current);
    const comparison_buckets = try overviewDayBuckets(allocator, comparison);
    const overview_execution = analysis.OverviewExecution{
        .site_id = site_id,
        .range = current,
        .comparison_range = comparison,
        .active_goals = resolved,
        .filters = filters,
        .strict_traffic_mode = policy.strict_mode,
        .daily_event_ceiling = policy.daily_event_ceiling,
        .trend = .{
            .metric = .visitors,
            .interval = .day,
            .current_buckets = current_buckets,
            .comparison_buckets = comparison_buckets,
        },
    };
    if (profile) {
        try output.writeAll(try analysis_store.profileOverview(
            allocator,
            &store,
            overview_execution,
        ));
        return;
    }

    var started = std.Io.Clock.awake.now(io).nanoseconds;
    const cold_overview = try analysis_store.executeOverview(
        allocator,
        &store,
        overview_execution,
    );
    const cold_overview_micros: i64 = @intCast(@divTrunc(
        std.Io.Clock.awake.now(io).nanoseconds - started,
        std.time.ns_per_us,
    ));
    std.debug.print("filtered cold Overview micros={d}\n", .{cold_overview_micros});
    var warm_overview_micros: [10]i64 = undefined;
    for (&warm_overview_micros) |*elapsed| {
        started = std.Io.Clock.awake.now(io).nanoseconds;
        _ = try analysis_store.executeOverview(allocator, &store, overview_execution);
        elapsed.* = @intCast(@divTrunc(
            std.Io.Clock.awake.now(io).nanoseconds - started,
            std.time.ns_per_us,
        ));
    }
    std.mem.sort(i64, &warm_overview_micros, {}, std.sort.asc(i64));
    std.debug.print("filtered warm Overview p95 micros={d}\n", .{
        warm_overview_micros[9],
    });

    const series = [_]analysis.Metric{.{ .kind = .visitors }};
    started = std.Io.Clock.awake.now(io).nanoseconds;
    const trend = try analysis_store.executeTrendSet(
        allocator,
        &store,
        .{
            .set = .{
                .site_id = site_id,
                .range = current,
                .comparison = .previous,
                .interval = .day,
                .series = &series,
                .filters = filters,
            },
            .comparison_range = comparison,
            .active_goals = resolved,
            .strict_traffic_mode = policy.strict_mode,
        },
    );
    const trend_micros: i64 = @intCast(@divTrunc(
        std.Io.Clock.awake.now(io).nanoseconds - started,
        std.time.ns_per_us,
    ));
    std.debug.print("filtered Trend micros={d}\n", .{trend_micros});

    const breakdown_query = analysis.Query{
        .site_id = site_id,
        .range = current,
        .mode = .breakdown,
        .metric = .{ .kind = .page_views },
        .dimension = .{ .kind = .page },
        .filters = filters,
    };
    started = std.Io.Clock.awake.now(io).nanoseconds;
    const breakdown = try analysis_store.executeBreakdownPage(
        allocator,
        &store,
        .{
            .query = breakdown_query,
            .active_goals = resolved,
            .strict_traffic_mode = policy.strict_mode,
        },
    );
    const breakdown_micros: i64 = @intCast(@divTrunc(
        std.Io.Clock.awake.now(io).nanoseconds - started,
        std.time.ns_per_us,
    ));
    std.debug.print("filtered Breakdown micros={d}\n", .{breakdown_micros});

    var suggestion_query = breakdown_query;
    suggestion_query.mode = .trend;
    suggestion_query.metric = .{ .kind = .visitors };
    suggestion_query.dimension = null;
    started = std.Io.Clock.awake.now(io).nanoseconds;
    const suggestions = try analysis_store.executeSuggestions(
        allocator,
        &store,
        .{
            .execution = .{
                .query = suggestion_query,
                .active_goals = resolved,
                .strict_traffic_mode = policy.strict_mode,
            },
            .scope = .event,
            .field = .{ .kind = .page },
            .scalar_type = .string,
            .search = "/",
        },
    );
    const suggestion_micros: i64 = @intCast(@divTrunc(
        std.Io.Clock.awake.now(io).nanoseconds - started,
        std.time.ns_per_us,
    ));
    std.debug.print("filtered suggestions micros={d}\n", .{suggestion_micros});

    try std.json.Stringify.value(.{
        .metric_version = analysis.metric_version,
        .strict_mode = policy.strict_mode,
        .filter = "session.device is desktop",
        .cold_overview_micros = cold_overview_micros,
        .warm_overview_sample_micros = warm_overview_micros,
        .warm_overview_p50_micros = warm_overview_micros[4],
        .warm_overview_p95_micros = warm_overview_micros[9],
        .warm_overview_p99_micros = warm_overview_micros[9],
        .overview_visitors = cold_overview.visitors.current,
        .trend_micros = trend_micros,
        .trend_points = trend.series[0].points.len,
        .breakdown_micros = breakdown_micros,
        .breakdown_rows = breakdown.breakdown.rows.len,
        .suggestion_micros = suggestion_micros,
        .suggestion_values = suggestions.values.len,
        .suggestion_has_more = suggestions.has_more,
    }, .{}, output);
    try output.writeByte('\n');
}

pub fn sessionList(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
    site_slug: []const u8,
    start_date: []const u8,
    end_date: []const u8,
    profile: bool,
) !void {
    try domain.validateSlug(site_slug);
    const range = analysis.LocalDateRange{
        .start = start_date,
        .end = end_date,
    };
    try range.validate();
    const metadata_path = try std.fs.path.join(
        allocator,
        &.{ directory, "meta.db" },
    );
    var metadata = try meta.Store.open(allocator, metadata_path);
    defer metadata.deinit();
    try metadata.requireCurrent();
    const site_id = try metadata.siteIdBySlug(allocator, site_slug);
    const goals = try metadata.listGoals(allocator, site_slug);
    const policy = try metadata.sitePolicy(allocator, site_id);
    const resolved = try allocator.alloc(analysis.ResolvedGoal, goals.len);
    for (resolved, goals) |*target, goal| target.* = .{
        .id = goal.id,
        .selector = .{
            .kind = switch (goal.match_kind) {
                .event => .exact_event,
                .path => .exact_page,
                .prefix => .page_prefix,
            },
            .value = goal.match_value,
            .predicates = goal.predicates,
        },
    };
    const request = analysis.SessionListRequest{
        .site_id = site_id,
        .range = range,
        .active_goals = resolved,
        .strict_traffic_mode = policy.strict_mode,
        .now_utc_micros = 1_800_000_000_000_000,
        .timeout_ms = analysis.maximum_timeout_ms,
    };
    const detail_request = analysis.SessionDetailRequest{
        .site_id = site_id,
        .session_id = "00000000-0000-4000-8000-00000000fb01",
        .active_goals = resolved,
        .now_utc_micros = request.now_utc_micros,
        .timeout_ms = request.timeout_ms,
    };
    var profile_request = request;
    profile_request.profile_person_key = "u:scale-user";
    var anonymous_profile_request = request;
    anonymous_profile_request.profile_person_key =
        "a:00000000-0000-4000-8000-00000000fa03";
    const event_path = try std.fs.path.join(
        allocator,
        &.{ directory, "events.duckdb" },
    );
    var store = try events.Store.open(allocator, event_path);
    defer store.deinit();
    try store.requireCurrent();
    if (profile) {
        try output.writeAll(try analysis_store.profileSessionList(
            allocator,
            &store,
            request,
        ));
        try output.writeAll(try analysis_store.profileSessionDetail(
            allocator,
            &store,
            detail_request,
        ));
        try output.writeAll(try analysis_store.profilePersonProfile(
            allocator,
            &store,
            profile_request,
        ));
        return;
    }
    if (builtin.mode == .debug) {
        const page = try analysis_store.executeSessionList(
            allocator,
            &store,
            request,
        );
        const detail = try analysis_store.executeSessionDetail(
            allocator,
            &store,
            detail_request,
        );
        const person = try analysis_store.executePersonProfile(
            allocator,
            &store,
            profile_request,
        );
        const anonymous_person = try analysis_store.executePersonProfile(
            allocator,
            &store,
            anonymous_profile_request,
        );
        try writeSessionListEvidence(
            output,
            policy.strict_mode,
            page,
            false,
            &.{},
            detail,
            person,
            anonymous_person,
            &.{},
            null,
            false,
            false,
            false,
            false,
        );
        return;
    }
    var timeout_request = request;
    timeout_request.timeout_ms = 1;
    if (analysis_store.executeSessionList(
        allocator,
        &store,
        timeout_request,
    )) |_| {
        return error.ExpectedSessionListTimeout;
    } else |err| if (err != error.AnalysisTimeout) return err;
    var timeout_detail = detail_request;
    timeout_detail.timeout_ms = 1;
    if (analysis_store.executeSessionDetail(
        allocator,
        &store,
        timeout_detail,
    )) |_| {
        return error.ExpectedSessionDetailTimeout;
    } else |err| if (err != error.AnalysisTimeout) return err;
    var timeout_profile = profile_request;
    timeout_profile.timeout_ms = 1;
    if (analysis_store.executePersonProfile(
        allocator,
        &store,
        timeout_profile,
    )) |_| {
        return error.ExpectedPersonProfileTimeout;
    } else |err| if (err != error.AnalysisTimeout) return err;

    _ = try analysis_store.executeSessionList(allocator, &store, request);
    var samples: [10]i64 = undefined;
    var last: analysis.SessionPage = undefined;
    for (&samples) |*elapsed| {
        const started = std.Io.Clock.awake.now(io).nanoseconds;
        last = try analysis_store.executeSessionList(
            allocator,
            &store,
            request,
        );
        elapsed.* = @intCast(@divTrunc(
            std.Io.Clock.awake.now(io).nanoseconds - started,
            std.time.ns_per_us,
        ));
    }
    std.mem.sort(i64, &samples, {}, std.sort.asc(i64));
    _ = try analysis_store.executeSessionDetail(
        allocator,
        &store,
        detail_request,
    );
    var detail_samples: [10]i64 = undefined;
    var detail: analysis.SessionDetail = undefined;
    for (&detail_samples) |*elapsed| {
        const started = std.Io.Clock.awake.now(io).nanoseconds;
        detail = try analysis_store.executeSessionDetail(
            allocator,
            &store,
            detail_request,
        );
        elapsed.* = @intCast(@divTrunc(
            std.Io.Clock.awake.now(io).nanoseconds - started,
            std.time.ns_per_us,
        ));
    }
    std.mem.sort(i64, &detail_samples, {}, std.sort.asc(i64));
    const profile_started = std.Io.Clock.awake.now(io).nanoseconds;
    const person = try analysis_store.executePersonProfile(
        allocator,
        &store,
        profile_request,
    );
    const profile_micros: i64 = @intCast(@divTrunc(
        std.Io.Clock.awake.now(io).nanoseconds - profile_started,
        std.time.ns_per_us,
    ));
    const anonymous_person = try analysis_store.executePersonProfile(
        allocator,
        &store,
        anonymous_profile_request,
    );
    try writeSessionListEvidence(
        output,
        policy.strict_mode,
        last,
        true,
        &samples,
        detail,
        person,
        anonymous_person,
        &detail_samples,
        profile_micros,
        true,
        true,
        true,
        true,
    );
    if (samples[9] >= 400_000) return error.SessionListPerformanceBudgetExceeded;
    if (detail_samples[9] >= 250_000) {
        return error.SessionDetailPerformanceBudgetExceeded;
    }
    if (profile_micros >= analysis.maximum_timeout_ms * 1_000) {
        return error.PersonProfilePerformanceBudgetExceeded;
    }
}

fn writeSessionListEvidence(
    output: *std.Io.Writer,
    strict_mode: bool,
    page: analysis.SessionPage,
    performance_enforced: bool,
    samples: []const i64,
    detail: analysis.SessionDetail,
    profile: analysis.PersonProfile,
    anonymous_profile: analysis.PersonProfile,
    detail_samples: []const i64,
    profile_micros: ?i64,
    timeout_interrupted: bool,
    connection_reused: bool,
    detail_timeout_interrupted: bool,
    profile_timeout_interrupted: bool,
) !void {
    var currencies: usize = 0;
    for (page.rows) |row| currencies += row.revenue.len;
    try std.json.Stringify.value(.{
        .strict_mode = strict_mode,
        .page_rows = page.rows.len,
        .has_more = page.has_more,
        .currency_rows = currencies,
        .performance_enforced = performance_enforced,
        .sample_micros = samples,
        .p50_micros = if (samples.len == 0) @as(?i64, null) else samples[4],
        .p95_micros = if (samples.len == 0) @as(?i64, null) else samples[9],
        .p99_micros = if (samples.len == 0) @as(?i64, null) else samples[9],
        .timeout_interrupted = timeout_interrupted,
        .connection_reused = connection_reused,
        .detail_timeline_rows = detail.timeline.len,
        .detail_has_more = detail.has_more,
        .detail_sample_micros = detail_samples,
        .detail_p50_micros = if (detail_samples.len == 0)
            @as(?i64, null)
        else
            detail_samples[4],
        .detail_p95_micros = if (detail_samples.len == 0)
            @as(?i64, null)
        else
            detail_samples[9],
        .profile_retained_sessions = profile.summary.sessions,
        .profile_linked_anonymous_ids = profile.summary.linked_anonymous_ids,
        .profile_context_rows = profile.sessions.rows.len,
        .anonymous_profile_retained_sessions = anonymous_profile.summary.sessions,
        .anonymous_profile_context_rows = anonymous_profile.sessions.rows.len,
        .anonymous_profile_linked_anonymous_ids = anonymous_profile.summary.linked_anonymous_ids,
        .profile_micros = profile_micros,
        .detail_timeout_interrupted = detail_timeout_interrupted,
        .profile_timeout_interrupted = profile_timeout_interrupted,
    }, .{}, output);
    try output.writeByte('\n');
}

fn overviewDayBuckets(
    allocator: std.mem.Allocator,
    range: analysis.LocalDateRange,
) ![]const analysis.OverviewBucket {
    var buckets: std.ArrayList(analysis.OverviewBucket) = .empty;
    var date = try timezone.Date.parse(range.start);
    const end = try timezone.Date.parse(range.end);
    while (date.dayNumber() <= end.dayNumber()) : (date = try date.addDays(1)) {
        const label = try date.format();
        try buckets.append(allocator, .{
            .label = try allocator.dupe(u8, &label),
        });
    }
    return buckets.toOwnedSlice(allocator);
}

fn writeOverviewEvidence(
    output: *std.Io.Writer,
    strict_mode: bool,
    result: analysis.OverviewResult,
    p50_micros: i64,
    p95_micros: i64,
    p99_micros: i64,
    sample_micros: []const i64,
) !void {
    try std.json.Stringify.value(.{
        .metric_version = analysis.metric_version,
        .strict_mode = strict_mode,
        .visitors = result.visitors.current,
        .comparison_visitors = result.visitors.comparison.?,
        .sessions = result.sessions.current,
        .comparison_sessions = result.sessions.comparison.?,
        .page_views = result.page_views.current,
        .engaged_sessions = result.engagement_rate.current.numerator,
        .conversion_matches = result.conversions.current,
        .converting_visitors = result.conversion_rate.current.numerator,
        .revenue_currencies = result.revenue.len,
        .legacy_people = result.completeness.legacy_people,
        .trend_points = result.details.?.trend.current.len,
        .comparison_trend_points = result.details.?.trend.comparison.?.len,
        .content_rows = result.details.?.content.len,
        .acquisition_rows = result.details.?.acquisition.len,
        .conversion_rows = result.details.?.conversions.len,
        .audience_rows = result.details.?.audience.len,
        .accepted_events = result.details.?.health.accepted_events,
        .query_elapsed_micros = p95_micros,
        .query_samples = sample_micros.len,
        .query_sample_micros = sample_micros,
        .query_p50_micros = p50_micros,
        .query_p95_micros = p95_micros,
        .query_p99_micros = p99_micros,
    }, .{}, output);
    try output.writeByte('\n');
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
