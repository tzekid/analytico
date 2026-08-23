const std = @import("std");
const domain = @import("domain.zig");

pub const metric_version: u8 = 1;
pub const traffic_quality_metric_version: u8 = 2;
pub const traffic_quality_version: u8 = 4;
pub const default_limit: u16 = 25;
pub const maximum_limit: u16 = 100;
pub const maximum_range_days: u16 = 400;

pub const Format = enum {
    table,
    json,
    csv,

    fn parse(value: []const u8) !Format {
        if (std.mem.eql(u8, value, "table")) return .table;
        if (std.mem.eql(u8, value, "json")) return .json;
        if (std.mem.eql(u8, value, "csv")) return .csv;
        return error.InvalidReportFormat;
    }
};

pub const Sort = enum {
    count,
    label,

    pub fn parse(value: []const u8) !Sort {
        if (std.mem.eql(u8, value, "count")) return .count;
        if (std.mem.eql(u8, value, "label")) return .label;
        return error.InvalidReportSort;
    }
};

pub const CampaignDimension = enum {
    source,
    medium,
    campaign,
    term,
    content,
    all,

    pub fn parse(value: []const u8) !CampaignDimension {
        if (std.mem.eql(u8, value, "source")) return .source;
        if (std.mem.eql(u8, value, "medium")) return .medium;
        if (std.mem.eql(u8, value, "campaign")) return .campaign;
        if (std.mem.eql(u8, value, "term")) return .term;
        if (std.mem.eql(u8, value, "content")) return .content;
        if (std.mem.eql(u8, value, "all")) return .all;
        return error.InvalidCampaignDimension;
    }
};

pub const Kind = enum {
    overview,
    pages,
    entries,
    exits,
    sources,
    campaigns,
    countries,
    browsers,
    operating_systems,
    devices,
    events,
    traffic_quality,
    goal,
    funnel,

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .overview => "overview",
            .pages => "pages",
            .entries => "entries",
            .exits => "exits",
            .sources => "sources",
            .campaigns => "campaigns",
            .countries => "countries",
            .browsers => "browsers",
            .operating_systems => "operating-systems",
            .devices => "devices",
            .events => "events",
            .traffic_quality => "traffic-quality",
            .goal => "goal",
            .funnel => "funnel",
        };
    }

    pub fn parse(value: []const u8) !Kind {
        const enum_info = @typeInfo(Kind).@"enum";
        inline for (enum_info.field_values) |field_value| {
            const candidate: Kind = @fromBackingInt(@intCast(field_value));
            if (std.mem.eql(u8, value, candidate.name())) return candidate;
        }
        return error.InvalidReportKind;
    }

    pub fn isList(self: Kind) bool {
        return switch (self) {
            .pages,
            .entries,
            .exits,
            .sources,
            .campaigns,
            .countries,
            .browsers,
            .operating_systems,
            .devices,
            .events,
            => true,
            else => false,
        };
    }

    pub fn isPaginated(self: Kind) bool {
        return self.isList() or self == .traffic_quality;
    }
};

pub const Request = struct {
    directory: []const u8,
    site_slug: []const u8,
    start_date: []const u8,
    end_date: []const u8,
    start_day: u32,
    end_day: u32,
    kind: Kind,
    subject: []const u8 = "",
    campaign_dimension: CampaignDimension = .all,
    format: Format = .table,
    sort: Sort = .count,
    limit: u16 = default_limit,
    page: u32 = 1,

    pub fn parse(args: []const []const u8) !Request {
        if (args.len < 7 or !std.mem.eql(u8, args[1], "report")) {
            return error.InvalidArguments;
        }
        try domain.validateSlug(args[3]);
        try domain.validateDate(args[4]);
        try domain.validateDate(args[5]);
        const start_day = try dateDay(args[4]);
        const end_day = try dateDay(args[5]);
        if (end_day < start_day or end_day - start_day + 1 > maximum_range_days) {
            return error.InvalidReportRange;
        }
        const kind = try Kind.parse(args[6]);
        var request = Request{
            .directory = args[2],
            .site_slug = args[3],
            .start_date = args[4],
            .end_date = args[5],
            .start_day = start_day,
            .end_day = end_day,
            .kind = kind,
        };
        var index: usize = 7;
        if (kind == .goal or kind == .funnel) {
            if (index >= args.len or std.mem.startsWith(u8, args[index], "--")) {
                return error.MissingReportSubject;
            }
            try domain.validateName(args[index], 120);
            request.subject = args[index];
            index += 1;
        } else if (kind == .campaigns) {
            if (index >= args.len or std.mem.startsWith(u8, args[index], "--")) {
                return error.MissingCampaignDimension;
            }
            request.campaign_dimension = try CampaignDimension.parse(args[index]);
            index += 1;
        }
        while (index < args.len) {
            if (index + 1 >= args.len) return error.InvalidReportOption;
            const flag = args[index];
            const value = args[index + 1];
            if (std.mem.eql(u8, flag, "--format")) {
                request.format = try Format.parse(value);
            } else if (std.mem.eql(u8, flag, "--sort")) {
                request.sort = try Sort.parse(value);
            } else if (std.mem.eql(u8, flag, "--limit")) {
                const limit = std.fmt.parseInt(u16, value, 10) catch
                    return error.InvalidReportLimit;
                if (limit == 0 or limit > maximum_limit) {
                    return error.InvalidReportLimit;
                }
                request.limit = limit;
            } else if (std.mem.eql(u8, flag, "--page")) {
                request.page = std.fmt.parseInt(u32, value, 10) catch
                    return error.InvalidReportPage;
                if (request.page == 0 or request.page > 1_000_000) {
                    return error.InvalidReportPage;
                }
            } else {
                return error.InvalidReportOption;
            }
            index += 2;
        }
        if (!kind.isPaginated() and
            (request.sort != .count or request.limit != default_limit or
                request.page != 1))
        {
            return error.ReportOptionsNotApplicable;
        }
        if (kind == .traffic_quality and request.sort != .count) {
            return error.ReportOptionsNotApplicable;
        }
        return request;
    }

    pub fn offset(self: Request) !i64 {
        const value = std.math.mul(
            u64,
            @as(u64, self.page - 1),
            @as(u64, self.limit),
        ) catch return error.InvalidReportPage;
        if (value > std.math.maxInt(i64)) return error.InvalidReportPage;
        return @intCast(value);
    }
};

pub const Overview = struct {
    page_views: i64,
    visitor_days: i64,
    sessions: i64,
    custom_events: i64,
    bot_events: i64,
};

pub const IdentityQuality = enum {
    persistent,
    ephemeral,
    legacy_daily,

    pub fn name(self: IdentityQuality) []const u8 {
        return switch (self) {
            .persistent => "persistent",
            .ephemeral => "ephemeral",
            .legacy_daily => "legacy_daily",
        };
    }
};

pub const IdentityQualityRow = struct {
    quality: IdentityQuality,
    events: i64,
    visitor_days: i64,
};

pub const ExclusionSourceRow = struct {
    source: domain.ExclusionSource,
    events: i64,
};

pub const TrafficClassRow = struct {
    class: domain.TrafficClass,
    events: i64,
};

pub const TrafficSignals = struct {
    client_signal_v1_events: i64,
    webdriver_events: i64,
    trusted_interaction_events: i64,
    visible_events: i64,
    prerendered_events: i64,
    client_hint_mismatch_events: i64,
    client_hint_absent_expected_events: i64,
    accept_language_present_events: i64,
};

pub const TrafficRuleRow = struct {
    class: domain.TrafficClass,
    classifier_version: u16,
    rule: []u8,
    events: i64,
};

pub const TrafficQualityDay = struct {
    date: []u8,
    new_anonymous_identities: i64,
    bot_events: i64,
};

pub const TrafficQuality = struct {
    distinct_people: i64,
    persistent_people: i64,
    ephemeral_people: i64,
    legacy_people: i64,
    persistent_basis_points: u16,
    visitor_days: i64,
    zero_engagement_single_event_sessions: i64,
    identity_quality: [3]IdentityQualityRow,
    exclusion_sources: [3]ExclusionSourceRow,
    traffic_classes: [5]TrafficClassRow,
    signals: TrafficSignals,
    rules: []TrafficRuleRow,
    days: []TrafficQualityDay,
    next_page: ?u32,
};

pub const ListRow = struct {
    label: []u8,
    primary: i64,
    secondary: i64,
};

pub const List = struct {
    label_name: []const u8,
    primary_name: []const u8,
    secondary_name: []const u8,
    rows: []ListRow,
    next_page: ?u32,
};

pub const Goal = struct {
    name: []const u8,
    total_matches: i64,
    matching_sessions: i64,
    eligible_sessions: i64,
};

pub const FunnelStep = struct {
    name: []const u8,
    sessions: i64,
};

pub const Funnel = struct {
    name: []const u8,
    eligible_sessions: i64,
    steps: []FunnelStep,
};

pub const Result = union(enum) {
    overview: Overview,
    traffic_quality: TrafficQuality,
    list: List,
    goal: Goal,
    funnel: Funnel,
};

pub fn render(
    output: *std.Io.Writer,
    request: Request,
    result: Result,
) !void {
    switch (request.format) {
        .table => try renderTable(output, request, result),
        .json => try renderJson(output, request, result),
        .csv => try renderCsv(output, request, result),
    }
}

fn renderTable(
    output: *std.Io.Writer,
    request: Request,
    result: Result,
) !void {
    if (request.kind == .traffic_quality) {
        try output.print(
            "metric_version={d}\ttraffic_quality_version={d}\tsite={s}\tutc_range={s}..{s}\treport={s}\n",
            .{
                traffic_quality_metric_version,
                traffic_quality_version,
                request.site_slug,
                request.start_date,
                request.end_date,
                request.kind.name(),
            },
        );
    } else {
        try output.print(
            "metric_version={d}\tsite={s}\tutc_range={s}..{s}\treport={s}\n",
            .{
                metric_version,
                request.site_slug,
                request.start_date,
                request.end_date,
                request.kind.name(),
            },
        );
    }
    switch (result) {
        .overview => |overview| {
            try output.writeAll(
                "page_views\tvisitor_days\tsessions\tcustom_events\tbot_events\n",
            );
            try output.print("{d}\t{d}\t{d}\t{d}\t{d}\n", .{
                overview.page_views,
                overview.visitor_days,
                overview.sessions,
                overview.custom_events,
                overview.bot_events,
            });
        },
        .traffic_quality => |quality| {
            try output.writeAll(
                "distinct_people\tvisitor_days\tpersistent_people\tephemeral_people\tlegacy_people\tpersistent_basis_points\tzero_engagement_single_event_sessions\n",
            );
            try output.print("{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
                quality.distinct_people,
                quality.visitor_days,
                quality.persistent_people,
                quality.ephemeral_people,
                quality.legacy_people,
                quality.persistent_basis_points,
                quality.zero_engagement_single_event_sessions,
            });
            try output.writeAll("identity_quality\tevents\tvisitor_days\n");
            for (quality.identity_quality) |row| {
                try output.print("{s}\t{d}\t{d}\n", .{
                    row.quality.name(), row.events, row.visitor_days,
                });
            }
            try output.writeAll("exclusion_source\tevents\n");
            for (quality.exclusion_sources) |row| {
                try output.print("{s}\t{d}\n", .{ @tagName(row.source), row.events });
            }
            try output.writeAll("traffic_class\tevents\n");
            for (quality.traffic_classes) |row| {
                try output.print("{s}\t{d}\n", .{ row.class.name(), row.events });
            }
            try output.writeAll("signal_evidence\tevents\n");
            inline for (.{
                .{ "client_signal_v1", quality.signals.client_signal_v1_events },
                .{ "webdriver", quality.signals.webdriver_events },
                .{ "trusted_interaction", quality.signals.trusted_interaction_events },
                .{ "visible", quality.signals.visible_events },
                .{ "prerendered", quality.signals.prerendered_events },
                .{ "client_hint_mismatch", quality.signals.client_hint_mismatch_events },
                .{ "client_hint_absent_expected", quality.signals.client_hint_absent_expected_events },
                .{ "accept_language_present", quality.signals.accept_language_present_events },
            }) |row| {
                try output.print("{s}\t{d}\n", .{ row[0], row[1] });
            }
            try output.writeAll(
                "classifier_rule\ttraffic_class\tclassifier_version\tevents\n",
            );
            for (quality.rules) |row| {
                try output.print("{s}\t{s}\t{d}\t{d}\n", .{
                    if (row.rule.len == 0) "(none)" else row.rule,
                    row.class.name(),
                    row.classifier_version,
                    row.events,
                });
            }
            try output.writeAll("date\tnew_anonymous_identities\tbot_events\n");
            for (quality.days) |day| {
                try output.print("{s}\t{d}\t{d}\n", .{
                    day.date, day.new_anonymous_identities, day.bot_events,
                });
            }
            try output.print("page={d}\tlimit={d}\tnext_page={s}\n", .{
                request.page,
                request.limit,
                if (quality.next_page == null) "none" else "present",
            });
        },
        .list => |list| {
            try output.print("{s}\t{s}\t{s}\n", .{
                list.label_name,
                list.primary_name,
                list.secondary_name,
            });
            for (list.rows) |row| {
                try writeTerminalText(output, row.label);
                try output.print("\t{d}\t{d}\n", .{ row.primary, row.secondary });
            }
            try output.print(
                "page={d}\tlimit={d}\tnext_page={s}\n",
                .{
                    request.page,
                    request.limit,
                    if (list.next_page == null) "none" else "present",
                },
            );
        },
        .goal => |goal| {
            try output.writeAll(
                "goal\ttotal_matches\tmatching_sessions\teligible_sessions\tconversion_rate\n",
            );
            try writeTerminalText(output, goal.name);
            try output.print("\t{d}\t{d}\t{d}\t", .{
                goal.total_matches,
                goal.matching_sessions,
                goal.eligible_sessions,
            });
            try writePercent(output, goal.matching_sessions, goal.eligible_sessions);
            try output.writeByte('\n');
        },
        .funnel => |funnel| {
            try output.writeAll(
                "step\tsessions\tstep_rate\toverall_rate\teligible_sessions\n",
            );
            for (funnel.steps, 0..) |step, index| {
                try writeTerminalText(output, step.name);
                try output.print("\t{d}\t", .{step.sessions});
                const prior = if (index == 0)
                    funnel.eligible_sessions
                else
                    funnel.steps[index - 1].sessions;
                try writePercent(output, step.sessions, prior);
                try output.writeByte('\t');
                try writePercent(output, step.sessions, funnel.eligible_sessions);
                try output.print("\t{d}\n", .{funnel.eligible_sessions});
            }
        },
    }
}

fn renderJson(
    output: *std.Io.Writer,
    request: Request,
    result: Result,
) !void {
    try output.print("{{\"metric_version\":{d}", .{if (request.kind == .traffic_quality)
        traffic_quality_metric_version
    else
        metric_version});
    if (request.kind == .traffic_quality) {
        try output.print(",\"traffic_quality_version\":{d}", .{traffic_quality_version});
    }
    try output.writeAll(",\"site\":");
    try jsonString(output, request.site_slug);
    try output.writeAll(",\"start_date\":");
    try jsonString(output, request.start_date);
    try output.writeAll(",\"end_date\":");
    try jsonString(output, request.end_date);
    try output.writeAll(",\"report\":");
    try jsonString(output, request.kind.name());
    switch (result) {
        .overview => |overview| try output.print(
            ",\"page_views\":{d},\"visitor_days\":{d},\"sessions\":{d}," ++
                "\"custom_events\":{d},\"bot_events\":{d}}}\n",
            .{
                overview.page_views,
                overview.visitor_days,
                overview.sessions,
                overview.custom_events,
                overview.bot_events,
            },
        ),
        .traffic_quality => |quality| {
            try output.print(
                ",\"page\":{d},\"limit\":{d},\"next_page\":",
                .{ request.page, request.limit },
            );
            if (quality.next_page) |next| {
                try output.print("{d}", .{next});
            } else {
                try output.writeAll("null");
            }
            try output.print(
                ",\"distinct_people\":{d},\"visitor_days\":{d}," ++
                    "\"persistent_people\":{d},\"ephemeral_people\":{d}," ++
                    "\"legacy_people\":{d},\"persistent_basis_points\":{d}," ++
                    "\"zero_engagement_single_event_sessions\":{d}," ++
                    "\"identity_quality\":[",
                .{
                    quality.distinct_people,
                    quality.visitor_days,
                    quality.persistent_people,
                    quality.ephemeral_people,
                    quality.legacy_people,
                    quality.persistent_basis_points,
                    quality.zero_engagement_single_event_sessions,
                },
            );
            for (quality.identity_quality, 0..) |row, index| {
                if (index != 0) try output.writeByte(',');
                try output.writeAll("{\"quality\":");
                try jsonString(output, row.quality.name());
                try output.print(",\"events\":{d},\"visitor_days\":{d}}}", .{
                    row.events, row.visitor_days,
                });
            }
            try output.writeAll("],\"exclusion_sources\":[");
            for (quality.exclusion_sources, 0..) |row, index| {
                if (index != 0) try output.writeByte(',');
                try output.writeAll("{\"source\":");
                try jsonString(output, @tagName(row.source));
                try output.print(",\"events\":{d}}}", .{row.events});
            }
            try output.writeAll("],\"traffic_classes\":[");
            for (quality.traffic_classes, 0..) |row, index| {
                if (index != 0) try output.writeByte(',');
                try output.writeAll("{\"class\":");
                try jsonString(output, row.class.name());
                try output.print(",\"events\":{d}}}", .{row.events});
            }
            try output.print(
                "],\"signal_evidence\":{{" ++
                    "\"client_signal_v1_events\":{d}," ++
                    "\"webdriver_events\":{d}," ++
                    "\"trusted_interaction_events\":{d}," ++
                    "\"visible_events\":{d},\"prerendered_events\":{d}," ++
                    "\"client_hint_mismatch_events\":{d}," ++
                    "\"client_hint_absent_expected_events\":{d}," ++
                    "\"accept_language_present_events\":{d}}}," ++
                    "\"classifier_rules\":[",
                .{
                    quality.signals.client_signal_v1_events,
                    quality.signals.webdriver_events,
                    quality.signals.trusted_interaction_events,
                    quality.signals.visible_events,
                    quality.signals.prerendered_events,
                    quality.signals.client_hint_mismatch_events,
                    quality.signals.client_hint_absent_expected_events,
                    quality.signals.accept_language_present_events,
                },
            );
            for (quality.rules, 0..) |row, index| {
                if (index != 0) try output.writeByte(',');
                try output.writeAll("{\"class\":");
                try jsonString(output, row.class.name());
                try output.print(
                    ",\"classifier_version\":{d},\"rule\":",
                    .{row.classifier_version},
                );
                try jsonString(output, row.rule);
                try output.print(",\"events\":{d}}}", .{row.events});
            }
            try output.writeAll("],\"days\":[");
            for (quality.days, 0..) |day, index| {
                if (index != 0) try output.writeByte(',');
                try output.writeAll("{\"date\":");
                try jsonString(output, day.date);
                try output.print(
                    ",\"new_anonymous_identities\":{d},\"bot_events\":{d}}}",
                    .{ day.new_anonymous_identities, day.bot_events },
                );
            }
            try output.writeAll("]}\n");
        },
        .list => |list| {
            try output.print(
                ",\"page\":{d},\"limit\":{d},\"next_page\":",
                .{ request.page, request.limit },
            );
            if (list.next_page) |next| {
                try output.print("{d}", .{next});
            } else {
                try output.writeAll("null");
            }
            try output.writeAll(",\"rows\":[");
            for (list.rows, 0..) |row, index| {
                if (index != 0) try output.writeByte(',');
                try output.writeByte('{');
                try jsonString(output, list.label_name);
                try output.writeByte(':');
                try jsonString(output, row.label);
                try output.writeByte(',');
                try jsonString(output, list.primary_name);
                try output.print(":{d},", .{row.primary});
                try jsonString(output, list.secondary_name);
                try output.print(":{d}}}", .{row.secondary});
            }
            try output.writeAll("]}\n");
        },
        .goal => |goal| {
            try output.writeAll(",\"goal\":");
            try jsonString(output, goal.name);
            try output.print(
                ",\"total_matches\":{d},\"matching_sessions\":{d}," ++
                    "\"eligible_sessions\":{d},\"conversion_rate\":",
                .{
                    goal.total_matches,
                    goal.matching_sessions,
                    goal.eligible_sessions,
                },
            );
            try writeRatio(output, goal.matching_sessions, goal.eligible_sessions);
            try output.writeAll("}\n");
        },
        .funnel => |funnel| {
            try output.writeAll(",\"funnel\":");
            try jsonString(output, funnel.name);
            try output.print(
                ",\"eligible_sessions\":{d},\"steps\":[",
                .{funnel.eligible_sessions},
            );
            for (funnel.steps, 0..) |step, index| {
                if (index != 0) try output.writeByte(',');
                try output.writeAll("{\"name\":");
                try jsonString(output, step.name);
                try output.print(",\"sessions\":{d},\"step_rate\":", .{step.sessions});
                const prior = if (index == 0)
                    funnel.eligible_sessions
                else
                    funnel.steps[index - 1].sessions;
                try writeRatio(output, step.sessions, prior);
                try output.writeAll(",\"overall_rate\":");
                try writeRatio(output, step.sessions, funnel.eligible_sessions);
                try output.writeByte('}');
            }
            try output.writeAll("]}\n");
        },
    }
}

fn renderCsv(
    output: *std.Io.Writer,
    request: Request,
    result: Result,
) !void {
    _ = request;
    switch (result) {
        .overview => |overview| {
            try output.writeAll(
                "page_views,visitor_days,sessions,custom_events,bot_events\n",
            );
            try output.print("{d},{d},{d},{d},{d}\n", .{
                overview.page_views,
                overview.visitor_days,
                overview.sessions,
                overview.custom_events,
                overview.bot_events,
            });
        },
        .traffic_quality => |quality| {
            try output.writeAll(
                "metric_version,traffic_quality_version,row_type,label,events,visitor_days,new_anonymous_identities,bot_events,distinct_people,persistent_people,ephemeral_people,legacy_people,persistent_basis_points,zero_engagement_single_event_sessions,traffic_class,classifier_version,rule\n",
            );
            try output.print("{d},{d},summary,all,,,,,{d},{d},{d},{d},{d},{d},,,\n", .{
                traffic_quality_metric_version,
                traffic_quality_version,
                quality.distinct_people,
                quality.persistent_people,
                quality.ephemeral_people,
                quality.legacy_people,
                quality.persistent_basis_points,
                quality.zero_engagement_single_event_sessions,
            });
            for (quality.identity_quality) |row| {
                try output.print("{d},{d},identity_quality,{s},{d},{d},,,,,,,,,,,\n", .{
                    traffic_quality_metric_version,
                    traffic_quality_version,
                    row.quality.name(),
                    row.events,
                    row.visitor_days,
                });
            }
            for (quality.exclusion_sources) |row| {
                try output.print("{d},{d},exclusion_source,{s},{d},,,,,,,,,,,,\n", .{
                    traffic_quality_metric_version,
                    traffic_quality_version,
                    @tagName(row.source),
                    row.events,
                });
            }
            for (quality.traffic_classes) |row| {
                try output.print("{d},{d},traffic_class,{s},{d},,,,,,,,,,{s},,\n", .{
                    traffic_quality_metric_version,
                    traffic_quality_version,
                    row.class.name(),
                    row.events,
                    row.class.name(),
                });
            }
            inline for (.{
                .{ "client_signal_v1", quality.signals.client_signal_v1_events },
                .{ "webdriver", quality.signals.webdriver_events },
                .{ "trusted_interaction", quality.signals.trusted_interaction_events },
                .{ "visible", quality.signals.visible_events },
                .{ "prerendered", quality.signals.prerendered_events },
                .{ "client_hint_mismatch", quality.signals.client_hint_mismatch_events },
                .{ "client_hint_absent_expected", quality.signals.client_hint_absent_expected_events },
                .{ "accept_language_present", quality.signals.accept_language_present_events },
            }) |row| {
                try output.print("{d},{d},signal_evidence,{s},{d},,,,,,,,,,,,\n", .{
                    traffic_quality_metric_version,
                    traffic_quality_version,
                    row[0],
                    row[1],
                });
            }
            for (quality.rules) |row| {
                try output.print(
                    "{d},{d},classifier_rule,{s},{d},,,,,,,,,,{s},{d},{s}\n",
                    .{
                        traffic_quality_metric_version,
                        traffic_quality_version,
                        row.rule,
                        row.events,
                        row.class.name(),
                        row.classifier_version,
                        row.rule,
                    },
                );
            }
            for (quality.days) |day| {
                try output.print("{d},{d},day,{s},,,{d},{d},,,,,,,,,\n", .{
                    traffic_quality_metric_version,
                    traffic_quality_version,
                    day.date,
                    day.new_anonymous_identities,
                    day.bot_events,
                });
            }
        },
        .list => |list| {
            try csvText(output, list.label_name);
            try output.writeByte(',');
            try csvText(output, list.primary_name);
            try output.writeByte(',');
            try csvText(output, list.secondary_name);
            try output.writeByte('\n');
            for (list.rows) |row| {
                try csvText(output, row.label);
                try output.print(",{d},{d}\n", .{ row.primary, row.secondary });
            }
        },
        .goal => |goal| {
            try output.writeAll(
                "goal,total_matches,matching_sessions,eligible_sessions,conversion_rate\n",
            );
            try csvText(output, goal.name);
            try output.print(",{d},{d},{d},", .{
                goal.total_matches,
                goal.matching_sessions,
                goal.eligible_sessions,
            });
            try writeRatio(output, goal.matching_sessions, goal.eligible_sessions);
            try output.writeByte('\n');
        },
        .funnel => |funnel| {
            try output.writeAll(
                "step,sessions,step_rate,overall_rate,eligible_sessions\n",
            );
            for (funnel.steps, 0..) |step, index| {
                try csvText(output, step.name);
                try output.print(",{d},", .{step.sessions});
                const prior = if (index == 0)
                    funnel.eligible_sessions
                else
                    funnel.steps[index - 1].sessions;
                try writeRatio(output, step.sessions, prior);
                try output.writeByte(',');
                try writeRatio(output, step.sessions, funnel.eligible_sessions);
                try output.print(",{d}\n", .{funnel.eligible_sessions});
            }
        },
    }
}

pub fn dateDay(value: []const u8) !u32 {
    const year = try std.fmt.parseInt(u16, value[0..4], 10);
    const month = try std.fmt.parseInt(u8, value[5..7], 10);
    const day = try std.fmt.parseInt(u8, value[8..10], 10);
    var result: u32 = 0;
    var cursor_year: u16 = 1970;
    while (cursor_year < year) : (cursor_year += 1) {
        result += if (isLeapYear(cursor_year)) 366 else 365;
    }
    const month_lengths = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var cursor_month: u8 = 1;
    while (cursor_month < month) : (cursor_month += 1) {
        result += month_lengths[cursor_month - 1];
        if (cursor_month == 2 and isLeapYear(year)) result += 1;
    }
    result += day - 1;
    return result;
}

fn isLeapYear(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn jsonString(output: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, output);
}

fn writeTerminalText(output: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789abcdef";
    for (value) |byte| {
        switch (byte) {
            '\t' => try output.writeAll("\\t"),
            '\r' => try output.writeAll("\\r"),
            '\n' => try output.writeAll("\\n"),
            '\\' => try output.writeAll("\\\\"),
            else => if (byte < 0x20 or byte == 0x7f) {
                try output.writeAll("\\x");
                try output.writeByte(hex[byte >> 4]);
                try output.writeByte(hex[byte & 0x0f]);
            } else {
                try output.writeByte(byte);
            },
        }
    }
}

fn csvText(output: *std.Io.Writer, value: []const u8) !void {
    try output.writeByte('"');
    if (needsFormulaPrefix(value)) try output.writeByte('\'');
    for (value) |byte| {
        if (byte == '"') try output.writeByte('"');
        try output.writeByte(byte);
    }
    try output.writeByte('"');
}

fn needsFormulaPrefix(value: []const u8) bool {
    if (value.len == 0) return false;
    var index: usize = 0;
    while (index < value.len and
        (value[index] == ' ' or value[index] == '\t' or
            value[index] == '\r' or value[index] == '\n'))
    {
        index += 1;
    }
    if (index == value.len) return false;
    return std.mem.findScalar(u8, "=+-@", value[index]) != null;
}

fn writeRatio(output: *std.Io.Writer, numerator: i64, denominator: i64) !void {
    const millionths = ratioMillionths(numerator, denominator);
    try output.print("{d}.", .{@divTrunc(millionths, 1_000_000)});
    try writePaddedUnsigned(output, @intCast(@mod(millionths, 1_000_000)), 6);
}

fn writePercent(output: *std.Io.Writer, numerator: i64, denominator: i64) !void {
    const hundredths = @divTrunc(ratioMillionths(numerator, denominator), 100);
    try output.print("{d}.", .{@divTrunc(hundredths, 100)});
    try writePaddedUnsigned(output, @intCast(@mod(hundredths, 100)), 2);
    try output.writeByte('%');
}

fn ratioMillionths(numerator: i64, denominator: i64) i64 {
    if (numerator <= 0 or denominator <= 0) return 0;
    const scaled = @as(i128, numerator) * 1_000_000;
    return @intCast(@divTrunc(scaled, denominator));
}

fn writePaddedUnsigned(
    output: *std.Io.Writer,
    value: u64,
    width: u8,
) !void {
    var divisor: u64 = 1;
    var remaining = width;
    while (remaining > 1) : (remaining -= 1) divisor *= 10;
    var current = value;
    remaining = width;
    while (remaining > 0) : (remaining -= 1) {
        try output.writeByte(@intCast('0' + @divTrunc(current, divisor)));
        current %= divisor;
        if (divisor > 1) divisor /= 10;
    }
}
