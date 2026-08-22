const std = @import("std");
const ops = @import("../ops.zig");
const meta = @import("../store/meta.zig");
const service = @import("service.zig");
const store_mod = @import("store.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    args: []const []const u8,
) !bool {
    if (args.len < 3 or !std.mem.eql(u8, args[1], "auth")) return false;
    if (std.mem.eql(u8, args[2], "configure") and args.len == 5) {
        try configure(allocator, output, args[3], args[4]);
        return true;
    }
    if (std.mem.eql(u8, args[2], "status") and args.len == 4) {
        try status(allocator, output, args[3]);
        return true;
    }
    if (std.mem.eql(u8, args[2], "bootstrap") and
        (args.len == 4 or args.len == 6))
    {
        const ttl = if (args.len == 4)
            service.default_bootstrap_seconds
        else blk: {
            if (!std.mem.eql(u8, args[4], "--ttl")) {
                return error.InvalidAuthArguments;
            }
            break :blk try parseDuration(args[5]);
        };
        try bootstrap(allocator, io, output, args[3], ttl);
        return true;
    }
    if (std.mem.eql(u8, args[2], "reset") and args.len == 6 and
        std.mem.eql(u8, args[5], "--confirm"))
    {
        try reset(allocator, io, output, args[3], args[4]);
        return true;
    }
    return error.InvalidAuthArguments;
}

pub fn writeUsage(output: *std.Io.Writer) !void {
    try output.writeAll(
        \\  analytico auth configure <directory> <dashboard-origin>
        \\  analytico auth status <directory>
        \\  analytico auth bootstrap <directory> [--ttl 10m]
        \\  analytico auth reset <directory> <new-backup-directory> --confirm
        \\
    );
}

fn configure(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
    raw_origin: []const u8,
) !void {
    const policy = try service.derivePolicy(allocator, raw_origin);
    defer policy.deinit(allocator);
    var metadata = try openMetadata(allocator, directory);
    defer metadata.deinit();
    const auth_store = store_mod.Store{ .metadata = &metadata };
    try auth_store.configure(
        allocator,
        policy.origin,
        policy.rp_id,
        try service.nowSeconds(),
    );
    try output.print("auth configured origin={s} rp_id={s}\n", .{
        policy.origin,
        policy.rp_id,
    });
}

fn status(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
) !void {
    var metadata = try openMetadata(allocator, directory);
    defer metadata.deinit();
    const auth_store = store_mod.Store{ .metadata = &metadata };
    const policy = try auth_store.policy(allocator);
    defer if (policy) |value| value.deinit(allocator);
    const now = try service.nowSeconds();
    const credentials = try auth_store.activeCredentialCount();
    try output.print(
        "Analytico passkey authentication\n" ++
            "configured={s} credentials={d} active_sessions={d} " ++
            "bootstrap_active={s}\norigin={s}\nrp_id={s}\n",
        .{
            if (credentials > 0) "yes" else "no",
            credentials,
            try auth_store.activeSessionCount(now),
            if (try auth_store.bootstrapActive(now)) "yes" else "no",
            if (policy) |value| value.origin else "not-configured",
            if (policy) |value| value.rp_id else "not-configured",
        },
    );
}

fn bootstrap(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
    ttl: u32,
) !void {
    var metadata = try openMetadata(allocator, directory);
    defer metadata.deinit();
    const auth_store = store_mod.Store{ .metadata = &metadata };
    const policy = (try auth_store.policy(allocator)) orelse
        return error.AuthPolicyMissing;
    defer policy.deinit(allocator);
    const value = try service.createBootstrap(.{
        .io = io,
        .allocator = allocator,
        .store = auth_store,
        .origin = policy.origin,
        .rp_id = policy.rp_id,
    }, ttl);
    defer value.deinit(allocator);
    try output.print(
        "Open this one-use setup link before it expires:\n{s}\n" ++
            "expires_at_utc_seconds={d}\n",
        .{ value.setup_url, value.expires_at },
    );
}

fn reset(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
    backup_directory: []const u8,
) !void {
    try ops.backup(allocator, io, output, directory, backup_directory);
    var metadata = try openMetadata(allocator, directory);
    defer metadata.deinit();
    const auth_store = store_mod.Store{ .metadata = &metadata };
    const policy = (try auth_store.policy(allocator)) orelse
        return error.AuthPolicyMissing;
    defer policy.deinit(allocator);
    try service.reset(.{
        .io = io,
        .allocator = allocator,
        .store = auth_store,
        .origin = policy.origin,
        .rp_id = policy.rp_id,
    });
    try output.print(
        "passkey authentication reset verified_backup={s}\n" ++
            "next=analytico auth bootstrap {s} --ttl 10m\n",
        .{ backup_directory, directory },
    );
}

fn openMetadata(
    allocator: std.mem.Allocator,
    directory: []const u8,
) !meta.Store {
    const path = try std.fs.path.join(allocator, &.{ directory, "meta.db" });
    var metadata = try meta.Store.open(allocator, path);
    errdefer metadata.deinit();
    try metadata.requireCurrent();
    return metadata;
}

fn parseDuration(value: []const u8) !u32 {
    if (value.len == 0) return error.InvalidBootstrapTtl;
    const suffix = value[value.len - 1];
    const multiplier: u32 = switch (suffix) {
        's' => 1,
        'm' => 60,
        'h' => 60 * 60,
        else => 1,
    };
    const digits = if (std.ascii.isDigit(suffix)) value else value[0 .. value.len - 1];
    const amount = std.fmt.parseInt(u32, digits, 10) catch
        return error.InvalidBootstrapTtl;
    const seconds = std.math.mul(u32, amount, multiplier) catch
        return error.InvalidBootstrapTtl;
    if (seconds == 0 or seconds > service.max_bootstrap_seconds) {
        return error.InvalidBootstrapTtl;
    }
    return seconds;
}
