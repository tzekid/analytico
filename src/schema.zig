//! The database schema: one baseline (schema 6) for new databases, then
//! numbered migrations from 7, each one transaction run after a verified
//! backup.
//!
//! Notes on the shape:
//! - Page views, summaries and events are clustered by (site_id,
//!   received_at_ms, event_id), so a time range is one contiguous read; event
//!   ids stay unique for idempotent ingestion.
//! - A page's engagement (active time, scroll, interactions) is copied onto
//!   its page view when the summary arrives.
//! - The visitor-day index is partial (`received_at_ms>0`): only the
//!   exact-count lookup names that term, so the planner never walks it for an
//!   ordinary count(DISTINCT ...).
//! - Rollups cover the current day up to `rollup_days.until_ms`.
const std = @import("std");
const db_mod = @import("db.zig");

const baseline_version: i64 = 6;
pub const current_version: i64 = 10;

/// Migrations after the baseline: index 0 takes schema 6 to 7.
const migrations = [_][]const u8{ chatgpt_sql, draft_notes_sql, scale_sql, apps_sql };

/// 7: each person can run Analytico's AI on their own ChatGPT plan. The
/// registration (issued client) outlives a sign-out; tokens are sealed;
/// `models` lists the plan's models as "slug<TAB>name" lines.
const chatgpt_sql =
    \\BEGIN IMMEDIATE;
    \\CREATE TABLE chatgpt_accounts (
    \\  user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    \\  client_id TEXT NOT NULL,
    \\  subject TEXT NOT NULL,
    \\  email TEXT NOT NULL DEFAULT '',
    \\  tokens TEXT,
    \\  model TEXT NOT NULL DEFAULT '',
    \\  models TEXT NOT NULL DEFAULT '',
    \\  background INTEGER NOT NULL DEFAULT 0 CHECK(background IN (0,1)),
    \\  welcomed INTEGER NOT NULL DEFAULT 0 CHECK(welcomed IN (0,1)),
    \\  created_at_ms INTEGER NOT NULL,
    \\  updated_at_ms INTEGER NOT NULL
    \\) STRICT;
    \\INSERT INTO schema_migrations VALUES(7,'chatgpt-plan',unixepoch('subsec')*1000);
    \\PRAGMA user_version=7;
    \\COMMIT;
;

/// 8: chart notes the daily check drafts for a day that broke the trend,
/// shown to editors to keep or dismiss; only kept notes reach the chart.
const draft_notes_sql =
    \\BEGIN IMMEDIATE;
    \\ALTER TABLE annotations ADD COLUMN draft INTEGER NOT NULL DEFAULT 0 CHECK(draft IN (0,1));
    \\INSERT INTO schema_migrations VALUES(8,'draft-notes',unixepoch('subsec')*1000);
    \\PRAGMA user_version=8;
    \\COMMIT;
;

/// 9: summaries that keep reports fast on large sites. Events carry the
/// traffic class of the browser that sent them (instead of a lookup of their
/// page view per event); Web Vitals are summarised per day and page; a small
/// cache holds results computed once a day. Clearing `rollup_days` makes the
/// background job summarise every day again with the new dimensions; until it
/// catches up, reports read raw rows.
const scale_sql =
    \\BEGIN IMMEDIATE;
    \\ALTER TABLE events ADD COLUMN traffic_class TEXT;
    \\UPDATE events SET traffic_class=CASE WHEN internal=1 THEN 'internal' ELSE (SELECT pv.traffic_class FROM page_views pv WHERE pv.site_id=events.site_id AND pv.page_id=events.page_id) END WHERE source<>'server';
    \\CREATE TABLE vitals_daily (
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  day TEXT NOT NULL CHECK(length(day)=10),
    \\  metric TEXT NOT NULL,
    \\  path TEXT NOT NULL,
    \\  value INTEGER NOT NULL,
    \\  samples INTEGER NOT NULL,
    \\  PRIMARY KEY(site_id,metric,day,path,value)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE cache (
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  name TEXT NOT NULL,
    \\  day TEXT NOT NULL CHECK(length(day)=10),
    \\  value TEXT NOT NULL,
    \\  PRIMARY KEY(site_id,name)
    \\) STRICT, WITHOUT ROWID;
    \\DELETE FROM rollup_days;
    \\INSERT INTO schema_migrations VALUES(9,'summaries-for-scale',unixepoch('subsec')*1000);
    \\PRAGMA user_version=9;
    \\COMMIT;
;

/// 10: native apps sign in like MCP clients, through a built-in OAuth
/// client per platform. Each sign-in is one device, named by the app and
/// kept across token refreshes, so Settings can list and sign it out.
const apps_sql =
    \\BEGIN IMMEDIATE;
    \\ALTER TABLE oauth_grants ADD COLUMN device_id TEXT;
    \\ALTER TABLE oauth_grants ADD COLUMN device_name TEXT;
    \\INSERT INTO oauth_clients(client_id,name,redirect_uris,created_at_ms) VALUES('analytico-apple','Analytico for Mac, iPhone and iPad','["analytico://oauth"]',unixepoch('subsec')*1000) ON CONFLICT DO NOTHING;
    \\INSERT INTO schema_migrations VALUES(10,'native-apps',unixepoch('subsec')*1000);
    \\PRAGMA user_version=10;
    \\COMMIT;
;

const baseline_sql =
    \\BEGIN IMMEDIATE;
    \\CREATE TABLE schema_migrations (
    \\  version INTEGER PRIMARY KEY,
    \\  name TEXT NOT NULL,
    \\  applied_at_ms INTEGER NOT NULL
    \\) STRICT;
    \\CREATE TABLE site_origins (
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  origin TEXT NOT NULL,
    \\  PRIMARY KEY(site_id,origin)
    \\) STRICT, WITHOUT ROWID;
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
    \\CREATE TABLE users (
    \\  id INTEGER PRIMARY KEY,
    \\  email TEXT NOT NULL UNIQUE,
    \\  password_hash TEXT,
    \\  created_at_ms INTEGER NOT NULL,
    \\  webauthn_handle TEXT,
    \\  role TEXT NOT NULL DEFAULT 'admin' CHECK(role IN ('owner','admin','editor','viewer')),
    \\  all_sites INTEGER NOT NULL DEFAULT 1 CHECK(all_sites IN (0,1))
    \\) STRICT;
    \\CREATE TABLE user_invites (
    \\  token_hash TEXT PRIMARY KEY CHECK(length(token_hash)=64),
    \\  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    \\  expires_at_ms INTEGER NOT NULL
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE web_sessions (
    \\  token_hash TEXT PRIMARY KEY CHECK(length(token_hash)=64),
    \\  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    \\  created_at_ms INTEGER NOT NULL,
    \\  expires_at_ms INTEGER NOT NULL
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE annotations (
    \\  id INTEGER PRIMARY KEY,
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  day TEXT NOT NULL CHECK(length(day)=10),
    \\  label TEXT NOT NULL,
    \\  created_at_ms INTEGER NOT NULL
    \\) STRICT;
    \\CREATE INDEX annotations_day ON annotations(site_id,day);
    \\CREATE TABLE segments (
    \\  id INTEGER PRIMARY KEY,
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  name TEXT NOT NULL,
    \\  filters TEXT NOT NULL,
    \\  created_at_ms INTEGER NOT NULL,
    \\  UNIQUE(site_id,name)
    \\) STRICT;
    \\CREATE TABLE dashboards (
    \\  id INTEGER PRIMARY KEY,
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  name TEXT NOT NULL,
    \\  widgets TEXT NOT NULL,
    \\  created_at_ms INTEGER NOT NULL,
    \\  updated_at_ms INTEGER NOT NULL,
    \\  UNIQUE(site_id,name)
    \\) STRICT;
    \\CREATE TABLE alerts (
    \\  id INTEGER PRIMARY KEY,
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  name TEXT NOT NULL,
    \\  metric TEXT NOT NULL CHECK(metric IN ('page_views','visitors','events')),
    \\  direction TEXT NOT NULL CHECK(direction IN ('drops','rises')),
    \\  threshold_percent INTEGER NOT NULL CHECK(threshold_percent BETWEEN 1 AND 1000),
    \\  filters TEXT NOT NULL DEFAULT '',
    \\  email INTEGER NOT NULL DEFAULT 0 CHECK(email IN (0,1)),
    \\  enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
    \\  state TEXT NOT NULL DEFAULT 'quiet' CHECK(state IN ('quiet','triggered')),
    \\  checked_at_ms INTEGER,
    \\  triggered_at_ms INTEGER,
    \\  last_change_milli INTEGER,
    \\  triage TEXT,
    \\  created_at_ms INTEGER NOT NULL,
    \\  channel_id INTEGER REFERENCES channels(id) ON DELETE SET NULL
    \\) STRICT;
    \\CREATE TABLE schedules (
    \\  id INTEGER PRIMARY KEY,
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  name TEXT NOT NULL,
    \\  view TEXT NOT NULL,
    \\  frequency TEXT NOT NULL CHECK(frequency IN ('daily','weekly','monthly')),
    \\  weekday INTEGER NOT NULL DEFAULT 1 CHECK(weekday BETWEEN 0 AND 6),
    \\  hour_utc INTEGER NOT NULL DEFAULT 9 CHECK(hour_utc BETWEEN 0 AND 23),
    \\  recipients TEXT NOT NULL,
    \\  enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
    \\  next_run_at_ms INTEGER NOT NULL,
    \\  last_sent_at_ms INTEGER,
    \\  last_error TEXT,
    \\  created_at_ms INTEGER NOT NULL,
    \\  channel_id INTEGER REFERENCES channels(id) ON DELETE SET NULL
    \\) STRICT;
    \\CREATE TABLE settings (
    \\  name TEXT PRIMARY KEY,
    \\  value TEXT NOT NULL
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE ai_log (
    \\  id INTEGER PRIMARY KEY,
    \\  at_ms INTEGER NOT NULL,
    \\  origin TEXT NOT NULL,
    \\  site_id INTEGER REFERENCES sites(id) ON DELETE SET NULL,
    \\  question TEXT NOT NULL,
    \\  data_used TEXT NOT NULL,
    \\  model TEXT NOT NULL,
    \\  input_tokens INTEGER NOT NULL DEFAULT 0,
    \\  output_tokens INTEGER NOT NULL DEFAULT 0,
    \\  cost_micro INTEGER NOT NULL DEFAULT 0,
    \\  payload TEXT NOT NULL DEFAULT '',
    \\  answer TEXT NOT NULL DEFAULT ''
    \\) STRICT;
    \\CREATE INDEX ai_log_time ON ai_log(at_ms);
    \\CREATE TABLE oauth_clients (
    \\  client_id TEXT PRIMARY KEY,
    \\  name TEXT NOT NULL,
    \\  redirect_uris TEXT NOT NULL,
    \\  created_at_ms INTEGER NOT NULL
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE oauth_grants (
    \\  token_hash TEXT PRIMARY KEY CHECK(length(token_hash)=64),
    \\  kind TEXT NOT NULL CHECK(kind IN ('code','access','refresh')),
    \\  client_id TEXT NOT NULL REFERENCES oauth_clients(client_id) ON DELETE CASCADE,
    \\  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    \\  sites TEXT NOT NULL,
    \\  redirect_uri TEXT NOT NULL DEFAULT '',
    \\  code_challenge TEXT NOT NULL DEFAULT '',
    \\  expires_at_ms INTEGER NOT NULL,
    \\  created_at_ms INTEGER NOT NULL,
    \\  last_used_at_ms INTEGER
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE passkeys (
    \\  id INTEGER PRIMARY KEY,
    \\  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    \\  credential_id TEXT NOT NULL UNIQUE,
    \\  public_key TEXT NOT NULL,
    \\  algorithm INTEGER NOT NULL,
    \\  sign_count INTEGER NOT NULL DEFAULT 0,
    \\  aaguid TEXT NOT NULL DEFAULT '',
    \\  transports TEXT NOT NULL DEFAULT '',
    \\  backup_eligible INTEGER NOT NULL DEFAULT 0 CHECK(backup_eligible IN (0,1)),
    \\  backup_state INTEGER NOT NULL DEFAULT 0 CHECK(backup_state IN (0,1)),
    \\  label TEXT NOT NULL,
    \\  created_at_ms INTEGER NOT NULL,
    \\  last_used_at_ms INTEGER
    \\) STRICT;
    \\CREATE INDEX passkeys_user ON passkeys(user_id);
    \\CREATE TABLE identities (
    \\  provider TEXT NOT NULL CHECK(provider IN ('google','chatgpt')),
    \\  subject TEXT NOT NULL,
    \\  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    \\  email TEXT NOT NULL DEFAULT '',
    \\  created_at_ms INTEGER NOT NULL,
    \\  last_used_at_ms INTEGER,
    \\  PRIMARY KEY(provider,subject),
    \\  UNIQUE(provider,user_id)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE auth_challenges (
    \\  id TEXT PRIMARY KEY CHECK(length(id)=64),
    \\  purpose TEXT NOT NULL CHECK(purpose IN ('setup','invite','add','login','oidc')),
    \\  challenge TEXT NOT NULL,
    \\  verifier TEXT NOT NULL DEFAULT '',
    \\  user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
    \\  binding TEXT NOT NULL DEFAULT '',
    \\  provider TEXT NOT NULL DEFAULT '',
    \\  intent TEXT NOT NULL DEFAULT '',
    \\  handle TEXT NOT NULL DEFAULT '',
    \\  email TEXT NOT NULL DEFAULT '',
    \\  next TEXT NOT NULL DEFAULT '',
    \\  expires_at_ms INTEGER NOT NULL
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE setup_links (
    \\  token_hash TEXT PRIMARY KEY CHECK(length(token_hash)=64),
    \\  expires_at_ms INTEGER NOT NULL
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE sites (
    \\  id INTEGER PRIMARY KEY,
    \\  public_id TEXT NOT NULL UNIQUE,
    \\  slug TEXT NOT NULL UNIQUE,
    \\  tracking_mode TEXT NOT NULL CHECK (tracking_mode IN ('lite','session','full')),
    \\  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
    \\  internal_secret BLOB NOT NULL CHECK (length(internal_secret)=32),
    \\  created_at_ms INTEGER NOT NULL,
    \\  name TEXT NOT NULL DEFAULT '',
    \\  consent_policy TEXT NOT NULL DEFAULT 'regional' CHECK(consent_policy IN ('regional','everyone','none')),
    \\  consent_banner INTEGER NOT NULL DEFAULT 0 CHECK(consent_banner IN (0,1)),
    \\  banner_text TEXT NOT NULL DEFAULT '',
    \\  privacy_url TEXT NOT NULL DEFAULT '',
    \\  search_params TEXT NOT NULL DEFAULT 'q,s,search,query',
    \\  replay_percent INTEGER NOT NULL DEFAULT 0 CHECK(replay_percent BETWEEN 0 AND 100),
    \\  replay_triggers INTEGER NOT NULL DEFAULT 0 CHECK(replay_triggers IN (0,1)),
    \\  mask_text INTEGER NOT NULL DEFAULT 1 CHECK(mask_text IN (0,1)),
    \\  record_exclude TEXT NOT NULL DEFAULT '',
    \\  currency TEXT NOT NULL DEFAULT 'EUR' CHECK(length(currency)=3),
    \\  public_dashboard INTEGER NOT NULL DEFAULT 0 CHECK(public_dashboard IN (0,1))
    \\) STRICT;
    \\CREATE TABLE record_receipts (
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  event_id TEXT NOT NULL,
    \\  payload_hash TEXT NOT NULL CHECK(length(payload_hash)=64),
    \\  record_kind TEXT NOT NULL CHECK(record_kind IN ('page_view','page_summary','event','consent','error','identify','forget')),
    \\  received_at_ms INTEGER NOT NULL,
    \\  PRIMARY KEY(site_id,event_id)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE event_items (
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  event_id TEXT NOT NULL,
    \\  position INTEGER NOT NULL CHECK(position BETWEEN 0 AND 31),
    \\  item_id TEXT NOT NULL,
    \\  name TEXT NOT NULL,
    \\  category TEXT,
    \\  price_minor INTEGER,
    \\  quantity INTEGER NOT NULL CHECK(quantity BETWEEN 1 AND 10000),
    \\  PRIMARY KEY(site_id,event_id,position)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE visitors (
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  visitor_id TEXT NOT NULL,
    \\  first_seen_ms INTEGER NOT NULL,
    \\  last_seen_ms INTEGER NOT NULL,
    \\  first_source TEXT NOT NULL,
    \\  first_campaign TEXT,
    \\  country TEXT,
    \\  user_hash TEXT,
    \\  PRIMARY KEY(site_id,visitor_id)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE INDEX visitors_first ON visitors(site_id,first_seen_ms);
    \\CREATE INDEX visitors_last ON visitors(site_id,last_seen_ms);
    \\CREATE INDEX visitors_user ON visitors(site_id,user_hash) WHERE user_hash IS NOT NULL;
    \\CREATE TABLE visitor_links (
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  user_hash TEXT NOT NULL,
    \\  visitor_id TEXT NOT NULL,
    \\  linked_at_ms INTEGER NOT NULL,
    \\  PRIMARY KEY(site_id,user_hash,visitor_id)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE INDEX visitor_links_visitor ON visitor_links(site_id,visitor_id);
    \\CREATE TABLE errors (
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  event_id TEXT NOT NULL,
    \\  page_id TEXT,
    \\  session_id TEXT,
    \\  visitor_id TEXT,
    \\  occurred_at_ms INTEGER NOT NULL,
    \\  received_at_ms INTEGER NOT NULL,
    \\  path TEXT NOT NULL,
    \\  release_id TEXT,
    \\  fingerprint TEXT NOT NULL CHECK(length(fingerprint)=16),
    \\  message TEXT NOT NULL,
    \\  file TEXT,
    \\  line INTEGER,
    \\  col INTEGER,
    \\  browser TEXT NOT NULL,
    \\  internal INTEGER NOT NULL CHECK(internal IN (0,1)),
    \\  PRIMARY KEY(site_id,event_id)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE INDEX errors_group ON errors(site_id,fingerprint,received_at_ms);
    \\CREATE INDEX errors_time ON errors(site_id,received_at_ms);
    \\CREATE TABLE click_cells (
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  path TEXT NOT NULL,
    \\  day TEXT NOT NULL,
    \\  viewport_class TEXT NOT NULL,
    \\  element TEXT NOT NULL,
    \\  x INTEGER NOT NULL CHECK(x BETWEEN 0 AND 100),
    \\  y INTEGER NOT NULL CHECK(y BETWEEN 0 AND 100),
    \\  clicks INTEGER NOT NULL,
    \\  rage INTEGER NOT NULL,
    \\  PRIMARY KEY(site_id,path,day,viewport_class,element,x,y)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE form_fields (
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  path TEXT NOT NULL,
    \\  day TEXT NOT NULL,
    \\  form TEXT NOT NULL,
    \\  field TEXT NOT NULL,
    \\  starts INTEGER NOT NULL,
    \\  ms INTEGER NOT NULL,
    \\  errors INTEGER NOT NULL,
    \\  abandons INTEGER NOT NULL,
    \\  submits INTEGER NOT NULL,
    \\  PRIMARY KEY(site_id,path,day,form,field)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE user_sites (
    \\  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  PRIMARY KEY(user_id,site_id)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE api_keys (
    \\  id INTEGER PRIMARY KEY,
    \\  name TEXT NOT NULL,
    \\  token_hash TEXT NOT NULL UNIQUE CHECK(length(token_hash)=64),
    \\  prefix TEXT NOT NULL,
    \\  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    \\  site_id INTEGER REFERENCES sites(id) ON DELETE CASCADE,
    \\  created_at_ms INTEGER NOT NULL,
    \\  last_used_at_ms INTEGER
    \\) STRICT;
    \\CREATE TABLE share_links (
    \\  id INTEGER PRIMARY KEY,
    \\  token_hash TEXT NOT NULL UNIQUE CHECK(length(token_hash)=64),
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  dashboard_id INTEGER REFERENCES dashboards(id) ON DELETE CASCADE,
    \\  label TEXT NOT NULL,
    \\  password_hash TEXT,
    \\  expires_at_ms INTEGER,
    \\  allow_range INTEGER NOT NULL DEFAULT 1 CHECK(allow_range IN (0,1)),
    \\  show_details INTEGER NOT NULL DEFAULT 0 CHECK(show_details IN (0,1)),
    \\  created_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
    \\  created_at_ms INTEGER NOT NULL,
    \\  views INTEGER NOT NULL DEFAULT 0,
    \\  last_viewed_at_ms INTEGER
    \\) STRICT;
    \\CREATE TABLE audit_log (
    \\  id INTEGER PRIMARY KEY,
    \\  at_ms INTEGER NOT NULL,
    \\  user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
    \\  actor TEXT NOT NULL,
    \\  site_id INTEGER REFERENCES sites(id) ON DELETE SET NULL,
    \\  action TEXT NOT NULL,
    \\  detail TEXT NOT NULL DEFAULT ''
    \\) STRICT;
    \\CREATE INDEX audit_log_time ON audit_log(at_ms);
    \\CREATE TABLE integrations (
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  kind TEXT NOT NULL CHECK(kind IN ('search_console','ga4','google_ads','meta','warehouse')),
    \\  config TEXT NOT NULL,
    \\  state TEXT NOT NULL DEFAULT 'connected' CHECK(state IN ('pending','connected','failed')),
    \\  synced_at_ms INTEGER,
    \\  last_error TEXT,
    \\  created_at_ms INTEGER NOT NULL,
    \\  PRIMARY KEY(site_id,kind)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE imported_daily (
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  day TEXT NOT NULL CHECK(length(day)=10),
    \\  dim TEXT NOT NULL CHECK(dim IN ('total','page','source','country','device')),
    \\  key TEXT NOT NULL,
    \\  views INTEGER NOT NULL,
    \\  visitors INTEGER NOT NULL,
    \\  PRIMARY KEY(site_id,day,dim,key)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE rollups (
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  day TEXT NOT NULL CHECK(length(day)=10),
    \\  dim TEXT NOT NULL,
    \\  key TEXT NOT NULL,
    \\  views INTEGER NOT NULL,
    \\  visitors INTEGER NOT NULL,
    \\  sessions INTEGER NOT NULL,
    \\  summaries INTEGER NOT NULL,
    \\  active_ms INTEGER NOT NULL,
    \\  engaged INTEGER NOT NULL,
    \\  scroll_sum INTEGER NOT NULL,
    \\  PRIMARY KEY(site_id,dim,day,key)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE visitor_weeks (
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  week INTEGER NOT NULL,
    \\  visitor_id TEXT NOT NULL,
    \\  PRIMARY KEY(site_id,week,visitor_id)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE INDEX visitor_weeks_visitor ON visitor_weeks(site_id,visitor_id);
    \\CREATE TABLE rollup_days (
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  day TEXT NOT NULL CHECK(length(day)=10),
    \\  until_ms INTEGER NOT NULL DEFAULT 0,
    \\  PRIMARY KEY(site_id,day)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE search_queries (
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  day TEXT NOT NULL CHECK(length(day)=10),
    \\  query TEXT NOT NULL,
    \\  page TEXT NOT NULL,
    \\  clicks INTEGER NOT NULL,
    \\  impressions INTEGER NOT NULL,
    \\  position_x10 INTEGER NOT NULL,
    \\  PRIMARY KEY(site_id,day,query,page)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE conversion_uploads (
    \\  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    \\  event_id TEXT NOT NULL,
    \\  destination TEXT NOT NULL CHECK(destination IN ('google_ads','meta')),
    \\  uploaded_at_ms INTEGER NOT NULL,
    \\  state TEXT NOT NULL CHECK(state IN ('sent','failed')),
    \\  PRIMARY KEY(site_id,event_id,destination)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE TABLE channels (
    \\  id INTEGER PRIMARY KEY,
    \\  kind TEXT NOT NULL CHECK(kind IN ('slack','webhook')),
    \\  name TEXT NOT NULL,
    \\  config TEXT NOT NULL,
    \\  created_at_ms INTEGER NOT NULL,
    \\  last_sent_at_ms INTEGER,
    \\  last_error TEXT
    \\) STRICT;
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
    \\  visitor_id TEXT,
    \\  region TEXT,
    \\  city TEXT,
    \\  search_term TEXT,
    \\  search_results INTEGER,
    \\  click_id TEXT,
    \\  active_ms INTEGER,
    \\  max_scroll INTEGER,
    \\  interaction_count INTEGER,
    \\  PRIMARY KEY(site_id,received_at_ms,event_id),
    \\  UNIQUE(site_id,event_id),
    \\  UNIQUE(site_id,page_id)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE INDEX page_views_page ON page_views(site_id,path,received_at_ms);
    \\CREATE INDEX page_views_campaign ON page_views(site_id,utm_campaign,received_at_ms);
    \\CREATE INDEX page_views_session ON page_views(site_id,session_id,received_at_ms) WHERE session_id IS NOT NULL;
    \\CREATE INDEX page_views_visitor ON page_views(site_id,visitor_id,received_at_ms) WHERE visitor_id IS NOT NULL;
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
    \\  visitor_id TEXT,
    \\  attention_json TEXT,
    \\  PRIMARY KEY(site_id,received_at_ms,event_id),
    \\  UNIQUE(site_id,event_id),
    \\  UNIQUE(site_id,page_id)
    \\) STRICT, WITHOUT ROWID;
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
    \\  visitor_id TEXT,
    \\  user_hash TEXT,
    \\  order_id TEXT,
    \\  PRIMARY KEY(site_id,received_at_ms,event_id),
    \\  UNIQUE(site_id,event_id)
    \\) STRICT, WITHOUT ROWID;
    \\CREATE INDEX events_name ON events(site_id,name,received_at_ms);
    \\CREATE INDEX events_session ON events(site_id,session_id,received_at_ms) WHERE session_id IS NOT NULL;
    \\CREATE INDEX events_visitor ON events(site_id,visitor_id) WHERE visitor_id IS NOT NULL;
    \\CREATE INDEX events_user ON events(site_id,user_hash) WHERE user_hash IS NOT NULL;
    \\CREATE INDEX events_order ON events(site_id,order_id) WHERE order_id IS NOT NULL;
    \\CREATE INDEX page_views_visitor_day ON page_views(site_id,visitor_day_id,received_at_ms) WHERE received_at_ms>0;
    \\INSERT INTO schema_migrations VALUES(6,'baseline',unixepoch('subsec')*1000);
    \\PRAGMA user_version=6;
    \\COMMIT;
;

pub fn initialize(database: *db_mod.Db) !void {
    const current = try version(database, std.heap.c_allocator);
    if (current != 0) return error.DatabaseAlreadyInitialized;
    try database.exec(baseline_sql);
    for (migrations) |sql| try database.exec(sql);
}

/// Applies every pending numbered migration. Callers create and verify a
/// backup first; each migration is one transaction.
pub fn migrate(database: *db_mod.Db, allocator: std.mem.Allocator) !i64 {
    const current = try version(database, allocator);
    if (current == 0) return error.UninitializedDatabase;
    if (current > current_version) return error.NewerDatabaseSchema;
    // Databases before the baseline upgrade through release 0.1 first.
    if (current < baseline_version) return error.SchemaTooOld;
    for (migrations[@intCast(current - baseline_version)..]) |sql| try database.exec(sql);
    return current_version;
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
