const std = @import("std");
const domain = @import("domain.zig");
const ops = @import("ops.zig");
const product = @import("product.zig");
const catalog = @import("web/catalog.zig");
const webdata = @import("web/data.zig");
const html = @import("web/html.zig");
const store_mod = @import("store.zig");
const trackers = @import("assets.zig");
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
    if (std.mem.eql(u8, args[1], "init") and args.len >= 3) {
        try ops.init(allocator, io, output, args[2]);
        if (option(args, "--origin")) |origin| return runSetupLink(allocator, io, output, args[2], origin);
        return;
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
    if (std.mem.eql(u8, args[1], "migrate")) {
        return ops.migrate(allocator, io, output, data, option(args, "--backup") orelse return error.MissingBackup);
    }
    if (std.mem.eql(u8, args[1], "email") and args.len >= 3 and std.mem.eql(u8, args[2], "set")) {
        return runEmailSet(allocator, io, output, args, data);
    }
    if (std.mem.eql(u8, args[1], "user") and args.len >= 4 and std.mem.eql(u8, args[2], "invite")) {
        return runInvite(allocator, io, output, args[3], data, option(args, "--origin") orelse return error.MissingOrigin);
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
        if (std.mem.eql(u8, args[2], "list")) return runReport(allocator, io, output, args, data, "sessions", args[3], null);
        if (std.mem.eql(u8, args[2], "show") and args.len >= 5) return runReport(allocator, io, output, args, data, "session", args[3], args[4]);
        return error.InvalidSessionCommand;
    }
    if (std.mem.eql(u8, args[1], "report") and args.len >= 4) {
        const positional = if (args.len >= 5 and !std.mem.startsWith(u8, args[4], "--")) args[4] else null;
        return runReport(allocator, io, output, args, data, args[2], args[3], positional);
    }
    if (std.mem.eql(u8, args[1], "goal") and args.len >= 4) return runGoal(allocator, io, output, args, data);
    if (std.mem.eql(u8, args[1], "funnel") and args.len >= 4) return runFunnel(allocator, io, output, args, data);
    if (std.mem.eql(u8, args[1], "campaign") and args.len >= 4) return runCampaign(allocator, io, output, args, data);
    if (std.mem.eql(u8, args[1], "stats")) return runStats(allocator, io, output, data);
    if (std.mem.eql(u8, args[1], "tail") and args.len >= 3) return runTail(allocator, io, output, args, data);
    if (std.mem.eql(u8, args[1], "site")) return runSite(allocator, io, output, args, data);
    if (std.mem.eql(u8, args[1], "geo") and args.len >= 4 and std.mem.eql(u8, args[2], "import")) return runGeoImport(allocator, io, output, args[3], data);
    if (std.mem.eql(u8, args[1], "geo") and args.len >= 4 and std.mem.eql(u8, args[2], "lookup")) {
        const paths = try store_mod.Paths.init(allocator, data);
        defer paths.deinit(allocator);
        var geo = try @import("geo.zig").Geo.open(io, paths.geo);
        defer geo.close(io);
        const place = geo.lookup(args[3]) orelse return output.writeAll("unknown\n");
        return output.print("{s}\t{s}\t{s}\n", .{ place.country, place.region, place.city });
    }
    if (std.mem.eql(u8, args[1], "forget") and args.len >= 3) return runForget(allocator, io, output, args, data);
    return error.InvalidCommand;
}

fn pinOrigin(allocator: std.mem.Allocator, store: *store_mod.Store, origin: []const u8) !void {
    // Passkeys are bound to this address; it is set here, never from requests.
    const existing = try @import("web/data.zig").setting(allocator, &store.database, .public_origin);
    if (existing) |value| if (!std.mem.eql(u8, value, origin)) return error.OriginAlreadyPinned;
    try @import("web/data.zig").putSetting(allocator, &store.database, .public_origin, origin);
}

fn runInvite(allocator: std.mem.Allocator, io: std.Io, output: *std.Io.Writer, email: []const u8, data: []const u8, origin_value: []const u8) !void {
    const origin = try domain.normalizeOrigin(allocator, origin_value);
    var store = try store_mod.Store.open(allocator, io, data, true);
    defer store.close();
    try pinOrigin(allocator, &store, origin);
    const token = try @import("web/auth.zig").createInvite(allocator, io, &store.database, email, domain.nowMs());
    try output.print("invite created email={s} expires_in_days=7\n{s}/invite/{s}\n", .{ email, origin, &token });
}

/// Configures SMTP from the shell. The password comes from stdin so it never
/// appears in the process list; a test email must arrive before it is saved.
fn runEmailSet(allocator: std.mem.Allocator, io: std.Io, output: *std.Io.Writer, args: []const []const u8, data: []const u8) !void {
    const mail = @import("web/mail.zig");
    const web_data = @import("web/data.zig");
    const security = std.meta.stringToEnum(mail.Security, option(args, "--security") orelse "tls") orelse return error.InvalidSecurity;
    const default_port: u16 = switch (security) {
        .tls => 465,
        .starttls => 587,
        .none => 25,
    };
    const port = if (option(args, "--port")) |text| std.fmt.parseInt(u16, text, 10) catch return error.InvalidPort else default_port;
    const host = option(args, "--host") orelse return error.MissingHost;
    const username = option(args, "--username") orelse "";
    const from = option(args, "--from") orelse return error.MissingFrom;
    var buffer: [1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &buffer);
    const password = std.mem.trim(u8, try stdin.interface.allocRemaining(allocator, .limited(1024)), " \r\n");
    const paths = try store_mod.Paths.init(allocator, data);
    defer paths.deinit(allocator);
    var master = try store_mod.readKey(io, paths.key);
    defer std.crypto.secureZero(u8, &master);
    var store = try store_mod.Store.open(allocator, io, data, true);
    defer store.close();
    const config: mail.Config = .{ .host = host, .port = port, .security = security, .username = username, .password = password, .from = from };
    const to = option(args, "--test-to") orelse mail.addressOf(from);
    try mail.send(allocator, io, config, .{
        .to = &.{to},
        .subject = "Analytico email delivery works",
        .text = "Alerts, scheduled reports and invites will arrive from this address.",
        .html = "<p>Alerts, scheduled reports and invites will arrive from this address.</p>",
    });
    const db = &store.database;
    try web_data.putSetting(allocator, db, .@"smtp.host", host);
    try web_data.putSetting(allocator, db, .@"smtp.port", try std.fmt.allocPrint(allocator, "{d}", .{port}));
    try web_data.putSetting(allocator, db, .@"smtp.security", @tagName(security));
    try web_data.putSetting(allocator, db, .@"smtp.username", username);
    try web_data.putSetting(allocator, db, .@"smtp.from", from);
    if (password.len != 0) try web_data.putSetting(allocator, db, .@"smtp.password", try @import("web/secret.zig").seal(allocator, io, master, password));
    try output.print("email delivery configured host={s} port={d} security={s} from={s}\ntest email sent to={s}\n", .{ host, port, @tagName(security), from, to });
}

fn runSetupLink(allocator: std.mem.Allocator, io: std.Io, output: *std.Io.Writer, data: []const u8, origin_value: []const u8) !void {
    const origin = try domain.normalizeOrigin(allocator, origin_value);
    var store = try store_mod.Store.open(allocator, io, data, true);
    defer store.close();
    try pinOrigin(allocator, &store, origin);
    const token = try @import("web/auth.zig").createSetupLink(allocator, io, &store.database, domain.nowMs());
    try output.print("create your account (link works once, expires in 1 hour):\n{s}/welcome/{s}\n", .{ origin, &token });
}

/// Builds geo.bin next to the database from a DB-IP "IP to City Lite" CSV.
/// The running server picks it up on its next start.
fn runGeoImport(allocator: std.mem.Allocator, io: std.Io, output: *std.Io.Writer, source: []const u8, data: []const u8) !void {
    const paths = try store_mod.Paths.init(allocator, data);
    defer paths.deinit(allocator);
    const temporary = try std.fmt.allocPrint(allocator, "{s}.new", .{paths.geo});
    std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
    const stats = try @import("geo.zig").import(allocator, io, source, temporary);
    var check = try @import("geo.zig").Geo.open(io, temporary);
    check.close(io);
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), paths.geo, io);
    try output.print("geo imported ipv4_ranges={d} ipv6_ranges={d} places={d} bytes={d}\nrestart the server to use it\n", .{ stats.v4, stats.v6, stats.places, stats.bytes });
}

/// Erases one visitor, or every visitor linked to one of your user IDs.
fn runForget(allocator: std.mem.Allocator, io: std.Io, output: *std.Io.Writer, args: []const []const u8, data: []const u8) !void {
    const collector = @import("collector.zig");
    const replay = @import("replay.zig");
    const paths = try store_mod.Paths.init(allocator, data);
    defer paths.deinit(allocator);
    var master = try store_mod.readKey(io, paths.key);
    defer std.crypto.secureZero(u8, &master);
    var store = try store_mod.Store.open(allocator, io, data, true);
    defer store.close();
    var site = try store.siteBySlug(args[2]);
    defer site.deinit(allocator);
    var visitors: std.ArrayList([]const u8) = .empty;
    try store.database.exec("BEGIN IMMEDIATE");
    errdefer store.database.exec("ROLLBACK") catch {};
    if (option(args, "--visitor")) |visitor_id| {
        try domain.validateUuid(visitor_id);
        try collector.forgetVisitor(allocator, &store, site.id, visitor_id);
        try visitors.append(allocator, visitor_id);
    } else if (option(args, "--user")) |user_id| {
        const hash = domain.userHash(master, site.public_id, user_id);
        try visitors.appendSlice(allocator, try collector.forgetUser(allocator, &store, site.id, &hash));
    } else return error.MissingVisitorOrUser;
    try store.database.exec("COMMIT");
    var replays = try replay.open(allocator, paths.replays, true);
    defer replays.close();
    try replay.forgetVisitors(allocator, &replays, site.id, visitors.items);
    try output.print("forgotten site={s} visitors={d}\n", .{ site.slug, visitors.items.len });
}

fn runTail(allocator: std.mem.Allocator, io: std.Io, output: *std.Io.Writer, args: []const []const u8, data: []const u8) !void {
    const limit = std.fmt.parseInt(i64, option(args, "--limit") orelse "50", 10) catch return error.InvalidLimit;
    if (limit < 1 or limit > 1000) return error.InvalidLimit;
    var store = try store_mod.Store.open(allocator, io, data, false);
    defer store.close();
    var site = try store.siteBySlug(args[2]);
    defer site.deinit(allocator);
    var cursor = domain.nowMs() - 7 * 86_400_000;
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
        try catalog.render(output, try catalog.sqlTable(allocator, &statement), .table);
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
    if (site.mode == .lite) return error.SessionModeRequired;
    if (std.mem.eql(u8, args[2], "list")) return product.funnelList(allocator, output, &store, site.id);
    if (std.mem.eql(u8, args[2], "show") and args.len >= 5) return runReport(allocator, io, output, args, data, "funnel", args[3], args[4]);
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
        const mode = try domain.parseMode(option(args, "--mode") orelse "full");
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
        const variant = trackers.forMode(site.mode, flag(args, "--rum"));
        const asset_path = trackers.scriptPath(variant);
        try output.print("<script defer src=\"{s}{s}\" data-site=\"{s}\"></script>\n", .{
            collector, asset_path, site.public_id,
        });
        return;
    }
    return error.InvalidSiteCommand;
}

/// Any report in the catalog. The period comes from --days N, --range or
/// --from/--to; filters from --filter dim:value (repeatable) and the older
/// --path, --campaign and --release; report parameters from --<name>; a
/// value after the site fills the report's required parameter.
fn runReport(allocator: std.mem.Allocator, io: std.Io, output: *std.Io.Writer, args: []const []const u8, data: []const u8, name: []const u8, slug: []const u8, positional: ?[]const u8) !void {
    const canonical = try std.mem.replaceOwned(u8, allocator, name, "-", "_");
    const report = catalog.find(canonical) orelse return error.UnknownReport;
    var store = try store_mod.Store.open(allocator, io, data, false);
    defer store.close();
    const site = try webdata.siteBySlug(allocator, &store.database, slug) orelse return error.UnknownSite;
    var query: std.Io.Writer.Allocating = .init(allocator);
    const w = &query.writer;
    const takes_path = for (report.params) |param| {
        if (std.mem.eql(u8, param.name, "from_path")) break true;
    } else false;
    if (option(args, "--range")) |range| try w.print("&range={f}", .{html.url(range)});
    if (option(args, "--days")) |text| {
        const days = std.fmt.parseInt(i64, text, 10) catch return error.InvalidDays;
        if (days < 1 or days > 3650) return error.InvalidDays;
        const today = domain.nowMs();
        try w.print("&range=custom&from={s}&to={s}", .{ &webdata.dateText(today - (days - 1) * webdata.day_ms), &webdata.dateText(today) });
    }
    if (option(args, "--from")) |from| {
        // `report paths --from /pricing` names a page, not a date.
        if (takes_path and std.mem.startsWith(u8, from, "/")) {
            try w.print("&from_path={f}", .{html.url(from)});
        } else try w.print("&range=custom&from={f}&to={f}", .{ html.url(from), html.url(option(args, "--to") orelse &webdata.dateText(domain.nowMs())) });
    }
    if (query.written().len == 0 or std.mem.indexOf(u8, query.written(), "range=") == null) try w.writeAll("&range=7d");
    for ([_][2][]const u8{ .{ "--path", "page" }, .{ "--campaign", "campaign" }, .{ "--release", "release" } }) |legacy| {
        if (option(args, legacy[0])) |value| if (value.len != 0) try w.print("&f={s}:{f}", .{ legacy[1], html.url(value) });
    }
    for (args, 0..) |arg, index| if (std.mem.eql(u8, arg, "--filter") and index + 1 < args.len) try w.print("&f={f}", .{html.url(args[index + 1])});
    for (report.params) |param| {
        var flag_buffer: [64]u8 = undefined;
        const flag_name = std.fmt.bufPrint(&flag_buffer, "--{s}", .{param.name}) catch continue;
        if (option(args, flag_name)) |value| try w.print("&{s}={f}", .{ param.name, html.url(value) });
    }
    if (positional) |value| for (report.params) |param| if (param.required) {
        try w.print("&{s}={f}", .{ param.name, html.url(value) });
        break;
    };
    const params = try html.Params.parse(allocator, query.written());
    const table = try catalog.run(allocator, &store.database, report, site, params, domain.nowMs());
    const format: catalog.Format = if (flag(args, "--json")) .json else if (flag(args, "--csv")) .csv else .table;
    return catalog.render(output, table, format);
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
        \\  analytico init <data-dir> [--origin https://analytics.example]
        \\    with --origin, prints a one-time link to create the first account
        \\  analytico site add <slug> <origin> [--mode full|session|lite] [--data <dir>]
        \\    full (default) asks for consent where needed and starts as lite
        \\  analytico geo import <dbip-city-lite.csv.gz> --data <dir>
        \\    places visitors by country, region and city; IPs are never stored
        \\  analytico geo lookup <ip> --data <dir>
        \\  analytico forget <site> --visitor <id> | --user <your-user-id> --data <dir>
        \\  analytico site origin-add <slug> <origin> [--data <dir>]
        \\  analytico site list|show|snippet|disable ... [--data <dir>]
        \\
        \\Workspace:
        \\  analytico user invite <email> --origin https://analytics.example.com --data <dir>
        \\    prints a one-time link to sign in (passkey, Google, ChatGPT or password)
        \\
        \\Operations:
        \\  analytico serve --data <dir> --listen 127.0.0.1:4318
        \\  analytico migrate --data <dir> --backup <new-backup.db>
        \\  analytico email set --host smtp.example.com --from "Analytico <a@b.c>" [--username u] [--security tls|starttls|none] [--port n] --data <dir> < password-file
        \\  analytico stats --data <dir>
        \\  analytico doctor --data <dir>
        \\  analytico backup <data-dir> <new-backup.db>
        \\  analytico restore <backup.db> <new-data-dir>
        \\  analytico prune <data-dir> --before YYYY-MM-DD --backup <new-backup.db>
        \\  analytico vacuum <data-dir> --backup <new-backup.db>
        \\  analytico tail <site> [--limit 50] [--follow] --data <dir>
        \\
        \\Reports:
        \\  analytico report <name> <site> [value] [--range 24h|7d|30d|90d | --days N | --from YYYY-MM-DD --to YYYY-MM-DD]
        \\                  [--filter dim:value ...] [--limit N] [--<parameter> value] [--json | --csv]
        \\  analytico session list <site>          (report sessions)
        \\  analytico session show <site> <id>     (report session)
        \\  analytico goal add <site> <name> event|path <match>
        \\  analytico goal list <site>
        \\  analytico funnel add <site> <name> <goal|event:name|path:/path>...
        \\  analytico funnel list <site>
        \\  analytico funnel show <site> <name>    (report funnel)
        \\  analytico campaign spend-add <site> <date> <source> <campaign> <content> <amount-minor> <currency>
        \\  analytico campaign spend-import <site> <costs.csv>
        \\
        \\Report names (the same reports serve the read API at /api/v1/sites/<site>/<name> and MCP connectors):
        \\
    );
    for (&catalog.reports) |*report| {
        try output.print("  {s:<20} {s}", .{ report.name, report.description });
        for (report.params) |param| {
            if (param.required) try output.print(" <{s}>", .{param.name}) else if (!std.mem.eql(u8, param.name, "limit")) try output.print(" [--{s}]", .{param.name});
        }
        try output.writeByte('\n');
    }
}
