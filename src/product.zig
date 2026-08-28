const std = @import("std");
const domain = @import("domain.zig");
const reports = @import("reports.zig");
const store_mod = @import("store.zig");

pub fn goalAdd(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    store: *store_mod.Store,
    site_id: i64,
    name: []const u8,
    kind: []const u8,
    match_value: []const u8,
) !void {
    try domain.validateName(name);
    try validateStep(kind, match_value);
    var statement = try store.database.prepare(allocator, "INSERT INTO goals(site_id,name,kind,match_value,created_at_ms) VALUES(?,?,?,?,?)");
    defer statement.deinit();
    try statement.bindInt(1, site_id);
    try statement.bindText(2, name);
    try statement.bindText(3, kind);
    try statement.bindText(4, match_value);
    try statement.bindInt(5, try domain.nowMilliseconds());
    _ = try statement.step();
    try output.print("goal added name={s} kind={s} match={s}\n", .{ name, kind, match_value });
}

pub fn goalList(allocator: std.mem.Allocator, output: *std.Io.Writer, store: *store_mod.Store, site_id: i64) !void {
    var statement = try store.database.prepare(allocator, "SELECT name,kind,match_value FROM goals WHERE site_id=? ORDER BY name");
    defer statement.deinit();
    try statement.bindInt(1, site_id);
    try reports.writeRows(output, &statement, .table);
}

pub fn funnelAdd(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    store: *store_mod.Store,
    site_id: i64,
    name: []const u8,
    raw_steps: []const []const u8,
) !void {
    try domain.validateName(name);
    if (raw_steps.len < 2 or raw_steps.len > 16) return error.InvalidFunnelStepCount;
    const now = try domain.nowMilliseconds();
    try store.database.exec("BEGIN IMMEDIATE");
    errdefer store.database.exec("ROLLBACK") catch {};
    var insert = try store.database.prepare(allocator, "INSERT INTO funnels(site_id,name,created_at_ms) VALUES(?,?,?)");
    defer insert.deinit();
    try insert.bindInt(1, site_id);
    try insert.bindText(2, name);
    try insert.bindInt(3, now);
    _ = try insert.step();
    const funnel_id = store.database.lastInsertRowId();
    var step_insert = try store.database.prepare(allocator, "INSERT INTO funnel_steps(funnel_id,step_index,kind,match_value) VALUES(?,?,?,?)");
    defer step_insert.deinit();
    for (raw_steps, 0..) |raw, index| {
        const resolved = try resolveStep(allocator, store, site_id, raw);
        try step_insert.bindInt(1, funnel_id);
        try step_insert.bindInt(2, @intCast(index));
        try step_insert.bindText(3, resolved.kind);
        try step_insert.bindText(4, resolved.value);
        _ = try step_insert.step();
        try step_insert.reset();
    }
    try store.database.exec("COMMIT");
    try output.print("funnel added name={s} steps={d}\n", .{ name, raw_steps.len });
}

pub fn funnelList(allocator: std.mem.Allocator, output: *std.Io.Writer, store: *store_mod.Store, site_id: i64) !void {
    var statement = try store.database.prepare(allocator, "SELECT f.name,count(s.step_index) steps,f.window_ms FROM funnels f JOIN funnel_steps s ON s.funnel_id=f.id WHERE f.site_id=? GROUP BY f.id ORDER BY f.name");
    defer statement.deinit();
    try statement.bindInt(1, site_id);
    try reports.writeRows(output, &statement, .table);
}

const Step = struct { kind: []u8, value: []u8 };
const Progress = struct { next_step: usize, started_at_ms: i64 };

pub fn funnelShow(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    store: *store_mod.Store,
    site_id: i64,
    name: []const u8,
    options_value: reports.Options,
) !void {
    try domain.validateName(name);
    var funnel = try store.database.prepare(allocator, "SELECT id,window_ms FROM funnels WHERE site_id=? AND name=?");
    defer funnel.deinit();
    try funnel.bindInt(1, site_id);
    try funnel.bindText(2, name);
    if (try funnel.step() != .row) return error.UnknownFunnel;
    const funnel_id = funnel.columnInt(0);
    const window_ms = funnel.columnInt(1);
    var step_query = try store.database.prepare(allocator, "SELECT kind,match_value FROM funnel_steps WHERE funnel_id=? ORDER BY step_index");
    defer step_query.deinit();
    try step_query.bindInt(1, funnel_id);
    var steps: std.ArrayList(Step) = .empty;
    while (try step_query.step() == .row) try steps.append(allocator, .{
        .kind = try allocator.dupe(u8, step_query.columnText(0)),
        .value = try allocator.dupe(u8, step_query.columnText(1)),
    });
    if (steps.items.len < 2) return error.CorruptFunnel;
    const counts = try allocator.alloc(i64, steps.items.len);
    @memset(counts, 0);
    var progress = std.StringHashMap(Progress).init(allocator);
    var timeline = try store.database.prepare(allocator,
        \\SELECT session_id,occurred_at_ms,kind,value FROM (
        \\ SELECT session_id,occurred_at_ms,'path' kind,path value FROM page_views
        \\ WHERE internal=0 AND traffic_class IN ('human_like','unknown') AND site_id=?1 AND received_at_ms>=?2 AND received_at_ms<?3 AND session_id IS NOT NULL
        \\ UNION ALL SELECT session_id,occurred_at_ms,'event',name FROM events
        \\ WHERE internal=0 AND site_id=?1 AND received_at_ms>=?2 AND received_at_ms<?3 AND session_id IS NOT NULL
        \\ AND (source='server' OR EXISTS(SELECT 1 FROM page_views p WHERE p.site_id=events.site_id AND p.page_id=events.page_id AND p.traffic_class IN ('human_like','unknown')))
        \\) ORDER BY session_id,occurred_at_ms
    );
    defer timeline.deinit();
    try timeline.bindInt(1, site_id);
    try timeline.bindInt(2, options_value.start_ms);
    try timeline.bindInt(3, options_value.end_ms);
    while (try timeline.step() == .row) {
        const session = timeline.columnText(0);
        const occurred = timeline.columnInt(1);
        const kind = timeline.columnText(2);
        const value = timeline.columnText(3);
        if (progress.getPtr(session)) |state| {
            if (state.next_step >= steps.items.len or occurred - state.started_at_ms > window_ms) continue;
            const expected = steps.items[state.next_step];
            if (std.mem.eql(u8, kind, expected.kind) and std.mem.eql(u8, value, expected.value)) {
                counts[state.next_step] += 1;
                state.next_step += 1;
            }
        } else {
            const first = steps.items[0];
            if (std.mem.eql(u8, kind, first.kind) and std.mem.eql(u8, value, first.value)) {
                counts[0] += 1;
                try progress.put(try allocator.dupe(u8, session), .{ .next_step = 1, .started_at_ms = occurred });
            }
        }
    }
    switch (options_value.format) {
        .table, .csv => {
            const sep: u8 = if (options_value.format == .csv) ',' else '\t';
            try output.print("step{c}kind{c}match{c}sessions{c}step_conversion_percent{c}overall_conversion_percent\n", .{ sep, sep, sep, sep, sep });
            for (steps.items, 0..) |step, index| {
                const prior = if (index == 0) counts[0] else counts[index - 1];
                const step_percent = if (prior == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(counts[index])) / @as(f64, @floatFromInt(prior));
                const overall = if (counts[0] == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(counts[index])) / @as(f64, @floatFromInt(counts[0]));
                try output.print("{d}{c}{s}{c}{s}{c}{d}{c}{d:.1}{c}{d:.1}\n", .{
                    index + 1, sep, step.kind, sep, step.value, sep, counts[index], sep, step_percent, sep, overall,
                });
            }
        },
        .json => {
            try output.writeByte('[');
            for (steps.items, 0..) |step, index| {
                if (index != 0) try output.writeByte(',');
                try output.print("{{\"step\":{d},\"kind\":", .{index + 1});
                try std.json.Stringify.value(step.kind, .{}, output);
                try output.writeAll(",\"match\":");
                try std.json.Stringify.value(step.value, .{}, output);
                try output.print(",\"sessions\":{d}}}", .{counts[index]});
            }
            try output.writeAll("]\n");
        },
    }
}

pub fn spendAdd(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    store: *store_mod.Store,
    site_id: i64,
    date: []const u8,
    source: []const u8,
    campaign: []const u8,
    content: []const u8,
    amount_text: []const u8,
    currency: []const u8,
) !void {
    _ = try reports.resolveOptions(&.{ "spend", "--from", date, "--to", date });
    try validateText(source, 128);
    try validateText(campaign, 128);
    try validateText(content, 128);
    if (currency.len != 3) return error.InvalidCurrency;
    for (currency) |byte| if (!std.ascii.isUpper(byte)) return error.InvalidCurrency;
    const amount = std.fmt.parseInt(i64, amount_text, 10) catch return error.InvalidAmount;
    if (amount < 0) return error.InvalidAmount;
    var statement = try store.database.prepare(allocator,
        \\INSERT INTO campaign_spend(site_id,spend_date,source,campaign,content,amount_minor,currency,created_at_ms)
        \\VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(site_id,spend_date,source,campaign,content,currency)
        \\DO UPDATE SET amount_minor=amount_minor+excluded.amount_minor
    );
    defer statement.deinit();
    try statement.bindInt(1, site_id);
    try statement.bindText(2, date);
    try statement.bindText(3, source);
    try statement.bindText(4, campaign);
    try statement.bindText(5, content);
    try statement.bindInt(6, amount);
    try statement.bindText(7, currency);
    try statement.bindInt(8, try domain.nowMilliseconds());
    _ = try statement.step();
    try output.print("campaign spend added campaign={s} amount_minor={d} currency={s}\n", .{ campaign, amount, currency });
}

pub fn spendImport(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    store: *store_mod.Store,
    site_id: i64,
    path: []const u8,
) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidCsv;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var imported: usize = 0;
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line_number == 1 and std.mem.startsWith(u8, line, "date,")) continue;
        var fields: [6][]const u8 = undefined;
        var parts = std.mem.splitScalar(u8, line, ',');
        var count: usize = 0;
        while (parts.next()) |field| {
            if (count >= fields.len) return error.InvalidCsv;
            fields[count] = std.mem.trim(u8, field, " \t");
            count += 1;
        }
        if (count != fields.len) return error.InvalidCsv;
        try spendAdd(allocator, output, store, site_id, fields[0], fields[1], fields[2], fields[3], fields[4], fields[5]);
        imported += 1;
    }
    try output.print("campaign spend import complete rows={d}\n", .{imported});
}

const ResolvedStep = struct { kind: []const u8, value: []const u8 };

fn resolveStep(allocator: std.mem.Allocator, store: *store_mod.Store, site_id: i64, raw: []const u8) !ResolvedStep {
    if (std.mem.startsWith(u8, raw, "event:")) {
        const value = raw[6..];
        try validateStep("event", value);
        return .{ .kind = "event", .value = value };
    }
    if (std.mem.startsWith(u8, raw, "path:")) {
        const value = raw[5..];
        try validateStep("path", value);
        return .{ .kind = "path", .value = value };
    }
    var statement = try store.database.prepare(allocator, "SELECT kind,match_value FROM goals WHERE site_id=? AND name=?");
    defer statement.deinit();
    try statement.bindInt(1, site_id);
    try statement.bindText(2, raw);
    if (try statement.step() != .row) return error.UnknownGoalOrStep;
    return .{
        .kind = try allocator.dupe(u8, statement.columnText(0)),
        .value = try allocator.dupe(u8, statement.columnText(1)),
    };
}

fn validateStep(kind: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, kind, "event")) return domain.validateName(value);
    if (std.mem.eql(u8, kind, "path")) return domain.validatePath(value);
    return error.InvalidGoalKind;
}

fn validateText(value: []const u8, maximum: usize) !void {
    if (value.len == 0 or value.len > maximum or !std.unicode.utf8ValidateSlice(value)) return error.InvalidText;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidText;
}
