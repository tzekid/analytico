const std = @import("std");
const domain = @import("domain.zig");
const catalog = @import("web/catalog.zig");
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
    try statement.bindInt(5, domain.nowMs());
    _ = try statement.step();
    try output.print("goal added name={s} kind={s} match={s}\n", .{ name, kind, match_value });
}

pub fn goalList(allocator: std.mem.Allocator, output: *std.Io.Writer, store: *store_mod.Store, site_id: i64) !void {
    var statement = try store.database.prepare(allocator, "SELECT name,kind,match_value FROM goals WHERE site_id=? ORDER BY name");
    defer statement.deinit();
    try statement.bindInt(1, site_id);
    try catalog.render(output, try catalog.sqlTable(allocator, &statement), .table);
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
    const now = domain.nowMs();
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
    try catalog.render(output, try catalog.sqlTable(allocator, &statement), .table);
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
    _ = try @import("web/data.zig").parseDate(date);
    try domain.validateText(source, 128, false);
    try domain.validateText(campaign, 128, false);
    try domain.validateText(content, 128, false);
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
    try statement.bindInt(8, domain.nowMs());
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
