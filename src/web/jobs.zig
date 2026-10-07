//! Background work on one thread: scheduled emails, daily alert checks,
//! nightly backups and retention. Reads use the thread's own connection;
//! writes take the shared write lock briefly, never across network calls.
const std = @import("std");
const ai = @import("ai.zig");
const data = @import("data.zig");
const db_mod = @import("../db.zig");
const html = @import("html.zig");
const mail = @import("mail.zig");
const manage = @import("manage.zig");
const overview = @import("overview.zig");
const settings = @import("settings.zig");
const server = @import("../server.zig");
const store_mod = @import("../store.zig");
const integrations = @import("integrations.zig");

const Shared = server.Shared;
const tick_seconds = 30;
const alert_hour = 6;
const backup_hour = 3;

pub fn run(shared: *Shared) void {
    var read_store = store_mod.Store.open(shared.gpa, shared.io, shared.data, false) catch |err| {
        std.log.err("jobs_open_failed code={s}", .{@errorName(err)});
        return;
    };
    defer read_store.close();
    var elapsed: u32 = tick_seconds - 5;
    while (!shared.stopping()) {
        std.Io.sleep(shared.io, .fromSeconds(1), .awake) catch {};
        elapsed += 1;
        if (elapsed < tick_seconds) continue;
        elapsed = 0;
        var arena_state = std.heap.ArenaAllocator.init(shared.gpa);
        defer arena_state.deinit();
        tick(arena_state.allocator(), shared, &read_store.database) catch |err| std.log.warn("jobs_tick_failed code={s}", .{@errorName(err)});
    }
}

const now = @import("../domain.zig").nowMs;

fn tick(arena: std.mem.Allocator, shared: *Shared, db: *db_mod.Db) !void {
    const at = now();
    // Independent: a failing report must not hold up alerts or backups.
    schedules(arena, shared, db, at) catch |err| std.log.warn("jobs_schedules_failed code={s}", .{@errorName(err)});
    alerts(arena, shared, db, at) catch |err| std.log.warn("jobs_alerts_failed code={s}", .{@errorName(err)});
    nightly(arena, shared, db, at) catch |err| std.log.warn("jobs_nightly_failed code={s}", .{@errorName(err)});
    anomalies(arena, shared, db, at) catch |err| std.log.warn("jobs_anomalies_failed code={s}", .{@errorName(err)});
    integrations.deliverGoals(arena, shared, db, at) catch |err| std.log.warn("jobs_webhooks_failed code={s}", .{@errorName(err)});
    @import("rollups.zig").run(arena, shared, db, at, 10_000) catch |err| std.log.warn("jobs_rollups_failed code={s}", .{@errorName(err)});
    retentionReports(arena, shared, db, at) catch |err| std.log.warn("jobs_retention_failed code={s}", .{@errorName(err)});
    const write = shared.lockWrite();
    defer shared.unlockWrite();
    try data.putSetting(arena, write, .@"jobs.last_run", try std.fmt.allocPrint(arena, "{d}", .{at}));
}

/// Each Full site's retention report for the new day, so nobody waits for it.
fn retentionReports(arena: std.mem.Allocator, shared: *Shared, db: *db_mod.Db, at: i64) !void {
    for (try data.sites(arena, db)) |site| {
        if (site.mode == .full and site.enabled) _ = try @import("customers.zig").retentionReport(arena, shared, db, site.id, at);
    }
}

fn origin(arena: std.mem.Allocator, db: *db_mod.Db) ![]const u8 {
    return (try data.setting(arena, db, .public_origin)) orelse "";
}

fn teamEmails(arena: std.mem.Allocator, db: *db_mod.Db) ![]const []const u8 {
    var statement = try db.prepare(arena, "SELECT u.email FROM users u WHERE " ++ @import("auth.zig").joined_sql ++ " ORDER BY u.id LIMIT 20");
    defer statement.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    while (try statement.step() == .row) try out.append(arena, try arena.dupe(u8, statement.columnText(0)));
    return out.items;
}

// ---------------------------------------------------------------- scheduled emails

fn schedules(arena: std.mem.Allocator, shared: *Shared, db: *db_mod.Db, at: i64) !void {
    var statement = try db.prepare(arena, "SELECT id,site_id,name,view,frequency,weekday,hour_utc,recipients FROM schedules WHERE enabled=1 AND next_run_at_ms<=? ORDER BY next_run_at_ms LIMIT 5");
    defer statement.deinit();
    try statement.bindInt(1, at);
    const Due = struct { id: i64, site_id: i64, name: []const u8, view: []const u8, frequency: []const u8, weekday: i64, hour: i64, recipients: []const u8 };
    var due: std.ArrayList(Due) = .empty;
    while (try statement.step() == .row) try due.append(arena, .{
        .id = statement.columnInt(0),
        .site_id = statement.columnInt(1),
        .name = try arena.dupe(u8, statement.columnText(2)),
        .view = try arena.dupe(u8, statement.columnText(3)),
        .frequency = try arena.dupe(u8, statement.columnText(4)),
        .weekday = statement.columnInt(5),
        .hour = statement.columnInt(6),
        .recipients = try arena.dupe(u8, statement.columnText(7)),
    });
    for (due.items) |item| {
        var failure: []const u8 = "";
        var log: ?ai.LogEntry = null;
        send: {
            const config = try mail.load(arena, db, shared.master_key) orelse {
                failure = "Email delivery isn’t set up";
                break :send;
            };
            const sites = try data.sites(arena, db);
            var site: ?data.Site = null;
            for (sites) |candidate| if (candidate.id == item.site_id) {
                site = candidate;
            };
            // Failures are recorded and the schedule moves on, so nothing retries every tick.
            const report = renderReport(arena, shared, db, site orelse {
                failure = "The website was removed";
                break :send;
            }, item.name, item.view, at) catch |err| {
                failure = @errorName(err);
                break :send;
            };
            log = report.log;
            var recipients: std.ArrayList([]const u8) = .empty;
            var parts = std.mem.splitScalar(u8, item.recipients, ',');
            while (parts.next()) |part| {
                const email = std.mem.trim(u8, part, " ");
                if (email.len != 0) try recipients.append(arena, email);
            }
            mail.send(arena, shared.io, config, .{ .to = recipients.items, .subject = report.subject, .html = report.html, .text = report.text }) catch |err| {
                failure = @errorName(err);
            };
        }
        const write = shared.lockWrite();
        defer shared.unlockWrite();
        if (log) |entry| _ = try ai.log(arena, write, at, entry);
        const next = manage.nextRun(item.frequency, item.weekday, item.hour, at);
        if (failure.len == 0) {
            try write.run(arena, "UPDATE schedules SET next_run_at_ms=?,last_sent_at_ms=?,last_error=NULL WHERE id=?", .{ next, at, item.id });
        } else {
            std.log.warn("schedule_send_failed id={d} reason={s}", .{ item.id, failure });
            try write.run(arena, "UPDATE schedules SET next_run_at_ms=?,last_error=? WHERE id=?", .{ next, failure, item.id });
        }
    }
}

const Report = struct { subject: []const u8, html: []const u8, text: []const u8, log: ?ai.LogEntry };

/// Email-safe summary of a saved view: tables and inline styles only.
pub fn renderReport(arena: std.mem.Allocator, shared: *Shared, db: *db_mod.Db, site: data.Site, name: []const u8, view_path: []const u8, at: i64) !Report {
    const query_start = std.mem.findScalar(u8, view_path, '?');
    const params = html.Params.parse(arena, if (query_start) |index| view_path[index + 1 ..] else "") catch html.Params{};
    var view = try data.View.parse(arena, site, params, at);
    // Reports cover the last complete period.
    const today = at - @mod(at, data.day_ms);
    if (view.range.bucket_ms == data.day_ms) {
        const length = view.range.end_ms - view.range.start_ms;
        view.range.end_ms = today;
        view.range.start_ms = today - length;
        view.range.prev_end_ms = view.range.start_ms;
        view.range.prev_start_ms = view.range.start_ms - length;
    }
    const base = try origin(arena, db);
    const current = try data.totals(arena, db, view, view.range.start_ms, view.range.end_ms);
    const previous = try data.totals(arena, db, view, view.range.prev_start_ms, view.range.prev_end_ms);
    const summary = try ai.digest(arena, shared, db, view, at);
    var out: std.Io.Writer.Allocating = .init(arena);
    var text: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    const t = &text.writer;
    const esc = html.esc;
    try w.print("<!doctype html><html><body style=\"margin:0;background:#F7F5F4;font-family:-apple-system,'Segoe UI',Roboto,sans-serif;color:#282421\"><table width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"background:#F7F5F4\"><tr><td align=\"center\" style=\"padding:24px 12px\"><table width=\"600\" cellpadding=\"0\" cellspacing=\"0\" style=\"max-width:600px;background:#fff;border:1px solid #E9E4E1;border-radius:12px\"><tr><td style=\"padding:24px 28px 8px\"><div style=\"font-size:12px;color:#A0948E;font-weight:600;letter-spacing:.06em;text-transform:uppercase\">{f}</div><h1 style=\"margin:6px 0 2px;font:400 24px/30px Georgia,serif\">{f}</h1><div style=\"font-size:13px;color:#6F625D\">{f} · {f}</div></td></tr>", .{ esc(site.title()), esc(name), view.range, esc(try manage.viewLabel(arena, site, view_path)) });
    try t.print("{s} — {s}\n{f}\n\n", .{ site.title(), name, view.range });
    if (summary) |value| {
        try w.print("<tr><td style=\"padding:12px 28px\"><div style=\"background:#FBEDEA;border-radius:10px;padding:14px 16px;font-size:14px;line-height:21px\">{f}<div style=\"font-size:11px;color:#A0948E;margin-top:6px\">Written by AI from your numbers</div></div></td></tr>", .{esc(value.text)});
        try t.print("{s}\n\n", .{value.text});
    }
    try w.writeAll("<tr><td style=\"padding:8px 28px\"><table width=\"100%\" cellpadding=\"0\" cellspacing=\"0\"><tr>");
    const tiles = [_]struct { []const u8, f64, f64, bool }{
        .{ "Page views", @floatFromInt(current.views), @floatFromInt(previous.views), false },
        .{ "Visitor-days", @floatFromInt(current.visitor_days), @floatFromInt(previous.visitor_days), false },
        .{ "Active time", @floatFromInt(current.active_ms), @floatFromInt(previous.active_ms), true },
    };
    for (tiles) |tile| {
        const change = html.changeValue(tile[1], tile[2]);
        try w.print("<td width=\"33%\" style=\"padding:10px 12px;border:1px solid #E9E4E1;border-radius:10px\"><div style=\"font-size:12px;color:#6F625D\">{s}</div><div style=\"font:400 22px/30px Georgia,serif\">", .{tile[0]});
        if (tile[3]) try w.print("{f}", .{html.duration(@intFromFloat(tile[1]))}) else try w.print("{f}", .{html.int(@intFromFloat(tile[1]))});
        try w.print("</div><div style=\"font-size:12px;font-weight:600;color:{s}\">{f}</div></td>", .{ if (std.math.isNan(change) or change >= 0) "#22704A" else "#9F1D20", html.change(tile[1], tile[2]) });
        if (tile[3]) try t.print("{s}: {f} ({f})\n", .{ tile[0], html.duration(@intFromFloat(tile[1])), html.change(tile[1], tile[2]) }) else try t.print("{s}: {f} ({f})\n", .{ tile[0], html.int(@intFromFloat(tile[1])), html.change(tile[1], tile[2]) });
    }
    try w.writeAll("</tr></table></td></tr>");
    const sections = [_]struct { []const u8, data.Dim }{ .{ "Top pages", .page }, .{ "Where visitors come from", .source } };
    for (sections) |section| {
        const rows = try data.top(arena, db, view, section[1], 6);
        try w.print("<tr><td style=\"padding:16px 28px 4px\"><div style=\"font-size:14px;font-weight:600;margin-bottom:8px\">{s}</div><table width=\"100%\" cellpadding=\"0\" cellspacing=\"0\">", .{section[0]});
        try t.print("\n{s}\n", .{section[0]});
        for (rows) |row| {
            const label = if (section[1] == .source) try overview.sourceLabel(arena, row.key) else row.key;
            const width = if (rows[0].value == 0) 0 else @divFloor(row.value * 100, rows[0].value);
            try w.print("<tr><td style=\"padding:3px 0;font-size:13px\"><div style=\"background:#FBEDEA;border-radius:6px;width:{d}%;padding:6px 8px;white-space:nowrap\">{f}</div></td><td align=\"right\" style=\"font:14px Georgia,serif;padding-left:12px;width:70px\">{f}</td></tr>", .{ @max(width, 12), esc(label), html.int(row.value) });
            try t.print("  {s}: {d}\n", .{ label, row.value });
        }
        if (rows.len == 0) try w.writeAll("<tr><td style=\"font-size:13px;color:#766A64\">No data in this period.</td></tr>");
        try w.writeAll("</table></td></tr>");
    }
    const link = try std.fmt.allocPrint(arena, "{s}{s}", .{ base, view_path });
    try w.print("<tr><td style=\"padding:20px 28px 26px\"><a href=\"{f}\" style=\"display:inline-block;background:#B53A2B;color:#fff;text-decoration:none;font-weight:600;font-size:14px;padding:10px 18px;border-radius:8px\">Open in Analytico</a></td></tr></table><div style=\"font-size:11px;color:#A0948E;margin-top:12px\">Sent by Analytico · change or stop this email under Reports &amp; alerts</div></td></tr></table></body></html>", .{esc(link)});
    try t.print("\nOpen in Analytico: {s}\n", .{link});
    return .{ .subject = try std.fmt.allocPrint(arena, "{s} · {s}", .{ name, try std.fmt.allocPrint(arena, "{f}", .{view.range}) }), .html = out.written(), .text = text.written(), .log = if (summary) |value| value.log else null };
}

// ---------------------------------------------------------------- alerts

fn alerts(arena: std.mem.Allocator, shared: *Shared, db: *db_mod.Db, at: i64) !void {
    const today = at - @mod(at, data.day_ms);
    if (at < today + alert_hour * data.hour_ms) return;
    var statement = try db.prepare(arena, "SELECT id,site_id,name,metric,direction,threshold_percent,filters,email,state FROM alerts WHERE enabled=1 AND coalesce(checked_at_ms,0)<? LIMIT 20");
    defer statement.deinit();
    try statement.bindInt(1, today + alert_hour * data.hour_ms);
    const Alert = struct { id: i64, site_id: i64, name: []const u8, metric: []const u8, direction: []const u8, threshold: i64, filters: []const u8, email: bool, state: []const u8 };
    var list: std.ArrayList(Alert) = .empty;
    while (try statement.step() == .row) try list.append(arena, .{
        .id = statement.columnInt(0),
        .site_id = statement.columnInt(1),
        .name = try arena.dupe(u8, statement.columnText(2)),
        .metric = try arena.dupe(u8, statement.columnText(3)),
        .direction = try arena.dupe(u8, statement.columnText(4)),
        .threshold = statement.columnInt(5),
        .filters = try arena.dupe(u8, statement.columnText(6)),
        .email = statement.columnBool(7),
        .state = try arena.dupe(u8, statement.columnText(8)),
    });
    const sites = try data.sites(arena, db);
    for (list.items) |alert| {
        var site: ?data.Site = null;
        for (sites) |candidate| if (candidate.id == alert.site_id) {
            site = candidate;
        };
        if (site == null) continue;
        const values = try manage.alertSeries(arena, db, site.?, .{ .metric = alert.metric, .filters = alert.filters }, today, 2);
        const fired = manage.alertTriggered(alert.direction, alert.threshold, values[0], values[1]);
        const change_milli: i64 = if (values[0] > 0) @intFromFloat((values[1] - values[0]) / values[0] * 1000) else 0;
        var triage_text: ?[]const u8 = null;
        var log: ?ai.LogEntry = null;
        if (fired) {
            const result = try ai.triageText(arena, shared.io, db, ai.forBackground(arena, shared, db, at) catch null, site.?, alert.filters, at);
            triage_text = result.text;
            log = result.log;
            const headline_text = try std.fmt.allocPrint(arena, "{s} · {s}: {f} yesterday ({d:.0} vs {d:.0})", .{ site.?.title(), alert.name, html.change(values[1], values[0]), values[1], values[0] });
            integrations.broadcast(arena, shared, db, try std.fmt.allocPrint(arena, "*Alert* {s}\n{s}", .{ headline_text, result.text }), .{ .kind = "alert", .site = site.?.slug, .text = headline_text, .at_ms = at }, false) catch |err| std.log.warn("alert_channels_failed id={d} code={s}", .{ alert.id, @errorName(err) });
            if (alert.email) if (try mail.load(arena, db, shared.master_key)) |config| {
                const recipients = try teamEmails(arena, db);
                const link = try std.fmt.allocPrint(arena, "{s}/{s}/reports?tab=alerts", .{ try origin(arena, db), site.?.slug });
                const headline = try std.fmt.allocPrint(arena, "{s}: {f} yesterday ({d:.0} vs {d:.0})", .{ alert.name, html.change(values[1], values[0]), values[1], values[0] });
                if (recipients.len != 0) mail.send(arena, shared.io, config, .{
                    .to = recipients,
                    .subject = try std.fmt.allocPrint(arena, "Alert · {s} · {s}", .{ site.?.title(), alert.name }),
                    .text = try std.fmt.allocPrint(arena, "{s}\n\n{s}\n\n{s}\n", .{ headline, result.text, link }),
                    .html = try std.fmt.allocPrint(arena, "<p style=\"font:600 15px sans-serif\">{f}</p><p style=\"font:14px/21px sans-serif\">{f}</p><p><a href=\"{f}\">Inspect in Analytico</a></p>", .{ html.esc(headline), html.esc(result.text), html.esc(link) }),
                }) catch |err| std.log.warn("alert_mail_failed id={d} code={s}", .{ alert.id, @errorName(err) });
            };
        }
        const write = shared.lockWrite();
        defer shared.unlockWrite();
        if (log) |entry| _ = try ai.log(arena, write, at, entry);
        if (fired) {
            try write.run(arena, "UPDATE alerts SET state='triggered',triggered_at_ms=?,last_change_milli=?,triage=?,checked_at_ms=? WHERE id=?", .{ at, change_milli, triage_text.?, at, alert.id });
        } else {
            try write.run(arena, "UPDATE alerts SET state='quiet',checked_at_ms=? WHERE id=?", .{ at, alert.id });
        }
    }
}

// ---------------------------------------------------------------- anomaly notes

/// Once a day closes, a website whose day broke its trend gets a draft chart
/// note naming the largest driver, for an editor to keep or dismiss.
fn anomalies(arena: std.mem.Allocator, shared: *Shared, db: *db_mod.Db, at: i64) !void {
    const day_start = at - @mod(at, data.day_ms) - data.day_ms;
    const day = data.dateText(day_start);
    if (std.mem.eql(u8, (try data.setting(arena, db, .@"anomalies.day")) orelse "", &day)) return;
    for (try data.sites(arena, db)) |site| {
        const label = try anomaly(arena, db, site, day_start, at) orelse continue;
        const write = shared.lockWrite();
        defer shared.unlockWrite();
        try write.run(arena, "INSERT INTO annotations(site_id,day,label,created_at_ms,draft) SELECT ?1,?2,?3,?4,1 WHERE NOT EXISTS (SELECT 1 FROM annotations WHERE site_id=?1 AND day=?2)", .{ site.id, &day, label, at });
        std.log.info("anomaly_noted site={s} day={s}", .{ site.slug, &day });
    }
    const write = shared.lockWrite();
    defer shared.unlockWrite();
    try data.putSetting(arena, write, .@"anomalies.day", &day);
}

/// A note for the day if its page views were at least twice or at most half
/// the previous two weeks' mean and more than three deviations from it.
pub fn anomaly(arena: std.mem.Allocator, db: *db_mod.Db, site: data.Site, day_start: i64, now_ms: i64) !?[]const u8 {
    const query = try std.fmt.allocPrint(arena, "range=custom&from={s}&to={s}", .{ &data.dateText(day_start - 14 * data.day_ms), &data.dateText(day_start) });
    const view = try data.View.parse(arena, site, try html.Params.parse(arena, query), now_ms);
    const days = try data.series(arena, db, view, .views, view.range.start_ms);
    if (days.len != 15) return null;
    const last = days[14];
    var mean: f64 = 0;
    for (days[0..14]) |value| mean += value / 14;
    var variance: f64 = 0;
    for (days[0..14]) |value| variance += (value - mean) * (value - mean) / 14;
    // A quiet or brand-new website has no trend to break.
    if (mean < 10 or @max(last, mean) < 50) return null;
    const ratio = last / mean;
    if ((ratio < 2 and ratio > 0.5) or @abs(last - mean) <= 3 * @sqrt(variance)) return null;
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    if (ratio >= 2) try w.print("Traffic {d:.1}× usual", .{ratio}) else try w.print("Traffic {d:.0}% below usual", .{(1 - ratio) * 100});
    // Against the same weekday a week before.
    const result = try ai.drivers(arena, db, view, day_start, day_start + data.day_ms, day_start - 7 * data.day_ms, day_start - 6 * data.day_ms);
    if (result.list.len != 0) {
        // A source or page says more than "mobile visitors", which moves with
        // almost any spike; use it when it explains much of the change.
        const change = result.current - result.previous;
        var top = result.list[0];
        for (result.list) |driver| if (driver.dim != .device and @abs(driver.delta) * 10 >= @abs(change) * 4) {
            top = driver;
            break;
        };
        const label = try ai.driverLabel(arena, top);
        try w.print(", {s} {s}", .{ switch (top.dim) {
            .source => if (ratio >= 2) "mostly from" else "mostly fewer from",
            .page => if (ratio >= 2) "mostly on" else "mostly fewer on",
            else => if (ratio >= 2) "mostly" else "mostly fewer",
        }, label });
    }
    return out.written();
}

// ---------------------------------------------------------------- nightly

fn nightly(arena: std.mem.Allocator, shared: *Shared, db: *db_mod.Db, at: i64) !void {
    const today = at - @mod(at, data.day_ms);
    if (at < today + backup_hour * data.hour_ms) return;
    const last = std.fmt.parseInt(i64, (try data.setting(arena, db, .@"jobs.nightly_at")) orelse "0", 10) catch 0;
    if (last >= today + backup_hour * data.hour_ms) return;
    var backed_up = false;
    if (!std.mem.eql(u8, (try data.setting(arena, db, .@"backup.daily")) orelse "1", "0")) {
        if (settings.backupNow(arena, shared.io, shared.data, db, "daily", at)) |path| {
            backed_up = true;
            std.log.info("backup_created path={s}", .{path});
            settings.pruneBackups(arena, shared.io, shared.data, 14) catch {};
        } else |err| std.log.warn("backup_failed code={s}", .{@errorName(err)});
    }
    const retention = try data.setting(arena, db, .@"retention.days");
    {
        const write = shared.lockWrite();
        defer shared.unlockWrite();
        if (backed_up) try data.putSetting(arena, write, .@"backup.last_at", try std.fmt.allocPrint(arena, "{d}", .{at}));
        // Retention only runs right after a verified backup.
        if (retention) |value| if (backed_up) {
            const days = std.fmt.parseInt(i64, value, 10) catch 0;
            if (days >= 30) {
                const removed = try settings.prune(arena, write, at - days * data.day_ms);
                std.log.info("retention_pruned rows={d}", .{removed});
            }
        };
        try data.putSetting(arena, write, .@"jobs.nightly_at", try std.fmt.allocPrint(arena, "{d}", .{at}));
        // Fresh table statistics keep the query planner on the right indexes.
        write.exec("PRAGMA optimize") catch |err| std.log.warn("optimize_failed code={s}", .{@errorName(err)});
    }
    // Receipts catch retried and conflicting records. Nothing older than the
    // 90 days a record may arrive late can still come in, so older receipts
    // go, in batches that let ingestion through in between.
    while (true) {
        const write = shared.lockWrite();
        defer shared.unlockWrite();
        try write.run(arena, "DELETE FROM record_receipts WHERE (site_id,event_id) IN (SELECT site_id,event_id FROM record_receipts WHERE received_at_ms<? LIMIT 20000)", .{at - 91 * data.day_ms});
        if (write.changes() < 20000) break;
    }
    // The rest runs without the write lock: network calls and file writes.
    @import("privacy_settings.zig").pruneReplays(arena, shared, db, at) catch |err| std.log.warn("replay_prune_failed code={s}", .{@errorName(err)});
    integrations.nightly(arena, shared, db) catch |err| std.log.warn("integrations_failed code={s}", .{@errorName(err)});
    if (std.mem.eql(u8, (try data.setting(arena, db, .@"export.daily")) orelse "0", "1")) {
        _ = integrations.exportDay(arena, shared, db, at - data.day_ms) catch |err| std.log.warn("export_failed code={s}", .{@errorName(err)});
    }
}
