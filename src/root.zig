pub const version = "0.0.0";

comptime {
    _ = @import("store/duckdb.zig");
    _ = @import("store/meta.zig");
    _ = @import("m0/probe.zig");
}
