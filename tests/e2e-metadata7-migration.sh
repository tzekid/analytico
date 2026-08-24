#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <current-binary> <metadata6-binary>" >&2
    exit 2
fi
current=$1
previous=$2
case "$current" in /*) ;; *) current="$PWD/$current" ;; esac
case "$previous" in /*) ;; *) previous="$PWD/$previous" ;; esac

fixture=$(mktemp -d)
cleanup() { rm -rf -- "$fixture"; }
trap cleanup EXIT
live="$fixture/live"

"$previous" init "$live" >/dev/null
"$previous" site add "$live" migration Migration https://migration.example \
    --timezone UTC >/dev/null
"$previous" site origin-add "$live" migration http://localhost:8080 >/dev/null
"$previous" site property-add "$live" migration plan >/dev/null
"$previous" site traffic-policy "$live" migration off 123456 >/dev/null
"$previous" goal add "$live" migration Signup event signup >/dev/null
"$previous" funnel add "$live" migration Journey path=/ event=signup >/dev/null
"$previous" auth configure "$live" https://analytics.example >/dev/null
"$previous" auth bootstrap "$live" --ttl 10m >/dev/null
"$previous" event add "$live" migration pageview /before \
    1787443200000000 2026-08-23 203.0.113.42 Chrome Linux desktop >/dev/null

test "$("$previous" doctor "$live")" = \
    "ok metadata=v6 events=v7 sites=1 goals=1 funnels=1 stored_events=1 key=ok"
before_report=$("$previous" report "$live" migration 2026-08-23 2026-08-23 \
    overview --format json)
metadata_facts() {
    sqlite3 -separator '|' "$1/meta.db" <<'SQL'
SELECT 'site', id, slug, name, created_at_utc_micros,
       COALESCE(disabled_at_utc_micros, '') FROM sites
UNION ALL SELECT 'origin', site_id, origin, '', '', '' FROM site_origins
UNION ALL SELECT 'timezone', site_id, zone_name, revision, rebucket_pending, ''
  FROM site_timezones
UNION ALL SELECT 'property', site_id, property_name, '', '', ''
  FROM site_event_properties
UNION ALL SELECT 'policy', site_id, strict_mode, daily_event_ceiling,
                 updated_at_utc_micros, '' FROM site_traffic_policy
UNION ALL SELECT 'settings', site_id, default_currency, '', '', ''
  FROM site_settings
UNION ALL SELECT 'goal', id, site_id, name, match_kind, match_value FROM goals
UNION ALL SELECT 'funnel', id, site_id, name, created_at_utc_micros, ''
  FROM funnels
UNION ALL SELECT 'step', funnel_id, step_index, name, match_kind, match_value
  FROM funnel_steps
UNION ALL SELECT 'auth-config', id, origin, rp_id, created_at_utc_seconds,
                 updated_at_utc_seconds FROM auth_config
UNION ALL SELECT 'auth-bootstrap', id, token_hash, expires_at_utc_seconds,
                 created_at_utc_seconds, COALESCE(consumed_at_utc_seconds, '')
  FROM auth_bootstrap
ORDER BY 1, 2, 3;
SQL
}
metadata_facts "$live" >"$fixture/before-metadata.txt"
before_event_sha=$(sha256sum "$live/events.duckdb" | cut -d' ' -f1)

backup="$fixture/pre-metadata7"
test "$("$current" backup "$live" "$backup")" = \
    "backup complete destination=$backup metadata=v6 events=v7"
test "$(jq -r .metadata_schema "$backup/manifest.json")" = 6
test "$(jq -r .event_schema "$backup/manifest.json")" = 7
verified="$fixture/verified-metadata6"
"$current" restore "$backup" "$verified" --verify >/dev/null
test "$("$previous" doctor "$verified")" = \
    "ok metadata=v6 events=v7 sites=1 goals=1 funnels=1 stored_events=1 key=ok"
test "$("$previous" report "$verified" migration 2026-08-23 2026-08-23 \
    overview --format json)" = "$before_report"

interrupted="$fixture/interrupted"
cp -a "$verified" "$interrupted"
interrupted_backup="$fixture/interrupted-backup"
"$current" backup "$interrupted" "$interrupted_backup" >/dev/null
sqlite3 "$interrupted/meta.db" <<'SQL'
PRAGMA foreign_keys = ON;
CREATE TABLE segments (
  id TEXT PRIMARY KEY,
  site_id TEXT NOT NULL,
  name TEXT NOT NULL,
  filter_schema_version INTEGER NOT NULL CHECK (filter_schema_version = 1),
  canonical_filter_json TEXT NOT NULL,
  created_at_utc_micros INTEGER NOT NULL,
  updated_at_utc_micros INTEGER NOT NULL,
  FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
  UNIQUE (site_id, name),
  CHECK (length(id) = 36),
  CHECK (length(name) BETWEEN 1 AND 120),
  CHECK (length(canonical_filter_json) BETWEEN 1 AND 32768)
);
SQL
test "$(sqlite3 "$interrupted/meta.db" \
    'SELECT max(version) FROM meta_migrations;')" = 6
if "$current" migrate "$interrupted" "$interrupted_backup" >/dev/null 2>&1; then
    echo "partially changed metadata unexpectedly matched the pre-migration backup" >&2
    exit 1
fi
test "$(sqlite3 "$interrupted/meta.db" \
    'SELECT max(version) FROM meta_migrations;')" = 6
interrupted_retry="$fixture/interrupted-retry"
"$current" restore "$interrupted_backup" "$interrupted_retry" --verify >/dev/null
test "$("$current" migrate "$interrupted_retry" "$interrupted_backup")" = \
    "migrated metadata=v7 events=v7"
test "$("$current" doctor "$interrupted_retry")" = \
    "ok metadata=v7 events=v7 sites=1 goals=1 funnels=1 stored_events=1 key=ok"
test "$(sqlite3 "$interrupted_retry/meta.db" \
    'SELECT count(*) FROM segments;')" = 0
test "$(sqlite3 "$interrupted_retry/meta.db" \
    'SELECT count(*) FROM saved_views;')" = 0
test "$("$current" migrate "$interrupted_retry")" = \
    "migrated metadata=v7 events=v7"

test "$("$current" migrate "$live" "$backup")" = \
    "migrated metadata=v7 events=v7"
test "$("$current" doctor "$live")" = \
    "ok metadata=v7 events=v7 sites=1 goals=1 funnels=1 stored_events=1 key=ok"
metadata_facts "$live" >"$fixture/after-metadata.txt"
cmp "$fixture/before-metadata.txt" "$fixture/after-metadata.txt"
test "$(sha256sum "$live/events.duckdb" | cut -d' ' -f1)" = "$before_event_sha"
test "$("$current" report "$live" migration 2026-08-23 2026-08-23 \
    overview --format json)" = "$before_report"
test "$(sqlite3 "$live/meta.db" 'SELECT count(*) FROM segments;')" = 0
test "$(sqlite3 "$live/meta.db" 'SELECT count(*) FROM saved_views;')" = 0
test "$(sqlite3 "$live/meta.db" \
    "SELECT count(*) FROM meta_migrations WHERE version=7 AND name='segments-and-saved-views';")" = 1
test "$("$current" migrate "$live" "$backup")" = \
    "migrated metadata=v7 events=v7"
if "$previous" doctor "$live" >/dev/null 2>&1; then
    echo "metadata-6 predecessor unexpectedly opened metadata 7" >&2
    exit 1
fi

rolled_back="$fixture/rolled-back"
"$previous" restore "$backup" "$rolled_back" --verify >/dev/null
test "$("$previous" doctor "$rolled_back")" = \
    "ok metadata=v6 events=v7 sites=1 goals=1 funnels=1 stored_events=1 key=ok"
test "$("$previous" report "$rolled_back" migration 2026-08-23 2026-08-23 \
    overview --format json)" = "$before_report"

fresh="$fixture/fresh"
"$current" init "$fresh" >/dev/null
test "$(sqlite3 "$fresh/meta.db" 'SELECT max(version) FROM meta_migrations;')" = 7
test "$(sqlite3 "$fresh/meta.db" 'SELECT count(*) FROM segments;')" = 0
test "$(sqlite3 "$fresh/meta.db" 'SELECT count(*) FROM saved_views;')" = 0

printf 'metadata7_migration_e2e=pass predecessor=a2d71c046a8b8b632429336f58ff0d1eebfea7b3 metadata=6-to-7 events=7 rows=preserved interruption=retried replay=idempotent rollback=matched-pair\n'
