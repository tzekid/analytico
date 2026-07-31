const std = @import("std");
const request_mod = @import("../http/request.zig");
const response = @import("../http/response.zig");
const meta = @import("../store/meta.zig");
const render = @import("render.zig");
const service = @import("service.zig");
const store_mod = @import("store.zig");

const json_headers =
    "Cache-Control: private, no-store, max-age=0\r\n" ++
    "X-Content-Type-Options: nosniff\r\n" ++
    "Referrer-Policy: no-referrer\r\n";

pub const Dependencies = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    metadata: *meta.Store,
    policy: store_mod.Policy,
};

pub fn handlePublic(
    dependencies: Dependencies,
    request: request_mod.Request,
    output: *std.Io.Writer,
) !bool {
    const path = request.path();
    if (std.mem.eql(u8, path, render.passkeys_path)) {
        if (!std.mem.eql(u8, request.method, "GET")) {
            try methodNotAllowed(output, "GET");
        } else {
            try response.write(
                output,
                200,
                "text/javascript; charset=utf-8",
                "Cache-Control: private, max-age=31536000, immutable\r\n" ++
                    "X-Content-Type-Options: nosniff\r\n",
                render.passkeys_js,
            );
        }
        return true;
    }
    if (std.mem.eql(u8, path, "/admin/setup")) {
        if (!std.mem.eql(u8, request.method, "GET")) {
            try methodNotAllowed(output, "GET");
        } else {
            var body = std.Io.Writer.Allocating.init(dependencies.allocator);
            try render.setupPage(&body.writer);
            try response.write(
                output,
                200,
                "text/html; charset=utf-8",
                render.html_headers,
                body.written(),
            );
        }
        return true;
    }
    if (std.mem.eql(u8, path, "/admin/login")) {
        if (!std.mem.eql(u8, request.method, "GET")) {
            try methodNotAllowed(output, "GET");
        } else {
            try loginPage(dependencies, request, output);
        }
        return true;
    }
    if (std.mem.eql(u8, path, "/admin/auth/setup/options")) {
        if (!std.mem.eql(u8, request.method, "POST")) {
            try methodNotAllowed(output, "POST");
        } else {
            try setupOptions(dependencies, request, output);
        }
        return true;
    }
    if (std.mem.eql(u8, path, "/admin/auth/setup/verify")) {
        if (!std.mem.eql(u8, request.method, "POST")) {
            try methodNotAllowed(output, "POST");
        } else {
            try setupVerify(dependencies, request, output);
        }
        return true;
    }
    if (std.mem.eql(u8, path, "/admin/auth/login/options")) {
        if (!std.mem.eql(u8, request.method, "POST")) {
            try methodNotAllowed(output, "POST");
        } else {
            try loginOptions(dependencies, request, output);
        }
        return true;
    }
    if (std.mem.eql(u8, path, "/admin/auth/login/verify")) {
        if (!std.mem.eql(u8, request.method, "POST")) {
            try methodNotAllowed(output, "POST");
        } else {
            try loginVerify(dependencies, request, output);
        }
        return true;
    }
    return false;
}

pub fn handlePrivate(
    dependencies: Dependencies,
    request: request_mod.Request,
    session: service.Session,
    output: *std.Io.Writer,
) !bool {
    if (!std.mem.eql(u8, request.path(), "/admin/logout")) return false;
    if (!std.mem.eql(u8, request.method, "POST")) {
        try methodNotAllowed(output, "POST");
        return true;
    }
    if (!hasFormContentType(try request.header("content-type")) or
        !try originMatches(request, dependencies.policy.origin))
    {
        try textError(output, 403, "forbidden\n");
        return true;
    }
    const csrf = (formValue(dependencies.allocator, request.body, "csrf") catch null) orelse {
        try textError(output, 403, "forbidden\n");
        return true;
    };
    if (!service.constantTimeEqual(csrf, session.csrf_token)) {
        try textError(output, 403, "forbidden\n");
        return true;
    }
    try service.revokeSession(appContext(dependencies), session.token);
    var headers = std.Io.Writer.Allocating.init(dependencies.allocator);
    try headers.writer.writeAll("Cache-Control: no-store\r\nLocation: /admin/login\r\n");
    try writeClearedSessionCookie(&headers.writer, isSecure(dependencies.policy.origin));
    try response.write(output, 303, "text/plain; charset=utf-8", headers.written(), "see other\n");
    return true;
}

pub fn requestSession(
    dependencies: Dependencies,
    request: request_mod.Request,
) !?service.Session {
    const cookies = (try request.header("cookie")) orelse return null;
    const token = cookieValue(cookies, cookieName(isSecure(dependencies.policy.origin))) orelse
        return null;
    return service.validateSession(appContext(dependencies), token);
}

pub fn denyAnonymous(
    allocator: std.mem.Allocator,
    request: request_mod.Request,
    output: *std.Io.Writer,
) !void {
    const enhanced = (try request.header("hx-request")) != null;
    if (!std.mem.eql(u8, request.method, "GET") or enhanced) {
        try textError(output, 401, "authentication required\n");
        return;
    }
    var location = std.Io.Writer.Allocating.init(allocator);
    try location.writer.writeAll("/admin/login?return=");
    try urlComponent(&location.writer, if (validReturnPath(request.target)) request.target else "/admin");
    var headers = std.Io.Writer.Allocating.init(allocator);
    try headers.writer.print("Cache-Control: no-store\r\nLocation: {s}\r\n", .{location.written()});
    try response.write(output, 303, "text/plain; charset=utf-8", headers.written(), "see other\n");
}

fn setupOptions(
    dependencies: Dependencies,
    request: request_mod.Request,
    output: *std.Io.Writer,
) !void {
    if (!hasJsonContentType(try request.header("content-type"))) {
        try jsonError(output, 415, "json_required");
        return;
    }
    const bootstrap = (try request.header("x-analytico-bootstrap")) orelse {
        try jsonError(output, 401, "invalid_setup_link");
        return;
    };
    if (bootstrap.len < 32 or bootstrap.len > 128) {
        try jsonError(output, 401, "invalid_setup_link");
        return;
    }
    var body = std.Io.Writer.Allocating.init(dependencies.allocator);
    service.writeSetupOptions(
        appContext(dependencies),
        bootstrap,
        &body.writer,
    ) catch |err| {
        try authError(output, err);
        return;
    };
    try response.write(
        output,
        200,
        "application/json; charset=utf-8",
        json_headers,
        body.written(),
    );
}

const RegistrationBody = struct {
    challenge_id: []const u8,
    credential_id: []const u8,
    attestation_object: []const u8,
    client_data_json: []const u8,
    transports: []const u8 = "",
    label: []const u8 = "Passkey",
};

fn setupVerify(
    dependencies: Dependencies,
    request: request_mod.Request,
    output: *std.Io.Writer,
) !void {
    if (!hasJsonContentType(try request.header("content-type"))) {
        try jsonError(output, 415, "json_required");
        return;
    }
    const bootstrap = (try request.header("x-analytico-bootstrap")) orelse {
        try jsonError(output, 401, "invalid_setup_link");
        return;
    };
    if (bootstrap.len < 32 or bootstrap.len > 128) {
        try jsonError(output, 401, "invalid_setup_link");
        return;
    }
    const parsed = std.json.parseFromSlice(
        RegistrationBody,
        dependencies.allocator,
        request.body,
        .{ .ignore_unknown_fields = false },
    ) catch {
        try jsonError(output, 400, "invalid_passkey_response");
        return;
    };
    defer parsed.deinit();
    if (parsed.value.credential_id.len == 0 or
        parsed.value.credential_id.len > 1374)
    {
        try jsonError(output, 400, "invalid_passkey_response");
        return;
    }
    const issued = (service.finishRegistration(appContext(dependencies), .{
        .challenge_id = parsed.value.challenge_id,
        .bootstrap_token = bootstrap,
        .attestation_object = parsed.value.attestation_object,
        .client_data_json = parsed.value.client_data_json,
        .transports = parsed.value.transports,
        .label = parsed.value.label,
    }) catch |err| {
        try authError(output, err);
        return;
    }) orelse {
        try jsonError(output, 400, "invalid_passkey_response");
        return;
    };
    defer issued.deinit(dependencies.allocator);

    var headers = std.Io.Writer.Allocating.init(dependencies.allocator);
    try headers.writer.writeAll(json_headers);
    try writeSessionCookie(
        &headers.writer,
        isSecure(dependencies.policy.origin),
        issued.token,
        service.session_seconds,
    );
    try response.write(
        output,
        201,
        "application/json; charset=utf-8",
        headers.written(),
        "{\"ok\":true}\n",
    );
}

fn loginPage(
    dependencies: Dependencies,
    request: request_mod.Request,
    output: *std.Io.Writer,
) !void {
    const return_path = try requestedReturnPath(dependencies.allocator, request.target);
    if (try requestSession(dependencies, request)) |session| {
        defer session.deinit(dependencies.allocator);
        var headers = std.Io.Writer.Allocating.init(dependencies.allocator);
        try headers.writer.print(
            "Cache-Control: no-store\r\nLocation: {s}\r\n",
            .{return_path},
        );
        try response.write(output, 303, "text/plain; charset=utf-8", headers.written(), "see other\n");
        return;
    }
    var body = std.Io.Writer.Allocating.init(dependencies.allocator);
    try render.loginPage(&body.writer, return_path);
    try response.write(
        output,
        200,
        "text/html; charset=utf-8",
        render.html_headers,
        body.written(),
    );
}

fn loginOptions(
    dependencies: Dependencies,
    request: request_mod.Request,
    output: *std.Io.Writer,
) !void {
    if (!hasJsonContentType(try request.header("content-type"))) {
        try jsonError(output, 415, "json_required");
        return;
    }
    var body = std.Io.Writer.Allocating.init(dependencies.allocator);
    service.writeLoginOptions(appContext(dependencies), &body.writer) catch |err| {
        try authError(output, err);
        return;
    };
    try response.write(output, 200, "application/json; charset=utf-8", json_headers, body.written());
}

const AuthenticationBody = struct {
    challenge_id: []const u8,
    credential_id: []const u8,
    authenticator_data: []const u8,
    client_data_json: []const u8,
    signature: []const u8,
};

fn loginVerify(
    dependencies: Dependencies,
    request: request_mod.Request,
    output: *std.Io.Writer,
) !void {
    if (!hasJsonContentType(try request.header("content-type"))) {
        try jsonError(output, 415, "json_required");
        return;
    }
    const parsed = std.json.parseFromSlice(
        AuthenticationBody,
        dependencies.allocator,
        request.body,
        .{ .ignore_unknown_fields = false },
    ) catch {
        try jsonError(output, 401, "invalid_passkey_response");
        return;
    };
    defer parsed.deinit();
    const issued = service.finishAuthentication(appContext(dependencies), .{
        .challenge_id = parsed.value.challenge_id,
        .credential_id = parsed.value.credential_id,
        .authenticator_data = parsed.value.authenticator_data,
        .client_data_json = parsed.value.client_data_json,
        .signature = parsed.value.signature,
    }) catch |err| {
        try authError(output, err);
        return;
    };
    defer issued.deinit(dependencies.allocator);

    var headers = std.Io.Writer.Allocating.init(dependencies.allocator);
    try headers.writer.writeAll(json_headers);
    try writeSessionCookie(
        &headers.writer,
        isSecure(dependencies.policy.origin),
        issued.token,
        service.session_seconds,
    );
    try response.write(output, 200, "application/json; charset=utf-8", headers.written(), "{\"ok\":true}\n");
}

fn appContext(dependencies: Dependencies) service.Context {
    return .{
        .io = dependencies.io,
        .allocator = dependencies.allocator,
        .store = .{ .metadata = dependencies.metadata },
        .origin = dependencies.policy.origin,
        .rp_id = dependencies.policy.rp_id,
    };
}

pub fn cookieName(secure: bool) []const u8 {
    return if (secure)
        "__Host-analytico_session"
    else
        "analytico_session";
}

pub fn writeSessionCookie(
    writer: *std.Io.Writer,
    secure: bool,
    token: []const u8,
    max_age: i64,
) !void {
    try writer.print(
        "Set-Cookie: {s}={s}; Path=/; HttpOnly; SameSite=Strict; " ++
            "Max-Age={d}{s}\r\n",
        .{ cookieName(secure), token, max_age, if (secure) "; Secure" else "" },
    );
}

pub fn writeClearedSessionCookie(
    writer: *std.Io.Writer,
    secure: bool,
) !void {
    try writer.print(
        "Set-Cookie: {s}=; Path=/; HttpOnly; SameSite=Strict; " ++
            "Max-Age=0{s}\r\n",
        .{ cookieName(secure), if (secure) "; Secure" else "" },
    );
}

pub fn cookieValue(header: []const u8, name: []const u8) ?[]const u8 {
    var items = std.mem.splitScalar(u8, header, ';');
    while (items.next()) |raw| {
        const pair = std.mem.trim(u8, raw, " \t");
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, pair[0..equals], " \t"), name)) {
            const value = pair[equals + 1 ..];
            return if (value.len == 0) null else value;
        }
    }
    return null;
}

fn isSecure(origin: []const u8) bool {
    return std.mem.startsWith(u8, origin, "https://");
}

fn hasJsonContentType(value: ?[]const u8) bool {
    const raw = value orelse return false;
    return std.ascii.startsWithIgnoreCase(raw, "application/json") and
        (raw.len == "application/json".len or raw["application/json".len] == ';');
}

fn hasFormContentType(value: ?[]const u8) bool {
    const raw = value orelse return false;
    const base = if (std.mem.cutScalar(u8, raw, ';')) |parts| parts[0] else raw;
    return std.ascii.eqlIgnoreCase(
        std.mem.trim(u8, base, " \t"),
        "application/x-www-form-urlencoded",
    );
}

fn originMatches(request: request_mod.Request, expected: []const u8) !bool {
    const actual = (try request.header("origin")) orelse return false;
    return service.constantTimeEqual(actual, expected);
}

fn formValue(
    allocator: std.mem.Allocator,
    body: []const u8,
    expected: []const u8,
) !?[]const u8 {
    var result: ?[]const u8 = null;
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const raw_name, const raw_value = std.mem.cutScalar(u8, pair, '=') orelse
            return error.InvalidFormEncoding;
        const name = try decodeComponent(allocator, raw_name);
        if (!std.mem.eql(u8, name, expected)) continue;
        if (result != null) return error.InvalidFormEncoding;
        result = try decodeComponent(allocator, raw_value);
    }
    return result;
}

fn requestedReturnPath(allocator: std.mem.Allocator, target: []const u8) ![]const u8 {
    const marker = std.mem.findScalar(u8, target, '?') orelse return "/admin";
    var pairs = std.mem.splitScalar(u8, target[marker + 1 ..], '&');
    while (pairs.next()) |pair| {
        const raw_name, const raw_value = std.mem.cutScalar(u8, pair, '=') orelse continue;
        const name = decodeComponent(allocator, raw_name) catch continue;
        if (!std.mem.eql(u8, name, "return")) continue;
        const value = decodeComponent(allocator, raw_value) catch return "/admin";
        return if (validReturnPath(value)) value else "/admin";
    }
    return "/admin";
}

fn validReturnPath(value: []const u8) bool {
    if (value.len < "/admin".len or value.len > request_mod.max_target_bytes or
        !std.mem.startsWith(u8, value, "/admin") or
        std.mem.startsWith(u8, value, "//"))
    {
        return false;
    }
    if (value.len > "/admin".len and value["/admin".len] != '/' and
        value["/admin".len] != '?')
    {
        return false;
    }
    for (value) |byte| {
        if (byte == '\\' or byte == '\r' or byte == '\n' or byte == 0) return false;
    }
    return true;
}

fn decodeComponent(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    const decoded = try allocator.alloc(u8, encoded.len);
    var input: usize = 0;
    var output: usize = 0;
    while (input < encoded.len) {
        if (encoded[input] == '+') {
            decoded[output] = ' ';
            input += 1;
        } else if (encoded[input] == '%') {
            if (input + 2 >= encoded.len) return error.InvalidUrlEncoding;
            decoded[output] = std.fmt.parseInt(
                u8,
                encoded[input + 1 .. input + 3],
                16,
            ) catch return error.InvalidUrlEncoding;
            input += 3;
        } else {
            decoded[output] = encoded[input];
            input += 1;
        }
        output += 1;
    }
    if (!std.unicode.utf8ValidateSlice(decoded[0..output])) {
        return error.InvalidUrlEncoding;
    }
    return decoded[0..output];
}

fn urlComponent(output: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or
            byte == '-' or byte == '_' or byte == '.' or byte == '~')
        {
            try output.writeByte(byte);
        } else {
            try output.writeByte('%');
            try output.writeByte(hex[byte >> 4]);
            try output.writeByte(hex[byte & 0x0f]);
        }
    }
}

fn authError(output: *std.Io.Writer, err: anyerror) !void {
    switch (err) {
        error.InvalidBootstrap => try jsonError(output, 401, "invalid_setup_link"),
        error.InvalidChallenge,
        error.InvalidPasskeyResponse,
        error.AuthNotConfigured,
        => try jsonError(output, 401, "invalid_passkey_response"),
        error.AuthAlreadyConfigured => try jsonError(output, 409, "passkey_already_configured"),
        error.InvalidCredentialLabel,
        error.InvalidTransports,
        error.CredentialAlreadyRegistered,
        => try jsonError(output, 400, "invalid_passkey_response"),
        error.TooManyAuthChallenges => try jsonError(output, 429, "try_again_later"),
        else => try jsonError(output, 500, "internal_error"),
    }
}

fn textError(output: *std.Io.Writer, status: u16, body: []const u8) !void {
    try response.write(
        output,
        status,
        "text/plain; charset=utf-8",
        "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n",
        body,
    );
}

fn jsonError(
    output: *std.Io.Writer,
    status: u16,
    code: []const u8,
) !void {
    var body_buffer: [160]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buffer, "{{\"error\":\"{s}\"}}\n", .{code});
    try response.write(
        output,
        status,
        "application/json; charset=utf-8",
        json_headers,
        body,
    );
}

fn methodNotAllowed(output: *std.Io.Writer, allow: []const u8) !void {
    var headers_buffer: [256]u8 = undefined;
    const headers = try std.fmt.bufPrint(
        &headers_buffer,
        "{s}Allow: {s}\r\n",
        .{ json_headers, allow },
    );
    try response.write(
        output,
        405,
        "text/plain; charset=utf-8",
        headers,
        "method not allowed\n",
    );
}
