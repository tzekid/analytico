const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite_translate = b.addTranslateC(.{
        .root_source_file = b.path("vendor/sqlite/sqlite3.h"),
        .target = target,
        .optimize = optimize,
    });
    sqlite_translate.addIncludePath(b.path("vendor/sqlite"));
    const sqlite_module = sqlite_translate.createModule();

    // Passkey verification: pure-Zig WebAuthn (passcay) and CBOR (zbor), vendored.
    const zbor_module = b.createModule(.{ .root_source_file = b.path("vendor/zbor/src/main.zig"), .target = target, .optimize = optimize });
    const passcay_module = b.createModule(.{ .root_source_file = b.path("vendor/passcay/src/public.zig"), .target = target, .optimize = optimize });
    passcay_module.addImport("zbor", zbor_module);

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addIncludePath(b.path("vendor/sqlite"));
    module.addImport("sqlite_c", sqlite_module);
    module.addImport("passcay", passcay_module);
    module.addImport("zbor", zbor_module);
    module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-std=c99",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
            "-DSQLITE_DQS=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            // Memory-mapped reads may cover a database of up to 16 GB.
            "-DSQLITE_MAX_MMAP_SIZE=17179869184",
        },
    });
    // The collector's scripts are cut from one source at build time.
    const generator = b.addExecutable(.{ .name = "gen-trackers", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/gen_trackers.zig"),
        .target = b.graph.host,
    }) });
    const generate = b.addRunArtifact(generator);
    generate.addFileArg(b.path("assets/tracker-source.js"));
    generate.addFileArg(b.path("assets/replay-recorder.js"));
    generate.addFileArg(b.path("assets/overlay.js"));
    generate.addFileArg(b.path("vendor/rrweb/record.min.js"));
    const generated = generate.addOutputDirectoryArg("trackers");
    inline for (.{
        .{ "tracker_lite", "tracker-lite.js" },
        .{ "tracker_lite_rum", "tracker-lite-rum.js" },
        .{ "tracker_session", "tracker-session.js" },
        .{ "tracker_session_rum", "tracker-session-rum.js" },
        .{ "tracker_full", "tracker-full.js" },
        .{ "tracker_full_rum", "tracker-full-rum.js" },
        .{ "tracker_replay", "replay.js" },
        .{ "tracker_overlay", "overlay.js" },
        .{ "tracker_hashes", "hashes.zig" },
    }) |asset| module.addAnonymousImport(asset[0], .{ .root_source_file = generated.path(b, asset[1]) });
    inline for (.{
        .{ "web_player_js", "vendor/rrweb/replay.min.js" },
        .{ "web_player_css", "vendor/rrweb/replay.min.css" },
        .{ "web_css", "assets/web/app.css" },
        .{ "web_js", "assets/web/app.js" },
        .{ "web_icons", "assets/web/icons.svg" },
        .{ "web_favicon", "assets/web/favicon.svg" },
        .{ "font_roboto", "assets/web/fonts/roboto.woff2" },
        .{ "font_quando", "assets/web/fonts/quando.woff2" },
        .{ "font_quicksand", "assets/web/fonts/quicksand.woff2" },
    }) |asset| module.addAnonymousImport(asset[0], .{ .root_source_file = b.path(asset[1]) });

    const app = b.addExecutable(.{ .name = "analytico", .root_module = module });
    b.installArtifact(app);

    const run = b.addRunArtifact(app);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run Analytico").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = module });
    const test_step = b.step("test", "Run focused unit checks");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // The push relay is a separate program, run by the app publisher.
    const relay_module = b.createModule(.{ .root_source_file = b.path("relay/main.zig"), .target = target, .optimize = optimize });
    const relay = b.addExecutable(.{ .name = "analytico-relay", .root_module = relay_module });
    const install_relay = b.addInstallArtifact(relay, .{});
    b.step("relay", "Build the push relay").dependOn(&install_relay.step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = relay_module })).step);

    const e2e = b.addSystemCommand(&.{ "node", "tests/e2e.mjs" });
    e2e.addArtifactArg(app);
    e2e.step.dependOn(b.getInstallStep());
    e2e.step.dependOn(&install_relay.step);
    b.step("e2e", "Run the real SQLite and loopback HTTP journey").dependOn(&e2e.step);
}
