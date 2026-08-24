const std = @import("std");
const domain = @import("../domain.zig");

pub const classifier_version: u8 = 1;
pub const identity_mint_threshold: i64 = 64;

pub const Goal = struct {
    kind: domain.MatchKind,
    value: []const u8,
};

pub const Binding = union(enum) {
    text: []const u8,
    integer: i64,
};

pub const Fragment = struct {
    sql: []const u8,
    bindings: []const Binding,
};

pub fn classifierFragment(
    allocator: std.mem.Allocator,
    site_id: []const u8,
    goals: []const Goal,
    available: bool,
) !Fragment {
    try domain.validateUuid(site_id);
    if (goals.len > 32) return error.TooManyActiveGoals;
    var output = std.Io.Writer.Allocating.init(allocator);
    var bindings: std.ArrayList(Binding) = .empty;
    try output.writer.writeAll(
        "site_product_events AS NOT MATERIALIZED (SELECT e.* FROM events e" ++
            " WHERE e.site_id = ? AND e.traffic_class IN (1, 5))," ++
            " d34_signal_sessions AS (SELECT DISTINCT session_id" ++
            " FROM site_product_events WHERE signal_version = 1)," ++
            " d34_signal_events AS MATERIALIZED (SELECT e.site_id," ++
            " e.received_date_utc, e.event_id, e.received_at_utc_micros," ++
            " e.occurred_at_utc_micros, e.anonymous_id, e.user_id," ++
            " e.session_id, e.sequence, e.identity_quality, e.traffic_class," ++
            " e.signal_version, e.trusted_interactions, e.engagement_ms," ++
            " e.max_scroll_depth, e.viewport_bucket, e.beacon_timing_bucket," ++
            " e.was_visible, e.client_hint_consistency," ++
            " e.accept_language_present, e.kind, e.event_name, e.path" ++
            " FROM site_product_events e JOIN d34_signal_sessions s" ++
            " USING (session_id))," ++
            " d34_first_meaningful AS (SELECT * EXCLUDE (d34_position) FROM (" ++
            " SELECT e.site_id, e.received_date_utc, e.event_id," ++
            " e.received_at_utc_micros, e.occurred_at_utc_micros," ++
            " e.anonymous_id, e.user_id, e.session_id, e.sequence," ++
            " e.identity_quality, e.traffic_class, e.signal_version," ++
            " e.trusted_interactions, e.engagement_ms, e.max_scroll_depth," ++
            " e.viewport_bucket, e.beacon_timing_bucket, e.was_visible," ++
            " e.client_hint_consistency, e.accept_language_present," ++
            " row_number() OVER (PARTITION BY session_id" ++
            " ORDER BY occurred_at_utc_micros, sequence," ++
            " received_at_utc_micros, event_id) AS d34_position" ++
            " FROM d34_signal_events e WHERE kind IN (1, 2)) ranked" ++
            " WHERE d34_position = 1)," ++
            " d34_session_summary AS (SELECT session_id," ++
            " count(*) FILTER (WHERE kind IN (1, 2))::BIGINT AS meaningful_events," ++
            " bit_or(trusted_interactions)::BIGINT AS trusted_interactions," ++
            " sum(engagement_ms)::BIGINT AS engagement_ms," ++
            " max(max_scroll_depth)::BIGINT AS max_scroll_depth" ++
            " FROM d34_signal_events GROUP BY session_id)," ++
            " d34_raw_candidates AS (SELECT f.session_id," ++
            " f.received_date_utc, f.identity_quality, CASE" ++
            " WHEN f.identity_quality = 1 AND COALESCE(l.user_id, f.user_id, '') <> ''" ++
            " THEN 'u:' || COALESCE(l.user_id, f.user_id)" ++
            " WHEN f.identity_quality = 1 THEN 'a:' || CAST(f.anonymous_id AS VARCHAR)" ++
            " ELSE '' END AS d34_person_key" ++
            " FROM d34_first_meaningful f LEFT JOIN identity_links l" ++
            " ON l.site_id = f.site_id AND l.anonymous_id = f.anonymous_id" ++
            " WHERE ? = 1 AND f.traffic_class = 1 AND f.signal_version = 1" ++
            " AND f.trusted_interactions = 0 AND f.engagement_ms = 0" ++
            " AND f.max_scroll_depth = 0 AND" ++
            " ((f.beacon_timing_bucket = 1)::INTEGER +" ++
            "  (f.viewport_bucket = 1)::INTEGER +" ++
            "  (NOT f.was_visible)::INTEGER +" ++
            "  (f.client_hint_consistency = 3)::INTEGER +" ++
            "  (NOT f.accept_language_present)::INTEGER) >= 2)," ++
            " d34_persistent_candidates AS MATERIALIZED (SELECT session_id," ++
            " d34_person_key FROM d34_raw_candidates" ++
            " WHERE identity_quality = 1 AND d34_person_key != '')," ++
            " d34_cross_session_contradictions AS MATERIALIZED (" ++
            " SELECT c.session_id FROM d34_persistent_candidates c" ++
            " JOIN site_product_events r ON r.kind IN (1, 2)" ++
            " AND r.identity_quality = 1 AND r.session_id != c.session_id" ++
            " LEFT JOIN identity_links rl ON rl.site_id = r.site_id" ++
            " AND rl.anonymous_id = r.anonymous_id WHERE CASE" ++
            " WHEN COALESCE(rl.user_id, r.user_id, '') <> ''" ++
            " THEN 'u:' || COALESCE(rl.user_id, r.user_id)" ++
            " ELSE 'a:' || CAST(r.anonymous_id AS VARCHAR) END" ++
            " = c.d34_person_key GROUP BY c.session_id)," ++
            " d34_candidate_verdicts AS (SELECT c.session_id," ++
            " (s.meaningful_events != 1 OR s.trusted_interactions != 0" ++
            " OR s.engagement_ms != 0 OR s.max_scroll_depth != 0 OR ",
    );
    try bindings.append(allocator, .{ .text = site_id });
    try bindings.append(allocator, .{ .integer = @intFromBool(available) });
    try writeGoalExists(&output.writer, allocator, &bindings, goals, "c.session_id");
    try output.writer.writeAll(
        " OR x.session_id IS NOT NULL) AS contradicted" ++
            " FROM d34_raw_candidates c" ++
            " JOIN d34_session_summary s USING (session_id)" ++
            " LEFT JOIN d34_cross_session_contradictions x" ++
            " ON x.session_id = c.session_id)," ++
            " d34_current_suspected_sessions AS (SELECT session_id" ++
            " FROM d34_candidate_verdicts WHERE NOT contradicted)",
    );
    return .{
        .sql = try output.toOwnedSlice(),
        .bindings = try bindings.toOwnedSlice(allocator),
    };
}

fn writeGoalExists(
    output: *std.Io.Writer,
    allocator: std.mem.Allocator,
    bindings: *std.ArrayList(Binding),
    goals: []const Goal,
    session_expression: []const u8,
) !void {
    if (goals.len == 0) return output.writeAll("FALSE");
    try output.writeAll("EXISTS (SELECT 1 FROM d34_signal_events g WHERE g.session_id = ");
    try output.writeAll(session_expression);
    try output.writeAll(" AND g.kind IN (1, 2) AND (");
    for (goals, 0..) |goal, index| {
        if (index != 0) try output.writeAll(" OR ");
        switch (goal.kind) {
            .event => try output.writeAll("g.event_name = ?"),
            .path => try output.writeAll("g.path = ?"),
            .prefix => try output.writeAll("starts_with(g.path, ?)"),
        }
        try bindings.append(allocator, .{ .text = goal.value });
    }
    try output.writeAll("))");
}

test "query classifier fragment binds site and bounded goals without input SQL" {
    const allocator = std.testing.allocator;
    const fragment = try classifierFragment(
        allocator,
        "00000000-0000-4000-8000-000000000070",
        &.{.{ .kind = .event, .value = "purchase" }},
        true,
    );
    defer allocator.free(fragment.sql);
    defer allocator.free(fragment.bindings);
    try std.testing.expectEqual(@as(usize, 3), fragment.bindings.len);
    try std.testing.expect(std.mem.indexOf(u8, fragment.sql, "purchase") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        fragment.sql,
        "d34_current_suspected_sessions",
    ) != null);
}
