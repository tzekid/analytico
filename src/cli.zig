const std = @import("std");
const domain = @import("domain.zig");
const http_server = @import("http/server.zig");
const ops = @import("ops.zig");
const report = @import("report.zig");
const meta = @import("store/meta.zig");
const events = @import("store/events.zig");
const reports = @import("store/reports.zig");
const auth_cli = @import("auth/cli.zig");
const timezone = @import("timezone.zig");

pub fn run(
    allocator: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    args: []const []const u8,
) !bool {
    if (try auth_cli.run(allocator, io, output, args)) return true;
    if (args.len == 3 and std.mem.eql(u8, args[1], "init")) {
        try initialize(allocator, io, output, args[2]);
        return true;
    }
    if ((args.len == 3 or args.len == 4) and
        std.mem.eql(u8, args[1], "migrate"))
    {
        try ops.migrate(
            allocator,
            io,
            output,
            args[2],
            if (args.len == 4) args[3] else null,
        );
        return true;
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "backup")) {
        try ops.backup(allocator, io, output, args[2], args[3]);
        return true;
    }
    if (args.len == 5 and std.mem.eql(u8, args[1], "restore") and
        std.mem.eql(u8, args[4], "--verify"))
    {
        try ops.restore(allocator, io, output, args[2], args[3]);
        return true;
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "maintain")) {
        try ops.maintain(allocator, io, output, args[2], args[3]);
        return true;
    }
    if (args.len == 7 and std.mem.eql(u8, args[1], "export")) {
        try ops.exportCsv(
            allocator,
            io,
            output,
            args[2],
            args[3],
            args[4],
            args[5],
            args[6],
        );
        return true;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "serve")) {
        try http_server.run(gpa, io, try parseServe(args));
        return true;
    }
    if (args.len >= 7 and std.mem.eql(u8, args[1], "report")) {
        try reportCommand(allocator, output, args);
        return true;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "site")) {
        try siteCommand(allocator, io, output, args);
        return true;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "goal")) {
        try goalCommand(allocator, io, output, args);
        return true;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "funnel")) {
        try funnelCommand(allocator, io, output, args);
        return true;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "event")) {
        try eventCommand(allocator, output, io, args);
        return true;
    }
    if ((args.len == 3 or args.len == 5) and
        std.mem.eql(u8, args[1], "doctor"))
    {
        const zoneinfo_root = if (args.len == 5 and
            std.mem.eql(u8, args[3], "--zoneinfo-root"))
            args[4]
        else if (args.len == 3)
            timezone.default_zoneinfo_root
        else
            return error.InvalidArguments;
        if (!std.fs.path.isAbsolute(zoneinfo_root)) return error.InvalidZoneinfoRoot;
        try ops.doctor(allocator, io, output, args[2], zoneinfo_root);
        return true;
    }
    if (args.len == 7 and std.mem.eql(u8, args[1], "pseudonym")) {
        const key = try domain.parseKeyHex(args[2]);
        const visitor = try domain.deriveVisitorDayId(
            key,
            args[3],
            args[4],
            args[5],
            args[6],
        );
        try output.print("{s}\n", .{std.fmt.bytesToHex(visitor, .lower)});
        return true;
    }
    return false;
}

pub fn writeUsage(output: *std.Io.Writer) !void {
    try output.writeAll(
        \\  analytico init <directory>
        \\  analytico migrate <directory> [verified-pre-upgrade-backup]
        \\  analytico backup <directory> <new-backup-directory>
        \\  analytico restore <backup-directory> <new-data-directory> --verify
        \\  analytico maintain <directory> <delete-before-date>
        \\  analytico export <directory> <site> <start-date> <end-date> <new.csv>
        \\  analytico serve --listen <loopback:port> --meta <absolute-path> --events <absolute-path> --temp <absolute-directory> --visitor-key-file <absolute-path> [--zoneinfo-root <absolute-directory>] [--report-timeout-ms 1..2000]
        \\  analytico site add <directory> <slug> <name> <origin> --timezone <iana-zone> [--zoneinfo-root <absolute-directory>]
        \\  analytico site list <directory>
        \\  analytico site timezone-set <directory> <slug> <iana-zone> [--zoneinfo-root <absolute-directory>] [--offline-rebucket]
        \\  analytico site disable <directory> <slug>
        \\  analytico site origin-add <directory> <slug> <origin>
        \\  analytico site property-add <directory> <slug> <property>
        \\  analytico site install <directory> <slug> <collector-origin>
        \\  analytico site delete <directory> <slug> --confirm <slug>
        \\  analytico goal add <directory> <site> <name> <event|path|prefix> <value>
        \\  analytico goal list <directory> <site>
        \\  analytico goal delete <directory> <site> <name> --confirm <name>
        \\  analytico funnel add <directory> <site> <name> <kind=value> <kind=value> [...]
        \\  analytico funnel show <directory> <site> <name>
        \\  analytico funnel delete <directory> <site> <name> --confirm <name>
        \\  analytico event add <directory> <site> <event> <path> <micros> <date> <ip> <browser> <os> <device> [--zoneinfo-root <absolute-directory>]
        \\  analytico event inspect <directory> [event-name]
        \\  analytico report <directory> <site> <start-date> <end-date> <kind> [subject] [--format table|json|csv] [--sort count|label] [--limit 1..100] [--page N]
        \\  analytico doctor <directory> [--zoneinfo-root <absolute-directory>]
        \\  analytico pseudonym <64-hex-key> <site-id> <date> <ip> <coarse-client>
        \\
    );
    try auth_cli.writeUsage(output);
}

fn reportCommand(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    args: []const []const u8,
) !void {
    // Parse and validate the complete request before either database is opened.
    const request = try report.Request.parse(args);
    const paths = try Paths.init(allocator, request.directory);
    var metadata = try meta.Store.open(allocator, paths.meta);
    defer metadata.deinit();
    try metadata.requireCurrent();
    const site_id = try metadata.siteIdBySlug(allocator, request.site_slug);
    const selected_goal: ?meta.Goal = if (request.kind == .goal)
        try metadata.goalByName(allocator, request.site_slug, request.subject)
    else
        null;
    const selected_funnel: ?[]const meta.FunnelStep = if (request.kind == .funnel)
        try metadata.funnelSteps(allocator, request.site_slug, request.subject)
    else
        null;

    var event_store = try events.Store.open(allocator, paths.events);
    defer event_store.deinit();
    try event_store.requireCurrent();
    const result = try reports.run(
        allocator,
        &event_store,
        request,
        site_id,
        selected_goal,
        selected_funnel,
    );
    try report.render(output, request, result);
}

fn initialize(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const paths = try Paths.init(allocator, directory);

    const metadata_exists = try pathExists(io, paths.meta);
    const events_exist = try pathExists(io, paths.events);
    if (metadata_exists != events_exist) return error.IncompleteDataDirectory;

    const key_created = if (metadata_exists)
        false
    else
        createKey(io, paths.key) catch |err| switch (err) {
            error.PathAlreadyExists => false,
            else => return err,
        };
    if (!key_created) {
        var existing_key = try readKey(allocator, io, paths.key);
        defer std.crypto.secureZero(u8, &existing_key);
    }

    var metadata = try meta.Store.open(allocator, paths.meta);
    defer metadata.deinit();
    if (metadata_exists) {
        try metadata.requireCurrent();
    } else {
        try metadata.migrate();
    }
    var event_store = try events.Store.open(allocator, paths.events);
    defer event_store.deinit();
    if (events_exist) {
        try event_store.requireCurrent();
    } else {
        try event_store.migrate();
    }
    const temp_path = try std.fs.path.join(allocator, &.{ directory, "tmp" });
    std.Io.Dir.cwd().createDir(io, temp_path, @fromBackingInt(@intCast(0o700))) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    try output.print(
        "initialized metadata=v{d} events=v{d} key={s}\n",
        .{
            try metadata.migrationVersion(),
            try event_store.migrationVersion(),
            if (key_created) "created" else "existing",
        },
    );
}

fn parseServe(args: []const []const u8) !http_server.Options {
    var listen: ?[]const u8 = null;
    var meta_path: ?[]const u8 = null;
    var event_path: ?[]const u8 = null;
    var temp_directory: ?[]const u8 = null;
    var key_path: ?[]const u8 = null;
    var report_timeout_ms: u32 = 2_000;
    var report_timeout_set = false;
    var zoneinfo_root: []const u8 = timezone.default_zoneinfo_root;
    var zoneinfo_root_set = false;
    var index: usize = 2;
    while (index < args.len) : (index += 2) {
        if (index + 1 >= args.len) return error.InvalidServeOption;
        const flag = args[index];
        const value = args[index + 1];
        if (std.mem.eql(u8, flag, "--listen")) {
            if (listen != null) return error.DuplicateServeOption;
            listen = value;
        } else if (std.mem.eql(u8, flag, "--meta")) {
            if (meta_path != null) return error.DuplicateServeOption;
            meta_path = value;
        } else if (std.mem.eql(u8, flag, "--events")) {
            if (event_path != null) return error.DuplicateServeOption;
            event_path = value;
        } else if (std.mem.eql(u8, flag, "--temp")) {
            if (temp_directory != null) return error.DuplicateServeOption;
            temp_directory = value;
        } else if (std.mem.eql(u8, flag, "--visitor-key-file")) {
            if (key_path != null) return error.DuplicateServeOption;
            key_path = value;
        } else if (std.mem.eql(u8, flag, "--report-timeout-ms")) {
            if (report_timeout_set) return error.DuplicateServeOption;
            report_timeout_ms = std.fmt.parseInt(u32, value, 10) catch
                return error.InvalidReportTimeout;
            if (report_timeout_ms == 0 or report_timeout_ms > 2_000) {
                return error.InvalidReportTimeout;
            }
            report_timeout_set = true;
        } else if (std.mem.eql(u8, flag, "--zoneinfo-root")) {
            if (zoneinfo_root_set or !std.fs.path.isAbsolute(value)) {
                return error.InvalidZoneinfoRoot;
            }
            zoneinfo_root = value;
            zoneinfo_root_set = true;
        } else {
            return error.InvalidServeOption;
        }
    }
    const listen_value = listen orelse return error.MissingServeOption;
    const separator = std.mem.lastIndexOfScalar(u8, listen_value, ':') orelse
        return error.InvalidListenAddress;
    var host = listen_value[0..separator];
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        host = host[1 .. host.len - 1];
    }
    const port = std.fmt.parseInt(u16, listen_value[separator + 1 ..], 10) catch
        return error.InvalidPort;
    return .{
        .host = host,
        .port = port,
        .meta_path = meta_path orelse return error.MissingServeOption,
        .event_path = event_path orelse return error.MissingServeOption,
        .temp_directory = temp_directory orelse return error.MissingServeOption,
        .key_path = key_path orelse return error.MissingServeOption,
        .zoneinfo_root = zoneinfo_root,
        .report_timeout_ms = report_timeout_ms,
    };
}

fn siteCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    args: []const []const u8,
) !void {
    if (args.len < 4) return error.InvalidArguments;
    const paths = try Paths.init(allocator, args[3]);
    var store = try meta.Store.open(allocator, paths.meta);
    defer store.deinit();
    try store.requireCurrent();

    if (std.mem.eql(u8, args[2], "add") and
        (args.len == 9 or args.len == 11) and
        std.mem.eql(u8, args[7], "--timezone"))
    {
        try domain.validateSlug(args[4]);
        try domain.validateName(args[5], 120);
        const origin = try domain.normalizeOrigin(allocator, args[6]);
        const zoneinfo_root = if (args.len == 11 and
            std.mem.eql(u8, args[9], "--zoneinfo-root"))
            args[10]
        else if (args.len == 9)
            timezone.default_zoneinfo_root
        else
            return error.InvalidArguments;
        var site_timezone = try timezone.load(allocator, io, zoneinfo_root, args[8]);
        defer site_timezone.deinit(allocator);
        _ = try site_timezone.localAt(@divFloor(try nowMicros(), 1_000_000));
        const id = try domain.randomUuid(io);
        try store.addSite(
            &id,
            args[4],
            args[5],
            origin,
            args[8],
            try nowMicros(),
        );
        try output.print("site added {s} {s}\n", .{ args[4], id });
        return;
    }
    if (std.mem.eql(u8, args[2], "timezone-set") and args.len >= 6) {
        var zoneinfo_root: []const u8 = timezone.default_zoneinfo_root;
        var zoneinfo_root_set = false;
        var offline_rebucket = false;
        var index: usize = 6;
        while (index < args.len) {
            if (std.mem.eql(u8, args[index], "--offline-rebucket")) {
                if (offline_rebucket) return error.InvalidArguments;
                offline_rebucket = true;
                index += 1;
            } else if (std.mem.eql(u8, args[index], "--zoneinfo-root")) {
                if (zoneinfo_root_set or index + 1 >= args.len) {
                    return error.InvalidArguments;
                }
                zoneinfo_root = args[index + 1];
                zoneinfo_root_set = true;
                index += 2;
            } else {
                return error.InvalidArguments;
            }
        }
        var site_timezone = try timezone.load(allocator, io, zoneinfo_root, args[5]);
        defer site_timezone.deinit(allocator);
        _ = try site_timezone.localAt(@divFloor(try nowMicros(), 1_000_000));
        const site_id = try store.siteIdBySlug(allocator, args[4]);
        var event_store = try events.Store.open(allocator, paths.events);
        defer event_store.deinit();
        try event_store.requireCurrent();
        const bounds = try event_store.siteEventBounds(site_id);
        if (bounds.count == 0) {
            try store.configureTimezoneReady(allocator, site_id, args[5]);
            try store.checkpoint();
            try output.print("site timezone ready {s} {s}\n", .{ args[4], args[5] });
            return;
        }
        const existing = store.siteTimezone(allocator, site_id) catch |err| switch (err) {
            error.SiteTimezoneRequired => null,
            else => return err,
        };
        if (existing) |current| {
            if (!current.rebucket_pending and
                std.mem.eql(u8, current.zone_name, args[5]))
            {
                try output.print("site timezone unchanged {s} {s}\n", .{ args[4], args[5] });
                return;
            }
        }
        if (!offline_rebucket) return error.TimezoneLocked;
        const intervals = try site_timezone.rebucketIntervals(
            allocator,
            bounds.minimum_utc_micros,
            bounds.maximum_utc_micros,
        );
        try store.markTimezoneRebucketPending(allocator, site_id, args[5]);
        try store.checkpoint();
        try event_store.rebucketSite(site_id, intervals, bounds.count);
        try event_store.checkpoint();
        try store.finishTimezoneRebucket(site_id, args[5]);
        try store.checkpoint();
        try output.print(
            "site timezone rebucketed {s} {s} events={d}\n",
            .{ args[4], args[5], bounds.count },
        );
        return;
    }
    if (std.mem.eql(u8, args[2], "list") and args.len == 4) {
        const sites = try store.listSites(allocator);
        for (sites) |site| {
            try output.print("{s}\t{s}\t{s}\t{s}\n", .{
                site.slug,
                site.id,
                if (site.disabled) "disabled" else "active",
                site.name,
            });
        }
        return;
    }
    if (std.mem.eql(u8, args[2], "disable") and args.len == 5) {
        try store.disableSite(args[4], try nowMicros());
        try output.print("site disabled {s}\n", .{args[4]});
        return;
    }
    if (std.mem.eql(u8, args[2], "origin-add") and args.len == 6) {
        const origin = try domain.normalizeOrigin(allocator, args[5]);
        try store.addOrigin(allocator, args[4], origin);
        try output.print("origin added {s} {s}\n", .{ args[4], origin });
        return;
    }
    if (std.mem.eql(u8, args[2], "property-add") and args.len == 6) {
        try store.addProperty(allocator, args[4], args[5]);
        try output.print("property added {s} {s}\n", .{ args[4], args[5] });
        return;
    }
    if (std.mem.eql(u8, args[2], "install") and args.len == 6) {
        const collector = try domain.normalizeOrigin(allocator, args[5]);
        const site_id = try store.siteIdBySlug(allocator, args[4]);
        try output.print(
            \\<!-- Analytico tracker -->
            \\<script defer src="{s}/tracker.81c3b777.js" data-site="{s}" data-spa="auto" data-engagement="true"></script>
            \\<noscript>
            \\  <img alt="" width="1" height="1" src="{s}/v1/p.gif?site={s}&amp;path=%2F">
            \\</noscript>
            \\
            \\CSP merge:
            \\  script-src {s}
            \\  connect-src {s}
            \\  img-src {s}
            \\
        , .{
            collector,
            site_id,
            collector,
            site_id,
            collector,
            collector,
            collector,
        });
        return;
    }
    if (std.mem.eql(u8, args[2], "delete") and args.len == 7 and
        std.mem.eql(u8, args[5], "--confirm") and
        std.mem.eql(u8, args[4], args[6]))
    {
        const site_id = try store.siteIdBySlug(allocator, args[4]);
        const policy = try store.sitePolicy(allocator, site_id);
        if (!policy.disabled) return error.SiteMustBeDisabled;
        var event_store = try events.Store.open(allocator, paths.events);
        defer event_store.deinit();
        try event_store.requireCurrent();
        _ = try event_store.deleteSite(site_id);
        try event_store.checkpoint();
        try store.deleteSite(args[4]);
        try store.checkpoint();
        try output.print("site deleted {s}\n", .{args[4]});
        return;
    }
    return error.InvalidArguments;
}

fn goalCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    args: []const []const u8,
) !void {
    if (args.len < 5) return error.InvalidArguments;
    const paths = try Paths.init(allocator, args[3]);
    var store = try meta.Store.open(allocator, paths.meta);
    defer store.deinit();
    try store.requireCurrent();

    if (std.mem.eql(u8, args[2], "add") and args.len == 8) {
        const id = try domain.randomUuid(io);
        const kind = try domain.MatchKind.parse(args[6]);
        try store.addGoal(
            allocator,
            &id,
            args[4],
            args[5],
            kind,
            args[7],
            try nowMicros(),
        );
        try output.print("goal added {s} {s}\n", .{ args[5], id });
        return;
    }
    if (std.mem.eql(u8, args[2], "list") and args.len == 5) {
        const goals = try store.listGoals(allocator, args[4]);
        for (goals) |goal| {
            try output.print("{s}\t{s}\t{s}\t{s}\n", .{
                goal.name,
                @tagName(goal.match_kind),
                goal.match_value,
                goal.id,
            });
        }
        return;
    }
    if (std.mem.eql(u8, args[2], "delete") and args.len == 8 and
        std.mem.eql(u8, args[6], "--confirm") and
        std.mem.eql(u8, args[5], args[7]))
    {
        try store.deleteGoal(allocator, args[4], args[5]);
        try output.print("goal deleted {s}\n", .{args[5]});
        return;
    }
    return error.InvalidArguments;
}

fn funnelCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    args: []const []const u8,
) !void {
    if (args.len < 6) return error.InvalidArguments;
    const paths = try Paths.init(allocator, args[3]);
    var store = try meta.Store.open(allocator, paths.meta);
    defer store.deinit();
    try store.requireCurrent();

    if (std.mem.eql(u8, args[2], "add") and args.len >= 8 and args.len <= 14) {
        var steps: std.ArrayList(meta.FunnelStepInput) = .empty;
        for (args[6..]) |encoded| {
            const kind_text, const value = std.mem.cutScalar(u8, encoded, '=') orelse
                return error.InvalidFunnelStep;
            try steps.append(allocator, .{
                .name = value,
                .match_kind = try domain.MatchKind.parse(kind_text),
                .match_value = value,
            });
        }
        const id = try domain.randomUuid(io);
        try store.addFunnel(
            allocator,
            &id,
            args[4],
            args[5],
            steps.items,
            try nowMicros(),
        );
        try output.print("funnel added {s} {s}\n", .{ args[5], id });
        return;
    }
    if (std.mem.eql(u8, args[2], "show") and args.len == 6) {
        const steps = try store.funnelSteps(allocator, args[4], args[5]);
        for (steps) |step| {
            try output.print("{d}\t{s}\t{s}\t{s}\n", .{
                step.index,
                step.name,
                @tagName(step.match_kind),
                step.match_value,
            });
        }
        return;
    }
    if (std.mem.eql(u8, args[2], "delete") and args.len == 8 and
        std.mem.eql(u8, args[6], "--confirm") and
        std.mem.eql(u8, args[5], args[7]))
    {
        try store.deleteFunnel(allocator, args[4], args[5]);
        try output.print("funnel deleted {s}\n", .{args[5]});
        return;
    }
    return error.InvalidArguments;
}

fn eventCommand(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    io: std.Io,
    args: []const []const u8,
) !void {
    if (std.mem.eql(u8, args[2], "inspect") and
        (args.len == 4 or args.len == 5))
    {
        const paths = try Paths.init(allocator, args[3]);
        var event_store = try events.Store.open(allocator, paths.events);
        defer event_store.deinit();
        try event_store.requireCurrent();
        const event = if (args.len == 5)
            try event_store.latestNamed(allocator, args[4])
        else
            try event_store.latest(allocator);
        try output.print("{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{
            event.event_name,
            event.path,
            event.referrer_host,
            event.country_code,
            event.browser_family,
            event.os_family,
            event.device_category,
            event.utm_source,
            event.properties_json,
        });
        return;
    }
    if (!std.mem.eql(u8, args[2], "add") or
        (args.len != 13 and args.len != 15))
    {
        return error.InvalidArguments;
    }
    const zoneinfo_root = if (args.len == 15 and
        std.mem.eql(u8, args[13], "--zoneinfo-root"))
        args[14]
    else if (args.len == 13)
        timezone.default_zoneinfo_root
    else
        return error.InvalidArguments;
    const paths = try Paths.init(allocator, args[3]);
    const key = try readKey(allocator, io, paths.key);
    var metadata = try meta.Store.open(allocator, paths.meta);
    defer metadata.deinit();
    try metadata.requireCurrent();
    const site_id = try metadata.siteIdBySlug(allocator, args[4]);
    const policy = try metadata.sitePolicy(allocator, site_id);
    var site_timezone = try timezone.load(
        allocator,
        io,
        zoneinfo_root,
        policy.timezone_name,
    );
    defer site_timezone.deinit(allocator);

    try domain.validateIdentifier(args[5]);
    const path = try domain.normalizePath(args[6]);
    const timestamp = std.fmt.parseInt(i64, args[7], 10) catch
        return error.InvalidTimestamp;
    try domain.validateDate(args[8]);
    try domain.validateIdentifier(args[10]);
    try domain.validateIdentifier(args[11]);
    try domain.validateIdentifier(args[12]);
    const coarse = try std.fmt.allocPrint(
        allocator,
        "{s}|{s}|{s}",
        .{ args[10], args[11], args[12] },
    );
    const visitor = try domain.deriveVisitorDayId(
        key,
        site_id,
        args[8],
        args[9],
        coarse,
    );
    const id = try domain.randomUuid(io);
    const local = try site_timezone.localAt(@divFloor(timestamp, 1_000_000));

    var event_store = try events.Store.open(allocator, paths.events);
    defer event_store.deinit();
    try event_store.requireCurrent();
    try event_store.insert(.{
        .event_id = &id,
        .site_id = site_id,
        .received_at_utc_micros = timestamp,
        .received_date_utc = args[8],
        .site_local_date = &local.date,
        .site_utc_offset_minutes = local.offset_minutes,
        .kind = if (std.mem.eql(u8, args[5], "pageview")) 1 else 2,
        .event_name = args[5],
        .path = path,
        .visitor_day_id = visitor,
        .browser_family = args[10],
        .os_family = args[11],
        .device_category = args[12],
    });
    try event_store.checkpoint();
    try output.print("event committed {s}\n", .{id});
}

const Paths = struct {
    meta: []const u8,
    events: []const u8,
    key: []const u8,

    fn init(allocator: std.mem.Allocator, directory: []const u8) !Paths {
        return .{
            .meta = try std.fs.path.join(allocator, &.{ directory, "meta.db" }),
            .events = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" }),
            .key = try std.fs.path.join(allocator, &.{ directory, "visitor.key" }),
        };
    }
};

fn pathExists(io: std.Io, path: []const u8) !bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn createKey(io: std.Io, path: []const u8) !bool {
    var key: [32]u8 = undefined;
    try io.randomSecure(&key);
    defer @memset(&key, 0);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = &key,
        .flags = .{
            .exclusive = true,
            .permissions = @fromBackingInt(@intCast(0o600)),
        },
    });
    return true;
}

fn readKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![32]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(33),
    );
    defer std.crypto.secureZero(u8, bytes);
    if (bytes.len != 32) return error.InvalidKeyFile;
    return bytes[0..32].*;
}

fn nowMicros() !i64 {
    var timestamp: std.os.linux.timespec = undefined;
    const result = std.os.linux.clock_gettime(.REALTIME, &timestamp);
    if (std.os.linux.errno(result) != .SUCCESS or timestamp.sec < 0) {
        return error.ClockUnavailable;
    }
    const seconds = std.math.mul(i64, timestamp.sec, 1_000_000) catch
        return error.ClockUnavailable;
    return std.math.add(i64, seconds, @divTrunc(timestamp.nsec, 1_000)) catch
        return error.ClockUnavailable;
}
