const std = @import("std");
const analytico = @import("root.zig");
const cli = @import("cli.zig");
const probe = @import("m0/probe.zig");
const m2_probe = @import("m2/probe.zig");
const m3_probe = @import("m3/probe.zig");
const m4_probe = @import("m4/probe.zig");

pub fn main(init: std.process.Init) !void {
    const ignore_file_limit: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.XFSZ, &ignore_file_limit, null);
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const output = &writer.interface;
    defer output.flush() catch {};

    if (args.len == 4 and
        std.mem.eql(u8, args[1], "m0") and
        std.mem.eql(u8, args[2], "probe"))
    {
        try probe.run(allocator, output, args[3]);
        return;
    }
    if (args.len == 3 and
        std.mem.eql(u8, args[1], "m2") and
        std.mem.eql(u8, args[2], "rate-probe"))
    {
        try m2_probe.rateTable(output);
        return;
    }
    if (args.len == 6 and
        std.mem.eql(u8, args[1], "m2") and
        std.mem.eql(u8, args[2], "v2-inspect"))
    {
        try m2_probe.inspectV2(allocator, output, args[3], args[4], args[5]);
        return;
    }
    if (args.len == 6 and
        std.mem.eql(u8, args[1], "m2") and
        std.mem.eql(u8, args[2], "session-timeline"))
    {
        try m2_probe.sessionTimeline(allocator, output, args[3], args[4], args[5]);
        return;
    }
    if (args.len == 4 and
        std.mem.eql(u8, args[1], "m2") and
        std.mem.eql(u8, args[2], "identity-links"))
    {
        try m2_probe.identityLinkCount(allocator, output, args[3]);
        return;
    }
    if (args.len == 5 and
        std.mem.eql(u8, args[1], "m3") and
        std.mem.eql(u8, args[2], "seed"))
    {
        try m3_probe.seed(allocator, output, args[3], args[4]);
        return;
    }
    if (args.len == 5 and
        std.mem.eql(u8, args[1], "m3") and
        std.mem.eql(u8, args[2], "million"))
    {
        try m3_probe.million(allocator, output, args[3], args[4]);
        return;
    }
    if (args.len == 4 and
        std.mem.eql(u8, args[1], "m3") and
        std.mem.eql(u8, args[2], "timeout"))
    {
        try m3_probe.timeout(allocator, output, args[3]);
        return;
    }
    if (args.len == 4 and
        std.mem.eql(u8, args[1], "m4") and
        std.mem.eql(u8, args[2], "legacy-million"))
    {
        try m4_probe.legacyMillion(allocator, output, args[3]);
        return;
    }
    if (args.len == 5 and
        std.mem.eql(u8, args[1], "m4") and
        std.mem.eql(u8, args[2], "poison-newer"))
    {
        try m4_probe.poisonNewer(allocator, output, args[3], args[4]);
        return;
    }
    if (args.len == 4 and
        std.mem.eql(u8, args[1], "m3") and
        std.mem.eql(u8, args[2], "legacy-create"))
    {
        try m3_probe.legacyCreate(allocator, output, args[3]);
        return;
    }
    if (args.len == 4 and
        std.mem.eql(u8, args[1], "m3") and
        std.mem.eql(u8, args[2], "legacy-verify"))
    {
        try m3_probe.legacyVerify(allocator, output, args[3]);
        return;
    }
    if (args.len == 4 and
        std.mem.eql(u8, args[1], "m0") and
        std.mem.eql(u8, args[2], "verify"))
    {
        try probe.verify(allocator, output, args[3]);
        return;
    }
    if (args.len == 4 and
        std.mem.eql(u8, args[1], "m0") and
        std.mem.eql(u8, args[2], "benchmark"))
    {
        try probe.benchmark(allocator, init.io, output, args[3]);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "version")) {
        try output.print("analytico {s}\n", .{analytico.version});
        return;
    }
    if (try cli.run(allocator, init.gpa, init.io, output, args)) return;

    try output.writeAll(
        \\Usage:
        \\  analytico version
        \\  analytico m0 probe <directory>
        \\  analytico m0 verify <directory>
        \\  analytico m0 benchmark <directory>
        \\  analytico m2 rate-probe
        \\  analytico m2 v2-inspect <directory> <site-id> <event-id>
        \\  analytico m2 session-timeline <directory> <site-id> <session-id>
        \\  analytico m2 identity-links <directory>
        \\  analytico m3 seed <directory> <site-id>
        \\  analytico m3 million <directory> <site-id>
        \\  analytico m3 timeout <directory>
        \\  analytico m3 legacy-create <directory>
        \\  analytico m3 legacy-verify <directory>
        \\  analytico m4 legacy-million <directory>
        \\  analytico m4 poison-newer <directory> <metadata|events>
        \\
    );
    try cli.writeUsage(output);
}
