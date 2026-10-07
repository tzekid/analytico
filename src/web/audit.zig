//! The audit log: who changed settings, invited people, exported or deleted
//! data, created keys or share links. Written on the write connection inside
//! the change it describes.
const std = @import("std");
const ctx_mod = @import("ctx.zig");
const db_mod = @import("../db.zig");

pub fn record(ctx: *ctx_mod.Ctx, db: *db_mod.Db, site_id: ?i64, action: []const u8, detail: []const u8) !void {
    const user = ctx.user;
    var statement = try db.prepare(ctx.arena, "INSERT INTO audit_log(at_ms,user_id,actor,site_id,action,detail) VALUES(?,?,?,?,?,?)");
    defer statement.deinit();
    try statement.bindInt(1, ctx.now());
    try statement.bindOptionalInt(2, if (user) |value| value.id else null);
    try statement.bindText(3, if (user) |value| value.email else "system");
    try statement.bindOptionalInt(4, site_id);
    try statement.bindText(5, action);
    try statement.bindText(6, detail[0..@min(detail.len, 500)]);
    _ = try statement.step();
}

/// For work without a signed-in person (API keys, jobs).
pub fn recordAs(arena: std.mem.Allocator, db: *db_mod.Db, actor: []const u8, site_id: ?i64, action: []const u8, detail: []const u8, now_ms: i64) !void {
    var statement = try db.prepare(arena, "INSERT INTO audit_log(at_ms,user_id,actor,site_id,action,detail) VALUES(?,NULL,?,?,?,?)");
    defer statement.deinit();
    try statement.bindInt(1, now_ms);
    try statement.bindText(2, actor);
    try statement.bindOptionalInt(3, site_id);
    try statement.bindText(4, action);
    try statement.bindText(5, detail[0..@min(detail.len, 500)]);
    _ = try statement.step();
}
