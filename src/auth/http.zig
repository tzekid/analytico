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

pub fn handle(
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
    return false;
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

fn authError(output: *std.Io.Writer, err: anyerror) !void {
    switch (err) {
        error.InvalidBootstrap, error.InvalidChallenge => try jsonError(output, 401, "invalid_setup_link"),
        error.AuthAlreadyConfigured => try jsonError(output, 409, "passkey_already_configured"),
        error.InvalidPasskeyResponse,
        error.InvalidCredentialLabel,
        error.InvalidTransports,
        error.CredentialAlreadyRegistered,
        => try jsonError(output, 400, "invalid_passkey_response"),
        error.TooManyAuthChallenges => try jsonError(output, 429, "try_again_later"),
        else => try jsonError(output, 500, "internal_error"),
    }
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
