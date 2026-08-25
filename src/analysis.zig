const std = @import("std");
const domain = @import("domain.zig");
const property = @import("property.zig");
const report = @import("report.zig");

pub const query_schema_version: u8 = 1;
pub const metric_version: u8 = 2;
pub const maximum_range_days: u16 = 400;
pub const maximum_clauses: u8 = 12;
pub const maximum_values: u8 = 20;
pub const maximum_selector_predicates: u8 = 3;
pub const maximum_active_goals: u8 = 32;
pub const maximum_series: u8 = 3;
pub const maximum_currency_series: u8 = 16;
pub const maximum_trend_rows: u16 = maximum_range_days * maximum_currency_series;
pub const maximum_limit: u16 = 100;
pub const maximum_page: u32 = 1_000_000;
pub const maximum_url_bytes: usize = 16 * 1024;
pub const maximum_json_bytes: usize = 32 * 1024;
pub const maximum_url_parameters: u8 = 32;
pub const maximum_timeout_ms: u32 = 2_000;
pub const maximum_filter_value_bytes: usize = 1_024;
pub const maximum_search_bytes: usize = 256;
pub const maximum_property_names: u16 = 100;
pub const maximum_property_catalog_events: u32 = 2_000;
pub const maximum_suggestions: u8 = 50;
pub const maximum_goal_path_rows: u8 = 10;

pub const LocalDateRange = struct {
    start: []const u8,
    end: []const u8,

    pub fn validate(self: LocalDateRange) !void {
        try domain.validateDate(self.start);
        try domain.validateDate(self.end);
        const start_day = try report.dateDay(self.start);
        const end_day = try report.dateDay(self.end);
        if (end_day < start_day or end_day - start_day + 1 > maximum_range_days) {
            return error.InvalidAnalysisRange;
        }
    }

    pub fn days(self: LocalDateRange) !u32 {
        try self.validate();
        return try report.dateDay(self.end) - try report.dateDay(self.start) + 1;
    }
};

pub const Comparison = enum {
    none,
    previous,
    previous_year,

    pub fn name(self: Comparison) []const u8 {
        return switch (self) {
            .none => "none",
            .previous => "previous",
            .previous_year => "previous-year",
        };
    }

    pub fn parse(value: []const u8) !Comparison {
        inline for (@typeInfo(Comparison).@"enum".field_values) |raw| {
            const candidate: Comparison = @fromBackingInt(@intCast(raw));
            if (std.mem.eql(u8, value, candidate.name())) return candidate;
        }
        return error.InvalidAnalysisComparison;
    }
};

pub const Mode = enum {
    trend,
    breakdown,

    pub fn name(self: Mode) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) !Mode {
        return std.meta.stringToEnum(Mode, value) orelse
            error.InvalidAnalysisMode;
    }
};

pub const Interval = enum {
    auto,
    hour,
    day,
    week,
    month,

    pub fn name(self: Interval) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) !Interval {
        return std.meta.stringToEnum(Interval, value) orelse
            error.InvalidAnalysisInterval;
    }
};

pub fn automaticInterval(range: LocalDateRange) !Interval {
    const days = try range.days();
    if (days <= 2) return .hour;
    if (days <= 90) return .day;
    return .week;
}

test "automatic interval follows the bounded visualization contract" {
    try std.testing.expectEqual(Interval.hour, try automaticInterval(.{
        .start = "2025-01-01",
        .end = "2025-01-02",
    }));
    try std.testing.expectEqual(Interval.day, try automaticInterval(.{
        .start = "2025-01-01",
        .end = "2025-03-31",
    }));
    try std.testing.expectEqual(Interval.week, try automaticInterval(.{
        .start = "2025-01-01",
        .end = "2025-04-01",
    }));
    try std.testing.expectEqual(Interval.week, try automaticInterval(.{
        .start = "1970-01-01",
        .end = "1971-02-04",
    }));
}

pub const Sort = enum {
    value_desc,
    value_asc,
    label_asc,
    label_desc,

    pub fn name(self: Sort) []const u8 {
        return switch (self) {
            .value_desc => "value-desc",
            .value_asc => "value-asc",
            .label_asc => "label-asc",
            .label_desc => "label-desc",
        };
    }

    pub fn parse(value: []const u8) !Sort {
        inline for (@typeInfo(Sort).@"enum".field_values) |raw| {
            const candidate: Sort = @fromBackingInt(@intCast(raw));
            if (std.mem.eql(u8, value, candidate.name())) return candidate;
        }
        return error.InvalidAnalysisSort;
    }
};

pub const MetricKind = enum {
    visitors,
    new_visitors,
    returning_visitors,
    sessions,
    engaged_sessions,
    engagement_rate,
    bounce_rate,
    page_views,
    custom_events,
    conversions,
    conversion_rate,
    revenue,
    average_value,
    event_count,
    event_visitors,

    pub fn name(self: MetricKind) []const u8 {
        return switch (self) {
            .visitors => "visitors",
            .new_visitors => "new-visitors",
            .returning_visitors => "returning-visitors",
            .sessions => "sessions",
            .engaged_sessions => "engaged-sessions",
            .engagement_rate => "engagement-rate",
            .bounce_rate => "bounce-rate",
            .page_views => "page-views",
            .custom_events => "custom-events",
            .conversions => "conversions",
            .conversion_rate => "conversion-rate",
            .revenue => "revenue",
            .average_value => "average-value",
            .event_count => "event-count",
            .event_visitors => "event-visitors",
        };
    }

    pub fn parse(value: []const u8) !MetricKind {
        inline for (@typeInfo(MetricKind).@"enum".field_values) |raw| {
            const candidate: MetricKind = @fromBackingInt(@intCast(raw));
            if (std.mem.eql(u8, value, candidate.name())) return candidate;
        }
        return error.InvalidAnalysisMetric;
    }

    pub fn requiresSelector(self: MetricKind) bool {
        return switch (self) {
            .conversions,
            .conversion_rate,
            .event_count,
            .event_visitors,
            => true,
            else => false,
        };
    }

    pub fn permitsSelector(self: MetricKind) bool {
        return self.requiresSelector() or self == .revenue or
            self == .average_value;
    }
};

pub const ConversionBasis = enum {
    event,
    visitor,
    session,

    pub fn name(self: ConversionBasis) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) !ConversionBasis {
        return std.meta.stringToEnum(ConversionBasis, value) orelse
            error.InvalidConversionBasis;
    }
};

pub const DimensionKind = enum {
    page,
    landing_page,
    exit_page,
    hostname,
    channel,
    referrer,
    utm_source,
    utm_medium,
    utm_campaign,
    utm_term,
    utm_content,
    country,
    language,
    device,
    browser,
    operating_system,
    event_name,
    event_property,

    pub fn name(self: DimensionKind) []const u8 {
        return switch (self) {
            .page => "page",
            .landing_page => "landing-page",
            .exit_page => "exit-page",
            .hostname => "hostname",
            .channel => "channel",
            .referrer => "referrer",
            .utm_source => "utm-source",
            .utm_medium => "utm-medium",
            .utm_campaign => "utm-campaign",
            .utm_term => "utm-term",
            .utm_content => "utm-content",
            .country => "country",
            .language => "language",
            .device => "device",
            .browser => "browser",
            .operating_system => "operating-system",
            .event_name => "event-name",
            .event_property => "event-property",
        };
    }

    pub fn parse(value: []const u8) !DimensionKind {
        inline for (@typeInfo(DimensionKind).@"enum".field_values) |raw| {
            const candidate: DimensionKind = @fromBackingInt(@intCast(raw));
            if (std.mem.eql(u8, value, candidate.name())) return candidate;
        }
        return error.InvalidAnalysisDimension;
    }
};

pub const ScalarType = enum {
    string,
    integer,
    decimal,
    boolean,
    null,
    missing,

    pub fn name(self: ScalarType) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) !ScalarType {
        return std.meta.stringToEnum(ScalarType, value) orelse
            error.InvalidAnalysisScalarType;
    }
};

pub const PropertyRef = struct {
    name: []const u8,
    scalar_type: ScalarType,

    pub fn validate(self: PropertyRef) !void {
        try domain.validateIdentifier(self.name);
    }
};

pub const Dimension = struct {
    kind: DimensionKind,
    property_ref: ?PropertyRef = null,

    pub fn validate(self: Dimension) !void {
        if (self.kind == .event_property) {
            try (self.property_ref orelse
                return error.MissingAnalysisProperty).validate();
        } else if (self.property_ref != null) {
            return error.UnexpectedAnalysisProperty;
        }
    }
};

pub const Operator = enum {
    is,
    is_not,
    contains,
    not_contains,
    starts_with,
    gt,
    gte,
    lt,
    lte,
    is_true,
    is_false,
    exists,
    absent,

    pub fn name(self: Operator) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) !Operator {
        return std.meta.stringToEnum(Operator, value) orelse
            error.InvalidAnalysisOperator;
    }
};

pub const Scope = enum {
    event,
    session,
    person,

    pub fn name(self: Scope) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) !Scope {
        return std.meta.stringToEnum(Scope, value) orelse
            error.InvalidAnalysisScope;
    }
};

pub const FieldKind = enum {
    page,
    page_title,
    hostname,
    landing_page,
    exit_page,
    channel,
    referrer,
    utm_source,
    utm_medium,
    utm_campaign,
    utm_term,
    utm_content,
    country,
    language,
    device,
    browser,
    operating_system,
    event_name,
    event_property,
    user_trait,
    identity_state,
    session_converted,
    session_duration_ms,
    session_engagement_ms,

    pub fn name(self: FieldKind) []const u8 {
        return switch (self) {
            .page => "page",
            .page_title => "page-title",
            .hostname => "hostname",
            .landing_page => "landing-page",
            .exit_page => "exit-page",
            .channel => "channel",
            .referrer => "referrer",
            .utm_source => "utm-source",
            .utm_medium => "utm-medium",
            .utm_campaign => "utm-campaign",
            .utm_term => "utm-term",
            .utm_content => "utm-content",
            .country => "country",
            .language => "language",
            .device => "device",
            .browser => "browser",
            .operating_system => "operating-system",
            .event_name => "event-name",
            .event_property => "event-property",
            .user_trait => "user-trait",
            .identity_state => "identity-state",
            .session_converted => "session-converted",
            .session_duration_ms => "session-duration-ms",
            .session_engagement_ms => "session-engagement-ms",
        };
    }

    pub fn parse(value: []const u8) !FieldKind {
        inline for (@typeInfo(FieldKind).@"enum".field_values) |raw| {
            const candidate: FieldKind = @fromBackingInt(@intCast(raw));
            if (std.mem.eql(u8, value, candidate.name())) return candidate;
        }
        return error.InvalidAnalysisField;
    }

    pub fn requiresProperty(self: FieldKind) bool {
        return self == .event_property or self == .user_trait;
    }
};

pub const Field = struct {
    kind: FieldKind,
    property_ref: ?PropertyRef = null,

    pub fn validate(self: Field) !void {
        if (self.kind.requiresProperty()) {
            try (self.property_ref orelse
                return error.MissingAnalysisProperty).validate();
        } else if (self.property_ref != null) {
            return error.UnexpectedAnalysisProperty;
        }
    }
};

pub const Clause = struct {
    scope: Scope,
    field: Field,
    operator: Operator,
    scalar_type: ScalarType,
    values: []const []const u8 = &.{},

    pub fn validate(self: Clause) !void {
        try self.field.validate();
        try validateFieldScope(self.field.kind, self.scope);
        try validateFieldType(self.field, self.scalar_type);
        try validateOperator(self.operator, self.scalar_type, self.values.len);
        if (self.values.len > maximum_values) return error.TooManyAnalysisValues;
        for (self.values) |value| try validateValue(self.scalar_type, value);
        if (self.field.kind == .identity_state) {
            for (self.values) |value| {
                if (!std.mem.eql(u8, value, "identified") and
                    !std.mem.eql(u8, value, "anonymous") and
                    !std.mem.eql(u8, value, "ephemeral") and
                    !std.mem.eql(u8, value, "legacy"))
                {
                    return error.InvalidIdentityState;
                }
            }
        }
    }
};

pub const FilterSet = struct {
    version: u8 = query_schema_version,
    clauses: []const Clause = &.{},

    pub fn validate(self: FilterSet) !void {
        if (self.version != query_schema_version) {
            return error.UnsupportedAnalysisQueryVersion;
        }
        if (self.clauses.len > maximum_clauses) {
            return error.TooManyAnalysisClauses;
        }
        for (self.clauses) |clause| try clause.validate();
    }
};

const JsonFilterSet = struct {
    schema: u8,
    match: []const u8,
    filters: []const []const u8 = &.{},
};

pub fn canonicalFilterJson(
    allocator: std.mem.Allocator,
    filters: FilterSet,
) ![]u8 {
    try filters.validate();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const encoded = try encodedClauses(arena.allocator(), filters.clauses);
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(JsonFilterSet{
        .schema = query_schema_version,
        .match = "all",
        .filters = encoded,
    }, .{}, &output.writer);
    const json = try output.toOwnedSlice();
    if (json.len > maximum_json_bytes) {
        allocator.free(json);
        return error.AnalysisJsonTooLong;
    }
    return json;
}

pub fn parseCanonicalFilterJson(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) !FilterSet {
    if (encoded.len == 0 or encoded.len > maximum_json_bytes) {
        return error.AnalysisJsonTooLong;
    }
    const state = std.json.parseFromSliceLeaky(
        JsonFilterSet,
        allocator,
        encoded,
        .{ .ignore_unknown_fields = false },
    ) catch return error.InvalidAnalysisJson;
    if (state.schema != query_schema_version) {
        return error.UnsupportedAnalysisQueryVersion;
    }
    if (!std.mem.eql(u8, state.match, "all")) {
        return error.InvalidAnalysisFilterMatch;
    }
    const filters = FilterSet{
        .clauses = try parseClauses(allocator, state.filters),
    };
    try filters.validate();
    return filters;
}

pub fn parseExactCanonicalFilterJson(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) !FilterSet {
    const filters = try parseCanonicalFilterJson(allocator, encoded);
    const normalized = try canonicalFilterJson(allocator, filters);
    defer allocator.free(normalized);
    if (!std.mem.eql(u8, encoded, normalized)) {
        return error.NonCanonicalAnalysisJson;
    }
    return filters;
}

const JsonPredicateSet = struct {
    schema: u8,
    predicates: []const []const u8 = &.{},
};

pub fn canonicalPredicateSetJson(
    allocator: std.mem.Allocator,
    predicates: []const PropertyPredicate,
) ![]u8 {
    if (predicates.len > maximum_selector_predicates) {
        return error.TooManySelectorPredicates;
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const encoded = try encodedPredicates(arena.allocator(), predicates);
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(JsonPredicateSet{
        .schema = query_schema_version,
        .predicates = encoded,
    }, .{}, &output.writer);
    const json = try output.toOwnedSlice();
    if (json.len > maximum_json_bytes) {
        allocator.free(json);
        return error.AnalysisJsonTooLong;
    }
    return json;
}

pub fn parseExactCanonicalPredicateSetJson(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) ![]const PropertyPredicate {
    if (encoded.len == 0 or encoded.len > maximum_json_bytes) {
        return error.AnalysisJsonTooLong;
    }
    const state = std.json.parseFromSliceLeaky(
        JsonPredicateSet,
        allocator,
        encoded,
        .{ .ignore_unknown_fields = false },
    ) catch return error.InvalidAnalysisJson;
    if (state.schema != query_schema_version) {
        return error.UnsupportedAnalysisQueryVersion;
    }
    const predicates = try parsePredicates(allocator, state.predicates);
    const normalized = try canonicalPredicateSetJson(allocator, predicates);
    defer allocator.free(normalized);
    if (!std.mem.eql(u8, encoded, normalized)) {
        return error.NonCanonicalAnalysisJson;
    }
    return predicates;
}

pub fn composeFilterSets(
    allocator: std.mem.Allocator,
    first: FilterSet,
    second: FilterSet,
) !FilterSet {
    try first.validate();
    try second.validate();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const encoded = try scratch.alloc(
        []const u8,
        first.clauses.len + second.clauses.len,
    );
    var index: usize = 0;
    for (first.clauses) |clause| {
        encoded[index] = try encodeClause(scratch, clause);
        index += 1;
    }
    for (second.clauses) |clause| {
        encoded[index] = try encodeClause(scratch, clause);
        index += 1;
    }
    const unique = sortUnique(encoded);
    if (unique.len > maximum_clauses) return error.TooManyAnalysisClauses;
    const clauses = try allocator.alloc(Clause, unique.len);
    for (unique, 0..) |value, clause_index| {
        clauses[clause_index] = try parseClause(allocator, value);
    }
    return .{ .clauses = clauses };
}

pub fn filterSetsEqual(left: FilterSet, right: FilterSet) bool {
    if (left.version != right.version or left.clauses.len != right.clauses.len) {
        return false;
    }
    for (left.clauses, right.clauses) |a, b| {
        if (!clausesEqual(a, b)) return false;
    }
    return true;
}

pub fn clausesEqual(a: Clause, b: Clause) bool {
    if (a.scope != b.scope or a.field.kind != b.field.kind or
        a.operator != b.operator or a.scalar_type != b.scalar_type or
        a.values.len != b.values.len)
    {
        return false;
    }
    if ((a.field.property_ref == null) != (b.field.property_ref == null)) {
        return false;
    }
    if (a.field.property_ref) |a_property| {
        const b_property = b.field.property_ref.?;
        if (a_property.scalar_type != b_property.scalar_type or
            !std.mem.eql(u8, a_property.name, b_property.name))
        {
            return false;
        }
    }
    for (a.values, b.values) |a_value, b_value| {
        if (!std.mem.eql(u8, a_value, b_value)) return false;
    }
    return true;
}

pub fn canonicalClause(
    allocator: std.mem.Allocator,
    clause: Clause,
) ![]u8 {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    return allocator.dupe(u8, try encodeClause(scratch.allocator(), clause));
}

pub fn canonicalFilterUrlSuffix(
    allocator: std.mem.Allocator,
    segment_id: ?[]const u8,
    filters: FilterSet,
) ![]u8 {
    try filters.validate();
    if (segment_id) |id| try domain.validateUuid(id);
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    var first = true;
    if (segment_id) |id| {
        try writeParameter(&output.writer, &first, "segment", id);
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const encoded = try encodedClauses(arena.allocator(), filters.clauses);
    for (encoded) |filter| {
        try writeRawParameter(&output.writer, &first, "f", filter);
    }
    return output.toOwnedSlice();
}

pub fn canonicalOverviewUrl(
    allocator: std.mem.Allocator,
    range: LocalDateRange,
    comparison: Comparison,
    metric: OverviewTrendMetric,
    currency: []const u8,
    segment_id: ?[]const u8,
    filters: FilterSet,
) ![]u8 {
    try range.validate();
    try filters.validate();
    if (segment_id) |id| try domain.validateUuid(id);
    if (metric == .revenue) {
        try domain.validateCurrency(currency);
    } else if (currency.len != 0) return error.UnexpectedOverviewCurrency;
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    var first = true;
    try writeParameter(&output.writer, &first, "v", "1");
    try writeParameter(&output.writer, &first, "from", range.start);
    try writeParameter(&output.writer, &first, "to", range.end);
    try writeParameter(&output.writer, &first, "compare", comparison.name());
    const selection = if (metric == .revenue)
        try std.fmt.allocPrint(allocator, "revenue-{s}", .{currency})
    else
        metric.name();
    defer if (metric == .revenue) allocator.free(selection);
    try writeParameter(&output.writer, &first, "metric", selection);
    const suffix = try canonicalFilterUrlSuffix(
        allocator,
        segment_id,
        filters,
    );
    defer allocator.free(suffix);
    if (suffix.len != 0) {
        try output.writer.writeByte('&');
        try output.writer.writeAll(suffix);
    }
    const encoded = try output.toOwnedSlice();
    if (encoded.len > maximum_url_bytes) {
        allocator.free(encoded);
        return error.AnalysisUrlTooLong;
    }
    return encoded;
}

pub fn parseCanonicalClause(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) !Clause {
    return parseClause(allocator, encoded);
}

pub const SelectorKind = enum {
    exact_page,
    page_prefix,
    exact_event,
    saved_goal,

    pub fn name(self: SelectorKind) []const u8 {
        return switch (self) {
            .exact_page => "page",
            .page_prefix => "page-prefix",
            .exact_event => "event",
            .saved_goal => "goal",
        };
    }

    pub fn parse(value: []const u8) !SelectorKind {
        inline for (@typeInfo(SelectorKind).@"enum".field_values) |raw| {
            const candidate: SelectorKind = @fromBackingInt(@intCast(raw));
            if (std.mem.eql(u8, value, candidate.name())) return candidate;
        }
        return error.InvalidEventSelector;
    }
};

pub const PropertyPredicate = struct {
    property_ref: PropertyRef,
    operator: Operator,
    values: []const []const u8 = &.{},

    pub fn validate(self: PropertyPredicate) !void {
        try self.property_ref.validate();
        try validateOperator(
            self.operator,
            self.property_ref.scalar_type,
            self.values.len,
        );
        if (self.values.len > maximum_values) return error.TooManyAnalysisValues;
        for (self.values) |value| {
            try validateValue(self.property_ref.scalar_type, value);
        }
    }
};

pub const EventSelector = struct {
    kind: SelectorKind,
    value: []const u8,
    predicates: []const PropertyPredicate = &.{},

    pub fn validate(self: EventSelector) !void {
        switch (self.kind) {
            .exact_page, .page_prefix => {
                const normalized = try domain.normalizePath(self.value);
                if (normalized.len != self.value.len) {
                    return error.NonCanonicalPageSelector;
                }
                for (self.value) |byte| {
                    if (byte < 0x20 or byte == 0x7f) {
                        return error.InvalidPageSelector;
                    }
                }
            },
            .exact_event => try domain.validateIdentifier(self.value),
            .saved_goal => try domain.validateUuid(self.value),
        }
        if (self.predicates.len > maximum_selector_predicates) {
            return error.TooManySelectorPredicates;
        }
        for (self.predicates) |predicate| try predicate.validate();
    }
};

pub const Metric = struct {
    kind: MetricKind,
    selector: ?EventSelector = null,
    conversion_basis: ?ConversionBasis = null,

    pub fn validate(self: Metric) !void {
        if (self.kind.requiresSelector() and self.selector == null) {
            return error.MissingMetricSelector;
        }
        if (!self.kind.permitsSelector() and self.selector != null) {
            return error.UnexpectedMetricSelector;
        }
        const conversion_metric = self.kind == .conversions or
            self.kind == .conversion_rate;
        if (conversion_metric != (self.conversion_basis != null) or
            (self.kind == .conversion_rate and
                self.conversion_basis.? == .event))
        {
            return error.InvalidConversionBasis;
        }
        if (self.selector) |selector| try selector.validate();
    }
};

pub fn canonicalTrendSeries(
    allocator: std.mem.Allocator,
    metric: Metric,
) ![]u8 {
    try validateBrowserTrendMetric(metric);
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    try writeGrammarComponent(&output.writer, metric.kind.name(), false);
    if (metric.conversion_basis) |basis| {
        try writeGrammarComponent(&output.writer, basis.name(), true);
    }
    if (metric.selector) |selector| {
        try writeGrammarComponent(&output.writer, selector.kind.name(), true);
        try writeGrammarComponent(&output.writer, selector.value, true);
    }
    return output.toOwnedSlice();
}

pub fn parseTrendSeries(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) !Metric {
    if (encoded.len == 0 or encoded.len > maximum_filter_value_bytes) {
        return error.InvalidTrendSeries;
    }
    var parts: [4][]const u8 = undefined;
    var count: usize = 0;
    var components = std.mem.splitScalar(u8, encoded, '~');
    while (components.next()) |component| {
        if (count == parts.len or component.len == 0) {
            return error.InvalidTrendSeries;
        }
        parts[count] = try percentDecode(allocator, component);
        count += 1;
    }
    if (count == 0) return error.InvalidTrendSeries;
    const kind = try MetricKind.parse(parts[0]);
    const metric = switch (kind) {
        .event_count, .event_visitors => if (count == 3)
            Metric{
                .kind = kind,
                .selector = .{
                    .kind = try SelectorKind.parse(parts[1]),
                    .value = parts[2],
                },
            }
        else
            return error.InvalidTrendSeries,
        .conversions, .conversion_rate => if (count == 4)
            Metric{
                .kind = kind,
                .conversion_basis = try ConversionBasis.parse(parts[1]),
                .selector = .{
                    .kind = try SelectorKind.parse(parts[2]),
                    .value = parts[3],
                },
            }
        else
            return error.InvalidTrendSeries,
        .revenue, .average_value => switch (count) {
            1 => Metric{ .kind = kind },
            3 => Metric{
                .kind = kind,
                .selector = .{
                    .kind = try SelectorKind.parse(parts[1]),
                    .value = parts[2],
                },
            },
            else => return error.InvalidTrendSeries,
        },
        else => if (count == 1)
            Metric{ .kind = kind }
        else
            return error.InvalidTrendSeries,
    };
    try validateBrowserTrendMetric(metric);
    return metric;
}

fn validateBrowserTrendMetric(metric: Metric) !void {
    try validateBrowserMetric(metric, false);
}

fn validateBrowserMetric(metric: Metric, allow_predicates: bool) !void {
    try metric.validate();
    if (metric.selector) |selector| {
        if (!allow_predicates and selector.predicates.len != 0) {
            return error.InvalidTrendSeries;
        }
    }
    switch (metric.kind) {
        .event_count, .event_visitors => if (metric.selector.?.kind != .exact_event) {
            return error.InvalidTrendSeries;
        },
        .conversions, .conversion_rate => if (metric.conversion_basis.? != .visitor or
            metric.selector.?.kind != .saved_goal)
        {
            return error.InvalidTrendSeries;
        },
        .revenue, .average_value => if (metric.selector) |selector| {
            if (selector.kind != .exact_event and selector.kind != .saved_goal) {
                return error.InvalidTrendSeries;
            }
        },
        else => {},
    }
}

pub fn validateTrendSeries(metric: Metric) !void {
    try validateBrowserTrendMetric(metric);
}

pub fn validateBrowserBreakdownMetric(metric: Metric) !void {
    validateBrowserMetric(metric, true) catch
        return error.InvalidBreakdownMetric;
}

pub const Ratio = struct {
    numerator: i64,
    denominator: i64,
};

pub const ExactAmount = struct {
    decimal: []const u8,
    currency: []const u8,
    value_count: i64,
};

pub const Measure = union(enum) {
    count: i64,
    ratio: Ratio,
    amount: ExactAmount,
};

pub const Completeness = struct {
    total_people: i64,
    persistent_people: i64,
    ephemeral_people: i64,
    legacy_people: i64,
    persistent_basis_points: u16,
    persistent_since_local_date: ?[]const u8,
};

pub const TrendPoint = struct {
    bucket: []const u8,
    measure: Measure,
};

pub const TrendResult = struct {
    points: []const TrendPoint,
    comparison_points: ?[]const TrendPoint,
    comparison_total: ?[]const Measure,
    comparison_completeness: ?Completeness,
    total: []const Measure,
    interval: Interval,
    completeness: Completeness,
};

pub const ComparedCount = struct {
    current: i64,
    comparison: ?i64,
};

pub const ComparedRatio = struct {
    current: Ratio,
    comparison: ?Ratio,
};

pub const ComparedAmount = struct {
    currency: []const u8,
    current: ExactAmount,
    comparison: ?ExactAmount,
};

pub const OverviewResult = struct {
    visitors: ComparedCount,
    sessions: ComparedCount,
    page_views: ComparedCount,
    engagement_rate: ComparedRatio,
    conversions: ComparedCount,
    conversion_rate: ComparedRatio,
    revenue: []const ComparedAmount,
    completeness: Completeness,
    comparison_completeness: ?Completeness,
    details: ?OverviewDetails = null,
};

pub const maximum_overview_panel_rows: u8 = 5;

pub const OverviewTrendMetric = enum {
    visitors,
    sessions,
    page_views,
    conversions,
    revenue,

    pub fn name(self: OverviewTrendMetric) []const u8 {
        return switch (self) {
            .visitors => "visitors",
            .sessions => "sessions",
            .page_views => "page-views",
            .conversions => "conversions",
            .revenue => "revenue",
        };
    }
};

pub const OverviewBucket = struct {
    label: []const u8,
};

pub const OverviewTrendSelection = struct {
    metric: OverviewTrendMetric = .visitors,
    currency: []const u8 = "",
    interval: Interval,
    current_buckets: []const OverviewBucket,
    comparison_buckets: []const OverviewBucket = &.{},

    pub fn validate(self: OverviewTrendSelection, comparison: bool) !void {
        if (self.interval == .auto) return error.InvalidOverviewInterval;
        if (self.current_buckets.len == 0 or
            self.current_buckets.len > maximum_range_days or
            self.comparison_buckets.len > maximum_range_days)
        {
            return error.InvalidOverviewBuckets;
        }
        if (comparison != (self.comparison_buckets.len != 0)) {
            return error.InvalidOverviewBuckets;
        }
        if (self.metric == .revenue) {
            if (self.currency.len != 3) return error.InvalidOverviewCurrency;
            for (self.currency) |byte| {
                if (byte < 'A' or byte > 'Z') return error.InvalidOverviewCurrency;
            }
        } else if (self.currency.len != 0) {
            return error.InvalidOverviewCurrency;
        }
        try validateOverviewBuckets(self.current_buckets);
        try validateOverviewBuckets(self.comparison_buckets);
    }
};

fn validateOverviewBuckets(buckets: []const OverviewBucket) !void {
    for (buckets, 0..) |bucket, index| {
        if (bucket.label.len == 0 or bucket.label.len > 16 or
            !std.unicode.utf8ValidateSlice(bucket.label))
        {
            return error.InvalidOverviewBuckets;
        }
        for (buckets[0..index]) |prior| {
            if (std.mem.eql(u8, prior.label, bucket.label)) {
                return error.InvalidOverviewBuckets;
            }
        }
    }
}

pub const OverviewTrendPoint = struct {
    label: []const u8,
    measure: Measure,
};

pub const OverviewTrend = struct {
    metric: OverviewTrendMetric,
    currency: []const u8,
    interval: Interval,
    current: []const OverviewTrendPoint,
    comparison: ?[]const OverviewTrendPoint,
};

pub const OverviewContentRow = struct {
    path: []const u8,
    page_views: i64,
    visitors: i64,
};

pub const OverviewAcquisitionRow = struct {
    source: []const u8,
    sessions: i64,
    converting_sessions: i64,
};

pub const OverviewConversionRow = struct {
    goal_id: []const u8,
    converting_people: i64,
};

pub const OverviewAudienceRow = struct {
    country: []const u8,
    sessions: i64,
};

pub const OverviewHealth = struct {
    daily_event_ceiling: i64,
    accepted_events: i64,
    ceiling_reached_days: i64,
    last_received_at_utc_micros: i64,
    protocol_v1_events: i64,
    protocol_v2_events: i64,
};

pub const OverviewDetails = struct {
    trend: OverviewTrend,
    content: []const OverviewContentRow,
    acquisition: []const OverviewAcquisitionRow,
    conversions: []const OverviewConversionRow,
    audience: []const OverviewAudienceRow,
    health: OverviewHealth,
};

pub const BreakdownLabel = struct {
    value: []const u8,
    scalar_type: ?ScalarType = null,
};

pub const BreakdownRow = struct {
    label: BreakdownLabel,
    measure: Measure,
};

pub const BreakdownResult = struct {
    rows: []const BreakdownRow,
    next_page: ?u32,
    cardinality: i64,
    completeness: Completeness,
};

pub const ObservedPropertyType = struct {
    name: []const u8,
    scalar_type: ScalarType,
    event_count: i64,
};

pub const PropertyCatalog = struct {
    entries: []const ObservedPropertyType,
    property_count: i64,
    truncated: bool,
};

pub const SuggestionRequest = struct {
    execution: Execution,
    scope: Scope,
    field: Field,
    scalar_type: ScalarType,
    search: []const u8 = "",

    pub fn validate(self: SuggestionRequest) !void {
        try self.execution.validate();
        try validateSearch(self.search);
        if (self.scalar_type == .boolean or self.scalar_type == .null or
            self.scalar_type == .missing)
        {
            return error.SuggestionValueNotApplicable;
        }
        try (Clause{
            .scope = self.scope,
            .field = self.field,
            .operator = .exists,
            .scalar_type = self.scalar_type,
        }).validate();
    }
};

pub const SuggestionResult = struct {
    values: []const []const u8,
    has_more: bool,
};

pub const GoalEntityKind = enum {
    page,
    event,
};

pub const GoalDiscoveryRequest = struct {
    site_id: []const u8,
    range: LocalDateRange,
    kind: GoalEntityKind,
    search: []const u8 = "",
    page: u32 = 1,
    active_goals: []const ResolvedGoal = &.{},
    strict_traffic_mode: bool = false,
    timeout_ms: u32 = maximum_timeout_ms,

    pub fn validate(self: GoalDiscoveryRequest) !void {
        try domain.validateUuid(self.site_id);
        try self.range.validate();
        try validateSearch(self.search);
        if (self.page == 0 or self.page > 1_000_000) {
            return error.InvalidGoalDiscoveryPage;
        }
        if (self.timeout_ms == 0 or self.timeout_ms > maximum_timeout_ms) {
            return error.InvalidAnalysisTimeout;
        }
        try validateActiveGoals(self.active_goals);
    }
};

pub const DiscoveredGoalEntity = struct {
    label: []const u8,
    eligible_count: i64,
    last_received_at_utc_micros: i64,
};

pub const GoalDiscoveryResult = struct {
    entities: []const DiscoveredGoalEntity,
    has_more: bool,
};

pub const GoalResultRequest = struct {
    site_id: []const u8,
    range: LocalDateRange,
    selector: EventSelector,
    filters: FilterSet = .{},
    active_goals: []const ResolvedGoal = &.{},
    strict_traffic_mode: bool = false,
    timeout_ms: u32 = maximum_timeout_ms,

    pub fn validate(self: GoalResultRequest) !void {
        try domain.validateUuid(self.site_id);
        try self.range.validate();
        try self.selector.validate();
        if (self.selector.kind == .saved_goal) {
            return error.UnresolvedGoalSelector;
        }
        try self.filters.validate();
        if (self.timeout_ms == 0 or self.timeout_ms > maximum_timeout_ms) {
            return error.InvalidAnalysisTimeout;
        }
        try validateActiveGoals(self.active_goals);
    }

    pub fn execution(self: GoalResultRequest) Execution {
        return .{
            .query = .{
                .site_id = self.site_id,
                .range = self.range,
                .mode = .breakdown,
                .metric = .{ .kind = .event_count, .selector = self.selector },
                .dimension = .{ .kind = .page },
                .filters = self.filters,
            },
            .active_goals = self.active_goals,
            .strict_traffic_mode = self.strict_traffic_mode,
            .timeout_ms = self.timeout_ms,
        };
    }
};

pub const GoalPathRow = struct {
    path: []const u8,
    matches: i64,
};

pub const GoalResult = struct {
    total_matches: i64,
    converting_visitors: i64,
    converting_sessions: i64,
    eligible_visitors: i64,
    eligible_sessions: i64,
    converting_coverage: Completeness,
    revenue: []const ExactAmount,
    paths: []const GoalPathRow,
    path_cardinality: i64,
};

pub const GoalPreviewResult = struct {
    result: GoalResult,
    properties: PropertyCatalog,
};

pub const FunnelAvailabilityRequest = struct {
    site_id: []const u8,
    range: LocalDateRange,
    selectors: []const EventSelector,
    filters: FilterSet = .{},
    active_goals: []const ResolvedGoal = &.{},
    strict_traffic_mode: bool = false,
    timeout_ms: u32 = maximum_timeout_ms,

    pub fn validate(self: FunnelAvailabilityRequest) !void {
        try domain.validateUuid(self.site_id);
        try self.range.validate();
        if (self.selectors.len < 2 or self.selectors.len > 8) {
            return error.InvalidFunnelLength;
        }
        for (self.selectors) |selector| {
            try selector.validate();
            if (selector.kind == .saved_goal) return error.UnresolvedGoalSelector;
        }
        try self.filters.validate();
        if (self.timeout_ms == 0 or self.timeout_ms > maximum_timeout_ms) {
            return error.InvalidAnalysisTimeout;
        }
        try validateActiveGoals(self.active_goals);
    }

    pub fn execution(self: FunnelAvailabilityRequest) Execution {
        return .{
            .query = .{
                .site_id = self.site_id,
                .range = self.range,
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

pub const FunnelAvailabilityRow = struct {
    step_index: u8,
    matching_events: i64,
};

pub const BreakdownPageResult = struct {
    breakdown: BreakdownResult,
    properties: PropertyCatalog,
    site_has_events: bool,
};

pub const Result = union(Mode) {
    trend: TrendResult,
    breakdown: BreakdownResult,
};

pub const Query = struct {
    site_id: []const u8,
    range: LocalDateRange,
    comparison: Comparison = .none,
    mode: Mode,
    metric: Metric,
    dimension: ?Dimension = null,
    interval: Interval = .auto,
    filters: FilterSet = .{},
    segment_id: ?[]const u8 = null,
    search: []const u8 = "",
    sort: Sort = .value_desc,
    page: u32 = 1,
    limit: u16 = 25,

    pub fn validate(self: Query) !void {
        try domain.validateUuid(self.site_id);
        try self.range.validate();
        try self.metric.validate();
        try self.filters.validate();
        if (self.segment_id) |id| try domain.validateUuid(id);
        try validateSearch(self.search);
        if (self.page == 0 or self.page > maximum_page) {
            return error.InvalidAnalysisPage;
        }
        if (self.limit == 0 or self.limit > maximum_limit) {
            return error.InvalidAnalysisLimit;
        }
        switch (self.mode) {
            .trend => {
                if (self.dimension != null) return error.TrendHasDimension;
                if (self.search.len != 0) return error.TrendHasSearch;
                if (self.page != 1 or self.limit != 25 or
                    self.sort != .value_desc)
                {
                    return error.TrendHasPagination;
                }
            },
            .breakdown => {
                try (self.dimension orelse
                    return error.BreakdownMissingDimension).validate();
                if ((self.metric.kind == .new_visitors or
                    self.metric.kind == .returning_visitors) and
                    self.dimension.?.kind == .event_property)
                {
                    return error.UnsupportedMetricDimension;
                }
                if (self.interval != .auto) {
                    return error.BreakdownHasInterval;
                }
                if (self.comparison != .none) {
                    return error.BreakdownHasComparison;
                }
            },
        }
        if (self.interval == .hour and try self.range.days() > 7) {
            return error.HourIntervalRangeTooLarge;
        }
    }

    pub fn offset(self: Query) !i64 {
        try self.validate();
        const value = std.math.mul(
            u64,
            @as(u64, self.page - 1),
            self.limit,
        ) catch return error.InvalidAnalysisPage;
        if (value > std.math.maxInt(i64)) return error.InvalidAnalysisPage;
        return @intCast(value);
    }
};

fn validateSearch(value: []const u8) !void {
    if (value.len > maximum_search_bytes or !std.unicode.utf8ValidateSlice(value)) {
        return error.InvalidAnalysisSearch;
    }
    for (value, 0..) |byte, index| {
        if (byte < 0x20 or byte == 0x7f) return error.InvalidAnalysisSearch;
        if (byte == 0xc2 and index + 1 < value.len and
            value[index + 1] >= 0x80 and value[index + 1] <= 0x9f)
        {
            return error.InvalidAnalysisSearch;
        }
    }
}

pub const ResolvedGoal = struct {
    id: []const u8,
    selector: EventSelector,

    pub fn validate(self: ResolvedGoal) !void {
        try domain.validateUuid(self.id);
        try self.selector.validate();
        if (self.selector.kind == .saved_goal) {
            return error.RecursiveGoalSelector;
        }
    }
};

pub const Execution = struct {
    query: Query,
    comparison_range: ?LocalDateRange = null,
    active_goals: []const ResolvedGoal = &.{},
    selected_goals: []const ResolvedGoal = &.{},
    strict_traffic_mode: bool = false,
    segment_resolved: bool = false,
    timeout_ms: u32 = maximum_timeout_ms,

    pub fn validate(self: Execution) !void {
        try self.query.validate();
        if (self.timeout_ms == 0 or self.timeout_ms > maximum_timeout_ms) {
            return error.InvalidAnalysisTimeout;
        }
        if ((self.query.comparison == .none) != (self.comparison_range == null)) {
            return error.InvalidResolvedComparison;
        }
        if (self.comparison_range) |range| {
            try range.validate();
            if (self.query.interval == .hour and try range.days() > 7) {
                return error.HourIntervalRangeTooLarge;
            }
        }
        if (self.query.segment_id != null and !self.segment_resolved) {
            return error.UnresolvedAnalysisSegment;
        }
        try validateActiveGoals(self.active_goals);
        try validateSelectedGoals(self.selected_goals, self.active_goals);
        if (try resolvedSelectorSets(
            self.query.metric.selector,
            self.active_goals,
            self.selected_goals,
        )) |resolved| {
            if (resolved.selector.predicates.len +
                resolved.additional_predicates.len > maximum_selector_predicates)
            {
                return error.TooManySelectorPredicates;
            }
        }
    }
};

pub const TrendSet = struct {
    site_id: []const u8,
    range: LocalDateRange,
    comparison: Comparison = .none,
    interval: Interval = .auto,
    series: []const Metric,
    filters: FilterSet = .{},
    segment_id: ?[]const u8 = null,

    pub fn validate(self: TrendSet) !void {
        try domain.validateUuid(self.site_id);
        try self.range.validate();
        try self.filters.validate();
        if (self.segment_id) |id| try domain.validateUuid(id);
        if (self.series.len == 0 or self.series.len > maximum_series) {
            return error.InvalidTrendSeriesCount;
        }
        for (self.series, 0..) |metric, index| {
            try validateBrowserTrendMetric(metric);
            const item_query = self.query(metric);
            try item_query.validate();
            for (self.series[0..index]) |prior| {
                if (metricsEqual(metric, prior)) {
                    return error.DuplicateTrendSeries;
                }
            }
        }
    }

    pub fn query(self: TrendSet, metric: Metric) Query {
        return .{
            .site_id = self.site_id,
            .range = self.range,
            .comparison = self.comparison,
            .mode = .trend,
            .metric = metric,
            .interval = self.interval,
            .filters = self.filters,
            .segment_id = self.segment_id,
        };
    }
};

pub fn canonicalTrendSetUrl(
    allocator: std.mem.Allocator,
    set: TrendSet,
    highlight: []const u8,
) ![]u8 {
    try set.validate();
    if (highlight.len > 16 or
        (highlight.len != 0 and !std.unicode.utf8ValidateSlice(highlight)))
    {
        return error.InvalidTrendHighlight;
    }
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    var first = true;
    try writeParameter(&output.writer, &first, "v", "1");
    try writeParameter(&output.writer, &first, "from", set.range.start);
    try writeParameter(&output.writer, &first, "to", set.range.end);
    try writeParameter(&output.writer, &first, "compare", set.comparison.name());
    try writeParameter(&output.writer, &first, "mode", "trend");
    try writeParameter(&output.writer, &first, "interval", set.interval.name());
    for (set.series) |metric| {
        const encoded = try canonicalTrendSeries(allocator, metric);
        defer allocator.free(encoded);
        try writeRawParameter(&output.writer, &first, "series", encoded);
    }
    if (set.segment_id) |id| {
        try writeParameter(&output.writer, &first, "segment", id);
    }
    if (highlight.len != 0) {
        try writeParameter(&output.writer, &first, "highlight", highlight);
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const filters = try encodedClauses(arena.allocator(), set.filters.clauses);
    for (filters) |filter| {
        try writeRawParameter(&output.writer, &first, "f", filter);
    }
    const encoded = try output.toOwnedSlice();
    if (encoded.len > maximum_url_bytes) {
        allocator.free(encoded);
        return error.AnalysisUrlTooLong;
    }
    return encoded;
}

const JsonTrendSet = struct {
    schema: u8,
    metric_version: u8,
    site_id: []const u8,
    from: []const u8,
    to: []const u8,
    compare: []const u8,
    mode: []const u8,
    interval: []const u8,
    series: []const []const u8,
    segment: ?[]const u8 = null,
    filters: []const []const u8 = &.{},
};

pub fn canonicalTrendSetJson(
    allocator: std.mem.Allocator,
    set: TrendSet,
) ![]u8 {
    try set.validate();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const series = try scratch.alloc([]const u8, set.series.len);
    for (set.series, 0..) |metric, index| {
        series[index] = try canonicalTrendSeries(scratch, metric);
    }
    const filters = try encodedClauses(scratch, set.filters.clauses);
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(JsonTrendSet{
        .schema = query_schema_version,
        .metric_version = metric_version,
        .site_id = set.site_id,
        .from = set.range.start,
        .to = set.range.end,
        .compare = set.comparison.name(),
        .mode = "trend",
        .interval = set.interval.name(),
        .series = series,
        .segment = set.segment_id,
        .filters = filters,
    }, .{ .emit_null_optional_fields = false }, &output.writer);
    const json = try output.toOwnedSlice();
    if (json.len > maximum_json_bytes) {
        allocator.free(json);
        return error.AnalysisJsonTooLong;
    }
    return json;
}

pub fn parseCanonicalTrendSetJson(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) !TrendSet {
    if (encoded.len == 0 or encoded.len > maximum_json_bytes) {
        return error.AnalysisJsonTooLong;
    }
    const state = std.json.parseFromSliceLeaky(
        JsonTrendSet,
        allocator,
        encoded,
        .{ .ignore_unknown_fields = false },
    ) catch return error.InvalidAnalysisJson;
    if (state.schema != query_schema_version or
        state.metric_version != metric_version)
    {
        return error.UnsupportedAnalysisQueryVersion;
    }
    if (!std.mem.eql(u8, state.mode, "trend") or
        state.series.len == 0 or state.series.len > maximum_series)
    {
        return error.InvalidAnalysisMode;
    }
    const series = try allocator.alloc(Metric, state.series.len);
    for (state.series, 0..) |value, index| {
        series[index] = try parseTrendSeries(allocator, value);
    }
    const set = TrendSet{
        .site_id = state.site_id,
        .range = .{ .start = state.from, .end = state.to },
        .comparison = try Comparison.parse(state.compare),
        .interval = try Interval.parse(state.interval),
        .series = series,
        .filters = .{ .clauses = try parseClauses(allocator, state.filters) },
        .segment_id = state.segment,
    };
    try set.validate();
    return set;
}

pub fn parseExactCanonicalTrendSetJson(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) !TrendSet {
    const set = try parseCanonicalTrendSetJson(allocator, encoded);
    const normalized = try canonicalTrendSetJson(allocator, set);
    defer allocator.free(normalized);
    if (!std.mem.eql(u8, encoded, normalized)) {
        return error.NonCanonicalAnalysisJson;
    }
    return set;
}

pub const ParsedTrendSetUrl = struct {
    set: TrendSet,
    highlight: []const u8 = "",
};

const TrendUrlParts = struct {
    version: ?[]const u8 = null,
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    comparison: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    interval: ?[]const u8 = null,
    segment: ?[]const u8 = null,
    highlight: ?[]const u8 = null,
};

pub fn parseCanonicalTrendSetUrl(
    allocator: std.mem.Allocator,
    site_id: []const u8,
    encoded: []const u8,
) !ParsedTrendSetUrl {
    if (encoded.len == 0 or encoded.len > maximum_url_bytes) {
        return error.AnalysisUrlTooLong;
    }
    var parts = TrendUrlParts{};
    var series: std.ArrayList(Metric) = .empty;
    var clauses: std.ArrayList(Clause) = .empty;
    var count: usize = 0;
    var parameters = std.mem.splitScalar(u8, encoded, '&');
    while (parameters.next()) |parameter| {
        count += 1;
        if (count > maximum_url_parameters or parameter.len == 0) {
            return error.TooManyAnalysisUrlParameters;
        }
        const equals = std.mem.findScalar(u8, parameter, '=') orelse
            return error.InvalidAnalysisUrl;
        if (equals == 0 or equals + 1 == parameter.len or
            std.mem.findScalar(u8, parameter[equals + 1 ..], '=') != null)
        {
            return error.InvalidAnalysisUrl;
        }
        const key = parameter[0..equals];
        const raw_value = parameter[equals + 1 ..];
        if (std.mem.eql(u8, key, "series")) {
            if (series.items.len >= maximum_series) {
                return error.InvalidTrendSeriesCount;
            }
            try series.append(allocator, try parseTrendSeries(allocator, raw_value));
        } else if (std.mem.eql(u8, key, "f")) {
            if (clauses.items.len >= maximum_clauses) {
                return error.TooManyAnalysisClauses;
            }
            try clauses.append(allocator, try parseFormClause(allocator, raw_value));
        } else {
            const value = try percentDecode(allocator, raw_value);
            if (std.mem.eql(u8, key, "v")) {
                try setOnce(&parts.version, value);
            } else if (std.mem.eql(u8, key, "from")) {
                try setOnce(&parts.from, value);
            } else if (std.mem.eql(u8, key, "to")) {
                try setOnce(&parts.to, value);
            } else if (std.mem.eql(u8, key, "compare")) {
                try setOnce(&parts.comparison, value);
            } else if (std.mem.eql(u8, key, "mode")) {
                try setOnce(&parts.mode, value);
            } else if (std.mem.eql(u8, key, "interval")) {
                try setOnce(&parts.interval, value);
            } else if (std.mem.eql(u8, key, "segment")) {
                try setOnce(&parts.segment, value);
            } else if (std.mem.eql(u8, key, "highlight")) {
                try setOnce(&parts.highlight, value);
            } else return error.UnknownAnalysisUrlParameter;
        }
    }
    if (!std.mem.eql(
        u8,
        parts.version orelse return error.MissingAnalysisUrlField,
        "1",
    )) return error.UnsupportedAnalysisQueryVersion;
    if (!std.mem.eql(
        u8,
        parts.mode orelse return error.MissingAnalysisUrlField,
        "trend",
    )) return error.InvalidAnalysisMode;
    const highlight = parts.highlight orelse "";
    if (highlight.len > 16) return error.InvalidTrendHighlight;
    const set = TrendSet{
        .site_id = site_id,
        .range = .{
            .start = parts.from orelse return error.MissingAnalysisUrlField,
            .end = parts.to orelse return error.MissingAnalysisUrlField,
        },
        .comparison = try Comparison.parse(
            parts.comparison orelse return error.MissingAnalysisUrlField,
        ),
        .interval = try Interval.parse(
            parts.interval orelse return error.MissingAnalysisUrlField,
        ),
        .series = try series.toOwnedSlice(allocator),
        .filters = .{ .clauses = try clauses.toOwnedSlice(allocator) },
        .segment_id = parts.segment,
    };
    try set.validate();
    return .{ .set = set, .highlight = highlight };
}

pub const TrendSetExecution = struct {
    set: TrendSet,
    comparison_range: ?LocalDateRange = null,
    active_goals: []const ResolvedGoal = &.{},
    selected_goals: []const ResolvedGoal = &.{},
    strict_traffic_mode: bool = false,
    segment_resolved: bool = false,
    timeout_ms: u32 = maximum_timeout_ms,

    pub fn validate(self: TrendSetExecution) !void {
        try self.set.validate();
        for (self.set.series) |metric| {
            try (Execution{
                .query = self.set.query(metric),
                .comparison_range = self.comparison_range,
                .active_goals = self.active_goals,
                .selected_goals = self.selected_goals,
                .strict_traffic_mode = self.strict_traffic_mode,
                .segment_resolved = self.segment_resolved,
                .timeout_ms = self.timeout_ms,
            }).validate();
        }
    }
};

pub const TrendSetResult = struct {
    series: []const TrendResult,
};

pub fn metricsEqual(left: Metric, right: Metric) bool {
    if (left.kind != right.kind or left.conversion_basis != right.conversion_basis) {
        return false;
    }
    if ((left.selector == null) != (right.selector == null)) return false;
    if (left.selector == null) return true;
    const left_selector = left.selector.?;
    const right_selector = right.selector.?;
    if (left_selector.kind != right_selector.kind or
        !std.mem.eql(u8, left_selector.value, right_selector.value) or
        left_selector.predicates.len != right_selector.predicates.len)
    {
        return false;
    }
    for (left_selector.predicates, right_selector.predicates) |left_predicate, right_predicate| {
        if (left_predicate.property_ref.scalar_type !=
            right_predicate.property_ref.scalar_type or
            !std.mem.eql(
                u8,
                left_predicate.property_ref.name,
                right_predicate.property_ref.name,
            ) or
            left_predicate.operator != right_predicate.operator or
            left_predicate.values.len != right_predicate.values.len)
        {
            return false;
        }
        for (left_predicate.values, right_predicate.values) |left_value, right_value| {
            if (!std.mem.eql(u8, left_value, right_value)) return false;
        }
    }
    return true;
}

pub const OverviewExecution = struct {
    site_id: []const u8,
    range: LocalDateRange,
    comparison_range: ?LocalDateRange = null,
    active_goals: []const ResolvedGoal = &.{},
    filters: FilterSet = .{},
    segment_id: ?[]const u8 = null,
    segment_resolved: bool = false,
    strict_traffic_mode: bool = false,
    daily_event_ceiling: i64 = 100_000,
    timeout_ms: u32 = maximum_timeout_ms,
    trend: ?OverviewTrendSelection = null,

    pub fn validate(self: OverviewExecution) !void {
        try domain.validateUuid(self.site_id);
        try self.range.validate();
        try self.filters.validate();
        if (self.segment_id) |id| try domain.validateUuid(id);
        if (self.segment_id != null and !self.segment_resolved) {
            return error.UnresolvedAnalysisSegment;
        }
        if (self.comparison_range) |range| try range.validate();
        if (self.timeout_ms == 0 or self.timeout_ms > maximum_timeout_ms) {
            return error.InvalidAnalysisTimeout;
        }
        if (self.daily_event_ceiling < 1 or self.daily_event_ceiling > 10_000_000) {
            return error.InvalidDailyEventCeiling;
        }
        try validateActiveGoals(self.active_goals);
        if (self.trend) |trend| {
            try trend.validate(self.comparison_range != null);
        }
    }
};

fn validateActiveGoals(goals: []const ResolvedGoal) !void {
    if (goals.len > maximum_active_goals) return error.TooManyActiveGoals;
    for (goals, 0..) |goal, index| {
        try goal.validate();
        for (goals[0..index]) |prior| {
            if (std.mem.eql(u8, goal.id, prior.id)) {
                return error.DuplicateResolvedGoal;
            }
        }
    }
}

test "strict traffic validates predicate goals for base-selector evidence" {
    const predicates = [_]PropertyPredicate{.{
        .property_ref = .{ .name = "plan", .scalar_type = .string },
        .operator = .is,
        .values = &.{"pro"},
    }};
    const goals = [_]ResolvedGoal{.{
        .id = "00000000-0000-4000-8000-000000000034",
        .selector = .{
            .kind = .exact_event,
            .value = "purchase",
            .predicates = &predicates,
        },
    }};
    try (GoalResultRequest{
        .site_id = "00000000-0000-4000-8000-000000000024",
        .range = .{ .start = "2026-01-01", .end = "2026-01-02" },
        .selector = .{ .kind = .exact_event, .value = "purchase" },
        .active_goals = &goals,
        .strict_traffic_mode = true,
    }).validate();
}

fn validateSelectedGoals(
    goals: []const ResolvedGoal,
    active_goals: []const ResolvedGoal,
) !void {
    if (goals.len > maximum_series) return error.TooManySelectedGoals;
    for (goals, 0..) |goal, index| {
        try goal.validate();
        for (active_goals) |active| {
            if (std.mem.eql(u8, goal.id, active.id)) {
                return error.DuplicateResolvedGoal;
            }
        }
        for (goals[0..index]) |prior| {
            if (std.mem.eql(u8, goal.id, prior.id)) {
                return error.DuplicateResolvedGoal;
            }
        }
    }
}

pub const Preset = enum {
    overview_visitors,
    overview_sessions,
    overview_page_views,
    overview_custom_events,
    pages,
    entries,
    exits,
    sources,
    campaigns_source,
    campaigns_medium,
    campaigns_campaign,
    campaigns_term,
    campaigns_content,
    countries,
    browsers,
    operating_systems,
    devices,
    events,
};

pub const CurrentReportPreset = union(enum) {
    analysis: Preset,
    overview,
    campaign_tuple,
    traffic_quality,
    goal,
    funnel,
};

pub fn presetQuery(
    preset: Preset,
    site_id: []const u8,
    range: LocalDateRange,
) Query {
    const metric: Metric = .{ .kind = switch (preset) {
        .overview_visitors => .visitors,
        .overview_sessions,
        .entries,
        .exits,
        .sources,
        .campaigns_source,
        .campaigns_medium,
        .campaigns_campaign,
        .campaigns_term,
        .campaigns_content,
        .countries,
        .browsers,
        .operating_systems,
        .devices,
        => .sessions,
        .overview_page_views, .pages => .page_views,
        .overview_custom_events, .events => .custom_events,
    } };
    const dimension: ?Dimension = switch (preset) {
        .overview_visitors,
        .overview_sessions,
        .overview_page_views,
        .overview_custom_events,
        => null,
        .pages => .{ .kind = .page },
        .entries => .{ .kind = .landing_page },
        .exits => .{ .kind = .exit_page },
        .sources => .{ .kind = .referrer },
        .campaigns_source => .{ .kind = .utm_source },
        .campaigns_medium => .{ .kind = .utm_medium },
        .campaigns_campaign => .{ .kind = .utm_campaign },
        .campaigns_term => .{ .kind = .utm_term },
        .campaigns_content => .{ .kind = .utm_content },
        .countries => .{ .kind = .country },
        .browsers => .{ .kind = .browser },
        .operating_systems => .{ .kind = .operating_system },
        .devices => .{ .kind = .device },
        .events => .{ .kind = .event_name },
    };
    return .{
        .site_id = site_id,
        .range = range,
        .mode = if (dimension == null) .trend else .breakdown,
        .metric = metric,
        .dimension = dimension,
    };
}

pub fn presetForCurrentReport(
    kind: report.Kind,
    campaign_dimension: report.CampaignDimension,
) CurrentReportPreset {
    return switch (kind) {
        .overview => .overview,
        .pages => .{ .analysis = .pages },
        .entries => .{ .analysis = .entries },
        .exits => .{ .analysis = .exits },
        .sources => .{ .analysis = .sources },
        .campaigns => switch (campaign_dimension) {
            .source => .{ .analysis = .campaigns_source },
            .medium => .{ .analysis = .campaigns_medium },
            .campaign => .{ .analysis = .campaigns_campaign },
            .term => .{ .analysis = .campaigns_term },
            .content => .{ .analysis = .campaigns_content },
            .all => .campaign_tuple,
        },
        .countries => .{ .analysis = .countries },
        .browsers => .{ .analysis = .browsers },
        .operating_systems => .{ .analysis = .operating_systems },
        .devices => .{ .analysis = .devices },
        .events => .{ .analysis = .events },
        .traffic_quality => .traffic_quality,
        .goal => .goal,
        .funnel => .funnel,
    };
}

pub const SelectorResolution = struct {
    selector: EventSelector,
    additional_predicates: []const PropertyPredicate = &.{},
};

pub fn resolvedSelector(
    selector: ?EventSelector,
    goals: []const ResolvedGoal,
) !?SelectorResolution {
    const selected = selector orelse return null;
    if (selected.kind != .saved_goal) return .{ .selector = selected };
    for (goals) |goal| {
        if (std.mem.eql(u8, goal.id, selected.value)) return .{
            .selector = goal.selector,
            .additional_predicates = selected.predicates,
        };
    }
    return error.UnresolvedGoalSelector;
}

pub fn resolvedSelectorSets(
    selector: ?EventSelector,
    active_goals: []const ResolvedGoal,
    selected_goals: []const ResolvedGoal,
) !?SelectorResolution {
    const selected = selector orelse return null;
    if (selected.kind != .saved_goal) return .{ .selector = selected };
    if (resolvedSelector(selected, active_goals)) |resolution| {
        return resolution;
    } else |err| if (err != error.UnresolvedGoalSelector) return err;
    return resolvedSelector(selected, selected_goals);
}

const JsonSelector = struct {
    kind: []const u8,
    value: []const u8,
    predicates: []const []const u8 = &.{},
};

const JsonDimension = struct {
    kind: []const u8,
    property: ?[]const u8 = null,
    property_type: ?[]const u8 = null,
};

const JsonState = struct {
    schema: u8,
    metric_version: u8,
    site_id: []const u8,
    from: []const u8,
    to: []const u8,
    compare: []const u8,
    mode: []const u8,
    metric: []const u8,
    conversion_basis: ?[]const u8 = null,
    selector: ?JsonSelector = null,
    dimension: ?JsonDimension = null,
    search: ?[]const u8 = null,
    interval: []const u8,
    segment: ?[]const u8 = null,
    sort: []const u8,
    limit: u16,
    filters: []const []const u8 = &.{},
};

pub fn canonicalJson(
    allocator: std.mem.Allocator,
    query: Query,
) ![]u8 {
    try query.validate();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const filters = try encodedClauses(scratch, query.filters.clauses);
    const selector = if (query.metric.selector) |selected|
        JsonSelector{
            .kind = selected.kind.name(),
            .value = selected.value,
            .predicates = try encodedPredicates(scratch, selected.predicates),
        }
    else
        null;
    const dimension = if (query.dimension) |selected|
        JsonDimension{
            .kind = selected.kind.name(),
            .property = if (selected.property_ref) |reference| reference.name else null,
            .property_type = if (selected.property_ref) |reference|
                reference.scalar_type.name()
            else
                null,
        }
    else
        null;
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(JsonState{
        .schema = query_schema_version,
        .metric_version = metric_version,
        .site_id = query.site_id,
        .from = query.range.start,
        .to = query.range.end,
        .compare = query.comparison.name(),
        .mode = query.mode.name(),
        .metric = query.metric.kind.name(),
        .conversion_basis = if (query.metric.conversion_basis) |basis|
            basis.name()
        else
            null,
        .selector = selector,
        .dimension = dimension,
        .search = if (query.search.len == 0) null else query.search,
        .interval = query.interval.name(),
        .segment = query.segment_id,
        .sort = query.sort.name(),
        .limit = query.limit,
        .filters = filters,
    }, .{ .emit_null_optional_fields = false }, &output.writer);
    const encoded = try output.toOwnedSlice();
    if (encoded.len > maximum_json_bytes) {
        allocator.free(encoded);
        return error.AnalysisJsonTooLong;
    }
    return encoded;
}

pub fn parseCanonicalJson(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) !Query {
    if (encoded.len == 0 or encoded.len > maximum_json_bytes) {
        return error.AnalysisJsonTooLong;
    }
    const state = std.json.parseFromSliceLeaky(
        JsonState,
        allocator,
        encoded,
        .{ .ignore_unknown_fields = false },
    ) catch return error.InvalidAnalysisJson;
    if (state.schema != query_schema_version or
        state.metric_version != metric_version)
    {
        return error.UnsupportedAnalysisQueryVersion;
    }
    const selector = if (state.selector) |selected|
        EventSelector{
            .kind = try SelectorKind.parse(selected.kind),
            .value = selected.value,
            .predicates = try parsePredicates(allocator, selected.predicates),
        }
    else
        null;
    const dimension = if (state.dimension) |selected|
        Dimension{
            .kind = try DimensionKind.parse(selected.kind),
            .property_ref = try parsePropertyRef(
                selected.property,
                selected.property_type,
            ),
        }
    else
        null;
    const query = Query{
        .site_id = state.site_id,
        .range = .{ .start = state.from, .end = state.to },
        .comparison = try Comparison.parse(state.compare),
        .mode = try Mode.parse(state.mode),
        .metric = .{
            .kind = try MetricKind.parse(state.metric),
            .selector = selector,
            .conversion_basis = if (state.conversion_basis) |basis|
                try ConversionBasis.parse(basis)
            else
                null,
        },
        .dimension = dimension,
        .search = state.search orelse "",
        .interval = try Interval.parse(state.interval),
        .filters = .{
            .clauses = try parseClauses(allocator, state.filters),
        },
        .segment_id = state.segment,
        .sort = try Sort.parse(state.sort),
        .limit = state.limit,
    };
    try query.validate();
    return query;
}

pub fn parseExactCanonicalJson(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) !Query {
    const query = try parseCanonicalJson(allocator, encoded);
    const normalized = try canonicalJson(allocator, query);
    defer allocator.free(normalized);
    if (!std.mem.eql(u8, encoded, normalized)) {
        return error.NonCanonicalAnalysisJson;
    }
    return query;
}

pub fn canonicalUrl(
    allocator: std.mem.Allocator,
    query: Query,
) ![]u8 {
    try query.validate();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    var first = true;
    try writeParameter(&output.writer, &first, "v", "1");
    try writeParameter(&output.writer, &first, "from", query.range.start);
    try writeParameter(&output.writer, &first, "to", query.range.end);
    try writeParameter(&output.writer, &first, "compare", query.comparison.name());
    try writeParameter(&output.writer, &first, "mode", query.mode.name());
    try writeParameter(&output.writer, &first, "metric", query.metric.kind.name());
    if (query.metric.conversion_basis) |basis| {
        try writeParameter(
            &output.writer,
            &first,
            "conversion-basis",
            basis.name(),
        );
    }
    if (query.metric.selector) |selector| {
        try writeParameter(&output.writer, &first, "selector", selector.kind.name());
        try writeParameter(&output.writer, &first, "selector-value", selector.value);
    }
    if (query.dimension) |dimension| {
        try writeParameter(&output.writer, &first, "dimension", dimension.kind.name());
        if (dimension.property_ref) |reference| {
            try writeParameter(&output.writer, &first, "property", reference.name);
            try writeParameter(
                &output.writer,
                &first,
                "property-type",
                reference.scalar_type.name(),
            );
        }
    }
    if (query.search.len != 0) {
        try writeParameter(&output.writer, &first, "search", query.search);
    }
    try writeParameter(&output.writer, &first, "interval", query.interval.name());
    if (query.segment_id) |id| {
        try writeParameter(&output.writer, &first, "segment", id);
    }
    try writeParameter(&output.writer, &first, "sort", query.sort.name());
    var number_buffer: [20]u8 = undefined;
    const page = try std.fmt.bufPrint(&number_buffer, "{d}", .{query.page});
    try writeParameter(&output.writer, &first, "page", page);
    const limit = try std.fmt.bufPrint(&number_buffer, "{d}", .{query.limit});
    try writeParameter(&output.writer, &first, "limit", limit);

    if (query.metric.selector) |selector| {
        const predicates = try encodedPredicates(scratch, selector.predicates);
        for (predicates) |predicate| {
            try writeRawParameter(&output.writer, &first, "p", predicate);
        }
    }
    const filters = try encodedClauses(scratch, query.filters.clauses);
    for (filters) |filter| {
        try writeRawParameter(&output.writer, &first, "f", filter);
    }
    const encoded = try output.toOwnedSlice();
    if (encoded.len > maximum_url_bytes) {
        allocator.free(encoded);
        return error.AnalysisUrlTooLong;
    }
    return encoded;
}

const UrlParts = struct {
    version: ?[]const u8 = null,
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    compare: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    metric: ?[]const u8 = null,
    conversion_basis: ?[]const u8 = null,
    selector: ?[]const u8 = null,
    selector_value: ?[]const u8 = null,
    dimension: ?[]const u8 = null,
    property_name: ?[]const u8 = null,
    property_type: ?[]const u8 = null,
    search: ?[]const u8 = null,
    interval: ?[]const u8 = null,
    segment: ?[]const u8 = null,
    sort: ?[]const u8 = null,
    page: ?[]const u8 = null,
    limit: ?[]const u8 = null,
};

pub fn parseCanonicalUrl(
    allocator: std.mem.Allocator,
    site_id: []const u8,
    encoded: []const u8,
) !Query {
    if (encoded.len == 0 or encoded.len > maximum_url_bytes) {
        return error.AnalysisUrlTooLong;
    }
    var parts = UrlParts{};
    var clauses: std.ArrayList(Clause) = .empty;
    var predicates: std.ArrayList(PropertyPredicate) = .empty;
    var count: usize = 0;
    var parameters = std.mem.splitScalar(u8, encoded, '&');
    while (parameters.next()) |parameter| {
        count += 1;
        if (count > maximum_url_parameters or parameter.len == 0) {
            return error.TooManyAnalysisUrlParameters;
        }
        const equals = std.mem.findScalar(u8, parameter, '=') orelse
            return error.InvalidAnalysisUrl;
        if (equals == 0 or equals + 1 == parameter.len or
            std.mem.findScalar(u8, parameter[equals + 1 ..], '=') != null)
        {
            return error.InvalidAnalysisUrl;
        }
        const key = parameter[0..equals];
        const raw_value = parameter[equals + 1 ..];
        if (std.mem.eql(u8, key, "f")) {
            try clauses.append(
                allocator,
                try parseFormClause(allocator, raw_value),
            );
        } else if (std.mem.eql(u8, key, "p")) {
            try predicates.append(
                allocator,
                try parseFormPredicate(allocator, raw_value),
            );
        } else {
            const value = try percentDecode(allocator, raw_value);
            try setUrlPart(&parts, key, value);
        }
    }
    if (!std.mem.eql(u8, parts.version orelse return error.MissingAnalysisUrlField, "1")) {
        return error.UnsupportedAnalysisQueryVersion;
    }
    const selector = if (parts.selector) |selector_name|
        EventSelector{
            .kind = try SelectorKind.parse(selector_name),
            .value = parts.selector_value orelse return error.MissingSelectorValue,
            .predicates = try predicates.toOwnedSlice(allocator),
        }
    else blk: {
        if (parts.selector_value != null or predicates.items.len != 0) {
            return error.UnexpectedSelectorValue;
        }
        break :blk null;
    };
    const dimension = if (parts.dimension) |dimension_name|
        Dimension{
            .kind = try DimensionKind.parse(dimension_name),
            .property_ref = try parsePropertyRef(
                parts.property_name,
                parts.property_type,
            ),
        }
    else blk: {
        if (parts.property_name != null or parts.property_type != null) {
            return error.UnexpectedAnalysisProperty;
        }
        break :blk null;
    };
    const query = Query{
        .site_id = site_id,
        .range = .{
            .start = parts.from orelse return error.MissingAnalysisUrlField,
            .end = parts.to orelse return error.MissingAnalysisUrlField,
        },
        .comparison = try Comparison.parse(
            parts.compare orelse return error.MissingAnalysisUrlField,
        ),
        .mode = try Mode.parse(parts.mode orelse return error.MissingAnalysisUrlField),
        .metric = .{
            .kind = try MetricKind.parse(
                parts.metric orelse return error.MissingAnalysisUrlField,
            ),
            .selector = selector,
            .conversion_basis = if (parts.conversion_basis) |basis|
                try ConversionBasis.parse(basis)
            else
                null,
        },
        .dimension = dimension,
        .search = parts.search orelse "",
        .interval = try Interval.parse(
            parts.interval orelse return error.MissingAnalysisUrlField,
        ),
        .filters = .{ .clauses = try clauses.toOwnedSlice(allocator) },
        .segment_id = parts.segment,
        .sort = try Sort.parse(parts.sort orelse return error.MissingAnalysisUrlField),
        .page = std.fmt.parseInt(
            u32,
            parts.page orelse return error.MissingAnalysisUrlField,
            10,
        ) catch return error.InvalidAnalysisPage,
        .limit = std.fmt.parseInt(
            u16,
            parts.limit orelse return error.MissingAnalysisUrlField,
            10,
        ) catch return error.InvalidAnalysisLimit,
    };
    try query.validate();
    return query;
}

pub fn parseFormPredicate(
    allocator: std.mem.Allocator,
    raw_value: []const u8,
) !PropertyPredicate {
    return parsePredicate(
        allocator,
        try formGrammarValue(allocator, raw_value),
    );
}

pub fn parseFormClause(
    allocator: std.mem.Allocator,
    raw_value: []const u8,
) !Clause {
    return parseClause(
        allocator,
        try formGrammarValue(allocator, raw_value),
    );
}

fn formGrammarValue(
    allocator: std.mem.Allocator,
    raw_value: []const u8,
) ![]const u8 {
    if (std.mem.findScalar(u8, raw_value, '~') != null) return raw_value;
    const decoded = try percentDecode(allocator, raw_value);
    if (std.mem.findScalar(u8, decoded, '~') == null) {
        return error.InvalidAnalysisUrl;
    }
    return decoded;
}

fn encodedClauses(
    allocator: std.mem.Allocator,
    clauses: []const Clause,
) ![]const []const u8 {
    const encoded = try allocator.alloc([]const u8, clauses.len);
    for (clauses, 0..) |clause, index| {
        encoded[index] = try encodeClause(allocator, clause);
    }
    return sortUnique(encoded);
}

fn encodedPredicates(
    allocator: std.mem.Allocator,
    predicates: []const PropertyPredicate,
) ![]const []const u8 {
    const encoded = try allocator.alloc([]const u8, predicates.len);
    for (predicates, 0..) |predicate, index| {
        encoded[index] = try canonicalPredicate(allocator, predicate);
    }
    return sortUnique(encoded);
}

fn sortUnique(values: [][]const u8) []const []const u8 {
    std.mem.sort([]const u8, values, {}, lessThanString);
    var written: usize = 0;
    for (values) |value| {
        if (written != 0 and std.mem.eql(u8, values[written - 1], value)) continue;
        values[written] = value;
        written += 1;
    }
    return values[0..written];
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn encodeClause(allocator: std.mem.Allocator, clause: Clause) ![]u8 {
    try clause.validate();
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    try writeGrammarComponent(&output.writer, clause.scope.name(), false);
    try writeGrammarComponent(&output.writer, clause.field.kind.name(), true);
    if (clause.field.property_ref) |reference| {
        try writeGrammarComponent(&output.writer, reference.name, true);
    }
    try writeGrammarComponent(&output.writer, clause.operator.name(), true);
    try writeGrammarComponent(&output.writer, clause.scalar_type.name(), true);
    try writeSortedValues(
        allocator,
        &output.writer,
        clause.scalar_type,
        clause.values,
    );
    return output.toOwnedSlice();
}

pub fn canonicalPredicate(
    allocator: std.mem.Allocator,
    predicate: PropertyPredicate,
) ![]u8 {
    try predicate.validate();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    try writeGrammarComponent(&output.writer, predicate.property_ref.name, false);
    try writeGrammarComponent(&output.writer, predicate.operator.name(), true);
    try writeGrammarComponent(
        &output.writer,
        predicate.property_ref.scalar_type.name(),
        true,
    );
    try writeSortedValues(
        scratch.allocator(),
        &output.writer,
        predicate.property_ref.scalar_type,
        predicate.values,
    );
    return output.toOwnedSlice();
}

test "canonical predicate owns only its returned slice" {
    const values = [_][]const u8{ "14.250000", "7.000000" };
    const predicate = PropertyPredicate{
        .property_ref = .{ .name = "amount", .scalar_type = .decimal },
        .operator = .is,
        .values = &values,
    };
    for (0..64) |_| {
        const encoded = try canonicalPredicate(std.testing.allocator, predicate);
        try std.testing.expectEqualStrings(
            "amount~is~decimal~14.250000~7.000000",
            encoded,
        );
        std.testing.allocator.free(encoded);
    }
}

test "canonical predicate-set JSON is exact ordered and collision-safe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const low_values = [_][]const u8{ "yearly", "monthly" };
    const high_values = [_][]const u8{ "year", "lymonthly" };
    const predicates = [_]PropertyPredicate{
        .{
            .property_ref = .{ .name = "plan", .scalar_type = .string },
            .operator = .is,
            .values = &.{"pro"},
        },
        .{
            .property_ref = .{ .name = "billing_period", .scalar_type = .string },
            .operator = .is,
            .values = &low_values,
        },
    };
    const json = try canonicalPredicateSetJson(std.testing.allocator, &predicates);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"schema\":1,\"predicates\":[\"billing_period~is~string~monthly~yearly\",\"plan~is~string~pro\"]}",
        json,
    );
    const parsed = try parseExactCanonicalPredicateSetJson(allocator, json);
    try std.testing.expectEqual(@as(usize, 2), parsed.len);

    var changed = predicates;
    changed[1].values = &high_values;
    const changed_json = try canonicalPredicateSetJson(
        std.testing.allocator,
        &changed,
    );
    defer std.testing.allocator.free(changed_json);
    try std.testing.expect(!std.mem.eql(u8, json, changed_json));
    try std.testing.expectError(
        error.NonCanonicalAnalysisJson,
        parseExactCanonicalPredicateSetJson(
            allocator,
            "{\"schema\":1,\"predicates\":[\"plan~is~string~pro\",\"billing_period~is~string~yearly~monthly\"]}",
        ),
    );
    try std.testing.expectError(
        error.InvalidAnalysisJson,
        parseExactCanonicalPredicateSetJson(
            allocator,
            "{\"schema\":1,\"predicates\":[],\"extra\":true}",
        ),
    );
}

fn writeSortedValues(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    scalar_type: ScalarType,
    values: []const []const u8,
) !void {
    const sorted = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, index| {
        sorted[index] = try canonicalEncodedValue(allocator, scalar_type, value);
    }
    std.mem.sort([]const u8, sorted, {}, lessThanString);
    var previous: ?[]const u8 = null;
    for (sorted) |value| {
        if (previous) |seen| if (std.mem.eql(u8, seen, value)) continue;
        try output.writeByte('~');
        try output.writeAll(value);
        previous = value;
    }
}

fn canonicalEncodedValue(
    allocator: std.mem.Allocator,
    scalar_type: ScalarType,
    value: []const u8,
) ![]u8 {
    if (scalar_type != .integer and scalar_type != .decimal) {
        return encodedComponent(allocator, value);
    }
    var number = std.Io.Writer.Allocating.init(allocator);
    try property.writeCanonicalNumber(&number.writer, value);
    const normalized = try number.toOwnedSlice();
    return encodedComponent(allocator, normalized);
}

fn parseClauses(
    allocator: std.mem.Allocator,
    encoded: []const []const u8,
) ![]Clause {
    if (encoded.len > maximum_clauses) return error.TooManyAnalysisClauses;
    const clauses = try allocator.alloc(Clause, encoded.len);
    for (encoded, 0..) |value, index| {
        clauses[index] = try parseClause(allocator, value);
    }
    return clauses;
}

fn parsePredicates(
    allocator: std.mem.Allocator,
    encoded: []const []const u8,
) ![]PropertyPredicate {
    if (encoded.len > maximum_selector_predicates) {
        return error.TooManySelectorPredicates;
    }
    const predicates = try allocator.alloc(PropertyPredicate, encoded.len);
    for (encoded, 0..) |value, index| {
        predicates[index] = try parsePredicate(allocator, value);
    }
    return predicates;
}

fn parseClause(allocator: std.mem.Allocator, encoded: []const u8) !Clause {
    var components = std.mem.splitScalar(u8, encoded, '~');
    const scope = try Scope.parse(try decodeNext(allocator, &components));
    const field_kind = try FieldKind.parse(try decodeNext(allocator, &components));
    if (field_kind.requiresProperty()) {
        const name = try decodeNext(allocator, &components);
        const operator_name = try decodeNext(allocator, &components);
        const scalar_name = try decodeNext(allocator, &components);
        const scalar_type = try ScalarType.parse(scalar_name);
        const values = try decodeRemaining(allocator, &components);
        const clause = Clause{
            .scope = scope,
            .field = .{
                .kind = field_kind,
                .property_ref = .{ .name = name, .scalar_type = scalar_type },
            },
            .operator = try Operator.parse(operator_name),
            .scalar_type = scalar_type,
            .values = values,
        };
        try clause.validate();
        return clause;
    }
    const operator = try Operator.parse(try decodeNext(allocator, &components));
    const scalar_type = try ScalarType.parse(try decodeNext(allocator, &components));
    const clause = Clause{
        .scope = scope,
        .field = .{ .kind = field_kind },
        .operator = operator,
        .scalar_type = scalar_type,
        .values = try decodeRemaining(allocator, &components),
    };
    try clause.validate();
    return clause;
}

fn parsePredicate(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) !PropertyPredicate {
    var components = std.mem.splitScalar(u8, encoded, '~');
    const name = try decodeNext(allocator, &components);
    const operator = try Operator.parse(try decodeNext(allocator, &components));
    const scalar_type = try ScalarType.parse(try decodeNext(allocator, &components));
    const predicate = PropertyPredicate{
        .property_ref = .{ .name = name, .scalar_type = scalar_type },
        .operator = operator,
        .values = try decodeRemaining(allocator, &components),
    };
    try predicate.validate();
    return predicate;
}

fn decodeNext(
    allocator: std.mem.Allocator,
    components: *std.mem.SplitIterator(u8, .scalar),
) ![]const u8 {
    const component = components.next() orelse return error.InvalidAnalysisGrammar;
    if (component.len == 0) return error.InvalidAnalysisGrammar;
    return percentDecode(allocator, component);
}

fn decodeRemaining(
    allocator: std.mem.Allocator,
    components: *std.mem.SplitIterator(u8, .scalar),
) ![]const []const u8 {
    var values: std.ArrayList([]const u8) = .empty;
    while (components.next()) |component| {
        if (values.items.len >= maximum_values or component.len == 0) {
            return error.TooManyAnalysisValues;
        }
        try values.append(allocator, try percentDecode(allocator, component));
    }
    return values.toOwnedSlice(allocator);
}

fn parsePropertyRef(
    name: ?[]const u8,
    scalar_type: ?[]const u8,
) !?PropertyRef {
    if ((name == null) != (scalar_type == null)) {
        return error.IncompleteAnalysisProperty;
    }
    if (name == null) return null;
    return .{
        .name = name.?,
        .scalar_type = try ScalarType.parse(scalar_type.?),
    };
}

fn setUrlPart(parts: *UrlParts, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "v")) return setOnce(&parts.version, value);
    if (std.mem.eql(u8, key, "from")) return setOnce(&parts.from, value);
    if (std.mem.eql(u8, key, "to")) return setOnce(&parts.to, value);
    if (std.mem.eql(u8, key, "compare")) return setOnce(&parts.compare, value);
    if (std.mem.eql(u8, key, "mode")) return setOnce(&parts.mode, value);
    if (std.mem.eql(u8, key, "metric")) return setOnce(&parts.metric, value);
    if (std.mem.eql(u8, key, "conversion-basis")) {
        return setOnce(&parts.conversion_basis, value);
    }
    if (std.mem.eql(u8, key, "selector")) return setOnce(&parts.selector, value);
    if (std.mem.eql(u8, key, "selector-value")) {
        return setOnce(&parts.selector_value, value);
    }
    if (std.mem.eql(u8, key, "dimension")) return setOnce(&parts.dimension, value);
    if (std.mem.eql(u8, key, "property")) return setOnce(&parts.property_name, value);
    if (std.mem.eql(u8, key, "property-type")) {
        return setOnce(&parts.property_type, value);
    }
    if (std.mem.eql(u8, key, "search")) return setOnce(&parts.search, value);
    if (std.mem.eql(u8, key, "interval")) return setOnce(&parts.interval, value);
    if (std.mem.eql(u8, key, "segment")) return setOnce(&parts.segment, value);
    if (std.mem.eql(u8, key, "sort")) return setOnce(&parts.sort, value);
    if (std.mem.eql(u8, key, "page")) return setOnce(&parts.page, value);
    if (std.mem.eql(u8, key, "limit")) return setOnce(&parts.limit, value);
    return error.UnknownAnalysisUrlParameter;
}

fn setOnce(target: *?[]const u8, value: []const u8) !void {
    if (target.* != null) return error.DuplicateAnalysisUrlParameter;
    target.* = value;
}

fn writeParameter(
    output: *std.Io.Writer,
    first: *bool,
    key: []const u8,
    value: []const u8,
) !void {
    if (!first.*) try output.writeByte('&');
    first.* = false;
    try output.writeAll(key);
    try output.writeByte('=');
    try writePercentComponent(output, value);
}

fn writeRawParameter(
    output: *std.Io.Writer,
    first: *bool,
    key: []const u8,
    value: []const u8,
) !void {
    if (!first.*) try output.writeByte('&');
    first.* = false;
    try output.writeAll(key);
    try output.writeByte('=');
    try output.writeAll(value);
}

fn writeGrammarComponent(
    output: *std.Io.Writer,
    value: []const u8,
    separator: bool,
) !void {
    if (separator) try output.writeByte('~');
    try writePercentComponent(output, value);
}

fn encodedComponent(
    allocator: std.mem.Allocator,
    value: []const u8,
) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    try writePercentComponent(&output.writer, value);
    return output.toOwnedSlice();
}

fn writePercentComponent(output: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or
            byte == '.')
        {
            try output.writeByte(byte);
        } else {
            try output.writeByte('%');
            try output.writeByte(hex[byte >> 4]);
            try output.writeByte(hex[byte & 0x0f]);
        }
    }
}

fn percentDecode(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) ![]const u8 {
    if (encoded.len == 0 or std.mem.findScalar(u8, encoded, '+') != null) {
        return error.InvalidAnalysisPercentEncoding;
    }
    const output = try allocator.alloc(u8, encoded.len);
    var read: usize = 0;
    var written: usize = 0;
    while (read < encoded.len) {
        if (encoded[read] != '%') {
            output[written] = encoded[read];
            read += 1;
            written += 1;
            continue;
        }
        if (read + 2 >= encoded.len) return error.InvalidAnalysisPercentEncoding;
        const high = try uppercaseHex(encoded[read + 1]);
        const low = try uppercaseHex(encoded[read + 2]);
        output[written] = high << 4 | low;
        read += 3;
        written += 1;
    }
    if (!std.unicode.utf8ValidateSlice(output[0..written])) {
        return error.InvalidAnalysisPercentEncoding;
    }
    return allocator.realloc(output, written);
}

fn uppercaseHex(byte: u8) !u8 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'A' and byte <= 'F') return byte - 'A' + 10;
    return error.InvalidAnalysisPercentEncoding;
}

fn validateFieldScope(field: FieldKind, scope: Scope) !void {
    switch (field) {
        .landing_page,
        .exit_page,
        .channel,
        .session_converted,
        .session_duration_ms,
        .session_engagement_ms,
        => if (scope != .session) return error.InvalidAnalysisFieldScope,
        .user_trait, .identity_state => if (scope != .person) {
            return error.InvalidAnalysisFieldScope;
        },
        else => {},
    }
}

fn validateFieldType(field: Field, scalar_type: ScalarType) !void {
    if (field.property_ref) |reference| {
        if (reference.scalar_type != scalar_type) {
            return error.AnalysisPropertyTypeMismatch;
        }
        return;
    }
    switch (field.kind) {
        .session_duration_ms, .session_engagement_ms => if (scalar_type != .integer) {
            return error.InvalidAnalysisFieldType;
        },
        .session_converted => if (scalar_type != .boolean) {
            return error.InvalidAnalysisFieldType;
        },
        else => if (scalar_type != .string) {
            return error.InvalidAnalysisFieldType;
        },
    }
}

fn validateOperator(
    operator: Operator,
    scalar_type: ScalarType,
    value_count: usize,
) !void {
    const requires_values = switch (operator) {
        .is, .is_not => scalar_type != .null and scalar_type != .missing,
        .contains,
        .not_contains,
        .starts_with,
        .gt,
        .gte,
        .lt,
        .lte,
        => true,
        .is_true, .is_false, .exists, .absent => false,
    };
    if (requires_values != (value_count != 0)) {
        return error.InvalidAnalysisOperatorValues;
    }
    switch (scalar_type) {
        .string => switch (operator) {
            .is, .is_not, .contains, .not_contains, .starts_with, .exists, .absent => {},
            else => return error.InvalidAnalysisOperatorType,
        },
        .integer, .decimal => switch (operator) {
            .is, .is_not, .gt, .gte, .lt, .lte, .exists, .absent => {},
            else => return error.InvalidAnalysisOperatorType,
        },
        .boolean => switch (operator) {
            .is_true, .is_false, .exists, .absent => {},
            else => return error.InvalidAnalysisOperatorType,
        },
        .null => switch (operator) {
            .is, .is_not, .exists, .absent => {},
            else => return error.InvalidAnalysisOperatorType,
        },
        .missing => switch (operator) {
            .is, .is_not => {},
            else => return error.InvalidAnalysisOperatorType,
        },
    }
    if (value_count > 1 and switch (operator) {
        .is, .is_not, .contains, .not_contains, .starts_with => false,
        else => true,
    }) {
        return error.TooManyAnalysisOperatorValues;
    }
}

fn validateValue(scalar_type: ScalarType, value: []const u8) !void {
    if (value.len == 0 or value.len > maximum_filter_value_bytes or
        !std.unicode.utf8ValidateSlice(value))
    {
        return error.InvalidAnalysisValue;
    }
    switch (scalar_type) {
        .integer => if (try property.numberType(value) != .integer) {
            return error.InvalidAnalysisValue;
        },
        .decimal => if (try property.numberType(value) != .decimal) {
            return error.InvalidAnalysisValue;
        },
        .boolean, .null, .missing => return error.InvalidAnalysisValue,
        .string => {},
    }
}

test "typed analysis query validates closed modes and preset boundary" {
    const range: LocalDateRange = .{ .start = "2026-01-01", .end = "2026-01-31" };
    const site = "00000000-0000-4000-8000-000000000024";
    const pages = presetQuery(.pages, site, range);
    try pages.validate();
    try std.testing.expectEqual(Mode.breakdown, pages.mode);
    try std.testing.expectEqual(DimensionKind.page, pages.dimension.?.kind);
    try std.testing.expectEqual(
        Preset.campaigns_source,
        presetForCurrentReport(.campaigns, .source).analysis,
    );
    try std.testing.expectEqual(
        CurrentReportPreset.funnel,
        presetForCurrentReport(.funnel, .all),
    );
    try std.testing.expectEqual(
        CurrentReportPreset.campaign_tuple,
        presetForCurrentReport(.campaigns, .all),
    );

    inline for (@typeInfo(report.Kind).@"enum".field_values) |raw| {
        const kind: report.Kind = @fromBackingInt(@intCast(raw));
        const current = presetForCurrentReport(kind, .source);
        if (current == .analysis) {
            try presetQuery(current.analysis, site, range).validate();
        }
    }
    inline for (@typeInfo(report.CampaignDimension).@"enum".field_values) |raw| {
        const dimension: report.CampaignDimension = @fromBackingInt(@intCast(raw));
        const current = presetForCurrentReport(.campaigns, dimension);
        if (current == .analysis) {
            try presetQuery(current.analysis, site, range).validate();
        } else {
            try std.testing.expectEqual(CurrentReportPreset.campaign_tuple, current);
        }
    }
}

test "typed filters enforce scope type operator and value bounds" {
    const valid = Clause{
        .scope = .session,
        .field = .{ .kind = .device },
        .operator = .is,
        .scalar_type = .string,
        .values = &.{ "mobile", "desktop" },
    };
    try valid.validate();
    var wrong_scope = valid;
    wrong_scope.field = .{ .kind = .session_duration_ms };
    try std.testing.expectError(
        error.InvalidAnalysisFieldType,
        wrong_scope.validate(),
    );
    var too_many: [maximum_values + 1][]const u8 = undefined;
    @memset(&too_many, "x");
    var invalid = valid;
    invalid.values = &too_many;
    try std.testing.expectError(error.TooManyAnalysisValues, invalid.validate());
}

test "canonical FilterSet JSON is exact and composition deduplicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const values = [_][]const u8{ "mobile", "desktop", "mobile" };
    const clause = Clause{
        .scope = .session,
        .field = .{ .kind = .device },
        .operator = .is,
        .scalar_type = .string,
        .values = &values,
    };
    const first = [_]Clause{clause};
    const second = [_]Clause{clause};
    const composed = try composeFilterSets(
        allocator,
        .{ .clauses = &first },
        .{ .clauses = &second },
    );
    try std.testing.expectEqual(@as(usize, 1), composed.clauses.len);
    const json = try canonicalFilterJson(std.testing.allocator, composed);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"schema\":1,\"match\":\"all\",\"filters\":[\"session~device~is~string~desktop~mobile\"]}",
        json,
    );
    const parsed = try parseExactCanonicalFilterJson(allocator, json);
    try std.testing.expectEqual(@as(usize, 1), parsed.clauses.len);
    try std.testing.expectError(
        error.NonCanonicalAnalysisJson,
        parseExactCanonicalFilterJson(
            allocator,
            "{\"schema\":1,\"match\":\"all\",\"filters\":[\"session~device~is~string~mobile~desktop\"]}",
        ),
    );

    const legacy_values = [_][]const u8{"=SUM(\"x\")\nnext"};
    const legacy_clause = Clause{
        .scope = .session,
        .field = .{ .kind = .utm_source },
        .operator = .is,
        .scalar_type = .string,
        .values = &legacy_values,
    };
    const legacy_encoded = try canonicalClause(
        std.testing.allocator,
        legacy_clause,
    );
    defer std.testing.allocator.free(legacy_encoded);
    try std.testing.expectEqualStrings(
        "session~utm-source~is~string~%3DSUM%28%22x%22%29%0Anext",
        legacy_encoded,
    );
    const legacy_round_trip = try parseCanonicalClause(allocator, legacy_encoded);
    try std.testing.expectEqualStrings(
        legacy_values[0],
        legacy_round_trip.values[0],
    );
}

test "canonical Overview URLs enforce the shared 16 KiB bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var values: [maximum_values][]const u8 = undefined;
    for (&values, 0..) |*value, index| {
        const generated = try allocator.alloc(u8, maximum_filter_value_bytes);
        @memset(generated, 'x');
        generated[0] = @intCast('A' + index);
        value.* = generated;
    }
    const clauses = [_]Clause{.{
        .scope = .event,
        .field = .{ .kind = .page_title },
        .operator = .is,
        .scalar_type = .string,
        .values = &values,
    }};
    try std.testing.expectError(
        error.AnalysisUrlTooLong,
        canonicalOverviewUrl(
            std.testing.allocator,
            .{ .start = "2026-08-01", .end = "2026-08-07" },
            .previous,
            .visitors,
            "",
            null,
            .{ .clauses = &clauses },
        ),
    );
}

test "Trend set canonical URL and JSON preserve filters and segment" {
    const filter_values = [_][]const u8{"DE"};
    const clauses = [_]Clause{.{
        .scope = .session,
        .field = .{ .kind = .country },
        .operator = .is,
        .scalar_type = .string,
        .values = &filter_values,
    }};
    const series = [_]Metric{.{ .kind = .visitors }};
    const set = TrendSet{
        .site_id = "00000000-0000-4000-8000-000000000030",
        .range = .{ .start = "2026-08-01", .end = "2026-08-07" },
        .comparison = .previous,
        .interval = .day,
        .series = &series,
        .filters = .{ .clauses = &clauses },
        .segment_id = "00000000-0000-4000-8000-000000000031",
    };
    const url = try canonicalTrendSetUrl(
        std.testing.allocator,
        set,
        "2026-08-07",
    );
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "v=1&from=2026-08-01&to=2026-08-07&compare=previous&mode=trend" ++
            "&interval=day&series=visitors" ++
            "&segment=00000000-0000-4000-8000-000000000031" ++
            "&highlight=2026-08-07&f=session~country~is~string~DE",
        url,
    );
    var url_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer url_arena.deinit();
    const parsed_url = try parseCanonicalTrendSetUrl(
        url_arena.allocator(),
        set.site_id,
        url,
    );
    try std.testing.expectEqualStrings("2026-08-07", parsed_url.highlight);
    try std.testing.expectEqual(@as(usize, 1), parsed_url.set.filters.clauses.len);
    const json = try canonicalTrendSetJson(std.testing.allocator, set);
    defer std.testing.allocator.free(json);
    var json_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer json_arena.deinit();
    const parsed_json = try parseExactCanonicalTrendSetJson(
        json_arena.allocator(),
        json,
    );
    try std.testing.expectEqual(@as(usize, 1), parsed_json.filters.clauses.len);
    try std.testing.expectEqualStrings(set.segment_id.?, parsed_json.segment_id.?);
}

test "metric selectors and resolved comparisons fail before execution" {
    const query = Query{
        .site_id = "00000000-0000-4000-8000-000000000024",
        .range = .{ .start = "2026-01-01", .end = "2026-01-02" },
        .mode = .trend,
        .metric = .{ .kind = .event_count },
    };
    try std.testing.expectError(error.MissingMetricSelector, query.validate());

    var page_views = query;
    page_views.metric = .{ .kind = .page_views };
    const execution = Execution{
        .query = page_views,
        .comparison_range = .{ .start = "2025-12-30", .end = "2025-12-31" },
    };
    try std.testing.expectError(
        error.InvalidResolvedComparison,
        execution.validate(),
    );
    var noncanonical = page_views;
    noncanonical.metric = .{
        .kind = .event_count,
        .selector = .{ .kind = .exact_page, .value = "/pricing?coupon=secret" },
    };
    try std.testing.expectError(
        error.NonCanonicalPageSelector,
        noncanonical.validate(),
    );
    var breakdown = presetQuery(
        .pages,
        query.site_id,
        query.range,
    );
    breakdown.comparison = .previous;
    try std.testing.expectError(
        error.BreakdownHasComparison,
        breakdown.validate(),
    );

    var segmented = page_views;
    segmented.segment_id = "00000000-0000-4000-8000-000000000030";
    try std.testing.expectError(
        error.UnresolvedAnalysisSegment,
        (Execution{ .query = segmented }).validate(),
    );
}

test "explicit selected goals resolve separately from the active snapshot" {
    const archived_id = "00000000-0000-4000-8000-000000000033";
    const selected = EventSelector{
        .kind = .saved_goal,
        .value = archived_id,
    };
    const active = [_]ResolvedGoal{.{
        .id = "00000000-0000-4000-8000-000000000034",
        .selector = .{ .kind = .exact_event, .value = "active" },
    }};
    const explicit = [_]ResolvedGoal{.{
        .id = archived_id,
        .selector = .{ .kind = .exact_event, .value = "archived" },
    }};
    try std.testing.expectError(
        error.UnresolvedGoalSelector,
        resolvedSelector(selected, &active),
    );
    const resolved = (try resolvedSelectorSets(
        selected,
        &active,
        &explicit,
    )).?;
    try std.testing.expectEqual(SelectorKind.exact_event, resolved.selector.kind);
    try std.testing.expectEqualStrings("archived", resolved.selector.value);

    try std.testing.expectError(
        error.DuplicateResolvedGoal,
        (Execution{
            .query = .{
                .site_id = "00000000-0000-4000-8000-000000000035",
                .range = .{ .start = "2025-01-01", .end = "2025-01-02" },
                .mode = .trend,
                .metric = .{ .kind = .visitors },
                .interval = .day,
            },
            .active_goals = &active,
            .selected_goals = &active,
        }).validate(),
    );
}

test "browser Trend series grammar and set remain finite and canonical" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const goal = "00000000-0000-4000-8000-000000000028";
    const cases = [_]Metric{
        .{ .kind = .visitors },
        .{
            .kind = .event_count,
            .selector = .{ .kind = .exact_event, .value = "sign_up" },
        },
        .{
            .kind = .conversion_rate,
            .conversion_basis = .visitor,
            .selector = .{ .kind = .saved_goal, .value = goal },
        },
        .{
            .kind = .average_value,
            .selector = .{ .kind = .exact_event, .value = "purchase" },
        },
    };
    const expected = [_][]const u8{
        "visitors",
        "event-count~event~sign_up",
        "conversion-rate~visitor~goal~00000000-0000-4000-8000-000000000028",
        "average-value~event~purchase",
    };
    for (cases, expected) |metric, encoded| {
        const canonical = try canonicalTrendSeries(allocator, metric);
        try std.testing.expectEqualStrings(encoded, canonical);
        const parsed = try parseTrendSeries(allocator, encoded);
        try std.testing.expect(metricsEqual(metric, parsed));
    }

    try std.testing.expectError(
        error.InvalidTrendSeries,
        parseTrendSeries(allocator, "event-count~page~%2Fpricing"),
    );
    try std.testing.expectError(
        error.InvalidTrendSeries,
        parseTrendSeries(allocator, "conversions~session~goal~" ++ goal),
    );
    try std.testing.expectError(
        error.InvalidTrendSeries,
        parseTrendSeries(allocator, "visitors~event~signup"),
    );
    try std.testing.expectError(
        error.InvalidAnalysisPercentEncoding,
        parseTrendSeries(allocator, "event-count~event~sign%5fup"),
    );
    try std.testing.expectError(
        error.InvalidAnalysisMetric,
        parseTrendSeries(allocator, "goal-matches"),
    );
    try std.testing.expectError(
        error.InvalidEventSelector,
        parseTrendSeries(allocator, "revenue~currency~EUR"),
    );

    const revenue_query = Query{
        .site_id = "00000000-0000-4000-8000-000000000024",
        .range = .{ .start = "2026-01-01", .end = "2026-01-02" },
        .mode = .trend,
        .metric = .{ .kind = .revenue },
        .interval = .day,
    };
    const revenue_url = try canonicalUrl(allocator, revenue_query);
    try std.testing.expectEqualStrings(
        "v=1&from=2026-01-01&to=2026-01-02&compare=none&mode=trend&metric=revenue&interval=day&sort=value-desc&page=1&limit=25",
        revenue_url,
    );
    const parsed_revenue = try parseCanonicalUrl(
        allocator,
        revenue_query.site_id,
        revenue_url,
    );
    try std.testing.expect(metricsEqual(revenue_query.metric, parsed_revenue.metric));

    const duplicate = [_]Metric{ cases[0], cases[0] };
    try std.testing.expectError(error.DuplicateTrendSeries, (TrendSet{
        .site_id = "00000000-0000-4000-8000-000000000024",
        .range = .{ .start = "2026-01-01", .end = "2026-01-02" },
        .series = &duplicate,
    }).validate());
    try std.testing.expectError(error.InvalidTrendSeriesCount, (TrendSet{
        .site_id = "00000000-0000-4000-8000-000000000024",
        .range = .{ .start = "2026-01-01", .end = "2026-01-02" },
        .series = &.{},
    }).validate());
}

test "canonical Trend set releases compact-series intermediates" {
    const metrics = [_]Metric{
        .{ .kind = .visitors },
        .{ .kind = .sessions },
        .{
            .kind = .event_count,
            .selector = .{ .kind = .exact_event, .value = "signup" },
        },
    };
    const set = TrendSet{
        .site_id = "00000000-0000-4000-8000-000000000028",
        .range = .{ .start = "2026-01-01", .end = "2026-01-02" },
        .comparison = .previous,
        .interval = .day,
        .series = &metrics,
    };
    for (0..64) |_| {
        const url = try canonicalTrendSetUrl(
            std.testing.allocator,
            set,
            "2026-01-01",
        );
        try std.testing.expect(std.mem.indexOf(u8, url, "series=event-count~event~signup") != null);
        std.testing.allocator.free(url);
    }
}

test "canonical URL normalizes equivalent typed query state" {
    const allocator = std.testing.allocator;
    const values = [_][]const u8{ "pro &= ~ plan", "free", "free" };
    const selector_values = [_][]const u8{"14.25"};
    const filter = Clause{
        .scope = .event,
        .field = .{
            .kind = .event_property,
            .property_ref = .{ .name = "plan.tier:v2", .scalar_type = .string },
        },
        .operator = .is_not,
        .scalar_type = .string,
        .values = &values,
    };
    const filters = [_]Clause{ filter, filter };
    const predicates = [_]PropertyPredicate{.{
        .property_ref = .{ .name = "amount", .scalar_type = .decimal },
        .operator = .gte,
        .values = &selector_values,
    }};
    const query = Query{
        .site_id = "00000000-0000-4000-8000-000000000024",
        .range = .{ .start = "2026-01-01", .end = "2026-01-31" },
        .mode = .breakdown,
        .metric = .{
            .kind = .event_count,
            .selector = .{
                .kind = .page_prefix,
                .value = "/pricing",
                .predicates = &predicates,
            },
        },
        .dimension = .{
            .kind = .event_property,
            .property_ref = .{ .name = "plan", .scalar_type = .string },
        },
        .filters = .{ .clauses = &filters },
        .sort = .label_asc,
        .page = 2,
        .limit = 50,
    };
    const encoded = try canonicalUrl(allocator, query);
    defer allocator.free(encoded);
    try std.testing.expect(std.mem.find(u8, encoded, "%26") != null);
    try std.testing.expect(std.mem.find(u8, encoded, "%3D") != null);
    try std.testing.expect(std.mem.find(u8, encoded, "%7E") != null);
    try std.testing.expect(std.mem.find(u8, encoded, "+") == null);
    try std.testing.expect(std.mem.find(u8, encoded, "14.250000") != null);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try parseCanonicalUrl(arena.allocator(), query.site_id, encoded);
    try std.testing.expectEqual(@as(u32, 2), parsed.page);
    try std.testing.expectEqual(@as(usize, 1), parsed.filters.clauses.len);
    const normalized = try canonicalUrl(allocator, parsed);
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings(encoded, normalized);
}

test "canonical parser accepts one browser form encoding of grammar separators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const query = try parseCanonicalUrl(
        arena.allocator(),
        "00000000-0000-4000-8000-000000000024",
        "v=1&from=2026-01-01&to=2026-01-31&compare=none&mode=breakdown" ++
            "&metric=event-count&selector=event&selector-value=signup" ++
            "&dimension=event-property&property=plan&property-type=string" ++
            "&interval=auto&sort=value-desc&page=1&limit=25" ++
            "&p=amount%7Egte%7Edecimal%7E14.25",
    );
    try std.testing.expectEqual(@as(usize, 1), query.metric.selector.?.predicates.len);
    try std.testing.expectEqualStrings(
        "amount",
        query.metric.selector.?.predicates[0].property_ref.name,
    );
    const canonical = try canonicalUrl(std.testing.allocator, query);
    defer std.testing.allocator.free(canonical);
    try std.testing.expect(
        std.mem.indexOf(u8, canonical, "p=amount~gte~decimal~14.250000") != null,
    );

    const encoded_data = try parseCanonicalUrl(
        arena.allocator(),
        "00000000-0000-4000-8000-000000000024",
        "v=1&from=2026-01-01&to=2026-01-31&compare=none&mode=breakdown" ++
            "&metric=event-count&selector=event&selector-value=signup" ++
            "&dimension=event-property&property=plan&property-type=string" ++
            "&interval=auto&sort=value-desc&page=1&limit=25" ++
            "&p=plan%7Eis%7Estring%7Epro%2520%2526%2520%257E%2520plan",
    );
    try std.testing.expectEqualStrings(
        "pro & ~ plan",
        encoded_data.metric.selector.?.predicates[0].values[0],
    );
    const encoded_data_canonical = try canonicalUrl(
        std.testing.allocator,
        encoded_data,
    );
    defer std.testing.allocator.free(encoded_data_canonical);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoded_data_canonical,
        "p=plan~is~string~pro%20%26%20%7E%20plan",
    ) != null);

    const prefix = "v=1&from=2026-01-01&to=2026-01-31&compare=none&mode=breakdown" ++
        "&metric=event-count&selector=event&selector-value=signup" ++
        "&dimension=event-property&property=plan&property-type=string" ++
        "&interval=auto&sort=value-desc&page=1&limit=25&p=";
    try std.testing.expectError(
        error.InvalidAnalysisUrl,
        parseCanonicalUrl(
            arena.allocator(),
            "00000000-0000-4000-8000-000000000024",
            prefix ++ "amount%257Egte%257Edecimal%257E14.25",
        ),
    );
    try std.testing.expectError(
        error.InvalidAnalysisPercentEncoding,
        parseCanonicalUrl(
            arena.allocator(),
            "00000000-0000-4000-8000-000000000024",
            prefix ++ "amount%7egte%7edecimal%7e14.25",
        ),
    );
}

test "Breakdown search is canonical bounded and mode specific" {
    const allocator = std.testing.allocator;
    var query = presetQuery(
        .pages,
        "00000000-0000-4000-8000-000000000024",
        .{ .start = "2026-02-01", .end = "2026-02-07" },
    );
    query.search = "Pricing & plans";
    const encoded = try canonicalUrl(allocator, query);
    defer allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoded,
        "dimension=page&search=Pricing%20%26%20plans&interval=auto",
    ) != null);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try parseCanonicalUrl(
        arena.allocator(),
        query.site_id,
        encoded,
    );
    try std.testing.expectEqualStrings(query.search, parsed.search);
    const json = try canonicalJson(allocator, query);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"search\":\"Pricing & plans\"",
    ) != null);

    var trend = presetQuery(.overview_visitors, query.site_id, query.range);
    trend.search = "visitor";
    try std.testing.expectError(error.TrendHasSearch, trend.validate());
    var invalid = query;
    invalid.search = "line\nbreak";
    try std.testing.expectError(error.InvalidAnalysisSearch, invalid.validate());
    invalid.search = "next\xc2\x85line";
    try std.testing.expectError(error.InvalidAnalysisSearch, invalid.validate());
    const too_long = try allocator.alloc(u8, maximum_search_bytes + 1);
    defer allocator.free(too_long);
    @memset(too_long, 'x');
    invalid.search = too_long;
    try std.testing.expectError(error.InvalidAnalysisSearch, invalid.validate());

    var unsupported = query;
    unsupported.metric = .{ .kind = .new_visitors };
    unsupported.dimension = .{
        .kind = .event_property,
        .property_ref = .{ .name = "plan", .scalar_type = .string },
    };
    try std.testing.expectError(
        error.UnsupportedMetricDimension,
        unsupported.validate(),
    );
}

test "canonical saved JSON excludes transient page and round trips" {
    const allocator = std.testing.allocator;
    var query = presetQuery(
        .pages,
        "00000000-0000-4000-8000-000000000024",
        .{ .start = "2026-02-01", .end = "2026-02-07" },
    );
    query.page = 7;
    query.limit = 10;
    const encoded = try canonicalJson(allocator, query);
    defer allocator.free(encoded);
    try std.testing.expect(std.mem.find(u8, encoded, "\"page\":") == null);
    try std.testing.expect(std.mem.find(u8, encoded, "\"search\":") == null);
    try std.testing.expect(std.mem.find(u8, encoded, "\"selector\":") == null);
    try std.testing.expect(std.mem.find(u8, encoded, "\"segment\":") == null);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try parseCanonicalJson(arena.allocator(), encoded);
    try std.testing.expectEqual(@as(u32, 1), parsed.page);
    const normalized = try canonicalJson(allocator, parsed);
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings(encoded, normalized);
}

test "conversion denominator is explicit in canonical URL and JSON" {
    const allocator = std.testing.allocator;
    const query = Query{
        .site_id = "00000000-0000-4000-8000-000000000024",
        .range = .{ .start = "2026-02-01", .end = "2026-02-07" },
        .mode = .trend,
        .metric = .{
            .kind = .conversion_rate,
            .selector = .{ .kind = .exact_event, .value = "purchase" },
            .conversion_basis = .session,
        },
        .interval = .day,
    };
    const url = try canonicalUrl(allocator, query);
    defer allocator.free(url);
    try std.testing.expect(std.mem.find(
        u8,
        url,
        "conversion-basis=session",
    ) != null);
    var url_arena = std.heap.ArenaAllocator.init(allocator);
    defer url_arena.deinit();
    const url_query = try parseCanonicalUrl(
        url_arena.allocator(),
        query.site_id,
        url,
    );
    try std.testing.expectEqual(
        ConversionBasis.session,
        url_query.metric.conversion_basis.?,
    );

    const json = try canonicalJson(allocator, query);
    defer allocator.free(json);
    var json_arena = std.heap.ArenaAllocator.init(allocator);
    defer json_arena.deinit();
    const json_query = try parseCanonicalJson(json_arena.allocator(), json);
    try std.testing.expectEqual(
        ConversionBasis.session,
        json_query.metric.conversion_basis.?,
    );
}

test "canonical parsers reject structural ambiguity and declared bounds" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    const base =
        "v=1&from=2026-01-01&to=2026-01-02&compare=none&mode=trend" ++
        "&metric=page-views&interval=auto&sort=value-desc&page=1&limit=25";
    try std.testing.expectError(
        error.DuplicateAnalysisUrlParameter,
        parseCanonicalUrl(
            arena_allocator,
            "00000000-0000-4000-8000-000000000024",
            base ++ "&limit=50",
        ),
    );
    try std.testing.expectError(
        error.UnknownAnalysisUrlParameter,
        parseCanonicalUrl(
            arena_allocator,
            "00000000-0000-4000-8000-000000000024",
            base ++ "&sql=events",
        ),
    );
    try std.testing.expectError(
        error.InvalidAnalysisPercentEncoding,
        parseCanonicalUrl(
            arena_allocator,
            "00000000-0000-4000-8000-000000000024",
            base ++ "&segment=%2f",
        ),
    );
    var oversized: [maximum_url_bytes + 1]u8 = undefined;
    @memset(&oversized, 'x');
    try std.testing.expectError(
        error.AnalysisUrlTooLong,
        parseCanonicalUrl(
            arena_allocator,
            "00000000-0000-4000-8000-000000000024",
            &oversized,
        ),
    );
    try std.testing.expectError(
        error.InvalidAnalysisJson,
        parseCanonicalJson(
            arena_allocator,
            "{\"schema\":1,\"metric_version\":2,\"unknown\":true}",
        ),
    );
}

test "canonical parsers remain bounded over deterministic malformed corpus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: u64 = 0x24_1a_1c_00_2026;
    var bytes: [256]u8 = undefined;
    for (0..512) |case_index| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        const length: usize = @intCast(state % bytes.len);
        for (bytes[0..length]) |*byte| {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            byte.* = @truncate(state >> 32);
        }
        _ = parseCanonicalUrl(
            arena.allocator(),
            "00000000-0000-4000-8000-000000000024",
            bytes[0..length],
        ) catch {};
        _ = parseCanonicalJson(arena.allocator(), bytes[0..length]) catch {};
        if (case_index % 32 == 31) _ = arena.reset(.retain_capacity);
    }
}
