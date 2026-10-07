//! Integrations. Each one lists exactly what leaves this server, and nothing
//! is sent until it is connected:
//! - Search Console: Google search queries per page (read only).
//! - Google Analytics 4: a one-time import of daily history (read only).
//! - Google Ads and Meta: daily cost in; purchases from consented visitors
//!   with an ad click ID out (value, currency, time, click ID, order ID).
//! - Slack and webhooks: alert text and goal events, never personal data.
//! - Daily export: yesterday's records as CSV files in the data directory.
//! Network calls happen without the write lock; results are written after.
const std = @import("std");
const net = @import("../net.zig");
const analyze = @import("analyze.zig");
const audit = @import("audit.zig");
const auth = @import("auth.zig");
const ctx_mod = @import("ctx.zig");
const customers = @import("customers.zig");
const data = @import("data.zig");
const db_mod = @import("../db.zig");
const domain = @import("../domain.zig");
const html = @import("html.zig");
const layout = @import("layout.zig");
const ui = @import("ui.zig");
const oidc = @import("oidc.zig");
const overview = @import("overview.zig");
const secret = @import("secret.zig");
const server = @import("../server.zig");

const Ctx = ctx_mod.Ctx;
const Shared = server.Shared;
const esc = html.esc;
const icon = layout.icon;
const render = html.render;

pub const Kind = enum {
    search_console,
    ga4,
    google_ads,
    meta,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .search_console => "Search Console",
            .ga4 => "Google Analytics 4 import",
            .google_ads => "Google Ads",
            .meta => "Meta Ads",
        };
    }

    fn scope(self: Kind) []const u8 {
        return switch (self) {
            .search_console => "https://www.googleapis.com/auth/webmasters.readonly",
            .ga4 => "https://www.googleapis.com/auth/analytics.readonly",
            .google_ads => "https://www.googleapis.com/auth/adwords",
            .meta => "",
        };
    }

    pub fn defaultApi(self: Kind) []const u8 {
        return switch (self) {
            .search_console => "https://searchconsole.googleapis.com",
            .ga4 => "https://analyticsdata.googleapis.com",
            .google_ads => "https://googleads.googleapis.com",
            .meta => "https://graph.facebook.com/v19.0",
        };
    }

    fn sends(self: Kind) []const u8 {
        return switch (self) {
            .search_console => "Receives nothing from Analytico.",
            .ga4 => "One-time read from Google. Nothing sent.",
            .google_ads, .meta => "Sends: order value, currency, time, order ID and the ad click ID — consented visitors only.",
        };
    }

    fn what(self: Kind) []const u8 {
        return switch (self) {
            .search_console => "Google search queries per page, shown under Search.",
            .ga4 => "Daily history: page views, visitors, pages, sources, countries and devices, marked “imported”.",
            .google_ads => "Imports daily cost per campaign; sends purchases back so Ads can optimise.",
            .meta => "Same for Facebook and Instagram, through the Conversions API.",
        };
    }
};

/// Settings of one integration, sealed at rest with the instance key.
pub const Config = struct {
    refresh_token: []const u8 = "",
    access_token: []const u8 = "",
    property: []const u8 = "",
    customer_id: []const u8 = "",
    developer_token: []const u8 = "",
    conversion_action: []const u8 = "",
    pixel_id: []const u8 = "",
    ad_account: []const u8 = "",
    api: []const u8 = "",
    /// GA4 import: next month to fetch (YYYY-MM-01), and the last one.
    cursor: []const u8 = "",
    until: []const u8 = "",
};

pub const Row = struct { kind: Kind, config: Config, state: []const u8, synced_at_ms: ?i64, last_error: []const u8 };

pub fn load(arena: std.mem.Allocator, db: *db_mod.Db, master: [32]u8, site_id: i64, kind: Kind) !?Row {
    var statement = try db.prepare(arena, "SELECT config,state,synced_at_ms,coalesce(last_error,'') FROM integrations WHERE site_id=? AND kind=?");
    defer statement.deinit();
    try statement.bindInt(1, site_id);
    try statement.bindText(2, @tagName(kind));
    if (try statement.step() != .row) return null;
    const json = try secret.open(arena, master, statement.columnText(0));
    var config = try std.json.parseFromSliceLeaky(Config, arena, json, .{ .ignore_unknown_fields = true });
    if (config.api.len == 0) config.api = kind.defaultApi();
    return .{
        .kind = kind,
        .config = config,
        .state = try arena.dupe(u8, statement.columnText(1)),
        .synced_at_ms = if (statement.columnType(2) == db_mod.sqlite.SQLITE_NULL) null else statement.columnInt(2),
        .last_error = try arena.dupe(u8, statement.columnText(3)),
    };
}

pub fn save(arena: std.mem.Allocator, io: std.Io, db: *db_mod.Db, master: [32]u8, site_id: i64, kind: Kind, config: Config, state: []const u8, now_ms: i64) !void {
    var json: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(config, .{}, &json.writer);
    const sealed = try secret.seal(arena, io, master, json.written());
    try db.run(arena, "INSERT INTO integrations(site_id,kind,config,state,created_at_ms) VALUES(?,?,?,?,?) ON CONFLICT(site_id,kind) DO UPDATE SET config=excluded.config,state=excluded.state", .{ site_id, @tagName(kind), sealed, state, now_ms });
}

fn markSynced(arena: std.mem.Allocator, db: *db_mod.Db, site_id: i64, kind: Kind, failure: ?[]const u8, now_ms: i64) !void {
    if (failure) |text| {
        try db.run(arena, "UPDATE integrations SET state='failed',last_error=? WHERE site_id=? AND kind=?", .{ text, site_id, @tagName(kind) });
    } else try db.run(arena, "UPDATE integrations SET state='connected',last_error=NULL,synced_at_ms=? WHERE site_id=? AND kind=?", .{ now_ms, site_id, @tagName(kind) });
}

// ---------------------------------------------------------------- HTTP

pub const Response = struct { status: u16, body: []const u8 };

pub fn fetch(arena: std.mem.Allocator, method: std.http.Method, url: []const u8, body: ?[]const u8, content_type: []const u8, headers: []const std.http.Header) !Response {
    const response = net.send(arena, url, .{ .method = method, .body = body, .content_type = content_type, .headers = headers }) catch return error.IntegrationUnreachable;
    return .{ .status = @backingInt(response.status), .body = response.body };
}

fn jsonObject(arena: std.mem.Allocator, body: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch error.InvalidIntegrationResponse;
}

fn field(object: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    return object.get(key);
}

fn jsonText(value: ?std.json.Value) []const u8 {
    const inner = value orelse return "";
    return if (inner == .string) inner.string else "";
}

fn number(value: ?std.json.Value) f64 {
    const inner = value orelse return 0;
    return switch (inner) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        .string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => 0,
    };
}

/// A fresh Google access token from the stored refresh token.
fn googleAccess(arena: std.mem.Allocator, db: *db_mod.Db, master: [32]u8, config: Config) ![]const u8 {
    const client = try oidc.load(arena, db, master, .google) orelse return error.GoogleNotConfigured;
    const discovery = try oidc.discover(arena, client.issuer);
    var form: std.Io.Writer.Allocating = .init(arena);
    try form.writer.writeAll("grant_type=refresh_token&refresh_token=");
    try net.formPart(&form.writer, config.refresh_token);
    const object = try oidc.tokenRequest(arena, discovery.token_endpoint, client, form.written());
    const token = jsonText(object.get("access_token"));
    if (token.len == 0) return error.GoogleTokenRejected;
    return token;
}

// ---------------------------------------------------------------- Google sign-in for integrations

pub fn route(ctx: *Ctx, parts: []const []const u8) !void {
    if (!ctx.can(.admin)) return @import("app.zig").forbidden(ctx);
    if (parts.len == 2 and std.mem.eql(u8, parts[0], "google") and std.mem.eql(u8, parts[1], "start") and ctx.method == .GET) return googleStart(ctx);
    if (parts.len == 2 and std.mem.eql(u8, parts[0], "google") and std.mem.eql(u8, parts[1], "callback") and ctx.method == .GET) return googleCallback(ctx);
    if (parts.len == 1 and ctx.method == .POST) return post(ctx, parts[0]);
    return layout.message(ctx, .not_found, "Nothing here", "That integration page doesn’t exist.");
}

fn siteParam(ctx: *Ctx, value: []const u8) !?data.Site {
    const site = try ctx.visibleSite(value) orelse return null;
    return site;
}

fn back(ctx: *Ctx, site: data.Site, message: []const u8) !void {
    return ctx.done(message, "/settings/integrations?site={s}", .{site.slug});
}

fn googleStart(ctx: *Ctx) !void {
    const arena = ctx.arena;
    const site = try siteParam(ctx, ctx.param("site") orelse "") orelse return layout.message(ctx, .not_found, "Unknown website", "");
    const kind = std.meta.stringToEnum(Kind, ctx.param("kind") orelse "") orelse return back(ctx, site, "!Unknown integration.");
    if (kind == .meta) return back(ctx, site, "!Meta connects with an access token.");
    const client = try oidc.load(arena, ctx.db, ctx.shared.master_key, .google) orelse
        return back(ctx, site, "!Set up Google under Settings → Sign-in first; integrations use the same Google client.");
    ctx.extendDeadline(30);
    const discovery = oidc.discover(arena, client.issuer) catch return back(ctx, site, "!Google couldn’t be reached.");
    const state = try auth.newToken(ctx.shared.io);
    var verifier_bytes: [32]u8 = undefined;
    try ctx.shared.io.randomSecure(&verifier_bytes);
    var verifier: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&verifier, &verifier_bytes);
    {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        const state_hash = auth.hashToken(&state);
        try db.run(arena, "INSERT INTO auth_challenges(id,purpose,challenge,verifier,user_id,binding,provider,intent,expires_at_ms) VALUES(?,'oidc','',?,?,?,'google',?,?)", .{ &state_hash, &verifier, ctx.user.?.id, site.slug, try std.fmt.allocPrint(arena, "integration:{s}", .{@tagName(kind)}), ctx.now() + 10 * 60_000 });
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&verifier, &digest, .{});
    var challenge: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&challenge, &digest);
    const origin = (try @import("signin.zig").pinnedOrigin(arena, ctx.db)) orelse try ctx.publicOrigin();
    var url: std.Io.Writer.Allocating = .init(arena);
    try url.writer.print("{s}{s}response_type=code&access_type=offline&prompt=consent&scope=", .{ discovery.authorization_endpoint, if (std.mem.findScalar(u8, discovery.authorization_endpoint, '?') == null) "?" else "&" });
    try net.formPart(&url.writer, kind.scope());
    try url.writer.writeAll("&client_id=");
    try net.formPart(&url.writer, client.client_id);
    try url.writer.writeAll("&redirect_uri=");
    try net.formPart(&url.writer, try std.fmt.allocPrint(arena, "{s}/integrations/google/callback", .{origin}));
    try url.writer.print("&state={s}&code_challenge={s}&code_challenge_method=S256", .{ &state, &challenge });
    return ctx.redirect(url.written());
}

fn googleCallback(ctx: *Ctx) !void {
    const arena = ctx.arena;
    const state = ctx.param("state") orelse "";
    if (state.len != 64) return layout.message(ctx, .bad_request, "Connection expired", "Start connecting again from Settings → Integrations.");
    const state_hash = auth.hashToken(state);
    var challenge = try ctx.db.prepare(arena, "SELECT verifier,binding,intent,user_id FROM auth_challenges WHERE id=? AND purpose='oidc' AND expires_at_ms>?");
    defer challenge.deinit();
    try challenge.bindText(1, &state_hash);
    try challenge.bindInt(2, ctx.now());
    if (try challenge.step() != .row or challenge.columnInt(3) != ctx.user.?.id) return layout.message(ctx, .bad_request, "Connection expired", "Start connecting again from Settings → Integrations.");
    const verifier = try arena.dupe(u8, challenge.columnText(0));
    const site = try siteParam(ctx, challenge.columnText(1)) orelse return layout.message(ctx, .not_found, "Unknown website", "");
    const intent = challenge.columnText(2);
    if (!std.mem.startsWith(u8, intent, "integration:")) return layout.message(ctx, .bad_request, "Connection expired", "");
    const kind = std.meta.stringToEnum(Kind, intent["integration:".len..]) orelse return layout.message(ctx, .bad_request, "Connection expired", "");
    {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try db.run(arena, "DELETE FROM auth_challenges WHERE id=?", .{&state_hash});
    }
    if (ctx.param("error") != null) return back(ctx, site, "!Google didn’t grant access.");
    const code = ctx.param("code") orelse return back(ctx, site, "!Google didn’t grant access.");
    const client = try oidc.load(arena, ctx.db, ctx.shared.master_key, .google) orelse return back(ctx, site, "!Google isn’t set up.");
    ctx.extendDeadline(30);
    const discovery = oidc.discover(arena, client.issuer) catch return back(ctx, site, "!Google couldn’t be reached.");
    const origin = (try @import("signin.zig").pinnedOrigin(arena, ctx.db)) orelse try ctx.publicOrigin();
    var form: std.Io.Writer.Allocating = .init(arena);
    try form.writer.writeAll("grant_type=authorization_code&code=");
    try net.formPart(&form.writer, code);
    try form.writer.writeAll("&redirect_uri=");
    try net.formPart(&form.writer, try std.fmt.allocPrint(arena, "{s}/integrations/google/callback", .{origin}));
    try form.writer.writeAll("&code_verifier=");
    try net.formPart(&form.writer, verifier);
    const tokens = oidc.tokenRequest(arena, discovery.token_endpoint, client, form.written()) catch return back(ctx, site, "!Google rejected the connection. Try again.");
    const refresh = jsonText(tokens.get("refresh_token"));
    if (refresh.len == 0) return back(ctx, site, "!Google didn’t return offline access. Remove Analytico under your Google account’s connections and try again.");
    var config: Config = if (try load(arena, ctx.db, ctx.shared.master_key, site.id, kind)) |existing| existing.config else .{};
    config.refresh_token = refresh;
    if (config.property.len == 0 and kind == .search_console) config.property = try std.fmt.allocPrint(arena, "sc-domain:{s}", .{site.host()});
    {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try save(arena, ctx.shared.io, db, ctx.shared.master_key, site.id, kind, config, "pending", ctx.now());
        try audit.record(ctx, db, site.id, "integration.connected", kind.label());
    }
    return back(ctx, site, try std.fmt.allocPrint(arena, "{s} connected. Check the settings below, then sync.", .{kind.label()}));
}

// ---------------------------------------------------------------- settings

pub fn section(ctx: *Ctx, maybe_site: ?data.Site) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    const site = maybe_site orelse return;
    try ui.sectionHead(w, "Integrations", "Each one lists exactly what leaves this server. Nothing is sent until you connect it.", "");
    try w.writeAll("<div class=\"grid grid-2\">");
    for (std.enums.values(Kind)) |kind| {
        const row = try load(arena, ctx.db, ctx.shared.master_key, site.id, kind);
        var status: std.Io.Writer.Allocating = .init(arena);
        if (row) |value| {
            const failed = std.mem.eql(u8, value.state, "failed");
            const pending = std.mem.eql(u8, value.state, "pending");
            try status.writer.print("<span class=\"status-dot {s}\"></span>{s}", .{ if (failed) "bad" else if (pending) "warn" else "good", if (failed) "Failed" else if (pending) "Connected · finish setup" else "Connected" });
            if (value.synced_at_ms) |at| try status.writer.print(" · synced {f}", .{data.ago(at, ctx.now())});
            if (kind == .ga4 and value.config.cursor.len != 0 and value.config.until.len != 0 and std.mem.order(u8, value.config.cursor, value.config.until) == .gt) try status.writer.writeAll(" · import done");
        } else try status.writer.writeAll("<span class=\"status-dot\"></span>Not connected");
        try cardTop(w, @tagName(kind), switch (kind) {
            .search_console => "GS",
            .ga4 => "G4",
            .google_ads => "GA",
            .meta => "M",
        }, kind.label(), status.written(), kind.what(), kind.sends());
        if (row) |value| if (value.last_error.len != 0) try render(w, "<div class=\"callout callout-bad mb-10\"><span>{error}</span></div>", .{ .@"error" = value.last_error });
        try settingsForm(ctx, site, kind, row);
        try w.writeAll("</section>");
    }
    try channelsCard(ctx, site);
    try exportCard(ctx, site);
    try w.writeAll("</div>");
}

/// An integration card's opening: its tile, name, status (HTML), what it
/// does and what it sends (HTML, it may hold code).
fn cardTop(w: *std.Io.Writer, id: []const u8, tile: []const u8, title: []const u8, status: []const u8, what: []const u8, sends: []const u8) !void {
    try render(w,
        \\<section class="card integration" id="{id}"><div class="row nowrap"><span class="icon-tile">{tile}</span><div><strong>{title}</strong><small class="status-line">{!status}</small></div></div><p class="t-13 my-12">{!what}</p><p class="sends">{!sends}</p>
    , .{ .id = id, .tile = tile, .title = title, .status = status, .what = what, .sends = sends });
}

fn input(w: *std.Io.Writer, label: []const u8, name: []const u8, value: []const u8, placeholder: []const u8) !void {
    try render(w, "<label class=\"field\">{label}<input class=\"input mono\" name=\"{name}\" value=\"{value}\" placeholder=\"{placeholder}\"></label>", .{ .label = label, .name = name, .value = value, .placeholder = placeholder });
}

fn settingsForm(ctx: *Ctx, site: data.Site, kind: Kind, row: ?Row) !void {
    const w = ctx.w();
    const config: Config = if (row) |value| value.config else .{ .api = kind.defaultApi() };
    if (row == null and kind != .meta) {
        try render(w, "<a class=\"btn btn-dark\" href=\"/integrations/google/start?site={slug}&amp;kind={kind}\">Connect with Google</a>", .{ .slug = site.slug, .kind = kind });
        return;
    }
    try render(w, "<details class=\"integration-form\"{!open}><summary class=\"btn\">{label}</summary><form method=\"post\" action=\"/integrations/save\" class=\"form-grid mt-12\"><input type=\"hidden\" name=\"site\" value=\"{slug}\"><input type=\"hidden\" name=\"kind\" value=\"{kind}\">", .{ .open = if (row != null and std.mem.eql(u8, row.?.state, "pending")) " open" else "", .label = if (row == null) "Connect" else "Settings", .slug = site.slug, .kind = kind });
    switch (kind) {
        .search_console => try input(w, "Property", "property", config.property, "sc-domain:example.com"),
        .ga4 => try input(w, "Property ID", "property", config.property, "318000000"),
        .google_ads => {
            try input(w, "Customer ID", "customer_id", config.customer_id, "123-456-7890");
            try input(w, "Developer token", "developer_token", if (config.developer_token.len != 0) "••••••••" else "", "From the Ads API center");
            try input(w, "Conversion action (resource name)", "conversion_action", config.conversion_action, "customers/1234567890/conversionActions/987");
        },
        .meta => {
            try input(w, "Pixel ID", "pixel_id", config.pixel_id, "1234567890");
            try input(w, "Ad account ID", "ad_account", config.ad_account, "act_1234567890");
            try input(w, "Access token", "access_token", if (config.access_token.len != 0) "••••••••" else "", "System user token with ads_read, ads_management");
        },
    }
    try render(w, "<details><summary class=\"hint\">Advanced</summary><label class=\"field mt-8\">API endpoint<input class=\"input mono\" name=\"api\" value=\"{api}\"></label></details><div class=\"row\"><button class=\"btn btn-primary\">Save</button>", .{ .api = config.api });
    // Meta connects with a token, so saving and the first sync are one step.
    if (row != null or kind == .meta) try render(w, "<button class=\"btn\" formaction=\"/integrations/sync\">{label}</button>", .{ .label = if (kind == .ga4) "Import history" else "Sync now" });
    if (row != null) try w.writeAll("<button class=\"btn btn-quiet\" formaction=\"/integrations/disconnect\" data-confirm=\"Disconnect? Imported data stays.\">Disconnect</button>");
    try w.writeAll("</div></form></details>");
}

fn channelsCard(ctx: *Ctx, site: data.Site) !void {
    const w = ctx.w();
    try cardTop(w, "channels", "#", "Slack and webhooks", try std.fmt.allocPrint(ctx.arena, "{d} connected", .{try ctx.db.scalar(ctx.arena, i64, "SELECT count(*) FROM channels", .{})}), "Post alerts to a Slack channel; call your URL when a goal is reached or an alert fires.", "Sends: alert text, event name, website, time and value — never personal data. Webhooks are signed (<code>X-Analytico-Signature</code>).");
    const Listed = struct { id: i64, kind: []const u8, name: []const u8, last_error: []const u8 };
    for (try ctx.db.all(ctx.arena, Listed, "SELECT id,kind,name,coalesce(last_error,'') FROM channels ORDER BY id", .{})) |channel| {
        try render(w, "<div class=\"list-row list-row-2\"><div><strong>{name}</strong><small>{kind}{failed}{error}</small></div><form method=\"post\" action=\"/integrations/channel-remove\"><input type=\"hidden\" name=\"site\" value=\"{slug}\"><input type=\"hidden\" name=\"id\" value=\"{id}\"><button class=\"btn btn-quiet btn-icon\" aria-label=\"Remove\">", .{
            .name = channel.name,
            .kind = if (std.mem.eql(u8, channel.kind, "slack")) "Slack" else "Webhook",
            .failed = if (channel.last_error.len != 0) " · failed: " else "",
            .@"error" = channel.last_error,
            .slug = site.slug,
            .id = channel.id,
        });
        try icon(w, "trash");
        try w.writeAll("</button></form></div>");
    }
    try render(w,
        \\<details class="integration-form"><summary class="btn">Add a channel</summary><form method="post" action="/integrations/channel-add" class="form-grid mt-12"><input type="hidden" name="site" value="{slug}">
        \\<div class="option-cards"><label class="option-card"><input type="radio" name="kind" value="slack" checked><strong>Slack</strong><small>Incoming webhook URL</small></label><label class="option-card"><input type="radio" name="kind" value="webhook"><strong>Webhook</strong><small>Your HTTPS endpoint</small></label></div>
        \\<label class="field">Name<input class="input" name="name" required maxlength="60" placeholder="#marketing"></label>
        \\<label class="field">URL<input class="input mono" name="url" type="url" required placeholder="https://hooks.slack.com/services/…"></label>
        \\<button class="btn btn-primary self-start">Add and send a test</button></form></details></section>
    , .{ .slug = site.slug });
}

fn exportCard(ctx: *Ctx, site: data.Site) !void {
    const w = ctx.w();
    const enabled = std.mem.eql(u8, (try data.setting(ctx.arena, ctx.db, .@"export.daily")) orelse "0", "1");
    try cardTop(w, "export", "CSV", "Daily export", if (enabled) "<span class=\"status-dot good\"></span>On" else "<span class=\"status-dot \"></span>Off", "Every night, yesterday’s page views, events and orders as gzip CSV files in <code>exports/</code> next to the database — for BigQuery, Snowflake or a spreadsheet.", "Includes pages, events, orders and consent mode. Never IPs, replays or typed values. Stays on this server.");
    if (try data.setting(ctx.arena, ctx.db, .@"export.last")) |value| try render(w, "<p class=\"hint mb-10\">Last export: {last}</p>", .{ .last = value });
    try render(w, "<form method=\"post\" action=\"/integrations/export\" class=\"row\"><input type=\"hidden\" name=\"site\" value=\"{slug}\"><button class=\"btn\" name=\"daily\" value=\"{daily}\">{label}</button><button class=\"btn btn-quiet\" name=\"now\" value=\"1\">Export yesterday now</button></form></section>", .{ .slug = site.slug, .daily = if (enabled) "0" else "1", .label = if (enabled) "Turn off" else "Turn on" });
}

fn post(ctx: *Ctx, action: []const u8) !void {
    const arena = ctx.arena;
    const site = try siteParam(ctx, try ctx.field("site")) orelse return layout.message(ctx, .not_found, "Unknown website", "");
    if (std.mem.eql(u8, action, "channel-add")) return channelAdd(ctx, site);
    if (std.mem.eql(u8, action, "channel-remove")) {
        const id = std.fmt.parseInt(i64, try ctx.field("id"), 10) catch 0;
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try db.run(arena, "DELETE FROM channels WHERE id=?", .{id});
        try audit.record(ctx, db, null, "channel.removed", try std.fmt.allocPrint(arena, "channel {d}", .{id}));
        return back(ctx, site, "Channel removed.");
    }
    if (std.mem.eql(u8, action, "export")) {
        if ((try ctx.field("now")).len != 0) {
            ctx.extendDeadline(300);
            const files = try exportDay(arena, ctx.shared, ctx.db, ctx.now() - data.day_ms);
            return back(ctx, site, try std.fmt.allocPrint(arena, "Exported {d} files.", .{files}));
        }
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        const on = std.mem.eql(u8, try ctx.field("daily"), "1");
        try data.putSetting(arena, db, .@"export.daily", if (on) "1" else "0");
        try audit.record(ctx, db, null, "export.changed", if (on) "Turned on the daily export" else "Turned off the daily export");
        return back(ctx, site, if (on) "Daily export on." else "Daily export off.");
    }
    const kind = std.meta.stringToEnum(Kind, try ctx.field("kind")) orelse return back(ctx, site, "!Unknown integration.");
    const existing = try load(arena, ctx.db, ctx.shared.master_key, site.id, kind);
    if (std.mem.eql(u8, action, "disconnect")) {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try db.run(arena, "DELETE FROM integrations WHERE site_id=? AND kind=?", .{ site.id, @tagName(kind) });
        try audit.record(ctx, db, site.id, "integration.disconnected", kind.label());
        return back(ctx, site, try std.fmt.allocPrint(arena, "{s} disconnected.", .{kind.label()}));
    }
    var config: Config = if (existing) |value| value.config else .{};
    const api = std.mem.trim(u8, try ctx.field("api"), " /");
    if (api.len != 0) {
        if (!(std.mem.startsWith(u8, api, "https://") or std.mem.startsWith(u8, api, "http://127.0.0.1") or std.mem.startsWith(u8, api, "http://localhost"))) return back(ctx, site, "!API endpoints use https.");
        config.api = api;
    }
    switch (kind) {
        .search_console, .ga4 => {
            const property = std.mem.trim(u8, try ctx.field("property"), " ");
            if (property.len != 0) config.property = property;
        },
        .google_ads => {
            config.customer_id = try digitsOnly(arena, try ctx.field("customer_id"));
            const developer = std.mem.trim(u8, try ctx.field("developer_token"), " ");
            if (developer.len != 0 and !std.mem.startsWith(u8, developer, "•")) config.developer_token = developer;
            config.conversion_action = std.mem.trim(u8, try ctx.field("conversion_action"), " ");
        },
        .meta => {
            config.pixel_id = try digitsOnly(arena, try ctx.field("pixel_id"));
            const account = std.mem.trim(u8, try ctx.field("ad_account"), " ");
            config.ad_account = if (std.mem.startsWith(u8, account, "act_")) account[4..] else account;
            const token = std.mem.trim(u8, try ctx.field("access_token"), " ");
            if (token.len != 0 and !std.mem.startsWith(u8, token, "•")) config.access_token = token;
        },
    }
    {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        try save(arena, ctx.shared.io, db, ctx.shared.master_key, site.id, kind, config, if (existing) |value| (if (std.mem.eql(u8, value.state, "pending")) "connected" else value.state) else "connected", ctx.now());
        try audit.record(ctx, db, site.id, "integration.changed", kind.label());
    }
    if (!std.mem.eql(u8, action, "sync")) return back(ctx, site, try std.fmt.allocPrint(arena, "{s} saved.", .{kind.label()}));
    ctx.extendDeadline(600);
    const result = syncOne(arena, ctx.shared, ctx.db, site, kind, true);
    const write = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    if (result) |summary| {
        try markSynced(arena, write, site.id, kind, null, ctx.now());
        return back(ctx, site, summary);
    } else |err| {
        try markSynced(arena, write, site.id, kind, errorText(err), ctx.now());
        return back(ctx, site, try std.fmt.allocPrint(arena, "!{s}: {s}", .{ kind.label(), errorText(err) }));
    }
}

fn digitsOnly(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (value) |byte| if (std.ascii.isDigit(byte)) try out.append(arena, byte);
    return out.items;
}

fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.GoogleNotConfigured => "Google sign-in isn’t set up (Settings → Sign-in)",
        error.GoogleTokenRejected, error.ProviderRejectedCode => "Google refused the stored access — connect again",
        error.IntegrationUnreachable, error.ProviderUnreachable, error.ProviderDiscoveryFailed => "the service couldn’t be reached",
        error.IntegrationRejected => "the service rejected the request — check the IDs",
        error.IntegrationIncomplete => "settings are incomplete",
        error.InvalidIntegrationResponse => "unexpected response from the service",
        else => @errorName(err),
    };
}

fn channelAdd(ctx: *Ctx, site: data.Site) !void {
    const arena = ctx.arena;
    const kind = try ctx.field("kind");
    if (!std.mem.eql(u8, kind, "slack") and !std.mem.eql(u8, kind, "webhook")) return back(ctx, site, "!Choose Slack or webhook.");
    const name = std.mem.trim(u8, try ctx.field("name"), " ");
    domain.validateText(name, 60, false) catch return back(ctx, site, "!Give the channel a name.");
    const url = std.mem.trim(u8, try ctx.field("url"), " ");
    if (!(std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://127.0.0.1") or std.mem.startsWith(u8, url, "http://localhost")) or url.len > 500) return back(ctx, site, "!Channel URLs use https.");
    var key: [32]u8 = undefined;
    try ctx.shared.io.randomSecure(&key);
    const signing = std.fmt.bytesToHex(key, .lower);
    var json: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{ .url = url, .secret = &signing }, .{}, &json.writer);
    const channel: Channel = .{ .id = 0, .kind = kind, .name = name, .url = url, .secret = &signing };
    ctx.extendDeadline(30);
    const failure: ?[]const u8 = if (send(arena, channel, "Analytico is connected", .{ .kind = "test", .site = site.slug, .text = "Analytico is connected. Alerts and goals will arrive here." })) |_| null else |err| errorText(err);
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    try db.run(arena, "INSERT INTO channels(kind,name,config,created_at_ms,last_error) VALUES(?,?,?,?,?)", .{ kind, name, try secret.seal(arena, ctx.shared.io, ctx.shared.master_key, json.written()), ctx.now(), if (failure) |value| value else "" });
    try audit.record(ctx, db, null, "channel.added", try std.fmt.allocPrint(arena, "{s} “{s}”", .{ kind, name }));
    if (kind[0] == 'w') return back(ctx, site, try std.fmt.allocPrint(arena, "Webhook added. Signing secret (shown once): {s}", .{&signing}));
    return back(ctx, site, if (failure == null) "Slack connected — a test message was posted." else "!The test message failed; check the URL.");
}

// ---------------------------------------------------------------- channels

pub const Channel = struct { id: i64, kind: []const u8, name: []const u8, url: []const u8, secret: []const u8 };

pub const Notice = struct { kind: []const u8, site: []const u8, text: []const u8, event: []const u8 = "", value_minor: ?i64 = null, currency: []const u8 = "", at_ms: i64 = 0 };

pub fn channels(arena: std.mem.Allocator, db: *db_mod.Db, master: [32]u8) ![]Channel {
    var statement = try db.prepare(arena, "SELECT id,kind,name,config FROM channels ORDER BY id");
    defer statement.deinit();
    var out: std.ArrayList(Channel) = .empty;
    while (try statement.step() == .row) {
        const json = try secret.open(arena, master, statement.columnText(3));
        const config = try std.json.parseFromSliceLeaky(struct { url: []const u8, secret: []const u8 }, arena, json, .{});
        try out.append(arena, .{ .id = statement.columnInt(0), .kind = try arena.dupe(u8, statement.columnText(1)), .name = try arena.dupe(u8, statement.columnText(2)), .url = config.url, .secret = config.secret });
    }
    return out.items;
}

/// Slack gets text; webhooks get JSON signed like `/i`:
/// hex HMAC-SHA256 of `timestamp + "." + body` with the channel's secret.
pub fn send(arena: std.mem.Allocator, channel: Channel, slack_text: []const u8, notice: Notice) !void {
    var body: std.Io.Writer.Allocating = .init(arena);
    if (std.mem.eql(u8, channel.kind, "slack")) {
        try std.json.Stringify.value(.{ .text = slack_text }, .{}, &body.writer);
        const response = try fetch(arena, .POST, channel.url, body.written(), "application/json", &.{});
        if (response.status >= 300) return error.IntegrationRejected;
        return;
    }
    try std.json.Stringify.value(notice, .{}, &body.writer);
    const timestamp = try std.fmt.allocPrint(arena, "{d}", .{@divFloor(domain.nowMs(), 1000)});
    var key: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&key, channel.secret) catch return error.IntegrationIncomplete;
    var mac: [32]u8 = undefined;
    var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(&key);
    hmac.update(timestamp);
    hmac.update(".");
    hmac.update(body.written());
    hmac.final(&mac);
    const signature = std.fmt.bytesToHex(mac, .lower);
    const response = try fetch(arena, .POST, channel.url, body.written(), "application/json", &.{ .{ .name = "x-analytico-timestamp", .value = timestamp }, .{ .name = "x-analytico-signature", .value = &signature } });
    if (response.status >= 300) return error.IntegrationRejected;
}

/// Delivers to every channel; failures are recorded per channel.
pub fn broadcast(arena: std.mem.Allocator, shared: *Shared, db: *db_mod.Db, slack_text: []const u8, notice: Notice, goals_only_webhooks: bool) !void {
    for (try channels(arena, db, shared.master_key)) |channel| {
        if (goals_only_webhooks and std.mem.eql(u8, channel.kind, "slack")) continue;
        const failure: ?[]const u8 = if (send(arena, channel, slack_text, notice)) |_| null else |err| errorText(err);
        const write = shared.lockWrite();
        defer shared.unlockWrite();
        try write.run(arena, "UPDATE channels SET last_sent_at_ms=?,last_error=? WHERE id=?", .{ notice.at_ms, if (failure) |value| value else "", channel.id });
    }
}

/// Goal events since the last delivery go to webhooks, oldest first.
pub fn deliverGoals(arena: std.mem.Allocator, shared: *Shared, db: *db_mod.Db, now_ms: i64) !void {
    if (try db.scalar(arena, i64, "SELECT count(*) FROM channels WHERE kind='webhook'", .{}) == 0) return;
    const cursor = std.fmt.parseInt(i64, (try data.setting(arena, db, .@"webhooks.cursor")) orelse "0", 10) catch 0;
    const since = if (cursor == 0) now_ms - 60_000 else cursor;
    var statement = try db.prepare(arena,
        \\SELECT s.slug,e.name,e.value_minor,coalesce(e.currency,''),e.received_at_ms,g.name FROM events e JOIN goals g ON g.site_id=e.site_id AND g.kind='event' AND g.match_value=e.name
        \\JOIN sites s ON s.id=e.site_id WHERE e.received_at_ms>? AND e.internal=0 ORDER BY e.received_at_ms LIMIT 200
    );
    defer statement.deinit();
    try statement.bindInt(1, since);
    var latest = since;
    const Item = struct { site: []const u8, event: []const u8, value: ?i64, currency: []const u8, at: i64, goal: []const u8 };
    var items: std.ArrayList(Item) = .empty;
    while (try statement.step() == .row) {
        try items.append(arena, .{ .site = try arena.dupe(u8, statement.columnText(0)), .event = try arena.dupe(u8, statement.columnText(1)), .value = if (statement.columnType(2) == db_mod.sqlite.SQLITE_NULL) null else statement.columnInt(2), .currency = try arena.dupe(u8, statement.columnText(3)), .at = statement.columnInt(4), .goal = try arena.dupe(u8, statement.columnText(5)) });
    }
    for (items.items) |item| {
        latest = @max(latest, item.at);
        try broadcast(arena, shared, db, "", .{ .kind = "goal", .site = item.site, .text = try std.fmt.allocPrint(arena, "Goal reached: {s}", .{item.goal}), .event = item.event, .value_minor = item.value, .currency = item.currency, .at_ms = item.at }, true);
    }
    const write = shared.lockWrite();
    defer shared.unlockWrite();
    try data.putSetting(arena, write, .@"webhooks.cursor", try std.fmt.allocPrint(arena, "{d}", .{if (items.items.len == 0) @max(since, now_ms - 60_000) else latest}));
}

// ---------------------------------------------------------------- syncs

/// Runs one integration once. `full` imports all pending GA4 months at once
/// (the button); the nightly job takes one month per run.
pub fn syncOne(arena: std.mem.Allocator, shared: *Shared, db: *db_mod.Db, site: data.Site, kind: Kind, full: bool) ![]const u8 {
    const row = try load(arena, db, shared.master_key, site.id, kind) orelse return error.IntegrationIncomplete;
    return switch (kind) {
        .search_console => syncSearchConsole(arena, shared, db, site, row.config),
        .ga4 => importGa4(arena, shared, db, site, row.config, full),
        .google_ads => syncGoogleAds(arena, shared, db, site, row.config),
        .meta => syncMeta(arena, shared, db, site, row.config),
    };
}

fn syncSearchConsole(arena: std.mem.Allocator, shared: *Shared, db: *db_mod.Db, site: data.Site, config: Config) ![]const u8 {
    if (config.property.len == 0 or config.refresh_token.len == 0) return error.IntegrationIncomplete;
    const token = try googleAccess(arena, db, shared.master_key, config);
    const now = domain.nowMs();
    const start = data.dateText(now - 30 * data.day_ms);
    const end = data.dateText(now - data.day_ms);
    var url: std.Io.Writer.Allocating = .init(arena);
    try url.writer.print("{s}/webmasters/v3/sites/", .{config.api});
    try net.formPart(&url.writer, config.property);
    try url.writer.writeAll("/searchAnalytics/query");
    var body: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{ .startDate = &start, .endDate = &end, .dimensions = &[_][]const u8{ "date", "query", "page" }, .rowLimit = 25000 }, .{}, &body.writer);
    const response = try fetch(arena, .POST, url.written(), body.written(), "application/json", &.{.{ .name = "authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{token}) }});
    if (response.status != 200) return error.IntegrationRejected;
    const parsed = try jsonObject(arena, response.body);
    const rows = if (parsed == .object) (if (parsed.object.get("rows")) |value| if (value == .array) value.array.items else &.{} else &.{}) else &.{};
    const write = shared.lockWrite();
    defer shared.unlockWrite();
    try write.exec("BEGIN IMMEDIATE");
    errdefer write.exec("ROLLBACK") catch {};
    var stored: usize = 0;
    for (rows) |item| {
        if (item != .object) continue;
        const keys = item.object.get("keys") orelse continue;
        if (keys != .array or keys.array.items.len != 3) continue;
        const day = jsonText(keys.array.items[0]);
        const query = jsonText(keys.array.items[1]);
        const page_url = jsonText(keys.array.items[2]);
        if (day.len != 10 or query.len == 0 or query.len > 200) continue;
        // Pages are kept as paths, like everywhere else.
        const path = pathOf(page_url);
        try write.run(arena, "INSERT INTO search_queries(site_id,day,query,page,clicks,impressions,position_x10) VALUES(?,?,?,?,?,?,?) ON CONFLICT(site_id,day,query,page) DO UPDATE SET clicks=excluded.clicks,impressions=excluded.impressions,position_x10=excluded.position_x10", .{ site.id, day, query, path, @as(i64, @intFromFloat(number(item.object.get("clicks")))), @as(i64, @intFromFloat(number(item.object.get("impressions")))), @as(i64, @intFromFloat(number(item.object.get("position")) * 10)) });
        stored += 1;
    }
    try write.exec("COMMIT");
    return std.fmt.allocPrint(arena, "Search Console synced: {d} query rows.", .{stored});
}

fn pathOf(url: []const u8) []const u8 {
    const scheme = std.mem.find(u8, url, "://") orelse return if (url.len != 0 and url[0] == '/') url else "/";
    const slash = std.mem.findScalarPos(u8, url, scheme + 3, '/') orelse return "/";
    const end = std.mem.findAny(u8, url[slash..], "?#") orelse url.len - slash;
    return url[slash .. slash + end];
}

/// GA4 history, one month per call (all pending months with `full`), from up
/// to two years back until the day before Analytico's first page view.
fn importGa4(arena: std.mem.Allocator, shared: *Shared, db: *db_mod.Db, site: data.Site, start_config: Config, full: bool) ![]const u8 {
    var config = start_config;
    if (config.property.len == 0 or config.refresh_token.len == 0) return error.IntegrationIncomplete;
    const now = domain.nowMs();
    if (config.until.len == 0) {
        const first = try db.scalar(arena, i64, "SELECT coalesce(min(received_at_ms),0) FROM page_views WHERE site_id=?", .{site.id});
        config.until = try arena.dupe(u8, &data.dateText((if (first == 0) now else first) - data.day_ms));
        const two_years = data.civil(now - 730 * data.day_ms);
        config.cursor = try std.fmt.allocPrint(arena, "{d}-{d:0>2}-01", .{ two_years.year, two_years.month });
    }
    const token = try googleAccess(arena, db, shared.master_key, config);
    var months: usize = 0;
    var rows_stored: usize = 0;
    while (std.mem.order(u8, config.cursor, config.until) != .gt) {
        const month_start = try data.parseDate(config.cursor);
        const civil = data.civil(month_start);
        const next_month = if (civil.month == 12) try std.fmt.allocPrint(arena, "{d}-01-01", .{civil.year + 1}) else try std.fmt.allocPrint(arena, "{d}-{d:0>2}-01", .{ civil.year, civil.month + 1 });
        const month_end_ms = @min(try data.parseDate(next_month) - data.day_ms, try data.parseDate(config.until));
        const end_text = data.dateText(month_end_ms);
        const dims = [_][2][]const u8{ .{ "total", "" }, .{ "page", "pagePath" }, .{ "source", "sessionSource" }, .{ "country", "countryId" }, .{ "device", "deviceCategory" } };
        var batch: std.ArrayList([5][]const u8) = .empty;
        for (dims) |dim| {
            var body: std.Io.Writer.Allocating = .init(arena);
            try body.writer.print("{{\"dateRanges\":[{{\"startDate\":\"{s}\",\"endDate\":\"{s}\"}}],\"dimensions\":[{{\"name\":\"date\"}}{s}{s}{s}],\"metrics\":[{{\"name\":\"screenPageViews\"}},{{\"name\":\"totalUsers\"}}],\"limit\":100000}}", .{ config.cursor, &end_text, if (dim[1].len != 0) ",{\"name\":\"" else "", dim[1], if (dim[1].len != 0) "\"}" else "" });
            const url = try std.fmt.allocPrint(arena, "{s}/v1beta/properties/{s}:runReport", .{ config.api, config.property });
            const response = try fetch(arena, .POST, url, body.written(), "application/json", &.{.{ .name = "authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{token}) }});
            if (response.status != 200) return error.IntegrationRejected;
            const parsed = try jsonObject(arena, response.body);
            const rows = if (parsed == .object) (if (parsed.object.get("rows")) |value| if (value == .array) value.array.items else &.{} else &.{}) else &.{};
            for (rows) |row| {
                if (row != .object) continue;
                const dimension_values = row.object.get("dimensionValues") orelse continue;
                const metric_values = row.object.get("metricValues") orelse continue;
                if (dimension_values != .array or metric_values != .array or metric_values.array.items.len < 2) continue;
                const raw_day = if (dimension_values.array.items[0] == .object) jsonText(dimension_values.array.items[0].object.get("value")) else "";
                if (raw_day.len != 8) continue;
                const key = if (dim[1].len == 0) "" else if (dimension_values.array.items.len > 1 and dimension_values.array.items[1] == .object) jsonText(dimension_values.array.items[1].object.get("value")) else "";
                if (key.len > 512) continue;
                const views = if (metric_values.array.items[0] == .object) jsonText(metric_values.array.items[0].object.get("value")) else "0";
                const users = if (metric_values.array.items[1] == .object) jsonText(metric_values.array.items[1].object.get("value")) else "0";
                try batch.append(arena, .{ try std.fmt.allocPrint(arena, "{s}-{s}-{s}", .{ raw_day[0..4], raw_day[4..6], raw_day[6..8] }), dim[0], if (std.mem.eql(u8, dim[0], "source") and std.mem.eql(u8, key, "(direct)")) "direct" else try std.ascii.allocLowerString(arena, key), views, users });
            }
        }
        {
            const write = shared.lockWrite();
            defer shared.unlockWrite();
            try write.exec("BEGIN IMMEDIATE");
            errdefer write.exec("ROLLBACK") catch {};
            for (batch.items) |item| {
                // Country codes stay uppercase; paths keep their case.
                const key = if (std.mem.eql(u8, item[1], "country")) try std.ascii.allocUpperString(arena, item[2]) else item[2];
                try write.run(arena, "INSERT INTO imported_daily(site_id,day,dim,key,views,visitors) VALUES(?,?,?,?,?,?) ON CONFLICT(site_id,day,dim,key) DO UPDATE SET views=excluded.views,visitors=excluded.visitors", .{ site.id, item[0], item[1], key, std.fmt.parseInt(i64, item[3], 10) catch 0, std.fmt.parseInt(i64, item[4], 10) catch 0 });
            }
            config.cursor = next_month;
            try save(arena, shared.io, write, shared.master_key, site.id, .ga4, config, "connected", now);
            try write.exec("COMMIT");
        }
        rows_stored += batch.items.len;
        months += 1;
        if (!full) break;
    }
    return std.fmt.allocPrint(arena, "Google Analytics import: {d} month{s}, {d} rows.", .{ months, if (months == 1) "" else "s", rows_stored });
}

const Conversion = struct { event_id: []const u8, value: i64, currency: []const u8, at_ms: i64, order: []const u8, click: []const u8 };

/// Orders in the last 30 days from visits with an ad click ID of `prefix`
/// that weren't uploaded to `destination` yet.
fn pendingConversions(arena: std.mem.Allocator, db: *db_mod.Db, site: data.Site, prefix: []const u8, destination: []const u8) ![]Conversion {
    const now = domain.nowMs();
    const view = try data.View.parse(arena, site, .{}, now);
    var sql = data.Sql.init(arena);
    try customers.ordersCte(&sql, view, now - 30 * data.day_ms, now + 1);
    try sql.add(" SELECT o.event_id,o.v,o.c,o.t,o.k,(SELECT pv.click_id FROM page_views pv WHERE pv.site_id=");
    try sql.int(site.id);
    try sql.add(" AND pv.click_id LIKE ");
    try sql.str(try std.fmt.allocPrint(arena, "{s}:%", .{prefix}));
    try sql.add(" AND ((o.session_id IS NOT NULL AND pv.session_id=o.session_id) OR pv.page_id=o.page_id) ORDER BY pv.occurred_at_ms LIMIT 1) cid FROM o WHERE cid IS NOT NULL AND NOT EXISTS(SELECT 1 FROM conversion_uploads u WHERE u.site_id=");
    try sql.int(site.id);
    try sql.add(" AND u.event_id=o.event_id AND u.destination=");
    try sql.str(destination);
    try sql.add(") LIMIT 200");
    var statement = try sql.prepare(db);
    defer statement.deinit();
    var out: std.ArrayList(Conversion) = .empty;
    while (try statement.step() == .row) {
        const click = statement.columnText(5);
        try out.append(arena, .{ .event_id = try arena.dupe(u8, statement.columnText(0)), .value = statement.columnInt(1), .currency = try arena.dupe(u8, statement.columnText(2)), .at_ms = statement.columnInt(3), .order = try arena.dupe(u8, statement.columnText(4)), .click = try arena.dupe(u8, click[(std.mem.findScalar(u8, click, ':') orelse 0) + 1 ..]) });
    }
    return out.items;
}

fn recordUploads(arena: std.mem.Allocator, shared: *Shared, site: data.Site, conversions: []const Conversion, destination: []const u8, ok: bool) !void {
    const write = shared.lockWrite();
    defer shared.unlockWrite();
    const now = domain.nowMs();
    for (conversions) |conversion| try write.run(arena, "INSERT INTO conversion_uploads(site_id,event_id,destination,uploaded_at_ms,state) VALUES(?,?,?,?,?) ON CONFLICT DO UPDATE SET state=excluded.state,uploaded_at_ms=excluded.uploaded_at_ms", .{ site.id, conversion.event_id, destination, now, if (ok) "sent" else "failed" });
}

fn upsertSpend(arena: std.mem.Allocator, write: *db_mod.Db, site: data.Site, day: []const u8, source: []const u8, campaign: []const u8, amount: i64, currency: []const u8, now: i64) !void {
    try write.run(arena, "INSERT INTO campaign_spend(site_id,spend_date,source,campaign,content,amount_minor,currency,created_at_ms) VALUES(?,?,?,?,'',?,?,?) ON CONFLICT(site_id,spend_date,source,campaign,content,currency) DO UPDATE SET amount_minor=excluded.amount_minor", .{ site.id, day, source, campaign, amount, currency, now });
}

fn syncGoogleAds(arena: std.mem.Allocator, shared: *Shared, db: *db_mod.Db, site: data.Site, config: Config) ![]const u8 {
    if (config.customer_id.len == 0 or config.developer_token.len == 0 or config.refresh_token.len == 0) return error.IntegrationIncomplete;
    const token = try googleAccess(arena, db, shared.master_key, config);
    const headers = [_]std.http.Header{ .{ .name = "authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{token}) }, .{ .name = "developer-token", .value = config.developer_token } };
    // Cost in.
    const query = "{\"query\":\"SELECT segments.date, campaign.name, metrics.cost_micros, customer.currency_code FROM campaign WHERE segments.date DURING LAST_30_DAYS\"}";
    const cost = try fetch(arena, .POST, try std.fmt.allocPrint(arena, "{s}/v17/customers/{s}/googleAds:searchStream", .{ config.api, config.customer_id }), query, "application/json", &headers);
    if (cost.status != 200) return error.IntegrationRejected;
    const parsed = try jsonObject(arena, cost.body);
    var days: usize = 0;
    {
        const write = shared.lockWrite();
        defer shared.unlockWrite();
        try write.exec("BEGIN IMMEDIATE");
        errdefer write.exec("ROLLBACK") catch {};
        const batches = if (parsed == .array) parsed.array.items else &.{};
        for (batches) |batch| {
            if (batch != .object) continue;
            const results = batch.object.get("results") orelse continue;
            if (results != .array) continue;
            for (results.array.items) |result| {
                if (result != .object) continue;
                const segments = result.object.get("segments") orelse continue;
                const campaign = result.object.get("campaign") orelse continue;
                const metrics = result.object.get("metrics") orelse continue;
                const customer = result.object.get("customer");
                if (segments != .object or campaign != .object or metrics != .object) continue;
                const day = jsonText(segments.object.get("date"));
                const name = jsonText(campaign.object.get("name"));
                if (day.len != 10 or name.len == 0) continue;
                const currency = if (customer) |value| (if (value == .object) jsonText(value.object.get("currencyCode")) else "") else "";
                try upsertSpend(arena, write, site, day, "google", name, @intFromFloat(number(metrics.object.get("costMicros")) / 10_000), if (currency.len == 3) currency else site.currency, domain.nowMs());
                days += 1;
            }
        }
        try write.exec("COMMIT");
    }
    // Conversions out.
    var sent: usize = 0;
    if (config.conversion_action.len != 0) {
        const conversions = try pendingConversions(arena, db, site, "gclid", "google_ads");
        if (conversions.len != 0) {
            var body: std.Io.Writer.Allocating = .init(arena);
            try body.writer.writeAll("{\"conversions\":[");
            for (conversions, 0..) |conversion, index| {
                if (index != 0) try body.writer.writeByte(',');
                const seconds = @divFloor(conversion.at_ms, 1000);
                const date = data.dateText(conversion.at_ms);
                const clock = @mod(seconds, 86400);
                try body.writer.writeAll("{\"gclid\":");
                try std.json.Stringify.value(conversion.click, .{}, &body.writer);
                try body.writer.writeAll(",\"conversionAction\":");
                try std.json.Stringify.value(config.conversion_action, .{}, &body.writer);
                try body.writer.print(",\"conversionDateTime\":\"{s} {d:0>2}:{d:0>2}:{d:0>2}+00:00\",\"conversionValue\":{d:.2},\"currencyCode\":\"{s}\",\"orderId\":", .{ &date, @as(u64, @intCast(@divFloor(clock, 3600))), @as(u64, @intCast(@mod(@divFloor(clock, 60), 60))), @as(u64, @intCast(@mod(clock, 60))), @as(f64, @floatFromInt(conversion.value)) / 100, conversion.currency });
                try std.json.Stringify.value(conversion.order, .{}, &body.writer);
                try body.writer.writeByte('}');
            }
            try body.writer.writeAll("],\"partialFailure\":true}");
            const upload = try fetch(arena, .POST, try std.fmt.allocPrint(arena, "{s}/v17/customers/{s}:uploadClickConversions", .{ config.api, config.customer_id }), body.written(), "application/json", &headers);
            try recordUploads(arena, shared, site, conversions, "google_ads", upload.status == 200);
            if (upload.status != 200) return error.IntegrationRejected;
            sent = conversions.len;
        }
    }
    return std.fmt.allocPrint(arena, "Google Ads synced: {d} cost rows in, {d} conversion{s} out.", .{ days, sent, if (sent == 1) "" else "s" });
}

fn syncMeta(arena: std.mem.Allocator, shared: *Shared, db: *db_mod.Db, site: data.Site, config: Config) ![]const u8 {
    if (config.access_token.len == 0) return error.IntegrationIncomplete;
    var days: usize = 0;
    if (config.ad_account.len != 0) {
        var url: std.Io.Writer.Allocating = .init(arena);
        try url.writer.print("{s}/act_{s}/insights?level=campaign&time_increment=1&fields=campaign_name,spend,account_currency&date_preset=last_30d&access_token=", .{ config.api, config.ad_account });
        try net.formPart(&url.writer, config.access_token);
        const cost = try fetch(arena, .GET, url.written(), null, "", &.{});
        if (cost.status != 200) return error.IntegrationRejected;
        const parsed = try jsonObject(arena, cost.body);
        const rows = if (parsed == .object) (if (parsed.object.get("data")) |value| if (value == .array) value.array.items else &.{} else &.{}) else &.{};
        const write = shared.lockWrite();
        defer shared.unlockWrite();
        try write.exec("BEGIN IMMEDIATE");
        errdefer write.exec("ROLLBACK") catch {};
        for (rows) |row| {
            if (row != .object) continue;
            const day = jsonText(row.object.get("date_start"));
            const name = jsonText(row.object.get("campaign_name"));
            if (day.len != 10 or name.len == 0) continue;
            const currency = jsonText(row.object.get("account_currency"));
            try upsertSpend(arena, write, site, day, "meta", name, @intFromFloat(number(row.object.get("spend")) * 100), if (currency.len == 3) currency else site.currency, domain.nowMs());
            days += 1;
        }
        try write.exec("COMMIT");
    }
    var sent: usize = 0;
    if (config.pixel_id.len != 0) {
        const conversions = try pendingConversions(arena, db, site, "fbclid", "meta");
        if (conversions.len != 0) {
            var body: std.Io.Writer.Allocating = .init(arena);
            try body.writer.writeAll("{\"data\":[");
            for (conversions, 0..) |conversion, index| {
                if (index != 0) try body.writer.writeByte(',');
                // Only the click ID identifies the visit: no email, phone or IP.
                try body.writer.print("{{\"event_name\":\"Purchase\",\"event_time\":{d},\"action_source\":\"website\",\"event_id\":", .{@divFloor(conversion.at_ms, 1000)});
                try std.json.Stringify.value(conversion.order, .{}, &body.writer);
                try body.writer.print(",\"user_data\":{{\"fbc\":\"fb.1.{d}.", .{conversion.at_ms});
                try body.writer.writeAll(conversion.click);
                try body.writer.print("\"}},\"custom_data\":{{\"value\":{d:.2},\"currency\":\"{s}\"}}}}", .{ @as(f64, @floatFromInt(conversion.value)) / 100, conversion.currency });
            }
            try body.writer.writeAll("]}");
            var url: std.Io.Writer.Allocating = .init(arena);
            try url.writer.print("{s}/{s}/events?access_token=", .{ config.api, config.pixel_id });
            try net.formPart(&url.writer, config.access_token);
            const upload = try fetch(arena, .POST, url.written(), body.written(), "application/json", &.{});
            try recordUploads(arena, shared, site, conversions, "meta", upload.status == 200);
            if (upload.status != 200) return error.IntegrationRejected;
            sent = conversions.len;
        }
    }
    return std.fmt.allocPrint(arena, "Meta synced: {d} cost rows in, {d} conversion{s} out.", .{ days, sent, if (sent == 1) "" else "s" });
}

/// Nightly: every connected integration of every website, once a day.
pub fn nightly(arena: std.mem.Allocator, shared: *Shared, db: *db_mod.Db) !void {
    const now = domain.nowMs();
    var statement = try db.prepare(arena, "SELECT site_id,kind FROM integrations WHERE state<>'pending' AND coalesce(synced_at_ms,0)<?");
    defer statement.deinit();
    try statement.bindInt(1, now - 20 * data.hour_ms);
    const Due = struct { site_id: i64, kind: Kind };
    var due: std.ArrayList(Due) = .empty;
    while (try statement.step() == .row) {
        const kind = std.meta.stringToEnum(Kind, statement.columnText(1)) orelse continue;
        try due.append(arena, .{ .site_id = statement.columnInt(0), .kind = kind });
    }
    const sites = try data.sites(arena, db);
    for (due.items) |item| {
        for (sites) |site| if (site.id == item.site_id) {
            const result = syncOne(arena, shared, db, site, item.kind, false);
            const write = shared.lockWrite();
            defer shared.unlockWrite();
            if (result) |summary| {
                std.log.info("integration_synced site={s} kind={s} {s}", .{ site.slug, @tagName(item.kind), summary });
                try markSynced(arena, write, site.id, item.kind, null, now);
            } else |err| {
                std.log.warn("integration_failed site={s} kind={s} code={s}", .{ site.slug, @tagName(item.kind), @errorName(err) });
                try markSynced(arena, write, site.id, item.kind, errorText(err), now);
            }
        };
    }
}

// ---------------------------------------------------------------- daily export

/// Writes the day's page views, events and orders for every website as gzip
/// CSV files under `<data>/exports/<site>/<day>/`. Returns the file count.
pub fn exportDay(arena: std.mem.Allocator, shared: *Shared, db: *db_mod.Db, day_ms: i64) !usize {
    const day_start = day_ms - @mod(day_ms, data.day_ms);
    const day = data.dateText(day_start);
    const tables = [_][2][]const u8{
        .{ "page_views", "SELECT received_at_ms,page_id,session_id,visitor_id,path,referrer_host,utm_source,utm_medium,utm_campaign,utm_content,utm_term,country,region,city,browser,operating_system,device,viewport_class,language,consent_mode,tracking_mode,traffic_class,search_term FROM page_views WHERE site_id=?1 AND received_at_ms>=?2 AND received_at_ms<?3 AND internal=0 ORDER BY received_at_ms" },
        .{ "events", "SELECT received_at_ms,event_id,page_id,session_id,visitor_id,source,name,path,value_minor,currency,order_id,properties_json,consent_mode FROM events WHERE site_id=?1 AND received_at_ms>=?2 AND received_at_ms<?3 AND internal=0 ORDER BY received_at_ms" },
        .{ "order_items", "SELECT e.received_at_ms,e.event_id,e.order_id,e.name,i.item_id,i.name,i.category,i.price_minor,i.quantity FROM event_items i JOIN events e ON e.site_id=i.site_id AND e.event_id=i.event_id WHERE i.site_id=?1 AND e.received_at_ms>=?2 AND e.received_at_ms<?3 ORDER BY e.received_at_ms" },
    };
    var files: usize = 0;
    for (try data.sites(arena, db)) |site| {
        const directory = try std.fs.path.join(arena, &.{ shared.data, "exports", site.slug, &day });
        try std.Io.Dir.cwd().createDirPath(shared.io, directory);
        for (tables) |table| {
            const path = try std.fmt.allocPrint(arena, "{s}/{s}.csv.gz", .{ directory, table[0] });
            const file = try std.Io.Dir.cwd().createFile(shared.io, path, .{ .truncate = true, .permissions = @fromBackingInt(@intCast(0o600)) });
            defer file.close(shared.io);
            const file_buffer = try arena.alloc(u8, 64 * 1024);
            var file_writer = file.writer(shared.io, file_buffer);
            const window = try arena.alloc(u8, std.compress.flate.max_window_len);
            var gzip = try std.compress.flate.Compress.init(&file_writer.interface, window, .gzip, .default);
            const w = &gzip.writer;
            var statement = try db.prepare(arena, table[1]);
            defer statement.deinit();
            try statement.bindInt(1, site.id);
            try statement.bindInt(2, day_start);
            try statement.bindInt(3, day_start + data.day_ms);
            for (0..statement.columnCount()) |index| {
                if (index != 0) try w.writeByte(',');
                try w.writeAll(statement.columnName(index));
            }
            try w.writeByte('\n');
            while (try statement.step() == .row) {
                for (0..statement.columnCount()) |index| {
                    if (index != 0) try w.writeByte(',');
                    if (statement.columnType(index) == db_mod.sqlite.SQLITE_NULL) continue;
                    try csvField(w, statement.columnText(index));
                }
                try w.writeByte('\n');
            }
            try gzip.finish();
            try file_writer.interface.flush();
            files += 1;
        }
    }
    const write = shared.lockWrite();
    defer shared.unlockWrite();
    try data.putSetting(arena, write, .@"export.last", try std.fmt.allocPrint(arena, "{s} · {d} files", .{ &day, files }));
    return files;
}

fn csvField(w: *std.Io.Writer, value: []const u8) !void {
    if (std.mem.findAny(u8, value, ",\"\n\r") == null) return w.writeAll(value);
    try w.writeByte('"');
    for (value) |byte| {
        if (byte == '"') try w.writeByte('"');
        try w.writeByte(byte);
    }
    try w.writeByte('"');
}

// ---------------------------------------------------------------- Search page

pub fn searchPage(ctx: *Ctx, site: data.Site) !void {
    const arena = ctx.arena;
    const view = try analyze.start(ctx, site, .search, "Search");
    const w = ctx.w();
    const path = try std.fmt.allocPrint(arena, "/{s}/search", .{site.slug});
    const range = view.range;
    try layout.head(ctx, .{ .title = "Search", .subtitle = try std.fmt.allocPrint(arena, "What people searched on Google before they arrived · Search Console · {f}", .{range}), .view = view, .path = path, .filter = false });
    const from = data.dateText(range.start_ms);
    const to = data.dateText(range.end_ms - 1);
    const prev_from = data.dateText(range.prev_start_ms);
    const prev_to = data.dateText(range.prev_end_ms - 1);
    const connected = try ctx.db.scalar(arena, i64, "SELECT count(*) FROM integrations WHERE site_id=? AND kind='search_console'", .{site.id}) != 0;
    if (!connected) {
        try w.writeAll("<div class=\"card\">");
        try ui.empty(w, "Connect Search Console", "See the Google searches that bring visitors here, joined to what they do on the site. Read-only; nothing is sent to Google.", if (ctx.can(.admin)) try std.fmt.allocPrint(arena, "<a class=\"btn btn-primary\" href=\"/settings/integrations?site={s}#search_console\">Connect Search Console</a>", .{site.slug}) else "");
        try w.writeAll("</div>");
        try siteSearch(ctx, view);
        return layout.end(ctx);
    }
    const Totals = struct { clicks: i64, impressions: i64, position: f64 };
    const totals = struct {
        fn get(c: *Ctx, site_id: i64, a: []const u8, b: []const u8) !Totals {
            var statement = try c.db.prepare(c.arena, "SELECT coalesce(sum(clicks),0),coalesce(sum(impressions),0),coalesce(sum(position_x10*impressions)*1.0/nullif(sum(impressions),0)/10,0) FROM search_queries WHERE site_id=? AND day>=? AND day<=?");
            defer statement.deinit();
            try statement.bindInt(1, site_id);
            try statement.bindText(2, a);
            try statement.bindText(3, b);
            _ = try statement.step();
            return .{ .clicks = statement.columnInt(0), .impressions = statement.columnInt(1), .position = statement.columnFloat(2) };
        }
    };
    const now_totals = try totals.get(ctx, site.id, &from, &to);
    const before = try totals.get(ctx, site.id, &prev_from, &prev_to);
    const ctr_now = if (now_totals.impressions == 0) 0 else @as(f64, @floatFromInt(now_totals.clicks)) / @as(f64, @floatFromInt(now_totals.impressions)) * 100;
    const ctr_before = if (before.impressions == 0) 0 else @as(f64, @floatFromInt(before.clicks)) / @as(f64, @floatFromInt(before.impressions)) * 100;
    try w.writeAll("<div class=\"metrics\">");
    const tiles = [_]struct { []const u8, []const u8, []const u8, f64, f64, bool }{
        .{ "search", "Clicks from Google", try std.fmt.allocPrint(arena, "{f}", .{html.int(now_totals.clicks)}), @floatFromInt(now_totals.clicks), @floatFromInt(before.clicks), false },
        .{ "eye", "Impressions", try std.fmt.allocPrint(arena, "{f}", .{html.int(now_totals.impressions)}), @floatFromInt(now_totals.impressions), @floatFromInt(before.impressions), false },
        .{ "arrow-up-right", "Click-through rate", try std.fmt.allocPrint(arena, "{d:.1}%", .{ctr_now}), ctr_now, ctr_before, false },
        .{ "flag", "Average position", try std.fmt.allocPrint(arena, "{d:.1}", .{now_totals.position}), now_totals.position, before.position, true },
    };
    for (tiles, 0..) |entry, index| try ui.metric(w, arena, .{ .tone = ui.tones[index], .icon = entry[0], .label = entry[1], .value = entry[2], .change = if (view.compare) try ui.change(arena, entry[3], entry[4], entry[5], range.shortComparison()) else "" });
    try w.writeAll("</div>");
    // Queries, joined to on-site engagement and goals of their landing pages.
    var statement = try ctx.db.prepare(arena,
        \\WITH q AS (SELECT query,sum(clicks) c,sum(impressions) i,sum(position_x10*impressions)*1.0/nullif(sum(impressions),0)/10 p,
        \\  (SELECT page FROM search_queries x WHERE x.site_id=s.site_id AND x.query=s.query AND x.day>=?2 AND x.day<=?3 GROUP BY page ORDER BY sum(clicks) DESC LIMIT 1) page
        \\  FROM search_queries s WHERE site_id=?1 AND day>=?2 AND day<=?3 GROUP BY query)
        \\SELECT query,c,i,p,page,
        \\ (SELECT coalesce(avg(pv.active_ms>=10000 OR pv.max_scroll>=50 OR pv.interaction_count>0),0) FROM page_views pv WHERE pv.active_ms IS NOT NULL AND pv.site_id=?1 AND pv.path=q.page AND pv.received_at_ms>=?4 AND pv.received_at_ms<?5 AND pv.referrer_host LIKE '%google.%'),
        \\ (SELECT count(*) FROM events e JOIN goals g ON g.site_id=e.site_id AND g.kind='event' AND g.match_value=e.name JOIN page_views pv ON pv.site_id=e.site_id AND pv.page_id=e.page_id WHERE e.site_id=?1 AND pv.path=q.page AND e.received_at_ms>=?4 AND e.received_at_ms<?5)
        \\FROM q ORDER BY c DESC,i DESC LIMIT 50
    );
    defer statement.deinit();
    try statement.bindInt(1, site.id);
    try statement.bindText(2, &from);
    try statement.bindText(3, &to);
    try statement.bindInt(4, range.start_ms);
    try statement.bindInt(5, range.end_ms);
    try w.writeAll("<div class=\"grid split-main mt-16\"><section class=\"card card-flush\"><div class=\"card-head table-head\"><h2>Queries</h2><span class=\"meta\">Google data · on-site columns from Analytico</span></div><div class=\"table-wrap\"><table class=\"table\"><thead><tr><th>Query</th><th class=\"r\">Clicks</th><th class=\"r hide-m\">Impr.</th><th class=\"r hide-m\">CTR</th><th class=\"r\">Position</th><th class=\"r hide-m onsite\">Engaged</th><th class=\"r hide-m onsite\">Goals</th></tr></thead><tbody>");
    const Look = struct { query: []const u8, clicks: i64, impressions: i64, position: f64, page: []const u8, engaged: f64 };
    var looks: std.ArrayList(Look) = .empty;
    var count: usize = 0;
    while (try statement.step() == .row) : (count += 1) {
        const clicks = statement.columnInt(1);
        const impressions = statement.columnInt(2);
        const ctr = if (impressions == 0) 0 else @as(f64, @floatFromInt(clicks)) / @as(f64, @floatFromInt(impressions)) * 100;
        const engaged = statement.columnFloat(5) * 100;
        try render(w, "<tr><td class=\"strong\" title=\"{page}\">{query}</td><td class=\"r\">{clicks}</td><td class=\"r hide-m\">{impressions}</td><td class=\"r hide-m\">{ctr:.1}%</td><td class=\"r\">{position:.1}</td><td class=\"r hide-m onsite\">{engaged:.0}%</td><td class=\"r hide-m onsite\">{goals}</td></tr>", .{
            .page = statement.columnText(4), .query = statement.columnText(0), .clicks = html.int(clicks), .impressions = html.int(impressions), .ctr = ctr, .position = statement.columnFloat(3), .engaged = engaged, .goals = statement.columnInt(6),
        });
        // Seen often but rarely clicked: a better title could win clicks.
        if (impressions >= 100 and ctr < 2.5 and looks.items.len < 4) try looks.append(arena, .{ .query = try arena.dupe(u8, statement.columnText(0)), .clicks = clicks, .impressions = impressions, .position = statement.columnFloat(3), .page = try arena.dupe(u8, statement.columnText(4)), .engaged = engaged });
    }
    try w.writeAll("</tbody></table></div>");
    if (count == 0) try ui.empty(w, "No queries in this period", "Search Console data arrives with a two-day delay; the nightly sync fills this in.", "");
    try render(w, "<div class=\"card-foot\"><span>Showing {count} queries · Google reports queries with enough searches only</span></div></section><aside class=\"card\"><div class=\"card-head\"><div><h2>Worth a look</h2><p class=\"hint\">Seen often, clicked rarely</p></div></div><div class=\"stack\">", .{ .count = count });
    for (looks.items) |look| try render(w, "<div class=\"look\"><small>Seen {impressions} times, {rate:.1}% click</small><strong>“{query}”</strong><p>Position {position:.1}. {verdict} — a clearer title or description could win more clicks.</p><a class=\"link\" href=\"/{slug}/pages?page={encoded}\">Open {page} →</a></div>", .{
        .impressions = html.int(look.impressions),
        .rate = @as(f64, @floatFromInt(look.clicks)) / @as(f64, @floatFromInt(@max(look.impressions, 1))) * 100,
        .query = look.query,
        .position = look.position,
        .verdict = if (look.engaged >= 60) "Visitors who do click stay engaged" else "Its page is",
        .slug = site.slug,
        .encoded = html.url(look.page),
        .page = look.page,
    });
    if (looks.items.len == 0) try w.writeAll("<p class=\"hint\">Nothing stands out in this period.</p>");
    try w.writeAll("</div></aside></div>");
    try siteSearch(ctx, view);
    return layout.end(ctx);
}

/// Searches on the site itself, from the configured query parameters.
fn siteSearch(ctx: *Ctx, view: data.View) !void {
    const w = ctx.w();
    var sql = data.Sql.init(ctx.arena);
    try sql.add("SELECT pv.search_term,count(*),sum(pv.search_results=0),count(DISTINCT pv.visitor_day_id) FROM page_views pv WHERE ");
    try sql.pageViews(view, view.range.start_ms, view.range.end_ms);
    try sql.add(" AND pv.search_term IS NOT NULL GROUP BY 1 ORDER BY 2 DESC LIMIT 30");
    var statement = try sql.prepare(ctx.db);
    defer statement.deinit();
    try w.writeAll("<h2 class=\"section-title\">Site search<span class=\"note\">What visitors looked for on the site</span></h2><section class=\"card card-flush\"><div class=\"table-wrap\"><table class=\"table\"><thead><tr><th>Term</th><th class=\"r\">Searches</th><th class=\"r\">Visitors</th><th class=\"r\">No results</th></tr></thead><tbody>");
    var any = false;
    while (try statement.step() == .row) {
        any = true;
        const zero = statement.columnInt(2);
        try render(w, "<tr><td class=\"strong\">{term}</td><td class=\"r\">{searches}</td><td class=\"r\">{visitors}</td><td class=\"r\">", .{ .term = statement.columnText(0), .searches = html.int(statement.columnInt(1)), .visitors = html.int(statement.columnInt(3)) });
        if (zero > 0) try w.print("<span class=\"pill pill-warn\">{d}</span>", .{zero}) else try w.writeAll("<span class=\"muted\">—</span>");
        try w.writeAll("</td></tr>");
    }
    try w.writeAll("</tbody></table></div>");
    if (!any) try ui.empty(w, "No site searches yet", "Search terms are read from the <code>q</code>, <code>s</code>, <code>search</code> or <code>query</code> parameter (change it with <code>data-search</code> on the snippet). Mark the result count with <code>data-analytics-search-results=\"0\"</code> to see searches that found nothing.", "");
    try w.writeAll("</section>");
}
