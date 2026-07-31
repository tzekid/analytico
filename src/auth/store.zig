const std = @import("std");
const meta = @import("../store/meta.zig");

const Allocator = std.mem.Allocator;

pub const Policy = struct {
    origin: []u8,
    rp_id: []u8,

    pub fn deinit(self: Policy, allocator: Allocator) void {
        allocator.free(self.origin);
        allocator.free(self.rp_id);
    }
};

pub const Challenge = struct {
    id: []u8,
    purpose: []u8,
    challenge: []u8,
    user_id: []u8,
    binding_hash: []u8,
    expires_at: i64,
    used_at: ?i64,

    pub fn deinit(self: Challenge, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.purpose);
        allocator.free(self.challenge);
        allocator.free(self.user_id);
        allocator.free(self.binding_hash);
    }
};

pub const Credential = struct {
    credential_id: []u8,
    user_id: []u8,
    public_key: []u8,
    algorithm: i64,
    sign_count: u32,
    transports: []u8,
    aaguid: []u8,
    backup_eligible: bool,
    backup_state: bool,
    label: []u8,
    created_at: i64,
    last_used_at: ?i64,
    revoked_at: ?i64,

    pub fn deinit(self: Credential, allocator: Allocator) void {
        allocator.free(self.credential_id);
        allocator.free(self.user_id);
        allocator.free(self.public_key);
        allocator.free(self.transports);
        allocator.free(self.aaguid);
        allocator.free(self.label);
    }
};

pub const Session = struct {
    token_hash: []u8,
    user_id: []u8,
    csrf_token: []u8,
    created_at: i64,
    expires_at: i64,
    last_seen_at: i64,
    revoked_at: ?i64,

    pub fn deinit(self: Session, allocator: Allocator) void {
        allocator.free(self.token_hash);
        allocator.free(self.user_id);
        allocator.free(self.csrf_token);
    }
};

pub const Store = struct {
    metadata: *meta.Store,

    pub fn policy(self: Store, allocator: Allocator) !?Policy {
        var rows = try self.metadata.connection.query(
            "SELECT origin, rp_id FROM auth_config WHERE id = 1",
            &.{},
            .{},
        );
        defer rows.deinit();
        const row = (try rows.next()) orelse return null;
        const origin = try allocator.dupe(u8, try row.get([]const u8, 0));
        errdefer allocator.free(origin);
        const rp_id = try allocator.dupe(u8, try row.get([]const u8, 1));
        try rows.finish(null);
        return .{ .origin = origin, .rp_id = rp_id };
    }

    pub fn configure(
        self: Store,
        allocator: Allocator,
        origin: []const u8,
        rp_id: []const u8,
        now: i64,
    ) !void {
        if (try self.activeCredentialCount() != 0) {
            const existing = (try self.policy(allocator)) orelse
                return error.AuthPolicyMissing;
            defer existing.deinit(allocator);
            if (!std.mem.eql(u8, existing.origin, origin) or
                !std.mem.eql(u8, existing.rp_id, rp_id))
            {
                return error.AuthPolicyLocked;
            }
            return;
        }
        _ = try self.metadata.connection.execParams(
            \\INSERT INTO auth_config(
            \\  id, origin, rp_id, created_at_utc_seconds, updated_at_utc_seconds
            \\) VALUES (1, ?1, ?2, ?3, ?3)
            \\ON CONFLICT(id) DO UPDATE SET
            \\  origin = excluded.origin,
            \\  rp_id = excluded.rp_id,
            \\  updated_at_utc_seconds = excluded.updated_at_utc_seconds
        ,
            .{ origin, rp_id, now },
            .{},
        );
    }

    pub fn activeCredentialCount(self: Store) !i64 {
        return self.scalar(
            "SELECT COUNT(*) FROM auth_credentials WHERE revoked_at_utc_seconds IS NULL",
        );
    }

    pub fn activeSessionCount(self: Store, now: i64) !i64 {
        return self.scalarParams(
            \\SELECT COUNT(*) FROM auth_sessions
            \\WHERE revoked_at_utc_seconds IS NULL AND expires_at_utc_seconds > ?1
        ,
            .{now},
        );
    }

    pub fn bootstrapActive(self: Store, now: i64) !bool {
        return (try self.scalarParams(
            \\SELECT COUNT(*) FROM auth_bootstrap
            \\WHERE id = 1 AND consumed_at_utc_seconds IS NULL
            \\  AND expires_at_utc_seconds > ?1
        ,
            .{now},
        )) == 1;
    }

    pub fn bootstrapMatches(
        self: Store,
        token_hash: []const u8,
        now: i64,
    ) !bool {
        return (try self.scalarParams(
            \\SELECT COUNT(*) FROM auth_bootstrap
            \\WHERE id = 1 AND token_hash = ?1
            \\  AND consumed_at_utc_seconds IS NULL
            \\  AND expires_at_utc_seconds > ?2
        ,
            .{ token_hash, now },
        )) == 1;
    }

    pub fn putBootstrap(
        self: Store,
        token_hash: []const u8,
        created_at: i64,
        expires_at: i64,
    ) !void {
        _ = try self.metadata.connection.execParams(
            \\INSERT INTO auth_bootstrap(
            \\  id, token_hash, expires_at_utc_seconds,
            \\  created_at_utc_seconds, consumed_at_utc_seconds
            \\) VALUES (1, ?1, ?2, ?3, NULL)
            \\ON CONFLICT(id) DO UPDATE SET
            \\  token_hash = excluded.token_hash,
            \\  expires_at_utc_seconds = excluded.expires_at_utc_seconds,
            \\  created_at_utc_seconds = excluded.created_at_utc_seconds,
            \\  consumed_at_utc_seconds = NULL
        ,
            .{ token_hash, expires_at, created_at },
            .{},
        );
    }

    pub fn consumeBootstrap(
        self: Store,
        token_hash: []const u8,
        now: i64,
    ) !bool {
        return try self.metadata.connection.execParams(
            \\UPDATE auth_bootstrap SET consumed_at_utc_seconds = ?2
            \\WHERE id = 1 AND token_hash = ?1
            \\  AND consumed_at_utc_seconds IS NULL
            \\  AND expires_at_utc_seconds > ?2
        ,
            .{ token_hash, now },
            .{},
        ) == 1;
    }

    pub fn putChallenge(
        self: Store,
        id: []const u8,
        purpose: []const u8,
        challenge: []const u8,
        user_id: []const u8,
        binding_hash: []const u8,
        created_at: i64,
        expires_at: i64,
    ) !void {
        try self.prune(created_at);
        if (try self.scalar("SELECT COUNT(*) FROM auth_challenges") >= 64) {
            return error.TooManyAuthChallenges;
        }
        _ = try self.metadata.connection.execParams(
            \\INSERT INTO auth_challenges(
            \\  id, purpose, challenge, user_id, binding_hash,
            \\  expires_at_utc_seconds, used_at_utc_seconds,
            \\  created_at_utc_seconds
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL, ?7)
        ,
            .{
                id,
                purpose,
                challenge,
                user_id,
                binding_hash,
                expires_at,
                created_at,
            },
            .{},
        );
    }

    pub fn findChallenge(
        self: Store,
        allocator: Allocator,
        id: []const u8,
    ) !?Challenge {
        var rows = try self.metadata.connection.queryParams(
            \\SELECT id, purpose, challenge, user_id, binding_hash,
            \\  expires_at_utc_seconds, used_at_utc_seconds
            \\FROM auth_challenges WHERE id = ?1
        ,
            .{id},
            .{},
        );
        defer rows.deinit();
        const row = (try rows.next()) orelse return null;
        const result = Challenge{
            .id = try allocator.dupe(u8, try row.get([]const u8, 0)),
            .purpose = try allocator.dupe(u8, try row.get([]const u8, 1)),
            .challenge = try allocator.dupe(u8, try row.get([]const u8, 2)),
            .user_id = try allocator.dupe(u8, try row.get([]const u8, 3)),
            .binding_hash = try allocator.dupe(u8, try row.get([]const u8, 4)),
            .expires_at = try row.get(i64, 5),
            .used_at = try row.get(?i64, 6),
        };
        try rows.finish(null);
        return result;
    }

    pub fn consumeChallenge(
        self: Store,
        id: []const u8,
        purpose: []const u8,
        now: i64,
    ) !bool {
        return try self.metadata.connection.execParams(
            \\UPDATE auth_challenges SET used_at_utc_seconds = ?3
            \\WHERE id = ?1 AND purpose = ?2
            \\  AND used_at_utc_seconds IS NULL
            \\  AND expires_at_utc_seconds > ?3
        ,
            .{ id, purpose, now },
            .{},
        ) == 1;
    }

    pub fn ensureOwner(
        self: Store,
        id: []const u8,
        display_name: []const u8,
        now: i64,
    ) !void {
        _ = try self.metadata.connection.execParams(
            \\INSERT OR IGNORE INTO auth_users(
            \\  id, display_name, created_at_utc_seconds
            \\) VALUES (?1, ?2, ?3)
        ,
            .{ id, display_name, now },
            .{},
        );
    }

    pub fn firstOwnerId(self: Store, allocator: Allocator) !?[]u8 {
        var rows = try self.metadata.connection.query(
            "SELECT id FROM auth_users ORDER BY created_at_utc_seconds LIMIT 1",
            &.{},
            .{},
        );
        defer rows.deinit();
        const row = (try rows.next()) orelse return null;
        const result = try allocator.dupe(u8, try row.get([]const u8, 0));
        try rows.finish(null);
        return result;
    }

    pub fn insertCredential(self: Store, value: Credential) !void {
        if (try self.activeCredentialCount() >= 16) {
            return error.TooManyCredentials;
        }
        _ = try self.metadata.connection.execParams(
            \\INSERT INTO auth_credentials(
            \\  credential_id, user_id, public_key, algorithm, sign_count,
            \\  transports, aaguid, backup_eligible, backup_state, label,
            \\  created_at_utc_seconds, last_used_at_utc_seconds,
            \\  revoked_at_utc_seconds
            \\) VALUES (
            \\  ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, NULL, NULL
            \\)
        ,
            .{
                value.credential_id,
                value.user_id,
                value.public_key,
                value.algorithm,
                value.sign_count,
                value.transports,
                value.aaguid,
                @as(i64, @intFromBool(value.backup_eligible)),
                @as(i64, @intFromBool(value.backup_state)),
                value.label,
                value.created_at,
            },
            .{},
        );
    }

    pub fn findCredential(
        self: Store,
        allocator: Allocator,
        id: []const u8,
    ) !?Credential {
        var rows = try self.metadata.connection.queryParams(
            credential_select ++ " WHERE credential_id = ?1",
            .{id},
            .{},
        );
        defer rows.deinit();
        const row = (try rows.next()) orelse return null;
        const result = try credentialFromRow(allocator, row);
        try rows.finish(null);
        return result;
    }

    pub fn listCredentials(
        self: Store,
        allocator: Allocator,
    ) ![]Credential {
        var rows = try self.metadata.connection.query(
            credential_select ++ " ORDER BY created_at_utc_seconds, credential_id",
            &.{},
            .{},
        );
        defer rows.deinit();
        var result: std.ArrayList(Credential) = .empty;
        errdefer {
            for (result.items) |item| item.deinit(allocator);
            result.deinit(allocator);
        }
        while (try rows.next()) |row| {
            try result.append(allocator, try credentialFromRow(allocator, row));
        }
        try rows.finish(null);
        return result.toOwnedSlice(allocator);
    }

    pub fn updateCredentialUse(
        self: Store,
        id: []const u8,
        sign_count: u32,
        backup_state: bool,
        now: i64,
    ) !void {
        _ = try self.metadata.connection.execParams(
            \\UPDATE auth_credentials SET sign_count = ?2,
            \\  backup_state = ?3, last_used_at_utc_seconds = ?4
            \\WHERE credential_id = ?1 AND revoked_at_utc_seconds IS NULL
        ,
            .{ id, sign_count, @as(i64, @intFromBool(backup_state)), now },
            .{},
        );
    }

    pub fn updateCredentialLabel(
        self: Store,
        id: []const u8,
        label: []const u8,
    ) !bool {
        return try self.metadata.connection.execParams(
            \\UPDATE auth_credentials SET label = ?2
            \\WHERE credential_id = ?1 AND revoked_at_utc_seconds IS NULL
        ,
            .{ id, label },
            .{},
        ) == 1;
    }

    pub fn revokeCredential(
        self: Store,
        id: []const u8,
        now: i64,
    ) !bool {
        return try self.metadata.connection.execParams(
            \\UPDATE auth_credentials SET revoked_at_utc_seconds = ?2
            \\WHERE credential_id = ?1 AND revoked_at_utc_seconds IS NULL
        ,
            .{ id, now },
            .{},
        ) == 1;
    }

    pub fn putSession(
        self: Store,
        token_hash: []const u8,
        user_id: []const u8,
        csrf_token: []const u8,
        now: i64,
        expires_at: i64,
    ) !void {
        try self.prune(now);
        if (try self.activeSessionCount(now) >= 16) {
            _ = try self.metadata.connection.execParams(
                \\UPDATE auth_sessions SET revoked_at_utc_seconds = ?1
                \\WHERE token_hash = (
                \\  SELECT token_hash FROM auth_sessions
                \\  WHERE revoked_at_utc_seconds IS NULL
                \\  ORDER BY created_at_utc_seconds LIMIT 1
                \\)
            ,
                .{now},
                .{},
            );
        }
        _ = try self.metadata.connection.execParams(
            \\INSERT INTO auth_sessions(
            \\  token_hash, user_id, csrf_token, created_at_utc_seconds,
            \\  expires_at_utc_seconds, last_seen_at_utc_seconds,
            \\  revoked_at_utc_seconds
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?4, NULL)
        ,
            .{ token_hash, user_id, csrf_token, now, expires_at },
            .{},
        );
    }

    pub fn findSession(
        self: Store,
        allocator: Allocator,
        token_hash: []const u8,
    ) !?Session {
        var rows = try self.metadata.connection.queryParams(
            \\SELECT token_hash, user_id, csrf_token,
            \\  created_at_utc_seconds, expires_at_utc_seconds,
            \\  last_seen_at_utc_seconds, revoked_at_utc_seconds
            \\FROM auth_sessions WHERE token_hash = ?1
        ,
            .{token_hash},
            .{},
        );
        defer rows.deinit();
        const row = (try rows.next()) orelse return null;
        const result = Session{
            .token_hash = try allocator.dupe(u8, try row.get([]const u8, 0)),
            .user_id = try allocator.dupe(u8, try row.get([]const u8, 1)),
            .csrf_token = try allocator.dupe(u8, try row.get([]const u8, 2)),
            .created_at = try row.get(i64, 3),
            .expires_at = try row.get(i64, 4),
            .last_seen_at = try row.get(i64, 5),
            .revoked_at = try row.get(?i64, 6),
        };
        try rows.finish(null);
        return result;
    }

    pub fn listSessions(self: Store, allocator: Allocator) ![]Session {
        var rows = try self.metadata.connection.query(
            \\SELECT token_hash, user_id, csrf_token,
            \\  created_at_utc_seconds, expires_at_utc_seconds,
            \\  last_seen_at_utc_seconds, revoked_at_utc_seconds
            \\FROM auth_sessions
            \\WHERE revoked_at_utc_seconds IS NULL
            \\ORDER BY created_at_utc_seconds DESC LIMIT 16
        ,
            &.{},
            .{},
        );
        defer rows.deinit();
        var result: std.ArrayList(Session) = .empty;
        errdefer {
            for (result.items) |item| item.deinit(allocator);
            result.deinit(allocator);
        }
        while (try rows.next()) |row| {
            try result.append(allocator, .{
                .token_hash = try allocator.dupe(u8, try row.get([]const u8, 0)),
                .user_id = try allocator.dupe(u8, try row.get([]const u8, 1)),
                .csrf_token = try allocator.dupe(u8, try row.get([]const u8, 2)),
                .created_at = try row.get(i64, 3),
                .expires_at = try row.get(i64, 4),
                .last_seen_at = try row.get(i64, 5),
                .revoked_at = try row.get(?i64, 6),
            });
        }
        try rows.finish(null);
        return result.toOwnedSlice(allocator);
    }

    pub fn touchSession(
        self: Store,
        token_hash: []const u8,
        now: i64,
    ) !void {
        _ = try self.metadata.connection.execParams(
            \\UPDATE auth_sessions SET last_seen_at_utc_seconds = ?2
            \\WHERE token_hash = ?1
        ,
            .{ token_hash, now },
            .{},
        );
    }

    pub fn revokeSession(
        self: Store,
        token_hash: []const u8,
        now: i64,
    ) !bool {
        return try self.metadata.connection.execParams(
            \\UPDATE auth_sessions SET revoked_at_utc_seconds = ?2
            \\WHERE token_hash = ?1 AND revoked_at_utc_seconds IS NULL
        ,
            .{ token_hash, now },
            .{},
        ) == 1;
    }

    pub fn reset(self: Store) !void {
        _ = try self.metadata.connection.execBatch(
            \\DELETE FROM auth_sessions;
            \\DELETE FROM auth_challenges;
            \\DELETE FROM auth_credentials;
            \\DELETE FROM auth_users;
            \\DELETE FROM auth_bootstrap;
        ,
            .{},
        );
    }

    pub fn prune(self: Store, now: i64) !void {
        _ = try self.metadata.connection.execParams(
            \\DELETE FROM auth_challenges
            \\WHERE expires_at_utc_seconds <= ?1
            \\  OR used_at_utc_seconds IS NOT NULL
        ,
            .{now},
            .{},
        );
        _ = try self.metadata.connection.execParams(
            \\DELETE FROM auth_sessions
            \\WHERE expires_at_utc_seconds <= ?1
            \\  OR revoked_at_utc_seconds IS NOT NULL
        ,
            .{now},
            .{},
        );
    }

    fn scalar(self: Store, sql: []const u8) !i64 {
        var rows = try self.metadata.connection.query(sql, &.{}, .{});
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.MissingAuthScalar;
        const result = try row.get(i64, 0);
        try rows.finish(null);
        return result;
    }

    fn scalarParams(self: Store, sql: []const u8, params: anytype) !i64 {
        var rows = try self.metadata.connection.queryParams(sql, params, .{});
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.MissingAuthScalar;
        const result = try row.get(i64, 0);
        try rows.finish(null);
        return result;
    }
};

const credential_select =
    \\SELECT credential_id, user_id, public_key, algorithm, sign_count,
    \\  transports, aaguid, backup_eligible, backup_state, label,
    \\  created_at_utc_seconds, last_used_at_utc_seconds,
    \\  revoked_at_utc_seconds
    \\FROM auth_credentials
;

fn credentialFromRow(allocator: Allocator, row: anytype) !Credential {
    return .{
        .credential_id = try allocator.dupe(u8, try row.get([]const u8, 0)),
        .user_id = try allocator.dupe(u8, try row.get([]const u8, 1)),
        .public_key = try allocator.dupe(u8, try row.get([]const u8, 2)),
        .algorithm = try row.get(i64, 3),
        .sign_count = try row.get(u32, 4),
        .transports = try allocator.dupe(u8, try row.get([]const u8, 5)),
        .aaguid = try allocator.dupe(u8, try row.get([]const u8, 6)),
        .backup_eligible = try row.get(bool, 7),
        .backup_state = try row.get(bool, 8),
        .label = try allocator.dupe(u8, try row.get([]const u8, 9)),
        .created_at = try row.get(i64, 10),
        .last_used_at = try row.get(?i64, 11),
        .revoked_at = try row.get(?i64, 12),
    };
}
