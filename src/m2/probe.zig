const std = @import("std");
const analysis = @import("../analysis.zig");
const domain = @import("../domain.zig");
const property = @import("../property.zig");
const rate_limit = @import("../http/rate_limit.zig");
const duckdb = @import("../store/duckdb.zig");
const events = @import("../store/events.zig");
const analysis_store = @import("../store/analysis.zig");
const properties = @import("../store/properties.zig");

const benchmark_site_id = "00000000-0000-4000-8000-000000000f10";
const benchmark_start_micros: i64 = 1_767_225_600_000_000;

pub fn rateTable(output: *std.Io.Writer) !void {
    var limiter = rate_limit.Limiter{};
    var accepted: usize = 0;
    var rejected: usize = 0;
    for (0..100_000) |index| {
        if (limiter.allow(@intCast(index + 1), 1_800_000_000)) {
            accepted += 1;
        } else {
            rejected += 1;
        }
    }
    if (accepted != rate_limit.max_buckets or
        rejected != 100_000 - rate_limit.max_buckets)
    {
        return error.RateTableInvariantFailed;
    }
    try output.print(
        "{{\"attempted\":100000,\"capacity\":{d},\"accepted\":{d},\"rejected\":{d}}}\n",
        .{ rate_limit.max_buckets, accepted, rejected },
    );
}

pub fn schema4Fixture(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    site_id: []const u8,
) !void {
    try domain.validateUuid(site_id);
    const path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, path);
    defer store.deinit();
    try store.migrateFixtureV4();
    if (try store.eventCount() != 0) return error.Schema4FixtureRequiresEmptyStore;
    var statement = try store.database.prepare(
        \\INSERT INTO events
        \\SELECT
        \\  4, 2, 2, CAST(v.event_id AS UUID), p.site_id,
        \\  1787184000000000 + v.position * 1000000,
        \\  1787184000000000 + v.position * 1000000,
        \\  DATE '2026-08-20', DATE '2026-08-20', 0,
        \\  1, 'page_view', v.path, v.label, 'migration.example',
        \\  CAST(v.anonymous_id AS UUID), 1, v.user_id,
        \\  CAST(v.session_id AS UUID), 0, v.exclusion_source_value = 0,
        \\  '', 'DE', 'en', v.browser, 'Linux', v.device,
        \\  '', '', '', '', '', '{}', '{}', CAST(NULL AS DECIMAL(18,6)), '',
        \\  0, 0, CAST(v.event_id AS BLOB), v.exclusion_source_value = 0,
        \\  repeat(substr(v.event_id, 36, 1), 64), v.exclusion_source_value
        \\FROM (VALUES
        \\  (1, '00000000-0000-4000-8000-000000000401',
        \\      '00000000-0000-4000-8000-000000000501',
        \\      '00000000-0000-4000-8000-000000000601',
        \\      '/human', 'Human', 'user-a', 'Chrome', 'desktop', 0),
        \\  (2, '00000000-0000-4000-8000-000000000402',
        \\      '00000000-0000-4000-8000-000000000502',
        \\      '00000000-0000-4000-8000-000000000602',
        \\      '/legacy-bot', 'Legacy bot', '', 'Other', 'bot', 0),
        \\  (3, '00000000-0000-4000-8000-000000000403',
        \\      '00000000-0000-4000-8000-000000000503',
        \\      '00000000-0000-4000-8000-000000000603',
        \\      '/tracker', 'Tracker exclusion', '', 'Chrome', 'desktop', 1),
        \\  (4, '00000000-0000-4000-8000-000000000404',
        \\      '00000000-0000-4000-8000-000000000504',
        \\      '00000000-0000-4000-8000-000000000604',
        \\      '/network', 'Network exclusion', '', 'Chrome', 'desktop', 2),
        \\  (5, '00000000-0000-4000-8000-000000000405',
        \\      '00000000-0000-4000-8000-000000000505',
        \\      '00000000-0000-4000-8000-000000000605',
        \\      '/both', 'Both exclusion', '', 'Chrome', 'desktop', 3),
        \\  (6, '00000000-0000-4000-8000-000000000406',
        \\      '00000000-0000-4000-8000-000000000506',
        \\      '00000000-0000-4000-8000-000000000606',
        \\      '/excluded-legacy-bot', 'Excluded legacy bot', '',
        \\      'Other', 'bot', 1)
        \\) v(position, event_id, anonymous_id, session_id, path, label,
        \\    user_id, browser, device, exclusion_source_value)
        \\CROSS JOIN (SELECT ?::VARCHAR AS site_id) p
    );
    defer statement.deinit();
    try statement.bindText(1, site_id);
    var result = try statement.execute();
    result.deinit();
    var link = try store.database.prepare(
        \\INSERT INTO identity_links VALUES (
        \\  ?, CAST('00000000-0000-4000-8000-000000000501' AS UUID),
        \\  'user-a', 1787184000000000,
        \\  CAST('00000000-0000-4000-8000-000000000401' AS UUID)
        \\)
    );
    defer link.deinit();
    try link.bindText(1, site_id);
    var link_result = try link.execute();
    link_result.deinit();
    try store.checkpoint();
    try output.writeAll("schema4 classifier fixture committed events=6 links=1\n");
}

pub fn inspectV2(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    site_id: []const u8,
    event_id: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, path);
    defer store.deinit();
    try store.requireCurrent();
    const inspected = try store.inspectV2(allocator, site_id, event_id);
    try std.json.Stringify.value(inspected, .{}, output);
    try output.writeByte('\n');
}

pub fn sessionTimeline(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    site_id: []const u8,
    session_id: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, path);
    defer store.deinit();
    try store.requireCurrent();
    const ids = try store.sessionTimelineIds(allocator, site_id, session_id);
    try std.json.Stringify.value(ids, .{}, output);
    try output.writeByte('\n');
}

pub fn identityLinkCount(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, path);
    defer store.deinit();
    try store.requireCurrent();
    var result = try store.database.query("SELECT count(*) FROM identity_links");
    defer result.deinit();
    if (result.rowCount() != 1 or result.columnCount() != 1) {
        return error.InvalidIdentityLinkCount;
    }
    try output.print("{d}\n", .{result.int64(0, 0)});
}

pub fn inspectPerson(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    site_id: []const u8,
    anonymous_id: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, path);
    defer store.deinit();
    try store.requireCurrent();
    const person = try store.resolvePerson(allocator, site_id, anonymous_id);
    try std.json.Stringify.value(person, .{}, output);
    try output.writeByte('\n');
}

pub fn timeBuckets(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    site_id: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, path);
    defer store.deinit();
    try store.requireCurrent();
    var statement = try store.database.prepare(
        \\SELECT received_at_utc_micros, CAST(received_date_utc AS VARCHAR),
        \\       CAST(site_local_date AS VARCHAR), site_utc_offset_minutes
        \\FROM events WHERE site_id = ?
        \\ORDER BY received_at_utc_micros, event_id
    );
    defer statement.deinit();
    try statement.bindText(1, site_id);
    var result = try statement.execute();
    defer result.deinit();
    if (result.columnCount() != 4) return error.InvalidTimeBuckets;
    for (0..result.rowCount()) |row| {
        const utc_date = try result.text(allocator, 1, row);
        const local_date = try result.text(allocator, 2, row);
        try output.print("{d}\t{s}\t{s}\t{d}\n", .{
            result.int64(0, row),
            utc_date,
            local_date,
            result.int64(3, row),
        });
    }
}

pub fn propertySemantics(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    site_id: []const u8,
    start_utc_micros: i64,
    end_utc_micros: i64,
) !void {
    const path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    var store = try events.Store.open(allocator, path);
    defer store.deinit();
    try store.requireCurrent();
    const event_window = properties.Window{
        .source = .event,
        .site_id = site_id,
        .start_utc_micros = start_utc_micros,
        .end_utc_micros = end_utc_micros,
    };
    const typed_query = properties.Query{
        .window = event_window,
        .property_name = "typed",
    };
    const high_query = properties.Query{
        .window = event_window,
        .property_name = "high",
    };
    const trait_query = properties.Query{
        .window = .{
            .source = .user_trait,
            .site_id = site_id,
            .start_utc_micros = start_utc_micros,
            .end_utc_micros = end_utc_micros,
        },
        .property_name = "typed",
    };
    const result = .{
        .catalog = try properties.discover(
            allocator,
            &store.database,
            event_window,
            property.max_result_rows,
        ),
        .filters = .{
            .string = try properties.countMatching(
                allocator,
                &store.database,
                typed_query,
                .{ .string = "14" },
            ),
            .integer = try properties.countMatching(
                allocator,
                &store.database,
                typed_query,
                .{ .integer = 14 },
            ),
            .decimal = try properties.countMatching(
                allocator,
                &store.database,
                typed_query,
                .{ .decimal = "14.25" },
            ),
            .boolean = try properties.countMatching(
                allocator,
                &store.database,
                typed_query,
                .{ .boolean = true },
            ),
            .null_value = try properties.countMatching(
                allocator,
                &store.database,
                typed_query,
                .{ .null = {} },
            ),
            .missing = try properties.countMatching(
                allocator,
                &store.database,
                typed_query,
                .{ .missing = {} },
            ),
        },
        .breakdown = try properties.breakdown(
            allocator,
            &store.database,
            typed_query,
            property.max_result_rows,
        ),
        .high_cardinality = try properties.breakdown(
            allocator,
            &store.database,
            high_query,
            3,
        ),
        .trait_breakdown = try properties.breakdown(
            allocator,
            &store.database,
            trait_query,
            property.max_result_rows,
        ),
    };
    try std.json.Stringify.value(result, .{}, output);
    try output.writeByte('\n');
}

pub fn propertyMillion(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" });
    if (std.Io.Dir.cwd().statFile(io, path, .{})) |_| {
        return error.PropertyBenchmarkRequiresNewStore;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    var store = try events.Store.open(allocator, path);
    defer store.deinit();
    try store.migrate();
    var existing = try store.database.query(
        \\SELECT
        \\  (SELECT count(*) FROM events) +
        \\  (SELECT count(*) FROM identity_links)
    );
    defer existing.deinit();
    if (existing.rowCount() != 1 or existing.columnCount() != 1 or
        existing.int64(0, 0) != 0)
    {
        return error.PropertyBenchmarkRequiresEmptyStore;
    }

    const seed_started = std.Io.Clock.awake.now(io).nanoseconds;
    try store.database.exec(
        \\INSERT INTO events (
        \\  event_schema_version, protocol_version, tracker_version,
        \\  event_id, site_id, received_at_utc_micros,
        \\  occurred_at_utc_micros, received_date_utc, site_local_date,
        \\  site_utc_offset_minutes, kind, event_name, path, page_title,
        \\  hostname, anonymous_id, identity_quality, user_id, session_id,
        \\  sequence, session_start, referrer_host, country_code, language,
        \\  browser_family, os_family, device_category, utm_source, utm_medium,
        \\  utm_campaign, utm_term, utm_content, properties_json,
        \\  user_traits_json, value_amount, value_currency, engagement_ms,
        \\  max_scroll_depth, visitor_day_id, visitor_day_start,
        \\  event_payload_digest, traffic_class, classifier_version, bot_rule,
        \\  signal_version, navigator_webdriver, trusted_interactions,
        \\  was_visible, was_prerendered, viewport_bucket,
        \\  beacon_timing_bucket, client_hint_consistency,
        \\  accept_language_present, network_day_id
        \\)
        \\SELECT
        \\  7, 2, 2,
        \\  CAST('00000000-0000-4000-8000-000000000f11' AS UUID),
        \\  '00000000-0000-4000-8000-000000000f10',
        \\  1767225600000000 + i * 1000,
        \\  1767225600000000 + i * 1000,
        \\  CAST('2026-01-01' AS DATE), CAST('2026-01-01' AS DATE), 0,
        \\  2, 'benchmark', '/', '', '',
        \\  CAST('00000000-0000-4000-8000-000000000f12' AS UUID),
        \\  1, '', CAST('00000000-0000-4000-8000-000000000f13' AS UUID),
        \\  CAST(i AS UINTEGER), i = 0, '', 'DE', '', 'Chrome', 'Linux',
        \\  'desktop', '', '', '', '', '',
        \\  '{"active":' || CASE WHEN i % 2 = 0 THEN 'true' ELSE 'false' END ||
        \\  ',"attempt":' || CAST(i % 100 AS VARCHAR) ||
        \\  ',"cohort":"c' || CAST(i % 12 AS VARCHAR) || '"' ||
        \\  ',"decimal":' || CAST(i % 10 AS VARCHAR) || '.250000' ||
        \\  ',"enabled":true' ||
        \\  ',"high":"h' || lpad(CAST(i % 100000 AS VARCHAR), 6, '0') || '"' ||
        \\  ',"integer":' || CAST(i % 1000 AS VARCHAR) ||
        \\  ',"mixed":' || CASE i % 4
        \\    WHEN 0 THEN '"alpha"'
        \\    WHEN 1 THEN '42'
        \\    WHEN 2 THEN '42.500000'
        \\    ELSE 'null'
        \\  END ||
        \\  ',"nullable":null' ||
        \\  CASE WHEN i % 2 = 0 THEN ',"optional":"present"' ELSE '' END ||
        \\  ',"plan":"' || CASE i % 4
        \\    WHEN 0 THEN 'free'
        \\    WHEN 1 THEN 'basic'
        \\    WHEN 2 THEN 'pro'
        \\    ELSE 'business'
        \\  END || '"' ||
        \\  ',"region":"r' || CAST(i % 8 AS VARCHAR) || '"}',
        \\  '{}', CAST(NULL AS DECIMAL(18,6)), '', 0, 0,
        \\  CAST('benchmark' AS BLOB), i = 0, '', 1, 2, '',
        \\  0, FALSE, 0, FALSE, FALSE, 0, 0, 0, FALSE,
        \\  from_hex('00000000000000000000000000000000')
        \\FROM range(1000000) rows(i);
    );
    try store.checkpoint();
    const seed_ms: i64 = @intCast(@divTrunc(
        std.Io.Clock.awake.now(io).nanoseconds - seed_started,
        std.time.ns_per_ms,
    ));

    const window = properties.Window{
        .source = .event,
        .site_id = benchmark_site_id,
        .start_utc_micros = benchmark_start_micros,
        .end_utc_micros = benchmark_start_micros + 2_000_000_000,
        .event_name = "benchmark",
    };
    const low_query = properties.Query{
        .window = window,
        .property_name = "plan",
    };
    _ = try properties.breakdown(
        allocator,
        &store.database,
        low_query,
        property.max_result_rows,
    );
    var samples: [10]i64 = undefined;
    var low_breakdown: properties.Breakdown = undefined;
    for (&samples) |*sample| {
        const started = std.Io.Clock.awake.now(io).nanoseconds;
        low_breakdown = try properties.breakdown(
            allocator,
            &store.database,
            low_query,
            property.max_result_rows,
        );
        sample.* = @intCast(@divTrunc(
            std.Io.Clock.awake.now(io).nanoseconds - started,
            std.time.ns_per_ms,
        ));
    }
    std.mem.sort(i64, &samples, {}, std.sort.asc(i64));

    const high_started = std.Io.Clock.awake.now(io).nanoseconds;
    const high_breakdown = try properties.breakdown(
        allocator,
        &store.database,
        .{ .window = window, .property_name = "high" },
        property.max_result_rows,
    );
    const high_ms: i64 = @intCast(@divTrunc(
        std.Io.Clock.awake.now(io).nanoseconds - high_started,
        std.time.ns_per_ms,
    ));
    const mixed = try properties.breakdown(
        allocator,
        &store.database,
        .{ .window = window, .property_name = "mixed" },
        property.max_result_rows,
    );
    const catalog = try properties.discover(
        allocator,
        &store.database,
        window,
        property.max_result_rows,
    );
    const typed_execution = analysis.Execution{ .query = .{
        .site_id = benchmark_site_id,
        .range = .{ .start = "2026-01-01", .end = "2026-01-01" },
        .mode = .breakdown,
        .metric = .{ .kind = .custom_events },
        .dimension = .{
            .kind = .event_property,
            .property_ref = .{ .name = "plan", .scalar_type = .string },
        },
        .limit = analysis.maximum_limit,
    } };
    const typed_cold_started = std.Io.Clock.awake.now(io).nanoseconds;
    _ = try analysis_store.executeBreakdownPage(
        allocator,
        &store,
        typed_execution,
    );
    const typed_cold_ms: i64 = @intCast(@divTrunc(
        std.Io.Clock.awake.now(io).nanoseconds - typed_cold_started,
        std.time.ns_per_ms,
    ));
    var typed_samples: [10]i64 = undefined;
    var typed_page: analysis.BreakdownPageResult = undefined;
    for (&typed_samples) |*sample| {
        const started = std.Io.Clock.awake.now(io).nanoseconds;
        typed_page = try analysis_store.executeBreakdownPage(
            allocator,
            &store,
            typed_execution,
        );
        sample.* = @intCast(@divTrunc(
            std.Io.Clock.awake.now(io).nanoseconds - started,
            std.time.ns_per_ms,
        ));
    }
    std.mem.sort(i64, &typed_samples, {}, std.sort.asc(i64));

    var ordinary_execution = typed_execution;
    ordinary_execution.query.dimension = .{ .kind = .event_name };
    _ = try analysis_store.executeBreakdownPage(
        allocator,
        &store,
        ordinary_execution,
    );
    var ordinary_samples: [10]i64 = undefined;
    for (&ordinary_samples) |*sample| {
        const started = std.Io.Clock.awake.now(io).nanoseconds;
        _ = try analysis_store.executeBreakdownPage(
            allocator,
            &store,
            ordinary_execution,
        );
        sample.* = @intCast(@divTrunc(
            std.Io.Clock.awake.now(io).nanoseconds - started,
            std.time.ns_per_ms,
        ));
    }
    std.mem.sort(i64, &ordinary_samples, {}, std.sort.asc(i64));

    var search_execution = typed_execution;
    search_execution.query.dimension.?.property_ref = .{
        .name = "high",
        .scalar_type = .string,
    };
    search_execution.query.search = "h09999";
    const search_started = std.Io.Clock.awake.now(io).nanoseconds;
    const searched = try analysis_store.executeBreakdownPage(
        allocator,
        &store,
        search_execution,
    );
    const search_ms: i64 = @intCast(@divTrunc(
        std.Io.Clock.awake.now(io).nanoseconds - search_started,
        std.time.ns_per_ms,
    ));

    var missing_execution = typed_execution;
    missing_execution.query.dimension.?.property_ref = .{
        .name = "optional",
        .scalar_type = .missing,
    };
    const missing = try analysis_store.executeBreakdownPage(
        allocator,
        &store,
        missing_execution,
    );
    var null_execution = typed_execution;
    null_execution.query.dimension.?.property_ref = .{
        .name = "nullable",
        .scalar_type = .null,
    };
    const null_value = try analysis_store.executeBreakdownPage(
        allocator,
        &store,
        null_execution,
    );
    var mixed_types: usize = 0;
    var sampled_plan_events: i64 = 0;
    for (typed_page.properties.entries) |entry| {
        if (std.mem.eql(u8, entry.name, "mixed")) mixed_types += 1;
        if (std.mem.eql(u8, entry.name, "plan") and
            entry.scalar_type == .string)
        {
            sampled_plan_events = entry.event_count;
        }
    }
    const filters = .{
        .string = try properties.countMatching(
            allocator,
            &store.database,
            .{ .window = window, .property_name = "plan" },
            .{ .string = "pro" },
        ),
        .integer = try properties.countMatching(
            allocator,
            &store.database,
            .{ .window = window, .property_name = "integer" },
            .{ .integer = 42 },
        ),
        .decimal = try properties.countMatching(
            allocator,
            &store.database,
            .{ .window = window, .property_name = "decimal" },
            .{ .decimal = "2.25" },
        ),
        .boolean = try properties.countMatching(
            allocator,
            &store.database,
            .{ .window = window, .property_name = "active" },
            .{ .boolean = true },
        ),
        .null_value = try properties.countMatching(
            allocator,
            &store.database,
            .{ .window = window, .property_name = "nullable" },
            .{ .null = {} },
        ),
        .missing = try properties.countMatching(
            allocator,
            &store.database,
            .{ .window = window, .property_name = "optional" },
            .{ .missing = {} },
        ),
    };
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const result = .{
        .duckdb_version = duckdb.Database.version(),
        .events = 1_000_000,
        .properties = 12,
        .seed_ms = seed_ms,
        .database_bytes = stat.size,
        .catalog = catalog,
        .filters = filters,
        .mixed = mixed,
        .low_breakdown = .{
            .rows = low_breakdown.rows.len,
            .bucket_count = low_breakdown.bucket_count,
            .samples = samples.len,
            .p50_ms = samples[4],
            .p95_ms = samples[9],
            .p99_ms = samples[9],
        },
        .high_breakdown = .{
            .rows = high_breakdown.rows.len,
            .bucket_count = high_breakdown.bucket_count,
            .truncated = high_breakdown.truncated,
            .elapsed_ms = high_ms,
        },
        .metric_v2_breakdown = .{
            .rows = typed_page.breakdown.rows.len,
            .cardinality = typed_page.breakdown.cardinality,
            .property_count = typed_page.properties.property_count,
            .mixed_types = mixed_types,
            .sampled_plan_events = sampled_plan_events,
            .samples = typed_samples.len,
            .cold_ms = typed_cold_ms,
            .p50_ms = typed_samples[4],
            .p95_ms = typed_samples[9],
            .p99_ms = typed_samples[9],
            .ordinary_p95_ms = ordinary_samples[9],
            .search_rows = searched.breakdown.rows.len,
            .search_cardinality = searched.breakdown.cardinality,
            .search_ms = search_ms,
            .missing_events = missing.breakdown.rows[0].measure.count,
            .null_events = null_value.breakdown.rows[0].measure.count,
        },
    };
    try std.json.Stringify.value(result, .{}, output);
    try output.writeByte('\n');
}
