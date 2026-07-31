pub const version = "0.0.0";

comptime {
    _ = @import("domain.zig");
    _ = @import("cli.zig");
    _ = @import("store/duckdb.zig");
    _ = @import("store/events.zig");
    _ = @import("store/meta.zig");
    _ = @import("m0/probe.zig");
}
