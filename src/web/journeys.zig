//! Funnels, Sessions & paths, Audience and Performance.
const std = @import("std");
const analyze = @import("analyze.zig");
const chart = @import("chart.zig");
const ctx_mod = @import("ctx.zig");
const data = @import("data.zig");
const db_mod = @import("../db.zig");
const domain = @import("../domain.zig");
const html = @import("html.zig");
const layout = @import("layout.zig");
const ui = @import("ui.zig");
const overview = @import("overview.zig");

const Ctx = ctx_mod.Ctx;
const esc = html.esc;
const icon = layout.icon;
const render = html.render;

pub fn sessionModeNotice(ctx: *Ctx, site: data.Site, what: []const u8) !void {
    const w = ctx.w();
    try w.writeAll("<div class=\"card\">");
    try ui.empty(w, try std.fmt.allocPrint(ctx.arena, "{s} need Full or Session mode", .{what}), "Lite mode never links page views together, so there are no visits to follow. Full mode links them for visitors who consent; Session mode uses an anonymous per-tab ID.", try html.print(ctx.arena, "<a class=\"btn btn-primary\" href=\"/settings/sites?site={slug}\">Change the tracking mode</a>", .{ .slug = site.slug }));
    try w.writeAll("</div>");
}

// ---------------------------------------------------------------- Funnels

pub const Step = struct { kind: []const u8, value: []const u8 };

fn loadSteps(ctx: *Ctx, funnel_id: i64) ![]Step {
    return ctx.db.all(ctx.arena, Step, "SELECT kind,match_value FROM funnel_steps WHERE funnel_id=? ORDER BY step_index", .{funnel_id});
}

const Progress = struct { next: usize, started: i64 };

/// Sessions reaching each step in order within `window_ms` of the first step.
pub fn computeFunnel(ctx: *Ctx, view: data.View, steps: []const Step, window_ms: i64) ![]i64 {
    const counts = try ctx.arena.alloc(i64, steps.len);
    @memset(counts, 0);
    if (steps.len == 0) return counts;
    var sql = data.Sql.init(ctx.arena);
    try sql.add("SELECT session_id,occurred_at_ms,kind,value FROM (SELECT pv.session_id,pv.occurred_at_ms,'path' kind,pv.path value FROM page_views pv WHERE pv.internal=0 AND pv.traffic_class IN ('human_like','unknown') AND pv.site_id=");
    try sql.int(view.site.id);
    try sql.add(" AND pv.received_at_ms>=");
    try sql.int(view.range.start_ms);
    try sql.add(" AND pv.received_at_ms<");
    try sql.int(view.range.end_ms);
    try sql.add(" AND pv.session_id IS NOT NULL UNION ALL SELECT e.session_id,e.occurred_at_ms,'event',e.name FROM events e WHERE e.internal=0 AND e.site_id=");
    try sql.int(view.site.id);
    try sql.add(" AND e.received_at_ms>=");
    try sql.int(view.range.start_ms);
    try sql.add(" AND e.received_at_ms<");
    try sql.int(view.range.end_ms);
    try sql.add(" AND e.session_id IS NOT NULL) t");
    if (view.filters.len != 0) {
        try sql.add(" WHERE t.session_id IN (SELECT pv.session_id FROM page_views pv WHERE ");
        try sql.pageViews(view, view.range.start_ms, view.range.end_ms);
        try sql.add(")");
    }
    try sql.add(" ORDER BY session_id,occurred_at_ms");
    var statement = try sql.prepare(ctx.db);
    defer statement.deinit();
    var progress = std.StringHashMap(Progress).init(ctx.arena);
    while (try statement.step() == .row) {
        const session = statement.columnText(0);
        const occurred = statement.columnInt(1);
        const kind = statement.columnText(2);
        const value = statement.columnText(3);
        if (progress.getPtr(session)) |state| {
            if (state.next >= steps.len or occurred - state.started > window_ms) continue;
            const expected = steps[state.next];
            if (std.mem.eql(u8, kind, expected.kind) and std.mem.eql(u8, value, expected.value)) {
                counts[state.next] += 1;
                state.next += 1;
            }
        } else if (std.mem.eql(u8, kind, steps[0].kind) and std.mem.eql(u8, value, steps[0].value)) {
            counts[0] += 1;
            try progress.put(try ctx.arena.dupe(u8, session), .{ .next = 1, .started = occurred });
        }
    }
    return counts;
}

fn stepLabel(ctx: *Ctx, site: data.Site, step: Step) ![]const u8 {
    return try ctx.db.scalar(ctx.arena, ?[]const u8, "SELECT name FROM goals WHERE site_id=? AND kind=? AND match_value=? LIMIT 1", .{ site.id, step.kind, step.value }) orelse step.value;
}

pub fn funnels(ctx: *Ctx, site: data.Site, id: ?i64) !void {
    const arena = ctx.arena;
    const view = try analyze.start(ctx, site, .funnels, "Funnels");
    const w = ctx.w();
    if (site.mode == .lite) {
        try layout.head(ctx, .{ .title = "Funnels", .subtitle = "Where visitors drop off on the way to a goal" });
        try sessionModeNotice(ctx, site, "Funnels");
        return layout.end(ctx);
    }
    if (id) |funnel_id| {
        const funnel = try ctx.db.one(arena, struct { name: []const u8, window: i64 }, "SELECT name,window_ms FROM funnels WHERE id=? AND site_id=?", .{ funnel_id, site.id }) orelse return layout.message(ctx, .not_found, "Funnel not found", "It may have been deleted.");
        const name = funnel.name;
        const window_ms = funnel.window;
        const steps = try loadSteps(ctx, funnel_id);
        const path = try std.fmt.allocPrint(arena, "/{s}/funnels/{d}", .{ site.slug, funnel_id });
        const saved = if (ctx.param("saved") != null) "<span class=\"saved\">✓ Saved</span>" else "";
        try layout.head(ctx, .{ .title = name, .badge = saved, .subtitle = try std.fmt.allocPrint(arena, "{f}", .{view.range}), .view = view, .path = path });
        try w.writeAll("<div class=\"grid split-builder\">");
        try builder(ctx, site, try std.fmt.allocPrint(arena, "/{s}/funnels/{d}/save", .{ site.slug, funnel_id }), name, steps, window_ms, false);
        try result(ctx, view, steps, window_ms);
        try render(w, "</div><form class=\"mt-16\" method=\"post\" action=\"/{slug}/funnels/{id}/delete\" data-undo=\"Funnel deleted\"><button class=\"btn btn-quiet\">", .{ .slug = site.slug, .id = funnel_id });
        try icon(w, "trash");
        try w.writeAll("Delete funnel</button></form>");
        return layout.end(ctx);
    }
    const path = try std.fmt.allocPrint(arena, "/{s}/funnels", .{site.slug});
    try layout.head(ctx, .{ .title = "Funnels", .subtitle = try std.fmt.allocPrint(arena, "Where visitors drop off on the way to a goal · {f}", .{view.range}), .view = view, .path = path });
    const tab = ctx.param("tab") orelse "funnels";
    try ui.tabs(ctx.w(), ctx.arena, view, path, "tab", &.{ .{ "funnels", "Funnels" }, .{ "forms", "Forms" } }, tab);
    if (std.mem.eql(u8, tab, "forms")) {
        try forms(ctx, view, path);
        return layout.end(ctx);
    }
    try w.writeAll("<div class=\"grid grid-3\">");
    for (try ctx.db.all(arena, struct { id: i64, name: []const u8, window: i64 }, "SELECT id,name,window_ms FROM funnels WHERE site_id=? ORDER BY name", .{site.id})) |funnel| {
        const steps = try loadSteps(ctx, funnel.id);
        const counts = try computeFunnel(ctx, view, steps, funnel.window);
        const end_to_end = if (counts.len == 0 or counts[0] == 0) 0 else @as(f64, @floatFromInt(counts[counts.len - 1])) / @as(f64, @floatFromInt(counts[0])) * 100;
        try render(w, "<a class=\"card funnel-card\" href=\"{href}\"><div class=\"row-between\"><strong>{name}</strong><span class=\"pill pill-good\">{rate:.1}%</span></div><div class=\"row funnel-mini\">", .{ .href = try view.href(arena, try std.fmt.allocPrint(arena, "/{s}/funnels/{d}", .{ site.slug, funnel.id }), &.{}), .name = funnel.name, .rate = end_to_end });
        for (counts) |value| try render(w, "<span style=\"height:{height:.0}px\"></span>", .{ .height = if (counts[0] == 0) 4 else @max(4, @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(counts[0])) * 56) });
        try render(w, "</div><span class=\"hint\">{steps} steps · {entered} sessions entered</span></a>", .{ .steps = steps.len, .entered = html.int(if (counts.len == 0) 0 else counts[0]) });
    }
    try w.writeAll("</div><h2 class=\"section-title\">New funnel</h2>");
    var preset: std.ArrayList(Step) = .empty;
    if (ctx.param("step")) |raw| {
        const split = std.mem.findScalar(u8, raw, ':') orelse 0;
        if (split > 0) try preset.append(arena, .{ .kind = raw[0..split], .value = raw[split + 1 ..] });
    }
    try builder(ctx, site, path, "", preset.items, 86_400_000, true);
    return layout.end(ctx);
}

/// Form analytics: starts, submits and where people give up, per field.
/// Field names only; what visitors type is never collected.
fn forms(ctx: *Ctx, view: data.View, path: []const u8) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    const site = view.site;
    if (site.mode != .full) {
        try w.writeAll("<div class=\"card\">");
        try ui.empty(w, "Form analytics need Full mode", "Field-level timing and drop-off come from visitors who consent in Full mode — field names only, never values.", "");
        try w.writeAll("</div>");
        return;
    }
    const from = data.dateText(view.range.start_ms);
    const to = data.dateText(view.range.end_ms - 1);
    const Form = struct { path: []const u8, form: []const u8, starts: i64, submits: i64, abandons: i64 };
    const rows = try ctx.db.all(arena, Form, "SELECT path,form,sum(starts),sum(submits),sum(abandons) FROM form_fields WHERE site_id=? AND field='' AND day>=? AND day<=? GROUP BY path,form ORDER BY 3 DESC LIMIT 30", .{ site.id, &from, &to });
    if (rows.len == 0) {
        try w.writeAll("<div class=\"card\">");
        try ui.empty(w, "No form activity yet", "Forms appear once consented visitors start filling them in. Name forms with a <code>name</code> or <code>id</code> attribute to tell them apart.", "");
        try w.writeAll("</div>");
        return;
    }
    const selected_key = ctx.param("form") orelse try std.fmt.allocPrint(arena, "{s}|{s}", .{ rows[0].path, rows[0].form });
    var selected = rows[0];
    try w.writeAll("<div class=\"grid split-detail\"><section class=\"card card-flush\"><div class=\"table-wrap\"><table class=\"table\"><thead><tr><th>Form</th><th class=\"r\">Started</th><th class=\"r\">Submitted</th><th class=\"r\">Gave up</th></tr></thead><tbody>");
    for (rows) |row| {
        const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ row.path, row.form });
        const is_selected = std.mem.eql(u8, key, selected_key);
        if (is_selected) selected = row;
        const href = try view.href(arena, path, &.{ .{ "tab", "forms" }, .{ "form", key } });
        try render(w, "<tr data-href=\"{href}\"{!selected}><td><a href=\"{href}\" class=\"strong block\">{form}</a><span class=\"mono secondary\">{path}</span></td><td class=\"r\">{starts}</td><td class=\"r\">{submits}</td><td class=\"r\"><span class=\"{class}\">{gave_up}</span></td></tr>", .{
            .href = href, .selected = if (is_selected) " aria-selected=\"true\"" else "", .form = row.form, .path = row.path, .starts = html.int(row.starts), .submits = html.int(row.submits), .class = if (row.abandons * 3 > row.starts) "warn" else "", .gave_up = html.share(row.abandons, row.starts),
        });
    }
    try w.writeAll("</tbody></table></div></section>");
    const Field = struct { name: []const u8, starts: i64, ms: i64, errors: i64, abandons: i64 };
    const fields = try ctx.db.all(arena, Field, "SELECT field,sum(starts),sum(ms),sum(errors),sum(abandons) FROM form_fields WHERE site_id=? AND path=? AND form=? AND field<>'' AND day>=? AND day<=? GROUP BY field ORDER BY 2 DESC LIMIT 24", .{ site.id, selected.path, selected.form, &from, &to });
    try render(w, "<section class=\"card\"><div class=\"overline\">{path}</div><h2 class=\"card-title form-title\">{form}</h2><p class=\"hint\">{starts} started · {submits} submitted · {abandons} gave up</p><table class=\"table mt-12\"><thead><tr><th>Field</th><th class=\"r\">Time</th><th class=\"r\">Errors</th><th class=\"r\">Last field before leaving</th></tr></thead><tbody>", .{ .path = selected.path, .form = selected.form, .starts = html.int(selected.starts), .submits = html.int(selected.submits), .abandons = html.int(selected.abandons) });
    var worst: []const u8 = "";
    var worst_count: i64 = 0;
    for (fields) |field| {
        if (field.abandons > worst_count) {
            worst_count = field.abandons;
            worst = field.name;
        }
        try render(w, "<tr><td class=\"mono\">{name}</td><td class=\"r\">{time}</td><td class=\"r\"><span class=\"{error_class}\">{errors}</span></td><td class=\"r\"><span class=\"{abandon_class}\">{abandons}</span></td></tr>", .{
            .name = field.name, .time = html.duration(@divFloor(field.ms, @max(1, field.starts))), .error_class = if (field.errors > 0) "bad" else "", .errors = field.errors, .abandon_class = if (field.abandons > 0) "warn strong" else "", .abandons = field.abandons,
        });
    }
    try w.writeAll("</tbody></table>");
    if (worst.len != 0) try render(w, "<div class=\"callout callout-warn mt-12\"><span>Most people who gave up left at <strong class=\"mono\">{field}</strong>. <a class=\"link\" href=\"/{slug}/sessions?signal=recorded\">Watch recorded sessions →</a></span></div>", .{ .field = worst, .slug = site.slug });
    try w.writeAll("<p class=\"hint mt-10\">Field names and timing only — what visitors type is never collected.</p></section></div>");
}

fn builder(ctx: *Ctx, site: data.Site, action: []const u8, name: []const u8, steps: []const Step, window_ms: i64, creating: bool) !void {
    const w = ctx.w();
    try render(w, "<form class=\"card\" method=\"post\" action=\"{action}\" data-funnel-builder{!autosave}><div class=\"card-head\"><h2>Steps</h2></div>", .{ .action = action, .autosave = if (creating) "" else " data-autosave" });
    if (creating) try render(w, "<label class=\"field mb-14\">Name<input class=\"input\" name=\"name\" value=\"{name}\" required maxlength=\"64\" placeholder=\"Signup funnel\"></label>", .{ .name = name });
    try w.writeAll("<div class=\"step-list\" data-steps>");
    const rows = if (steps.len == 0) &[_]Step{ .{ .kind = "path", .value = "" }, .{ .kind = "event", .value = "" } } else steps;
    for (rows, 0..) |step, index| try stepRow(w, index, step);
    if (steps.len == 1) try stepRow(w, 1, .{ .kind = "event", .value = "" });
    try w.writeAll("</div><template data-step-template>");
    try stepRow(w, 0, .{ .kind = "event", .value = "" });
    try w.writeAll("</template><button type=\"button\" class=\"add-tile add-step\" data-add-step>");
    try icon(w, "plus");
    try w.writeAll("Add step</button><datalist id=\"funnel-events\">");
    for (try ctx.db.all(ctx.arena, struct { name: []const u8 }, "SELECT DISTINCT name FROM events WHERE site_id=? ORDER BY name LIMIT 100", .{site.id})) |row| try render(w, "<option value=\"{name}\">", .{ .name = row.name });
    try w.writeAll("</datalist><datalist id=\"funnel-paths\">");
    for (try ctx.db.all(ctx.arena, struct { path: []const u8 }, "SELECT path FROM page_views WHERE site_id=? GROUP BY path ORDER BY count(*) DESC LIMIT 100", .{site.id})) |row| try render(w, "<option value=\"{path}\">", .{ .path = row.path });
    try w.writeAll("</datalist><label class=\"field mt-16\"><span class=\"hint regular\">Within one session, completed within</span><select class=\"input\" name=\"window\">");
    const windows = [_]struct { i64, []const u8 }{ .{ 1_800_000, "30 minutes" }, .{ 3_600_000, "1 hour" }, .{ 86_400_000, "1 day" } };
    for (windows) |option| try render(w, "<option value=\"{value}\"{!selected}>{label}</option>", .{ .value = option[0], .selected = if (option[0] == window_ms) " selected" else "", .label = option[1] });
    try render(w, "</select></label><div class=\"row end mt-16\"><button class=\"btn{!primary}\">{label}</button></div></form>", .{ .primary = if (creating) " btn-primary" else "", .label = if (creating) "Create funnel" else "Save steps" });
}

fn stepRow(w: *std.Io.Writer, index: usize, step: Step) !void {
    const page = std.mem.eql(u8, step.kind, "path");
    try render(w,
        \\<div class="step-item" data-step draggable="true"><span class="step-num">{n}</span><div class="row nowrap gap-6"><select class="input step-kind" name="kind" aria-label="Step type"><option value="path"{!page}>Page</option><option value="event"{!event}>Event</option></select><input class="input mono step-match" name="match" value="{value}" list="{list}" placeholder="{placeholder}" aria-label="Step match"></div><button type="button" class="btn btn-quiet btn-icon" data-remove-step aria-label="Remove step">
    , .{ .n = index + 1, .page = if (page) " selected" else "", .event = if (std.mem.eql(u8, step.kind, "event")) " selected" else "", .value = step.value, .list = if (page) "funnel-paths" else "funnel-events", .placeholder = if (page) "/pricing" else "signup" });
    try icon(w, "x");
    try w.writeAll("</button></div>");
}

fn result(ctx: *Ctx, view: data.View, steps: []const Step, window_ms: i64) !void {
    const w = ctx.w();
    const arena = ctx.arena;
    const counts = try computeFunnel(ctx, view, steps, window_ms);
    const first: f64 = @floatFromInt(if (counts.len == 0) 0 else counts[0]);
    const end_to_end = if (first == 0) 0 else @as(f64, @floatFromInt(counts[counts.len - 1])) / first * 100;
    try render(w, "<section class=\"card card-flush\"><div class=\"card-head funnel-head\"><h2>Conversion</h2><strong class=\"good t-15\">{rate:.1}% end to end</strong></div><div class=\"pad-20\"><div class=\"funnel\" style=\"--steps:{steps}\">", .{ .rate = end_to_end, .steps = steps.len });
    var biggest: usize = 0;
    var biggest_drop: f64 = -1;
    for (steps, 0..) |step, index| {
        const value: f64 = @floatFromInt(counts[index]);
        const share = if (first == 0) 0 else value / first * 100;
        const previous: f64 = if (index == 0) value else @floatFromInt(counts[index - 1]);
        if (index > 0 and previous > 0 and (previous - value) / previous > biggest_drop) {
            biggest_drop = (previous - value) / previous;
            biggest = index;
        }
        // A bar too short to hold its share shows it just above instead.
        const short = share < 18;
        try w.writeAll("<div class=\"funnel-col\"><div class=\"funnel-track\">");
        if (index > 0 and previous > value) try render(w, "<span class=\"funnel-drop\" style=\"bottom:calc({share:.1}% + {lift}px)\">{left} left</span>", .{ .share = share, .lift = @as(u32, if (short) 44 else 10), .left = html.int(@intFromFloat(previous - value)) });
        if (short) try render(w, "<span class=\"funnel-value\" style=\"bottom:calc({share:.1}% + 6px)\">{share:.1}%</span>", .{ .share = share });
        try render(w, "<div class=\"funnel-bar{!short}\" style=\"height:{height:.1}%;--w:{width:.1}%\">{share:.1}%</div></div><div><strong>{count}</strong><small title=\"{value}\">{label}</small>", .{ .short = if (short) " short" else "", .height = @max(share, 1.5), .width = @max(share, 4), .share = share, .count = html.int(counts[index]), .value = step.value, .label = try stepLabel(ctx, view.site, step) });
        if (index > 0) try render(w, "<small><b class=\"ink\">{rate:.1}%</b> from previous</small>", .{ .rate = if (previous == 0) 0 else value / previous * 100 });
        try w.writeAll("</div></div>");
    }
    try w.writeAll("</div></div>");
    if (biggest > 0 and first > 0) {
        try render(w, "<div class=\"card-foot\"><span>Biggest drop: step {from} → {to} ({drop:.0}% leave)</span><a class=\"link\" href=\"{href}\">See paths from step {from} →</a></div>", .{
            .from = biggest,
            .to = biggest + 1,
            .drop = biggest_drop * 100,
            .href = try view.href(arena, try std.fmt.allocPrint(arena, "/{s}/sessions", .{view.site.slug}), &.{ .{ "tab", "paths" }, .{ "from", if (std.mem.eql(u8, steps[biggest - 1].kind, "path")) steps[biggest - 1].value else "" } }),
        });
    } else if (first == 0) {
        try w.writeAll("<div class=\"card-foot\"><span>No session reached the first step in this period.</span></div>");
    }
    try w.writeAll("</section>");
}

fn readSteps(ctx: *Ctx) ![]Step {
    const form = try ctx.form();
    const kinds = try form.all(ctx.arena, "kind");
    const matches = try form.all(ctx.arena, "match");
    var out: std.ArrayList(Step) = .empty;
    for (kinds, 0..) |kind, index| {
        if (index >= matches.len) break;
        const value = std.mem.trim(u8, matches[index], " ");
        if (value.len == 0) continue;
        if (std.mem.eql(u8, kind, "event")) {
            domain.validateName(value) catch return error.InvalidStep;
        } else if (std.mem.eql(u8, kind, "path")) {
            domain.validatePath(value) catch return error.InvalidStep;
        } else return error.InvalidStep;
        try out.append(ctx.arena, .{ .kind = kind, .value = value });
    }
    if (out.items.len < 2 or out.items.len > 16) return error.InvalidStepCount;
    return out.items;
}

fn windowValue(ctx: *Ctx) i64 {
    const value = std.fmt.parseInt(i64, ctx.field("window") catch "", 10) catch 86_400_000;
    return std.math.clamp(value, 60_000, 7 * data.day_ms);
}

fn writeSteps(ctx: *Ctx, db: anytype, funnel_id: i64, steps: []const Step) !void {
    try db.run(ctx.arena, "DELETE FROM funnel_steps WHERE funnel_id=?", .{funnel_id});
    for (steps, 0..) |step, index| {
        try db.run(ctx.arena, "INSERT INTO funnel_steps(funnel_id,step_index,kind,match_value) VALUES(?,?,?,?)", .{ funnel_id, @as(i64, @intCast(index)), step.kind, step.value });
    }
}

pub fn addFunnel(ctx: *Ctx, site: data.Site) !void {
    const name = std.mem.trim(u8, try ctx.field("name"), " ");
    domain.validateText(name, 64, false) catch return overview.failBack(ctx, site, "Give the funnel a name.");
    const steps = readSteps(ctx) catch return overview.failBack(ctx, site, "A funnel needs 2–16 steps: pages start with /, events use letters, numbers and _ - . :");
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    try db.exec("BEGIN IMMEDIATE");
    errdefer db.exec("ROLLBACK") catch {};
    db.run(ctx.arena, "INSERT INTO funnels(site_id,name,window_ms,created_at_ms) VALUES(?,?,?,?)", .{ site.id, name, windowValue(ctx), ctx.now() }) catch {
        db.exec("ROLLBACK") catch {};
        return overview.failBack(ctx, site, "A funnel with that name already exists.");
    };
    const funnel_id = db.lastInsertRowId();
    try writeSteps(ctx, db, funnel_id, steps);
    try db.exec("COMMIT");
    return ctx.done(try std.fmt.allocPrint(ctx.arena, "Funnel “{s}” created.", .{name}), "/{s}/funnels/{d}", .{ site.slug, funnel_id });
}

pub fn funnelAction(ctx: *Ctx, site: data.Site, id: i64, action: []const u8) !void {
    if (std.mem.eql(u8, action, "delete")) return deleteFunnel(ctx, site, id);
    if (!std.mem.eql(u8, action, "save")) return layout.message(ctx, .not_found, "Nothing here", "Unknown action.");
    const steps = readSteps(ctx) catch return overview.failBack(ctx, site, "A funnel needs 2–16 steps: pages start with /, events use letters, numbers and _ - . :");
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    if (try db.scalar(ctx.arena, i64, "SELECT count(*) FROM funnels WHERE id=? AND site_id=?", .{ id, site.id }) != 1) return layout.message(ctx, .not_found, "Funnel not found", "It may have been deleted.");
    try db.exec("BEGIN IMMEDIATE");
    errdefer db.exec("ROLLBACK") catch {};
    try db.run(ctx.arena, "UPDATE funnels SET window_ms=? WHERE id=?", .{ windowValue(ctx), id });
    try writeSteps(ctx, db, id, steps);
    try db.exec("COMMIT");
    const back = overview.referer(ctx, site);
    return ctx.redirectFmt("{s}{s}saved=1", .{ back, if (std.mem.findScalar(u8, back, '?') == null) "?" else "&" });
}

pub fn deleteFunnel(ctx: *Ctx, site: data.Site, id: i64) !void {
    const db = ctx.shared.lockWrite();
    defer ctx.shared.unlockWrite();
    try db.run(ctx.arena, "DELETE FROM funnels WHERE id=? AND site_id=?", .{ id, site.id });
    return ctx.done("Funnel deleted.", "/{s}/funnels", .{site.slug});
}

// ---------------------------------------------------------------- Sessions & paths

pub fn pathsTab(ctx: *Ctx, view: data.View, path: []const u8) !void {
    const arena = ctx.arena;
    const w = ctx.w();
    // Visits split at midnight in the summaries, so they cover whole days only.
    const split = try pathsSplit(ctx, view);
    var landing_sql = data.Sql.init(arena);
    try landing_sql.add("WITH f AS (SELECT pv.path,row_number() OVER(PARTITION BY pv.session_id ORDER BY pv.occurred_at_ms,pv.received_at_ms) rn,row_number() OVER(PARTITION BY pv.session_id ORDER BY pv.occurred_at_ms DESC,pv.received_at_ms DESC) rl FROM page_views pv WHERE ");
    try landing_sql.pageViews(view, split, view.range.end_ms);
    try landing_sql.add(" AND pv.session_id IS NOT NULL), r AS (SELECT 'entry' kind,path,count(*) n FROM f WHERE rn=1 GROUP BY path UNION ALL SELECT 'exit',path,count(*) FROM f WHERE rl=1 GROUP BY path");
    for ([_][]const u8{ "entry", "exit" }) |dim| if (split > view.range.start_ms) {
        try landing_sql.add(" UNION ALL SELECT dim,key,sum(views)");
        try data.rollupWhere(&landing_sql, view.site.id, .{ .dim = dim, .key = null }, view.range.start_ms, split);
        try landing_sql.add(" GROUP BY key");
    };
    try landing_sql.add(") SELECT kind,path,sum(n) FROM r GROUP BY 1,2 ORDER BY 1,3 DESC,2");
    var statement = try landing_sql.prepare(ctx.db);
    defer statement.deinit();
    var entries: std.ArrayList(data.Row) = .empty;
    var exits: std.ArrayList(data.Row) = .empty;
    while (try statement.step() == .row) {
        const row: data.Row = .{ .key = try arena.dupe(u8, statement.columnText(1)), .value = statement.columnInt(2) };
        if (std.mem.eql(u8, statement.columnText(0), "entry")) {
            if (entries.items.len < 8) try entries.append(arena, row);
        } else if (exits.items.len < 8) try exits.append(arena, row);
    }
    const from = ctx.param("from") orelse if (entries.items.len != 0) entries.items[0].key else "";
    try render(w, "<form class=\"row mb-16\" method=\"get\" action=\"{path}\"><input type=\"hidden\" name=\"tab\" value=\"paths\">", .{ .path = path });
    try layout.hiddenState(ctx, view, &.{});
    try render(w, "<label class=\"row nowrap\"><span class=\"secondary\">After visiting</span><input class=\"input mono input-path\" name=\"from\" value=\"{from}\" list=\"path-options\" data-autosubmit></label><datalist id=\"path-options\">", .{ .from = from });
    for (entries.items) |row| try render(w, "<option value=\"{path}\">", .{ .path = row.key });
    try w.writeAll("</datalist></form><div class=\"grid grid-3\"><section class=\"card\">");
    if (from.len != 0) try nextPagesFrom(ctx, view, from);
    try w.writeAll("</section><section class=\"card\"><div class=\"card-head\"><h2>Entry pages</h2></div><div class=\"rank\">");
    for (entries.items, 0..) |row, index| try overview.pageRow(w, arena, index, row, entries.items[0].value, overview.listGrowth(entries.items), try view.href(arena, path, &.{ .{ "tab", "paths" }, .{ "from", row.key } }));
    try w.writeAll("</div></section><section class=\"card\"><div class=\"card-head\"><h2>Exit pages</h2></div><div class=\"rank\">");
    for (exits.items, 0..) |row, index| try overview.pageRow(w, arena, index, row, exits.items[0].value, overview.listGrowth(exits.items), try view.href(arena, path, &.{ .{ "tab", "paths" }, .{ "from", row.key } }));
    try w.writeAll("</div></section></div>");
}

/// Raw rows from here on; whole days before it come from the summaries.
fn pathsSplit(ctx: *Ctx, view: data.View) !i64 {
    if (view.filters.len != 0) return view.range.start_ms;
    const split = try data.rollupSplit(ctx.arena, ctx.db, view, view.range.start_ms, view.range.end_ms);
    return @max(view.range.start_ms, split - @mod(split, data.day_ms));
}

pub const PathStep = struct { path: []const u8, count: i64 };

/// Where visits went right after `from` ("" where they ended), most first,
/// and how many steps left `from` in all.
pub fn nextSteps(ctx: *Ctx, view: data.View, from: []const u8, limit: i64) !struct { steps: []PathStep, total: i64 } {
    const split = try pathsSplit(ctx, view);
    var sql = data.Sql.init(ctx.arena);
    try sql.add("WITH o AS (SELECT pv.path,lead(pv.path) OVER(PARTITION BY pv.session_id ORDER BY pv.occurred_at_ms,pv.received_at_ms) nxt FROM page_views pv WHERE ");
    try sql.pageViews(view, split, view.range.end_ms);
    try sql.add(" AND pv.session_id IS NOT NULL), r AS (SELECT coalesce(nxt,'') k,count(*) n FROM o WHERE path=");
    try sql.str(from);
    try sql.add(" GROUP BY 1");
    if (split > view.range.start_ms) {
        try sql.add(" UNION ALL SELECT substr(key,length(");
        try sql.str(from);
        try sql.add(")+2),sum(views)");
        try data.rollupWhere(&sql, view.site.id, .{ .dim = "next", .key = null }, view.range.start_ms, split);
        try sql.add(" AND key>=");
        try sql.str(try std.fmt.allocPrint(ctx.arena, "{s}\x1f", .{from}));
        try sql.add(" AND key<");
        try sql.str(try std.fmt.allocPrint(ctx.arena, "{s}\x20", .{from}));
        try sql.add(" GROUP BY key");
    }
    try sql.add(") SELECT k,sum(n),sum(sum(n)) OVER() FROM r GROUP BY k ORDER BY 2 DESC,1 LIMIT ");
    try sql.int(limit);
    var statement = try sql.prepare(ctx.db);
    defer statement.deinit();
    var steps: std.ArrayList(PathStep) = .empty;
    var total: i64 = 0;
    while (try statement.step() == .row) {
        try steps.append(ctx.arena, .{ .path = try ctx.arena.dupe(u8, statement.columnText(0)), .count = statement.columnInt(1) });
        total = statement.columnInt(2);
    }
    return .{ .steps = steps.items, .total = total };
}

/// Where visits were right before `to` ("" where they entered), most first.
pub fn previousSteps(ctx: *Ctx, view: data.View, to: []const u8, limit: i64) ![]PathStep {
    const split = try pathsSplit(ctx, view);
    var sql = data.Sql.init(ctx.arena);
    try sql.add("WITH o AS (SELECT pv.path,lag(pv.path) OVER(PARTITION BY pv.session_id ORDER BY pv.occurred_at_ms,pv.received_at_ms) prv FROM page_views pv WHERE ");
    try sql.pageViews(view, split, view.range.end_ms);
    try sql.add(" AND pv.session_id IS NOT NULL), r AS (SELECT coalesce(prv,'') k,count(*) n FROM o WHERE path=");
    try sql.str(to);
    try sql.add(" GROUP BY 1");
    if (split > view.range.start_ms) {
        try sql.add(" UNION ALL SELECT '',sum(views)");
        try data.rollupWhere(&sql, view.site.id, .{ .dim = "entry", .key = to }, view.range.start_ms, split);
        try sql.add(" UNION ALL SELECT substr(key,1,instr(key,char(31))-1),sum(views)");
        try data.rollupWhere(&sql, view.site.id, .{ .dim = "next", .key = null }, view.range.start_ms, split);
        try sql.add(" AND substr(key,instr(key,char(31))+1)=");
        try sql.str(to);
        try sql.add(" GROUP BY key");
    }
    try sql.add(") SELECT k,sum(n) FROM r GROUP BY k HAVING sum(n)>0 ORDER BY 2 DESC,1 LIMIT ");
    try sql.int(limit);
    var statement = try sql.prepare(ctx.db);
    defer statement.deinit();
    var steps: std.ArrayList(PathStep) = .empty;
    while (try statement.step() == .row) try steps.append(ctx.arena, .{ .path = try ctx.arena.dupe(u8, statement.columnText(0)), .count = statement.columnInt(1) });
    return steps.items;
}

fn nextPagesFrom(ctx: *Ctx, view: data.View, from: []const u8) !void {
    const w = ctx.w();
    const next = try nextSteps(ctx, view, from, 8);
    try render(w, "<div class=\"card-head\"><h2>Next from <span class=\"mono\">{from}</span></h2></div><div class=\"rank\">", .{ .from = from });
    for (next.steps) |step| {
        const share = @as(f64, @floatFromInt(step.count)) / @as(f64, @floatFromInt(@max(1, next.total))) * 100;
        try ui.rankRow(w, ctx.arena, .{ .width = @max(share * 0.85, 6), .bar = if (step.path.len == 0) "var(--subtle)" else "var(--brand-wash)", .name = if (step.path.len == 0) "Left the site" else step.path, .value = try std.fmt.allocPrint(ctx.arena, "{f}", .{html.int(step.count)}), .pct = try std.fmt.allocPrint(ctx.arena, "{d:.0}%", .{share}) });
    }
    if (next.steps.len == 0) try w.writeAll("<p class=\"hint\">Nobody visited this page in this period.</p>");
    try w.writeAll("</div>");
}

pub fn liveTab(ctx: *Ctx, view: data.View) !void {
    const w = ctx.w();
    var statement = try ctx.db.prepare(ctx.arena,
        \\SELECT at,kind,name,path,session_id FROM (
        \\ SELECT received_at_ms at,'page' kind,'' name,path,session_id FROM page_views WHERE site_id=?1 AND received_at_ms>=?2 AND internal=0 AND traffic_class IN ('human_like','unknown')
        \\ UNION ALL SELECT received_at_ms,'event',name,coalesce(path,''),session_id FROM events WHERE site_id=?1 AND received_at_ms>=?2 AND internal=0
        \\) ORDER BY at DESC LIMIT 40
    );
    defer statement.deinit();
    try statement.bindInt(1, view.site.id);
    try statement.bindInt(2, ctx.now() - 30 * 60_000);
    try render(w, "<section class=\"card\" id=\"live-feed\" data-refresh-live data-stream=\"/{slug}/stream\"><div class=\"card-head\">", .{ .slug = view.site.slug });
    try w.writeAll("<h2>Last 30 minutes</h2><span class=\"live\">Updating</span></div><div class=\"timeline\">");
    var any = false;
    while (try statement.step() == .row) {
        any = true;
        const is_page = std.mem.eql(u8, statement.columnText(1), "page");
        try render(w, "<div class=\"tl-row\"><span class=\"tl-time\">{ago}</span><span class=\"tl-dot {tone}\"></span><div><strong>{title}</strong><small>{detail}</small></div></div>", .{ .ago = data.ago(statement.columnInt(0), ctx.now()), .tone = if (is_page) "" else "blue", .title = if (is_page) statement.columnText(3) else statement.columnText(2), .detail = if (is_page) "Page view" else statement.columnText(3) });
    }
    try w.writeAll("</div>");
    if (!any) try w.writeAll("<p class=\"hint\">Quiet right now. New visits appear here within seconds.</p>");
    try w.writeAll("</section>");
}

// ---------------------------------------------------------------- Audience

pub fn audience(ctx: *Ctx, site: data.Site) !void {
    const arena = ctx.arena;
    const view = try analyze.start(ctx, site, .audience, "Audience");
    const w = ctx.w();
    const path = try std.fmt.allocPrint(arena, "/{s}/audience", .{site.slug});
    try layout.head(ctx, .{ .title = "Audience", .subtitle = try std.fmt.allocPrint(arena, "Who visits · {f}", .{view.range}), .view = view, .path = path });
    const Stats = struct { visitors: i64, views: i64, engaged: i64, active: i64 };
    const stats = struct {
        fn get(c: *Ctx, v: data.View, from: i64, to: i64) !Stats {
            const sums = data.keySum(try data.keySums(c.arena, c.db, v, "total", from, to, 1), "");
            return .{ .visitors = sums.visitors, .views = sums.views, .engaged = sums.engaged, .active = sums.active_ms };
        }
    };
    const tech = ctx.param("tech") orelse "device";
    const tech_dim: data.Dim = if (std.mem.eql(u8, tech, "browser")) .browser else if (std.mem.eql(u8, tech, "os")) .os else .device;
    const geo_tab = ctx.param("geo") orelse "country";
    const geo_dim: data.Dim = if (std.mem.eql(u8, geo_tab, "region")) .region else if (std.mem.eql(u8, geo_tab, "city")) .city else .country;
    const r = view.range;
    try data.prefetch(ctx.shared, ctx.db, arena, view, &.{
        .{ .key_sums = .{ .dim = "total", .start = r.start_ms, .end = r.end_ms, .limit = 1 } },
        .{ .key_sums = .{ .dim = "total", .start = r.prev_start_ms, .end = r.prev_end_ms, .limit = 1 } },
        .{ .top = .{ .dim = tech_dim, .limit = 8 } },
        .{ .key_sums = .{ .dim = "language", .start = r.start_ms, .end = r.end_ms, .limit = 6 } },
        .{ .key_sums = .{ .dim = "viewport", .start = r.start_ms, .end = r.end_ms, .limit = 6 } },
        .{ .key_sums = .{ .dim = @tagName(geo_dim), .start = r.start_ms, .end = r.end_ms, .limit = 12 } },
    });
    const now_stats = try stats.get(ctx, view, view.range.start_ms, view.range.end_ms);
    const prev_stats = try stats.get(ctx, view, view.range.prev_start_ms, view.range.prev_end_ms);
    const ratio = struct {
        fn of(a: i64, b: i64) f64 {
            return if (b == 0) 0 else @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b));
        }
    };
    try w.writeAll("<div class=\"metrics\">");
    const tiles = [_]struct { []const u8, []const u8, f64, f64, u8 }{
        .{ "Visitor-days", "audience", @floatFromInt(now_stats.visitors), @floatFromInt(prev_stats.visitors), 0 },
        .{ "Pages per visitor", "pages", ratio.of(now_stats.views, now_stats.visitors), ratio.of(prev_stats.views, prev_stats.visitors), 1 },
        .{ "Engaged views", "zap", ratio.of(now_stats.engaged, now_stats.views) * 100, ratio.of(prev_stats.engaged, prev_stats.views) * 100, 2 },
        .{ "Active time per visitor", "clock", ratio.of(now_stats.active, now_stats.visitors), ratio.of(prev_stats.active, prev_stats.visitors), 3 },
    };
    for (tiles, 0..) |tile, index| try ui.metric(w, arena, .{
        .tone = ui.tones[index],
        .icon = tile[1],
        .label = tile[0],
        .value = switch (tile[4]) {
            0 => try std.fmt.allocPrint(arena, "{f}", .{html.int(@intFromFloat(tile[2]))}),
            1 => try std.fmt.allocPrint(arena, "{d:.1}", .{tile[2]}),
            2 => try std.fmt.allocPrint(arena, "{d:.0}%", .{tile[2]}),
            else => try std.fmt.allocPrint(arena, "{f}", .{html.duration(@intFromFloat(tile[2]))}),
        },
        .change = if (view.compare) try ui.change(arena, tile[2], tile[3], false, view.range.shortComparison()) else "",
    });
    try w.writeAll("</div>");
    try w.writeAll("<div class=\"grid grid-2\"><section class=\"card\"><div class=\"card-head\"><h2>Technology</h2></div>");
    try ui.tabs(ctx.w(), ctx.arena, view, path, "tech", &.{ .{ "device", "Devices" }, .{ "browser", "Browsers" }, .{ "os", "Operating systems" } }, tech);
    try breakdown(ctx, view, tech_dim, now_stats.views, try std.fmt.allocPrint(arena, "/{s}", .{site.slug}));
    try w.writeAll("</section><section class=\"card\"><div class=\"card-head\"><h2>Languages</h2><span class=\"meta\">Browser language</span></div>");
    try columnBreakdown(ctx, view, "language", now_stats.views);
    try w.writeAll("</section><section class=\"card\"><div class=\"card-head\"><h2>Screen sizes</h2><span class=\"meta\">Viewport class</span></div>");
    try columnBreakdown(ctx, view, "viewport", now_stats.views);
    try w.writeAll("</section><section class=\"card\"><div class=\"card-head\"><h2>Where they are</h2>");
    try w.writeAll("<span class=\"meta\">IP used once, never stored</span></div>");
    if (ctx.shared.geo == null) {
        try w.writeAll("<div class=\"callout\">");
        try icon(w, "lock");
        try w.writeAll("<span>No location yet. Install the free DB-IP Lite database with <code>analytico geo import</code> to see countries, regions and cities. The address is used for the lookup and then discarded.</span></div>");
    } else {
        try ui.tabs(ctx.w(), ctx.arena, view, path, "geo", &.{ .{ "country", "Countries" }, .{ "region", "Regions" }, .{ "city", "Cities" } }, geo_tab);
        try places(ctx, view, geo_dim, now_stats.views, try std.fmt.allocPrint(arena, "/{s}", .{site.slug}));
        try w.writeAll("<p class=\"hint mt-12\"><a class=\"link\" href=\"https://db-ip.com\" rel=\"noopener\">IP location by DB-IP</a> (CC BY 4.0)</p>");
    }
    try w.writeAll("</section></div>");
    // Saved segments as one-click views.
    const segments = try ctx.db.all(arena, struct { id: i64, name: []const u8, filters: []const u8 }, "SELECT id,name,filters FROM segments WHERE site_id=? ORDER BY name", .{site.id});
    try w.writeAll("<section class=\"card mt-16\">");
    try ui.cardHead(w, "Saved segments", "<span class=\"meta\">Create one from any filter</span>");
    try w.writeAll("<div class=\"row\">");
    for (segments) |segment| {
        try render(w, "<span class=\"chip chip-plain segment-chip\"><a href=\"{path}?{filters}\">", .{ .path = path, .filters = segment.filters });
        try icon(w, "bookmark");
        try render(w, "{name}</a><form class=\"contents\" method=\"post\" action=\"/{slug}/segments/{id}/delete\" data-undo=\"Segment deleted\"><button class=\"btn btn-quiet btn-icon btn-tiny\" aria-label=\"Delete segment\">×</button></form></span>", .{ .name = segment.name, .slug = site.slug, .id = segment.id });
    }
    if (segments.len == 0) try w.writeAll("<p class=\"hint\">No segments yet. Filter any page, then choose “Save as segment”.</p>");
    try w.writeAll("</div></section>");
    return layout.end(ctx);
}

fn places(ctx: *Ctx, view: data.View, dim: data.Dim, total: i64, base: []const u8) !void {
    const w = ctx.w();
    const geo = @import("../geo.zig");
    const sums = try data.keySums(ctx.arena, ctx.db, view, @tagName(dim), view.range.start_ms, view.range.end_ms, 12);
    try w.writeAll("<div class=\"stack-s\">");
    for (sums) |entry| {
        const key = entry.key;
        const share = @as(f64, @floatFromInt(entry.sums.views)) / @as(f64, @floatFromInt(@max(total, 1))) * 100;
        const label = if (std.mem.eql(u8, key, "unknown")) "Unknown" else if (dim == .country) geo.countryName(key) else key;
        try render(w, "<a class=\"country-row\" href=\"{href}\"><span class=\"cc\">{code}</span><span class=\"grow\">{label}</span><span class=\"hint\">{visitors} visitor{plural}</span><span class=\"meter\" title=\"Share of page views\"><i style=\"width:{share:.0}%\"></i></span><strong>{share:.0}%</strong></a>", .{
            .href = try view.href(ctx.arena, base, &.{.{ "f+", try std.fmt.allocPrint(ctx.arena, "{s}:{s}", .{ @tagName(dim), key }) }}),
            .code = if (dim == .country and key.len == 2) key else "··",
            .label = label,
            .visitors = html.int(entry.sums.visitors),
            .plural = if (entry.sums.visitors == 1) "" else "s",
            .share = share,
        });
    }
    try w.writeAll("</div>");
}

fn breakdown(ctx: *Ctx, view: data.View, dim: data.Dim, total: i64, base: []const u8) !void {
    const w = ctx.w();
    const rows = try data.top(ctx.arena, ctx.db, view, dim, 8);
    try w.writeAll("<div class=\"rank\">");
    for (rows) |row| {
        const share = if (total == 0) 0 else @as(f64, @floatFromInt(row.value)) / @as(f64, @floatFromInt(total)) * 100;
        try render(w, "<a class=\"rank-row\" href=\"{href}\"><span class=\"bar\" style=\"width:{width:.1}%;background:var(--brand-wash)\"></span><span class=\"rank-name\"><span>{name}</span></span><span class=\"rank-value rank-value-text\">{value} · {share:.1}%</span><span></span></a>", .{
            .href = try view.href(ctx.arena, base, &.{.{ "f+", try std.fmt.allocPrint(ctx.arena, "{s}:{s}", .{ @tagName(dim), row.key }) }}), .width = @max(share * 0.75, 4), .name = capitalized(ctx.arena, row.key), .value = html.int(row.value), .share = share,
        });
    }
    try w.writeAll("</div>");
    if (rows.len == 0) try w.writeAll("<p class=\"hint\">No visits in this period.</p>");
}

fn columnBreakdown(ctx: *Ctx, view: data.View, dim: []const u8, total: i64) !void {
    const w = ctx.w();
    const sums = try data.keySums(ctx.arena, ctx.db, view, dim, view.range.start_ms, view.range.end_ms, 6);
    try w.writeAll("<div class=\"rank\">");
    for (sums) |entry| {
        const value = entry.sums.views;
        const share = if (total == 0) 0 else @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(total)) * 100;
        try render(w, "<div class=\"rank-row\"><span class=\"bar\" style=\"width:{width:.1}%\"></span><span class=\"rank-name\"><span>{name}</span></span><span class=\"rank-value rank-value-text\">{value} · {share:.1}%</span><span></span></div>", .{ .width = @max(share * 0.75, 4), .name = if (std.mem.eql(u8, dim, "language")) try languageName(ctx.arena, entry.key) else capitalized(ctx.arena, entry.key), .value = html.int(value), .share = share });
    }
    try w.writeAll("</div>");
    if (sums.len == 0) try w.writeAll("<p class=\"hint\">No visits in this period.</p>");
}

/// "de-AT" → "German (AT)"; codes without a name stay as they are.
fn languageName(arena: std.mem.Allocator, code: []const u8) ![]const u8 {
    const names = [_][2][]const u8{
        .{ "en", "English" },   .{ "de", "German" },     .{ "fr", "French" },    .{ "es", "Spanish" },   .{ "it", "Italian" },
        .{ "nl", "Dutch" },     .{ "pt", "Portuguese" }, .{ "sv", "Swedish" },   .{ "da", "Danish" },    .{ "nb", "Norwegian" },
        .{ "no", "Norwegian" }, .{ "fi", "Finnish" },    .{ "pl", "Polish" },    .{ "cs", "Czech" },     .{ "ro", "Romanian" },
        .{ "hu", "Hungarian" }, .{ "el", "Greek" },      .{ "tr", "Turkish" },   .{ "ru", "Russian" },   .{ "uk", "Ukrainian" },
        .{ "ja", "Japanese" },  .{ "ko", "Korean" },     .{ "zh", "Chinese" },   .{ "ar", "Arabic" },    .{ "he", "Hebrew" },
        .{ "hi", "Hindi" },     .{ "id", "Indonesian" }, .{ "vi", "Vietnamese" }, .{ "th", "Thai" },     .{ "bg", "Bulgarian" },
    };
    const dash = std.mem.findScalar(u8, code, '-') orelse code.len;
    for (names) |pair| if (std.ascii.eqlIgnoreCase(code[0..dash], pair[0])) {
        return if (dash == code.len) pair[1] else std.fmt.allocPrint(arena, "{s} ({s})", .{ pair[1], code[dash + 1 ..] });
    };
    return code;
}

fn capitalized(arena: std.mem.Allocator, value: []const u8) []const u8 {
    return data.prettyLabel(arena, value);
}

// ---------------------------------------------------------------- Performance

pub const Vital = struct { key: []const u8, column: []const u8, name: []const u8, good: i64, poor: i64, cls: bool = false };
pub const vitals = [_]Vital{
    .{ .key = "lcp", .column = "lcp_ms", .name = "Largest Contentful Paint", .good = 2500, .poor = 4000 },
    .{ .key = "inp", .column = "inp_ms", .name = "Interaction to Next Paint", .good = 200, .poor = 500 },
    .{ .key = "cls", .column = "cls_milli", .name = "Cumulative Layout Shift", .good = 100, .poor = 250, .cls = true },
    .{ .key = "ttfb", .column = "ttfb_ms", .name = "Time to First Byte", .good = 800, .poor = 1800 },
};

pub const VitalValue = struct {
    vital: Vital,
    value: i64,

    pub fn format(self: VitalValue, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.vital.cls) return w.print("{d:.2}", .{@as(f64, @floatFromInt(self.value)) / 1000.0});
        return html.millis(self.value).format(w);
    }
};

pub const Distribution = struct { samples: usize, p50: i64, p75: i64, p95: i64, good: usize, poor: usize };

pub const Sample = struct { value: i64, count: i64 };

/// The vitals, then FCP for the slow-page hints.
const columns = vitals.len + 1;
const fcp: Vital = .{ .key = "fcp", .column = "fcp_ms", .name = "", .good = 1800, .poor = 3000 };

pub const Samples = struct {
    all: [columns]std.ArrayList(Sample) = @splat(.empty),
    by_path: std.StringArrayHashMapUnmanaged([columns]std.ArrayList(Sample)) = .empty,

    fn add(self: *Samples, arena: std.mem.Allocator, path: []const u8, column: usize, value: i64, count: i64) !void {
        try self.all[column].append(arena, .{ .value = value, .count = count });
        const entry = try self.by_path.getOrPut(arena, path);
        if (!entry.found_existing) {
            entry.key_ptr.* = try arena.dupe(u8, path);
            entry.value_ptr.* = @splat(.empty);
        }
        try entry.value_ptr[column].append(arena, .{ .value = value, .count = count });
    }
};

/// Every vital sample of the view's range, overall and per page, sorted by
/// value: the daily summaries (rounded up to two significant figures) where
/// they cover an unfiltered view, raw rows for the rest.
pub fn loadSamples(ctx: *Ctx, view: data.View) !Samples {
    const arena = ctx.arena;
    const range = view.range;
    var out: Samples = .{};
    const split = if (view.filters.len == 0) try data.rollupSplit(arena, ctx.db, view, range.start_ms, range.end_ms) else range.start_ms;
    if (split > range.start_ms) {
        var rolled = try ctx.db.prepare(arena, "SELECT path,metric,value,sum(samples) FROM vitals_daily WHERE site_id=? AND metric IN ('lcp','inp','cls','ttfb','fcp') AND day>=? AND day<=? GROUP BY metric,path,value");
        defer rolled.deinit();
        const first = data.dateText(range.start_ms);
        const last = data.dateText(split - 1);
        try rolled.bindAll(.{ view.site.id, &first, &last });
        while (try rolled.step() == .row) {
            const metric = rolled.columnText(1);
            const column = for (vitals, 0..) |vital, index| {
                if (std.mem.eql(u8, vital.key, metric)) break index;
            } else vitals.len;
            try out.add(arena, rolled.columnText(0), column, rolled.columnInt(2), rolled.columnInt(3));
        }
    }
    var raw = data.Sql.init(arena);
    try raw.add("SELECT pv.path,ps.lcp_ms,ps.inp_ms,ps.cls_milli,ps.ttfb_ms,ps.fcp_ms FROM page_views pv JOIN page_summaries ps ON ps.site_id=pv.site_id AND ps.page_id=pv.page_id WHERE ");
    try raw.pageViews(view, split, range.end_ms);
    try raw.add(" AND (ps.lcp_ms IS NOT NULL OR ps.inp_ms IS NOT NULL OR ps.cls_milli IS NOT NULL OR ps.ttfb_ms IS NOT NULL OR ps.fcp_ms IS NOT NULL)");
    var statement = try raw.prepare(ctx.db);
    defer statement.deinit();
    while (try statement.step() == .row) {
        for (0..columns) |column| {
            if (statement.columnType(@intCast(column + 1)) == db_mod.sqlite.SQLITE_NULL) continue;
            try out.add(arena, statement.columnText(0), column, statement.columnInt(@intCast(column + 1)), 1);
        }
    }
    const byValue = struct {
        fn less(_: void, a: Sample, b: Sample) bool {
            return a.value < b.value;
        }
    }.less;
    for (&out.all) |*list| std.mem.sort(Sample, list.items, {}, byValue);
    for (out.by_path.values()) |*lists| for (lists) |*list| std.mem.sort(Sample, list.items, {}, byValue);
    return out;
}

/// Percentiles and good/poor counts of samples sorted by value.
pub fn summarize(vital: Vital, items: []const Sample) Distribution {
    var total: i64 = 0;
    var good: i64 = 0;
    var poor: i64 = 0;
    for (items) |item| {
        total += item.count;
        if (item.value <= vital.good) good += item.count else if (item.value > vital.poor) poor += item.count;
    }
    if (total == 0) return .{ .samples = 0, .p50 = 0, .p75 = 0, .p95 = 0, .good = 0, .poor = 0 };
    const at = struct {
        fn p(list: []const Sample, count: i64, percent: i64) i64 {
            const rank = @max(1, @divFloor(count * percent + 99, 100));
            var seen: i64 = 0;
            for (list) |item| {
                seen += item.count;
                if (seen >= rank) return item.value;
            }
            return list[list.len - 1].value;
        }
    };
    return .{ .samples = @intCast(total), .p50 = at.p(items, total, 50), .p75 = at.p(items, total, 75), .p95 = at.p(items, total, 95), .good = @intCast(good), .poor = @intCast(poor) };
}

fn rating(vital: Vital, value: i64) struct { []const u8, []const u8 } {
    if (value <= vital.good) return .{ "Good", "pill-good" };
    if (value <= vital.poor) return .{ "Needs work", "pill-warn" };
    return .{ "Poor", "pill-bad" };
}

pub fn performance(ctx: *Ctx, site: data.Site) !void {
    const arena = ctx.arena;
    const view = try analyze.start(ctx, site, .performance, "Performance");
    const w = ctx.w();
    const path = try std.fmt.allocPrint(arena, "/{s}/performance", .{site.slug});
    const loaded = try loadSamples(ctx, view);
    var results: [vitals.len]Distribution = undefined;
    for (vitals, 0..) |vital, index| results[index] = summarize(vital, loaded.all[index].items);
    try layout.head(ctx, .{ .title = "Performance", .subtitle = try std.fmt.allocPrint(arena, "Real-user measurements · {f} samples · p75", .{html.int(@intCast(results[0].samples))}), .view = view, .path = path, .compare = false });
    if (results[0].samples == 0 and results[3].samples == 0) {
        try w.writeAll("<div class=\"card\">");
        try ui.empty(w, "No performance data yet", "Use the <strong>RUM</strong> variant of the tracker to measure Core Web Vitals from real visits. It adds about 1 KB and never records content.", try html.print(arena, "<a class=\"btn btn-primary\" href=\"/{slug}/setup?rum=1\">Get the RUM snippet</a>", .{ .slug = site.slug }));
        try w.writeAll("</div>");
        return layout.end(ctx);
    }
    const selected_key = ctx.param("vital") orelse "lcp";
    try w.writeAll("<div class=\"vitals\">");
    var selected: usize = 0;
    for (vitals, 0..) |vital, index| {
        const result_value = results[index];
        if (std.mem.eql(u8, vital.key, selected_key)) selected = index;
        const rate = rating(vital, result_value.p75);
        try render(w, "<a class=\"card{!selected}\" href=\"{href}\"><div class=\"hint ink-2\">{name}</div><div class=\"row-between\"><span class=\"metric-value mt-4\">{value}</span>", .{
            .selected = if (std.mem.eql(u8, vital.key, selected_key)) " card-selected" else "",
            .href = try view.href(arena, path, &.{.{ "vital", vital.key }}),
            .name = vital.name,
            .value = if (result_value.samples == 0) "—" else try std.fmt.allocPrint(arena, "{f}", .{VitalValue{ .vital = vital, .value = result_value.p75 }}),
        });
        if (result_value.samples != 0) try render(w, "<span class=\"pill {class}\">{label}</span>", .{ .class = rate[1], .label = rate[0] });
        try w.writeAll("</div>");
        try distributionBar(w, result_value);
        try w.writeAll("</a>");
    }
    try w.writeAll("</div>");
    const vital = vitals[selected];
    const chosen = results[selected];
    try render(w, "<section class=\"card\"><div class=\"card-head\"><h2>{name}</h2><span class=\"meta\">{samples} samples · good ≤ {good} · poor &gt; {poor}</span></div><div class=\"grid grid-3\">", .{ .name = vital.name, .samples = html.int(@intCast(chosen.samples)), .good = VitalValue{ .vital = vital, .value = vital.good }, .poor = VitalValue{ .vital = vital, .value = vital.poor } });
    const percentiles = [_]struct { []const u8, i64 }{ .{ "p50", chosen.p50 }, .{ "p75", chosen.p75 }, .{ "p95", chosen.p95 } };
    for (percentiles) |entry| try render(w, "<div><div class=\"hint\">{label}</div><div class=\"metric-value metric-value-l\">{value}</div></div>", .{ .label = entry[0], .value = VitalValue{ .vital = vital, .value = entry[1] } });
    try w.writeAll("</div>");
    try distributionBar(w, chosen);
    try w.writeAll("</section>");
    // Slowest pages by the selected vital, among the 30 with the most samples.
    const Slow = struct { path: []const u8, value: i64, ttfb: i64, fcp: i64, samples: usize };
    var slow: std.ArrayList(Slow) = .empty;
    for (loaded.by_path.keys(), loaded.by_path.values()) |page_path, *lists| {
        const page = summarize(vital, lists[selected].items);
        if (page.samples < 3) continue;
        try slow.append(arena, .{
            .path = page_path,
            .value = page.p75,
            .ttfb = summarize(vitals[3], lists[3].items).p75,
            .fcp = summarize(fcp, lists[vitals.len].items).p75,
            .samples = page.samples,
        });
    }
    std.mem.sort(Slow, slow.items, {}, struct {
        fn more(_: void, a: Slow, b: Slow) bool {
            return a.samples > b.samples;
        }
    }.more);
    slow.shrinkRetainingCapacity(@min(slow.items.len, 30));
    std.mem.sort(Slow, slow.items, {}, struct {
        fn less(_: void, a: Slow, b: Slow) bool {
            return a.value > b.value;
        }
    }.less);
    try render(w, "<section class=\"card card-flush mt-16\"><div class=\"card-head table-head\"><h2>Slowest pages · {key} p75</h2><span class=\"meta\">Pages with 3+ samples</span></div><div class=\"table-wrap\"><table class=\"table\"><tbody>", .{ .key = vital.key });
    for (slow.items[0..@min(slow.items.len, 8)]) |row| {
        const rate = rating(vital, row.value);
        const hint = if (vital.cls) "Layout moves after load" else if (row.ttfb > 800) "Slow server response" else if (row.fcp > 1800) "Late first paint — render-blocking resources?" else if (std.mem.eql(u8, vital.key, "lcp") and row.value - row.fcp > 1200) "Largest element arrives late — images?" else "—";
        try render(w, "<tr><td class=\"strong\">{path}</td><td class=\"r\"><span class=\"{class}\">{value}</span></td><td class=\"secondary hide-m wrap\">{hint}</td><td class=\"r\"><a class=\"link\" href=\"{href}\">Page detail →</a></td></tr>", .{
            .path = row.path, .class = if (std.mem.eql(u8, rate[1], "pill-good")) "good" else if (std.mem.eql(u8, rate[1], "pill-warn")) "warn" else "bad", .value = VitalValue{ .vital = vital, .value = row.value }, .hint = hint, .href = try view.href(arena, try std.fmt.allocPrint(arena, "/{s}/pages", .{site.slug}), &.{.{ "page", row.path }}),
        });
    }
    try w.writeAll("</tbody></table></div>");
    if (slow.items.len == 0) try w.writeAll("<p class=\"hint pad-under\">Not enough samples per page yet.</p>");
    try w.writeAll("</section>");
    return layout.end(ctx);
}

fn distributionBar(w: *std.Io.Writer, result_value: Distribution) !void {
    if (result_value.samples == 0) return w.writeAll("<p class=\"hint mt-14\">No samples</p>");
    const total: f64 = @floatFromInt(result_value.samples);
    const good = @as(f64, @floatFromInt(result_value.good)) / total * 100;
    const poor = @as(f64, @floatFromInt(result_value.poor)) / total * 100;
    const middle = 100 - good - poor;
    try render(w, "<div class=\"vital-dist\"><span class=\"dist-good\" style=\"flex:{good:.1}\"></span><span class=\"dist-warn\" style=\"flex:{middle:.1}\"></span><span class=\"dist-poor\" style=\"flex:{poor:.1}\"></span></div><div class=\"hint\">{good:.0}% good · {middle:.0}% needs work · {poor:.0}% poor</div>", .{ .good = good, .middle = middle, .poor = poor });
}
