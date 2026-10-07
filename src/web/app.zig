//! Web workspace entry point: request context, auth gate and routing.
const std = @import("std");
const assets = @import("../assets.zig");
const auth = @import("auth.zig");
const signin = @import("signin.zig");
const ctx_mod = @import("ctx.zig");
const data = @import("data.zig");
const db_mod = @import("../db.zig");
const html = @import("html.zig");
const layout = @import("layout.zig");
const overview = @import("overview.zig");
const analyze = @import("analyze.zig");
const manage = @import("manage.zig");
const settings = @import("settings.zig");
const ai = @import("ai.zig");
const mcp = @import("mcp.zig");
const behaviour = @import("behaviour.zig");
const customers = @import("customers.zig");
const heatmaps = @import("heatmaps.zig");
const share = @import("share.zig");
const integrations = @import("integrations.zig");

const Ctx = ctx_mod.Ctx;

pub fn handle(
    arena: std.mem.Allocator,
    shared: *ctx_mod.Shared,
    read_db: *db_mod.Db,
    request: *std.http.Server.Request,
    deadline: *std.Io.Clock.Timestamp,
    target: []const u8,
    path: []const u8,
) !?i64 {
    const query_start = std.mem.findScalar(u8, target, '?');
    db_mod.thread_ns = 0;
    db_mod.thread_statements = 0;
    data.prefetch_ns = 0;
    var memo: data.Memo = .{};
    data.memo = &memo;
    defer data.memo = null;
    var ctx: Ctx = .{
        .started_ns = db_mod.monotonicNs(),
        .arena = arena,
        .shared = shared,
        .db = read_db,
        .request = request,
        .deadline = deadline,
        .method = if (request.head.method == .HEAD) .GET else request.head.method,
        .target = target,
        .path = path,
        .query = html.Params.parse(arena, if (query_start) |index| target[index + 1 ..] else "") catch .{},
        .head = try readHead(arena, request),
        .body = .init(arena),
    };
    route(&ctx) catch |err| {
        // The browser went away mid-response, typically a prefetch it no
        // longer needed; nothing failed here.
        if (err == error.WriteFailed) return null;
        std.log.warn("web_request_failed method={s} path={s} code={s}", .{ @tagName(ctx.method), path, @errorName(err) });
        if (ctx.responded) return null;
        ctx.headers.clearRetainingCapacity();
        try switch (err) {
            error.PayloadTooLarge => layout.message(&ctx, .payload_too_large, "That was too large", "The upload is over the 2 MB limit."),
            error.InvalidBody, error.InvalidEncoding => layout.message(&ctx, .bad_request, "Something went wrong", "The request could not be read. Please try again."),
            else => layout.message(&ctx, .internal_server_error, "Something went wrong", "The error was logged. Reloading usually helps; if not, check Data health."),
        };
        return null;
    };
    if (ctx.live_site) |site_id| return site_id;
    if (!ctx.responded) try ctx.text(.internal_server_error, "no response\n");
    return null;
}

/// A full page load without a period opens the website with the period it
/// was last viewed in. The browser keeps it in a cookie as you navigate, and
/// applies it to in-app links itself.
fn rememberedView(ctx: *Ctx, site: data.Site) !void {
    if (ctx.head.fetch) return;
    for ([_][]const u8{ "range", "from", "to", "cmp" }) |key| if (ctx.query.get(key) != null) return;
    const name = try std.fmt.allocPrint(ctx.arena, "an_view_{s}", .{site.slug});
    const saved = html.decodeComponent(ctx.arena, ctx.cookie(name) orelse return) catch return;
    const raw = if (std.mem.findScalar(u8, ctx.target, '?')) |index| ctx.target[index + 1 ..] else "";
    ctx.query = html.Params.parse(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{s}&{s}", .{ saved, raw })) catch return;
}

fn readHead(arena: std.mem.Allocator, request: *std.http.Server.Request) !ctx_mod.Head {
    var out: ctx_mod.Head = .{ .content_length = request.head.content_length };
    var cookies: std.ArrayList(u8) = .empty;
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        const name = header.name;
        const value = try arena.dupe(u8, header.value);
        if (std.ascii.eqlIgnoreCase(name, "cookie")) {
            if (cookies.items.len != 0) try cookies.appendSlice(arena, "; ");
            try cookies.appendSlice(arena, value);
        } else if (std.ascii.eqlIgnoreCase(name, "origin")) {
            out.origin = value;
        } else if (std.ascii.eqlIgnoreCase(name, "host")) {
            out.host = value;
        } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            out.content_type = value;
        } else if (std.ascii.eqlIgnoreCase(name, "x-forwarded-for")) {
            out.forwarded_for = value;
        } else if (std.ascii.eqlIgnoreCase(name, "x-forwarded-proto")) {
            out.forwarded_proto = value;
        } else if (std.ascii.eqlIgnoreCase(name, "x-forwarded-host")) {
            out.host = value;
        } else if (std.ascii.eqlIgnoreCase(name, "user-agent")) {
            out.user_agent = value;
        } else if (std.ascii.eqlIgnoreCase(name, "authorization")) {
            out.authorization = value;
        } else if (std.ascii.eqlIgnoreCase(name, "accept")) {
            out.accept = value;
        } else if (std.ascii.eqlIgnoreCase(name, "referer")) {
            out.referer = value;
        } else if (std.ascii.eqlIgnoreCase(name, "if-none-match")) {
            out.if_none_match = value;
        } else if (std.ascii.eqlIgnoreCase(name, "x-requested-with")) {
            out.fetch = std.mem.eql(u8, value, "fetch");
        }
    }
    out.cookie = cookies.items;
    return out;
}

fn segments(arena: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        try out.append(arena, html.decodeComponent(arena, part) catch return error.InvalidEncoding);
    }
    return out.items;
}

fn is(value: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, value, expected);
}

fn route(ctx: *Ctx) !void {
    const get = ctx.method == .GET;
    const post = ctx.method == .POST;
    if (get and std.mem.startsWith(u8, ctx.path, "/_/")) {
        const asset = assets.find(ctx.path) orelse return ctx.text(.not_found, "not found\n");
        try ctx.header("cache-control", "public, max-age=31536000, immutable");
        try ctx.body.writer.writeAll(asset.bytes);
        return ctx.finish(asset.content_type);
    }
    if (get and is(ctx.path, "/favicon.ico")) {
        try ctx.header("cache-control", "public, max-age=86400");
        try ctx.body.writer.writeAll(assets.find(assets.path("favicon.svg")).?.bytes);
        return ctx.finish("image/svg+xml");
    }
    const parts = try segments(ctx.arena, ctx.path);

    // Public routes with their own authentication.
    if (try mcp.route(ctx, parts)) return;
    if (try share.route(ctx, parts)) return;
    if (post and parts.len != 0 and (is(parts[0], "login") or is(parts[0], "invite") or is(parts[0], "welcome") or is(parts[0], "auth")) and !ctx.sameOrigin()) {
        return ctx.text(.forbidden, "cross-origin request refused\n");
    }
    if (parts.len == 1 and is(parts[0], "login")) {
        if (get) return signin.loginPage(ctx, "");
        if (post) return signin.loginPost(ctx);
    }
    if (parts.len == 2 and is(parts[0], "invite")) {
        if (get) return signin.invitePage(ctx, parts[1], "");
        if (post) return signin.invitePost(ctx, parts[1]);
    }
    if (parts.len == 2 and is(parts[0], "welcome")) {
        if (get) return signin.setupPage(ctx, parts[1], "");
        if (post) return signin.setupPost(ctx, parts[1]);
    }
    if (parts.len == 3 and is(parts[0], "auth")) {
        if (post and is(parts[1], "passkey") and is(parts[2], "options")) return signin.passkeyOptions(ctx);
        if (post and is(parts[1], "passkey") and is(parts[2], "verify")) return signin.passkeyVerify(ctx);
        const method = std.meta.stringToEnum(signin.Method, parts[1]);
        if (get and method != null and method.?.provider() != null) {
            if (is(parts[2], "start")) return signin.providerStart(ctx, method.?);
            if (is(parts[2], "callback")) return signin.providerCallback(ctx, method.?);
        }
    }

    ctx.user = try auth.currentUser(ctx);
    if (ctx.user == null) {
        if (get) return ctx.redirectFmt("/login?next={f}", .{html.url(ctx.target)});
        return ctx.text(.unauthorized, "sign in required\n");
    }
    if (!get and !ctx.sameOrigin()) return ctx.text(.forbidden, "cross-origin request refused\n");

    if (parts.len == 0) {
        const sites = try ctx.visibleSites();
        if (sites.len == 0 and !ctx.can(.admin)) return layout.message(ctx, .ok, "No websites yet", "Nobody has shared a website with you on this instance yet. Ask an admin to give you access.");
        if (sites.len == 0) return ctx.redirect("/setup");
        return ctx.redirectFmt("/{s}", .{sites[0].slug});
    }
    if (is(parts[0], "logout") and post) return auth.logout(ctx);
    if (is(parts[0], "setup") and parts.len == 1) {
        if (!ctx.can(.admin)) return forbidden(ctx);
        if (get) return manage.addSitePage(ctx, "", "");
        if (post) return manage.addSitePost(ctx);
    }
    if (is(parts[0], "settings")) return settings.route(ctx, parts[1..]);
    if (is(parts[0], "integrations")) return integrations.route(ctx, parts[1..]);

    const site = try data.siteBySlug(ctx.arena, ctx.db, parts[0]) orelse
        return layout.message(ctx, .not_found, "Nothing here", "That website or page doesn’t exist on this instance.");
    // Websites outside someone's access look exactly like missing ones.
    if (!try ctx.canSee(site.id)) return layout.message(ctx, .not_found, "Nothing here", "That website or page doesn’t exist on this instance.");
    const rest = parts[1..];
    const page = if (rest.len == 0) "" else rest[0];
    const id: ?i64 = if (rest.len >= 2) std.fmt.parseInt(i64, rest[1], 10) catch null else null;
    const action = if (rest.len >= 3) rest[2] else "";

    if (get) try rememberedView(ctx, site);
    if (get) {
        if (rest.len == 0) return overview.page(ctx, site);
        if (rest.len == 1) {
            if (is(page, "pages")) return analyze.pages(ctx, site);
            if (is(page, "acquisition")) return analyze.acquisition(ctx, site);
            if (is(page, "events")) return analyze.events(ctx, site);
            if (is(page, "funnels")) return analyze.funnels(ctx, site, null);
            if (is(page, "sessions")) return analyze.sessions(ctx, site);
            if (is(page, "audience")) return analyze.audience(ctx, site);
            if (is(page, "search")) return integrations.searchPage(ctx, site);
            if (is(page, "heatmaps")) return heatmaps.page(ctx, site);
            if (is(page, "errors")) return behaviour.errors(ctx, site);
            if (is(page, "revenue")) return customers.revenue(ctx, site);
            if (is(page, "retention")) return customers.retention(ctx, site);
            if (is(page, "people")) return customers.people(ctx, site);
            if (is(page, "performance")) return analyze.performance(ctx, site);
            if (is(page, "health")) return manage.health(ctx, site);
            if (is(page, "reports")) return manage.reports(ctx, site);
            if (is(page, "dashboards")) return manage.dashboards(ctx, site, null);
            if (is(page, "setup")) return manage.setupPage(ctx, site);
            if (is(page, "stream")) {
                // The connection is handed to the live broadcaster.
                ctx.live_site = site.id;
                ctx.responded = true;
                return;
            }
            if (is(page, "setup.json")) return manage.setupStatus(ctx, site);
            if (is(page, "palette.json")) return overview.palette(ctx, site);
            if (is(page, "match.json")) return overview.match(ctx, site);
            if (is(page, "values.json")) return overview.values(ctx, site);
            if (is(page, "alert-preview.json")) return manage.alertPreview(ctx, site);
            if (is(page, "export.csv")) return overview.exportCsv(ctx, site);
            if (is(page, "ask")) return ai.askPage(ctx, site);
        }
        if (rest.len == 2 and id != null) {
            if (is(page, "funnels")) return analyze.funnels(ctx, site, id);
            if (is(page, "dashboards")) return manage.dashboards(ctx, site, id);
        }
        if (rest.len == 2 and is(page, "replays")) return behaviour.player(ctx, site, rest[1]);
        if (rest.len == 3 and is(page, "replays") and is(rest[2], "events")) return behaviour.replayEvents(ctx, site, rest[1]);
        if (rest.len == 2 and is(page, "people")) return customers.person(ctx, site, rest[1]);
        if (rest.len == 2 and is(page, "heatmaps") and is(rest[1], "open")) return heatmaps.open(ctx, site);
        if (rest.len == 2 and is(page, "heatmaps") and is(rest[1], "warm")) return heatmaps.warm(ctx, site);
    }
    const summary = rest.len == 3 and is(page, "replays") and is(rest[2], "summary");
    if (post and !ctx.can(.editor) and !summary and !(rest.len == 1 and (is(page, "ask") or is(page, "why") or is(page, "describe")))) return forbidden(ctx);
    if (post) {
        if (rest.len == 1) {
            if (is(page, "annotations")) return overview.addAnnotation(ctx, site);
            if (is(page, "segments")) return overview.addSegment(ctx, site);
            if (is(page, "goals")) return analyze.addGoal(ctx, site);
            if (is(page, "funnels")) return analyze.addFunnel(ctx, site);
            if (is(page, "spend")) return analyze.setSpend(ctx, site);
            if (is(page, "spend-import")) return analyze.importSpend(ctx, site);
            if (is(page, "alerts")) return manage.addAlert(ctx, site);
            if (is(page, "schedules")) return manage.addSchedule(ctx, site);
            if (is(page, "dashboards")) return manage.addDashboard(ctx, site);
            if (is(page, "ask")) return ai.ask(ctx, site);
            if (is(page, "why")) return ai.why(ctx, site);
            if (is(page, "describe")) return ai.describe(ctx, site);
        }
        if (summary) return ai.sessionSummary(ctx, site, rest[1]);
        if (rest.len == 3 and id != null) {
            if (is(page, "annotations") and is(action, "delete")) return overview.deleteAnnotation(ctx, site, id.?);
            if (is(page, "annotations") and is(action, "keep")) return overview.keepAnnotation(ctx, site, id.?);
            if (is(page, "segments") and is(action, "delete")) return overview.deleteSegment(ctx, site, id.?);
            if (is(page, "goals") and is(action, "delete")) return analyze.deleteGoal(ctx, site, id.?);
            if (is(page, "funnels")) return analyze.funnelAction(ctx, site, id.?, action);
            if (is(page, "alerts")) return manage.alertAction(ctx, site, id.?, action);
            if (is(page, "schedules")) return manage.scheduleAction(ctx, site, id.?, action);
            if (is(page, "dashboards")) return manage.dashboardAction(ctx, site, id.?, action);
        }
        if (rest.len == 1 and is(page, "shares")) {
            if (!ctx.can(.admin)) return forbidden(ctx);
            return share.createLink(ctx, site);
        }
        if (rest.len == 3 and is(page, "shares") and is(action, "revoke") and id != null) {
            if (!ctx.can(.admin)) return forbidden(ctx);
            return share.revokeLink(ctx, site, id.?);
        }
        if (rest.len == 3 and is(page, "people") and is(rest[2], "forget")) {
            if (!ctx.can(.admin)) return forbidden(ctx);
            return customers.forget(ctx, site, rest[1]);
        }
    }
    return layout.message(ctx, .not_found, "Nothing here", "That page doesn’t exist. It may have been renamed or removed.");
}

pub fn forbidden(ctx: *Ctx) !void {
    return layout.message(ctx, .forbidden, "Not allowed", "Your role on this instance can’t do that. An admin can change your role under Settings → Team & access.");
}

/// Shared helpers for page handlers.
pub fn shell(ctx: *Ctx, site: data.Site, nav: layout.Nav, title: []const u8, view: ?data.View) !layout.Shell {
    var carry: []const u8 = "";
    if (view) |value| {
        carry = try value.href(ctx.arena, "", &.{.{ "m", "" }});
    }
    return .{
        .title = title,
        .nav = nav,
        .site = site,
        .sites = try ctx.visibleSites(),
        .carry = carry,
        .has_view = view != null,
        .health = try manage.healthLevel(ctx, site),
        .consented = try consentShare(ctx, site),
    };
}

/// Full mode: page views in the last 7 days whose visitor consented, or did
/// not need to, out of all Full-mode page views.
pub fn consentShare(ctx: *Ctx, site: data.Site) !?f64 {
    if (site.mode != .full) return null;
    const now = ctx.now();
    const view = try data.View.parse(ctx.arena, site, .{}, now);
    const start = now - @mod(now, data.day_ms) - 6 * data.day_ms;
    const sums = try data.keySums(ctx.arena, ctx.db, view, "consent", start, now + 1, 20);
    var asked: i64 = 0;
    var consented: i64 = 0;
    for ([_][]const u8{ "granted", "not_required", "pending", "denied", "gpc" }) |state| {
        const views = data.keySum(sums, state).views;
        asked += views;
        if (std.mem.eql(u8, state, "granted") or std.mem.eql(u8, state, "not_required")) consented += views;
    }
    if (asked == 0) return null;
    return @as(f64, @floatFromInt(consented)) / @as(f64, @floatFromInt(asked));
}
