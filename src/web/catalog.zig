//! The report catalog: every report Analytico answers outside its pages —
//! for the CLI, the read API, MCP connectors and the AI — defined once.
//! Each report declares its parameters (they become CLI flags, API query
//! parameters and JSON Schema for tools) and returns one table; the
//! renderers turn a table into TSV, CSV, JSON or text.
//!
//! Two kinds of report: summaries from the workspace's data layer (rollups,
//! filters, the same numbers as the pages) and detailed exports from raw rows
//! (page, event and session detail the rollups do not keep).
const std = @import("std");
const data = @import("data.zig");
const db_mod = @import("../db.zig");
const domain = @import("../domain.zig");
const html = @import("html.zig");
const customers = @import("customers.zig");
const behaviour = @import("behaviour.zig");

pub const Value = union(enum) { null, int: i64, float: f64, text: []const u8 };

pub const Table = struct {
    columns: []const []const u8,
    rows: []const []const Value,
};

pub const Param = struct {
    name: []const u8,
    description: []const u8,
    kind: enum { string, integer } = .string,
    values: []const []const u8 = &.{},
    required: bool = false,
};

/// What a report reveals, for "What the AI can see" in Settings → AI.
pub const Reveals = enum { counts, paths, sources, paths_and_sources };

pub const Input = struct {
    arena: std.mem.Allocator,
    db: *db_mod.Db,
    view: data.View,
    params: html.Params,
    now_ms: i64,

    pub fn get(self: Input, name: []const u8) ?[]const u8 {
        const value = self.params.get(name) orelse return null;
        return if (value.len == 0) null else value;
    }

    pub fn int(self: Input, name: []const u8, default: i64, min: i64, max: i64) i64 {
        const text = self.get(name) orelse return default;
        return std.math.clamp(std.fmt.parseInt(i64, text, 10) catch default, min, max);
    }
};

pub const Report = struct {
    name: []const u8,
    title: []const u8,
    description: []const u8,
    params: []const Param = &.{},
    reveals: Reveals = .counts,
    /// Needs visitors followed through a visit (Session or Full mode).
    sessions: bool = false,
    run: *const fn (Input) anyerror!Table,
};

/// Parameters every report takes besides its own.
pub const common = [_]Param{
    .{ .name = "site", .description = "Website slug", .required = true },
    .{ .name = "range", .description = "Period", .values = &.{ "24h", "7d", "30d", "90d" } },
    .{ .name = "from", .description = "Custom start date YYYY-MM-DD (with to)" },
    .{ .name = "to", .description = "Custom end date YYYY-MM-DD, inclusive" },
    .{ .name = "filters", .description = "Filters like page:/pricing, source:google, device:mobile, country:DE, campaign:spring, release:v2; prefix the value with ! to exclude (page:!/admin)" },
};

const limit_param: Param = .{ .name = "limit", .description = "Maximum rows (1–1000, default 100)", .kind = .integer };

pub const reports = [_]Report{
    .{ .name = "overview", .title = "Overview", .description = "Totals for the period and the previous period: page views, visitor-days, sessions, active time, orders and revenue.", .run = overviewReport },
    .{ .name = "breakdown", .title = "Breakdown", .description = "Page views and visitor-days per value of one dimension, with the previous period.", .reveals = .paths_and_sources, .params = &.{ .{ .name = "dimension", .description = "Dimension", .values = &dim_names, .required = true }, limit_param }, .run = breakdownReport },
    .{ .name = "timeseries", .title = "Time series", .description = "One metric per day (per hour for 24h).", .params = &.{.{ .name = "metric", .description = "Metric", .values = &.{ "views", "visitor_days", "active" } }}, .run = timeseriesReport },
    .{ .name = "pages", .title = "Pages", .description = "Every page with views, visitors, engagement, scroll and clicks out.", .reveals = .paths, .params = &.{limit_param}, .run = pagesReport },
    .{ .name = "acquisition", .title = "Acquisition", .description = "Sources and mediums with views and visitors.", .reveals = .sources, .params = &.{limit_param}, .run = acquisitionReport },
    .{ .name = "campaigns", .title = "Campaigns", .description = "UTM campaigns with views, visitors and sessions.", .reveals = .sources, .params = &.{limit_param}, .run = campaignsReport },
    .{ .name = "events", .title = "Events", .description = "Custom events with occurrences, sessions and value.", .params = &.{limit_param}, .run = eventsReport },
    .{ .name = "goals", .title = "Goals", .description = "Each goal with completions and the share of visitor-days that reached it.", .reveals = .paths, .run = goalsReport },
    .{ .name = "funnel", .title = "Funnel", .description = "Sessions reaching each step of a saved funnel, in order, within its time window.", .reveals = .paths, .sessions = true, .params = &.{.{ .name = "name", .description = "Funnel name", .required = true }}, .run = funnelReport },
    .{ .name = "paths", .title = "Next pages", .description = "Where visitors went next from a page.", .reveals = .paths, .sessions = true, .params = &.{ .{ .name = "from_path", .description = "Page path such as /pricing", .required = true }, limit_param }, .run = pathsReport },
    .{ .name = "revenue", .title = "Products", .description = "Products with views, add-to-carts, orders, revenue and refunds (minor currency units).", .params = &.{limit_param}, .run = revenueReport },
    .{ .name = "errors", .title = "Errors", .description = "JavaScript errors, grouped: occurrences, visits affected, where and since when.", .reveals = .paths, .params = &.{limit_param}, .run = errorsReport },
    .{ .name = "search", .title = "Site search", .description = "What visitors searched for on the site, and how often nothing was found.", .reveals = .paths, .params = &.{limit_param}, .run = searchReport },
    .{ .name = "performance", .title = "Performance", .description = "Core Web Vitals percentiles (TTFB, FCP, LCP, INP, CLS) by page type, release, navigation and device.", .params = &.{limit_param}, .run = performanceReport },
    .{ .name = "sections", .title = "Sections", .description = "Marked page sections: how often each was seen and where visitors stopped.", .params = &.{limit_param}, .run = sectionsReport },
    .{ .name = "actions", .title = "Actions", .description = "Marked actions and rage clicks.", .params = &.{limit_param}, .run = actionsReport },
    .{ .name = "recent", .title = "Recent activity", .description = "The latest page views and events.", .reveals = .paths, .params = &.{limit_param}, .run = recentReport },
    .{ .name = "coverage", .title = "Coverage", .description = "How complete collection is: summaries, unknown traffic, sessions, internal views and performance samples.", .run = coverageReport },
    .{ .name = "traffic", .title = "Traffic classes", .description = "Page views by traffic class (human-like, bots, monitors, internal).", .run = trafficReport },
    .{ .name = "sessions", .title = "Sessions", .description = "Recent sessions with length, pages, events, landing and exit page.", .reveals = .paths, .sessions = true, .params = &.{limit_param}, .run = sessionsReport },
    .{ .name = "session", .title = "Session", .description = "Every page view and event of one session, in order.", .reveals = .paths, .sessions = true, .params = &.{.{ .name = "id", .description = "Session id", .required = true }}, .run = sessionReport },
    .{ .name = "flow", .title = "Flow", .description = "Steps of a named flow (events flow_* with a flow property), with abandoned sessions.", .params = &.{ .{ .name = "flow", .description = "Flow name", .required = true }, limit_param }, .run = flowReport },
    .{ .name = "friction", .title = "Friction", .description = "Failed steps, backtracks, failed or unresponsive actions and rage clicks.", .params = &.{ .{ .name = "flow", .description = "Only this flow" }, limit_param }, .run = frictionReport },
    .{ .name = "campaign_economics", .title = "Campaign economics", .description = "Spend, sessions, registrations, payments, refunds, revenue and cost per result for each campaign.", .reveals = .sources, .params = &.{limit_param}, .run = economicsReport },
};

const dim_names = blk: {
    var names: [@typeInfo(data.Dim).@"enum".field_names.len][]const u8 = undefined;
    for (&names, @typeInfo(data.Dim).@"enum".field_names) |*name, field| name.* = field;
    break :blk names;
};

pub fn find(name: []const u8) ?*const Report {
    for (&reports) |*report| if (std.mem.eql(u8, report.name, name)) return report;
    return null;
}

pub const Problem = error{ UnknownReport, MissingParameter, InvalidParameter, SessionModeRequired, UnsupportedFilter };

/// A view for the report's period and filters, from the same parameters
/// every surface passes (range, from/to, f=dim:value).
pub fn view(arena: std.mem.Allocator, site: data.Site, params: html.Params, now_ms: i64) !data.View {
    var out = try data.View.parse(arena, site, params, now_ms);
    out.compare = true;
    return out;
}

pub fn run(arena: std.mem.Allocator, db: *db_mod.Db, report: *const Report, site: data.Site, params: html.Params, now_ms: i64) !Table {
    for (report.params) |param| if (param.required) {
        const value: []const u8 = params.get(param.name) orelse "";
        if (value.len == 0) return error.MissingParameter;
    };
    if (report.sessions and site.mode == .lite) return error.SessionModeRequired;
    return report.run(.{ .arena = arena, .db = db, .view = try view(arena, site, params, now_ms), .params = params, .now_ms = now_ms });
}

// ---------------------------------------------------------------- renderers

pub const Format = enum { table, csv, json, text };

pub fn render(w: *std.Io.Writer, table: Table, format: Format) !void {
    switch (format) {
        .json => {
            try w.writeByte('[');
            for (table.rows, 0..) |row, index| {
                if (index != 0) try w.writeByte(',');
                try jsonRow(w, table.columns, row);
            }
            try w.writeAll("]\n");
        },
        .table, .csv, .text => {
            const separator: []const u8 = switch (format) {
                .csv => ",",
                .text => " | ",
                else => "\t",
            };
            for (table.columns, 0..) |column, index| {
                if (index != 0) try w.writeAll(separator);
                if (format == .csv) try csvText(w, column) else try w.writeAll(column);
            }
            try w.writeByte('\n');
            for (table.rows) |row| {
                for (row, 0..) |cell, index| {
                    if (index != 0) try w.writeAll(separator);
                    switch (cell) {
                        .null => {},
                        .int => |value| try w.print("{d}", .{value}),
                        .float => |value| try w.print("{d}", .{value}),
                        .text => |value| if (format == .csv) try csvText(w, value) else try w.writeAll(value),
                    }
                }
                try w.writeByte('\n');
            }
        },
    }
}

pub fn jsonRow(w: *std.Io.Writer, columns: []const []const u8, row: []const Value) !void {
    try w.writeByte('{');
    for (columns, row, 0..) |column, cell, index| {
        if (index != 0) try w.writeByte(',');
        try std.json.Stringify.value(column, .{}, w);
        try w.writeByte(':');
        switch (cell) {
            .null => try w.writeAll("null"),
            .int => |value| try w.print("{d}", .{value}),
            .float => |value| try w.print("{d}", .{value}),
            .text => |value| try std.json.Stringify.value(value, .{}, w),
        }
    }
    try w.writeByte('}');
}

/// Spreadsheet-safe CSV: quoted, and formula-looking values defused.
pub fn csvText(w: *std.Io.Writer, value: []const u8) !void {
    try w.writeByte('"');
    if (value.len != 0 and std.mem.findScalar(u8, "=+-@", value[0]) != null) try w.writeByte('\'');
    for (value) |byte| {
        if (byte == '"') try w.writeByte('"');
        try w.writeByte(byte);
    }
    try w.writeByte('"');
}

/// JSON Schema for a report's parameters (MCP tools, AI function tools).
/// Without `site` when the caller fixes the website.
pub fn schema(w: *std.Io.Writer, report: *const Report, site: bool) !void {
    try w.writeAll("{\"type\":\"object\",\"properties\":{");
    var first = true;
    for ([_][]const Param{ if (site) &common else common[1..], report.params }) |group| for (group) |param| {
        if (!first) try w.writeByte(',');
        first = false;
        try std.json.Stringify.value(param.name, .{}, w);
        if (std.mem.eql(u8, param.name, "filters")) {
            try w.writeAll(":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":");
        } else try w.print(":{{\"type\":\"{s}\",\"description\":", .{@tagName(param.kind)});
        try std.json.Stringify.value(param.description, .{}, w);
        if (param.values.len != 0) {
            try w.writeAll(",\"enum\":");
            try std.json.Stringify.value(param.values, .{}, w);
        }
        try w.writeByte('}');
    };
    try w.writeAll("},\"required\":[");
    first = !site;
    if (site) try w.writeAll("\"site\"");
    for (report.params) |param| if (param.required) {
        if (!first) try w.writeByte(',');
        first = false;
        try std.json.Stringify.value(param.name, .{}, w);
    };
    try w.writeAll("],\"additionalProperties\":false}");
}

/// Tool or JSON arguments as query parameters (filters become repeated f=).
pub fn paramsFromJson(arena: std.mem.Allocator, arguments: std.json.ObjectMap) !html.Params {
    var query: std.Io.Writer.Allocating = .init(arena);
    var it = arguments.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        switch (entry.value_ptr.*) {
            .string => |text| try query.writer.print("&{f}={f}", .{ html.url(key), html.url(text) }),
            .integer => |number| try query.writer.print("&{f}={d}", .{ html.url(key), number }),
            .array => |items| if (std.mem.eql(u8, key, "filters")) for (items.items) |item| if (item == .string) try query.writer.print("&f={f}", .{html.url(item.string)}),
            else => {},
        }
    }
    // Custom dates win over a preset.
    if (arguments.get("from") != null) try query.writer.writeAll("&range=custom");
    return html.Params.parse(arena, query.written());
}

/// A report's own parameters (not period or filters) from tool arguments.
pub fn reportParams(arena: std.mem.Allocator, report: *const Report, arguments: std.json.ObjectMap) ![]const u8 {
    var query: std.Io.Writer.Allocating = .init(arena);
    for (report.params) |param| if (arguments.get(param.name)) |value| switch (value) {
        .string => |text| try query.writer.print("&{s}={f}", .{ param.name, html.url(text) }),
        .integer => |number| try query.writer.print("&{s}={d}", .{ param.name, number }),
        else => {},
    };
    return query.written();
}

// ---------------------------------------------------------------- building tables

const TableBuilder = struct {
    arena: std.mem.Allocator,
    columns: []const []const u8,
    rows: std.ArrayList([]const Value) = .empty,

    fn add(self: *TableBuilder, values: anytype) !void {
        const row = try self.arena.alloc(Value, values.len);
        inline for (values, 0..) |value, index| row[index] = toValue(value);
        try self.rows.append(self.arena, row);
    }

    fn done(self: *TableBuilder) Table {
        return .{ .columns = self.columns, .rows = self.rows.items };
    }
};

fn toValue(value: anytype) Value {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .int, .comptime_int => .{ .int = @intCast(value) },
        .float, .comptime_float => .{ .float = value },
        .null => .null,
        .optional => if (value) |present| toValue(present) else .null,
        else => .{ .text = value },
    };
}

/// Runs a statement and keeps every cell with its SQLite type.
pub fn sqlTable(arena: std.mem.Allocator, statement: *db_mod.Statement) !Table {
    const c = db_mod.sqlite;
    const count = statement.columnCount();
    const columns = try arena.alloc([]const u8, count);
    for (columns, 0..) |*column, index| column.* = try arena.dupe(u8, statement.columnName(index));
    var rows: std.ArrayList([]const Value) = .empty;
    while (try statement.step() == .row) {
        const row = try arena.alloc(Value, count);
        for (row, 0..) |*cell, index| cell.* = switch (statement.columnType(index)) {
            c.SQLITE_NULL => .null,
            c.SQLITE_INTEGER => .{ .int = statement.columnInt(index) },
            c.SQLITE_FLOAT => .{ .float = statement.columnFloat(index) },
            else => .{ .text = try arena.dupe(u8, statement.columnText(index)) },
        };
        try rows.append(arena, row);
    }
    return .{ .columns = columns, .rows = rows.items };
}

// ---------------------------------------------------------------- summaries (data layer)

fn overviewReport(input: Input) !Table {
    const view_value = input.view;
    const range = view_value.range;
    const current = try data.totals(input.arena, input.db, view_value, range.start_ms, range.end_ms);
    const previous = try data.totals(input.arena, input.db, view_value, range.prev_start_ms, range.prev_end_ms);
    const sold = try customers.sales(input.arena, input.db, view_value, range.start_ms, range.end_ms);
    var table: TableBuilder = .{ .arena = input.arena, .columns = &.{ "from", "to", "page_views", "visitor_days", "sessions", "active_ms", "orders", "revenue_minor", "currency", "previous_page_views", "previous_visitor_days", "previous_sessions", "previous_active_ms" } };
    try table.add(.{ try input.arena.dupe(u8, &data.dateText(range.start_ms)), try input.arena.dupe(u8, &data.dateText(range.end_ms - 1)), current.views, current.visitor_days, current.sessions, current.active_ms, sold.orders, sold.revenue, view_value.site.currency, previous.views, previous.visitor_days, previous.sessions, previous.active_ms });
    return table.done();
}

fn breakdownReport(input: Input) !Table {
    const dim = std.meta.stringToEnum(data.Dim, input.get("dimension") orelse "page") orelse return error.InvalidParameter;
    var table: TableBuilder = .{ .arena = input.arena, .columns = &.{ "value", "page_views", "visitor_days", "previous_page_views" } };
    for (try data.top(input.arena, input.db, input.view, dim, @intCast(input.int("limit", 100, 1, 1000)))) |row| try table.add(.{ row.key, row.value, row.extra, row.previous });
    return table.done();
}

fn timeseriesReport(input: Input) !Table {
    const metric = std.meta.stringToEnum(data.Metric, input.get("metric") orelse "views") orelse return error.InvalidParameter;
    const range = input.view.range;
    var table: TableBuilder = .{ .arena = input.arena, .columns = &.{ "at", "value" } };
    for (try data.series(input.arena, input.db, input.view, metric, range.start_ms), 0..) |value, index| {
        const at = range.start_ms + @as(i64, @intCast(index)) * range.bucket_ms;
        const stamp = if (range.bucket_ms == data.hour_ms)
            try std.fmt.allocPrint(input.arena, "{s}T{d:0>2}:00Z", .{ &data.dateText(at), @as(u64, @intCast(@divFloor(@mod(at, data.day_ms), data.hour_ms))) })
        else
            try input.arena.dupe(u8, &data.dateText(at));
        try table.add(.{ stamp, @as(i64, @intFromFloat(@round(value))) });
    }
    return table.done();
}

fn goalsReport(input: Input) !Table {
    const goals = try input.db.all(input.arena, struct { name: []const u8, kind: []const u8, match: []const u8 }, "SELECT name,kind,match_value FROM goals WHERE site_id=? ORDER BY name", .{input.view.site.id});
    var table: TableBuilder = .{ .arena = input.arena, .columns = &.{ "goal", "kind", "match", "completions", "visitor_days" } };
    for (goals) |goal| {
        const counts = try data.goalCount(input.arena, input.db, input.view, goal.kind, goal.match, input.view.range.start_ms, input.view.range.end_ms, true);
        try table.add(.{ goal.name, goal.kind, goal.match, counts.completions, counts.visitor_days });
    }
    return table.done();
}

fn revenueReport(input: Input) !Table {
    var sql = data.Sql.init(input.arena);
    try sql.add("WITH it AS (SELECT e.name,i.item_id,i.name iname,i.price_minor,i.quantity,e.event_id FROM events e JOIN event_items i ON i.site_id=e.site_id AND i.event_id=e.event_id WHERE ");
    try sql.events(input.view, input.view.range.start_ms, input.view.range.end_ms);
    try sql.add(") SELECT item_id AS product_id,max(iname) AS product,sum(name='view_item') AS views,sum(name='add_to_cart') AS add_to_carts,count(DISTINCT CASE WHEN name IN " ++ customers.purchase_names ++ " THEN event_id END) AS orders,coalesce(sum(CASE WHEN name IN " ++ customers.purchase_names ++ " THEN coalesce(price_minor,0)*quantity END),0) AS revenue_minor,coalesce(sum(CASE WHEN name IN " ++ customers.refund_names ++ " THEN coalesce(price_minor,0)*quantity END),0) AS refunds_minor FROM it GROUP BY item_id ORDER BY 6 DESC,3 DESC LIMIT ");
    try sql.int(input.int("limit", 100, 1, 1000));
    var statement = try sql.prepare(input.db);
    defer statement.deinit();
    return sqlTable(input.arena, &statement);
}

fn errorsReport(input: Input) !Table {
    const unit = if (input.view.site.linked()) "coalesce(x.session_id,x.page_id)" else "x.page_id";
    var sql = data.Sql.init(input.arena);
    try sql.add("SELECT max(x.message) AS message,coalesce(max(x.file),'') AS file,coalesce(max(x.line),0) AS line,(SELECT y.path FROM errors y WHERE y.site_id=x.site_id AND y.fingerprint=x.fingerprint GROUP BY y.path ORDER BY count(*) DESC LIMIT 1) AS path,count(*) AS occurrences,count(DISTINCT ");
    try sql.add(unit);
    try sql.add(") AS visits,(SELECT min(y.received_at_ms) FROM errors y WHERE y.site_id=x.site_id AND y.fingerprint=x.fingerprint) AS first_seen_ms,max(x.received_at_ms) AS last_seen_ms,group_concat(DISTINCT x.browser) AS browsers FROM errors x WHERE ");
    try behaviour.errorScope(&sql, input.view, input.view.range.start_ms, input.view.range.end_ms);
    try sql.add(" GROUP BY x.fingerprint ORDER BY 6 DESC,5 DESC LIMIT ");
    try sql.int(input.int("limit", 100, 1, 1000));
    var statement = try sql.prepare(input.db);
    defer statement.deinit();
    return sqlTable(input.arena, &statement);
}

fn searchReport(input: Input) !Table {
    var sql = data.Sql.init(input.arena);
    try sql.add("SELECT pv.search_term AS term,count(*) AS searches,sum(pv.search_results=0) AS no_results,count(DISTINCT pv.visitor_day_id) AS visitor_days FROM page_views pv WHERE ");
    try sql.pageViews(input.view, input.view.range.start_ms, input.view.range.end_ms);
    try sql.add(" AND pv.search_term IS NOT NULL GROUP BY 1 ORDER BY 2 DESC LIMIT ");
    try sql.int(input.int("limit", 100, 1, 1000));
    var statement = try sql.prepare(input.db);
    defer statement.deinit();
    return sqlTable(input.arena, &statement);
}

fn funnelReport(input: Input) !Table {
    const name = input.get("name").?;
    try domain.validateName(name);
    const funnel = try input.db.one(input.arena, struct { id: i64, window_ms: i64 }, "SELECT id,window_ms FROM funnels WHERE site_id=? AND name=?", .{ input.view.site.id, name }) orelse return error.InvalidParameter;
    const steps = try input.db.all(input.arena, struct { kind: []const u8, value: []const u8 }, "SELECT kind,match_value FROM funnel_steps WHERE funnel_id=? ORDER BY step_index", .{funnel.id});
    if (steps.len < 2) return error.InvalidParameter;
    const counts = try input.arena.alloc(i64, steps.len);
    @memset(counts, 0);
    const Progress = struct { next_step: usize, started_at_ms: i64 };
    var progress: std.StringHashMapUnmanaged(Progress) = .empty;
    var timeline = try input.db.prepare(input.arena,
    \\SELECT session_id,occurred_at_ms,kind,value FROM (
    \\ SELECT session_id,occurred_at_ms,'path' kind,path value FROM page_views
    \\ WHERE internal=0 AND traffic_class IN ('human_like','unknown') AND site_id=?1 AND received_at_ms>=?2 AND received_at_ms<?3 AND session_id IS NOT NULL
    \\ UNION ALL SELECT session_id,occurred_at_ms,'event',name FROM events
    \\ WHERE internal=0 AND site_id=?1 AND received_at_ms>=?2 AND received_at_ms<?3 AND session_id IS NOT NULL
    \\ AND (source='server' OR traffic_class IN ('human_like','unknown'))
    \\) ORDER BY session_id,occurred_at_ms
    );
    defer timeline.deinit();
    try timeline.bindAll(.{ input.view.site.id, input.view.range.start_ms, input.view.range.end_ms });
    while (try timeline.step() == .row) {
        const session = timeline.columnText(0);
        const occurred = timeline.columnInt(1);
        const kind = timeline.columnText(2);
        const value = timeline.columnText(3);
        if (progress.getPtr(session)) |state| {
            if (state.next_step >= steps.len or occurred - state.started_at_ms > funnel.window_ms) continue;
            const expected = steps[state.next_step];
            if (std.mem.eql(u8, kind, expected.kind) and std.mem.eql(u8, value, expected.value)) {
                counts[state.next_step] += 1;
                state.next_step += 1;
            }
        } else if (std.mem.eql(u8, kind, steps[0].kind) and std.mem.eql(u8, value, steps[0].value)) {
            counts[0] += 1;
            try progress.put(input.arena, try input.arena.dupe(u8, session), .{ .next_step = 1, .started_at_ms = occurred });
        }
    }
    var table: TableBuilder = .{ .arena = input.arena, .columns = &.{ "step", "kind", "match", "sessions", "step_conversion_percent", "overall_conversion_percent" } };
    for (steps, 0..) |step, index| {
        const prior = if (index == 0) counts[0] else counts[index - 1];
        const step_percent = if (prior == 0) 0.0 else @round(1000.0 * @as(f64, @floatFromInt(counts[index])) / @as(f64, @floatFromInt(prior))) / 10;
        const overall = if (counts[0] == 0) 0.0 else @round(1000.0 * @as(f64, @floatFromInt(counts[index])) / @as(f64, @floatFromInt(counts[0]))) / 10;
        try table.add(.{ index + 1, step.kind, step.value, counts[index], step_percent, overall });
    }
    return table.done();
}

// ---------------------------------------------------------------- detailed exports (raw rows)

/// The detailed exports filter by page, campaign and release (?4–?9).
const Scoped = struct { release: []const u8 = "", campaign: []const u8 = "", path: []const u8 = "" };

fn scoped(input: Input) !Scoped {
    var out: Scoped = .{};
    for (input.view.filters) |filter| {
        if (filter.negate) return error.UnsupportedFilter;
        switch (filter.dim) {
            .page => out.path = filter.value,
            .campaign => out.campaign = filter.value,
            .release => out.release = filter.value,
            else => return error.UnsupportedFilter,
        }
    }
    return out;
}

fn legacy(input: Input, sql: []const u8) !Table {
    const scope = try scoped(input);
    var statement = try input.db.prepare(input.arena, sql);
    defer statement.deinit();
    try statement.bindAll(.{ input.view.site.id, input.view.range.start_ms, input.view.range.end_ms, scope.release, scope.release, scope.campaign, scope.campaign, scope.path, scope.path, input.int("limit", 100, 1, 1000) });
    return sqlTable(input.arena, &statement);
}

fn pagesReport(input: Input) !Table {
    return legacy(input, pages_sql);
}
fn acquisitionReport(input: Input) !Table {
    return legacy(input, acquisition_sql);
}
fn campaignsReport(input: Input) !Table {
    return legacy(input, campaigns_sql);
}
fn eventsReport(input: Input) !Table {
    return legacy(input, events_sql);
}
fn sectionsReport(input: Input) !Table {
    return legacy(input, sections_sql);
}
fn actionsReport(input: Input) !Table {
    return legacy(input, actions_sql);
}
fn recentReport(input: Input) !Table {
    return legacy(input, recent_sql);
}
fn coverageReport(input: Input) !Table {
    return legacy(input, coverage_sql);
}
fn trafficReport(input: Input) !Table {
    return legacy(input, traffic_sql);
}
fn performanceReport(input: Input) !Table {
    return legacy(input, performance_sql);
}

fn sessionsReport(input: Input) !Table {
    var statement = try input.db.prepare(input.arena, sessions_sql);
    defer statement.deinit();
    try statement.bindAll(.{ input.view.site.id, input.view.range.start_ms, input.view.range.end_ms, input.int("limit", 100, 1, 1000) });
    return sqlTable(input.arena, &statement);
}

fn sessionReport(input: Input) !Table {
    const id = input.get("id").?;
    try domain.validateUuid(id);
    var statement = try input.db.prepare(input.arena, session_sql);
    defer statement.deinit();
    try statement.bindAll(.{ input.view.site.id, id });
    return sqlTable(input.arena, &statement);
}

fn flowReport(input: Input) !Table {
    const flow = input.get("flow").?;
    try domain.validateName(flow);
    var statement = try input.db.prepare(input.arena, flow_sql);
    defer statement.deinit();
    try statement.bindAll(.{ input.view.site.id, input.view.range.start_ms, input.view.range.end_ms, flow, input.int("limit", 100, 1, 1000) });
    return sqlTable(input.arena, &statement);
}

fn frictionReport(input: Input) !Table {
    const flow = input.get("flow") orelse "";
    if (flow.len != 0) try domain.validateName(flow);
    var statement = try input.db.prepare(input.arena, friction_sql);
    defer statement.deinit();
    try statement.bindAll(.{ input.view.site.id, input.view.range.start_ms, input.view.range.end_ms, flow, input.int("limit", 100, 1, 1000) });
    return sqlTable(input.arena, &statement);
}

fn pathsReport(input: Input) !Table {
    const from_path = input.get("from_path").?;
    try domain.validatePath(from_path);
    // Whole days come from the daily summaries, like the workspace's paths.
    const next = try @import("journeys.zig").nextSteps(input.arena, input.db, input.view, from_path, input.int("limit", 100, 1, 1000) + 1);
    var table: TableBuilder = .{ .arena = input.arena, .columns = &.{ "from_path", "next_path", "transitions" } };
    for (next.steps) |step| {
        // The catalog has always listed only steps to another page.
        if (step.path.len != 0) try table.add(.{ from_path, step.path, step.count });
    }
    return table.done();
}

fn economicsReport(input: Input) !Table {
    const scope = try scoped(input);
    var statement = try input.db.prepare(input.arena, economics_sql);
    defer statement.deinit();
    try statement.bindAll(.{ input.view.site.id, input.view.range.start_ms, input.view.range.end_ms, scope.campaign, input.int("limit", 100, 1, 1000) });
    return sqlTable(input.arena, &statement);
}

const pages_sql =
    \\SELECT pv.path,coalesce(max(pv.page_type),'') AS page_type,coalesce(max(pv.content_id),'') AS content_id,
    \\ count(*) AS views,count(DISTINCT pv.visitor_day_id) AS visitors,
    \\ coalesce(round(avg(ps.visible_ms)),0) AS avg_visible_ms,coalesce(round(avg(ps.active_ms)),0) AS avg_active_ms,
    \\ coalesce(round(avg(ps.first_interaction_ms)),0) AS avg_first_interaction_ms,
    \\ coalesce(round(avg(ps.max_scroll)),0) AS avg_scroll,coalesce(sum(ps.copy_count),0) AS copies,
    \\ coalesce(sum(ps.outbound_clicks),0) AS outbound_clicks,coalesce(sum(ps.downloads),0) AS downloads,
    \\ coalesce(sum(ps.form_attempts),0) AS form_attempts
    \\FROM page_views pv LEFT JOIN page_summaries ps ON ps.site_id=pv.site_id AND ps.page_id=pv.page_id
    \\WHERE pv.internal=0 AND pv.traffic_class IN ('human_like','unknown') AND pv.site_id=? AND pv.received_at_ms>=? AND pv.received_at_ms<?
    \\AND (?='' OR coalesce(pv.release_id,'')=?) AND (?='' OR coalesce(pv.utm_campaign,'')=?) AND (?='' OR pv.path=?)
    \\GROUP BY pv.path ORDER BY views DESC,pv.path LIMIT ?
;
const acquisition_sql =
    \\SELECT coalesce(nullif(pv.utm_source,''),nullif(pv.referrer_host,''),'direct') AS source,
    \\ coalesce(nullif(pv.utm_medium,''),'') AS medium,count(*) AS views,
    \\ count(DISTINCT pv.visitor_day_id) AS visitors
    \\FROM page_views pv WHERE pv.internal=0 AND pv.traffic_class IN ('human_like','unknown') AND pv.site_id=? AND pv.received_at_ms>=? AND pv.received_at_ms<?
    \\AND (?='' OR coalesce(pv.release_id,'')=?) AND (?='' OR coalesce(pv.utm_campaign,'')=?) AND (?='' OR pv.path=?)
    \\GROUP BY source,medium ORDER BY views DESC,source LIMIT ?
;
const campaigns_sql =
    \\SELECT coalesce(pv.utm_source,'') AS source,coalesce(pv.utm_campaign,'') AS campaign,
    \\ coalesce(pv.utm_content,'') AS content,count(*) AS views,
    \\ count(DISTINCT pv.visitor_day_id) AS visitors,count(DISTINCT pv.session_id) AS sessions
    \\FROM page_views pv WHERE pv.internal=0 AND pv.traffic_class IN ('human_like','unknown') AND pv.site_id=? AND pv.received_at_ms>=? AND pv.received_at_ms<?
    \\AND (?='' OR coalesce(pv.release_id,'')=?) AND (?='' OR coalesce(pv.utm_campaign,'')=?) AND (?='' OR pv.path=?)
    \\AND pv.utm_campaign IS NOT NULL GROUP BY source,campaign,content ORDER BY views DESC LIMIT ?
;
const sections_sql =
    \\WITH filtered AS (
    \\ SELECT pv.site_id,pv.page_id FROM page_views pv WHERE pv.internal=0 AND pv.traffic_class IN ('human_like','unknown')
    \\ AND pv.site_id=?1 AND pv.received_at_ms>=?2 AND pv.received_at_ms<?3
    \\ AND (?4='' OR coalesce(pv.release_id,'')=?5) AND (?6='' OR coalesce(pv.utm_campaign,'')=?7) AND (?8='' OR pv.path=?9)
    \\), summaries AS (
    \\ SELECT ps.* FROM page_summaries ps JOIN filtered f ON f.site_id=ps.site_id AND f.page_id=ps.page_id
    \\)
    \\SELECT j.value AS section,count(*) AS exposures,
    \\ round(100.0*count(*)/max(1,(SELECT count(*) FROM filtered)),1) AS exposure_percent,
    \\ sum(CASE WHEN ps.last_section=j.value THEN 1 ELSE 0 END) AS final_section
    \\FROM summaries ps, json_each(ps.sections_json) j
    \\GROUP BY j.value ORDER BY exposures DESC,j.value LIMIT ?10
;
const actions_sql =
    \\SELECT e.name,coalesce(json_extract(e.properties_json,'$.action'),'') AS action,count(*) AS occurrences
    \\FROM events e WHERE e.internal=0 AND e.site_id=? AND e.received_at_ms>=? AND e.received_at_ms<? AND (e.source='server' OR e.traffic_class IN ('human_like','unknown'))
    \\AND (?='' OR coalesce(e.release_id,'')=?) AND (?='' OR coalesce(json_extract(e.properties_json,'$.campaign'),'')=?) AND (?='' OR coalesce(e.path,'')=?)
    \\AND (e.name LIKE 'action_%' OR e.name='rage_click') GROUP BY e.name,action ORDER BY occurrences DESC LIMIT ?
;
const events_sql =
    \\SELECT e.name,e.source,count(*) AS occurrences,count(DISTINCT e.session_id) AS sessions,
    \\ coalesce(sum(e.value_minor),0) AS value_minor,max(coalesce(e.currency,'')) AS currency
    \\FROM events e WHERE e.internal=0 AND e.site_id=? AND e.received_at_ms>=? AND e.received_at_ms<? AND (e.source='server' OR e.traffic_class IN ('human_like','unknown'))
    \\AND (?='' OR coalesce(e.release_id,'')=?) AND (?='' OR coalesce(json_extract(e.properties_json,'$.campaign'),'')=?) AND (?='' OR coalesce(e.path,'')=?)
    \\GROUP BY e.name,e.source ORDER BY occurrences DESC,e.name LIMIT ?
;
const recent_sql =
    \\SELECT received_at_ms,kind,name,path,source,session_id FROM (
    \\ SELECT pv.received_at_ms,'page_view' AS kind,'page_view' AS name,pv.path,'browser' AS source,pv.session_id,pv.release_id,pv.utm_campaign
    \\ FROM page_views pv WHERE pv.internal=0 AND pv.traffic_class IN ('human_like','unknown') AND pv.site_id=?1 AND pv.received_at_ms>=?2 AND pv.received_at_ms<?3
    \\ UNION ALL SELECT e.received_at_ms,'event',e.name,coalesce(e.path,''),e.source,e.session_id,e.release_id,json_extract(e.properties_json,'$.campaign')
    \\ FROM events e WHERE e.internal=0 AND e.site_id=?1 AND e.received_at_ms>=?2 AND e.received_at_ms<?3 AND (e.source='server' OR e.traffic_class IN ('human_like','unknown'))
    \\) WHERE (?4='' OR coalesce(release_id,'')=?5) AND (?6='' OR coalesce(utm_campaign,'')=?7) AND (?8='' OR path=?9)
    \\ORDER BY received_at_ms DESC LIMIT ?10
;
const coverage_sql =
    \\WITH pv AS (SELECT * FROM page_views WHERE site_id=?1 AND received_at_ms>=?2 AND received_at_ms<?3
    \\ AND (?4='' OR coalesce(release_id,'')=?5) AND (?6='' OR coalesce(utm_campaign,'')=?7) AND (?8='' OR path=?9))
    \\SELECT count(*) AS page_views,
    \\ (SELECT count(*) FROM page_summaries ps JOIN pv ON pv.site_id=ps.site_id AND pv.page_id=ps.page_id) AS summaries,
    \\ round(100.0*(SELECT count(*) FROM page_summaries ps JOIN pv ON pv.site_id=ps.site_id AND pv.page_id=ps.page_id)/max(1,count(*)),1) AS summary_percent,
    \\ sum(CASE WHEN traffic_class='unknown' THEN 1 ELSE 0 END) AS unknown_traffic,
    \\ sum(CASE WHEN session_id IS NOT NULL THEN 1 ELSE 0 END) AS session_identified,
    \\ sum(CASE WHEN internal=1 THEN 1 ELSE 0 END) AS internal_page_views,
    \\ (SELECT count(*) FROM page_summaries ps JOIN pv ON pv.site_id=ps.site_id AND pv.page_id=ps.page_id WHERE ps.lcp_ms IS NOT NULL) AS rum_samples
    \\FROM pv LIMIT ?10
;
const traffic_sql =
    \\SELECT pv.traffic_class,pv.internal,count(*) AS page_views,count(DISTINCT pv.visitor_day_id) AS visitors
    \\FROM page_views pv WHERE pv.site_id=?1 AND pv.received_at_ms>=?2 AND pv.received_at_ms<?3
    \\AND (?4='' OR coalesce(pv.release_id,'')=?5) AND (?6='' OR coalesce(pv.utm_campaign,'')=?7) AND (?8='' OR pv.path=?9)
    \\GROUP BY pv.traffic_class,pv.internal ORDER BY page_views DESC,pv.traffic_class LIMIT ?10
;
const performance_sql =
    \\WITH base AS (
    \\ SELECT coalesce(pv.page_type,'') AS page_type,coalesce(pv.release_id,'') AS release_id,
    \\ coalesce(pv.navigation_type,'') AS navigation_type,pv.device,ps.*
    \\ FROM page_views pv JOIN page_summaries ps ON ps.site_id=pv.site_id AND ps.page_id=pv.page_id
    \\ WHERE pv.internal=0 AND pv.traffic_class IN ('human_like','unknown') AND pv.site_id=?1 AND pv.received_at_ms>=?2 AND pv.received_at_ms<?3
    \\ AND (?4='' OR coalesce(pv.release_id,'')=?5) AND (?6='' OR coalesce(pv.utm_campaign,'')=?7) AND (?8='' OR pv.path=?9)
    \\), samples AS (
    \\ SELECT page_type,release_id,navigation_type,device,'ttfb' metric,ttfb_ms value FROM base WHERE ttfb_ms IS NOT NULL UNION ALL
    \\ SELECT page_type,release_id,navigation_type,device,'fcp',fcp_ms FROM base WHERE fcp_ms IS NOT NULL UNION ALL
    \\ SELECT page_type,release_id,navigation_type,device,'lcp',lcp_ms FROM base WHERE lcp_ms IS NOT NULL UNION ALL
    \\ SELECT page_type,release_id,navigation_type,device,'inp',inp_ms FROM base WHERE inp_ms IS NOT NULL UNION ALL
    \\ SELECT page_type,release_id,navigation_type,device,'cls_milli',cls_milli FROM base WHERE cls_milli IS NOT NULL UNION ALL
    \\ SELECT page_type,release_id,navigation_type,device,'long_frame_count',long_frame_count FROM base WHERE long_frame_count IS NOT NULL UNION ALL
    \\ SELECT page_type,release_id,navigation_type,device,'blocking_ms',blocking_ms FROM base WHERE blocking_ms IS NOT NULL
    \\), ranked AS (
    \\ SELECT *,row_number() OVER(PARTITION BY page_type,release_id,navigation_type,device,metric ORDER BY value) rn,
    \\ count(*) OVER(PARTITION BY page_type,release_id,navigation_type,device,metric) n FROM samples
    \\)
    \\SELECT page_type,release_id,navigation_type,device,metric,max(n) samples,
    \\ min(CASE WHEN rn*100>=n*50 THEN value END) p50,
    \\ min(CASE WHEN rn*100>=n*75 THEN value END) p75,
    \\ min(CASE WHEN rn*100>=n*95 THEN value END) p95
    \\FROM ranked GROUP BY page_type,release_id,navigation_type,device,metric
    \\ORDER BY page_type,release_id,navigation_type,device,metric LIMIT ?10
;
const sessions_sql =
    \\SELECT pv.session_id,min(pv.received_at_ms) AS started_at_ms,max(pv.received_at_ms) AS ended_at_ms,
    \\ max(pv.received_at_ms)-min(pv.received_at_ms) AS duration_ms,count(*) AS page_views,
    \\ count(DISTINCT pv.path) AS distinct_pages,
    \\ (SELECT count(*) FROM events e WHERE e.internal=0 AND e.site_id=pv.site_id AND e.session_id=pv.session_id AND e.received_at_ms>=?2 AND e.received_at_ms<?3) AS events,
    \\ (SELECT x.path FROM page_views x WHERE x.internal=0 AND x.site_id=pv.site_id AND x.session_id=pv.session_id ORDER BY x.received_at_ms LIMIT 1) AS landing_path,
    \\ (SELECT x.path FROM page_views x WHERE x.internal=0 AND x.site_id=pv.site_id AND x.session_id=pv.session_id ORDER BY x.received_at_ms DESC LIMIT 1) AS exit_path
    \\FROM page_views pv WHERE pv.internal=0 AND pv.traffic_class IN ('human_like','unknown') AND pv.site_id=?1 AND pv.received_at_ms>=?2 AND pv.received_at_ms<?3 AND pv.session_id IS NOT NULL
    \\GROUP BY pv.site_id,pv.session_id ORDER BY ended_at_ms DESC LIMIT ?4
;
const session_sql =
    \\SELECT occurred_at_ms,received_at_ms,kind,name,path,properties_json FROM (
    \\ SELECT occurred_at_ms,received_at_ms,'page_view' kind,'page_view' name,path,'{}' properties_json
    \\ FROM page_views WHERE internal=0 AND traffic_class IN ('human_like','unknown') AND site_id=?1 AND session_id=?2
    \\ UNION ALL SELECT occurred_at_ms,received_at_ms,'event',name,coalesce(path,''),properties_json
    \\ FROM events e WHERE e.internal=0 AND e.site_id=?1 AND e.session_id=?2 AND (e.source='server' OR e.traffic_class IN ('human_like','unknown'))
    \\) ORDER BY occurred_at_ms,received_at_ms LIMIT 1000
;
const flow_sql =
    \\WITH matched AS (
    \\ SELECT e.* FROM events e WHERE e.internal=0 AND e.site_id=?1 AND e.received_at_ms>=?2 AND e.received_at_ms<?3 AND (e.source='server' OR e.traffic_class IN ('human_like','unknown'))
    \\ AND json_extract(e.properties_json,'$.flow')=?4 AND e.name LIKE 'flow_%'
    \\), actual AS (
    \\ SELECT name,coalesce(json_extract(properties_json,'$.step'),'') step,count(*) occurrences,
    \\ count(DISTINCT session_id) sessions,min(received_at_ms) first_at FROM matched GROUP BY name,step
    \\), session_last AS (
    \\ SELECT session_id,max(received_at_ms) last_at FROM (
    \\  SELECT session_id,received_at_ms FROM page_views WHERE internal=0 AND traffic_class IN ('human_like','unknown') AND site_id=?1 AND received_at_ms>=?2 AND received_at_ms<?3 AND session_id IS NOT NULL
    \\  UNION ALL SELECT e.session_id,e.received_at_ms FROM events e WHERE e.internal=0 AND e.site_id=?1 AND e.received_at_ms>=?2 AND e.received_at_ms<?3 AND e.session_id IS NOT NULL AND (e.source='server' OR e.traffic_class IN ('human_like','unknown'))
    \\ ) GROUP BY session_id
    \\), abandoned AS (
    \\ SELECT 'flow_abandoned' name,'' step,count(*) occurrences,count(*) sessions,9223372036854775807 first_at
    \\ FROM (SELECT DISTINCT m.session_id FROM matched m JOIN session_last s ON s.session_id=m.session_id
    \\ WHERE m.name='flow_started' AND m.session_id IS NOT NULL AND s.last_at<unixepoch('subsec')*1000-1800000
    \\ AND NOT EXISTS (SELECT 1 FROM matched done WHERE done.session_id=m.session_id AND done.name='flow_completed'))
    \\)
    \\SELECT name,step,occurrences,sessions FROM (SELECT * FROM actual UNION ALL SELECT * FROM abandoned WHERE sessions>0)
    \\ORDER BY first_at,name,step LIMIT ?5
;
const friction_sql =
    \\SELECT e.name,coalesce(json_extract(e.properties_json,'$.step'),'') AS step,
    \\ coalesce(json_extract(e.properties_json,'$.action'),'') AS action,
    \\ coalesce(json_extract(e.properties_json,'$.error'),'') AS error_code,
    \\ coalesce(json_extract(e.properties_json,'$.attempt_bucket'),'') AS attempt_bucket,
    \\ coalesce(json_extract(e.properties_json,'$.dwell_bucket'),'') AS dwell_bucket,
    \\ coalesce(json_extract(e.properties_json,'$.click_bucket'),'') AS click_bucket,count(*) AS occurrences,
    \\ count(DISTINCT e.session_id) AS sessions
    \\FROM events e WHERE e.internal=0 AND e.site_id=?1 AND e.received_at_ms>=?2 AND e.received_at_ms<?3 AND (e.source='server' OR e.traffic_class IN ('human_like','unknown'))
    \\AND (?4='' OR json_extract(e.properties_json,'$.flow')=?4)
    \\AND e.name IN ('flow_step_failed','flow_backtracked','action_failed','action_unresponsive','rage_click')
    \\GROUP BY e.name,step,action,error_code,attempt_bucket,dwell_bucket,click_bucket ORDER BY occurrences DESC LIMIT ?5
;
const economics_sql =
    \\WITH cs AS MATERIALIZED (
    \\ SELECT session_id,max(coalesce(utm_source,'')) source,max(coalesce(utm_campaign,'')) campaign,max(coalesce(utm_content,'')) content
    \\ FROM page_views WHERE internal=0 AND traffic_class IN ('human_like','unknown') AND site_id=?1 AND received_at_ms>=?2 AND received_at_ms<?3 AND session_id IS NOT NULL AND utm_campaign IS NOT NULL
    \\ GROUP BY session_id
    \\), engaged AS (
    \\ SELECT DISTINCT session_id FROM page_views WHERE site_id=?1 AND received_at_ms>=?2 AND received_at_ms<?3 AND session_id IN (SELECT session_id FROM cs)
    \\ AND (active_ms>=10000 OR max_scroll>=50 OR interaction_count>0)
    \\), starts AS (
    \\ SELECT DISTINCT session_id FROM events WHERE internal=0 AND site_id=?1 AND name='registration_started' AND received_at_ms>=?2 AND received_at_ms<?3 AND session_id IN (SELECT session_id FROM cs)
    \\), sessions AS (
    \\ SELECT source,campaign,content,count(*) landing_sessions,sum(session_id IN (SELECT session_id FROM engaged)) engaged_sessions,
    \\ sum(session_id IN (SELECT session_id FROM starts)) registration_starts FROM cs GROUP BY 1,2,3
    \\), ev AS MATERIALIZED (
    \\ SELECT name,source origin,coalesce(json_extract(properties_json,'$.source'),'') source,coalesce(json_extract(properties_json,'$.campaign'),'') campaign,
    \\ coalesce(json_extract(properties_json,'$.content'),'') content,value_minor,currency
    \\ FROM events WHERE internal=0 AND site_id=?1 AND received_at_ms>=?2 AND received_at_ms<?3 AND json_extract(properties_json,'$.campaign') IS NOT NULL
    \\), outcomes AS (
    \\ SELECT source,campaign,content,sum(name='registration_confirmed') registrations,sum(name='payment_confirmed') paid_registrations,
    \\ sum(name IN ('payment_refunded','refund_confirmed')) refunds,sum(name='attendance_confirmed') attendees,
    \\ coalesce(sum(CASE WHEN name='payment_confirmed' THEN value_minor END),0)-coalesce(sum(CASE WHEN name IN ('payment_refunded','refund_confirmed') THEN value_minor END),0) revenue_minor,
    \\ max(currency) currency FROM ev GROUP BY 1,2,3
    \\), spend AS (
    \\ SELECT source,campaign,content,sum(amount_minor) spend_minor FROM campaign_spend WHERE site_id=?1 AND unixepoch(spend_date)*1000>=?2 AND unixepoch(spend_date)*1000<?3 GROUP BY 1,2,3
    \\), spend_currency AS (
    \\ SELECT source,campaign,content,max(currency) currency FROM campaign_spend WHERE site_id=?1 GROUP BY 1,2,3
    \\), keys AS (
    \\ SELECT source,campaign,content FROM cs UNION SELECT source,campaign,content FROM spend UNION SELECT source,campaign,content FROM ev WHERE origin='server'
    \\), facts AS (
    \\SELECT k.source,k.campaign,k.content,coalesce(sp.spend_minor,0) spend_minor,coalesce(sc.currency,o.currency,'') currency,
    \\ coalesce(se.landing_sessions,0) landing_sessions,coalesce(se.engaged_sessions,0) engaged_sessions,coalesce(se.registration_starts,0) registration_starts,
    \\ coalesce(o.registrations,0) registrations,coalesce(o.paid_registrations,0) paid_registrations,coalesce(o.refunds,0) refunds,
    \\ coalesce(o.attendees,0) attendees,coalesce(o.revenue_minor,0) revenue_minor
    \\FROM keys k LEFT JOIN spend sp USING(source,campaign,content) LEFT JOIN spend_currency sc USING(source,campaign,content)
    \\ LEFT JOIN sessions se USING(source,campaign,content) LEFT JOIN outcomes o USING(source,campaign,content)
    \\WHERE k.campaign<>'' AND (?4='' OR k.campaign=?4)
    \\)
    \\SELECT *,
    \\ CASE WHEN registration_starts>0 THEN spend_minor/registration_starts END cost_per_start_minor,
    \\ CASE WHEN paid_registrations>0 THEN spend_minor/paid_registrations END cost_per_paid_minor,
    \\ CASE WHEN attendees>0 THEN spend_minor/attendees END cost_per_attendee_minor,
    \\ CASE WHEN spend_minor>0 THEN round(1.0*revenue_minor/spend_minor,3) END roas
    \\FROM facts ORDER BY revenue_minor DESC,campaign LIMIT ?5
;

test "every report has a unique name and a valid schema" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    for (&reports, 0..) |*report, index| {
        for (reports[index + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, report.name, other.name));
        for ([_]bool{ true, false }) |site| {
            var out: std.Io.Writer.Allocating = .init(arena_state.allocator());
            try schema(&out.writer, report, site);
            _ = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), out.written(), .{});
        }
    }
}
