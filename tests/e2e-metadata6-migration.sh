#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <current-binary> <metadata5-binary>" >&2
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
    "ok metadata=v5 events=v7 sites=1 goals=1 funnels=1 stored_events=1 key=ok"
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
sqlite3 -separator '|' "$live/meta.db" \
    'SELECT id, site_id, name, match_kind, match_value, created_at_utc_micros FROM goals ORDER BY id;' \
    >"$fixture/before-goals.txt"
before_event_sha=$(sha256sum "$live/events.duckdb" | cut -d' ' -f1)

backup="$fixture/pre-metadata6"
test "$("$current" backup "$live" "$backup")" = \
    "backup complete destination=$backup metadata=v5 events=v7"
test "$(jq -r .metadata_schema "$backup/manifest.json")" = 5
test "$(jq -r .event_schema "$backup/manifest.json")" = 7
verified="$fixture/verified-metadata5"
"$current" restore "$backup" "$verified" --verify >/dev/null
test "$("$previous" doctor "$verified")" = \
    "ok metadata=v5 events=v7 sites=1 goals=1 funnels=1 stored_events=1 key=ok"
test "$("$previous" report "$verified" migration 2026-08-23 2026-08-23 \
    overview --format json)" = "$before_report"

test "$("$current" migrate "$live" "$backup")" = \
    "migrated metadata=v8 events=v7"
test "$("$current" doctor "$live")" = \
    "ok metadata=v8 events=v7 sites=1 goals=1 funnels=1 stored_events=1 key=ok"
metadata_facts "$live" >"$fixture/after-metadata.txt"
cmp "$fixture/before-metadata.txt" "$fixture/after-metadata.txt"
sqlite3 -separator '|' "$live/meta.db" \
    'SELECT id, site_id, name, match_kind, match_value, created_at_utc_micros FROM goal_definitions ORDER BY id;' \
    >"$fixture/after-goals.txt"
cmp "$fixture/before-goals.txt" "$fixture/after-goals.txt"
test "$(sha256sum "$live/events.duckdb" | cut -d' ' -f1)" = "$before_event_sha"
test "$("$current" report "$live" migration 2026-08-23 2026-08-23 \
    overview --format json)" = "$before_report"
test "$(sqlite3 "$live/meta.db" 'SELECT count(*) FROM site_settings;')" = 1
test -z "$(sqlite3 "$live/meta.db" 'SELECT default_currency FROM site_settings;')"
test "$(sqlite3 "$live/meta.db" \
    "SELECT count(*) FROM sqlite_master WHERE type='index' AND name='site_origins_unique_origin';")" = 1
test "$("$current" migrate "$live" "$backup")" = \
    "migrated metadata=v8 events=v7"
if "$previous" doctor "$live" >/dev/null 2>&1; then
    echo "metadata-5 predecessor unexpectedly opened current metadata" >&2
    exit 1
fi

rolled_back="$fixture/rolled-back"
"$previous" restore "$backup" "$rolled_back" --verify >/dev/null
test "$("$previous" doctor "$rolled_back")" = \
    "ok metadata=v5 events=v7 sites=1 goals=1 funnels=1 stored_events=1 key=ok"
test "$("$previous" report "$rolled_back" migration 2026-08-23 2026-08-23 \
    overview --format json)" = "$before_report"

fresh="$fixture/fresh"
"$current" init "$fresh" >/dev/null
test "$(sqlite3 "$fresh/meta.db" 'SELECT max(version) FROM meta_migrations;')" = 8
test "$(sqlite3 "$fresh/meta.db" 'SELECT count(*) FROM site_settings;')" = 0

duplicate="$fixture/duplicate"
"$previous" init "$duplicate" >/dev/null
"$previous" site add "$duplicate" alpha Alpha https://alpha.example \
    --timezone UTC >/dev/null
"$previous" site add "$duplicate" beta Beta https://beta.example \
    --timezone UTC >/dev/null
"$previous" site origin-add "$duplicate" beta https://alpha.example >/dev/null
duplicate_backup="$fixture/duplicate-backup"
"$current" backup "$duplicate" "$duplicate_backup" >/dev/null
if "$current" migrate "$duplicate" "$duplicate_backup" >/dev/null 2>&1; then
    echo "cross-site duplicate origin unexpectedly migrated" >&2
    exit 1
fi
test "$(sqlite3 "$duplicate/meta.db" 'SELECT max(version) FROM meta_migrations;')" = 5
test "$(sqlite3 "$duplicate/meta.db" 'SELECT count(*) FROM site_settings;')" = 2
test "$(sqlite3 "$duplicate/meta.db" \
    "SELECT count(*) FROM sqlite_master WHERE type='index' AND name='site_origins_unique_origin';")" = 0

printf 'metadata6_migration_e2e=pass predecessor=b96bc79677280367e87668811aa250300f35865a metadata=5-to-8 events=7 rows=preserved goals=preserved-active duplicate_origin=failed-before-ledger rollback=matched-pair\n'
