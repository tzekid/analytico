const std = @import("std");
const analysis = @import("../analysis.zig");
const diagnostics = @import("../diagnostics.zig");
const report = @import("../report.zig");
const charts = @import("charts.zig");
const components = @import("components.zig");
const model = @import("model.zig");

pub const stylesheet = @embedFile("style.css");
pub const stylesheet_path = "/admin/app.v10.css";
pub const htmx = @embedFile("htmx_js");
pub const htmx_gzip = @embedFile("htmx_gzip");
pub const htmx_path = "/admin/htmx.28fae7bb.js";
pub const dashboard_js = @embedFile("dashboard.js");
pub const dashboard_js_previous = @embedFile("dashboard.5f88a716.js");
pub const dashboard_js_previous_path = "/admin/dashboard.5f88a716.js";
pub const dashboard_js_path = "/admin/dashboard.9c3ac396.js";
pub const install_js = @embedFile("install.js");
pub const install_js_path = "/admin/install.fe0cc47b.js";

const html_headers =
    "Cache-Control: private, no-store, max-age=0\r\n" ++
    "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; " ++
    "connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'\r\n" ++
    "X-Content-Type-Options: nosniff\r\n" ++
    "Referrer-Policy: same-origin\r\n";

pub const headers = html_headers;
pub const install_headers =
    "Cache-Control: private, no-store, max-age=0\r\n" ++
    "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; " ++
    "connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'\r\n" ++
    "X-Content-Type-Options: nosniff\r\n" ++
    "Referrer-Policy: no-referrer\r\n";

pub fn page(output: *std.Io.Writer, value: model.Page) !void {
    try head(output, value.destination.label());
    if (value.selected_site == null) {
        try output.writeAll(
            "<header class=\"first-run-header\"><a class=\"brand\" href=\"/admin\">Analytico</a></header>" ++
                "<main id=\"main\" class=\"first-run-main\"><section class=\"panel\"><h1>No sites configured</h1>" ++
                "<p>Create the first site in the authenticated browser; no service restart is required.</p>" ++
                "<a class=\"button\" href=\"/admin/sites/new\">Create site</a></section></main>",
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
            if (value.analyze_trend != null) {
                try analyzeTrendSection(output, value);
            } else {
                try reportNavigation(output, value);
                try reportSection(output, value);
            }
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

pub fn firstRunPage(output: *std.Io.Writer, value: model.FirstRunPage) !void {
    try onboardingHead(output, "Create your first site");
    try onboardingHeader(output);
    try output.writeAll(
        "<main id=\"main\" tabindex=\"-1\" class=\"first-run-main onboarding-main\">" ++
            "<section class=\"panel onboarding-hero\"><span class=\"eyebrow\">First run</span>" ++
            "<h1>Turn visits into useful answers</h1>" ++
            "<p>Create the first site in this browser. Analytico will store its exact " ++
            "origin and reporting timezone, then activate collection without a restart.</p>" ++
            "<a class=\"button\" href=\"/admin/sites/new\">Create site</a>" ++
            "<p class=\"field-help\">If setup is blocked, run <code>analytico doctor DATA</code> " ++
            "and consult the <a href=\"https://github.com/tzekid/analytico/blob/master/docs/OPERATIONS.md\">operator documentation</a>.</p></section>" ++
            "<section class=\"panel\"><h2>Setup health</h2><dl class=\"setup-health\">" ++
            "<div><dt>Metadata</dt><dd>",
    );
    if (value.runtime_ready) {
        try output.writeAll("Ready · schema ");
    } else {
        try output.writeAll("Check readiness · expected schema ");
    }
    try output.print("{d}", .{value.metadata_schema});
    try output.writeAll("</dd></div><div><dt>Events</dt><dd>");
    if (value.runtime_ready) {
        try output.writeAll("Ready · schema ");
    } else {
        try output.writeAll("Check readiness · expected schema ");
    }
    try output.print("{d}", .{value.event_schema});
    try output.writeAll("</dd></div><div><dt>Collector</dt><dd>");
    if (value.runtime_ready) {
        try output.writeAll("Ready for a site policy");
    } else {
        try output.writeAll("Collection unavailable · run doctor and check /readyz");
    }
    try output.writeAll("</dd></div></dl></section></main>");
    try foot(output);
}

pub fn siteFormPage(output: *std.Io.Writer, value: model.SiteFormPage) !void {
    try onboardingHead(output, "Create site");
    try onboardingHeader(output);
    try output.writeAll(
        "<main id=\"main\" tabindex=\"-1\" class=\"first-run-main onboarding-main\">" ++
            "<div class=\"page-heading\"><span class=\"eyebrow\">Site setup</span>" ++
            "<h1>Create site</h1><p>Use explicit reporting and collection settings. " ++
            "You can change additional settings later.</p></div>",
    );
    if (value.errors.any()) {
        try components.feedback(output, .{
            .kind = .error_message,
            .message = "Check the marked fields. No site was created.",
            .id = "site-form-errors",
            .focus = true,
        });
    }
    try output.writeAll(
        "<form class=\"panel site-form\" method=\"post\" action=\"/admin/sites\">" ++
            "<input type=\"hidden\" name=\"csrf\" value=\"",
    );
    try attribute(output, value.csrf_token);
    try output.writeAll("\"><label for=\"site-name\">Display name</label><input id=\"site-name\" name=\"name\" maxlength=\"120\" required autocomplete=\"organization\"");
    try siteFieldAttributes(output, value.errors.name, "site-name-error");
    try output.writeAll(" value=\"");
    try attribute(output, value.draft.name);
    try output.writeAll("\">");
    try siteFieldError(output, value.errors.name, "site-name-error");
    try output.writeAll(
        "<label for=\"site-slug\">Slug</label>" ++
            "<p class=\"field-help\" id=\"site-slug-help\">Leave blank to derive it from the name.</p>" ++
            "<input id=\"site-slug\" name=\"slug\" maxlength=\"48\" " ++
            "aria-describedby=\"site-slug-help",
    );
    if (value.errors.slug.len != 0) try output.writeAll(" site-slug-error");
    try output.writeAll("\" value=\"");
    try attribute(output, value.draft.slug);
    try output.writeAll("\"");
    if (value.errors.slug.len != 0) try output.writeAll(" aria-invalid=\"true\"");
    try output.writeAll(">");
    try siteFieldError(output, value.errors.slug, "site-slug-error");
    try output.writeAll(
        "<label for=\"site-origin\">Primary origin</label>" ++
            "<p class=\"field-help\" id=\"site-origin-help\">Exact HTTPS origin; loopback HTTP is allowed for development.</p>" ++
            "<input id=\"site-origin\" name=\"origin\" type=\"url\" maxlength=\"512\" required " ++
            "placeholder=\"https://example.com\" aria-describedby=\"site-origin-help",
    );
    if (value.errors.origin.len != 0) try output.writeAll(" site-origin-error");
    try output.writeAll("\" value=\"");
    try attribute(output, value.draft.origin);
    try output.writeAll("\"");
    if (value.errors.origin.len != 0) try output.writeAll(" aria-invalid=\"true\"");
    try output.writeAll(">");
    try siteFieldError(output, value.errors.origin, "site-origin-error");
    try output.writeAll(
        "<label for=\"site-timezone\">Reporting timezone</label>" ++
            "<p class=\"field-help\" id=\"site-timezone-help\">Choose explicitly; the server never guesses. Example: Europe/Berlin.</p>" ++
            "<input id=\"site-timezone\" name=\"timezone\" maxlength=\"255\" required " ++
            "autocomplete=\"off\" placeholder=\"Europe/Berlin\" aria-describedby=\"site-timezone-help",
    );
    if (value.errors.timezone.len != 0) try output.writeAll(" site-timezone-error");
    try output.writeAll("\" value=\"");
    try attribute(output, value.draft.timezone);
    try output.writeAll("\"");
    if (value.errors.timezone.len != 0) try output.writeAll(" aria-invalid=\"true\"");
    try output.writeAll(">");
    try siteFieldError(output, value.errors.timezone, "site-timezone-error");
    try output.writeAll(
        "<label for=\"site-currency\">Default currency <span class=\"muted\">(optional)</span></label>" ++
            "<p class=\"field-help\" id=\"site-currency-help\">Three uppercase letters such as EUR. Currencies are never converted or combined.</p>" ++
            "<input id=\"site-currency\" name=\"currency\" maxlength=\"3\" pattern=\"[A-Z]{3}\" " ++
            "placeholder=\"EUR\" aria-describedby=\"site-currency-help",
    );
    if (value.errors.currency.len != 0) try output.writeAll(" site-currency-error");
    try output.writeAll("\" value=\"");
    try attribute(output, value.draft.currency);
    try output.writeAll("\"");
    if (value.errors.currency.len != 0) try output.writeAll(" aria-invalid=\"true\"");
    try output.writeAll(">");
    try siteFieldError(output, value.errors.currency, "site-currency-error");
    try output.writeAll(
        "<div class=\"form-actions\"><button type=\"submit\">Create site</button>" ++
            "<a class=\"button button-secondary\" href=\"/admin\">Cancel</a>" ++
            "</div></form></main>",
    );
    try foot(output);
}

pub fn installPage(output: *std.Io.Writer, value: model.InstallPage) !void {
    try documentHead(output, "Install tracker", .install);
    try onboardingHeader(output);
    try output.writeAll(
        "<main id=\"main\" tabindex=\"-1\" class=\"first-run-main onboarding-main\">" ++
            "<div class=\"page-heading\"><span class=\"eyebrow\">Site ready</span><h1>Install tracker</h1>",
    );
    if (value.policy_active) {
        try output.writeAll(
            "<p>The site is stored and its collection policy is active without a restart.</p>",
        );
    } else {
        try output.writeAll(
            "<p role=\"status\">The site is stored, but its collection policy is not active " ++
                "in this running process. Restart the service or submit the same site form after recovery.</p>",
        );
    }
    if (!value.verification.collection_available) {
        try output.writeAll(
            "<p role=\"alert\"><strong>Collection unavailable:</strong> collector storage is not " ++
                "ready in this running process. Restore the configured paths and confirm readiness " ++
                "before installing the tracker.</p>",
        );
    }
    try output.writeAll("</div><section class=\"panel\"><h2>");
    try text(output, value.site.name);
    try output.writeAll("</h2><dl class=\"configuration-list\"><div><dt>Site ID</dt><dd><code>");
    try text(output, value.site.id);
    try output.writeAll("</code></dd></div><div><dt>Slug</dt><dd><code>");
    try text(output, value.site.slug);
    try output.writeAll("</code></dd></div><div><dt>Timezone</dt><dd>");
    try text(output, value.site.timezone_name);
    try output.writeAll("</dd></div><div><dt>Default currency</dt><dd>");
    if (value.site.default_currency.len == 0) {
        try output.writeAll("Not set");
    } else {
        try text(output, value.site.default_currency);
    }
    try output.writeAll("</dd></div></dl><h3>Configured origins</h3><ul>");
    for (value.site.origins) |origin| {
        try output.writeAll("<li><code>");
        try text(output, origin);
        try output.writeAll("</code></li>");
    }
    try output.writeAll(
        "</ul></section><section class=\"panel\" aria-labelledby=\"tracker-setup-heading\">" ++
            "<h2 id=\"tracker-setup-heading\">Tracker setup</h2>" ++
            "<dl class=\"configuration-list\"><div><dt>Collector origin</dt><dd><code>",
    );
    try text(output, value.collector_origin);
    try output.print(
        "</code></dd></div><div><dt>Tracker protocol</dt><dd>v{d}</dd></div>" ++
            "<div><dt>Immutable asset</dt><dd><code>",
        .{value.tracker_protocol_version},
    );
    try text(output, value.tracker_path);
    try output.writeAll(
        "</code></dd></div></dl><label for=\"tracker-snippet\">Canonical snippet</label>" ++
            "<textarea id=\"tracker-snippet\" rows=\"9\" readonly spellcheck=\"false\">",
    );
    try text(output, value.snippet);
    try output.writeAll(
        "</textarea><div class=\"form-actions\"><button type=\"button\" " ++
            "data-copy-target=\"tracker-snippet\" data-copy-status=\"tracker-copy-status\">" ++
            "Copy snippet</button></div><p id=\"tracker-copy-status\" class=\"muted\" " ++
            "role=\"status\" aria-live=\"polite\">Select the snippet manually if clipboard access is unavailable.</p>" ++
            "<details><summary>Optional automatic events</summary><p>Add only the attributes you need: " ++
            "<code>data-outbound=\"true\"</code>, <code>data-downloads=\"true\"</code>, " ++
            "<code>data-forms=\"true\"</code>, or <code>data-not-found=\"true\"</code>. " ++
            "No configuration request runs at page startup.</p></details>" ++
            "<h3>Manual API</h3><label for=\"manual-track-example\">Track an event</label>" ++
            "<textarea id=\"manual-track-example\" rows=\"2\" readonly spellcheck=\"false\">window.analytico?.track(&quot;signup&quot;, { plan: &quot;basic&quot; });</textarea>" ++
            "<label for=\"manual-identify-example\">Identify a user</label>" ++
            "<textarea id=\"manual-identify-example\" rows=\"2\" readonly spellcheck=\"false\">window.analytico?.identify(&quot;user_123&quot;, { plan: &quot;basic&quot; });</textarea>" ++
            "<p class=\"muted\">Call <code>window.analytico?.reset();</code> on logout or user switch.</p>" ++
            "</section>",
    );
    try installVerificationFragment(output, value.verification);
    try output.writeAll("</main>");
    try foot(output);
}

pub fn installVerificationFragment(
    output: *std.Io.Writer,
    value: model.InstallVerification,
) !void {
    const state = if (value.event != null)
        "success"
    else if (!value.collection_available)
        "unavailable"
    else
        "waiting";
    try output.writeAll(
        "<section id=\"installation-verification\" class=\"panel\" " ++
            "aria-labelledby=\"installation-verification-heading\" " ++
            "data-install-verification data-state=\"",
    );
    try attribute(output, state);
    try output.writeAll("\" data-fragment-url=\"");
    try installVerificationUrl(output, value, true);
    try output.writeAll(
        "\"><h2 id=\"installation-verification-heading\">Verify collection</h2>",
    );
    if (value.event) |event| {
        try output.writeAll(
            "<p class=\"notice\" role=\"status\"><strong>Tracker verified.</strong> " ++
                "A new event was committed after this verification started.</p>",
        );
        if (event.protocol_version == 1) {
            try output.writeAll(
                "<p class=\"warning\" role=\"status\"><strong>Protocol v1 compatibility:</strong> " ++
                    "collection works, but replace the old tracker with the generated v2 snippet above.</p>",
            );
        }
        try output.print(
            "<dl class=\"configuration-list\"><div><dt>Protocol</dt><dd>v{d}</dd></div>" ++
                "<div><dt>Type</dt><dd>",
            .{event.protocol_version},
        );
        try text(output, event.event_type);
        try output.writeAll("</dd></div><div><dt>Event</dt><dd><code>");
        try text(output, event.event_name);
        try output.writeAll("</code></dd></div><div><dt>Path</dt><dd><code>");
        try text(output, event.path);
        try output.writeAll("</code></dd></div><div><dt>Received</dt><dd>");
        try text(output, event.received_at_utc);
        try output.writeAll("</dd></div></dl><div class=\"form-actions\"><a class=\"button\" href=\"/admin/sites/");
        try attribute(output, value.site_slug);
        try output.writeAll("/overview\">Open Overview</a><a class=\"button button-secondary\" href=\"/admin/sites/");
        try attribute(output, value.site_slug);
        try output.writeAll("/live\">View Live diagnostics</a></div>");
    } else {
        if (value.collection_available) {
            try output.writeAll(
                "<p role=\"status\">Waiting for a new committed event. Open the tracked site after installing the snippet, then check again.</p>",
            );
        } else {
            try output.writeAll(
                "<p class=\"error\" role=\"alert\"><strong>Verification unavailable:</strong> " ++
                    "collector storage is not ready. Restore readiness, reload the bare Install page to start a new verification, then send a fresh event.</p>",
            );
        }
        if (value.guidance) |guidance| {
            try output.writeAll(
                "<div class=\"warning\" role=\"status\"><strong>Recent attempt since process restart: ",
            );
            try text(output, guidance.category);
            try output.writeAll(".</strong> ");
            try text(output, guidance.consequence);
            try output.writeByte(' ');
            try text(output, guidance.correction);
            try output.writeAll("</div>");
        }
        try output.writeAll(
            "<details><summary>Common rejection corrections</summary><ul>" ++
                "<li><strong>Origin:</strong> match one configured scheme, host, and port exactly.</li>" ++
                "<li><strong>Payload:</strong> use the generated tracker or bounded v2 examples; remove unknown, nested, or oversized fields.</li>" ++
                "<li><strong>Identity/session:</strong> use generated UUID/session state and reset before switching users.</li>" ++
                "<li><strong>Storage or rate limit:</strong> restore readiness or wait before sending a fresh event.</li>" ++
                "</ul><p class=\"muted\">Malformed or oversized attempts without a validated Site ID cannot be attributed to this site.</p></details>" ++
                "<form method=\"get\" action=\"/admin/sites/",
        );
        try attribute(output, value.site_slug);
        try output.writeAll("/install\"><input type=\"hidden\" name=\"started\" value=\"");
        try output.print("{d}", .{value.watermark.started_at_utc_micros});
        try output.writeAll("\"><input type=\"hidden\" name=\"count\" value=\"");
        try output.print("{d}", .{value.watermark.event_count});
        try output.writeAll("\"><input type=\"hidden\" name=\"after\" value=\"");
        try output.print("{d}", .{value.watermark.after_received_at_utc_micros});
        try output.writeAll("\"><input type=\"hidden\" name=\"event\" value=\"");
        try attribute(output, value.watermark.after_event_id);
        try output.writeAll("\"><input type=\"hidden\" name=\"sig\" value=\"");
        try attribute(output, value.watermark.signature);
        try output.writeAll(
            "\"><div class=\"form-actions\"><button type=\"submit\">Check again</button>" ++
                "<button type=\"button\" class=\"button-secondary\" hidden " ++
                "data-verification-pause aria-pressed=\"false\">Pause automatic checks</button>" ++
                "</div></form><p class=\"muted\" role=\"status\" aria-live=\"polite\" " ++
                "data-verification-client-status></p>",
        );
    }
    try output.writeAll("</section>");
}

fn installVerificationUrl(
    output: *std.Io.Writer,
    value: model.InstallVerification,
    fragment: bool,
) !void {
    try output.writeAll("/admin/sites/");
    try attribute(output, value.site_slug);
    try output.print(
        "/install?started={d}&amp;count={d}&amp;after={d}&amp;event=",
        .{
            value.watermark.started_at_utc_micros,
            value.watermark.event_count,
            value.watermark.after_received_at_utc_micros,
        },
    );
    try attribute(output, value.watermark.after_event_id);
    try output.writeAll("&amp;sig=");
    try attribute(output, value.watermark.signature);
    if (fragment) try output.writeAll("&amp;fragment=verification");
}

fn onboardingHeader(output: *std.Io.Writer) !void {
    try output.writeAll("<header class=\"first-run-header onboarding-header\"><a class=\"brand\" href=\"/admin\">Analytico <b>1.0</b></a></header>");
}

fn siteFieldAttributes(
    output: *std.Io.Writer,
    message: []const u8,
    error_id: []const u8,
) !void {
    if (message.len == 0) return;
    try output.writeAll(" aria-invalid=\"true\" aria-describedby=\"");
    try attribute(output, error_id);
    try output.writeByte('"');
}

fn siteFieldError(
    output: *std.Io.Writer,
    message: []const u8,
    error_id: []const u8,
) !void {
    if (message.len == 0) return;
    try output.writeAll("<p class=\"field-error\" id=\"");
    try attribute(output, error_id);
    try output.writeAll("\">");
    try text(output, message);
    try output.writeAll("</p>");
}

fn head(output: *std.Io.Writer, title: []const u8) !void {
    try documentHead(output, title, .dashboard);
}

fn onboardingHead(output: *std.Io.Writer, title: []const u8) !void {
    try documentHead(output, title, .none);
}

const ScriptSet = enum { none, dashboard, install };

fn documentHead(
    output: *std.Io.Writer,
    title: []const u8,
    scripts: ScriptSet,
) !void {
    try output.writeAll("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>");
    try text(output, title);
    try output.writeAll(" · Analytico</title><link rel=\"stylesheet\" href=\"");
    try attribute(output, stylesheet_path);
    switch (scripts) {
        .dashboard => {
            try output.writeAll("\"><script defer src=\"");
            try attribute(output, htmx_path);
            try output.writeAll("\"></script><script defer src=\"");
            try attribute(output, dashboard_js_path);
            try output.writeAll("\"></script></head><body hx-boost:inherited=\"true\" hx-indicator:inherited=\"#loading-region\">");
        },
        .install => {
            try output.writeAll("\"><script defer src=\"");
            try attribute(output, install_js_path);
            try output.writeAll("\"></script></head><body>");
        },
        .none => try output.writeAll("\"></head><body>"),
    }
    try output.writeAll("<a class=\"skip-link\" href=\"#main\">Skip to main content</a>");
    if (scripts == .dashboard) {
        try output.writeAll("<p id=\"loading-region\" class=\"loading-region htmx-indicator\" role=\"status\" aria-live=\"polite\" aria-atomic=\"true\">Updating view…</p>");
    }
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
        var destination_query = value.query;
        var default_analysis_series = [_]analysis.Metric{.{ .kind = .visitors }};
        if (destination == .analyze and destination_query.analysis_series.len == 0) {
            destination_query.kind = .overview;
            destination_query.analysis_interval = .auto;
            destination_query.analysis_series = &default_analysis_series;
            destination_query.highlighted_interval = "";
        }
        try output.writeAll("<a href=\"");
        try canonicalUrl(output, destination, destination_query, 1);
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
        "<button class=\"button-secondary\" type=\"submit\">View site</button>" ++
            "<a class=\"button button-secondary\" href=\"/admin/sites/new\">Create site</a></form>" ++
            "<details class=\"date-presets\"><summary>",
    );
    try text(output, context.selected_preset.label());
    try output.writeAll("</summary><nav class=\"preset-list\" aria-label=\"Date presets\">");
    for (context.presets) |option| {
        if (option.preset == .custom or option.range == null) continue;
        var adjusted = value.query;
        adjusted.range = option.range.?.view();
        adjusted.highlighted_interval = "";
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
    if (value.destination == .analyze and value.query.analysis_series.len != 0) {
        try output.writeAll("<input type=\"hidden\" name=\"interval\" value=\"");
        try attribute(output, value.query.analysis_interval.name());
        try output.writeAll("\">");
        for (value.query.analysis_series, 0..) |series_metric, index| {
            try output.print(
                "<input type=\"hidden\" name=\"metric-{d}\" value=\"",
                .{index + 1},
            );
            try attribute(output, series_metric.kind.name());
            try output.writeAll("\">");
            if (series_metric.selector) |selector| switch (selector.kind) {
                .exact_event => {
                    try output.print(
                        "<input type=\"hidden\" name=\"event-{d}\" value=\"",
                        .{index + 1},
                    );
                    try attribute(output, selector.value);
                    try output.writeAll("\">");
                },
                .saved_goal => {
                    try output.print(
                        "<input type=\"hidden\" name=\"goal-{d}\" value=\"",
                        .{index + 1},
                    );
                    try attribute(output, selector.value);
                    try output.writeAll("\">");
                },
                else => return error.InvalidTrendSubject,
            };
        }
    } else if (value.destination == .analyze) {
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
    if ((value.destination == .analyze and value.query.analysis_series.len == 0) or
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
        .analyze => "Compare bounded metrics, events, and goals over time.",
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
    if (value.query.highlighted_interval.len != 0) {
        try output.writeAll(
            "<aside class=\"analysis-focus\" aria-label=\"Overview trend focus\"><strong>",
        );
        try text(output, overviewMetricLabel(value.query.overview_metric));
        if (value.query.overview_metric == .revenue) {
            try output.writeAll(" (");
            try text(output, value.query.overview_currency);
            try output.writeByte(')');
        }
        try output.writeAll(" focus:</strong> ");
        try text(output, value.query.highlighted_interval);
        try output.writeAll(
            ". The current report keeps the complete selected range; this highlight is not a hidden filter.</aside>",
        );
    }
    if (value.result) |result| {
        try renderResult(output, value.query, result);
    } else {
        try output.writeAll("<p class=\"muted\">Create a definition below to run this report.</p>");
    }
    try output.writeAll("</section>");
}

fn analyzeTrendSection(output: *std.Io.Writer, value: model.Page) !void {
    const trend = value.analyze_trend orelse return error.MissingAnalyzeTrend;
    try output.writeAll(
        "<section id=\"report\" aria-labelledby=\"analyze-trend-heading\">" ++
            "<div class=\"analysis-heading\"><div><h2 id=\"analyze-trend-heading\">Trend</h2>" ++
            "<p class=\"muted\">One to three typed metric queries share this request's deadline. Exact currencies remain separate.</p></div>" ++
            "<a class=\"button button-secondary\" href=\"",
    );
    var legacy = value.query;
    legacy.analysis_series = &.{};
    legacy.analysis_interval = .auto;
    legacy.highlighted_interval = "";
    legacy.kind = .pages;
    legacy.sort = .count;
    legacy.limit = report.default_limit;
    legacy.page = 1;
    try canonicalUrl(output, .analyze, legacy, 1);
    try output.writeAll("\">Open Breakdown presets</a></div>");

    try output.writeAll("<form class=\"panel analysis-builder\" method=\"get\" action=\"");
    try canonicalPath(output, .analyze, value.query);
    try output.writeAll("\">");
    try calendarHiddenFields(output, value.query);
    try output.writeAll("<label class=\"analysis-interval\">Interval<select name=\"interval\">");
    inline for (std.meta.tags(analysis.Interval)) |interval| {
        try output.writeAll("<option value=\"");
        try attribute(output, interval.name());
        try output.writeByte('"');
        if (interval == value.query.analysis_interval) try output.writeAll(" selected");
        try output.writeByte('>');
        try text(output, intervalLabel(interval));
        try output.writeAll("</option>");
    }
    try output.writeAll("</select></label><p class=\"field-help analysis-builder-help\">Event metrics require one exact event. Conversion metrics require one saved goal. Revenue and average value may use either subject or all value events.</p><div class=\"analysis-series-builder\">");
    for (0..analysis.maximum_series) |index| {
        const configured_metric: ?analysis.Metric = if (index < value.query.analysis_series.len)
            value.query.analysis_series[index]
        else
            null;
        try output.print("<fieldset><legend>Series {d}</legend><label>Metric<select name=\"metric-{d}\"><option value=\"\">None</option>", .{ index + 1, index + 1 });
        inline for (std.meta.tags(analysis.MetricKind)) |kind| {
            try output.writeAll("<option value=\"");
            try attribute(output, kind.name());
            try output.writeByte('"');
            if (configured_metric != null and configured_metric.?.kind == kind) {
                try output.writeAll(" selected");
            }
            try output.writeByte('>');
            try text(output, analysisMetricLabel(kind));
            try output.writeAll("</option>");
        }
        try output.print("</select></label><label>Exact event <span class=\"muted\">(when applicable)</span><input name=\"event-{d}\" maxlength=\"64\" autocomplete=\"off\" value=\"", .{index + 1});
        if (configured_metric) |selected_metric| if (selected_metric.selector) |selector| {
            if (selector.kind == .exact_event) try attribute(output, selector.value);
        };
        try output.print("\"></label><label>Saved goal <span class=\"muted\">(when applicable)</span><select name=\"goal-{d}\"><option value=\"\">None</option>", .{index + 1});
        if (value.goals.len == 0) {
            try output.writeAll("<option disabled>No saved goals available</option>");
        }
        for (value.goals) |goal| {
            try output.writeAll("<option value=\"");
            try attribute(output, goal.id);
            try output.writeByte('"');
            if (configured_metric) |selected_metric| if (selected_metric.selector) |selector| {
                if (selector.kind == .saved_goal and
                    std.mem.eql(u8, selector.value, goal.id))
                {
                    try output.writeAll(" selected");
                }
            };
            try output.writeByte('>');
            try text(output, goal.name);
            try output.writeAll("</option>");
        }
        try output.writeAll("</select></label></fieldset>");
    }
    try output.writeAll("</div><button type=\"submit\">Run Trend</button></form>");

    if (trend.no_events_ever) {
        const install_url = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "/admin/sites/{s}/install",
            .{value.query.site},
        );
        defer std.heap.page_allocator.free(install_url);
        try components.emptyState(output, .{
            .id = "analyze-no-events",
            .title = "No events received yet",
            .message = "Install the tracker and accept an event before comparing Trend series.",
            .action_url = install_url,
            .action_label = "Open installation",
        });
    } else if (trend.no_matches) {
        try components.emptyState(output, .{
            .id = "analyze-no-matches",
            .title = "No matching data",
            .message = "The site has events, but none match the selected metric subjects in this range.",
        });
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (trend.series, 0..) |series, series_index| {
        try output.writeAll("<section class=\"analysis-series\"><div class=\"analysis-series-summary\"><h3>");
        try text(output, series.title);
        try output.writeAll("</h3><p>");
        try writeAnalyzeTotal(output, allocator, "Current total", series.current_total, series.metric.kind);
        if (value.query.comparison != .none) {
            try output.writeAll(" · ");
            try writeAnalyzeTotal(
                output,
                allocator,
                "Comparison total",
                series.comparison_total,
                series.metric.kind,
            );
        }
        try output.writeAll("</p><p class=\"coverage-note\">");
        try text(output, series.current_coverage);
        try output.writeAll("</p>");
        if (series.comparison_coverage) |coverage| {
            try output.writeAll("<p class=\"coverage-note\">");
            try text(output, coverage);
            try output.writeAll("</p>");
        }
        try output.writeAll("</div>");
        const points = try allocator.alloc(charts.TrendPoint, series.points.len);
        for (points, series.points) |*point, source| {
            const current = if (source.current) |measure|
                try analyzeChartMeasure(allocator, measure, series.metric.kind)
            else
                AnalyzeChartMeasure{};
            const comparison = if (source.comparison) |measure|
                try analyzeChartMeasure(allocator, measure, series.metric.kind)
            else
                AnalyzeChartMeasure{};
            point.* = .{
                .label = source.current_label,
                .comparison_interval_label = source.comparison_label,
                .current = current.value,
                .current_incomplete = source.current_incomplete,
                .current_highlighted = source.current_highlighted,
                .current_formatted = current.formatted,
                .current_href = "",
                .comparison = comparison.value,
                .comparison_highlighted = source.comparison_highlighted,
                .comparison_formatted = comparison.formatted,
                .comparison_href = "",
            };
        }
        const id = try std.fmt.allocPrint(allocator, "analyze-trend-{d}", .{series_index + 1});
        try charts.renderTrend(output, .{
            .id = id,
            .title = series.title,
            .summary = "Site-local current and comparison intervals. The shared exact table after the figures preserves every source value and native interval link.",
            .current_label = analyzeValueLabel(series.metric.kind, false),
            .comparison_label = analyzeValueLabel(series.metric.kind, true),
            .show_comparison = value.query.comparison != .none and
                value.calendar_context.?.comparison_range != null,
            .scale = metricScale(series.metric.kind),
            .points = points,
            .render_exact_table = false,
        });
        try output.writeAll("</section>");
    }
    try renderAnalyzeExactTable(output, allocator, value, trend);
    try output.writeAll("</section>");
}

fn renderAnalyzeExactTable(
    output: *std.Io.Writer,
    allocator: std.mem.Allocator,
    page_value: model.Page,
    trend: model.AnalyzeTrend,
) !void {
    if (trend.series.len == 0) return error.MissingAnalyzeTrend;
    const point_count = trend.series[0].points.len;
    for (trend.series[1..]) |series| if (series.points.len != point_count) {
        return error.InvalidAnalyzeTrendMeasure;
    };
    const show_comparison = page_value.query.comparison != .none and
        page_value.calendar_context.?.comparison_range != null;
    try output.writeAll(
        "<details id=\"analyze-trend-data\" class=\"chart-data analysis-exact-data\"><summary>View exact data for all series</summary>" ++
            "<div class=\"table-scroll mobile-records\"><table>" ++
            "<caption>Analyze Trend — exact values and source components</caption>" ++
            "<thead><tr><th scope=\"col\">Current interval</th>",
    );
    for (trend.series) |series| {
        try output.writeAll("<th scope=\"col\">Current · ");
        try text(output, series.title);
        try output.writeAll("</th>");
    }
    if (show_comparison) {
        try output.writeAll("<th scope=\"col\">Comparison interval</th>");
        for (trend.series) |series| {
            try output.writeAll("<th scope=\"col\">Comparison · ");
            try text(output, series.title);
            try output.writeAll("</th>");
        }
    }
    try output.writeAll("</tr></thead><tbody>");
    for (0..point_count) |index| {
        const primary = trend.series[0].points[index];
        try output.writeAll("<tr><th scope=\"row\" data-label=\"Current interval\">");
        try analyzeIntervalCell(
            output,
            allocator,
            page_value.query,
            primary.current_label,
            primary.current_incomplete,
            primary.current_highlighted,
        );
        try output.writeAll("</th>");
        for (trend.series) |series| {
            try output.writeAll("<td data-label=\"Current · ");
            try attribute(output, series.title);
            try output.writeAll("\">");
            try analyzeExactMeasure(
                output,
                allocator,
                series.points[index].current,
                series.metric.kind,
            );
            try output.writeAll("</td>");
        }
        if (show_comparison) {
            try output.writeAll("<td data-label=\"Comparison interval\">");
            try analyzeIntervalCell(
                output,
                allocator,
                page_value.query,
                primary.comparison_label,
                false,
                primary.comparison_highlighted,
            );
            try output.writeAll("</td>");
            for (trend.series) |series| {
                try output.writeAll("<td data-label=\"Comparison · ");
                try attribute(output, series.title);
                try output.writeAll("\">");
                try analyzeExactMeasure(
                    output,
                    allocator,
                    series.points[index].comparison,
                    series.metric.kind,
                );
                try output.writeAll("</td>");
            }
        }
        try output.writeAll("</tr>");
    }
    if (point_count == 0) {
        try output.print(
            "<tr><td colspan=\"{d}\">No data in this range.</td></tr>",
            .{1 + trend.series.len + if (show_comparison) 1 + trend.series.len else 0},
        );
    }
    try output.writeAll("</tbody></table></div></details>");
}

fn analyzeIntervalCell(
    output: *std.Io.Writer,
    allocator: std.mem.Allocator,
    query: model.Query,
    label: []const u8,
    incomplete: bool,
    highlighted: bool,
) !void {
    if (label.len == 0) return output.writeAll("Unavailable");
    const href = try analyzePointHref(allocator, query, label);
    try output.writeAll("<a href=\"");
    try attribute(output, href);
    try output.writeAll("\">");
    try text(output, label);
    try output.writeAll("</a>");
    if (incomplete) {
        try output.writeAll(" <span class=\"trend-incomplete-marker\">Incomplete</span>");
    }
    if (highlighted) {
        try output.writeAll(" <span class=\"trend-highlight-marker\">Highlighted</span>");
    }
}

fn analyzeExactMeasure(
    output: *std.Io.Writer,
    allocator: std.mem.Allocator,
    measure: ?analysis.Measure,
    kind: analysis.MetricKind,
) !void {
    if (measure) |source| {
        const value = try analyzeChartMeasure(allocator, source, kind);
        try charts.writeExactTrendValue(
            output,
            value.value,
            value.formatted,
            metricScale(kind),
        );
    } else {
        try output.writeAll("Unavailable");
    }
}

fn intervalLabel(interval: analysis.Interval) []const u8 {
    return switch (interval) {
        .auto => "Auto",
        .hour => "Hour",
        .day => "Day",
        .week => "Week",
        .month => "Month",
    };
}

fn analysisMetricLabel(kind: analysis.MetricKind) []const u8 {
    return switch (kind) {
        .visitors => "Visitors",
        .new_visitors => "New visitors",
        .returning_visitors => "Returning visitors",
        .sessions => "Sessions",
        .engaged_sessions => "Engaged sessions",
        .engagement_rate => "Engagement rate",
        .bounce_rate => "Bounce rate",
        .page_views => "Page views",
        .custom_events => "Custom events",
        .conversions => "Conversions",
        .conversion_rate => "Conversion rate",
        .revenue => "Revenue",
        .average_value => "Average value",
        .event_count => "Event count",
        .event_visitors => "Event visitors",
    };
}

const AnalyzeChartMeasure = struct {
    value: ?i128 = null,
    formatted: []const u8 = "",
};

fn analyzeChartMeasure(
    allocator: std.mem.Allocator,
    measure: analysis.Measure,
    kind: analysis.MetricKind,
) !AnalyzeChartMeasure {
    return switch (measure) {
        .count => |count| if (metricScale(kind) != 0 or count < 0)
            error.InvalidAnalyzeTrendMeasure
        else
            .{ .value = count },
        .ratio => |ratio| value: {
            if (metricScale(kind) != 2 or ratio.numerator < 0 or
                ratio.denominator < 0 or ratio.numerator > ratio.denominator)
            {
                return error.InvalidAnalyzeTrendMeasure;
            }
            const basis_points: i128 = if (ratio.denominator == 0)
                0
            else
                @divTrunc(
                    @as(i128, ratio.numerator) * 10_000,
                    ratio.denominator,
                );
            const percent_text = if (ratio.denominator == 0)
                "unavailable"
            else
                try std.fmt.allocPrint(
                    allocator,
                    "{d}.{d:0>2}%",
                    .{ @divTrunc(basis_points, 100), @mod(basis_points, 100) },
                );
            const formatted = try std.fmt.allocPrint(
                allocator,
                "{d}/{d} · {s}",
                .{ ratio.numerator, ratio.denominator, percent_text },
            );
            break :value .{
                .value = if (ratio.denominator == 0)
                    null
                else
                    basis_points,
                .formatted = formatted,
            };
        },
        .amount => |amount| value: {
            if (metricScale(kind) != 6 or amount.value_count < 0) {
                return error.InvalidAnalyzeTrendMeasure;
            }
            const sum = try decimalMicros(amount.decimal);
            if (kind == .average_value) break :value .{
                .value = if (amount.value_count == 0)
                    null
                else
                    @divTrunc(sum, amount.value_count),
                .formatted = try std.fmt.allocPrint(
                    allocator,
                    "exact sum {s} {s} / {d} values",
                    .{ amount.currency, amount.decimal, amount.value_count },
                ),
            };
            if (kind != .revenue) return error.InvalidAnalyzeTrendMeasure;
            break :value .{
                .value = sum,
                .formatted = try std.fmt.allocPrint(
                    allocator,
                    "{s} {s}",
                    .{ amount.currency, amount.decimal },
                ),
            };
        },
    };
}

fn analyzeValueLabel(kind: analysis.MetricKind, comparison: bool) []const u8 {
    return switch (kind) {
        .average_value => if (comparison)
            "Comparison computed average"
        else
            "Current computed average",
        .engagement_rate, .bounce_rate, .conversion_rate => if (comparison)
            "Comparison rate"
        else
            "Current rate",
        else => if (comparison) "Comparison range" else "Current range",
    };
}

fn metricScale(kind: analysis.MetricKind) u8 {
    return switch (kind) {
        .engagement_rate, .bounce_rate, .conversion_rate => 2,
        .revenue, .average_value => 6,
        else => 0,
    };
}

fn analyzePointHref(
    allocator: std.mem.Allocator,
    query: model.Query,
    interval: []const u8,
) ![]const u8 {
    var adjusted = query;
    adjusted.highlighted_interval = interval;
    var href = std.Io.Writer.Allocating.init(allocator);
    try canonicalUrlRaw(&href.writer, .analyze, adjusted, 1);
    return href.toOwnedSlice();
}

fn writeAnalyzeTotal(
    output: *std.Io.Writer,
    allocator: std.mem.Allocator,
    label: []const u8,
    measure: ?analysis.Measure,
    kind: analysis.MetricKind,
) !void {
    try output.writeAll("<strong>");
    try text(output, label);
    try output.writeAll(":</strong> ");
    if (measure) |source| {
        const value = try analyzeChartMeasure(allocator, source, kind);
        try charts.writeExactTrendValue(output, value.value, value.formatted, metricScale(kind));
    } else {
        try output.writeAll("Unavailable");
    }
}

fn overviewSection(output: *std.Io.Writer, value: model.Page) !void {
    const overview = value.overview_kpis orelse return error.MissingOverviewKpis;
    const details = value.overview_details orelse return error.MissingOverviewDetails;
    const diagnostics_snapshot = value.collection_diagnostics orelse
        return error.MissingCollectionDiagnostics;
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
            .analyze => target: {
                if (card.analysis_metric) |card_metric| {
                    adjusted.kind = .overview;
                    adjusted.subject = "";
                    adjusted.analysis_interval = .auto;
                    adjusted.analysis_series = &.{card_metric};
                    adjusted.highlighted_interval = "";
                } else if (card.legacy_focus_currency.len != 0) {
                    adjusted.kind = .pages;
                    adjusted.analysis_series = &.{};
                    adjusted.overview_metric = .revenue;
                    adjusted.overview_currency = card.legacy_focus_currency;
                }
                break :target .analyze;
            },
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
    if (details.accepted_events == 0 and
        (diagnostics_snapshot.counts.rejected != 0 or diagnostics_snapshot.counts.store_failures != 0))
    {
        try components.feedback(output, .{
            .kind = .error_message,
            .message = "Tracking attempts are reaching the collector, but no event has been accepted. Open Live to inspect restart-scoped rejection evidence.",
        });
    } else if (details.accepted_events == 0) {
        var live_buffer: [analysis.maximum_url_bytes]u8 = undefined;
        var live_url = std.Io.Writer.fixed(&live_buffer);
        var live_query = value.query;
        live_query.kind = .traffic_quality;
        live_query.highlighted_interval = "";
        try canonicalUrlRaw(&live_url, .live, live_query, 1);
        try components.emptyState(output, .{
            .id = "overview-install-empty",
            .title = "No events received yet",
            .message = "Install the tracker, then open Live to verify the first accepted event.",
            .action_url = live_url.buffered(),
            .action_label = "Open Live",
        });
    } else if (overview.cards.len != 0 and overview.cards[0].value.len != 0 and
        std.mem.eql(u8, overview.cards[0].value, "0"))
    {
        try components.feedback(output, .{
            .kind = .notice,
            .message = "No eligible events are in this range. Data health below shows the latest accepted event.",
        });
    }
    try renderOverviewTrend(output, value, details.trend);
    try renderOverviewPanels(output, value, details);
    try renderOverviewHealth(output, value.query, details, diagnostics_snapshot);
    try output.writeAll("</section>");
}

fn renderOverviewTrend(
    output: *std.Io.Writer,
    value: model.Page,
    trend: model.OverviewTrend,
) !void {
    try output.writeAll(
        "<section class=\"overview-trend\" aria-labelledby=\"overview-trend-heading\">" ++
            "<div class=\"overview-section-heading\"><div><h2 id=\"overview-trend-heading\">Trend</h2>" ++
            "<p class=\"muted\">Current range and its resolved comparison. Every interval also has an exact native Analyze link.</p></div>" ++
            "<form class=\"overview-metric-form\" method=\"get\" action=\"",
    );
    try canonicalPath(output, .overview, value.query);
    try output.writeAll("\"><input type=\"hidden\" name=\"from\" value=\"");
    try attribute(output, value.query.range.start);
    try output.writeAll("\"><input type=\"hidden\" name=\"to\" value=\"");
    try attribute(output, value.query.range.end);
    try output.writeAll("\"><input type=\"hidden\" name=\"compare\" value=\"");
    try attribute(output, value.query.comparison.name());
    try output.writeAll("\"><label>Trend metric<select name=\"metric\">");
    inline for (.{
        analysis.OverviewTrendMetric.visitors,
        analysis.OverviewTrendMetric.sessions,
        analysis.OverviewTrendMetric.page_views,
        analysis.OverviewTrendMetric.conversions,
    }) |kind| {
        try output.writeAll("<option value=\"");
        try attribute(output, kind.name());
        try output.writeByte('"');
        if (trend.metric == kind) try output.writeAll(" selected");
        try output.writeByte('>');
        try text(output, overviewMetricLabel(kind));
        try output.writeAll("</option>");
    }
    for (trend.revenue_options) |currency| {
        try output.writeAll("<option value=\"revenue-");
        try attribute(output, currency);
        try output.writeByte('"');
        if (trend.metric == .revenue and std.mem.eql(u8, trend.currency, currency)) {
            try output.writeAll(" selected");
        }
        try output.writeAll(">Revenue (");
        try text(output, currency);
        try output.writeAll(")</option>");
    }
    try output.writeAll("</select></label><button type=\"submit\">Update trend</button></form></div>");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const points = try allocator.alloc(charts.TrendPoint, trend.points.len);
    var last_current_index: ?usize = null;
    for (trend.points, 0..) |source, index| {
        if (source.current_label != null and source.current != null) {
            last_current_index = index;
        }
    }
    for (points, trend.points, 0..) |*target, source, index| {
        target.* = .{
            .label = source.current_label orelse "",
            .comparison_interval_label = source.comparison_label orelse "",
            .current = if (source.current) |measure| try trendMeasure(measure) else null,
            .current_incomplete = value.overview_kpis.?.includes_incomplete_today and
                last_current_index != null and last_current_index.? == index,
            .current_formatted = if (source.current) |measure|
                try trendFormatted(allocator, measure)
            else
                "",
            .current_href = if (source.current_label) |label|
                try trendPointHref(allocator, value.query, label)
            else
                "",
            .comparison = if (source.comparison) |measure| try trendMeasure(measure) else null,
            .comparison_formatted = if (source.comparison) |measure|
                try trendFormatted(allocator, measure)
            else
                "",
            .comparison_href = if (source.comparison_label) |label|
                try trendPointHref(allocator, value.query, label)
            else
                "",
        };
    }
    var title_buffer: [64]u8 = undefined;
    const title = if (trend.metric == .revenue)
        try std.fmt.bufPrint(&title_buffer, "Revenue ({s}) over time", .{trend.currency})
    else
        try std.fmt.bufPrint(
            &title_buffer,
            "{s} over time",
            .{overviewMetricLabel(trend.metric)},
        );
    try charts.renderTrend(output, .{
        .id = "overview-trend",
        .title = title,
        .summary = "Exact current and comparison intervals for the selected site-local context. Point links preserve the full range and visibly highlight one interval in Analyze.",
        .current_label = "Current range",
        .comparison_label = "Comparison range",
        .show_comparison = value.query.comparison != .none and
            value.calendar_context.?.comparison_range != null,
        .scale = if (trend.metric == .revenue) 6 else 0,
        .points = points,
    });
    try output.writeAll("</section>");
}

fn trendPointHref(
    allocator: std.mem.Allocator,
    query: model.Query,
    interval: []const u8,
) ![]const u8 {
    var adjusted = query;
    const typed_kind: ?analysis.MetricKind = switch (query.overview_metric) {
        .visitors => .visitors,
        .sessions => .sessions,
        .page_views => .page_views,
        .conversions, .revenue => null,
    };
    var typed_series: [1]analysis.Metric = undefined;
    if (typed_kind) |kind| {
        typed_series[0] = .{ .kind = kind };
        adjusted.kind = .overview;
        adjusted.analysis_interval = .auto;
        adjusted.analysis_series = &typed_series;
    } else {
        adjusted.kind = .pages;
        adjusted.sort = .count;
        adjusted.limit = report.default_limit;
        adjusted.page = 1;
        adjusted.analysis_series = &.{};
    }
    adjusted.highlighted_interval = interval;
    var href = std.Io.Writer.Allocating.init(allocator);
    try canonicalUrlRaw(&href.writer, .analyze, adjusted, 1);
    return href.toOwnedSlice();
}

fn trendMeasure(measure: analysis.Measure) !i128 {
    return switch (measure) {
        .count => |count| if (count < 0)
            error.InvalidOverviewDetails
        else
            @as(i128, count),
        .amount => |amount| try decimalMicros(amount.decimal),
        .ratio => error.InvalidOverviewDetails,
    };
}

fn trendFormatted(
    allocator: std.mem.Allocator,
    measure: analysis.Measure,
) ![]const u8 {
    return switch (measure) {
        .count => "",
        .ratio => error.InvalidOverviewDetails,
        .amount => |amount| std.fmt.allocPrint(
            allocator,
            "{s} {s}",
            .{ amount.currency, amount.decimal },
        ),
    };
}

fn decimalMicros(value: []const u8) !i128 {
    if (value.len < 8 or value.len > 32) return error.InvalidOverviewAmount;
    const negative = value[0] == '-';
    const start: usize = if (negative) 1 else 0;
    const dot = std.mem.findScalar(u8, value[start..], '.') orelse
        return error.InvalidOverviewAmount;
    const absolute_dot = start + dot;
    if (value.len - absolute_dot - 1 != 6) return error.InvalidOverviewAmount;
    const whole = std.fmt.parseInt(i128, value[start..absolute_dot], 10) catch
        return error.InvalidOverviewAmount;
    const fraction = std.fmt.parseInt(i128, value[absolute_dot + 1 ..], 10) catch
        return error.InvalidOverviewAmount;
    const magnitude = std.math.add(
        i128,
        std.math.mul(i128, whole, 1_000_000) catch
            return error.InvalidOverviewAmount,
        fraction,
    ) catch return error.InvalidOverviewAmount;
    return if (negative) -magnitude else magnitude;
}

fn renderOverviewPanels(
    output: *std.Io.Writer,
    value: model.Page,
    details: model.OverviewDetails,
) !void {
    try output.writeAll("<section class=\"answer-grid\" aria-label=\"Overview answers\">");
    try output.writeAll("<article class=\"answer-panel\"><div class=\"answer-heading\"><h2>Content</h2><a href=\"");
    try queryUrl(output, value.query, .pages, "", 1);
    try output.writeAll("\">View all pages</a></div><div class=\"table-scroll mobile-records\"><table><caption>Top pages</caption><thead><tr><th scope=\"col\">Page</th><th scope=\"col\">Page views</th><th scope=\"col\">Visitors</th><th scope=\"col\">Share</th></tr></thead><tbody>");
    for (details.content) |row| {
        try output.writeAll("<tr><th scope=\"row\" data-label=\"Page\"><a href=\"");
        try queryUrl(output, value.query, .pages, "", 1);
        try output.writeAll("\">");
        try text(output, row.label);
        try output.print("</a></th><td data-label=\"Page views\">{d}</td><td data-label=\"Visitors\">{d}</td><td data-label=\"Share\">", .{ row.page_views, row.visitors });
        try renderBasisPoints(output, row.share_basis_points);
        try output.writeAll("</td></tr>");
    }
    if (details.content.len == 0) try output.writeAll("<tr><td colspan=\"4\">No page views in this range.</td></tr>");
    try output.writeAll("</tbody></table></div></article>");

    try output.writeAll("<article class=\"answer-panel\"><div class=\"answer-heading\"><h2>Acquisition</h2><a href=\"");
    try queryUrl(output, value.query, .sources, "", 1);
    try output.writeAll("\">View all sources</a></div><div class=\"table-scroll mobile-records\"><table><caption>Top referrer sources</caption><thead><tr><th scope=\"col\">Source</th><th scope=\"col\">Sessions</th><th scope=\"col\">Conversion rate</th></tr></thead><tbody>");
    for (details.acquisition) |row| {
        try output.writeAll("<tr><th scope=\"row\" data-label=\"Source\"><a href=\"");
        try queryUrl(output, value.query, .sources, "", 1);
        try output.writeAll("\">");
        try text(output, row.label);
        try output.print("</a></th><td data-label=\"Sessions\">{d}</td><td data-label=\"Conversion rate\">", .{row.sessions});
        try renderRatio(output, row.conversion);
        try output.writeAll("</td></tr>");
    }
    if (details.acquisition.len == 0) try output.writeAll("<tr><td colspan=\"3\">No sessions in this range.</td></tr>");
    try output.writeAll("</tbody></table></div></article>");

    try output.writeAll("<article class=\"answer-panel\"><div class=\"answer-heading\"><h2>Conversions</h2><a href=\"");
    try queryUrl(output, value.query, .goal, "", 1);
    try output.writeAll("\">View goals</a></div>");
    if (value.goals.len == 0) {
        try output.writeAll("<p class=\"answer-empty\">No active goals. Traffic remains available; create a goal to measure conversions.</p>");
    } else {
        try output.writeAll("<div class=\"table-scroll mobile-records\"><table><caption>Top active goals</caption><thead><tr><th scope=\"col\">Goal</th><th scope=\"col\">Converting people</th><th scope=\"col\">Visitor conversion rate</th></tr></thead><tbody>");
        for (details.conversions) |row| {
            try output.writeAll("<tr><th scope=\"row\" data-label=\"Goal\"><a href=\"");
            try queryUrl(output, value.query, .goal, row.goal_name, 1);
            try output.writeAll("\">");
            try text(output, row.goal_name);
            try output.print("</a></th><td data-label=\"Converting people\">{d}</td><td data-label=\"Visitor conversion rate\">", .{row.converting_people});
            try renderRatio(output, row.conversion);
            try output.writeAll("</td></tr>");
        }
        try output.writeAll("</tbody></table></div>");
    }
    try output.writeAll("</article>");

    try output.writeAll("<article class=\"answer-panel\"><div class=\"answer-heading\"><h2>Audience</h2><span><a href=\"");
    try queryUrl(output, value.query, .countries, "", 1);
    try output.writeAll("\">Countries</a> · <a href=\"");
    try queryUrl(output, value.query, .devices, "", 1);
    try output.writeAll("\">Devices</a></span></div><div class=\"table-scroll mobile-records\"><table><caption>Top countries</caption><thead><tr><th scope=\"col\">Country</th><th scope=\"col\">Sessions</th></tr></thead><tbody>");
    for (details.audience) |row| {
        try output.writeAll("<tr><th scope=\"row\" data-label=\"Country\"><a href=\"");
        try queryUrl(output, value.query, .countries, "", 1);
        try output.writeAll("\">");
        try text(output, row.label);
        try output.print("</a></th><td data-label=\"Sessions\">{d}</td></tr>", .{row.sessions});
    }
    if (details.audience.len == 0) try output.writeAll("<tr><td colspan=\"2\">No audience sessions in this range.</td></tr>");
    try output.writeAll("</tbody></table></div></article></section>");
}

fn renderOverviewHealth(
    output: *std.Io.Writer,
    query: model.Query,
    details: model.OverviewDetails,
    diagnostics_snapshot: diagnostics.Snapshot,
) !void {
    try output.writeAll(
        "<section class=\"data-health\" aria-labelledby=\"data-health-heading\"><div class=\"answer-heading\"><div><h2 id=\"data-health-heading\">Data health</h2><p class=\"muted\">Collection evidence is operational context, not a product metric.</p></div><a href=\"",
    );
    try queryUrl(output, query, .traffic_quality, "", 1);
    try output.writeAll("\">Open full Live diagnostics</a></div>");
    if (details.ceiling_reached_days != 0) {
        var warning_buffer: [192]u8 = undefined;
        const warning = try std.fmt.bufPrint(
            &warning_buffer,
            "The daily accepted-event ceiling was reached on {d} site-local day(s) in this range. New events received after the cap returned 429.",
            .{details.ceiling_reached_days},
        );
        try components.feedback(output, .{ .kind = .warning, .message = warning });
    }
    try output.writeAll("<dl class=\"health-grid\"><div><dt>Last accepted event</dt><dd>");
    try text(output, details.last_event_utc);
    try output.print(
        "</dd></div><div><dt>Tracker protocol distribution</dt><dd>v1 {d} · v2 {d}</dd></div>" ++
            "<div><dt>Collector/report</dt><dd>Available</dd></div>" ++
            "<div><dt>Rejected since process restart</dt><dd>{d}</dd></div>" ++
            "<div><dt>Store failures since process restart</dt><dd>{d}</dd></div>" ++
            "<div><dt>Accepted events stored</dt><dd>{d}</dd></div>" ++
            "<div><dt>Configured daily cap</dt><dd>{d}</dd></div>" ++
            "<div><dt>Ceiling-reached site-local days in range</dt><dd>{d}</dd></div>",
        .{
            details.protocol_v1_events,
            details.protocol_v2_events,
            diagnostics_snapshot.counts.rejected,
            diagnostics_snapshot.counts.store_failures,
            details.accepted_events,
            details.daily_event_ceiling,
            details.ceiling_reached_days,
        },
    );
    try output.writeAll("</dl></section>");
}

fn renderRatio(output: *std.Io.Writer, ratio: analysis.Ratio) !void {
    if (ratio.denominator == 0) {
        if (ratio.numerator != 0) return error.InvalidReportRate;
        return output.writeAll("Unavailable");
    }
    var buffer: [24]u8 = undefined;
    try text(output, try percentText(&buffer, ratio.numerator, ratio.denominator));
}

fn renderBasisPoints(output: *std.Io.Writer, basis_points: u16) !void {
    if (basis_points > 10_000) return error.InvalidReportRate;
    try output.print("{d}.{d:0>2}%", .{ basis_points / 100, basis_points % 100 });
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
        .analyze => if (adjusted.analysis_series.len == 0 and
            !adjusted.kind.isList())
        {
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
    if (destination == .analyze and adjusted.analysis_series.len != 0) {
        const parameters = try analysis.canonicalTrendSetUrl(
            std.heap.page_allocator,
            .{
                .site_id = adjusted.analysis_site_id,
                .range = adjusted.range,
                .comparison = adjusted.comparison,
                .interval = adjusted.analysis_interval,
                .series = adjusted.analysis_series,
            },
            adjusted.highlighted_interval,
        );
        defer std.heap.page_allocator.free(parameters);
        try output.writeByte('?');
        var parts = std.mem.splitScalar(u8, parameters, '&');
        var first = true;
        while (parts.next()) |part| {
            if (!first) try output.writeAll(separator);
            first = false;
            try output.writeAll(part);
        }
        return;
    }
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
            if (adjusted.overview_metric != .visitors) {
                try output.writeAll(separator);
                try output.writeAll("focus=");
                if (adjusted.overview_metric == .revenue) {
                    try output.writeAll("revenue-");
                    try urlComponent(output, adjusted.overview_currency);
                } else {
                    try urlComponent(output, adjusted.overview_metric.name());
                }
            }
            if (adjusted.highlighted_interval.len != 0) {
                try output.writeAll(separator);
                try output.writeAll("highlight=");
                try urlComponent(output, adjusted.highlighted_interval);
            }
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
        .overview => if (adjusted.overview_metric != .visitors) {
            try output.writeAll(separator);
            try output.writeAll("metric=");
            if (adjusted.overview_metric == .revenue) {
                try output.writeAll("revenue-");
                try urlComponent(output, adjusted.overview_currency);
            } else {
                try urlComponent(output, adjusted.overview_metric.name());
            }
        },
        .sessions, .settings => {},
    }
}

fn overviewMetricLabel(kind: analysis.OverviewTrendMetric) []const u8 {
    return switch (kind) {
        .visitors => "Visitors",
        .sessions => "Sessions",
        .page_views => "Page views",
        .conversions => "Conversions",
        .revenue => "Revenue",
    };
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

    var unavailable = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer unavailable.deinit();
    try renderRatio(&unavailable.writer, .{ .numerator = 0, .denominator = 0 });
    try std.testing.expectEqualStrings("Unavailable", unavailable.written());
}

test "Analyze chart coordinates retain exact rate and average components" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const rate = try analyzeChartMeasure(
        allocator,
        .{ .ratio = .{ .numerator = 1, .denominator = 3 } },
        .conversion_rate,
    );
    try std.testing.expectEqual(@as(?i128, 3333), rate.value);
    try std.testing.expectEqualStrings("1/3 · 33.33%", rate.formatted);

    const unavailable = try analyzeChartMeasure(
        allocator,
        .{ .ratio = .{ .numerator = 0, .denominator = 0 } },
        .engagement_rate,
    );
    try std.testing.expectEqual(@as(?i128, null), unavailable.value);
    try std.testing.expectEqualStrings("0/0 · unavailable", unavailable.formatted);

    const average = try analyzeChartMeasure(
        allocator,
        .{ .amount = .{
            .decimal = "10.000000",
            .currency = "EUR",
            .value_count = 3,
        } },
        .average_value,
    );
    try std.testing.expectEqual(@as(?i128, 3_333_333), average.value);
    try std.testing.expectEqualStrings(
        "exact sum EUR 10.000000 / 3 values",
        average.formatted,
    );
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
    try std.testing.expectEqualStrings("/admin/app.v10.css", stylesheet_path);
}
