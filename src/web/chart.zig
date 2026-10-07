//! Server-drawn SVG charts. Geometry is computed here; app.js only adds hover.
const std = @import("std");
const html = @import("html.zig");
const layout = @import("layout.zig");

const Writer = std.Io.Writer;

pub const Mark = struct { index: usize, label: []const u8, href: []const u8 = "" };

pub const Trend = struct {
    current: []const f64,
    previous: ?[]const f64 = null,
    labels: []const []const u8,
    long_labels: []const []const u8,
    marks: []const Mark = &.{},
    unit: []const u8,
    duration: bool = false,
    /// Index drawn bold on the x axis.
    emphasis: ?usize = null,
    /// POST target for "Why?" on a point; empty disables it.
    why: []const u8 = "",
    /// The day of each bucket (daily charts); clicking a point opens that day.
    days: []const []const u8 = &.{},
    height: u16 = 224,
};

pub fn niceMax(value: f64) f64 {
    if (value <= 0) return 4;
    const magnitude = std.math.pow(f64, 10, @floor(std.math.log10(value)));
    const steps = [_]f64{ 1, 2, 2.5, 4, 5, 8, 10 };
    for (steps) |step| if (step * magnitude >= value) return step * magnitude;
    return 10 * magnitude;
}

pub const Axis = struct {
    value: f64,
    duration: bool,

    pub fn format(self: Axis, w: *Writer) Writer.Error!void {
        if (self.duration) {
            const hours = self.value / 3_600_000.0;
            if (hours >= 1) return w.print("{d:.0}h", .{hours});
            return w.print("{d:.0}m", .{self.value / 60_000.0});
        }
        if (self.value >= 1_000_000) return trimmed(w, self.value / 1_000_000.0, "M");
        if (self.value >= 1000) return trimmed(w, self.value / 1000.0, "k");
        return trimmed(w, self.value, "");
    }

    fn trimmed(w: *Writer, value: f64, suffix: []const u8) Writer.Error!void {
        if (@abs(value - @round(value)) < 0.05) return w.print("{d:.0}{s}", .{ value, suffix });
        return w.print("{d:.1}{s}", .{ value, suffix });
    }
};

/// Fritsch–Carlson monotone cubic through the points; never overshoots.
fn monotonePath(w: *Writer, xs: []const f64, ys: []const f64, move: bool) !void {
    const n = xs.len;
    if (n == 0) return;
    if (move) try w.print("M{d:.1},{d:.1}", .{ xs[0], ys[0] }) else try w.print("L{d:.1},{d:.1}", .{ xs[0], ys[0] });
    if (n == 1) return;
    var slopes: [400]f64 = undefined;
    var tangents: [400]f64 = undefined;
    const count = @min(n, slopes.len);
    for (0..count - 1) |i| slopes[i] = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]);
    tangents[0] = slopes[0];
    tangents[count - 1] = slopes[count - 2];
    for (1..count - 1) |i| {
        if (slopes[i - 1] * slopes[i] <= 0) {
            tangents[i] = 0;
        } else {
            tangents[i] = 2 * slopes[i - 1] * slopes[i] / (slopes[i - 1] + slopes[i]);
        }
    }
    for (0..count - 1) |i| {
        const dx = (xs[i + 1] - xs[i]) / 3;
        try w.print("C{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}", .{
            xs[i] + dx,     ys[i] + tangents[i] * dx,
            xs[i + 1] - dx, ys[i + 1] - tangents[i + 1] * dx,
            xs[i + 1],      ys[i + 1],
        });
    }
}

fn project(arena: std.mem.Allocator, values: []const f64, maximum: f64) !struct { []f64, []f64 } {
    const xs = try arena.alloc(f64, values.len);
    const ys = try arena.alloc(f64, values.len);
    const denominator: f64 = @floatFromInt(@max(values.len, 2) - 1);
    for (values, 0..) |value, index| {
        xs[index] = if (values.len == 1) 500 else @as(f64, @floatFromInt(index)) / denominator * 1000.0;
        ys[index] = 1000.0 - value / maximum * 1000.0;
    }
    return .{ xs, ys };
}

fn writeNumbers(w: *Writer, values: []const f64) !void {
    try w.writeByte('[');
    for (values, 0..) |value, index| {
        if (index != 0) try w.writeByte(',');
        try w.print("{d:.0}", .{value});
    }
    try w.writeByte(']');
}

pub fn trend(arena: std.mem.Allocator, w: *Writer, chart: Trend) !void {
    var largest: f64 = 0;
    for (chart.current) |value| largest = @max(largest, value);
    if (chart.previous) |previous| for (previous) |value| {
        largest = @max(largest, value);
    };
    const maximum = niceMax(largest * 1.08);
    // Data for hover: values, previous values, long labels, unit.
    var json: std.Io.Writer.Allocating = .init(arena);
    const jw = &json.writer;
    try jw.writeAll("{\"v\":");
    try writeNumbers(jw, chart.current);
    if (chart.previous) |previous| {
        try jw.writeAll(",\"p\":");
        try writeNumbers(jw, previous);
    }
    try jw.writeAll(",\"l\":");
    try std.json.Stringify.value(chart.long_labels, .{}, jw);
    try jw.writeAll(",\"u\":");
    try std.json.Stringify.value(chart.unit, .{}, jw);
    if (chart.days.len == chart.current.len and chart.days.len != 0) {
        try jw.writeAll(",\"k\":");
        try std.json.Stringify.value(chart.days, .{}, jw);
    }
    try jw.print(",\"d\":{d}}}", .{@intFromBool(chart.duration)});
    try w.print("<div class=\"chart\" style=\"height:{d}px\" data-chart=\"{f}\"", .{ chart.height, html.esc(json.written()) });
    if (chart.why.len != 0) try w.print(" data-why=\"{f}\"", .{html.esc(chart.why)});
    try w.writeAll("><div class=\"chart-y\" aria-hidden=\"true\">");
    var tick: usize = 0;
    while (tick <= 4) : (tick += 1) {
        const value = maximum * @as(f64, @floatFromInt(4 - tick)) / 4.0;
        try w.print("<span style=\"top:{d}%\">{f}</span>", .{ tick * 25, Axis{ .value = value, .duration = chart.duration } });
    }
    try w.writeAll(
        \\</div><div class="chart-plot"><svg viewBox="0 0 1000 1000" preserveAspectRatio="none" role="img" aria-label="Trend chart">
        \\<defs><linearGradient id="area-fill" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#D64937" stop-opacity=".16"/><stop offset="1" stop-color="#D64937" stop-opacity="0"/></linearGradient></defs><g class="chart-grid">
    );
    tick = 0;
    while (tick <= 4) : (tick += 1) try w.print("<line x1=\"0\" x2=\"1000\" y1=\"{d}\" y2=\"{d}\"{s}/>", .{ tick * 250, tick * 250, if (tick == 4) " class=\"base\"" else "" });
    try w.writeAll("</g>");
    const current = try project(arena, chart.current, maximum);
    if (chart.current.len != 0) {
        try w.writeAll("<path class=\"area-current\" d=\"");
        try monotonePath(w, current[0], current[1], true);
        try w.print("L{d:.1},1000L{d:.1},1000Z\"/>", .{ current[0][current[0].len - 1], current[0][0] });
    }
    if (chart.previous) |previous| {
        const projected = try project(arena, previous, maximum);
        try w.writeAll("<path class=\"line-previous\" d=\"");
        try monotonePath(w, projected[0], projected[1], true);
        try w.writeAll("\"/>");
    }
    if (chart.current.len != 0) {
        try w.writeAll("<path class=\"line-current\" d=\"");
        try monotonePath(w, current[0], current[1], true);
        try w.writeAll("\"/>");
    }
    try w.writeAll("</svg>");
    const denominator: f64 = @floatFromInt(@max(chart.current.len, 2) - 1);
    // Marks close to the previous one take turns on a raised row.
    var previous_left: f64 = -100;
    var raised = false;
    for (chart.marks) |mark| {
        const left = @as(f64, @floatFromInt(mark.index)) / denominator * 100.0;
        raised = left - previous_left < 20 and !raised;
        previous_left = left;
        // Labels near an edge grow inwards instead of overflowing the card.
        const shift: []const u8 = if (left > 85) "-100%" else if (left < 15) "0%" else "-50%";
        try w.print("<div class=\"chart-mark{s}\" style=\"left:{d:.2}%;--shift:{s}\"><span title=\"{f}\">", .{ if (raised) " raised" else "", left, shift, html.esc(mark.label) });
        try layout.icon(w, "pin");
        try w.print("<b>{f}</b></span></div>", .{html.esc(mark.label)});
    }
    try w.writeAll("<div class=\"chart-hover\"></div><div class=\"chart-dot\"></div><div class=\"chart-tip\" role=\"status\"></div>");
    if (chart.why.len != 0) {
        try w.writeAll("<button class=\"chart-why\" type=\"button\">");
        try layout.icon(w, "sparkles");
        try w.writeAll("Why?</button>");
    }
    try w.writeAll("</div><div class=\"chart-x\" aria-hidden=\"true\">");
    const n = chart.labels.len;
    const shown: usize = @min(n, 7);
    var index: usize = 0;
    while (index < shown) : (index += 1) {
        const at = if (shown <= 1) 0 else (index * (n - 1) + (shown - 1) / 2) / (shown - 1);
        try w.print("<span{s}>{f}</span>", .{ if (chart.emphasis != null and chart.emphasis.? == at) " aria-current=\"true\"" else "", html.esc(chart.labels[at]) });
    }
    try w.writeAll("</div></div>");
}

/// Small area sparkline for metric tiles.
pub fn spark(arena: std.mem.Allocator, w: *Writer, values: []const f64, color: []const u8) !void {
    var largest: f64 = 0;
    for (values) |value| largest = @max(largest, value);
    const maximum = if (largest <= 0) 1 else largest * 1.15;
    const projected = try project(arena, values, maximum);
    const id = std.hash.Wyhash.hash(0, color) % 100000;
    try w.print(
        \\<svg class="metric-spark spark" viewBox="0 0 1000 1000" preserveAspectRatio="none" aria-hidden="true"><defs><linearGradient id="s{d}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{s}" stop-opacity=".22"/><stop offset="1" stop-color="{s}" stop-opacity="0"/></linearGradient></defs>
    , .{ id, color, color });
    if (values.len != 0) {
        try w.writeAll("<path d=\"");
        try monotonePath(w, projected[0], projected[1], true);
        try w.print("L1000,1000L0,1000Z\" fill=\"url(#s{d})\"/><path d=\"", .{id});
        try monotonePath(w, projected[0], projected[1], true);
        try w.print("\" fill=\"none\" stroke=\"{s}\" stroke-width=\"2\"/>", .{color});
    }
    try w.writeAll("</svg>");
}

test "nice maximum" {
    try std.testing.expectEqual(@as(f64, 4000), niceMax(3400));
    try std.testing.expectEqual(@as(f64, 250), niceMax(210));
}
