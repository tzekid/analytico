#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <current-binary> <metadata7-binary>" >&2
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
goal_output=$("$previous" goal add "$live" migration Signup event signup)
goal_id=${goal_output##* }
second_goal_output=$("$previous" goal add \
    "$live" migration Pricing path /pricing)
second_goal_id=${second_goal_output##* }
test "${#second_goal_id}" = 36
"$previous" auth configure "$live" https://analytics.example >/dev/null
"$previous" auth bootstrap "$live" --ttl 10m >/dev/null

saved_view_id=00000000-0000-4000-8000-000000000380
segment_id=00000000-0000-4000-8000-000000000381
sqlite3 "$live/meta.db" <<SQL
INSERT INTO segments
  (id, site_id, name, filter_schema_version, canonical_filter_json,
   created_at_utc_micros, updated_at_utc_micros)
VALUES
  ('$segment_id', '$site_id', 'Desktop', 1,
   '{"schema":1,"clauses":[]}', 77, 78);
INSERT INTO saved_views
  (id, site_id, name, query_schema_version, canonical_query_json,
   created_at_utc_micros, updated_at_utc_micros)
VALUES
  ('$saved_view_id', '$site_id', 'Signup trend', 1,
   '{"schema":1,"mode":"trend","series":["conversions~visitor~goal~$goal_id"]}',
   79, 80);
SQL

test "$("$previous" doctor "$live")" = \
    "ok metadata=v7 events=v7 sites=1 goals=2 funnels=0 stored_events=14 key=ok"
before_v1=$("$previous" report "$live" migration 2025-01-01 2025-01-02 \
    overview --format json)
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
    'SELECT id, site_id, name, match_kind, match_value, created_at_utc_micros FROM goals ORDER BY id;' \
    >"$fixture/before-goals.txt"
sqlite3 -separator '|' "$live/meta.db" \
    'SELECT id, site_id, name, query_schema_version, canonical_query_json, created_at_utc_micros, updated_at_utc_micros FROM saved_views ORDER BY id;' \
    >"$fixture/before-views.txt"
before_event_sha=$(sha256sum "$live/events.duckdb" | cut -d' ' -f1)

backup="$fixture/pre-metadata8"
test "$("$current" backup "$live" "$backup")" = \
    "backup complete destination=$backup metadata=v7 events=v7"
test "$(jq -r .metadata_schema "$backup/manifest.json")" = 7
test "$(jq -r .event_schema "$backup/manifest.json")" = 7
verified="$fixture/verified-metadata7"
"$current" restore "$backup" "$verified" --verify >/dev/null
test "$("$previous" doctor "$verified")" = \
    "ok metadata=v7 events=v7 sites=1 goals=2 funnels=0 stored_events=14 key=ok"
test "$("$previous" report "$verified" migration 2025-01-01 2025-01-02 \
    overview --format json)" = "$before_v1"

create_replacement() {
    sqlite3 "$1/meta.db" <<'SQL'
PRAGMA foreign_keys = ON;
CREATE TABLE goal_definitions (
  id TEXT PRIMARY KEY,
  site_id TEXT NOT NULL,
  name TEXT NOT NULL,
  match_kind INTEGER NOT NULL,
  match_value TEXT NOT NULL,
  created_at_utc_micros INTEGER NOT NULL,
  updated_at_utc_micros INTEGER NOT NULL,
  archived_at_utc_micros INTEGER,
  FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
  UNIQUE (site_id, name),
  CHECK (length(id) = 36),
  CHECK (length(name) BETWEEN 1 AND 120),
  CHECK (match_kind IN (1, 2, 3)),
  CHECK (length(match_value) BETWEEN 1 AND 1024),
  CHECK (updated_at_utc_micros >= created_at_utc_micros),
  CHECK (archived_at_utc_micros IS NULL OR
    archived_at_utc_micros >= created_at_utc_micros)
);
SQL
}

partial="$fixture/partial-copy"
cp -a "$verified" "$partial"
create_replacement "$partial"
sqlite3 -separator '|' "$partial/meta.db" \
    'SELECT id, site_id, name, match_kind, match_value, created_at_utc_micros, created_at_utc_micros, NULL FROM goals ORDER BY id;' \
    >"$fixture/partial-expected.txt"
sqlite3 "$partial/meta.db" <<'SQL'
INSERT INTO goal_definitions
  (id, site_id, name, match_kind, match_value, created_at_utc_micros,
   updated_at_utc_micros, archived_at_utc_micros)
SELECT id, site_id, name, match_kind, match_value, created_at_utc_micros,
       created_at_utc_micros, NULL FROM goals LIMIT 1;
SQL
test "$(sqlite3 "$partial/meta.db" 'SELECT count(*) FROM goal_definitions;')" = 1
partial_backup="$fixture/partial-backup"
"$current" backup "$partial" "$partial_backup" >/dev/null
test "$("$current" migrate "$partial" "$partial_backup")" = \
    "migrated metadata=v10 events=v7"
test "$(sqlite3 "$partial/meta.db" 'SELECT count(*) FROM goal_definitions_v2;')" = 2
sqlite3 -separator '|' "$partial/meta.db" \
    'SELECT id, site_id, name, match_kind, match_value, created_at_utc_micros, updated_at_utc_micros, archived_at_utc_micros FROM goal_definitions_v2 ORDER BY id;' \
    >"$fixture/partial-actual.txt"
cmp "$fixture/partial-expected.txt" "$fixture/partial-actual.txt"
test "$(sqlite3 "$partial/meta.db" \
    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='goals';")" = 0
test "$(sqlite3 "$partial/meta.db" \
    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='goal_definitions';")" = 0

after_drop="$fixture/after-drop"
cp -a "$verified" "$after_drop"
after_drop_initial_backup="$fixture/after-drop-initial-backup"
"$current" backup "$after_drop" "$after_drop_initial_backup" >/dev/null
"$current" migrate "$after_drop" "$after_drop_initial_backup" >/dev/null
test "$(sqlite3 "$after_drop/meta.db" \
    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='goals';")" = 0
after_drop_backup="$fixture/after-drop-backup"
"$current" backup "$after_drop" "$after_drop_backup" >/dev/null
test "$("$current" migrate "$after_drop" "$after_drop_backup")" = \
    "migrated metadata=v10 events=v7"
test "$(sqlite3 "$after_drop/meta.db" \
    "SELECT count(*) FROM meta_migrations WHERE version=8 AND name='guided-goal-lifecycle';")" = 1
test "$(sqlite3 "$after_drop/meta.db" \
    "SELECT count(*) FROM meta_migrations WHERE version=9 AND name='goal-property-predicates';")" = 1

corrupt="$fixture/corrupt-replacement"
cp -a "$verified" "$corrupt"
create_replacement "$corrupt"
sqlite3 "$corrupt/meta.db" <<'SQL'
INSERT INTO goal_definitions
  (id, site_id, name, match_kind, match_value, created_at_utc_micros,
   updated_at_utc_micros, archived_at_utc_micros)
SELECT id, site_id, name, match_kind, match_value, created_at_utc_micros,
       created_at_utc_micros, NULL FROM goals;
INSERT INTO goal_definitions VALUES
  ('00000000-0000-4000-8000-000000000389',
   (SELECT id FROM sites LIMIT 1), 'Unexpected', 2, 'unexpected', 90, 90, 90);
SQL
corrupt_backup="$fixture/corrupt-backup"
"$current" backup "$corrupt" "$corrupt_backup" >/dev/null
if "$current" migrate "$corrupt" "$corrupt_backup" >/dev/null 2>&1; then
    echo "non-predecessor replacement row unexpectedly passed equality" >&2
    exit 1
fi
test "$(sqlite3 "$corrupt/meta.db" 'SELECT max(version) FROM meta_migrations;')" = 7
test "$(sqlite3 "$corrupt/meta.db" \
    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='goals';")" = 1

test "$("$current" migrate "$live" "$backup")" = \
    "migrated metadata=v10 events=v7"
test "$("$current" doctor "$live")" = \
    "ok metadata=v10 events=v7 sites=1 goals=2 funnels=0 stored_events=14 key=ok"
sqlite3 -separator '|' "$live/meta.db" \
    'SELECT id, site_id, name, match_kind, match_value, created_at_utc_micros FROM goal_definitions_v2 ORDER BY id;' \
    >"$fixture/after-goals.txt"
cmp "$fixture/before-goals.txt" "$fixture/after-goals.txt"
test "$(sqlite3 "$live/meta.db" \
    'SELECT count(*) FROM goal_definitions_v2 WHERE updated_at_utc_micros != created_at_utc_micros OR archived_at_utc_micros IS NOT NULL;')" = 0
sqlite3 -separator '|' "$live/meta.db" \
    'SELECT id, site_id, name, query_schema_version, canonical_query_json, created_at_utc_micros, updated_at_utc_micros FROM saved_views ORDER BY id;' \
    >"$fixture/after-views.txt"
cmp "$fixture/before-views.txt" "$fixture/after-views.txt"
test "$(sha256sum "$live/events.duckdb" | cut -d' ' -f1)" = "$before_event_sha"
test "$("$current" report "$live" migration 2025-01-01 2025-01-02 \
    overview --format json)" = "$before_v1"
test "$(metric_v2_semantics "$current" "$live")" = "$before_v2"
test "$("$current" migrate "$live")" = "migrated metadata=v10 events=v7"
if "$previous" doctor "$live" >/dev/null 2>&1; then
    echo "metadata-7 predecessor unexpectedly opened metadata 8" >&2
    exit 1
fi

overflow="$fixture/overflow"
"$previous" init "$overflow" >/dev/null
"$previous" site add "$overflow" overflow Overflow https://overflow.example \
    --timezone UTC >/dev/null
overflow_site_id=$("$previous" site list "$overflow" |
    awk -F '\t' '$1 == "overflow" { print $2 }')
for index in $(seq 0 31); do
    "$previous" goal add "$overflow" overflow \
        "CLI goal $index" event "event_$index" >/dev/null
done
test "$(sqlite3 "$overflow/meta.db" 'SELECT count(*) FROM goals;')" = 32
sqlite3 "$overflow/meta.db" <<SQL
INSERT INTO goals
  (id, site_id, name, match_kind, match_value, created_at_utc_micros)
VALUES
  ('30000000-0000-4000-8000-000000000032', '$overflow_site_id',
   'Injected goal 32', 1, 'injected_32', 1000),
  ('30000000-0000-4000-8000-000000000033', '$overflow_site_id',
   'Injected goal 33', 2, '/injected-33', 1001);
SQL
test "$(sqlite3 "$overflow/meta.db" 'SELECT count(*) FROM goals;')" = 34
sqlite3 -separator '|' "$overflow/meta.db" \
    'SELECT id, site_id, name, match_kind, match_value, created_at_utc_micros FROM goals ORDER BY id;' \
    >"$fixture/overflow-before.txt"
overflow_backup="$fixture/overflow-backup"
"$current" backup "$overflow" "$overflow_backup" >/dev/null
test "$("$current" migrate "$overflow" "$overflow_backup")" = \
    "migrated metadata=v10 events=v7"
test "$(sqlite3 "$overflow/meta.db" \
    'SELECT count(*) FROM goal_definitions_v2 WHERE archived_at_utc_micros IS NULL;')" = 34
sqlite3 -separator '|' "$overflow/meta.db" \
    'SELECT id, site_id, name, match_kind, match_value, created_at_utc_micros FROM goal_definitions_v2 ORDER BY id;' \
    >"$fixture/overflow-after.txt"
cmp "$fixture/overflow-before.txt" "$fixture/overflow-after.txt"
if "$current" goal add "$overflow" overflow Rejected event rejected >/dev/null 2>&1; then
    echo "over-cap migrated site unexpectedly accepted another active goal" >&2
    exit 1
fi
if "$current" m3 filters-v2-series "$overflow" overflow \
    2025-01-01 2025-01-02 2024-12-30 2024-12-31 >/dev/null 2>&1
then
    echo "over-cap migrated site unexpectedly entered metric-v2 analysis" >&2
    exit 1
fi
sqlite3 "$overflow/meta.db" \
    'SELECT id FROM goal_definitions_v2 ORDER BY id;' \
    >"$fixture/overflow-ids-before-recovery.txt"
"$current" m3 goal-cap-recovery "$overflow" overflow \
    >"$fixture/overflow-recovery.json"
jq -e '
    .initial_active == 34 and .new_blocked_at_34_33_32 and
    .reactivation_blocked_at_33_32 and .new_succeeded_at_31 and
    .reactivation_succeeded_at_31 and .final_active == 32 and
    .definitions_preserved == 34
' "$fixture/overflow-recovery.json" >/dev/null
sqlite3 "$overflow/meta.db" \
    'SELECT id FROM goal_definitions_v2 ORDER BY id;' \
    >"$fixture/overflow-ids-after-recovery.txt"
cmp "$fixture/overflow-ids-before-recovery.txt" \
    "$fixture/overflow-ids-after-recovery.txt"
test "$(sqlite3 "$overflow/meta.db" \
    'SELECT count(*) FROM goal_definitions_v2 WHERE archived_at_utc_micros IS NULL;')" = 32

rolled_back="$fixture/rolled-back"
"$previous" restore "$backup" "$rolled_back" --verify >/dev/null
test "$("$previous" doctor "$rolled_back")" = \
    "ok metadata=v7 events=v7 sites=1 goals=2 funnels=0 stored_events=14 key=ok"
test "$("$previous" report "$rolled_back" migration 2025-01-01 2025-01-02 \
    overview --format json)" = "$before_v1"

fresh="$fixture/fresh"
"$current" init "$fresh" >/dev/null
test "$(sqlite3 "$fresh/meta.db" 'SELECT max(version) FROM meta_migrations;')" = 10
test "$(sqlite3 "$fresh/meta.db" \
    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='goal_definitions_v2';")" = 1
test "$(sqlite3 "$fresh/meta.db" \
    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='goals';")" = 0

printf 'metadata8_migration_e2e=pass predecessor=54f49ed309638da04eb1cd3fd67652832727068a metadata=7-to-10 events=7 rows=preserved saved_views=preserved reports=v1+v2 interruption=partial-copy replay=idempotent overflow=34-preserved+analysis-blocked+mutations-recovered rollback=matched-pair\n'
