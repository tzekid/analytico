const analysis = @import("../analysis.zig");
const calendar = @import("../calendar.zig");
const diagnostics = @import("../diagnostics.zig");
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
};

pub const OverviewAcquisitionRow = struct {
    label: []const u8,
    sessions: i64,
    conversion: analysis.Ratio,
};

pub const OverviewConversionRow = struct {
    goal_name: []const u8,
    converting_people: i64,
    conversion: analysis.Ratio,
};

pub const OverviewAudienceRow = struct {
    label: []const u8,
    sessions: i64,
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

pub const GoalDraft = struct {
    name: []const u8 = "",
    match_kind: []const u8 = "event",
    match_value: []const u8 = "",
};

pub const FunnelDraft = struct {
    name: []const u8 = "",
    steps: []const u8 = "path=/pricing\nevent=signup",
};

pub const FormErrorTarget = enum {
    none,
    goal,
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
    collection_diagnostics: ?diagnostics.Snapshot = null,
    goals: []const meta.Goal,
    funnels: []const meta.Funnel,
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
    policy_active: bool,
    collection_available: bool,
};
