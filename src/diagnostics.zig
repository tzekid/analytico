const std = @import("std");
const property = @import("property.zig");

pub const capacity: usize = 200;
pub const maximum_properties: usize = 16;

pub const Protocol = enum {
    v1,
    v2,
    pixel,
};

pub const Category = enum {
    unknown,
    pageview,
    custom,
    engagement,
    identify,
};

pub const Outcome = enum {
    accepted,
    rejected,
    duplicate,
    store_failure,
};

pub const RejectionCode = enum {
    none,
    site_unknown,
    site_disabled,
    origin_missing,
    origin_not_allowed,
    protocol_unsupported,
    payload_too_large,
    payload_invalid,
    event_invalid,
    event_id_conflict,
    property_invalid,
    property_type_conflict,
    identity_invalid,
    identity_conflict,
    session_invalid,
    timestamp_invalid,
    value_invalid,
    rate_limited,
    store_unavailable,
    disk_full,
};

pub const ScalarType = enum {
    string,
    integer,
    decimal,
    boolean,
    null,
};

pub fn BoundedText(comptime maximum: usize) type {
    return struct {
        bytes: [maximum]u8 = undefined,
        len: u16 = 0,

        const Self = @This();

        pub fn set(self: *Self, value: []const u8) bool {
            if (value.len > maximum) return false;
            @memcpy(self.bytes[0..value.len], value);
            self.len = @intCast(value.len);
            return true;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

pub const Property = struct {
    key: BoundedText(64) = .{},
    scalar_type: ScalarType = .null,
};

pub const Summary = struct {
    correlation: u64 = 0,
    received_at_utc_micros: i64 = 0,
    site_id: BoundedText(36) = .{},
    protocol: Protocol = .v1,
    category: Category = .unknown,
    outcome: Outcome = .rejected,
    rejection_code: RejectionCode = .payload_invalid,
    subject: BoundedText(1024) = .{},
    origin_host: BoundedText(253) = .{},
    properties: [maximum_properties]Property = @splat(.{}),
    property_count: u8 = 0,

    pub fn init(protocol: Protocol, received_at_utc_micros: i64) Summary {
        return .{
            .protocol = protocol,
            .received_at_utc_micros = received_at_utc_micros,
        };
    }

    pub fn setSite(self: *Summary, site_id: []const u8) void {
        std.debug.assert(self.site_id.set(site_id));
    }

    pub fn setOrigin(self: *Summary, normalized_origin: []const u8) void {
        const uri = std.Uri.parse(normalized_origin) catch return;
        const host_component = uri.host orelse return;
        var host_buffer: [253]u8 = undefined;
        const host = host_component.toRaw(&host_buffer) catch return;
        _ = self.origin_host.set(host);
    }

    pub fn setEvent(self: *Summary, kind: u8, path: []const u8, name: []const u8) void {
        self.category = switch (kind) {
            1 => .pageview,
            2 => .custom,
            3 => .engagement,
            4 => .identify,
            else => .unknown,
        };
        const subject = if (self.category == .pageview or self.category == .engagement)
            path
        else
            name;
        std.debug.assert(self.subject.set(subject));
    }

    pub fn setProperties(self: *Summary, value: ?std.json.Value) void {
        const object = switch (value orelse return) {
            .object => |object| object,
            else => return,
        };
        if (object.count() > maximum_properties) return;
        var iterator = object.iterator();
        while (iterator.next()) |entry| {
            const scalar_type: ScalarType = switch (entry.value_ptr.*) {
                .string => .string,
                .integer => .integer,
                .number_string => |number| switch (property.numberType(number) catch return) {
                    .integer => .integer,
                    .decimal => .decimal,
                    else => return,
                },
                .bool => .boolean,
                .null => .null,
                else => return,
            };
            const index: usize = self.property_count;
            if (!self.properties[index].key.set(entry.key_ptr.*)) return;
            self.properties[index].scalar_type = scalar_type;
            self.property_count += 1;
        }
        var index: usize = 1;
        while (index < self.property_count) : (index += 1) {
            const value_to_place = self.properties[index];
            var position = index;
            while (position > 0 and std.mem.order(
                u8,
                value_to_place.key.slice(),
                self.properties[position - 1].key.slice(),
            ) == .lt) : (position -= 1) {
                self.properties[position] = self.properties[position - 1];
            }
            self.properties[position] = value_to_place;
        }
    }
};

pub const Counts = struct {
    accepted: usize = 0,
    rejected: usize = 0,
    duplicates: usize = 0,
    store_failures: usize = 0,

    fn add(self: *Counts, outcome: Outcome) void {
        switch (outcome) {
            .accepted => self.accepted += 1,
            .rejected => self.rejected += 1,
            .duplicate => self.duplicates += 1,
            .store_failure => self.store_failures += 1,
        }
    }
};

pub const Snapshot = struct {
    summaries: []Summary,
    counts: Counts,
};

pub const Stats = struct {
    retained: usize,
    overwritten: u64,
    counts: Counts,
};

pub const Ring = struct {
    mutex: std.atomic.Mutex = .unlocked,
    summaries: [capacity]Summary = @splat(.{}),
    len: usize = 0,
    next: usize = 0,
    overwritten: u64 = 0,

    pub fn append(self: *Ring, input: Summary) void {
        self.lock();
        defer self.mutex.unlock();

        var value = input;
        value.correlation = 1;
        for (self.summaries[0..self.len]) |retained| {
            if (std.mem.eql(u8, retained.site_id.slice(), value.site_id.slice())) {
                value.correlation = @max(
                    value.correlation,
                    retained.correlation +| 1,
                );
            }
        }
        self.summaries[self.next] = value;
        self.next = (self.next + 1) % capacity;
        if (self.len < capacity) {
            self.len += 1;
        } else {
            self.overwritten +|= 1;
        }
    }

    pub fn snapshot(
        self: *Ring,
        site_id: []const u8,
        output: []Summary,
    ) Snapshot {
        std.debug.assert(output.len >= capacity);
        if (site_id.len == 0) {
            return .{ .summaries = output[0..0], .counts = .{} };
        }
        self.lock();
        defer self.mutex.unlock();

        var count: usize = 0;
        var counts: Counts = .{};
        var scanned: usize = 0;
        var index = if (self.next == 0) capacity - 1 else self.next - 1;
        while (scanned < self.len) : (scanned += 1) {
            const value = self.summaries[index];
            if (std.mem.eql(u8, value.site_id.slice(), site_id)) {
                output[count] = value;
                count += 1;
                counts.add(value.outcome);
            }
            index = if (index == 0) capacity - 1 else index - 1;
        }
        return .{
            .summaries = output[0..count],
            .counts = counts,
        };
    }

    pub fn stats(self: *Ring) Stats {
        self.lock();
        defer self.mutex.unlock();

        var counts: Counts = .{};
        for (self.summaries[0..self.len]) |value| counts.add(value.outcome);
        return .{
            .retained = self.len,
            .overwritten = self.overwritten,
            .counts = counts,
        };
    }

    fn lock(self: *Ring) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
};

test "fixed ring wraps newest first and filters sites" {
    var ring = Ring{};
    for (0..capacity + 3) |index| {
        var value = Summary.init(.v2, @intCast(index));
        value.setSite(if (index % 2 == 0) "site-a" else "site-b");
        value.outcome = if (index % 4 == 0) .accepted else .rejected;
        ring.append(value);
    }
    var output: [capacity]Summary = undefined;
    const result = ring.snapshot("site-a", &output);
    const stats = ring.stats();
    try std.testing.expectEqual(capacity, stats.retained);
    try std.testing.expectEqual(@as(u64, 3), stats.overwritten);
    try std.testing.expectEqual(@as(i64, capacity + 2), result.summaries[0].received_at_utc_micros);
    for (result.summaries) |value| {
        try std.testing.expectEqualStrings("site-a", value.site_id.slice());
    }
    try std.testing.expectEqual(result.summaries.len, result.counts.accepted +
        result.counts.rejected + result.counts.duplicates + result.counts.store_failures);
}

test "snapshot exposes only selected-site fields" {
    const fields = @typeInfo(Snapshot).@"struct".field_names;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("summaries", fields[0]);
    try std.testing.expectEqualStrings("counts", fields[1]);
    var ring = Ring{};
    ring.append(Summary.init(.v2, 0));
    for (0..7) |index| {
        var value = Summary.init(.v2, @intCast(index + 10));
        value.setSite("site-b");
        value.outcome = if (index == 0) .rejected else .store_failure;
        ring.append(value);
        if (index < 3) {
            var site_a_value = Summary.init(.v1, @intCast(index + 1));
            site_a_value.setSite("site-a");
            site_a_value.outcome = .accepted;
            ring.append(site_a_value);
        }
    }

    var output_a: [capacity]Summary = undefined;
    var output_b: [capacity]Summary = undefined;
    var output_empty: [capacity]Summary = undefined;
    const site_a = ring.snapshot("site-a", &output_a);
    const site_b = ring.snapshot("site-b", &output_b);
    const empty = ring.snapshot("", &output_empty);
    try std.testing.expectEqual(@as(usize, 0), empty.summaries.len);
    try std.testing.expectEqual(@as(usize, 0), empty.counts.accepted);
    try std.testing.expectEqual(@as(usize, 0), empty.counts.rejected);
    try std.testing.expectEqual(@as(usize, 0), empty.counts.duplicates);
    try std.testing.expectEqual(@as(usize, 0), empty.counts.store_failures);
    try std.testing.expectEqual(@as(usize, 3), site_a.summaries.len);
    try std.testing.expectEqual(@as(usize, 3), site_a.counts.accepted);
    try std.testing.expectEqual(@as(usize, 0), site_a.counts.rejected);
    try std.testing.expectEqual(@as(usize, 0), site_a.counts.duplicates);
    try std.testing.expectEqual(@as(usize, 0), site_a.counts.store_failures);
    for (site_a.summaries, 0..) |value, index| {
        try std.testing.expectEqualStrings("site-a", value.site_id.slice());
        try std.testing.expectEqual(Outcome.accepted, value.outcome);
        try std.testing.expectEqual(@as(u64, @intCast(3 - index)), value.correlation);
    }
    try std.testing.expectEqual(@as(usize, 7), site_b.summaries.len);
    try std.testing.expectEqual(@as(usize, 0), site_b.counts.accepted);
    try std.testing.expectEqual(@as(usize, 1), site_b.counts.rejected);
    try std.testing.expectEqual(@as(usize, 0), site_b.counts.duplicates);
    try std.testing.expectEqual(@as(usize, 6), site_b.counts.store_failures);
    for (site_b.summaries, 0..) |value, index| {
        try std.testing.expectEqualStrings("site-b", value.site_id.slice());
        try std.testing.expectEqual(@as(u64, @intCast(7 - index)), value.correlation);
    }
}

test "summary retains only property keys and types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        "{\"z\":\"secret\",\"amount\":1.25,\"count\":14,\"active\":true}",
        .{ .parse_numbers = false },
    );
    var value = Summary.init(.v2, 0);
    value.setProperties(parsed);
    try std.testing.expectEqual(@as(u8, 4), value.property_count);
    try std.testing.expectEqualStrings("active", value.properties[0].key.slice());
    try std.testing.expectEqual(ScalarType.boolean, value.properties[0].scalar_type);
    try std.testing.expectEqualStrings("amount", value.properties[1].key.slice());
    try std.testing.expectEqual(ScalarType.decimal, value.properties[1].scalar_type);
    try std.testing.expectEqualStrings("count", value.properties[2].key.slice());
    try std.testing.expectEqual(ScalarType.integer, value.properties[2].scalar_type);
    try std.testing.expectEqualStrings("z", value.properties[3].key.slice());
    try std.testing.expectEqual(ScalarType.string, value.properties[3].scalar_type);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.asBytes(&value), "secret") == null);
}

test "origin summary retains a host without path or query" {
    var value = Summary.init(.pixel, 0);
    value.setOrigin("https://Disallowed.Example/private/path?token=secret");
    try std.testing.expectEqualStrings("Disallowed.Example", value.origin_host.slice());
    try std.testing.expect(std.mem.indexOf(u8, value.origin_host.slice(), "private") == null);
    try std.testing.expect(std.mem.indexOf(u8, value.origin_host.slice(), "secret") == null);
}

test "terminal consequences remain distinct" {
    var ring = Ring{};
    inline for (.{
        Outcome.accepted,
        Outcome.rejected,
        Outcome.duplicate,
        Outcome.store_failure,
    }) |outcome| {
        var value = Summary.init(.v2, 1);
        value.setSite("site-a");
        value.outcome = outcome;
        ring.append(value);
    }
    var output: [capacity]Summary = undefined;
    const result = ring.snapshot("site-a", &output);
    try std.testing.expectEqual(@as(usize, 1), result.counts.accepted);
    try std.testing.expectEqual(@as(usize, 1), result.counts.rejected);
    try std.testing.expectEqual(@as(usize, 1), result.counts.duplicates);
    try std.testing.expectEqual(@as(usize, 1), result.counts.store_failures);
}

test "ring append and snapshot are synchronized" {
    const Worker = struct {
        ring: *Ring,
        worker: usize,
        start: *std.atomic.Value(bool),
        snapshot_observed: *std.atomic.Value(bool),

        fn run(self: @This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            for (0..500) |index| {
                var value = Summary.init(.v1, @intCast(self.worker * 500 + index));
                value.setSite("shared-site");
                value.outcome = .accepted;
                self.ring.append(value);
                if (index == 0) {
                    while (!self.snapshot_observed.load(.acquire)) {
                        std.atomic.spinLoopHint();
                    }
                }
            }
        }
    };
    const Reader = struct {
        ring: *Ring,
        start: *std.atomic.Value(bool),
        done: *std.atomic.Value(bool),
        observed: *std.atomic.Value(bool),

        fn run(self: @This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            var output: [capacity]Summary = undefined;
            while (!self.done.load(.acquire)) {
                const result = self.ring.snapshot("shared-site", &output);
                std.debug.assert(result.summaries.len == result.counts.accepted);
                for (result.summaries) |value| {
                    std.debug.assert(std.mem.eql(u8, "shared-site", value.site_id.slice()));
                    std.debug.assert(value.outcome == .accepted);
                }
                self.observed.store(true, .release);
            }
        }
    };

    var ring = Ring{};
    var start = std.atomic.Value(bool).init(false);
    var done = std.atomic.Value(bool).init(false);
    var snapshot_observed = std.atomic.Value(bool).init(false);
    const reader = try std.Thread.spawn(.{}, Reader.run, .{Reader{
        .ring = &ring,
        .start = &start,
        .done = &done,
        .observed = &snapshot_observed,
    }});
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*thread, worker| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{Worker{
            .ring = &ring,
            .worker = worker,
            .start = &start,
            .snapshot_observed = &snapshot_observed,
        }});
    }
    start.store(true, .release);
    for (threads) |thread| thread.join();
    done.store(true, .release);
    reader.join();

    var output: [capacity]Summary = undefined;
    const result = ring.snapshot("shared-site", &output);
    const stats = ring.stats();
    try std.testing.expectEqual(capacity, result.summaries.len);
    try std.testing.expectEqual(@as(u64, 8 * 500 - capacity), stats.overwritten);
    try std.testing.expectEqual(capacity, result.counts.accepted);
    try std.testing.expect(snapshot_observed.load(.acquire));
    for (result.summaries, 0..) |left, index| {
        for (result.summaries[index + 1 ..]) |right| {
            try std.testing.expect(left.correlation != right.correlation);
        }
    }
}
