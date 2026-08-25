const std = @import("std");
const analysis = @import("../analysis.zig");
const diagnostics = @import("../diagnostics.zig");
const funnel_domain = @import("../funnel.zig");
const report = @import("../report.zig");
const meta = @import("../store/meta.zig");
const charts = @import("charts.zig");
const components = @import("components.zig");
const controller = @import("controller.zig");
const model = @import("model.zig");

pub const stylesheet = @embedFile("style.css");
pub const stylesheet_path = "/admin/app.v16.css";
pub const htmx = @embedFile("htmx_js");
pub const htmx_gzip = @embedFile("htmx_gzip");
pub const htmx_path = "/admin/htmx.28fae7bb.js";
pub const dashboard_js = @embedFile("dashboard.js");
pub const dashboard_js_previous = @embedFile("dashboard.9c3ac396.js");
pub const dashboard_js_previous_path = "/admin/dashboard.9c3ac396.js";
pub const dashboard_js_path = "/admin/dashboard.96caab5d.js";
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
    if (value.analysis_state_kind.len != 0) try filterBar(output, value);
    switch (value.destination) {
        .overview => try overviewSection(output, value),
        .analyze => {
            if (value.analyze_trend != null) {
                try analyzeTrendSection(output, value);
            } else if (value.analyze_breakdown != null) {
                try analyzeBreakdownSection(output, value);
            } else {
                try reportNavigation(output, value);
                try reportSection(output, value);
            }
        },
        .journeys => {
            try journeyNavigation(output, value);
            if (value.goal_management != null) {
                try goalManagement(output, value);
                if (value.goal_management.?.screen == .detail) {
                    try reportSection(output, value);
                }
            } else if (value.funnel_management != null) {
                try funnelManagement(output, value);
                if (value.funnel_management.?.screen == .detail and
                    value.result != null)
                {
                    try reportSection(output, value);
                }
            } else {
                try reportSection(output, value);
                try definitions(output, value);
            }
        },
        .sessions => try sessionSection(output, value),
        .live => {
            try liveRegion(output, value.live_region orelse
                return error.MissingLiveRegion);
            try reportSection(output, value);
        },
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
        destination_query.goal_screen = .none;
        destination_query.goal_id = "";
        destination_query.goal_page = 1;
        destination_query.goal_search = "";
        destination_query.goal_entity_page = 1;
        destination_query.session_screen = .list;
        destination_query.session_id = "";
        destination_query.profile_person_key = "";
        destination_query.session_timeline_page = 1;
        if (destination != .sessions) {
            destination_query.session_goal_id = "";
            destination_query.session_page = 1;
        }
        var default_analysis_series = [_]analysis.Metric{.{ .kind = .visitors }};
        if (destination == .analyze and
            destination_query.analysis_series.len == 0 and
            destination_query.analysis_breakdown == null)
        {
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
        if (adjusted.analysis_breakdown) |breakdown_state| {
            var breakdown = breakdown_state;
            breakdown.range = adjusted.range;
            breakdown.page = 1;
            adjusted.analysis_breakdown = breakdown;
        }
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
    for (std.meta.tags(@TypeOf(value.query.comparison))) |comparison| {
        if (value.query.analysis_breakdown != null and comparison != .none) continue;
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
    try output.writeAll("</dd></div><div><dt>Segment</dt><dd>");
    if (value.selected_segment_name.len == 0) {
        try output.writeAll("All visitors");
    } else {
        try text(output, value.selected_segment_name);
    }
    try output.writeAll("</dd></div><div><dt>Filters</dt><dd>");
    if (value.filter_chips.len == 0) {
        try output.writeAll("None");
    } else {
        try output.print("{d} ad-hoc", .{value.filter_chips.len});
    }
    try output.writeAll("</dd></div></dl></div>");
}

fn filterBar(output: *std.Io.Writer, value: model.Page) !void {
    const selected_scope = if (value.filter_suggestions) |suggestions|
        suggestions.scope.name()
    else
        "event";
    const selected_field = if (value.filter_suggestions) |suggestions|
        suggestions.field.kind.name()
    else
        "page";
    const selected_property = if (value.filter_suggestions) |suggestions|
        if (suggestions.field.property_ref) |reference| reference.name else ""
    else
        "";
    const selected_type = if (value.filter_suggestions) |suggestions|
        suggestions.scalar_type.name()
    else
        "string";
    const selected_operator = if (value.filter_suggestions) |suggestions|
        suggestions.operator.name()
    else
        "is";
    const selected_search = if (value.filter_suggestions) |suggestions|
        suggestions.search
    else
        "";
    const selected_values = if (value.filter_suggestions) |suggestions|
        suggestions.builder_values
    else
        "";
    try output.writeAll(
        "<section class=\"panel filter-context\" aria-labelledby=\"filter-context-heading\">" ++
            "<div class=\"analysis-heading\"><div><h2 id=\"filter-context-heading\">Filters</h2>" ++
            "<p class=\"muted\">All clauses match; multiple values inside one clause match any value.</p></div></div>" ++
            "<div class=\"filter-chips\">",
    );
    if (value.selected_segment_name.len != 0) {
        try output.writeAll("<span class=\"filter-chip segment-chip\">Segment: ");
        try text(output, value.selected_segment_name);
        try output.writeAll(" <a aria-label=\"Remove selected segment\" href=\"");
        try attribute(output, value.clear_segment_url);
        try output.writeAll("\">Remove</a></span>");
    }
    for (value.filter_chips) |chip| {
        try output.writeAll("<span class=\"filter-chip\">");
        try text(output, chip.label);
        try output.writeAll(" <a aria-label=\"Remove filter: ");
        try attribute(output, chip.label);
        try output.writeAll("\" href=\"");
        try attribute(output, chip.remove_url);
        try output.writeAll("\">Remove</a></span>");
    }
    if (value.selected_segment_name.len == 0 and value.filter_chips.len == 0) {
        try output.writeAll("<span class=\"muted\">All visitors · no filters</span>");
    }
    try output.writeAll("</div><details class=\"management filter-builder\"");
    if (value.filter_suggestions != null) try output.writeAll(" open");
    try output.writeAll("><summary>Add a filter</summary><form method=\"post\" action=\"/admin/filters/apply\">");
    try analysisStateHiddenFields(output, value);
    try output.writeAll("<div class=\"form-grid\"><label>Scope<select name=\"scope\">");
    try filterSelectOptions(output, &filter_scope_options, selected_scope);
    try output.writeAll("</select></label><label>Field<select name=\"field\">");
    try filterSelectOptions(output, &filter_field_options, selected_field);
    try output.writeAll("</select></label><label>Property name<input name=\"property\" maxlength=\"120\" placeholder=\"Required for property or trait\" value=\"");
    try attribute(output, selected_property);
    try output.writeAll("\"></label><label>Type<select name=\"scalar_type\">");
    try filterSelectOptions(output, &filter_type_options, selected_type);
    try output.writeAll("</select></label><label>Operator<select name=\"operator\">");
    try filterSelectOptions(output, &filter_operator_options, selected_operator);
    try output.writeAll("</select></label><label>Suggestion search<input name=\"search\" maxlength=\"256\" value=\"");
    try attribute(output, selected_search);
    try output.writeAll("\"></label><label class=\"wide\">Values, one per line<textarea name=\"values\" rows=\"3\" maxlength=\"20480\">");
    try text(output, selected_values);
    try output.writeAll(
        "</textarea></label></div><button type=\"submit\">Apply filter</button> " ++
            "<button class=\"button-secondary\" type=\"submit\" formaction=\"/admin/filters/suggest\">Preview values</button></form>",
    );
    if (value.filter_suggestions) |suggestions| {
        try output.writeAll("<section class=\"suggestion-results\" aria-live=\"polite\"><h3>Suggested values for ");
        try text(output, suggestions.scope.name());
        try output.writeAll(" · ");
        try text(output, suggestions.field.kind.name());
        if (suggestions.field.property_ref) |reference| {
            try output.writeByte(':');
            try text(output, reference.name);
        }
        try output.writeAll(" · ");
        try text(output, suggestions.scalar_type.name());
        try output.writeAll("</h3>");
        try output.writeAll("<p class=\"muted\">Context: ");
        try text(output, suggestions.scope.name());
        try output.writeAll(" · ");
        try text(output, suggestions.field.kind.name());
        if (suggestions.field.property_ref) |reference| {
            try output.writeByte(':');
            try text(output, reference.name);
        }
        try output.writeAll(" · ");
        try text(output, suggestions.scalar_type.name());
        if (suggestions.search.len != 0) {
            try output.writeAll(" · search “");
            try text(output, suggestions.search);
            try output.writeAll("”");
        }
        try output.writeAll("</p>");
        if (suggestions.values.len == 0) {
            try output.writeAll("<p>No values matched this site, range, preceding filter context, and search.</p>");
        } else {
            try output.writeAll("<ul>");
            for (suggestions.values) |option| {
                try output.writeAll("<li><code>");
                try text(output, option.value);
                try output.writeAll("</code> ");
                try filterActions(
                    output,
                    option.filter_url,
                    option.exclude_url,
                    option.value,
                );
                try output.writeAll("</li>");
            }
            try output.writeAll("</ul>");
            if (suggestions.has_more) {
                try output.writeAll("<p>More than 50 values matched. Refine the search.</p>");
            }
        }
        try output.writeAll("</section>");
    }
    try output.writeAll("</details><details class=\"management\"><summary>Segments</summary>");
    if (value.segment_options.len != 0) {
        try output.writeAll("<nav class=\"saved-list\" aria-label=\"Saved segments\">");
        for (value.segment_options) |option| {
            try output.writeAll("<article class=\"segment-row\">");
            if (option.url.len == 0) {
                try output.writeAll("<span>");
                try text(output, option.name);
                try output.writeAll(" — URL limit reached</span>");
            } else {
                try output.writeAll("<a href=\"");
                try attribute(output, option.url);
                if (option.selected) {
                    try output.writeAll("\" aria-current=\"page\">");
                } else try output.writeAll("\">");
                try text(output, option.name);
                try output.writeAll("</a>");
            }
            try output.writeAll(" <small class=\"muted\">Updated ");
            try text(output, option.updated_at_utc);
            try output.writeAll("</small><form method=\"post\" action=\"/admin/segments/delete\">");
            try hidden(output, "csrf", value.csrf_token);
            try hidden(output, "site", value.query.site);
            try hidden(output, "id", option.id);
            try output.writeAll("<label>Type exact name to delete<input name=\"name\" required maxlength=\"120\"></label><button class=\"danger\" type=\"submit\">Delete segment</button></form></article>");
        }
        try output.writeAll("</nav>");
    } else try output.writeAll("<p class=\"muted\">No saved segments.</p>");
    try output.writeAll("<form method=\"post\" action=\"/admin/segments\">");
    try analysisStateHiddenFields(output, value);
    try output.writeAll("<label>Name<input name=\"name\" required maxlength=\"120\"></label><button type=\"submit\">Save current filters as segment</button></form>");
    if (value.query.analysis_segment_id) |id| {
        try output.writeAll("<form method=\"post\" action=\"/admin/segments/update\">");
        try analysisStateHiddenFields(output, value);
        try hidden(output, "id", id);
        try output.writeAll("<button type=\"submit\">Replace segment with current filters</button></form>");
        try output.writeAll("<form method=\"post\" action=\"/admin/segments/rename\">");
        try analysisStateHiddenFields(output, value);
        try hidden(output, "id", id);
        try output.writeAll("<label>New name<input name=\"name\" required maxlength=\"120\" value=\"");
        try attribute(output, value.selected_segment_name);
        try output.writeAll("\"></label><button type=\"submit\">Rename segment</button></form>" ++
            "<form method=\"post\" action=\"/admin/segments/duplicate\">");
        try analysisStateHiddenFields(output, value);
        try hidden(output, "id", id);
        try output.writeAll("<label>Copy name<input name=\"name\" required maxlength=\"120\"></label><button type=\"submit\">Duplicate segment</button></form>");
    }
    try output.writeAll("</details>");
    if (value.destination == .analyze) try savedViews(output, value);
    try output.writeAll("</section>");
}

const FilterSelectOption = struct {
    value: []const u8,
    label: []const u8,
};

const filter_scope_options = [_]FilterSelectOption{
    .{ .value = "event", .label = "Event" },
    .{ .value = "session", .label = "Session" },
    .{ .value = "person", .label = "Person" },
};

const filter_field_options = [_]FilterSelectOption{
    .{ .value = "page", .label = "Page" },
    .{ .value = "page-title", .label = "Page title" },
    .{ .value = "hostname", .label = "Hostname" },
    .{ .value = "event-name", .label = "Event name" },
    .{ .value = "landing-page", .label = "Landing page" },
    .{ .value = "exit-page", .label = "Exit page" },
    .{ .value = "channel", .label = "Channel" },
    .{ .value = "referrer", .label = "Referrer" },
    .{ .value = "utm-source", .label = "UTM source" },
    .{ .value = "utm-medium", .label = "UTM medium" },
    .{ .value = "utm-campaign", .label = "UTM campaign" },
    .{ .value = "utm-term", .label = "UTM term" },
    .{ .value = "utm-content", .label = "UTM content" },
    .{ .value = "country", .label = "Country" },
    .{ .value = "language", .label = "Language" },
    .{ .value = "device", .label = "Device" },
    .{ .value = "browser", .label = "Browser" },
    .{ .value = "operating-system", .label = "Operating system" },
    .{ .value = "identity-state", .label = "Identity state" },
    .{ .value = "session-converted", .label = "Session converted" },
    .{ .value = "session-duration-ms", .label = "Session duration ms" },
    .{ .value = "session-engagement-ms", .label = "Session engagement ms" },
    .{ .value = "event-property", .label = "Event property" },
    .{ .value = "user-trait", .label = "User trait" },
};

const filter_type_options = [_]FilterSelectOption{
    .{ .value = "string", .label = "String" },
    .{ .value = "integer", .label = "Integer" },
    .{ .value = "decimal", .label = "Decimal" },
    .{ .value = "boolean", .label = "Boolean" },
    .{ .value = "null", .label = "Null" },
    .{ .value = "missing", .label = "Missing" },
};

const filter_operator_options = [_]FilterSelectOption{
    .{ .value = "is", .label = "Is (Filter)" },
    .{ .value = "is_not", .label = "Is not (Exclude)" },
    .{ .value = "contains", .label = "Contains" },
    .{ .value = "not_contains", .label = "Does not contain" },
    .{ .value = "starts_with", .label = "Starts with" },
    .{ .value = "gt", .label = "Greater than" },
    .{ .value = "gte", .label = "At least" },
    .{ .value = "lt", .label = "Less than" },
    .{ .value = "lte", .label = "At most" },
    .{ .value = "is_true", .label = "Is true" },
    .{ .value = "is_false", .label = "Is false" },
    .{ .value = "exists", .label = "Exists" },
    .{ .value = "absent", .label = "Absent" },
};

fn filterSelectOptions(
    output: *std.Io.Writer,
    options: []const FilterSelectOption,
    selected: []const u8,
) !void {
    for (options) |option| {
        try output.writeAll("<option value=\"");
        try attribute(output, option.value);
        if (std.mem.eql(u8, option.value, selected)) {
            try output.writeAll("\" selected>");
        } else {
            try output.writeAll("\">");
        }
        try text(output, option.label);
        try output.writeAll("</option>");
    }
}

fn savedViews(output: *std.Io.Writer, value: model.Page) !void {
    try output.writeAll("<details class=\"management\"><summary>Saved views</summary><form method=\"post\" action=\"/admin/saved-views\">");
    try analysisStateHiddenFields(output, value);
    try output.writeAll("<label>Name<input name=\"name\" required maxlength=\"120\"></label><button type=\"submit\">Save this view</button></form>");
    if (value.saved_views.len == 0) {
        try output.writeAll("<p class=\"muted\">No saved views.</p>");
    }
    for (value.saved_views) |view| {
        try output.writeAll("<article class=\"saved-row\"><a href=\"/admin/sites/");
        try attribute(output, value.query.site);
        try output.writeAll("/saved-views/");
        try attribute(output, view.id);
        try output.writeAll("\">");
        try text(output, view.name);
        try output.writeAll("</a><form method=\"post\" action=\"/admin/saved-views/rename\">");
        try savedEntityFields(output, value, view.id);
        try output.writeAll("<label>New name<input name=\"name\" required maxlength=\"120\" value=\"");
        try attribute(output, view.name);
        try output.writeAll("\"></label><button type=\"submit\">Rename</button></form>" ++
            "<form method=\"post\" action=\"/admin/saved-views/duplicate\">");
        try savedEntityFields(output, value, view.id);
        try output.writeAll("<label>Copy name<input name=\"name\" required maxlength=\"120\"></label><button type=\"submit\">Duplicate</button></form>" ++
            "<form method=\"post\" action=\"/admin/saved-views/delete\">");
        try savedEntityFields(output, value, view.id);
        try output.writeAll("<label>Type exact name<input name=\"name\" required maxlength=\"120\"></label><button class=\"danger\" type=\"submit\">Delete</button></form></article>");
    }
    try output.writeAll("</details>");
}

fn savedEntityFields(
    output: *std.Io.Writer,
    value: model.Page,
    id: []const u8,
) !void {
    try hidden(output, "csrf", value.csrf_token);
    try hidden(output, "site", value.query.site);
    try hidden(output, "id", id);
}

fn analysisStateHiddenFields(output: *std.Io.Writer, value: model.Page) !void {
    try hidden(output, "csrf", value.csrf_token);
    try hidden(output, "site", value.query.site);
    try hidden(output, "state_kind", value.analysis_state_kind);
    try hidden(output, "state", value.analysis_state_json);
    if (std.mem.eql(u8, value.analysis_state_kind, "overview")) {
        try hidden(output, "from", value.query.range.start);
        try hidden(output, "to", value.query.range.end);
        try hidden(output, "compare", value.query.comparison.name());
        if (value.query.overview_metric == .revenue) {
            try output.writeAll(
                "<input type=\"hidden\" name=\"metric\" value=\"revenue-",
            );
            try attribute(output, value.query.overview_currency);
            try output.writeAll("\">");
        } else {
            try hidden(output, "metric", value.query.overview_metric.name());
        }
        try hidden(
            output,
            "segment",
            value.query.analysis_segment_id orelse "",
        );
    } else if (std.mem.eql(u8, value.analysis_state_kind, "sessions")) {
        try hidden(output, "from", value.query.range.start);
        try hidden(output, "to", value.query.range.end);
        try hidden(output, "compare", value.query.comparison.name());
        try hidden(output, "goal", value.query.session_goal_id);
        try hidden(
            output,
            "segment",
            value.query.analysis_segment_id orelse "",
        );
        if (value.query.session_screen != .list) {
            try hidden(
                output,
                "session_screen",
                @tagName(value.query.session_screen),
            );
            try hidden(output, "session_id", value.query.session_id);
            try hidden(
                output,
                "profile_person",
                value.query.profile_person_key,
            );
            var page_buffer: [16]u8 = undefined;
            try hidden(
                output,
                "session_page",
                try std.fmt.bufPrint(&page_buffer, "{d}", .{
                    value.query.session_page,
                }),
            );
            var timeline_buffer: [16]u8 = undefined;
            try hidden(
                output,
                "timeline_page",
                try std.fmt.bufPrint(&timeline_buffer, "{d}", .{
                    value.query.session_timeline_page,
                }),
            );
        }
    }
}

fn hidden(output: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try output.writeAll("<input type=\"hidden\" name=\"");
    try attribute(output, name);
    try output.writeAll("\" value=\"");
    try attribute(output, value);
    try output.writeAll("\">");
}

fn destinationHiddenFields(output: *std.Io.Writer, value: model.Page) !void {
    if (value.destination == .overview) {
        try hidden(output, "v", "1");
        if (value.query.overview_metric == .revenue) {
            try output.writeAll("<input type=\"hidden\" name=\"metric\" value=\"revenue-");
            try attribute(output, value.query.overview_currency);
            try output.writeAll("\">");
        } else {
            try hidden(output, "metric", value.query.overview_metric.name());
        }
    } else if (value.destination == .sessions) {
        try hidden(output, "v", "1");
        if (value.query.session_goal_id.len != 0) {
            try hidden(output, "goal", value.query.session_goal_id);
        }
    } else if (value.destination == .analyze and value.query.analysis_breakdown != null) {
        const breakdown = value.query.analysis_breakdown.?;
        try output.writeAll(
            "<input type=\"hidden\" name=\"v\" value=\"1\">" ++
                "<input type=\"hidden\" name=\"mode\" value=\"breakdown\">" ++
                "<input type=\"hidden\" name=\"metric\" value=\"",
        );
        try attribute(output, breakdown.metric.kind.name());
        try output.writeAll("\">");
        if (breakdown.metric.conversion_basis) |basis| {
            try output.writeAll("<input type=\"hidden\" name=\"conversion-basis\" value=\"");
            try attribute(output, basis.name());
            try output.writeAll("\">");
        }
        if (breakdown.metric.selector) |selector| {
            try output.writeAll("<input type=\"hidden\" name=\"selector\" value=\"");
            try attribute(output, selector.kind.name());
            try output.writeAll("\"><input type=\"hidden\" name=\"selector-value\" value=\"");
            try attribute(output, selector.value);
            try output.writeAll("\">");
            for (value.analysis_predicate_parameters) |encoded| {
                try output.writeAll("<input type=\"hidden\" name=\"p\" value=\"");
                try attribute(output, encoded);
                try output.writeAll("\">");
            }
        }
        try output.writeAll("<input type=\"hidden\" name=\"dimension\" value=\"");
        try attribute(output, breakdown.dimension.?.kind.name());
        try output.writeAll("\">");
        if (breakdown.dimension.?.property_ref) |reference| {
            try output.writeAll("<input type=\"hidden\" name=\"property\" value=\"");
            try attribute(output, reference.name);
            try output.writeAll("\"><input type=\"hidden\" name=\"property-type\" value=\"");
            try attribute(output, reference.scalar_type.name());
            try output.writeAll("\">");
        }
        if (breakdown.search.len != 0) {
            try output.writeAll("<input type=\"hidden\" name=\"search\" value=\"");
            try attribute(output, breakdown.search);
            try output.writeAll("\">");
        }
        try output.writeAll("<input type=\"hidden\" name=\"interval\" value=\"auto\"><input type=\"hidden\" name=\"sort\" value=\"");
        try attribute(output, breakdown.sort.name());
        try output.print("\"><input type=\"hidden\" name=\"page\" value=\"1\"><input type=\"hidden\" name=\"limit\" value=\"{d}\">", .{breakdown.limit});
    } else if (value.destination == .analyze and value.query.analysis_series.len != 0) {
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
    if ((value.destination == .analyze and value.query.analysis_series.len == 0 and
        value.query.analysis_breakdown == null) or
        (value.destination == .live and value.query.limit != report.default_limit))
    {
        try output.writeAll("<input type=\"hidden\" name=\"limit\" value=\"");
        try output.print("{d}", .{value.query.limit});
        try output.writeAll("\"><input type=\"hidden\" name=\"page\" value=\"1\">");
    }
    if (value.destination == .overview or value.destination == .analyze or
        value.destination == .sessions)
    {
        try analysisContextHiddenFields(output, value);
    }
}

fn analysisContextHiddenFields(output: *std.Io.Writer, value: model.Page) !void {
    if (value.query.analysis_segment_id) |id| try hidden(output, "segment", id);
    for (value.analysis_filter_parameters) |encoded| {
        try hidden(output, "f", encoded);
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

pub fn liveRegion(output: *std.Io.Writer, value: model.LiveRegion) !void {
    try output.writeAll(
        "<section id=\"live-region\" data-live-region data-live-paused=\"false\"" ++
            " hx-get=\"",
    );
    try attribute(output, value.refresh_url);
    try output.writeAll(
        "\" hx-trigger=\"every 5s\" hx-target=\"this\"" ++
            " hx-swap=\"outerHTML focus-scroll:false\" hx-sync=\"this:drop\"" ++
            " hx-status:4xx=\"swap:none\" hx-status:5xx=\"swap:none\"" ++
            " aria-labelledby=\"live-current-heading\">" ++
            "<div class=\"overview-section-heading\"><div>" ++
            "<h2 id=\"live-current-heading\">Current traffic</h2>" ++
            "<p class=\"muted\">Product activity uses authoritative receipt time: the last 30 minutes, with Active now covering the last 5 minutes.</p>" ++
            "</div><div class=\"form-actions\"><a class=\"button button-secondary\" href=\"",
    );
    try attribute(output, value.refresh_url);
    try output.writeAll(
        "\">Refresh Live</a><button id=\"live-pause\" type=\"button\"" ++
            " class=\"button-secondary\" data-live-pause aria-pressed=\"false\"" ++
            " hidden>Pause automatic refresh</button>" ++
            "</div></div><p class=\"muted\" role=\"status\" aria-live=\"polite\"" ++
            " data-live-client-status>Updated <time data-live-generated datetime=\"",
    );
    try attribute(output, value.generated_at_utc_datetime);
    try output.writeAll("\">");
    try text(output, value.generated_at_utc);
    try output.writeAll("</time>. Latest accepted receipt: ");
    try text(output, value.latest_accepted_at_utc);
    try output.writeAll(".</p><ul class=\"metrics\">");
    try liveKpi(output, "Active now", value.active_sessions);
    try liveKpi(output, "Page views", value.page_views);
    try liveKpi(output, "Custom events", value.custom_events);
    try liveKpi(output, "Conversions", value.conversions);
    try output.writeAll("</ul><section class=\"answer-grid\" aria-label=\"Current traffic breakdowns\">");
    try liveCountPanel(output, "Pages", "Page", value.pages);
    try liveCountPanel(output, "Sources", "Source", value.sources);
    try liveCountPanel(output, "Events", "Event", value.events);
    try liveCountPanel(output, "Conversions", "Goal", value.goals);
    try liveCountPanel(output, "Countries", "Country", value.countries);
    try liveCountPanel(output, "Devices", "Device", value.devices);
    try output.writeAll("</section><section class=\"data-health\" aria-labelledby=\"live-protocol-heading\">" ++
        "<div class=\"answer-heading\"><div><h3 id=\"live-protocol-heading\">Collection protocol</h3>" ++
        "<p class=\"muted\">Stored accepted events in the current 30-minute receipt window.</p></div></div>");
    try liveCountTable(output, "Protocol", value.protocols);
    try output.writeAll("</section><section class=\"data-health\" aria-labelledby=\"live-attempts-heading\">" ++
        "<div class=\"answer-heading\"><div><h3 id=\"live-attempts-heading\">Recent collection attempts</h3>" ++
        "<p class=\"muted\">Safe protocol summaries from this process only. They reset on restart, are capped at 200 globally, and are filtered to this site before every count and row below.</p>" ++
        "</div></div><dl class=\"health-grid\">");
    try liveHealthCount(output, "Accepted", value.accepted_attempts);
    try liveHealthCount(output, "Rejected", value.rejected_attempts);
    try liveHealthCount(output, "Duplicates", value.duplicate_attempts);
    try liveHealthCount(output, "Store failures", value.store_failure_attempts);
    try liveHealthCount(output, "Selected-site retained", value.retained_attempts);
    try liveHealthCount(output, "Newest rows shown", value.shown_attempts);
    try output.writeAll("</dl>");
    if (value.attempts.len == 0) {
        try output.writeAll("<p class=\"answer-empty\">No selected-site collection attempts are retained since this process started.</p>");
    } else {
        try output.writeAll("<div class=\"table-scroll mobile-records\"><table>" ++
            "<caption>Newest safe selected-site attempts</caption><thead><tr>" ++
            "<th scope=\"col\">Receipt</th><th scope=\"col\">Protocol</th>" ++
            "<th scope=\"col\">Type</th><th scope=\"col\">Outcome</th>" ++
            "<th scope=\"col\">Safe context</th></tr></thead><tbody>");
        for (value.attempts) |attempt| try liveAttemptRow(output, attempt);
        try output.writeAll("</tbody></table></div>");
    }
    try output.writeAll("</section></section>");
}

fn liveKpi(output: *std.Io.Writer, label: []const u8, count: i64) !void {
    try output.writeAll("<li class=\"kpi\"><span>");
    try text(output, label);
    try output.print("</span><strong>{d}</strong></li>", .{count});
}

fn liveCountPanel(
    output: *std.Io.Writer,
    title: []const u8,
    label_heading: []const u8,
    rows: []const model.LiveCountRow,
) !void {
    try output.writeAll("<article class=\"answer-panel\"><h3>");
    try text(output, title);
    try output.writeAll("</h3>");
    try liveCountTableHeading(output, label_heading, rows);
    try output.writeAll("</article>");
}

fn liveCountTable(
    output: *std.Io.Writer,
    label_heading: []const u8,
    rows: []const model.LiveCountRow,
) !void {
    try output.writeAll("<div class=\"table-scroll mobile-records\">");
    try liveCountTableHeading(output, label_heading, rows);
    try output.writeAll("</div>");
}

fn liveCountTableHeading(
    output: *std.Io.Writer,
    label_heading: []const u8,
    rows: []const model.LiveCountRow,
) !void {
    if (rows.len == 0) {
        try output.writeAll("<p class=\"answer-empty\">No matching activity in this window.</p>");
        return;
    }
    try output.writeAll("<table><thead><tr><th scope=\"col\">");
    try text(output, label_heading);
    try output.writeAll("</th><th scope=\"col\">Count</th></tr></thead><tbody>");
    for (rows) |row| {
        try output.writeAll("<tr><th scope=\"row\" data-label=\"");
        try attribute(output, label_heading);
        try output.writeAll("\">");
        try text(output, row.label);
        try output.print("</th><td data-label=\"Count\">{d}</td></tr>", .{row.count});
    }
    try output.writeAll("</tbody></table>");
}

fn liveHealthCount(output: *std.Io.Writer, label: []const u8, count: usize) !void {
    try output.writeAll("<div><dt>");
    try text(output, label);
    try output.print("</dt><dd>{d}</dd></div>", .{count});
}

fn liveAttemptRow(output: *std.Io.Writer, attempt: model.LiveAttempt) !void {
    try output.writeAll("<tr><th scope=\"row\" data-label=\"Receipt\">");
    try text(output, attempt.received_at_utc);
    try output.writeAll("<br><span class=\"muted\">#");
    try output.print("{d}</span></th><td data-label=\"Protocol\">", .{attempt.correlation});
    try text(output, attempt.protocol);
    try output.writeAll("</td><td data-label=\"Type\">");
    try text(output, attempt.category);
    try output.writeAll("</td><td data-label=\"Outcome\">");
    try text(output, attempt.outcome);
    if (attempt.rejection_code.len != 0) {
        try output.writeAll("<br><span class=\"muted\">");
        try text(output, attempt.rejection_code);
        try output.writeAll("</span>");
    }
    try output.writeAll("</td><td data-label=\"Safe context\">");
    var wrote = false;
    if (attempt.subject.len != 0) {
        try text(output, attempt.subject);
        wrote = true;
    }
    if (attempt.origin_host.len != 0) {
        if (wrote) try output.writeAll(" · ");
        try text(output, attempt.origin_host);
        wrote = true;
    }
    for (attempt.properties) |property| {
        if (wrote) try output.writeAll(" · ");
        try text(output, property.key);
        try output.writeByte(':');
        try text(output, property.scalar_type);
        wrote = true;
    }
    if (!wrote) try output.writeAll("None retained");
    try output.writeAll("</td></tr>");
}

fn analyzeTrendSection(output: *std.Io.Writer, value: model.Page) !void {
    const trend = value.analyze_trend orelse return error.MissingAnalyzeTrend;
    try output.writeAll(
        "<section id=\"report\" aria-labelledby=\"analyze-trend-heading\">" ++
            "<div class=\"analysis-heading\"><div><h2 id=\"analyze-trend-heading\">Trend</h2>" ++
            "<p class=\"muted\">One to three typed metric queries share this request's deadline. Exact currencies remain separate.</p></div>" ++
            "<a class=\"button button-secondary\" href=\"",
    );
    var breakdown = analysis.presetQuery(
        .pages,
        value.query.analysis_site_id,
        value.query.range,
    );
    breakdown.filters = value.query.analysis_filters;
    breakdown.segment_id = value.query.analysis_segment_id;
    var breakdown_query = value.query;
    breakdown_query.comparison = .none;
    breakdown_query.analysis_series = &.{};
    breakdown_query.analysis_interval = .auto;
    breakdown_query.highlighted_interval = "";
    breakdown_query.analysis_breakdown = breakdown;
    try canonicalUrl(output, .analyze, breakdown_query, 1);
    try output.writeAll("\">Open Breakdown</a></div>");

    try output.writeAll("<form class=\"panel analysis-builder\" method=\"get\" action=\"");
    try canonicalPath(output, .analyze, value.query);
    try output.writeAll("\">");
    try calendarHiddenFields(output, value.query);
    try analysisContextHiddenFields(output, value);
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

const BreakdownPreset = struct {
    preset: analysis.Preset,
    label: []const u8,
};

const breakdown_presets = [_]BreakdownPreset{
    .{ .preset = .pages, .label = "Pages" },
    .{ .preset = .entries, .label = "Entries" },
    .{ .preset = .exits, .label = "Exits" },
    .{ .preset = .sources, .label = "Sources" },
    .{ .preset = .campaigns_source, .label = "UTM source" },
    .{ .preset = .campaigns_medium, .label = "UTM medium" },
    .{ .preset = .campaigns_campaign, .label = "UTM campaign" },
    .{ .preset = .campaigns_term, .label = "UTM term" },
    .{ .preset = .campaigns_content, .label = "UTM content" },
    .{ .preset = .countries, .label = "Countries" },
    .{ .preset = .browsers, .label = "Browsers" },
    .{ .preset = .operating_systems, .label = "OS" },
    .{ .preset = .devices, .label = "Devices" },
    .{ .preset = .events, .label = "Events" },
};

fn analyzeBreakdownSection(output: *std.Io.Writer, value: model.Page) !void {
    const view = value.analyze_breakdown orelse return error.MissingAnalyzeBreakdown;
    const query = value.query.analysis_breakdown orelse
        return error.MissingAnalyzeBreakdown;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try output.writeAll(
        "<section id=\"report\" aria-labelledby=\"analyze-breakdown-heading\">" ++
            "<div class=\"analysis-heading\"><div>" ++
            "<h2 id=\"analyze-breakdown-heading\">Breakdown</h2>" ++
            "<p class=\"muted\">One typed metric grouped by one dimension. Search, sort, and pagination are server-owned.</p></div>" ++
            "<a class=\"button button-secondary\" href=\"",
    );
    var trend_query = value.query;
    const trend_series = [_]analysis.Metric{.{ .kind = .visitors }};
    trend_query.analysis_breakdown = null;
    trend_query.analysis_series = &trend_series;
    trend_query.analysis_interval = .auto;
    trend_query.comparison = .none;
    try canonicalUrl(output, .analyze, trend_query, 1);
    try output.writeAll("\">Open Trend</a></div><nav class=\"report-tabs breakdown-presets\" aria-label=\"Breakdown presets\">");
    for (breakdown_presets) |item| {
        var preset_query = value.query;
        var preset = analysis.presetQuery(
            item.preset,
            value.query.analysis_site_id,
            value.query.range,
        );
        preset.filters = value.query.analysis_filters;
        preset.segment_id = value.query.analysis_segment_id;
        preset_query.analysis_breakdown = preset;
        try output.writeAll("<a id=\"breakdown-preset-");
        try attribute(output, @tagName(item.preset));
        try output.writeAll("\" href=\"");
        try canonicalUrl(output, .analyze, preset_query, 1);
        if (breakdownPresetSelected(query, preset)) {
            try output.writeAll("\" aria-current=\"page\">");
        } else {
            try output.writeAll("\">");
        }
        try text(output, item.label);
        try output.writeAll("</a>");
    }
    try output.writeAll("</nav><form class=\"panel analysis-builder breakdown-builder\" method=\"get\" action=\"");
    try canonicalPath(output, .analyze, value.query);
    try output.writeAll(
        "\"><input type=\"hidden\" name=\"builder\" value=\"1\">" ++
            "<input type=\"hidden\" name=\"mode\" value=\"breakdown\">" ++
            "<input type=\"hidden\" name=\"from\" value=\"",
    );
    try attribute(output, query.range.start);
    try output.writeAll("\"><input type=\"hidden\" name=\"to\" value=\"");
    try attribute(output, query.range.end);
    try output.writeAll("\">");
    try analysisContextHiddenFields(output, value);
    try output.writeAll("<label>Metric<select name=\"metric\">");
    inline for (std.meta.tags(analysis.MetricKind)) |kind| {
        try output.writeAll("<option value=\"");
        try attribute(output, kind.name());
        try output.writeByte('"');
        if (kind == query.metric.kind) try output.writeAll(" selected");
        try output.writeByte('>');
        try text(output, analysisMetricLabel(kind));
        try output.writeAll("</option>");
    }
    try output.writeAll("</select></label><label>Exact event <span class=\"muted\">(when applicable)</span><input name=\"event\" maxlength=\"64\" autocomplete=\"off\" value=\"");
    if (query.metric.selector) |selector| {
        if (selector.kind == .exact_event) try attribute(output, selector.value);
    }
    try output.writeAll("\"></label><label>Saved goal <span class=\"muted\">(when applicable)</span><select name=\"goal\"><option value=\"\">None</option>");
    for (value.goals) |goal| {
        try output.writeAll("<option value=\"");
        try attribute(output, goal.id);
        try output.writeByte('"');
        if (query.metric.selector) |selector| {
            if (selector.kind == .saved_goal and
                std.mem.eql(u8, selector.value, goal.id))
            {
                try output.writeAll(" selected");
            }
        }
        try output.writeByte('>');
        try text(output, goal.name);
        try output.writeAll("</option>");
    }
    try output.writeAll("</select></label><label>Dimension<select name=\"dimension\">");
    inline for (std.meta.tags(analysis.DimensionKind)) |kind| {
        try output.writeAll("<option value=\"");
        try attribute(output, kind.name());
        try output.writeByte('"');
        if (kind == query.dimension.?.kind) try output.writeAll(" selected");
        try output.writeByte('>');
        try text(output, dimensionLabel(kind));
        try output.writeAll("</option>");
    }
    try output.writeAll("</select></label><label>Event property <span class=\"muted\">(for Property dimension)</span><input name=\"property\" list=\"breakdown-property-names\" maxlength=\"64\" autocomplete=\"off\" value=\"");
    if (query.dimension.?.property_ref) |reference| try attribute(output, reference.name);
    try output.writeAll("\"></label><datalist id=\"breakdown-property-names\">");
    var previous_property: []const u8 = "";
    for (view.properties) |entry| {
        if (std.mem.eql(u8, previous_property, entry.name)) continue;
        try output.writeAll("<option value=\"");
        try attribute(output, entry.name);
        try output.writeAll("\"></option>");
        previous_property = entry.name;
    }
    try output.writeAll("</datalist><label>Property type<select name=\"property-type\">");
    inline for (std.meta.tags(analysis.ScalarType)) |scalar_type| {
        try output.writeAll("<option value=\"");
        try attribute(output, scalar_type.name());
        try output.writeByte('"');
        if (query.dimension.?.property_ref != null and
            query.dimension.?.property_ref.?.scalar_type == scalar_type)
        {
            try output.writeAll(" selected");
        }
        try output.writeByte('>');
        try text(output, humanize(scalar_type.name()));
        try output.writeAll("</option>");
    }
    try output.writeAll("</select></label><label>Search labels<input type=\"search\" name=\"search\" maxlength=\"256\" value=\"");
    try attribute(output, query.search);
    try output.writeAll("\"></label><label>Sort<select name=\"sort\">");
    inline for (std.meta.tags(analysis.Sort)) |sort| {
        try output.writeAll("<option value=\"");
        try attribute(output, sort.name());
        try output.writeByte('"');
        if (sort == query.sort) try output.writeAll(" selected");
        try output.writeByte('>');
        try text(output, breakdownSortLabel(sort));
        try output.writeAll("</option>");
    }
    try output.writeAll("</select></label><label>Rows<select name=\"limit\">");
    inline for (.{ 10, 25, 50, 100 }) |limit| {
        try output.print("<option value=\"{d}\"", .{limit});
        if (limit == query.limit) try output.writeAll(" selected");
        try output.print(">{d}</option>", .{limit});
    }
    try output.writeAll("</select></label>");
    for (value.analysis_predicate_parameters) |encoded| {
        try output.writeAll("<input type=\"hidden\" name=\"p\" value=\"");
        try attribute(output, encoded);
        try output.writeAll("\">");
    }
    try output.writeAll("<p class=\"field-help analysis-builder-help\">Event metrics require one exact event; conversion metrics require one saved goal. A property with multiple observed types requires one explicit type. Missing is distinct from null.");
    if (query.metric.selector) |selector| if (selector.predicates.len != 0) {
        try output.print(
            " {d} typed subject predicate(s) from this canonical query will be preserved.",
            .{selector.predicates.len},
        );
    };
    try output.writeAll("</p><button type=\"submit\">Run Breakdown</button></form>");

    try renderPropertyCatalog(output, view);
    if (view.no_events_ever) {
        const install_url = try std.fmt.allocPrint(
            allocator,
            "/admin/sites/{s}/install",
            .{value.query.site},
        );
        try components.emptyState(output, .{
            .id = "breakdown-no-events",
            .title = "No events received yet",
            .message = "Install the tracker and accept an event before running a Breakdown.",
            .action_url = install_url,
            .action_label = "Open installation",
        });
    } else if (view.rows.len == 0) {
        try components.emptyState(output, .{
            .id = "breakdown-no-matches",
            .title = "No matching buckets",
            .message = "The site has events, but no typed dimension label matches this query and search.",
        });
    }
    if (view.cardinality > query.limit) {
        const warning = try std.fmt.allocPrint(
            allocator,
            "High-cardinality result: {d} exact matching buckets. This page is bounded to {d} rows; use search or pagination.",
            .{ view.cardinality, query.limit },
        );
        try components.feedback(output, .{ .kind = .warning, .message = warning });
    }
    try output.writeAll("<p class=\"coverage-note\">");
    try text(output, view.coverage);
    try output.writeAll("</p><p class=\"breakdown-cardinality\"><strong>Exact matching buckets:</strong> ");
    try output.print("{d}</p>", .{view.cardinality});
    try renderBreakdownTable(output, allocator, value, view, query);
    try output.writeAll("</section>");
}

fn breakdownPresetSelected(
    selected: analysis.Query,
    preset: analysis.Query,
) bool {
    return analysis.metricsEqual(selected.metric, preset.metric) and
        selected.dimension.?.kind == preset.dimension.?.kind and
        selected.dimension.?.property_ref == null and
        selected.search.len == 0 and selected.sort == .value_desc and
        selected.page == 1 and selected.limit == 25;
}

fn renderPropertyCatalog(
    output: *std.Io.Writer,
    view: model.AnalyzeBreakdown,
) !void {
    try output.print(
        "<details class=\"management property-catalog\"><summary>Observed event properties <span class=\"muted\">{d} names",
        .{view.property_count},
    );
    if (view.properties_truncated) try output.writeAll(" · first 100 shown");
    try output.writeAll("</span></summary><p class=\"muted\">Suggestions use the latest 2,000 eligible custom events in this site-local range and may update within 30 seconds. Counts are exact for that sample, not the complete result range. Each row is one observed scalar type. Repeated names are type conflicts; choose one type. Missing is selectable but is not an observed JSON type. A property outside the sample can still be entered directly.</p><div class=\"table-scroll mobile-records\"><table><caption>Sampled custom-event property types in this site-local range</caption><thead><tr><th scope=\"col\">Property</th><th scope=\"col\">Type</th><th scope=\"col\">Sample events</th></tr></thead><tbody>");
    for (view.properties) |entry| {
        try output.writeAll("<tr><th scope=\"row\" data-label=\"Property\">");
        try text(output, entry.name);
        try output.writeAll("</th><td data-label=\"Type\">");
        try text(output, humanize(entry.scalar_type.name()));
        try output.print("</td><td data-label=\"Sample events\">{d}</td></tr>", .{entry.event_count});
    }
    if (view.properties.len == 0) {
        try output.writeAll("<tr><td colspan=\"3\">No event properties were observed in this range.</td></tr>");
    }
    try output.writeAll("</tbody></table></div></details>");
}

fn renderBreakdownTable(
    output: *std.Io.Writer,
    allocator: std.mem.Allocator,
    page_value: model.Page,
    view: model.AnalyzeBreakdown,
    query: analysis.Query,
) !void {
    const values = try allocator.alloc(AnalyzeChartMeasure, view.rows.len);
    for (values, view.rows) |*target, row| {
        target.* = try analyzeChartMeasure(
            allocator,
            row.data.measure,
            query.metric.kind,
        );
    }
    const property_dimension = query.dimension.?.kind == .event_property;
    try output.writeAll("<div class=\"table-scroll mobile-records\"><table class=\"breakdown-table\"><caption>");
    try text(output, analysisMetricLabel(query.metric.kind));
    try output.writeAll(" by ");
    try text(output, dimensionLabel(query.dimension.?.kind));
    try output.writeAll(" — exact values for the selected site-local range</caption><thead><tr><th scope=\"col\">");
    try text(output, dimensionLabel(query.dimension.?.kind));
    if (property_dimension) try output.writeAll("</th><th scope=\"col\">Type");
    try output.writeAll("</th><th scope=\"col\">");
    try text(output, analysisMetricLabel(query.metric.kind));
    try output.writeAll("</th><th scope=\"col\">Actions</th></tr></thead><tbody>");
    for (view.rows, values, 0..) |row, chart_value, row_index| {
        try output.writeAll("<tr><th scope=\"row\" data-label=\"");
        try attribute(output, dimensionLabel(query.dimension.?.kind));
        try output.writeAll("\">");
        try text(output, row.data.label.value);
        try output.writeAll("</th>");
        if (property_dimension) {
            try output.writeAll("<td data-label=\"Type\">");
            try text(output, humanize(row.data.label.scalar_type.?.name()));
            try output.writeAll("</td>");
        }
        try output.writeAll("<td data-label=\"");
        try attribute(output, analysisMetricLabel(query.metric.kind));
        try output.writeAll("\"><span class=\"cell-number\">");
        try charts.writeExactTrendValue(
            output,
            chart_value.value,
            chart_value.formatted,
            metricScale(query.metric.kind),
        );
        try output.writeAll("</span>");
        const maximum = breakdownBarMaximum(view.rows, values, row_index);
        if (chart_value.value) |number| if (number >= 0 and maximum > 0) {
            try output.print(
                "<progress class=\"cell-bar\" max=\"{d}\" value=\"{d}\" aria-label=\"",
                .{ maximum, number },
            );
            try attribute(output, row.data.label.value);
            try output.writeAll(" — ");
            try attribute(output, analysisMetricLabel(query.metric.kind));
            try output.writeAll(" proportional bar\"></progress>");
        };
        try output.writeAll("</td><td data-label=\"Actions\">");
        try filterActions(
            output,
            row.filter_url,
            row.exclude_url,
            row.data.label.value,
        );
        try output.writeAll("</td></tr>");
    }
    if (view.rows.len == 0) {
        try output.print(
            "<tr><td colspan=\"{d}\">No matching buckets.</td></tr>",
            .{@as(u8, if (property_dimension) 4 else 3)},
        );
    }
    try output.writeAll("</tbody></table></div><nav aria-label=\"Breakdown pagination\">");
    if (query.page > 1) {
        try output.writeAll("<a rel=\"prev\" href=\"");
        try canonicalUrl(output, .analyze, page_value.query, query.page - 1);
        try output.writeAll("\">Previous</a>");
    }
    if (view.next_page) |next_page| {
        try output.writeAll("<a rel=\"next\" href=\"");
        try canonicalUrl(output, .analyze, page_value.query, next_page);
        try output.writeAll("\">Next</a>");
    }
    try output.writeAll("</nav>");
}

fn breakdownBarMaximum(
    rows: []const model.AnalyzeBreakdownRow,
    values: []const AnalyzeChartMeasure,
    selected: usize,
) i128 {
    const selected_currency: ?[]const u8 = switch (rows[selected].data.measure) {
        .amount => |amount| amount.currency,
        else => null,
    };
    var maximum: i128 = 0;
    for (rows, values) |row, value| {
        const comparable = if (selected_currency) |currency| switch (row.data.measure) {
            .amount => |amount| std.mem.eql(u8, currency, amount.currency),
            else => false,
        } else switch (row.data.measure) {
            .amount => false,
            else => true,
        };
        if (comparable) if (value.value) |number| {
            if (number > maximum) maximum = number;
        };
    }
    return maximum;
}

fn dimensionLabel(kind: analysis.DimensionKind) []const u8 {
    return switch (kind) {
        .page => "Page",
        .landing_page => "Landing page",
        .exit_page => "Exit page",
        .hostname => "Hostname",
        .channel => "Channel",
        .referrer => "Referrer",
        .utm_source => "UTM source",
        .utm_medium => "UTM medium",
        .utm_campaign => "UTM campaign",
        .utm_term => "UTM term",
        .utm_content => "UTM content",
        .country => "Country",
        .language => "Language",
        .device => "Device",
        .browser => "Browser",
        .operating_system => "Operating system",
        .event_name => "Event name",
        .event_property => "Event property",
    };
}

fn breakdownSortLabel(sort: analysis.Sort) []const u8 {
    return switch (sort) {
        .value_desc => "Value, high to low",
        .value_asc => "Value, low to high",
        .label_asc => "Label, A to Z",
        .label_desc => "Label, Z to A",
    };
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
            var percent_buffer: [32]u8 = undefined;
            const percent_text = if (ratio.denominator == 0)
                "unavailable"
            else
                try percentText(
                    &percent_buffer,
                    ratio.numerator,
                    ratio.denominator,
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
                    "{s} {s} / {d} values",
                    .{ amount.currency, amount.decimal, amount.value_count },
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
    try output.writeAll("\">");
    try hidden(output, "v", "1");
    try analysisContextHiddenFields(output, value);
    try output.writeAll("<label>Trend metric<select name=\"metric\">");
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
    try output.writeAll("\">View all pages</a></div><div class=\"table-scroll mobile-records\"><table><caption>Top pages</caption><thead><tr><th scope=\"col\">Page</th><th scope=\"col\">Page views</th><th scope=\"col\">Visitors</th><th scope=\"col\">Share</th><th scope=\"col\">Actions</th></tr></thead><tbody>");
    for (details.content) |row| {
        try output.writeAll("<tr><th scope=\"row\" data-label=\"Page\"><a href=\"");
        try queryUrl(output, value.query, .pages, "", 1);
        try output.writeAll("\">");
        try text(output, row.label);
        try output.print("</a></th><td data-label=\"Page views\">{d}</td><td data-label=\"Visitors\">{d}</td><td data-label=\"Share\">", .{ row.page_views, row.visitors });
        try renderBasisPoints(output, row.share_basis_points);
        try output.writeAll("</td><td data-label=\"Actions\">");
        try filterActions(output, row.filter_url, row.exclude_url, row.label);
        try output.writeAll("</td></tr>");
    }
    if (details.content.len == 0) try output.writeAll("<tr><td colspan=\"5\">No page views in this range.</td></tr>");
    try output.writeAll("</tbody></table></div></article>");

    try output.writeAll("<article class=\"answer-panel\"><div class=\"answer-heading\"><h2>Acquisition</h2><a href=\"");
    try queryUrl(output, value.query, .sources, "", 1);
    try output.writeAll("\">View all sources</a></div><div class=\"table-scroll mobile-records\"><table><caption>Top referrer sources</caption><thead><tr><th scope=\"col\">Source</th><th scope=\"col\">Sessions</th><th scope=\"col\">Conversion rate</th><th scope=\"col\">Actions</th></tr></thead><tbody>");
    for (details.acquisition) |row| {
        try output.writeAll("<tr><th scope=\"row\" data-label=\"Source\"><a href=\"");
        try queryUrl(output, value.query, .sources, "", 1);
        try output.writeAll("\">");
        try text(output, row.label);
        try output.print("</a></th><td data-label=\"Sessions\">{d}</td><td data-label=\"Conversion rate\">", .{row.sessions});
        try renderRatio(output, row.conversion);
        try output.writeAll("</td><td data-label=\"Actions\">");
        try filterActions(output, row.filter_url, row.exclude_url, row.label);
        try output.writeAll("</td></tr>");
    }
    if (details.acquisition.len == 0) try output.writeAll("<tr><td colspan=\"4\">No sessions in this range.</td></tr>");
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
    try output.writeAll("\">Devices</a></span></div><div class=\"table-scroll mobile-records\"><table><caption>Top countries</caption><thead><tr><th scope=\"col\">Country</th><th scope=\"col\">Sessions</th><th scope=\"col\">Actions</th></tr></thead><tbody>");
    for (details.audience) |row| {
        try output.writeAll("<tr><th scope=\"row\" data-label=\"Country\"><a href=\"");
        try queryUrl(output, value.query, .countries, "", 1);
        try output.writeAll("\">");
        try text(output, row.label);
        try output.print("</a></th><td data-label=\"Sessions\">{d}</td><td data-label=\"Actions\">", .{row.sessions});
        try filterActions(output, row.filter_url, row.exclude_url, row.label);
        try output.writeAll("</td></tr>");
    }
    if (details.audience.len == 0) try output.writeAll("<tr><td colspan=\"3\">No audience sessions in this range.</td></tr>");
    try output.writeAll("</tbody></table></div></article></section>");
}

fn filterActions(
    output: *std.Io.Writer,
    filter_url: []const u8,
    exclude_url: []const u8,
    label: []const u8,
) !void {
    if (filter_url.len == 0 or exclude_url.len == 0) {
        try output.writeAll("Filter limit reached");
        return;
    }
    try output.writeAll("<a href=\"");
    try attribute(output, filter_url);
    try output.writeAll("\" aria-label=\"Filter to ");
    try attribute(output, label);
    try output.writeAll("\">Filter</a> · <a href=\"");
    try attribute(output, exclude_url);
    try output.writeAll("\" aria-label=\"Exclude ");
    try attribute(output, label);
    try output.writeAll("\">Exclude</a>");
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

fn sessionSection(output: *std.Io.Writer, value: model.Page) !void {
    return switch (value.query.session_screen) {
        .list => sessionListSection(output, value),
        .detail => sessionDetailSection(output, value),
        .profile => personProfileSection(output, value),
    };
}

fn sessionListSection(output: *std.Io.Writer, value: model.Page) !void {
    const sessions = value.session_list orelse return error.MissingSessionList;
    try output.writeAll(
        "<section class=\"session-workspace\" aria-labelledby=\"session-list-heading\">" ++
            "<div class=\"analysis-heading\"><div><h2 id=\"session-list-heading\">Session list</h2>" ++
            "<p class=\"muted\">Meaningful activity in the selected site-local range, then complete retained session summaries. Newest starts appear first. Current means the latest authoritative receipt is not in the future and is no more than 30 minutes old.</p></div></div>" ++
            "<form class=\"session-goal-filter\" method=\"get\" action=\"",
    );
    try canonicalPath(output, .sessions, value.query);
    try output.writeAll("\"><input type=\"hidden\" name=\"v\" value=\"1\">");
    try calendarHiddenFields(output, value.query);
    try analysisContextHiddenFields(output, value);
    try output.writeAll(
        "<label>Goal restriction<select name=\"goal\"><option value=\"\">All sessions</option>",
    );
    for (sessions.goals) |goal| {
        try output.writeAll("<option value=\"");
        try attribute(output, goal.id);
        if (goal.selected) {
            try output.writeAll("\" selected>");
        } else try output.writeAll("\">");
        try text(output, goal.name);
        try output.writeAll("</option>");
    }
    try output.writeAll(
        "</select></label><button type=\"submit\">Apply Goal</button></form>",
    );
    if (sessions.selected_goal_name.len != 0) {
        try output.writeAll("<p class=\"analysis-focus\">Showing sessions with an in-range match for <strong>");
        try text(output, sessions.selected_goal_name);
        try output.writeAll("</strong>.</p>");
    }
    if (sessions.rows.len == 0) {
        try components.emptyState(output, .{
            .id = "sessions-empty",
            .title = "No matching sessions",
            .message = "No eligible sessions match this date range, Goal restriction, segment, and filter context.",
        });
    } else {
        try output.writeAll("<ol class=\"session-list\">");
        for (sessions.rows) |session| {
            try output.writeAll("<li>");
            try sessionRecord(output, session, true);
            try output.writeAll("</li>");
        }
        try output.writeAll("</ol>");
    }
    try output.writeAll("<nav class=\"session-pagination\" aria-label=\"Sessions pagination\">");
    if (sessions.previous_url) |url| {
        try output.writeAll("<a rel=\"prev\" href=\"");
        try attribute(output, url);
        try output.writeAll("\">Previous</a>");
    }
    if (sessions.next_url) |url| {
        try output.writeAll("<a rel=\"next\" href=\"");
        try attribute(output, url);
        try output.writeAll("\">Next</a>");
    }
    try output.writeAll("</nav></section>");
}

fn sessionDetailSection(output: *std.Io.Writer, value: model.Page) !void {
    const detail = value.session_detail orelse return error.MissingSessionDetail;
    try output.writeAll(
        "<section class=\"session-workspace session-detail-workspace\" " ++
            "aria-labelledby=\"session-detail-heading\"><div class=\"analysis-heading\"><div>" ++
            "<span class=\"eyebrow\">Session detail</span><h2 id=\"session-detail-heading\">Session ",
    );
    try text(output, detail.summary.short_id);
    try output.writeAll("</h2><p class=\"muted\">Chronological retained activity. Late accepted events may change this derived view.</p></div><a href=\"");
    try attribute(output, detail.back_url);
    try output.writeAll("\">Back to Sessions</a></div><div class=\"session-detail-layout\"><div><h3>Summary</h3>");
    try sessionRecord(output, detail.summary, false);
    if (detail.profile_url) |url| {
        try output.writeAll("<p><a class=\"button button-secondary\" href=\"");
        try attribute(output, url);
        try output.writeAll("\">Open compatible profile</a></p>");
    }
    try output.writeAll("</div><div><h3>Timeline</h3>");
    if (detail.timeline.len == 0) {
        try components.emptyState(output, .{
            .id = "session-timeline-empty",
            .title = "No entries on this page",
            .message = "This bounded timeline page has no retained entries.",
        });
    } else {
        try output.writeAll("<ol class=\"session-timeline\">");
        for (detail.timeline) |entry| {
            try output.writeAll("<li><article><header><span class=\"eyebrow\">");
            try text(output, entry.kind);
            try output.writeAll("</span><h4>");
            try text(output, entry.title);
            try output.writeAll("</h4><time>");
            try text(output, entry.occurred_at);
            try output.writeAll("</time></header><dl class=\"session-facts\">");
            if (entry.path.len != 0) try sessionFact(output, "Path", entry.path);
            if (!std.mem.eql(u8, entry.properties_json, "{}")) {
                try sessionFact(output, "Properties", entry.properties_json);
            }
            if (entry.user_id.len != 0) try sessionFact(output, "User ID", entry.user_id);
            if (!std.mem.eql(u8, entry.user_traits_json, "{}")) {
                try sessionFact(output, "Traits", entry.user_traits_json);
            }
            if (entry.value.len != 0) try sessionFact(output, "Exact value", entry.value);
            if (entry.engagement.len != 0) {
                try sessionFact(output, "Active engagement", entry.engagement);
                try output.print(
                    "<div><dt>Maximum scroll depth</dt><dd>{d}%</dd></div>" ++
                        "<div><dt>Transport fragments combined</dt><dd>{d}</dd></div>",
                    .{ entry.max_scroll_depth, entry.engagement_fragments },
                );
            }
            if (entry.goal_names.len != 0) {
                try output.writeAll("<div><dt>Goal matches</dt><dd><ul>");
                for (entry.goal_names) |name| {
                    try output.writeAll("<li>");
                    try text(output, name);
                    try output.writeAll("</li>");
                }
                try output.writeAll("</ul></dd></div>");
            }
            try output.writeAll("</dl></article></li>");
        }
        try output.writeAll("</ol>");
    }
    try sessionPagination(
        output,
        "Session timeline pagination",
        detail.previous_timeline_url,
        detail.next_timeline_url,
    );
    try output.writeAll("</div></div></section>");
}

fn personProfileSection(output: *std.Io.Writer, value: model.Page) !void {
    const profile = value.person_profile orelse return error.MissingPersonProfile;
    try output.writeAll(
        "<section class=\"session-workspace person-profile\" aria-labelledby=\"person-profile-heading\">" ++
            "<div class=\"analysis-heading\"><div><span class=\"eyebrow\">Compatible profile</span>" ++
            "<h2 id=\"person-profile-heading\">",
    );
    try text(output, profile.identity);
    try output.writeAll("</h2><p class=\"muted\">");
    try text(output, profile.identity_state);
    try output.writeAll(". Derived from retained product-eligible events; retention may remove older activity. Rejected identity conflicts are not merged.</p></div><a href=\"");
    try attribute(output, profile.back_url);
    try output.writeAll("\">Back to Sessions</a></div><section aria-labelledby=\"retained-history-heading\"><h3 id=\"retained-history-heading\">Retained history</h3><dl class=\"session-facts\">");
    try sessionFact(output, "First seen", profile.first_seen);
    try sessionFact(output, "Last seen", profile.last_seen);
    try sessionFact(output, "Active engagement", profile.engagement);
    try output.print(
        "<div><dt>Sessions</dt><dd>{d}</dd></div>" ++
            "<div><dt>Conversions (current active Goals)</dt><dd>{d}</dd></div>" ++
            "<div><dt>Explicitly linked anonymous identities</dt><dd>{d}</dd></div>",
        .{ profile.sessions, profile.conversions, profile.linked_anonymous_ids },
    );
    if (!std.mem.eql(u8, profile.latest_traits_json, "{}")) {
        try sessionFact(output, "Latest identify traits", profile.latest_traits_json);
    }
    try output.writeAll("<div><dt>Exact revenue</dt><dd>");
    try sessionRevenue(output, profile.revenue);
    try output.writeAll("</dd></div></dl></section><section aria-labelledby=\"context-sessions-heading\"><h3 id=\"context-sessions-heading\">Sessions matching this context</h3>");
    if (profile.related_sessions.selected_goal_name.len != 0) {
        try output.writeAll("<p class=\"analysis-focus\">Restricted to <strong>");
        try text(output, profile.related_sessions.selected_goal_name);
        try output.writeAll("</strong>.</p>");
    }
    if (profile.related_sessions.rows.len == 0) {
        try components.emptyState(output, .{
            .id = "profile-sessions-empty",
            .title = "No sessions match this context",
            .message = "The retained profile exists, but no related session matches the selected range, Goal, segment, filters, and traffic policy.",
        });
    } else {
        try output.writeAll("<ol class=\"session-list\">");
        for (profile.related_sessions.rows) |session| {
            try output.writeAll("<li>");
            try sessionRecord(output, session, true);
            try output.writeAll("</li>");
        }
        try output.writeAll("</ol>");
    }
    try sessionPagination(
        output,
        "Profile sessions pagination",
        profile.related_sessions.previous_url,
        profile.related_sessions.next_url,
    );
    try output.writeAll("</section></section>");
}

fn sessionRecord(
    output: *std.Io.Writer,
    session: model.SessionRecord,
    linked_heading: bool,
) !void {
    try output.writeAll("<article class=\"session-record\"><header><div><span class=\"eyebrow\">Session</span><h3>");
    if (linked_heading) {
        try output.writeAll("<a href=\"");
        try attribute(output, session.detail_url);
        try output.writeAll("\">");
    }
    try text(output, session.short_id);
    if (linked_heading) try output.writeAll("</a>");
    try output.writeAll("</h3></div><strong class=\"session-status\">");
    try output.writeAll(if (session.current)
        "Current · activity received within 30 minutes; activity may be incomplete"
    else
        "Ended");
    try output.writeAll("</strong></header><dl class=\"session-facts\">");
    try sessionFact(output, "Identity", session.identity);
    try sessionFact(output, "Identity state", session.identity_state);
    try sessionFact(output, "Started", session.started_at);
    try sessionFact(output, "Last activity", session.last_activity);
    try sessionFact(output, "Last received", session.last_received);
    try sessionFact(output, "Landing page", session.landing_page);
    try sessionFact(output, "Acquisition", session.acquisition);
    try sessionFact(output, "Country", session.country);
    try sessionFact(output, "Device and browser", session.client);
    try sessionFact(output, "Duration", session.duration);
    try sessionFact(output, "Active engagement", session.engagement);
    try output.print(
        "<div><dt>Page views</dt><dd>{d}</dd></div>" ++
            "<div><dt>Custom events</dt><dd>{d}</dd></div>" ++
            "<div><dt>Conversions (Goal matches)</dt><dd>{d}</dd></div>",
        .{ session.page_views, session.custom_events, session.conversions },
    );
    try output.writeAll("<div><dt>Exact revenue</dt><dd>");
    try sessionRevenue(output, session.revenue);
    try output.writeAll("</dd></div></dl></article>");
}

fn sessionRevenue(
    output: *std.Io.Writer,
    revenue: []const model.SessionRevenue,
) !void {
    if (revenue.len == 0) return output.writeAll("None");
    try output.writeAll("<ul class=\"session-revenue\">");
    for (revenue) |amount| {
        try output.writeAll("<li>");
        try text(output, amount.amount);
        try output.print(
            " · {d} {s}</li>",
            .{ amount.value_count, if (amount.value_count == 1) "value" else "values" },
        );
    }
    try output.writeAll("</ul>");
}

fn sessionPagination(
    output: *std.Io.Writer,
    label: []const u8,
    previous_url: ?[]const u8,
    next_url: ?[]const u8,
) !void {
    try output.writeAll("<nav class=\"session-pagination\" aria-label=\"");
    try attribute(output, label);
    try output.writeAll("\">");
    if (previous_url) |url| {
        try output.writeAll("<a rel=\"prev\" href=\"");
        try attribute(output, url);
        try output.writeAll("\">Previous</a>");
    }
    if (next_url) |url| {
        try output.writeAll("<a rel=\"next\" href=\"");
        try attribute(output, url);
        try output.writeAll("\">Next</a>");
    }
    try output.writeAll("</nav>");
}

fn sessionFact(
    output: *std.Io.Writer,
    label: []const u8,
    value: []const u8,
) !void {
    try output.writeAll("<div><dt>");
    try text(output, label);
    try output.writeAll("</dt><dd>");
    try text(output, value);
    try output.writeAll("</dd></div>");
}

fn journeyNavigation(output: *std.Io.Writer, value: model.Page) !void {
    try output.writeAll("<div class=\"report-navigation\"><nav class=\"report-tabs\" aria-label=\"Journey type\">");
    try journeyTypeLink(output, value.query, .goal, "Goals");
    try journeyTypeLink(output, value.query, .funnel, "Funnels");
    try output.writeAll("</nav>");
    const show_legacy_goals = value.goal_management == null;
    const show_legacy_funnels = value.funnel_management == null;
    var legacy_funnel_count: usize = 0;
    if (show_legacy_funnels) for (value.funnels) |funnel| {
        legacy_funnel_count += @intFromBool(legacyFunnelCompatible(funnel));
    };
    if ((show_legacy_goals and value.goals.len != 0) or
        legacy_funnel_count != 0)
    {
        try output.writeAll("<div class=\"conversion-navigation\"><span class=\"eyebrow\">Definitions</span><nav aria-label=\"Journey definitions\">");
    }
    if (show_legacy_goals) {
        for (value.goals) |goal| {
            try reportLink(output, value.query, .goal, goal.name, goal.name);
        }
    }
    if (show_legacy_funnels) for (value.funnels) |funnel| {
        if (legacyFunnelCompatible(funnel)) {
            try reportLink(output, value.query, .funnel, funnel.name, funnel.name);
        }
    };
    if ((show_legacy_goals and value.goals.len != 0) or
        legacy_funnel_count != 0)
    {
        try output.writeAll("</nav></div>");
    }
    try output.writeAll("</div>");
}

fn legacyFunnelCompatible(value: meta.Funnel) bool {
    if (value.archived_at_utc_micros != null or
        value.definition.order != .sequential or
        value.definition.scope != .sessions or
        value.definition.window != .same_session)
    {
        return false;
    }
    for (value.definition.steps) |step| switch (step) {
        .goal => return false,
        .direct => |direct| if (direct.selector.predicates.len != 0) return false,
    };
    return true;
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
                    .count = try nonnegative(step.sessions),
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

fn funnelBuilder(
    output: *std.Io.Writer,
    value: model.Page,
    management: model.FunnelManagement,
) !void {
    const selected = management.selected;
    const has_draft = value.funnel_draft.steps.len != 0;
    const name = if (has_draft)
        value.funnel_draft.name
    else if (selected) |definition|
        definition.name
    else
        "";
    const order = if (has_draft)
        value.funnel_draft.order
    else if (selected) |definition|
        definition.order
    else
        funnel_domain.Order.sequential;
    const scope = if (has_draft)
        value.funnel_draft.scope
    else if (selected) |definition|
        definition.scope
    else
        funnel_domain.Scope.sessions;
    const window = if (has_draft)
        value.funnel_draft.window
    else if (selected) |definition|
        definition.window
    else
        funnel_domain.Window.same_session;
    const steps = management.draft_steps;

    try output.writeAll("<section class=\"panel\"><h2>");
    try output.writeAll(if (management.screen == .edit) "Edit funnel" else "New funnel");
    try output.writeAll(
        "</h2><p>Compose two through eight ordered Page, Event, or Goal steps. " ++
            "Preview reports each selector's independent event availability; " ++
            "the ordered conversion result appears below the form.</p>" ++
            "<form class=\"funnel-builder\" method=\"post\" action=\"",
    );
    try attribute(output, if (management.screen == .edit)
        management.edit_action_url
    else
        management.create_action_url);
    try output.writeAll("\" hx-boost=\"true\" hx-sync=\"this:drop\">");
    try formCommon(output, value);
    if (selected) |definition| try funnelIdentityFields(output, definition);
    try output.print("<input type=\"hidden\" name=\"step_count\" value=\"{d}\">", .{steps.len});
    try output.writeAll("<label>Name<input name=\"name\" maxlength=\"120\" required");
    try formErrorAttributes(output, value, .funnel);
    try output.writeAll(" value=\"");
    try attribute(output, name);
    try output.writeAll("\"></label><div class=\"funnel-settings\"><label>Order<select name=\"order\">");
    try selectedOption(output, "sequential", "Sequential", order == .sequential);
    try selectedOption(output, "consecutive", "Consecutive tracked events", order == .consecutive);
    try output.writeAll("</select></label><label>Scope<select name=\"scope\">");
    try selectedOption(output, "sessions", "Sessions", scope == .sessions);
    try selectedOption(output, "visitors", "Visitors", scope == .visitors);
    try output.writeAll("</select></label><label>Conversion window<select name=\"window_seconds\">");
    inline for (.{
        .{ funnel_domain.Window.same_session, "Same session" },
        .{ funnel_domain.Window.one_hour, "1 hour" },
        .{ funnel_domain.Window.one_day, "1 day" },
        .{ funnel_domain.Window.seven_days, "7 days" },
        .{ funnel_domain.Window.thirty_days, "30 days" },
    }) |option| {
        var seconds: [16]u8 = undefined;
        try selectedOption(
            output,
            try std.fmt.bufPrint(&seconds, "{d}", .{option[0].seconds()}),
            option[1],
            window == option[0],
        );
    }
    try output.writeAll(
        "</select></label></div><p class=\"muted\">Consecutive checks the next" ++
            " qualifying tracked Page/Event. Visitor scope and cross-session" ++
            " windows require compatible persistent identity.</p>" ++
            "<ol class=\"funnel-steps\">",
    );
    for (steps) |step| try funnelStepEditor(
        output,
        step,
        management.goals,
        steps.len,
    );
    try output.writeAll("</ol><div class=\"management-actions\">");
    if (steps.len < funnel_domain.maximum_steps) {
        try output.writeAll("<button class=\"button-secondary\" type=\"submit\" formnovalidate name=\"intent\" value=\"add-step\">Add step</button>");
    }
    try output.writeAll(
        "<button class=\"button-secondary\" type=\"submit\" name=\"intent\"" ++
            " formnovalidate value=\"refresh\">Update step controls</button>" ++
            "<button class=\"button-secondary\" type=\"submit\" name=\"intent\"" ++
            " value=\"preview\">Preview funnel</button>" ++
            "<button type=\"submit\" name=\"intent\" value=\"save\">" ++
            "Save funnel</button></div></form></section>",
    );
    if (management.result) |result| {
        try orderedFunnelResult(output, value, steps, order, scope, result);
    }
}

fn funnelStepEditor(
    output: *std.Io.Writer,
    step: model.FunnelStepView,
    goals: []const model.GoalDefinitionView,
    step_count: usize,
) !void {
    const one_based = step.index + 1;
    try output.print("<li><fieldset class=\"funnel-step\"><legend>Step {d}</legend><div class=\"funnel-step-heading\"><strong>", .{one_based});
    try text(output, step.label);
    try output.writeAll("</strong><span class=\"management-actions\">");
    if (step.index != 0) {
        try output.print("<button class=\"button-secondary\" type=\"submit\" formnovalidate name=\"intent\" value=\"move-up-{d}\">Move up</button>", .{one_based});
    }
    if (step.index + 1 < step_count) {
        try output.print("<button class=\"button-secondary\" type=\"submit\" formnovalidate name=\"intent\" value=\"move-down-{d}\">Move down</button>", .{one_based});
    }
    if (step_count > funnel_domain.minimum_steps) {
        try output.print("<button class=\"button-secondary\" type=\"submit\" formnovalidate name=\"intent\" value=\"remove-step-{d}\">Remove</button>", .{one_based});
    }
    try output.print("</span></div><label>Step type<select name=\"step_kind_{d}\">", .{one_based});
    try selectedOption(output, "page", "Page equals", step.draft.kind == .exact_page);
    try selectedOption(output, "page-prefix", "Page starts with", step.draft.kind == .page_prefix);
    try selectedOption(output, "event", "Custom event equals", step.draft.kind == .exact_event);
    try selectedOption(output, "goal", "Saved goal", step.draft.kind == .saved_goal);
    try output.writeAll("</select></label>");
    if (step.draft.kind == .saved_goal) {
        try funnelGoalSelect(output, step, goals, one_based);
    } else {
        try funnelDirectFields(output, step, one_based);
    }
    if (step.stale) try components.feedback(output, .{
        .kind = .warning,
        .message = "This Goal reference is archived or unavailable. Preview and save are blocked until it is replaced or reactivated.",
    });
    if (step.matching_events) |count| {
        if (count < 0) return error.InvalidFunnelAvailability;
        try output.print("<p class=\"selector-availability\"><strong>Selector availability:</strong> {d} matching event(s).", .{count});
        if (count == 0) {
            try output.writeAll(" <span class=\"status-text\">Zero matches in this context.</span>");
        }
        try output.writeAll(" This is not funnel progression.</p>");
    }
    try output.writeAll("</fieldset></li>");
}

fn funnelGoalSelect(
    output: *std.Io.Writer,
    step: model.FunnelStepView,
    goals: []const model.GoalDefinitionView,
    one_based: usize,
) !void {
    try output.print("<label>Goal<select name=\"step_goal_{d}\">", .{one_based});
    if (step.stale) {
        try output.writeAll("<option value=\"");
        try attribute(output, step.draft.goal_id);
        try output.writeAll("\" selected>Unavailable or archived goal · ");
        try text(output, step.draft.goal_id);
        try output.writeAll("</option>");
    }
    for (goals) |goal| {
        try output.writeAll("<option value=\"");
        try attribute(output, goal.id);
        try output.writeAll("\"");
        if (std.mem.eql(u8, goal.id, step.draft.goal_id)) {
            try output.writeAll(" selected");
        }
        try output.writeAll(">");
        try text(output, goal.name);
        try output.writeAll("</option>");
    }
    try output.writeAll("</select></label>");
}

fn funnelDirectFields(
    output: *std.Io.Writer,
    step: model.FunnelStepView,
    one_based: usize,
) !void {
    try output.print("<label>Exact value<input name=\"step_value_{d}\" maxlength=\"1024\" required value=\"", .{one_based});
    try attribute(output, step.draft.value);
    try output.writeAll("\"></label><fieldset class=\"predicate-builder\"><legend>Optional event properties</legend>");
    for (0..analysis.maximum_selector_predicates) |predicate_index| {
        const predicate = if (predicate_index < step.draft.predicates.len)
            step.draft.predicates[predicate_index]
        else
            model.GoalPredicateDraft{};
        const predicate_one_based = predicate_index + 1;
        try output.print("<div class=\"predicate-row\"><label>Property {d}<input name=\"step_property_{d}_{d}\" maxlength=\"120\" value=\"", .{ predicate_one_based, one_based, predicate_one_based });
        try attribute(output, predicate.property_name);
        try output.print("\"></label><label>Type and rule<select name=\"step_rule_{d}_{d}\">", .{ one_based, predicate_one_based });
        try goalRuleOptions(output, predicate.rule, null);
        try output.print("</select></label><label>Value<input name=\"step_predicate_value_{d}_{d}\" maxlength=\"1024\" value=\"", .{ one_based, predicate_one_based });
        try attribute(output, predicate.value);
        try output.writeAll("\"></label></div>");
    }
    try output.writeAll("</fieldset>");
}

fn funnelDetail(
    output: *std.Io.Writer,
    value: model.Page,
    management: model.FunnelManagement,
) !void {
    const definition = management.selected.?;
    try output.writeAll("<section class=\"panel\"><div class=\"split-heading\"><div><h2>");
    try text(output, definition.name);
    try output.writeAll("</h2><p><strong>");
    try output.writeAll(if (definition.archived) "Archived" else "Active");
    try output.writeAll("</strong> · ");
    try text(output, @tagName(definition.order));
    try output.writeAll(" · ");
    try text(output, @tagName(definition.scope));
    try output.writeAll(" · ");
    try text(output, funnelWindowLabel(definition.window));
    try output.writeAll("</p></div><a class=\"button-secondary\" href=\"");
    try attribute(output, definition.edit_url);
    try output.writeAll("\">Edit funnel</a></div><dl class=\"definition-grid\"><div><dt>Created</dt><dd>");
    try text(output, definition.created_at);
    try output.writeAll("</dd></div><div><dt>Updated</dt><dd>");
    try text(output, definition.updated_at);
    try output.writeAll("</dd></div></dl><ol class=\"definition-list\">");
    var stale = false;
    for (definition.steps) |step| {
        stale = stale or step.stale;
        try output.writeAll("<li><strong>");
        try text(output, step.label);
        try output.writeAll("</strong>");
        if (step.stale) try output.writeAll(" · stale Goal reference");
        if (step.draft.predicates.len != 0) {
            try output.writeAll("<ul class=\"definition-list\" aria-label=\"Step predicates\">");
            for (step.draft.predicates) |predicate| {
                try output.writeAll("<li><code>");
                try text(output, predicate.property_name);
                try output.writeAll("</code> · ");
                try text(output, predicate.rule);
                if (predicate.value.len != 0) {
                    try output.writeAll(" · <code>");
                    try text(output, predicate.value);
                    try output.writeAll("</code>");
                }
                try output.writeAll("</li>");
            }
            try output.writeAll("</ul>");
        }
        try output.writeAll("</li>");
    }
    try output.writeAll("</ol>");
    if (stale) try components.feedback(output, .{
        .kind = .warning,
        .message = "This funnel has an archived or unavailable Goal reference. Edit the step or reactivate the goal before previewing or running it.",
    });
    try output.writeAll("<form method=\"post\" action=\"");
    try output.writeAll(if (definition.archived)
        "/admin/funnels/reactivate"
    else
        "/admin/funnels/archive");
    try attribute(output, management.action_suffix);
    try output.writeAll("\" hx-boost=\"true\" hx-sync=\"this:drop\">");
    try formCommon(output, value);
    try funnelIdentityFields(output, definition);
    try output.writeAll("<button class=\"button-secondary\" type=\"submit\">");
    try output.writeAll(if (definition.archived) "Reactivate" else "Archive");
    try output.writeAll("</button></form></section>");
    if (management.result) |result| {
        try orderedFunnelResult(
            output,
            value,
            definition.steps,
            definition.order,
            definition.scope,
            result,
        );
    }
}

fn orderedFunnelResult(
    output: *std.Io.Writer,
    value: model.Page,
    step_views: []const model.FunnelStepView,
    order: funnel_domain.Order,
    scope: funnel_domain.Scope,
    result: funnel_domain.Result,
) !void {
    if (result.current.steps.len != step_views.len or
        (result.comparison != null and
            result.comparison.?.steps.len != step_views.len))
    {
        return error.InvalidFunnelResult;
    }
    var chart_steps: [funnel_domain.maximum_steps]charts.FunnelStep = undefined;
    for (chart_steps[0..step_views.len], step_views, result.current.steps, 0..) |*target, step_view, step, index| {
        if (step.step_index != index) return error.InvalidFunnelResult;
        const comparison_step = if (result.comparison) |comparison|
            comparison.steps[index]
        else
            null;
        if (comparison_step) |candidate| {
            if (candidate.step_index != index) return error.InvalidFunnelResult;
        }
        target.* = .{
            .name = step_view.label,
            .count = try nonnegative(step.participants),
            .median_from_prior_micros = if (step.median_from_prior_micros) |micros|
                try nonnegative(micros)
            else
                null,
            .comparison_count = if (comparison_step) |candidate|
                try nonnegative(candidate.participants)
            else
                null,
            .comparison_median_from_prior_micros = if (comparison_step) |candidate|
                if (candidate.median_from_prior_micros) |micros|
                    try nonnegative(micros)
                else
                    null
            else
                null,
        };
    }
    const count_label = if (scope == .sessions)
        "Sessions"
    else
        "Persistent visitors";
    try output.writeAll("<section class=\"panel funnel-ordered-result\">" ++
        "<h2>Ordered funnel result</h2><p class=\"muted\">Current ");
    try text(output, value.query.range.start);
    try output.writeAll(" through ");
    try text(output, value.query.range.end);
    try output.writeAll(" · ");
    try text(output, count_label);
    try output.writeAll(" · ");
    try text(output, @tagName(order));
    try output.writeAll("</p>");
    if (order == .consecutive) try components.feedback(output, .{
        .kind = .notice,
        .message = "Consecutive mode stops an attempt when the next meaningful Page/Event does not match; identify and engagement events are ignored.",
    });
    if (result.current.entrants == 0) {
        try components.feedback(output, .{
            .kind = .notice,
            .message = "No entrants matched step one in the current range and filters.",
        });
    } else if (result.current.completions == 0) {
        try components.feedback(output, .{
            .kind = .notice,
            .message = "Entrants matched step one, but none completed every step in scope and window.",
        });
    }
    try output.writeAll("<ul class=\"metrics\">");
    try metric(output, "Entrants", result.current.entrants);
    try metric(output, "Completions", result.current.completions);
    try ratioKpi(
        output,
        "Overall conversion rate",
        result.current.completions,
        result.current.entrants,
    );
    try funnelDurationKpi(
        output,
        "Median total time",
        result.current.median_total_micros,
    );
    try output.writeAll("</ul>");
    if (result.comparison) |comparison| {
        const comparison_range = value.calendar_context.?.comparison_range orelse
            return error.MissingComparisonResolution;
        try output.writeAll("<h3>Comparison summary · ");
        try text(output, comparison_range.start[0..]);
        try output.writeAll(" through ");
        try text(output, comparison_range.end[0..]);
        try output.writeAll("</h3><ul class=\"metrics\">");
        try metric(output, "Comparison entrants", comparison.entrants);
        try metric(output, "Comparison completions", comparison.completions);
        try ratioKpi(
            output,
            "Comparison conversion rate",
            comparison.completions,
            comparison.entrants,
        );
        try funnelDurationKpi(
            output,
            "Comparison median total time",
            comparison.median_total_micros,
        );
        try output.writeAll("</ul>");
    }
    if (result.current.identity_coverage) |coverage| {
        try output.print(
            "<p class=\"funnel-identity-coverage\">Persistent visitor" ++
                " step-one identities: <strong>{d}</strong>. Excluded" ++
                " ephemeral identities: <strong>{d}</strong>. Excluded" ++
                " legacy-daily identities: <strong>{d}</strong>.</p>",
            .{
                coverage.persistent_step_one,
                coverage.ephemeral_step_one,
                coverage.legacy_step_one,
            },
        );
    }
    if (result.comparison) |comparison| {
        if (comparison.identity_coverage) |coverage| {
            try output.print(
                "<p class=\"funnel-identity-coverage\">Comparison persistent" ++
                    " visitor step-one identities: <strong>{d}</strong>." ++
                    " Excluded comparison ephemeral identities:" ++
                    " <strong>{d}</strong>. Excluded comparison legacy-daily" ++
                    " identities: <strong>{d}</strong>.</p>",
                .{
                    coverage.persistent_step_one,
                    coverage.ephemeral_step_one,
                    coverage.legacy_step_one,
                },
            );
        }
    }
    try charts.renderFunnel(output, .{
        .id = "ordered-funnel-result",
        .title = "Ordered funnel progression",
        .summary = if (result.comparison == null)
            "Current participants reaching each ordered step. Exact counts, rates, drop-off, and timing follow."
        else
            "Current filled bars and neutral outlined comparison bars show participants reaching each ordered step. Exact values follow.",
        .count_label = count_label,
        .entrants = try nonnegative(result.current.entrants),
        .comparison_entrants = if (result.comparison) |comparison|
            try nonnegative(comparison.entrants)
        else
            null,
        .steps = chart_steps[0..step_views.len],
    });
    try output.writeAll("</section>");
}

fn funnelDurationKpi(
    output: *std.Io.Writer,
    label: []const u8,
    micros: ?i64,
) !void {
    try output.writeAll("<li class=\"kpi\"><span>");
    try text(output, label);
    try output.writeAll("</span><strong>");
    if (micros) |value| {
        const raw = try nonnegative(value);
        try output.print("<span class=\"chart-raw-value\">{d} µs</span> ", .{raw});
        try output.writeAll("<span class=\"chart-formatted-value\">(");
        try charts.formattedDurationMicros(output, raw);
        try output.writeAll(")</span>");
    } else {
        try output.writeAll("Unavailable");
    }
    try output.writeAll("</strong></li>");
}

fn funnelIdentityFields(
    output: *std.Io.Writer,
    definition: model.FunnelDefinitionView,
) !void {
    try output.writeAll("<input type=\"hidden\" name=\"id\" value=\"");
    try attribute(output, definition.id);
    try output.print("\"><input type=\"hidden\" name=\"updated_at\" value=\"{d}\">", .{definition.updated_at_utc_micros});
}

fn selectedOption(
    output: *std.Io.Writer,
    value: []const u8,
    label: []const u8,
    selected: bool,
) !void {
    try output.writeAll("<option value=\"");
    try attribute(output, value);
    try output.writeAll("\"");
    if (selected) try output.writeAll(" selected");
    try output.writeAll(">");
    try text(output, label);
    try output.writeAll("</option>");
}

fn funnelWindowLabel(window: funnel_domain.Window) []const u8 {
    return switch (window) {
        .same_session => "same session",
        .one_hour => "1 hour",
        .one_day => "1 day",
        .seven_days => "7 days",
        .thirty_days => "30 days",
    };
}

fn funnelManagement(output: *std.Io.Writer, value: model.Page) !void {
    const management = value.funnel_management.?;
    try output.writeAll(
        "<nav class=\"management-actions\" aria-label=\"Funnel management\">" ++
            "<a href=\"",
    );
    try attribute(output, management.list_url);
    try output.writeAll("\"");
    if (management.screen == .list) try output.writeAll(" aria-current=\"page\"");
    try output.writeAll(">All funnels</a><a class=\"button\" href=\"");
    try attribute(output, management.new_url);
    try output.writeAll("\"");
    if (management.screen == .new) try output.writeAll(" aria-current=\"page\"");
    try output.writeAll(">New funnel</a></nav>");
    if (management.filter_count != 0 or management.segment_name.len != 0) {
        try output.writeAll("<p class=\"muted\">Selector availability uses ");
        if (management.segment_name.len != 0) {
            try output.writeAll("segment <strong>");
            try text(output, management.segment_name);
            try output.writeAll("</strong>");
            if (management.filter_count != 0) try output.writeAll(" plus ");
        }
        if (management.filter_count != 0) {
            try output.print("{d} ad-hoc filter(s)", .{management.filter_count});
        }
        try output.writeAll(" from the current analysis context.</p>");
    }
    switch (management.screen) {
        .list => try funnelList(output, management),
        .new, .edit => try funnelBuilder(output, value, management),
        .detail => try funnelDetail(output, value, management),
        .none => unreachable,
    }
}

fn funnelList(
    output: *std.Io.Writer,
    management: model.FunnelManagement,
) !void {
    try output.writeAll("<section class=\"panel\"><h2>Funnels</h2>");
    if (management.definitions.len == 0) {
        try components.emptyState(output, .{
            .id = "funnels-empty",
            .title = "No funnels yet",
            .message = "Build a two-to-eight-step Page, Event, or Goal sequence without writing selector syntax.",
        });
    } else {
        try output.writeAll(
            "<div class=\"table-scroll mobile-records\"><table>" ++
                "<caption>Funnel definitions</caption><thead><tr>" ++
                "<th scope=\"col\">Funnel</th><th scope=\"col\">State</th>" ++
                "<th scope=\"col\">Steps</th><th scope=\"col\">Settings</th>" ++
                "<th scope=\"col\">Updated</th></tr></thead><tbody>",
        );
        for (management.definitions) |definition| {
            try output.writeAll("<tr><th scope=\"row\" data-label=\"Funnel\"><a href=\"");
            try attribute(output, definition.detail_url);
            try output.writeAll("\">");
            try text(output, definition.name);
            try output.writeAll("</a></th><td data-label=\"State\">");
            try output.writeAll(if (definition.archived) "Archived" else "Active");
            try output.print("</td><td data-label=\"Steps\">{d}</td><td data-label=\"Settings\">", .{definition.steps.len});
            try text(output, @tagName(definition.order));
            try output.writeAll(" · ");
            try text(output, @tagName(definition.scope));
            try output.writeAll(" · ");
            try text(output, funnelWindowLabel(definition.window));
            try output.writeAll("</td><td data-label=\"Updated\">");
            try text(output, definition.updated_at);
            try output.writeAll("</td></tr>");
        }
        try output.writeAll("</tbody></table></div><nav aria-label=\"Funnel pages\">");
        if (management.previous_definitions_url) |previous| {
            try output.writeAll("<a rel=\"prev\" href=\"");
            try attribute(output, previous);
            try output.writeAll("\">Previous</a>");
        }
        if (management.next_definitions_url) |next| {
            try output.writeAll("<a rel=\"next\" href=\"");
            try attribute(output, next);
            try output.writeAll("\">Next</a>");
        }
        try output.writeAll("</nav>");
    }
    try output.writeAll("</section>");
}

fn goalManagement(output: *std.Io.Writer, value: model.Page) !void {
    const management = value.goal_management.?;
    try output.writeAll(
        "<nav class=\"management-actions\" aria-label=\"Goal management\">" ++
            "<a href=\"",
    );
    try attribute(output, management.list_url);
    try output.writeAll("\"");
    if (management.screen == .list) try output.writeAll(" aria-current=\"page\"");
    try output.writeAll(">All goals</a><a class=\"button\" href=\"");
    try attribute(output, management.new_url);
    try output.writeAll("\"");
    if (management.screen == .new) try output.writeAll(" aria-current=\"page\"");
    try output.writeAll(">New goal</a></nav>");
    if (management.filter_count != 0 or management.segment_name.len != 0) {
        try output.writeAll("<p class=\"muted\">Goal results use ");
        if (management.segment_name.len != 0) {
            try output.writeAll("segment <strong>");
            try text(output, management.segment_name);
            try output.writeAll("</strong>");
            if (management.filter_count != 0) try output.writeAll(" plus ");
        }
        if (management.filter_count != 0) {
            try output.print("{d} ad-hoc filter(s)", .{management.filter_count});
        }
        try output.writeAll(" from the current analysis context.</p>");
    }

    switch (management.screen) {
        .list => {
            try output.writeAll("<section class=\"panel\"><h2>Goals</h2><p>");
            try output.print("{d} of 32 active goals", .{management.active_count});
            try output.writeAll(". Archived goals remain explicitly reportable.</p>");
            if (management.active_count > analysis.maximum_active_goals) {
                try components.feedback(output, .{
                    .kind = .warning,
                    .message = "This migrated site is above the active-goal bound. Archive goals until 32 or fewer remain; no definition was truncated.",
                });
            }
            if (management.definitions.len == 0) {
                try components.emptyState(output, .{
                    .id = "goals-empty",
                    .title = "No goals yet",
                    .message = "Create a Page or Event goal from observed values, or explicitly confirm a value that has not fired yet.",
                });
            } else {
                try output.writeAll(
                    "<div class=\"table-scroll mobile-records\"><table>" ++
                        "<caption>Goal definitions</caption><thead><tr>" ++
                        "<th scope=\"col\">Goal</th><th scope=\"col\">State</th>" ++
                        "<th scope=\"col\">Selector</th><th scope=\"col\">Updated</th>" ++
                        "</tr></thead><tbody>",
                );
                for (management.definitions) |goal| {
                    try output.writeAll("<tr><th scope=\"row\" data-label=\"Goal\"><a href=\"");
                    try attribute(output, goal.detail_url);
                    try output.writeAll("\">");
                    try text(output, goal.name);
                    try output.writeAll("</a></th><td data-label=\"State\">");
                    try output.writeAll(if (goal.archived) "Archived" else "Active");
                    try output.writeAll("</td><td data-label=\"Selector\">");
                    try output.writeAll(goalSelectorLabel(goal));
                    try output.writeAll(" <code>");
                    try text(output, goal.match_value);
                    try output.writeAll("</code></td><td data-label=\"Updated\">");
                    try text(output, goal.updated_at);
                    try output.writeAll("</td></tr>");
                }
                try output.writeAll("</tbody></table></div><nav aria-label=\"Goal pages\">");
                if (management.previous_definitions_url) |previous| {
                    try output.writeAll("<a rel=\"prev\" href=\"");
                    try attribute(output, previous);
                    try output.writeAll("\">Previous</a>");
                }
                if (management.next_definitions_url) |next| {
                    try output.writeAll("<a rel=\"next\" href=\"");
                    try attribute(output, next);
                    try output.writeAll("\">Next</a>");
                }
                try output.writeAll("</nav>");
            }
            try output.writeAll("</section>");
        },
        .new, .edit => try goalBuilder(output, value, management),
        .detail => try goalDetail(output, value, management),
        .none => unreachable,
    }
}

fn goalBuilder(
    output: *std.Io.Writer,
    value: model.Page,
    management: model.GoalManagement,
) !void {
    const selected = management.selected;
    const has_draft = value.form_error_target == .goal or
        management.result_is_preview;
    const entity_kind = if (has_draft)
        value.goal_draft.entity_kind
    else
        management.entity_kind;
    const match_mode = if (has_draft)
        value.goal_draft.match_kind
    else if (selected) |goal|
        @tagName(goal.match_mode)
    else
        "exact";
    const name = if (has_draft)
        value.goal_draft.name
    else if (selected) |goal|
        goal.name
    else
        "";
    const match_value = if (has_draft)
        value.goal_draft.match_value
    else if (selected) |goal|
        goal.match_value
    else
        "";
    const confirm_unseen = has_draft and value.goal_draft.confirm_unseen;

    try output.writeAll("<section class=\"panel\"><h2>");
    try output.writeAll(if (management.screen == .edit) "Edit goal" else "New goal");
    try output.writeAll(
        "</h2><p>Choose an observed Page or Event, then optionally require up to three typed event properties. " ++
            "The selected date range, analysis context, and traffic policy determine the preview.</p>" ++
            "<form class=\"filter-builder\" method=\"get\" action=\"",
    );
    try attribute(output, if (management.screen == .edit)
        management.selected.?.edit_url
    else
        management.new_url);
    try output.writeAll("\"><input type=\"hidden\" name=\"from\" value=\"");
    try attribute(output, value.query.range.start);
    try output.writeAll("\"><input type=\"hidden\" name=\"to\" value=\"");
    try attribute(output, value.query.range.end);
    try output.writeAll("\"><input type=\"hidden\" name=\"compare\" value=\"");
    try attribute(output, value.query.comparison.name());
    try output.writeAll("\">");
    try analysisContextHiddenFields(output, value);
    try output.writeAll("<label>Discover<select name=\"entity\">");
    try output.writeAll(if (entity_kind == .page)
        "<option value=\"page\" selected>Pages</option><option value=\"event\">Events</option>"
    else
        "<option value=\"page\">Pages</option><option value=\"event\" selected>Events</option>");
    try output.writeAll("</select></label><label>Search<input name=\"search\" maxlength=\"256\" value=\"");
    try attribute(output, management.search);
    try output.writeAll("\"></label><button class=\"button-secondary\" type=\"submit\">Search observed values</button></form>");

    if (management.entities.len == 0) {
        try output.writeAll("<p class=\"muted\">No observed values match this search and date range.</p>");
    } else {
        try output.writeAll(
            "<div class=\"table-scroll mobile-records\"><table><caption>Observed " ++
                "values available to this goal</caption><thead><tr><th scope=\"col\">Value</th>" ++
                "<th scope=\"col\">Eligible events</th><th scope=\"col\">Last seen</th>" ++
                "</tr></thead><tbody>",
        );
        for (management.entities) |entity| {
            try output.writeAll("<tr><th scope=\"row\" data-label=\"Value\"><code>");
            try text(output, entity.label);
            try output.print("</code></th><td data-label=\"Eligible events\">{d}</td><td data-label=\"Last seen\">", .{entity.eligible_count});
            try text(output, entity.last_seen);
            try output.writeAll("</td></tr>");
        }
        try output.writeAll("</tbody></table></div>");
    }
    if (management.previous_entities_url != null or
        management.next_entities_url != null)
    {
        try output.writeAll("<nav aria-label=\"Observed value pages\">");
        if (management.previous_entities_url) |previous| {
            try output.writeAll("<a rel=\"prev\" href=\"");
            try attribute(output, previous);
            try output.writeAll("\">Previous observed values</a>");
        }
        if (management.next_entities_url) |next| {
            try output.writeAll("<a rel=\"next\" href=\"");
            try attribute(output, next);
            try output.writeAll("\">Next observed values</a>");
        }
        try output.writeAll("</nav>");
    }

    try output.writeAll("<form method=\"post\" action=\"");
    try attribute(output, if (management.screen == .edit)
        management.edit_action_url
    else
        management.create_action_url);
    try output.writeAll("\" hx-boost=\"true\" hx-sync=\"this:drop\">");
    try formCommon(output, value);
    if (selected) |goal| {
        try output.writeAll("<input type=\"hidden\" name=\"id\" value=\"");
        try attribute(output, goal.id);
        try output.print("\"><input type=\"hidden\" name=\"updated_at\" value=\"{d}\">", .{goal.updated_at_utc_micros});
    }
    try output.writeAll("<input type=\"hidden\" name=\"search\" value=\"");
    try attribute(output, management.search);
    try output.writeAll("\"><label>Source<select name=\"entity\">");
    try output.writeAll(if (entity_kind == .page)
        "<option value=\"page\" selected>Page</option><option value=\"event\">Event</option>"
    else
        "<option value=\"page\">Page</option><option value=\"event\" selected>Event</option>");
    try output.writeAll("</select></label><label>Match<select name=\"match\">");
    try output.writeAll("<option value=\"exact\"");
    if (std.mem.eql(u8, match_mode, "exact")) try output.writeAll(" selected");
    try output.writeAll(">Exact value</option>");
    if (entity_kind == .page) {
        try output.writeAll("<option value=\"prefix\"");
        if (std.mem.eql(u8, match_mode, "prefix")) try output.writeAll(" selected");
        try output.writeAll(">Path starts with</option>");
    }
    try output.writeAll("</select></label><label>Value<input list=\"goal-entity-options\" name=\"value\" maxlength=\"1024\" required");
    try formErrorAttributes(output, value, .goal);
    try output.writeAll(" value=\"");
    try attribute(output, match_value);
    try output.writeAll("\"></label><datalist id=\"goal-entity-options\">");
    for (management.entities) |entity| {
        try output.writeAll("<option value=\"");
        try attribute(output, entity.label);
        try output.writeAll("\"></option>");
    }
    try output.writeAll("</datalist><label>Name<input name=\"name\" maxlength=\"120\" required");
    try formErrorAttributes(output, value, .goal);
    try output.writeAll(" value=\"");
    try attribute(output, name);
    try output.writeAll("\"></label>");
    try goalPredicateBuilder(output, value, management, has_draft);
    try output.writeAll("<label class=\"warning-control\"><input type=\"checkbox\" name=\"confirm_unseen\" value=\"on\"");
    if (confirm_unseen) try output.writeAll(" checked");
    try output.writeAll("> Save even if this definition has zero matching events in the selected range</label>" ++
        "<div class=\"management-actions\"><button class=\"button-secondary\" type=\"submit\" name=\"intent\" value=\"preview\">Preview result</button><button type=\"submit\" name=\"intent\" value=\"save\">");
    try output.writeAll(if (management.screen == .edit) "Save goal" else "Create goal");
    try output.writeAll("</button></div></form>");
    if (management.result_is_preview) {
        try components.feedback(output, .{
            .kind = .notice,
            .message = "Preview completed. This definition has not been saved.",
        });
        try goalResult(output, management.result.?);
        try goalPropertyCatalog(output, management.properties);
    }
    try output.writeAll("</section>");
}

fn goalPredicateBuilder(
    output: *std.Io.Writer,
    value: model.Page,
    management: model.GoalManagement,
    has_draft: bool,
) !void {
    try output.writeAll(
        "<fieldset><legend>Event properties — all rows must match</legend>" ++
            "<p class=\"muted\">Add up to three typed predicates. Empty property rows are ignored.</p>",
    );
    for (0..analysis.maximum_selector_predicates) |index| {
        const draft: ?model.GoalPredicateDraft = if (has_draft and
            index < value.goal_draft.predicates.len)
            value.goal_draft.predicates[index]
        else
            null;
        const predicate: ?analysis.PropertyPredicate = if (!has_draft and
            management.selected != null and
            index < management.selected.?.predicates.len)
            management.selected.?.predicates[index]
        else
            null;
        const property_name = if (draft) |row|
            row.property_name
        else if (predicate) |row|
            row.property_ref.name
        else
            "";
        const predicate_value = if (draft) |row|
            row.value
        else if (predicate) |row|
            if (row.values.len == 0) "" else row.values[0]
        else
            "";
        try output.print("<div class=\"filter-builder\"><label>Property {d}<input list=\"goal-property-options\" name=\"property_{d}\" maxlength=\"120\" value=\"", .{ index + 1, index + 1 });
        try attribute(output, property_name);
        try output.print("\"></label><label>Type and rule<select name=\"rule_{d}\">", .{index + 1});
        try goalRuleOptions(output, if (draft) |row| row.rule else "", predicate);
        try output.print("</select></label><label>Value<input name=\"predicate_value_{d}\" maxlength=\"1024\" value=\"", .{index + 1});
        try attribute(output, predicate_value);
        try output.writeAll("\"></label></div>");
    }
    try output.writeAll("<datalist id=\"goal-property-options\">");
    for (management.properties.entries) |property| {
        try output.writeAll("<option value=\"");
        try attribute(output, property.name);
        try output.writeAll("\">");
        try text(output, property.scalar_type.name());
        try output.writeAll("</option>");
    }
    try output.writeAll("</datalist></fieldset>");
}

const GoalRuleOption = struct {
    value: []const u8,
    label: []const u8,
    scalar_type: analysis.ScalarType,
    operator: analysis.Operator,
};

fn goalRuleOptions(
    output: *std.Io.Writer,
    draft_rule: []const u8,
    selected: ?analysis.PropertyPredicate,
) !void {
    const options = [_]GoalRuleOption{
        .{ .value = "string:is", .label = "Text · is", .scalar_type = .string, .operator = .is },
        .{ .value = "string:is_not", .label = "Text · is not", .scalar_type = .string, .operator = .is_not },
        .{ .value = "string:contains", .label = "Text · contains", .scalar_type = .string, .operator = .contains },
        .{ .value = "string:not_contains", .label = "Text · does not contain", .scalar_type = .string, .operator = .not_contains },
        .{ .value = "string:starts_with", .label = "Text · starts with", .scalar_type = .string, .operator = .starts_with },
        .{ .value = "string:exists", .label = "Text · exists", .scalar_type = .string, .operator = .exists },
        .{ .value = "string:absent", .label = "Text · absent", .scalar_type = .string, .operator = .absent },
        .{ .value = "integer:is", .label = "Integer · is", .scalar_type = .integer, .operator = .is },
        .{ .value = "integer:is_not", .label = "Integer · is not", .scalar_type = .integer, .operator = .is_not },
        .{ .value = "integer:gt", .label = "Integer · greater than", .scalar_type = .integer, .operator = .gt },
        .{ .value = "integer:gte", .label = "Integer · at least", .scalar_type = .integer, .operator = .gte },
        .{ .value = "integer:lt", .label = "Integer · less than", .scalar_type = .integer, .operator = .lt },
        .{ .value = "integer:lte", .label = "Integer · at most", .scalar_type = .integer, .operator = .lte },
        .{ .value = "integer:exists", .label = "Integer · exists", .scalar_type = .integer, .operator = .exists },
        .{ .value = "integer:absent", .label = "Integer · absent", .scalar_type = .integer, .operator = .absent },
        .{ .value = "decimal:is", .label = "Decimal · is", .scalar_type = .decimal, .operator = .is },
        .{ .value = "decimal:is_not", .label = "Decimal · is not", .scalar_type = .decimal, .operator = .is_not },
        .{ .value = "decimal:gt", .label = "Decimal · greater than", .scalar_type = .decimal, .operator = .gt },
        .{ .value = "decimal:gte", .label = "Decimal · at least", .scalar_type = .decimal, .operator = .gte },
        .{ .value = "decimal:lt", .label = "Decimal · less than", .scalar_type = .decimal, .operator = .lt },
        .{ .value = "decimal:lte", .label = "Decimal · at most", .scalar_type = .decimal, .operator = .lte },
        .{ .value = "decimal:exists", .label = "Decimal · exists", .scalar_type = .decimal, .operator = .exists },
        .{ .value = "decimal:absent", .label = "Decimal · absent", .scalar_type = .decimal, .operator = .absent },
        .{ .value = "boolean:is_true", .label = "Boolean · is true", .scalar_type = .boolean, .operator = .is_true },
        .{ .value = "boolean:is_false", .label = "Boolean · is false", .scalar_type = .boolean, .operator = .is_false },
        .{ .value = "boolean:exists", .label = "Boolean · exists", .scalar_type = .boolean, .operator = .exists },
        .{ .value = "boolean:absent", .label = "Boolean · absent", .scalar_type = .boolean, .operator = .absent },
        .{ .value = "null:is", .label = "Null · is null", .scalar_type = .null, .operator = .is },
        .{ .value = "null:is_not", .label = "Null · is not null", .scalar_type = .null, .operator = .is_not },
        .{ .value = "null:exists", .label = "Null · exists", .scalar_type = .null, .operator = .exists },
        .{ .value = "null:absent", .label = "Null · absent", .scalar_type = .null, .operator = .absent },
        .{ .value = "missing:is", .label = "Missing · is missing", .scalar_type = .missing, .operator = .is },
        .{ .value = "missing:is_not", .label = "Missing · is present", .scalar_type = .missing, .operator = .is_not },
    };
    for (options) |option| {
        try output.writeAll("<option value=\"");
        try attribute(output, option.value);
        try output.writeAll("\"");
        const is_selected = if (selected) |predicate|
            predicate.property_ref.scalar_type == option.scalar_type and
                predicate.operator == option.operator
        else if (draft_rule.len != 0)
            std.mem.eql(u8, draft_rule, option.value)
        else
            std.mem.eql(u8, option.value, "string:is");
        if (is_selected) try output.writeAll(" selected");
        try output.writeAll(">");
        try text(output, option.label);
        try output.writeAll("</option>");
    }
}

fn goalDetail(
    output: *std.Io.Writer,
    value: model.Page,
    management: model.GoalManagement,
) !void {
    const goal = management.selected.?;
    try output.writeAll("<section class=\"panel\"><div class=\"split-heading\"><div><h2>");
    try text(output, goal.name);
    try output.writeAll("</h2><p><strong>");
    try output.writeAll(if (goal.archived) "Archived" else "Active");
    try output.writeAll("</strong> · ");
    try output.writeAll(goalSelectorLabel(goal));
    try output.writeAll(" <code>");
    try text(output, goal.match_value);
    try output.writeAll("</code></p>");
    try goalPredicateSummary(output, goal.predicates);
    try output.writeAll("</div><a class=\"button-secondary\" href=\"");
    try attribute(output, goal.edit_url);
    try output.writeAll("\">Edit goal</a></div><dl class=\"definition-grid\"><div><dt>Created</dt><dd>");
    try text(output, goal.created_at);
    try output.writeAll("</dd></div><div><dt>Updated</dt><dd>");
    try text(output, goal.updated_at);
    try output.writeAll("</dd></div></dl><p><a href=\"");
    try attribute(output, goal.analyze_url);
    try output.writeAll("\">Open this goal in Analyze</a></p>");
    try goalResult(output, management.result.?);
    try output.writeAll("<div class=\"management-actions\">");
    try goalStateForm(output, value, management, goal);
    try output.writeAll("<form method=\"post\" action=\"/admin/goals/duplicate");
    try attribute(output, management.action_suffix);
    try output.writeAll("\" hx-boost=\"true\" hx-sync=\"this:drop\">");
    try formCommon(output, value);
    try goalIdentityFields(output, goal);
    try output.writeAll("<label>Duplicate name<input name=\"name\" maxlength=\"120\" required");
    try formErrorAttributes(output, value, .goal_duplicate);
    try output.writeAll(" value=\"");
    if (value.form_error_target == .goal_duplicate) {
        try attribute(output, value.goal_draft.name);
    } else {
        try attribute(output, goal.name);
        try output.writeAll(" copy");
    }
    try output.writeAll("\"></label><button class=\"button-secondary\" type=\"submit\">Duplicate</button></form>");
    try output.writeAll("<form method=\"post\" action=\"/admin/goals/delete");
    try attribute(output, management.action_suffix);
    try output.writeAll("\" hx-boost=\"true\" hx-sync=\"this:drop\">");
    try formCommon(output, value);
    try goalIdentityFields(output, goal);
    try output.writeAll("<label>Type the exact goal name to delete<input name=\"name\" maxlength=\"120\" required autocomplete=\"off\" aria-describedby=\"goal-delete-name\"></label><p id=\"goal-delete-name\" class=\"muted\">Enter <strong>");
    try text(output, goal.name);
    try output.writeAll("</strong>. This cannot be undone.</p><button class=\"danger\" type=\"submit\">Delete permanently</button></form></div></section>");
}

fn goalStateForm(
    output: *std.Io.Writer,
    value: model.Page,
    management: model.GoalManagement,
    goal: model.GoalDefinitionView,
) !void {
    try output.writeAll("<form method=\"post\" action=\"");
    try output.writeAll(if (goal.archived)
        "/admin/goals/reactivate"
    else
        "/admin/goals/archive");
    try attribute(output, management.action_suffix);
    try output.writeAll("\" hx-boost=\"true\" hx-sync=\"this:drop\">");
    try formCommon(output, value);
    try goalIdentityFields(output, goal);
    try output.writeAll("<button class=\"button-secondary\" type=\"submit\">");
    try output.writeAll(if (goal.archived) "Reactivate" else "Archive");
    try output.writeAll("</button></form>");
}

fn goalPredicateSummary(
    output: *std.Io.Writer,
    predicates: []const analysis.PropertyPredicate,
) !void {
    if (predicates.len == 0) {
        try output.writeAll("<p class=\"muted\">No property predicates.</p>");
        return;
    }
    try output.writeAll("<ul class=\"definition-list\">");
    for (predicates) |predicate| {
        try output.writeAll("<li><code>");
        try text(output, predicate.property_ref.name);
        try output.writeAll("</code> · ");
        try text(output, predicate.property_ref.scalar_type.name());
        try output.writeAll(" · ");
        try text(output, predicate.operator.name());
        if (predicate.values.len != 0) {
            try output.writeAll(" · <code>");
            try text(output, predicate.values[0]);
            try output.writeAll("</code>");
        }
        try output.writeAll("</li>");
    }
    try output.writeAll("</ul>");
}

fn goalResult(output: *std.Io.Writer, result: analysis.GoalResult) !void {
    if (result.total_matches < 0 or result.converting_visitors < 0 or
        result.converting_sessions < 0 or result.eligible_visitors < 0 or
        result.eligible_sessions < 0 or result.path_cardinality < 0)
    {
        return error.InvalidGoalResult;
    }
    var visitor_percent: [32]u8 = undefined;
    var session_percent: [32]u8 = undefined;
    var coverage_percent: [32]u8 = undefined;
    const visitor_rate = try percentText(
        &visitor_percent,
        result.converting_visitors,
        result.eligible_visitors,
    );
    const session_rate = try percentText(
        &session_percent,
        result.converting_sessions,
        result.eligible_sessions,
    );
    const coverage_rate = try percentText(
        &coverage_percent,
        result.converting_coverage.persistent_basis_points,
        10_000,
    );
    var matches_buffer: [32]u8 = undefined;
    var visitors_buffer: [96]u8 = undefined;
    var sessions_buffer: [96]u8 = undefined;
    const matches_text = try std.fmt.bufPrint(
        &matches_buffer,
        "{d}",
        .{result.total_matches},
    );
    const visitors_text = try std.fmt.bufPrint(
        &visitors_buffer,
        "{d}/{d} · {s}",
        .{
            result.converting_visitors,
            result.eligible_visitors,
            if (result.eligible_visitors == 0) "unavailable" else visitor_rate,
        },
    );
    const sessions_text = try std.fmt.bufPrint(
        &sessions_buffer,
        "{d}/{d} · {s}",
        .{
            result.converting_sessions,
            result.eligible_sessions,
            if (result.eligible_sessions == 0) "unavailable" else session_rate,
        },
    );
    try output.writeAll("<section class=\"panel\"><h3>Goal result</h3><p class=\"muted\">Counts use event-row selector semantics in the selected site-local range and current filter context.</p><ul class=\"kpi-grid\">");
    try components.kpi(output, .{ .label = "Matching events", .value = matches_text });
    try components.kpi(output, .{ .label = "Converting visitors", .value = visitors_text });
    try components.kpi(output, .{ .label = "Converting sessions", .value = sessions_text });
    try components.kpi(output, .{
        .label = "Persistent identity coverage",
        .value = if (result.converting_visitors == 0)
            "unavailable"
        else
            coverage_rate,
    });
    try output.writeAll(
        "</ul><p class=\"coverage-note\">Legacy coverage counts daily" ++
            " identities only; those rows are never linked into persistent" ++
            " people across dates.</p>",
    );
    if (result.revenue.len != 0) {
        try output.writeAll("<div class=\"table-scroll mobile-records\"><table><caption>Exact revenue on matching events</caption><thead><tr><th scope=\"col\">Currency</th><th scope=\"col\">Exact sum</th><th scope=\"col\">Values</th></tr></thead><tbody>");
        for (result.revenue) |amount| {
            try output.writeAll("<tr><th scope=\"row\" data-label=\"Currency\">");
            try text(output, amount.currency);
            try output.writeAll("</th><td data-label=\"Exact sum\">");
            try text(output, amount.decimal);
            try output.print("</td><td data-label=\"Values\">{d}</td></tr>", .{amount.value_count});
        }
        try output.writeAll("</tbody></table></div>");
    }
    try output.writeAll("<div class=\"table-scroll mobile-records\"><table><caption>Top paths for matching events</caption><thead><tr><th scope=\"col\">Path</th><th scope=\"col\">Matches</th></tr></thead><tbody>");
    for (result.paths) |row| {
        try output.writeAll("<tr><th scope=\"row\" data-label=\"Path\"><code>");
        try text(output, row.path);
        try output.print("</code></th><td data-label=\"Matches\">{d}</td></tr>", .{row.matches});
    }
    if (result.paths.len == 0) {
        try output.writeAll("<tr><td colspan=\"2\">No matching paths.</td></tr>");
    }
    try output.print("</tbody></table></div><p class=\"muted\">{d} distinct matching path(s); at most {d} are shown.</p></section>", .{ result.path_cardinality, analysis.maximum_goal_path_rows });
}

fn goalPropertyCatalog(
    output: *std.Io.Writer,
    catalog: analysis.PropertyCatalog,
) !void {
    if (catalog.property_count < 0) return error.InvalidPropertyCatalog;
    try output.writeAll("<details><summary>Observed properties for this selector</summary><div class=\"table-scroll mobile-records\"><table><caption>Latest 2,000 matching base-selector events</caption><thead><tr><th scope=\"col\">Property</th><th scope=\"col\">Type</th><th scope=\"col\">Events</th></tr></thead><tbody>");
    for (catalog.entries) |property| {
        if (property.event_count < 0) return error.InvalidPropertyCatalog;
        try output.writeAll("<tr><th scope=\"row\" data-label=\"Property\"><code>");
        try text(output, property.name);
        try output.writeAll("</code></th><td data-label=\"Type\">");
        try text(output, property.scalar_type.name());
        try output.print("</td><td data-label=\"Events\">{d}</td></tr>", .{property.event_count});
    }
    if (catalog.entries.len == 0) {
        try output.writeAll("<tr><td colspan=\"3\">No typed properties were observed for this selector.</td></tr>");
    }
    try output.print("</tbody></table></div><p class=\"muted\">{d} distinct property name(s){s}.</p></details>", .{ catalog.property_count, if (catalog.truncated) "; bounded list truncated" else "" });
}

fn goalIdentityFields(
    output: *std.Io.Writer,
    goal: model.GoalDefinitionView,
) !void {
    try output.writeAll("<input type=\"hidden\" name=\"id\" value=\"");
    try attribute(output, goal.id);
    try output.print("\"><input type=\"hidden\" name=\"updated_at\" value=\"{d}\">", .{goal.updated_at_utc_micros});
}

fn goalSelectorLabel(goal: model.GoalDefinitionView) []const u8 {
    return switch (goal.entity_kind) {
        .event => "Event equals",
        .page => switch (goal.match_mode) {
            .exact => "Page equals",
            .prefix => "Page starts with",
        },
    };
}

fn definitions(output: *std.Io.Writer, value: model.Page) !void {
    try output.print(
        "<details class=\"management\"><summary><span>Funnel definitions</span>" ++
            "<span class=\"muted\">{d} funnels</span></summary><section class=\"panel\">" ++
            "<h2>Funnels</h2><ul class=\"definition-list\">",
        .{value.funnels.len},
    );
    for (value.funnels) |funnel| {
        var detail_query = value.query;
        detail_query.kind = .funnel;
        detail_query.subject = "";
        detail_query.funnel_screen = .detail;
        detail_query.funnel_id = funnel.id;
        detail_query.funnel_page = 1;
        try output.writeAll("<li><a href=\"");
        try canonicalUrl(output, .journeys, detail_query, 1);
        try output.writeAll("\"><strong>");
        try text(output, funnel.name);
        try output.print("</strong></a> <span class=\"muted\">{d} steps</span></li>", .{
            funnel.step_count,
        });
    }
    if (value.funnels.len == 0) try output.writeAll("<li>No funnels yet.</li>");
    var list_query = value.query;
    list_query.kind = .funnel;
    list_query.subject = "";
    list_query.funnel_screen = .list;
    list_query.funnel_id = "";
    list_query.funnel_page = 1;
    try output.writeAll("</ul><p><a class=\"button\" href=\"");
    try canonicalUrl(output, .journeys, list_query, 1);
    try output.writeAll("\">Manage funnels</a></p></section></details>");
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
    adjusted.goal_screen = .none;
    adjusted.goal_id = "";
    adjusted.goal_page = 1;
    adjusted.goal_search = "";
    adjusted.goal_entity_page = 1;
    adjusted.funnel_screen = .none;
    adjusted.funnel_id = "";
    adjusted.funnel_page = 1;
    adjusted.page = page_number;
    if (kind.isList()) {
        adjusted.comparison = .none;
        adjusted.analysis_series = &.{};
        adjusted.analysis_interval = .auto;
        adjusted.highlighted_interval = "";
        const mapped = analysis.presetForCurrentReport(
            kind,
            adjusted.campaign_dimension,
        );
        const preset: analysis.Preset = switch (mapped) {
            .analysis => |value| value,
            .campaign_tuple => .campaigns_campaign,
            else => return error.InvalidBreakdownPreset,
        };
        var breakdown = analysis.presetQuery(
            preset,
            adjusted.analysis_site_id,
            adjusted.range,
        );
        breakdown.filters = adjusted.analysis_filters;
        breakdown.segment_id = adjusted.analysis_segment_id;
        adjusted.analysis_breakdown = breakdown;
        return canonicalUrl(output, .analyze, adjusted, page_number);
    }
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
    const default_trend_series = [_]analysis.Metric{.{ .kind = .visitors }};
    switch (destination) {
        .overview => {
            adjusted.kind = .overview;
            adjusted.subject = "";
        },
        .analyze => if (adjusted.analysis_series.len == 0 and
            adjusted.analysis_breakdown == null and
            !adjusted.kind.isList())
        {
            if (adjusted.analysis_filters.clauses.len != 0 or
                adjusted.analysis_segment_id != null)
            {
                adjusted.analysis_series = &default_trend_series;
                adjusted.analysis_interval = .auto;
            } else {
                adjusted.kind = .pages;
                adjusted.subject = "";
            }
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
    if (destination == .overview) {
        try output.writeAll("?v=1");
        try output.writeAll(separator);
        try output.writeAll("from=");
        try urlComponent(output, adjusted.range.start);
        try output.writeAll(separator);
        try output.writeAll("to=");
        try urlComponent(output, adjusted.range.end);
        try output.writeAll(separator);
        try output.writeAll("compare=");
        try urlComponent(output, adjusted.comparison.name());
        try output.writeAll(separator);
        try output.writeAll("metric=");
        if (adjusted.overview_metric == .revenue) {
            try output.writeAll("revenue-");
            try urlComponent(output, adjusted.overview_currency);
        } else {
            try urlComponent(output, adjusted.overview_metric.name());
        }
        var parts = std.mem.splitScalar(
            u8,
            adjusted.canonical_filter_suffix,
            '&',
        );
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            try output.writeAll(separator);
            try output.writeAll(part);
        }
        return;
    }
    if (destination == .sessions) {
        const sessions_query = model.Query{
            .site = adjusted.site,
            .analysis_site_id = adjusted.analysis_site_id,
            .range = adjusted.range,
            .comparison = adjusted.comparison,
            .analysis_filters = adjusted.analysis_filters,
            .analysis_segment_id = adjusted.analysis_segment_id,
            .session_screen = adjusted.session_screen,
            .session_id = adjusted.session_id,
            .profile_person_key = adjusted.profile_person_key,
            .session_goal_id = adjusted.session_goal_id,
            .session_page = if (adjusted.session_screen == .list)
                page_number
            else
                adjusted.session_page,
            .session_timeline_page = adjusted.session_timeline_page,
        };
        const parameters = try controller.canonicalSessionParameters(
            std.heap.page_allocator,
            sessions_query,
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
    if (destination == .analyze and adjusted.analysis_breakdown != null) {
        var breakdown = adjusted.analysis_breakdown.?;
        breakdown.page = page_number;
        const parameters = try analysis.canonicalUrl(
            std.heap.page_allocator,
            breakdown,
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
    if (destination == .analyze and adjusted.analysis_series.len != 0) {
        const parameters = try analysis.canonicalTrendSetUrl(
            std.heap.page_allocator,
            .{
                .site_id = adjusted.analysis_site_id,
                .range = adjusted.range,
                .comparison = adjusted.comparison,
                .interval = adjusted.analysis_interval,
                .series = adjusted.analysis_series,
                .filters = adjusted.analysis_filters,
                .segment_id = adjusted.analysis_segment_id,
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
        .journeys => if (adjusted.goal_screen != .none) {
            if (adjusted.goal_screen == .list and adjusted.goal_page != 1) {
                try output.writeAll(separator);
                try output.print("goal-page={d}", .{adjusted.goal_page});
            }
            if (adjusted.goal_screen == .new or adjusted.goal_screen == .edit) {
                if (adjusted.goal_entity_set or adjusted.goal_entity_kind == .event) {
                    try output.writeAll(separator);
                    try output.writeAll(if (adjusted.goal_entity_kind == .event)
                        "entity=event"
                    else
                        "entity=page");
                }
                if (adjusted.goal_search.len != 0) {
                    try output.writeAll(separator);
                    try output.writeAll("search=");
                    try urlComponent(output, adjusted.goal_search);
                }
                if (adjusted.goal_entity_page != 1) {
                    try output.writeAll(separator);
                    try output.print("entity-page={d}", .{adjusted.goal_entity_page});
                }
            }
        } else if (adjusted.funnel_screen != .none) {
            if (adjusted.funnel_screen == .list and adjusted.funnel_page != 1) {
                try output.writeAll(separator);
                try output.print("funnel-page={d}", .{adjusted.funnel_page});
            }
        } else if (adjusted.subject.len != 0) {
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
    if (destination == .journeys and
        (adjusted.goal_screen != .none or adjusted.funnel_screen != .none))
    {
        var parts = std.mem.splitScalar(
            u8,
            adjusted.canonical_filter_suffix,
            '&',
        );
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            try output.writeAll(separator);
            try output.writeAll(part);
        }
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
    switch (destination) {
        .overview => try output.writeAll("/overview"),
        .analyze => try output.writeAll("/analyze"),
        .journeys => if (query.kind == .funnel) {
            try output.writeAll("/journeys/funnels");
            switch (query.funnel_screen) {
                .none, .list => {},
                .new => try output.writeAll("/new"),
                .detail, .edit => {
                    try output.writeByte('/');
                    try output.writeAll(query.funnel_id);
                    if (query.funnel_screen == .edit) {
                        try output.writeAll("/edit");
                    }
                },
            }
        } else {
            try output.writeAll("/journeys/goals");
            switch (query.goal_screen) {
                .none, .list => {},
                .new => try output.writeAll("/new"),
                .detail, .edit => {
                    try output.writeByte('/');
                    try output.writeAll(query.goal_id);
                    if (query.goal_screen == .edit) try output.writeAll("/edit");
                },
            }
        },
        .sessions => switch (query.session_screen) {
            .list => try output.writeAll("/sessions"),
            .detail => {
                try output.writeAll("/sessions/");
                try urlComponent(output, query.session_id);
            },
            .profile => {
                try output.writeAll("/users/");
                try urlComponent(output, query.profile_person_key);
            },
        },
        .live => try output.writeAll("/live"),
        .settings => try output.writeAll("/settings/general"),
    }
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

test "Sessions render exact semantic summaries and native controls" {
    const revenue = [_]model.SessionRevenue{.{
        .amount = "EUR 12.500000",
        .value_count = 1,
    }};
    const rows = [_]model.SessionRecord{.{
        .detail_url = "/admin/sites/example/sessions/00000000-0000-4000-8000-0000000000b1?v=1&from=2026-01-03&to=2026-01-03&compare=none",
        .short_id = "000000b1",
        .identity = "user-a",
        .identity_state = "Identified user",
        .started_at = "2026-01-03 01:00:00 UTC+01:00",
        .last_activity = "2026-01-03 01:00:04 UTC+01:00",
        .last_received = "2026-01-03 01:00:05 UTC+01:00",
        .landing_page = "/landing",
        .acquisition = "Paid Search · google · winter",
        .country = "DE",
        .client = "desktop · Chrome",
        .duration = "4s",
        .engagement = "10s",
        .page_views = 2,
        .custom_events = 3,
        .conversions = 4,
        .current = true,
        .revenue = &revenue,
    }};
    const goals = [_]model.SessionGoalOption{.{
        .id = "00000000-0000-4000-8000-000000000041",
        .name = "Purchases",
        .selected = true,
    }};
    const page_value = model.Page{
        .destination = .sessions,
        .sites = &.{},
        .selected_site = null,
        .query = .{
            .site = "example",
            .range = .{ .start = "2026-01-01", .end = "2026-01-03" },
            .comparison = .none,
            .session_goal_id = goals[0].id,
        },
        .calendar_context = null,
        .report_time_basis = .none,
        .result = null,
        .session_list = .{
            .rows = &rows,
            .goals = &goals,
            .selected_goal_name = "Purchases",
            .previous_url = null,
            .next_url = "/admin/sites/example/sessions?v=1&from=2026-01-01&to=2026-01-03&compare=none&goal=00000000-0000-4000-8000-000000000041&page=2",
        },
        .goals = &.{},
        .funnels = &.{},
        .self_exclusion_origins = &.{},
        .excluded_networks = &.{},
        .csrf_token = "csrf-token",
    };
    var rendered = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer rendered.deinit();
    try sessionSection(&rendered.writer, page_value);
    const html = rendered.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "Session list") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Current") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "UTC+01:00") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "EUR 12.500000") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "1 value") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "no more than 30 minutes old") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        html,
        "Conversions (Goal matches)</dt><dd>4",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"goal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "rel=\"next\"") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        html,
        "/sessions/00000000-0000-4000-8000-0000000000b1",
    ) != null);
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

    const revenue = try analyzeChartMeasure(
        allocator,
        .{ .amount = .{
            .decimal = "10.000000",
            .currency = "EUR",
            .value_count = 3,
        } },
        .revenue,
    );
    try std.testing.expectEqual(@as(?i128, 10_000_000), revenue.value);
    try std.testing.expectEqualStrings(
        "EUR 10.000000 / 3 values",
        revenue.formatted,
    );
}

test "Breakdown bars never compare unlike currencies" {
    const rows = [_]model.AnalyzeBreakdownRow{
        .{ .data = .{
            .label = .{ .value = "A" },
            .measure = .{ .amount = .{
                .decimal = "10.000000",
                .currency = "EUR",
                .value_count = 1,
            } },
        }, .filter_url = "", .exclude_url = "" },
        .{ .data = .{
            .label = .{ .value = "B" },
            .measure = .{ .amount = .{
                .decimal = "20.000000",
                .currency = "USD",
                .value_count = 1,
            } },
        }, .filter_url = "", .exclude_url = "" },
        .{ .data = .{
            .label = .{ .value = "C" },
            .measure = .{ .amount = .{
                .decimal = "5.000000",
                .currency = "EUR",
                .value_count = 1,
            } },
        }, .filter_url = "", .exclude_url = "" },
    };
    const values = [_]AnalyzeChartMeasure{
        .{ .value = 10_000_000 },
        .{ .value = 20_000_000 },
        .{ .value = 5_000_000 },
    };
    try std.testing.expectEqual(
        @as(i128, 10_000_000),
        breakdownBarMaximum(&rows, &values, 0),
    );
    try std.testing.expectEqual(
        @as(i128, 20_000_000),
        breakdownBarMaximum(&rows, &values, 1),
    );
}

test "production stylesheet mirrors the approved accessible design tokens" {
    const source = @embedFile("design_tokens");
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
    try std.testing.expectEqualStrings("/admin/app.v16.css", stylesheet_path);
}
