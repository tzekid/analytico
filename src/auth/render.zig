const std = @import("std");
const store_mod = @import("store.zig");

pub const passkeys_js = @embedFile("passkeys.js");
pub const passkeys_path = "/admin/passkeys.a2d7cf37.js";

pub const html_headers =
    "Cache-Control: private, no-store, max-age=0\r\n" ++
    "Content-Security-Policy: default-src 'none'; script-src 'self'; " ++
    "style-src 'self'; connect-src 'self'; form-action 'self'; " ++
    "base-uri 'none'; frame-ancestors 'none'\r\n" ++
    "Permissions-Policy: publickey-credentials-create=(self), " ++
    "publickey-credentials-get=(self)\r\n" ++
    "X-Content-Type-Options: nosniff\r\n" ++
    "Referrer-Policy: no-referrer\r\n";

pub const authenticated_html_headers =
    "Cache-Control: private, no-store, max-age=0\r\n" ++
    "Content-Security-Policy: default-src 'none'; script-src 'self'; " ++
    "style-src 'self'; connect-src 'self'; form-action 'self'; " ++
    "base-uri 'none'; frame-ancestors 'none'\r\n" ++
    "Permissions-Policy: publickey-credentials-create=(self), " ++
    "publickey-credentials-get=(self)\r\n" ++
    "X-Content-Type-Options: nosniff\r\n" ++
    "Referrer-Policy: same-origin\r\n";

pub fn setupPage(output: *std.Io.Writer) !void {
    try head(output, "Set up a passkey", null);
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

pub fn loginPage(output: *std.Io.Writer, return_path: []const u8) !void {
    try head(output, "Sign in", return_path);
    try output.writeAll(
        "<main><section class=\"panel\"><h1>Analytico</h1>" ++
            "<p>Use the owner passkey to unlock the private dashboard.</p>" ++
            "<p><button id=\"login-button\" type=\"button\">Use a passkey</button></p>" ++
            "<p id=\"login-error\" class=\"error\" role=\"alert\"></p>" ++
            "<noscript><p class=\"error\">Sign-in needs JavaScript because WebAuthn " ++
            "is a browser API. No dashboard state is available until sign-in " ++
            "succeeds.</p></noscript>" ++
            "<p class=\"muted\">Touch ID, Face ID, device passcode, or a compatible " ++
            "security key can verify you.</p></section></main>",
    );
    try foot(output);
}

pub const SecurityPage = struct {
    credentials: []const store_mod.Credential,
    sessions: []const store_mod.Session,
    current_session_hash: []const u8,
    csrf_token: []const u8,
    notice: []const u8,
    error_message: []const u8,
};

pub fn securityPage(output: *std.Io.Writer, value: SecurityPage) !void {
    try head(output, "Security", null);
    try output.writeAll(
        "<header><h1>Security</h1><nav><a href=\"/admin\">Dashboard</a> " ++
            "<form class=\"inline\" method=\"post\" action=\"/admin/logout\">",
    );
    try hiddenCsrf(output, value.csrf_token);
    try output.writeAll("<button type=\"submit\">Sign out</button></form></nav></header><main>");
    if (value.notice.len != 0) {
        try output.writeAll("<p class=\"notice\" role=\"status\">");
        try text(output, value.notice);
        try output.writeAll("</p>");
    }
    if (value.error_message.len != 0) {
        try output.writeAll("<p class=\"error\" role=\"alert\">");
        try text(output, value.error_message);
        try output.writeAll("</p>");
    }
    try output.writeAll(
        "<section class=\"panel\"><h2>Passkeys</h2>" ++
            "<p>Keep at least one passkey. A second independent passkey gives you a recovery path.</p><ul>",
    );
    var active_credentials: usize = 0;
    for (value.credentials) |credential| {
        if (credential.revoked_at != null) continue;
        active_credentials += 1;
        try output.writeAll("<li><strong>");
        try text(output, credential.label);
        try output.print(
            "</strong> <span class=\"muted\">created {d}; last used {s}; synced-capable {s}</span>" ++
                "<form method=\"post\" action=\"/admin/security/passkeys/rename\">",
            .{
                credential.created_at,
                if (credential.last_used_at == null) "never" else "recorded",
                if (credential.backup_eligible) "yes" else "no",
            },
        );
        try hiddenCsrf(output, value.csrf_token);
        try hidden(output, "credential_id", credential.credential_id);
        try output.writeAll("<label>Label<input name=\"label\" maxlength=\"64\" required value=\"");
        try attribute(output, credential.label);
        try output.writeAll("\"></label><button type=\"submit\">Rename</button></form>");
        try output.writeAll("<form method=\"post\" action=\"/admin/security/passkeys/revoke\">");
        try hiddenCsrf(output, value.csrf_token);
        try hidden(output, "credential_id", credential.credential_id);
        try output.writeAll("<button class=\"danger\" type=\"submit\">Revoke</button></form></li>");
    }
    if (active_credentials == 0) try output.writeAll("<li>No active passkeys.</li>");
    try output.writeAll(
        "</ul><h3>Add passkey</h3><form id=\"add-passkey-form\">",
    );
    try hiddenCsrf(output, value.csrf_token);
    try output.writeAll(
        "<label>Passkey name<input id=\"add-passkey-label\" maxlength=\"64\" " ++
            "value=\"Backup passkey\" required></label>" ++
            "<button id=\"add-passkey-button\" type=\"submit\">Add passkey</button>" ++
            "<p id=\"add-passkey-error\" class=\"error\" role=\"alert\"></p></form>" ++
            "<noscript><p class=\"error\">Adding a passkey needs JavaScript because WebAuthn is a browser API.</p></noscript>" ++
            "</section><section class=\"panel\"><h2>Active sessions</h2><ul>",
    );
    for (value.sessions) |session| {
        const current = std.mem.eql(u8, session.token_hash, value.current_session_hash);
        try output.print(
            "<li><strong>{s}</strong> <span class=\"muted\">created {d}; last seen {d}; expires {d}</span>",
            .{ if (current) "Current session" else "Other session", session.created_at, session.last_seen_at, session.expires_at },
        );
        if (!current) {
            try output.writeAll("<form method=\"post\" action=\"/admin/security/sessions/revoke\">");
            try hiddenCsrf(output, value.csrf_token);
            try hidden(output, "session_hash", session.token_hash);
            try output.writeAll("<button class=\"danger\" type=\"submit\">Revoke session</button></form>");
        }
        try output.writeAll("</li>");
    }
    try output.writeAll("</ul></section></main>");
    try foot(output);
}

fn hiddenCsrf(output: *std.Io.Writer, value: []const u8) !void {
    try hidden(output, "csrf", value);
}

fn hidden(output: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try output.writeAll("<input type=\"hidden\" name=\"");
    try attribute(output, name);
    try output.writeAll("\" value=\"");
    try attribute(output, value);
    try output.writeAll("\">");
}

fn head(
    output: *std.Io.Writer,
    title: []const u8,
    return_path: ?[]const u8,
) !void {
    try output.writeAll(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" ++
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
            "<title>",
    );
    try text(output, title);
    try output.writeAll(
        " · Analytico</title><link rel=\"stylesheet\" href=\"/admin/app.v11.css\">" ++
            "<script defer src=\"",
    );
    try attribute(output, passkeys_path);
    try output.writeAll("\"></script></head><body class=\"auth-page\"");
    if (return_path) |value| {
        try output.writeAll(" data-return=\"");
        try attribute(output, value);
        try output.writeByte('"');
    }
    try output.writeByte('>');
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
