const std = @import("std");
const duckdb = @import("duckdb.zig");

const State = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    timed_out: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub const Budget = struct {
    timeout_ms: u32,
    started_nanos: ?i128,

    pub fn init(timeout_ms: u32) Budget {
        return .{
            .timeout_ms = timeout_ms,
            .started_nanos = monotonicNanos(),
        };
    }

    pub fn execute(
        self: Budget,
        database: *duckdb.Database,
        statement: *duckdb.Statement,
    ) !duckdb.Result {
        const started = self.started_nanos orelse return error.ReportTimeout;
        const now = monotonicNanos() orelse return error.ReportTimeout;
        const timeout_nanos = @as(i128, self.timeout_ms) * std.time.ns_per_ms;
        const remaining = timeout_nanos - (now - started);
        if (remaining <= 0) return error.ReportTimeout;
        const remaining_ms: u32 = @intCast(@divTrunc(
            remaining + std.time.ns_per_ms - 1,
            std.time.ns_per_ms,
        ));
        return deadlineExecute(database, statement, remaining_ms);
    }
};

pub fn execute(
    database: *duckdb.Database,
    statement: *duckdb.Statement,
    timeout_ms: u32,
) !duckdb.Result {
    return deadlineExecute(database, statement, timeout_ms);
}

fn deadlineExecute(
    database: *duckdb.Database,
    statement: *duckdb.Statement,
    timeout_ms: u32,
) !duckdb.Result {
    var state = State{};
    const thread = try std.Thread.spawn(
        .{ .stack_size = 1024 * 1024 },
        watchdog,
        .{ database, &state, timeout_ms },
    );
    var result = statement.execute() catch |err| {
        state.done.store(true, .release);
        thread.join();
        if (state.timed_out.load(.acquire)) return error.ReportTimeout;
        return err;
    };
    state.done.store(true, .release);
    thread.join();
    if (state.timed_out.load(.acquire)) {
        result.deinit();
        return error.ReportTimeout;
    }
    return result;
}

fn watchdog(
    database: *duckdb.Database,
    state: *State,
    timeout_ms: u32,
) void {
    const pause: std.os.linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
    const started = monotonicNanos() orelse {
        state.timed_out.store(true, .release);
        database.interrupt();
        return;
    };
    const timeout_nanos = @as(i128, timeout_ms) * std.time.ns_per_ms;
    while (true) {
        if (state.done.load(.acquire)) return;
        _ = std.os.linux.nanosleep(&pause, null);
        const now = monotonicNanos() orelse break;
        if (now - started >= timeout_nanos) break;
    }
    if (!state.done.load(.acquire)) {
        state.timed_out.store(true, .release);
        database.interrupt();
    }
}

fn monotonicNanos() ?i128 {
    var timestamp: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(.MONOTONIC, &timestamp) != 0) return null;
    return @as(i128, timestamp.sec) * std.time.ns_per_s + timestamp.nsec;
}
