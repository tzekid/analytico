const std = @import("std");
const components = @import("components.zig");

pub const maximum_trend_points: usize = 400;
pub const maximum_bars: usize = 100;
pub const maximum_funnel_steps: usize = 8;
pub const maximum_path_columns: usize = 5;
pub const maximum_path_nodes: usize = 10;
pub const maximum_path_edges: usize = 400;
pub const maximum_retention_periods: usize = 12;
pub const maximum_retention_rows: usize = 12;
const maximum_label_bytes: usize = 1024;
const maximum_href_bytes: usize = 16 * 1024;

pub const TrendPoint = struct {
    label: []const u8,
    comparison_interval_label: []const u8 = "",
    current: ?i128,
    current_incomplete: bool = false,
    current_formatted: []const u8 = "",
    current_href: []const u8 = "",
    comparison: ?i128 = null,
    comparison_formatted: []const u8 = "",
    comparison_href: []const u8 = "",
};

pub const TrendFigure = struct {
    id: []const u8,
    title: []const u8,
    summary: []const u8,
    current_label: []const u8,
    comparison_label: []const u8 = "Comparison",
    show_comparison: bool = false,
    scale: u8 = 0,
    points: []const TrendPoint,
};

pub const Bar = struct {
    label: []const u8,
    value: u64,
    value_formatted: []const u8 = "",
};

pub const BarFigure = struct {
    id: []const u8,
    title: []const u8,
    summary: []const u8,
    metric_label: []const u8,
    bars: []const Bar,
};

pub const FunnelStep = struct {
    name: []const u8,
    sessions: u64,
    median_to_next: ?[]const u8 = null,
};

pub const FunnelFigure = struct {
    id: []const u8,
    title: []const u8,
    summary: []const u8,
    entrants: u64,
    steps: []const FunnelStep,
};

pub const PathNode = struct {
    label: []const u8,
    count: u64,
};

pub const PathColumn = struct {
    label: []const u8,
    nodes: []const PathNode,
};

pub const PathEdge = struct {
    from_column: u8,
    from_node: u8,
    to_node: u8,
    count: u64,
};

pub const PathFigure = struct {
    id: []const u8,
    title: []const u8,
    summary: []const u8,
    columns: []const PathColumn,
    edges: []const PathEdge,
};

pub const RetentionCell = struct {
    returned: ?u64,
};

pub const RetentionRow = struct {
    cohort: []const u8,
    cohort_size: u64,
    cells: []const RetentionCell,
};

pub const RetentionFigure = struct {
    id: []const u8,
    title: []const u8,
    summary: []const u8,
    period_labels: []const []const u8,
    rows: []const RetentionRow,
};

pub fn renderTrend(output: *std.Io.Writer, value: TrendFigure) !void {
    try validateFigure(value.id, value.title, value.summary);
    if (value.points.len > maximum_trend_points) return error.TooManyTrendPoints;
    try validateRequiredLabel(value.current_label);
    try validateRequiredLabel(value.comparison_label);
    if (value.scale > 6) return error.InvalidTrendScale;
    var minimum: i128 = 0;
    var maximum: i128 = 0;
    var current_count: usize = 0;
    var comparison_count: usize = 0;
    var current_has_gap = false;
    var incomplete_index: ?usize = null;
    for (value.points, 0..) |point, index| {
        if (point.current != null) try validateRequiredLabel(point.label) else try validateLabel(point.label);
        try validateLabel(point.comparison_interval_label);
        try validateLabel(point.current_formatted);
        try validateLabel(point.comparison_formatted);
        try validateHref(point.current_href);
        try validateHref(point.comparison_href);
        if (point.current) |number| {
            minimum = @min(minimum, number);
            maximum = @max(maximum, number);
            current_count += 1;
        } else {
            current_has_gap = true;
        }
        if (point.current_incomplete) {
            if (point.current == null or incomplete_index != null) {
                return error.InvalidIncompleteTrendPoint;
            }
            incomplete_index = index;
        }
        if (value.show_comparison) {
            if (point.comparison) |number| {
                minimum = @min(minimum, number);
                maximum = @max(maximum, number);
                comparison_count += 1;
            }
        }
    }
    if (incomplete_index) |index| {
        for (value.points[index + 1 ..]) |point| {
            if (point.current != null) return error.InvalidIncompleteTrendPoint;
        }
    }

    try figureStart(output, "trend-figure", value.id, value.title, value.summary);
    if (value.points.len == 0) {
        try output.writeAll("<p class=\"chart-empty\">No trend data in this range.</p>");
    } else {
        const left: u32 = 56;
        const top: u32 = 24;
        const width: u32 = 816;
        const height: u32 = 220;
        const bottom = top + height;
        try svgStart(output, "trend-chart", value.id, 900, 290);
        for ([_]u32{ top, top + height / 2, bottom }) |y| {
            try output.print(
                "<line class=\"chart-grid\" x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\"/>",
                .{ left, y, left + width, y },
            );
        }
        try output.print("<text class=\"chart-axis\" x=\"8\" y=\"{d}\">", .{top + 4});
        try scaledNumber(output, maximum, value.scale);
        try output.writeAll("</text>");
        try output.print("<text class=\"chart-axis\" x=\"8\" y=\"{d}\">", .{bottom + 4});
        try scaledNumber(output, minimum, value.scale);
        try output.writeAll("</text>");
        const zero_y = try pointY(0, minimum, maximum, top, height);

        if (!current_has_gap and current_count > 1) {
            try output.print("<path class=\"chart-area\" d=\"M {d} {d}", .{ left, zero_y });
            for (value.points, 0..) |point, index| {
                try output.print(" L {d} {d}", .{
                    pointX(index, value.points.len, left, width),
                    try pointY(point.current.?, minimum, maximum, top, height),
                });
            }
            try output.print(" L {d} {d} Z\"/>", .{ left + width, zero_y });
        }

        if (current_count > 1) {
            try renderTrendPath(output, value.points, false, minimum, maximum, left, top, width, height);
        }
        if (value.show_comparison and comparison_count > 1) {
            try renderTrendPath(output, value.points, true, minimum, maximum, left, top, width, height);
        }
        for (value.points, 0..) |point, index| {
            if (point.current) |number| try renderTrendMarker(
                output,
                "chart-point",
                point.current_href,
                point.label,
                point.current_incomplete,
                pointX(index, value.points.len, left, width),
                try pointY(number, minimum, maximum, top, height),
            );
            if (value.show_comparison) if (point.comparison) |number| try renderTrendMarker(
                output,
                "chart-compare-point",
                point.comparison_href,
                if (point.comparison_interval_label.len == 0)
                    point.label
                else
                    point.comparison_interval_label,
                false,
                pointX(index, value.points.len, left, width),
                try pointY(number, minimum, maximum, top, height),
            );
        }
        try output.writeAll("<text class=\"chart-axis\" x=\"");
        try output.print("{d}\" y=\"276\">", .{left});
        try components.text(output, firstTrendLabel(value.points));
        try output.writeAll("</text>");
        if (value.points.len > 1) {
            try output.print("<text class=\"chart-axis chart-axis-end\" x=\"{d}\" y=\"276\">", .{left + width});
            try components.text(output, lastTrendLabel(value.points));
            try output.writeAll("</text>");
        }
        try output.writeAll("</svg>");
    }
    try exactStart(output, value.id, value.title);
    try output.writeAll("<thead><tr><th scope=\"col\">");
    try output.writeAll(if (value.show_comparison) "Current interval" else "Interval");
    try output.writeAll("</th><th scope=\"col\">");
    try components.text(output, value.current_label);
    try output.writeAll("</th>");
    if (value.show_comparison) {
        try output.writeAll("<th scope=\"col\">Comparison interval</th><th scope=\"col\">");
        try components.text(output, value.comparison_label);
        try output.writeAll("</th>");
    }
    try output.writeAll("</tr></thead><tbody>");
    for (value.points) |point| {
        try output.writeAll("<tr><th scope=\"row\" data-label=\"");
        try output.writeAll(if (value.show_comparison) "Current interval" else "Interval");
        try output.writeAll("\">");
        try intervalLink(output, point.label, point.current_href, point.current_incomplete);
        try output.writeAll("</th><td data-label=\"");
        try components.attribute(output, value.current_label);
        try output.writeAll("\">");
        try optionalTrendValue(output, point.current, point.current_formatted, value.scale);
        try output.writeAll("</td>");
        if (value.show_comparison) {
            try output.writeAll("<td data-label=\"Comparison interval\">");
            try intervalLink(
                output,
                point.comparison_interval_label,
                point.comparison_href,
                false,
            );
            try output.writeAll("</td><td data-label=\"");
            try components.attribute(output, value.comparison_label);
            try output.writeAll("\">");
            try optionalTrendValue(output, point.comparison, point.comparison_formatted, value.scale);
            try output.writeAll("</td>");
        }
        try output.writeAll("</tr>");
    }
    if (value.points.len == 0) try emptyTableRow(output, if (value.show_comparison) 4 else 2);
    try exactEnd(output);
    try output.writeAll("</figure>");
}

pub fn renderBars(output: *std.Io.Writer, value: BarFigure) !void {
    try validateFigure(value.id, value.title, value.summary);
    try validateRequiredLabel(value.metric_label);
    if (value.bars.len > maximum_bars) return error.TooManyBars;
    var maximum: u64 = 0;
    for (value.bars) |bar| {
        try validateRequiredLabel(bar.label);
        try validateLabel(bar.value_formatted);
        maximum = @max(maximum, bar.value);
    }
    const svg_height: u32 = @max(64, @as(u32, @intCast(value.bars.len)) * 36 + 24);
    try figureStart(output, "bar-figure", value.id, value.title, value.summary);
    if (value.bars.len == 0) {
        try output.writeAll("<p class=\"chart-empty\">No breakdown data in this range.</p>");
    } else {
        try svgStart(output, "bar-chart", value.id, 900, svg_height);
        for (value.bars, 0..) |bar, index| {
            const y: u32 = 14 + @as(u32, @intCast(index)) * 36;
            const width = scaled(bar.value, maximum, 590);
            try output.print("<text class=\"chart-label\" x=\"8\" y=\"{d}\">", .{y + 16});
            try components.text(output, bar.label);
            try output.print("</text><rect class=\"chart-bar\" x=\"210\" y=\"{d}\" width=\"{d}\" height=\"18\" rx=\"4\"/><text class=\"chart-value\" x=\"{d}\" y=\"{d}\">", .{
                y, width, 220 + width, y + 15,
            });
            try formattedOrRaw(output, bar.value, bar.value_formatted);
            try output.writeAll("</text>");
        }
        try output.writeAll("</svg>");
    }
    try exactStart(output, value.id, value.title);
    try output.writeAll("<thead><tr><th scope=\"col\">Label</th><th scope=\"col\">");
    try components.text(output, value.metric_label);
    try output.writeAll("</th></tr></thead><tbody>");
    for (value.bars) |bar| {
        try output.writeAll("<tr><th scope=\"row\" data-label=\"Label\">");
        try components.text(output, bar.label);
        try output.writeAll("</th><td data-label=\"");
        try components.attribute(output, value.metric_label);
        try output.writeAll("\">");
        try exactValue(output, bar.value, bar.value_formatted);
        try output.writeAll("</td></tr>");
    }
    if (value.bars.len == 0) try emptyTableRow(output, 2);
    try exactEnd(output);
    try output.writeAll("</figure>");
}

pub fn renderFunnel(output: *std.Io.Writer, value: FunnelFigure) !void {
    try validateFigure(value.id, value.title, value.summary);
    if (value.steps.len > maximum_funnel_steps) return error.TooManyFunnelSteps;
    var prior = value.entrants;
    for (value.steps) |step| {
        try validateRequiredLabel(step.name);
        if (step.median_to_next) |label| try validateLabel(label);
        if (step.sessions > prior) return error.InvalidFunnelCounts;
        prior = step.sessions;
    }

    const svg_height: u32 = @max(70, @as(u32, @intCast(value.steps.len)) * 44 + 24);
    try figureStart(output, "funnel-figure", value.id, value.title, value.summary);
    if (value.steps.len == 0) {
        try output.writeAll("<p class=\"chart-empty\">No funnel steps are available.</p>");
    } else {
        try svgStart(output, "funnel-chart", value.id, 900, svg_height);
        for (value.steps, 0..) |step, index| {
            const y: u32 = 14 + @as(u32, @intCast(index)) * 44;
            const width = scaled(step.sessions, value.entrants, 620);
            try output.print("<rect class=\"funnel-track\" x=\"250\" y=\"{d}\" width=\"620\" height=\"26\" rx=\"5\"/><rect class=\"funnel-bar\" x=\"250\" y=\"{d}\" width=\"{d}\" height=\"26\" rx=\"5\"/><text class=\"chart-label\" x=\"8\" y=\"{d}\">{d} · ", .{
                y, y, width, y + 18, index + 1,
            });
            try components.text(output, step.name);
            try output.print("</text><text class=\"chart-value\" x=\"{d}\" y=\"{d}\">{d} · ", .{ 260 + width, y + 18, step.sessions });
            try percent(output, step.sessions, value.entrants);
            try output.writeAll("</text>");
        }
        try output.writeAll("</svg>");
    }
    try exactStart(output, value.id, value.title);
    try output.writeAll("<thead><tr><th scope=\"col\">Step</th><th scope=\"col\">Sessions</th><th scope=\"col\">Step rate</th><th scope=\"col\">Overall rate</th><th scope=\"col\">Drop-off</th><th scope=\"col\">Median to next</th></tr></thead><tbody>");
    prior = value.entrants;
    for (value.steps, 0..) |step, index| {
        try output.print("<tr><th scope=\"row\" data-label=\"Step\">{d} · ", .{index + 1});
        try components.text(output, step.name);
        try output.print("</th><td data-label=\"Sessions\">{d}</td><td data-label=\"Step rate\">", .{step.sessions});
        try percent(output, step.sessions, prior);
        try output.writeAll("</td><td data-label=\"Overall rate\">");
        try percent(output, step.sessions, value.entrants);
        try output.print("</td><td data-label=\"Drop-off\">{d}</td><td data-label=\"Median to next\">", .{prior - step.sessions});
        if (step.median_to_next) |label| {
            try components.text(output, label);
        } else {
            try output.writeAll("Unavailable");
        }
        try output.writeAll("</td></tr>");
        prior = step.sessions;
    }
    if (value.steps.len == 0) try emptyTableRow(output, 6);
    try exactEnd(output);
    try output.writeAll("</figure>");
}

pub fn renderPath(output: *std.Io.Writer, value: PathFigure) !void {
    try validateFigure(value.id, value.title, value.summary);
    if (value.columns.len != 0 and (value.columns.len < 3 or value.columns.len > maximum_path_columns)) {
        return error.InvalidPathColumnCount;
    }
    if (value.edges.len > maximum_path_edges) return error.TooManyPathEdges;
    if (value.columns.len == 0 and value.edges.len != 0) return error.InvalidPathEdge;
    var maximum_edge: u64 = 0;
    for (value.columns, 0..) |column, column_index| {
        try validateRequiredLabel(column.label);
        for (value.columns[0..column_index]) |prior_column| {
            if (std.mem.eql(u8, prior_column.label, column.label)) {
                return error.DuplicatePathColumnLabel;
            }
        }
        if (column.nodes.len > maximum_path_nodes) return error.TooManyPathNodes;
        for (column.nodes, 0..) |node, node_index| {
            try validateRequiredLabel(node.label);
            for (column.nodes[0..node_index]) |prior_node| {
                if (std.mem.eql(u8, prior_node.label, node.label)) {
                    return error.DuplicatePathNodeLabel;
                }
            }
            if (node_index != 0 and !pathNodePrecedes(column.nodes[node_index - 1], node)) {
                return error.InvalidPathNodeOrder;
            }
        }
    }
    var outgoing = std.mem.zeroes([maximum_path_columns][maximum_path_nodes]u128);
    var incoming = std.mem.zeroes([maximum_path_columns][maximum_path_nodes]u128);
    for (value.edges, 0..) |edge, edge_index| {
        if (edge.from_column >= value.columns.len - 1) return error.InvalidPathEdge;
        const from_column = value.columns[edge.from_column];
        const to_column = value.columns[edge.from_column + 1];
        if (edge.from_node >= from_column.nodes.len or edge.to_node >= to_column.nodes.len) {
            return error.InvalidPathEdge;
        }
        if (edge.count > from_column.nodes[edge.from_node].count or
            edge.count > to_column.nodes[edge.to_node].count)
        {
            return error.InvalidPathEdge;
        }
        for (value.edges[0..edge_index]) |prior_edge| {
            if (prior_edge.from_column == edge.from_column and
                prior_edge.from_node == edge.from_node and
                prior_edge.to_node == edge.to_node)
            {
                return error.DuplicatePathEdge;
            }
        }
        if (edge_index != 0 and !pathEdgePrecedes(value.columns, value.edges[edge_index - 1], edge)) {
            return error.InvalidPathEdgeOrder;
        }
        outgoing[edge.from_column][edge.from_node] += edge.count;
        incoming[edge.from_column + 1][edge.to_node] += edge.count;
        maximum_edge = @max(maximum_edge, edge.count);
    }
    for (value.columns, 0..) |column, column_index| {
        for (column.nodes, 0..) |node, node_index| {
            if (column_index + 1 < value.columns.len and
                outgoing[column_index][node_index] != node.count)
            {
                return error.InvalidPathTotals;
            }
            if (column_index != 0 and incoming[column_index][node_index] != node.count) {
                return error.InvalidPathTotals;
            }
        }
    }

    try figureStart(output, "path-figure", value.id, value.title, value.summary);
    if (value.columns.len == 0) {
        try output.writeAll("<p class=\"chart-empty\">No path transitions in this range.</p>");
    } else {
        try svgStart(output, "path-chart", value.id, 900, 560);
        for (value.edges) |edge| {
            const from = nodeBox(value.columns, edge.from_column, edge.from_node);
            const to = nodeBox(value.columns, edge.from_column + 1, edge.to_node);
            const middle = (from.x + from.width + to.x) / 2;
            const stroke = 1 + scaled(edge.count, maximum_edge, 11);
            try output.print("<path class=\"path-edge\" d=\"M {d} {d} C {d} {d}, {d} {d}, {d} {d}\" stroke-width=\"{d}\"/>", .{
                from.x + from.width,
                from.y + from.height / 2,
                middle,
                from.y + from.height / 2,
                middle,
                to.y + to.height / 2,
                to.x,
                to.y + to.height / 2,
                stroke,
            });
        }
        for (value.columns, 0..) |column, column_index| {
            const x = columnX(column_index, value.columns.len);
            try output.print("<text class=\"path-column-label\" x=\"{d}\" y=\"24\">", .{x});
            try components.text(output, column.label);
            try output.writeAll("</text>");
            for (column.nodes, 0..) |node, node_index| {
                const box = nodeBox(value.columns, column_index, node_index);
                try output.print("<rect class=\"path-node\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"5\"/><text class=\"path-node-label\" x=\"{d}\" y=\"{d}\">", .{
                    box.x, box.y, box.width, box.height, box.x + 6, box.y + 15,
                });
                try components.text(output, node.label);
                try output.print("</text><text class=\"path-node-count\" x=\"{d}\" y=\"{d}\">{d}</text>", .{
                    box.x + 6, box.y + box.height - 5, node.count,
                });
            }
        }
        try output.writeAll("</svg>");
    }
    try output.writeAll("<div class=\"path-transitions\">");
    try exactStart(output, value.id, value.title);
    try output.writeAll("<thead><tr><th scope=\"col\">From step and node</th><th scope=\"col\">To step and node</th><th scope=\"col\">Transitions</th></tr></thead><tbody>");
    for (value.edges) |edge| {
        const from_column = value.columns[edge.from_column];
        const to_column = value.columns[edge.from_column + 1];
        const from = from_column.nodes[edge.from_node];
        const to = to_column.nodes[edge.to_node];
        try output.writeAll("<tr><th scope=\"row\" data-label=\"From\">");
        try components.text(output, from_column.label);
        try output.writeAll(" — ");
        try components.text(output, from.label);
        try output.writeAll("</th><td data-label=\"To\">");
        try components.text(output, to_column.label);
        try output.writeAll(" — ");
        try components.text(output, to.label);
        try output.print("</td><td data-label=\"Transitions\">{d}</td></tr>", .{edge.count});
    }
    if (value.edges.len == 0) try emptyTableRow(output, 3);
    try exactEnd(output);
    try output.writeAll("</div></figure>");
}

pub fn renderRetention(output: *std.Io.Writer, value: RetentionFigure) !void {
    try validateFigure(value.id, value.title, value.summary);
    if (value.period_labels.len > maximum_retention_periods) return error.TooManyRetentionPeriods;
    if (value.rows.len > maximum_retention_rows) return error.TooManyRetentionRows;
    for (value.period_labels) |label| try validateRequiredLabel(label);
    for (value.rows) |row| {
        try validateRequiredLabel(row.cohort);
        if (row.cells.len != value.period_labels.len) return error.InvalidRetentionRow;
        for (row.cells) |cell| if (cell.returned) |returned| {
            if (returned > row.cohort_size) return error.InvalidRetentionCell;
        };
    }

    try figureStart(output, "retention-figure", value.id, value.title, value.summary);
    try output.writeAll("<div class=\"retention-scroll\"><table class=\"retention-table\"><caption>");
    try components.text(output, value.title);
    try output.writeAll(" — exact cohort sizes, returned people, and rates</caption><thead><tr><th scope=\"col\">Cohort</th><th scope=\"col\">Size</th>");
    for (value.period_labels) |label| {
        try output.writeAll("<th scope=\"col\">");
        try components.text(output, label);
        try output.writeAll("</th>");
    }
    try output.writeAll("</tr></thead><tbody>");
    for (value.rows) |row| {
        try output.writeAll("<tr><th scope=\"row\">");
        try components.text(output, row.cohort);
        try output.print("</th><td data-label=\"Cohort size\">{d}</td>", .{row.cohort_size});
        for (row.cells, value.period_labels) |cell, period| {
            try output.writeAll("<td data-label=\"");
            try components.attribute(output, period);
            if (cell.returned) |returned| {
                const rate = ratioBasisPoints(returned, row.cohort_size);
                try output.print("\" class=\"retention-cell retention-{d}\">{d} (", .{ intensity(rate), returned });
                try basisPoints(output, rate);
                try output.writeAll(")</td>");
            } else {
                try output.writeAll("\" class=\"retention-cell retention-incomplete\">Incomplete</td>");
            }
        }
        try output.writeAll("</tr>");
    }
    if (value.rows.len == 0) {
        try emptyTableRow(output, value.period_labels.len + 2);
    }
    try output.writeAll("</tbody></table></div></figure>");
}

fn renderTrendPath(
    output: *std.Io.Writer,
    points: []const TrendPoint,
    comparison: bool,
    minimum: i128,
    maximum: i128,
    left: u32,
    top: u32,
    width: u32,
    height: u32,
) !void {
    try output.writeAll(if (comparison)
        "<path class=\"chart-compare\" d=\""
    else
        "<path class=\"chart-line\" d=\"");
    var connected = false;
    for (points, 0..) |point, index| {
        const optional = if (comparison) point.comparison else point.current;
        if (optional) |number| {
            try output.print("{s} {d} {d}", .{
                if (connected) " L" else "M",
                pointX(index, points.len, left, width),
                try pointY(number, minimum, maximum, top, height),
            });
            connected = true;
        } else {
            connected = false;
        }
    }
    try output.writeAll("\"/>");
}

fn renderTrendMarker(
    output: *std.Io.Writer,
    class: []const u8,
    href: []const u8,
    interval: []const u8,
    incomplete: bool,
    x: u32,
    y: u32,
) !void {
    if (href.len != 0) {
        try output.writeAll("<a href=\"");
        try components.attribute(output, href);
        try output.writeAll("\" tabindex=\"-1\" aria-label=\"Open interval ");
        try components.attribute(output, interval);
        if (incomplete) try output.writeAll(" (incomplete)");
        try output.writeAll(" in Analyze\">");
    }
    if (incomplete) {
        try output.print("<rect class=\"{s} chart-point-incomplete\"", .{class});
        if (href.len == 0) try output.writeAll(" aria-hidden=\"true\"");
        try output.print(
            " x=\"{d}\" y=\"{d}\" width=\"10\" height=\"10\" rx=\"1\"/>",
            .{ x -| 5, y -| 5 },
        );
    } else {
        try output.print("<circle class=\"{s}\"", .{class});
        if (href.len == 0) try output.writeAll(" aria-hidden=\"true\"");
        try output.print(" cx=\"{d}\" cy=\"{d}\" r=\"4\"/>", .{ x, y });
    }
    if (href.len != 0) try output.writeAll("</a>");
}

fn firstTrendLabel(points: []const TrendPoint) []const u8 {
    for (points) |point| {
        if (point.label.len != 0) return point.label;
        if (point.comparison_interval_label.len != 0) {
            return point.comparison_interval_label;
        }
    }
    return "";
}

fn lastTrendLabel(points: []const TrendPoint) []const u8 {
    var index = points.len;
    while (index != 0) {
        index -= 1;
        const point = points[index];
        if (point.label.len != 0) return point.label;
        if (point.comparison_interval_label.len != 0) {
            return point.comparison_interval_label;
        }
    }
    return "";
}

fn validateFigure(id: []const u8, title: []const u8, summary: []const u8) !void {
    try components.validateDocumentId(id);
    try validateRequiredLabel(title);
    try validateRequiredLabel(summary);
}

fn validateLabel(label: []const u8) !void {
    if (label.len > maximum_label_bytes) return error.ChartLabelTooLong;
    if (!std.unicode.utf8ValidateSlice(label)) return error.InvalidUtf8;
}

fn validateRequiredLabel(label: []const u8) !void {
    try validateLabel(label);
    if (label.len == 0) return error.MissingChartLabel;
}

fn validateHref(href: []const u8) !void {
    if (href.len > maximum_href_bytes or !std.unicode.utf8ValidateSlice(href)) {
        return error.InvalidChartHref;
    }
    if (href.len != 0 and href[0] != '/') return error.InvalidChartHref;
    for (href) |byte| if (byte < 0x20 or byte == 0x7f) {
        return error.InvalidChartHref;
    };
}

fn figureStart(
    output: *std.Io.Writer,
    class: []const u8,
    id: []const u8,
    title: []const u8,
    summary: []const u8,
) !void {
    try output.writeAll("<figure class=\"chart-figure ");
    try output.writeAll(class);
    try output.writeAll("\" aria-labelledby=\"");
    try output.writeAll(id);
    try output.writeAll("-title\" aria-describedby=\"");
    try output.writeAll(id);
    try output.writeAll("-summary\"><figcaption id=\"");
    try output.writeAll(id);
    try output.writeAll("-title\">");
    try components.text(output, title);
    try output.writeAll("</figcaption><p class=\"chart-summary\" id=\"");
    try output.writeAll(id);
    try output.writeAll("-summary\">");
    try components.text(output, summary);
    try output.writeAll("</p>");
}

fn svgStart(
    output: *std.Io.Writer,
    class: []const u8,
    id: []const u8,
    width: u32,
    height: u32,
) !void {
    try output.writeAll("<svg class=\"");
    try output.writeAll(class);
    try output.print("\" viewBox=\"0 0 {d} {d}\" role=\"img\" aria-labelledby=\"", .{ width, height });
    try output.writeAll(id);
    try output.writeAll("-title\" aria-describedby=\"");
    try output.writeAll(id);
    try output.writeAll("-summary\" focusable=\"false\">");
}

fn exactStart(output: *std.Io.Writer, id: []const u8, title: []const u8) !void {
    try output.writeAll("<details class=\"chart-data\"><summary>View exact data</summary><div class=\"table-scroll mobile-records\"><table><caption id=\"");
    try output.writeAll(id);
    try output.writeAll("-data\">");
    try components.text(output, title);
    try output.writeAll(" — exact values</caption>");
}

fn exactEnd(output: *std.Io.Writer) !void {
    try output.writeAll("</tbody></table></div></details>");
}

fn emptyTableRow(output: *std.Io.Writer, columns: usize) !void {
    try output.print("<tr><td colspan=\"{d}\">No data in this range.</td></tr>", .{columns});
}

fn formattedOrRaw(output: *std.Io.Writer, value: u64, formatted: []const u8) !void {
    if (formatted.len == 0) {
        try output.print("{d}", .{value});
    } else {
        try components.text(output, formatted);
    }
}

fn exactValue(output: *std.Io.Writer, value: u64, formatted: []const u8) !void {
    try output.print("<span class=\"chart-raw-value\">{d}</span>", .{value});
    if (formatted.len != 0) {
        try output.writeAll(" <span class=\"chart-formatted-value\">(");
        try components.text(output, formatted);
        try output.writeAll(")</span>");
    }
}

fn optionalExactValue(output: *std.Io.Writer, value: ?u64, formatted: []const u8) !void {
    if (value) |number| {
        try exactValue(output, number, formatted);
    } else {
        try output.writeAll("Unavailable");
    }
}

fn optionalTrendValue(
    output: *std.Io.Writer,
    value: ?i128,
    formatted: []const u8,
    scale: u8,
) !void {
    if (value) |number| {
        try output.writeAll("<span class=\"chart-raw-value\">");
        try scaledNumber(output, number, scale);
        try output.writeAll("</span>");
        if (formatted.len != 0) {
            try output.writeAll(" <span class=\"chart-formatted-value\">(");
            try components.text(output, formatted);
            try output.writeAll(")</span>");
        }
    } else {
        try output.writeAll("Unavailable");
    }
}

fn intervalLink(
    output: *std.Io.Writer,
    label: []const u8,
    href: []const u8,
    incomplete: bool,
) !void {
    if (label.len == 0) return output.writeAll("Unavailable");
    if (href.len != 0) {
        try output.writeAll("<a href=\"");
        try components.attribute(output, href);
        try output.writeAll("\">");
    }
    try components.text(output, label);
    if (href.len != 0) try output.writeAll("</a>");
    if (incomplete) {
        try output.writeAll(" <span class=\"trend-incomplete-marker\">Incomplete</span>");
    }
}

fn scaledNumber(output: *std.Io.Writer, value: i128, scale: u8) !void {
    if (scale == 0) return output.print("{d}", .{value});
    var factor: i128 = 1;
    for (0..scale) |_| factor *= 10;
    const negative = value < 0;
    const magnitude: u128 = if (negative)
        @intCast(-(value + 1) + 1)
    else
        @intCast(value);
    if (negative) try output.writeByte('-');
    const divisor: u128 = @intCast(factor);
    try output.print("{d}.", .{magnitude / divisor});
    const fraction = magnitude % divisor;
    switch (scale) {
        1 => try output.print("{d:0>1}", .{fraction}),
        2 => try output.print("{d:0>2}", .{fraction}),
        3 => try output.print("{d:0>3}", .{fraction}),
        4 => try output.print("{d:0>4}", .{fraction}),
        5 => try output.print("{d:0>5}", .{fraction}),
        6 => try output.print("{d:0>6}", .{fraction}),
        else => unreachable,
    }
}

fn pointX(index: usize, count: usize, left: u32, width: u32) u32 {
    if (count <= 1) return left + width / 2;
    return left + @as(u32, @intCast(
        (@as(u64, @intCast(index)) * width) / @as(u64, @intCast(count - 1)),
    ));
}

fn pointY(value: i128, minimum: i128, maximum: i128, top: u32, height: u32) !u32 {
    if (minimum == maximum) return top + height;
    const range = std.math.sub(i128, maximum, minimum) catch
        return error.InvalidTrendValue;
    const distance = std.math.sub(i128, maximum, value) catch
        return error.InvalidTrendValue;
    if (range <= 0 or distance < 0 or distance > range) {
        return error.InvalidTrendValue;
    }
    const scaled_distance = std.math.mul(i128, distance, height) catch
        return error.InvalidTrendValue;
    return top + @as(u32, @intCast(@divTrunc(scaled_distance, range)));
}

fn scaled(value: u64, maximum: u64, extent: u32) u32 {
    if (maximum == 0) return 0;
    return @intCast((@as(u128, value) * extent) / maximum);
}

fn percent(output: *std.Io.Writer, numerator: u64, denominator: u64) !void {
    try basisPoints(output, ratioBasisPoints(numerator, denominator));
}

fn ratioBasisPoints(numerator: u64, denominator: u64) u16 {
    if (denominator == 0) return 0;
    return @intCast(@min(@as(u128, 10_000), (@as(u128, numerator) * 10_000) / denominator));
}

fn basisPoints(output: *std.Io.Writer, value: u16) !void {
    try output.print("{d}.{d:0>2}%", .{ value / 100, value % 100 });
}

const NodeBox = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

fn pathNodePrecedes(first: PathNode, second: PathNode) bool {
    if (first.count != second.count) return first.count > second.count;
    return std.mem.order(u8, first.label, second.label) == .lt;
}

fn pathEdgePrecedes(columns: []const PathColumn, first: PathEdge, second: PathEdge) bool {
    if (first.from_column != second.from_column) return first.from_column < second.from_column;
    if (first.count != second.count) return first.count > second.count;
    const first_from = columns[first.from_column].nodes[first.from_node].label;
    const second_from = columns[second.from_column].nodes[second.from_node].label;
    const from_order = std.mem.order(u8, first_from, second_from);
    if (from_order != .eq) return from_order == .lt;
    const first_to = columns[first.from_column + 1].nodes[first.to_node].label;
    const second_to = columns[second.from_column + 1].nodes[second.to_node].label;
    return std.mem.order(u8, first_to, second_to) == .lt;
}

fn columnX(index: usize, count: usize) u32 {
    if (count <= 1) return 20;
    return 20 + @as(u32, @intCast(
        (@as(u64, @intCast(index)) * 730) / @as(u64, @intCast(count - 1)),
    ));
}

fn nodeBox(columns: []const PathColumn, column_index: usize, node_index: usize) NodeBox {
    const column = columns[column_index];
    var maximum: u64 = 0;
    for (column.nodes) |node| maximum = @max(maximum, node.count);
    const height = 22 + scaled(column.nodes[node_index].count, maximum, 18);
    return .{
        .x = columnX(column_index, columns.len),
        .y = 42 + @as(u32, @intCast(node_index)) * 50,
        .width = 150,
        .height = height,
    };
}

fn intensity(rate: u16) u8 {
    if (rate == 0) return 0;
    if (rate <= 2_500) return 1;
    if (rate <= 5_000) return 2;
    if (rate <= 7_500) return 3;
    return 4;
}

test "trend handles empty single constant gaps escaping and stable IDs" {
    const points = [_]TrendPoint{
        .{ .label = "Day <1>", .current = 7, .current_formatted = "seven visitors", .comparison = 4 },
        .{ .label = "Day 2", .current = null, .comparison = 4 },
        .{ .label = "Day 3", .current = 7, .current_incomplete = true, .comparison = 4 },
    };
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    try renderTrend(&output.writer, .{
        .id = "trend-fixture",
        .title = "Visitors <trend>",
        .summary = "Current and comparison.",
        .current_label = "Visitors",
        .show_comparison = true,
        .points = &points,
    });
    const rendered = try output.toOwnedSlice();
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "aria-labelledby=\"trend-fixture-title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Visitors &lt;trend&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Day &lt;1&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "scope=\"row\" data-label=\"Current interval\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "class=\"chart-raw-value\">7</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "(seven visitors)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "class=\"chart-line\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "class=\"chart-compare\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "chart-point chart-point-incomplete") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "trend-incomplete-marker\">Incomplete") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "onclick") == null);
    try std.testing.expectError(error.InvalidDocumentId, renderTrend(&output.writer, .{
        .id = "bad)id",
        .title = "Bad",
        .summary = "Bad",
        .current_label = "Count",
        .points = &.{},
    }));
    try std.testing.expectError(error.InvalidIncompleteTrendPoint, renderTrend(&output.writer, .{
        .id = "bad-incomplete",
        .title = "Bad incomplete",
        .summary = "Incomplete cannot precede another current interval.",
        .current_label = "Count",
        .points = &.{
            .{ .label = "First", .current = 1, .current_incomplete = true },
            .{ .label = "Last", .current = 2 },
        },
    }));

    var single = std.Io.Writer.Allocating.init(std.testing.allocator);
    try renderTrend(&single.writer, .{
        .id = "single",
        .title = "Single",
        .summary = "One point.",
        .current_label = "Count",
        .points = &.{.{ .label = "Now", .current = 0 }},
    });
    const single_rendered = try single.toOwnedSlice();
    defer std.testing.allocator.free(single_rendered);
    try std.testing.expect(std.mem.indexOf(u8, single_rendered, "<circle") != null);
    try std.testing.expect(std.mem.indexOf(u8, single_rendered, "d=\"\"") == null);
    try std.testing.expectEqual(@as(u32, 464), pointX(0, 1, 56, 816));
    try std.testing.expectEqual(@as(u32, 244), try pointY(0, 0, 0, 24, 220));

    var empty = std.Io.Writer.Allocating.init(std.testing.allocator);
    try renderTrend(&empty.writer, .{
        .id = "empty-trend",
        .title = "Empty trend",
        .summary = "No intervals.",
        .current_label = "Count",
        .points = &.{},
    });
    const empty_rendered = try empty.toOwnedSlice();
    defer std.testing.allocator.free(empty_rendered);
    try std.testing.expect(std.mem.indexOf(u8, empty_rendered, "No trend data in this range.") != null);

    var constant = std.Io.Writer.Allocating.init(std.testing.allocator);
    try renderTrend(&constant.writer, .{
        .id = "constant-trend",
        .title = "Constant trend",
        .summary = "Two equal values.",
        .current_label = "Count",
        .points = &.{
            .{ .label = "First", .current = 5 },
            .{ .label = "Last", .current = 5 },
        },
    });
    const constant_rendered = try constant.toOwnedSlice();
    defer std.testing.allocator.free(constant_rendered);
    try std.testing.expect(std.mem.indexOf(u8, constant_rendered, "class=\"chart-area\"") != null);
    try std.testing.expectEqual(@as(u32, 24), try pointY(5, 0, 5, 24, 220));

    var single_comparison = std.Io.Writer.Allocating.init(std.testing.allocator);
    try renderTrend(&single_comparison.writer, .{
        .id = "single-comparison",
        .title = "Single comparison",
        .summary = "One comparison point.",
        .current_label = "Count",
        .show_comparison = true,
        .points = &.{
            .{ .label = "First", .current = 2, .comparison = null },
            .{ .label = "Last", .current = 3, .comparison = 4 },
        },
    });
    const single_comparison_rendered = try single_comparison.toOwnedSlice();
    defer std.testing.allocator.free(single_comparison_rendered);
    try std.testing.expect(std.mem.indexOf(u8, single_comparison_rendered, "class=\"chart-compare-point\"") != null);
}

test "trend preserves signed exact values and bounded native interval links" {
    const points = [_]TrendPoint{.{
        .label = "2025-01-01T00:00",
        .comparison_interval_label = "2024-12-31T00:00",
        .current = -1_250_000,
        .current_formatted = "EUR -1.250000",
        .current_href = "/admin/sites/example/analyze?a=1&b=2",
        .comparison = 2_500_000,
        .comparison_formatted = "EUR 2.500000",
        .comparison_href = "/admin/sites/example/analyze?comparison=1",
    }};
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try renderTrend(&output.writer, .{
        .id = "signed-trend",
        .title = "Revenue (EUR) over time",
        .summary = "Signed exact values.",
        .current_label = "Current range",
        .comparison_label = "Comparison range",
        .show_comparison = true,
        .scale = 6,
        .points = &points,
    });
    const rendered = output.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "class=\"chart-raw-value\">-1.250000</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "(EUR -1.250000)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Current interval") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Comparison interval") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "a=1&amp;b=2") != null);
    try std.testing.expectError(error.InvalidChartHref, renderTrend(&output.writer, .{
        .id = "bad-href",
        .title = "Bad href",
        .summary = "External links are rejected.",
        .current_label = "Current",
        .points = &.{.{
            .label = "Now",
            .current = 1,
            .current_href = "https://attacker.example/",
        }},
    }));
}

test "bar and funnel figures preserve exact all-zero data" {
    var bars = std.Io.Writer.Allocating.init(std.testing.allocator);
    try renderBars(&bars.writer, .{
        .id = "bars",
        .title = "Sources",
        .summary = "Exact source counts.",
        .metric_label = "Visitors",
        .bars = &.{
            .{ .label = "Direct", .value = 0, .value_formatted = "none" },
            .{ .label = "Search", .value = 0 },
        },
    });
    const bars_rendered = try bars.toOwnedSlice();
    defer std.testing.allocator.free(bars_rendered);
    try std.testing.expect(std.mem.indexOf(u8, bars_rendered, "width=\"0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bars_rendered, "<caption id=\"bars-data\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bars_rendered, "class=\"chart-raw-value\">0</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, bars_rendered, "(none)") != null);

    var funnel = std.Io.Writer.Allocating.init(std.testing.allocator);
    try renderFunnel(&funnel.writer, .{
        .id = "funnel",
        .title = "Signup funnel",
        .summary = "All steps are zero.",
        .entrants = 0,
        .steps = &.{
            .{ .name = "Visit", .sessions = 0 },
            .{ .name = "Signup", .sessions = 0 },
        },
    });
    const funnel_rendered = try funnel.toOwnedSlice();
    defer std.testing.allocator.free(funnel_rendered);
    try std.testing.expect(std.mem.indexOf(u8, funnel_rendered, "0.00%") != null);
    try std.testing.expect(std.mem.indexOf(u8, funnel_rendered, "Median to next") != null);
    try std.testing.expectError(error.InvalidFunnelCounts, renderFunnel(&funnel.writer, .{
        .id = "invalid-funnel",
        .title = "Invalid",
        .summary = "Invalid counts.",
        .entrants = 1,
        .steps = &.{.{ .name = "Too many", .sessions = 2 }},
    }));
}

test "fixed path layout validates references and renders ranked alternative" {
    const first = [_]PathNode{
        .{ .label = "A", .count = 7 },
        .{ .label = "B", .count = 3 },
    };
    const middle = [_]PathNode{
        .{ .label = "X", .count = 6 },
        .{ .label = "Y", .count = 4 },
    };
    const last = [_]PathNode{
        .{ .label = "P", .count = 5 },
        .{ .label = "Q", .count = 5 },
    };
    const columns = [_]PathColumn{
        .{ .label = "Before", .nodes = &first },
        .{ .label = "Selected", .nodes = &middle },
        .{ .label = "After", .nodes = &last },
    };
    const edges = [_]PathEdge{
        .{ .from_column = 0, .from_node = 0, .to_node = 0, .count = 4 },
        .{ .from_column = 0, .from_node = 0, .to_node = 1, .count = 3 },
        .{ .from_column = 0, .from_node = 1, .to_node = 0, .count = 2 },
        .{ .from_column = 0, .from_node = 1, .to_node = 1, .count = 1 },
        .{ .from_column = 1, .from_node = 0, .to_node = 0, .count = 3 },
        .{ .from_column = 1, .from_node = 0, .to_node = 1, .count = 3 },
        .{ .from_column = 1, .from_node = 1, .to_node = 0, .count = 2 },
        .{ .from_column = 1, .from_node = 1, .to_node = 1, .count = 2 },
    };
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    try renderPath(&output.writer, .{
        .id = "paths",
        .title = "Paths",
        .summary = "Three fixed columns.",
        .columns = &columns,
        .edges = &edges,
    });
    const rendered = try output.toOwnedSlice();
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "class=\"path-edge\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Before — A") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Selected — X") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "data-label=\"Transitions\">4") != null);
    try std.testing.expectError(error.InvalidPathEdge, renderPath(&output.writer, .{
        .id = "bad-path",
        .title = "Bad",
        .summary = "Bad edge.",
        .columns = &columns,
        .edges = &.{.{ .from_column = 2, .from_node = 0, .to_node = 0, .count = 1 }},
    }));
}

test "fixed path rejects unordered nodes edges and dishonest aggregate totals" {
    const unordered_first = [_]PathNode{
        .{ .label = "Low", .count = 1 },
        .{ .label = "High", .count = 2 },
    };
    const one = [_]PathNode{.{ .label = "One", .count = 1 }};
    const unordered_columns = [_]PathColumn{
        .{ .label = "Before", .nodes = &unordered_first },
        .{ .label = "Selected", .nodes = &one },
        .{ .label = "After", .nodes = &one },
    };
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    try std.testing.expectError(error.InvalidPathNodeOrder, renderPath(&output.writer, .{
        .id = "unordered-nodes",
        .title = "Unordered nodes",
        .summary = "Counts must descend.",
        .columns = &unordered_columns,
        .edges = &.{},
    }));

    const duplicate_nodes = [_]PathNode{
        .{ .label = "Same", .count = 2 },
        .{ .label = "Same", .count = 1 },
    };
    const duplicate_node_columns = [_]PathColumn{
        .{ .label = "Before", .nodes = &duplicate_nodes },
        .{ .label = "Selected", .nodes = &one },
        .{ .label = "After", .nodes = &one },
    };
    try std.testing.expectError(error.DuplicatePathNodeLabel, renderPath(&output.writer, .{
        .id = "duplicate-nodes",
        .title = "Duplicate nodes",
        .summary = "Node labels identify a transition.",
        .columns = &duplicate_node_columns,
        .edges = &.{},
    }));

    const duplicate_column_labels = [_]PathColumn{
        .{ .label = "Step", .nodes = &one },
        .{ .label = "Step", .nodes = &one },
        .{ .label = "After", .nodes = &one },
    };
    try std.testing.expectError(error.DuplicatePathColumnLabel, renderPath(&output.writer, .{
        .id = "duplicate-columns",
        .title = "Duplicate columns",
        .summary = "Step context must remain distinct.",
        .columns = &duplicate_column_labels,
        .edges = &.{},
    }));

    const high_low = [_]PathNode{
        .{ .label = "High", .count = 4 },
        .{ .label = "Low", .count = 3 },
    };
    const ordered_columns = [_]PathColumn{
        .{ .label = "Before", .nodes = &high_low },
        .{ .label = "Selected", .nodes = &high_low },
        .{ .label = "After", .nodes = &high_low },
    };
    try std.testing.expectError(error.InvalidPathEdgeOrder, renderPath(&output.writer, .{
        .id = "unordered-edges",
        .title = "Unordered edges",
        .summary = "Transitions must be ranked.",
        .columns = &ordered_columns,
        .edges = &.{
            .{ .from_column = 0, .from_node = 1, .to_node = 1, .count = 3 },
            .{ .from_column = 0, .from_node = 0, .to_node = 0, .count = 4 },
            .{ .from_column = 1, .from_node = 0, .to_node = 0, .count = 4 },
            .{ .from_column = 1, .from_node = 1, .to_node = 1, .count = 3 },
        },
    }));

    const eight = [_]PathNode{.{ .label = "Only", .count = 8 }};
    const duplicate_edge_columns = [_]PathColumn{
        .{ .label = "Before", .nodes = &eight },
        .{ .label = "Selected", .nodes = &eight },
        .{ .label = "After", .nodes = &eight },
    };
    try std.testing.expectError(error.DuplicatePathEdge, renderPath(&output.writer, .{
        .id = "duplicate-edges",
        .title = "Duplicate edges",
        .summary = "One transition has one ranked edge.",
        .columns = &duplicate_edge_columns,
        .edges = &.{
            .{ .from_column = 0, .from_node = 0, .to_node = 0, .count = 4 },
            .{ .from_column = 0, .from_node = 0, .to_node = 0, .count = 4 },
        },
    }));

    const aggregate_first = [_]PathNode{.{ .label = "A", .count = 5 }};
    const aggregate_next = [_]PathNode{
        .{ .label = "X", .count = 3 },
        .{ .label = "Y", .count = 3 },
    };
    const aggregate_last = [_]PathNode{
        .{ .label = "P", .count = 3 },
        .{ .label = "Q", .count = 3 },
    };
    const aggregate_columns = [_]PathColumn{
        .{ .label = "Before", .nodes = &aggregate_first },
        .{ .label = "Selected", .nodes = &aggregate_next },
        .{ .label = "After", .nodes = &aggregate_last },
    };
    try std.testing.expectError(error.InvalidPathTotals, renderPath(&output.writer, .{
        .id = "dishonest-totals",
        .title = "Dishonest totals",
        .summary = "Each edge fits but their aggregate does not.",
        .columns = &aggregate_columns,
        .edges = &.{
            .{ .from_column = 0, .from_node = 0, .to_node = 0, .count = 3 },
            .{ .from_column = 0, .from_node = 0, .to_node = 1, .count = 3 },
            .{ .from_column = 1, .from_node = 0, .to_node = 0, .count = 3 },
            .{ .from_column = 1, .from_node = 1, .to_node = 1, .count = 3 },
        },
    }));

    const five = [_]PathNode{.{ .label = "Only", .count = 5 }};
    const missing_columns = [_]PathColumn{
        .{ .label = "Before", .nodes = &five },
        .{ .label = "Selected", .nodes = &five },
        .{ .label = "After", .nodes = &five },
    };
    try std.testing.expectError(error.InvalidPathTotals, renderPath(&output.writer, .{
        .id = "missing-totals",
        .title = "Missing totals",
        .summary = "Individually valid edges omit one transition.",
        .columns = &missing_columns,
        .edges = &.{
            .{ .from_column = 0, .from_node = 0, .to_node = 0, .count = 4 },
            .{ .from_column = 1, .from_node = 0, .to_node = 0, .count = 4 },
        },
    }));
}

test "retention prints rates counts and incomplete cells without color-only meaning" {
    const periods = [_][]const u8{ "Week 0", "Week 1" };
    const cells = [_]RetentionCell{
        .{ .returned = 10 },
        .{ .returned = null },
    };
    const rows = [_]RetentionRow{.{ .cohort = "2026-W31", .cohort_size = 10, .cells = &cells }};
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    try renderRetention(&output.writer, .{
        .id = "retention",
        .title = "Weekly retention",
        .summary = "Persistent people only.",
        .period_labels = &periods,
        .rows = &rows,
    });
    const rendered = try output.toOwnedSlice();
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "10 (100.00%)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Incomplete") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "scope=\"row\"") != null);
    try std.testing.expectEqual(@as(u8, 0), intensity(0));
    try std.testing.expectEqual(@as(u8, 4), intensity(10_000));

    const inconsistent = [_]RetentionCell{.{ .returned = 11 }};
    try std.testing.expectError(error.InvalidRetentionCell, renderRetention(&output.writer, .{
        .id = "invalid-retention",
        .title = "Invalid retention",
        .summary = "Returned count exceeds cohort size.",
        .period_labels = &.{"Week 0"},
        .rows = &.{.{ .cohort = "2026-W31", .cohort_size = 10, .cells = &inconsistent }},
    }));

    var rounded = std.Io.Writer.Allocating.init(std.testing.allocator);
    try renderRetention(&rounded.writer, .{
        .id = "rounded-retention",
        .title = "Rounded retention",
        .summary = "One of three returned.",
        .period_labels = &.{"Week 0"},
        .rows = &.{.{
            .cohort = "2026-W32",
            .cohort_size = 3,
            .cells = &.{.{ .returned = 1 }},
        }},
    });
    const rounded_rendered = try rounded.toOwnedSlice();
    defer std.testing.allocator.free(rounded_rendered);
    try std.testing.expect(std.mem.indexOf(u8, rounded_rendered, "1 (33.33%)") != null);
}

test "chart families reject work above every documented bound" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    var trend_points: [maximum_trend_points + 1]TrendPoint = undefined;
    try std.testing.expectError(error.TooManyTrendPoints, renderTrend(&output.writer, .{
        .id = "too-many-trend",
        .title = "Trend",
        .summary = "Too many points.",
        .current_label = "Count",
        .points = &trend_points,
    }));
    var bars: [maximum_bars + 1]Bar = undefined;
    try std.testing.expectError(error.TooManyBars, renderBars(&output.writer, .{
        .id = "too-many-bars",
        .title = "Bars",
        .summary = "Too many bars.",
        .metric_label = "Count",
        .bars = &bars,
    }));
    var funnel_steps: [maximum_funnel_steps + 1]FunnelStep = undefined;
    try std.testing.expectError(error.TooManyFunnelSteps, renderFunnel(&output.writer, .{
        .id = "too-many-funnel",
        .title = "Funnel",
        .summary = "Too many steps.",
        .entrants = 0,
        .steps = &funnel_steps,
    }));
    var path_columns: [maximum_path_columns + 1]PathColumn = undefined;
    try std.testing.expectError(error.InvalidPathColumnCount, renderPath(&output.writer, .{
        .id = "too-many-columns",
        .title = "Paths",
        .summary = "Too many columns.",
        .columns = &path_columns,
        .edges = &.{},
    }));
    var path_nodes: [maximum_path_nodes + 1]PathNode = undefined;
    const node_heavy_columns = [_]PathColumn{
        .{ .label = "One", .nodes = &path_nodes },
        .{ .label = "Two", .nodes = &.{} },
        .{ .label = "Three", .nodes = &.{} },
    };
    try std.testing.expectError(error.TooManyPathNodes, renderPath(&output.writer, .{
        .id = "too-many-nodes",
        .title = "Paths",
        .summary = "Too many nodes.",
        .columns = &node_heavy_columns,
        .edges = &.{},
    }));
    const empty_path_columns = [_]PathColumn{
        .{ .label = "One", .nodes = &.{} },
        .{ .label = "Two", .nodes = &.{} },
        .{ .label = "Three", .nodes = &.{} },
    };
    var path_edges: [maximum_path_edges + 1]PathEdge = undefined;
    try std.testing.expectError(error.TooManyPathEdges, renderPath(&output.writer, .{
        .id = "too-many-edges",
        .title = "Paths",
        .summary = "Too many edges.",
        .columns = &empty_path_columns,
        .edges = &path_edges,
    }));
    var periods: [maximum_retention_periods + 1][]const u8 = undefined;
    try std.testing.expectError(error.TooManyRetentionPeriods, renderRetention(&output.writer, .{
        .id = "too-many-periods",
        .title = "Retention",
        .summary = "Too many periods.",
        .period_labels = &periods,
        .rows = &.{},
    }));
    var retention_rows: [maximum_retention_rows + 1]RetentionRow = undefined;
    try std.testing.expectError(error.TooManyRetentionRows, renderRetention(&output.writer, .{
        .id = "too-many-retention-rows",
        .title = "Retention",
        .summary = "Too many rows.",
        .period_labels = &.{},
        .rows = &retention_rows,
    }));

    const long_id: [65]u8 = @splat('a');
    try std.testing.expectError(error.InvalidDocumentId, renderBars(&output.writer, .{
        .id = &long_id,
        .title = "Bars",
        .summary = "ID too long.",
        .metric_label = "Count",
        .bars = &.{},
    }));
    const long_label: [maximum_label_bytes + 1]u8 = @splat('a');
    try std.testing.expectError(error.ChartLabelTooLong, renderBars(&output.writer, .{
        .id = "long-label",
        .title = &long_label,
        .summary = "Label too long.",
        .metric_label = "Count",
        .bars = &.{},
    }));

    const empty_columns = [_]PathColumn{};
    try std.testing.expectError(error.InvalidPathEdge, renderPath(&output.writer, .{
        .id = "edge-without-columns",
        .title = "Paths",
        .summary = "No columns.",
        .columns = &empty_columns,
        .edges = &.{.{ .from_column = 0, .from_node = 0, .to_node = 0, .count = 1 }},
    }));
}

test "maximum fixed path geometry remains inside its view box" {
    var nodes: [maximum_path_nodes]PathNode = undefined;
    for (&nodes, 0..) |*node, index| node.* = .{
        .label = "Node",
        .count = @intCast(index + 1),
    };
    const columns = [_]PathColumn{
        .{ .label = "One", .nodes = &nodes },
        .{ .label = "Two", .nodes = &nodes },
        .{ .label = "Three", .nodes = &nodes },
        .{ .label = "Four", .nodes = &nodes },
        .{ .label = "Five", .nodes = &nodes },
    };
    const last = nodeBox(&columns, maximum_path_columns - 1, maximum_path_nodes - 1);
    try std.testing.expect(last.x + last.width <= 900);
    try std.testing.expect(last.y + last.height <= 560);
}
