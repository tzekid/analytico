//! Sites, view state (range, comparison, filters) and the shared report queries.
//! Queries read raw rows: the data is small and SQLite is fast enough that
//! rollups would only add a second source of truth.
const std = @import("std");
const db_mod = @import("../db.zig");
const domain = @import("../domain.zig");
const html = @import("html.zig");

pub const day_ms: i64 = 86_400_000;
pub const hour_ms: i64 = 3_600_000;

pub const Site = struct {
    id: i64,
    public_id: []const u8,
    slug: []const u8,
    name: []const u8,
    mode: domain.Mode,
    enabled: bool,
    origin: []const u8,
    created_at_ms: i64,
    consent_policy: domain.ConsentPolicy = .regional,
    consent_banner: bool = false,
    banner_text: []const u8 = "",
    privacy_url: []const u8 = "",
    search_params: []const u8 = "",
    replay_percent: i64 = 0,
    replay_triggers: bool = false,
    currency: []const u8 = "EUR",
    public_dashboard: bool = false,
    mask_text: bool = true,
    record_exclude: []const u8 = "",

    /// Session and Full link page views into visits.
    pub fn linked(self: Site) bool {
        return self.mode != .lite;
    }

    pub fn modeLabel(self: Site) []const u8 {
        return switch (self.mode) {
            .lite => "Lite",
            .session => "Session",
            .full => "Full",
        };
    }

    pub fn recording(self: Site) bool {
        return self.mode == .full and (self.replay_percent > 0 or self.replay_triggers);
    }

    /// Host shown under the site name: "fieldnotes.example".
    pub fn host(self: Site) []const u8 {
        const start = if (std.mem.find(u8, self.origin, "://")) |index| index + 3 else 0;
        return self.origin[start..];
    }

    pub fn title(self: Site) []const u8 {
        return if (self.name.len != 0) self.name else self.host();
    }

    pub fn initial(self: Site) u8 {
        const value = self.title();
        return if (value.len == 0) '?' else std.ascii.toUpper(value[0]);
    }
};

const site_columns = "SELECT s.id,s.public_id,s.slug,s.name,s.tracking_mode,s.enabled,coalesce((SELECT min(origin) FROM site_origins o WHERE o.site_id=s.id),''),s.created_at_ms," ++
    "s.consent_policy,s.consent_banner,s.banner_text,s.privacy_url,s.search_params,s.replay_percent,s.replay_triggers,s.currency,s.public_dashboard,s.mask_text,s.record_exclude FROM sites s";

fn readSite(arena: std.mem.Allocator, statement: *db_mod.Statement) !Site {
    return .{
        .id = statement.columnInt(0),
        .public_id = try arena.dupe(u8, statement.columnText(1)),
        .slug = try arena.dupe(u8, statement.columnText(2)),
        .name = try arena.dupe(u8, statement.columnText(3)),
        .mode = try domain.parseMode(statement.columnText(4)),
        .enabled = statement.columnBool(5),
        .origin = try arena.dupe(u8, statement.columnText(6)),
        .created_at_ms = statement.columnInt(7),
        .consent_policy = try domain.parseConsentPolicy(statement.columnText(8)),
        .consent_banner = statement.columnBool(9),
        .banner_text = try arena.dupe(u8, statement.columnText(10)),
        .privacy_url = try arena.dupe(u8, statement.columnText(11)),
        .search_params = try arena.dupe(u8, statement.columnText(12)),
        .replay_percent = statement.columnInt(13),
        .replay_triggers = statement.columnBool(14),
        .currency = try arena.dupe(u8, statement.columnText(15)),
        .public_dashboard = statement.columnBool(16),
        .mask_text = statement.columnBool(17),
        .record_exclude = try arena.dupe(u8, statement.columnText(18)),
    };
}

pub fn sites(arena: std.mem.Allocator, db: *db_mod.Db) ![]Site {
    var statement = try db.prepare(arena, site_columns ++ " ORDER BY s.enabled DESC, s.created_at_ms");
    defer statement.deinit();
    var out: std.ArrayList(Site) = .empty;
    while (try statement.step() == .row) try out.append(arena, try readSite(arena, &statement));
    return out.items;
}

/// Websites a user may see: all of them, or only those granted.
pub fn sitesFor(arena: std.mem.Allocator, db: *db_mod.Db, user_id: i64, all_sites: bool) ![]Site {
    if (all_sites) return sites(arena, db);
    var statement = try db.prepare(arena, site_columns ++ " WHERE s.id IN (SELECT site_id FROM user_sites WHERE user_id=?) ORDER BY s.enabled DESC, s.created_at_ms");
    defer statement.deinit();
    try statement.bindInt(1, user_id);
    var out: std.ArrayList(Site) = .empty;
    while (try statement.step() == .row) try out.append(arena, try readSite(arena, &statement));
    return out.items;
}

pub fn siteBySlug(arena: std.mem.Allocator, db: *db_mod.Db, slug: []const u8) !?Site {
    var statement = try db.prepare(arena, site_columns ++ " WHERE s.slug=?");
    defer statement.deinit();
    try statement.bindText(1, slug);
    if (try statement.step() != .row) return null;
    return try readSite(arena, &statement);
}

/// Slugs share the URL root with workspace routes.
/// Display names for the classified browser, OS and device values.
pub fn prettyLabel(arena: std.mem.Allocator, value: []const u8) []const u8 {
    const known = [_][2][]const u8{
        .{ "macos", "macOS" }, .{ "ios", "iOS" },         .{ "windows", "Windows" }, .{ "android", "Android" },
        .{ "linux", "Linux" }, .{ "chrome", "Chrome" },   .{ "safari", "Safari" },   .{ "firefox", "Firefox" },
        .{ "edge", "Edge" },   .{ "desktop", "Desktop" }, .{ "mobile", "Mobile" },   .{ "tablet", "Tablet" },
        .{ "phone", "Phone" }, .{ "unknown", "Unknown" },
    };
    for (known) |entry| if (std.mem.eql(u8, entry[0], value)) return entry[1];
    // Plain lowercase names only ("opera"); codes like "en-US" or "de" stay as sent.
    if (value.len <= 3) return value;
    for (value) |char| if (!std.ascii.isLower(char)) return value;
    const out = arena.dupe(u8, value) catch return value;
    out[0] = std.ascii.toUpper(out[0]);
    return out;
}

/// "ios,macos" from group_concat becomes "iOS, macOS".
pub fn prettyList(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var parts = std.mem.splitScalar(u8, value, ',');
    var first = true;
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (!first) try out.writer.writeAll(", ");
        first = false;
        try out.writer.writeAll(prettyLabel(arena, part));
    }
    return out.written();
}

pub fn reservedSlug(slug: []const u8) bool {
    const reserved = [_][]const u8{ "login", "logout", "invite", "setup", "settings", "oauth", "mcp", "t", "e", "i", "r", "h", "healthz", "readyz", "_", "api", "static", "share", "welcome", "auth", "integrations" };
    for (reserved) |name| if (std.mem.eql(u8, slug, name)) return true;
    return false;
}

// ---------------------------------------------------------------- time

pub const RangeKind = enum { @"24h", @"7d", @"30d", @"90d", custom };

pub const Range = struct {
    kind: RangeKind,
    start_ms: i64,
    end_ms: i64,
    bucket_ms: i64,
    buckets: usize,
    prev_start_ms: i64,
    prev_end_ms: i64,
    now_ms: i64,
    from_text: []const u8 = "",
    to_text: []const u8 = "",

    pub fn parse(params: html.Params, now_ms: i64) Range {
        const kind = std.meta.stringToEnum(RangeKind, params.get("range") orelse "7d") orelse .@"7d";
        const today = now_ms - @mod(now_ms, day_ms);
        var out: Range = switch (kind) {
            .@"24h" => blk: {
                const hour = now_ms - @mod(now_ms, hour_ms);
                break :blk .{ .kind = kind, .start_ms = hour - 23 * hour_ms, .end_ms = hour + hour_ms, .bucket_ms = hour_ms, .buckets = 24, .prev_start_ms = 0, .prev_end_ms = 0, .now_ms = now_ms };
            },
            .@"7d", .@"30d", .@"90d" => blk: {
                const count_days: i64 = switch (kind) {
                    .@"7d" => 7,
                    .@"30d" => 30,
                    else => 90,
                };
                break :blk .{ .kind = kind, .start_ms = today - (count_days - 1) * day_ms, .end_ms = today + day_ms, .bucket_ms = day_ms, .buckets = @intCast(count_days), .prev_start_ms = 0, .prev_end_ms = 0, .now_ms = now_ms };
            },
            .custom => custom: {
                const from = parseDate(params.get("from") orelse "") catch break :custom parse(.{}, now_ms);
                const to = parseDate(params.get("to") orelse "") catch break :custom parse(.{}, now_ms);
                if (to < from or to - from > 366 * day_ms) break :custom parse(.{}, now_ms);
                const count_days: usize = @intCast(@divExact(to - from, day_ms) + 1);
                break :custom .{ .kind = kind, .start_ms = from, .end_ms = to + day_ms, .bucket_ms = day_ms, .buckets = count_days, .prev_start_ms = 0, .prev_end_ms = 0, .now_ms = now_ms, .from_text = params.get("from").?, .to_text = params.get("to").? };
            },
        };
        out.prev_end_ms = out.start_ms;
        out.prev_start_ms = out.start_ms - (out.end_ms - out.start_ms);
        return out;
    }

    pub fn days(self: Range) f64 {
        return @max(1.0, @as(f64, @floatFromInt(self.end_ms - self.start_ms)) / @as(f64, @floatFromInt(day_ms)));
    }

    /// "21–27 Sep 2026", "28 Sep – 4 Oct 2026", "Last 24 hours".
    pub fn format(self: Range, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.kind == .@"24h") return w.writeAll("Last 24 hours");
        const a = civil(self.start_ms);
        const b = civil(self.end_ms - 1);
        if (a.year != b.year) return w.print("{d} {s} {d} – {d} {s} {d}", .{ a.day, month_names[a.month - 1], a.year, b.day, month_names[b.month - 1], b.year });
        if (a.month != b.month) return w.print("{d} {s} – {d} {s} {d}", .{ a.day, month_names[a.month - 1], b.day, month_names[b.month - 1], b.year });
        if (a.day == b.day) return w.print("{d} {s} {d}", .{ a.day, month_names[a.month - 1], a.year });
        return w.print("{d}–{d} {s} {d}", .{ a.day, b.day, month_names[a.month - 1], a.year });
    }

    pub fn comparisonLabel(self: Range) []const u8 {
        return switch (self.kind) {
            .@"24h" => "the previous 24 hours",
            .@"7d" => "the previous 7 days",
            .@"30d" => "the previous 30 days",
            .@"90d" => "the previous 90 days",
            .custom => "the previous period",
        };
    }

    pub fn shortComparison(self: Range) []const u8 {
        return switch (self.kind) {
            .@"24h" => "vs yesterday",
            .@"7d" => "vs last week",
            .@"30d" => "vs previous 30d",
            .@"90d" => "vs previous 90d",
            .custom => "vs previous",
        };
    }

    /// Label for bucket `index`: "Mon 21", "14:00", "21 Sep".
    pub fn bucketLabel(self: Range, buffer: []u8, index: usize) []const u8 {
        const at = self.start_ms + @as(i64, @intCast(index)) * self.bucket_ms;
        const date = civil(at);
        if (self.bucket_ms == hour_ms) return std.fmt.bufPrint(buffer, "{d:0>2}:00", .{@as(u64, @intCast(@divFloor(@mod(at, day_ms), hour_ms)))}) catch "";
        if (self.buckets <= 7) return std.fmt.bufPrint(buffer, "{s} {d}", .{ weekday_names[weekday(at)], date.day }) catch "";
        return std.fmt.bufPrint(buffer, "{d} {s}", .{ date.day, month_names[date.month - 1] }) catch "";
    }

    pub fn bucketLong(self: Range, buffer: []u8, index: usize) []const u8 {
        const at = self.start_ms + @as(i64, @intCast(index)) * self.bucket_ms;
        const date = civil(at);
        if (self.bucket_ms == hour_ms) return std.fmt.bufPrint(buffer, "{s} {d} {s}, {d:0>2}:00", .{ weekday_names[weekday(at)], date.day, month_names[date.month - 1], @as(u64, @intCast(@divFloor(@mod(at, day_ms), hour_ms))) }) catch "";
        return std.fmt.bufPrint(buffer, "{s} {d} {s}", .{ weekday_names[weekday(at)], date.day, month_names[date.month - 1] }) catch "";
    }

    pub fn bucketOfDay(self: Range, day: []const u8) ?usize {
        const at = parseDate(day) catch return null;
        if (at < self.start_ms or at >= self.end_ms or self.bucket_ms != day_ms) return null;
        return @intCast(@divFloor(at - self.start_ms, self.bucket_ms));
    }
};

pub const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
pub const weekday_names = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };

pub const Civil = struct { year: u16, month: u8, day: u8 };

pub fn civil(ms: i64) Civil {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, @divFloor(ms, 1000))) };
    const yd = epoch.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return .{ .year = yd.year, .month = @intCast(@backingInt(md.month)), .day = md.day_index + 1 };
}

/// 0 = Monday.
pub fn weekday(ms: i64) usize {
    const days = @divFloor(ms, day_ms);
    return @intCast(@mod(days + 3, 7));
}

pub fn parseDate(text: []const u8) !i64 {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return error.InvalidDate;
    const year = std.fmt.parseInt(u16, text[0..4], 10) catch return error.InvalidDate;
    const month = std.fmt.parseInt(u8, text[5..7], 10) catch return error.InvalidDate;
    const day = std.fmt.parseInt(u8, text[8..10], 10) catch return error.InvalidDate;
    if (year < 1970 or month < 1 or month > 12 or day < 1) return error.InvalidDate;
    if (day > std.time.epoch.getDaysInMonth(year, @fromBackingInt(@intCast(month)))) return error.InvalidDate;
    var days: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) days += std.time.epoch.getDaysInYear(y);
    var m: u8 = 1;
    while (m < month) : (m += 1) days += std.time.epoch.getDaysInMonth(year, @fromBackingInt(@intCast(m)));
    return (days + day - 1) * day_ms;
}

pub fn dateText(ms: i64) [10]u8 {
    return domain.utcDate(@max(ms, 0)) catch "1970-01-01".*;
}

/// "2 min ago", "3 h ago", "Thu", "21 Sep".
pub const Ago = struct {
    at: i64,
    now: i64,

    pub fn format(self: Ago, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const delta = self.now - self.at;
        if (delta < 60_000) return w.writeAll("just now");
        if (delta < hour_ms) return w.print("{d} min ago", .{@divFloor(delta, 60_000)});
        if (delta < day_ms) return w.print("{d} h ago", .{@divFloor(delta, hour_ms)});
        if (delta < 7 * day_ms) return w.writeAll(weekday_names[weekday(self.at)]);
        const date = civil(self.at);
        return w.print("{d} {s}", .{ date.day, month_names[date.month - 1] });
    }
};

pub fn ago(at: i64, now: i64) Ago {
    return .{ .at = at, .now = now };
}

/// "14:32" for today, otherwise like `ago`.
pub const Clock = struct {
    at: i64,
    now: i64,

    pub fn format(self: Clock, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.now - self.at < day_ms and @divFloor(self.at, day_ms) == @divFloor(self.now, day_ms)) {
            const minutes = @divFloor(@mod(self.at, day_ms), 60_000);
            return w.print("{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(@divFloor(minutes, 60))), @as(u64, @intCast(@mod(minutes, 60))) });
        }
        return (Ago{ .at = self.at, .now = self.now }).format(w);
    }
};

pub fn clock(at: i64, now: i64) Clock {
    return .{ .at = at, .now = now };
}

// ---------------------------------------------------------------- filters

pub const Dim = enum {
    source,
    page,
    campaign,
    device,
    browser,
    os,
    country,
    region,
    city,
    release,

    /// SQL expression over page_views aliased `pv`.
    pub fn column(self: Dim) []const u8 {
        return switch (self) {
            .source => "coalesce(nullif(pv.utm_source,''),nullif(pv.referrer_host,''),'direct')",
            .page => "pv.path",
            .campaign => "coalesce(pv.utm_campaign,'')",
            .device => "pv.device",
            .browser => "pv.browser",
            .os => "pv.operating_system",
            .country => "coalesce(pv.country,'unknown')",
            .region => "coalesce(pv.region,'unknown')",
            .city => "coalesce(pv.city,'unknown')",
            .release => "coalesce(pv.release_id,'')",
        };
    }

    pub fn label(self: Dim) []const u8 {
        return switch (self) {
            .source => "Source",
            .page => "Page",
            .campaign => "Campaign",
            .device => "Device",
            .browser => "Browser",
            .os => "OS",
            .country => "Country",
            .region => "Region",
            .city => "City",
            .release => "Release",
        };
    }
};

pub const Filter = struct {
    dim: Dim,
    value: []const u8,
    negate: bool = false,

    /// URL form: "source:google" or "source!:google".
    pub fn format(self: Filter, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}{s}:{s}", .{ @tagName(self.dim), if (self.negate) "!" else "", self.value });
    }
};

pub fn parseFilters(arena: std.mem.Allocator, params: html.Params) ![]Filter {
    var out: std.ArrayList(Filter) = .empty;
    for (try params.all(arena, "f")) |raw| {
        const split = std.mem.findScalar(u8, raw, ':') orelse continue;
        const negate = split > 0 and raw[split - 1] == '!';
        const dim = std.meta.stringToEnum(Dim, raw[0 .. split - @intFromBool(negate)]) orelse continue;
        const value = raw[split + 1 ..];
        if (value.len == 0 or value.len > 512) continue;
        try out.append(arena, .{ .dim = dim, .value = value, .negate = negate });
        if (out.items.len == 8) break;
    }
    return out.items;
}

pub const Metric = enum {
    visitors,
    visitor_days,
    views,
    active,

    pub fn label(self: Metric) []const u8 {
        return switch (self) {
            .visitors => "Visitors / day",
            .visitor_days => "Visitor-days",
            .views => "Page views",
            .active => "Active time",
        };
    }

    pub fn chartTitle(self: Metric) []const u8 {
        return switch (self) {
            .visitors, .visitor_days => "Visitors",
            .views => "Page views",
            .active => "Active time",
        };
    }

    pub fn unit(self: Metric) []const u8 {
        return switch (self) {
            .visitors, .visitor_days => "visitors",
            .views => "views",
            .active => "active",
        };
    }
};

/// Everything a site page needs to render a consistent view.
pub const View = struct {
    site: Site,
    range: Range,
    filters: []Filter,
    any: bool,
    compare: bool,
    metric: Metric,
    params: html.Params,

    pub fn parse(arena: std.mem.Allocator, site: Site, params: html.Params, now_ms: i64) !View {
        return .{
            .site = site,
            .range = Range.parse(params, now_ms),
            .filters = try parseFilters(arena, params),
            .any = std.mem.eql(u8, params.get("fm") orelse "", "any"),
            .compare = !std.mem.eql(u8, params.get("cmp") orelse "1", "0"),
            .metric = std.meta.stringToEnum(Metric, params.get("m") orelse "visitors") orelse .visitors,
            .params = params,
        };
    }

    /// Query string carrying view state, with overrides. Values of "" drop the key.
    pub fn href(self: View, arena: std.mem.Allocator, path: []const u8, overrides: []const [2][]const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        try w.writeAll(path);
        var first = true;
        const keys = [_][]const u8{ "range", "from", "to", "cmp", "m", "fm" };
        for (keys) |key| {
            var value = self.params.get(key) orelse "";
            for (overrides) |pair| if (std.mem.eql(u8, pair[0], key)) {
                value = pair[1];
            };
            if (value.len == 0) continue;
            if (std.mem.eql(u8, key, "range") and std.mem.eql(u8, value, "7d")) continue;
            if (std.mem.eql(u8, key, "m") and std.mem.eql(u8, value, "visitors")) continue;
            try w.print("{s}{s}={f}", .{ if (first) "?" else "&", key, html.url(value) });
            first = false;
        }
        var drop_filters = false;
        for (overrides) |pair| if (std.mem.eql(u8, pair[0], "f!")) {
            drop_filters = true;
        };
        if (!drop_filters) for (self.filters) |filter| {
            var removed = false;
            for (overrides) |pair| if (std.mem.eql(u8, pair[0], "f-") and std.mem.eql(u8, pair[1], filter.value)) {
                removed = true;
            };
            if (removed) continue;
            try w.print("{s}f={s}{s}%3A{f}", .{ if (first) "?" else "&", @tagName(filter.dim), if (filter.negate) "!" else "", html.url(filter.value) });
            first = false;
        };
        for (overrides) |pair| {
            if (std.mem.eql(u8, pair[0], "f+")) {
                try w.print("{s}f={f}", .{ if (first) "?" else "&", html.url(pair[1]) });
                first = false;
            } else if (std.mem.indexOfAny(u8, pair[0], "!+-") == null) {
                var known = false;
                for (keys) |key| if (std.mem.eql(u8, key, pair[0])) {
                    known = true;
                };
                if (known or pair[1].len == 0) continue;
                try w.print("{s}{s}={f}", .{ if (first) "?" else "&", pair[0], html.url(pair[1]) });
                first = false;
            }
        }
        return out.written();
    }

    pub fn hasFilter(self: View, dim: Dim) ?[]const u8 {
        for (self.filters) |filter| if (filter.dim == dim) return filter.value;
        return null;
    }
};

// ---------------------------------------------------------------- SQL builder

pub const Bind = union(enum) { int: i64, text: []const u8 };

pub const Sql = struct {
    arena: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    binds: std.ArrayList(Bind) = .empty,

    pub fn init(arena: std.mem.Allocator) Sql {
        return .{ .arena = arena };
    }

    pub fn add(self: *Sql, fragment: []const u8) !void {
        try self.text.appendSlice(self.arena, fragment);
    }

    pub fn int(self: *Sql, value: i64) !void {
        try self.text.append(self.arena, '?');
        try self.binds.append(self.arena, .{ .int = value });
    }

    pub fn str(self: *Sql, value: []const u8) !void {
        try self.text.append(self.arena, '?');
        try self.binds.append(self.arena, .{ .text = value });
    }

    /// Human page views of the site in [start, end) matching the view filters.
    pub fn pageViews(self: *Sql, view: View, start: i64, end: i64) !void {
        try self.add("pv.internal=0 AND pv.traffic_class IN ('human_like','unknown') AND pv.site_id=");
        try self.int(view.site.id);
        try self.add(" AND pv.received_at_ms>=");
        try self.int(start);
        try self.add(" AND pv.received_at_ms<");
        try self.int(end);
        try self.filters(view.filters, view.any);
    }

    /// count(DISTINCT pv.<column>) over raw rows from `split`. When `split`
    /// is today's cut, people already counted in that day's partial rollup
    /// under the same key and filters are left out, so the sum stays exact.
    pub fn distinctAfter(self: *Sql, view: View, column: []const u8, key: []const u8, start: i64, split: i64) !void {
        if (split == start or @mod(split, day_ms) == 0) {
            try self.add("count(DISTINCT pv.");
            try self.add(column);
            try self.add(")");
            return;
        }
        // The index keeps this a lookup of the person's few rows; left to
        // itself the planner scans every row of the day before the cut.
        try self.add("count(DISTINCT CASE WHEN NOT EXISTS(SELECT 1 FROM page_views x INDEXED BY ");
        try self.add(if (std.mem.eql(u8, column, "session_id")) "page_views_session" else "page_views_visitor_day");
        try self.add(" WHERE x.site_id=pv.site_id AND x.");
        try self.add(column);
        try self.add("=pv.");
        try self.add(column);
        // The literal term matches the visitor-day index's partial condition.
        if (!std.mem.eql(u8, column, "session_id")) try self.add(" AND x.received_at_ms>0");
        try self.add(" AND x.received_at_ms>=");
        try self.int(split - @mod(split, day_ms));
        try self.add(" AND x.received_at_ms<");
        try self.int(split);
        try self.add(" AND x.internal=0 AND x.traffic_class IN ('human_like','unknown')");
        for (view.filters) |filter| {
            try self.add(" AND ");
            try self.add(try aliased(self.arena, filter.dim.column()));
            try self.add(if (filter.negate) "<>" else "=");
            try self.str(filter.value);
        }
        if (!std.mem.eql(u8, key, "''")) {
            try self.add(" AND ");
            try self.add(try aliased(self.arena, key));
            try self.add("=");
            try self.add(key);
        }
        try self.add(") THEN pv.");
        try self.add(column);
        try self.add(" END)");
    }

    fn aliased(arena: std.mem.Allocator, expression: []const u8) ![]const u8 {
        return std.mem.replaceOwned(u8, arena, expression, "pv.", "x.");
    }

    pub fn filters(self: *Sql, list: []const Filter, any: bool) !void {
        if (list.len == 0) return;
        try self.add(" AND (");
        for (list, 0..) |filter, index| {
            if (index != 0) try self.add(if (any) " OR " else " AND ");
            try self.add(filter.dim.column());
            try self.add(if (filter.negate) "<>" else "=");
            try self.str(filter.value);
        }
        try self.add(")");
    }

    /// Events of the site in [start, end): server events always count; browser
    /// events count when their page view is human. Filters apply via that page.
    pub fn events(self: *Sql, view: View, start: i64, end: i64) !void {
        try self.add("e.internal=0 AND e.site_id=");
        try self.int(view.site.id);
        try self.add(" AND e.received_at_ms>=");
        try self.int(start);
        try self.add(" AND e.received_at_ms<");
        try self.int(end);
        if (view.filters.len == 0) {
            try self.add(" AND (e.source='server' OR EXISTS(SELECT 1 FROM page_views pv WHERE pv.site_id=e.site_id AND pv.page_id=e.page_id AND pv.traffic_class IN ('human_like','unknown')))");
        } else {
            try self.add(" AND EXISTS(SELECT 1 FROM page_views pv WHERE pv.site_id=e.site_id AND pv.page_id=e.page_id AND pv.traffic_class IN ('human_like','unknown')");
            try self.filters(view.filters, view.any);
            try self.add(")");
        }
    }

    pub fn prepare(self: *Sql, db: *db_mod.Db) !db_mod.Statement {
        var statement = try db.prepare(self.arena, self.text.items);
        errdefer statement.deinit();
        for (self.binds.items, 1..) |bind, index| switch (bind) {
            .int => |value| try statement.bindInt(index, value),
            .text => |value| try statement.bindText(index, value),
        };
        return statement;
    }
};

// ---------------------------------------------------------------- queries

pub const Totals = struct {
    views: i64 = 0,
    visitor_days: i64 = 0,
    active_ms: i64 = 0,
    sessions: i64 = 0,

    pub fn metric(self: Totals, which: Metric, range: Range) f64 {
        return switch (which) {
            .visitors => @as(f64, @floatFromInt(self.visitor_days)) / (if (range.bucket_ms == hour_ms) 1.0 else range.days()),
            .visitor_days => @floatFromInt(self.visitor_days),
            .views => @floatFromInt(self.views),
            .active => @floatFromInt(self.active_ms),
        };
    }
};

pub fn totals(arena: std.mem.Allocator, db: *db_mod.Db, view: View, start: i64, end: i64) !Totals {
    if (try remembered(arena, view, .{ .totals = .{ .start = start, .end = end } })) |value| return value.totals;
    const split = try rollupSplit(arena, db, view, start, end);
    var out: Totals = .{};
    if (split < end) {
        var sql = Sql.init(arena);
        try sql.add("SELECT count(*),");
        try sql.distinctAfter(view, "visitor_day_id", "''", start, split);
        try sql.add(",coalesce(sum(pv.active_ms),0),");
        try sql.distinctAfter(view, "session_id", "''", start, split);
        try sql.add(" FROM page_views pv WHERE ");
        try sql.pageViews(view, split, end);
        var statement = try sql.prepare(db);
        defer statement.deinit();
        if (try statement.step() == .row) out = .{ .views = statement.columnInt(0), .visitor_days = statement.columnInt(1), .active_ms = statement.columnInt(2), .sessions = statement.columnInt(3) };
    }
    if (split > start) {
        const rolled = try rollupSums(arena, db, view, start, split);
        out.views += rolled.views;
        out.visitor_days += rolled.visitors;
        out.active_ms += rolled.active_ms;
        out.sessions += rolled.sessions;
    }
    const imported = try importedTotal(arena, db, view, start, end);
    out.views += imported[0];
    out.visitor_days += imported[1];
    return out;
}

/// Imported history (Google Analytics) covers days before Analytico ran; it
/// has no filters, sessions or engagement, so it counts only unfiltered.
pub fn importedTotal(arena: std.mem.Allocator, db: *db_mod.Db, view: View, start: i64, end: i64) ![2]i64 {
    if (view.filters.len != 0) return .{ 0, 0 };
    var statement = try db.prepare(arena, "SELECT coalesce(sum(views),0),coalesce(sum(visitors),0) FROM imported_daily WHERE site_id=? AND dim='total' AND day>=? AND day<?");
    defer statement.deinit();
    try statement.bindInt(1, view.site.id);
    const from = dateText(start);
    const to = dateText(end);
    try statement.bindText(2, &from);
    try statement.bindText(3, &to);
    _ = try statement.step();
    return .{ statement.columnInt(0), statement.columnInt(1) };
}

pub fn hasImported(arena: std.mem.Allocator, db: *db_mod.Db, view: View) !bool {
    const from = dateText(view.range.start_ms);
    const to = dateText(view.range.end_ms);
    return try db.scalar(arena, i64, "SELECT count(*) FROM imported_daily WHERE site_id=? AND dim='total' AND day>=? AND day<?", .{ view.site.id, &from, &to }) != 0;
}

/// One value per bucket of `range`, shifted to start at `start`.
pub fn series(arena: std.mem.Allocator, db: *db_mod.Db, view: View, metric: Metric, start: i64) ![]f64 {
    if (try remembered(arena, view, .{ .series = .{ .metric = metric, .start = start } })) |value| return value.series;
    const range = view.range;
    const out = try arena.alloc(f64, range.buckets);
    @memset(out, 0);
    const end = start + range.bucket_ms * @as(i64, @intCast(range.buckets));
    const split = if (range.bucket_ms == day_ms) try rollupSplit(arena, db, view, start, end) else start;
    if (split > start) {
        const scope = rollupScope(view).?;
        var rolled = Sql.init(arena);
        try rolled.add(switch (metric) {
            .visitors, .visitor_days => "SELECT day,sum(visitors)",
            .views => "SELECT day,sum(views)",
            .active => "SELECT day,sum(active_ms)",
        });
        try rollupWhere(&rolled, view.site.id, scope, start, split);
        try rolled.add(" GROUP BY day");
        var statement = try rolled.prepare(db);
        defer statement.deinit();
        while (try statement.step() == .row) {
            const at = parseDate(statement.columnText(0)) catch continue;
            const bucket = @divFloor(at - start, day_ms);
            if (bucket >= 0 and bucket < out.len) out[@intCast(bucket)] += @floatFromInt(statement.columnInt(1));
        }
    }
    var sql = Sql.init(arena);
    try sql.add("SELECT (pv.received_at_ms-");
    try sql.int(start);
    try sql.add(")/");
    try sql.int(range.bucket_ms);
    switch (metric) {
        .visitors, .visitor_days => {
            try sql.add(" b,");
            try sql.distinctAfter(view, "visitor_day_id", "''", start, split);
            try sql.add(" FROM page_views pv WHERE ");
        },
        .views => try sql.add(" b,count(*) FROM page_views pv WHERE "),
        .active => try sql.add(" b,coalesce(sum(pv.active_ms),0) FROM page_views pv WHERE "),
    }
    try sql.pageViews(view, split, end);
    try sql.add(" GROUP BY b");
    var statement = try sql.prepare(db);
    defer statement.deinit();
    while (try statement.step() == .row) {
        const bucket = statement.columnInt(0);
        if (bucket >= 0 and bucket < out.len) out[@intCast(bucket)] += @floatFromInt(statement.columnInt(1));
    }
    if (view.filters.len == 0 and range.bucket_ms == day_ms and metric != .active) {
        var imported = try db.prepare(arena, "SELECT day,views,visitors FROM imported_daily WHERE site_id=? AND dim='total' AND day>=? AND day<?");
        defer imported.deinit();
        const from = dateText(start);
        const to = dateText(start + range.bucket_ms * @as(i64, @intCast(range.buckets)));
        try imported.bindInt(1, view.site.id);
        try imported.bindText(2, &from);
        try imported.bindText(3, &to);
        while (try imported.step() == .row) {
            const at = parseDate(imported.columnText(0)) catch continue;
            const bucket = @divFloor(at - start, day_ms);
            if (bucket >= 0 and bucket < out.len) out[@intCast(bucket)] += @floatFromInt(imported.columnInt(if (metric == .views) 1 else 2));
        }
    }
    return out;
}

pub const Row = struct {
    key: []const u8,
    value: i64,
    previous: i64 = 0,
    extra: i64 = 0,
};

/// Top values of a dimension by page views, with the previous period's count.
pub fn top(arena: std.mem.Allocator, db: *db_mod.Db, view: View, dim: Dim, limit: usize) ![]Row {
    if (try remembered(arena, view, .{ .top = .{ .dim = dim, .limit = limit } })) |value| return value.top;
    const imported_dim: ?[]const u8 = if (view.filters.len != 0) null else switch (dim) {
        .page => "page",
        .source => "source",
        .country => "country",
        .device => "device",
        else => null,
    };
    // Rollups hold one dimension at a time, so breakdowns use them unfiltered.
    const split = if (view.filters.len == 0) try rollupSplit(arena, db, view, view.range.start_ms, view.range.end_ms) else view.range.start_ms;
    const prev_split = if (view.filters.len == 0) try rollupSplit(arena, db, view, view.range.prev_start_ms, view.range.prev_end_ms) else view.range.prev_start_ms;
    var sql = Sql.init(arena);
    try sql.add("WITH cur AS (SELECT k,sum(n) n,sum(v) v FROM (SELECT ");
    try sql.add(dim.column());
    try sql.add(" k,count(*) n,");
    try sql.distinctAfter(view, "visitor_day_id", dim.column(), view.range.start_ms, split);
    try sql.add(" v FROM page_views pv WHERE ");
    try sql.pageViews(view, split, view.range.end_ms);
    try sql.add(" GROUP BY k");
    if (imported_dim) |name| try importedUnion(&sql, view, name, view.range.start_ms, view.range.end_ms, true);
    if (split > view.range.start_ms) {
        try sql.add(" UNION ALL SELECT key,sum(views),sum(visitors)");
        try rollupWhere(&sql, view.site.id, .{ .dim = @tagName(dim), .key = null }, view.range.start_ms, split);
        try sql.add(" GROUP BY key");
    }
    try sql.add(") GROUP BY k), prev AS (SELECT k,sum(n) n FROM (SELECT ");
    try sql.add(dim.column());
    try sql.add(" k,count(*) n FROM page_views pv WHERE ");
    try sql.pageViews(view, prev_split, view.range.prev_end_ms);
    try sql.add(" GROUP BY k");
    if (imported_dim) |name| try importedUnion(&sql, view, name, view.range.prev_start_ms, view.range.prev_end_ms, false);
    if (prev_split > view.range.prev_start_ms) {
        try sql.add(" UNION ALL SELECT key,sum(views)");
        try rollupWhere(&sql, view.site.id, .{ .dim = @tagName(dim), .key = null }, view.range.prev_start_ms, prev_split);
        try sql.add(" GROUP BY key");
    }
    try sql.add(") GROUP BY k) SELECT cur.k,cur.n,coalesce(prev.n,0),cur.v FROM cur LEFT JOIN prev ON prev.k=cur.k ORDER BY cur.n DESC,cur.k LIMIT ");
    try sql.int(@intCast(limit));
    var statement = try sql.prepare(db);
    defer statement.deinit();
    var out: std.ArrayList(Row) = .empty;
    while (try statement.step() == .row) try out.append(arena, .{
        .key = try arena.dupe(u8, statement.columnText(0)),
        .value = statement.columnInt(1),
        .previous = statement.columnInt(2),
        .extra = statement.columnInt(3),
    });
    return out.items;
}

// ---------------------------------------------------------------- parallel prefetch

/// One report query a page is about to make, so it can run ahead of time.
pub const Call = union(enum) {
    totals: struct { start: i64, end: i64 },
    series: struct { metric: Metric, start: i64 },
    top: struct { dim: Dim, limit: usize },
    key_sums: struct { dim: []const u8, start: i64, end: i64, limit: usize },
};

const Value = union(enum) { totals: Totals, series: []f64, top: []Row, key_sums: []KeySum };

/// Results computed ahead for the current request. Only the request's own
/// thread sees it; prefetch tasks always query.
pub const Memo = struct { entries: std.StringHashMapUnmanaged(Value) = .empty };
pub threadlocal var memo: ?*Memo = null;
/// Wall time the request spent waiting for prefetched queries.
pub threadlocal var prefetch_ns: u64 = 0;

fn callKey(arena: std.mem.Allocator, view: View, call: Call) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    const r = view.range;
    try w.print("{d}|{d}|{d}|{d}|{d}|{d}|{d}|{}", .{ view.site.id, r.start_ms, r.end_ms, r.prev_start_ms, r.prev_end_ms, r.bucket_ms, r.buckets, view.any });
    for (view.filters) |filter| try w.print("|{s}{s}={s}", .{ @tagName(filter.dim), if (filter.negate) "!" else "", filter.value });
    switch (call) {
        .totals => |c| try w.print("|totals|{d}|{d}", .{ c.start, c.end }),
        .series => |c| try w.print("|series|{s}|{d}", .{ @tagName(c.metric), c.start }),
        .top => |c| try w.print("|top|{s}|{d}", .{ @tagName(c.dim), c.limit }),
        .key_sums => |c| try w.print("|sums|{s}|{d}|{d}|{d}", .{ c.dim, c.start, c.end, c.limit }),
    }
    return out.written();
}

fn remembered(arena: std.mem.Allocator, view: View, call: Call) !?Value {
    const current = memo orelse return null;
    return current.entries.get(try callKey(arena, view, call));
}

const Task = struct {
    shared: *@import("../server.zig").Shared,
    view: View,
    call: Call,
    arena: std.heap.ArenaAllocator,
    value: ?Value = null,

    fn run(task: *Task) void {
        const db = task.shared.readers.acquire(task.shared.io);
        defer task.shared.readers.release(task.shared.io, db);
        const arena = task.arena.allocator();
        const view = task.view;
        task.value = switch (task.call) {
            .totals => |c| .{ .totals = totals(arena, db, view, c.start, c.end) catch return },
            .series => |c| .{ .series = series(arena, db, view, c.metric, c.start) catch return },
            .top => |c| .{ .top = top(arena, db, view, c.dim, c.limit) catch return },
            .key_sums => |c| .{ .key_sums = keySums(arena, db, view, c.dim, c.start, c.end, c.limit) catch return },
        };
    }
};

/// Below this many raw page views (those not yet in rollups), a page's
/// queries finish sooner one after another than coordinated across
/// connections.
const parallel_rows = 20_000;

/// Runs a page's independent queries concurrently, each on its own pooled
/// read connection, and keeps the results for the rendering that follows. A
/// failed task is simply queried again while rendering. Small views skip it.
pub fn prefetch(shared: *@import("../server.zig").Shared, db: *db_mod.Db, arena: std.mem.Allocator, view: View, calls: []const Call) !void {
    const current = memo orelse return;
    const started = db_mod.monotonicNs();
    const range = view.range;
    const raw_from = if (rollupScope(view) != null) @max(range.prev_start_ms, try rolledUntil(arena, db, view.site.id)) else range.prev_start_ms;
    if (try db.scalar(arena, i64, "SELECT count(*) FROM (SELECT 1 FROM page_views WHERE site_id=? AND received_at_ms>=? AND received_at_ms<? LIMIT ?)", .{ view.site.id, raw_from, range.end_ms, parallel_rows }) < parallel_rows) return;
    const tasks = try arena.alloc(Task, calls.len);
    var group: std.Io.Group = .init;
    for (calls, tasks) |call, *task| {
        task.* = .{ .shared = shared, .view = view, .call = call, .arena = .init(shared.gpa) };
        group.async(shared.io, Task.run, .{task});
    }
    group.await(shared.io) catch {};
    defer for (tasks) |*task| task.arena.deinit();
    for (tasks) |task| {
        const value = task.value orelse continue;
        // Copy out of the task's arena into the request's.
        const copy: Value = switch (value) {
            .totals => value,
            .series => |items| .{ .series = try arena.dupe(f64, items) },
            .top => |rows| blk: {
                const out = try arena.dupe(Row, rows);
                for (out) |*row| row.key = try arena.dupe(u8, row.key);
                break :blk .{ .top = out };
            },
            .key_sums => |sums| blk: {
                const out = try arena.dupe(KeySum, sums);
                for (out) |*entry| entry.key = try arena.dupe(u8, entry.key);
                break :blk .{ .key_sums = out };
            },
        };
        try current.entries.put(arena, try callKey(arena, view, task.call), copy);
    }
    prefetch_ns += db_mod.monotonicNs() - started;
}

// ---------------------------------------------------------------- rollups

/// Which daily rollup answers a view: the site total without filters, or one
/// dimension's value for a single positive filter. Anything else reads raw rows.
pub const RollupScope = struct { dim: []const u8, key: ?[]const u8 };

pub fn rollupScope(view: View) ?RollupScope {
    if (view.filters.len == 0) return .{ .dim = "total", .key = null };
    if (view.filters.len == 1 and !view.filters[0].negate and isRolledUp(@tagName(view.filters[0].dim))) return .{ .dim = @tagName(view.filters[0].dim), .key = view.filters[0].value };
    return null;
}

fn isRolledUp(name: []const u8) bool {
    for (rollup_dims) |dim| if (std.mem.eql(u8, dim[0], name)) return true;
    return false;
}

/// The moment rollups cover up to: the end of the last closed day, or the
/// cut of today's partial summary; 0 before the first rollup.
pub fn rolledUntil(arena: std.mem.Allocator, db: *db_mod.Db, site_id: i64) !i64 {
    return db.scalar(arena, i64, "SELECT coalesce(max(until_ms),0) FROM rollup_days WHERE site_id=?", .{site_id});
}

/// Rollups cover [start, split); raw rows cover [split, end). The split is
/// a day boundary, or today's cut when the range runs past it.
pub fn rollupSplit(arena: std.mem.Allocator, db: *db_mod.Db, view: View, start: i64, end: i64) !i64 {
    if (rollupScope(view) == null or @mod(start, day_ms) != 0) return start;
    const until = try rolledUntil(arena, db, view.site.id);
    if (until <= start) return start;
    if (until <= end) return until;
    return end - @mod(end, day_ms);
}

pub fn rollupWhere(sql: *Sql, site_id: i64, scope: RollupScope, start: i64, end: i64) !void {
    try sql.add(" FROM rollups WHERE site_id=");
    try sql.int(site_id);
    try sql.add(" AND dim=");
    try sql.str(scope.dim);
    if (scope.key) |key| {
        try sql.add(" AND key=");
        try sql.str(key);
    }
    try sql.add(" AND day>=");
    try sql.str(try sql.arena.dupe(u8, &dateText(start)));
    // A split inside today includes today's partial summary.
    try sql.add(" AND day<=");
    try sql.str(try sql.arena.dupe(u8, &dateText(end - 1)));
}

/// Dimensions summarised per day, as (name, expression over `pv`).
pub const rollup_dims = [_][2][]const u8{
    .{ "total", "''" },
    .{ "page", "pv.path" },
    .{ "source", "coalesce(nullif(pv.utm_source,''),nullif(pv.referrer_host,''),'direct')" },
    .{ "campaign", "coalesce(pv.utm_campaign,'')" },
    .{ "device", "pv.device" },
    .{ "browser", "pv.browser" },
    .{ "os", "pv.operating_system" },
    .{ "country", "coalesce(pv.country,'unknown')" },
    .{ "region", "coalesce(pv.region,'unknown')" },
    .{ "city", "coalesce(pv.city,'unknown')" },
    .{ "language", "coalesce(nullif(pv.language,''),'unknown')" },
    .{ "viewport", "coalesce(nullif(pv.viewport_class,''),'unknown')" },
    .{ "consent", "pv.consent_mode" },
    // Remembered visitors first seen before the day are returning.
    .{ "visitor_type", "CASE WHEN pv.visitor_id IS NULL THEN 'lite' WHEN (SELECT v.first_seen_ms FROM visitors v WHERE v.site_id=pv.site_id AND v.visitor_id=pv.visitor_id)<pv.received_at_ms-pv.received_at_ms%86400000 THEN 'returning' ELSE 'new' END" },
};

pub fn dimExpression(name: []const u8) []const u8 {
    for (rollup_dims) |dim| if (std.mem.eql(u8, dim[0], name)) return dim[1];
    unreachable;
}

pub const KeySum = struct { key: []const u8, sums: RollupSums };

/// Per-value totals of one rolled-up dimension over [start, end): rollups for
/// whole past days of unfiltered views, raw rows for everything else.
pub fn keySums(arena: std.mem.Allocator, db: *db_mod.Db, view: View, dim: []const u8, start: i64, end: i64, limit: usize) ![]KeySum {
    if (try remembered(arena, view, .{ .key_sums = .{ .dim = dim, .start = start, .end = end, .limit = limit } })) |value| return value.key_sums;
    const split = if (view.filters.len == 0) try rollupSplit(arena, db, view, start, end) else start;
    var sql = Sql.init(arena);
    try sql.add("SELECT k,sum(a),sum(b),sum(c),sum(d),sum(e),sum(f),sum(g) FROM (SELECT ");
    try sql.add(dimExpression(dim));
    try sql.add(" k,count(*) a,");
    try sql.distinctAfter(view, "visitor_day_id", dimExpression(dim), start, split);
    try sql.add(" b,");
    try sql.distinctAfter(view, "session_id", dimExpression(dim), start, split);
    try sql.add(" c,count(pv.active_ms) d,coalesce(sum(pv.active_ms),0) e,coalesce(sum(pv.active_ms>=10000 OR pv.max_scroll>=50 OR pv.interaction_count>0),0) f,coalesce(sum(pv.max_scroll),0) g FROM page_views pv WHERE ");
    try sql.pageViews(view, split, end);
    try sql.add(" GROUP BY k");
    if (split > start) {
        try sql.add(" UNION ALL SELECT key,sum(views),sum(visitors),sum(sessions),sum(summaries),sum(active_ms),sum(engaged),sum(scroll_sum)");
        try rollupWhere(&sql, view.site.id, .{ .dim = dim, .key = null }, start, split);
        try sql.add(" GROUP BY key");
    }
    try sql.add(") GROUP BY k ORDER BY 2 DESC,1 LIMIT ");
    try sql.int(@intCast(limit));
    var statement = try sql.prepare(db);
    defer statement.deinit();
    var out: std.ArrayList(KeySum) = .empty;
    while (try statement.step() == .row) try out.append(arena, .{ .key = try arena.dupe(u8, statement.columnText(0)), .sums = .{
        .views = statement.columnInt(1),
        .visitors = statement.columnInt(2),
        .sessions = statement.columnInt(3),
        .summaries = statement.columnInt(4),
        .active_ms = statement.columnInt(5),
        .engaged = statement.columnInt(6),
        .scroll_sum = statement.columnInt(7),
    } });
    return out.items;
}

pub fn keySum(sums: []const KeySum, key: []const u8) RollupSums {
    for (sums) |entry| if (std.mem.eql(u8, entry.key, key)) return entry.sums;
    return .{};
}

pub const RollupSums = struct { views: i64 = 0, visitors: i64 = 0, sessions: i64 = 0, summaries: i64 = 0, active_ms: i64 = 0, engaged: i64 = 0, scroll_sum: i64 = 0 };

pub fn rollupSums(arena: std.mem.Allocator, db: *db_mod.Db, view: View, start: i64, end: i64) !RollupSums {
    var sql = Sql.init(arena);
    try sql.add("SELECT coalesce(sum(views),0),coalesce(sum(visitors),0),coalesce(sum(sessions),0),coalesce(sum(summaries),0),coalesce(sum(active_ms),0),coalesce(sum(engaged),0),coalesce(sum(scroll_sum),0)");
    try rollupWhere(&sql, view.site.id, rollupScope(view).?, start, end);
    var statement = try sql.prepare(db);
    defer statement.deinit();
    _ = try statement.step();
    return .{ .views = statement.columnInt(0), .visitors = statement.columnInt(1), .sessions = statement.columnInt(2), .summaries = statement.columnInt(3), .active_ms = statement.columnInt(4), .engaged = statement.columnInt(5), .scroll_sum = statement.columnInt(6) };
}

fn importedUnion(sql: *Sql, view: View, dim: []const u8, start: i64, end: i64, with_visitors: bool) !void {
    try sql.add(" UNION ALL SELECT key,sum(views)");
    if (with_visitors) try sql.add(",sum(visitors)");
    try sql.add(" FROM imported_daily WHERE site_id=");
    try sql.int(view.site.id);
    try sql.add(" AND dim=");
    try sql.str(dim);
    try sql.add(" AND day>=");
    try sql.str(try sql.arena.dupe(u8, &dateText(start)));
    try sql.add(" AND day<");
    try sql.str(try sql.arena.dupe(u8, &dateText(end)));
    try sql.add(" GROUP BY key");
}

/// Distinct visitors seen in the last five minutes.
pub fn online(arena: std.mem.Allocator, db: *db_mod.Db, site_id: i64, now_ms: i64) !i64 {
    return db.scalar(arena, i64, "SELECT count(DISTINCT visitor_day_id) FROM page_views WHERE site_id=? AND received_at_ms>=? AND internal=0 AND traffic_class IN ('human_like','unknown')", .{ site_id, now_ms - 5 * 60_000 });
}

pub fn lastSeen(arena: std.mem.Allocator, db: *db_mod.Db, site_id: i64) !i64 {
    return db.scalar(arena, i64, "SELECT coalesce(max(received_at_ms),0) FROM page_views WHERE site_id=?", .{site_id});
}

/// The instance settings with fixed names; a misspelt one fails to compile.
pub const Setting = enum {
    @"anomalies.day",
    @"ai.base_url",
    @"ai.budget_cents",
    @"ai.key",
    @"ai.model",
    @"ai.provider",
    @"ai.share_paths",
    @"ai.share_sources",
    @"auth.google.domain",
    @"auth.primary",
    @"backup.daily",
    @"backup.last_at",
    @"chatgpt.api_base",
    @"chatgpt.auth_origin",
    @"chatgpt.host_id",
    collector_origin,
    currency,
    @"export.daily",
    @"export.last",
    @"jobs.last_run",
    @"jobs.nightly_at",
    public_origin,
    @"replays.retention_days",
    @"retention.days",
    @"smtp.from",
    @"smtp.host",
    @"smtp.password",
    @"smtp.port",
    @"smtp.security",
    @"smtp.username",
    @"webhooks.cursor",
};

pub fn setting(arena: std.mem.Allocator, db: *db_mod.Db, comptime name: Setting) !?[]const u8 {
    return settingNamed(arena, db, @tagName(name));
}

pub fn putSetting(arena: std.mem.Allocator, db: *db_mod.Db, comptime name: Setting, value: ?[]const u8) !void {
    return putSettingNamed(arena, db, @tagName(name), value);
}

/// A setting whose name is built at run time, such as `auth.google.client_id`.
pub fn settingNamed(arena: std.mem.Allocator, db: *db_mod.Db, name: []const u8) !?[]const u8 {
    const row = try db.one(arena, struct { value: []const u8 }, "SELECT value FROM settings WHERE name=?", .{name});
    return if (row) |found| found.value else null;
}

pub const GoalCount = struct { completions: i64, visitor_days: i64 };

/// How often a goal (an event name or a page path) was reached in a window;
/// with `visitors`, also by how many visitor-days.
pub fn goalCount(arena: std.mem.Allocator, db: *db_mod.Db, view: View, kind: []const u8, match: []const u8, start: i64, end: i64, visitors: bool) !GoalCount {
    var sql = Sql.init(arena);
    if (std.mem.eql(u8, kind, "event")) {
        try sql.add(if (visitors) "SELECT count(*),count(DISTINCT coalesce((SELECT pv2.visitor_day_id FROM page_views pv2 WHERE pv2.site_id=e.site_id AND pv2.page_id=e.page_id),e.event_id)) FROM events e WHERE " else "SELECT count(*),0 FROM events e WHERE ");
        try sql.events(view, start, end);
        try sql.add(" AND e.name=");
    } else {
        try sql.add(if (visitors) "SELECT count(*),count(DISTINCT pv.visitor_day_id) FROM page_views pv WHERE " else "SELECT count(*),0 FROM page_views pv WHERE ");
        try sql.pageViews(view, start, end);
        try sql.add(" AND pv.path=");
    }
    try sql.str(match);
    var statement = try sql.prepare(db);
    defer statement.deinit();
    _ = try statement.step();
    return .{ .completions = statement.columnInt(0), .visitor_days = statement.columnInt(1) };
}

pub fn putSettingNamed(arena: std.mem.Allocator, db: *db_mod.Db, name: []const u8, value: ?[]const u8) !void {
    if (value) |text| {
        try db.run(arena, "INSERT INTO settings(name,value) VALUES(?,?) ON CONFLICT(name) DO UPDATE SET value=excluded.value", .{ name, text });
    } else try db.run(arena, "DELETE FROM settings WHERE name=?", .{name});
}

test "dates" {
    const at = try parseDate("2026-09-25");
    try std.testing.expectEqual(@as(usize, 4), weekday(at));
    try std.testing.expectEqualStrings("2026-09-25", &dateText(at));
    var buffer: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    const range = Range.parse(try html.Params.parse(std.testing.allocator, ""), at + 5 * hour_ms);
    try w.print("{f}", .{range});
    try std.testing.expectEqualStrings("19–25 Sep 2026", w.buffered());
}
