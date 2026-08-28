const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var buffer: [16 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    defer stdout.interface.flush() catch {};
    cli.run(allocator, init.gpa, init.io, &stdout.interface, args) catch |err| {
        var err_buffer: [1024]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(init.io, &err_buffer);
        try stderr.interface.print("analytico: {s}\n", .{@errorName(err)});
        try stderr.interface.flush();
        try stdout.interface.flush();
        std.process.exit(1);
    };
}

test {
    _ = @import("domain.zig");
    _ = @import("db.zig");
}
