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

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addIncludePath(b.path("vendor/sqlite"));
    module.addImport("sqlite_c", sqlite_module);
    module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-std=c99",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
            "-DSQLITE_DQS=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_ENABLE_DBSTAT_VTAB",
        },
    });
    inline for (.{
        .{ "tracker_lite", "assets/generated/tracker-lite.js" },
        .{ "tracker_lite_rum", "assets/generated/tracker-lite-rum.js" },
        .{ "tracker_session", "assets/generated/tracker-session.js" },
        .{ "tracker_session_rum", "assets/generated/tracker-session-rum.js" },
    }) |asset| module.addAnonymousImport(asset[0], .{ .root_source_file = b.path(asset[1]) });

    const app = b.addExecutable(.{ .name = "analytico", .root_module = module });
    b.installArtifact(app);

    const run = b.addRunArtifact(app);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run Analytico").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run focused unit checks").dependOn(&b.addRunArtifact(tests).step);

    const e2e = b.addSystemCommand(&.{ "bash", "tests/e2e.sh" });
    e2e.addArtifactArg(app);
    e2e.step.dependOn(b.getInstallStep());
    b.step("e2e", "Run the real SQLite and loopback HTTP journey").dependOn(&e2e.step);
}
