const std = @import("std");
const analysis = @import("../analysis.zig");
const calendar = @import("../calendar.zig");
const diagnostics_mod = @import("../diagnostics.zig");
const domain = @import("../domain.zig");
const request_mod = @import("../http/request.zig");
const response = @import("../http/response.zig");
const events = @import("../store/events.zig");
const meta = @import("../store/meta.zig");
const report = @import("../report.zig");
const timezone = @import("../timezone.zig");
const tracker_asset = @import("../tracker_asset.zig");
const controller = @import("controller.zig");
const model = @import("model.zig");
const render = @import("render.zig");

pub const Dependencies = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    metadata: *meta.Store,
    events: *events.Store,
    csrf_token: []const u8,
    origin: []const u8,
    zoneinfo_root: []const u8 = timezone.default_zoneinfo_root,
    report_timeout_ms: u32,
    policy_refresh: ?PolicyRefresh = null,
    site_calendar: ?SiteCalendarLookup = null,
    diagnostics: ?DiagnosticsLookup = null,
    collection_available: bool = true,
};

pub const PolicyRefresh = struct {
    context: *anyopaque,
    apply: *const fn (*anyopaque) anyerror!void,

    fn run(self: PolicyRefresh) !void {
        try self.apply(self.context);
    }
};

pub const SiteCalendar = struct {
    timezone_name: []const u8,
    zone: timezone.Zone,
};

pub const SiteCalendarLookup = struct {
    context: *anyopaque,
    get: *const fn (*anyopaque, []const u8) ?SiteCalendar,

    fn find(self: SiteCalendarLookup, site_id: []const u8) ?SiteCalendar {
        return self.get(self.context, site_id);
    }
};

pub const DiagnosticsLookup = struct {
    context: *anyopaque,
    snapshot: *const fn (
        *anyopaque,
        std.mem.Allocator,
        []const u8,
    ) anyerror!diagnostics_mod.Snapshot,

    fn get(
        self: DiagnosticsLookup,
        allocator: std.mem.Allocator,
        site_id: []const u8,
    ) !diagnostics_mod.Snapshot {
        return self.snapshot(self.context, allocator, site_id);
    }
};

pub fn handle(
    dependencies: Dependencies,
    request: request_mod.Request,
    output: *std.Io.Writer,
) !bool {
    const path = request.path();
    if (std.mem.eql(u8, path, render.stylesheet_path)) {
        if (!std.mem.eql(u8, request.method, "GET")) {
            try methodNotAllowed(output, "GET");
        } else {
            try response.write(
                output,
                200,
                "text/css; charset=utf-8",
                "Cache-Control: private, max-age=86400\r\n" ++
                    "X-Content-Type-Options: nosniff\r\n",
                render.stylesheet,
            );
        }
        return true;
    }
    if (std.mem.eql(u8, path, render.htmx_path)) {
        if (!std.mem.eql(u8, request.method, "GET")) {
            try methodNotAllowed(output, "GET");
        } else {
            const use_gzip = acceptsEncoding(
                (try request.header("accept-encoding")) orelse "",
                "gzip",
            );
            try response.write(
                output,
                200,
                "text/javascript; charset=utf-8",
                if (use_gzip)
                    "Cache-Control: private, max-age=31536000, immutable\r\n" ++
                        "Content-Encoding: gzip\r\n" ++
                        "Vary: Accept-Encoding\r\n" ++
                        "X-Content-Type-Options: nosniff\r\n"
                else
                    "Cache-Control: private, max-age=31536000, immutable\r\n" ++
                        "Vary: Accept-Encoding\r\n" ++
                        "X-Content-Type-Options: nosniff\r\n",
                if (use_gzip) render.htmx_gzip else render.htmx,
            );
        }
        return true;
    }
    if (std.mem.eql(u8, path, render.dashboard_js_path) or
        std.mem.eql(u8, path, render.dashboard_js_previous_path))
    {
        if (!std.mem.eql(u8, request.method, "GET")) {
            try methodNotAllowed(output, "GET");
        } else {
            try response.write(
                output,
                200,
                "text/javascript; charset=utf-8",
                "Cache-Control: private, max-age=31536000, immutable\r\n" ++
                    "X-Content-Type-Options: nosniff\r\n",
                if (std.mem.eql(u8, path, render.dashboard_js_path))
                    render.dashboard_js
                else
                    render.dashboard_js_previous,
            );
        }
        return true;
    }
    if (std.mem.eql(u8, path, render.install_js_path)) {
        if (!std.mem.eql(u8, request.method, "GET")) {
            try methodNotAllowed(output, "GET");
        } else {
            try response.write(
                output,
                200,
                "text/javascript; charset=utf-8",
                "Cache-Control: private, max-age=31536000, immutable\r\n" ++
                    "X-Content-Type-Options: nosniff\r\n",
                render.install_js,
            );
        }
        return true;
    }
    if (std.mem.eql(u8, path, "/admin") or
        std.mem.eql(u8, path, "/admin/"))
    {
        if (!std.mem.eql(u8, request.method, "GET")) {
            try methodNotAllowed(output, "GET");
            return true;
        }
        try getLegacyPage(dependencies, request, output);
        return true;
    }
    if (std.mem.eql(u8, path, "/admin/sites/new")) {
        if (!std.mem.eql(u8, request.method, "GET")) {
            try methodNotAllowed(output, "GET");
        } else {
            try writeSiteForm(output, 200, .{
                .csrf_token = dependencies.csrf_token,
            });
        }
        return true;
    }
    if (std.mem.eql(u8, path, "/admin/sites")) {
        if (!std.mem.eql(u8, request.method, "POST")) {
            try methodNotAllowed(output, "POST");
        } else {
            try postSite(dependencies, request, output);
        }
        return true;
    }
    if (installSiteForPath(path)) |site_slug| {
        if (!std.mem.eql(u8, request.method, "GET")) {
            try methodNotAllowed(output, "GET");
        } else {
            try getInstall(dependencies, request, output, site_slug);
        }
        return true;
    }
    if (savedViewForPath(path)) |saved| {
        if (!std.mem.eql(u8, request.method, "GET")) {
            try methodNotAllowed(output, "GET");
        } else {
            const target = controller.loadSavedView(
                dependencies.allocator,
                dependencies.metadata,
                saved.site,
                saved.id,
            ) catch |err| {
                var return_url = std.Io.Writer.Allocating.init(dependencies.allocator);
                defer return_url.deinit();
                try return_url.writer.print(
                    "/admin/sites/{s}/analyze",
                    .{saved.site},
                );
                try writeError(output, .{
                    .status = if (err == error.SavedViewNotFound) 404 else 422,
                    .title = "Saved view unavailable",
                    .message = "This saved view is missing, corrupt, belongs to another site, or references state that is no longer valid. Return to the site, open Saved views, and delete or recreate the affected view.",
                    .return_url = return_url.written(),
                });
                return true;
            };
            try redirectToCanonical(
                dependencies.allocator,
                output,
                target.destination,
                target.query,
                "",
            );
        }
        return true;
    }
    if (routeFor(path)) |route| {
        if (!std.mem.eql(u8, request.method, "GET")) {
            try methodNotAllowed(output, "GET");
            return true;
        }
        if (route.destination == .analyze) {
            try getAnalyzePage(dependencies, request, output, route);
        } else {
            try getPage(dependencies, request, output, route);
        }
        return true;
    }
    if (analysisActionFor(path)) |action| {
        if (!std.mem.eql(u8, request.method, "POST")) {
            try methodNotAllowed(output, "POST");
        } else {
            try postAnalysisAction(dependencies, request, output, action);
        }
        return true;
    }
    const action = actionFor(path) orelse return false;
    if (!std.mem.eql(u8, request.method, "POST")) {
        try methodNotAllowed(output, "POST");
        return true;
    }
    try postAction(dependencies, request, output, action);
    return true;
}

const SavedViewPath = struct {
    site: []const u8,
    id: []const u8,
};

fn savedViewForPath(path: []const u8) ?SavedViewPath {
    const prefix = "/admin/sites/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const site, const suffix = std.mem.cutScalar(u8, path[prefix.len..], '/') orelse
        return null;
    const view_prefix = "saved-views/";
    if (!std.mem.startsWith(u8, suffix, view_prefix)) return null;
    const id = suffix[view_prefix.len..];
    domain.validateSlug(site) catch return null;
    domain.validateUuid(id) catch return null;
    return .{ .site = site, .id = id };
}

fn installSiteForPath(path: []const u8) ?[]const u8 {
    const prefix = "/admin/sites/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const site, const suffix = std.mem.cutScalar(u8, path[prefix.len..], '/') orelse
        return null;
    domain.validateSlug(site) catch return null;
    if (!std.mem.eql(u8, suffix, "install")) return null;
    return site;
}

const Action = enum {
    add_goal,
    edit_goal,
    duplicate_goal,
    archive_goal,
    reactivate_goal,
    delete_goal,
    add_funnel,
    delete_funnel,
    add_excluded_network,
    delete_excluded_network,
    update_traffic_policy,
};

const AnalysisAction = enum {
    apply_filter,
    suggest_filter,
    remove_filter,
    create_segment,
    update_segment,
    rename_segment,
    duplicate_segment,
    delete_segment,
    create_saved_view,
    duplicate_saved_view,
    rename_saved_view,
    delete_saved_view,
};

fn analysisActionFor(path: []const u8) ?AnalysisAction {
    if (std.mem.eql(u8, path, "/admin/filters/apply")) return .apply_filter;
    if (std.mem.eql(u8, path, "/admin/filters/suggest")) return .suggest_filter;
    if (std.mem.eql(u8, path, "/admin/filters/remove")) return .remove_filter;
    if (std.mem.eql(u8, path, "/admin/segments")) return .create_segment;
    if (std.mem.eql(u8, path, "/admin/segments/update")) return .update_segment;
    if (std.mem.eql(u8, path, "/admin/segments/rename")) return .rename_segment;
    if (std.mem.eql(u8, path, "/admin/segments/duplicate")) {
        return .duplicate_segment;
    }
    if (std.mem.eql(u8, path, "/admin/segments/delete")) return .delete_segment;
    if (std.mem.eql(u8, path, "/admin/saved-views")) return .create_saved_view;
    if (std.mem.eql(u8, path, "/admin/saved-views/duplicate")) {
        return .duplicate_saved_view;
    }
    if (std.mem.eql(u8, path, "/admin/saved-views/rename")) {
        return .rename_saved_view;
    }
    if (std.mem.eql(u8, path, "/admin/saved-views/delete")) {
        return .delete_saved_view;
    }
    return null;
}

const Route = struct {
    site: []const u8,
    destination: model.Destination,
    default_kind: report.Kind,
    goal_screen: model.GoalScreen = .none,
    goal_id: []const u8 = "",
};

fn routeFor(path: []const u8) ?Route {
    const prefix = "/admin/sites/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const site, const suffix = std.mem.cutScalar(u8, path[prefix.len..], '/') orelse
        return null;
    domain.validateSlug(site) catch return null;
    if (std.mem.eql(u8, suffix, "overview")) return .{
        .site = site,
        .destination = .overview,
        .default_kind = .overview,
    };
    if (std.mem.eql(u8, suffix, "analyze")) return .{
        .site = site,
        .destination = .analyze,
        .default_kind = .pages,
    };
    if (std.mem.eql(u8, suffix, "journeys/goals")) return .{
        .site = site,
        .destination = .journeys,
        .default_kind = .goal,
        .goal_screen = .list,
    };
    if (std.mem.eql(u8, suffix, "journeys/goals/new")) return .{
        .site = site,
        .destination = .journeys,
        .default_kind = .goal,
        .goal_screen = .new,
    };
    const goal_prefix = "journeys/goals/";
    if (std.mem.startsWith(u8, suffix, goal_prefix)) {
        const goal_suffix = suffix[goal_prefix.len..];
        var id = goal_suffix;
        var screen: model.GoalScreen = .detail;
        if (std.mem.endsWith(u8, goal_suffix, "/edit")) {
            id = goal_suffix[0 .. goal_suffix.len - "/edit".len];
            screen = .edit;
        }
        domain.validateUuid(id) catch return null;
        return .{
            .site = site,
            .destination = .journeys,
            .default_kind = .goal,
            .goal_screen = screen,
            .goal_id = id,
        };
    }
    if (std.mem.eql(u8, suffix, "journeys/funnels")) return .{
        .site = site,
        .destination = .journeys,
        .default_kind = .funnel,
    };
    if (std.mem.eql(u8, suffix, "sessions")) return .{
        .site = site,
        .destination = .sessions,
        .default_kind = .overview,
    };
    if (std.mem.eql(u8, suffix, "live")) return .{
        .site = site,
        .destination = .live,
        .default_kind = .traffic_quality,
    };
    if (std.mem.eql(u8, suffix, "settings/general")) return .{
        .site = site,
        .destination = .settings,
        .default_kind = .overview,
    };
    return null;
}

fn actionFor(path: []const u8) ?Action {
    if (std.mem.eql(u8, path, "/admin/goals")) return .add_goal;
    if (std.mem.eql(u8, path, "/admin/goals/edit")) return .edit_goal;
    if (std.mem.eql(u8, path, "/admin/goals/duplicate")) return .duplicate_goal;
    if (std.mem.eql(u8, path, "/admin/goals/archive")) return .archive_goal;
    if (std.mem.eql(u8, path, "/admin/goals/reactivate")) return .reactivate_goal;
    if (std.mem.eql(u8, path, "/admin/goals/delete")) return .delete_goal;
    if (std.mem.eql(u8, path, "/admin/funnels")) return .add_funnel;
    if (std.mem.eql(u8, path, "/admin/funnels/delete")) return .delete_funnel;
    if (std.mem.eql(u8, path, "/admin/exclusions/networks")) {
        return .add_excluded_network;
    }
    if (std.mem.eql(u8, path, "/admin/exclusions/networks/delete")) {
        return .delete_excluded_network;
    }
    if (std.mem.eql(u8, path, "/admin/traffic-policy")) {
        return .update_traffic_policy;
    }
    return null;
}

fn postSite(
    dependencies: Dependencies,
    request: request_mod.Request,
    output: *std.Io.Writer,
) !void {
    if (!validFormContentType(try request.header("content-type"))) {
        try writeError(output, .{
            .status = 415,
            .title = "Unsupported form",
            .message = "Use a normal URL-encoded HTML form.",
            .return_url = "/admin/sites/new",
        });
        return;
    }
    if (!try sameOrigin(request, dependencies.origin)) {
        try writeError(output, .{
            .status = 403,
            .title = "Forbidden",
            .message = "The site form did not come from this dashboard origin.",
            .return_url = "/admin/sites/new",
        });
        return;
    }
    const form = controller.Form.parse(
        dependencies.allocator,
        request.body,
    ) catch {
        try writeError(output, .{
            .status = 400,
            .title = "Invalid form",
            .message = "The submitted site form was malformed or too large.",
            .return_url = "/admin/sites/new",
        });
        return;
    };
    controller.verifyCsrf(form, dependencies.csrf_token) catch {
        try writeError(output, .{
            .status = 403,
            .title = "Forbidden",
            .message = "The form token was missing or stale. Reload and try again.",
            .return_url = "/admin/sites/new",
        });
        return;
    };
    const now = currentMicros() catch {
        try writeError(output, .{
            .status = 503,
            .title = "Clock unavailable",
            .message = "The server could not safely timestamp this site.",
            .return_url = "/admin/sites/new",
        });
        return;
    };
    const submission = controller.submitSite(
        dependencies.allocator,
        dependencies.io,
        dependencies.metadata,
        form,
        dependencies.csrf_token,
        dependencies.zoneinfo_root,
        now,
    ) catch |err| {
        std.log.err("site creation failed: {s}", .{@errorName(err)});
        if (err == error.SiteCompensationFailed) {
            try writeError(output, .{
                .status = 503,
                .title = "Site cleanup failed",
                .message = "A metadata write and its compensating delete both failed. Run analytico doctor before retrying; an incomplete site may remain.",
                .return_url = "/admin/sites/new",
            });
        } else {
            try writeError(output, .{
                .status = 503,
                .title = "Site was not created",
                .message = "Metadata storage rejected the operation. No success is claimed; it is safe to reload and retry after storage recovers.",
                .return_url = "/admin/sites/new",
            });
        }
        return;
    };
    switch (submission) {
        .invalid => |page| try writeSiteForm(output, 422, page),
        .stored => |stored| {
            const refresh = dependencies.policy_refresh orelse {
                try siteRefreshFailed(dependencies.allocator, output, stored.slug);
                return;
            };
            refresh.run() catch {
                try siteRefreshFailed(dependencies.allocator, output, stored.slug);
                return;
            };
            try redirectToInstall(dependencies.allocator, output, stored.slug);
        },
    }
}

fn getInstall(
    dependencies: Dependencies,
    request: request_mod.Request,
    output: *std.Io.Writer,
    site_slug: []const u8,
) !void {
    const site = dependencies.metadata.siteConfigurationBySlug(
        dependencies.allocator,
        site_slug,
    ) catch |err| switch (err) {
        error.SiteNotFound => {
            try writeError(output, .{
                .status = 404,
                .title = "Site not found",
                .message = "The selected site no longer exists.",
            });
            return;
        },
        else => return err,
    };
    const parsed = controller.parseInstallQuery(
        dependencies.allocator,
        request.target,
    ) catch {
        try invalidInstallPage(output, site.slug);
        return;
    };
    var collection_available = dependencies.collection_available;
    const query = if (parsed) |provided| query: {
        controller.verifyInstallWatermark(
            provided,
            site.id,
            dependencies.csrf_token,
        ) catch {
            try invalidInstallPage(output, site.slug);
            return;
        };
        if (!(try isCanonicalInstallTarget(
            dependencies.allocator,
            request.target,
            site.slug,
            provided,
        ))) {
            try redirectToInstallQuery(
                dependencies.allocator,
                output,
                site.slug,
                provided,
            );
            return;
        }
        break :query provided;
    } else {
        const started_at_utc_micros = currentMicros() catch {
            try writeError(output, .{
                .status = 503,
                .title = "Clock unavailable",
                .message = "The server could not safely start installation verification. Restore the server clock and reload this page.",
                .return_url = "/admin",
            });
            return;
        };
        const watermark = dependencies.events.installationWatermark(
            dependencies.allocator,
            site.id,
        ) catch unavailable: {
            collection_available = false;
            break :unavailable events.InstallationWatermark{
                .event_count = std.math.maxInt(i64),
                .received_at_utc_micros = std.math.maxInt(i64),
                .event_id = "00000000-0000-0000-0000-000000000000",
            };
        };
        const signature = try controller.signInstallWatermark(
            site.id,
            dependencies.csrf_token,
            started_at_utc_micros,
            watermark.event_count,
            watermark.received_at_utc_micros,
            watermark.event_id,
        );
        const issued = controller.InstallQuery{
            .started_at_utc_micros = started_at_utc_micros,
            .event_count = watermark.event_count,
            .after_received_at_utc_micros = watermark.received_at_utc_micros,
            .after_event_id = watermark.event_id,
            .signature = try dependencies.allocator.dupe(u8, &signature),
            .fragment = false,
        };
        try redirectToInstallQuery(
            dependencies.allocator,
            output,
            site.slug,
            issued,
        );
        return;
    };

    const stored_event = dependencies.events.firstInstallationEventAfter(
        dependencies.allocator,
        site.id,
        .{
            .event_count = query.event_count,
            .received_at_utc_micros = query.after_received_at_utc_micros,
            .event_id = query.after_event_id,
        },
    ) catch unavailable: {
        collection_available = false;
        break :unavailable null;
    };
    const event = if (stored_event) |source|
        try controller.installEvent(dependencies.allocator, source)
    else
        null;
    var guidance: ?model.InstallGuidance = null;
    if (event == null) if (dependencies.diagnostics) |lookup| {
        const snapshot = try lookup.get(dependencies.allocator, site.id);
        for (snapshot.summaries) |summary| {
            if (summary.received_at_utc_micros < query.started_at_utc_micros) {
                continue;
            }
            if (summary.outcome == .accepted) break;
            guidance = controller.installGuidance(summary);
            if (guidance != null) break;
        }
    };
    const verification = model.InstallVerification{
        .site_slug = site.slug,
        .watermark = .{
            .started_at_utc_micros = query.started_at_utc_micros,
            .event_count = query.event_count,
            .after_received_at_utc_micros = query.after_received_at_utc_micros,
            .after_event_id = query.after_event_id,
            .signature = query.signature,
        },
        .event = event,
        .guidance = guidance,
        .collection_available = collection_available,
    };
    var body = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer body.deinit();
    if (query.fragment) {
        try render.installVerificationFragment(&body.writer, verification);
        try response.write(
            output,
            200,
            "text/html; charset=utf-8",
            render.install_headers,
            body.written(),
        );
        return;
    }
    const policy_active = if (dependencies.site_calendar) |lookup|
        lookup.find(site.id) != null
    else
        false;
    var snippet = std.Io.Writer.Allocating.init(dependencies.allocator);
    try snippet.writer.print(
        \\<script defer
        \\  src="{s}{s}"
        \\  data-site="{s}"
        \\  data-spa="auto"
        \\  data-engagement="true"></script>
        \\<noscript>
        \\  <img alt="" width="1" height="1"
        \\    src="{s}/v1/p.gif?site={s}&amp;path=%2F">
        \\</noscript>
    , .{
        dependencies.origin,
        tracker_asset.current_path,
        site.id,
        dependencies.origin,
        site.id,
    });
    try render.installPage(&body.writer, .{
        .site = site,
        .collector_origin = dependencies.origin,
        .tracker_path = tracker_asset.current_path,
        .tracker_protocol_version = tracker_asset.protocol_version,
        .snippet = snippet.written(),
        .policy_active = policy_active,
        .verification = verification,
    });
    try response.write(
        output,
        200,
        "text/html; charset=utf-8",
        render.install_headers,
        body.written(),
    );
}

fn invalidInstallPage(output: *std.Io.Writer, site_slug: []const u8) !void {
    var return_buffer: [96]u8 = undefined;
    const return_url = try std.fmt.bufPrint(
        &return_buffer,
        "/admin/sites/{s}/install",
        .{site_slug},
    );
    try writeError(output, .{
        .status = 400,
        .title = "Invalid installation verification",
        .message = "The verification URL has an invalid, duplicate, incomplete, expired-session, or unsupported field. Start a new verification from the bare Install page.",
        .return_url = return_url,
    });
}

fn writeInstallTarget(
    output: *std.Io.Writer,
    site_slug: []const u8,
    query: controller.InstallQuery,
) !void {
    try output.print(
        "/admin/sites/{s}/install?started={d}&count={d}&after={d}&event={s}&sig={s}",
        .{
            site_slug,
            query.started_at_utc_micros,
            query.event_count,
            query.after_received_at_utc_micros,
            query.after_event_id,
            query.signature,
        },
    );
    if (query.fragment) try output.writeAll("&fragment=verification");
}

fn isCanonicalInstallTarget(
    allocator: std.mem.Allocator,
    target: []const u8,
    site_slug: []const u8,
    query: controller.InstallQuery,
) !bool {
    var expected = std.Io.Writer.Allocating.init(allocator);
    try writeInstallTarget(&expected.writer, site_slug, query);
    return std.mem.eql(u8, target, expected.written());
}

fn redirectToInstallQuery(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    site_slug: []const u8,
    query: controller.InstallQuery,
) !void {
    var location = std.Io.Writer.Allocating.init(allocator);
    try writeInstallTarget(&location.writer, site_slug, query);
    var headers = std.Io.Writer.Allocating.init(allocator);
    try headers.writer.print(
        "Cache-Control: no-store\r\nLocation: {s}\r\n",
        .{location.written()},
    );
    try response.write(
        output,
        303,
        "text/plain; charset=utf-8",
        headers.written(),
        "see other\n",
    );
}

fn writeSiteForm(
    output: *std.Io.Writer,
    status: u16,
    page: model.SiteFormPage,
) !void {
    var body = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer body.deinit();
    try render.siteFormPage(&body.writer, page);
    try response.write(
        output,
        status,
        "text/html; charset=utf-8",
        render.headers,
        body.written(),
    );
}

fn writeFirstRun(output: *std.Io.Writer, runtime_ready: bool) !void {
    var body = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer body.deinit();
    try render.firstRunPage(&body.writer, .{
        .metadata_schema = meta.schema_version,
        .event_schema = events.schema_version,
        .runtime_ready = runtime_ready,
    });
    try response.write(
        output,
        200,
        "text/html; charset=utf-8",
        render.headers,
        body.written(),
    );
}

fn redirectToInstall(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    site_slug: []const u8,
) !void {
    var headers = std.Io.Writer.Allocating.init(allocator);
    try headers.writer.print(
        "Cache-Control: no-store\r\nLocation: /admin/sites/{s}/install\r\n",
        .{site_slug},
    );
    try response.write(
        output,
        303,
        "text/plain; charset=utf-8",
        headers.written(),
        "see other\n",
    );
}

fn siteRefreshFailed(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    site_slug: []const u8,
) !void {
    const install_url = try std.fmt.allocPrint(
        allocator,
        "/admin/sites/{s}/install",
        .{site_slug},
    );
    try writeError(output, .{
        .status = 503,
        .title = "Collection policy refresh failed",
        .message = "The site exists, but the running collector could not load its policy. Restart the service or submit the same site form after recovery; no second site will be inserted.",
        .return_url = install_url,
    });
}

fn getLegacyPage(
    dependencies: Dependencies,
    request: request_mod.Request,
    output: *std.Io.Writer,
) !void {
    const now = currentSeconds() catch {
        try writeError(output, .{
            .status = 503,
            .title = "Clock unavailable",
            .message = "The server could not determine a safe report calendar.",
        });
        return;
    };
    const parsed = controller.parseQuery(
        dependencies.allocator,
        request.target,
        .overview,
    ) catch {
        try writeError(output, .{
            .status = 400,
            .title = "Invalid report request",
            .message = "Check the site, local date range, comparison, report, sort, and page values.",
        });
        return;
    };
    if (parsed.goal_fields_set) {
        try writeError(output, .{
            .status = 400,
            .title = "Invalid report request",
            .message = "Goal builder fields are valid only on a site-scoped Goals route.",
        });
        return;
    }
    const sites = try dependencies.metadata.listSites(dependencies.allocator);
    if (sites.len == 0) {
        try writeFirstRun(output, dependencies.collection_available);
        return;
    }
    const selected = controller.resolveSite(sites, parsed.site) catch {
        try writeError(output, .{
            .status = 404,
            .title = "Report not found",
            .message = "The selected site, goal, or funnel no longer exists.",
        });
        return;
    };
    const site_calendar = dependencies.site_calendar orelse {
        try calendarUnavailable(output);
        return;
    };
    const selected_calendar = site_calendar.find(selected.id) orelse {
        try calendarUnavailable(output);
        return;
    };
    const default_range = calendar.rangeForPreset(
        selected_calendar.zone,
        now,
        .last_30_days,
    ) catch {
        try calendarUnavailable(output);
        return;
    };
    const query = controller.finishQuery(
        parsed,
        selected.slug,
        &default_range,
        .previous,
    ) catch {
        try writeError(output, .{
            .status = 400,
            .title = "Invalid report request",
            .message = "Check the site, local date range, comparison, report, sort, and page values.",
        });
        return;
    };
    if (query.kind.isList()) {
        const breakdown = controller.translateLegacyBreakdown(
            query,
            selected.id,
        ) catch {
            try writeError(output, .{
                .status = 400,
                .title = "Invalid analysis request",
                .message = "The legacy list state could not be translated to a typed Breakdown preset.",
            });
            return;
        };
        try redirectToCanonical(
            dependencies.allocator,
            output,
            .analyze,
            breakdown,
            "",
        );
        return;
    }
    try redirectToCanonical(
        dependencies.allocator,
        output,
        legacyDestination(query.kind),
        query,
        parsed.notice,
    );
}

fn getPage(
    dependencies: Dependencies,
    request: request_mod.Request,
    output: *std.Io.Writer,
    route: Route,
) !void {
    const now = currentSeconds() catch {
        try writeError(output, .{
            .status = 503,
            .title = "Clock unavailable",
            .message = "The server could not determine a safe report calendar.",
        });
        return;
    };
    const sites = try dependencies.metadata.listSites(dependencies.allocator);
    if (sites.len == 0) {
        try writeFirstRun(output, dependencies.collection_available);
        return;
    }
    const selected = controller.resolveSite(sites, route.site) catch {
        try writeError(output, .{
            .status = 404,
            .title = "Report not found",
            .message = "The selected site no longer exists.",
        });
        return;
    };
    const site_calendar = dependencies.site_calendar orelse {
        try calendarUnavailable(output);
        return;
    };
    const selected_calendar = site_calendar.find(selected.id) orelse {
        try calendarUnavailable(output);
        return;
    };
    const default_range = calendar.rangeForPreset(
        selected_calendar.zone,
        now,
        .last_30_days,
    ) catch {
        try calendarUnavailable(output);
        return;
    };
    const default_query = model.Query{
        .site = selected.slug,
        .range = default_range.view(),
        .comparison = .previous,
        .kind = route.default_kind,
    };
    const parsed = controller.parseQuery(
        dependencies.allocator,
        request.target,
        route.default_kind,
    ) catch {
        try invalidQueryPage(dependencies.allocator, output, route.destination, default_query);
        return;
    };
    if (parsed.site.len != 0 or !kindAllowed(route, parsed.kind) or
        (parsed.goal_fields_set and route.goal_screen == .none))
    {
        try invalidQueryPage(dependencies.allocator, output, route.destination, default_query);
        return;
    }
    var query = controller.finishQuery(
        parsed,
        selected.slug,
        &default_range,
        .previous,
    ) catch {
        try invalidQueryPage(dependencies.allocator, output, route.destination, default_query);
        return;
    };
    query.goal_screen = route.goal_screen;
    query.goal_id = route.goal_id;
    if (route.goal_screen == .list and query.subject.len != 0) {
        const legacy_goal = dependencies.metadata.goalByName(
            dependencies.allocator,
            selected.slug,
            query.subject,
        ) catch |err| {
            if (err == error.GoalNotFound) {
                try writeError(output, .{
                    .status = 404,
                    .title = "Goal not found",
                    .message = "The selected goal no longer exists.",
                });
                return;
            }
            return err;
        };
        query.goal_screen = .detail;
        query.goal_id = legacy_goal.id;
        query.subject = "";
    }
    controller.validateQuery(query) catch {
        try invalidQueryPage(dependencies.allocator, output, route.destination, default_query);
        return;
    };
    const resolved_calendar = calendar.resolve(
        selected_calendar.zone,
        selected_calendar.timezone_name,
        now,
        query.range,
        query.comparison,
    ) catch {
        try invalidQueryPage(dependencies.allocator, output, route.destination, default_query);
        return;
    };
    if (!try isCanonicalTarget(
        dependencies.allocator,
        request.target,
        route.destination,
        query,
        parsed.notice,
    )) {
        try redirectToCanonical(
            dependencies.allocator,
            output,
            route.destination,
            query,
            parsed.notice,
        );
        return;
    }
    var loaded = controller.loadPage(
        dependencies.allocator,
        dependencies.metadata,
        dependencies.events,
        route.destination,
        query,
        resolved_calendar,
        selected_calendar.zone,
        dependencies.csrf_token,
        noticeMessage(parsed.notice),
        dependencies.report_timeout_ms,
    ) catch |err| {
        if (err == error.ReportTimeout) {
            try writeError(output, .{
                .status = 503,
                .title = "Report timed out",
                .message = "The report exceeded its server deadline. Narrow the selected date range and retry.",
                .return_url = request.target,
            });
        } else if (err == error.StaleFilterProperty) {
            try staleFilterPage(
                dependencies.allocator,
                output,
                route.destination,
                query,
            );
        } else if (isStaleSegmentError(err)) {
            try staleSegmentPage(
                dependencies.allocator,
                output,
                route.destination,
                query,
            );
        } else if (err == error.SiteNotFound or err == error.GoalNotFound or
            err == error.FunnelNotFound)
        {
            try writeError(output, .{
                .status = 404,
                .title = "Report not found",
                .message = "The selected site, goal, or funnel no longer exists.",
            });
        } else if (isInvalidInput(err)) {
            try writeError(output, .{
                .status = 400,
                .title = "Invalid report request",
                .message = "Check the site, local date range, comparison, report, sort, and page values.",
            });
        } else {
            return err;
        }
        return;
    };
    if (route.destination == .overview or route.destination == .live) {
        const diagnostics = dependencies.diagnostics orelse
            return error.MissingDiagnosticsLookup;
        loaded.collection_diagnostics = try diagnostics.get(
            dependencies.allocator,
            selected.id,
        );
    }
    try writePage(output, 200, loaded);
}

fn getAnalyzePage(
    dependencies: Dependencies,
    request: request_mod.Request,
    output: *std.Io.Writer,
    route: Route,
) !void {
    if (rawQueryFieldEquals(request.target, "mode", "breakdown")) {
        return getBreakdownPage(
            dependencies,
            request,
            output,
            route,
            if (hasRawQueryField(request.target, "v")) .canonical else .builder,
        );
    }
    const legacy = controller.parseQuery(
        dependencies.allocator,
        request.target,
        route.default_kind,
    ) catch {
        if (hasRawQueryField(request.target, "report") or
            hasRawQueryField(request.target, "focus"))
        {
            return getPage(dependencies, request, output, route);
        }
        return getTrendPage(dependencies, request, output, route, null);
    };
    if (try controller.translateOverviewTrendHandoff(
        dependencies.allocator,
        legacy,
    )) |translated| {
        return getTrendPage(dependencies, request, output, route, translated);
    }
    if (legacy.report_set and legacy.kind.isList()) {
        return getBreakdownPage(
            dependencies,
            request,
            output,
            route,
            .{ .legacy = legacy },
        );
    }
    if (legacy.report_set or legacy.overview_selection_set) {
        return getPage(dependencies, request, output, route);
    }
    return getTrendPage(dependencies, request, output, route, null);
}

const BreakdownInput = union(enum) {
    canonical,
    builder,
    legacy: controller.ParsedQuery,
};

fn hasRawQueryField(target: []const u8, expected: []const u8) bool {
    const marker = std.mem.findScalar(u8, target, '?') orelse return false;
    var parameters = std.mem.splitScalar(u8, target[marker + 1 ..], '&');
    while (parameters.next()) |parameter| {
        const name, _ = std.mem.cutScalar(u8, parameter, '=') orelse continue;
        if (std.mem.eql(u8, name, expected)) return true;
    }
    return false;
}

fn rawQueryFieldEquals(
    target: []const u8,
    expected_name: []const u8,
    expected_value: []const u8,
) bool {
    const marker = std.mem.findScalar(u8, target, '?') orelse return false;
    var parameters = std.mem.splitScalar(u8, target[marker + 1 ..], '&');
    while (parameters.next()) |parameter| {
        const name, const value = std.mem.cutScalar(u8, parameter, '=') orelse
            continue;
        if (std.mem.eql(u8, name, expected_name) and
            std.mem.eql(u8, value, expected_value)) return true;
    }
    return false;
}

fn getBreakdownPage(
    dependencies: Dependencies,
    request: request_mod.Request,
    output: *std.Io.Writer,
    route: Route,
    input: BreakdownInput,
) !void {
    const now = currentSeconds() catch {
        try writeError(output, .{
            .status = 503,
            .title = "Clock unavailable",
            .message = "The server could not determine a safe analysis calendar.",
        });
        return;
    };
    const sites = try dependencies.metadata.listSites(dependencies.allocator);
    if (sites.len == 0) {
        try writeFirstRun(output, dependencies.collection_available);
        return;
    }
    const selected = controller.resolveSite(sites, route.site) catch {
        try writeError(output, .{
            .status = 404,
            .title = "Analysis not found",
            .message = "The selected site no longer exists.",
        });
        return;
    };
    const site_calendar = dependencies.site_calendar orelse {
        try calendarUnavailable(output);
        return;
    };
    const selected_calendar = site_calendar.find(selected.id) orelse {
        try calendarUnavailable(output);
        return;
    };
    const default_range = calendar.rangeForPreset(
        selected_calendar.zone,
        now,
        .last_30_days,
    ) catch {
        try calendarUnavailable(output);
        return;
    };
    const default_breakdown = analysis.presetQuery(
        .pages,
        selected.id,
        default_range.view(),
    );
    const default_query = controller.finishBreakdownQuery(
        default_breakdown,
        selected.slug,
    ) catch unreachable;
    const query = switch (input) {
        .canonical => value: {
            const marker = std.mem.findScalar(u8, request.target, '?') orelse {
                try invalidBreakdownQueryPage(
                    dependencies.allocator,
                    output,
                    400,
                    default_query,
                );
                return;
            };
            const breakdown = analysis.parseCanonicalUrl(
                dependencies.allocator,
                selected.id,
                request.target[marker + 1 ..],
            ) catch |err| {
                try invalidBreakdownQueryPage(
                    dependencies.allocator,
                    output,
                    if (err == error.UnsupportedMetricDimension) 422 else 400,
                    default_query,
                );
                return;
            };
            break :value controller.finishBreakdownQuery(
                breakdown,
                selected.slug,
            ) catch |err| {
                try invalidBreakdownQueryPage(
                    dependencies.allocator,
                    output,
                    if (err == error.UnsupportedMetricDimension) 422 else 400,
                    default_query,
                );
                return;
            };
        },
        .builder => value: {
            const parsed = controller.parseBreakdownBuilder(
                dependencies.allocator,
                request.target,
            ) catch |err| {
                try invalidBreakdownQueryPage(
                    dependencies.allocator,
                    output,
                    if (err == error.UnsupportedMetricDimension) 422 else 400,
                    default_query,
                );
                return;
            };
            break :value controller.finishBreakdownBuilder(
                parsed,
                selected.slug,
                selected.id,
            ) catch |err| {
                try invalidBreakdownQueryPage(
                    dependencies.allocator,
                    output,
                    if (err == error.UnsupportedMetricDimension) 422 else 400,
                    default_query,
                );
                return;
            };
        },
        .legacy => |parsed| value: {
            if (parsed.site.len != 0) {
                try invalidBreakdownQueryPage(
                    dependencies.allocator,
                    output,
                    400,
                    default_query,
                );
                return;
            }
            const legacy = controller.finishQuery(
                parsed,
                selected.slug,
                &default_range,
                .previous,
            ) catch {
                try invalidBreakdownQueryPage(
                    dependencies.allocator,
                    output,
                    400,
                    default_query,
                );
                return;
            };
            break :value controller.translateLegacyBreakdown(
                legacy,
                selected.id,
            ) catch {
                try invalidBreakdownQueryPage(
                    dependencies.allocator,
                    output,
                    400,
                    default_query,
                );
                return;
            };
        },
    };
    if (input != .canonical or !try isCanonicalTarget(
        dependencies.allocator,
        request.target,
        .analyze,
        query,
        "",
    )) {
        try redirectToCanonical(
            dependencies.allocator,
            output,
            .analyze,
            query,
            "",
        );
        return;
    }
    const resolved_calendar = calendar.resolve(
        selected_calendar.zone,
        selected_calendar.timezone_name,
        now,
        query.range,
        .none,
    ) catch {
        try invalidBreakdownQueryPage(
            dependencies.allocator,
            output,
            400,
            default_query,
        );
        return;
    };
    const loaded = controller.loadBreakdownPage(
        dependencies.allocator,
        dependencies.metadata,
        dependencies.events,
        query,
        resolved_calendar,
        dependencies.csrf_token,
        dependencies.report_timeout_ms,
    ) catch |err| {
        if (err == error.ReportTimeout) {
            try writeError(output, .{
                .status = 503,
                .title = "Report timed out",
                .message = "The Breakdown result, conditional empty-site check, and property catalog exceeded their shared server deadline. Narrow the selected date range and retry.",
                .return_url = request.target,
            });
        } else if (err == error.StaleFilterProperty) {
            try staleFilterPage(
                dependencies.allocator,
                output,
                .analyze,
                query,
            );
        } else if (isStaleSegmentError(err)) {
            try staleSegmentPage(
                dependencies.allocator,
                output,
                .analyze,
                query,
            );
        } else if (err == error.SiteNotFound or err == error.GoalNotFound) {
            try writeError(output, .{
                .status = 404,
                .title = "Analysis not found",
                .message = "The selected site or goal no longer exists.",
            });
        } else if (isInvalidInput(err)) {
            try invalidBreakdownQueryPage(
                dependencies.allocator,
                output,
                if (err == error.UnsupportedMetricDimension) 422 else 400,
                default_query,
            );
        } else {
            return err;
        }
        return;
    };
    try writePage(output, 200, loaded);
}

fn getTrendPage(
    dependencies: Dependencies,
    request: request_mod.Request,
    output: *std.Io.Writer,
    route: Route,
    translated: ?controller.ParsedTrendQuery,
) !void {
    const now = currentSeconds() catch {
        try writeError(output, .{
            .status = 503,
            .title = "Clock unavailable",
            .message = "The server could not determine a safe analysis calendar.",
        });
        return;
    };
    const sites = try dependencies.metadata.listSites(dependencies.allocator);
    if (sites.len == 0) {
        try writeFirstRun(output, dependencies.collection_available);
        return;
    }
    const selected = controller.resolveSite(sites, route.site) catch {
        try writeError(output, .{
            .status = 404,
            .title = "Analysis not found",
            .message = "The selected site no longer exists.",
        });
        return;
    };
    const site_calendar = dependencies.site_calendar orelse {
        try calendarUnavailable(output);
        return;
    };
    const selected_calendar = site_calendar.find(selected.id) orelse {
        try calendarUnavailable(output);
        return;
    };
    const default_range = calendar.rangeForPreset(
        selected_calendar.zone,
        now,
        .last_30_days,
    ) catch {
        try calendarUnavailable(output);
        return;
    };
    const default_series = [_]analysis.Metric{.{ .kind = .visitors }};
    const default_query = model.Query{
        .site = selected.slug,
        .analysis_site_id = selected.id,
        .range = default_range.view(),
        .comparison = .previous,
        .kind = .overview,
        .analysis_series = &default_series,
    };
    const parsed = translated orelse parsed: {
        if (hasRawQueryField(request.target, "v")) {
            const marker = std.mem.findScalar(u8, request.target, '?') orelse {
                try invalidTrendQueryPage(dependencies.allocator, output, default_query);
                return;
            };
            const canonical = analysis.parseCanonicalTrendSetUrl(
                dependencies.allocator,
                selected.id,
                request.target[marker + 1 ..],
            ) catch {
                try invalidTrendQueryPage(dependencies.allocator, output, default_query);
                return;
            };
            break :parsed controller.ParsedTrendQuery{
                .from = canonical.set.range.start,
                .to = canonical.set.range.end,
                .comparison = canonical.set.comparison,
                .interval = canonical.set.interval,
                .series = canonical.set.series,
                .highlighted_interval = canonical.highlight,
                .filters = canonical.set.filters,
                .segment_id = canonical.set.segment_id,
            };
        }
        break :parsed controller.parseTrendQuery(
            dependencies.allocator,
            request.target,
        ) catch {
            try invalidTrendQueryPage(dependencies.allocator, output, default_query);
            return;
        };
    };
    const query = controller.finishTrendQuery(
        parsed,
        selected.slug,
        selected.id,
        &default_range,
        .previous,
    ) catch {
        try invalidTrendQueryPage(dependencies.allocator, output, default_query);
        return;
    };
    const resolved_calendar = calendar.resolve(
        selected_calendar.zone,
        selected_calendar.timezone_name,
        now,
        query.range,
        query.comparison,
    ) catch {
        try invalidTrendQueryPage(dependencies.allocator, output, default_query);
        return;
    };
    controller.validateTrendHighlight(
        dependencies.allocator,
        query,
        resolved_calendar,
        selected_calendar.zone,
    ) catch {
        try writeError(output, .{
            .status = 400,
            .title = "Invalid report request",
            .message = "The highlighted interval is not part of the generated current or comparison Trend buckets.",
            .return_url = request.target,
        });
        return;
    };
    if (!try isCanonicalTarget(
        dependencies.allocator,
        request.target,
        .analyze,
        query,
        "",
    )) {
        try redirectToCanonical(
            dependencies.allocator,
            output,
            .analyze,
            query,
            "",
        );
        return;
    }
    const loaded = controller.loadTrendPage(
        dependencies.allocator,
        dependencies.metadata,
        dependencies.events,
        query,
        resolved_calendar,
        selected_calendar.zone,
        dependencies.csrf_token,
        dependencies.report_timeout_ms,
    ) catch |err| {
        if (err == error.ReportTimeout) {
            try writeError(output, .{
                .status = 503,
                .title = "Analysis timed out",
                .message = "The analysis exceeded its shared server deadline. Narrow the selected date range or reduce the series and retry.",
                .return_url = request.target,
            });
        } else if (err == error.StaleFilterProperty) {
            try staleFilterPage(
                dependencies.allocator,
                output,
                .analyze,
                query,
            );
        } else if (isStaleSegmentError(err)) {
            try staleSegmentPage(
                dependencies.allocator,
                output,
                .analyze,
                query,
            );
        } else if (err == error.TooManyAnalyzeTrendSeries) {
            try writeError(output, .{
                .status = 422,
                .title = "Too many visual series",
                .message = "Exact currencies remain separate, and this result expands beyond the three-series display limit. Select fewer amount metrics or narrower subjects.",
                .return_url = request.target,
            });
        } else if (err == error.GoalNotFound or isInvalidInput(err)) {
            try writeError(output, .{
                .status = 400,
                .title = "Invalid analysis request",
                .message = "The typed metric, subject, interval, or highlighted interval is no longer valid for this site.",
                .return_url = request.target,
            });
        } else {
            return err;
        }
        return;
    };
    try writePage(output, 200, loaded);
}

fn kindAllowed(route: Route, kind: report.Kind) bool {
    return switch (route.destination) {
        .overview => kind == .overview,
        .analyze => kind.isList(),
        .journeys => kind == route.default_kind,
        .sessions, .settings => kind == .overview,
        .live => kind == .traffic_quality,
    };
}

fn legacyDestination(kind: report.Kind) model.Destination {
    return switch (kind) {
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
}

fn postAnalysisAction(
    dependencies: Dependencies,
    request: request_mod.Request,
    output: *std.Io.Writer,
    action: AnalysisAction,
) !void {
    if (!validFormContentType(try request.header("content-type"))) {
        try writeError(output, .{
            .status = 415,
            .title = "Unsupported form",
            .message = "Use a normal URL-encoded HTML form.",
        });
        return;
    }
    if (!try sameOrigin(request, dependencies.origin)) {
        try writeError(output, .{
            .status = 403,
            .title = "Forbidden",
            .message = "The saved analysis form did not come from this dashboard origin.",
        });
        return;
    }
    const form = controller.Form.parseSavedState(
        dependencies.allocator,
        request.body,
    ) catch {
        try writeError(output, .{
            .status = 400,
            .title = "Invalid saved analysis form",
            .message = "The submitted state was malformed or exceeded its bounded size.",
        });
        return;
    };
    controller.verifyCsrf(form, dependencies.csrf_token) catch {
        try writeError(output, .{
            .status = 403,
            .title = "Forbidden",
            .message = "The form token was missing or stale. Reload and try again.",
        });
        return;
    };
    const needs_state = switch (action) {
        .apply_filter,
        .suggest_filter,
        .remove_filter,
        .create_segment,
        .update_segment,
        .rename_segment,
        .duplicate_segment,
        .create_saved_view,
        => true,
        .delete_segment => form.optional("state") != null,
        .duplicate_saved_view,
        .rename_saved_view,
        .delete_saved_view,
        => false,
    };
    var target: ?controller.AnalysisTarget = if (needs_state)
        controller.analysisTargetFromForm(
            dependencies.allocator,
            dependencies.metadata,
            form,
        ) catch |err| {
            try analysisMutationError(output, err);
            return;
        }
    else
        null;
    if (action == .suggest_filter) {
        const suggested = controller.suggestionsFromForm(
            dependencies.allocator,
            dependencies.metadata,
            dependencies.events,
            form,
            dependencies.report_timeout_ms,
        ) catch |err| {
            try analysisMutationError(output, err);
            return;
        };
        var page = loadAnalysisTargetPage(
            dependencies,
            suggested.target,
        ) catch |err| {
            try analysisMutationError(output, err);
            return;
        };
        page.filter_suggestions = suggested.suggestions;
        try writePage(output, 200, page);
        return;
    }
    const now: i64 = switch (action) {
        .create_segment,
        .update_segment,
        .rename_segment,
        .duplicate_segment,
        .create_saved_view,
        .duplicate_saved_view,
        .rename_saved_view,
        => currentMicros() catch {
            try writeError(output, .{
                .status = 503,
                .title = "Clock unavailable",
                .message = "The server could not safely timestamp this saved state.",
            });
            return;
        },
        else => 0,
    };
    switch (action) {
        .apply_filter => target = controller.applyFilterFromForm(
            dependencies.allocator,
            dependencies.metadata,
            form,
        ) catch |err| {
            try analysisMutationError(output, err);
            return;
        },
        .suggest_filter => unreachable,
        .remove_filter => target = controller.removeFilterFromForm(
            dependencies.allocator,
            dependencies.metadata,
            form,
        ) catch |err| {
            try analysisMutationError(output, err);
            return;
        },
        .create_segment => controller.createSegmentFromForm(
            dependencies.allocator,
            dependencies.io,
            dependencies.metadata,
            form,
            now,
        ) catch |err| {
            try analysisMutationError(output, err);
            return;
        },
        .update_segment => controller.updateSegmentFromForm(
            dependencies.allocator,
            dependencies.metadata,
            form,
            now,
        ) catch |err| {
            try analysisMutationError(output, err);
            return;
        },
        .rename_segment => controller.renameSegmentFromForm(
            dependencies.allocator,
            dependencies.metadata,
            form,
            now,
        ) catch |err| {
            try analysisMutationError(output, err);
            return;
        },
        .duplicate_segment => controller.duplicateSegmentFromForm(
            dependencies.allocator,
            dependencies.io,
            dependencies.metadata,
            form,
            now,
        ) catch |err| {
            try analysisMutationError(output, err);
            return;
        },
        .delete_segment => target = controller.deleteSegmentFromForm(
            dependencies.allocator,
            dependencies.metadata,
            form,
        ) catch |err| {
            try analysisMutationError(output, err);
            return;
        },
        .create_saved_view => controller.createSavedViewFromForm(
            dependencies.allocator,
            dependencies.io,
            dependencies.metadata,
            form,
            now,
        ) catch |err| {
            try analysisMutationError(output, err);
            return;
        },
        .duplicate_saved_view => controller.duplicateSavedViewFromForm(
            dependencies.allocator,
            dependencies.io,
            dependencies.metadata,
            form,
            now,
        ) catch |err| {
            try analysisMutationError(output, err);
            return;
        },
        .rename_saved_view => controller.renameSavedViewFromForm(
            dependencies.allocator,
            dependencies.metadata,
            form,
            now,
        ) catch |err| {
            try analysisMutationError(output, err);
            return;
        },
        .delete_saved_view => controller.deleteSavedViewFromForm(
            dependencies.allocator,
            dependencies.metadata,
            form,
        ) catch |err| {
            try analysisMutationError(output, err);
            return;
        },
    }
    if (target) |resolved| {
        try redirectToCanonical(
            dependencies.allocator,
            output,
            resolved.destination,
            resolved.query,
            "",
        );
        return;
    }
    const site = try form.required("site");
    if (action == .duplicate_saved_view or action == .rename_saved_view) {
        const id = try form.required("id");
        var location = std.Io.Writer.Allocating.init(dependencies.allocator);
        defer location.deinit();
        try location.writer.print(
            "/admin/sites/{s}/saved-views/{s}",
            .{ site, id },
        );
        try redirectLocal(output, location.written());
    } else {
        var location = std.Io.Writer.Allocating.init(dependencies.allocator);
        defer location.deinit();
        try location.writer.print("/admin/sites/{s}/overview", .{site});
        try redirectLocal(output, location.written());
    }
}

fn redirectLocal(output: *std.Io.Writer, location: []const u8) !void {
    var headers = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer headers.deinit();
    try headers.writer.print(
        "Cache-Control: no-store\r\nLocation: {s}\r\n",
        .{location},
    );
    try response.write(
        output,
        303,
        "text/plain; charset=utf-8",
        headers.written(),
        "See Other\n",
    );
}

fn loadAnalysisTargetPage(
    dependencies: Dependencies,
    target: controller.AnalysisTarget,
) !model.Page {
    const sites = try dependencies.metadata.listSites(dependencies.allocator);
    const selected = try controller.resolveSite(sites, target.query.site);
    const lookup = dependencies.site_calendar orelse
        return error.SiteCalendarUnavailable;
    const selected_calendar = lookup.find(selected.id) orelse
        return error.SiteCalendarUnavailable;
    const context = try calendar.resolve(
        selected_calendar.zone,
        selected_calendar.timezone_name,
        try currentSeconds(),
        target.query.range,
        target.query.comparison,
    );
    if (target.destination == .overview) {
        var page = try controller.loadPage(
            dependencies.allocator,
            dependencies.metadata,
            dependencies.events,
            .overview,
            target.query,
            context,
            selected_calendar.zone,
            dependencies.csrf_token,
            "",
            dependencies.report_timeout_ms,
        );
        const diagnostics = dependencies.diagnostics orelse
            return error.MissingDiagnosticsLookup;
        page.collection_diagnostics = try diagnostics.get(
            dependencies.allocator,
            selected.id,
        );
        return page;
    }
    if (target.query.analysis_breakdown != null) {
        return controller.loadBreakdownPage(
            dependencies.allocator,
            dependencies.metadata,
            dependencies.events,
            target.query,
            context,
            dependencies.csrf_token,
            dependencies.report_timeout_ms,
        );
    }
    try controller.validateTrendHighlight(
        dependencies.allocator,
        target.query,
        context,
        selected_calendar.zone,
    );
    return controller.loadTrendPage(
        dependencies.allocator,
        dependencies.metadata,
        dependencies.events,
        target.query,
        context,
        selected_calendar.zone,
        dependencies.csrf_token,
        dependencies.report_timeout_ms,
    );
}

fn analysisMutationError(output: *std.Io.Writer, err: anyerror) !void {
    std.log.warn("analysis state mutation rejected: {s}", .{@errorName(err)});
    if (err == error.AnalysisTimeout or err == error.ReportTimeout) {
        try writeError(output, .{
            .status = 503,
            .title = "Analysis timed out",
            .message = "The filter preview or analysis exceeded its shared server deadline. Narrow the date range or preceding filters and retry.",
        });
        return;
    }
    try writeError(output, .{
        .status = 422,
        .title = "Saved analysis state was not changed",
        .message = "The filter, segment, or saved view is invalid, stale, duplicated, over its bound, or belongs to another site. Reload the analysis and correct the highlighted state.",
    });
}

fn postAction(
    dependencies: Dependencies,
    request: request_mod.Request,
    output: *std.Io.Writer,
    action: Action,
) !void {
    if (!validFormContentType(try request.header("content-type"))) {
        try writeError(output, .{
            .status = 415,
            .title = "Unsupported form",
            .message = "Use a normal URL-encoded HTML form.",
        });
        return;
    }
    if (!try sameOrigin(request, dependencies.origin)) {
        try writeError(output, .{
            .status = 403,
            .title = "Forbidden",
            .message = "The modifying form did not come from this dashboard origin.",
        });
        return;
    }
    const form = controller.Form.parse(
        dependencies.allocator,
        request.body,
    ) catch {
        try writeError(output, .{
            .status = 400,
            .title = "Invalid form",
            .message = "The submitted form was malformed or too large.",
        });
        return;
    };
    controller.verifyCsrf(form, dependencies.csrf_token) catch {
        try writeError(output, .{
            .status = 403,
            .title = "Forbidden",
            .message = "The form token was missing or stale. Reload and try again.",
        });
        return;
    };
    const form_context = controller.formContext(form) catch {
        try writeError(output, .{
            .status = 400,
            .title = "Invalid form",
            .message = "The submitted report date range was missing or invalid.",
        });
        return;
    };
    const now = currentMicros() catch {
        try writeError(output, .{
            .status = 503,
            .title = "Clock unavailable",
            .message = "The server could not safely timestamp this change.",
        });
        return;
    };
    const operation = switch (action) {
        .add_goal => controller.addGoal(
            dependencies.allocator,
            dependencies.io,
            dependencies.metadata,
            dependencies.events,
            form,
            now,
            dependencies.report_timeout_ms,
        ),
        .edit_goal => controller.editGoal(
            dependencies.allocator,
            dependencies.metadata,
            dependencies.events,
            form,
            now,
            dependencies.report_timeout_ms,
        ),
        .duplicate_goal => controller.duplicateGoal(
            dependencies.allocator,
            dependencies.io,
            dependencies.metadata,
            form,
            now,
        ),
        .archive_goal => controller.archiveGoal(
            dependencies.allocator,
            dependencies.metadata,
            form,
            now,
        ),
        .reactivate_goal => controller.reactivateGoal(
            dependencies.allocator,
            dependencies.metadata,
            form,
            now,
        ),
        .delete_goal => controller.deleteGoal(
            dependencies.allocator,
            dependencies.metadata,
            form,
        ),
        .add_funnel => controller.addFunnel(
            dependencies.allocator,
            dependencies.io,
            dependencies.metadata,
            form,
            now,
        ),
        .delete_funnel => controller.deleteFunnel(
            dependencies.allocator,
            dependencies.metadata,
            form,
        ),
        .add_excluded_network => controller.addExcludedNetwork(
            dependencies.allocator,
            dependencies.metadata,
            form,
            now,
        ),
        .delete_excluded_network => controller.deleteExcludedNetwork(
            dependencies.allocator,
            dependencies.metadata,
            form,
        ),
        .update_traffic_policy => controller.updateTrafficPolicy(
            dependencies.allocator,
            dependencies.metadata,
            form,
            now,
        ),
    };
    operation catch |err| {
        if (err == error.ReportTimeout) {
            try writeError(output, .{
                .status = 503,
                .title = "Goal validation timed out",
                .message = "The goal was not saved because observed-entity validation exceeded the report deadline. Narrow the date range and retry.",
            });
            return;
        }
        if (!isFormError(err)) return err;
        try formErrorPage(dependencies, output, form, action, err);
        return;
    };
    if (action == .add_excluded_network or
        action == .delete_excluded_network or
        action == .update_traffic_policy)
    {
        if (dependencies.policy_refresh) |refresh| {
            refresh.run() catch {
                try writeError(output, .{
                    .status = 503,
                    .title = "Collection policy refresh failed",
                    .message = "The network setting was stored, but the running collector could not refresh it. Restart the service before relying on the change.",
                });
                return;
            };
        }
    }
    const site = try form.required("site");
    const destination: model.Destination = switch (action) {
        .add_goal,
        .edit_goal,
        .duplicate_goal,
        .archive_goal,
        .reactivate_goal,
        .delete_goal,
        .add_funnel,
        .delete_funnel,
        => .journeys,
        .add_excluded_network, .delete_excluded_network, .update_traffic_policy => .settings,
    };
    const kind: report.Kind = switch (action) {
        .add_funnel, .delete_funnel => .funnel,
        .add_goal,
        .edit_goal,
        .duplicate_goal,
        .archive_goal,
        .reactivate_goal,
        .delete_goal,
        => .goal,
        .add_excluded_network, .delete_excluded_network, .update_traffic_policy => .overview,
    };
    try redirectToCanonical(dependencies.allocator, output, destination, .{
        .site = site,
        .range = form_context.range,
        .comparison = form_context.comparison,
        .kind = kind,
    }, switch (action) {
        .add_goal => "goal-added",
        .edit_goal => "goal-updated",
        .duplicate_goal => "goal-duplicated",
        .archive_goal => "goal-archived",
        .reactivate_goal => "goal-reactivated",
        .delete_goal => "goal-deleted",
        .add_funnel => "funnel-added",
        .delete_funnel => "funnel-deleted",
        .add_excluded_network => "network-exclusion-added",
        .delete_excluded_network => "network-exclusion-deleted",
        .update_traffic_policy => "traffic-policy-updated",
    });
}

fn formErrorPage(
    dependencies: Dependencies,
    output: *std.Io.Writer,
    form: controller.Form,
    action: Action,
    failure: anyerror,
) !void {
    const form_context = controller.formContext(form) catch {
        try writeError(output, .{
            .status = 400,
            .title = "Invalid form",
            .message = "The submitted report date range was missing or invalid.",
        });
        return;
    };
    const site = form.required("site") catch "";
    var query = model.Query{
        .site = site,
        .range = form_context.range,
        .comparison = form_context.comparison,
        .kind = switch (action) {
            .add_goal,
            .edit_goal,
            .duplicate_goal,
            .archive_goal,
            .reactivate_goal,
            .delete_goal,
            => .goal,
            .add_funnel, .delete_funnel => .funnel,
            .add_excluded_network, .delete_excluded_network, .update_traffic_policy => .overview,
        },
    };
    switch (action) {
        .add_goal => query.goal_screen = .new,
        .edit_goal => {
            query.goal_screen = .edit;
            query.goal_id = form.required("id") catch "";
        },
        .duplicate_goal,
        .archive_goal,
        .reactivate_goal,
        .delete_goal,
        => {
            query.goal_screen = .detail;
            query.goal_id = form.required("id") catch "";
        },
        else => {},
    }
    if (query.goal_screen == .new or query.goal_screen == .edit) {
        query.goal_entity_set = true;
        query.goal_entity_kind = if (std.mem.eql(
            u8,
            form.required("entity") catch "page",
            "event",
        )) .event else .page;
        query.goal_search = form.optional("search") orelse "";
    }
    const resolved_calendar = resolvePageCalendar(dependencies, query) catch {
        try writeError(output, .{
            .status = 503,
            .title = "Site calendar unavailable",
            .message = "The form was not retried because the selected site's validated timezone is unavailable. Restore the site policy or restart the service, then reload.",
        });
        return;
    };
    var page = controller.loadPage(
        dependencies.allocator,
        dependencies.metadata,
        dependencies.events,
        switch (action) {
            .add_goal,
            .edit_goal,
            .duplicate_goal,
            .archive_goal,
            .reactivate_goal,
            .delete_goal,
            .add_funnel,
            .delete_funnel,
            => .journeys,
            .add_excluded_network, .delete_excluded_network, .update_traffic_policy => .settings,
        },
        query,
        resolved_calendar,
        null,
        dependencies.csrf_token,
        "",
        dependencies.report_timeout_ms,
    ) catch {
        try writeError(output, .{
            .status = 422,
            .title = "Invalid form",
            .message = "Correct the highlighted values and try again.",
        });
        return;
    };
    page.form_error = if (failure == error.GoalReferenced)
        "This goal is used by a saved view. It was not deleted; archive it instead or remove the saved reference first."
    else if (failure == error.GoalConfirmationMismatch)
        "The goal was not deleted because the confirmation did not exactly match its current name."
    else if (failure == error.GoalNotObserved)
        "No matching Page or Event was seen in this date range. Confirm the zero-seen definition explicitly to save it."
    else if (failure == error.GoalNameConflict)
        "The goal was not saved because this site already has a goal with that name."
    else if (failure == error.StaleGoal)
        "The goal changed after this form loaded. Reload its current detail before retrying."
    else if (failure == error.TooManyActiveGoals)
        "This site already has 32 active goals. Archive one before creating or reactivating another."
    else if (action == .update_traffic_policy)
        "The traffic policy was not saved. Use a ceiling from 1 to 10,000,000; strict mode also requires at most 32 goals."
    else if (action == .add_excluded_network or
        action == .delete_excluded_network)
        "The network exclusion was not saved. Enter an IPv4 address or /24, or an IPv6 address or /48."
    else
        "The definition was not saved. Check its name, match kind, value, and step count.";
    page.form_error_target = switch (action) {
        .add_goal, .edit_goal => .goal,
        .add_funnel => .funnel,
        .add_excluded_network => .network,
        .update_traffic_policy => .traffic_policy,
        .duplicate_goal => .goal_duplicate,
        .archive_goal,
        .reactivate_goal,
        .delete_goal,
        .delete_funnel,
        .delete_excluded_network,
        => .none,
    };
    if (action == .add_goal or action == .edit_goal) {
        page.goal_draft = .{
            .name = form.required("name") catch "",
            .entity_kind = query.goal_entity_kind,
            .match_kind = form.required("match") catch "exact",
            .match_value = form.required("value") catch "",
            .confirm_unseen = if (form.optional("confirm_unseen")) |value|
                std.mem.eql(u8, value, "on")
            else
                false,
        };
    } else if (action == .duplicate_goal) {
        page.goal_draft.name = form.required("name") catch "";
    } else if (action == .add_funnel) {
        page.funnel_draft = .{
            .name = form.required("name") catch "",
            .steps = form.required("steps") catch "",
        };
    } else if (action == .add_excluded_network) {
        page.network_draft = form.required("network") catch "";
    } else if (action == .update_traffic_policy) {
        page.traffic_policy_draft = .{
            .strict_mode = if (form.optional("strict")) |strict|
                std.mem.eql(u8, strict, "on")
            else
                false,
            .daily_event_ceiling = form.required("daily_event_ceiling") catch "",
        };
    }
    try writePage(output, if (failure == error.GoalReferenced) 409 else 422, page);
}

fn writePage(output: *std.Io.Writer, status: u16, page: model.Page) !void {
    var body = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer body.deinit();
    try render.page(&body.writer, page);
    try response.write(
        output,
        status,
        "text/html; charset=utf-8",
        render.headers,
        body.written(),
    );
}

fn writeError(output: *std.Io.Writer, value: model.ErrorPage) !void {
    var body = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer body.deinit();
    try render.errorPage(&body.writer, value);
    try response.write(
        output,
        value.status,
        "text/html; charset=utf-8",
        render.headers,
        body.written(),
    );
}

fn sameOrigin(
    request: request_mod.Request,
    expected: []const u8,
) !bool {
    const raw_origin = (try request.header("origin")) orelse return false;
    if (raw_origin.len != expected.len) return false;
    var difference: u8 = 0;
    for (raw_origin, expected) |actual, wanted| difference |= actual ^ wanted;
    return difference == 0;
}

fn validFormContentType(value: ?[]const u8) bool {
    const actual = value orelse return false;
    const before_parameters = if (std.mem.cutScalar(u8, actual, ';')) |parts|
        parts[0]
    else
        actual;
    const base = std.mem.trim(
        u8,
        before_parameters,
        " \t",
    );
    return std.ascii.eqlIgnoreCase(base, "application/x-www-form-urlencoded");
}

fn currentSeconds() !i64 {
    var timestamp: std.os.linux.timespec = undefined;
    const result = std.os.linux.clock_gettime(.REALTIME, &timestamp);
    if (std.os.linux.errno(result) != .SUCCESS or timestamp.sec < 0) {
        return error.ClockUnavailable;
    }
    return timestamp.sec;
}

fn currentUtcRange(now_seconds: i64) !calendar.Range {
    if (now_seconds < 29 * std.time.s_per_day) return error.ClockUnavailable;
    return .{
        .start = try dateForSeconds(now_seconds - 29 * std.time.s_per_day),
        .end = try dateForSeconds(now_seconds),
    };
}

fn currentMicros() !i64 {
    var timestamp: std.os.linux.timespec = undefined;
    const result = std.os.linux.clock_gettime(.REALTIME, &timestamp);
    if (std.os.linux.errno(result) != .SUCCESS or timestamp.sec < 0) {
        return error.ClockUnavailable;
    }
    return std.math.add(
        i64,
        try std.math.mul(i64, timestamp.sec, 1_000_000),
        @divTrunc(timestamp.nsec, 1_000),
    );
}

fn dateForSeconds(seconds: i64) ![10]u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var date: [10]u8 = undefined;
    _ = try std.fmt.bufPrint(&date, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        @backingInt(month_day.month),
        month_day.day_index + 1,
    });
    return date;
}

fn noticeMessage(code: []const u8) []const u8 {
    if (std.mem.eql(u8, code, "goal-added")) {
        return "Goal added.";
    }
    if (std.mem.eql(u8, code, "goal-updated")) return "Goal updated.";
    if (std.mem.eql(u8, code, "goal-duplicated")) return "Goal duplicated.";
    if (std.mem.eql(u8, code, "goal-archived")) return "Goal archived.";
    if (std.mem.eql(u8, code, "goal-reactivated")) return "Goal reactivated.";
    if (std.mem.eql(u8, code, "goal-deleted")) {
        return "Goal deleted.";
    }
    if (std.mem.eql(u8, code, "funnel-added")) {
        return "Funnel added.";
    }
    if (std.mem.eql(u8, code, "funnel-deleted")) {
        return "Funnel deleted.";
    }
    if (std.mem.eql(u8, code, "network-exclusion-added")) {
        return "Network exclusion added and collection policy refreshed.";
    }
    if (std.mem.eql(u8, code, "network-exclusion-deleted")) {
        return "Network exclusion deleted and collection policy refreshed.";
    }
    if (std.mem.eql(u8, code, "traffic-policy-updated")) {
        return "Traffic policy updated and collection policy refreshed.";
    }
    return "";
}

fn resolvePageCalendar(
    dependencies: Dependencies,
    query: model.Query,
) !calendar.Context {
    const sites = try dependencies.metadata.listSites(dependencies.allocator);
    const selected = try controller.resolveSite(sites, query.site);
    const lookup = dependencies.site_calendar orelse
        return error.SiteCalendarUnavailable;
    const selected_calendar = lookup.find(selected.id) orelse
        return error.SiteCalendarUnavailable;
    return calendar.resolve(
        selected_calendar.zone,
        selected_calendar.timezone_name,
        try currentSeconds(),
        query.range,
        query.comparison,
    );
}

fn redirectToCanonical(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    destination: model.Destination,
    query: model.Query,
    notice: []const u8,
) !void {
    var location = std.Io.Writer.Allocating.init(allocator);
    try canonicalUrl(&location.writer, destination, query);
    if (notice.len != 0) {
        try location.writer.writeAll("&notice=");
        try urlComponent(&location.writer, notice);
    }
    var headers = std.Io.Writer.Allocating.init(allocator);
    try headers.writer.print(
        "Cache-Control: no-store\r\nLocation: {s}\r\n",
        .{location.written()},
    );
    try response.write(
        output,
        303,
        "text/plain; charset=utf-8",
        headers.written(),
        "see other\n",
    );
}

fn isCanonicalTarget(
    allocator: std.mem.Allocator,
    target: []const u8,
    destination: model.Destination,
    query: model.Query,
    notice: []const u8,
) !bool {
    var expected = std.Io.Writer.Allocating.init(allocator);
    try canonicalUrl(&expected.writer, destination, query);
    if (notice.len != 0) {
        try expected.writer.writeAll("&notice=");
        try urlComponent(&expected.writer, notice);
    }
    return std.mem.eql(u8, target, expected.written());
}

fn invalidQueryPage(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    destination: model.Destination,
    default_query: model.Query,
) !void {
    var reset = std.Io.Writer.Allocating.init(allocator);
    try canonicalUrl(&reset.writer, destination, default_query);
    try writeError(output, .{
        .status = 400,
        .title = "Invalid calendar or report state",
        .message = "The URL has an invalid, duplicate, incomplete, or unsupported field. Reset to the site's default calendar and try again.",
        .return_url = reset.written(),
    });
}

fn invalidTrendQueryPage(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    default_query: model.Query,
) !void {
    var reset = std.Io.Writer.Allocating.init(allocator);
    try canonicalUrl(&reset.writer, .analyze, default_query);
    try writeError(output, .{
        .status = 400,
        .title = "Invalid analysis request",
        .message = "The URL has an invalid, duplicate, incomplete, or unsupported typed metric, subject, interval, or series field.",
        .return_url = reset.written(),
    });
}

fn invalidBreakdownQueryPage(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    status: u16,
    default_query: model.Query,
) !void {
    var reset = std.Io.Writer.Allocating.init(allocator);
    try canonicalUrl(&reset.writer, .analyze, default_query);
    try writeError(output, .{
        .status = status,
        .title = if (status == 422)
            "Unsupported Breakdown combination"
        else
            "Invalid analysis request",
        .message = if (status == 422)
            "New and returning visitors cannot be grouped by an event property. Choose Visitors or another standard dimension."
        else
            "The URL has an invalid, duplicate, incomplete, or unsupported metric, subject, dimension, property type, search, sort, page, or limit field.",
        .return_url = reset.written(),
    });
}

fn calendarUnavailable(output: *std.Io.Writer) !void {
    try writeError(output, .{
        .status = 503,
        .title = "Site calendar unavailable",
        .message = "The report was not run because the selected site's validated timezone is unavailable. Restore the site policy or restart the service, then retry.",
    });
}

fn canonicalUrl(
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
        .sessions => try output.writeAll("/sessions"),
        .live => try output.writeAll("/live"),
        .settings => try output.writeAll("/settings/general"),
    }
    if (destination == .overview) {
        try output.writeAll("?v=1&from=");
        try urlComponent(output, query.range.start);
        try output.writeAll("&to=");
        try urlComponent(output, query.range.end);
        try output.writeAll("&compare=");
        try urlComponent(output, query.comparison.name());
        try output.writeAll("&metric=");
        if (query.overview_metric == .revenue) {
            try output.writeAll("revenue-");
            try urlComponent(output, query.overview_currency);
        } else {
            try urlComponent(output, query.overview_metric.name());
        }
        const suffix = try analysis.canonicalFilterUrlSuffix(
            std.heap.page_allocator,
            query.analysis_segment_id,
            query.analysis_filters,
        );
        defer std.heap.page_allocator.free(suffix);
        if (suffix.len != 0) {
            try output.writeByte('&');
            try output.writeAll(suffix);
        }
        return;
    }
    if (destination == .analyze and query.analysis_breakdown != null) {
        const parameters = try analysis.canonicalUrl(
            std.heap.page_allocator,
            query.analysis_breakdown.?,
        );
        defer std.heap.page_allocator.free(parameters);
        try output.writeByte('?');
        try output.writeAll(parameters);
        return;
    }
    if (destination == .analyze and query.analysis_series.len != 0) {
        const parameters = try analysis.canonicalTrendSetUrl(
            std.heap.page_allocator,
            .{
                .site_id = query.analysis_site_id,
                .range = query.range,
                .comparison = query.comparison,
                .interval = query.analysis_interval,
                .series = query.analysis_series,
                .filters = query.analysis_filters,
                .segment_id = query.analysis_segment_id,
            },
            query.highlighted_interval,
        );
        defer std.heap.page_allocator.free(parameters);
        try output.writeByte('?');
        try output.writeAll(parameters);
        return;
    }
    try output.writeAll("?from=");
    try urlComponent(output, query.range.start);
    try output.writeAll("&to=");
    try urlComponent(output, query.range.end);
    try output.writeAll("&compare=");
    try urlComponent(output, query.comparison.name());
    switch (destination) {
        .analyze => {
            try output.writeAll("&report=");
            try urlComponent(output, query.kind.name());
            if (query.kind == .campaigns) {
                try output.writeAll("&campaign=");
                try urlComponent(output, @tagName(query.campaign_dimension));
            }
            if (query.kind.isList()) {
                try output.writeAll("&sort=");
                try urlComponent(output, @tagName(query.sort));
            }
            if (query.kind.isPaginated()) {
                try output.print("&limit={d}&page={d}", .{ query.limit, query.page });
            }
            if (query.overview_metric != .visitors) {
                try output.writeAll("&focus=");
                if (query.overview_metric == .revenue) {
                    try output.writeAll("revenue-");
                    try urlComponent(output, query.overview_currency);
                } else {
                    try urlComponent(output, query.overview_metric.name());
                }
            }
            if (query.highlighted_interval.len != 0) {
                try output.writeAll("&highlight=");
                try urlComponent(output, query.highlighted_interval);
            }
        },
        .journeys => if (query.goal_screen != .none) {
            if (query.goal_screen == .list and query.goal_page != 1) {
                try output.print("&goal-page={d}", .{query.goal_page});
            }
            if (query.goal_screen == .new or query.goal_screen == .edit) {
                if (query.goal_entity_set or query.goal_entity_kind == .event) {
                    try output.writeAll(if (query.goal_entity_kind == .event)
                        "&entity=event"
                    else
                        "&entity=page");
                }
                if (query.goal_search.len != 0) {
                    try output.writeAll("&search=");
                    try urlComponent(output, query.goal_search);
                }
                if (query.goal_entity_page != 1) {
                    try output.print("&entity-page={d}", .{query.goal_entity_page});
                }
            }
        } else if (query.subject.len != 0) {
            try output.writeAll("&subject=");
            try urlComponent(output, query.subject);
        },
        .live => if (query.limit != report.default_limit or query.page != 1) {
            try output.print("&limit={d}&page={d}", .{ query.limit, query.page });
        },
        .overview => if (query.overview_metric != .visitors) {
            try output.writeAll("&metric=");
            if (query.overview_metric == .revenue) {
                try output.writeAll("revenue-");
                try urlComponent(output, query.overview_currency);
            } else {
                try urlComponent(output, query.overview_metric.name());
            }
        },
        .sessions, .settings => {},
    }
}

fn isInvalidInput(err: anyerror) bool {
    return switch (err) {
        error.InvalidSlug,
        error.InvalidDate,
        error.InvalidReportRange,
        error.InvalidName,
        error.InvalidReportPage,
        error.InvalidReportLimit,
        error.ReportOptionsNotApplicable,
        error.ReportSubjectNotApplicable,
        error.InvalidOverviewMetric,
        error.InvalidOverviewHighlight,
        error.OverviewMetricNotApplicable,
        error.OverviewHighlightNotApplicable,
        error.AnalysisOptionsNotApplicable,
        error.InvalidBreakdownMetric,
        error.InvalidAnalysisSite,
        error.InvalidAnalyzeTrendResult,
        error.InvalidTrendSeries,
        error.InvalidTrendSubject,
        error.InvalidTrendHighlight,
        error.InvalidAnalysisRange,
        error.InvalidAnalysisInterval,
        error.HourIntervalRangeTooLarge,
        => true,
        else => false,
    };
}

fn isStaleSegmentError(err: anyerror) bool {
    return switch (err) {
        error.SegmentNotFound,
        error.StaleSegmentState,
        error.StaleSegmentProperty,
        error.TooManyAnalysisClauses,
        => true,
        else => false,
    };
}

fn staleFilterPage(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    destination: model.Destination,
    query: model.Query,
) !void {
    var reset = query;
    reset.analysis_filters = .{};
    if (reset.analysis_breakdown) |*breakdown| breakdown.filters = .{};
    var return_url = std.Io.Writer.Allocating.init(allocator);
    defer return_url.deinit();
    try canonicalUrl(&return_url.writer, destination, reset);
    try writeError(output, .{
        .status = 422,
        .title = "Filter is stale",
        .message = "An ad-hoc property filter references a property that this site no longer collects. Remove the stale ad-hoc filters, then inspect or recreate the affected saved view.",
        .return_url = return_url.written(),
    });
}

fn staleSegmentPage(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    destination: model.Destination,
    query: model.Query,
) !void {
    var reset = query;
    reset.analysis_segment_id = null;
    if (reset.analysis_breakdown) |*breakdown| breakdown.segment_id = null;
    var return_url = std.Io.Writer.Allocating.init(allocator);
    defer return_url.deinit();
    try canonicalUrl(&return_url.writer, destination, reset);
    try writeError(output, .{
        .status = 422,
        .title = "Saved segment is stale",
        .message = "The selected segment is missing, corrupt, over the composed filter bound, or references a property that is no longer collected. Remove it, inspect the remaining ad-hoc filters, and choose or recreate a valid segment.",
        .return_url = return_url.written(),
    });
}

fn isFormError(err: anyerror) bool {
    return switch (err) {
        error.MissingFormField,
        error.InvalidSlug,
        error.InvalidName,
        error.InvalidIdentifier,
        error.InvalidMatchKind,
        error.InvalidGoalEntityKind,
        error.InvalidGoalMatch,
        error.InvalidGoalTimestamp,
        error.GoalNotObserved,
        error.GoalNameConflict,
        error.GoalConfirmationMismatch,
        error.GoalReferenced,
        error.StaleGoal,
        error.InvalidPath,
        error.InvalidFunnelLength,
        error.InvalidFunnelStep,
        error.GoalNotFound,
        error.FunnelNotFound,
        error.InvalidNetworkPrefix,
        error.TooManyNetworkExclusions,
        error.NetworkExclusionNotFound,
        error.InvalidDailyEventCeiling,
        error.InvalidStrictMode,
        error.TooManyActiveGoals,
        error.Constraint,
        => true,
        else => std.mem.indexOf(u8, @errorName(err), "Constraint") != null,
    };
}

fn methodNotAllowed(output: *std.Io.Writer, allow: []const u8) !void {
    var headers_buffer: [128]u8 = undefined;
    const headers = try std.fmt.bufPrint(
        &headers_buffer,
        "Cache-Control: no-store\r\nAllow: {s}\r\n",
        .{allow},
    );
    try response.write(
        output,
        405,
        "text/plain; charset=utf-8",
        headers,
        "method not allowed\n",
    );
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

test "canonical dashboard URL orders explicit calendar state" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try canonicalUrl(&output.writer, .analyze, .{
        .site = "example",
        .range = .{ .start = "2024-02-01", .end = "2024-02-29" },
        .comparison = .previous_year,
        .kind = .campaigns,
        .campaign_dimension = .source,
    });
    try std.testing.expectEqualStrings(
        "/admin/sites/example/analyze?from=2024-02-01&to=2024-02-29&compare=previous-year&report=campaigns&campaign=source&sort=count&limit=25&page=1",
        output.written(),
    );
}

test "canonical dashboard URL preserves Overview trend handoff state" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    const base = model.Query{
        .site = "example",
        .range = .{ .start = "2025-01-01", .end = "2025-01-02" },
        .comparison = .previous,
        .kind = .pages,
        .overview_metric = .revenue,
        .overview_currency = "EUR",
        .highlighted_interval = "2025-01-01T12:00",
    };
    try canonicalUrl(&output.writer, .analyze, base);
    try std.testing.expectEqualStrings(
        "/admin/sites/example/analyze?from=2025-01-01&to=2025-01-02&compare=previous&report=pages&sort=count&limit=25&page=1&focus=revenue-EUR&highlight=2025-01-01T12%3A00",
        output.written(),
    );
    output.clearRetainingCapacity();
    var overview = base;
    overview.kind = .overview;
    overview.highlighted_interval = "";
    try canonicalUrl(&output.writer, .overview, overview);
    try std.testing.expectEqualStrings(
        "/admin/sites/example/overview?v=1&from=2025-01-01&to=2025-01-02&compare=previous&metric=revenue-EUR",
        output.written(),
    );
}

test "post-commit refresh failure leaves one exact retryable site" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const backing_allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(
        backing_allocator,
        ".zig-cache/tmp/{s}/meta.db",
        .{temporary.sub_path},
    );
    defer backing_allocator.free(path);
    var metadata = try meta.Store.open(backing_allocator, path);
    defer metadata.deinit();
    try metadata.migrate();

    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const form = try controller.Form.parse(
        allocator,
        "csrf=fixture-token&name=Retry+site&slug=retry-site&" ++
            "origin=https%3A%2F%2Fretry.example&timezone=UTC&currency=EUR",
    );
    const first = try controller.submitSite(
        allocator,
        std.testing.io,
        &metadata,
        form,
        "fixture-token",
        timezone.default_zoneinfo_root,
        1_777_161_600_000_000,
    );
    switch (first) {
        .invalid => return error.UnexpectedInvalidSiteFixture,
        .stored => {},
    }
    try std.testing.expectEqual(@as(i64, 1), try metadata.siteCount());
    var marker: u8 = 0;
    const refresh = PolicyRefresh{
        .context = &marker,
        .apply = failPolicyRefreshFixture,
    };
    try std.testing.expectError(error.FixturePolicyRefresh, refresh.run());
    const second = try controller.submitSite(
        allocator,
        std.testing.io,
        &metadata,
        form,
        "fixture-token",
        timezone.default_zoneinfo_root,
        1_777_161_600_000_001,
    );
    switch (second) {
        .invalid => return error.UnexpectedInvalidSiteFixture,
        .stored => {},
    }
    try std.testing.expectEqual(@as(i64, 1), try metadata.siteCount());
}

fn failPolicyRefreshFixture(_: *anyopaque) !void {
    return error.FixturePolicyRefresh;
}

fn acceptsEncoding(value: []const u8, expected: []const u8) bool {
    var encodings = std.mem.splitScalar(u8, value, ',');
    while (encodings.next()) |raw_encoding| {
        var parts = std.mem.splitScalar(u8, raw_encoding, ';');
        const name = std.mem.trim(u8, parts.next() orelse continue, " \t");
        if (!std.ascii.eqlIgnoreCase(name, expected)) continue;
        while (parts.next()) |raw_parameter| {
            const parameter = std.mem.trim(u8, raw_parameter, " \t");
            const key, const raw_quality = std.mem.cutScalar(u8, parameter, '=') orelse
                return false;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, key, " \t"), "q")) {
                continue;
            }
            const quality = std.fmt.parseFloat(
                f32,
                std.mem.trim(u8, raw_quality, " \t"),
            ) catch return false;
            return quality > 0 and quality <= 1;
        }
        return true;
    }
    return false;
}
