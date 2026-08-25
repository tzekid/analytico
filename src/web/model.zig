const analysis = @import("../analysis.zig");
const calendar = @import("../calendar.zig");
const diagnostics = @import("../diagnostics.zig");
const funnel = @import("../funnel.zig");
const meta = @import("../store/meta.zig");
const report = @import("../report.zig");

pub const Destination = enum {
    overview,
    analyze,
    journeys,
    sessions,
    live,
    settings,

    pub fn label(self: Destination) []const u8 {
        return switch (self) {
            .overview => "Overview",
            .analyze => "Analyze",
            .journeys => "Journeys",
            .sessions => "Sessions",
            .live => "Live",
            .settings => "Settings",
        };
    }

    pub fn shortLabel(self: Destination) []const u8 {
        return switch (self) {
            .overview => "Ov",
            .analyze => "An",
            .journeys => "Jo",
            .sessions => "Se",
            .live => "Li",
            .settings => "St",
        };
    }

    pub fn runsReport(self: Destination) bool {
        return switch (self) {
            .overview, .analyze, .journeys, .live => true,
            .sessions, .settings => false,
        };
    }
};

pub const Query = struct {
    site: []const u8 = "",
    analysis_site_id: []const u8 = "",
    range: analysis.LocalDateRange,
    comparison: analysis.Comparison = .previous,
    kind: report.Kind = .overview,
    subject: []const u8 = "",
    campaign_dimension: report.CampaignDimension = .all,
    sort: report.Sort = .count,
    limit: u16 = report.default_limit,
    page: u32 = 1,
    overview_metric: analysis.OverviewTrendMetric = .visitors,
    overview_currency: []const u8 = "",
    highlighted_interval: []const u8 = "",
    analysis_interval: analysis.Interval = .auto,
    analysis_series: []const analysis.Metric = &.{},
    analysis_breakdown: ?analysis.Query = null,
    analysis_filters: analysis.FilterSet = .{},
    analysis_segment_id: ?[]const u8 = null,
    canonical_filter_suffix: []const u8 = "",
    goal_screen: GoalScreen = .none,
    goal_id: []const u8 = "",
    goal_page: u32 = 1,
    goal_entity_kind: analysis.GoalEntityKind = .page,
    goal_search: []const u8 = "",
    goal_entity_page: u32 = 1,
    goal_entity_set: bool = false,
    goal_preview_response: bool = false,
    funnel_screen: FunnelScreen = .none,
    funnel_id: []const u8 = "",
    funnel_page: u32 = 1,
    funnel_preview_response: bool = false,
};

pub const GoalScreen = enum {
    none,
    list,
    new,
    detail,
    edit,
};

pub const FunnelScreen = enum {
    none,
    list,
    new,
    detail,
    edit,
};

pub const ReportTimeBasis = enum {
    none,
    metric_v1_utc,
};

pub const KpiDirection = enum {
    neutral,
    positive,
    negative,
};

pub const KpiTarget = enum {
    analyze,
    goals,
};

pub const OverviewKpi = struct {
    label: []const u8,
    value: []const u8,
    comparison: []const u8,
    direction: KpiDirection,
    definition: []const u8,
    target: KpiTarget,
    analysis_metric: ?analysis.Metric = null,
    legacy_focus_currency: []const u8 = "",
};

pub const OverviewKpis = struct {
    cards: []const OverviewKpi,
    coverage: []const u8,
    comparison_coverage: ?[]const u8,
    includes_incomplete_today: bool,
};

pub const OverviewTrendPoint = struct {
    current_label: ?[]const u8,
    comparison_label: ?[]const u8,
    current: ?analysis.Measure,
    comparison: ?analysis.Measure,
};

pub const OverviewTrend = struct {
    metric: analysis.OverviewTrendMetric,
    currency: []const u8,
    points: []const OverviewTrendPoint,
    revenue_options: []const []const u8,
};

pub const OverviewContentRow = struct {
    label: []const u8,
    page_views: i64,
    visitors: i64,
    share_basis_points: u16,
    filter_url: []const u8 = "",
    exclude_url: []const u8 = "",
};

pub const OverviewAcquisitionRow = struct {
    label: []const u8,
    sessions: i64,
    conversion: analysis.Ratio,
    filter_url: []const u8 = "",
    exclude_url: []const u8 = "",
};

pub const OverviewConversionRow = struct {
    goal_name: []const u8,
    converting_people: i64,
    conversion: analysis.Ratio,
};

pub const OverviewAudienceRow = struct {
    label: []const u8,
    sessions: i64,
    filter_url: []const u8 = "",
    exclude_url: []const u8 = "",
};

pub const OverviewDetails = struct {
    trend: OverviewTrend,
    content: []const OverviewContentRow,
    acquisition: []const OverviewAcquisitionRow,
    conversions: []const OverviewConversionRow,
    audience: []const OverviewAudienceRow,
    daily_event_ceiling: i64,
    accepted_events: i64,
    ceiling_reached_days: i64,
    last_event_utc: []const u8,
    protocol_v1_events: i64,
    protocol_v2_events: i64,
};

pub const AnalyzeTrendPoint = struct {
    current_label: []const u8,
    comparison_label: []const u8 = "",
    current: ?analysis.Measure,
    comparison: ?analysis.Measure = null,
    current_incomplete: bool = false,
    current_highlighted: bool = false,
    comparison_highlighted: bool = false,
};

pub const AnalyzeTrendSeries = struct {
    metric: analysis.Metric,
    title: []const u8,
    points: []const AnalyzeTrendPoint,
    current_total: ?analysis.Measure,
    comparison_total: ?analysis.Measure = null,
    current_coverage: []const u8,
    comparison_coverage: ?[]const u8 = null,
};

pub const AnalyzeTrend = struct {
    series: []const AnalyzeTrendSeries,
    no_events_ever: bool,
    no_matches: bool,
};

pub const AnalyzeBreakdown = struct {
    rows: []const AnalyzeBreakdownRow,
    next_page: ?u32,
    cardinality: i64,
    coverage: []const u8,
    properties: []const analysis.ObservedPropertyType,
    property_count: i64,
    properties_truncated: bool,
    no_events_ever: bool,
};

pub const AnalyzeBreakdownRow = struct {
    data: analysis.BreakdownRow,
    filter_url: []const u8,
    exclude_url: []const u8,
};

pub const FilterSuggestions = struct {
    values: []const FilterSuggestion,
    has_more: bool,
    scope: analysis.Scope,
    field: analysis.Field,
    scalar_type: analysis.ScalarType,
    operator: analysis.Operator,
    search: []const u8,
    builder_values: []const u8,
};

pub const FilterSuggestion = struct {
    value: []const u8,
    filter_url: []const u8,
    exclude_url: []const u8,
};

pub const FilterChip = struct {
    label: []const u8,
    remove_url: []const u8,
};

pub const SegmentOption = struct {
    id: []const u8,
    name: []const u8,
    url: []const u8,
    updated_at_utc: []const u8,
    selected: bool,
};

pub const GoalDraft = struct {
    name: []const u8 = "",
    entity_kind: analysis.GoalEntityKind = .page,
    match_kind: []const u8 = "exact",
    match_value: []const u8 = "",
    predicates: []const GoalPredicateDraft = &.{},
    confirm_unseen: bool = false,
};

pub const GoalPredicateDraft = struct {
    property_name: []const u8 = "",
    rule: []const u8 = "string:is",
    value: []const u8 = "",
};

pub const GoalEntityOption = struct {
    label: []const u8,
    eligible_count: i64,
    last_seen: []const u8,
};

pub const GoalMatchMode = enum {
    exact,
    prefix,
};

pub const GoalDefinitionView = struct {
    id: []const u8,
    name: []const u8,
    entity_kind: analysis.GoalEntityKind,
    match_mode: GoalMatchMode,
    match_value: []const u8,
    predicates: []const analysis.PropertyPredicate,
    archived: bool,
    created_at: []const u8,
    updated_at: []const u8,
    updated_at_utc_micros: i64,
    detail_url: []const u8,
    edit_url: []const u8,
    analyze_url: []const u8,
};

pub const GoalManagement = struct {
    screen: GoalScreen,
    definitions: []const GoalDefinitionView = &.{},
    active_count: i64 = 0,
    selected: ?GoalDefinitionView = null,
    entity_kind: analysis.GoalEntityKind = .page,
    search: []const u8 = "",
    entities: []const GoalEntityOption = &.{},
    properties: analysis.PropertyCatalog = .{
        .entries = &.{},
        .property_count = 0,
        .truncated = false,
    },
    result: ?analysis.GoalResult = null,
    result_is_preview: bool = false,
    filter_count: usize = 0,
    segment_name: []const u8 = "",
    list_url: []const u8,
    new_url: []const u8,
    create_action_url: []const u8,
    edit_action_url: []const u8,
    action_suffix: []const u8,
    previous_definitions_url: ?[]const u8 = null,
    next_definitions_url: ?[]const u8 = null,
    previous_entities_url: ?[]const u8 = null,
    next_entities_url: ?[]const u8 = null,
};

pub const FunnelStepDraft = struct {
    kind: analysis.SelectorKind = .exact_page,
    value: []const u8 = "/",
    goal_id: []const u8 = "",
    predicates: []const GoalPredicateDraft = &.{},
};

pub const FunnelDraft = struct {
    name: []const u8 = "",
    order: funnel.Order = .sequential,
    scope: funnel.Scope = .sessions,
    window: funnel.Window = .same_session,
    steps: []const FunnelStepDraft = &.{},
};

pub const FunnelStepView = struct {
    index: usize,
    draft: FunnelStepDraft,
    label: []const u8,
    stale: bool = false,
    matching_events: ?i64 = null,
};

pub const FunnelDefinitionView = struct {
    id: []const u8,
    name: []const u8,
    order: funnel.Order,
    scope: funnel.Scope,
    window: funnel.Window,
    steps: []const FunnelStepView,
    archived: bool,
    created_at: []const u8,
    updated_at: []const u8,
    updated_at_utc_micros: i64,
    detail_url: []const u8,
    edit_url: []const u8,
};

pub const FunnelManagement = struct {
    screen: FunnelScreen,
    definitions: []const FunnelDefinitionView = &.{},
    selected: ?FunnelDefinitionView = null,
    draft_steps: []const FunnelStepView = &.{},
    result: ?funnel.Result = null,
    goals: []const GoalDefinitionView = &.{},
    filter_count: usize = 0,
    segment_name: []const u8 = "",
    list_url: []const u8,
    new_url: []const u8,
    create_action_url: []const u8,
    edit_action_url: []const u8,
    action_suffix: []const u8,
    previous_definitions_url: ?[]const u8 = null,
    next_definitions_url: ?[]const u8 = null,
};

pub const FormErrorTarget = enum {
    none,
    goal,
    goal_duplicate,
    funnel,
    network,
    traffic_policy,
};

pub const TrafficPolicyDraft = struct {
    strict_mode: bool,
    daily_event_ceiling: []const u8,
};

pub const Page = struct {
    destination: Destination,
    sites: []const meta.Site,
    selected_site: ?meta.Site,
    query: Query,
    calendar_context: ?calendar.Context,
    report_time_basis: ReportTimeBasis,
    result: ?report.Result,
    overview_kpis: ?OverviewKpis = null,
    overview_details: ?OverviewDetails = null,
    analyze_trend: ?AnalyzeTrend = null,
    analyze_breakdown: ?AnalyzeBreakdown = null,
    collection_diagnostics: ?diagnostics.Snapshot = null,
    goal_management: ?GoalManagement = null,
    funnel_management: ?FunnelManagement = null,
    goals: []const meta.Goal,
    funnels: []const meta.Funnel,
    saved_views: []const meta.SavedView = &.{},
    selected_segment_name: []const u8 = "",
    analysis_state_kind: []const u8 = "",
    analysis_state_json: []const u8 = "",
    analysis_filter_parameters: []const []const u8 = &.{},
    analysis_predicate_parameters: []const []const u8 = &.{},
    filter_suggestions: ?FilterSuggestions = null,
    filter_chips: []const FilterChip = &.{},
    segment_options: []const SegmentOption = &.{},
    clear_segment_url: []const u8 = "",
    self_exclusion_origins: []const []u8,
    excluded_networks: []const []u8,
    strict_mode: bool = false,
    daily_event_ceiling: i64 = meta.default_daily_event_ceiling,
    csrf_token: []const u8,
    notice: []const u8 = "",
    form_error: []const u8 = "",
    form_error_target: FormErrorTarget = .none,
    traffic_policy_draft: ?TrafficPolicyDraft = null,
    goal_draft: GoalDraft = .{},
    funnel_draft: FunnelDraft = .{},
    network_draft: []const u8 = "",
};

pub const ErrorPage = struct {
    status: u16,
    title: []const u8,
    message: []const u8,
    return_url: []const u8 = "/admin",
};

pub const FirstRunPage = struct {
    metadata_schema: i64,
    event_schema: i64,
    runtime_ready: bool,
};

pub const SiteDraft = struct {
    name: []const u8 = "",
    slug: []const u8 = "",
    origin: []const u8 = "",
    timezone: []const u8 = "",
    currency: []const u8 = "",
};

pub const SiteFormErrors = struct {
    name: []const u8 = "",
    slug: []const u8 = "",
    origin: []const u8 = "",
    timezone: []const u8 = "",
    currency: []const u8 = "",

    pub fn any(self: SiteFormErrors) bool {
        return self.name.len != 0 or self.slug.len != 0 or
            self.origin.len != 0 or self.timezone.len != 0 or
            self.currency.len != 0;
    }
};

pub const SiteFormPage = struct {
    csrf_token: []const u8,
    draft: SiteDraft = .{},
    errors: SiteFormErrors = .{},
};

pub const SiteSubmission = union(enum) {
    invalid: SiteFormPage,
    stored: struct {
        slug: []const u8,
    },
};

pub const InstallPage = struct {
    site: meta.SiteConfiguration,
    collector_origin: []const u8,
    tracker_path: []const u8,
    tracker_protocol_version: u8,
    snippet: []const u8,
    policy_active: bool,
    verification: InstallVerification,
};

pub const InstallWatermark = struct {
    started_at_utc_micros: i64,
    event_count: i64,
    after_received_at_utc_micros: i64,
    after_event_id: []const u8,
    signature: []const u8,
};

pub const InstallEvent = struct {
    protocol_version: u8,
    event_type: []const u8,
    event_name: []const u8,
    path: []const u8,
    received_at_utc: []const u8,
};

pub const InstallGuidance = struct {
    category: []const u8,
    consequence: []const u8,
    correction: []const u8,
};

pub const InstallVerification = struct {
    site_slug: []const u8,
    watermark: InstallWatermark,
    event: ?InstallEvent = null,
    guidance: ?InstallGuidance = null,
    collection_available: bool,
};
