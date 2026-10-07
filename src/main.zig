const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    @import("net.zig").init(init.gpa, init.io);
    defer @import("net.zig").deinit();
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
    _ = @import("web/html.zig");
    _ = @import("web/data.zig");
    _ = @import("web/chart.zig");
    _ = @import("web/manage.zig");
    _ = @import("web/analyze.zig");
    _ = @import("web/ai.zig");
    _ = @import("web/mail.zig");
    _ = @import("web/oidc.zig");
    _ = @import("web/signin.zig");
    _ = @import("web/passkeys.zig");
    _ = @import("web/auth.zig");
    _ = @import("web/mcp.zig");
    _ = @import("web/rollups.zig");
    _ = @import("web/heatmaps.zig");
    _ = @import("geo.zig");
    _ = @import("assets.zig");
    _ = @import("web/catalog.zig");
    _ = @import("web/push.zig");
}
