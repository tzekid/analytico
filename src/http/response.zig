const std = @import("std");

pub fn write(
    output: *std.Io.Writer,
    status: u16,
    content_type: []const u8,
    headers: []const u8,
    body: []const u8,
) !void {
    try output.print(
        "HTTP/1.1 {d} {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "{s}" ++
            "Connection: close\r\n\r\n",
        .{ status, statusText(status), content_type, body.len, headers },
    );
    try output.writeAll(body);
    try output.flush();
}

pub fn statusText(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        204 => "No Content",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        415 => "Unsupported Media Type",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        else => "Error",
    };
}
