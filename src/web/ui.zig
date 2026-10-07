//! The workspace's recurring pieces of markup, each written in one place.
const std = @import("std");
const data = @import("data.zig");
const html = @import("html.zig");

const Writer = std.Io.Writer;
const render = html.render;

/// A settings page's title and introduction, with optional actions (HTML).
pub fn sectionHead(w: *Writer, title: []const u8, intro: []const u8, actions: []const u8) !void {
    try render(w,
        \\<div class="section-head"><div><h2>{title}</h2><p>{intro}</p></div>{!actions}</div>
    , .{ .title = title, .intro = intro, .actions = actions });
}

pub const Kind = enum { plain, good, warn, bad };

/// A highlighted note; `body` is HTML.
pub fn callout(w: *Writer, kind: Kind, body: []const u8) !void {
    try render(w,
        \\<div class="callout{!tone}"><span>{!body}</span></div>
    , .{ .tone = switch (kind) {
        .plain => "",
        .good => " callout-good",
        .warn => " callout-warn",
        .bad => " callout-bad",
    }, .body = body });
}

/// A hidden form field.
pub fn hidden(w: *Writer, name: []const u8, value: []const u8) !void {
    try render(w,
        \\<input type="hidden" name="{name}" value="{value}">
    , .{ .name = name, .value = value });
}

/// Nothing to show yet: a title, a sentence and an optional action (HTML).
pub fn empty(w: *Writer, title: []const u8, body: []const u8, action: []const u8) !void {
    try render(w,
        \\<div class="empty"><svg class="empty-art" viewBox="0 0 200 120" aria-hidden="true"><rect x="20" y="70" width="24" height="34" rx="5" fill="#F3EFED"/><rect x="56" y="52" width="24" height="52" rx="5" fill="#F3EFED"/><rect x="92" y="34" width="24" height="70" rx="5" fill="#FBEDEA"/><rect x="128" y="18" width="24" height="86" rx="5" fill="#D64937" opacity=".85"/><path d="M14 108h172" stroke="#E9E4E1" stroke-width="2" stroke-linecap="round"/></svg><h3>{title}</h3><p>{!body}</p>
    , .{ .title = title, .body = body });
    if (action.len != 0) try render(w, "<div class=\"row\">{!action}</div>", .{ .action = action });
    try w.writeAll("</div>");
}

/// The change against the previous period, coloured by whether it is good.
pub fn delta(w: *Writer, current: f64, previous: f64, invert: bool) !void {
    const value = html.changeValue(current, previous);
    const good = if (invert) value < 0 else value > 0;
    const class = if (std.math.isNan(value)) "delta-up" else if (@abs(value) < 0.05) "delta-flat" else if (good) "delta-up" else "delta-down";
    try render(w, "<span class=\"delta {class}\">{change}</span>", .{ .class = class, .change = html.change(current, previous) });
}

/// Tabs that keep the view's period and filters; `items` are {value, label}.
pub fn tabs(w: *Writer, arena: std.mem.Allocator, view: data.View, path: []const u8, key: []const u8, items: []const [2][]const u8, active: []const u8) !void {
    try w.writeAll("<nav class=\"tabs\">");
    for (items) |item| try render(w, "<a href=\"{href}\"{!current}>{label}</a>", .{
        .href = try view.href(arena, path, &.{.{ key, item[0] }}),
        .current = if (std.mem.eql(u8, item[0], active)) " aria-current=\"page\"" else "",
        .label = item[1],
    });
    try w.writeAll("</nav>");
}

pub const Tone = struct { color: []const u8, wash: []const u8 };

/// The workspace's five accent colours, each with its pale background.
pub const tones = [_]Tone{
    .{ .color = "#D64937", .wash = "#FBEDEA" },
    .{ .color = "#0057AE", .wash = "#E6EEF7" },
    .{ .color = "#644A9B", .wash = "#EFEBF5" },
    .{ .color = "#1A7471", .wash = "#E5F2F1" },
    .{ .color = "#9A5B08", .wash = "#F8EEDF" },
};

/// A card's title row; `aside` is HTML (a meta note or a link).
pub fn cardHead(w: *Writer, title: []const u8, aside: []const u8) !void {
    try render(w, "<div class=\"card-head\"><h2>{title}</h2>{!aside}</div>", .{ .title = title, .aside = aside });
}

/// The change line under a metric: the delta and what it compares with.
pub fn change(arena: std.mem.Allocator, current: f64, previous: f64, invert: bool, against: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try delta(&out.writer, current, previous, invert);
    try out.writer.writeAll(against);
    return out.written();
}

pub const Metric = struct {
    href: []const u8 = "",
    current: bool = false,
    tone: Tone,
    icon: []const u8,
    label: []const u8,
    value: []const u8,
    spark: ?[]const f64 = null,
    /// HTML: usually `change`, or "&nbsp;" without a comparison.
    change: []const u8,
};

/// A headline number; with `href`, a link (the overview's tiles switch the chart).
pub fn metric(w: *Writer, arena: std.mem.Allocator, m: Metric) !void {
    try render(w, "<{!tag} class=\"metric\"{!href}{!current}><span class=\"metric-label\"><span class=\"badge\" style=\"background:{wash};color:{color}\">", .{
        .tag = if (m.href.len != 0) "a" else "div",
        .href = if (m.href.len != 0) try html.print(arena, " href=\"{href}\"", .{ .href = m.href }) else "",
        .current = if (m.current) " aria-current=\"true\"" else "",
        .wash = m.tone.wash,
        .color = m.tone.color,
    });
    try @import("layout.zig").icon(w, m.icon);
    try render(w, "</span>{label}</span><span class=\"metric-value\">{value}</span>", .{ .label = m.label, .value = m.value });
    if (m.spark) |values| try @import("chart.zig").spark(arena, w, values, m.tone.color);
    try render(w, "<span class=\"metric-delta\">{!change}</span></{!tag}>", .{ .change = m.change, .tag = if (m.href.len != 0) "a" else "div" });
}

pub const Rank = struct {
    /// A link when set.
    href: []const u8 = "",
    title: []const u8 = "",
    /// Bar width in percent, and its colour (the stylesheet's when empty).
    width: f64,
    bar: []const u8 = "",
    lead: bool = false,
    /// A coloured left edge.
    edge: []const u8 = "",
    /// HTML before and after the name: a number, an avatar, a pill.
    before: []const u8 = "",
    name: []const u8,
    after: []const u8 = "",
    value: []const u8,
    pct: []const u8 = "",
};

/// One row of a ranked list with its proportional bar.
pub fn rankRow(w: *Writer, arena: std.mem.Allocator, r: Rank) !void {
    const tag = if (r.href.len != 0) "a" else "div";
    try render(w, "<{!tag} class=\"rank-row\"{!href}><span class=\"bar{!lead}\" style=\"width:{width:.1}%{!bar}\"></span>{!edge}<span class=\"rank-name\">{!before}<span>{name}</span>{!after}</span><span class=\"rank-value\">{value}</span>{!pct}</{!tag}>", .{
        .tag = tag,
        .href = if (r.href.len != 0) try html.print(arena, " href=\"{href}\"{!title}", .{ .href = r.href, .title = if (r.title.len != 0) try html.print(arena, " title=\"{t}\"", .{ .t = r.title }) else "" }) else "",
        .lead = if (r.lead) " lead" else "",
        .width = r.width,
        .bar = if (r.bar.len != 0) try html.print(arena, ";background:{bar}", .{ .bar = r.bar }) else "",
        .edge = if (r.edge.len != 0) try html.print(arena, "<span class=\"rank-edge\" style=\"background:{edge}\"></span>", .{ .edge = r.edge }) else "",
        .before = r.before,
        .name = r.name,
        .after = r.after,
        .value = r.value,
        .pct = if (r.pct.len != 0) try html.print(arena, "<span class=\"rank-pct\">{pct}</span>", .{ .pct = r.pct }) else "<span></span>",
    });
}

/// A country with its share of the views.
pub fn countryRow(w: *Writer, arena: std.mem.Allocator, href: []const u8, code: []const u8, share: f64) !void {
    try render(w, "<{!tag} class=\"country-row\"{!href}><span class=\"cc\">{code}</span><span class=\"grow\">{name}</span><span class=\"meter\"><i style=\"width:{share:.0}%\"></i></span><strong>{share:.0}%</strong></{!tag}>", .{
        .tag = if (href.len != 0) "a" else "div",
        .href = if (href.len != 0) try html.print(arena, " href=\"{href}\"", .{ .href = href }) else "",
        .code = code,
        .name = @import("../geo.zig").countryName(code),
        .share = share,
    });
}

pub const Part = struct { value: i64, color: []const u8, label: []const u8 };

/// A stacked bar of shares and its legend (`legend_class` lays it out).
pub fn shareBar(w: *Writer, bar_class: []const u8, legend_class: []const u8, parts: []const Part) !void {
    var total: i64 = 0;
    for (parts) |part| total += part.value;
    try render(w, "<div class=\"share-bar {!class}\">", .{ .class = bar_class });
    for (parts) |part| if (part.value > 0) try render(w, "<span style=\"flex:{value};background:{color}\"></span>", .{ .value = part.value, .color = part.color });
    try render(w, "</div><div class=\"{!class}\">", .{ .class = legend_class });
    for (parts) |part| try render(w,
        \\<div class="row-between t-13"><span class="row nowrap"><span class="dot-mark" style="background:{color}"></span>{label}</span><strong>{share}</strong></div>
    , .{ .color = part.color, .label = part.label, .share = html.share(part.value, total) });
    try w.writeAll("</div>");
}

/// A small figure card: a label, a big value and an optional note.
pub fn stat(w: *Writer, label: []const u8, value: []const u8, note: []const u8) !void {
    try render(w, "<div class=\"card\"><div class=\"hint ink-2\">{label}</div><div class=\"metric-value{!muted}\">{value}</div>", .{ .label = label, .muted = if (std.mem.eql(u8, value, "—")) " muted" else "", .value = value });
    if (note.len != 0) try render(w, "<div class=\"hint\">{note}</div>", .{ .note = note });
    try w.writeAll("</div>");
}
