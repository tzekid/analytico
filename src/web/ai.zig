//! AI inside Analytico: Ask, Why?, alert triage and scheduled summaries.
//! Runs on the person's own ChatGPT plan or the instance's API key (any
//! provider in `agent.zig`). Only aggregates leave the instance, and every
//! call is logged with the exact text that was sent.
const std = @import("std");
const agent = @import("agent.zig");
const chatgpt = @import("chatgpt.zig");
const ctx_mod = @import("ctx.zig");
const data = @import("data.zig");
const db_mod = @import("../db.zig");
const html = @import("html.zig");
const behaviour = @import("behaviour.zig");
const layout = @import("layout.zig");
const ui = @import("ui.zig");
const net = @import("../net.zig");
const overview = @import("overview.zig");
const secret = @import("secret.zig");

const Ctx = ctx_mod.Ctx;
const Shared = ctx_mod.Shared;
const esc = html.esc;
const render = html.render;
const icon = layout.icon;

pub const Provider = enum { anthropic, openai, compatible, chatgpt };

pub const Config = struct {
    provider: Provider,
    model: []const u8,
    /// Compatible endpoints and the ChatGPT plan; for Anthropic, only test
    /// stand-ins set it.
    base_url: []const u8,
    /// API key, or the ChatGPT plan's access token.
    key: []const u8,
    budget_cents: i64,
    share_paths: bool,
    share_sources: bool,

    pub fn label(self: Config) []const u8 {
        return modelLabel(self.model);
    }
};

pub const anthropic_models = [_][2][]const u8{
    .{ "claude-sonnet-5-5", "Claude Sonnet" },
    .{ "claude-haiku-4-5-20251001", "Claude Haiku" },
    .{ "claude-opus-5-5", "Claude Opus" },
};

pub fn modelLabel(model: []const u8) []const u8 {
    for (anthropic_models) |entry| if (std.mem.eql(u8, entry[0], model)) return entry[1];
    return model;
}

pub fn sharePaths(arena: std.mem.Allocator, db: *db_mod.Db) !bool {
    return !std.mem.eql(u8, (try data.setting(arena, db, .@"ai.share_paths")) orelse "1", "0");
}

pub fn shareSources(arena: std.mem.Allocator, db: *db_mod.Db) !bool {
    return !std.mem.eql(u8, (try data.setting(arena, db, .@"ai.share_sources")) orelse "1", "0");
}

/// The instance's API key, if one is set.
pub fn load(arena: std.mem.Allocator, db: *db_mod.Db, master: [32]u8) !?Config {
    const provider = std.meta.stringToEnum(Provider, (try data.setting(arena, db, .@"ai.provider")) orelse return null) orelse return null;
    const sealed = try data.setting(arena, db, .@"ai.key");
    return .{
        .provider = provider,
        .model = (try data.setting(arena, db, .@"ai.model")) orelse "claude-sonnet-5-5",
        .base_url = (try data.setting(arena, db, .@"ai.base_url")) orelse "",
        .key = if (sealed) |value| secret.open(arena, master, value) catch "" else "",
        .budget_cents = std.fmt.parseInt(i64, (try data.setting(arena, db, .@"ai.budget_cents")) orelse "1000", 10) catch 1000,
        .share_paths = try sharePaths(arena, db),
        .share_sources = try shareSources(arena, db),
    };
}

/// The instance's key, within this month's limit.
fn instance(arena: std.mem.Allocator, db: *db_mod.Db, master: [32]u8, now_ms: i64) !Config {
    const config = try load(arena, db, master) orelse return error.AiNotConfigured;
    if (config.budget_cents > 0 and try monthSpentMicro(arena, db, now_ms) >= config.budget_cents * 10_000) return error.AiBudgetReached;
    return config;
}

fn plan(arena: std.mem.Allocator, shared: *Shared, db: *db_mod.Db, user_id: i64, account: chatgpt.Account) !Config {
    return .{
        .provider = .chatgpt,
        .model = account.activeModel(),
        .base_url = try chatgpt.apiBase(arena, db),
        .key = try chatgpt.accessToken(arena, shared, db, user_id),
        .budget_cents = 0,
        .share_paths = try sharePaths(arena, db),
        .share_sources = try shareSources(arena, db),
    };
}

/// Interactive AI: the person's own ChatGPT plan, else the instance's key.
/// A plan that fails never falls back to the key.
pub fn forPerson(arena: std.mem.Allocator, shared: *Shared, db: *db_mod.Db, user_id: i64, now_ms: i64) !Config {
    if (try chatgpt.account(arena, db, shared.master_key, user_id)) |account| if (account.tokens != null) return plan(arena, shared, db, user_id, account);
    return instance(arena, db, shared.master_key, now_ms);
}

/// Alerts and scheduled emails: the instance's key, else the plan of an
/// admin who chose to lend it.
pub fn forBackground(arena: std.mem.Allocator, shared: *Shared, db: *db_mod.Db, now_ms: i64) !Config {
    if (instance(arena, db, shared.master_key, now_ms)) |config| return config else |err| if (err != error.AiNotConfigured) return err;
    const user_id = try db.scalar(arena, ?i64, "SELECT a.user_id FROM chatgpt_accounts a JOIN users u ON u.id=a.user_id WHERE a.background=1 AND a.tokens IS NOT NULL AND u.role IN ('owner','admin') ORDER BY a.user_id LIMIT 1", .{}) orelse return error.AiNotConfigured;
    const account = try chatgpt.account(arena, db, shared.master_key, user_id) orelse return error.AiNotConfigured;
    return plan(arena, shared, db, user_id, account);
}

/// Approximate list prices in micro-dollars per token; unknown models (and plans) cost 0.
pub fn costMicro(model: []const u8, input_tokens: i64, output_tokens: i64) i64 {
    const Price = struct { []const u8, i64, i64 };
    const prices = [_]Price{ .{ "claude-sonnet", 3, 15 }, .{ "claude-haiku", 1, 5 }, .{ "claude-opus", 5, 25 } };
    for (prices) |price| if (std.mem.startsWith(u8, model, price[0])) return input_tokens * price[1] + output_tokens * price[2];
    return 0;
}

fn cost(config: Config, input_tokens: i64, output_tokens: i64) i64 {
    return if (config.provider == .chatgpt) 0 else costMicro(config.model, input_tokens, output_tokens);
}

/// The model as the AI log shows it; plan usage is marked.
fn logModel(arena: std.mem.Allocator, config: Config) ![]const u8 {
    return if (config.provider == .chatgpt) std.fmt.allocPrint(arena, "{s}{s}", .{ config.model, plan_suffix }) else config.model;
}

const plan_suffix = " · ChatGPT plan";

pub fn monthSpentMicro(arena: std.mem.Allocator, db: *db_mod.Db, now_ms: i64) !i64 {
    const date = data.civil(now_ms);
    var buffer: [16]u8 = undefined;
    const first = try data.parseDate(try std.fmt.bufPrint(&buffer, "{d:0>4}-{d:0>2}-01", .{ date.year, date.month }));
    return db.scalar(arena, i64, "SELECT coalesce(sum(cost_micro),0) FROM ai_log WHERE at_ms>=?", .{first});
}

pub const Reply = struct { text: []const u8, input_tokens: i64, output_tokens: i64, elapsed_ms: i64 };

/// One answer without tools.
pub fn call(arena: std.mem.Allocator, io: std.Io, config: Config, system: []const u8, user: []const u8, max_tokens: u32) !Reply {
    const started = std.Io.Clock.awake.now(io);
    const result = try agent.run(arena, config, system, user, null, null, max_tokens);
    return .{ .text = result.text, .input_tokens = result.input_tokens, .output_tokens = result.output_tokens, .elapsed_ms = @intCast(@divFloor(started.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds(), 1_000_000)) };
}

pub fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.AiKeyRejected => "The provider rejected the key. Check it in Settings → AI.",
        error.AiModelNotFound => "The provider doesn’t know that model. Pick another in Settings → AI.",
        error.AiRateLimited => "The provider is rate-limiting this key. Try again in a minute.",
        error.AiUnreachable => "Couldn’t reach the AI provider. Check the endpoint and the server’s network.",
        error.AiBudgetReached => "This month’s AI limit is reached. Raise it in Settings → AI — analytics keep working.",
        error.AiNotConfigured => "Connect an AI provider in Settings → AI first.",
        error.AiPlanLimit => "Usage limit reached on your ChatGPT plan. It resets on its own — see Manage usage.",
        error.AiPlanIneligible => "This ChatGPT account can’t use its plan in other apps.",
        error.AiPlanUnavailable => "The AI is busy right now. Try again in a minute.",
        error.AiSignInAgain => "Sign in to ChatGPT again under Settings → AI.",
        error.AiIncomplete => "The answer was cut short. Try a narrower question.",
        error.AiTooManySteps => "That needed too many steps. Try a narrower question.",
        error.AiBusy => "Several questions are being answered already. Try again in a moment.",
        else => "The AI provider returned something unexpected. Try again.",
    };
}

// ---------------------------------------------------------------- data packet

const Namer = struct {
    arena: std.mem.Allocator,
    paths: bool,
    sources: bool,
    path_names: std.StringHashMap([]const u8),
    source_names: std.StringHashMap([]const u8),

    fn init(arena: std.mem.Allocator, paths: bool, sources: bool) Namer {
        return .{ .arena = arena, .paths = paths, .sources = sources, .path_names = .init(arena), .source_names = .init(arena) };
    }

    fn path(self: *Namer, value: []const u8) ![]const u8 {
        if (self.paths) return value;
        if (self.path_names.get(value)) |name| return name;
        const name = try std.fmt.allocPrint(self.arena, "page #{d}", .{self.path_names.count() + 1});
        try self.path_names.put(value, name);
        return name;
    }

    fn source(self: *Namer, value: []const u8) ![]const u8 {
        if (self.sources or std.mem.eql(u8, value, "direct")) return value;
        if (self.source_names.get(value)) |name| return name;
        const name = try std.fmt.allocPrint(self.arena, "source #{d}", .{self.source_names.count() + 1});
        try self.source_names.put(value, name);
        return name;
    }
};

/// The exact text the model sees: aggregates only, never visitor rows.
pub fn packet(arena: std.mem.Allocator, db: *db_mod.Db, view: data.View, share_paths: bool, share_sources: bool) ![]const u8 {
    var namer = Namer.init(arena, share_paths, share_sources);
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    const site = view.site;
    const range = view.range;
    try w.print("Website: {s} ({s}), {s} mode, times in UTC\nPeriod: {f}, compared with {s}\n", .{ site.title(), site.host(), @tagName(site.mode), range, range.comparisonLabel() });
    if (view.filters.len != 0) {
        try w.writeAll("Filters: ");
        for (view.filters, 0..) |filter, index| try w.print("{s}{s} {s} {s}", .{ if (index == 0) "" else if (view.any) " or " else " and ", filter.dim.label(), if (filter.negate) "is not" else "is", if (filter.dim == .page) try namer.path(filter.value) else if (filter.dim == .source or filter.dim == .campaign) try namer.source(filter.value) else filter.value });
        try w.writeByte('\n');
    }
    const now_totals = try data.totals(arena, db, view, range.start_ms, range.end_ms);
    const prev_totals = try data.totals(arena, db, view, range.prev_start_ms, range.prev_end_ms);
    try w.print("Totals (previous period in brackets): page views {d} ({d}); visitor-days {d} ({d}); active time {d} min ({d} min)", .{ now_totals.views, prev_totals.views, now_totals.visitor_days, prev_totals.visitor_days, @divFloor(now_totals.active_ms, 60_000), @divFloor(prev_totals.active_ms, 60_000) });
    if (site.mode != .lite) try w.print("; sessions {d} ({d})", .{ now_totals.sessions, prev_totals.sessions });
    try w.writeAll("\nVisitor-days are unique visitors per day; the same person on two days counts twice.\n");
    const views = try data.series(arena, db, view, .views, range.start_ms);
    const visitors = try data.series(arena, db, view, .visitor_days, range.start_ms);
    try w.print("Page views and visitor-days per {s}:", .{if (range.bucket_ms == data.hour_ms) "hour" else "day"});
    for (views, 0..) |value, index| {
        var buffer: [48]u8 = undefined;
        try w.print(" {s}={d:.0}/{d:.0}", .{ range.bucketLong(&buffer, index), value, visitors[index] });
        if (index + 1 != views.len) try w.writeByte(';');
    }
    try w.writeAll("\nTop pages (views, visitors, avg active seconds, avg scroll %, previous views):\n");
    var sql = data.Sql.init(arena);
    try sql.add("WITH prev AS (SELECT pv.path p,count(*) n FROM page_views pv WHERE ");
    try sql.pageViews(view, range.prev_start_ms, range.prev_end_ms);
    try sql.add(" GROUP BY pv.path) SELECT pv.path,count(*),count(DISTINCT pv.visitor_day_id),coalesce(avg(pv.active_ms),0)/1000,coalesce(avg(pv.max_scroll),0),coalesce((SELECT n FROM prev WHERE prev.p=pv.path),0) FROM page_views pv WHERE ");
    try sql.pageViews(view, range.start_ms, range.end_ms);
    try sql.add(" GROUP BY pv.path ORDER BY 2 DESC LIMIT 15");
    var pages = try sql.prepare(db);
    defer pages.deinit();
    while (try pages.step() == .row) try w.print("- {s}: {d}, {d}, {d:.0}, {d:.0}, {d}\n", .{ try namer.path(pages.columnText(0)), pages.columnInt(1), pages.columnInt(2), pages.columnFloat(3), pages.columnFloat(4), pages.columnInt(5) });
    try w.writeAll("Top sources (views, previous views):\n");
    for (try data.top(arena, db, view, .source, 10)) |row| try w.print("- {s}: {d}, {d}\n", .{ try namer.source(row.key), row.value, row.previous });
    try w.writeAll("Devices (views): ");
    for (try data.top(arena, db, view, .device, 4), 0..) |row, index| try w.print("{s}{s} {d}", .{ if (index == 0) "" else ", ", row.key, row.value });
    try w.writeAll("\nCampaigns (views, previous views): ");
    const campaigns = try data.top(arena, db, view, .campaign, 8);
    var any_campaign = false;
    for (campaigns) |row| {
        if (row.key.len == 0) continue;
        try w.print("{s}{s} {d} ({d})", .{ if (any_campaign) ", " else "", try namer.source(row.key), row.value, row.previous });
        any_campaign = true;
    }
    if (!any_campaign) try w.writeAll("none");
    var events_sql = data.Sql.init(arena);
    try events_sql.add("SELECT e.name,count(*) FROM events e WHERE ");
    try events_sql.events(view, range.start_ms, range.end_ms);
    try events_sql.add(" GROUP BY e.name ORDER BY 2 DESC LIMIT 12");
    var events = try events_sql.prepare(db);
    defer events.deinit();
    try w.writeAll("\nCustom events (count): ");
    var any_event = false;
    while (try events.step() == .row) {
        try w.print("{s}{s} {d}", .{ if (any_event) ", " else "", events.columnText(0), events.columnInt(1) });
        any_event = true;
    }
    if (!any_event) try w.writeAll("none");
    var goals = try db.prepare(arena, "SELECT name,kind,match_value FROM goals WHERE site_id=? ORDER BY name LIMIT 10");
    defer goals.deinit();
    try goals.bindInt(1, site.id);
    try w.writeAll("\nGoals: ");
    var any_goal = false;
    while (try goals.step() == .row) {
        try w.print("{s}{s} = {s} {s}", .{ if (any_goal) "; " else "", goals.columnText(0), goals.columnText(1), if (std.mem.eql(u8, goals.columnText(1), "path")) try namer.path(goals.columnText(2)) else goals.columnText(2) });
        any_goal = true;
    }
    if (!any_goal) try w.writeAll("none");
    var notes = try db.prepare(arena, "SELECT day,label FROM annotations WHERE site_id=? AND day>=? AND day<=? AND draft=0 ORDER BY day");
    defer notes.deinit();
    const from = data.dateText(range.prev_start_ms);
    const to = data.dateText(range.end_ms - 1);
    try notes.bindInt(1, site.id);
    try notes.bindText(2, &from);
    try notes.bindText(3, &to);
    try w.writeAll("\nNotes the team added: ");
    var any_note = false;
    while (try notes.step() == .row) {
        try w.print("{s}{s} {s}", .{ if (any_note) "; " else "", notes.columnText(0), notes.columnText(1) });
        any_note = true;
    }
    if (!any_note) try w.writeAll("none");
    try w.writeByte('\n');
    return out.written();
}

pub fn dataUsed(arena: std.mem.Allocator, view: data.View) ![]const u8 {
    return std.fmt.allocPrint(arena, "Overview, pages, sources · {d:.0} {s}", .{ if (view.range.bucket_ms == data.hour_ms) 24 else view.range.days(), if (view.range.bucket_ms == data.hour_ms) "hours" else "days" });
}

pub const LogEntry = struct {
    origin: []const u8,
    site_id: ?i64,
    question: []const u8,
    data_used: []const u8,
    model: []const u8,
    input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    cost_micro: i64 = 0,
    payload: []const u8,
    answer: []const u8,
};

pub fn log(arena: std.mem.Allocator, db: *db_mod.Db, now_ms: i64, entry: LogEntry) !i64 {
    var statement = try db.prepare(arena, "INSERT INTO ai_log(at_ms,origin,site_id,question,data_used,model,input_tokens,output_tokens,cost_micro,payload,answer) VALUES(?,?,?,?,?,?,?,?,?,?,?)");
    defer statement.deinit();
    try statement.bindInt(1, now_ms);
    try statement.bindText(2, entry.origin);
    try statement.bindOptionalInt(3, entry.site_id);
    try statement.bindText(4, entry.question);
    try statement.bindText(5, entry.data_used);
    try statement.bindText(6, entry.model);
    try statement.bindInt(7, entry.input_tokens);
    try statement.bindInt(8, entry.output_tokens);
    try statement.bindInt(9, entry.cost_micro);
    try statement.bindText(10, entry.payload);
    try statement.bindText(11, entry.answer);
    _ = try statement.step();
    return db.lastInsertRowId();
}

/// Pulls the first JSON object out of a model reply.
fn jsonObject(arena: std.mem.Allocator, text: []const u8) ?std.json.ObjectMap {
    const start = std.mem.indexOfScalar(u8, text, '{') orelse return null;
    const end = std.mem.lastIndexOfScalar(u8, text, '}') orelse return null;
    if (end <= start) return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text[start .. end + 1], .{}) catch return null;
    return if (parsed == .object) parsed.object else null;
}

const jsonString = net.string;

// ---------------------------------------------------------------- Ask

fn askInstructions(arena: std.mem.Allocator, site: data.Site) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\You are the analytics assistant inside Analytico, a privacy-first web analytics tool, answering the site owner's question about one website.
        \\The message starts with a summary of the view they are looking at, then the screen it is on; read "this page" or "here" as that screen and view. When it can't answer the question, use the analytico tools (other periods, pages, sources, funnels, errors and more); call several at once when you can.
        \\Answer in at most four short sentences, plainly, citing numbers. Don't speculate beyond the data; if it can't answer, say what is missing.
        \\You may link to views in Analytico with Markdown links to these paths: /{0s} (overview), /{0s}/pages, /{0s}/acquisition, /{0s}/events, /{0s}/funnels, /{0s}/sessions, /{0s}/audience, /{0s}/errors, /{0s}/revenue, /{0s}/performance. Add range=24h, 7d, 30d or 90d and filters such as f=page:/pricing or f=source:google to the query.
        \\End with one line starting "Follow-ups:" with up to three short follow-up questions separated by " | ".
    , .{site.slug});
}

pub fn askPage(ctx: *Ctx, site: data.Site) !void {
    const id = ctx.param("id") orelse "";
    return ctx.redirectFmt("/{s}?ask={f}", .{ site.slug, html.url(id) });
}

/// Answers in flight; each holds a request worker while it streams.
var asking = std.atomic.Value(u32).init(0);
const max_asking = 4;

/// Server-sent events to the Ask sheet: `delta` text, `tool` progress, then
/// `done` with the answer's address, or `error`.
const AskStream = struct {
    body: *std.http.BodyWriter,

    fn send(self: *AskStream, name: []const u8, value: anytype) !void {
        const w = &self.body.writer;
        try w.print("event: {s}\ndata: ", .{name});
        try std.json.Stringify.value(value, .{}, w);
        try w.writeAll("\n\n");
        try w.flush();
        try self.body.flush();
    }

    fn emit(context: *anyopaque, event: agent.Event) anyerror!void {
        const self: *AskStream = @ptrCast(@alignCast(context));
        switch (event) {
            .delta => |text| try self.send("delta", text),
            .tool => |used| try self.send("tool", used),
        }
    }

    fn fail(self: *AskStream, err: anyerror) !void {
        const settings = err == error.AiNotConfigured or err == error.AiSignInAgain or err == error.AiBudgetReached or err == error.AiKeyRejected or err == error.AiModelNotFound;
        try self.send("error", .{ .message = errorText(err), .href = if (err == error.AiPlanLimit) chatgpt.usage_url else if (settings) "/settings/ai" else "", .label = if (err == error.AiPlanLimit) "Manage usage" else if (settings) "Open settings" else "" });
        try self.body.end();
    }
};

pub fn ask(ctx: *Ctx, site: data.Site) !void {
    const arena = ctx.arena;
    const question = std.mem.trim(u8, try ctx.field("q"), " \n");
    if (question.len == 0 or question.len > 500) return ctx.text(.bad_request, "Ask a question of up to 500 characters.");
    const back = try stripParam(arena, try ctx.field("view"), "ask");
    const params = html.Params.parse(arena, if (std.mem.findScalar(u8, back, '?')) |index| back[index + 1 ..] else "") catch html.Params{};
    const view = try data.View.parse(arena, site, params, ctx.now());
    if (asking.fetchAdd(1, .monotonic) >= max_asking) {
        _ = asking.fetchSub(1, .monotonic);
        return ctx.text(.service_unavailable, errorText(error.AiBusy));
    }
    defer _ = asking.fetchSub(1, .monotonic);
    ctx.extendDeadline(180);
    var buffer: [1024]u8 = undefined;
    var body = try ctx.request.respondStreaming(&buffer, .{ .respond_options = .{ .keep_alive = false, .extra_headers = &.{
        .{ .name = "content-type", .value = "text/event-stream; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store, no-transform" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    } } });
    ctx.responded = true;
    var stream: AskStream = .{ .body = &body };
    const config = forPerson(arena, ctx.shared, ctx.db, ctx.user.?.id, ctx.now()) catch |err| return stream.fail(err);
    const instructions = try askInstructions(arena, site);
    const input = try std.fmt.allocPrint(arena, "{s}\nScreen: {s}\nQuestion: {s}", .{ try packet(arena, ctx.db, view, config.share_paths, config.share_sources), screenOf(back, site.slug), question });
    const scope: agent.Scope = .{ .db = ctx.db, .site = site, .now_ms = ctx.now(), .paths = config.share_paths, .sources = config.share_sources };
    const result = agent.run(arena, config, instructions, input, scope, .{ .context = &stream, .emitFn = AskStream.emit }, 1500) catch |err| {
        // The browser left; nothing to tell it.
        if (err == error.WriteFailed) return;
        return stream.fail(err);
    };
    const id = blk: {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        break :blk try log(arena, db, ctx.now(), .{
            .origin = "Ask in Analytico",
            .site_id = site.id,
            .question = question,
            .data_used = try dataUsed(arena, view),
            .model = try logModel(arena, config),
            .input_tokens = result.input_tokens,
            .output_tokens = result.output_tokens,
            .cost_micro = cost(config, result.input_tokens, result.output_tokens),
            .payload = try std.mem.concat(arena, u8, &.{ input, result.tools }),
            .answer = result.text,
        });
    };
    try stream.send("done", .{ .href = try std.fmt.allocPrint(arena, "{s}{s}ask={d}", .{ back, if (std.mem.findScalar(u8, back, '?') == null) "?" else "&", id }) });
    try body.end();
}

/// Plain-language filters: one call without tools turns "mobile visitors from
/// Germany last month" into a view, shown as chips before it is applied.
pub fn describe(ctx: *Ctx, site: data.Site) !void {
    const arena = ctx.arena;
    const text = std.mem.trim(u8, try ctx.field("q"), " \n");
    if (text.len == 0 or text.len > 200) return jsonFailed(ctx, "Describe the visitors in up to 200 characters.");
    const back = try ctx.field("view");
    const query_at = std.mem.findScalar(u8, back, '?') orelse back.len;
    // Only screens of this website; anything else opens its overview.
    const own = try std.fmt.allocPrint(arena, "/{s}", .{site.slug});
    const path = if (std.mem.eql(u8, screenOf(back, site.slug), "overview")) own else back[0..query_at];
    const params = html.Params.parse(arena, if (query_at < back.len) back[query_at + 1 ..] else "") catch html.Params{};
    const current = try data.View.parse(arena, site, params, ctx.now());
    const config = forPerson(arena, ctx.shared, ctx.db, ctx.user.?.id, ctx.now()) catch |err| return jsonFailed(ctx, errorText(err));
    const today = data.dateText(ctx.now());
    const system = try std.fmt.allocPrint(arena, describe_system, .{&today});
    ctx.extendDeadline(60);
    const reply = call(arena, ctx.shared.io, config, system, text, 300) catch |err| return jsonFailed(ctx, errorText(err));
    {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        _ = try log(arena, db, ctx.now(), .{ .origin = "Filter from a description", .site_id = site.id, .question = text, .data_used = "None", .model = try logModel(arena, config), .input_tokens = reply.input_tokens, .output_tokens = reply.output_tokens, .cost_micro = cost(config, reply.input_tokens, reply.output_tokens), .payload = text, .answer = reply.text });
    }
    const object = jsonObject(arena, reply.text) orelse return jsonFailed(ctx, "Couldn’t turn that into filters. Try naming a period, country, device, source or page.");
    var overrides: std.ArrayList([2][]const u8) = .empty;
    try overrides.append(arena, .{ "f!", "" });
    const range = jsonString(object, "range");
    if (std.meta.stringToEnum(data.RangeKind, range)) |kind| {
        const from = jsonString(object, "from");
        const to = jsonString(object, "to");
        if (kind != .custom) {
            try overrides.appendSlice(arena, &.{ .{ "range", range }, .{ "from", "" }, .{ "to", "" } });
        } else if (data.parseDate(from)) |_| if (data.parseDate(to)) |_| {
            try overrides.appendSlice(arena, &.{ .{ "range", range }, .{ "from", from }, .{ "to", to } });
        } else |_| {} else |_| {}
    }
    if (object.get("filters")) |list| if (list == .array) for (list.array.items) |item| {
        if (item != .object) continue;
        const dim = std.meta.stringToEnum(data.Dim, jsonString(item.object, "dim")) orelse continue;
        const value = std.mem.trim(u8, jsonString(item.object, "value"), " ");
        if (value.len == 0 or value.len > 200) continue;
        const negate = if (item.object.get("not")) |not| not == .bool and not.bool else false;
        try overrides.append(arena, .{ "f+", try std.fmt.allocPrint(arena, "{s}{s}:{s}", .{ @tagName(dim), if (negate) "!" else "", value }) });
    };
    if (overrides.items.len == 1) return jsonFailed(ctx, "Couldn’t turn that into filters. Try naming a period, country, device, source or page.");
    const href = try current.href(arena, path, overrides.items);
    // The chips read back what the address now says.
    const next_at = std.mem.findScalar(u8, href, '?') orelse href.len;
    const next = try data.View.parse(arena, site, html.Params.parse(arena, if (next_at < href.len) href[next_at + 1 ..] else "") catch html.Params{}, ctx.now());
    var chips: std.ArrayList([]const u8) = .empty;
    try chips.append(arena, try std.fmt.allocPrint(arena, "{f}", .{next.range}));
    for (next.filters) |filter| try chips.append(arena, try std.fmt.allocPrint(arena, "{s} {s} {s}", .{ filter.dim.label(), if (filter.negate) "is not" else "is", filter.value }));
    try std.json.Stringify.value(.{ .href = href, .chips = chips.items }, .{}, ctx.w());
    return ctx.json();
}

const describe_system =
    \\You turn a description of website visitors into analytics filters. Today is {s} (UTC).
    \\Reply with JSON only: {{"range":"24h|7d|30d|90d|custom","from":"YYYY-MM-DD","to":"YYYY-MM-DD","filters":[{{"dim":"...","value":"...","not":false}}]}}
    \\Give from and to only with custom (both inclusive); leave range out when no period is named. "Last month" is the previous calendar month, as custom.
    \\dim is one of: source (a referrer host such as google.com or news.ycombinator.com, a utm_source, or "direct"), page (a path starting with /), campaign, device (mobile or desktop), browser (chrome, safari, firefox or edge), os (android, ios, windows, macos or linux), country (ISO 3166 alpha-2, uppercase, such as DE), region, city, release.
    \\One filter per condition; "not" true for exclusions. Leave out anything not asked for.
;

fn jsonFailed(ctx: *Ctx, message: []const u8) !void {
    try std.json.Stringify.value(.{ .@"error" = message }, .{}, ctx.w());
    return ctx.json();
}

/// "What happened?" on a replay: the session's moments (pages, events,
/// rage clicks, errors; never anything typed) become a few timestamped lines
/// that seek the player.
pub fn sessionSummary(ctx: *Ctx, site: data.Site, session_id: []const u8) !void {
    const arena = ctx.arena;
    @import("../domain.zig").validateUuid(session_id) catch return jsonFailed(ctx, "Session not found.");
    const moments = try behaviour.momentsOf(ctx, site.id, session_id);
    if (moments.len == 0) return jsonFailed(ctx, "Session not found.");
    const started = try behaviour.startOf(ctx, site.id, session_id, moments);
    const config = forPerson(arena, ctx.shared, ctx.db, ctx.user.?.id, ctx.now()) catch |err| return jsonFailed(ctx, errorText(err));
    var namer = Namer.init(arena, config.share_paths, config.share_sources);
    var timeline: std.Io.Writer.Allocating = .init(arena);
    const w = &timeline.writer;
    for (moments) |moment| {
        try w.print("{f} ", .{behaviour.Offset{ .ms = moment.at - started }});
        if (std.mem.eql(u8, moment.kind, "page")) {
            try w.print("opened {s}\n", .{try namer.path(moment.title)});
        } else if (std.mem.eql(u8, moment.kind, "rage")) {
            try w.writeAll("rage click\n");
        } else if (std.mem.eql(u8, moment.kind, "error")) {
            try w.print("JavaScript error: {s}\n", .{moment.title[0..@min(moment.title.len, 120)]});
        } else {
            try w.print("{s} {s}\n", .{ if (std.mem.eql(u8, moment.kind, "money")) "payment" else "event", moment.title });
        }
    }
    ctx.extendDeadline(60);
    const reply = call(arena, ctx.shared.io, config, summary_system, timeline.written(), 300) catch |err| return jsonFailed(ctx, errorText(err));
    {
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        _ = try log(arena, db, ctx.now(), .{ .origin = "Session summary", .site_id = site.id, .question = "What happened in this session?", .data_used = "The session’s pages, events and errors", .model = try logModel(arena, config), .input_tokens = reply.input_tokens, .output_tokens = reply.output_tokens, .cost_micro = cost(config, reply.input_tokens, reply.output_tokens), .payload = timeline.written(), .answer = reply.text });
    }
    const Line = struct { at: i64, time: []const u8, text: []const u8 };
    var lines: std.ArrayList(Line) = .empty;
    var rows = std.mem.tokenizeScalar(u8, reply.text, '\n');
    while (rows.next()) |row| {
        // "1:05 — Rage-clicked the Buy button": minutes, seconds, then the line.
        const line = std.mem.trim(u8, row, " -*•");
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        var end = colon + 1;
        while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
        const minutes = std.fmt.parseInt(i64, line[0..colon], 10) catch continue;
        const seconds = std.fmt.parseInt(i64, line[colon + 1 .. end], 10) catch continue;
        const text = std.mem.trim(u8, line[end..], " —–-:");
        if (text.len == 0 or lines.items.len == 4) continue;
        const at = (minutes * 60 + seconds) * 1000;
        try lines.append(arena, .{ .at = at, .time = try std.fmt.allocPrint(arena, "{f}", .{behaviour.Offset{ .ms = at }}), .text = text });
    }
    if (lines.items.len == 0) return jsonFailed(ctx, "Couldn’t summarise this session. Try again.");
    try std.json.Stringify.value(.{ .lines = lines.items }, .{}, ctx.w());
    return ctx.json();
}

const summary_system =
    \\You summarise one visit to a website from its timeline (minutes:seconds from the start, then what happened).
    \\Reply with two or three lines in order, each "m:ss — what happened" in plain words: where the visitor went, where they struggled (rage clicks, errors, going back and forth) and how the visit ended.
    \\Use only the timeline; don't guess at intent.
;

/// The workspace screen a view address points at, such as "pages".
fn screenOf(target: []const u8, slug: []const u8) []const u8 {
    const path = target[0 .. std.mem.findScalar(u8, target, '?') orelse target.len];
    if (path.len < slug.len + 2 or path[0] != '/' or !std.mem.eql(u8, path[1 .. slug.len + 1], slug) or path[slug.len + 1] != '/') return "overview";
    const rest = path[slug.len + 2 ..];
    for (rest) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '/') return "overview";
    return if (rest.len == 0) "overview" else rest;
}

/// An answer: paragraphs with links into this website, then follow-ups.
const Answer = struct { body: []const u8, followups: []const []const u8 };

fn splitAnswer(arena: std.mem.Allocator, text: []const u8) !Answer {
    // Answers from before streaming were JSON.
    if (jsonObject(arena, text)) |object| if (object.get("answer") != null) {
        var list: std.ArrayList([]const u8) = .empty;
        if (object.get("followups")) |value| if (value == .array) for (value.array.items) |item| if (item == .string) try list.append(arena, item.string);
        return .{ .body = jsonString(object, "answer"), .followups = list.items };
    };
    const marker = "Follow-ups:";
    const at = std.mem.lastIndexOf(u8, text, marker) orelse return .{ .body = std.mem.trim(u8, text, " \n"), .followups = &.{} };
    var list: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, text[at + marker.len ..], " \n"), '|');
    while (parts.next()) |part| {
        const question = std.mem.trim(u8, part, " \n-*");
        if (question.len != 0 and list.items.len < 3) try list.append(arena, question);
    }
    return .{ .body = std.mem.trim(u8, text[0..at], " \n*"), .followups = list.items };
}

/// Text with [label](/site/...) links kept when they stay on this website;
/// everything else is escaped as written, less Markdown emphasis.
fn answerHtml(w: *std.Io.Writer, site: data.Site, text: []const u8) !void {
    var paragraphs = std.mem.splitSequence(u8, text, "\n\n");
    while (paragraphs.next()) |paragraph| {
        const trimmed = std.mem.trim(u8, paragraph, " \n");
        if (trimmed.len == 0) continue;
        try w.writeAll("<p class=\"ask-answer\">");
        var rest = trimmed;
        while (rest.len != 0) {
            const open = std.mem.findScalar(u8, rest, '[') orelse rest.len;
            try writePlain(w, rest[0..open]);
            if (open == rest.len) break;
            rest = rest[open..];
            const close = std.mem.find(u8, rest, "](") orelse {
                try writePlain(w, rest);
                break;
            };
            const end = std.mem.findScalarPos(u8, rest, close, ')') orelse rest.len;
            const label = rest[1..close];
            const href = rest[@min(close + 2, end)..end];
            const own = std.mem.startsWith(u8, href, "/") and !std.mem.startsWith(u8, href, "//") and std.mem.startsWith(u8, href[1..], site.slug) and (href.len == site.slug.len + 1 or href[site.slug.len + 1] == '/' or href[site.slug.len + 1] == '?');
            if (own and end < rest.len) {
                try w.print("<a class=\"link\" href=\"{f}\">", .{esc(href)});
                try writePlain(w, label);
                try w.writeAll("</a>");
            } else try writePlain(w, label);
            rest = if (end < rest.len) rest[end + 1 ..] else "";
        }
        try w.writeAll("</p>");
    }
}

/// Escaped text without Markdown emphasis markers.
fn writePlain(w: *std.Io.Writer, text: []const u8) !void {
    var parts = std.mem.tokenizeAny(u8, text, "*`");
    while (parts.next()) |part| try w.print("{f}", .{esc(part)});
}

/// The answer sheet, rendered over whatever page asked.
pub fn askSheet(ctx: *Ctx, site: data.Site, id_text: []const u8) !void {
    const arena = ctx.arena;
    const id = std.fmt.parseInt(i64, id_text, 10) catch return;
    const Row = struct { question: []const u8, answer: []const u8, model: []const u8, cost_micro: i64, data_used: []const u8 };
    const row = try ctx.db.one(arena, Row, "SELECT question,answer,model,cost_micro,data_used FROM ai_log WHERE id=? AND site_id=?", .{ id, site.id }) orelse return;
    const w = ctx.w();
    const close = try stripParam(arena, ctx.target, "ask");
    try render(w, "<dialog class=\"sheet\" data-sheet data-close-href=\"{close}\" id=\"ask-sheet\"><div class=\"sheet-head ask-head\"><div class=\"row\">", .{ .close = close });
    try icon(w, "sparkles");
    try render(w, "<h2>Ask</h2></div><div class=\"row nowrap ml-auto\"><button class=\"btn btn-quiet\" type=\"button\" data-palette>New question</button><a class=\"btn btn-quiet btn-icon\" href=\"{close}\" data-close aria-label=\"Close\">", .{ .close = close });
    try icon(w, "x");
    try render(w, "</a></div></div><div class=\"sheet-body\"><div class=\"ask-q\">{question}</div>", .{ .question = row.question });
    const answer = try splitAnswer(arena, row.answer);
    try answerHtml(w, site, answer.body);
    if (answer.followups.len != 0) {
        try w.writeAll("<div><div class=\"menu-label flush-left\">Follow up</div><div class=\"stack-s\">");
        for (answer.followups) |item| {
            try render(w, "<form method=\"post\" action=\"/{slug}/ask\" data-ask-form><input type=\"hidden\" name=\"q\" value=\"{question}\"><input type=\"hidden\" name=\"view\" value=\"{view}\"><button class=\"menu-item followup\">", .{ .slug = site.slug, .question = item, .view = close });
            try icon(w, "sparkles");
            try render(w, "{question}</button></form>", .{ .question = item });
        }
        try w.writeAll("</div></div>");
    }
    try render(w, "<form method=\"post\" action=\"/{slug}/ask\" class=\"ask-input\" data-ask-form><input type=\"hidden\" name=\"view\" value=\"{view}\"><input class=\"input\" name=\"q\" placeholder=\"Ask a follow-up…\" required maxlength=\"500\" autocomplete=\"off\"><button class=\"btn btn-primary btn-icon\" aria-label=\"Ask\">", .{ .slug = site.slug, .view = close });
    try icon(w, "send");
    const on_plan = std.mem.endsWith(u8, row.model, plan_suffix);
    try render(w, "</button></form><p class=\"hint\">{model} · ", .{ .model = modelLabel(if (on_plan) row.model[0 .. row.model.len - plan_suffix.len] else row.model) });
    if (on_plan) try icon(w, "chatgpt");
    try render(w, "{source} · aggregates only · {used}", .{ .source = if (on_plan) "Using ChatGPT plan" else "instance key", .used = row.data_used });
    if (on_plan) try render(w, " · <a class=\"link\" href=\"{url}\" target=\"_blank\" rel=\"noopener\">Manage usage</a>", .{ .url = chatgpt.usage_url });
    if (row.cost_micro > 0) try render(w, " · ≈${cost:.3}", .{ .cost = @as(f64, @floatFromInt(row.cost_micro)) / 1_000_000 });
    if (ctx.can(.admin)) try render(w, " · <a class=\"link\" href=\"/settings/ai/log/{id}?site={slug}\">See what was sent</a>", .{ .id = id, .slug = site.slug });
    try w.writeAll("</p></div></dialog>");
}

pub fn stripParam(arena: std.mem.Allocator, target: []const u8, key: []const u8) ![]const u8 {
    const query_start = std.mem.findScalar(u8, target, '?') orelse return target;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, target[0..query_start]);
    var parts = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    var first = true;
    while (parts.next()) |part| {
        const name = part[0 .. std.mem.findScalar(u8, part, '=') orelse part.len];
        if (std.mem.eql(u8, name, key) or part.len == 0) continue;
        try out.appendSlice(arena, if (first) "?" else "&");
        try out.appendSlice(arena, part);
        first = false;
    }
    return out.items;
}

// ---------------------------------------------------------------- Why?

pub const Driver = struct { dim: data.Dim, key: []const u8, delta: i64, current: i64, previous: i64 };

pub const Drivers = struct {
    current: i64,
    previous: i64,
    list: []Driver,
    bot_share: f64,
};

/// Splits the change between two windows into its largest contributors.
pub fn drivers(arena: std.mem.Allocator, db: *db_mod.Db, view: data.View, start: i64, end: i64, base_start: i64, base_end: i64) !Drivers {
    var all: std.ArrayList(Driver) = .empty;
    var current: i64 = 0;
    var previous: i64 = 0;
    for ([_]data.Dim{ .source, .page, .device }) |dim| {
        var sql = data.Sql.init(arena);
        try sql.add("SELECT k,sum(c),sum(p) FROM (SELECT ");
        try sql.add(dim.column());
        try sql.add(" k,1 c,0 p FROM page_views pv WHERE ");
        try sql.pageViews(view, start, end);
        try sql.add(" UNION ALL SELECT ");
        try sql.add(dim.column());
        try sql.add(" k,0,1 FROM page_views pv WHERE ");
        try sql.pageViews(view, base_start, base_end);
        try sql.add(") GROUP BY k");
        var statement = try sql.prepare(db);
        defer statement.deinit();
        var sum_current: i64 = 0;
        var sum_previous: i64 = 0;
        while (try statement.step() == .row) {
            const c = statement.columnInt(1);
            const p = statement.columnInt(2);
            sum_current += c;
            sum_previous += p;
            if (c != p) try all.append(arena, .{ .dim = dim, .key = try arena.dupe(u8, statement.columnText(0)), .delta = c - p, .current = c, .previous = p });
        }
        current = sum_current;
        previous = sum_previous;
    }
    const total = current - previous;
    // Keep contributors moving with the overall change; one per key.
    std.mem.sort(Driver, all.items, total, struct {
        fn less(direction: i64, a: Driver, b: Driver) bool {
            const sa = if (direction >= 0) a.delta else -a.delta;
            const sb = if (direction >= 0) b.delta else -b.delta;
            if (sa != sb) return sa > sb;
            return @backingInt(a.dim) < @backingInt(b.dim);
        }
    }.less);
    var picked: std.ArrayList(Driver) = .empty;
    for (all.items) |driver| {
        if (picked.items.len == 3) break;
        if ((total >= 0) != (driver.delta >= 0)) continue;
        var duplicate_dim = false;
        for (picked.items) |other| if (other.dim == driver.dim and other.dim == .device) {
            duplicate_dim = true;
        };
        if (!duplicate_dim) try picked.append(arena, driver);
    }
    const bots = try db.scalar(arena, i64, "SELECT count(*) FROM page_views WHERE site_id=? AND received_at_ms>=? AND received_at_ms<? AND traffic_class IN ('known_bot','monitor')", .{ view.site.id, start, end });
    return .{ .current = current, .previous = previous, .list = picked.items, .bot_share = if (current + bots == 0) 0 else @as(f64, @floatFromInt(bots)) / @as(f64, @floatFromInt(current + bots)) };
}

const why_system =
    \\You explain changes in website traffic for the site owner, using only the numbers provided.
    \\Reply with JSON only: {"headline": string (one short sentence), "reasons": [string] (one short phrase per contributor, same order, at most 10 words each)}.
;

pub fn driverLabel(arena: std.mem.Allocator, driver: Driver) ![]const u8 {
    return switch (driver.dim) {
        .source => overview.sourceLabel(arena, driver.key),
        .device => std.fmt.allocPrint(arena, "{s} visitors", .{driver.key}),
        else => driver.key,
    };
}

fn driversText(arena: std.mem.Allocator, result: Drivers, period: []const u8, baseline: []const u8, paths: bool, sources: bool) ![]const u8 {
    var namer = Namer.init(arena, paths, sources);
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("Page views {s}: {d}. {s}: {d}. Bot share of raw traffic: {d:.0}%.\nLargest contributors:\n", .{ period, result.current, baseline, result.previous, result.bot_share * 100 });
    for (result.list) |driver| {
        const name = switch (driver.dim) {
            .page => try namer.path(driver.key),
            .source => try namer.source(driver.key),
            else => driver.key,
        };
        try out.writer.print("- {s} {s}: {d} vs {d}\n", .{ driver.dim.label(), name, driver.current, driver.previous });
    }
    return out.written();
}

pub fn why(ctx: *Ctx, site: data.Site) !void {
    const arena = ctx.arena;
    if ((try ctx.field("alert")).len != 0) return triage(ctx, site, std.fmt.parseInt(i64, try ctx.field("alert"), 10) catch 0);
    const view_query = try ctx.field("view");
    const params = html.Params.parse(arena, if (std.mem.findScalar(u8, view_query, '?')) |index| view_query[index + 1 ..] else "") catch html.Params{};
    const view = try data.View.parse(arena, site, params, ctx.now());
    const index = std.math.clamp(std.fmt.parseInt(i64, try ctx.field("i"), 10) catch 0, 0, @as(i64, @intCast(view.range.buckets)) - 1);
    const range = view.range;
    const start = range.start_ms + index * range.bucket_ms;
    const end = start + range.bucket_ms;
    const shift = if (view.compare) range.start_ms - range.prev_start_ms else range.bucket_ms;
    var label_buffer: [48]u8 = undefined;
    var base_buffer: [48]u8 = undefined;
    const label = range.bucketLong(&label_buffer, @intCast(index));
    const base_label = if (view.compare) try std.fmt.allocPrint(arena, "same {s} of the previous period", .{if (range.bucket_ms == data.hour_ms) "hour" else "day"}) else if (index > 0) range.bucketLong(&base_buffer, @intCast(index - 1)) else "the day before";
    const result = try drivers(arena, ctx.db, view, start, end, start - shift, end - shift);
    const total = result.current - result.previous;
    var reasons: []const []const u8 = &.{};
    var headline: []const u8 = "";
    var cost_micro: i64 = 0;
    var ai_error: []const u8 = "";
    if (result.list.len != 0) ai: {
        const config = forPerson(arena, ctx.shared, ctx.db, ctx.user.?.id, ctx.now()) catch |err| {
            if (err != error.AiNotConfigured) ai_error = errorText(err);
            break :ai;
        };
        const sent = try driversText(arena, result, label, base_label, config.share_paths, config.share_sources);
        ctx.extendDeadline(60);
        const reply = call(arena, ctx.shared.io, config, why_system, sent, 400) catch |err| {
            ai_error = errorText(err);
            break :ai;
        };
        cost_micro = cost(config, reply.input_tokens, reply.output_tokens);
        if (jsonObject(arena, reply.text)) |object| {
            headline = jsonString(object, "headline");
            if (object.get("reasons")) |value| if (value == .array) {
                var list: std.ArrayList([]const u8) = .empty;
                for (value.array.items) |item| if (item == .string) try list.append(arena, item.string);
                reasons = list.items;
            };
        }
        const db = ctx.shared.lockWrite();
        defer ctx.shared.unlockWrite();
        _ = try log(arena, db, ctx.now(), .{ .origin = "Why?", .site_id = site.id, .question = try std.fmt.allocPrint(arena, "Why did {s} change?", .{label}), .data_used = "Sources, pages, devices · 2 periods", .model = try logModel(arena, config), .input_tokens = reply.input_tokens, .output_tokens = reply.output_tokens, .cost_micro = cost_micro, .payload = sent, .answer = reply.text });
    }
    const w = ctx.w();
    const verb = if (total >= 0) "rise" else "drop";
    try w.writeAll("<div class=\"row-between mb-10\"><div class=\"row nowrap\"><span class=\"badge badge-brand\">");
    try icon(w, "sparkles");
    try render(w, "</span><strong>Why did {label} {verb}?</strong></div><button class=\"btn btn-quiet btn-icon\" type=\"button\" data-close-why aria-label=\"Close\">", .{ .label = label, .verb = verb });
    try icon(w, "x");
    try render(w, "</button></div><p class=\"t-13 mb-12\">{sign}{change} views vs {base}.{space}{headline}</p>", .{ .sign = if (total >= 0) "+" else "−", .change = @abs(total), .base = base_label, .space = if (headline.len != 0) " " else "", .headline = headline });
    for (result.list, 0..) |driver, position| {
        const share = if (total == 0) 0 else @as(f64, @floatFromInt(driver.delta)) / @as(f64, @floatFromInt(total)) * 100;
        const tone = ui.tones[position % ui.tones.len];
        try render(w, "<div class=\"driver mb-10\"><div class=\"row-between t-13\"><strong>{label}</strong><strong>{sign}{delta} · {share:.0}%</strong></div><small class=\"secondary t-12\">{reason}</small><div class=\"track\"><span style=\"width:{width:.0}%;background:{color}\"></span></div></div>", .{
            .label = try driverLabel(arena, driver),
            .sign = if (driver.delta >= 0) "+" else "−",
            .delta = @abs(driver.delta),
            .share = @abs(share),
            .reason = if (position < reasons.len) reasons[position] else try std.fmt.allocPrint(arena, "{s} · {d} vs {d}", .{ driver.dim.label(), driver.current, driver.previous }),
            .width = @min(100, @abs(share)),
            .color = tone.color,
        });
    }
    if (result.list.len == 0) try w.writeAll("<p class=\"hint\">No single source, page or device stands out.</p>");
    if (result.bot_share < 0.3) {
        try w.writeAll("<div class=\"callout callout-good callout-tight\">");
        try icon(w, "check");
        try w.writeAll("<span>Not a tracking glitch — bot traffic was normal.</span></div>");
    } else {
        try render(w, "<div class=\"callout callout-warn callout-tight\"><span>{share:.0}% of raw traffic in this window was bots (filtered from reports).</span></div>", .{ .share = result.bot_share * 100 });
    }
    if (ai_error.len != 0) try render(w, "<p class=\"hint mb-10\">{problem}</p>", .{ .problem = ai_error });
    try render(w, "<div class=\"row-between\"><div class=\"row\"><button class=\"btn btn-primary\" type=\"button\" data-dialog=\"note-dialog\" data-note-day=\"{day}\">Add a note</button><button class=\"btn\" type=\"button\" data-palette data-question=\"Why did {label} {verb}?\">Ask follow-up</button></div>", .{ .day = &data.dateText(start), .label = label, .verb = verb });
    if (cost_micro > 0) try render(w, "<span class=\"hint\">≈${cost:.3}</span>", .{ .cost = @as(f64, @floatFromInt(cost_micro)) / 1_000_000 });
    try w.writeAll("</div>");
    return ctx.finish("text/html; charset=utf-8");
}

/// Explains a triggered alert: yesterday against the day before.
/// `config` is null without AI: the explanation is then the numbers alone.
pub fn triageText(arena: std.mem.Allocator, io: std.Io, db: *db_mod.Db, maybe_config: ?Config, site: data.Site, filters: []const u8, now_ms: i64) !struct { text: []const u8, log: ?LogEntry } {
    const today = now_ms - @mod(now_ms, data.day_ms);
    const params = try html.Params.parse(arena, filters);
    const view = try data.View.parse(arena, site, params, now_ms);
    const result = try drivers(arena, db, view, today - data.day_ms, today, today - 2 * data.day_ms, today - data.day_ms);
    var deterministic: std.Io.Writer.Allocating = .init(arena);
    const total = result.current - result.previous;
    try deterministic.writer.print("{s}{d} page views vs the day before.", .{ if (total >= 0) "+" else "−", @abs(total) });
    for (result.list, 0..) |driver, index| {
        try deterministic.writer.print("{s} {s} {s}{d}", .{ if (index == 0) " Mostly" else ",", try driverLabel(arena, driver), if (driver.delta >= 0) "+" else "−", @abs(driver.delta) });
    }
    if (result.list.len != 0) try deterministic.writer.writeByte('.');
    const config = maybe_config orelse return .{ .text = deterministic.written(), .log = null };
    const sent = try driversText(arena, result, "yesterday", "The day before", config.share_paths, config.share_sources);
    const reply = call(arena, io, config, why_system, sent, 300) catch return .{ .text = deterministic.written(), .log = null };
    const object = jsonObject(arena, reply.text) orelse return .{ .text = deterministic.written(), .log = null };
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll(jsonString(object, "headline"));
    if (object.get("reasons")) |value| if (value == .array) for (value.array.items, 0..) |item, index| {
        if (item != .string or index >= result.list.len) continue;
        try out.writer.print(" {s}: {s}.", .{ try driverLabel(arena, result.list[index]), std.mem.trimEnd(u8, item.string, ".") });
    };
    return .{ .text = out.written(), .log = .{ .origin = "Alert triage", .site_id = site.id, .question = "Why did this alert trigger?", .data_used = "Sources, pages, devices · 2 days", .model = try logModel(arena, config), .input_tokens = reply.input_tokens, .output_tokens = reply.output_tokens, .cost_micro = cost(config, reply.input_tokens, reply.output_tokens), .payload = sent, .answer = reply.text } };
}

fn triage(ctx: *Ctx, site: data.Site, alert_id: i64) !void {
    const arena = ctx.arena;
    var statement = try ctx.db.prepare(arena, "SELECT filters FROM alerts WHERE id=? AND site_id=?");
    defer statement.deinit();
    try statement.bindInt(1, alert_id);
    try statement.bindInt(2, site.id);
    if (try statement.step() != .row) return layout.message(ctx, .not_found, "Alert not found", "It may have been deleted.");
    const filters = try arena.dupe(u8, statement.columnText(0));
    ctx.extendDeadline(60);
    const config = forPerson(arena, ctx.shared, ctx.db, ctx.user.?.id, ctx.now()) catch null;
    const result = try triageText(arena, ctx.shared.io, ctx.db, config, site, filters, ctx.now());
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    if (result.log) |entry| _ = try log(arena, db, ctx.now(), entry);
    try db.run(arena, "UPDATE alerts SET triage=? WHERE id=?", .{ result.text, alert_id });
    return ctx.redirect(overview.referer(ctx, site));
}

// ---------------------------------------------------------------- digest

const digest_system =
    \\You write the opening paragraph of a scheduled analytics email for a website owner.
    \\Using only the numbers provided, write 2 or 3 plain sentences: the headline change, what drove it, and one thing worth checking. No greeting, no markdown.
;

/// A short AI-written summary for scheduled emails, or null without AI.
pub fn digest(arena: std.mem.Allocator, shared: *Shared, db: *db_mod.Db, view: data.View, now_ms: i64) !?struct { text: []const u8, log: LogEntry } {
    const config = forBackground(arena, shared, db, now_ms) catch return null;
    const sent = try packet(arena, db, view, config.share_paths, config.share_sources);
    const reply = call(arena, shared.io, config, digest_system, sent, 300) catch return null;
    return .{ .text = std.mem.trim(u8, reply.text, " \n"), .log = .{ .origin = "Scheduled email", .site_id = view.site.id, .question = "Summarize this period", .data_used = try dataUsed(arena, view), .model = try logModel(arena, config), .input_tokens = reply.input_tokens, .output_tokens = reply.output_tokens, .cost_micro = cost(config, reply.input_tokens, reply.output_tokens), .payload = sent, .answer = reply.text } };
}

test "strip parameter" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("/a?range=7d", try stripParam(arena.allocator(), "/a?ask=4&range=7d", "ask"));
    try std.testing.expectEqualStrings("/a", try stripParam(arena.allocator(), "/a?ask=4", "ask"));
}
