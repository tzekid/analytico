const meta = @import("../store/meta.zig");
const report = @import("../report.zig");

pub const Query = struct {
    site: []const u8 = "",
    start_date: []const u8,
    end_date: []const u8,
    kind: report.Kind = .overview,
    subject: []const u8 = "",
    campaign_dimension: report.CampaignDimension = .all,
    sort: report.Sort = .count,
    limit: u16 = report.default_limit,
    page: u32 = 1,
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

pub const Page = struct {
    sites: []const meta.Site,
    selected_site: ?meta.Site,
    query: Query,
    result: ?report.Result,
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
