const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const turso_native_path = b.option(
        []const u8,
        "turso-native-path",
        "Prefix containing a prebuilt Turso SDK Kit",
    );
    const turso_native = if (turso_native_path == null) "source" else "system";
    const turso_dependency = if (turso_native_path) |prefix|
        b.dependency("turso", .{
            .target = target,
            .optimize = optimize,
            .native = turso_native,
            .@"native-path" = prefix,
            .encryption = false,
            .fts = false,
            .sync = false,
        })
    else
        b.dependency("turso", .{
            .target = target,
            .optimize = optimize,
            .native = turso_native,
            .encryption = false,
            .fts = false,
            .sync = false,
        });
    const turso_module = turso_dependency.module("turso");

    const duckdb_dependency = b.dependency("duckdb", .{});
    const duckdb_translate_c = b.addTranslateC(.{
        .root_source_file = duckdb_dependency.path("duckdb.h"),
        .target = target,
        .optimize = optimize,
    });
    duckdb_translate_c.addIncludePath(duckdb_dependency.path(""));
    const duckdb_c_module = duckdb_translate_c.createModule();

    const app_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "turso", .module = turso_module },
            .{ .name = "duckdb_c", .module = duckdb_c_module },
        },
    });
    app_module.addLibraryPath(duckdb_dependency.path(""));
    app_module.linkSystemLibrary("duckdb", .{ .use_pkg_config = .no });
    app_module.addRPath(duckdb_dependency.path(""));
    app_module.addRPathSpecial("$ORIGIN/../lib");
    const app = b.addExecutable(.{
        .name = "analytico",
        .root_module = app_module,
    });
    b.installArtifact(app);
    b.getInstallStep().dependOn(
        &b.addInstallLibFile(duckdb_dependency.path("libduckdb.so"), "libduckdb.so").step,
    );

    const run_command = b.addRunArtifact(app);
    run_command.step.dependOn(b.getInstallStep());
    run_command.addPassthruArgs();
    b.step("run", "Run the Analytico scaffold").dependOn(&run_command.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
            .imports = &.{
                .{ .name = "turso", .module = turso_module },
                .{ .name = "duckdb_c", .module = duckdb_c_module },
            },
        }),
    });
    tests.root_module.addLibraryPath(duckdb_dependency.path(""));
    tests.root_module.linkSystemLibrary("duckdb", .{ .use_pkg_config = .no });
    tests.root_module.addRPath(duckdb_dependency.path(""));
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run Analytico tests").dependOn(&run_tests.step);

    const m0_e2e = b.addSystemCommand(&.{ "bash", "tests/e2e-m0.sh" });
    m0_e2e.addArtifactArg(app);
    m0_e2e.step.dependOn(b.getInstallStep());
    b.step("e2e-m0", "Run M0 against real on-disk Turso and DuckDB files").dependOn(&m0_e2e.step);

    const m1_e2e = b.addSystemCommand(&.{ "bash", "tests/e2e-m1.sh" });
    m1_e2e.addArtifactArg(app);
    m1_e2e.step.dependOn(b.getInstallStep());
    b.step("e2e-m1", "Run M1 administration and durability through real processes").dependOn(&m1_e2e.step);
}
