const std = @import("std");
const analytico = @import("root.zig");
const cli = @import("cli.zig");
const probe = @import("m0/probe.zig");
const m2_probe = @import("m2/probe.zig");
const m3_probe = @import("m3/probe.zig");
const m4_probe = @import("m4/probe.zig");
const analysis_probe = @import("analysis_probe.zig");

pub fn main(init: std.process.Init) !void {
    const ignore_file_limit: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.XFSZ, &ignore_file_limit, null);
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const output = &writer.interface;
    defer output.flush() catch {};

    if (args.len == 4 and
        std.mem.eql(u8, args[1], "analysis") and
        std.mem.eql(u8, args[2], "semantic-probe"))
    {
        try analysis_probe.run(allocator, init.io, output, args[3]);
        return;
    }
    if (args.len == 4 and
        std.mem.eql(u8, args[1], "analysis") and
        std.mem.eql(u8, args[2], "traffic-quality-seed"))
    {
        try analysis_probe.seedTrafficQuality(allocator, output, args[3]);
        return;
    }
    if (args.len == 4 and
        std.mem.eql(u8, args[1], "analysis") and
        std.mem.eql(u8, args[2], "heuristics-seed"))
    {
        try analysis_probe.seedHeuristics(allocator, output, args[3]);
        return;
    }
    if (args.len == 4 and
        std.mem.eql(u8, args[1], "analysis") and
        std.mem.eql(u8, args[2], "heuristics-check"))
    {
        try analysis_probe.checkHeuristics(allocator, output, args[3]);
        return;
    }
    if (args.len == 4 and
        std.mem.eql(u8, args[1], "m0") and
        std.mem.eql(u8, args[2], "probe"))
    {
        try probe.run(allocator, output, args[3]);
        return;
    }
    if (args.len == 3 and
        std.mem.eql(u8, args[1], "m2") and
        std.mem.eql(u8, args[2], "rate-probe"))
    {
        try m2_probe.rateTable(output);
        return;
    }
    if (args.len == 6 and
        std.mem.eql(u8, args[1], "m2") and
        std.mem.eql(u8, args[2], "v2-inspect"))
    {
        try m2_probe.inspectV2(allocator, output, args[3], args[4], args[5]);
        return;
    }
    if (args.len == 5 and
        std.mem.eql(u8, args[1], "m2") and
        std.mem.eql(u8, args[2], "schema4-fixture"))
    {
        try m2_probe.schema4Fixture(allocator, output, args[3], args[4]);
        return;
    }
    if (args.len == 5 and
        std.mem.eql(u8, args[1], "m2") and
        std.mem.eql(u8, args[2], "time-buckets"))
    {
        try m2_probe.timeBuckets(allocator, output, args[3], args[4]);
        return;
    }
    if (args.len == 7 and
        std.mem.eql(u8, args[1], "m2") and
        std.mem.eql(u8, args[2], "property-semantics"))
    {
        try m2_probe.propertySemantics(
            allocator,
            output,
            args[3],
            args[4],
            try std.fmt.parseInt(i64, args[5], 10),
            try std.fmt.parseInt(i64, args[6], 10),
        );
        return;
    }
    if (args.len == 4 and
        std.mem.eql(u8, args[1], "m2") and
        std.mem.eql(u8, args[2], "property-million"))
    {
        try m2_probe.propertyMillion(allocator, init.io, output, args[3]);
        return;
    }
    if (args.len == 6 and
        std.mem.eql(u8, args[1], "m2") and
        std.mem.eql(u8, args[2], "session-timeline"))
    {
        try m2_probe.sessionTimeline(allocator, output, args[3], args[4], args[5]);
        return;
    }
    if (args.len == 4 and
        std.mem.eql(u8, args[1], "m2") and
        std.mem.eql(u8, args[2], "identity-links"))
    {
        try m2_probe.identityLinkCount(allocator, output, args[3]);
        return;
    }
    if (args.len == 6 and
        std.mem.eql(u8, args[1], "m2") and
        std.mem.eql(u8, args[2], "person-inspect"))
    {
        try m2_probe.inspectPerson(allocator, output, args[3], args[4], args[5]);
        return;
    }
    if (args.len == 5 and
        std.mem.eql(u8, args[1], "m3") and
        std.mem.eql(u8, args[2], "seed"))
    {
        try m3_probe.seed(allocator, output, args[3], args[4]);
        return;
    }
    if (args.len == 5 and
        std.mem.eql(u8, args[1], "m3") and
        std.mem.eql(u8, args[2], "million"))
    {
        try m3_probe.million(allocator, output, args[3], args[4]);
        return;
    }
    if (args.len == 5 and
        std.mem.eql(u8, args[1], "m3") and
        std.mem.eql(u8, args[2], "goal-predicates-fixture"))
    {
        try m3_probe.goalPredicatesFixture(
            allocator,
            output,
            args[3],
            args[4],
        );
        return;
    }
    if (args.len == 4 and
        std.mem.eql(u8, args[1], "m3") and
        std.mem.eql(u8, args[2], "timeout"))
    {
        try m3_probe.timeout(allocator, output, args[3]);
        return;
    }
    if (args.len == 7 and
        std.mem.eql(u8, args[1], "m3") and
        std.mem.eql(u8, args[2], "traffic-quality-profile"))
    {
        try m3_probe.trafficQualityProfile(
            allocator,
            output,
            args[3],
            args[4],
            args[5],
            args[6],
        );
        return;
    }
    if (args.len == 7 and
        std.mem.eql(u8, args[1], "m3") and
        std.mem.eql(u8, args[2], "goal-discovery"))
    {
        try m3_probe.goalDiscovery(
            allocator,
            output,
            args[3],
            args[4],
            args[5],
            args[6],
        );
        return;
    }
    if (args.len == 7 and
        std.mem.eql(u8, args[1], "m3") and
        (std.mem.eql(u8, args[2], "goal-predicates-profile") or
            std.mem.eql(u8, args[2], "goal-predicates-explain")))
    {
        try m3_probe.goalPredicatesProfile(
            allocator,
            init.io,
            output,
            args[3],
            args[4],
            args[5],
            args[6],
            std.mem.eql(u8, args[2], "goal-predicates-explain"),
        );
        return;
    }
    if (args.len == 7 and
        std.mem.eql(u8, args[1], "m3") and
        (std.mem.eql(u8, args[2], "funnel-availability-profile") or
            std.mem.eql(u8, args[2], "funnel-availability-explain")))
    {
        try m3_probe.funnelAvailabilityProfile(
            allocator,
            init.io,
            output,
            args[3],
            args[4],
            args[5],
            args[6],
            std.mem.eql(u8, args[2], "funnel-availability-explain"),
        );
        return;
    }
    if (args.len == 5 and
        std.mem.eql(u8, args[1], "m3") and
        std.mem.eql(u8, args[2], "goal-cap-recovery"))
    {
        try m3_probe.goalCapacityRecovery(
            allocator,
            output,
            args[3],
            args[4],
        );
        return;
    }
    if (args.len == 9 and
        std.mem.eql(u8, args[1], "m3") and
        std.mem.eql(u8, args[2], "overview-v2-series"))
    {
        try m3_probe.overviewV2(
            allocator,
            init.io,
            output,
            args[3],
            args[4],
            args[5],
            args[6],
            args[7],
            args[8],
            false,
        );
        return;
    }
    if (args.len == 9 and
        std.mem.eql(u8, args[1], "m3") and
        std.mem.eql(u8, args[2], "overview-v2-profile"))
    {
        try m3_probe.overviewV2(
            allocator,
            init.io,
            output,
            args[3],
            args[4],
            args[5],
            args[6],
            args[7],
            args[8],
            true,
        );
        return;
    }
    if (args.len == 9 and
        std.mem.eql(u8, args[1], "m3") and
        (std.mem.eql(u8, args[2], "filters-v2-series") or
            std.mem.eql(u8, args[2], "filters-v2-profile")))
    {
        try m3_probe.filtersV2(
            allocator,
            init.io,
            output,
            args[3],
            args[4],
            args[5],
            args[6],
            args[7],
            args[8],
            std.mem.eql(u8, args[2], "filters-v2-profile"),
        );
        return;
    }
    if (args.len == 4 and
        std.mem.eql(u8, args[1], "m4") and
        std.mem.eql(u8, args[2], "legacy-million"))
    {
        try m4_probe.legacyMillion(allocator, output, args[3]);
        return;
    }
    if (args.len == 5 and
        std.mem.eql(u8, args[1], "m4") and
        std.mem.eql(u8, args[2], "poison-newer"))
    {
        try m4_probe.poisonNewer(allocator, output, args[3], args[4]);
        return;
    }
    if (args.len == 4 and
        std.mem.eql(u8, args[1], "m3") and
        std.mem.eql(u8, args[2], "legacy-create"))
    {
        try m3_probe.legacyCreate(allocator, output, args[3]);
        return;
    }
    if (args.len == 4 and
        std.mem.eql(u8, args[1], "m3") and
        std.mem.eql(u8, args[2], "legacy-verify"))
    {
        try m3_probe.legacyVerify(allocator, output, args[3]);
        return;
    }
    if (args.len == 4 and
        std.mem.eql(u8, args[1], "m3") and
        std.mem.eql(u8, args[2], "legacy-evidence"))
    {
        try m3_probe.legacyEvidence(allocator, output, args[3]);
        return;
    }
    if (args.len == 7 and
        std.mem.eql(u8, args[1], "m3") and
        std.mem.eql(u8, args[2], "identity-coverage"))
    {
        try m3_probe.identityCoverage(
            allocator,
            output,
            args[3],
            args[4],
            args[5],
            args[6],
        );
        return;
    }
    if (args.len == 4 and
        std.mem.eql(u8, args[1], "m0") and
        std.mem.eql(u8, args[2], "verify"))
    {
        try probe.verify(allocator, output, args[3]);
        return;
    }
    if (args.len == 4 and
        std.mem.eql(u8, args[1], "m0") and
        std.mem.eql(u8, args[2], "benchmark"))
    {
        try probe.benchmark(allocator, init.io, output, args[3]);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "version")) {
        try output.print("analytico {s}\n", .{analytico.version});
        return;
    }
    if (try cli.run(allocator, init.gpa, init.io, output, args)) return;

    try output.writeAll(
        \\Usage:
        \\  analytico version
        \\  analytico m0 probe <directory>
        \\  analytico m0 verify <directory>
        \\  analytico m0 benchmark <directory>
        \\  analytico m2 rate-probe
        \\  analytico m2 v2-inspect <directory> <site-id> <event-id>
        \\  analytico m2 session-timeline <directory> <site-id> <session-id>
        \\  analytico m2 identity-links <directory>
        \\  analytico m2 person-inspect <directory> <site-id> <anonymous-id>
        \\  analytico m2 property-semantics <directory> <site-id> <start-micros> <end-micros>
        \\  analytico m2 property-million <directory>
        \\  analytico m3 seed <directory> <site-id>
        \\  analytico m3 million <directory> <site-id>
        \\  analytico m3 timeout <directory>
        \\  analytico m3 traffic-quality-profile <directory> <site-slug> <start-date> <end-date>
        \\  analytico m3 goal-discovery <directory> <site-slug> <start-date> <end-date>
        \\  analytico m3 goal-predicates-profile <directory> <site-slug> <start-date> <end-date>
        \\  analytico m3 goal-predicates-explain <directory> <site-slug> <start-date> <end-date>
        \\  analytico m3 funnel-availability-profile <directory> <site-slug> <start-date> <end-date>
        \\  analytico m3 funnel-availability-explain <directory> <site-slug> <start-date> <end-date>
        \\  analytico m3 goal-cap-recovery <directory> <site-slug>
        \\  analytico m3 filters-v2-series <directory> <site-slug> <current-start> <current-end> <comparison-start> <comparison-end>
        \\  analytico m3 filters-v2-profile <directory> <site-slug> <current-start> <current-end> <comparison-start> <comparison-end>
        \\  analytico m3 legacy-create <directory>
        \\  analytico m3 legacy-verify <directory>
        \\  analytico m3 legacy-evidence <directory>
        \\  analytico m3 identity-coverage <directory> <site-id> <start-local-date> <end-local-date>
        \\  analytico m4 legacy-million <directory>
        \\  analytico m4 poison-newer <directory> <metadata|events>
        \\
    );
    try cli.writeUsage(output);
}
