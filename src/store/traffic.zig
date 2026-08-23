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
        "site_product_events AS (SELECT e.*, CASE" ++
            " WHEN e.identity_quality = 1 AND COALESCE(l.user_id, e.user_id, '') <> ''" ++
            " THEN 'u:' || COALESCE(l.user_id, e.user_id)" ++
            " WHEN e.identity_quality = 1 THEN 'a:' || CAST(e.anonymous_id AS VARCHAR)" ++
            " ELSE '' END AS d34_person_key" ++
            " FROM events e LEFT JOIN identity_links l" ++
            " ON l.site_id = e.site_id AND l.anonymous_id = e.anonymous_id" ++
            " WHERE e.site_id = ? AND e.traffic_class IN (1, 5))," ++
            " d34_first_meaningful AS (SELECT * EXCLUDE (d34_position) FROM (" ++
            " SELECT e.*, row_number() OVER (PARTITION BY session_id" ++
            " ORDER BY occurred_at_utc_micros, sequence," ++
            " received_at_utc_micros, event_id) AS d34_position" ++
            " FROM site_product_events e WHERE kind IN (1, 2)) ranked" ++
            " WHERE d34_position = 1)," ++
            " d34_session_summary AS (SELECT session_id," ++
            " count(*) FILTER (WHERE kind IN (1, 2))::BIGINT AS meaningful_events," ++
            " bit_or(trusted_interactions)::BIGINT AS trusted_interactions," ++
            " sum(engagement_ms)::BIGINT AS engagement_ms," ++
            " max(max_scroll_depth)::BIGINT AS max_scroll_depth" ++
            " FROM site_product_events GROUP BY session_id)," ++
            " d34_raw_candidates AS (SELECT f.* FROM d34_first_meaningful f" ++
            " WHERE ? = 1 AND f.traffic_class = 1 AND f.signal_version = 1" ++
            " AND f.trusted_interactions = 0 AND f.engagement_ms = 0" ++
            " AND f.max_scroll_depth = 0 AND" ++
            " ((f.beacon_timing_bucket = 1)::INTEGER +" ++
            "  (f.viewport_bucket = 1)::INTEGER +" ++
            "  (NOT f.was_visible)::INTEGER +" ++
            "  (f.client_hint_consistency = 3)::INTEGER +" ++
            "  (NOT f.accept_language_present)::INTEGER) >= 2)," ++
            " d34_candidate_verdicts AS (SELECT c.session_id," ++
            " (s.meaningful_events != 1 OR s.trusted_interactions != 0" ++
            " OR s.engagement_ms != 0 OR s.max_scroll_depth != 0 OR ",
    );
    try bindings.append(allocator, .{ .text = site_id });
    try bindings.append(allocator, .{ .integer = @intFromBool(available) });
    try writeGoalExists(&output.writer, allocator, &bindings, goals, "c.session_id");
    try output.writer.writeAll(
        " OR (c.identity_quality = 1 AND c.d34_person_key != '' AND EXISTS (" ++
            " SELECT 1 FROM site_product_events r" ++
            " WHERE r.kind IN (1, 2) AND r.identity_quality = 1" ++
            " AND r.d34_person_key = c.d34_person_key" ++
            " AND r.session_id != c.session_id))) AS contradicted" ++
            " FROM d34_raw_candidates c" ++
            " JOIN d34_session_summary s USING (session_id))," ++
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
    try output.writeAll("EXISTS (SELECT 1 FROM site_product_events g WHERE g.session_id = ");
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
