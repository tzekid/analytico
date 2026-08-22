const std = @import("std");
const turso = @import("turso");
const domain = @import("../domain.zig");

pub const schema_version: i64 = 3;

pub const Site = struct {
    id: []u8,
    slug: []u8,
    name: []u8,
    disabled: bool,
};

pub const Goal = struct {
    id: []u8,
    name: []u8,
    match_kind: domain.MatchKind,
    match_value: []u8,
};

pub const FunnelStep = struct {
    index: i64,
    name: []u8,
    match_kind: domain.MatchKind,
    match_value: []u8,
};

pub const Funnel = struct {
    id: []u8,
    name: []u8,
    step_count: i64,
};

pub const FunnelStepInput = struct {
    name: []const u8,
    match_kind: domain.MatchKind,
    match_value: []const u8,
};

pub const Counts = struct {
    sites: i64,
    goals: i64,
    funnels: i64,
};

pub const SitePolicy = struct {
    id: []u8,
    disabled: bool,
    timezone_name: []u8,
    origins: []const []u8,
    properties: []const []u8,

    pub fn allowsOrigin(self: SitePolicy, origin: []const u8) bool {
        for (self.origins) |allowed| {
            if (std.mem.eql(u8, allowed, origin)) return true;
        }
        return false;
    }

    pub fn allowsProperty(self: SitePolicy, property: []const u8) bool {
        for (self.properties) |allowed| {
            if (std.mem.eql(u8, allowed, property)) return true;
        }
        return false;
    }
};

pub const SiteTimezone = struct {
    zone_name: []u8,
    rebucket_pending: bool,
};

pub const Store = struct {
    database: turso.Database,
    connection: turso.Connection,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Store {
        var database = try turso.Database.open(allocator, .{ .path = path });
        errdefer database.deinit();
        const connection = try database.connect(.{ .busy_timeout_ms = 2_000 });
        return .{
            .database = database,
            .connection = connection,
        };
    }

    pub fn deinit(self: *Store) void {
        self.connection.deinit();
        self.database.deinit();
    }

    pub fn migrate(self: *Store) !void {
        try self.enableForeignKeys();
        var diagnostics = turso.Diagnostics{};
        _ = self.connection.execBatch(
            \\CREATE TABLE IF NOT EXISTS meta_migrations (
            \\  version INTEGER PRIMARY KEY,
            \\  name TEXT NOT NULL,
            \\  applied_at_utc_micros INTEGER NOT NULL
            \\);
        , .{ .diagnostics = &diagnostics }) catch |err| {
            std.log.err("metadata bootstrap failed: {s}", .{diagnostics.text()});
            return err;
        };
        const current = try self.migrationVersion();
        if (current > schema_version) return error.NewerMetadataSchema;
        if (current < 1) _ = self.connection.execBatch(
            \\CREATE TABLE IF NOT EXISTS sites (
            \\  id TEXT PRIMARY KEY,
            \\  slug TEXT NOT NULL UNIQUE,
            \\  name TEXT NOT NULL,
            \\  created_at_utc_micros INTEGER NOT NULL,
            \\  disabled_at_utc_micros INTEGER,
            \\  CHECK (length(id) = 36),
            \\  CHECK (length(slug) BETWEEN 1 AND 48),
            \\  CHECK (length(name) BETWEEN 1 AND 120)
            \\);
            \\CREATE TABLE IF NOT EXISTS site_origins (
            \\  site_id TEXT NOT NULL,
            \\  origin TEXT NOT NULL,
            \\  PRIMARY KEY (site_id, origin),
            \\  FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE
            \\);
            \\CREATE TABLE IF NOT EXISTS site_event_properties (
            \\  site_id TEXT NOT NULL,
            \\  property_name TEXT NOT NULL,
            \\  PRIMARY KEY (site_id, property_name),
            \\  FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE
            \\);
            \\CREATE TABLE IF NOT EXISTS goals (
            \\  id TEXT PRIMARY KEY,
            \\  site_id TEXT NOT NULL,
            \\  name TEXT NOT NULL,
            \\  match_kind INTEGER NOT NULL CHECK (match_kind BETWEEN 1 AND 3),
            \\  match_value TEXT NOT NULL,
            \\  created_at_utc_micros INTEGER NOT NULL,
            \\  FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
            \\  UNIQUE (site_id, name)
            \\);
            \\CREATE TABLE IF NOT EXISTS funnels (
            \\  id TEXT PRIMARY KEY,
            \\  site_id TEXT NOT NULL,
            \\  name TEXT NOT NULL,
            \\  created_at_utc_micros INTEGER NOT NULL,
            \\  FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
            \\  UNIQUE (site_id, name)
            \\);
            \\CREATE TABLE IF NOT EXISTS funnel_steps (
            \\  funnel_id TEXT NOT NULL,
            \\  step_index INTEGER NOT NULL CHECK (step_index BETWEEN 0 AND 7),
            \\  name TEXT NOT NULL,
            \\  match_kind INTEGER NOT NULL CHECK (match_kind BETWEEN 1 AND 3),
            \\  match_value TEXT NOT NULL,
            \\  PRIMARY KEY (funnel_id, step_index),
            \\  FOREIGN KEY (funnel_id) REFERENCES funnels(id) ON DELETE CASCADE
            \\);
            \\INSERT INTO meta_migrations VALUES (1, 'initial-metadata', 0);
        , .{ .diagnostics = &diagnostics }) catch |err| {
            std.log.err("metadata migration v1 failed: {s}", .{diagnostics.text()});
            return err;
        };
        if (current < 2) _ = self.connection.execBatch(
            \\CREATE TABLE IF NOT EXISTS auth_config (
            \\  id INTEGER PRIMARY KEY CHECK (id = 1),
            \\  origin TEXT NOT NULL,
            \\  rp_id TEXT NOT NULL,
            \\  created_at_utc_seconds INTEGER NOT NULL,
            \\  updated_at_utc_seconds INTEGER NOT NULL,
            \\  CHECK (length(origin) BETWEEN 8 AND 255),
            \\  CHECK (length(rp_id) BETWEEN 1 AND 253)
            \\);
            \\CREATE TABLE IF NOT EXISTS auth_users (
            \\  id TEXT PRIMARY KEY,
            \\  display_name TEXT NOT NULL,
            \\  created_at_utc_seconds INTEGER NOT NULL,
            \\  CHECK (length(id) BETWEEN 32 AND 128),
            \\  CHECK (length(display_name) BETWEEN 1 AND 120)
            \\);
            \\CREATE TABLE IF NOT EXISTS auth_credentials (
            \\  credential_id TEXT PRIMARY KEY,
            \\  user_id TEXT NOT NULL,
            \\  public_key TEXT NOT NULL,
            \\  algorithm INTEGER NOT NULL CHECK (algorithm IN (-7, -257)),
            \\  sign_count INTEGER NOT NULL CHECK (sign_count >= 0),
            \\  transports TEXT NOT NULL,
            \\  aaguid TEXT NOT NULL,
            \\  backup_eligible INTEGER NOT NULL CHECK (backup_eligible IN (0, 1)),
            \\  backup_state INTEGER NOT NULL CHECK (backup_state IN (0, 1)),
            \\  label TEXT NOT NULL,
            \\  created_at_utc_seconds INTEGER NOT NULL,
            \\  last_used_at_utc_seconds INTEGER,
            \\  revoked_at_utc_seconds INTEGER,
            \\  FOREIGN KEY (user_id) REFERENCES auth_users(id) ON DELETE CASCADE,
            \\  CHECK (length(credential_id) BETWEEN 1 AND 1374),
            \\  CHECK (length(public_key) BETWEEN 1 AND 16384),
            \\  CHECK (length(transports) <= 128),
            \\  CHECK (length(aaguid) <= 128),
            \\  CHECK (length(label) BETWEEN 1 AND 64)
            \\);
            \\CREATE TABLE IF NOT EXISTS auth_challenges (
            \\  id TEXT PRIMARY KEY,
            \\  purpose TEXT NOT NULL CHECK (purpose IN ('setup', 'register', 'login')),
            \\  challenge TEXT NOT NULL UNIQUE,
            \\  user_id TEXT NOT NULL,
            \\  binding_hash TEXT NOT NULL,
            \\  expires_at_utc_seconds INTEGER NOT NULL,
            \\  used_at_utc_seconds INTEGER,
            \\  created_at_utc_seconds INTEGER NOT NULL,
            \\  CHECK (length(id) BETWEEN 32 AND 128),
            \\  CHECK (length(challenge) BETWEEN 32 AND 128),
            \\  CHECK (length(user_id) <= 128),
            \\  CHECK (length(binding_hash) IN (0, 64))
            \\);
            \\CREATE TABLE IF NOT EXISTS auth_sessions (
            \\  token_hash TEXT PRIMARY KEY,
            \\  user_id TEXT NOT NULL,
            \\  csrf_token TEXT NOT NULL,
            \\  created_at_utc_seconds INTEGER NOT NULL,
            \\  expires_at_utc_seconds INTEGER NOT NULL,
            \\  last_seen_at_utc_seconds INTEGER NOT NULL,
            \\  revoked_at_utc_seconds INTEGER,
            \\  FOREIGN KEY (user_id) REFERENCES auth_users(id) ON DELETE CASCADE,
            \\  CHECK (length(token_hash) = 64),
            \\  CHECK (length(csrf_token) BETWEEN 32 AND 128)
            \\);
            \\CREATE TABLE IF NOT EXISTS auth_bootstrap (
            \\  id INTEGER PRIMARY KEY CHECK (id = 1),
            \\  token_hash TEXT NOT NULL CHECK (length(token_hash) = 64),
            \\  expires_at_utc_seconds INTEGER NOT NULL,
            \\  created_at_utc_seconds INTEGER NOT NULL,
            \\  consumed_at_utc_seconds INTEGER
            \\);
            \\CREATE INDEX IF NOT EXISTS auth_sessions_active
            \\  ON auth_sessions(expires_at_utc_seconds, revoked_at_utc_seconds);
            \\CREATE INDEX IF NOT EXISTS auth_challenges_expiry
            \\  ON auth_challenges(expires_at_utc_seconds, used_at_utc_seconds);
            \\INSERT INTO meta_migrations VALUES (2, 'passkey-owner-auth', 0);
        , .{ .diagnostics = &diagnostics }) catch |err| {
            std.log.err("metadata migration v2 failed: {s}", .{diagnostics.text()});
            return err;
        };
        if (current < 3) _ = self.connection.execBatch(
            \\CREATE TABLE IF NOT EXISTS site_timezones (
            \\  site_id TEXT PRIMARY KEY,
            \\  zone_name TEXT NOT NULL,
            \\  revision INTEGER NOT NULL,
            \\  rebucket_pending INTEGER NOT NULL,
            \\  FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
            \\  CHECK (length(zone_name) BETWEEN 1 AND 255),
            \\  CHECK (revision >= 1),
            \\  CHECK (rebucket_pending IN (0, 1))
            \\);
            \\INSERT INTO meta_migrations VALUES (3, 'explicit-site-timezones', 0);
        , .{ .diagnostics = &diagnostics }) catch |err| {
            std.log.err("metadata migration v3 failed: {s}", .{diagnostics.text()});
            return err;
        };
    }

    pub fn migrateProbe(self: *Store) !void {
        try self.migrate();
    }

    pub fn requireCurrent(self: *Store) !void {
        try self.enableForeignKeys();
        const current = try self.migrationVersion();
        if (current > schema_version) return error.NewerMetadataSchema;
        if (current < schema_version) return error.MetadataMigrationRequired;
    }

    fn enableForeignKeys(self: *Store) !void {
        var diagnostics = turso.Diagnostics{};
        _ = self.connection.exec(
            "PRAGMA foreign_keys = ON",
            &.{},
            .{ .diagnostics = &diagnostics },
        ) catch |err| {
            std.log.err("metadata connection setup failed: {s}", .{diagnostics.text()});
            return err;
        };
    }

    pub fn checkpoint(self: *Store) !void {
        var rows = try self.connection.query(
            "PRAGMA wal_checkpoint",
            &.{},
            .{},
        );
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.MissingCheckpointRow;
        if (try row.get(i64, 0) != 0) return error.CheckpointBusy;
        if ((try rows.next()) != null) return error.UnexpectedCheckpointRow;
        try rows.finish(null);
    }

    pub fn integrityCheck(self: *Store) !void {
        var rows = try self.connection.query(
            "PRAGMA integrity_check",
            &.{},
            .{},
        );
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.MissingIntegrityRow;
        if (!std.mem.eql(u8, try row.get([]const u8, 0), "ok")) {
            return error.MetadataIntegrityFailed;
        }
        if ((try rows.next()) != null) return error.UnexpectedIntegrityRow;
        try rows.finish(null);
    }

    pub fn seedProbeSite(self: *Store) !void {
        _ = try self.connection.execParams(
            \\INSERT INTO sites
            \\  (id, slug, name, created_at_utc_micros, disabled_at_utc_micros)
            \\VALUES (?1, ?2, ?3, 0, NULL)
            \\ON CONFLICT(id) DO UPDATE
            \\SET slug = excluded.slug, name = excluded.name
        ,
            .{
                "00000000-0000-4000-8000-000000000001",
                "probe",
                "M0 Probe",
            },
            .{},
        );
        _ = try self.connection.execParams(
            \\INSERT INTO site_timezones
            \\  (site_id, zone_name, revision, rebucket_pending)
            \\VALUES (?1, 'UTC', 1, 0)
            \\ON CONFLICT(site_id) DO NOTHING
        ,
            .{"00000000-0000-4000-8000-000000000001"},
            .{},
        );
    }

    pub fn addSite(
        self: *Store,
        id: []const u8,
        slug: []const u8,
        name: []const u8,
        origin: []const u8,
        timezone_name: []const u8,
        created_at: i64,
    ) !void {
        try domain.validateUuid(id);
        try domain.validateSlug(slug);
        try domain.validateName(name, 120);

        _ = try self.connection.execParams(
            \\INSERT INTO sites
            \\  (id, slug, name, created_at_utc_micros, disabled_at_utc_micros)
            \\VALUES (?1, ?2, ?3, ?4, NULL)
        ,
            .{ id, slug, name, created_at },
            .{},
        );
        errdefer _ = self.connection.execParams(
            "DELETE FROM sites WHERE id = ?1",
            .{id},
            .{},
        ) catch 0;
        _ = try self.connection.execParams(
            "INSERT INTO site_origins (site_id, origin) VALUES (?1, ?2)",
            .{ id, origin },
            .{},
        );
        _ = try self.connection.execParams(
            \\INSERT INTO site_timezones
            \\  (site_id, zone_name, revision, rebucket_pending)
            \\VALUES (?1, ?2, 1, 0)
        ,
            .{ id, timezone_name },
            .{},
        );
    }

    pub fn siteTimezone(
        self: *Store,
        allocator: std.mem.Allocator,
        site_id: []const u8,
    ) !SiteTimezone {
        try domain.validateUuid(site_id);
        var rows = try self.connection.queryParams(
            \\SELECT zone_name, rebucket_pending
            \\FROM site_timezones WHERE site_id = ?1
        ,
            .{site_id},
            .{},
        );
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.SiteTimezoneRequired;
        const result = SiteTimezone{
            .zone_name = try allocator.dupe(u8, try row.get([]const u8, 0)),
            .rebucket_pending = (try row.get(i64, 1)) != 0,
        };
        if ((try rows.next()) != null) return error.UnexpectedSiteTimezoneRow;
        try rows.finish(null);
        return result;
    }

    pub fn configureTimezoneReady(
        self: *Store,
        allocator: std.mem.Allocator,
        site_id: []const u8,
        zone_name: []const u8,
    ) !void {
        const existing = self.siteTimezone(allocator, site_id) catch |err| switch (err) {
            error.SiteTimezoneRequired => null,
            else => return err,
        };
        if (existing) |timezone| {
            if (timezone.rebucket_pending and
                !std.mem.eql(u8, timezone.zone_name, zone_name))
            {
                return error.TimezoneRebucketPending;
            }
            if (timezone.rebucket_pending and
                std.mem.eql(u8, timezone.zone_name, zone_name))
            {
                const changed = try self.connection.execParams(
                    \\UPDATE site_timezones SET rebucket_pending = 0
                    \\WHERE site_id = ?1 AND zone_name = ?2
                ,
                    .{ site_id, zone_name },
                    .{},
                );
                if (changed != 1) return error.SiteTimezoneNotFound;
                return;
            }
            if (!timezone.rebucket_pending and
                std.mem.eql(u8, timezone.zone_name, zone_name))
            {
                return;
            }
            const changed = try self.connection.execParams(
                \\UPDATE site_timezones
                \\SET zone_name = ?2, revision = revision + 1,
                \\    rebucket_pending = 0
                \\WHERE site_id = ?1
            ,
                .{ site_id, zone_name },
                .{},
            );
            if (changed != 1) return error.SiteTimezoneNotFound;
            return;
        }
        _ = try self.connection.execParams(
            \\INSERT INTO site_timezones
            \\  (site_id, zone_name, revision, rebucket_pending)
            \\VALUES (?1, ?2, 1, 0)
        ,
            .{ site_id, zone_name },
            .{},
        );
    }

    pub fn markTimezoneRebucketPending(
        self: *Store,
        allocator: std.mem.Allocator,
        site_id: []const u8,
        zone_name: []const u8,
    ) !void {
        const existing = self.siteTimezone(allocator, site_id) catch |err| switch (err) {
            error.SiteTimezoneRequired => null,
            else => return err,
        };
        if (existing) |timezone| {
            if (timezone.rebucket_pending) {
                if (!std.mem.eql(u8, timezone.zone_name, zone_name)) {
                    return error.TimezoneRebucketPending;
                }
                return;
            }
            const changed = try self.connection.execParams(
                \\UPDATE site_timezones
                \\SET zone_name = ?2, revision = revision + 1,
                \\    rebucket_pending = 1
                \\WHERE site_id = ?1
            ,
                .{ site_id, zone_name },
                .{},
            );
            if (changed != 1) return error.SiteTimezoneNotFound;
            return;
        }
        _ = try self.connection.execParams(
            \\INSERT INTO site_timezones
            \\  (site_id, zone_name, revision, rebucket_pending)
            \\VALUES (?1, ?2, 1, 1)
        ,
            .{ site_id, zone_name },
            .{},
        );
    }

    pub fn finishTimezoneRebucket(
        self: *Store,
        site_id: []const u8,
        zone_name: []const u8,
    ) !void {
        const changed = try self.connection.execParams(
            \\UPDATE site_timezones SET rebucket_pending = 0
            \\WHERE site_id = ?1 AND zone_name = ?2 AND rebucket_pending = 1
        ,
            .{ site_id, zone_name },
            .{},
        );
        if (changed != 1) return error.TimezoneRebucketStateChanged;
    }

    pub fn addOrigin(
        self: *Store,
        allocator: std.mem.Allocator,
        slug: []const u8,
        origin: []const u8,
    ) !void {
        const site_id = try self.siteIdBySlug(allocator, slug);
        _ = try self.connection.execParams(
            "INSERT INTO site_origins (site_id, origin) VALUES (?1, ?2)",
            .{ site_id, origin },
            .{},
        );
    }

    pub fn addProperty(
        self: *Store,
        allocator: std.mem.Allocator,
        slug: []const u8,
        property: []const u8,
    ) !void {
        try domain.validateIdentifier(property);
        const site_id = try self.siteIdBySlug(allocator, slug);
        _ = try self.connection.execParams(
            \\INSERT INTO site_event_properties (site_id, property_name)
            \\VALUES (?1, ?2)
        ,
            .{ site_id, property },
            .{},
        );
    }

    pub fn listSites(
        self: *Store,
        allocator: std.mem.Allocator,
    ) ![]Site {
        var rows = try self.connection.query(
            \\SELECT id, slug, name, disabled_at_utc_micros IS NOT NULL
            \\FROM sites ORDER BY slug
        ,
            &.{},
            .{},
        );
        defer rows.deinit();
        var result: std.ArrayList(Site) = .empty;
        while (try rows.next()) |row| {
            try result.append(allocator, .{
                .id = try allocator.dupe(u8, try row.get([]const u8, 0)),
                .slug = try allocator.dupe(u8, try row.get([]const u8, 1)),
                .name = try allocator.dupe(u8, try row.get([]const u8, 2)),
                .disabled = (try row.get(i64, 3)) != 0,
            });
        }
        try rows.finish(null);
        return result.toOwnedSlice(allocator);
    }

    pub fn disableSite(
        self: *Store,
        slug: []const u8,
        disabled_at: i64,
    ) !void {
        const changed = try self.connection.execParams(
            \\UPDATE sites SET disabled_at_utc_micros = ?2
            \\WHERE slug = ?1 AND disabled_at_utc_micros IS NULL
        ,
            .{ slug, disabled_at },
            .{},
        );
        if (changed != 1) return error.SiteNotFoundOrDisabled;
    }

    pub fn deleteSite(self: *Store, slug: []const u8) !void {
        const changed = try self.connection.execParams(
            "DELETE FROM sites WHERE slug = ?1",
            .{slug},
            .{},
        );
        if (changed != 1) return error.SiteNotFound;
    }

    pub fn addGoal(
        self: *Store,
        allocator: std.mem.Allocator,
        id: []const u8,
        site_slug: []const u8,
        name: []const u8,
        kind: domain.MatchKind,
        value: []const u8,
        created_at: i64,
    ) !void {
        try domain.validateUuid(id);
        try domain.validateName(name, 120);
        try validateMatch(kind, value);
        const site_id = try self.siteIdBySlug(allocator, site_slug);
        _ = try self.connection.execParams(
            \\INSERT INTO goals
            \\  (id, site_id, name, match_kind, match_value, created_at_utc_micros)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        ,
            .{ id, site_id, name, @backingInt(kind), value, created_at },
            .{},
        );
    }

    pub fn listGoals(
        self: *Store,
        allocator: std.mem.Allocator,
        site_slug: []const u8,
    ) ![]Goal {
        var rows = try self.connection.queryParams(
            \\SELECT goals.id, goals.name, goals.match_kind, goals.match_value
            \\FROM goals JOIN sites ON sites.id = goals.site_id
            \\WHERE sites.slug = ?1 ORDER BY goals.name
        ,
            .{site_slug},
            .{},
        );
        defer rows.deinit();
        var result: std.ArrayList(Goal) = .empty;
        while (try rows.next()) |row| {
            try result.append(allocator, .{
                .id = try allocator.dupe(u8, try row.get([]const u8, 0)),
                .name = try allocator.dupe(u8, try row.get([]const u8, 1)),
                .match_kind = @fromBackingInt(@intCast(try row.get(i64, 2))),
                .match_value = try allocator.dupe(u8, try row.get([]const u8, 3)),
            });
        }
        try rows.finish(null);
        return result.toOwnedSlice(allocator);
    }

    pub fn goalByName(
        self: *Store,
        allocator: std.mem.Allocator,
        site_slug: []const u8,
        name: []const u8,
    ) !Goal {
        try domain.validateSlug(site_slug);
        try domain.validateName(name, 120);
        var rows = try self.connection.queryParams(
            \\SELECT goals.id, goals.name, goals.match_kind, goals.match_value
            \\FROM goals JOIN sites ON sites.id = goals.site_id
            \\WHERE sites.slug = ?1 AND goals.name = ?2
        ,
            .{ site_slug, name },
            .{},
        );
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.GoalNotFound;
        const result = Goal{
            .id = try allocator.dupe(u8, try row.get([]const u8, 0)),
            .name = try allocator.dupe(u8, try row.get([]const u8, 1)),
            .match_kind = @fromBackingInt(@intCast(try row.get(i64, 2))),
            .match_value = try allocator.dupe(u8, try row.get([]const u8, 3)),
        };
        try rows.finish(null);
        return result;
    }

    pub fn deleteGoal(
        self: *Store,
        allocator: std.mem.Allocator,
        site_slug: []const u8,
        name: []const u8,
    ) !void {
        const site_id = try self.siteIdBySlug(allocator, site_slug);
        const changed = try self.connection.execParams(
            "DELETE FROM goals WHERE site_id = ?1 AND name = ?2",
            .{ site_id, name },
            .{},
        );
        if (changed != 1) return error.GoalNotFound;
    }

    pub fn addFunnel(
        self: *Store,
        allocator: std.mem.Allocator,
        id: []const u8,
        site_slug: []const u8,
        name: []const u8,
        steps: []const FunnelStepInput,
        created_at: i64,
    ) !void {
        try domain.validateUuid(id);
        try domain.validateName(name, 120);
        if (steps.len < 2 or steps.len > 8) return error.InvalidFunnelLength;
        for (steps) |step| {
            try domain.validateName(step.name, 120);
            try validateMatch(step.match_kind, step.match_value);
        }
        const site_id = try self.siteIdBySlug(allocator, site_slug);

        _ = try self.connection.execParams(
            \\INSERT INTO funnels (id, site_id, name, created_at_utc_micros)
            \\VALUES (?1, ?2, ?3, ?4)
        ,
            .{ id, site_id, name, created_at },
            .{},
        );
        errdefer _ = self.connection.execParams(
            "DELETE FROM funnels WHERE id = ?1",
            .{id},
            .{},
        ) catch 0;
        for (steps, 0..) |step, index| {
            _ = try self.connection.execParams(
                \\INSERT INTO funnel_steps
                \\  (funnel_id, step_index, name, match_kind, match_value)
                \\VALUES (?1, ?2, ?3, ?4, ?5)
            ,
                .{
                    id,
                    @as(i64, @intCast(index)),
                    step.name,
                    @backingInt(step.match_kind),
                    step.match_value,
                },
                .{},
            );
        }
    }

    pub fn funnelSteps(
        self: *Store,
        allocator: std.mem.Allocator,
        site_slug: []const u8,
        funnel_name: []const u8,
    ) ![]FunnelStep {
        var rows = try self.connection.queryParams(
            \\SELECT funnel_steps.step_index, funnel_steps.name,
            \\       funnel_steps.match_kind, funnel_steps.match_value
            \\FROM funnel_steps
            \\JOIN funnels ON funnels.id = funnel_steps.funnel_id
            \\JOIN sites ON sites.id = funnels.site_id
            \\WHERE sites.slug = ?1 AND funnels.name = ?2
            \\ORDER BY funnel_steps.step_index
        ,
            .{ site_slug, funnel_name },
            .{},
        );
        defer rows.deinit();
        var result: std.ArrayList(FunnelStep) = .empty;
        while (try rows.next()) |row| {
            try result.append(allocator, .{
                .index = try row.get(i64, 0),
                .name = try allocator.dupe(u8, try row.get([]const u8, 1)),
                .match_kind = @fromBackingInt(@intCast(try row.get(i64, 2))),
                .match_value = try allocator.dupe(u8, try row.get([]const u8, 3)),
            });
        }
        try rows.finish(null);
        if (result.items.len == 0) return error.FunnelNotFound;
        return result.toOwnedSlice(allocator);
    }

    pub fn listFunnels(
        self: *Store,
        allocator: std.mem.Allocator,
        site_slug: []const u8,
    ) ![]Funnel {
        var rows = try self.connection.queryParams(
            \\SELECT funnels.id, funnels.name, count(funnel_steps.step_index)
            \\FROM funnels
            \\JOIN sites ON sites.id = funnels.site_id
            \\LEFT JOIN funnel_steps ON funnel_steps.funnel_id = funnels.id
            \\WHERE sites.slug = ?1
            \\GROUP BY funnels.id, funnels.name
            \\ORDER BY funnels.name
        ,
            .{site_slug},
            .{},
        );
        defer rows.deinit();
        var result: std.ArrayList(Funnel) = .empty;
        while (try rows.next()) |row| {
            try result.append(allocator, .{
                .id = try allocator.dupe(u8, try row.get([]const u8, 0)),
                .name = try allocator.dupe(u8, try row.get([]const u8, 1)),
                .step_count = try row.get(i64, 2),
            });
        }
        try rows.finish(null);
        return result.toOwnedSlice(allocator);
    }

    pub fn deleteFunnel(
        self: *Store,
        allocator: std.mem.Allocator,
        site_slug: []const u8,
        name: []const u8,
    ) !void {
        const site_id = try self.siteIdBySlug(allocator, site_slug);
        const changed = try self.connection.execParams(
            "DELETE FROM funnels WHERE site_id = ?1 AND name = ?2",
            .{ site_id, name },
            .{},
        );
        if (changed != 1) return error.FunnelNotFound;
    }

    pub fn siteIdBySlug(
        self: *Store,
        allocator: std.mem.Allocator,
        slug: []const u8,
    ) ![]u8 {
        try domain.validateSlug(slug);
        var rows = try self.connection.queryParams(
            "SELECT id FROM sites WHERE slug = ?1",
            .{slug},
            .{},
        );
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.SiteNotFound;
        const result = try allocator.dupe(u8, try row.get([]const u8, 0));
        try rows.finish(null);
        return result;
    }

    pub fn sitePolicy(
        self: *Store,
        allocator: std.mem.Allocator,
        id: []const u8,
    ) !SitePolicy {
        try domain.validateUuid(id);
        var site_rows = try self.connection.queryParams(
            \\SELECT id, disabled_at_utc_micros IS NOT NULL
            \\FROM sites WHERE id = ?1
        ,
            .{id},
            .{},
        );
        defer site_rows.deinit();
        const site_row = (try site_rows.next()) orelse return error.SiteNotFound;
        const owned_id = try allocator.dupe(u8, try site_row.get([]const u8, 0));
        const disabled = (try site_row.get(i64, 1)) != 0;
        try site_rows.finish(null);

        const timezone = try self.siteTimezone(allocator, id);
        if (timezone.rebucket_pending) return error.TimezoneRebucketPending;

        const origins = try self.stringColumn(
            allocator,
            "SELECT origin FROM site_origins WHERE site_id = ?1 ORDER BY origin",
            id,
        );
        const properties = try self.stringColumn(
            allocator,
            \\SELECT property_name FROM site_event_properties
            \\WHERE site_id = ?1 ORDER BY property_name
        ,
            id,
        );
        return .{
            .id = owned_id,
            .disabled = disabled,
            .timezone_name = timezone.zone_name,
            .origins = origins,
            .properties = properties,
        };
    }

    pub fn siteIds(
        self: *Store,
        allocator: std.mem.Allocator,
    ) ![]const []u8 {
        var rows = try self.connection.query(
            "SELECT id FROM sites ORDER BY id",
            &.{},
            .{},
        );
        defer rows.deinit();
        var result: std.ArrayList([]u8) = .empty;
        while (try rows.next()) |row| {
            try result.append(
                allocator,
                try allocator.dupe(u8, try row.get([]const u8, 0)),
            );
        }
        try rows.finish(null);
        return result.toOwnedSlice(allocator);
    }

    pub fn siteCount(self: *Store) !i64 {
        return self.scalar("SELECT COUNT(*) FROM sites");
    }

    pub fn migrationVersion(self: *Store) !i64 {
        return self.scalar("SELECT COALESCE(MAX(version), 0) FROM meta_migrations");
    }

    pub fn counts(self: *Store) !Counts {
        return .{
            .sites = try self.scalar("SELECT COUNT(*) FROM sites"),
            .goals = try self.scalar("SELECT COUNT(*) FROM goals"),
            .funnels = try self.scalar("SELECT COUNT(*) FROM funnels"),
        };
    }

    fn scalar(self: *Store, sql: []const u8) !i64 {
        var rows = try self.connection.query(sql, &.{}, .{});
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.MissingCount;
        const result = try row.get(i64, 0);
        try rows.finish(null);
        return result;
    }

    fn stringColumn(
        self: *Store,
        allocator: std.mem.Allocator,
        sql: []const u8,
        parameter: []const u8,
    ) ![]const []u8 {
        var rows = try self.connection.queryParams(sql, .{parameter}, .{});
        defer rows.deinit();
        var result: std.ArrayList([]u8) = .empty;
        while (try rows.next()) |row| {
            try result.append(
                allocator,
                try allocator.dupe(u8, try row.get([]const u8, 0)),
            );
        }
        try rows.finish(null);
        return result.toOwnedSlice(allocator);
    }
};

fn validateMatch(kind: domain.MatchKind, value: []const u8) !void {
    switch (kind) {
        .event => try domain.validateIdentifier(value),
        .path, .prefix => _ = try domain.normalizePath(value),
    }
}
