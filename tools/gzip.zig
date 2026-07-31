const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.InvalidArguments;
    const source = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        allocator,
        .limited(128 * 1024),
    );

    var output_buffer: [16 * 1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    var history: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip = try std.compress.flate.Compress.init(
        &output.interface,
        &history,
        .gzip,
        .default,
    );
    try gzip.writer.writeAll(source);
    try gzip.finish();
    try output.interface.flush();
}
