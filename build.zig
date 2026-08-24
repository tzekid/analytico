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
    const htmx_dependency = b.dependency("htmx", .{});
    const htmx_source = htmx_dependency.path("package/dist/htmx.min.js");
    const gzip_tool = b.addExecutable(.{
        .name = "analytico-gzip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gzip.zig"),
            .target = b.graph.host,
        }),
    });
    const gzip_htmx = b.addRunArtifact(gzip_tool);
    gzip_htmx.addFileArg(htmx_source);
    const htmx_gzip = gzip_htmx.captureStdOut(.{});
    const passcay_module = b.dependency("passcay", .{
        .target = target,
        .optimize = optimize,
    }).module("passcay");
    const zbor_module = b.dependency("zbor", .{
        .target = target,
        .optimize = optimize,
    }).module("zbor");

    const app_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "turso", .module = turso_module },
            .{ .name = "duckdb_c", .module = duckdb_c_module },
            .{ .name = "passcay", .module = passcay_module },
            .{ .name = "zbor", .module = zbor_module },
        },
    });
    app_module.addLibraryPath(duckdb_dependency.path(""));
    addHtmxAssets(app_module, htmx_source, htmx_gzip);
    app_module.linkSystemLibrary("duckdb", .{ .use_pkg_config = .no });
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
                .{ .name = "passcay", .module = passcay_module },
                .{ .name = "zbor", .module = zbor_module },
            },
        }),
    });
    tests.root_module.addLibraryPath(duckdb_dependency.path(""));
    addHtmxAssets(tests.root_module, htmx_source, htmx_gzip);
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

    const m2_e2e = b.addSystemCommand(&.{ "bash", "tests/e2e-m2.sh" });
    m2_e2e.addArtifactArg(app);
    m2_e2e.step.dependOn(b.getInstallStep());
    b.step("e2e-m2", "Run M2 through the real loopback HTTP collector").dependOn(&m2_e2e.step);

    const timezone_e2e = b.addSystemCommand(&.{ "bash", "tests/e2e-timezone.sh" });
    timezone_e2e.addArtifactArg(app);
    timezone_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-timezone",
        "Run site timezone ingestion and rebucketing through real stores and HTTP",
    ).dependOn(&timezone_e2e.step);

    const properties_e2e = b.addSystemCommand(&.{ "bash", "tests/e2e-properties.sh" });
    properties_e2e.addArtifactArg(app);
    properties_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-properties",
        "Run typed property ingestion and queries through real HTTP and DuckDB",
    ).dependOn(&properties_e2e.step);

    const analysis_e2e = b.addSystemCommand(&.{ "bash", "tests/e2e-analysis.sh" });
    analysis_e2e.addArtifactArg(app);
    analysis_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-analysis",
        "Run metric-v2 typed analysis against a real on-disk DuckDB file",
    ).dependOn(&analysis_e2e.step);

    const traffic_quality_e2e = b.addSystemCommand(&.{
        "bash",
        "tests/e2e-traffic-quality.sh",
    });
    traffic_quality_e2e.addArtifactArg(app);
    traffic_quality_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-traffic-quality",
        "Run traffic-quality diagnostics through real CLI and on-disk stores",
    ).dependOn(&traffic_quality_e2e.step);

    const heuristics_e2e = b.addSystemCommand(&.{
        "bash",
        "tests/e2e-heuristics.sh",
    });
    heuristics_e2e.addArtifactArg(app);
    heuristics_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-heuristics",
        "Run query heuristics and collection caps through real stores and HTTP",
    ).dependOn(&heuristics_e2e.step);

    const diagnostics_e2e = b.addSystemCommand(&.{
        "bash",
        "tests/e2e-diagnostics.sh",
    });
    diagnostics_e2e.addArtifactArg(app);
    diagnostics_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-diagnostics",
        "Run bounded collection diagnostics through real stores, HTTP, and auth",
    ).dependOn(&diagnostics_e2e.step);

    const classifier_e2e = b.addSystemCommand(&.{
        "bash",
        "tests/e2e-classifier.sh",
    });
    classifier_e2e.addArtifactArg(app);
    classifier_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-classifier",
        "Run classifier v2 signals through real loopback HTTP and on-disk stores",
    ).dependOn(&classifier_e2e.step);

    const schema5_migration_e2e = b.addSystemCommand(&.{
        "bash",
        "scripts/run-schema4-gate.sh",
    });
    schema5_migration_e2e.addArtifactArg(app);
    schema5_migration_e2e.addArg("tests/e2e-schema5-migration.sh");
    schema5_migration_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-schema5-migration",
        "Migrate and roll back the exact deployed schema-4 predecessor",
    ).dependOn(&schema5_migration_e2e.step);

    const schema6_migration_e2e = b.addSystemCommand(&.{
        "bash",
        "scripts/run-schema5-gate.sh",
    });
    schema6_migration_e2e.addArtifactArg(app);
    schema6_migration_e2e.addArg("tests/e2e-schema6-migration.sh");
    schema6_migration_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-schema6-migration",
        "Migrate and roll back the exact deployed schema-5 predecessor",
    ).dependOn(&schema6_migration_e2e.step);

    const schema7_migration_e2e = b.addSystemCommand(&.{
        "bash",
        "scripts/run-schema6-gate.sh",
    });
    schema7_migration_e2e.addArtifactArg(app);
    schema7_migration_e2e.addArg("tests/e2e-schema7-migration.sh");
    schema7_migration_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-schema7-migration",
        "Migrate and roll back the exact deployed schema-6 predecessor",
    ).dependOn(&schema7_migration_e2e.step);

    const exclusion_e2e = b.addSystemCommand(&.{
        "bash",
        "tests/e2e-exclusion.sh",
    });
    exclusion_e2e.addArtifactArg(app);
    exclusion_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-exclusion",
        "Run stored self-exclusion through real Chromium and live stores",
    ).dependOn(&exclusion_e2e.step);

    const legacy_migration_e2e = b.addSystemCommand(&.{
        "bash",
        "scripts/run-v0.3-gate.sh",
    });
    legacy_migration_e2e.addArtifactArg(app);
    legacy_migration_e2e.addArg("tests/e2e-legacy-migration.sh");
    legacy_migration_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-legacy-migration",
        "Upgrade the exact v0.3.0 pair and prove mixed-data rollback",
    ).dependOn(&legacy_migration_e2e.step);

    const properties_benchmark = b.addSystemCommand(&.{ "bash", "bench/properties.sh" });
    properties_benchmark.addArtifactArg(app);
    properties_benchmark.step.dependOn(b.getInstallStep());
    b.step(
        "bench-properties",
        "Measure bounded property queries over one million real DuckDB rows",
    ).dependOn(&properties_benchmark.step);

    const m2_browser_e2e = b.addSystemCommand(&.{ "bash", "tests/e2e-m2-browser.sh" });
    m2_browser_e2e.addArtifactArg(app);
    m2_browser_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-m2-browser",
        "Run M2 in real Chromium, Firefox, and WebKit processes",
    ).dependOn(&m2_browser_e2e.step);

    const identity_browser_e2e = b.addSystemCommand(&.{ "bash", "tests/e2e-identity-browser.sh" });
    identity_browser_e2e.addArtifactArg(app);
    identity_browser_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-identity-browser",
        "Run protocol-v2 identity persistence and reset in a real browser",
    ).dependOn(&identity_browser_e2e.step);

    const tracker_browser_e2e = b.addSystemCommand(&.{ "bash", "tests/e2e-tracker-browser.sh" });
    tracker_browser_e2e.addArtifactArg(app);
    tracker_browser_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-tracker-browser",
        "Run tracker behavior and bounded signals in real Chromium",
    ).dependOn(&tracker_browser_e2e.step);

    const m2_benchmark = b.addSystemCommand(&.{ "bash", "bench/m2-collection.sh" });
    m2_benchmark.addArtifactArg(app);
    m2_benchmark.step.dependOn(b.getInstallStep());
    b.step(
        "bench-m2",
        "Measure the real ReleaseSafe HTTP collection path",
    ).dependOn(&m2_benchmark.step);

    const m3_e2e = b.addSystemCommand(&.{ "bash", "tests/e2e-m3.sh" });
    m3_e2e.addArtifactArg(app);
    m3_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-m3",
        "Run M3 reports against real on-disk databases",
    ).dependOn(&m3_e2e.step);

    const m3_benchmark = b.addSystemCommand(&.{ "bash", "bench/m3-reports.sh" });
    m3_benchmark.addArtifactArg(app);
    m3_benchmark.step.dependOn(b.getInstallStep());
    b.step(
        "bench-m3",
        "Measure M3 reports over one million real events",
    ).dependOn(&m3_benchmark.step);

    const m4_e2e = b.addSystemCommand(&.{ "bash", "tests/e2e-m4.sh" });
    m4_e2e.addArtifactArg(app);
    m4_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-m4",
        "Run M4 lifecycle, recovery, and storage-failure checks",
    ).dependOn(&m4_e2e.step);

    const package_release = b.addSystemCommand(&.{
        "bash",
        "scripts/package-release.sh",
    });
    package_release.addArtifactArg(app);
    package_release.addFileArg(duckdb_dependency.path("libduckdb.so"));
    package_release.addArg("dist");
    package_release.step.dependOn(b.getInstallStep());
    b.step(
        "release",
        "Package the current build with checksums and deployment artifacts",
    ).dependOn(&package_release.step);

    const release_e2e = b.addSystemCommand(&.{
        "bash",
        "tests/e2e-release.sh",
    });
    release_e2e.addArtifactArg(app);
    release_e2e.addArg("dist");
    release_e2e.step.dependOn(&package_release.step);
    b.step(
        "e2e-release",
        "Verify the extracted release using its private DuckDB runtime",
    ).dependOn(&release_e2e.step);

    const full_release_e2e = b.addSystemCommand(&.{
        "bash",
        "tests/e2e-release.sh",
    });
    full_release_e2e.addArtifactArg(app);
    full_release_e2e.addArgs(&.{ "dist", "--full" });
    full_release_e2e.step.dependOn(&package_release.step);
    b.step(
        "e2e-release-full",
        "Run every real-process gate against the extracted release",
    ).dependOn(&full_release_e2e.step);

    const rollback_e2e = b.addSystemCommand(&.{
        "bash",
        "scripts/rehearse-rollback.sh",
    });
    rollback_e2e.addArtifactArg(app);
    rollback_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-rollback",
        "Build the prior release and rehearse a verified data rollback",
    ).dependOn(&rollback_e2e.step);

    const m5_cutover_e2e = b.addSystemCommand(&.{
        "bash",
        "tests/e2e-m5-cutover.sh",
    });
    m5_cutover_e2e.addArtifactArg(app);
    m5_cutover_e2e.addArg("dist");
    m5_cutover_e2e.step.dependOn(&package_release.step);
    b.step(
        "e2e-m5",
        "Run a browser cutover and every report from the extracted release",
    ).dependOn(&m5_cutover_e2e.step);

    const m6_dashboard_e2e = b.addSystemCommand(&.{
        "bash",
        "tests/e2e-m6.sh",
    });
    m6_dashboard_e2e.addArtifactArg(app);
    m6_dashboard_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-m6",
        "Run the no-JavaScript dashboard through Caddy and real Chromium",
    ).dependOn(&m6_dashboard_e2e.step);

    const m7_htmx_e2e = b.addSystemCommand(&.{
        "bash",
        "tests/e2e-m7.sh",
    });
    m7_htmx_e2e.addArtifactArg(app);
    m7_htmx_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-m7",
        "Run HTMX 4 enhancement and native fallback through real Chromium",
    ).dependOn(&m7_htmx_e2e.step);

    const passkey_p1_e2e = b.addSystemCommand(&.{
        "bash",
        "tests/e2e-passkey-p1.sh",
    });
    passkey_p1_e2e.addArtifactArg(app);
    passkey_p1_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-passkey-p1",
        "Run owner bootstrap through real Turso, HTTP, Chromium, and WebAuthn",
    ).dependOn(&passkey_p1_e2e.step);

    const onboarding_e2e = b.addSystemCommand(&.{
        "bash",
        "tests/e2e-onboarding.sh",
    });
    onboarding_e2e.addArtifactArg(app);
    onboarding_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-onboarding",
        "Create the first site through passkey auth, real stores, Caddy, and Chromium",
    ).dependOn(&onboarding_e2e.step);

    const installation_e2e = b.addSystemCommand(&.{
        "bash",
        "tests/e2e-installation.sh",
    });
    installation_e2e.addArtifactArg(app);
    installation_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-installation",
        "Verify tracker installation through real stores, Caddy, Chromium, and scale",
    ).dependOn(&installation_e2e.step);

    const metadata6_migration_e2e = b.addSystemCommand(&.{
        "bash",
        "scripts/run-metadata5-gate.sh",
    });
    metadata6_migration_e2e.addArtifactArg(app);
    metadata6_migration_e2e.addArg("tests/e2e-metadata6-migration.sh");
    metadata6_migration_e2e.step.dependOn(b.getInstallStep());
    b.step(
        "e2e-metadata6-migration",
        "Migrate and roll back the exact deployed metadata-5/event-7 predecessor",
    ).dependOn(&metadata6_migration_e2e.step);
}

fn addHtmxAssets(
    module: *std.Build.Module,
    source: std.Build.LazyPath,
    gzip: std.Build.LazyPath,
) void {
    module.addAnonymousImport("htmx_js", .{ .root_source_file = source });
    module.addAnonymousImport("htmx_gzip", .{ .root_source_file = gzip });
}
