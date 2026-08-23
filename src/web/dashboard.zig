const std = @import("std");
const domain = @import("../domain.zig");
const request_mod = @import("../http/request.zig");
const response = @import("../http/response.zig");
const events = @import("../store/events.zig");
const meta = @import("../store/meta.zig");
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
    report_timeout_ms: u32,
    policy_refresh: ?PolicyRefresh = null,
};

pub const PolicyRefresh = struct {
    context: *anyopaque,
    apply: *const fn (*anyopaque) anyerror!void,

    fn run(self: PolicyRefresh) !void {
        try self.apply(self.context);
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
    if (std.mem.eql(u8, path, "/admin") or
        std.mem.eql(u8, path, "/admin/"))
    {
        if (!std.mem.eql(u8, request.method, "GET")) {
            try methodNotAllowed(output, "GET");
            return true;
        }
        try getPage(dependencies, request, output);
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

const Action = enum {
    add_goal,
    delete_goal,
    add_funnel,
    delete_funnel,
    add_excluded_network,
    delete_excluded_network,
    update_traffic_policy,
};

fn actionFor(path: []const u8) ?Action {
    if (std.mem.eql(u8, path, "/admin/goals")) return .add_goal;
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

fn getPage(
    dependencies: Dependencies,
    request: request_mod.Request,
    output: *std.Io.Writer,
) !void {
    const range = currentRange() catch {
        try writeError(output, .{
            .status = 503,
            .title = "Clock unavailable",
            .message = "The server could not determine a safe UTC report range.",
        });
        return;
    };
    const query = controller.parseQuery(
        dependencies.allocator,
        request.target,
        &range.start,
        &range.end,
    ) catch {
        try writeError(output, .{
            .status = 400,
            .title = "Invalid report request",
            .message = "Check the site, UTC date range, report, sort, and page values.",
        });
        return;
    };
    const loaded = controller.loadPage(
        dependencies.allocator,
        dependencies.metadata,
        dependencies.events,
        query,
        dependencies.csrf_token,
        noticeMessage(request.target),
        dependencies.report_timeout_ms,
    ) catch |err| {
        if (err == error.ReportTimeout) {
            try writeError(output, .{
                .status = 503,
                .title = "Report timed out",
                .message = "The report exceeded its server deadline. Narrow the UTC date range and retry.",
                .return_url = request.target,
            });
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
                .message = "Check the site, UTC date range, report, sort, and page values.",
            });
        } else {
            return err;
        }
        return;
    };
    try writePage(output, 200, loaded);
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
    const date_range = controller.formDateRange(form) catch {
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
        if (!isFormError(err)) return err;
        try formErrorPage(dependencies, output, form, action);
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
    var location = std.Io.Writer.Allocating.init(dependencies.allocator);
    try location.writer.writeAll("/admin?site=");
    try urlComponent(&location.writer, site);
    try location.writer.writeAll("&start=");
    try urlComponent(&location.writer, date_range.start);
    try location.writer.writeAll("&end=");
    try urlComponent(&location.writer, date_range.end);
    try location.writer.writeAll("&report=overview&notice=");
    try location.writer.writeAll(switch (action) {
        .add_goal => "goal-added",
        .delete_goal => "goal-deleted",
        .add_funnel => "funnel-added",
        .delete_funnel => "funnel-deleted",
        .add_excluded_network => "network-exclusion-added",
        .delete_excluded_network => "network-exclusion-deleted",
        .update_traffic_policy => "traffic-policy-updated",
    });
    var headers = std.Io.Writer.Allocating.init(dependencies.allocator);
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

fn formErrorPage(
    dependencies: Dependencies,
    output: *std.Io.Writer,
    form: controller.Form,
    action: Action,
) !void {
    const range = controller.formDateRange(form) catch {
        try writeError(output, .{
            .status = 400,
            .title = "Invalid form",
            .message = "The submitted report date range was missing or invalid.",
        });
        return;
    };
    const site = form.required("site") catch "";
    const query = model.Query{
        .site = site,
        .start_date = range.start,
        .end_date = range.end,
    };
    var page = controller.loadPage(
        dependencies.allocator,
        dependencies.metadata,
        dependencies.events,
        query,
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
    page.form_error = if (action == .update_traffic_policy)
        "The traffic policy was not saved. Use a ceiling from 1 to 10,000,000; strict mode also requires at most 32 goals."
    else if (action == .add_excluded_network or
        action == .delete_excluded_network)
        "The network exclusion was not saved. Enter an IPv4 address or /24, or an IPv6 address or /48."
    else
        "The definition was not saved. Check its name, match kind, value, and step count.";
    if (action == .add_goal) {
        page.goal_draft = .{
            .name = form.required("name") catch "",
            .match_kind = form.required("kind") catch "event",
            .match_value = form.required("value") catch "",
        };
    } else if (action == .add_funnel) {
        page.funnel_draft = .{
            .name = form.required("name") catch "",
            .steps = form.required("steps") catch "",
        };
    } else if (action == .add_excluded_network) {
        page.network_draft = form.required("network") catch "";
    }
    try writePage(output, 422, page);
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

const Range = struct {
    start: [10]u8,
    end: [10]u8,
};

fn currentRange() !Range {
    var timestamp: std.os.linux.timespec = undefined;
    const result = std.os.linux.clock_gettime(.REALTIME, &timestamp);
    if (std.os.linux.errno(result) != .SUCCESS or
        timestamp.sec < 29 * std.time.s_per_day)
    {
        return error.ClockUnavailable;
    }
    return .{
        .start = try dateForSeconds(timestamp.sec - 29 * std.time.s_per_day),
        .end = try dateForSeconds(timestamp.sec),
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

fn noticeMessage(target: []const u8) []const u8 {
    if (std.mem.indexOf(u8, target, "notice=goal-added") != null) {
        return "Goal added.";
    }
    if (std.mem.indexOf(u8, target, "notice=goal-deleted") != null) {
        return "Goal deleted.";
    }
    if (std.mem.indexOf(u8, target, "notice=funnel-added") != null) {
        return "Funnel added.";
    }
    if (std.mem.indexOf(u8, target, "notice=funnel-deleted") != null) {
        return "Funnel deleted.";
    }
    if (std.mem.indexOf(u8, target, "notice=network-exclusion-added") != null) {
        return "Network exclusion added and collection policy refreshed.";
    }
    if (std.mem.indexOf(u8, target, "notice=network-exclusion-deleted") != null) {
        return "Network exclusion deleted and collection policy refreshed.";
    }
    if (std.mem.indexOf(u8, target, "notice=traffic-policy-updated") != null) {
        return "Traffic policy updated and collection policy refreshed.";
    }
    return "";
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
        => true,
        else => false,
    };
}

fn isFormError(err: anyerror) bool {
    return switch (err) {
        error.MissingFormField,
        error.InvalidSlug,
        error.InvalidName,
        error.InvalidIdentifier,
        error.InvalidMatchKind,
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
