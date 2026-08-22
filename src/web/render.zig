const std = @import("std");
const report = @import("../report.zig");
const model = @import("model.zig");

pub const stylesheet = @embedFile("style.css");
pub const stylesheet_path = "/admin/app.v2.css";
pub const htmx = @embedFile("htmx_js");
pub const htmx_gzip = @embedFile("htmx_gzip");
pub const htmx_path = "/admin/htmx.28fae7bb.js";
pub const dashboard_js = @embedFile("dashboard.js");
pub const dashboard_js_path = "/admin/dashboard.5f88a716.js";

const html_headers =
    "Cache-Control: private, no-store, max-age=0\r\n" ++
    "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; " ++
    "connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'\r\n" ++
    "X-Content-Type-Options: nosniff\r\n" ++
    "Referrer-Policy: same-origin\r\n";

pub const headers = html_headers;

pub fn page(output: *std.Io.Writer, value: model.Page) !void {
    try head(output, "Dashboard");
    try output.writeAll(
        "<header class=\"app-header\"><h1><a class=\"brand\" href=\"/admin\">Analytico</a></h1>" ++
            "<nav class=\"account-nav\" aria-label=\"Account\"><a href=\"/admin/security\">Security</a>" ++
            "<form class=\"inline\" method=\"post\" action=\"/admin/logout\" hx-boost=\"false\">" ++
            "<input type=\"hidden\" name=\"csrf\" value=\"",
    );
    try attribute(output, value.csrf_token);
    try output.writeAll(
        "\"><button class=\"button-secondary\" type=\"submit\">Sign out</button></form>" ++
            "</nav></header><main>",
    );
    if (value.notice.len != 0) {
        try output.writeAll("<p class=\"notice\" role=\"status\">");
        try text(output, value.notice);
        try output.writeAll("</p>");
    }
    if (value.form_error.len != 0) {
        try output.writeAll("<p class=\"error\" role=\"alert\">");
        try text(output, value.form_error);
        try output.writeAll("</p>");
    }
    if (value.selected_site == null) {
        try output.writeAll(
            "<section class=\"panel\"><h2>No sites configured</h2>" ++
                "<p>Add the first site with <code>analytico site add " ++
                "... --timezone &lt;IANA-zone&gt;</code>, " ++
                "then restart the service.</p></section></main>",
        );
        try foot(output);
        return;
    }
    try output.writeAll("<section class=\"site-context\"><div><span class=\"eyebrow\">Current site</span><strong>");
    try text(output, value.selected_site.?.name);
    try output.writeAll("</strong><span class=\"muted\">");
    try text(output, value.query.start_date);
    try output.writeAll(" to ");
    try text(output, value.query.end_date);
    try output.writeAll(" · UTC</span></div></section>");
    try filters(output, value);
    try reportNavigation(output, value);
    try output.writeAll("<section id=\"report\"><h2>");
    try text(output, reportTitle(value.query.kind));
    try output.writeAll("</h2>");
    if (value.result) |result| {
        try renderResult(output, value.query, result);
    } else {
        try output.writeAll("<p class=\"muted\">Create a definition below to run this report.</p>");
    }
    try output.writeAll("</section>");
    try definitions(output, value);
    try output.writeAll("</main>");
    try foot(output);
}

pub fn errorPage(output: *std.Io.Writer, value: model.ErrorPage) !void {
    try head(output, value.title);
    try output.writeAll("<header><h1>Analytico</h1></header><main><section class=\"panel\"><h2>");
    try text(output, value.title);
    try output.writeAll("</h2><p class=\"error\" role=\"alert\">");
    try text(output, value.message);
    try output.writeAll("</p><p><a hx-boost=\"true\" href=\"");
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
    try output.writeAll("\"></script></head><body hx-boost:inherited=\"true\">");
}

fn foot(output: *std.Io.Writer) !void {
    try output.writeAll("<footer>UTC dates · server-rendered · no JavaScript required</footer></body></html>");
}

fn filters(output: *std.Io.Writer, value: model.Page) !void {
    try output.writeAll(
        "<section class=\"report-controls\" aria-label=\"Report controls\">" ++
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
    try output.writeAll("</select></label><input type=\"hidden\" name=\"start\" value=\"");
    try attribute(output, value.query.start_date);
    try output.writeAll("\"><input type=\"hidden\" name=\"end\" value=\"");
    try attribute(output, value.query.end_date);
    try output.writeAll(
        "\"><button class=\"button-secondary\" type=\"submit\">View site</button></form>" ++
            "<form class=\"range-filter\" method=\"get\" action=\"/admin\" " ++
            "hx-boost=\"true\" hx-sync=\"this:replace\">" ++
            "<input type=\"hidden\" name=\"site\" value=\"",
    );
    try attribute(output, value.query.site);
    try output.writeAll("\"><label><span>Start</span><input type=\"date\" name=\"start\" required value=\"");
    try attribute(output, value.query.start_date);
    try output.writeAll("\"></label><label><span>End</span><input type=\"date\" name=\"end\" required value=\"");
    try attribute(output, value.query.end_date);
    try output.writeAll("\"></label><input type=\"hidden\" name=\"report\" value=\"");
    try attribute(output, value.query.kind.name());
    try output.writeAll("\">");
    if (value.query.subject.len != 0) {
        try output.writeAll("<input type=\"hidden\" name=\"subject\" value=\"");
        try attribute(output, value.query.subject);
        try output.writeAll("\">");
    }
    if (value.query.kind == .campaigns) {
        try output.writeAll("<input type=\"hidden\" name=\"campaign\" value=\"");
        try attribute(output, @tagName(value.query.campaign_dimension));
        try output.writeAll("\">");
    }
    if (value.query.kind.isList()) {
        try output.writeAll("<input type=\"hidden\" name=\"sort\" value=\"");
        try attribute(output, @tagName(value.query.sort));
        try output.writeAll("\"><input type=\"hidden\" name=\"limit\" value=\"");
        try output.print("{d}", .{value.query.limit});
        try output.writeAll("\">");
    }
    try output.writeAll("<button type=\"submit\">Update dates</button></form></section>");
}

const NavItem = struct {
    kind: report.Kind,
    label: []const u8,
};

const navigation = [_]NavItem{
    .{ .kind = .overview, .label = "Overview" },
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

fn reportNavigation(output: *std.Io.Writer, value: model.Page) !void {
    try output.writeAll("<div class=\"report-navigation\"><nav class=\"report-tabs\" aria-label=\"Reports\">");
    for (navigation) |item| {
        try reportLink(output, value.query, item.kind, "", item.label);
    }
    try output.writeAll("</nav>");
    if (value.goals.len != 0 or value.funnels.len != 0) {
        try output.writeAll("<div class=\"conversion-navigation\"><span class=\"eyebrow\">Conversions</span><nav aria-label=\"Conversions\">");
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
        .overview => |overview| {
            try output.writeAll("<ul class=\"metrics\">");
            try metric(output, "Page views", overview.page_views);
            try metric(output, "Daily visitors", overview.visitor_days);
            try metric(output, "Sessions", overview.sessions);
            try metric(output, "Custom events", overview.custom_events);
            try metric(output, "Bot events", overview.bot_events);
            try output.writeAll("</ul>");
        },
        .list => |list| {
            if (query.kind == .campaigns) try campaignTabs(output, query);
            try output.writeAll("<div class=\"table-scroll\"><table><thead><tr><th>");
            try text(output, humanize(list.label_name));
            try output.writeAll("</th><th>");
            try text(output, humanize(list.primary_name));
            try output.writeAll("</th><th>");
            try text(output, humanize(list.secondary_name));
            try output.writeAll("</th></tr></thead><tbody>");
            for (list.rows) |row| {
                try output.writeAll("<tr><td>");
                try text(output, row.label);
                try output.print("</td><td>{d}</td><td>{d}</td></tr>", .{
                    row.primary,
                    row.secondary,
                });
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
            try output.writeAll("<li><span>Conversion rate</span><strong>");
            try percent(output, goal.matching_sessions, goal.eligible_sessions);
            try output.writeAll("</strong></li></ul>");
        },
        .funnel => |funnel| {
            try output.writeAll("<div class=\"table-scroll\"><table><thead><tr><th>Step</th><th>Sessions</th><th>Step rate</th><th>Overall</th></tr></thead><tbody>");
            for (funnel.steps, 0..) |step, index| {
                const prior = if (index == 0)
                    funnel.eligible_sessions
                else
                    funnel.steps[index - 1].sessions;
                try output.writeAll("<tr><td>");
                try text(output, step.name);
                try output.print("</td><td>{d}</td><td>", .{step.sessions});
                try percent(output, step.sessions, prior);
                try output.writeAll("</td><td>");
                try percent(output, step.sessions, funnel.eligible_sessions);
                try output.writeAll("</td></tr>");
            }
            try output.writeAll("</tbody></table></div>");
        },
    }
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
    try output.writeAll("<label>Name<input name=\"name\" maxlength=\"120\" required value=\"");
    try attribute(output, value.goal_draft.name);
    try output.writeAll("\"></label><label>Match<select name=\"kind\">");
    inline for (.{ "event", "path", "prefix" }) |kind| {
        try output.writeAll("<option");
        if (std.mem.eql(u8, value.goal_draft.match_kind, kind)) {
            try output.writeAll(" selected");
        }
        try output.writeAll(">");
        try text(output, kind);
        try output.writeAll("</option>");
    }
    try output.writeAll("</select></label><label>Value<input name=\"value\" maxlength=\"1024\" required value=\"");
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
    try output.writeAll("<label>Name<input name=\"name\" maxlength=\"120\" required value=\"");
    try attribute(output, value.funnel_draft.name);
    try output.writeAll("\"></label><label>Steps, one <code>kind=value</code> per line<textarea name=\"steps\" maxlength=\"8192\" required>");
    try text(output, value.funnel_draft.steps);
    try output.writeAll("</textarea></label><button type=\"submit\">Add funnel</button></form></section></div></details>");
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
    try output.writeAll("\"><input type=\"hidden\" name=\"start\" value=\"");
    try attribute(output, value.query.start_date);
    try output.writeAll("\"><input type=\"hidden\" name=\"end\" value=\"");
    try attribute(output, value.query.end_date);
    try output.writeAll("\">");
}

fn metric(output: *std.Io.Writer, name: []const u8, count: i64) !void {
    try output.writeAll("<li><span>");
    try text(output, name);
    try output.print("</span><strong>{d}</strong></li>", .{count});
}

fn queryUrl(
    output: *std.Io.Writer,
    query: model.Query,
    kind: report.Kind,
    subject: []const u8,
    page_number: u32,
) !void {
    try output.writeAll("/admin?site=");
    try urlComponent(output, query.site);
    try output.writeAll("&amp;start=");
    try urlComponent(output, query.start_date);
    try output.writeAll("&amp;end=");
    try urlComponent(output, query.end_date);
    try output.writeAll("&amp;report=");
    try urlComponent(output, kind.name());
    if (subject.len != 0) {
        try output.writeAll("&amp;subject=");
        try urlComponent(output, subject);
    }
    if (kind == .campaigns) {
        try output.writeAll("&amp;campaign=");
        try urlComponent(output, @tagName(query.campaign_dimension));
    }
    if (kind.isList()) {
        try output.writeAll("&amp;sort=");
        try urlComponent(output, @tagName(query.sort));
        try output.print("&amp;limit={d}&amp;page={d}", .{ query.limit, page_number });
    }
}

fn text(output: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '&' => try output.writeAll("&amp;"),
        '<' => try output.writeAll("&lt;"),
        '>' => try output.writeAll("&gt;"),
        '"' => try output.writeAll("&quot;"),
        '\'' => try output.writeAll("&#39;"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => try output.writeAll("&#xfffd;"),
        else => try output.writeByte(byte),
    };
}

fn attribute(output: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '\t' => try output.writeAll("&#9;"),
        '\n' => try output.writeAll("&#10;"),
        '\r' => try output.writeAll("&#13;"),
        else => try text(output, &.{byte}),
    };
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

fn percent(output: *std.Io.Writer, numerator: i64, denominator: i64) !void {
    const hundredths: i64 = if (numerator <= 0 or denominator <= 0)
        0
    else
        @intCast(@divTrunc(@as(i128, numerator) * 10_000, denominator));
    try output.print("{d}.{d:0>2}%", .{
        @divTrunc(hundredths, 100),
        @mod(hundredths, 100),
    });
}

fn humanize(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "page_views")) return "Page views";
    if (std.mem.eql(u8, value, "visitor_days")) return "Daily visitors";
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
        .goal => "Conversion goal",
        .funnel => "Funnel",
    };
}
