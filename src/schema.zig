const std = @import("std");
const db_mod = @import("db.zig");

pub const current_version: i64 = 1;

const initial_sql =
    \\BEGIN IMMEDIATE;
    \\CREATE TABLE schema_migrations (
    \\  version INTEGER PRIMARY KEY,
    \\  name TEXT NOT NULL,
    \\  applied_at_ms INTEGER NOT NULL
    \\) STRICT;
    \\CREATE TABLE sites (
    \\  id INTEGER PRIMARY KEY,
    \\  public_id TEXT NOT NULL UNIQUE,
    \\  slug TEXT NOT NULL UNIQUE,
    \\  tracking_mode TEXT NOT NULL CHECK (tracking_mode IN ('lite','session')),
    \\  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
    \\  internal_secret BLOB NOT NULL CHECK (length(internal_secret)=32),
    \\  created_at_ms INTEGER NOT NULL
    \\) STRICT;
    \\CREATE TABLE site_origins (
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  origin TEXT NOT NULL,
    \\  PRIMARY KEY(site_id,origin)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE record_receipts (
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  event_id TEXT NOT NULL,
    \\  payload_hash TEXT NOT NULL CHECK(length(payload_hash)=64),
    \\  record_kind TEXT NOT NULL CHECK(record_kind IN ('page_view','page_summary','event')),
    \\  received_at_ms INTEGER NOT NULL,
    \\  PRIMARY KEY(site_id,event_id)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE page_views (
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  event_id TEXT NOT NULL,
    \\  page_id TEXT NOT NULL,
    \\  session_id TEXT,
    \\  occurred_at_ms INTEGER NOT NULL,
    \\  received_at_ms INTEGER NOT NULL,
    \\  received_date TEXT NOT NULL,
    \\  visitor_day_id TEXT NOT NULL,
    \\  tracking_mode TEXT NOT NULL,
    \\  path TEXT NOT NULL,
    \\  page_type TEXT,
    \\  content_id TEXT,
    \\  referrer_host TEXT,
    \\  utm_source TEXT,
    \\  utm_medium TEXT,
    \\  utm_campaign TEXT,
    \\  utm_content TEXT,
    \\  utm_term TEXT,
    \\  navigation_type TEXT,
    \\  viewport_class TEXT,
    \\  language TEXT,
    \\  release_id TEXT,
    \\  tracker_version TEXT NOT NULL,
    \\  consent_mode TEXT NOT NULL,
    \\  internal INTEGER NOT NULL CHECK(internal IN (0,1)),
    \\  country TEXT,
    \\  browser TEXT NOT NULL,
    \\  operating_system TEXT NOT NULL,
    \\  device TEXT NOT NULL,
    \\  traffic_class TEXT NOT NULL CHECK(traffic_class IN ('human_like','known_bot','monitor','internal','unknown')),
    \\  PRIMARY KEY(site_id,event_id),
    \\  UNIQUE(site_id,page_id)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE INDEX page_views_time ON page_views(site_id,received_at_ms);
    \\CREATE INDEX page_views_page ON page_views(site_id,path,received_at_ms);
    \\CREATE INDEX page_views_campaign ON page_views(site_id,utm_campaign,received_at_ms);
    \\CREATE INDEX page_views_session ON page_views(site_id,session_id,received_at_ms) WHERE session_id IS NOT NULL;
    \\CREATE TABLE page_summaries (
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  event_id TEXT NOT NULL,
    \\  page_id TEXT NOT NULL,
    \\  session_id TEXT,
    \\  occurred_at_ms INTEGER NOT NULL,
    \\  received_at_ms INTEGER NOT NULL,
    \\  tracking_mode TEXT NOT NULL,
    \\  visible_ms INTEGER NOT NULL,
    \\  active_ms INTEGER NOT NULL,
    \\  first_interaction_ms INTEGER,
    \\  interaction_count INTEGER NOT NULL,
    \\  max_scroll INTEGER NOT NULL,
    \\  sections_json TEXT NOT NULL,
    \\  last_section TEXT,
    \\  selection_count INTEGER NOT NULL,
    \\  copy_count INTEGER NOT NULL,
    \\  outbound_clicks INTEGER NOT NULL,
    \\  downloads INTEGER NOT NULL,
    \\  form_attempts INTEGER NOT NULL,
    \\  ttfb_ms INTEGER,
    \\  fcp_ms INTEGER,
    \\  lcp_ms INTEGER,
    \\  inp_ms INTEGER,
    \\  cls_milli INTEGER,
    \\  long_frame_count INTEGER,
    \\  blocking_ms INTEGER,
    \\  tracker_version TEXT NOT NULL,
    \\  consent_mode TEXT NOT NULL,
    \\  release_id TEXT,
    \\  internal INTEGER NOT NULL CHECK(internal IN (0,1)),
    \\  PRIMARY KEY(site_id,event_id),
    \\  UNIQUE(site_id,page_id)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE INDEX page_summaries_page ON page_summaries(site_id,page_id,received_at_ms);
    \\CREATE TABLE events (
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  event_id TEXT NOT NULL,
    \\  page_id TEXT,
    \\  session_id TEXT,
    \\  source TEXT NOT NULL CHECK(source IN ('browser','server')),
    \\  occurred_at_ms INTEGER NOT NULL,
    \\  received_at_ms INTEGER NOT NULL,
    \\  received_date TEXT NOT NULL,
    \\  tracking_mode TEXT NOT NULL,
    \\  name TEXT NOT NULL,
    \\  path TEXT,
    \\  release_id TEXT,
    \\  tracker_version TEXT NOT NULL,
    \\  consent_mode TEXT NOT NULL,
    \\  internal INTEGER NOT NULL CHECK(internal IN (0,1)),
    \\  value_minor INTEGER,
    \\  currency TEXT,
    \\  properties_json TEXT NOT NULL,
    \\  PRIMARY KEY(site_id,event_id)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE INDEX events_time ON events(site_id,received_at_ms);
    \\CREATE INDEX events_name ON events(site_id,name,received_at_ms);
    \\CREATE INDEX events_session ON events(site_id,session_id,received_at_ms) WHERE session_id IS NOT NULL;
    \\CREATE TABLE goals (
    \\  id INTEGER PRIMARY KEY,
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  name TEXT NOT NULL,
    \\  kind TEXT NOT NULL CHECK(kind IN ('event','path')),
    \\  match_value TEXT NOT NULL,
    \\  created_at_ms INTEGER NOT NULL,
    \\  UNIQUE(site_id,name)
    \\) STRICT;
    \\CREATE TABLE funnels (
    \\  id INTEGER PRIMARY KEY,
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  name TEXT NOT NULL,
    \\  unit TEXT NOT NULL DEFAULT 'session' CHECK(unit='session'),
    \\  window_ms INTEGER NOT NULL DEFAULT 86400000,
    \\  created_at_ms INTEGER NOT NULL,
    \\  UNIQUE(site_id,name)
    \\) STRICT;
    \\CREATE TABLE funnel_steps (
    \\  funnel_id INTEGER NOT NULL REFERENCES funnels(id) ON DELETE CASCADE,
    \\  step_index INTEGER NOT NULL CHECK(step_index BETWEEN 0 AND 15),
    \\  kind TEXT NOT NULL CHECK(kind IN ('event','path')),
    \\  match_value TEXT NOT NULL,
    \\  PRIMARY KEY(funnel_id,step_index)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE campaign_spend (
    \\  id INTEGER PRIMARY KEY,
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  spend_date TEXT NOT NULL,
    \\  source TEXT NOT NULL,
    \\  campaign TEXT NOT NULL,
    \\  content TEXT NOT NULL DEFAULT '',
    \\  amount_minor INTEGER NOT NULL CHECK(amount_minor>=0),
    \\  currency TEXT NOT NULL CHECK(length(currency)=3),
    \\  created_at_ms INTEGER NOT NULL,
    \\  UNIQUE(site_id,spend_date,source,campaign,content,currency)
    \\) STRICT;
    \\CREATE TABLE ingest_counters (
    \\  name TEXT PRIMARY KEY,
    \\  value INTEGER NOT NULL CHECK(value>=0)
    \\) STRICT, WITHOUT ROWID;
    \\INSERT INTO schema_migrations VALUES(1,'initial-cli-engine',unixepoch('subsec')*1000);
    \\PRAGMA user_version=1;
    \\COMMIT;
;

pub fn initialize(database: *db_mod.Db) !void {
    const current = try version(database, std.heap.c_allocator);
    if (current != 0) return error.DatabaseAlreadyInitialized;
    try database.exec(initial_sql);
}

pub fn requireCurrent(database: *db_mod.Db, allocator: std.mem.Allocator) !void {
    const actual = try version(database, allocator);
    if (actual < current_version) return error.MigrationRequired;
    if (actual > current_version) return error.NewerDatabaseSchema;
}

pub fn version(database: *db_mod.Db, allocator: std.mem.Allocator) !i64 {
    var statement = try database.prepare(allocator, "PRAGMA user_version");
    defer statement.deinit();
    if (try statement.step() != .row) return error.MissingSchemaVersion;
    return statement.columnInt(0);
}
