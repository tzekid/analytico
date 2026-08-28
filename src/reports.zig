const std = @import("std");
const db_mod = @import("db.zig");
const domain = @import("domain.zig");
const store_mod = @import("store.zig");

pub const Format = enum { table, json, csv };

pub const Options = struct {
    start_ms: i64,
    end_ms: i64,
    limit: i64 = 100,
    release: []const u8 = "",
    campaign: []const u8 = "",
    path: []const u8 = "",
    format: Format = .table,
};

pub fn resolveOptions(args: []const []const u8) !Options {
    const now = try domain.nowMilliseconds();
    const days_text = option(args, "--days") orelse "7";
    const days = std.fmt.parseInt(i64, days_text, 10) catch return error.InvalidDays;
    if (days < 1 or days > 3650) return error.InvalidDays;
    var start = now - days * 86_400_000;
    var end = now + 1;
    if (option(args, "--from")) |value| start = try dateMilliseconds(value);
    if (option(args, "--to")) |value| end = try dateMilliseconds(value) + 86_400_000;
    if (start >= end) return error.InvalidDateRange;
    const limit = std.fmt.parseInt(i64, option(args, "--limit") orelse "100", 10) catch return error.InvalidLimit;
    if (limit < 1 or limit > 1000) return error.InvalidLimit;
    var format: Format = .table;
    if (flag(args, "--json")) format = .json;
    if (flag(args, "--csv")) format = .csv;
    if (option(args, "--format")) |value| format = std.meta.stringToEnum(Format, value) orelse return error.InvalidFormat;
    const path = option(args, "--path") orelse "";
    if (path.len != 0) try domain.validatePath(path);
    return .{
        .start_ms = start,
        .end_ms = end,
        .limit = limit,
        .release = option(args, "--release") orelse "",
        .campaign = option(args, "--campaign") orelse "",
        .path = path,
        .format = format,
    };
}

pub fn resolveDaysOptions(args: []const []const u8) !Options {
    const now = try domain.nowMilliseconds();
    const days = std.fmt.parseInt(i64, option(args, "--days") orelse "7", 10) catch return error.InvalidDays;
    if (days < 1 or days > 3650) return error.InvalidDays;
    const limit = std.fmt.parseInt(i64, option(args, "--limit") orelse "100", 10) catch return error.InvalidLimit;
    if (limit < 1 or limit > 1000) return error.InvalidLimit;
    var format: Format = .table;
    if (flag(args, "--json")) format = .json;
    if (flag(args, "--csv")) format = .csv;
    return .{ .start_ms = now - days * 86_400_000, .end_ms = now + 1, .limit = limit, .format = format };
}

pub fn run(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    store: *store_mod.Store,
    site_id: i64,
    kind: []const u8,
    options_value: Options,
) !void {
    const sql = reportSql(kind) orelse return error.UnknownReport;
    var statement = try store.database.prepare(allocator, sql);
    defer statement.deinit();
    try bindCommon(&statement, site_id, options_value);
    try statement.bindInt(10, options_value.limit);
    try writeRows(output, &statement, options_value.format);
}

pub fn sessionList(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    store: *store_mod.Store,
    site_id: i64,
    options_value: Options,
) !void {
    var statement = try store.database.prepare(allocator,
        \\SELECT pv.session_id,min(pv.received_at_ms) AS started_at_ms,max(pv.received_at_ms) AS ended_at_ms,
        \\ max(pv.received_at_ms)-min(pv.received_at_ms) AS duration_ms,count(*) AS page_views,
        \\ count(DISTINCT pv.path) AS distinct_pages,
        \\ (SELECT count(*) FROM events e WHERE e.internal=0 AND e.site_id=pv.site_id AND e.session_id=pv.session_id AND e.received_at_ms>=?2 AND e.received_at_ms<?3) AS events,
        \\ (SELECT x.path FROM page_views x WHERE x.internal=0 AND x.site_id=pv.site_id AND x.session_id=pv.session_id ORDER BY x.received_at_ms LIMIT 1) AS landing_path,
        \\ (SELECT x.path FROM page_views x WHERE x.internal=0 AND x.site_id=pv.site_id AND x.session_id=pv.session_id ORDER BY x.received_at_ms DESC LIMIT 1) AS exit_path
        \\FROM page_views pv WHERE pv.internal=0 AND pv.traffic_class IN ('human_like','unknown') AND pv.site_id=?1 AND pv.received_at_ms>=?2 AND pv.received_at_ms<?3 AND pv.session_id IS NOT NULL
        \\GROUP BY pv.site_id,pv.session_id ORDER BY ended_at_ms DESC LIMIT ?4
    );
    defer statement.deinit();
    try statement.bindInt(1, site_id);
    try statement.bindInt(2, options_value.start_ms);
    try statement.bindInt(3, options_value.end_ms);
    try statement.bindInt(4, options_value.limit);
    try writeRows(output, &statement, options_value.format);
}

pub fn sessionShow(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    store: *store_mod.Store,
    site_id: i64,
    session_id: []const u8,
    format: Format,
) !void {
    try domain.validateUuid(session_id);
    var statement = try store.database.prepare(allocator,
        \\SELECT occurred_at_ms,received_at_ms,kind,name,path,properties_json FROM (
        \\ SELECT occurred_at_ms,received_at_ms,'page_view' kind,'page_view' name,path,'{}' properties_json
        \\ FROM page_views WHERE internal=0 AND traffic_class IN ('human_like','unknown') AND site_id=?1 AND session_id=?2
        \\ UNION ALL SELECT occurred_at_ms,received_at_ms,'event',name,coalesce(path,''),properties_json
        \\ FROM events e WHERE e.internal=0 AND e.site_id=?1 AND e.session_id=?2 AND (e.source='server' OR EXISTS(SELECT 1 FROM page_views p WHERE p.site_id=e.site_id AND p.page_id=e.page_id AND p.traffic_class IN ('human_like','unknown')))
        \\) ORDER BY occurred_at_ms,received_at_ms LIMIT 1000
    );
    defer statement.deinit();
    try statement.bindInt(1, site_id);
    try statement.bindText(2, session_id);
    try writeRows(output, &statement, format);
}

pub fn flow(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    store: *store_mod.Store,
    site_id: i64,
    flow_name: []const u8,
    options_value: Options,
) !void {
    try domain.validateName(flow_name);
    var statement = try store.database.prepare(allocator,
        \\WITH matched AS (
        \\ SELECT e.* FROM events e WHERE e.internal=0 AND e.site_id=?1 AND e.received_at_ms>=?2 AND e.received_at_ms<?3 AND (e.source='server' OR EXISTS(SELECT 1 FROM page_views p WHERE p.site_id=e.site_id AND p.page_id=e.page_id AND p.traffic_class IN ('human_like','unknown')))
        \\ AND json_extract(e.properties_json,'$.flow')=?4 AND e.name LIKE 'flow_%'
        \\), actual AS (
        \\ SELECT name,coalesce(json_extract(properties_json,'$.step'),'') step,count(*) occurrences,
        \\ count(DISTINCT session_id) sessions,min(received_at_ms) first_at FROM matched GROUP BY name,step
        \\), session_last AS (
        \\ SELECT session_id,max(received_at_ms) last_at FROM (
        \\  SELECT session_id,received_at_ms FROM page_views WHERE internal=0 AND traffic_class IN ('human_like','unknown') AND site_id=?1 AND received_at_ms>=?2 AND received_at_ms<?3 AND session_id IS NOT NULL
        \\  UNION ALL SELECT e.session_id,e.received_at_ms FROM events e WHERE e.internal=0 AND e.site_id=?1 AND e.received_at_ms>=?2 AND e.received_at_ms<?3 AND e.session_id IS NOT NULL AND (e.source='server' OR EXISTS(SELECT 1 FROM page_views p WHERE p.site_id=e.site_id AND p.page_id=e.page_id AND p.traffic_class IN ('human_like','unknown')))
        \\ ) GROUP BY session_id
        \\), abandoned AS (
        \\ SELECT 'flow_abandoned' name,'' step,count(*) occurrences,count(*) sessions,9223372036854775807 first_at
        \\ FROM (SELECT DISTINCT m.session_id FROM matched m JOIN session_last s ON s.session_id=m.session_id
        \\ WHERE m.name='flow_started' AND m.session_id IS NOT NULL AND s.last_at<unixepoch('subsec')*1000-1800000
        \\ AND NOT EXISTS (SELECT 1 FROM matched done WHERE done.session_id=m.session_id AND done.name='flow_completed'))
        \\)
        \\SELECT name,step,occurrences,sessions FROM (SELECT * FROM actual UNION ALL SELECT * FROM abandoned WHERE sessions>0)
        \\ORDER BY first_at,name,step LIMIT ?5
    );
    defer statement.deinit();
    try statement.bindInt(1, site_id);
    try statement.bindInt(2, options_value.start_ms);
    try statement.bindInt(3, options_value.end_ms);
    try statement.bindText(4, flow_name);
    try statement.bindInt(5, options_value.limit);
    try writeRows(output, &statement, options_value.format);
}

pub fn friction(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    store: *store_mod.Store,
    site_id: i64,
    flow_name: []const u8,
    options_value: Options,
) !void {
    if (flow_name.len != 0) try domain.validateName(flow_name);
    var statement = try store.database.prepare(allocator,
        \\SELECT e.name,coalesce(json_extract(e.properties_json,'$.step'),'') AS step,
        \\ coalesce(json_extract(e.properties_json,'$.action'),'') AS action,
        \\ coalesce(json_extract(e.properties_json,'$.error'),'') AS error_code,
        \\ coalesce(json_extract(e.properties_json,'$.attempt_bucket'),'') AS attempt_bucket,
        \\ coalesce(json_extract(e.properties_json,'$.dwell_bucket'),'') AS dwell_bucket,
        \\ coalesce(json_extract(e.properties_json,'$.click_bucket'),'') AS click_bucket,count(*) AS occurrences,
        \\ count(DISTINCT e.session_id) AS sessions
        \\FROM events e WHERE e.internal=0 AND e.site_id=?1 AND e.received_at_ms>=?2 AND e.received_at_ms<?3 AND (e.source='server' OR EXISTS(SELECT 1 FROM page_views p WHERE p.site_id=e.site_id AND p.page_id=e.page_id AND p.traffic_class IN ('human_like','unknown')))
        \\AND (?4='' OR json_extract(e.properties_json,'$.flow')=?4)
        \\AND e.name IN ('flow_step_failed','flow_backtracked','action_failed','action_unresponsive','rage_click')
        \\GROUP BY e.name,step,action,error_code,attempt_bucket,dwell_bucket,click_bucket ORDER BY occurrences DESC LIMIT ?5
    );
    defer statement.deinit();
    try statement.bindInt(1, site_id);
    try statement.bindInt(2, options_value.start_ms);
    try statement.bindInt(3, options_value.end_ms);
    try statement.bindText(4, flow_name);
    try statement.bindInt(5, options_value.limit);
    try writeRows(output, &statement, options_value.format);
}

pub fn paths(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    store: *store_mod.Store,
    site_id: i64,
    from_path: []const u8,
    options_value: Options,
) !void {
    try domain.validatePath(from_path);
    var statement = try store.database.prepare(allocator,
        \\WITH ordered AS (
        \\ SELECT session_id,path,lead(path) OVER(PARTITION BY session_id ORDER BY occurred_at_ms,received_at_ms) next_path
        \\ FROM page_views WHERE internal=0 AND traffic_class IN ('human_like','unknown') AND site_id=?1 AND received_at_ms>=?2 AND received_at_ms<?3 AND session_id IS NOT NULL
        \\)
        \\SELECT path AS from_path,next_path,count(*) AS transitions FROM ordered
        \\WHERE path=?4 AND next_path IS NOT NULL GROUP BY path,next_path ORDER BY transitions DESC,next_path LIMIT ?5
    );
    defer statement.deinit();
    try statement.bindInt(1, site_id);
    try statement.bindInt(2, options_value.start_ms);
    try statement.bindInt(3, options_value.end_ms);
    try statement.bindText(4, from_path);
    try statement.bindInt(5, options_value.limit);
    try writeRows(output, &statement, options_value.format);
}

pub fn campaignEconomics(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    store: *store_mod.Store,
    site_id: i64,
    options_value: Options,
) !void {
    var statement = try store.database.prepare(allocator,
        \\WITH campaign_sessions AS (
        \\ SELECT site_id,session_id,max(coalesce(utm_source,'')) source,max(coalesce(utm_campaign,'')) campaign,
        \\ max(coalesce(utm_content,'')) content,count(*) landing_views
        \\ FROM page_views WHERE internal=0 AND traffic_class IN ('human_like','unknown') AND site_id=?1 AND received_at_ms>=?2 AND received_at_ms<?3 AND session_id IS NOT NULL AND utm_campaign IS NOT NULL
        \\ GROUP BY site_id,session_id
        \\), keys AS (
        \\ SELECT source,campaign,content FROM campaign_sessions UNION
        \\ SELECT source,campaign,content FROM campaign_spend WHERE site_id=?1 AND unixepoch(spend_date)*1000>=?2 AND unixepoch(spend_date)*1000<?3 UNION
        \\ SELECT coalesce(json_extract(properties_json,'$.source'),''),coalesce(json_extract(properties_json,'$.campaign'),''),coalesce(json_extract(properties_json,'$.content'),'')
        \\ FROM events WHERE internal=0 AND site_id=?1 AND received_at_ms>=?2 AND received_at_ms<?3 AND source='server' AND json_extract(properties_json,'$.campaign') IS NOT NULL
        \\), facts AS (
        \\SELECT k.source,k.campaign,k.content,
        \\ coalesce((SELECT sum(amount_minor) FROM campaign_spend s WHERE s.site_id=?1 AND s.source=k.source AND s.campaign=k.campaign AND s.content=k.content AND unixepoch(s.spend_date)*1000>=?2 AND unixepoch(s.spend_date)*1000<?3),0) spend_minor,
        \\ coalesce((SELECT max(currency) FROM campaign_spend s WHERE s.site_id=?1 AND s.source=k.source AND s.campaign=k.campaign AND s.content=k.content),
        \\ (SELECT max(e.currency) FROM events e WHERE e.internal=0 AND e.site_id=?1 AND e.received_at_ms>=?2 AND e.received_at_ms<?3 AND coalesce(json_extract(e.properties_json,'$.source'),'')=k.source AND coalesce(json_extract(e.properties_json,'$.campaign'),'')=k.campaign AND coalesce(json_extract(e.properties_json,'$.content'),'')=k.content),'') currency,
        \\ (SELECT count(*) FROM campaign_sessions cs WHERE cs.source=k.source AND cs.campaign=k.campaign AND cs.content=k.content) landing_sessions,
        \\ (SELECT count(DISTINCT cs.session_id) FROM campaign_sessions cs JOIN page_summaries ps ON ps.site_id=cs.site_id AND ps.session_id=cs.session_id WHERE cs.source=k.source AND cs.campaign=k.campaign AND cs.content=k.content AND (ps.active_ms>=10000 OR ps.max_scroll>=50 OR ps.interaction_count>0)) engaged_sessions,
        \\ (SELECT count(DISTINCT e.session_id) FROM events e JOIN campaign_sessions cs ON cs.site_id=e.site_id AND cs.session_id=e.session_id WHERE e.internal=0 AND cs.source=k.source AND cs.campaign=k.campaign AND cs.content=k.content AND e.name='registration_started') registration_starts,
        \\ (SELECT count(*) FROM events e WHERE e.internal=0 AND e.site_id=?1 AND e.name='registration_confirmed' AND e.received_at_ms>=?2 AND e.received_at_ms<?3 AND coalesce(json_extract(e.properties_json,'$.source'),'')=k.source AND coalesce(json_extract(e.properties_json,'$.campaign'),'')=k.campaign AND coalesce(json_extract(e.properties_json,'$.content'),'')=k.content) registrations,
        \\ (SELECT count(*) FROM events e WHERE e.internal=0 AND e.site_id=?1 AND e.name='payment_confirmed' AND e.received_at_ms>=?2 AND e.received_at_ms<?3 AND coalesce(json_extract(e.properties_json,'$.source'),'')=k.source AND coalesce(json_extract(e.properties_json,'$.campaign'),'')=k.campaign AND coalesce(json_extract(e.properties_json,'$.content'),'')=k.content) paid_registrations,
        \\ (SELECT count(*) FROM events e WHERE e.internal=0 AND e.site_id=?1 AND e.name IN ('payment_refunded','refund_confirmed') AND e.received_at_ms>=?2 AND e.received_at_ms<?3 AND coalesce(json_extract(e.properties_json,'$.source'),'')=k.source AND coalesce(json_extract(e.properties_json,'$.campaign'),'')=k.campaign AND coalesce(json_extract(e.properties_json,'$.content'),'')=k.content) refunds,
        \\ (SELECT count(*) FROM events e WHERE e.internal=0 AND e.site_id=?1 AND e.name='attendance_confirmed' AND e.received_at_ms>=?2 AND e.received_at_ms<?3 AND coalesce(json_extract(e.properties_json,'$.source'),'')=k.source AND coalesce(json_extract(e.properties_json,'$.campaign'),'')=k.campaign AND coalesce(json_extract(e.properties_json,'$.content'),'')=k.content) attendees,
        \\ coalesce((SELECT sum(e.value_minor) FROM events e WHERE e.internal=0 AND e.site_id=?1 AND e.name='payment_confirmed' AND e.received_at_ms>=?2 AND e.received_at_ms<?3 AND coalesce(json_extract(e.properties_json,'$.source'),'')=k.source AND coalesce(json_extract(e.properties_json,'$.campaign'),'')=k.campaign AND coalesce(json_extract(e.properties_json,'$.content'),'')=k.content),0)-
        \\ coalesce((SELECT sum(e.value_minor) FROM events e WHERE e.internal=0 AND e.site_id=?1 AND e.name IN ('payment_refunded','refund_confirmed') AND e.received_at_ms>=?2 AND e.received_at_ms<?3 AND coalesce(json_extract(e.properties_json,'$.source'),'')=k.source AND coalesce(json_extract(e.properties_json,'$.campaign'),'')=k.campaign AND coalesce(json_extract(e.properties_json,'$.content'),'')=k.content),0) revenue_minor
        \\FROM keys k WHERE k.campaign<>'' AND (?4='' OR k.campaign=?4)
        \\)
        \\SELECT *,
        \\ CASE WHEN registration_starts>0 THEN spend_minor/registration_starts END cost_per_start_minor,
        \\ CASE WHEN paid_registrations>0 THEN spend_minor/paid_registrations END cost_per_paid_minor,
        \\ CASE WHEN attendees>0 THEN spend_minor/attendees END cost_per_attendee_minor,
        \\ CASE WHEN spend_minor>0 THEN round(1.0*revenue_minor/spend_minor,3) END roas
        \\FROM facts ORDER BY revenue_minor DESC,campaign LIMIT ?5
    );
    defer statement.deinit();
    try statement.bindInt(1, site_id);
    try statement.bindInt(2, options_value.start_ms);
    try statement.bindInt(3, options_value.end_ms);
    try statement.bindText(4, options_value.campaign);
    try statement.bindInt(5, options_value.limit);
    try writeRows(output, &statement, options_value.format);
}

fn reportSql(kind: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, kind, "overview")) return
    \\WITH filtered AS (
    \\ SELECT pv.* FROM page_views pv WHERE pv.internal=0 AND pv.traffic_class IN ('human_like','unknown') AND pv.site_id=? AND pv.received_at_ms>=? AND pv.received_at_ms<?
    \\ AND (?='' OR coalesce(pv.release_id,'')=?) AND (?='' OR coalesce(pv.utm_campaign,'')=?) AND (?='' OR pv.path=?)
    \\)
    \\SELECT count(*) AS page_views,count(DISTINCT visitor_day_id) AS visitors,
    \\ count(DISTINCT session_id) AS sessions,
    \\ (SELECT count(*) FROM events e WHERE e.internal=0 AND e.site_id=?1
    \\   AND e.received_at_ms>=?2 AND e.received_at_ms<?3
    \\   AND (e.source='server' OR EXISTS(SELECT 1 FROM page_views p WHERE p.site_id=e.site_id AND p.page_id=e.page_id AND p.traffic_class IN ('human_like','unknown')))
    \\   AND (?4='' OR coalesce(e.release_id,'')=?5)
    \\   AND (?6='' OR coalesce(json_extract(e.properties_json,'$.campaign'),'')=?7)
    \\   AND (?8='' OR coalesce(e.path,'')=?9)) AS events,
    \\ coalesce((SELECT sum(ps.active_ms) FROM page_summaries ps JOIN filtered f ON f.site_id=ps.site_id AND f.page_id=ps.page_id),0) AS active_ms,
    \\ count(DISTINCT path) AS pages FROM filtered LIMIT ?10
    ;
    if (std.mem.eql(u8, kind, "pages")) return
    \\SELECT pv.path,count(*) AS views,count(DISTINCT pv.visitor_day_id) AS visitors,
    \\ coalesce(round(avg(ps.active_ms)),0) AS avg_active_ms,coalesce(round(avg(ps.max_scroll)),0) AS avg_scroll
    \\FROM page_views pv LEFT JOIN page_summaries ps ON ps.site_id=pv.site_id AND ps.page_id=pv.page_id
    \\WHERE pv.internal=0 AND pv.traffic_class IN ('human_like','unknown') AND pv.site_id=? AND pv.received_at_ms>=? AND pv.received_at_ms<?
    \\AND (?='' OR coalesce(pv.release_id,'')=?) AND (?='' OR coalesce(pv.utm_campaign,'')=?) AND (?='' OR pv.path=?)
    \\GROUP BY pv.path ORDER BY views DESC,pv.path LIMIT ?
    ;
    if (std.mem.eql(u8, kind, "acquisition")) return
    \\SELECT coalesce(nullif(pv.utm_source,''),nullif(pv.referrer_host,''),'direct') AS source,
    \\ coalesce(nullif(pv.utm_medium,''),'') AS medium,count(*) AS views,
    \\ count(DISTINCT pv.visitor_day_id) AS visitors
    \\FROM page_views pv WHERE pv.internal=0 AND pv.traffic_class IN ('human_like','unknown') AND pv.site_id=? AND pv.received_at_ms>=? AND pv.received_at_ms<?
    \\AND (?='' OR coalesce(pv.release_id,'')=?) AND (?='' OR coalesce(pv.utm_campaign,'')=?) AND (?='' OR pv.path=?)
    \\GROUP BY source,medium ORDER BY views DESC,source LIMIT ?
    ;
    if (std.mem.eql(u8, kind, "campaigns")) return
    \\SELECT coalesce(pv.utm_source,'') AS source,coalesce(pv.utm_campaign,'') AS campaign,
    \\ coalesce(pv.utm_content,'') AS content,count(*) AS views,
    \\ count(DISTINCT pv.visitor_day_id) AS visitors,count(DISTINCT pv.session_id) AS sessions
    \\FROM page_views pv WHERE pv.internal=0 AND pv.traffic_class IN ('human_like','unknown') AND pv.site_id=? AND pv.received_at_ms>=? AND pv.received_at_ms<?
    \\AND (?='' OR coalesce(pv.release_id,'')=?) AND (?='' OR coalesce(pv.utm_campaign,'')=?) AND (?='' OR pv.path=?)
    \\AND pv.utm_campaign IS NOT NULL GROUP BY source,campaign,content ORDER BY views DESC LIMIT ?
    ;
    if (std.mem.eql(u8, kind, "sections")) return
    \\SELECT j.value AS section,count(*) AS exposures,
    \\ round(100.0*count(*)/max(1,(SELECT count(*) FROM page_views x WHERE x.internal=0 AND x.traffic_class IN ('human_like','unknown') AND x.site_id=pv.site_id AND x.received_at_ms>=?2 AND x.received_at_ms<?3 AND (?9='' OR x.path=?9))),1) AS exposure_percent
    \\FROM page_views pv JOIN page_summaries ps ON ps.site_id=pv.site_id AND ps.page_id=pv.page_id, json_each(ps.sections_json) j
    \\WHERE pv.internal=0 AND pv.traffic_class IN ('human_like','unknown') AND pv.site_id=?1 AND pv.received_at_ms>=?2 AND pv.received_at_ms<?3
    \\AND (?4='' OR coalesce(pv.release_id,'')=?5) AND (?6='' OR coalesce(pv.utm_campaign,'')=?7) AND (?8='' OR pv.path=?9)
    \\GROUP BY j.value ORDER BY exposures DESC,j.value LIMIT ?10
    ;
    if (std.mem.eql(u8, kind, "actions")) return
    \\SELECT e.name,coalesce(json_extract(e.properties_json,'$.action'),'') AS action,count(*) AS occurrences
    \\FROM events e WHERE e.internal=0 AND e.site_id=? AND e.received_at_ms>=? AND e.received_at_ms<? AND (e.source='server' OR EXISTS(SELECT 1 FROM page_views p WHERE p.site_id=e.site_id AND p.page_id=e.page_id AND p.traffic_class IN ('human_like','unknown')))
    \\AND (?='' OR coalesce(e.release_id,'')=?) AND (?='' OR coalesce(json_extract(e.properties_json,'$.campaign'),'')=?) AND (?='' OR coalesce(e.path,'')=?)
    \\AND (e.name LIKE 'action_%' OR e.name='rage_click') GROUP BY e.name,action ORDER BY occurrences DESC LIMIT ?
    ;
    if (std.mem.eql(u8, kind, "events")) return
    \\SELECT e.name,e.source,count(*) AS occurrences,count(DISTINCT e.session_id) AS sessions,
    \\ coalesce(sum(e.value_minor),0) AS value_minor,max(coalesce(e.currency,'')) AS currency
    \\FROM events e WHERE e.internal=0 AND e.site_id=? AND e.received_at_ms>=? AND e.received_at_ms<? AND (e.source='server' OR EXISTS(SELECT 1 FROM page_views p WHERE p.site_id=e.site_id AND p.page_id=e.page_id AND p.traffic_class IN ('human_like','unknown')))
    \\AND (?='' OR coalesce(e.release_id,'')=?) AND (?='' OR coalesce(json_extract(e.properties_json,'$.campaign'),'')=?) AND (?='' OR coalesce(e.path,'')=?)
    \\GROUP BY e.name,e.source ORDER BY occurrences DESC,e.name LIMIT ?
    ;
    if (std.mem.eql(u8, kind, "recent")) return
    \\SELECT received_at_ms,kind,name,path,source,session_id FROM (
    \\ SELECT pv.received_at_ms,'page_view' AS kind,'page_view' AS name,pv.path,'browser' AS source,pv.session_id,pv.release_id,pv.utm_campaign
    \\ FROM page_views pv WHERE pv.internal=0 AND pv.traffic_class IN ('human_like','unknown') AND pv.site_id=?1 AND pv.received_at_ms>=?2 AND pv.received_at_ms<?3
    \\ UNION ALL SELECT e.received_at_ms,'event',e.name,coalesce(e.path,''),e.source,e.session_id,e.release_id,json_extract(e.properties_json,'$.campaign')
    \\ FROM events e WHERE e.internal=0 AND e.site_id=?1 AND e.received_at_ms>=?2 AND e.received_at_ms<?3 AND (e.source='server' OR EXISTS(SELECT 1 FROM page_views p WHERE p.site_id=e.site_id AND p.page_id=e.page_id AND p.traffic_class IN ('human_like','unknown')))
    \\) WHERE (?4='' OR coalesce(release_id,'')=?5) AND (?6='' OR coalesce(utm_campaign,'')=?7) AND (?8='' OR path=?9)
    \\ORDER BY received_at_ms DESC LIMIT ?10
    ;
    if (std.mem.eql(u8, kind, "coverage")) return
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
    if (std.mem.eql(u8, kind, "traffic")) return
    \\SELECT pv.traffic_class,pv.internal,count(*) AS page_views,count(DISTINCT pv.visitor_day_id) AS visitors
    \\FROM page_views pv WHERE pv.site_id=?1 AND pv.received_at_ms>=?2 AND pv.received_at_ms<?3
    \\AND (?4='' OR coalesce(pv.release_id,'')=?5) AND (?6='' OR coalesce(pv.utm_campaign,'')=?7) AND (?8='' OR pv.path=?9)
    \\GROUP BY pv.traffic_class,pv.internal ORDER BY page_views DESC,pv.traffic_class LIMIT ?10
    ;
    if (std.mem.eql(u8, kind, "performance")) return
    \\WITH base AS (
    \\ SELECT coalesce(pv.page_type,'') AS page_type,coalesce(pv.release_id,'') AS release_id,pv.device,ps.*
    \\ FROM page_views pv JOIN page_summaries ps ON ps.site_id=pv.site_id AND ps.page_id=pv.page_id
    \\ WHERE pv.internal=0 AND pv.traffic_class IN ('human_like','unknown') AND pv.site_id=?1 AND pv.received_at_ms>=?2 AND pv.received_at_ms<?3
    \\ AND (?4='' OR coalesce(pv.release_id,'')=?5) AND (?6='' OR coalesce(pv.utm_campaign,'')=?7) AND (?8='' OR pv.path=?9)
    \\), samples AS (
    \\ SELECT page_type,release_id,device,'ttfb' metric,ttfb_ms value FROM base WHERE ttfb_ms IS NOT NULL UNION ALL
    \\ SELECT page_type,release_id,device,'fcp',fcp_ms FROM base WHERE fcp_ms IS NOT NULL UNION ALL
    \\ SELECT page_type,release_id,device,'lcp',lcp_ms FROM base WHERE lcp_ms IS NOT NULL UNION ALL
    \\ SELECT page_type,release_id,device,'inp',inp_ms FROM base WHERE inp_ms IS NOT NULL UNION ALL
    \\ SELECT page_type,release_id,device,'cls_milli',cls_milli FROM base WHERE cls_milli IS NOT NULL
    \\), ranked AS (
    \\ SELECT *,row_number() OVER(PARTITION BY page_type,release_id,device,metric ORDER BY value) rn,
    \\ count(*) OVER(PARTITION BY page_type,release_id,device,metric) n FROM samples
    \\)
    \\SELECT page_type,release_id,device,metric,max(n) samples,
    \\ min(CASE WHEN rn*100>=n*50 THEN value END) p50,
    \\ min(CASE WHEN rn*100>=n*75 THEN value END) p75,
    \\ min(CASE WHEN rn*100>=n*95 THEN value END) p95
    \\FROM ranked GROUP BY page_type,release_id,device,metric ORDER BY page_type,release_id,device,metric LIMIT ?10
    ;
    return null;
}

fn bindCommon(statement: *db_mod.Statement, site_id: i64, options_value: Options) !void {
    try statement.bindInt(1, site_id);
    try statement.bindInt(2, options_value.start_ms);
    try statement.bindInt(3, options_value.end_ms);
    try statement.bindText(4, options_value.release);
    try statement.bindText(5, options_value.release);
    try statement.bindText(6, options_value.campaign);
    try statement.bindText(7, options_value.campaign);
    try statement.bindText(8, options_value.path);
    try statement.bindText(9, options_value.path);
}

pub fn writeRows(output: *std.Io.Writer, statement: *db_mod.Statement, format: Format) !void {
    const count = statement.columnCount();
    switch (format) {
        .table, .csv => {
            for (0..count) |index| {
                if (index != 0) try output.writeByte(if (format == .csv) ',' else '\t');
                if (format == .csv) try csvText(output, statement.columnName(index)) else try output.writeAll(statement.columnName(index));
            }
            try output.writeByte('\n');
        },
        .json => try output.writeByte('['),
    }
    var row_index: usize = 0;
    while (try statement.step() == .row) : (row_index += 1) {
        if (format == .json) {
            if (row_index != 0) try output.writeByte(',');
            try output.writeByte('{');
        }
        for (0..count) |index| {
            if (format == .json) {
                if (index != 0) try output.writeByte(',');
                try std.json.Stringify.value(statement.columnName(index), .{}, output);
                try output.writeByte(':');
                try writeJsonValue(output, statement, index);
            } else {
                if (index != 0) try output.writeByte(if (format == .csv) ',' else '\t');
                try writeTextValue(output, statement, index, format == .csv);
            }
        }
        if (format == .json) try output.writeByte('}') else try output.writeByte('\n');
    }
    if (format == .json) try output.writeAll("]\n");
}

fn writeJsonValue(output: *std.Io.Writer, statement: *db_mod.Statement, index: usize) !void {
    const c = db_mod.sqlite;
    switch (statement.columnType(index)) {
        c.SQLITE_NULL => try output.writeAll("null"),
        c.SQLITE_INTEGER => try output.print("{d}", .{statement.columnInt(index)}),
        c.SQLITE_FLOAT => try output.print("{d}", .{statement.columnFloat(index)}),
        else => try std.json.Stringify.value(statement.columnText(index), .{}, output),
    }
}

fn writeTextValue(output: *std.Io.Writer, statement: *db_mod.Statement, index: usize, csv: bool) !void {
    const c = db_mod.sqlite;
    switch (statement.columnType(index)) {
        c.SQLITE_NULL => {},
        c.SQLITE_INTEGER => try output.print("{d}", .{statement.columnInt(index)}),
        c.SQLITE_FLOAT => try output.print("{d}", .{statement.columnFloat(index)}),
        else => if (csv) try csvText(output, statement.columnText(index)) else try output.writeAll(statement.columnText(index)),
    }
}

fn csvText(output: *std.Io.Writer, value: []const u8) !void {
    try output.writeByte('"');
    if (value.len != 0 and std.mem.findScalar(u8, "=+-@", value[0]) != null) try output.writeByte('\'');
    for (value) |byte| {
        if (byte == '"') try output.writeByte('"');
        try output.writeByte(byte);
    }
    try output.writeByte('"');
}

fn dateMilliseconds(value: []const u8) !i64 {
    if (value.len != 10 or value[4] != '-' or value[7] != '-') return error.InvalidDate;
    const year = std.fmt.parseInt(u16, value[0..4], 10) catch return error.InvalidDate;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return error.InvalidDate;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return error.InvalidDate;
    if (year < 1970 or month < 1 or month > 12 or day < 1) return error.InvalidDate;
    const lengths = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var max_day = lengths[month - 1];
    if (month == 2 and year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) max_day = 29;
    if (day > max_day) return error.InvalidDate;
    var days: i64 = 0;
    var cursor: u16 = 1970;
    while (cursor < year) : (cursor += 1) days += if (cursor % 4 == 0 and (cursor % 100 != 0 or cursor % 400 == 0)) 366 else 365;
    for (1..month) |m| {
        days += lengths[m - 1];
        if (m == 2 and year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) days += 1;
    }
    days += day - 1;
    return days * 86_400_000;
}

fn option(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args, 0..) |arg, index| if (std.mem.eql(u8, arg, name) and index + 1 < args.len) return args[index + 1];
    return null;
}

fn flag(args: []const []const u8, name: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, name)) return true;
    return false;
}
