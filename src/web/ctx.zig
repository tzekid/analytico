//! Per-request state for the web workspace.
const std = @import("std");
const db_mod = @import("../db.zig");
const html_mod = @import("html.zig");
const server = @import("../server.zig");
const data = @import("data.zig");

pub const Shared = server.Shared;

pub const Role = enum {
    viewer,
    editor,
    admin,
    owner,

    pub fn label(self: Role) []const u8 {
        return switch (self) {
            .viewer => "Viewer",
            .editor => "Editor",
            .admin => "Admin",
            .owner => "Owner",
        };
    }

    pub fn atLeast(self: Role, minimum: Role) bool {
        return @backingInt(self) >= @backingInt(minimum);
    }
};

pub const User = struct {
    id: i64,
    email: []const u8,
    role: Role = .owner,
    /// False when the user only sees the websites granted to them.
    all_sites: bool = true,
};

pub const Head = struct {
    cookie: []const u8 = "",
    origin: ?[]const u8 = null,
    host: []const u8 = "",
    content_type: []const u8 = "",
    content_length: ?u64 = null,
    forwarded_for: ?[]const u8 = null,
    forwarded_proto: ?[]const u8 = null,
    user_agent: []const u8 = "",
    authorization: []const u8 = "",
    accept: []const u8 = "",
    referer: ?[]const u8 = null,
    if_none_match: []const u8 = "",
    /// Sent by the workspace's own navigation (app.js).
    fetch: bool = false,
};

pub const maximum_form_bytes = 2 * 1024 * 1024;

pub const Ctx = struct {
    arena: std.mem.Allocator,
    shared: *Shared,
    db: *db_mod.Db,
    request: *std.http.Server.Request,
    deadline: *std.Io.Clock.Timestamp,
    method: std.http.Method,
    target: []const u8,
    path: []const u8,
    query: html_mod.Params,
    head: Head,
    user: ?User = null,
    status: std.http.Status = .ok,
    headers: std.ArrayList(std.http.Header) = .empty,
    body: std.Io.Writer.Allocating,
    responded: bool = false,
    form_params: ?html_mod.Params = null,
    raw_body: ?[]const u8 = null,
    /// Extra origin allowed as a form target (OAuth consent redirects there).
    form_action: []const u8 = "",
    /// Public share pages may be embedded; everything else may not.
    frame_ancestors: []const u8 = "'none'",
    started_ns: u64 = 0,
    /// The page frame, built once by `layout.begin` and reused by `layout.end`.
    shell: ?@import("layout.zig").Shell = null,
    /// Set by the live stream route: the connection goes to the broadcaster.
    live_site: ?i64 = null,
    /// Read-only pages and API answers: an ETag of the body lets clients
    /// revalidate and get an empty 304 when nothing changed.
    revalidate: bool = false,

    pub fn w(self: *Ctx) *std.Io.Writer {
        return &self.body.writer;
    }

    pub fn now(_: *Ctx) i64 {
        return @import("../domain.zig").nowMs();
    }

    pub fn header(self: *Ctx, name: []const u8, value: []const u8) !void {
        // std.http asserts on CR/LF in header values; refuse instead of crashing.
        if (std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidHeaderValue;
        try self.headers.append(self.arena, .{ .name = name, .value = value });
    }

    /// Extends the network deadline for slow but legitimate work such as AI calls.
    pub fn extendDeadline(self: *Ctx, seconds: i64) void {
        self.deadline.* = .fromNow(self.shared.io, .{ .raw = .fromSeconds(seconds), .clock = .awake });
    }

    pub fn finish(self: *Ctx, content_type: []const u8) !void {
        if (self.responded) return;
        self.responded = true;
        // Where the time went, for the browser's network panel.
        try self.header("server-timing", try std.fmt.allocPrint(self.arena, "db;dur={d:.1};desc=\"{d} statements\", prefetch;dur={d:.1};desc=\"parallel queries\", app;dur={d:.1}", .{
            @as(f64, @floatFromInt(db_mod.thread_ns)) / std.time.ns_per_ms,
            db_mod.thread_statements,
            @as(f64, @floatFromInt(data.prefetch_ns)) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(db_mod.monotonicNs() - self.started_ns)) / std.time.ns_per_ms,
        }));
        try self.header("content-type", content_type);
        try self.header("x-content-type-options", "nosniff");
        try self.header("referrer-policy", "same-origin");
        if (self.revalidate and self.method == .GET and self.status == .ok and !self.hasHeader("cache-control")) {
            const tag = try std.fmt.allocPrint(self.arena, "\"{x}\"", .{std.hash.Wyhash.hash(0, self.body.writer.buffered())});
            try self.header("etag", tag);
            try self.header("cache-control", "private, no-cache");
            if (std.mem.eql(u8, self.head.if_none_match, tag)) {
                self.status = .not_modified;
                self.body.writer.end = 0;
            }
        }
        if (std.mem.startsWith(u8, content_type, "text/html")) {
            if (!self.hasHeader("cache-control")) try self.header("cache-control", "no-store");
            try self.header("content-security-policy", try std.fmt.allocPrint(self.arena, "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors {s}; base-uri 'none'; form-action 'self'{s}{s}", .{ self.frame_ancestors, if (self.form_action.len == 0) "" else " ", self.form_action }));
        }
        try self.request.respond(self.body.writer.buffered(), .{
            .status = self.status,
            .keep_alive = false,
            .extra_headers = self.headers.items,
        });
    }

    pub fn html(self: *Ctx) !void {
        return self.finish("text/html; charset=utf-8");
    }

    pub fn json(self: *Ctx) !void {
        if (!self.revalidate and !self.hasHeader("cache-control")) try self.header("cache-control", "no-store");
        return self.finish("application/json; charset=utf-8");
    }

    fn hasHeader(self: *Ctx, name: []const u8) bool {
        for (self.headers.items) |item| if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
        return false;
    }

    pub fn redirect(self: *Ctx, location: []const u8) !void {
        self.status = .see_other;
        try self.header("location", location);
        self.body.writer.end = 0;
        return self.finish("text/plain; charset=utf-8");
    }

    pub fn redirectFmt(self: *Ctx, comptime fmt: []const u8, args: anytype) !void {
        return self.redirect(try std.fmt.allocPrint(self.arena, fmt, args));
    }

    /// Shows `message` on the next page and goes there.
    pub fn done(self: *Ctx, message: []const u8, comptime fmt: []const u8, args: anytype) !void {
        try self.flash(message, "", "");
        return self.redirectFmt(fmt, args);
    }

    /// The website named by a slug, if this person may see it.
    pub fn visibleSite(self: *Ctx, slug: []const u8) !?data.Site {
        const site = try data.siteBySlug(self.arena, self.db, slug) orelse return null;
        return if (try self.canSee(site.id)) site else null;
    }

    pub fn text(self: *Ctx, status: std.http.Status, message: []const u8) !void {
        self.status = status;
        self.body.writer.end = 0;
        try self.body.writer.writeAll(message);
        return self.finish("text/plain; charset=utf-8");
    }

    pub fn param(self: *Ctx, key: []const u8) ?[]const u8 {
        return self.query.get(key);
    }

    /// Reads and caches the request body.
    pub fn bodyBytes(self: *Ctx) ![]const u8 {
        if (self.raw_body) |bytes| return bytes;
        const length = self.head.content_length orelse 0;
        if (length > maximum_form_bytes) return error.PayloadTooLarge;
        const bytes = try self.arena.alloc(u8, @intCast(length));
        if (length != 0) {
            var buffer: [16 * 1024]u8 = undefined;
            const reader = self.request.readerExpectContinue(&buffer) catch return error.InvalidBody;
            reader.readSliceAll(bytes) catch return error.InvalidBody;
        }
        self.raw_body = bytes;
        return bytes;
    }

    /// Urlencoded form fields. Multipart is not used anywhere.
    pub fn form(self: *Ctx) !html_mod.Params {
        if (self.form_params) |params| return params;
        const params = try html_mod.Params.parse(self.arena, try self.bodyBytes());
        self.form_params = params;
        return params;
    }

    pub fn field(self: *Ctx, key: []const u8) ![]const u8 {
        return (try self.form()).get(key) orelse "";
    }

    pub fn cookie(self: *Ctx, name: []const u8) ?[]const u8 {
        var parts = std.mem.splitScalar(u8, self.head.cookie, ';');
        while (parts.next()) |raw| {
            const part = std.mem.trim(u8, raw, " ");
            const split = std.mem.findScalar(u8, part, '=') orelse continue;
            if (std.mem.eql(u8, part[0..split], name)) return part[split + 1 ..];
        }
        return null;
    }

    pub fn setCookie(self: *Ctx, name: []const u8, value: []const u8, max_age: i64) !void {
        const secure = if (self.secureOrigin()) "; Secure" else "";
        try self.header("set-cookie", try std.fmt.allocPrint(self.arena, "{s}={s}; Path=/; Max-Age={d}; HttpOnly; SameSite=Lax{s}", .{ name, value, max_age, secure }));
    }

    pub fn secureOrigin(self: *Ctx) bool {
        if (self.head.forwarded_proto) |proto| return std.mem.eql(u8, proto, "https");
        return false;
    }

    /// Absolute origin of this deployment, as seen by the browser.
    pub fn publicOrigin(self: *Ctx) ![]const u8 {
        const scheme = if (self.secureOrigin()) "https" else "http";
        return std.fmt.allocPrint(self.arena, "{s}://{s}", .{ scheme, self.head.host });
    }

    /// A one-shot toast shown on the next rendered page. `undo` is an optional
    /// POST target; `link` is an optional GET target.
    pub fn flash(self: *Ctx, message: []const u8, action_label: []const u8, action_href: []const u8) !void {
        var buffer: std.Io.Writer.Allocating = .init(self.arena);
        try buffer.writer.print("{f}|{f}|{f}", .{ html_mod.url(message), html_mod.url(action_label), html_mod.url(action_href) });
        try self.header("set-cookie", try std.fmt.allocPrint(self.arena, "an_flash={s}; Path=/; Max-Age=60; SameSite=Lax", .{buffer.writer.buffered()}));
    }

    pub const Flash = struct { message: []const u8, action_label: []const u8, action_href: []const u8 };

    pub fn takeFlash(self: *Ctx) !?Flash {
        const raw = self.cookie("an_flash") orelse return null;
        try self.header("set-cookie", "an_flash=; Path=/; Max-Age=0; SameSite=Lax");
        var parts = std.mem.splitScalar(u8, raw, '|');
        const message = html_mod.decodeComponent(self.arena, parts.next() orelse return null) catch return null;
        const label = html_mod.decodeComponent(self.arena, parts.next() orelse "") catch "";
        const href = html_mod.decodeComponent(self.arena, parts.next() orelse "") catch "";
        if (message.len == 0) return null;
        return .{ .message = message, .action_label = label, .action_href = href };
    }

    /// Same-origin check for state-changing requests.
    pub fn sameOrigin(self: *Ctx) bool {
        const origin = self.head.origin orelse return false;
        const scheme_end = std.mem.find(u8, origin, "://") orelse return false;
        return std.ascii.eqlIgnoreCase(origin[scheme_end + 3 ..], self.head.host);
    }

    pub fn role(self: *Ctx) Role {
        return if (self.user) |user| user.role else .viewer;
    }

    /// Websites the signed-in user may see. Admins and owners see all.
    pub fn visibleSites(self: *Ctx) ![]data.Site {
        const user = self.user orelse return &.{};
        return data.sitesFor(self.arena, self.db, user.id, user.all_sites or user.role.atLeast(.admin));
    }

    pub fn canSee(self: *Ctx, site_id: i64) !bool {
        for (try self.visibleSites()) |site| if (site.id == site_id) return true;
        return false;
    }

    pub fn can(self: *Ctx, minimum: Role) bool {
        return self.role().atLeast(minimum);
    }

    pub fn clientIp(self: *Ctx) []const u8 {
        const raw = self.head.forwarded_for orelse return "loopback";
        return std.mem.trim(u8, raw, " ");
    }
};
