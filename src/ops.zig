const std = @import("std");
const domain = @import("domain.zig");
const report = @import("report.zig");
const version = @import("version.zig");
const events = @import("store/events.zig");
const meta = @import("store/meta.zig");
const timezone = @import("timezone.zig");

const manifest_schema: u8 = 1;
const export_page_size: i64 = 1_000;
const migration_space_headroom: u64 = 64 * 1024 * 1024;

const Statvfs = extern struct {
    block_size: usize,
    fragment_size: usize,
    blocks: u64,
    blocks_free: u64,
    blocks_available: u64,
    files: u64,
    files_free: u64,
    files_available: u64,
    filesystem_id: usize,
    flags: usize,
    name_max: usize,
    filesystem_type: u32,
    spare: [5]i32,
};

extern fn statvfs(path: [*:0]const u8, result: *Statvfs) i32;

const Paths = struct {
    meta: []const u8,
    events: []const u8,
    key: []const u8,

    fn init(allocator: std.mem.Allocator, directory: []const u8) !Paths {
        return .{
            .meta = try std.fs.path.join(allocator, &.{ directory, "meta.db" }),
            .events = try std.fs.path.join(allocator, &.{ directory, "events.duckdb" }),
            .key = try std.fs.path.join(allocator, &.{ directory, "visitor.key" }),
        };
    }
};

const ManifestFile = struct {
    name: []const u8,
    bytes: u64,
    sha256: []const u8,
};

const Manifest = struct {
    schema: u8,
    analytico_version: []const u8,
    created_at_utc_micros: i64,
    metadata_schema: i64,
    event_schema: i64,
    meta: ManifestFile,
    events: ManifestFile,
    visitor_key: ManifestFile,
};

const FileEvidence = struct {
    bytes: u64,
    sha256: [64]u8,
};

pub fn migrate(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
    backup_directory: ?[]const u8,
) !void {
    const paths = try Paths.init(allocator, directory);
    try validateKey(io, paths.key);
    try requireRegularFile(io, paths.meta);
    try requireRegularFile(io, paths.events);
    var metadata = try meta.Store.open(allocator, paths.meta);
    defer metadata.deinit();
    var event_store = try events.Store.open(allocator, paths.events);
    defer event_store.deinit();
    const metadata_version = try metadata.migrationVersion();
    const event_version = try event_store.migrationVersion();
    try validateStoreVersions(metadata_version, event_version);

    const metadata_upgrade = metadata_version < meta.schema_version;
    const event_upgrade = event_version < events.schema_version;
    if (metadata_upgrade or event_upgrade) {
        const verified_backup = backup_directory orelse
            return error.VerifiedBackupRequired;
        try metadata.integrityCheck();
        try event_store.checkpoint();
        try metadata.checkpoint();
        _ = try event_store.eventCount();
        try verifyMigrationBackup(
            allocator,
            io,
            verified_backup,
            paths,
            metadata_version,
            event_version,
        );
        if (event_upgrade) {
            try requireMigrationSpace(allocator, io, paths.events);
            try event_store.migrate();
            try event_store.requireCurrent();
        }
        if (metadata_upgrade) {
            try metadata.migrate();
            try metadata.requireCurrent();
        }
        try event_store.checkpoint();
        try metadata.checkpoint();
    }
    try output.print("migrated metadata=v{d} events=v{d}\n", .{
        try metadata.migrationVersion(),
        try event_store.migrationVersion(),
    });
}

pub fn backup(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
    destination: []const u8,
) !void {
    const source = try Paths.init(allocator, directory);
    try validateKey(io, source.key);
    try requireRegularFile(io, source.meta);
    try requireRegularFile(io, source.events);
    var metadata_version: i64 = undefined;
    var event_version: i64 = undefined;
    {
        var metadata = try meta.Store.open(allocator, source.meta);
        defer metadata.deinit();
        metadata_version = try metadata.migrationVersion();
        try metadata.integrityCheck();
        try metadata.checkpoint();
        var event_store = try events.Store.open(allocator, source.events);
        defer event_store.deinit();
        event_version = try event_store.migrationVersion();
        try validateStoreVersions(metadata_version, event_version);
        _ = try event_store.eventCount();
        try event_store.checkpoint();
    }

    try requireMissing(io, destination);
    const temporary = try temporarySibling(allocator, io, destination);
    errdefer std.Io.Dir.cwd().deleteTree(io, temporary) catch {};
    try std.Io.Dir.cwd().createDir(
        io,
        temporary,
        @fromBackingInt(@intCast(0o700)),
    );

    const copied_meta = try std.fs.path.join(allocator, &.{ temporary, "meta.db" });
    const copied_events = try std.fs.path.join(
        allocator,
        &.{ temporary, "events.duckdb" },
    );
    const copied_key = try std.fs.path.join(allocator, &.{ temporary, "visitor.key" });
    try copyDurable(io, source.meta, copied_meta);
    try copyDurable(io, source.events, copied_events);
    try copyDurable(io, source.key, copied_key);
    try validateKey(io, copied_key);

    const meta_evidence = try hashFile(io, copied_meta);
    const event_evidence = try hashFile(io, copied_events);
    const key_evidence = try hashFile(io, copied_key);
    const manifest_path = try std.fs.path.join(
        allocator,
        &.{ temporary, "manifest.json" },
    );
    const manifest = Manifest{
        .schema = manifest_schema,
        .analytico_version = version.value,
        .created_at_utc_micros = try nowMicros(),
        .metadata_schema = metadata_version,
        .event_schema = event_version,
        .meta = .{
            .name = "meta.db",
            .bytes = meta_evidence.bytes,
            .sha256 = &meta_evidence.sha256,
        },
        .events = .{
            .name = "events.duckdb",
            .bytes = event_evidence.bytes,
            .sha256 = &event_evidence.sha256,
        },
        .visitor_key = .{
            .name = "visitor.key",
            .bytes = key_evidence.bytes,
            .sha256 = &key_evidence.sha256,
        },
    };
    try writeManifest(io, manifest_path, manifest);
    try syncDirectory(io, temporary);
    try std.Io.Dir.renamePreserve(
        .cwd(),
        temporary,
        .cwd(),
        destination,
        io,
    );
    if (std.fs.path.dirname(destination)) |parent| try syncDirectory(io, parent);
    try output.print(
        "backup complete destination={s} metadata=v{d} events=v{d}\n",
        .{ destination, metadata_version, event_version },
    );
}

pub fn restore(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    backup_directory: []const u8,
    destination: []const u8,
) !void {
    const manifest_path = try std.fs.path.join(
        allocator,
        &.{ backup_directory, "manifest.json" },
    );
    const encoded = try std.Io.Dir.cwd().readFileAlloc(
        io,
        manifest_path,
        allocator,
        .limited(16 * 1024),
    );
    const parsed = std.json.parseFromSlice(
        Manifest,
        allocator,
        encoded,
        .{ .ignore_unknown_fields = false },
    ) catch return error.InvalidBackupManifest;
    defer parsed.deinit();
    const manifest = parsed.value;
    try validateManifest(manifest);
    try verifyManifestFile(allocator, io, backup_directory, manifest.meta);
    try verifyManifestFile(allocator, io, backup_directory, manifest.events);
    try verifyManifestFile(allocator, io, backup_directory, manifest.visitor_key);

    try requireMissing(io, destination);
    const temporary = try temporarySibling(allocator, io, destination);
    errdefer std.Io.Dir.cwd().deleteTree(io, temporary) catch {};
    try std.Io.Dir.cwd().createDir(io, temporary, @fromBackingInt(@intCast(0o700)));
    const restored_temp = try std.fs.path.join(allocator, &.{ temporary, "tmp" });
    try std.Io.Dir.cwd().createDir(
        io,
        restored_temp,
        @fromBackingInt(@intCast(0o700)),
    );
    inline for (.{
        .{ "meta.db", manifest.meta },
        .{ "events.duckdb", manifest.events },
        .{ "visitor.key", manifest.visitor_key },
    }) |entry| {
        const source = try std.fs.path.join(
            allocator,
            &.{ backup_directory, entry[0] },
        );
        const target = try std.fs.path.join(allocator, &.{ temporary, entry[0] });
        try copyDurable(io, source, target);
    }
    const restored_paths = try Paths.init(allocator, temporary);
    try validateKey(io, restored_paths.key);
    try verifyStores(
        allocator,
        restored_paths,
        manifest.metadata_schema,
        manifest.event_schema,
    );
    try syncDirectory(io, temporary);
    try std.Io.Dir.renamePreserve(
        .cwd(),
        temporary,
        .cwd(),
        destination,
        io,
    );
    if (std.fs.path.dirname(destination)) |parent| try syncDirectory(io, parent);
    try output.print(
        "restore verified destination={s} metadata=v{d} events=v{d}\n",
        .{ destination, manifest.metadata_schema, manifest.event_schema },
    );
}

pub fn maintain(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
    cutoff_date: []const u8,
) !void {
    try domain.validateDate(cutoff_date);
    const cutoff_day = try report.dateDay(cutoff_date);
    const today = try currentDate();
    const today_day = try report.dateDay(&today);
    if (cutoff_day > today_day or today_day - cutoff_day < 400) {
        return error.RetentionWouldDeleteRecentEvents;
    }
    const paths = try Paths.init(allocator, directory);
    try validateKey(io, paths.key);
    var metadata = try meta.Store.open(allocator, paths.meta);
    defer metadata.deinit();
    try metadata.requireCurrent();
    var event_store = try events.Store.open(allocator, paths.events);
    defer event_store.deinit();
    try event_store.requireCurrent();

    const before = try event_store.eventCount();
    const expired = try event_store.deleteBefore(cutoff_date);
    var deleted_site_events: i64 = 0;
    var deleted_sites: i64 = 0;
    const sites = try metadata.listSites(allocator);
    for (sites) |site| {
        if (!site.disabled) continue;
        deleted_site_events += try event_store.deleteSite(site.id);
        try metadata.deleteSite(site.slug);
        deleted_sites += 1;
    }
    try event_store.checkpoint();
    try metadata.checkpoint();
    const after = try event_store.eventCount();
    try output.print(
        "maintenance cutoff={s} before={d} expired={d} " ++
            "site_events={d} sites={d} after={d}\n",
        .{
            cutoff_date,
            before,
            expired,
            deleted_site_events,
            deleted_sites,
            after,
        },
    );
}

pub fn exportCsv(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
    site_slug: []const u8,
    start_date: []const u8,
    end_date: []const u8,
    destination: []const u8,
) !void {
    try domain.validateSlug(site_slug);
    try domain.validateDate(start_date);
    try domain.validateDate(end_date);
    if (try report.dateDay(end_date) < try report.dateDay(start_date)) {
        return error.InvalidExportRange;
    }
    const paths = try Paths.init(allocator, directory);
    var metadata = try meta.Store.open(allocator, paths.meta);
    defer metadata.deinit();
    try metadata.requireCurrent();
    const site_id = try metadata.siteIdBySlug(allocator, site_slug);
    var event_store = try events.Store.open(allocator, paths.events);
    defer event_store.deinit();
    try event_store.requireCurrent();

    const file = try std.Io.Dir.cwd().createFile(io, destination, .{
        .read = true,
        .exclusive = true,
        .permissions = @fromBackingInt(@intCast(0o600)),
    });
    errdefer {
        std.Io.Dir.cwd().deleteFile(io, destination) catch {};
    }
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(
        "received_at_utc_micros,received_date_utc,event_name,path," ++
            "referrer_host,country_code,browser_family,os_family," ++
            "device_category,utm_source,utm_medium,utm_campaign,utm_term," ++
            "utm_content,properties_json\n",
    );
    var offset: i64 = 0;
    var written: i64 = 0;
    while (true) {
        var page_arena = std.heap.ArenaAllocator.init(allocator);
        defer page_arena.deinit();
        const page = try event_store.exportPage(
            page_arena.allocator(),
            site_id,
            start_date,
            end_date,
            offset,
            export_page_size,
        );
        for (page) |event| try writeExportEvent(writer, event);
        written += @intCast(page.len);
        if (page.len < export_page_size) break;
        offset = std.math.add(i64, offset, export_page_size) catch
            return error.ExportTooLarge;
    }
    try file_writer.flush();
    try file.sync(io);
    try output.print("export complete destination={s} events={d}\n", .{
        destination,
        written,
    });
}

pub fn doctor(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    directory: []const u8,
    zoneinfo_root: []const u8,
) !void {
    const paths = try Paths.init(allocator, directory);
    try validateKey(io, paths.key);
    const zoneinfo_stat = try std.Io.Dir.cwd().statFile(io, zoneinfo_root, .{});
    if (zoneinfo_stat.kind != .directory) return error.InvalidZoneinfoRoot;
    var metadata = try meta.Store.open(allocator, paths.meta);
    defer metadata.deinit();
    try metadata.requireCurrent();
    try metadata.integrityCheck();
    const site_ids = try metadata.siteIds(allocator);
    const now_seconds = @divFloor(try nowMicros(), 1_000_000);
    for (site_ids) |site_id| {
        const policy = try metadata.sitePolicy(allocator, site_id);
        var zone = try timezone.load(
            allocator,
            io,
            zoneinfo_root,
            policy.timezone_name,
        );
        errdefer zone.deinit(allocator);
        _ = try zone.localAt(now_seconds);
        zone.deinit(allocator);
    }
    var event_store = try events.Store.open(allocator, paths.events);
    defer event_store.deinit();
    try event_store.requireCurrent();
    const counts = try metadata.counts();
    try output.print(
        "ok metadata=v{d} events=v{d} sites={d} goals={d} funnels={d} " ++
            "stored_events={d} key=ok\n",
        .{
            try metadata.migrationVersion(),
            try event_store.migrationVersion(),
            counts.sites,
            counts.goals,
            counts.funnels,
            try event_store.eventCount(),
        },
    );
}

fn verifyStores(
    allocator: std.mem.Allocator,
    paths: Paths,
    expected_metadata_version: i64,
    expected_event_version: i64,
) !void {
    var metadata = try meta.Store.open(allocator, paths.meta);
    defer metadata.deinit();
    if (try metadata.migrationVersion() != expected_metadata_version) {
        return error.BackupSchemaMismatch;
    }
    try metadata.integrityCheck();
    var event_store = try events.Store.open(allocator, paths.events);
    defer event_store.deinit();
    if (try event_store.migrationVersion() != expected_event_version) {
        return error.BackupSchemaMismatch;
    }
    _ = try event_store.eventCount();
}

fn validateManifest(manifest: Manifest) !void {
    if (manifest.schema != manifest_schema or
        !std.mem.eql(u8, manifest.meta.name, "meta.db") or
        !std.mem.eql(u8, manifest.events.name, "events.duckdb") or
        !std.mem.eql(u8, manifest.visitor_key.name, "visitor.key") or
        manifest.meta.sha256.len != 64 or manifest.events.sha256.len != 64 or
        manifest.visitor_key.sha256.len != 64)
    {
        return error.IncompatibleBackupManifest;
    }
    try validateStoreVersions(manifest.metadata_schema, manifest.event_schema);
}

fn validateStoreVersions(metadata_version: i64, event_version: i64) !void {
    if (metadata_version > meta.schema_version) return error.NewerMetadataSchema;
    if (event_version > events.schema_version) return error.NewerEventSchema;
    if (metadata_version < 1 or event_version < 1) {
        return error.UnsupportedBackupSchema;
    }
}

fn verifyMigrationBackup(
    allocator: std.mem.Allocator,
    io: std.Io,
    backup_directory: []const u8,
    live: Paths,
    metadata_version: i64,
    event_version: i64,
) !void {
    const manifest_path = try std.fs.path.join(
        allocator,
        &.{ backup_directory, "manifest.json" },
    );
    const encoded = try std.Io.Dir.cwd().readFileAlloc(
        io,
        manifest_path,
        allocator,
        .limited(16 * 1024),
    );
    const parsed = std.json.parseFromSlice(
        Manifest,
        allocator,
        encoded,
        .{ .ignore_unknown_fields = false },
    ) catch return error.InvalidBackupManifest;
    defer parsed.deinit();
    const manifest = parsed.value;
    try validateManifest(manifest);
    try verifyManifestFile(allocator, io, backup_directory, manifest.meta);
    try verifyManifestFile(allocator, io, backup_directory, manifest.events);
    try verifyManifestFile(allocator, io, backup_directory, manifest.visitor_key);

    if (metadata_version < meta.schema_version) {
        if (manifest.metadata_schema != metadata_version) {
            return error.BackupSchemaMismatch;
        }
        try verifyLiveFile(io, live.meta, manifest.meta);
    }
    if (event_version < events.schema_version) {
        if (manifest.event_schema != event_version) {
            return error.BackupSchemaMismatch;
        }
        try verifyLiveFile(io, live.events, manifest.events);
    }
    try verifyLiveFile(io, live.key, manifest.visitor_key);
}

fn verifyLiveFile(io: std.Io, path: []const u8, expected: ManifestFile) !void {
    const actual = try hashFile(io, path);
    if (actual.bytes != expected.bytes or
        !std.mem.eql(u8, &actual.sha256, expected.sha256))
    {
        return error.BackupDoesNotMatchLiveData;
    }
}

fn requireMigrationSpace(
    allocator: std.mem.Allocator,
    io: std.Io,
    event_path: []const u8,
) !void {
    const stat = try std.Io.Dir.cwd().statFile(io, event_path, .{});
    if (stat.kind != .file) return error.InvalidEventStorePath;
    const required = try migrationBytesRequired(stat.size);
    const path_z = try allocator.dupeSentinel(u8, event_path, 0);
    defer allocator.free(path_z);
    var filesystem: Statvfs = undefined;
    if (statvfs(path_z.ptr, &filesystem) != 0) {
        return error.MigrationSpaceUnavailable;
    }
    const available = std.math.mul(
        u64,
        filesystem.blocks_available,
        filesystem.fragment_size,
    ) catch return error.MigrationSpaceUnavailable;
    if (available < required) return error.InsufficientMigrationSpace;
}

fn migrationBytesRequired(event_bytes: u64) !u64 {
    const copies = std.math.mul(u64, event_bytes, 3) catch
        return error.MigrationSizeOverflow;
    return std.math.add(u64, copies, migration_space_headroom) catch
        return error.MigrationSizeOverflow;
}

fn verifyManifestFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    expected: ManifestFile,
) !void {
    const path = try std.fs.path.join(allocator, &.{ directory, expected.name });
    const actual = try hashFile(io, path);
    if (actual.bytes != expected.bytes or
        !std.mem.eql(u8, &actual.sha256, expected.sha256))
    {
        return error.BackupHashMismatch;
    }
}

fn validateKey(io: std.Io, path: []const u8) !void {
    const stat = try std.Io.Dir.cwd().statFile(
        io,
        path,
        .{ .follow_symlinks = false },
    );
    if (stat.kind != .file or stat.size != 32) return error.InvalidKeyFile;
    if (stat.permissions.toMode() & 0o777 != 0o600) {
        return error.InsecureKeyPermissions;
    }
}

fn requireRegularFile(io: std.Io, path: []const u8) !void {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (stat.kind != .file) return error.InvalidStoreFile;
}

fn hashFile(io: std.Io, path: []const u8) !FileEvidence {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    var reader_buffer: [64 * 1024]u8 = undefined;
    var chunk: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        const read = reader.interface.readSliceShort(&chunk) catch
            return reader.err.?;
        hasher.update(chunk[0..read]);
        if (read < chunk.len) break;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{
        .bytes = stat.size,
        .sha256 = std.fmt.bytesToHex(digest, .lower),
    };
}

fn writeManifest(io: std.Io, path: []const u8, manifest: Manifest) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .exclusive = true,
        .permissions = @fromBackingInt(@intCast(0o600)),
    });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try std.json.Stringify.value(manifest, .{ .whitespace = .indent_2 }, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.flush();
    try file.sync(io);
}

fn copyDurable(io: std.Io, source: []const u8, destination: []const u8) !void {
    try std.Io.Dir.copyFile(
        .cwd(),
        source,
        .cwd(),
        destination,
        io,
        .{ .replace = false },
    );
    const file = try std.Io.Dir.cwd().openFile(io, destination, .{});
    defer file.close(io);
    try file.sync(io);
}

fn temporarySibling(
    allocator: std.mem.Allocator,
    io: std.Io,
    destination: []const u8,
) ![]const u8 {
    const name = std.fs.path.basename(destination);
    const parent = std.fs.path.dirname(destination) orelse ".";
    const id = try domain.randomUuid(io);
    const temporary_name = try std.fmt.allocPrint(
        allocator,
        ".{s}.tmp-{s}",
        .{ name, id },
    );
    return std.fs.path.join(allocator, &.{ parent, temporary_name });
}

fn requireMissing(io: std.Io, path: []const u8) !void {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.DestinationAlreadyExists;
}

fn syncDirectory(io: std.Io, path: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{
        .allow_directory = true,
    });
    defer file.close(io);
    try file.sync(io);
}

fn currentDate() ![10]u8 {
    var timestamp: std.os.linux.timespec = undefined;
    const result = std.os.linux.clock_gettime(.REALTIME, &timestamp);
    if (std.os.linux.errno(result) != .SUCCESS or timestamp.sec < 0) {
        return error.ClockUnavailable;
    }
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp.sec) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var date: [10]u8 = undefined;
    _ = try std.fmt.bufPrint(&date, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        @backingInt(month_day.month),
        month_day.day_index + 1,
    });
    return date;
}

fn nowMicros() !i64 {
    var timestamp: std.os.linux.timespec = undefined;
    const result = std.os.linux.clock_gettime(.REALTIME, &timestamp);
    if (std.os.linux.errno(result) != .SUCCESS or timestamp.sec < 0) {
        return error.ClockUnavailable;
    }
    const seconds = std.math.mul(i64, timestamp.sec, 1_000_000) catch
        return error.ClockUnavailable;
    return std.math.add(i64, seconds, @divTrunc(timestamp.nsec, 1_000)) catch
        return error.ClockUnavailable;
}

fn writeExportEvent(output: *std.Io.Writer, event: events.ExportEvent) !void {
    try output.print("{d},", .{event.received_at_utc_micros});
    inline for (.{
        event.received_date_utc,
        event.event_name,
        event.path,
        event.referrer_host,
        event.country_code,
        event.browser_family,
        event.os_family,
        event.device_category,
        event.utm_source,
        event.utm_medium,
        event.utm_campaign,
        event.utm_term,
        event.utm_content,
        event.properties_json,
    }, 0..) |value, index| {
        try csvText(output, value);
        try output.writeByte(if (index == 13) '\n' else ',');
    }
}

fn csvText(output: *std.Io.Writer, value: []const u8) !void {
    try output.writeByte('"');
    if (needsFormulaPrefix(value)) try output.writeByte('\'');
    for (value) |byte| {
        if (byte == '"') try output.writeByte('"');
        try output.writeByte(byte);
    }
    try output.writeByte('"');
}

fn needsFormulaPrefix(value: []const u8) bool {
    if (value.len == 0) return false;
    var index: usize = 0;
    while (index < value.len and std.ascii.isWhitespace(value[index])) {
        index += 1;
    }
    return index < value.len and
        std.mem.findScalar(u8, "=+-@", value[index]) != null;
}

test "migration space preflight reserves three event files and headroom" {
    try std.testing.expectEqual(
        @as(u64, 94 * 1024 * 1024),
        try migrationBytesRequired(10 * 1024 * 1024),
    );
    try std.testing.expectError(
        error.MigrationSizeOverflow,
        migrationBytesRequired(std.math.maxInt(u64)),
    );
}
