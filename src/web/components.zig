const std = @import("std");

const maximum_id_bytes: usize = 64;

pub const Kpi = struct {
    label: []const u8,
    value: []const u8,
    detail: []const u8 = "",
    detail_kind: DetailKind = .neutral,
};

pub const DetailKind = enum {
    neutral,
    positive,
    negative,
};

pub const FeedbackKind = enum {
    notice,
    warning,
    error_message,
};

pub const Feedback = struct {
    kind: FeedbackKind,
    message: []const u8,
    id: []const u8 = "",
    focus: bool = false,
};

pub const EmptyState = struct {
    id: []const u8,
    title: []const u8,
    message: []const u8,
    action_label: []const u8 = "",
    action_url: []const u8 = "",
};

pub fn kpi(output: *std.Io.Writer, value: Kpi) !void {
    try output.writeAll("<li class=\"kpi\"><span>");
    try text(output, value.label);
    try output.writeAll("</span><strong>");
    try text(output, value.value);
    try output.writeAll("</strong>");
    if (value.detail.len != 0) {
        try output.writeAll("<small class=\"kpi-detail");
        switch (value.detail_kind) {
            .neutral => {},
            .positive => try output.writeAll(" kpi-positive"),
            .negative => try output.writeAll(" kpi-negative"),
        }
        try output.writeAll("\">");
        try text(output, value.detail);
        try output.writeAll("</small>");
    }
    try output.writeAll("</li>");
}

pub fn feedback(output: *std.Io.Writer, value: Feedback) !void {
    if (value.id.len != 0) try validateDocumentId(value.id);
    if (value.focus and value.id.len == 0) return error.MissingFeedbackId;
    try output.writeAll("<p class=\"");
    try output.writeAll(switch (value.kind) {
        .notice => "notice",
        .warning => "warning",
        .error_message => "error",
    });
    try output.writeAll("\" role=\"");
    try output.writeAll(switch (value.kind) {
        .notice, .warning => "status",
        .error_message => "alert",
    });
    try output.writeAll("\"");
    if (value.id.len != 0) {
        try output.writeAll(" id=\"");
        try attribute(output, value.id);
        try output.writeByte('"');
    }
    if (value.focus) {
        try output.writeAll(" tabindex=\"-1\" autofocus");
    }
    try output.writeByte('>');
    try text(output, value.message);
    try output.writeAll("</p>");
}

pub fn emptyState(output: *std.Io.Writer, value: EmptyState) !void {
    try validateDocumentId(value.id);
    if ((value.action_label.len == 0) != (value.action_url.len == 0)) {
        return error.IncompleteEmptyStateAction;
    }
    try output.writeAll("<section class=\"panel empty-state\" aria-labelledby=\"");
    try attribute(output, value.id);
    try output.writeAll("\"><h2 id=\"");
    try attribute(output, value.id);
    try output.writeAll("\">");
    try text(output, value.title);
    try output.writeAll("</h2><p>");
    try text(output, value.message);
    try output.writeAll("</p>");
    if (value.action_label.len != 0) {
        try output.writeAll("<p><a href=\"");
        try attribute(output, value.action_url);
        try output.writeAll("\">");
        try text(output, value.action_label);
        try output.writeAll("</a></p>");
    }
    try output.writeAll("</section>");
}

pub fn text(output: *std.Io.Writer, value: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
    for (value) |byte| switch (byte) {
        '&' => try output.writeAll("&amp;"),
        '<' => try output.writeAll("&lt;"),
        '>' => try output.writeAll("&gt;"),
        '"' => try output.writeAll("&quot;"),
        '\'' => try output.writeAll("&#39;"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => try output.writeAll("&#xfffd;"),
        else => try output.writeByte(byte),
    };
}

pub fn attribute(output: *std.Io.Writer, value: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
    for (value) |byte| switch (byte) {
        '\t' => try output.writeAll("&#9;"),
        '\n' => try output.writeAll("&#10;"),
        '\r' => try output.writeAll("&#13;"),
        '&' => try output.writeAll("&amp;"),
        '<' => try output.writeAll("&lt;"),
        '>' => try output.writeAll("&gt;"),
        '"' => try output.writeAll("&quot;"),
        '\'' => try output.writeAll("&#39;"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => try output.writeAll("&#xfffd;"),
        else => try output.writeByte(byte),
    };
}

pub fn validateDocumentId(id: []const u8) !void {
    if (id.len == 0 or id.len > maximum_id_bytes) return error.InvalidDocumentId;
    for (id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') {
            return error.InvalidDocumentId;
        }
    }
}

test "components escape every caller-controlled output context" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    try kpi(&output.writer, .{
        .label = "<label>\"&",
        .value = "7<8",
        .detail = "up 'now'",
        .detail_kind = .positive,
    });
    try feedback(&output.writer, .{
        .kind = .error_message,
        .message = "bad <value>",
        .id = "failure-summary",
        .focus = true,
    });
    const rendered = try output.toOwnedSlice();
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<label>") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "&lt;label&gt;&quot;&amp;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "7&lt;8") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "up &#39;now&#39;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "id=\"failure-summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "tabindex=\"-1\" autofocus") != null);
    try std.testing.expectError(error.InvalidUtf8, text(&output.writer, "\xff"));
    try std.testing.expectError(error.InvalidDocumentId, feedback(&output.writer, .{
        .kind = .error_message,
        .message = "Bad ID",
        .id = "failure\nsummary",
    }));
    try std.testing.expectError(error.MissingFeedbackId, feedback(&output.writer, .{
        .kind = .error_message,
        .message = "Missing ID",
        .focus = true,
    }));

    var attribute_output = std.Io.Writer.Allocating.init(std.testing.allocator);
    try attribute(&attribute_output.writer, "value\n\"<&");
    const escaped_attribute = try attribute_output.toOwnedSlice();
    defer std.testing.allocator.free(escaped_attribute);
    try std.testing.expectEqualStrings("value&#10;&quot;&lt;&amp;", escaped_attribute);
}

test "empty state has one named region and escaped action" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    try emptyState(&output.writer, .{
        .id = "sessions-empty",
        .title = "No <sessions>",
        .message = "Try another range.",
        .action_label = "View & settings",
        .action_url = "/admin?x=\"unsafe\"",
    });
    const rendered = try output.toOwnedSlice();
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "aria-labelledby=\"sessions-empty\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "No &lt;sessions&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "href=\"/admin?x=&quot;unsafe&quot;\"") != null);
    try std.testing.expectError(error.IncompleteEmptyStateAction, emptyState(&output.writer, .{
        .id = "incomplete-empty",
        .title = "Incomplete",
        .message = "Missing action URL.",
        .action_label = "Continue",
    }));
}
