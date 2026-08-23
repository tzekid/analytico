const analysis = @import("../analysis.zig");
const calendar = @import("../calendar.zig");
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
    range: analysis.LocalDateRange,
    comparison: analysis.Comparison = .previous,
    kind: report.Kind = .overview,
    subject: []const u8 = "",
    campaign_dimension: report.CampaignDimension = .all,
    sort: report.Sort = .count,
    limit: u16 = report.default_limit,
    page: u32 = 1,
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
};

pub const OverviewKpis = struct {
    cards: []const OverviewKpi,
    coverage: []const u8,
    comparison_coverage: ?[]const u8,
    includes_incomplete_today: bool,
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
    overview_quality: ?report.TrafficQuality = null,
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
