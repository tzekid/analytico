const std = @import("std");

pub const passkeys_js = @embedFile("passkeys.js");
pub const passkeys_path = "/admin/passkeys.5e127fb5.js";

pub const html_headers =
    "Cache-Control: private, no-store, max-age=0\r\n" ++
    "Content-Security-Policy: default-src 'none'; script-src 'self'; " ++
    "style-src 'self'; connect-src 'self'; form-action 'self'; " ++
    "base-uri 'none'; frame-ancestors 'none'\r\n" ++
    "Permissions-Policy: publickey-credentials-create=(self), " ++
    "publickey-credentials-get=(self)\r\n" ++
    "X-Content-Type-Options: nosniff\r\n" ++
    "Referrer-Policy: no-referrer\r\n";

pub fn setupPage(output: *std.Io.Writer) !void {
    try head(output, "Set up a passkey");
    try output.writeAll(
        "<main><section class=\"panel\"><h1>Set up Analytico</h1>" ++
            "<p>Create the owner passkey that will unlock the private dashboard.</p>" ++
            "<form id=\"setup-form\"><label>Passkey name" ++
            "<input id=\"passkey-label\" name=\"label\" maxlength=\"64\" " ++
            "value=\"Personal passkey\" autocomplete=\"off\" required></label>" ++
            "<p><button id=\"setup-button\" type=\"submit\">Create passkey</button></p>" ++
            "<p id=\"setup-error\" class=\"error\" role=\"alert\"></p></form>" ++
            "<noscript><p class=\"error\">Passkey setup needs JavaScript because " ++
            "WebAuthn is a browser API. The analytics dashboard itself remains " ++
            "usable without JavaScript after login.</p></noscript>" ++
            "<p class=\"muted\">Touch ID, Face ID, device passcode, and compatible " ++
            "hardware security keys are supported.</p></section></main>",
    );
    try foot(output);
}

fn head(output: *std.Io.Writer, title: []const u8) !void {
    try output.writeAll(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" ++
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
            "<title>",
    );
    try text(output, title);
    try output.writeAll(
        " · Analytico</title><link rel=\"stylesheet\" href=\"/admin/app.v1.css\">" ++
            "<script defer src=\"",
    );
    try attribute(output, passkeys_path);
    try output.writeAll("\"></script></head><body>");
}

fn foot(output: *std.Io.Writer) !void {
    try output.writeAll(
        "<footer>Private owner access · server-side authorization</footer>" ++
            "</body></html>",
    );
}

fn text(output: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '&' => try output.writeAll("&amp;"),
        '<' => try output.writeAll("&lt;"),
        '>' => try output.writeAll("&gt;"),
        else => try output.writeByte(byte),
    };
}

fn attribute(output: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '&' => try output.writeAll("&amp;"),
        '<' => try output.writeAll("&lt;"),
        '>' => try output.writeAll("&gt;"),
        '"' => try output.writeAll("&quot;"),
        '\'' => try output.writeAll("&#39;"),
        else => try output.writeByte(byte),
    };
}
