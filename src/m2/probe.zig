const std = @import("std");
const rate_limit = @import("../http/rate_limit.zig");

pub fn rateTable(output: *std.Io.Writer) !void {
    var limiter = rate_limit.Limiter{};
    var accepted: usize = 0;
    var rejected: usize = 0;
    for (0..100_000) |index| {
        if (limiter.allow(@intCast(index + 1), 1_800_000_000)) {
            accepted += 1;
        } else {
            rejected += 1;
        }
    }
    if (accepted != rate_limit.max_buckets or
        rejected != 100_000 - rate_limit.max_buckets)
    {
        return error.RateTableInvariantFailed;
    }
    try output.print(
        "{{\"attempted\":100000,\"capacity\":{d},\"accepted\":{d},\"rejected\":{d}}}\n",
        .{ rate_limit.max_buckets, accepted, rejected },
    );
}
