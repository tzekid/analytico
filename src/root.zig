pub const version = "0.0.0";

comptime {
    _ = @import("domain.zig");
    _ = @import("cli.zig");
    _ = @import("store/duckdb.zig");
    _ = @import("store/events.zig");
    _ = @import("store/meta.zig");
    _ = @import("http/request.zig");
    _ = @import("http/response.zig");
    _ = @import("http/rate_limit.zig");
    _ = @import("http/classify.zig");
    _ = @import("http/collect.zig");
    _ = @import("http/server.zig");
    _ = @import("m0/probe.zig");
    _ = @import("m2/probe.zig");
}
