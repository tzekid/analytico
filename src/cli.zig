const std = @import("std");
const domain = @import("domain.zig");
const meta = @import("store/meta.zig");
const events = @import("store/events.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    args: []const []const u8,
) !bool {
    if (args.len == 3 and std.mem.eql(u8, args[1], "init")) {
        try initialize(allocator, io, output, args[2]);
        return true;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "site")) {
        try siteCommand(allocator, io, output, args);
        return true;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "goal")) {
        try goalCommand(allocator, io, output, args);
        return true;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "funnel")) {
        try funnelCommand(allocator, io, output, args);
        return true;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "event")) {
        try eventCommand(allocator, output, io, args);
        return true;
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "doctor")) {
        try doctor(allocator, output, args[2]);
        return true;
    }
    if (args.len == 7 and std.mem.eql(u8, args[1], "pseudonym")) {
        const key = try domain.parseKeyHex(args[2]);
        const visitor = try domain.deriveVisitorDayId(
            key,
            args[3],
            args[4],
            args[5],
            args[6],
        );
        try output.print("{s}\n", .{std.fmt.bytesToHex(visitor, .lower)});
        return true;
    }
    return false;
}

pub fn writeUsage(output: *std.Io.Writer) !void {
    try output.writeAll(
        \\  analytico init <directory>
        \\  analytico site add <directory> <slug> <name> <origin>
        \\  analytico site list <directory>
        \\  analytico site disable <directory> <slug>
        \\  analytico site origin-add <directory> <slug> <origin>
        \\  analytico site property-add <directory> <slug> <property>
        \\  analytico site delete <directory> <slug> --confirm <slug>
        \\  analytico goal add <directory> <site> <name> <event|path|prefix> <value>
        \\  analytico goal list <directory> <site>
        \\  analytico goal delete <directory> <site> <name> --confirm <name>
        \\  analytico funnel add <directory> <site> <name> <kind=value> <kind=value> [...]
        \\  analytico funnel show <directory> <site> <name>
        \\  analytico funnel delete <directory> <site> <name> --confirm <name>
        \\  analytico event add <directory> <site> <event> <path> <micros> <date> <ip> <browser> <os> <device>
        \\  analytico doctor <directory>
        \\  analytico pseudonym <64-hex-key> <site-id> <date> <ip> <coarse-client>
        \\
    );
}

fn initialize(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const paths = try Paths.init(allocator, directory);

    const key_created = createKey(io, paths.key) catch |err| switch (err) {
        error.PathAlreadyExists => false,
        else => return err,
    };

    var metadata = try meta.Store.open(allocator, paths.meta);
    defer metadata.deinit();
    try metadata.migrate();
    var event_store = try events.Store.open(allocator, paths.events);
    defer event_store.deinit();
    try event_store.migrate();

    try output.print(
        "initialized metadata=v{d} events=v{d} key={s}\n",
        .{
            try metadata.migrationVersion(),
            try event_store.migrationVersion(),
            if (key_created) "created" else "existing",
        },
    );
}

fn siteCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    args: []const []const u8,
) !void {
    if (args.len < 4) return error.InvalidArguments;
    const paths = try Paths.init(allocator, args[3]);
    var store = try meta.Store.open(allocator, paths.meta);
    defer store.deinit();
    try store.migrate();

    if (std.mem.eql(u8, args[2], "add") and args.len == 7) {
        try domain.validateSlug(args[4]);
        try domain.validateName(args[5], 120);
        const origin = try domain.normalizeOrigin(allocator, args[6]);
        const id = try domain.randomUuid(io);
        try store.addSite(&id, args[4], args[5], origin, try nowMicros());
        try output.print("site added {s} {s}\n", .{ args[4], id });
        return;
    }
    if (std.mem.eql(u8, args[2], "list") and args.len == 4) {
        const sites = try store.listSites(allocator);
        for (sites) |site| {
            try output.print("{s}\t{s}\t{s}\t{s}\n", .{
                site.slug,
                site.id,
                if (site.disabled) "disabled" else "active",
                site.name,
            });
        }
        return;
    }
    if (std.mem.eql(u8, args[2], "disable") and args.len == 5) {
        try store.disableSite(args[4], try nowMicros());
        try output.print("site disabled {s}\n", .{args[4]});
        return;
    }
    if (std.mem.eql(u8, args[2], "origin-add") and args.len == 6) {
        const origin = try domain.normalizeOrigin(allocator, args[5]);
        try store.addOrigin(allocator, args[4], origin);
        try output.print("origin added {s} {s}\n", .{ args[4], origin });
        return;
    }
    if (std.mem.eql(u8, args[2], "property-add") and args.len == 6) {
        try store.addProperty(allocator, args[4], args[5]);
        try output.print("property added {s} {s}\n", .{ args[4], args[5] });
        return;
    }
    if (std.mem.eql(u8, args[2], "delete") and args.len == 7 and
        std.mem.eql(u8, args[5], "--confirm") and
        std.mem.eql(u8, args[4], args[6]))
    {
        try store.deleteSite(args[4]);
        try output.print("site deleted {s}\n", .{args[4]});
        return;
    }
    return error.InvalidArguments;
}

fn goalCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    args: []const []const u8,
) !void {
    if (args.len < 5) return error.InvalidArguments;
    const paths = try Paths.init(allocator, args[3]);
    var store = try meta.Store.open(allocator, paths.meta);
    defer store.deinit();
    try store.migrate();

    if (std.mem.eql(u8, args[2], "add") and args.len == 8) {
        const id = try domain.randomUuid(io);
        const kind = try domain.MatchKind.parse(args[6]);
        try store.addGoal(
            allocator,
            &id,
            args[4],
            args[5],
            kind,
            args[7],
            try nowMicros(),
        );
        try output.print("goal added {s} {s}\n", .{ args[5], id });
        return;
    }
    if (std.mem.eql(u8, args[2], "list") and args.len == 5) {
        const goals = try store.listGoals(allocator, args[4]);
        for (goals) |goal| {
            try output.print("{s}\t{s}\t{s}\t{s}\n", .{
                goal.name,
                @tagName(goal.match_kind),
                goal.match_value,
                goal.id,
            });
        }
        return;
    }
    if (std.mem.eql(u8, args[2], "delete") and args.len == 8 and
        std.mem.eql(u8, args[6], "--confirm") and
        std.mem.eql(u8, args[5], args[7]))
    {
        try store.deleteGoal(allocator, args[4], args[5]);
        try output.print("goal deleted {s}\n", .{args[5]});
        return;
    }
    return error.InvalidArguments;
}

fn funnelCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    args: []const []const u8,
) !void {
    if (args.len < 6) return error.InvalidArguments;
    const paths = try Paths.init(allocator, args[3]);
    var store = try meta.Store.open(allocator, paths.meta);
    defer store.deinit();
    try store.migrate();

    if (std.mem.eql(u8, args[2], "add") and args.len >= 8 and args.len <= 14) {
        var steps: std.ArrayList(meta.FunnelStepInput) = .empty;
        for (args[6..]) |encoded| {
            const kind_text, const value = std.mem.cutScalar(u8, encoded, '=') orelse
                return error.InvalidFunnelStep;
            try steps.append(allocator, .{
                .name = value,
                .match_kind = try domain.MatchKind.parse(kind_text),
                .match_value = value,
            });
        }
        const id = try domain.randomUuid(io);
        try store.addFunnel(
            allocator,
            &id,
            args[4],
            args[5],
            steps.items,
            try nowMicros(),
        );
        try output.print("funnel added {s} {s}\n", .{ args[5], id });
        return;
    }
    if (std.mem.eql(u8, args[2], "show") and args.len == 6) {
        const steps = try store.funnelSteps(allocator, args[4], args[5]);
        for (steps) |step| {
            try output.print("{d}\t{s}\t{s}\t{s}\n", .{
                step.index,
                step.name,
                @tagName(step.match_kind),
                step.match_value,
            });
        }
        return;
    }
    if (std.mem.eql(u8, args[2], "delete") and args.len == 8 and
        std.mem.eql(u8, args[6], "--confirm") and
        std.mem.eql(u8, args[5], args[7]))
    {
        try store.deleteFunnel(allocator, args[4], args[5]);
        try output.print("funnel deleted {s}\n", .{args[5]});
        return;
    }
    return error.InvalidArguments;
}

fn eventCommand(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    io: std.Io,
    args: []const []const u8,
) !void {
    if (!std.mem.eql(u8, args[2], "add") or args.len != 13) {
        return error.InvalidArguments;
    }
    const paths = try Paths.init(allocator, args[3]);
    const key = try readKey(allocator, io, paths.key);
    var metadata = try meta.Store.open(allocator, paths.meta);
    defer metadata.deinit();
    try metadata.migrate();
    const site_id = try metadata.siteIdBySlug(allocator, args[4]);

    try domain.validateIdentifier(args[5]);
    const path = try domain.normalizePath(args[6]);
    const timestamp = std.fmt.parseInt(i64, args[7], 10) catch
        return error.InvalidTimestamp;
    try domain.validateDate(args[8]);
    try domain.validateIdentifier(args[10]);
    try domain.validateIdentifier(args[11]);
    try domain.validateIdentifier(args[12]);
    const coarse = try std.fmt.allocPrint(
        allocator,
        "{s}|{s}|{s}",
        .{ args[10], args[11], args[12] },
    );
    const visitor = try domain.deriveVisitorDayId(
        key,
        site_id,
        args[8],
        args[9],
        coarse,
    );
    const id = try domain.randomUuid(io);

    var event_store = try events.Store.open(allocator, paths.events);
    defer event_store.deinit();
    try event_store.migrate();
    try event_store.insert(.{
        .event_id = &id,
        .site_id = site_id,
        .received_at_utc_micros = timestamp,
        .received_date_utc = args[8],
        .kind = if (std.mem.eql(u8, args[5], "pageview")) 1 else 2,
        .event_name = args[5],
        .path = path,
        .visitor_day_id = visitor,
        .browser_family = args[10],
        .os_family = args[11],
        .device_category = args[12],
    });
    try event_store.checkpoint();
    try output.print("event committed {s}\n", .{id});
}

fn doctor(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    directory: []const u8,
) !void {
    const paths = try Paths.init(allocator, directory);
    var metadata = try meta.Store.open(allocator, paths.meta);
    defer metadata.deinit();
    try metadata.migrate();
    var event_store = try events.Store.open(allocator, paths.events);
    defer event_store.deinit();
    try event_store.migrate();
    const counts = try metadata.counts();
    try output.print(
        "ok metadata=v{d} events=v{d} sites={d} goals={d} funnels={d} stored_events={d}\n",
        .{
            try metadata.migrationVersion(),
            try event_store.migrationVersion(),
            counts.sites,
            counts.goals,
            counts.funnels,
            try event_store.eventCount(),
        },
    );
}

const Paths = struct {
    meta: []const u8,
    events: []const u8,
    key: []const u8,

    fn init(allocator: std.mem.Allocator, directory: []const u8) !Paths {
        return .{
            .meta = try std.fs.path.join(allocator, &.{ directory, "meta.db" }),
            .events = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" }),
            .key = try std.fs.path.join(allocator, &.{ directory, "visitor.key" }),
        };
    }
};

fn createKey(io: std.Io, path: []const u8) !bool {
    var key: [32]u8 = undefined;
    try io.randomSecure(&key);
    defer @memset(&key, 0);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = &key,
        .flags = .{
            .exclusive = true,
            .permissions = @fromBackingInt(@intCast(0o600)),
        },
    });
    return true;
}

fn readKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![32]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(33),
    );
    defer std.crypto.secureZero(u8, bytes);
    if (bytes.len != 32) return error.InvalidKeyFile;
    return bytes[0..32].*;
}

fn nowMicros() !i64 {
    var timestamp: std.os.linux.timespec = undefined;
    const result = std.os.linux.clock_gettime(.REALTIME, &timestamp);
    if (std.os.linux.errno(result) != .SUCCESS or timestamp.sec < 0) {
        return error.ClockUnavailable;
    }
    const seconds = std.math.mul(i64, timestamp.sec, 1_000_000) catch
        return error.ClockUnavailable;
    return std.math.add(i64, seconds, @divTrunc(timestamp.nsec, 1_000)) catch
        return error.ClockUnavailable;
}
