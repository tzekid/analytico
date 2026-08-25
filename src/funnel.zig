const std = @import("std");
const analysis = @import("analysis.zig");
const domain = @import("domain.zig");

pub const schema_version: u8 = 1;
pub const minimum_steps: usize = 2;
pub const maximum_steps: usize = 8;
pub const maximum_definition_bytes: usize = 8 * 1024;

pub const Order = enum {
    sequential,
    consecutive,

    pub fn name(self: Order) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) !Order {
        if (std.mem.eql(u8, value, "sequential")) return .sequential;
        if (std.mem.eql(u8, value, "consecutive")) return .consecutive;
        return error.InvalidFunnelOrder;
    }
};

pub const Scope = enum {
    sessions,
    visitors,

    pub fn name(self: Scope) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) !Scope {
        if (std.mem.eql(u8, value, "sessions")) return .sessions;
        if (std.mem.eql(u8, value, "visitors")) return .visitors;
        return error.InvalidFunnelScope;
    }
};

pub const Window = enum(u32) {
    same_session = 0,
    one_hour = 3_600,
    one_day = 86_400,
    seven_days = 604_800,
    thirty_days = 2_592_000,

    pub fn seconds(self: Window) u32 {
        return @backingInt(self);
    }

    pub fn fromSeconds(value: u32) !Window {
        return switch (value) {
            0 => .same_session,
            3_600 => .one_hour,
            86_400 => .one_day,
            604_800 => .seven_days,
            2_592_000 => .thirty_days,
            else => error.InvalidFunnelWindow,
        };
    }
};

pub const DirectStep = struct {
    selector: analysis.EventSelector,
};

pub const Step = union(enum) {
    direct: DirectStep,
    goal: []const u8,

    pub fn validate(self: Step) !void {
        switch (self) {
            .direct => |direct| {
                if (direct.selector.kind == .saved_goal) {
                    return error.InvalidFunnelStep;
                }
                try direct.selector.validate();
                for (direct.selector.predicates) |predicate| {
                    if (predicate.values.len > 1) {
                        return error.UnsupportedFunnelPredicateValues;
                    }
                }
            },
            .goal => |goal_id| try domain.validateUuid(goal_id),
        }
    }
};

pub const Definition = struct {
    order: Order = .sequential,
    scope: Scope = .sessions,
    window: Window = .same_session,
    steps: []const Step,

    pub fn validate(self: Definition) !void {
        if (self.steps.len < minimum_steps or self.steps.len > maximum_steps) {
            return error.InvalidFunnelLength;
        }
        for (self.steps) |step| try step.validate();
    }
};

pub const ResultRequest = struct {
    site_id: []const u8,
    range: analysis.LocalDateRange,
    comparison_range: ?analysis.LocalDateRange = null,
    order: Order,
    scope: Scope,
    window: Window,
    selectors: []const analysis.EventSelector,
    filters: analysis.FilterSet = .{},
    active_goals: []const analysis.ResolvedGoal = &.{},
    strict_traffic_mode: bool = false,
    timeout_ms: u32 = analysis.maximum_timeout_ms,

    pub fn validate(self: ResultRequest) !void {
        try domain.validateUuid(self.site_id);
        try self.range.validate();
        if (self.comparison_range) |range| try range.validate();
        if (self.selectors.len < minimum_steps or
            self.selectors.len > maximum_steps)
        {
            return error.InvalidFunnelLength;
        }
        for (self.selectors) |selector| {
            try selector.validate();
            if (selector.kind == .saved_goal) {
                return error.UnresolvedGoalSelector;
            }
        }
        try self.filters.validate();
        if (self.timeout_ms == 0 or self.timeout_ms > analysis.maximum_timeout_ms) {
            return error.InvalidAnalysisTimeout;
        }
        const resolved_execution = self.execution(self.range);
        try resolved_execution.validate();
    }

    pub fn execution(
        self: ResultRequest,
        range: analysis.LocalDateRange,
    ) analysis.Execution {
        return .{
            .query = .{
                .site_id = self.site_id,
                .range = range,
                .mode = .breakdown,
                .metric = .{ .kind = .page_views },
                .dimension = .{ .kind = .page },
                .filters = self.filters,
            },
            .active_goals = self.active_goals,
            .strict_traffic_mode = self.strict_traffic_mode,
            .timeout_ms = self.timeout_ms,
        };
    }
};

pub const IdentityCoverage = struct {
    persistent_step_one: i64,
    ephemeral_step_one: i64,
    legacy_step_one: i64,
};

pub const ResultStep = struct {
    step_index: u8,
    participants: i64,
    median_from_prior_micros: ?i64,
};

pub const Run = struct {
    entrants: i64,
    completions: i64,
    median_total_micros: ?i64,
    steps: []const ResultStep,
    identity_coverage: ?IdentityCoverage,

    pub fn validate(self: Run, expected_steps: usize, scope: Scope) !void {
        if (self.steps.len != expected_steps or expected_steps < minimum_steps or
            expected_steps > maximum_steps or self.entrants < 0 or
            self.completions < 0)
        {
            return error.InvalidFunnelResult;
        }
        var prior = self.entrants;
        for (self.steps, 0..) |step, index| {
            if (step.step_index != @as(u8, @intCast(index)) or
                step.participants < 0 or step.participants > prior or
                (index == 0 and step.median_from_prior_micros != null) or
                (index != 0 and
                    (step.participants == 0) !=
                        (step.median_from_prior_micros == null)) or
                (step.median_from_prior_micros orelse 0) < 0)
            {
                return error.InvalidFunnelResult;
            }
            prior = step.participants;
        }
        if (self.steps[0].participants != self.entrants or
            self.steps[self.steps.len - 1].participants != self.completions or
            (self.median_total_micros orelse 0) < 0 or
            (self.completions == 0) != (self.median_total_micros == null))
        {
            return error.InvalidFunnelResult;
        }
        switch (scope) {
            .sessions => if (self.identity_coverage != null) {
                return error.InvalidFunnelResult;
            },
            .visitors => {
                const coverage = self.identity_coverage orelse
                    return error.InvalidFunnelResult;
                if (coverage.persistent_step_one != self.entrants or
                    coverage.ephemeral_step_one < 0 or
                    coverage.legacy_step_one < 0)
                {
                    return error.InvalidFunnelResult;
                }
            },
        }
    }
};

pub const Result = struct {
    current: Run,
    comparison: ?Run,
};

pub const PreviewResult = struct {
    availability: []const analysis.FunnelAvailabilityRow,
    result: Result,
};

const JsonDefinition = struct {
    schema: u8,
    order: []const u8,
    scope: []const u8,
    window_seconds: u32,
    steps: []const JsonStep,
};

const JsonStep = struct {
    kind: []const u8,
    value: ?[]const u8 = null,
    predicates: []const []const u8 = &.{},
    goal_id: ?[]const u8 = null,
};

pub fn canonicalJson(
    allocator: std.mem.Allocator,
    definition: Definition,
) ![]u8 {
    try definition.validate();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const temporary = scratch.allocator();

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"schema\":1,\"order\":");
    try writeJsonString(&output.writer, definition.order.name());
    try output.writer.writeAll(",\"scope\":");
    try writeJsonString(&output.writer, definition.scope.name());
    try output.writer.print(",\"window_seconds\":{d},\"steps\":[", .{
        definition.window.seconds(),
    });
    for (definition.steps, 0..) |step, index| {
        if (index != 0) try output.writer.writeByte(',');
        switch (step) {
            .direct => |direct| {
                try output.writer.writeAll("{\"kind\":");
                try writeJsonString(&output.writer, direct.selector.kind.name());
                try output.writer.writeAll(",\"value\":");
                try writeJsonString(&output.writer, direct.selector.value);
                try output.writer.writeAll(",\"predicates\":[");
                const predicates = try canonicalPredicates(
                    temporary,
                    direct.selector.predicates,
                );
                for (predicates, 0..) |predicate, predicate_index| {
                    if (predicate_index != 0) try output.writer.writeByte(',');
                    try writeJsonString(&output.writer, predicate);
                }
                try output.writer.writeAll("]}");
            },
            .goal => |goal_id| {
                try output.writer.writeAll("{\"kind\":\"goal\",\"goal_id\":");
                try writeJsonString(&output.writer, goal_id);
                try output.writer.writeByte('}');
            },
        }
    }
    try output.writer.writeAll("]}");
    const encoded = try output.toOwnedSlice();
    if (encoded.len > maximum_definition_bytes) {
        allocator.free(encoded);
        return error.FunnelDefinitionTooLong;
    }
    return encoded;
}

pub fn parseExactCanonicalJson(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) !Definition {
    if (encoded.len == 0 or encoded.len > maximum_definition_bytes) {
        return error.FunnelDefinitionTooLong;
    }
    const state = std.json.parseFromSliceLeaky(
        JsonDefinition,
        allocator,
        encoded,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
    ) catch return error.InvalidFunnelDefinition;
    if (state.schema != schema_version) return error.UnsupportedFunnelDefinition;
    const steps = try allocator.alloc(Step, state.steps.len);
    for (state.steps, 0..) |step, index| {
        const kind = analysis.SelectorKind.parse(step.kind) catch
            return error.InvalidFunnelStep;
        steps[index] = if (kind == .saved_goal) value: {
            if (step.value != null or step.predicates.len != 0) {
                return error.InvalidFunnelStep;
            }
            break :value .{ .goal = step.goal_id orelse
                return error.InvalidFunnelStep };
        } else value: {
            if (step.goal_id != null) return error.InvalidFunnelStep;
            const predicates = try allocator.alloc(
                analysis.PropertyPredicate,
                step.predicates.len,
            );
            for (step.predicates, 0..) |predicate, predicate_index| {
                predicates[predicate_index] = analysis.parseFormPredicate(
                    allocator,
                    predicate,
                ) catch return error.InvalidFunnelPredicate;
            }
            break :value .{ .direct = .{ .selector = .{
                .kind = kind,
                .value = step.value orelse return error.InvalidFunnelStep,
                .predicates = predicates,
            } } };
        };
    }
    const definition = Definition{
        .order = try Order.parse(state.order),
        .scope = try Scope.parse(state.scope),
        .window = try Window.fromSeconds(state.window_seconds),
        .steps = steps,
    };
    try definition.validate();
    const normalized = try canonicalJson(allocator, definition);
    defer allocator.free(normalized);
    if (!std.mem.eql(u8, encoded, normalized)) {
        return error.NonCanonicalFunnelDefinition;
    }
    return definition;
}

pub fn legacyDefinition(
    allocator: std.mem.Allocator,
    steps: []const LegacyStep,
) !Definition {
    const result = try allocator.alloc(Step, steps.len);
    for (steps, 0..) |step, index| {
        try domain.validateName(step.name, 120);
        if (!std.mem.eql(u8, step.name, step.match_value)) {
            return error.InvalidLegacyFunnelStep;
        }
        result[index] = .{ .direct = .{ .selector = .{
            .kind = switch (step.match_kind) {
                .event => .exact_event,
                .path => .exact_page,
                .prefix => .page_prefix,
            },
            .value = step.match_value,
        } } };
    }
    const definition = Definition{ .steps = result };
    try definition.validate();
    return definition;
}

pub const LegacyStep = struct {
    name: []const u8,
    match_kind: domain.MatchKind,
    match_value: []const u8,
};

pub fn legacySteps(
    allocator: std.mem.Allocator,
    definition: Definition,
) ![]LegacyStep {
    try definition.validate();
    if (definition.order != .sequential or definition.scope != .sessions or
        definition.window != .same_session)
    {
        return error.UnsupportedLegacyFunnel;
    }
    const result = try allocator.alloc(LegacyStep, definition.steps.len);
    for (definition.steps, 0..) |step, index| {
        const direct = switch (step) {
            .direct => |value| value,
            .goal => return error.UnsupportedLegacyFunnel,
        };
        if (direct.selector.predicates.len != 0) {
            return error.UnsupportedLegacyFunnel;
        }
        result[index] = .{
            .name = direct.selector.value,
            .match_kind = switch (direct.selector.kind) {
                .exact_event => .event,
                .exact_page => .path,
                .page_prefix => .prefix,
                .saved_goal => unreachable,
            },
            .match_value = direct.selector.value,
        };
    }
    return result;
}

fn canonicalPredicates(
    allocator: std.mem.Allocator,
    predicates: []const analysis.PropertyPredicate,
) ![]const []const u8 {
    if (predicates.len > analysis.maximum_selector_predicates) {
        return error.TooManySelectorPredicates;
    }
    const encoded = try allocator.alloc([]const u8, predicates.len);
    for (predicates, 0..) |predicate, index| {
        encoded[index] = try analysis.canonicalPredicate(allocator, predicate);
    }
    std.mem.sort([]const u8, encoded, {}, stringLessThan);
    var length: usize = 0;
    for (encoded) |value| {
        if (length != 0 and std.mem.eql(u8, encoded[length - 1], value)) continue;
        encoded[length] = value;
        length += 1;
    }
    return encoded[0..length];
}

fn stringLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn writeJsonString(output: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, output);
}

test "funnel definition is exact canonical bounded JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const plan_values = [_][]const u8{"pro"};
    const predicates = [_]analysis.PropertyPredicate{
        .{
            .property_ref = .{ .name = "plan", .scalar_type = .string },
            .operator = .is,
            .values = &plan_values,
        },
        .{
            .property_ref = .{ .name = "amount", .scalar_type = .integer },
            .operator = .gte,
            .values = &.{"5"},
        },
    };
    const steps = [_]Step{
        .{ .direct = .{ .selector = .{
            .kind = .exact_page,
            .value = "/pricing/<safe>",
            .predicates = &.{ predicates[1], predicates[0], predicates[0] },
        } } },
        .{ .goal = "00000000-0000-4000-8000-000000000035" },
    };
    const encoded = try canonicalJson(allocator, .{
        .order = .consecutive,
        .scope = .visitors,
        .window = .seven_days,
        .steps = &steps,
    });
    try std.testing.expectEqualStrings(
        "{\"schema\":1,\"order\":\"consecutive\",\"scope\":\"visitors\"," ++
            "\"window_seconds\":604800,\"steps\":[{\"kind\":\"page\"," ++
            "\"value\":\"/pricing/<safe>\",\"predicates\":[" ++
            "\"amount~gte~integer~5\",\"plan~is~string~pro\"]}," ++
            "{\"kind\":\"goal\",\"goal_id\":" ++
            "\"00000000-0000-4000-8000-000000000035\"}]}",
        encoded,
    );
    const parsed = try parseExactCanonicalJson(allocator, encoded);
    try std.testing.expectEqual(Order.consecutive, parsed.order);
    try std.testing.expectEqual(Scope.visitors, parsed.scope);
    try std.testing.expectEqual(Window.seven_days, parsed.window);
    try std.testing.expectEqual(@as(usize, 2), parsed.steps.len);

    const noncanonical =
        "{\"schema\":1,\"order\":\"consecutive\",\"scope\":\"visitors\"," ++
        "\"window_seconds\":604800,\"steps\":[{\"kind\":\"page\"," ++
        "\"value\":\"/pricing/<safe>\",\"predicates\":[" ++
        "\"plan~is~string~pro\",\"amount~gte~integer~5\"]}," ++
        "{\"kind\":\"goal\",\"goal_id\":" ++
        "\"00000000-0000-4000-8000-000000000035\"}]}";
    try std.testing.expectError(
        error.NonCanonicalFunnelDefinition,
        parseExactCanonicalJson(allocator, noncanonical),
    );
    @memset(encoded, 0);
    try std.testing.expectEqualStrings(
        "/pricing/<safe>",
        parsed.steps[0].direct.selector.value,
    );
    try std.testing.expectEqualStrings(
        "00000000-0000-4000-8000-000000000035",
        parsed.steps[1].goal,
    );
    try std.testing.expectEqualStrings(
        "plan",
        parsed.steps[0].direct.selector.predicates[1].property_ref.name,
    );
}

test "funnel canonical shape separates goal references from direct UUID text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const uuid = "00000000-0000-4000-8000-000000000035";
    const steps = [_]Step{
        .{ .direct = .{ .selector = .{
            .kind = .exact_event,
            .value = uuid,
        } } },
        .{ .goal = uuid },
    };
    const encoded = try canonicalJson(allocator, .{ .steps = &steps });
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"value\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"goal_id\":\"") != null);

    const goal_with_predicates =
        "{\"schema\":1,\"order\":\"sequential\",\"scope\":\"sessions\"," ++
        "\"window_seconds\":0,\"steps\":[{\"kind\":\"goal\"," ++
        "\"predicates\":[],\"goal_id\":\"00000000-0000-4000-8000-000000000035\"}," ++
        "{\"kind\":\"event\",\"value\":\"signup\",\"predicates\":[]}]}";
    try std.testing.expectError(
        error.NonCanonicalFunnelDefinition,
        parseExactCanonicalJson(allocator, goal_with_predicates),
    );
}

test "funnel canonical document rejects individually valid oversized steps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = try allocator.alloc(u8, 1024);
    path[0] = '/';
    @memset(path[1..], 'x');
    var steps: [maximum_steps]Step = undefined;
    for (&steps) |*step| step.* = .{ .direct = .{ .selector = .{
        .kind = .exact_page,
        .value = path,
    } } };
    try std.testing.expectError(
        error.FunnelDefinitionTooLong,
        canonicalJson(allocator, .{ .steps = &steps }),
    );
}

test "legacy funnel conversion preserves compatible behavior and refuses richer definitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const legacy = [_]LegacyStep{
        .{ .name = "/", .match_kind = .path, .match_value = "/" },
        .{ .name = "signup", .match_kind = .event, .match_value = "signup" },
    };
    const definition = try legacyDefinition(allocator, &legacy);
    const restored = try legacySteps(allocator, definition);
    try std.testing.expectEqual(@as(usize, 2), restored.len);
    try std.testing.expectEqual(domain.MatchKind.path, restored[0].match_kind);
    try std.testing.expectEqualStrings("signup", restored[1].match_value);

    var changed = definition;
    changed.scope = .visitors;
    try std.testing.expectError(
        error.UnsupportedLegacyFunnel,
        legacySteps(allocator, changed),
    );
    const mismatched = [_]LegacyStep{
        .{ .name = "Home", .match_kind = .path, .match_value = "/" },
        legacy[1],
    };
    try std.testing.expectError(
        error.InvalidLegacyFunnelStep,
        legacyDefinition(allocator, &mismatched),
    );
}
