#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <current-binary> <metadata9-binary>" >&2
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
site_id=$("$previous" site list "$live" |
    awk -F '\t' '$1 == "migration" { print $2 }')
"$previous" m3 seed "$live" "$site_id" >/dev/null
"$previous" funnel add "$live" migration "Two step" \
    path=/ event=signup >/dev/null
"$previous" funnel add "$live" migration "Eight step" \
    path=/ event=signup path=/pricing event=purchase prefix=/docs \
    event=download path=/complete event=logout >/dev/null

test "$("$previous" doctor "$live")" = \
    "ok metadata=v9 events=v7 sites=1 goals=0 funnels=2 stored_events=14 key=ok"
before_v1=$("$previous" report "$live" migration 2025-01-01 2025-01-02 \
    overview --format json)
before_funnel=$("$previous" funnel show "$live" migration "Two step")
metric_v2_semantics() {
    "$1" m3 filters-v2-series "$2" migration \
        2025-01-01 2025-01-02 2024-12-30 2024-12-31 2>/dev/null |
        jq -cS 'del(
            .cold_overview_micros,
            .warm_overview_sample_micros,
            .warm_overview_p50_micros,
            .warm_overview_p95_micros,
            .warm_overview_p99_micros,
            .trend_micros,
            .breakdown_micros,
            .suggestion_micros
        )'
}
before_v2=$(metric_v2_semantics "$previous" "$live")
sqlite3 -separator '|' "$live/meta.db" \
    'SELECT id, site_id, name, created_at_utc_micros FROM funnels ORDER BY id;' \
    >"$fixture/before-funnels.txt"
sqlite3 -separator '|' "$live/meta.db" \
    'SELECT funnel_id, step_index, name, match_kind, match_value FROM funnel_steps ORDER BY funnel_id, step_index;' \
    >"$fixture/before-steps.txt"
before_event_sha=$(sha256sum "$live/events.duckdb" | cut -d' ' -f1)

backup="$fixture/pre-metadata10"
test "$("$current" backup "$live" "$backup")" = \
    "backup complete destination=$backup metadata=v9 events=v7"
test "$(jq -r .metadata_schema "$backup/manifest.json")" = 9
test "$(jq -r .event_schema "$backup/manifest.json")" = 7
verified="$fixture/verified-metadata9"
"$current" restore "$backup" "$verified" --verify >/dev/null
test "$("$previous" doctor "$verified")" = \
    "ok metadata=v9 events=v7 sites=1 goals=0 funnels=2 stored_events=14 key=ok"
test "$("$previous" funnel show "$verified" migration "Two step")" = \
    "$before_funnel"

create_replacement() {
    sqlite3 "$1/meta.db" <<'SQL'
PRAGMA foreign_keys = ON;
CREATE TABLE funnel_definitions (id TEXT PRIMARY KEY, site_id TEXT NOT NULL, name TEXT NOT NULL, canonical_definition_json TEXT NOT NULL, created_at_utc_micros INTEGER NOT NULL, updated_at_utc_micros INTEGER NOT NULL, archived_at_utc_micros INTEGER, FOREIGN KEY (site_id) REFERENCES sites (id) ON DELETE CASCADE, UNIQUE (site_id, name), CHECK (length (id) = 36), CHECK (length (name) BETWEEN 1 AND 120), CHECK (length (canonical_definition_json) BETWEEN 2 AND 8192), CHECK (updated_at_utc_micros >= created_at_utc_micros), CHECK (archived_at_utc_micros IS NULL OR archived_at_utc_micros >= created_at_utc_micros));
SQL
}

invalid_source="$fixture/invalid-source"
cp -a "$verified" "$invalid_source"
sqlite3 "$invalid_source/meta.db" <<'SQL'
UPDATE funnel_steps
SET name = printf('/%0120d', 0), match_value = printf('/%0120d', 0)
WHERE funnel_id = (SELECT id FROM funnels ORDER BY id LIMIT 1)
  AND step_index = 0;
SQL
test "$(sqlite3 "$invalid_source/meta.db" \
    'SELECT length(name) FROM funnel_steps ORDER BY funnel_id, step_index LIMIT 1;')" = 121
invalid_source_backup="$fixture/invalid-source-backup"
"$current" backup "$invalid_source" "$invalid_source_backup" >/dev/null
if "$current" migrate "$invalid_source" "$invalid_source_backup" \
    >/dev/null 2>&1; then
    echo "invalid predecessor funnel unexpectedly passed migration" >&2
    exit 1
fi
test "$(sqlite3 "$invalid_source/meta.db" \
    'SELECT max(version) FROM meta_migrations;')" = 9

insert_replacement() {
    local target=$1
    local limit=${2:-}
    sqlite3 "$target/meta.db" <<SQL
INSERT INTO funnel_definitions
  (id, site_id, name, canonical_definition_json,
   created_at_utc_micros, updated_at_utc_micros,
   archived_at_utc_micros)
SELECT id, site_id, name,
       CASE name
         WHEN 'Two step' THEN '{"schema":1,"order":"sequential","scope":"sessions","window_seconds":0,"steps":[{"kind":"page","value":"/","predicates":[]},{"kind":"event","value":"signup","predicates":[]}]}'
         WHEN 'Eight step' THEN '{"schema":1,"order":"sequential","scope":"sessions","window_seconds":0,"steps":[{"kind":"page","value":"/","predicates":[]},{"kind":"event","value":"signup","predicates":[]},{"kind":"page","value":"/pricing","predicates":[]},{"kind":"event","value":"purchase","predicates":[]},{"kind":"page-prefix","value":"/docs","predicates":[]},{"kind":"event","value":"download","predicates":[]},{"kind":"page","value":"/complete","predicates":[]},{"kind":"event","value":"logout","predicates":[]}]}'
       END,
       created_at_utc_micros, created_at_utc_micros, NULL
FROM funnels ORDER BY id $limit;
SQL
}

partial="$fixture/partial-copy"
cp -a "$verified" "$partial"
create_replacement "$partial"
insert_replacement "$partial" 'LIMIT 1'
test "$(sqlite3 "$partial/meta.db" 'SELECT count(*) FROM funnels;')" = 2
test "$(sqlite3 "$partial/meta.db" \
    'SELECT count(*) FROM funnel_definitions;')" = 1
partial_backup="$fixture/partial-backup"
"$current" backup "$partial" "$partial_backup" >/dev/null
test "$("$current" migrate "$partial" "$partial_backup")" = \
    "migrated metadata=v10 events=v7"
test "$(sqlite3 "$partial/meta.db" \
    'SELECT count(*) FROM funnel_definitions;')" = 2
test "$(sqlite3 "$partial/meta.db" \
    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('funnels','funnel_steps');")" = 0

child_dropped="$fixture/child-dropped"
cp -a "$verified" "$child_dropped"
create_replacement "$child_dropped"
insert_replacement "$child_dropped"
sqlite3 "$child_dropped/meta.db" 'DROP TABLE funnel_steps;'
test "$(sqlite3 "$child_dropped/meta.db" \
    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='funnels';")" = 1
child_backup="$fixture/child-backup"
"$current" backup "$child_dropped" "$child_backup" >/dev/null
test "$("$current" migrate "$child_dropped" "$child_backup")" = \
    "migrated metadata=v10 events=v7"
test "$(sqlite3 "$child_dropped/meta.db" \
    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='funnels';")" = 0

after_drop="$fixture/after-drop"
cp -a "$verified" "$after_drop"
after_drop_initial_backup="$fixture/after-drop-initial-backup"
"$current" backup "$after_drop" "$after_drop_initial_backup" >/dev/null
"$current" migrate "$after_drop" "$after_drop_initial_backup" >/dev/null
sqlite3 "$after_drop/meta.db" 'DELETE FROM meta_migrations WHERE version=10;'
after_drop_backup="$fixture/after-drop-backup"
"$current" backup "$after_drop" "$after_drop_backup" >/dev/null
test "$("$current" migrate "$after_drop" "$after_drop_backup")" = \
    "migrated metadata=v10 events=v7"
test "$(sqlite3 "$after_drop/meta.db" \
    "SELECT count(*) FROM meta_migrations WHERE version=10 AND name='guided-funnel-definitions';")" = 1

corrupt="$fixture/corrupt-after-drop"
cp -a "$after_drop" "$corrupt"
sqlite3 "$corrupt/meta.db" <<'SQL'
DELETE FROM meta_migrations WHERE version=10;
UPDATE funnel_definitions
SET canonical_definition_json = replace(
  canonical_definition_json, '"scope":', '"scope": ')
WHERE id = (SELECT id FROM funnel_definitions ORDER BY id LIMIT 1);
SQL
corrupt_backup="$fixture/corrupt-backup"
"$current" backup "$corrupt" "$corrupt_backup" >/dev/null
if "$current" migrate "$corrupt" "$corrupt_backup" >/dev/null 2>&1; then
    echo "noncanonical funnel document unexpectedly passed migration" >&2
    exit 1
fi
test "$(sqlite3 "$corrupt/meta.db" 'SELECT max(version) FROM meta_migrations;')" = 9

test "$("$current" migrate "$live" "$backup")" = \
    "migrated metadata=v10 events=v7"
test "$("$current" doctor "$live")" = \
    "ok metadata=v10 events=v7 sites=1 goals=0 funnels=2 stored_events=14 key=ok"
test "$(sqlite3 "$live/meta.db" \
    'SELECT count(*) FROM funnel_definitions;')" = 2
test "$(sqlite3 "$live/meta.db" \
    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('funnels','funnel_steps');")" = 0
test "$(sha256sum "$live/events.duckdb" | cut -d' ' -f1)" = \
    "$before_event_sha"
test "$("$current" report "$live" migration 2025-01-01 2025-01-02 \
    overview --format json)" = "$before_v1"
test "$(metric_v2_semantics "$current" "$live")" = "$before_v2"
test "$("$current" funnel show "$live" migration "Two step")" = \
    "$before_funnel"
test "$("$current" migrate "$live")" = "migrated metadata=v10 events=v7"
if "$previous" doctor "$live" >/dev/null 2>&1; then
    echo "metadata-9 predecessor unexpectedly opened metadata 10" >&2
    exit 1
fi

rolled_back="$fixture/rolled-back"
"$previous" restore "$backup" "$rolled_back" --verify >/dev/null
test "$("$previous" doctor "$rolled_back")" = \
    "ok metadata=v9 events=v7 sites=1 goals=0 funnels=2 stored_events=14 key=ok"
test "$("$previous" funnel show "$rolled_back" migration "Two step")" = \
    "$before_funnel"

fresh="$fixture/fresh"
"$current" init "$fresh" >/dev/null
test "$(sqlite3 "$fresh/meta.db" 'SELECT max(version) FROM meta_migrations;')" = 10
test "$(sqlite3 "$fresh/meta.db" \
    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='funnel_definitions';")" = 1
test "$(sqlite3 "$fresh/meta.db" \
    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('funnels','funnel_steps');")" = 0

printf 'metadata10_migration_e2e=pass predecessor=d58316145ff2e7fecb834bedc2e5ea7034349952 metadata=9-to-10 events=7 funnels=2+8-step invalid-source=refused interruption=partial-copy+child-drop+after-drop corruption=refused reports=v1+v2 rollback=matched-pair\n'
