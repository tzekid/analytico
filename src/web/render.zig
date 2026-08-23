const std = @import("std");
const analysis = @import("../analysis.zig");
const report = @import("../report.zig");
const charts = @import("charts.zig");
const components = @import("components.zig");
const model = @import("model.zig");

pub const stylesheet = @embedFile("style.css");
pub const stylesheet_path = "/admin/app.v7.css";
pub const htmx = @embedFile("htmx_js");
pub const htmx_gzip = @embedFile("htmx_gzip");
pub const htmx_path = "/admin/htmx.28fae7bb.js";
pub const dashboard_js = @embedFile("dashboard.js");
pub const dashboard_js_previous = @embedFile("dashboard.5f88a716.js");
pub const dashboard_js_previous_path = "/admin/dashboard.5f88a716.js";
pub const dashboard_js_path = "/admin/dashboard.9c3ac396.js";

const html_headers =
    "Cache-Control: private, no-store, max-age=0\r\n" ++
    "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; " ++
    "connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'\r\n" ++
    "X-Content-Type-Options: nosniff\r\n" ++
    "Referrer-Policy: same-origin\r\n";

pub const headers = html_headers;

pub fn page(output: *std.Io.Writer, value: model.Page) !void {
    try head(output, value.destination.label());
    if (value.selected_site == null) {
        try output.writeAll(
            "<header class=\"first-run-header\"><a class=\"brand\" href=\"/admin\">Analytico</a></header>" ++
                "<main id=\"main\" class=\"first-run-main\"><section class=\"panel\"><h1>No sites configured</h1>" ++
                "<p>Add the first site with <code>analytico site add " ++
                "... --timezone &lt;IANA-zone&gt;</code>, " ++
                "then restart the service.</p></section></main>",
        );
        try foot(output);
        return;
    }
    try shellStart(output, value);
    if (value.notice.len != 0) {
        try components.feedback(output, .{
            .kind = .notice,
            .message = value.notice,
        });
    }
    if (value.form_error.len != 0) {
        try components.feedback(output, .{
            .kind = .error_message,
            .message = value.form_error,
            .id = "form-error-summary",
            .focus = true,
        });
    }
    if (value.report_time_basis == .metric_v1_utc) {
        try components.feedback(output, .{
            .kind = .warning,
            .message = "Compatibility report: the values below still use UTC calendar dates. The selected site-local context is preserved for 1.0 analysis views.",
        });
    }
    try output.writeAll("<div class=\"page-heading\"><span class=\"eyebrow\">Analytico 1.0</span><h1>");
    try text(output, value.destination.label());
    try output.writeAll("</h1><p>");
    try text(output, destinationSummary(value.destination));
    try output.writeAll("</p></div>");
    switch (value.destination) {
        .overview => try overviewSection(output, value),
        .analyze => {
            try reportNavigation(output, value);
            try reportSection(output, value);
        },
        .journeys => {
            try journeyNavigation(output, value);
            try reportSection(output, value);
            try definitions(output, value);
        },
        .sessions => try components.emptyState(output, .{
            .id = "sessions-empty",
            .title = "Session explorer is not available yet",
            .message = "Session lists and details are not available in this build.",
        }),
        .live => try reportSection(output, value),
        .settings => {
            try trafficPolicy(output, value);
            try selfExclusions(output, value);
        },
    }
    try shellEnd(output, value);
}

pub fn errorPage(output: *std.Io.Writer, value: model.ErrorPage) !void {
    try head(output, value.title);
    try output.writeAll("<header><h1>Analytico</h1></header><main id=\"main\" tabindex=\"-1\"><section class=\"panel\"><h2>");
    try text(output, value.title);
    try output.writeAll("</h2>");
    try components.feedback(output, .{
        .kind = .error_message,
        .message = value.message,
    });
    try output.writeAll("<p><a hx-boost=\"true\" href=\"");
    try attribute(output, value.return_url);
    try output.writeAll("\">Return to dashboard</a></p></section></main>");
    try foot(output);
}

fn head(output: *std.Io.Writer, title: []const u8) !void {
    try output.writeAll("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>");
    try text(output, title);
    try output.writeAll(" · Analytico</title><link rel=\"stylesheet\" href=\"");
    try attribute(output, stylesheet_path);
    try output.writeAll("\"><script defer src=\"");
    try attribute(output, htmx_path);
    try output.writeAll("\"></script><script defer src=\"");
    try attribute(output, dashboard_js_path);
    try output.writeAll("\"></script></head><body hx-boost:inherited=\"true\" hx-indicator:inherited=\"#loading-region\"><a class=\"skip-link\" href=\"#main\">Skip to main content</a><p id=\"loading-region\" class=\"loading-region htmx-indicator\" role=\"status\" aria-live=\"polite\" aria-atomic=\"true\">Updating view…</p>");
}

fn foot(output: *std.Io.Writer) !void {
    try output.writeAll("<footer class=\"first-run-footer\">Server-rendered · no JavaScript required</footer></body></html>");
}

fn shellStart(output: *std.Io.Writer, value: model.Page) !void {
    try output.writeAll("<div class=\"app-shell\"><aside class=\"app-sidebar\"><a class=\"brand\" href=\"");
    try canonicalUrl(output, .overview, value.query, 1);
    try output.writeAll("\">Analytico <b>1.0</b></a>");
    try primaryNavigation(output, value, "primary-navigation");
    try accountNavigation(output, value.csrf_token, "sidebar-account");
    try output.writeAll("</aside><div class=\"app-column\"><header class=\"context-header\"><div class=\"mobile-context-heading\"><strong>");
    try text(output, value.selected_site.?.name);
    try output.writeAll("</strong><span class=\"muted\">");
    try text(output, value.query.range.start);
    try output.writeAll(" – ");
    try text(output, value.query.range.end);
    try output.writeAll("</span></div><div class=\"desktop-context\">");
    try contextControls(output, value);
    try output.writeAll("</div><details class=\"mobile-context\"><summary>Context</summary>");
    try contextControls(output, value);
    try accountNavigation(output, value.csrf_token, "mobile-account");
    try output.writeAll("</details></header><main id=\"main\" tabindex=\"-1\" class=\"app-content\">");
}

fn shellEnd(output: *std.Io.Writer, value: model.Page) !void {
    try output.writeAll("</main><footer class=\"app-footer\">Site-local context · server-rendered · no JavaScript required</footer></div></div>");
    try primaryNavigation(output, value, "mobile-navigation");
    try output.writeAll("</body></html>");
}

fn accountNavigation(
    output: *std.Io.Writer,
    csrf_token: []const u8,
    class: []const u8,
) !void {
    try output.writeAll("<nav class=\"");
    try attribute(output, class);
    try output.writeAll(" account-nav\" aria-label=\"Account\"><a href=\"/admin/security\">Security</a>" ++
        "<form class=\"inline\" method=\"post\" action=\"/admin/logout\" hx-boost=\"false\">" ++
        "<input type=\"hidden\" name=\"csrf\" value=\"");
    try attribute(output, csrf_token);
    try output.writeAll("\"><button class=\"button-secondary\" type=\"submit\">Sign out</button></form></nav>");
}

fn primaryNavigation(
    output: *std.Io.Writer,
    value: model.Page,
    class: []const u8,
) !void {
    try output.writeAll("<nav class=\"");
    try attribute(output, class);
    try output.writeAll("\" aria-label=\"Primary\">");
    inline for (std.meta.tags(model.Destination)) |destination| {
        try output.writeAll("<a href=\"");
        try canonicalUrl(output, destination, value.query, 1);
        if (destination == value.destination) {
            try output.writeAll("\" aria-current=\"page\">");
        } else {
            try output.writeAll("\">");
        }
        try output.writeAll("<span class=\"nav-short\" aria-hidden=\"true\">");
        try output.writeAll(destination.shortLabel());
        try output.writeAll("</span><span class=\"nav-label\">");
        try text(output, destination.label());
        try output.writeAll("</span></a>");
    }
    try output.writeAll("</nav>");
}

fn contextControls(output: *std.Io.Writer, value: model.Page) !void {
    const context = value.calendar_context orelse return error.MissingCalendarContext;
    try output.writeAll(
        "<div class=\"context-controls\">" ++
            "<form class=\"site-switcher\" method=\"get\" action=\"/admin\" " ++
            "data-site-switcher hx-boost=\"true\" hx-sync=\"this:replace\">" ++
            "<label><span>Site</span><select name=\"site\">",
    );
    for (value.sites) |site| {
        try output.writeAll("<option value=\"");
        try attribute(output, site.slug);
        if (std.mem.eql(u8, site.slug, value.query.site)) {
            try output.writeAll("\" selected>");
        } else {
            try output.writeAll("\">");
        }
        try text(output, site.name);
        if (site.disabled) try output.writeAll(" (disabled)");
        try output.writeAll("</option>");
    }
    try output.writeAll("</select></label>");
    try calendarHiddenFields(output, value.query);
    try output.writeAll(
        "<button class=\"button-secondary\" type=\"submit\">View site</button></form>" ++
            "<details class=\"date-presets\"><summary>",
    );
    try text(output, context.selected_preset.label());
    try output.writeAll("</summary><nav class=\"preset-list\" aria-label=\"Date presets\">");
    for (context.presets) |option| {
        if (option.preset == .custom or option.range == null) continue;
        var adjusted = value.query;
        adjusted.range = option.range.?.view();
        try output.writeAll("<a href=\"");
        try canonicalUrl(output, value.destination, adjusted, adjusted.page);
        if (option.preset == context.selected_preset) {
            try output.writeAll("\" aria-current=\"page\">");
        } else {
            try output.writeAll("\">");
        }
        try text(output, option.preset.label());
        try output.writeAll("</a>");
    }
    try output.writeAll("</nav></details><form class=\"range-filter\" method=\"get\" action=\"");
    try canonicalPath(output, value.destination, value.query);
    try output.writeAll("\" hx-boost=\"true\" hx-sync=\"this:replace\"><label><span>From</span><input type=\"date\" name=\"from\" required value=\"");
    try attribute(output, value.query.range.start);
    try output.writeAll("\"></label><label><span>To</span><input type=\"date\" name=\"to\" required value=\"");
    try attribute(output, value.query.range.end);
    try output.writeAll("\"></label><label><span>Compare</span><select name=\"compare\">");
    inline for (std.meta.tags(@TypeOf(value.query.comparison))) |comparison| {
        try output.writeAll("<option value=\"");
        try attribute(output, comparison.name());
        if (comparison == value.query.comparison) {
            try output.writeAll("\" selected>");
        } else {
            try output.writeAll("\">");
        }
        try text(output, comparisonLabel(comparison));
        try output.writeAll("</option>");
    }
    try output.writeAll("</select></label>");
    try destinationHiddenFields(output, value);
    try output.writeAll("<button type=\"submit\">Update context</button></form><dl class=\"context-state\"><div><dt>Timezone</dt><dd>");
    try text(output, context.timezone_name);
    try output.writeAll("</dd></div><div><dt>Comparison period</dt><dd>");
    if (context.comparison == .none) {
        try output.writeAll("None");
    } else if (context.comparison_range) |comparison_range| {
        try text(output, comparison_range.start[0..]);
        try output.writeAll(" – ");
        try text(output, comparison_range.end[0..]);
    } else if (context.comparison_unavailable) |unavailable| {
        try text(output, comparisonLabel(context.comparison));
        try output.writeAll(switch (unavailable) {
            .before_supported_calendar => " unavailable before 1970",
        });
    } else {
        return error.MissingComparisonResolution;
    }
    try output.writeAll("</dd></div><div><dt>Range status</dt><dd>");
    if (context.includes_incomplete_today) {
        try output.writeAll("Today is incomplete");
    } else {
        try output.writeAll("Complete local dates");
    }
    try output.writeAll("</dd></div><div><dt>Segment</dt><dd>All visitors</dd></div><div><dt>Filters</dt><dd>None</dd></div></dl></div>");
}

fn destinationHiddenFields(output: *std.Io.Writer, value: model.Page) !void {
    if (value.destination == .analyze) {
        try output.writeAll("<input type=\"hidden\" name=\"report\" value=\"");
        try attribute(output, value.query.kind.name());
        try output.writeAll("\">");
    }
    if (value.destination == .journeys and value.query.subject.len != 0) {
        try output.writeAll("<input type=\"hidden\" name=\"subject\" value=\"");
        try attribute(output, value.query.subject);
        try output.writeAll("\">");
    }
    if (value.destination == .analyze and value.query.kind == .campaigns) {
        try output.writeAll("<input type=\"hidden\" name=\"campaign\" value=\"");
        try attribute(output, @tagName(value.query.campaign_dimension));
        try output.writeAll("\">");
    }
    if (value.destination == .analyze and value.query.kind.isList()) {
        try output.writeAll("<input type=\"hidden\" name=\"sort\" value=\"");
        try attribute(output, @tagName(value.query.sort));
        try output.writeAll("\">");
    }
    if (value.destination == .analyze or
        (value.destination == .live and value.query.limit != report.default_limit))
    {
        try output.writeAll("<input type=\"hidden\" name=\"limit\" value=\"");
        try output.print("{d}", .{value.query.limit});
        try output.writeAll("\"><input type=\"hidden\" name=\"page\" value=\"1\">");
    }
}

fn calendarHiddenFields(output: *std.Io.Writer, query: model.Query) !void {
    try output.writeAll("<input type=\"hidden\" name=\"from\" value=\"");
    try attribute(output, query.range.start);
    try output.writeAll("\"><input type=\"hidden\" name=\"to\" value=\"");
    try attribute(output, query.range.end);
    try output.writeAll("\"><input type=\"hidden\" name=\"compare\" value=\"");
    try attribute(output, query.comparison.name());
    try output.writeAll("\">");
}

fn comparisonLabel(value: analysis.Comparison) []const u8 {
    return switch (value) {
        .none => "None",
        .previous => "Previous period",
        .previous_year => "Previous year",
    };
}

const NavItem = struct {
    kind: report.Kind,
    label: []const u8,
};

const navigation = [_]NavItem{
    .{ .kind = .pages, .label = "Pages" },
    .{ .kind = .entries, .label = "Entries" },
    .{ .kind = .exits, .label = "Exits" },
    .{ .kind = .sources, .label = "Sources" },
    .{ .kind = .campaigns, .label = "Campaigns" },
    .{ .kind = .countries, .label = "Countries" },
    .{ .kind = .browsers, .label = "Browsers" },
    .{ .kind = .operating_systems, .label = "OS" },
    .{ .kind = .devices, .label = "Devices" },
    .{ .kind = .events, .label = "Events" },
};

fn destinationSummary(destination: model.Destination) []const u8 {
    return switch (destination) {
        .overview => "Traffic and audience at a glance.",
        .analyze => "Explore the currently available report presets.",
        .journeys => "Review and manage goals and funnels.",
        .sessions => "Inspect visits and people without losing the shared site and date context.",
        .live => "Inspect current traffic-quality and collection diagnostics.",
        .settings => "Manage site-level tracking safeguards and exclusions.",
    };
}

fn reportSection(output: *std.Io.Writer, value: model.Page) !void {
    try output.writeAll("<section id=\"report\"><h2>");
    try text(output, reportTitle(value.query.kind));
    try output.writeAll("</h2>");
    if (value.result) |result| {
        try renderResult(output, value.query, result);
    } else {
        try output.writeAll("<p class=\"muted\">Create a definition below to run this report.</p>");
    }
    try output.writeAll("</section>");
}

fn overviewSection(output: *std.Io.Writer, value: model.Page) !void {
    const overview = value.overview_kpis orelse return error.MissingOverviewKpis;
    const quality = value.overview_quality orelse return error.MissingTrafficQuality;
    try output.writeAll(
        "<section id=\"report\" aria-labelledby=\"overview-kpis-heading\">" ++
            "<h2 id=\"overview-kpis-heading\">Key metrics</h2>",
    );
    if (overview.includes_incomplete_today) {
        try components.feedback(output, .{
            .kind = .warning,
            .message = "The selected range includes today; current values are still incomplete.",
        });
    }
    try output.writeAll("<ul class=\"metrics overview-metrics\">");
    for (overview.cards) |card| {
        var href_buffer: [analysis.maximum_url_bytes]u8 = undefined;
        var href = std.Io.Writer.fixed(&href_buffer);
        var adjusted = value.query;
        const destination: model.Destination = switch (card.target) {
            .analyze => .analyze,
            .goals => target: {
                adjusted.kind = .goal;
                adjusted.subject = "";
                break :target .journeys;
            },
        };
        try canonicalUrlRaw(&href, destination, adjusted, 1);
        try components.kpi(output, .{
            .label = card.label,
            .value = card.value,
            .detail = card.comparison,
            .detail_kind = switch (card.direction) {
                .neutral => .neutral,
                .positive => .positive,
                .negative => .negative,
            },
            .href = href.buffered(),
            .definition = card.definition,
        });
    }
    try output.writeAll("</ul><p class=\"coverage-note\">");
    try text(output, overview.coverage);
    try output.writeAll("</p>");
    if (overview.comparison_coverage) |coverage| {
        try output.writeAll("<p class=\"coverage-note\">");
        try text(output, coverage);
        try output.writeAll("</p>");
    }
    try components.feedback(output, .{
        .kind = .warning,
        .message = "Traffic-quality diagnostics below use received UTC dates and are separate from the site-local KPI range.",
    });
    try renderTrafficQuality(output, value.query, quality, false);
    try output.writeAll("</section>");
}

fn reportNavigation(output: *std.Io.Writer, value: model.Page) !void {
    try output.writeAll("<div class=\"report-navigation\"><nav class=\"report-tabs\" aria-label=\"Reports\">");
    for (navigation) |item| {
        try reportLink(output, value.query, item.kind, "", item.label);
    }
    try output.writeAll("</nav></div>");
}

fn journeyNavigation(output: *std.Io.Writer, value: model.Page) !void {
    try output.writeAll("<div class=\"report-navigation\"><nav class=\"report-tabs\" aria-label=\"Journey type\">");
    try journeyTypeLink(output, value.query, .goal, "Goals");
    try journeyTypeLink(output, value.query, .funnel, "Funnels");
    try output.writeAll("</nav>");
    if (value.goals.len != 0 or value.funnels.len != 0) {
        try output.writeAll("<div class=\"conversion-navigation\"><span class=\"eyebrow\">Definitions</span><nav aria-label=\"Journey definitions\">");
    }
    for (value.goals) |goal| {
        try reportLink(output, value.query, .goal, goal.name, goal.name);
    }
    for (value.funnels) |funnel| {
        try reportLink(output, value.query, .funnel, funnel.name, funnel.name);
    }
    if (value.goals.len != 0 or value.funnels.len != 0) {
        try output.writeAll("</nav></div>");
    }
    try output.writeAll("</div>");
}

fn journeyTypeLink(
    output: *std.Io.Writer,
    query: model.Query,
    kind: report.Kind,
    label: []const u8,
) !void {
    try output.writeAll("<a hx-boost=\"true\" href=\"");
    try queryUrl(output, query, kind, "", 1);
    if (query.kind == kind) {
        try output.writeAll("\" aria-current=\"page\">");
    } else {
        try output.writeAll("\">");
    }
    try text(output, label);
    try output.writeAll("</a>");
}

fn reportLink(
    output: *std.Io.Writer,
    query: model.Query,
    kind: report.Kind,
    subject: []const u8,
    label: []const u8,
) !void {
    try output.writeAll("<a hx-boost=\"true\"");
    if (subject.len == 0) {
        try output.writeAll(" id=\"report-nav-");
        try attribute(output, kind.name());
        try output.writeAll("\"");
    }
    try output.writeAll(" href=\"");
    try queryUrl(output, query, kind, subject, 1);
    if (query.kind == kind and std.mem.eql(u8, query.subject, subject)) {
        try output.writeAll("\" aria-current=\"page\">");
    } else {
        try output.writeAll("\">");
    }
    try text(output, label);
    try output.writeAll("</a>");
}

fn renderResult(
    output: *std.Io.Writer,
    query: model.Query,
    result: report.Result,
) !void {
    switch (result) {
        .overview => return error.LegacyOverviewResult,
        .traffic_quality => |quality| try renderTrafficQuality(output, query, quality, true),
        .list => |list| {
            if (query.kind == .campaigns) try campaignTabs(output, query);
            var maximum_primary: i64 = 0;
            for (list.rows) |row| {
                if (row.primary < 0 or row.secondary < 0) return error.InvalidReportCount;
                maximum_primary = @max(maximum_primary, row.primary);
            }
            try output.writeAll("<div class=\"table-scroll mobile-records\"><table><caption>");
            try text(output, reportTitle(query.kind));
            try output.writeAll(" — exact values for the selected range</caption><thead><tr><th scope=\"col\">");
            try text(output, humanize(list.label_name));
            try output.writeAll("</th><th scope=\"col\">");
            try text(output, humanize(list.primary_name));
            try output.writeAll("</th><th scope=\"col\">");
            try text(output, humanize(list.secondary_name));
            try output.writeAll("</th></tr></thead><tbody>");
            for (list.rows) |row| {
                try output.writeAll("<tr><th scope=\"row\" data-label=\"");
                try attribute(output, humanize(list.label_name));
                try output.writeAll("\">");
                try text(output, row.label);
                try output.writeAll("</th><td data-label=\"");
                try attribute(output, humanize(list.primary_name));
                try output.print("\"><span class=\"cell-number\">{d}</span><progress class=\"cell-bar\" max=\"{d}\" value=\"{d}\" aria-label=\"", .{
                    row.primary,
                    @max(1, maximum_primary),
                    @max(0, row.primary),
                });
                try attribute(output, row.label);
                try output.writeAll(" — ");
                try attribute(output, humanize(list.primary_name));
                try output.print(": {d}\"></progress></td><td data-label=\"", .{row.primary});
                try attribute(output, humanize(list.secondary_name));
                try output.print("\">{d}</td></tr>", .{row.secondary});
            }
            if (list.rows.len == 0) {
                try output.writeAll("<tr><td colspan=\"3\">No results in this range.</td></tr>");
            }
            try output.writeAll("</tbody></table></div><nav aria-label=\"Pagination\">");
            if (query.page > 1) {
                try output.writeAll("<a hx-boost=\"true\" rel=\"prev\" href=\"");
                try queryUrl(output, query, query.kind, query.subject, query.page - 1);
                try output.writeAll("\">Previous</a>");
            }
            if (list.next_page) |next| {
                try output.writeAll("<a hx-boost=\"true\" rel=\"next\" href=\"");
                try queryUrl(output, query, query.kind, query.subject, next);
                try output.writeAll("\">Next</a>");
            }
            try output.writeAll("</nav>");
        },
        .goal => |goal| {
            try output.writeAll("<ul class=\"metrics\">");
            try metric(output, "Matches", goal.total_matches);
            try metric(output, "Converted sessions", goal.matching_sessions);
            try metric(output, "Eligible sessions", goal.eligible_sessions);
            try ratioKpi(output, "Conversion rate", goal.matching_sessions, goal.eligible_sessions);
            try output.writeAll("</ul>");
        },
        .funnel => |funnel| {
            if (funnel.steps.len > charts.maximum_funnel_steps) {
                return error.TooManyFunnelSteps;
            }
            var steps: [charts.maximum_funnel_steps]charts.FunnelStep = undefined;
            for (funnel.steps, 0..) |step, index| {
                steps[index] = .{
                    .name = step.name,
                    .sessions = try nonnegative(step.sessions),
                };
            }
            try charts.renderFunnel(output, .{
                .id = "funnel-result",
                .title = "Funnel result",
                .summary = "Sessions reaching each ordered step. Median time to the next step is unavailable in the current metric-v1 report.",
                .entrants = try nonnegative(funnel.eligible_sessions),
                .steps = steps[0..funnel.steps.len],
            });
        },
    }
}

fn renderTrafficQuality(
    output: *std.Io.Writer,
    query: model.Query,
    quality: report.TrafficQuality,
    show_headlines: bool,
) !void {
    if (show_headlines) {
        try output.writeAll("<ul class=\"metrics\">");
        try metric(output, "Visitor-days", quality.visitor_days);
        try metric(output, "Distinct people", quality.distinct_people);
        try output.writeAll("</ul>");
    }
    try output.writeAll(
        "<section aria-labelledby=\"traffic-quality-heading\"><h3 id=\"traffic-quality-heading\">Traffic quality</h3>" ++
            "<p class=\"muted\">Stored classes plus reversible query-classifier v1 diagnostics. Bot and explicit self-exclusion remain separate; strict mode excludes only current low-quality sessions.</p>",
    );
    if (quality.ceiling_reached_days != 0) {
        var warning_buffer: [192]u8 = undefined;
        const warning = try std.fmt.bufPrint(
            &warning_buffer,
            "The daily accepted-event ceiling was reached on {d} site-local day(s) in this range. New events received after the cap returned 429.",
            .{quality.ceiling_reached_days},
        );
        try components.feedback(output, .{ .kind = .warning, .message = warning });
    }
    try output.writeAll("<ul class=\"metrics\">");
    try metric(output, "Persistent people", quality.persistent_people);
    try metric(output, "Ephemeral people", quality.ephemeral_people);
    try metric(output, "Legacy daily people", quality.legacy_people);
    try ratioKpi(output, "Persistent coverage", quality.persistent_people, quality.distinct_people);
    try metric(
        output,
        "Zero-engagement single-event sessions",
        quality.zero_engagement_single_event_sessions,
    );
    try metric(output, "Query candidates", quality.raw_candidates);
    try metric(output, "Current low-quality sessions", quality.current_suspected_sessions);
    try metric(output, "Contradicted candidates", quality.contradicted_candidates);
    try basisPointsKpi(output, "Contradiction rate", quality.contradiction_basis_points);
    try metric(output, "Accepted events", quality.accepted_events);
    try metric(output, "Prefix anomaly groups", quality.mint_anomaly_groups);
    try output.writeAll(
        "</ul><h4>Identity quality</h4><div class=\"table-scroll mobile-records\"><table>" ++
            "<caption>Identity-quality events and visitor-days</caption><thead><tr>" ++
            "<th scope=\"col\">Identity quality</th><th scope=\"col\">Events</th><th scope=\"col\">Visitor-days</th>" ++
            "</tr></thead><tbody>",
    );
    for (quality.identity_quality) |row| {
        try output.writeAll("<tr><th scope=\"row\" data-label=\"Identity quality\">");
        try text(output, humanize(row.quality.name()));
        try output.print("</th><td data-label=\"Events\">{d}</td><td data-label=\"Visitor-days\">{d}</td></tr>", .{
            row.events, row.visitor_days,
        });
    }
    try output.writeAll(
        "</tbody></table></div><h4>Stored self-exclusion</h4>" ++
            "<div class=\"table-scroll\"><table><caption>Stored exclusion source counts</caption><thead><tr>" ++
            "<th scope=\"col\">Source</th><th scope=\"col\">Events</th></tr></thead><tbody>",
    );
    for (quality.exclusion_sources) |row| {
        try output.writeAll("<tr><th scope=\"row\">");
        try text(output, humanize(@tagName(row.source)));
        try output.print("</th><td>{d}</td></tr>", .{row.events});
    }
    try output.writeAll(
        "</tbody></table></div><h4>Traffic class</h4>" ++
            "<div class=\"table-scroll\"><table><caption>Stored traffic-class counts</caption><thead><tr>" ++
            "<th scope=\"col\">Class</th><th scope=\"col\">Events</th></tr></thead><tbody>",
    );
    for (quality.traffic_classes) |row| {
        try output.writeAll("<tr><th scope=\"row\">");
        try text(output, humanize(row.class.name()));
        try output.print("</th><td>{d}</td></tr>", .{row.events});
    }
    try output.print(
        "</tbody></table></div><h4>Bounded signal evidence</h4>" ++
            "<div class=\"table-scroll\"><table><caption>Bounded client-signal evidence counts</caption><thead><tr>" ++
            "<th scope=\"col\">Evidence</th><th scope=\"col\">Events</th></tr></thead><tbody>" ++
            "<tr><th scope=\"row\">Client signal v1</th><td>{d}</td></tr>" ++
            "<tr><th scope=\"row\">WebDriver</th><td>{d}</td></tr>" ++
            "<tr><th scope=\"row\">Trusted interaction</th><td>{d}</td></tr>" ++
            "<tr><th scope=\"row\">Was visible</th><td>{d}</td></tr>" ++
            "<tr><th scope=\"row\">Was prerendered</th><td>{d}</td></tr>" ++
            "<tr><th scope=\"row\">Client-hint mismatch</th><td>{d}</td></tr>" ++
            "<tr><th scope=\"row\">Expected client hints absent</th><td>{d}</td></tr>" ++
            "<tr><th scope=\"row\">Accept-Language present</th><td>{d}</td></tr>" ++
            "</tbody></table></div>",
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
    if (show_headlines) {
        try output.writeAll(
            "<h4>Classifier rules</h4><div class=\"table-scroll mobile-records\"><table>" ++
                "<caption>Stored classifier rule counts</caption><thead><tr><th scope=\"col\">Rule</th><th scope=\"col\">Class</th><th scope=\"col\">Version</th>" ++
                "<th scope=\"col\">Events</th></tr></thead><tbody>",
        );
        for (quality.rules) |row| {
            try output.writeAll("<tr><th scope=\"row\" data-label=\"Rule\">");
            try text(output, if (row.rule.len == 0) "(none)" else row.rule);
            try output.writeAll("</th><td data-label=\"Class\">");
            try text(output, humanize(row.class.name()));
            try output.print("</td><td data-label=\"Version\">{d}</td><td data-label=\"Events\">{d}</td></tr>", .{
                row.classifier_version,
                row.events,
            });
        }
        try output.writeAll("</tbody></table></div>");
    }
    try output.writeAll(
        "<h4>Daily diagnostics</h4>" ++
            "<div class=\"table-scroll mobile-records\"><table><caption>Daily traffic-quality diagnostics</caption><thead><tr><th scope=\"col\">Date (UTC)</th>" ++
            "<th scope=\"col\">New anonymous identities</th><th scope=\"col\">Bot events</th>" ++
            "<th scope=\"col\">Current low-quality sessions</th><th scope=\"col\">Accepted (site-local date)</th>" ++
            "<th scope=\"col\">Prefix anomaly groups</th><th scope=\"col\">Largest identity mint</th><th scope=\"col\">Ceiling</th>" ++
            "</tr></thead><tbody>",
    );
    for (quality.days) |day| {
        try output.writeAll("<tr><th scope=\"row\" data-label=\"Date (UTC)\">");
        try text(output, day.date);
        try output.print("</th><td data-label=\"New anonymous identities\">{d}</td><td data-label=\"Bot events\">{d}</td><td data-label=\"Current low-quality sessions\">{d}</td><td data-label=\"Accepted (site-local date)\">{d}</td><td data-label=\"Prefix anomaly groups\">{d}</td><td data-label=\"Largest identity mint\">{d}</td><td data-label=\"Ceiling\">{s}</td></tr>", .{
            day.new_anonymous_identities,
            day.bot_events,
            day.suspected_sessions,
            day.accepted_events,
            day.mint_anomaly_groups,
            day.maximum_minted_identities,
            if (day.ceiling_reached) "reached" else "below",
        });
    }
    try output.writeAll("</tbody></table></div><nav aria-label=\"Traffic-quality pagination\">");
    if (!show_headlines and quality.next_page != null) {
        try output.writeAll("<a hx-boost=\"true\" href=\"");
        try queryUrl(output, query, .traffic_quality, "", 1);
        try output.writeAll("\">View all diagnostics</a>");
    } else if (show_headlines) {
        if (query.page > 1) {
            try output.writeAll("<a hx-boost=\"true\" rel=\"prev\" href=\"");
            try queryUrl(output, query, .traffic_quality, "", query.page - 1);
            try output.writeAll("\">Previous</a>");
        }
        if (quality.next_page) |next| {
            try output.writeAll("<a hx-boost=\"true\" rel=\"next\" href=\"");
            try queryUrl(output, query, .traffic_quality, "", next);
            try output.writeAll("\">Next</a>");
        }
    }
    try output.writeAll("</nav></section>");
}

fn campaignTabs(output: *std.Io.Writer, query: model.Query) !void {
    try output.writeAll("<nav aria-label=\"Campaign dimension\">");
    inline for (.{ "source", "medium", "campaign", "term", "content", "all" }) |name| {
        const dimension = report.CampaignDimension.parse(name) catch unreachable;
        try output.writeAll("<a hx-boost=\"true\" href=\"");
        var adjusted = query;
        adjusted.campaign_dimension = dimension;
        try queryUrl(output, adjusted, .campaigns, "", 1);
        if (query.campaign_dimension == dimension) {
            try output.writeAll("\" aria-current=\"page\">");
        } else {
            try output.writeAll("\">");
        }
        try text(output, humanize(name));
        try output.writeAll("</a>");
    }
    try output.writeAll("</nav>");
}

fn definitions(output: *std.Io.Writer, value: model.Page) !void {
    try output.writeAll("<details class=\"management\"");
    if (value.form_error.len != 0 or value.notice.len != 0) {
        try output.writeAll(" open");
    }
    try output.print(
        "><summary><span>Goals &amp; funnels</span><span class=\"muted\">{d} goals · {d} funnels</span></summary>" ++
            "<div class=\"split\"><section class=\"panel\"><h2>Goals</h2><ul class=\"definition-list\">",
        .{ value.goals.len, value.funnels.len },
    );
    for (value.goals) |goal| {
        try output.writeAll("<li><strong>");
        try text(output, goal.name);
        try output.writeAll("</strong> <span class=\"muted\">");
        try text(output, @tagName(goal.match_kind));
        try output.writeAll(" = ");
        try text(output, goal.match_value);
        try output.writeAll("</span> ");
        try deleteForm(output, "/admin/goals/delete", value, goal.name);
        try output.writeAll("</li>");
    }
    if (value.goals.len == 0) try output.writeAll("<li>No goals yet.</li>");
    try output.writeAll("</ul><h3>Add goal</h3><form method=\"post\" action=\"/admin/goals\" hx-boost=\"true\" hx-sync=\"this:drop\">");
    try formCommon(output, value);
    try output.writeAll("<label>Name<input name=\"name\" maxlength=\"120\" required");
    try formErrorAttributes(output, value, .goal);
    try output.writeAll(" value=\"");
    try attribute(output, value.goal_draft.name);
    try output.writeAll("\"></label><label>Match<select name=\"kind\"");
    try formErrorAttributes(output, value, .goal);
    try output.writeAll(">");
    inline for (.{ "event", "path", "prefix" }) |kind| {
        try output.writeAll("<option");
        if (std.mem.eql(u8, value.goal_draft.match_kind, kind)) {
            try output.writeAll(" selected");
        }
        try output.writeAll(">");
        try text(output, kind);
        try output.writeAll("</option>");
    }
    try output.writeAll("</select></label><label>Value<input name=\"value\" maxlength=\"1024\" required");
    try formErrorAttributes(output, value, .goal);
    try output.writeAll(" value=\"");
    try attribute(output, value.goal_draft.match_value);
    try output.writeAll("\"></label><button type=\"submit\">Add goal</button></form></section>");

    try output.writeAll("<section class=\"panel\"><h2>Funnels</h2><ul class=\"definition-list\">");
    for (value.funnels) |funnel| {
        try output.writeAll("<li><strong>");
        try text(output, funnel.name);
        try output.print("</strong> <span class=\"muted\">{d} steps</span> ", .{
            funnel.step_count,
        });
        try deleteForm(output, "/admin/funnels/delete", value, funnel.name);
        try output.writeAll("</li>");
    }
    if (value.funnels.len == 0) try output.writeAll("<li>No funnels yet.</li>");
    try output.writeAll("</ul><h3>Add funnel</h3><form method=\"post\" action=\"/admin/funnels\" hx-boost=\"true\" hx-sync=\"this:drop\">");
    try formCommon(output, value);
    try output.writeAll("<label>Name<input name=\"name\" maxlength=\"120\" required");
    try formErrorAttributes(output, value, .funnel);
    try output.writeAll(" value=\"");
    try attribute(output, value.funnel_draft.name);
    try output.writeAll("\"></label><label>Steps, one <code>kind=value</code> per line<textarea name=\"steps\" maxlength=\"8192\" required");
    try formErrorAttributes(output, value, .funnel);
    try output.writeAll(">");
    try text(output, value.funnel_draft.steps);
    try output.writeAll("</textarea></label><button type=\"submit\">Add funnel</button></form></section></div></details>");
}

fn selfExclusions(output: *std.Io.Writer, value: model.Page) !void {
    const site = value.selected_site.?;
    try output.writeAll(
        "<details class=\"management\"",
    );
    if (value.form_error_target == .network) try output.writeAll(" open");
    try output.writeAll("><summary><span>Self-visit exclusion</span><span class=\"muted\">");
    try output.print("{d} network prefixes</span></summary><div class=\"split\">", .{
        value.excluded_networks.len,
    });
    try output.writeAll(
        "<section class=\"panel\"><h2>This browser</h2>" ++
            "<p>Browser storage is origin-scoped. Set or clear the flag on each measured origin you use. " ++
            "This control requires JavaScript; flagged events remain stored in traffic-quality diagnostics.</p>" ++
            "<ul class=\"definition-list\">",
    );
    for (value.self_exclusion_origins) |origin| {
        try output.writeAll("<li><code>");
        try text(output, origin);
        try output.writeAll(
            "</code> <a class=\"button-secondary\" hx-boost=\"false\" target=\"_blank\" data-self-exclusion=\"on\" data-site=\"",
        );
        try attribute(output, site.id);
        try output.writeAll("\" data-origin=\"");
        try attribute(output, origin);
        try output.writeAll("\" href=\"");
        try attribute(output, origin);
        try output.writeAll("/#analytico-self-exclusion=on:");
        try attribute(output, site.id);
        try output.writeAll(
            "\">Exclude this browser</a> " ++
                "<a hx-boost=\"false\" target=\"_blank\" data-self-exclusion=\"off\" data-site=\"",
        );
        try attribute(output, site.id);
        try output.writeAll("\" data-origin=\"");
        try attribute(output, origin);
        try output.writeAll("\" href=\"");
        try attribute(output, origin);
        try output.writeAll("/#analytico-self-exclusion=off:");
        try attribute(output, site.id);
        try output.writeAll("\">Include this browser again</a></li>");
    }
    try output.writeAll(
        "</ul></section>" ++
            "<section class=\"panel\"><h2>Network prefixes</h2>" ++
            "<p>Store at most 16 exact IPv4 /24 or IPv6 /48 prefixes. Raw visitor IPs are never stored.</p>" ++
            "<ul class=\"definition-list\">",
    );
    for (value.excluded_networks) |network| {
        try output.writeAll("<li><code>");
        try text(output, network);
        try output.writeAll(
            "</code> <form class=\"inline\" method=\"post\" hx-boost=\"true\" hx-sync=\"this:drop\" action=\"/admin/exclusions/networks/delete\">",
        );
        try formCommon(output, value);
        try output.writeAll("<input type=\"hidden\" name=\"network\" value=\"");
        try attribute(output, network);
        try output.writeAll(
            "\"><button class=\"danger\" type=\"submit\">Delete</button></form></li>",
        );
    }
    if (value.excluded_networks.len == 0) {
        try output.writeAll("<li>No network exclusions yet.</li>");
    }
    try output.writeAll(
        "</ul><h3>Add network prefix</h3>" ++
            "<form method=\"post\" action=\"/admin/exclusions/networks\" hx-boost=\"true\" hx-sync=\"this:drop\">",
    );
    try formCommon(output, value);
    try output.writeAll(
        "<label>IP address or fixed prefix<input name=\"network\" maxlength=\"64\" " ++
            "placeholder=\"203.0.113.0/24\" required",
    );
    try formErrorAttributes(output, value, .network);
    try output.writeAll(" value=\"");
    try attribute(output, value.network_draft);
    try output.writeAll(
        "\"></label><button type=\"submit\">Add network exclusion</button></form>" ++
            "</section></div></details>",
    );
}

fn trafficPolicy(output: *std.Io.Writer, value: model.Page) !void {
    if (value.selected_site == null) return;
    const strict_mode = if (value.traffic_policy_draft) |draft|
        draft.strict_mode
    else
        value.strict_mode;
    try output.writeAll(
        "<details class=\"management\"",
    );
    if (value.form_error_target == .traffic_policy) try output.writeAll(" open");
    try output.writeAll("><summary><span>Traffic safeguards</span><span class=\"muted\">");
    try output.writeAll(if (strict_mode) "Strict on" else "Strict off");
    try output.print(" · ceiling {d}</span></summary>", .{value.daily_event_ceiling});
    try output.writeAll(
        "<section class=\"panel\"><h2>Traffic safeguards</h2>" ++
            "<p>Strict mode is off by default and excludes only current query-time low-quality sessions. The daily ceiling counts every stored class and returns 429 instead of silently dropping data.</p>" ++
            "<form method=\"post\" action=\"/admin/traffic-policy\" hx-boost=\"true\" hx-sync=\"this:drop\">",
    );
    try formCommon(output, value);
    try output.writeAll("<label><input type=\"checkbox\" name=\"strict\" value=\"on\"");
    if (strict_mode) try output.writeAll(" checked");
    try formErrorAttributes(output, value, .traffic_policy);
    try output.writeAll("> Exclude current low-quality sessions from product metrics</label>");
    try output.writeAll("<label>Daily accepted-event ceiling<input type=\"number\" name=\"daily_event_ceiling\" min=\"1\" max=\"10000000\" required");
    try formErrorAttributes(output, value, .traffic_policy);
    try output.writeAll(" value=\"");
    if (value.traffic_policy_draft) |draft| {
        try attribute(output, draft.daily_event_ceiling);
    } else {
        try output.print("{d}", .{value.daily_event_ceiling});
    }
    try output.writeAll("\"></label>");
    try output.writeAll("<button type=\"submit\">Save traffic safeguards</button></form></section></details>");
}

fn deleteForm(
    output: *std.Io.Writer,
    action: []const u8,
    value: model.Page,
    name: []const u8,
) !void {
    try output.writeAll("<form class=\"inline\" method=\"post\" hx-boost=\"true\" hx-sync=\"this:drop\" action=\"");
    try attribute(output, action);
    try output.writeAll("\">");
    try formCommon(output, value);
    try output.writeAll("<input type=\"hidden\" name=\"name\" value=\"");
    try attribute(output, name);
    try output.writeAll("\"><button class=\"danger\" type=\"submit\">Delete</button></form>");
}

fn formCommon(output: *std.Io.Writer, value: model.Page) !void {
    try output.writeAll("<input type=\"hidden\" name=\"csrf\" value=\"");
    try attribute(output, value.csrf_token);
    try output.writeAll("\"><input type=\"hidden\" name=\"site\" value=\"");
    try attribute(output, value.query.site);
    try output.writeAll("\">");
    try calendarHiddenFields(output, value.query);
}

fn formErrorAttributes(
    output: *std.Io.Writer,
    value: model.Page,
    target: model.FormErrorTarget,
) !void {
    if (value.form_error.len != 0 and value.form_error_target == target) {
        try output.writeAll(" aria-invalid=\"true\" aria-describedby=\"form-error-summary\"");
    }
}

fn metric(output: *std.Io.Writer, name: []const u8, count: i64) !void {
    if (count < 0) return error.InvalidReportCount;
    var buffer: [32]u8 = undefined;
    const value = try std.fmt.bufPrint(&buffer, "{d}", .{count});
    try components.kpi(output, .{ .label = name, .value = value });
}

fn ratioKpi(
    output: *std.Io.Writer,
    name: []const u8,
    numerator: i64,
    denominator: i64,
) !void {
    var buffer: [32]u8 = undefined;
    const value = try percentText(&buffer, numerator, denominator);
    try components.kpi(output, .{ .label = name, .value = value });
}

fn basisPointsKpi(
    output: *std.Io.Writer,
    name: []const u8,
    basis_points: u16,
) !void {
    if (basis_points > 10_000) return error.InvalidReportRate;
    var buffer: [16]u8 = undefined;
    const value = try std.fmt.bufPrint(&buffer, "{d}.{d:0>2}%", .{
        basis_points / 100,
        basis_points % 100,
    });
    try components.kpi(output, .{ .label = name, .value = value });
}

fn percentText(buffer: []u8, numerator: i64, denominator: i64) ![]const u8 {
    if (numerator < 0 or denominator < 0) return error.InvalidReportCount;
    if ((denominator == 0 and numerator != 0) or
        (denominator != 0 and numerator > denominator))
    {
        return error.InvalidReportRate;
    }
    const hundredths: u64 = if (denominator == 0)
        0
    else
        @intCast((@as(u128, @intCast(numerator)) * 10_000) / @as(u64, @intCast(denominator)));
    const fraction = hundredths % 100;
    return std.fmt.bufPrint(buffer, "{d}.{d}{d}%", .{
        hundredths / 100,
        fraction / 10,
        fraction % 10,
    });
}

fn nonnegative(value: i64) !u64 {
    if (value < 0) return error.InvalidReportCount;
    return @intCast(value);
}

fn queryUrl(
    output: *std.Io.Writer,
    query: model.Query,
    kind: report.Kind,
    subject: []const u8,
    page_number: u32,
) !void {
    var adjusted = query;
    adjusted.kind = kind;
    adjusted.subject = subject;
    adjusted.page = page_number;
    const destination: model.Destination = switch (kind) {
        .overview => .overview,
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
        => .analyze,
        .goal, .funnel => .journeys,
        .traffic_quality => .live,
    };
    try canonicalUrl(output, destination, adjusted, page_number);
}

fn canonicalUrl(
    output: *std.Io.Writer,
    destination: model.Destination,
    query: model.Query,
    page_number: u32,
) !void {
    return canonicalUrlSeparated(
        output,
        destination,
        query,
        page_number,
        "&amp;",
    );
}

fn canonicalUrlRaw(
    output: *std.Io.Writer,
    destination: model.Destination,
    query: model.Query,
    page_number: u32,
) !void {
    return canonicalUrlSeparated(output, destination, query, page_number, "&");
}

fn canonicalUrlSeparated(
    output: *std.Io.Writer,
    destination: model.Destination,
    query: model.Query,
    page_number: u32,
    separator: []const u8,
) !void {
    var adjusted = query;
    switch (destination) {
        .overview => {
            adjusted.kind = .overview;
            adjusted.subject = "";
        },
        .analyze => if (!adjusted.kind.isList()) {
            adjusted.kind = .pages;
            adjusted.subject = "";
        },
        .journeys => if (adjusted.kind != .goal and adjusted.kind != .funnel) {
            adjusted.kind = .goal;
            adjusted.subject = "";
        },
        .sessions, .settings => {
            adjusted.kind = .overview;
            adjusted.subject = "";
        },
        .live => {
            adjusted.kind = .traffic_quality;
            adjusted.subject = "";
        },
    }
    adjusted.page = page_number;
    try canonicalPath(output, destination, adjusted);
    try output.writeAll("?from=");
    try urlComponent(output, adjusted.range.start);
    try output.writeAll(separator);
    try output.writeAll("to=");
    try urlComponent(output, adjusted.range.end);
    try output.writeAll(separator);
    try output.writeAll("compare=");
    try urlComponent(output, adjusted.comparison.name());
    switch (destination) {
        .analyze => {
            try output.writeAll(separator);
            try output.writeAll("report=");
            try urlComponent(output, adjusted.kind.name());
            if (adjusted.kind == .campaigns) {
                try output.writeAll(separator);
                try output.writeAll("campaign=");
                try urlComponent(output, @tagName(adjusted.campaign_dimension));
            }
            try output.writeAll(separator);
            try output.writeAll("sort=");
            try urlComponent(output, @tagName(adjusted.sort));
            try output.writeAll(separator);
            try output.print("limit={d}", .{adjusted.limit});
            try output.writeAll(separator);
            try output.print("page={d}", .{adjusted.page});
        },
        .journeys => if (adjusted.subject.len != 0) {
            try output.writeAll(separator);
            try output.writeAll("subject=");
            try urlComponent(output, adjusted.subject);
        },
        .live => if (adjusted.limit != report.default_limit or adjusted.page != 1) {
            try output.writeAll(separator);
            try output.print("limit={d}", .{adjusted.limit});
            try output.writeAll(separator);
            try output.print("page={d}", .{adjusted.page});
        },
        .overview, .sessions, .settings => {},
    }
}

fn canonicalPath(
    output: *std.Io.Writer,
    destination: model.Destination,
    query: model.Query,
) !void {
    try output.writeAll("/admin/sites/");
    try output.writeAll(query.site);
    try output.writeAll(switch (destination) {
        .overview => "/overview",
        .analyze => "/analyze",
        .journeys => if (query.kind == .funnel)
            "/journeys/funnels"
        else
            "/journeys/goals",
        .sessions => "/sessions",
        .live => "/live",
        .settings => "/settings/general",
    });
}

fn text(output: *std.Io.Writer, value: []const u8) !void {
    try components.text(output, value);
}

fn attribute(output: *std.Io.Writer, value: []const u8) !void {
    try components.attribute(output, value);
}

fn urlComponent(output: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or
            byte == '-' or byte == '_' or byte == '.' or byte == '~')
        {
            try output.writeByte(byte);
        } else {
            try output.writeByte('%');
            try output.writeByte(hex[byte >> 4]);
            try output.writeByte(hex[byte & 0x0f]);
        }
    }
}

fn humanize(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "page_views")) return "Page views";
    if (std.mem.eql(u8, value, "visitor_days")) return "Visitor-days";
    if (std.mem.eql(u8, value, "persistent")) return "Persistent";
    if (std.mem.eql(u8, value, "ephemeral")) return "Ephemeral";
    if (std.mem.eql(u8, value, "legacy_daily")) return "Legacy daily";
    if (std.mem.eql(u8, value, "operating_system")) return "Operating system";
    if (std.mem.eql(u8, value, "event_count")) return "Events";
    if (std.mem.eql(u8, value, "utm_source")) return "UTM source";
    if (std.mem.eql(u8, value, "utm_medium")) return "UTM medium";
    if (std.mem.eql(u8, value, "utm_campaign")) return "UTM campaign";
    if (std.mem.eql(u8, value, "utm_term")) return "UTM term";
    if (std.mem.eql(u8, value, "utm_content")) return "UTM content";
    if (std.mem.eql(u8, value, "campaign_tuple")) return "Campaign";
    return value;
}

fn reportTitle(kind: report.Kind) []const u8 {
    return switch (kind) {
        .overview => "Overview",
        .pages => "Popular pages",
        .entries => "Entry pages",
        .exits => "Exit pages",
        .sources => "Referral sources",
        .campaigns => "Marketing campaigns",
        .countries => "Countries",
        .browsers => "Browsers",
        .operating_systems => "Operating systems",
        .devices => "Devices",
        .events => "Custom events",
        .traffic_quality => "Traffic quality diagnostics",
        .goal => "Conversion goal",
        .funnel => "Funnel",
    };
}

fn designGroup(root: std.json.ObjectMap, name: []const u8) !std.json.ObjectMap {
    const value = root.get(name) orelse return error.MissingDesignTokenGroup;
    return switch (value) {
        .object => |object| object,
        else => error.InvalidDesignTokenGroup,
    };
}

fn designString(group: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = group.get(name) orelse return error.MissingDesignToken;
    return switch (value) {
        .string => |string| string,
        else => error.InvalidDesignToken,
    };
}

fn expectTokenGroup(prefix: []const u8, group: std.json.ObjectMap) !void {
    var iterator = group.iterator();
    while (iterator.next()) |entry| {
        const value = switch (entry.value_ptr.*) {
            .string => |string| string,
            else => return error.InvalidDesignToken,
        };
        const declaration = try std.fmt.allocPrint(
            std.testing.allocator,
            "--{s}-{s}: {s};",
            .{ prefix, entry.key_ptr.*, value },
        );
        defer std.testing.allocator.free(declaration);
        try std.testing.expect(std.mem.indexOf(u8, stylesheet, declaration) != null);
    }
}

fn relativeLuminance(value: []const u8) !f64 {
    if (value.len != 7 or value[0] != '#') return error.InvalidDesignColor;
    var channels: [3]f64 = undefined;
    for (&channels, 0..) |*channel, index| {
        const byte = try std.fmt.parseInt(
            u8,
            value[1 + index * 2 .. 3 + index * 2],
            16,
        );
        const encoded: f64 = @as(f64, @floatFromInt(byte)) / 255.0;
        channel.* = if (encoded <= 0.04045)
            encoded / 12.92
        else
            std.math.pow(f64, (encoded + 0.055) / 1.055, 2.4);
    }
    return 0.2126 * channels[0] + 0.7152 * channels[1] +
        0.0722 * channels[2];
}

fn expectContrast(
    foreground: []const u8,
    background: []const u8,
    minimum: f64,
) !void {
    const first = try relativeLuminance(foreground);
    const second = try relativeLuminance(background);
    const lighter = @max(first, second);
    const darker = @min(first, second);
    try std.testing.expect((lighter + 0.05) / (darker + 0.05) >= minimum);
}

test "report percentages format zero and positive signed counts exactly" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0.00%", try percentText(&buffer, 0, 0));
    try std.testing.expectEqualStrings("0.00%", try percentText(&buffer, 0, 7));
    try std.testing.expectEqualStrings("33.33%", try percentText(&buffer, 1, 3));
    try std.testing.expectEqualStrings("100.00%", try percentText(&buffer, 7, 7));
    try std.testing.expectError(error.InvalidReportCount, percentText(&buffer, -1, 7));
    try std.testing.expectError(error.InvalidReportCount, percentText(&buffer, 1, -7));
    try std.testing.expectError(error.InvalidReportRate, percentText(&buffer, 1, 0));
    try std.testing.expectError(error.InvalidReportRate, percentText(&buffer, 8, 7));
}

test "production stylesheet mirrors the approved accessible design tokens" {
    const source = @embedFile("../../docs/design-tokens.json");
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        source,
        .{},
    );
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidDesignTokenDocument,
    };
    try std.testing.expectEqualStrings(
        "analytico.design-tokens.v1",
        try designString(root, "$schema"),
    );
    const light = try designGroup(root, "light");
    const dark = try designGroup(root, "dark");
    try expectTokenGroup("color", light);
    try expectTokenGroup("color", dark);
    try expectTokenGroup("space", try designGroup(root, "space"));
    try expectTokenGroup("radius", try designGroup(root, "radius"));
    try expectTokenGroup("font", try designGroup(root, "font"));
    try expectTokenGroup("layout", try designGroup(root, "layout"));

    try expectContrast(try designString(light, "ink"), try designString(light, "canvas"), 4.5);
    try expectContrast(try designString(light, "inkSoft"), try designString(light, "canvas"), 4.5);
    try expectContrast(try designString(light, "inkMuted"), try designString(light, "canvas"), 4.5);
    try expectContrast(try designString(light, "brandStrong"), try designString(light, "canvas"), 4.5);
    try expectContrast(try designString(light, "brandHover"), try designString(light, "canvas"), 4.5);
    try expectContrast(try designString(light, "focus"), try designString(light, "canvas"), 3.0);
    try expectContrast(try designString(light, "positive"), try designString(light, "positiveWash"), 4.5);
    try expectContrast(try designString(light, "ink"), try designString(light, "warningWash"), 4.5);
    try expectContrast(try designString(light, "warning"), try designString(light, "warningWash"), 3.0);
    try expectContrast(try designString(light, "danger"), try designString(light, "dangerWash"), 4.5);
    try expectContrast(try designString(dark, "ink"), try designString(dark, "canvas"), 4.5);
    try expectContrast(try designString(dark, "inkSoft"), try designString(dark, "canvas"), 4.5);
    try expectContrast(try designString(dark, "inkMuted"), try designString(dark, "canvas"), 4.5);
    try expectContrast(try designString(dark, "brand"), try designString(dark, "canvas"), 4.5);
    try expectContrast(try designString(dark, "brandHover"), try designString(dark, "canvas"), 4.5);
    try expectContrast(try designString(dark, "focus"), try designString(dark, "canvas"), 3.0);
    try expectContrast(try designString(dark, "positive"), try designString(dark, "positiveWash"), 4.5);
    try expectContrast(try designString(dark, "ink"), try designString(dark, "warningWash"), 4.5);
    try expectContrast(try designString(dark, "warning"), try designString(dark, "warningWash"), 3.0);
    try expectContrast(try designString(dark, "danger"), try designString(dark, "dangerWash"), 4.5);

    try std.testing.expect(std.mem.indexOf(u8, stylesheet, "@import") == null);
    try std.testing.expect(std.mem.indexOf(u8, stylesheet, "url(") == null);
    try std.testing.expectEqualStrings("/admin/app.v7.css", stylesheet_path);
}
