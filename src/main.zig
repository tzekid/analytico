const std = @import("std");
const analytico = @import("root.zig");
const probe = @import("m0/probe.zig");

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

    try output.writeAll(
        \\Usage:
        \\  analytico version
        \\  analytico m0 probe <directory>
        \\  analytico m0 verify <directory>
        \\  analytico m0 benchmark <directory>
        \\
    );
}
