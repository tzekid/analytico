//! Talking to the AI providers, for every feature: OpenAI's Responses API
//! (ChatGPT plan or API key), Anthropic Messages, or any OpenAI-compatible
//! chat completions endpoint. With a `Scope`, the model may call the report
//! catalog as tools, in-process and within "What the AI can see", for up to
//! six rounds; text streams to a `Sink` as it arrives.
const std = @import("std");
const net = @import("../net.zig");
const ai = @import("ai.zig");
const catalog = @import("catalog.zig");
const data = @import("data.zig");
const db_mod = @import("../db.zig");
const html = @import("html.zig");

pub const Event = union(enum) {
    delta: []const u8,
    /// A tool started, described for people ("Pages · 30 days").
    tool: []const u8,
};

pub const Sink = struct {
    context: *anyopaque,
    emitFn: *const fn (*anyopaque, Event) anyerror!void,

    fn emit(self: ?Sink, event: Event) !void {
        if (self) |sink| try sink.emitFn(sink.context, event);
    }
};

/// What tools may read: one website, as "What the AI can see" allows.
pub const Scope = struct { db: *db_mod.Db, site: data.Site, now_ms: i64, paths: bool, sources: bool };

pub const Result = struct {
    text: []const u8,
    input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    /// Tool calls and their results, for the AI log.
    tools: []const u8 = "",
};

const max_rounds = 6;

pub fn run(arena: std.mem.Allocator, config: ai.Config, instructions: []const u8, input: []const u8, scope: ?Scope, sink: ?Sink, max_tokens: u32) !Result {
    return switch (config.provider) {
        .openai, .chatgpt => responses(arena, config, instructions, input, scope, sink, max_tokens),
        .anthropic => messages(arena, config, instructions, input, scope, sink, max_tokens),
        .compatible => {
            const result = try chat(arena, config, instructions, input, max_tokens);
            try Sink.emit(sink, .{ .delta = result.text });
            return result;
        },
    };
}

fn json(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.written();
}

fn bearer(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "Bearer {s}", .{key});
}

// ---------------------------------------------------------------- tools

pub const ToolOutput = struct { text: []const u8, used: []const u8 };

/// Runs one catalog report (or the overview packet) for a website. Problems
/// the model can fix come back as text.
pub fn tool(arena: std.mem.Allocator, db: *db_mod.Db, site: data.Site, name: []const u8, arguments: std.json.ObjectMap, paths: bool, sources: bool, now_ms: i64) !ToolOutput {
    const overview = std.mem.eql(u8, name, "site_overview");
    const report = if (overview) null else catalog.find(name) orelse return error.UnknownTool;
    // Period and filters; a filter on a hidden dimension would let the model probe for its values.
    var query: std.Io.Writer.Allocating = .init(arena);
    try query.writer.print("range={f}", .{html.url(argString(arguments, "range") orelse if (overview) "7d" else "30d")});
    if (argString(arguments, "from")) |from| try query.writer.print("&range=custom&from={f}&to={f}", .{ html.url(from), html.url(argString(arguments, "to") orelse "") });
    if (arguments.get("filters")) |filters| if (filters == .array) for (filters.array.items) |item| {
        if (item == .string and !hiddenFilter(item.string, paths, sources)) try query.writer.print("&f={f}", .{html.url(item.string)});
    };
    if (report) |value| try query.writer.writeAll(try catalog.reportParams(arena, value, arguments));
    const params = try html.Params.parse(arena, query.written());
    if (report == null) {
        const view = try data.View.parse(arena, site, params, now_ms);
        return .{ .text = try ai.packet(arena, db, view, paths, sources), .used = try ai.dataUsed(arena, view) };
    }
    if (!revealed(report.?, arguments, paths, sources)) return .{ .text = "This instance doesn't share that with AI tools (Settings → AI → What the AI can see).", .used = "None" };
    const table = catalog.run(arena, db, report.?, site, params, now_ms) catch |err| return .{ .used = "None", .text = switch (err) {
        error.MissingParameter => "A required parameter is missing; see the tool's input schema.",
        error.SessionModeRequired => "This report needs a website in Session or Full mode.",
        error.UnsupportedFilter => "This report filters by page, campaign and release only.",
        else => return err,
    } };
    const view = try catalog.view(arena, site, params, now_ms);
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("{s} for {s}, {f}\n", .{ report.?.title, site.title(), view.range });
    try catalog.render(&out.writer, table, .text);
    return .{ .text = out.written(), .used = try std.fmt.allocPrint(arena, "{s} · {d:.0} days", .{ report.?.title, view.range.days() }) };
}

pub fn argString(arguments: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = arguments.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

pub fn hiddenFilter(filter: []const u8, paths: bool, sources: bool) bool {
    const split = std.mem.findScalar(u8, filter, ':') orelse return false;
    const dim = std.meta.stringToEnum(data.Dim, std.mem.trimEnd(u8, filter[0..split], "!")) orelse return false;
    return (dim == .page and !paths) or ((dim == .source or dim == .campaign) and !sources);
}

/// Whether "What the AI can see" allows this report (and, for breakdowns,
/// this dimension).
fn revealed(report: *const catalog.Report, arguments: std.json.ObjectMap, paths: bool, sources: bool) bool {
    if (std.mem.eql(u8, report.name, "breakdown")) {
        const dim = std.meta.stringToEnum(data.Dim, argString(arguments, "dimension") orelse "page") orelse return true;
        return !((dim == .page and !paths) or ((dim == .source or dim == .campaign) and !sources));
    }
    return switch (report.reveals) {
        .counts => true,
        .paths => paths,
        .sources => sources,
        .paths_and_sources => paths and sources,
    };
}

/// Function definitions for the catalog, without the website (the scope fixes it).
fn toolList(w: *std.Io.Writer, comptime style: enum { responses, anthropic }) !void {
    for (&catalog.reports, 0..) |*report, index| {
        if (index != 0) try w.writeByte(',');
        try w.writeAll(if (style == .responses) "{\"type\":\"function\",\"name\":" else "{\"name\":");
        try std.json.Stringify.value(report.name, .{}, w);
        try w.writeAll(",\"description\":");
        try std.json.Stringify.value(report.description, .{}, w);
        try w.writeAll(if (style == .responses) ",\"parameters\":" else ",\"input_schema\":");
        try catalog.schema(w, report, false);
        try w.writeByte('}');
    }
}

const Call = struct { id: []const u8, name: []const u8, arguments: []const u8, namespace: []const u8 = "" };

/// Runs a round's tool calls; each result goes back to the model as text.
fn runCalls(arena: std.mem.Allocator, scope: Scope, calls: []const Call, sink: ?Sink, log: *std.Io.Writer) ![]const []const u8 {
    const outputs = try arena.alloc([]const u8, calls.len);
    for (calls, outputs) |call, *output| {
        const name = if (std.mem.startsWith(u8, call.name, "analytico.")) call.name["analytico.".len..] else call.name;
        const arguments: std.json.ObjectMap = net.parseObject(arena, if (call.arguments.len == 0) "{}" else call.arguments) orelse .empty;
        const result: ToolOutput = tool(arena, scope.db, scope.site, name, arguments, scope.paths, scope.sources, scope.now_ms) catch |err| switch (err) {
            error.UnknownTool => .{ .text = "No such tool.", .used = "None" },
            else => return err,
        };
        try Sink.emit(sink, .{ .tool = result.used });
        try log.print("\n\n[{s} {s}]\n{s}", .{ name, call.arguments, result.text });
        output.* = result.text;
    }
    return outputs;
}

// ---------------------------------------------------------------- errors

/// Plan errors stop inference; none falls back to another provider.
fn codeError(code: []const u8) ?anyerror {
    const Entry = struct { []const u8, anyerror };
    const table = [_]Entry{
        .{ "subscription_sharing_usage_limit_exceeded", error.AiPlanLimit },
        .{ "subscription_sharing_user_not_eligible", error.AiPlanIneligible },
        .{ "subscription_sharing_usage_unavailable", error.AiPlanUnavailable },
        .{ "subscription_sharing_user_unavailable", error.AiPlanUnavailable },
        .{ "subscription_sharing_invalid_user", error.AiSignInAgain },
        .{ "rate_limit_error", error.AiRateLimited },
        .{ "overloaded_error", error.AiPlanUnavailable },
        .{ "authentication_error", error.AiKeyRejected },
        .{ "model_not_found", error.AiModelNotFound },
    };
    for (table) |entry| if (std.mem.eql(u8, entry[0], code)) return entry[1];
    return null;
}

fn errorCode(object: std.json.ObjectMap) []const u8 {
    const inner = net.object(object, "error") orelse return net.string(object, "code");
    const code = net.string(inner, "code");
    return if (code.len != 0) code else net.string(inner, "type");
}

fn httpError(arena: std.mem.Allocator, provider: ai.Provider, response: net.Response) anyerror {
    std.log.warn("ai_request_rejected provider={s} status={d} body={s}", .{ @tagName(provider), @backingInt(response.status), response.body[0..@min(response.body.len, 300)] });
    if (net.parseObject(arena, response.body)) |object| if (codeError(errorCode(object))) |err| return err;
    return switch (response.status) {
        .unauthorized => if (provider == .chatgpt) error.AiSignInAgain else error.AiKeyRejected,
        .forbidden => error.AiKeyRejected,
        .not_found => error.AiModelNotFound,
        .too_many_requests => error.AiRateLimited,
        .service_unavailable => error.AiPlanUnavailable,
        else => error.AiFailed,
    };
}

// ---------------------------------------------------------------- Responses

const ResponsesStream = struct {
    arena: std.mem.Allocator,
    sink: ?Sink,
    text: *std.ArrayList(u8),
    calls: std.ArrayList(Call) = .empty,
    completed: bool = false,
    failure: ?anyerror = null,
    input_tokens: i64 = 0,
    output_tokens: i64 = 0,

    pub fn event(self: *ResponsesStream, _: []const u8, payload: []const u8) !void {
        const object = net.parseObject(self.arena, payload) orelse return;
        const kind = net.string(object, "type");
        if (std.mem.eql(u8, kind, "response.output_text.delta")) {
            const delta = net.string(object, "delta");
            try self.text.appendSlice(self.arena, delta);
            try Sink.emit(self.sink, .{ .delta = delta });
        } else if (std.mem.eql(u8, kind, "response.output_item.done")) {
            const item = net.object(object, "item") orelse return;
            if (!std.mem.eql(u8, net.string(item, "type"), "function_call")) return;
            try self.calls.append(self.arena, .{ .id = net.string(item, "call_id"), .name = net.string(item, "name"), .arguments = net.string(item, "arguments"), .namespace = net.string(item, "namespace") });
        } else if (std.mem.eql(u8, kind, "response.completed")) {
            self.completed = true;
            const usage = net.object(net.object(object, "response") orelse return, "usage") orelse return;
            self.input_tokens += net.int(usage, "input_tokens");
            self.output_tokens += net.int(usage, "output_tokens");
        } else if (std.mem.eql(u8, kind, "response.failed")) {
            const code = errorCode(net.object(object, "response") orelse object);
            std.log.warn("ai_response_failed code={s}", .{code});
            self.failure = codeError(code) orelse error.AiFailed;
        } else if (std.mem.eql(u8, kind, "response.incomplete")) {
            self.failure = error.AiIncomplete;
        } else if (std.mem.eql(u8, kind, "error")) {
            const code = errorCode(object);
            std.log.warn("ai_stream_error code={s}", .{code});
            self.failure = codeError(code) orelse error.AiFailed;
        }
    }
};

fn responses(arena: std.mem.Allocator, config: ai.Config, instructions: []const u8, input: []const u8, scope: ?Scope, sink: ?Sink, max_tokens: u32) !Result {
    const plan = config.provider == .chatgpt;
    const url = if (plan) try std.fmt.allocPrint(arena, "{s}/responses", .{config.base_url}) else "https://api.openai.com/v1/responses";
    var items: std.ArrayList([]const u8) = .empty;
    try items.append(arena, try json(arena, .{ .role = "user", .content = input }));
    var text: std.ArrayList(u8) = .empty;
    var log: std.Io.Writer.Allocating = .init(arena);
    var result: Result = .{ .text = "" };
    for (0..max_rounds) |_| {
        var body: std.Io.Writer.Allocating = .init(arena);
        const w = &body.writer;
        try w.print("{{\"model\":{f},\"instructions\":{f},\"stream\":true,\"store\":false,\"input\":[", .{ std.json.fmt(config.model, .{}), std.json.fmt(instructions, .{}) });
        for (items.items, 0..) |item, index| {
            if (index != 0) try w.writeByte(',');
            try w.writeAll(item);
        }
        try w.writeByte(']');
        // The plan takes no output limit and wants functions in a namespace.
        // Reasoning models spend part of the limit thinking.
        if (!plan) try w.print(",\"max_output_tokens\":{d}", .{@max(max_tokens, 4000)});
        if (scope != null) {
            try w.writeAll(if (plan) ",\"tools\":[{\"type\":\"namespace\",\"name\":\"analytico\",\"description\":\"Read-only reports for this website\",\"tools\":[" else ",\"tools\":[");
            try toolList(w, .responses);
            try w.writeAll(if (plan) "]}]" else "]");
        }
        try w.writeByte('}');
        var stream: ResponsesStream = .{ .arena = arena, .sink = sink, .text = &text };
        const response = net.stream(arena, url, .{ .method = .POST, .body = body.written(), .headers = &.{ .{ .name = "authorization", .value = try bearer(arena, config.key) }, .{ .name = "accept", .value = "text/event-stream" } } }, &stream) catch |err| switch (err) {
            error.Unreachable => return error.AiUnreachable,
            else => return err,
        };
        if (response.status != .ok) return httpError(arena, config.provider, response);
        if (stream.failure) |err| return err;
        // Only a completed response counts.
        if (!stream.completed) return error.AiFailed;
        result.input_tokens += stream.input_tokens;
        result.output_tokens += stream.output_tokens;
        if (stream.calls.items.len == 0 or scope == null) {
            result.text = text.items;
            result.tools = log.written();
            return result;
        }
        const outputs = try runCalls(arena, scope.?, stream.calls.items, sink, &log.writer);
        // No stored conversation: the calls and their results go back in full.
        for (stream.calls.items, outputs) |call, output| {
            if (call.namespace.len != 0) {
                try items.append(arena, try json(arena, .{ .type = "function_call", .call_id = call.id, .namespace = call.namespace, .name = call.name, .arguments = call.arguments }));
            } else try items.append(arena, try json(arena, .{ .type = "function_call", .call_id = call.id, .name = call.name, .arguments = call.arguments }));
            try items.append(arena, try json(arena, .{ .type = "function_call_output", .call_id = call.id, .output = output }));
        }
    }
    return error.AiTooManySteps;
}

// ---------------------------------------------------------------- Anthropic

const Block = struct { tool: bool, id: []const u8 = "", name: []const u8 = "", input: std.ArrayList(u8) = .empty, text: std.ArrayList(u8) = .empty };

const MessagesStream = struct {
    arena: std.mem.Allocator,
    sink: ?Sink,
    text: *std.ArrayList(u8),
    blocks: std.ArrayList(Block) = .empty,
    completed: bool = false,
    failure: ?anyerror = null,
    input_tokens: i64 = 0,
    output_tokens: i64 = 0,

    fn block(self: *MessagesStream, object: std.json.ObjectMap) ?*Block {
        const index: usize = @intCast(@max(0, net.int(object, "index")));
        return if (index < self.blocks.items.len) &self.blocks.items[index] else null;
    }

    pub fn event(self: *MessagesStream, _: []const u8, payload: []const u8) !void {
        const object = net.parseObject(self.arena, payload) orelse return;
        const kind = net.string(object, "type");
        if (std.mem.eql(u8, kind, "message_start")) {
            const usage = net.object(net.object(object, "message") orelse return, "usage") orelse return;
            self.input_tokens += net.int(usage, "input_tokens");
        } else if (std.mem.eql(u8, kind, "content_block_start")) {
            const content = net.object(object, "content_block") orelse return;
            const is_tool = std.mem.eql(u8, net.string(content, "type"), "tool_use");
            try self.blocks.append(self.arena, .{ .tool = is_tool, .id = net.string(content, "id"), .name = net.string(content, "name") });
        } else if (std.mem.eql(u8, kind, "content_block_delta")) {
            const target = self.block(object) orelse return;
            const delta = net.object(object, "delta") orelse return;
            if (std.mem.eql(u8, net.string(delta, "type"), "text_delta")) {
                const piece = net.string(delta, "text");
                try target.text.appendSlice(self.arena, piece);
                try self.text.appendSlice(self.arena, piece);
                try Sink.emit(self.sink, .{ .delta = piece });
            } else if (std.mem.eql(u8, net.string(delta, "type"), "input_json_delta")) {
                try target.input.appendSlice(self.arena, net.string(delta, "partial_json"));
            }
        } else if (std.mem.eql(u8, kind, "message_delta")) {
            if (net.object(object, "usage")) |usage| self.output_tokens += net.int(usage, "output_tokens");
        } else if (std.mem.eql(u8, kind, "message_stop")) {
            self.completed = true;
        } else if (std.mem.eql(u8, kind, "error")) {
            self.failure = codeError(errorCode(object)) orelse error.AiFailed;
        }
    }
};

fn messages(arena: std.mem.Allocator, config: ai.Config, instructions: []const u8, input: []const u8, scope: ?Scope, sink: ?Sink, max_tokens: u32) !Result {
    var turns: std.ArrayList([]const u8) = .empty;
    try turns.append(arena, try json(arena, .{ .role = "user", .content = input }));
    var text: std.ArrayList(u8) = .empty;
    var log: std.Io.Writer.Allocating = .init(arena);
    var result: Result = .{ .text = "" };
    for (0..max_rounds) |_| {
        var body: std.Io.Writer.Allocating = .init(arena);
        const w = &body.writer;
        try w.print("{{\"model\":{f},\"max_tokens\":{d},\"system\":{f},\"stream\":true,\"messages\":[", .{ std.json.fmt(config.model, .{}), max_tokens, std.json.fmt(instructions, .{}) });
        for (turns.items, 0..) |turn, index| {
            if (index != 0) try w.writeByte(',');
            try w.writeAll(turn);
        }
        try w.writeByte(']');
        if (scope != null) {
            try w.writeAll(",\"tools\":[");
            try toolList(w, .anthropic);
            try w.writeByte(']');
        }
        try w.writeByte('}');
        var stream: MessagesStream = .{ .arena = arena, .sink = sink, .text = &text };
        const url = if (config.base_url.len != 0) try std.fmt.allocPrint(arena, "{s}/messages", .{config.base_url}) else "https://api.anthropic.com/v1/messages";
        const response = net.stream(arena, url, .{ .method = .POST, .body = body.written(), .headers = &.{ .{ .name = "x-api-key", .value = config.key }, .{ .name = "anthropic-version", .value = "2023-06-01" }, .{ .name = "accept", .value = "text/event-stream" } } }, &stream) catch |err| switch (err) {
            error.Unreachable => return error.AiUnreachable,
            else => return err,
        };
        if (response.status != .ok) return httpError(arena, config.provider, response);
        if (stream.failure) |err| return err;
        if (!stream.completed) return error.AiFailed;
        result.input_tokens += stream.input_tokens;
        result.output_tokens += stream.output_tokens;
        var calls: std.ArrayList(Call) = .empty;
        for (stream.blocks.items) |item| if (item.tool) try calls.append(arena, .{ .id = item.id, .name = item.name, .arguments = item.input.items });
        if (calls.items.len == 0 or scope == null) {
            result.text = text.items;
            result.tools = log.written();
            return result;
        }
        const outputs = try runCalls(arena, scope.?, calls.items, sink, &log.writer);
        var assistant: std.Io.Writer.Allocating = .init(arena);
        try assistant.writer.writeAll("{\"role\":\"assistant\",\"content\":[");
        var first = true;
        for (stream.blocks.items) |item| {
            if (!item.tool and item.text.items.len == 0) continue;
            if (!first) try assistant.writer.writeByte(',');
            first = false;
            if (item.tool) {
                try assistant.writer.print("{{\"type\":\"tool_use\",\"id\":{f},\"name\":{f},\"input\":{s}}}", .{ std.json.fmt(item.id, .{}), std.json.fmt(item.name, .{}), if (net.parseObject(arena, item.input.items) != null) item.input.items else "{}" });
            } else try assistant.writer.print("{{\"type\":\"text\",\"text\":{f}}}", .{std.json.fmt(item.text.items, .{})});
        }
        try assistant.writer.writeAll("]}");
        try turns.append(arena, assistant.written());
        var results: std.Io.Writer.Allocating = .init(arena);
        try results.writer.writeAll("{\"role\":\"user\",\"content\":[");
        for (calls.items, outputs, 0..) |call, output, index| {
            if (index != 0) try results.writer.writeByte(',');
            try results.writer.print("{{\"type\":\"tool_result\",\"tool_use_id\":{f},\"content\":{f}}}", .{ std.json.fmt(call.id, .{}), std.json.fmt(output, .{}) });
        }
        try results.writer.writeAll("]}");
        try turns.append(arena, results.written());
    }
    return error.AiTooManySteps;
}

// ---------------------------------------------------------------- chat completions

/// OpenAI-compatible endpoints (local models and gateways): one call, no tools.
fn chat(arena: std.mem.Allocator, config: ai.Config, instructions: []const u8, input: []const u8, max_tokens: u32) !Result {
    const url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{std.mem.trimEnd(u8, config.base_url, "/")});
    const body = try json(arena, .{
        .model = config.model,
        .max_completion_tokens = max_tokens,
        .messages = &[_]struct { role: []const u8, content: []const u8 }{ .{ .role = "system", .content = instructions }, .{ .role = "user", .content = input } },
    });
    const headers: []const std.http.Header = if (config.key.len != 0) &.{.{ .name = "authorization", .value = try bearer(arena, config.key) }} else &.{};
    const response = net.send(arena, url, .{ .method = .POST, .body = body, .headers = headers }) catch return error.AiUnreachable;
    if (response.status != .ok) return httpError(arena, config.provider, response);
    const object = net.parseObject(arena, response.body) orelse return error.AiFailed;
    const choices = net.array(object, "choices");
    if (choices.len == 0 or choices[0] != .object) return error.AiFailed;
    const message = net.object(choices[0].object, "message") orelse return error.AiFailed;
    const usage = net.object(object, "usage");
    return .{
        .text = net.string(message, "content"),
        .input_tokens = if (usage) |value| net.int(value, "prompt_tokens") else 0,
        .output_tokens = if (usage) |value| net.int(value, "completion_tokens") else 0,
    };
}
