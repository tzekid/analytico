const std = @import("std");
const turso = @import("turso");
const domain = @import("../domain.zig");

pub const schema_version: i64 = 7;
pub const maximum_excluded_networks: usize = 16;
pub const maximum_active_goals: usize = 32;
pub const maximum_saved_entities: usize = 32;
pub const maximum_saved_state_bytes: usize = 32 * 1024;
pub const default_daily_event_ceiling: i64 = 100_000;
pub const maximum_daily_event_ceiling: i64 = 10_000_000;

pub const Site = struct {
    id: []u8,
    slug: []u8,
    name: []u8,
    disabled: bool,
};

pub const SiteConfiguration = struct {
    id: []u8,
    slug: []u8,
    name: []u8,
    origins: []const []u8,
    timezone_name: []u8,
    default_currency: []u8,
};

pub const CreateSiteInput = struct {
    id: []const u8,
    slug: []const u8,
    name: []const u8,
    origin: []const u8,
    timezone_name: []const u8,
    default_currency: []const u8,
    created_at_utc_micros: i64,
};

pub const CreateSiteOutcome = struct {
    created: bool,
};

const StoredSiteIdentity = struct {
    id: []u8,
    name: []u8,
    disabled: bool,
};

const StoredSiteChildren = struct {
    origins: []const []u8,
    timezone_name: ?[]u8,
    default_currency: ?[]u8,
    traffic_policy_present: bool,

    fn deinit(self: StoredSiteChildren, allocator: std.mem.Allocator) void {
        for (self.origins) |origin| allocator.free(origin);
        allocator.free(self.origins);
        if (self.timezone_name) |value| allocator.free(value);
        if (self.default_currency) |value| allocator.free(value);
    }
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

pub const Segment = struct {
    id: []u8,
    name: []u8,
    canonical_filter_json: []u8,
    created_at_utc_micros: i64,
    updated_at_utc_micros: i64,
};

pub const SavedView = struct {
    id: []u8,
    name: []u8,
    canonical_query_json: []u8,
    created_at_utc_micros: i64,
    updated_at_utc_micros: i64,
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
    excluded_networks: []const []u8,
    strict_mode: bool,
    daily_event_ceiling: i64,

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

    pub fn excludesNetwork(self: SitePolicy, client_ip: []const u8) !bool {
        for (self.excluded_networks) |configured| {
            if (try domain.networkPrefixMatches(configured, client_ip)) return true;
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
        if (current < 4) _ = self.connection.execBatch(
            \\CREATE TABLE IF NOT EXISTS site_excluded_networks (
            \\  site_id TEXT NOT NULL,
            \\  network_prefix TEXT NOT NULL,
            \\  created_at_utc_micros INTEGER NOT NULL,
            \\  PRIMARY KEY (site_id, network_prefix),
            \\  FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
            \\  CHECK (length(network_prefix) BETWEEN 9 AND 64)
            \\);
            \\INSERT INTO meta_migrations VALUES (4, 'self-excluded-networks', 0);
        , .{ .diagnostics = &diagnostics }) catch |err| {
            std.log.err("metadata migration v4 failed: {s}", .{diagnostics.text()});
            return err;
        };
        if (current < 5) _ = self.connection.execBatch(
            \\CREATE TABLE IF NOT EXISTS site_traffic_policy (
            \\  site_id TEXT PRIMARY KEY,
            \\  strict_mode INTEGER NOT NULL,
            \\  daily_event_ceiling INTEGER NOT NULL,
            \\  updated_at_utc_micros INTEGER NOT NULL,
            \\  FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
            \\  CHECK (strict_mode IN (0, 1)),
            \\  CHECK (daily_event_ceiling BETWEEN 1 AND 10000000)
            \\);
            \\INSERT INTO site_traffic_policy
            \\  (site_id, strict_mode, daily_event_ceiling, updated_at_utc_micros)
            \\SELECT id, 0, 100000, 0 FROM sites
            \\ON CONFLICT(site_id) DO NOTHING;
            \\INSERT INTO meta_migrations VALUES (5, 'site-traffic-policy', 0);
        , .{ .diagnostics = &diagnostics }) catch |err| {
            std.log.err("metadata migration v5 failed: {s}", .{diagnostics.text()});
            return err;
        };
        if (current < 6) _ = self.connection.execBatch(
            \\CREATE TABLE IF NOT EXISTS site_settings (
            \\  site_id TEXT PRIMARY KEY,
            \\  default_currency TEXT NOT NULL,
            \\  FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
            \\  CHECK (default_currency = '' OR (
            \\    length(default_currency) = 3 AND
            \\    default_currency NOT GLOB '*[^A-Z]*'
            \\  ))
            \\);
            \\INSERT INTO site_settings (site_id, default_currency)
            \\SELECT id, '' FROM sites
            \\ON CONFLICT(site_id) DO NOTHING;
            \\CREATE UNIQUE INDEX IF NOT EXISTS site_origins_unique_origin
            \\  ON site_origins(origin);
            \\INSERT INTO meta_migrations VALUES (6, 'site-settings-and-origin-owner', 0);
        , .{ .diagnostics = &diagnostics }) catch |err| {
            std.log.err("metadata migration v6 failed: {s}", .{diagnostics.text()});
            return err;
        };
        if (current < 7) _ = self.connection.execBatch(
            \\CREATE TABLE IF NOT EXISTS segments (
            \\  id TEXT PRIMARY KEY,
            \\  site_id TEXT NOT NULL,
            \\  name TEXT NOT NULL,
            \\  filter_schema_version INTEGER NOT NULL
            \\    CHECK (filter_schema_version = 1),
            \\  canonical_filter_json TEXT NOT NULL,
            \\  created_at_utc_micros INTEGER NOT NULL,
            \\  updated_at_utc_micros INTEGER NOT NULL,
            \\  FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
            \\  UNIQUE (site_id, name),
            \\  CHECK (length(id) = 36),
            \\  CHECK (length(name) BETWEEN 1 AND 120),
            \\  CHECK (length(canonical_filter_json) BETWEEN 1 AND 32768)
            \\);
            \\CREATE TABLE IF NOT EXISTS saved_views (
            \\  id TEXT PRIMARY KEY,
            \\  site_id TEXT NOT NULL,
            \\  name TEXT NOT NULL,
            \\  query_schema_version INTEGER NOT NULL
            \\    CHECK (query_schema_version = 1),
            \\  canonical_query_json TEXT NOT NULL,
            \\  created_at_utc_micros INTEGER NOT NULL,
            \\  updated_at_utc_micros INTEGER NOT NULL,
            \\  FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
            \\  UNIQUE (site_id, name),
            \\  CHECK (length(id) = 36),
            \\  CHECK (length(name) BETWEEN 1 AND 120),
            \\  CHECK (length(canonical_query_json) BETWEEN 1 AND 32768)
            \\);
            \\INSERT INTO meta_migrations VALUES (7, 'segments-and-saved-views', 0);
        , .{ .diagnostics = &diagnostics }) catch |err| {
            std.log.err("metadata migration v7 failed: {s}", .{diagnostics.text()});
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
            \\INSERT INTO site_traffic_policy
            \\  (site_id, strict_mode, daily_event_ceiling, updated_at_utc_micros)
            \\VALUES (?1, 0, 100000, 0)
            \\ON CONFLICT(site_id) DO NOTHING
        ,
            .{"00000000-0000-4000-8000-000000000001"},
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
        _ = try self.connection.execParams(
            \\INSERT INTO site_settings (site_id, default_currency)
            \\VALUES (?1, '')
            \\ON CONFLICT(site_id) DO NOTHING
        ,
            .{"00000000-0000-4000-8000-000000000001"},
            .{},
        );
    }

    pub fn addSite(
        self: *Store,
        allocator: std.mem.Allocator,
        id: []const u8,
        slug: []const u8,
        name: []const u8,
        origin: []const u8,
        timezone_name: []const u8,
        created_at: i64,
    ) !void {
        const outcome = try self.createSite(allocator, .{
            .id = id,
            .slug = slug,
            .name = name,
            .origin = origin,
            .timezone_name = timezone_name,
            .default_currency = "",
            .created_at_utc_micros = created_at,
        });
        if (!outcome.created) return error.SiteAlreadyExists;
    }

    pub fn createSite(
        self: *Store,
        allocator: std.mem.Allocator,
        input: CreateSiteInput,
    ) !CreateSiteOutcome {
        try domain.validateUuid(input.id);
        try domain.validateSlug(input.slug);
        try domain.validateName(input.name, 120);
        try domain.validateCurrency(input.default_currency);
        const normalized_origin = try domain.normalizeOrigin(allocator, input.origin);
        defer allocator.free(normalized_origin);
        if (!std.mem.eql(u8, normalized_origin, input.origin)) {
            return error.InvalidOrigin;
        }

        const existing = try self.siteIdentityBySlug(allocator, input.slug);
        const origin_owner = try self.siteIdByOrigin(allocator, input.origin);
        defer if (origin_owner) |owner| allocator.free(owner);
        if (existing) |site| {
            defer allocator.free(site.id);
            defer allocator.free(site.name);
            if (site.disabled or !std.mem.eql(u8, site.name, input.name)) {
                return error.SiteSlugConflict;
            }
            var children = try self.siteChildren(allocator, site.id);
            defer children.deinit(allocator);
            if (origin_owner) |owner| {
                if (!std.mem.eql(u8, owner, site.id)) {
                    return error.SiteOriginConflict;
                }
            }
            if (children.origins.len != 0 and
                !containsString(children.origins, input.origin))
            {
                return error.SiteOriginConflict;
            }
            if (children.timezone_name) |stored_timezone| {
                if (!std.mem.eql(u8, stored_timezone, input.timezone_name)) {
                    return error.SiteTimezoneConflict;
                }
            }
            if (children.default_currency) |stored_currency| {
                if (!std.mem.eql(u8, stored_currency, input.default_currency)) {
                    return error.SiteCurrencyConflict;
                }
            }
            try self.completeMissingSiteChildren(site.id, input, children);
            return .{ .created = false };
        }
        if (origin_owner != null) return error.SiteOriginConflict;

        _ = try self.connection.execParams(
            \\INSERT INTO sites
            \\  (id, slug, name, created_at_utc_micros, disabled_at_utc_micros)
            \\VALUES (?1, ?2, ?3, ?4, NULL)
        ,
            .{ input.id, input.slug, input.name, input.created_at_utc_micros },
            .{},
        );
        self.insertSiteChildren(input.id, input) catch |write_error| {
            const deleted = self.connection.execParams(
                "DELETE FROM sites WHERE id = ?1",
                .{input.id},
                .{},
            ) catch return error.SiteCompensationFailed;
            if (deleted != 1) return error.SiteCompensationFailed;
            return write_error;
        };
        return .{ .created = true };
    }

    fn insertSiteChildren(
        self: *Store,
        site_id: []const u8,
        input: CreateSiteInput,
    ) !void {
        _ = try self.connection.execParams(
            "INSERT INTO site_origins (site_id, origin) VALUES (?1, ?2)",
            .{ site_id, input.origin },
            .{},
        );
        _ = try self.connection.execParams(
            \\INSERT INTO site_timezones
            \\  (site_id, zone_name, revision, rebucket_pending)
            \\VALUES (?1, ?2, 1, 0)
        ,
            .{ site_id, input.timezone_name },
            .{},
        );
        _ = try self.connection.execParams(
            \\INSERT INTO site_settings (site_id, default_currency)
            \\VALUES (?1, ?2)
        ,
            .{ site_id, input.default_currency },
            .{},
        );
        _ = try self.connection.execParams(
            \\INSERT INTO site_traffic_policy
            \\  (site_id, strict_mode, daily_event_ceiling, updated_at_utc_micros)
            \\VALUES (?1, 0, 100000, ?2)
        ,
            .{ site_id, input.created_at_utc_micros },
            .{},
        );
    }

    fn completeMissingSiteChildren(
        self: *Store,
        site_id: []const u8,
        input: CreateSiteInput,
        children: StoredSiteChildren,
    ) !void {
        if (children.origins.len == 0) {
            _ = try self.connection.execParams(
                "INSERT INTO site_origins (site_id, origin) VALUES (?1, ?2)",
                .{ site_id, input.origin },
                .{},
            );
        }
        if (children.timezone_name == null) {
            _ = try self.connection.execParams(
                \\INSERT INTO site_timezones
                \\  (site_id, zone_name, revision, rebucket_pending)
                \\VALUES (?1, ?2, 1, 0)
            ,
                .{ site_id, input.timezone_name },
                .{},
            );
        }
        if (children.default_currency == null) {
            _ = try self.connection.execParams(
                \\INSERT INTO site_settings (site_id, default_currency)
                \\VALUES (?1, ?2)
            ,
                .{ site_id, input.default_currency },
                .{},
            );
        }
        if (!children.traffic_policy_present) {
            _ = try self.connection.execParams(
                \\INSERT INTO site_traffic_policy
                \\  (site_id, strict_mode, daily_event_ceiling, updated_at_utc_micros)
                \\VALUES (?1, 0, 100000, ?2)
            ,
                .{ site_id, input.created_at_utc_micros },
                .{},
            );
        }
    }

    fn siteChildren(
        self: *Store,
        allocator: std.mem.Allocator,
        site_id: []const u8,
    ) !StoredSiteChildren {
        const origins = try self.stringColumn(
            allocator,
            "SELECT origin FROM site_origins WHERE site_id = ?1 ORDER BY origin",
            site_id,
        );
        errdefer {
            for (origins) |origin| allocator.free(origin);
            allocator.free(origins);
        }
        const timezone_name = try self.optionalString(
            allocator,
            "SELECT zone_name FROM site_timezones WHERE site_id = ?1",
            site_id,
        );
        errdefer if (timezone_name) |value| allocator.free(value);
        const default_currency = try self.optionalString(
            allocator,
            "SELECT default_currency FROM site_settings WHERE site_id = ?1",
            site_id,
        );
        errdefer if (default_currency) |value| allocator.free(value);
        return .{
            .origins = origins,
            .timezone_name = timezone_name,
            .default_currency = default_currency,
            .traffic_policy_present = try self.rowExists(
                "SELECT 1 FROM site_traffic_policy WHERE site_id = ?1",
                site_id,
            ),
        };
    }

    pub fn siteConfigurationBySlug(
        self: *Store,
        allocator: std.mem.Allocator,
        slug: []const u8,
    ) !SiteConfiguration {
        try domain.validateSlug(slug);
        const identity = (try self.siteIdentityBySlug(allocator, slug)) orelse
            return error.SiteNotFound;
        const origins = try self.stringColumn(
            allocator,
            "SELECT origin FROM site_origins WHERE site_id = ?1 ORDER BY origin",
            identity.id,
        );
        if (origins.len == 0) return error.SiteOriginRequired;
        const timezone_name = (try self.optionalString(
            allocator,
            "SELECT zone_name FROM site_timezones WHERE site_id = ?1",
            identity.id,
        )) orelse return error.SiteTimezoneRequired;
        const default_currency = (try self.optionalString(
            allocator,
            "SELECT default_currency FROM site_settings WHERE site_id = ?1",
            identity.id,
        )) orelse return error.SiteSettingsRequired;
        try domain.validateCurrency(default_currency);
        return .{
            .id = identity.id,
            .slug = try allocator.dupe(u8, slug),
            .name = identity.name,
            .origins = origins,
            .timezone_name = timezone_name,
            .default_currency = default_currency,
        };
    }

    fn siteIdentityBySlug(
        self: *Store,
        allocator: std.mem.Allocator,
        slug: []const u8,
    ) !?StoredSiteIdentity {
        var rows = try self.connection.queryParams(
            \\SELECT id, name, disabled_at_utc_micros IS NOT NULL
            \\FROM sites WHERE slug = ?1
        ,
            .{slug},
            .{},
        );
        defer rows.deinit();
        const row = (try rows.next()) orelse {
            try rows.finish(null);
            return null;
        };
        const result = StoredSiteIdentity{
            .id = try allocator.dupe(u8, try row.get([]const u8, 0)),
            .name = try allocator.dupe(u8, try row.get([]const u8, 1)),
            .disabled = (try row.get(i64, 2)) != 0,
        };
        if ((try rows.next()) != null) return error.UnexpectedSiteRow;
        try rows.finish(null);
        return result;
    }

    fn siteIdByOrigin(
        self: *Store,
        allocator: std.mem.Allocator,
        origin: []const u8,
    ) !?[]u8 {
        return self.optionalString(
            allocator,
            "SELECT site_id FROM site_origins WHERE origin = ?1",
            origin,
        );
    }

    fn optionalString(
        self: *Store,
        allocator: std.mem.Allocator,
        sql: []const u8,
        parameter: []const u8,
    ) !?[]u8 {
        var rows = try self.connection.queryParams(sql, .{parameter}, .{});
        defer rows.deinit();
        const row = (try rows.next()) orelse {
            try rows.finish(null);
            return null;
        };
        const result = try allocator.dupe(u8, try row.get([]const u8, 0));
        if ((try rows.next()) != null) return error.UnexpectedMetadataRow;
        try rows.finish(null);
        return result;
    }

    fn rowExists(
        self: *Store,
        sql: []const u8,
        parameter: []const u8,
    ) !bool {
        var rows = try self.connection.queryParams(sql, .{parameter}, .{});
        defer rows.deinit();
        const exists = (try rows.next()) != null;
        if (exists and (try rows.next()) != null) {
            return error.UnexpectedMetadataRow;
        }
        try rows.finish(null);
        return exists;
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

    pub fn addExcludedNetwork(
        self: *Store,
        allocator: std.mem.Allocator,
        slug: []const u8,
        input: []const u8,
        now_micros: i64,
    ) !void {
        const site_id = try self.siteIdBySlug(allocator, slug);
        var rows = try self.connection.queryParams(
            "SELECT count(*) FROM site_excluded_networks WHERE site_id = ?1",
            .{site_id},
            .{},
        );
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.MissingCountRow;
        const count = try row.get(i64, 0);
        try rows.finish(null);
        if (count < 0 or count >= maximum_excluded_networks) {
            return error.TooManyNetworkExclusions;
        }
        var buffer: [64]u8 = undefined;
        const canonical = try domain.canonicalNetworkPrefix(&buffer, input);
        _ = try self.connection.execParams(
            \\INSERT INTO site_excluded_networks (
            \\  site_id, network_prefix, created_at_utc_micros
            \\) VALUES (?1, ?2, ?3)
        ,
            .{ site_id, canonical, now_micros },
            .{},
        );
    }

    pub fn deleteExcludedNetwork(
        self: *Store,
        allocator: std.mem.Allocator,
        slug: []const u8,
        input: []const u8,
    ) !void {
        const site_id = try self.siteIdBySlug(allocator, slug);
        var buffer: [64]u8 = undefined;
        const canonical = try domain.canonicalNetworkPrefix(&buffer, input);
        const changed = try self.connection.execParams(
            \\DELETE FROM site_excluded_networks
            \\WHERE site_id = ?1 AND network_prefix = ?2
        ,
            .{ site_id, canonical },
            .{},
        );
        if (changed != 1) return error.NetworkExclusionNotFound;
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
        var count_rows = try self.connection.queryParams(
            "SELECT count(*) FROM goals WHERE site_id = ?1",
            .{site_id},
            .{},
        );
        defer count_rows.deinit();
        const count_row = (try count_rows.next()) orelse return error.MissingCountRow;
        const count = try count_row.get(i64, 0);
        try count_rows.finish(null);
        if (count < 0 or count >= maximum_active_goals) {
            return error.TooManyActiveGoals;
        }
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

    pub fn addSegment(
        self: *Store,
        allocator: std.mem.Allocator,
        id: []const u8,
        site_slug: []const u8,
        name: []const u8,
        canonical_filter_json: []const u8,
        now_micros: i64,
    ) !void {
        try validateSavedEntity(id, name, canonical_filter_json);
        const site_id = try self.siteIdBySlug(allocator, site_slug);
        const changed = try self.connection.execParams(
            \\INSERT INTO segments
            \\  (id, site_id, name, filter_schema_version,
            \\   canonical_filter_json, created_at_utc_micros,
            \\   updated_at_utc_micros)
            \\SELECT ?1, ?2, ?3, 1, ?4, ?5, ?5
            \\WHERE (SELECT count(*) FROM segments WHERE site_id = ?2) < ?6
        ,
            .{
                id,
                site_id,
                name,
                canonical_filter_json,
                now_micros,
                @as(i64, maximum_saved_entities),
            },
            .{},
        );
        if (changed != 1) return error.TooManySavedEntities;
    }

    pub fn listSegments(
        self: *Store,
        allocator: std.mem.Allocator,
        site_slug: []const u8,
    ) ![]Segment {
        return self.listSavedEntities(Segment, allocator, site_slug, .segment);
    }

    pub fn segmentById(
        self: *Store,
        allocator: std.mem.Allocator,
        site_slug: []const u8,
        id: []const u8,
    ) !Segment {
        try domain.validateUuid(id);
        return self.savedEntityById(Segment, allocator, site_slug, id, .segment);
    }

    pub fn renameSegment(
        self: *Store,
        allocator: std.mem.Allocator,
        site_slug: []const u8,
        id: []const u8,
        name: []const u8,
        now_micros: i64,
    ) !void {
        try self.renameSavedEntity(
            allocator,
            "segments",
            site_slug,
            id,
            name,
            now_micros,
            error.SegmentNotFound,
        );
    }

    pub fn updateSegmentState(
        self: *Store,
        allocator: std.mem.Allocator,
        site_slug: []const u8,
        id: []const u8,
        canonical_filter_json: []const u8,
        now_micros: i64,
    ) !void {
        try domain.validateUuid(id);
        if (canonical_filter_json.len == 0 or
            canonical_filter_json.len > maximum_saved_state_bytes or
            !std.unicode.utf8ValidateSlice(canonical_filter_json))
        {
            return error.InvalidSavedState;
        }
        const site_id = try self.siteIdBySlug(allocator, site_slug);
        const changed = try self.connection.execParams(
            \\UPDATE segments SET canonical_filter_json = ?3,
            \\  updated_at_utc_micros = ?4
            \\WHERE site_id = ?1 AND id = ?2
        ,
            .{ site_id, id, canonical_filter_json, now_micros },
            .{},
        );
        if (changed != 1) return error.SegmentNotFound;
    }

    pub fn deleteSegment(
        self: *Store,
        allocator: std.mem.Allocator,
        site_slug: []const u8,
        id: []const u8,
        exact_name: []const u8,
    ) !void {
        try self.deleteSavedEntity(
            allocator,
            "segments",
            site_slug,
            id,
            exact_name,
            error.SegmentNotFound,
        );
    }

    pub fn addSavedView(
        self: *Store,
        allocator: std.mem.Allocator,
        id: []const u8,
        site_slug: []const u8,
        name: []const u8,
        canonical_query_json: []const u8,
        now_micros: i64,
    ) !void {
        try validateSavedEntity(id, name, canonical_query_json);
        const site_id = try self.siteIdBySlug(allocator, site_slug);
        const changed = try self.connection.execParams(
            \\INSERT INTO saved_views
            \\  (id, site_id, name, query_schema_version,
            \\   canonical_query_json, created_at_utc_micros,
            \\   updated_at_utc_micros)
            \\SELECT ?1, ?2, ?3, 1, ?4, ?5, ?5
            \\WHERE (SELECT count(*) FROM saved_views WHERE site_id = ?2) < ?6
        ,
            .{
                id,
                site_id,
                name,
                canonical_query_json,
                now_micros,
                @as(i64, maximum_saved_entities),
            },
            .{},
        );
        if (changed != 1) return error.TooManySavedEntities;
    }

    pub fn listSavedViews(
        self: *Store,
        allocator: std.mem.Allocator,
        site_slug: []const u8,
    ) ![]SavedView {
        return self.listSavedEntities(SavedView, allocator, site_slug, .view);
    }

    pub fn savedViewById(
        self: *Store,
        allocator: std.mem.Allocator,
        site_slug: []const u8,
        id: []const u8,
    ) !SavedView {
        try domain.validateUuid(id);
        return self.savedEntityById(SavedView, allocator, site_slug, id, .view);
    }

    pub fn renameSavedView(
        self: *Store,
        allocator: std.mem.Allocator,
        site_slug: []const u8,
        id: []const u8,
        name: []const u8,
        now_micros: i64,
    ) !void {
        try self.renameSavedEntity(
            allocator,
            "saved_views",
            site_slug,
            id,
            name,
            now_micros,
            error.SavedViewNotFound,
        );
    }

    pub fn deleteSavedView(
        self: *Store,
        allocator: std.mem.Allocator,
        site_slug: []const u8,
        id: []const u8,
        exact_name: []const u8,
    ) !void {
        try self.deleteSavedEntity(
            allocator,
            "saved_views",
            site_slug,
            id,
            exact_name,
            error.SavedViewNotFound,
        );
    }

    const SavedKind = enum { segment, view };

    fn listSavedEntities(
        self: *Store,
        comptime T: type,
        allocator: std.mem.Allocator,
        site_slug: []const u8,
        kind: SavedKind,
    ) ![]T {
        try domain.validateSlug(site_slug);
        const sql = switch (kind) {
            .segment =>
            \\SELECT segments.id, segments.name, segments.canonical_filter_json,
            \\       segments.created_at_utc_micros, segments.updated_at_utc_micros
            \\FROM segments JOIN sites ON sites.id = segments.site_id
            \\WHERE sites.slug = ?1 ORDER BY segments.name, segments.id
            ,
            .view =>
            \\SELECT saved_views.id, saved_views.name, saved_views.canonical_query_json,
            \\       saved_views.created_at_utc_micros, saved_views.updated_at_utc_micros
            \\FROM saved_views JOIN sites ON sites.id = saved_views.site_id
            \\WHERE sites.slug = ?1 ORDER BY saved_views.name, saved_views.id
            ,
        };
        var rows = try self.connection.queryParams(sql, .{site_slug}, .{});
        defer rows.deinit();
        var result: std.ArrayList(T) = .empty;
        while (try rows.next()) |row| {
            if (result.items.len >= maximum_saved_entities) {
                return error.TooManySavedEntities;
            }
            try result.append(
                allocator,
                try savedEntityFromRow(T, allocator, row),
            );
        }
        try rows.finish(null);
        return result.toOwnedSlice(allocator);
    }

    fn savedEntityById(
        self: *Store,
        comptime T: type,
        allocator: std.mem.Allocator,
        site_slug: []const u8,
        id: []const u8,
        kind: SavedKind,
    ) !T {
        try domain.validateSlug(site_slug);
        const sql = switch (kind) {
            .segment =>
            \\SELECT segments.id, segments.name, segments.canonical_filter_json,
            \\       segments.created_at_utc_micros, segments.updated_at_utc_micros
            \\FROM segments JOIN sites ON sites.id = segments.site_id
            \\WHERE sites.slug = ?1 AND segments.id = ?2
            ,
            .view =>
            \\SELECT saved_views.id, saved_views.name, saved_views.canonical_query_json,
            \\       saved_views.created_at_utc_micros, saved_views.updated_at_utc_micros
            \\FROM saved_views JOIN sites ON sites.id = saved_views.site_id
            \\WHERE sites.slug = ?1 AND saved_views.id = ?2
            ,
        };
        var rows = try self.connection.queryParams(sql, .{ site_slug, id }, .{});
        defer rows.deinit();
        const row = (try rows.next()) orelse return switch (kind) {
            .segment => error.SegmentNotFound,
            .view => error.SavedViewNotFound,
        };
        const result = try savedEntityFromRow(T, allocator, row);
        if ((try rows.next()) != null) return error.UnexpectedSavedEntityRow;
        try rows.finish(null);
        return result;
    }

    fn renameSavedEntity(
        self: *Store,
        allocator: std.mem.Allocator,
        table: []const u8,
        site_slug: []const u8,
        id: []const u8,
        name: []const u8,
        now_micros: i64,
        not_found: anyerror,
    ) !void {
        try domain.validateUuid(id);
        try domain.validateName(name, 120);
        const site_id = try self.siteIdBySlug(allocator, site_slug);
        const sql = if (std.mem.eql(u8, table, "segments"))
            "UPDATE segments SET name = ?3, updated_at_utc_micros = ?4 WHERE site_id = ?1 AND id = ?2"
        else if (std.mem.eql(u8, table, "saved_views"))
            "UPDATE saved_views SET name = ?3, updated_at_utc_micros = ?4 WHERE site_id = ?1 AND id = ?2"
        else
            unreachable;
        const changed = try self.connection.execParams(
            sql,
            .{ site_id, id, name, now_micros },
            .{},
        );
        if (changed != 1) return not_found;
    }

    fn deleteSavedEntity(
        self: *Store,
        allocator: std.mem.Allocator,
        table: []const u8,
        site_slug: []const u8,
        id: []const u8,
        exact_name: []const u8,
        not_found: anyerror,
    ) !void {
        try domain.validateUuid(id);
        try domain.validateName(exact_name, 120);
        const site_id = try self.siteIdBySlug(allocator, site_slug);
        const sql = if (std.mem.eql(u8, table, "segments"))
            "DELETE FROM segments WHERE site_id = ?1 AND id = ?2 AND name = ?3"
        else if (std.mem.eql(u8, table, "saved_views"))
            "DELETE FROM saved_views WHERE site_id = ?1 AND id = ?2 AND name = ?3"
        else
            unreachable;
        const changed = try self.connection.execParams(
            sql,
            .{ site_id, id, exact_name },
            .{},
        );
        if (changed != 1) return not_found;
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
        if (origins.len == 0) return error.SiteOriginRequired;
        try self.requireValidSiteSettings(id);
        const properties = try self.stringColumn(
            allocator,
            \\SELECT property_name FROM site_event_properties
            \\WHERE site_id = ?1 ORDER BY property_name
        ,
            id,
        );
        const excluded_networks = try self.stringColumn(
            allocator,
            \\SELECT network_prefix FROM site_excluded_networks
            \\WHERE site_id = ?1 ORDER BY network_prefix
        ,
            id,
        );
        if (excluded_networks.len > maximum_excluded_networks) {
            return error.TooManyNetworkExclusions;
        }
        for (excluded_networks) |configured| {
            var buffer: [64]u8 = undefined;
            const canonical = try domain.canonicalNetworkPrefix(&buffer, configured);
            if (!std.mem.eql(u8, canonical, configured)) {
                return error.InvalidStoredNetworkPrefix;
            }
        }
        var traffic_rows = try self.connection.queryParams(
            \\SELECT strict_mode, daily_event_ceiling
            \\FROM site_traffic_policy WHERE site_id = ?1
        ,
            .{id},
            .{},
        );
        defer traffic_rows.deinit();
        const traffic_row = (try traffic_rows.next()) orelse
            return error.SiteTrafficPolicyRequired;
        const strict_value = try traffic_row.get(i64, 0);
        const daily_event_ceiling = try traffic_row.get(i64, 1);
        if ((try traffic_rows.next()) != null or
            (strict_value != 0 and strict_value != 1) or
            daily_event_ceiling < 1 or
            daily_event_ceiling > maximum_daily_event_ceiling)
        {
            return error.InvalidSiteTrafficPolicy;
        }
        try traffic_rows.finish(null);
        return .{
            .id = owned_id,
            .disabled = disabled,
            .timezone_name = timezone.zone_name,
            .origins = origins,
            .properties = properties,
            .excluded_networks = excluded_networks,
            .strict_mode = strict_value == 1,
            .daily_event_ceiling = daily_event_ceiling,
        };
    }

    fn requireValidSiteSettings(self: *Store, site_id: []const u8) !void {
        var rows = try self.connection.queryParams(
            "SELECT default_currency FROM site_settings WHERE site_id = ?1",
            .{site_id},
            .{},
        );
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.SiteSettingsRequired;
        try domain.validateCurrency(try row.get([]const u8, 0));
        if ((try rows.next()) != null) return error.UnexpectedSiteSettingsRow;
        try rows.finish(null);
    }

    pub fn updateTrafficPolicy(
        self: *Store,
        allocator: std.mem.Allocator,
        site_slug: []const u8,
        strict_mode: bool,
        daily_event_ceiling: i64,
        updated_at_micros: i64,
    ) !void {
        if (daily_event_ceiling < 1 or
            daily_event_ceiling > maximum_daily_event_ceiling)
        {
            return error.InvalidDailyEventCeiling;
        }
        const site_id = try self.siteIdBySlug(allocator, site_slug);
        if (strict_mode) {
            var rows = try self.connection.queryParams(
                "SELECT count(*) FROM goals WHERE site_id = ?1",
                .{site_id},
                .{},
            );
            defer rows.deinit();
            const row = (try rows.next()) orelse return error.MissingCountRow;
            const count = try row.get(i64, 0);
            try rows.finish(null);
            if (count < 0 or count > maximum_active_goals) {
                return error.TooManyActiveGoals;
            }
        }
        const changed = try self.connection.execParams(
            \\UPDATE site_traffic_policy
            \\SET strict_mode = ?2, daily_event_ceiling = ?3,
            \\    updated_at_utc_micros = ?4
            \\WHERE site_id = ?1
        ,
            .{
                site_id,
                @intFromBool(strict_mode),
                daily_event_ceiling,
                updated_at_micros,
            },
            .{},
        );
        if (changed != 1) return error.SiteTrafficPolicyRequired;
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

fn validateSavedEntity(
    id: []const u8,
    name: []const u8,
    canonical_json: []const u8,
) !void {
    try domain.validateUuid(id);
    try domain.validateName(name, 120);
    if (canonical_json.len == 0 or canonical_json.len > maximum_saved_state_bytes) {
        return error.InvalidSavedState;
    }
    if (!std.unicode.utf8ValidateSlice(canonical_json)) {
        return error.InvalidSavedState;
    }
}

fn savedEntityFromRow(
    comptime T: type,
    allocator: std.mem.Allocator,
    row: anytype,
) !T {
    const id = try allocator.dupe(u8, try row.get([]const u8, 0));
    const name = try allocator.dupe(u8, try row.get([]const u8, 1));
    const canonical_json = try allocator.dupe(u8, try row.get([]const u8, 2));
    const created = try row.get(i64, 3);
    const updated = try row.get(i64, 4);
    if (T == Segment) return .{
        .id = id,
        .name = name,
        .canonical_filter_json = canonical_json,
        .created_at_utc_micros = created,
        .updated_at_utc_micros = updated,
    };
    if (T == SavedView) return .{
        .id = id,
        .name = name,
        .canonical_query_json = canonical_json,
        .created_at_utc_micros = created,
        .updated_at_utc_micros = updated,
    };
    @compileError("unsupported saved entity type");
}

fn containsString(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, expected)) return true;
    }
    return false;
}

fn validateMatch(kind: domain.MatchKind, value: []const u8) !void {
    switch (kind) {
        .event => try domain.validateIdentifier(value),
        .path, .prefix => _ = try domain.normalizePath(value),
    }
}

test "site creation classifies exact retries before repairing missing children" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const backing_allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(
        backing_allocator,
        ".zig-cache/tmp/{s}/meta.db",
        .{temporary.sub_path},
    );
    defer backing_allocator.free(path);
    var store = try Store.open(backing_allocator, path);
    defer store.deinit();
    try store.migrate();

    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const input = CreateSiteInput{
        .id = "00000000-0000-4000-8000-000000000019",
        .slug = "example",
        .name = "Example",
        .origin = "https://example.com",
        .timezone_name = "UTC",
        .default_currency = "EUR",
        .created_at_utc_micros = 1,
    };
    try std.testing.expect((try store.createSite(allocator, input)).created);
    try std.testing.expect(!(try store.createSite(allocator, input)).created);

    var changed = input;
    changed.id = "00000000-0000-4000-8000-000000000020";
    changed.origin = "https://changed.example";
    try std.testing.expectError(
        error.SiteOriginConflict,
        store.createSite(allocator, changed),
    );
    changed = input;
    changed.timezone_name = "Europe/Berlin";
    try std.testing.expectError(
        error.SiteTimezoneConflict,
        store.createSite(allocator, changed),
    );
    changed = input;
    changed.default_currency = "USD";
    try std.testing.expectError(
        error.SiteCurrencyConflict,
        store.createSite(allocator, changed),
    );

    const complete = try store.siteConfigurationBySlug(allocator, input.slug);
    try std.testing.expectEqual(@as(usize, 1), complete.origins.len);
    try std.testing.expectEqualStrings(input.origin, complete.origins[0]);
    try std.testing.expectEqualStrings(input.timezone_name, complete.timezone_name);
    try std.testing.expectEqualStrings(input.default_currency, complete.default_currency);

    _ = try store.connection.execBatch(
        \\DELETE FROM site_origins WHERE site_id =
        \\  '00000000-0000-4000-8000-000000000019';
        \\DELETE FROM site_settings WHERE site_id =
        \\  '00000000-0000-4000-8000-000000000019';
    , .{});
    changed = input;
    changed.timezone_name = "Europe/Berlin";
    try std.testing.expectError(
        error.SiteTimezoneConflict,
        store.createSite(allocator, changed),
    );
    try std.testing.expect(!try store.rowExists(
        "SELECT 1 FROM site_origins WHERE site_id = ?1",
        input.id,
    ));
    try std.testing.expect(!try store.rowExists(
        "SELECT 1 FROM site_settings WHERE site_id = ?1",
        input.id,
    ));
    try std.testing.expect(!(try store.createSite(allocator, input)).created);
    const repaired = try store.siteConfigurationBySlug(allocator, input.slug);
    try std.testing.expectEqual(@as(usize, 1), repaired.origins.len);
    try std.testing.expectEqualStrings(input.origin, repaired.origins[0]);
    try std.testing.expectEqualStrings(input.timezone_name, repaired.timezone_name);
    try std.testing.expectEqualStrings(input.default_currency, repaired.default_currency);
    _ = try store.sitePolicy(allocator, input.id);
}

test "probe seed preserves the metadata 6 settings invariant" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/meta.db",
        .{temporary.sub_path},
    );
    defer allocator.free(path);
    var store = try Store.open(allocator, path);
    defer store.deinit();
    try store.migrateProbe();
    try store.seedProbeSite();

    const currency = (try store.optionalString(
        allocator,
        "SELECT default_currency FROM site_settings WHERE site_id = ?1",
        "00000000-0000-4000-8000-000000000001",
    )) orelse return error.MissingProbeSiteSettings;
    defer allocator.free(currency);
    try std.testing.expectEqualStrings("", currency);
}

test "saved segments and views remain site scoped and require exact deletion" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const backing_allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(
        backing_allocator,
        ".zig-cache/tmp/{s}/meta.db",
        .{temporary.sub_path},
    );
    defer backing_allocator.free(path);
    var store = try Store.open(backing_allocator, path);
    defer store.deinit();
    try store.migrate();

    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    _ = try store.createSite(allocator, .{
        .id = "00000000-0000-4000-8000-000000000030",
        .slug = "alpha",
        .name = "Alpha",
        .origin = "https://alpha.example",
        .timezone_name = "UTC",
        .default_currency = "",
        .created_at_utc_micros = 1,
    });
    _ = try store.createSite(allocator, .{
        .id = "00000000-0000-4000-8000-000000000031",
        .slug = "beta",
        .name = "Beta",
        .origin = "https://beta.example",
        .timezone_name = "UTC",
        .default_currency = "",
        .created_at_utc_micros = 1,
    });
    try store.addSegment(
        allocator,
        "00000000-0000-4000-8000-000000000032",
        "alpha",
        "Mobile",
        "{\"schema\":1,\"match\":\"all\",\"filters\":[]}",
        2,
    );
    try store.addSavedView(
        allocator,
        "00000000-0000-4000-8000-000000000033",
        "alpha",
        "Main trend",
        "{\"schema\":1}",
        2,
    );
    try std.testing.expectEqual(@as(usize, 1), (try store.listSegments(
        allocator,
        "alpha",
    )).len);
    try std.testing.expectEqual(@as(usize, 0), (try store.listSegments(
        allocator,
        "beta",
    )).len);
    try std.testing.expectError(
        error.SegmentNotFound,
        store.segmentById(
            allocator,
            "beta",
            "00000000-0000-4000-8000-000000000032",
        ),
    );
    try store.renameSegment(
        allocator,
        "alpha",
        "00000000-0000-4000-8000-000000000032",
        "Phones",
        3,
    );
    const renamed = try store.segmentById(
        allocator,
        "alpha",
        "00000000-0000-4000-8000-000000000032",
    );
    try std.testing.expectEqualStrings("Phones", renamed.name);
    try std.testing.expectEqual(@as(i64, 3), renamed.updated_at_utc_micros);
    try std.testing.expectError(
        error.SegmentNotFound,
        store.deleteSegment(
            allocator,
            "alpha",
            renamed.id,
            "Wrong name",
        ),
    );
    try store.deleteSegment(allocator, "alpha", renamed.id, renamed.name);
    try store.deleteSavedView(
        allocator,
        "alpha",
        "00000000-0000-4000-8000-000000000033",
        "Main trend",
    );
    try std.testing.expectEqual(@as(usize, 0), (try store.listSavedViews(
        allocator,
        "alpha",
    )).len);
}

test "saved segment and view counts stop exactly at the per-site bound" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const backing = std.testing.allocator;
    const path = try std.fmt.allocPrint(
        backing,
        ".zig-cache/tmp/{s}/meta.db",
        .{temporary.sub_path},
    );
    defer backing.free(path);
    var store = try Store.open(backing, path);
    defer store.deinit();
    try store.migrate();
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();
    _ = try store.createSite(allocator, .{
        .id = "00000000-0000-4000-8000-000000000030",
        .slug = "alpha",
        .name = "Alpha",
        .origin = "https://alpha.example",
        .timezone_name = "UTC",
        .default_currency = "",
        .created_at_utc_micros = 1,
    });
    for (0..maximum_saved_entities) |index| {
        const segment_id = try std.fmt.allocPrint(
            allocator,
            "00000000-0000-4000-8000-{d:0>12}",
            .{index + 1},
        );
        const segment_name = try std.fmt.allocPrint(
            allocator,
            "Segment {d}",
            .{index + 1},
        );
        try store.addSegment(
            allocator,
            segment_id,
            "alpha",
            segment_name,
            "{\"schema\":1,\"match\":\"all\",\"filters\":[]}",
            @intCast(index + 2),
        );
        const view_id = try std.fmt.allocPrint(
            allocator,
            "00000000-0000-4001-8000-{d:0>12}",
            .{index + 1},
        );
        const view_name = try std.fmt.allocPrint(
            allocator,
            "View {d}",
            .{index + 1},
        );
        try store.addSavedView(
            allocator,
            view_id,
            "alpha",
            view_name,
            "{\"schema\":1}",
            @intCast(index + 2),
        );
    }
    try std.testing.expectError(
        error.TooManySavedEntities,
        store.addSegment(
            allocator,
            "00000000-0000-4000-8000-000000000099",
            "alpha",
            "Segment overflow",
            "{\"schema\":1,\"match\":\"all\",\"filters\":[]}",
            100,
        ),
    );
    try std.testing.expectError(
        error.TooManySavedEntities,
        store.addSavedView(
            allocator,
            "00000000-0000-4001-8000-000000000099",
            "alpha",
            "View overflow",
            "{\"schema\":1}",
            100,
        ),
    );
}

test "returned child write failure synchronously compensates the new parent" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const backing_allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(
        backing_allocator,
        ".zig-cache/tmp/{s}/meta.db",
        .{temporary.sub_path},
    );
    defer backing_allocator.free(path);
    var store = try Store.open(backing_allocator, path);
    defer store.deinit();
    try store.migrate();
    _ = try store.connection.execBatch(
        \\CREATE TRIGGER reject_site_settings
        \\BEFORE INSERT ON site_settings
        \\BEGIN SELECT RAISE(ABORT, 'fixture child failure'); END;
    , .{});

    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    var failed = false;
    _ = store.createSite(arena.allocator(), .{
        .id = "00000000-0000-4000-8000-000000000021",
        .slug = "compensate",
        .name = "Compensate",
        .origin = "https://compensate.example",
        .timezone_name = "UTC",
        .default_currency = "",
        .created_at_utc_micros = 1,
    }) catch {
        failed = true;
    };
    try std.testing.expect(failed);
    try std.testing.expectEqual(@as(i64, 0), try store.siteCount());
}

test "failed compensation remains visible as an incomplete site" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const backing_allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(
        backing_allocator,
        ".zig-cache/tmp/{s}/meta.db",
        .{temporary.sub_path},
    );
    defer backing_allocator.free(path);
    var store = try Store.open(backing_allocator, path);
    defer store.deinit();
    try store.migrate();
    _ = try store.connection.execBatch(
        \\CREATE TRIGGER reject_site_settings
        \\BEFORE INSERT ON site_settings
        \\BEGIN SELECT RAISE(ABORT, 'fixture child failure'); END;
        \\CREATE TRIGGER reject_site_delete
        \\BEFORE DELETE ON sites
        \\BEGIN SELECT RAISE(ABORT, 'fixture compensation failure'); END;
    , .{});

    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const site_id = "00000000-0000-4000-8000-000000000022";
    try std.testing.expectError(
        error.SiteCompensationFailed,
        store.createSite(allocator, .{
            .id = site_id,
            .slug = "incomplete",
            .name = "Incomplete",
            .origin = "https://incomplete.example",
            .timezone_name = "UTC",
            .default_currency = "",
            .created_at_utc_micros = 1,
        }),
    );
    try std.testing.expectEqual(@as(i64, 1), try store.siteCount());
    try std.testing.expectError(
        error.SiteSettingsRequired,
        store.sitePolicy(allocator, site_id),
    );
}
