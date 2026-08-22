pub const version = @import("version.zig").value;

comptime {
    _ = @import("domain.zig");
    _ = @import("version.zig");
    _ = @import("timezone.zig");
    _ = @import("report.zig");
    _ = @import("ops.zig");
    _ = @import("cli.zig");
    _ = @import("store/duckdb.zig");
    _ = @import("store/events.zig");
    _ = @import("store/meta.zig");
    _ = @import("store/reports.zig");
    _ = @import("auth/passkeys.zig");
    _ = @import("auth/store.zig");
    _ = @import("auth/service.zig");
    _ = @import("auth/cli.zig");
    _ = @import("auth/render.zig");
    _ = @import("auth/http.zig");
    _ = @import("http/request.zig");
    _ = @import("http/response.zig");
    _ = @import("http/rate_limit.zig");
    _ = @import("http/classify.zig");
    _ = @import("http/collect.zig");
    _ = @import("http/server.zig");
    _ = @import("m0/probe.zig");
    _ = @import("m2/probe.zig");
    _ = @import("m3/probe.zig");
    _ = @import("m4/probe.zig");
}
