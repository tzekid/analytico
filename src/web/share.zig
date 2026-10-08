//! Public, read-only links (for clients, investors, a wall screen) and the
//! token-scoped read API. Both work without a workspace session.
const std = @import("std");
const catalog = @import("catalog.zig");
const auth = @import("auth.zig");
const chart = @import("chart.zig");
const ctx_mod = @import("ctx.zig");
const customers = @import("customers.zig");
const data = @import("data.zig");
const db_mod = @import("../db.zig");
const mcp = @import("mcp.zig");
const push = @import("push.zig");
const geo = @import("../geo.zig");
const html = @import("html.zig");
const layout = @import("layout.zig");
const ui = @import("ui.zig");
const overview = @import("overview.zig");
const assets = @import("../assets.zig");

const Ctx = ctx_mod.Ctx;
const icon = layout.icon;
const render = html.render;

fn is(value: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, value, expected);
}

pub fn route(ctx: *Ctx, parts: []const []const u8) !bool {
    if (parts.len == 2 and is(parts[0], "share")) {
        ctx.revalidate = true;
        try sharePage(ctx, parts[1]);
        return true;
    }
    if (parts.len >= 2 and is(parts[0], "api") and is(parts[1], "v1")) {
        ctx.revalidate = true;
        try api(ctx, parts[2..]);
        return true;
    }
    return false;
}

// ---------------------------------------------------------------- share links

const Link = struct { id: i64, site: data.Site, label: []const u8, password_hash: ?[]const u8, allow_range: bool, show_details: bool };

fn findLink(ctx: *Ctx, token: []const u8) !?Link {
    if (token.len != 64) return null;
    const hashed = auth.hashToken(token);
    var statement = try ctx.db.prepare(ctx.arena, "SELECT l.id,s.slug,l.label,l.password_hash,l.allow_range,l.show_details FROM share_links l JOIN sites s ON s.id=l.site_id WHERE l.token_hash=? AND (l.expires_at_ms IS NULL OR l.expires_at_ms>?) AND s.enabled=1");
    defer statement.deinit();
    try statement.bindText(1, &hashed);
    try statement.bindInt(2, ctx.now());
    if (try statement.step() != .row) return null;
    const site = try data.siteBySlug(ctx.arena, ctx.db, statement.columnText(1)) orelse return null;
    return .{
        .id = statement.columnInt(0),
        .site = site,
        .label = try ctx.arena.dupe(u8, statement.columnText(2)),
        .password_hash = if (statement.columnType(3) == db_mod.sqlite.SQLITE_NULL) null else try ctx.arena.dupe(u8, statement.columnText(3)),
        .allow_range = statement.columnBool(4),
        .show_details = statement.columnBool(5),
    };
}

/// Proof that this browser entered the link's password: an HMAC of the link,
/// so it can't be reused for another link.
fn unlockValue(ctx: *Ctx, link: Link) [64]u8 {
    var mac: [32]u8 = undefined;
    var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(&ctx.shared.master_key);
    hmac.update("analytico/share/v1\x00");
    var id_buffer: [24]u8 = undefined;
    hmac.update(std.fmt.bufPrint(&id_buffer, "{d}", .{link.id}) catch unreachable);
    hmac.update(link.password_hash orelse "");
    hmac.final(&mac);
    return std.fmt.bytesToHex(mac, .lower);
}

fn sharePage(ctx: *Ctx, token: []const u8) !void {
    const arena = ctx.arena;
    const link = try findLink(ctx, token) orelse return layout.message(ctx, .not_found, "This link doesn’t work anymore", "It may have expired or been revoked. Ask whoever shared it for a new one.");
    ctx.frame_ancestors = "*";
    const cookie_name = try std.fmt.allocPrint(arena, "an_share_{d}", .{link.id});
    if (link.password_hash) |stored| {
        const expected = unlockValue(ctx, link);
        const unlocked = if (ctx.cookie(cookie_name)) |value| std.mem.eql(u8, value, &expected) else false;
        if (!unlocked) {
            if (ctx.method == .POST) {
                if (!ctx.sameOrigin()) return ctx.text(.forbidden, "cross-origin request refused\n");
                if (auth.tooManyFailures(ctx)) return passwordPage(ctx, link, "Too many attempts. Try again in 15 minutes.");
                if (!auth.passwordMatches(ctx, stored, try ctx.field("password"))) {
                    auth.recordFailure(ctx);
                    return passwordPage(ctx, link, "That password isn’t right.");
                }
                try ctx.header("set-cookie", try std.fmt.allocPrint(arena, "{s}={s}; Path=/share/; Max-Age=86400; HttpOnly; SameSite=Lax{s}", .{ cookie_name, &expected, if (ctx.secureOrigin()) "; Secure" else "" }));
                return ctx.redirectFmt("/share/{s}", .{token});
            }
            return passwordPage(ctx, link, "");
        }
    }
    if (ctx.method != .GET) return ctx.text(.method_not_allowed, "read-only link\n");
    {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try db.run(arena, "UPDATE share_links SET views=views+1,last_viewed_at_ms=? WHERE id=?", .{ ctx.now(), link.id });
    }
    var params = ctx.query;
    if (!link.allow_range) params = .{};
    // Public views offer the fixed ranges only, never filters.
    const range_param = params.get("range") orelse "7d";
    const safe_range = if (is(range_param, "30d") or is(range_param, "90d")) range_param else "7d";
    const view = try data.View.parse(arena, link.site, try html.Params.parse(arena, try std.fmt.allocPrint(arena, "range={s}", .{safe_range})), ctx.now());
    const site = link.site;
    const embed = ctx.param("embed") != null;
    try layout.document(ctx, try std.fmt.allocPrint(arena, "{s} · {s}", .{ link.label, site.title() }));
    const w = ctx.w();
    try render(w,
        \\<main class="public{!embed}"><header class="public-head"><div class="row nowrap"><span class="site-avatar site-avatar-l">{initial}</span><div><strong>{title}</strong><small>{label} · {host}</small></div></div>
    , .{ .embed = if (embed) " embed" else "", .initial = &[_]u8{site.initial()}, .title = site.title(), .label = link.label, .host = site.host() });
    if (link.allow_range) {
        try w.writeAll("<nav class=\"seg\" aria-label=\"Date range\">");
        for ([_][]const u8{ "7d", "30d", "90d" }) |kind| try render(w, "<a href=\"/share/{token}?range={kind}{!embed}\"{!current}>{kind}</a>", .{ .token = token, .kind = kind, .embed = if (embed) "&amp;embed=1" else "", .current = if (is(kind, safe_range)) " aria-current=\"true\"" else "" });
        try w.writeAll("</nav>");
    }
    const range = view.range;
    try render(w, "</header><h1 class=\"title mt-28\">Last {days} days</h1><p class=\"subtitle\">{range} · compared with {against}</p><div class=\"metrics mt-20\">", .{
        .days = if (is(safe_range, "30d")) "30" else if (is(safe_range, "90d")) "90" else "7",
        .range = range,
        .against = try std.fmt.allocPrint(arena, "{f}", .{range.text(.compared)}),
    });
    const current = try data.totals(arena, ctx.db, view, range.start_ms, range.end_ms);
    const previous = try data.totals(arena, ctx.db, view, range.prev_start_ms, range.prev_end_ms);
    const now_sales = try customers.sales(ctx.arena, ctx.db, view, range.start_ms, range.end_ms);
    const before_sales = try customers.sales(ctx.arena, ctx.db, view, range.prev_start_ms, range.prev_end_ms);
    try tile(ctx, view, 0, "audience", "Visitors / day", try std.fmt.allocPrint(arena, "{f}", .{html.int(@intFromFloat(@round(current.metric(.visitors, range))))}), current.metric(.visitors, range), previous.metric(.visitors, range), try data.series(arena, ctx.db, view, .visitors, range.start_ms));
    try tile(ctx, view, 1, "pages", "Page views", try std.fmt.allocPrint(arena, "{f}", .{html.int(current.views)}), @floatFromInt(current.views), @floatFromInt(previous.views), try data.series(arena, ctx.db, view, .views, range.start_ms));
    if (now_sales.orders > 0 or before_sales.orders > 0) {
        try tile(ctx, view, 2, "revenue", "Revenue", try std.fmt.allocPrint(arena, "{f}", .{html.money(now_sales.revenue, site.currency)}), @floatFromInt(now_sales.revenue), @floatFromInt(before_sales.revenue), null);
        try tile(ctx, view, 3, "cart", "Orders", try std.fmt.allocPrint(arena, "{f}", .{html.int(now_sales.orders)}), @floatFromInt(now_sales.orders), @floatFromInt(before_sales.orders), null);
    } else {
        try tile(ctx, view, 2, "performance", "Active time", try std.fmt.allocPrint(arena, "{f}", .{html.duration(current.active_ms)}), @floatFromInt(current.active_ms), @floatFromInt(previous.active_ms), try data.series(arena, ctx.db, view, .active, range.start_ms));
        try tile(ctx, view, 3, "calendar", "Visitor-days", try std.fmt.allocPrint(arena, "{f}", .{html.int(current.visitor_days)}), @floatFromInt(current.visitor_days), @floatFromInt(previous.visitor_days), null);
    }
    try w.print("</div><section class=\"card chart-card mt-16\"><div class=\"chart-head\"><h2>Page views</h2><div class=\"legend\"><span class=\"this\">{f}</span><span class=\"prev\">{f}</span></div></div>", .{ range.text(.this), range.text(.previous) });
    const names = try overview.labels(arena, range);
    try chart.trend(arena, w, .{ .current = try data.series(arena, ctx.db, view, .views, range.start_ms), .previous = try data.series(arena, ctx.db, view, .views, range.prev_start_ms), .labels = names[0], .long_labels = names[1], .unit = "views", .height = 200 });
    try w.writeAll("</section><div class=\"grid grid-3 mt-16\">");
    try countries(ctx, view, current.views);
    try devices(ctx, view, current.views);
    try goals(ctx, view);
    try w.writeAll("</div>");
    if (link.show_details) {
        try w.writeAll("<div class=\"grid grid-2 mt-16\">");
        try rankCard(ctx, view, .page, "Top pages", current.views);
        try rankCard(ctx, view, .source, "Where visitors come from", current.views);
        try w.writeAll("</div>");
    }
    try render(w, "<footer class=\"public-foot\"><span>Read-only view shared by {title} · no cookies are set on this page</span><span>Analytico</span></footer></main></body></html>", .{ .title = site.title() });
    return ctx.html();
}

fn passwordPage(ctx: *Ctx, link: Link, problem: []const u8) !void {
    ctx.body.writer.end = 0;
    try layout.document(ctx, link.label);
    const w = ctx.w();
    try render(w, "<main class=\"login\"><form class=\"login-card\" method=\"post\"><img src=\"{logo}\" width=\"32\" height=\"32\" alt=\"\"><h1>{label}</h1><p class=\"secondary\">{site} shared this view with a password.</p>", .{ .logo = assets.path("favicon.svg"), .label = link.label, .site = link.site.title() });
    if (problem.len != 0) try render(w, "<div class=\"callout callout-bad mt-14\"><span>{problem}</span></div>", .{ .problem = problem });
    try w.writeAll("<label class=\"field mt-16\">Password<input class=\"input\" type=\"password\" name=\"password\" required autofocus autocomplete=\"current-password\"></label><button class=\"btn btn-primary btn-block mt-14\">View</button></form></main></body></html>");
    return ctx.html();
}

fn tile(ctx: *Ctx, view: data.View, index: usize, icon_name: []const u8, label: []const u8, value: []const u8, current: f64, previous: f64, series: ?[]const f64) !void {
    try ui.metric(ctx.w(), ctx.arena, .{ .tone = ui.tones[index], .icon = icon_name, .label = label, .value = value, .spark = series, .change = try ui.change(ctx.arena, current, previous, false, try view.range.versus(ctx.arena)) });
}

fn countries(ctx: *Ctx, view: data.View, total: i64) !void {
    const w = ctx.w();
    try w.writeAll("<section class=\"card\">");
    try ui.cardHead(w, "Where they are", "");
    try w.writeAll("<div class=\"stack-s\">");
    var any = false;
    for (try data.top(ctx.arena, ctx.db, view, .country, 6)) |row| {
        if (is(row.key, "unknown")) continue;
        any = true;
        try ui.countryRow(w, ctx.arena, "", row.key, @as(f64, @floatFromInt(row.value)) / @as(f64, @floatFromInt(@max(total, 1))) * 100);
    }
    if (!any) try w.writeAll("<p class=\"hint\">Location isn’t collected for this website.</p>");
    try w.writeAll("</div></section>");
}

fn devices(ctx: *Ctx, view: data.View, total: i64) !void {
    _ = total;
    const w = ctx.w();
    const colors = [_][]const u8{ "var(--brand)", "var(--blue)", "var(--teal)", "var(--violet)" };
    var parts: std.ArrayList(ui.Part) = .empty;
    for (try data.top(ctx.arena, ctx.db, view, .device, 4), 0..) |row, index| try parts.append(ctx.arena, .{ .value = row.value, .color = colors[index % colors.len], .label = data.prettyLabel(ctx.arena, row.key) });
    try w.writeAll("<section class=\"card\">");
    try ui.cardHead(w, "Devices", "");
    try ui.shareBar(w, "mb-14", "stack-s", parts.items);
    try w.writeAll("</section>");
}

fn goals(ctx: *Ctx, view: data.View) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    try w.writeAll("<section class=\"card\">");
    try ui.cardHead(w, "Goals", "");
    try w.writeAll("<div class=\"stack-s\">");
    const Goal = struct { name: []const u8, kind: []const u8, match: []const u8 };
    const list = try ctx.db.all(arena, Goal, "SELECT name,kind,match_value FROM goals WHERE site_id=? ORDER BY name LIMIT 4", .{view.site.id});
    for (list) |goal| {
        const now_count = try data.goalCount(arena, ctx.db, view, goal.kind, goal.match, view.range.start_ms, view.range.end_ms, false);
        const before = try data.goalCount(arena, ctx.db, view, goal.kind, goal.match, view.range.prev_start_ms, view.range.prev_end_ms, false);
        const counts = [2]i64{ now_count.completions, before.completions };
        try render(w, "<div class=\"goal-tile\"><div><small>{name}</small><strong>{count}</strong></div>", .{ .name = goal.name, .count = html.int(counts[0]) });
        try ui.delta(w, @floatFromInt(counts[0]), @floatFromInt(counts[1]), false);
        try w.writeAll("</div>");
    }
    if (list.len == 0) try w.writeAll("<p class=\"hint\">No goals set up.</p>");
    try w.writeAll("</div></section>");
}

fn rankCard(ctx: *Ctx, view: data.View, dim: data.Dim, title: []const u8, total: i64) !void {
    const w = ctx.w();
    try w.writeAll("<section class=\"card\">");
    try ui.cardHead(w, title, "");
    try w.writeAll("<div class=\"rank\">");
    const rows = try data.top(ctx.arena, ctx.db, view, dim, 6);
    const keys = try ctx.arena.alloc([]const u8, rows.len);
    for (rows, keys) |row, *key| key.* = row.key;
    const labels = if (dim == .source) try overview.sourceLabels(ctx.arena, keys) else keys;
    for (rows, labels) |row, label| try ui.rankRow(w, ctx.arena, .{
        .width = @as(f64, @floatFromInt(row.value)) / @as(f64, @floatFromInt(@max(total, 1))) * 80 + 6,
        .bar = "var(--brand-wash)",
        .name = label,
        .value = try std.fmt.allocPrint(ctx.arena, "{f}", .{html.int(row.value)}),
        .pct = try std.fmt.allocPrint(ctx.arena, "{f}", .{html.share(row.value, total)}),
    });
    try w.writeAll("</div></section>");
}

/// Share management: create (with optional password and expiry) and revoke.
pub fn createLink(ctx: *Ctx, site: data.Site) !void {
    const arena = ctx.arena;
    const label = std.mem.trim(u8, try ctx.field("label"), " ");
    @import("../domain.zig").validateText(label, 80, false) catch return @import("overview.zig").failBack(ctx, site, "Give the link a name.");
    const days = std.fmt.parseInt(i64, try ctx.field("expires"), 10) catch 0;
    const password = try ctx.field("password");
    const dashboard_id: ?i64 = std.fmt.parseInt(i64, try ctx.field("dashboard"), 10) catch null;
    const password_hash: ?[]const u8 = if (password.len != 0) try auth.hashPassword(ctx, password) else null;
    const token = try auth.newToken(ctx.shared.io);
    const hashed = auth.hashToken(&token);
    {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        var statement = try db.prepare(arena, "INSERT INTO share_links(token_hash,site_id,dashboard_id,label,password_hash,expires_at_ms,allow_range,show_details,created_by,created_at_ms) VALUES(?,?,?,?,?,?,?,?,?,?)");
        defer statement.deinit();
        try statement.bindText(1, &hashed);
        try statement.bindInt(2, site.id);
        try statement.bindOptionalInt(3, dashboard_id);
        try statement.bindText(4, label);
        try statement.bindOptionalText(5, password_hash);
        try statement.bindOptionalInt(6, if (days > 0) ctx.now() + days * data.day_ms else null);
        try statement.bindBool(7, (try ctx.field("range")).len != 0);
        try statement.bindBool(8, (try ctx.field("details")).len != 0);
        try statement.bindInt(9, ctx.user.?.id);
        try statement.bindInt(10, ctx.now());
        _ = try statement.step();
        try @import("audit.zig").record(ctx, db, site.id, "share.created", try std.fmt.allocPrint(arena, "Shared “{s}” publicly{s}{s}", .{ label, if (days > 0) try std.fmt.allocPrint(arena, ", expires in {d} days", .{days}) else "", if (password_hash != null) ", with a password" else "" }));
    }
    const origin = (try @import("signin.zig").pinnedOrigin(arena, ctx.db)) orelse try ctx.publicOrigin();
    try ctx.flash(try std.fmt.allocPrint(arena, "Public link ready: {s}/share/{s}", .{ origin, &token }), "Open", try std.fmt.allocPrint(arena, "/share/{s}", .{&token}));
    return ctx.redirect(@import("overview.zig").referer(ctx, site));
}

pub fn revokeLink(ctx: *Ctx, site: data.Site, id: i64) !void {
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    try db.run(ctx.arena, "DELETE FROM share_links WHERE id=? AND site_id=?", .{ id, site.id });
    try @import("audit.zig").record(ctx, db, site.id, "share.revoked", try std.fmt.allocPrint(ctx.arena, "Revoked public link {d}", .{id}));
    return ctx.done("Link revoked. It stops working immediately.", "{s}", .{@import("overview.zig").referer(ctx, site)});
}

/// The share dialog: existing links and a form for a new one.
pub fn dialog(ctx: *Ctx, site: data.Site, dashboard_id: ?i64, label: []const u8) !void {
    const w = ctx.w();
    try render(w, "<dialog class=\"dialog\" id=\"share-dialog\"><form method=\"post\" action=\"/{slug}/shares\"><div class=\"dialog-head\"><div><h2>Share “{label}”</h2><p>For clients, investors or a wall screen — no account needed.</p></div><button class=\"btn btn-quiet btn-icon close\" type=\"button\" data-close aria-label=\"Close\">", .{ .slug = site.slug, .label = label });
    try icon(w, "x");
    try w.writeAll("</button></div><div class=\"dialog-body\">");
    const Existing = struct { id: i64, label: []const u8, expires: ?i64, views: i64 };
    for (try ctx.db.all(ctx.arena, Existing, "SELECT id,label,expires_at_ms,views FROM share_links WHERE site_id=? AND (dashboard_id IS ?2) ORDER BY created_at_ms DESC", .{ site.id, dashboard_id })) |link| try render(w,
        \\<div class="list-row list-row-2"><div><strong>{label}</strong><small>{expires} · opened {views} time{plural}</small></div><button class="btn btn-quiet" type="submit" formaction="/{slug}/shares/{id}/revoke" formnovalidate>Revoke</button></div>
    , .{ .label = link.label, .expires = if (link.expires) |at| try expiryText(ctx.arena, at, ctx.now()) else "Never expires", .views = link.views, .plural = if (link.views == 1) "" else "s", .slug = site.slug, .id = link.id });
    if (dashboard_id) |id| try render(w, "<input type=\"hidden\" name=\"dashboard\" value=\"{id}\">", .{ .id = id });
    try render(w,
        \\<label class="field">Link name<input class="input" name="label" value="{label}" required maxlength="80"></label>
        \\<label class="field">Expires<select class="input" name="expires"><option value="30">In 30 days</option><option value="7">In 7 days</option><option value="90">In 90 days</option><option value="0">Never</option></select></label>
        \\<label class="field">Password (optional)<input class="input" type="password" name="password" autocomplete="new-password" placeholder="Leave empty for no password"></label>
        \\<label class="check"><span class="switch"><input type="checkbox" name="range" value="1" checked></span>Let viewers change the date range</label>
        \\<label class="check"><span class="switch"><input type="checkbox" name="details" value="1"></span>Show page paths and sources</label>
        \\<p class="hint">Off: numbers and charts only. Add <code>?embed=1</code> to the link to embed it in another website.</p>
        \\</div><div class="dialog-foot"><button class="btn" type="button" data-close>Cancel</button><button class="btn btn-primary">Create public link</button></div></form></dialog>
    , .{ .label = label });
}

// ---------------------------------------------------------------- read API

const Key = struct { id: i64, site_id: ?i64 };

fn apiKey(ctx: *Ctx) !?Key {
    const header = ctx.head.authorization;
    if (!std.ascii.startsWithIgnoreCase(header, "bearer ")) return null;
    const value = std.mem.trim(u8, header[7..], " ");
    if (!std.mem.startsWith(u8, value, "an_")) return null;
    const hashed = auth.hashToken(value);
    var statement = try ctx.db.prepare(ctx.arena, "SELECT k.id,k.site_id,u.id,u.email,u.role,u.all_sites FROM api_keys k JOIN users u ON u.id=k.user_id WHERE k.token_hash=?");
    defer statement.deinit();
    try statement.bindText(1, &hashed);
    if (try statement.step() != .row) return null;
    // A key reads with its creator's access, narrowed to its website.
    ctx.user = .{
        .id = statement.columnInt(2),
        .email = try ctx.arena.dupe(u8, statement.columnText(3)),
        .role = std.meta.stringToEnum(ctx_mod.Role, statement.columnText(4)) orelse return null,
        .all_sites = statement.columnBool(5),
    };
    return .{ .id = statement.columnInt(0), .site_id = if (statement.columnType(1) == db_mod.sqlite.SQLITE_NULL) null else statement.columnInt(1) };
}

fn apiError(ctx: *Ctx, status: std.http.Status, code: []const u8) !void {
    ctx.status = status;
    try ctx.w().print("{{\"error\":\"{s}\"}}", .{code});
    return ctx.json();
}

/// Who is calling the read API: an API key (read-only, optionally one
/// website) or a signed-in native app (the sites its sign-in allowed, plus
/// chart notes).
const Caller = union(enum) { key: Key, app: mcp.AppGrant };

fn api(ctx: *Ctx, parts: []const []const u8) !void {
    const arena = ctx.arena;
    const caller: Caller = if (try apiKey(ctx)) |key| .{ .key = key } else if (try mcp.appBearer(ctx)) |grant| .{ .app = grant } else {
        try ctx.header("www-authenticate", "Bearer");
        return apiError(ctx, .unauthorized, "invalid_key");
    };
    if (ctx.method != .GET and caller != .app) return apiError(ctx, .method_not_allowed, "read_only");
    {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        switch (caller) {
            .key => |key| try db.run(arena, "UPDATE api_keys SET last_used_at_ms=? WHERE id=?", .{ ctx.now(), key.id }),
            .app => try db.run(arena, "UPDATE oauth_grants SET last_used_at_ms=? WHERE token_hash=?", .{ ctx.now(), &auth.hashToken(std.mem.trim(u8, ctx.head.authorization[7..], " ")) }),
        }
    }
    var visible: std.ArrayList(data.Site) = .empty;
    for (try ctx.visibleSites()) |site| {
        const allowed = switch (caller) {
            .key => |key| key.site_id == null or key.site_id.? == site.id,
            .app => |grant| mcp.grantAllows(grant.sites, site.id),
        };
        if (allowed) try visible.append(arena, site);
    }
    const w = ctx.w();
    if (parts.len == 1 and is(parts[0], "device")) return switch (caller) {
        .app => |grant| device(ctx, grant.device_id),
        .key => apiError(ctx, .not_found, "unknown_endpoint"),
    };
    if (parts.len == 1 and is(parts[0], "catalog")) {
        try w.writeAll("{\"reports\":[");
        for (catalog.reports, 0..) |report, index| {
            if (index != 0) try w.writeByte(',');
            try w.writeAll("{\"name\":");
            try std.json.Stringify.value(report.name, .{}, w);
            try w.writeAll(",\"title\":");
            try std.json.Stringify.value(report.title, .{}, w);
            try w.writeAll(",\"description\":");
            try std.json.Stringify.value(report.description, .{}, w);
            try w.writeAll(",\"parameters\":");
            try catalog.schema(w, &report, false);
            try w.writeByte('}');
        }
        try w.writeAll("]}");
        return ctx.json();
    }
    if (parts.len == 1 and is(parts[0], "sites")) {
        // Today's visitors come from the daily summaries, so the list is cheap.
        const today = ctx.now() - @mod(ctx.now(), data.day_ms);
        try w.writeAll("{\"sites\":[");
        for (visible.items, 0..) |site, index| {
            if (index != 0) try w.writeByte(',');
            const view = try catalog.view(arena, site, .{}, ctx.now());
            const totals = try data.totals(arena, ctx.db, view, today, today + data.day_ms);
            try std.json.Stringify.value(.{ .slug = site.slug, .name = site.title(), .host = site.host(), .mode = @tagName(site.mode), .currency = site.currency, .today = .{ .visitors = totals.visitor_days, .page_views = totals.views } }, .{}, w);
        }
        try w.writeAll("]}");
        return ctx.json();
    }
    if (parts.len < 3 or !is(parts[0], "sites")) return apiError(ctx, .not_found, "unknown_endpoint");
    var site: ?data.Site = null;
    for (visible.items) |candidate| if (is(candidate.slug, parts[1])) {
        site = candidate;
    };
    const chosen = site orelse return apiError(ctx, .not_found, "unknown_site");
    if (is(parts[2], "notes")) return notes(ctx, chosen, parts[3..]);
    if (parts.len == 3 and is(parts[2], "retention") and ctx.method == .GET) {
        // Remembered visitors exist in Full mode only.
        if (chosen.mode != .full) return apiError(ctx, .conflict, "full_mode_required");
        try std.json.Stringify.value(try customers.retentionData(arena, ctx.shared, ctx.db, chosen.id, ctx.now()), .{}, w);
        return ctx.json();
    }
    if (parts.len == 3 and is(parts[2], "live") and ctx.method == .GET) {
        // The connection is handed to the live broadcaster, as for the workspace.
        ctx.live_site = chosen.id;
        ctx.responded = true;
        return;
    }
    if (parts.len != 3 or ctx.method != .GET) return apiError(ctx, .not_found, "unknown_endpoint");
    // Every report in the catalog, by name.
    const report = catalog.find(parts[2]) orelse return apiError(ctx, .not_found, "unknown_report");
    const table = catalog.run(arena, ctx.db, report, chosen, ctx.query, ctx.now()) catch |err| return apiError(ctx, .bad_request, switch (err) {
        error.MissingParameter => "missing_parameter",
        error.SessionModeRequired => "session_mode_required",
        error.UnsupportedFilter => "unsupported_filter",
        error.InvalidParameter, error.InvalidName, error.InvalidPath, error.InvalidUuid => "invalid_parameter",
        else => return err,
    });
    if (is(ctx.param("format") orelse "json", "csv")) {
        try catalog.render(w, table, .csv);
        return ctx.finish("text/csv; charset=utf-8");
    }
    const range = (try catalog.view(arena, chosen, ctx.query, ctx.now())).range;
    try w.print("{{\"site\":\"{s}\",\"report\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"rows\":", .{ chosen.slug, report.name, &data.dateText(range.start_ms), &data.dateText(range.end_ms - 1) });
    try catalog.render(w, table, .json);
    try w.writeByte('}');
    return ctx.json();
}

/// Chart notes: the period's notes and drafts; apps may add one, keep a
/// draft or remove a note, with the same rules as the workspace forms.
fn notes(ctx: *Ctx, site: data.Site, rest: []const []const u8) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    if (rest.len == 0 and ctx.method == .GET) {
        const range = (try catalog.view(arena, site, ctx.query, ctx.now())).range;
        const Note = struct { id: i64, day: []const u8, label: []const u8, draft: bool };
        const rows = try ctx.db.all(arena, Note, "SELECT id,day,label,draft FROM annotations WHERE site_id=? AND day>=? AND day<=? ORDER BY day,id", .{ site.id, &data.dateText(range.start_ms), &data.dateText(range.end_ms - 1) });
        try std.json.Stringify.value(.{ .notes = rows }, .{}, w);
        return ctx.json();
    }
    if (!ctx.can(.editor)) return apiError(ctx, .forbidden, "editor_role_required");
    if (rest.len == 0 and ctx.method == .POST) {
        const day = try ctx.field("day");
        const label = std.mem.trim(u8, try ctx.field("label"), " ");
        _ = data.parseDate(day) catch return apiError(ctx, .bad_request, "invalid_day");
        @import("../domain.zig").validateText(label, 60, false) catch return apiError(ctx, .bad_request, "invalid_label");
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try db.run(arena, "INSERT INTO annotations(site_id,day,label,created_at_ms) VALUES(?,?,?,?)", .{ site.id, day, label, ctx.now() });
        ctx.status = .created;
        try w.print("{{\"id\":{d}}}", .{db.lastInsertRowId()});
        return ctx.json();
    }
    const id = if (rest.len >= 1) std.fmt.parseInt(i64, rest[0], 10) catch return apiError(ctx, .not_found, "unknown_note") else return apiError(ctx, .not_found, "unknown_endpoint");
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    if (rest.len == 2 and is(rest[1], "keep") and ctx.method == .POST) {
        try db.run(arena, "UPDATE annotations SET draft=0 WHERE id=? AND site_id=?", .{ id, site.id });
    } else if (rest.len == 1 and ctx.method == .DELETE) {
        try db.run(arena, "DELETE FROM annotations WHERE id=? AND site_id=?", .{ id, site.id });
    } else return apiError(ctx, .not_found, "unknown_endpoint");
    if (db.changes() == 0) return apiError(ctx, .not_found, "unknown_note");
    ctx.status = .no_content;
    return ctx.json();
}

/// The app's push registration: its token, the key notifications are
/// encrypted to, and which kinds it wants. Signing out removes it.
fn device(ctx: *Ctx, device_id: []const u8) !void {
    const arena = ctx.arena;
    if (ctx.method == .DELETE) {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try db.run(arena, "DELETE FROM devices WHERE device_id=?", .{device_id});
        ctx.status = .no_content;
        return ctx.json();
    }
    if (ctx.method != .POST) return apiError(ctx, .method_not_allowed, "method_not_allowed");
    const environment = try ctx.field("environment");
    const token = try ctx.field("token");
    const public_key = try ctx.field("public_key");
    const auth_secret = try ctx.field("auth_secret");
    const kinds = try ctx.field("kinds");
    if (!is(try ctx.field("platform"), "apns")) return apiError(ctx, .bad_request, "unknown_platform");
    if (!is(environment, "production") and !is(environment, "development")) return apiError(ctx, .bad_request, "invalid_environment");
    if (token.len == 0 or token.len > 200 or !allHex(token)) return apiError(ctx, .bad_request, "invalid_token");
    if (!push.validKeys(public_key, auth_secret)) return apiError(ctx, .bad_request, "invalid_keys");
    var parts = std.mem.splitScalar(u8, kinds, ',');
    while (parts.next()) |kind| if (kind.len != 0 and std.meta.stringToEnum(push.Kind, kind) == null) return apiError(ctx, .bad_request, "invalid_kinds");
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    try db.run(arena,
        \\INSERT INTO devices(device_id,user_id,platform,environment,token,public_key,auth_secret,kinds,updated_at_ms) VALUES(?,?,'apns',?,?,?,?,?,?)
        \\ON CONFLICT(device_id) DO UPDATE SET environment=excluded.environment,token=excluded.token,public_key=excluded.public_key,auth_secret=excluded.auth_secret,kinds=excluded.kinds,updated_at_ms=excluded.updated_at_ms,last_error=''
    , .{ device_id, ctx.user.?.id, environment, token, public_key, auth_secret, kinds, ctx.now() });
    ctx.status = .no_content;
    return ctx.json();
}

fn allHex(text: []const u8) bool {
    for (text) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn csv(w: *std.Io.Writer, value: []const u8) !void {
    if (std.mem.findAny(u8, value, ",\"\n") == null and !(value.len != 0 and (value[0] == '=' or value[0] == '+' or value[0] == '-' or value[0] == '@'))) return w.writeAll(value);
    try w.writeByte('"');
    if (value.len != 0 and (value[0] == '=' or value[0] == '+' or value[0] == '-' or value[0] == '@')) try w.writeByte('\'');
    for (value) |byte| {
        if (byte == '"') try w.writeByte('"');
        try w.writeByte(byte);
    }
    try w.writeByte('"');
}

/// "Expires 5 Nov", or "Expired 5 Nov" once past.
fn expiryText(arena: std.mem.Allocator, at: i64, now: i64) ![]const u8 {
    const date = data.civil(at);
    return std.fmt.allocPrint(arena, "{s} {d} {s}", .{ if (at > now) "Expires" else "Expired", date.day, data.month_names[date.month - 1] });
}
