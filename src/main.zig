const std = @import("std");
const analytico = @import("root.zig");
const cli = @import("cli.zig");
const probe = @import("m0/probe.zig");
const m2_probe = @import("m2/probe.zig");
const m3_probe = @import("m3/probe.zig");

pub fn main(init: std.process.Init) !void {
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
        \\  analytico m3 seed <directory> <site-id>
        \\  analytico m3 million <directory> <site-id>
        \\  analytico m3 timeout <directory>
        \\  analytico m3 legacy-create <directory>
        \\  analytico m3 legacy-verify <directory>
        \\
    );
    try cli.writeUsage(output);
}
