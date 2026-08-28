const std = @import("std");
const domain = @import("domain.zig");
const ops = @import("ops.zig");
const product = @import("product.zig");
const reports = @import("reports.zig");
const store_mod = @import("store.zig");
const trackers = @import("tracker_assets.zig");
const server = @import("server.zig");

pub const version = "1.0.0-dev";

pub fn run(
    allocator: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    args: []const []const u8,
) !void {
    if (args.len == 1 or std.mem.eql(u8, args[1], "help") or std.mem.eql(u8, args[1], "--help")) {
        return writeUsage(output);
    }
    if (std.mem.eql(u8, args[1], "version")) {
        try output.print("analytico {s} sqlite 3.53.4\n", .{version});
        return;
    }
    if (std.mem.eql(u8, args[1], "init") and args.len == 3) {
        return ops.init(allocator, io, output, args[2]);
    }
    const data = option(args, "--data") orelse "data";
    if (std.mem.eql(u8, args[1], "doctor")) return ops.doctor(allocator, io, output, data);
    if (std.mem.eql(u8, args[1], "backup") and args.len == 4) return ops.backup(allocator, io, output, args[2], args[3]);
    if (std.mem.eql(u8, args[1], "restore") and args.len == 4) {
        return ops.restore(allocator, io, output, args[2], args[3]);
    }
    if (std.mem.eql(u8, args[1], "prune") and args.len >= 3) {
        return ops.prune(allocator, io, output, args[2], option(args, "--before") orelse return error.MissingBeforeDate, option(args, "--backup") orelse return error.MissingBackup);
    }
    if (std.mem.eql(u8, args[1], "vacuum") and args.len >= 3) {
        return ops.vacuum(allocator, io, output, args[2], option(args, "--backup") orelse return error.MissingBackup);
    }
    if (std.mem.eql(u8, args[1], "serve")) {
        const listen = option(args, "--listen") orelse "127.0.0.1:4318";
        const split = std.mem.lastIndexOfScalar(u8, listen, ':') orelse return error.InvalidListenAddress;
        const host = listen[0..split];
        const port = std.fmt.parseInt(u16, listen[split + 1 ..], 10) catch return error.InvalidListenAddress;
        return server.run(gpa, io, .{ .data = data, .host = host, .port = port });
    }
    if (std.mem.eql(u8, args[1], "session") and args.len >= 4) {
        var store = try store_mod.Store.open(allocator, io, data, false);
        defer store.close();
        var site = try store.siteBySlug(args[3]);
        defer site.deinit(allocator);
        if (site.mode != .session) return error.SessionModeRequired;
        if (std.mem.eql(u8, args[2], "list")) return reports.sessionList(allocator, output, &store, site.id, try reports.resolveOptions(args));
        if (std.mem.eql(u8, args[2], "show") and args.len >= 5) {
            const format: reports.Format = if (flag(args, "--json")) .json else if (flag(args, "--csv")) .csv else .table;
            return reports.sessionShow(allocator, output, &store, site.id, args[4], format);
        }
        return error.InvalidSessionCommand;
    }
    if (std.mem.eql(u8, args[1], "report") and args.len >= 4) {
        var store = try store_mod.Store.open(allocator, io, data, false);
        defer store.close();
        var site = try store.siteBySlug(args[3]);
        defer site.deinit(allocator);
        if (std.mem.eql(u8, args[2], "flow") and args.len >= 5) return reports.flow(allocator, output, &store, site.id, args[4], try reports.resolveOptions(args));
        if (std.mem.eql(u8, args[2], "friction")) return reports.friction(allocator, output, &store, site.id, option(args, "--flow") orelse "", try reports.resolveOptions(args));
        if (std.mem.eql(u8, args[2], "paths")) {
            const from_path = option(args, "--from") orelse return error.MissingFromPath;
            return reports.paths(allocator, output, &store, site.id, from_path, try reports.resolveDaysOptions(args));
        }
        if (std.mem.eql(u8, args[2], "campaign-economics")) return reports.campaignEconomics(allocator, output, &store, site.id, try reports.resolveOptions(args));
        const options_value = try reports.resolveOptions(args);
        return reports.run(allocator, output, &store, site.id, args[2], options_value);
    }
    if (std.mem.eql(u8, args[1], "goal") and args.len >= 4) return runGoal(allocator, io, output, args, data);
    if (std.mem.eql(u8, args[1], "funnel") and args.len >= 4) return runFunnel(allocator, io, output, args, data);
    if (std.mem.eql(u8, args[1], "campaign") and args.len >= 4) return runCampaign(allocator, io, output, args, data);
    if (std.mem.eql(u8, args[1], "stats")) return runStats(allocator, io, output, data);
    if (std.mem.eql(u8, args[1], "tail") and args.len >= 3) return runTail(allocator, io, output, args, data);
    if (std.mem.eql(u8, args[1], "site")) return runSite(allocator, io, output, args, data);
    return error.InvalidCommand;
}

fn runTail(allocator: std.mem.Allocator, io: std.Io, output: *std.Io.Writer, args: []const []const u8, data: []const u8) !void {
    const limit = std.fmt.parseInt(i64, option(args, "--limit") orelse "50", 10) catch return error.InvalidLimit;
    if (limit < 1 or limit > 1000) return error.InvalidLimit;
    var store = try store_mod.Store.open(allocator, io, data, false);
    defer store.close();
    var site = try store.siteBySlug(args[2]);
    defer site.deinit(allocator);
    var cursor = (try domain.nowMilliseconds()) - 7 * 86_400_000;
    while (true) {
        var statement = try store.database.prepare(allocator,
            \\SELECT received_at_ms,kind,name,path,source FROM (SELECT received_at_ms,kind,name,path,source FROM (
            \\ SELECT received_at_ms,'page_view' kind,'page_view' name,path,'browser' source FROM page_views WHERE site_id=?1 AND received_at_ms>?2
            \\ UNION ALL SELECT received_at_ms,'event',name,coalesce(path,''),source FROM events WHERE site_id=?1 AND received_at_ms>?2
            \\) ORDER BY received_at_ms DESC LIMIT ?3) ORDER BY received_at_ms
        );
        try statement.bindInt(1, site.id);
        try statement.bindInt(2, cursor);
        try statement.bindInt(3, limit);
        try reports.writeRows(output, &statement, .table);
        statement.deinit();
        var latest = try store.database.prepare(allocator, "SELECT max(received_at_ms) FROM (SELECT received_at_ms FROM page_views WHERE site_id=? UNION ALL SELECT received_at_ms FROM events WHERE site_id=?)");
        try latest.bindInt(1, site.id);
        try latest.bindInt(2, site.id);
        if (try latest.step() == .row and latest.columnType(0) != @import("db.zig").sqlite.SQLITE_NULL) cursor = @max(cursor, latest.columnInt(0));
        latest.deinit();
        try output.flush();
        if (!flag(args, "--follow")) return;
        try std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .awake);
    }
}

fn runGoal(allocator: std.mem.Allocator, io: std.Io, output: *std.Io.Writer, args: []const []const u8, data: []const u8) !void {
    const write = std.mem.eql(u8, args[2], "add");
    var store = try store_mod.Store.open(allocator, io, data, write);
    defer store.close();
    var site = try store.siteBySlug(args[3]);
    defer site.deinit(allocator);
    if (std.mem.eql(u8, args[2], "add") and args.len >= 7) return product.goalAdd(allocator, output, &store, site.id, args[4], args[5], args[6]);
    if (std.mem.eql(u8, args[2], "list")) return product.goalList(allocator, output, &store, site.id);
    return error.InvalidGoalCommand;
}

fn runFunnel(allocator: std.mem.Allocator, io: std.Io, output: *std.Io.Writer, args: []const []const u8, data: []const u8) !void {
    const write = std.mem.eql(u8, args[2], "add");
    var store = try store_mod.Store.open(allocator, io, data, write);
    defer store.close();
    var site = try store.siteBySlug(args[3]);
    defer site.deinit(allocator);
    if (site.mode != .session) return error.SessionModeRequired;
    if (std.mem.eql(u8, args[2], "list")) return product.funnelList(allocator, output, &store, site.id);
    if (std.mem.eql(u8, args[2], "show") and args.len >= 5) return product.funnelShow(allocator, output, &store, site.id, args[4], try reports.resolveOptions(args));
    if (std.mem.eql(u8, args[2], "add") and args.len >= 7) {
        var end: usize = 5;
        while (end < args.len and !std.mem.startsWith(u8, args[end], "--")) : (end += 1) {}
        return product.funnelAdd(allocator, output, &store, site.id, args[4], args[5..end]);
    }
    return error.InvalidFunnelCommand;
}

fn runCampaign(allocator: std.mem.Allocator, io: std.Io, output: *std.Io.Writer, args: []const []const u8, data: []const u8) !void {
    var store = try store_mod.Store.open(allocator, io, data, true);
    defer store.close();
    var site = try store.siteBySlug(args[3]);
    defer site.deinit(allocator);
    if (std.mem.eql(u8, args[2], "spend-add") and args.len >= 10) return product.spendAdd(allocator, output, &store, site.id, args[4], args[5], args[6], args[7], args[8], args[9]);
    if (std.mem.eql(u8, args[2], "spend-import") and args.len >= 5) return product.spendImport(allocator, io, output, &store, site.id, args[4]);
    return error.InvalidCampaignCommand;
}

fn runStats(allocator: std.mem.Allocator, io: std.Io, output: *std.Io.Writer, data: []const u8) !void {
    var store = try store_mod.Store.open(allocator, io, data, false);
    defer store.close();
    try output.writeAll("name\tvalue\n");
    var statement = try store.database.prepare(allocator, "SELECT name,value FROM ingest_counters UNION ALL " ++
        "SELECT 'page_views',count(*) FROM page_views UNION ALL " ++
        "SELECT 'page_summaries',count(*) FROM page_summaries UNION ALL " ++
        "SELECT 'events',count(*) FROM events ORDER BY name");
    defer statement.deinit();
    while (try statement.step() == .row) try output.print("{s}\t{d}\n", .{
        statement.columnText(0), statement.columnInt(1),
    });
    try output.writeAll("\ntracker_version\trecords\n");
    var versions = try store.database.prepare(allocator,
        \\SELECT tracker_version,count(*) FROM (
        \\ SELECT tracker_version FROM page_views UNION ALL SELECT tracker_version FROM page_summaries UNION ALL SELECT tracker_version FROM events
        \\) GROUP BY tracker_version ORDER BY count(*) DESC,tracker_version
    );
    defer versions.deinit();
    while (try versions.step() == .row) try output.print("{s}\t{d}\n", .{ versions.columnText(0), versions.columnInt(1) });
    try output.writeAll("\nconsent_mode\trecords\n");
    var consent = try store.database.prepare(allocator,
        \\SELECT consent_mode,count(*) FROM (
        \\ SELECT consent_mode FROM page_views UNION ALL SELECT consent_mode FROM page_summaries UNION ALL SELECT consent_mode FROM events
        \\) GROUP BY consent_mode ORDER BY count(*) DESC,consent_mode
    );
    defer consent.deinit();
    while (try consent.step() == .row) try output.print("{s}\t{d}\n", .{ consent.columnText(0), consent.columnInt(1) });
    try output.writeAll("\ntraffic_class\tpage_views\n");
    var traffic = try store.database.prepare(allocator, "SELECT traffic_class,count(*) FROM page_views GROUP BY traffic_class ORDER BY count(*) DESC,traffic_class");
    defer traffic.deinit();
    while (try traffic.step() == .row) try output.print("{s}\t{d}\n", .{ traffic.columnText(0), traffic.columnInt(1) });
}

fn runSite(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    args: []const []const u8,
    data: []const u8,
) !void {
    if (args.len < 3) return error.InvalidCommand;
    const write = std.mem.eql(u8, args[2], "add") or std.mem.eql(u8, args[2], "origin-add") or std.mem.eql(u8, args[2], "disable");
    var store = try store_mod.Store.open(allocator, io, data, write);
    defer store.close();
    if (std.mem.eql(u8, args[2], "add") and args.len >= 5) {
        const mode = try domain.parseMode(option(args, "--mode") orelse return error.MissingTrackingMode);
        var site = try store.addSite(io, args[3], args[4], mode);
        defer site.deinit(allocator);
        const secret = std.fmt.bytesToHex(site.internal_secret, .lower);
        try output.print("site added slug={s} public_id={s} mode={s}\ninternal_secret={s}\n", .{
            site.slug, site.public_id, domain.modeName(site.mode), secret,
        });
        return;
    }
    if (std.mem.eql(u8, args[2], "origin-add") and args.len >= 5) {
        try store.addOrigin(args[3], args[4]);
        try output.print("origin added site={s}\n", .{args[3]});
        return;
    }
    if (std.mem.eql(u8, args[2], "disable") and args.len >= 4) {
        try store.disableSite(args[3]);
        try output.print("site disabled slug={s}\n", .{args[3]});
        return;
    }
    if (std.mem.eql(u8, args[2], "show") and args.len >= 4) {
        var site = try store.siteBySlug(args[3]);
        defer site.deinit(allocator);
        try output.print("slug\tpublic_id\tmode\tenabled\n{s}\t{s}\t{s}\t{}\norigins\n", .{
            site.slug, site.public_id, domain.modeName(site.mode), site.enabled,
        });
        var statement = try store.database.prepare(allocator, "SELECT origin FROM site_origins WHERE site_id=? ORDER BY origin");
        defer statement.deinit();
        try statement.bindInt(1, site.id);
        while (try statement.step() == .row) try output.print("{s}\n", .{statement.columnText(0)});
        return;
    }
    if (std.mem.eql(u8, args[2], "secret-show") and args.len >= 4) {
        var site = try store.siteBySlug(args[3]);
        defer site.deinit(allocator);
        try output.print("{s}\n", .{std.fmt.bytesToHex(site.internal_secret, .lower)});
        return;
    }
    if (std.mem.eql(u8, args[2], "list")) {
        try output.writeAll("slug\tpublic_id\tmode\tenabled\n");
        var statement = try store.database.prepare(allocator, "SELECT slug,public_id,tracking_mode,enabled FROM sites ORDER BY slug");
        defer statement.deinit();
        while (try statement.step() == .row) try output.print("{s}\t{s}\t{s}\t{}\n", .{
            statement.columnText(0), statement.columnText(1), statement.columnText(2), statement.columnBool(3),
        });
        return;
    }
    if (std.mem.eql(u8, args[2], "snippet") and args.len >= 5) {
        var site = try store.siteBySlug(args[3]);
        defer site.deinit(allocator);
        const collector = try domain.normalizeOrigin(allocator, args[4]);
        defer allocator.free(collector);
        const rum = flag(args, "--rum");
        const variant: trackers.Variant = switch (site.mode) {
            .lite => if (rum) .lite_rum else .lite,
            .session => if (rum) .session_rum else .session,
        };
        var path_buffer: [64]u8 = undefined;
        const asset_path = try trackers.path(&path_buffer, variant);
        try output.print("<script defer src=\"{s}{s}\" data-site=\"{s}\"></script>\n", .{
            collector, asset_path, site.public_id,
        });
        return;
    }
    return error.InvalidSiteCommand;
}

pub fn option(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, name) and index + 1 < args.len) return args[index + 1];
    }
    return null;
}

pub fn flag(args: []const []const u8, name: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, name)) return true;
    return false;
}

pub fn writeUsage(output: *std.Io.Writer) !void {
    try output.writeAll(
        \\Analytico - CLI-first self-hosted analytics
        \\
        \\Administration:
        \\  analytico init <data-dir>
        \\  analytico site add <slug> <origin> --mode lite|session [--data <dir>]
        \\  analytico site origin-add <slug> <origin> [--data <dir>]
        \\  analytico site list|show|snippet|disable ... [--data <dir>]
        \\
        \\Operations:
        \\  analytico serve --data <dir> --listen 127.0.0.1:4318
        \\  analytico stats --data <dir>
        \\  analytico doctor --data <dir>
        \\  analytico backup <data-dir> <new-backup.db>
        \\  analytico restore <backup.db> <new-data-dir>
        \\  analytico prune <data-dir> --before YYYY-MM-DD --backup <new-backup.db>
        \\  analytico vacuum <data-dir> --backup <new-backup.db>
        \\  analytico tail <site> [--limit 50] [--follow] --data <dir>
        \\
        \\Reports:
        \\  analytico report overview|pages|acquisition|campaigns <site> [--days N]
        \\  analytico report sections|actions|events|performance|coverage|traffic|recent <site>
        \\  analytico session list <site> --days 7
        \\  analytico session show <site> <session-id>
        \\  analytico report flow <site> <flow-name> --days 30
        \\  analytico report friction <site> --flow <flow-name>
        \\  analytico report paths <site> --from /path --days 30
        \\  analytico goal add <site> <name> event|path <match>
        \\  analytico goal list <site>
        \\  analytico funnel add <site> <name> <goal|event:name|path:/path>...
        \\  analytico funnel show|list <site> ...
        \\  analytico campaign spend-add <site> <date> <source> <campaign> <content> <amount-minor> <currency>
        \\  analytico campaign spend-import <site> <costs.csv>
        \\  analytico report campaign-economics <site> --days 30
        \\  report options: --from YYYY-MM-DD --to YYYY-MM-DD --limit N --json --csv
        \\                  --release ID --campaign ID --path /path
    );
}
