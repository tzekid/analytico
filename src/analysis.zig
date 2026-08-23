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
    sort: Sort = .value_desc,
    page: u32 = 1,
    limit: u16 = 25,

    pub fn validate(self: Query) !void {
        try domain.validateUuid(self.site_id);
        try self.range.validate();
        try self.metric.validate();
        try self.filters.validate();
        if (self.segment_id) |id| try domain.validateUuid(id);
        if (self.page == 0 or self.page > maximum_page) {
            return error.InvalidAnalysisPage;
        }
        if (self.limit == 0 or self.limit > maximum_limit) {
            return error.InvalidAnalysisLimit;
        }
        switch (self.mode) {
            .trend => {
                if (self.dimension != null) return error.TrendHasDimension;
                if (self.page != 1 or self.limit != 25 or
                    self.sort != .value_desc)
                {
                    return error.TrendHasPagination;
                }
            },
            .breakdown => {
                try (self.dimension orelse
                    return error.BreakdownMissingDimension).validate();
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
        try validateActiveGoals(self.active_goals, self.strict_traffic_mode);
        if (try resolvedSelector(self.query.metric.selector, self.active_goals)) |resolved| {
            if (resolved.selector.predicates.len +
                resolved.additional_predicates.len > maximum_selector_predicates)
            {
                return error.TooManySelectorPredicates;
            }
        }
    }
};

pub const OverviewExecution = struct {
    site_id: []const u8,
    range: LocalDateRange,
    comparison_range: ?LocalDateRange = null,
    active_goals: []const ResolvedGoal = &.{},
    strict_traffic_mode: bool = false,
    timeout_ms: u32 = maximum_timeout_ms,

    pub fn validate(self: OverviewExecution) !void {
        try domain.validateUuid(self.site_id);
        try self.range.validate();
        if (self.comparison_range) |range| try range.validate();
        if (self.timeout_ms == 0 or self.timeout_ms > maximum_timeout_ms) {
            return error.InvalidAnalysisTimeout;
        }
        try validateActiveGoals(self.active_goals, self.strict_traffic_mode);
    }
};

fn validateActiveGoals(
    goals: []const ResolvedGoal,
    strict_traffic_mode: bool,
) !void {
    if (goals.len > maximum_active_goals) return error.TooManyActiveGoals;
    for (goals, 0..) |goal, index| {
        try goal.validate();
        if (strict_traffic_mode and goal.selector.predicates.len != 0) {
            return error.UnsupportedStrictGoalPredicate;
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
        .interval = query.interval.name(),
        .segment = query.segment_id,
        .sort = query.sort.name(),
        .limit = query.limit,
        .filters = filters,
    }, .{}, &output.writer);
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
            try clauses.append(allocator, try parseClause(allocator, raw_value));
        } else if (std.mem.eql(u8, key, "p")) {
            try predicates.append(
                allocator,
                try parsePredicate(allocator, raw_value),
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
        encoded[index] = try encodePredicate(allocator, predicate);
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

fn encodePredicate(
    allocator: std.mem.Allocator,
    predicate: PropertyPredicate,
) ![]u8 {
    try predicate.validate();
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
        allocator,
        &output.writer,
        predicate.property_ref.scalar_type,
        predicate.values,
    );
    return output.toOwnedSlice();
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
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) {
        return error.InvalidAnalysisValue;
    };
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
