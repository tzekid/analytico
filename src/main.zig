const std = @import("std");
const analytico = @import("root.zig");

pub fn main(init: std.process.Init) !void {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const output = &writer.interface;
    defer output.flush() catch {};

    try output.print(
        "analytico {s}: specification scaffold; MVP implementation has not started\n",
        .{analytico.version},
    );
}
