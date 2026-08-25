#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <current-binary> <schema4-binary>" >&2
    exit 2
fi

current=$1
previous=$2
case "$current" in
    /*) ;;
    *) current="$PWD/$current" ;;
esac
case "$previous" in
    /*) ;;
    *) previous="$PWD/$previous" ;;
esac

fixture=$(mktemp -d)
migration_pid=
cleanup() {
    if [[ -n "$migration_pid" ]]; then
        kill -KILL "$migration_pid" 2>/dev/null || true
        wait "$migration_pid" 2>/dev/null || true
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT
live="$fixture/live"
"$previous" init "$live" >/dev/null
"$previous" site add "$live" migration Migration https://migration.example \
    --timezone UTC >/dev/null
site_id=$("$previous" site list "$live" |
    awk -F '\t' '$1 == "migration" { print $2 }')
rm "$live/events.duckdb"
"$current" m2 schema4-fixture "$live" "$site_id" >/dev/null

test "$("$previous" doctor "$live")" = \
    "ok metadata=v4 events=v4 sites=1 goals=0 funnels=0 stored_events=6 key=ok"
before=$("$previous" report "$live" migration 2026-08-20 2026-08-20 \
    overview --format json)
test "$before" = \
    '{"metric_version":1,"site":"migration","start_date":"2026-08-20","end_date":"2026-08-20","report":"overview","page_views":1,"visitor_days":1,"sessions":1,"custom_events":0,"bot_events":1}'

backup="$fixture/pre-schema5"
test "$("$current" backup "$live" "$backup")" = \
    "backup complete destination=$backup metadata=v4 events=v4"
test "$(jq -r .metadata_schema "$backup/manifest.json")" = 4
test "$(jq -r .event_schema "$backup/manifest.json")" = 4
verified="$fixture/verified-schema4"
"$current" restore "$backup" "$verified" --verify >/dev/null
test "$("$previous" doctor "$verified")" = \
    "ok metadata=v4 events=v4 sites=1 goals=0 funnels=0 stored_events=6 key=ok"
test "$("$previous" report "$verified" migration 2026-08-20 2026-08-20 \
    overview --format json)" = "$before"

test "$("$current" migrate "$live" "$backup")" = \
    "migrated metadata=v9 events=v7"
test "$("$current" doctor "$live")" = \
    "ok metadata=v9 events=v7 sites=1 goals=0 funnels=0 stored_events=6 key=ok"
test "$("$current" report "$live" migration 2026-08-20 2026-08-20 \
    overview --format json)" = "$before"
test "$("$current" m2 identity-links "$live")" = 1

inspect() {
    "$current" m2 v2-inspect "$live" "$site_id" \
        "00000000-0000-4000-8000-000000000$1"
}
jq -e '
    .device_category == "desktop" and .traffic_class == 1 and
    .classifier_version == 0 and .bot_rule == "" and
    .signals.version == 0 and .client_hint_consistency == 0 and
    (has("legacy_bot_verdict") | not)
' <<<"$(inspect 401)" >/dev/null
jq -e '
    .device_category == "unknown" and .traffic_class == 2 and
    .classifier_version == 0 and .bot_rule == "legacy-device-bot" and
    .signals.version == 0 and .session_start == true
' <<<"$(inspect 402)" >/dev/null
while read -r suffix rule; do
    jq -e --arg rule "$rule" '
        .device_category == "desktop" and .traffic_class == 4 and
        .classifier_version == 1 and .bot_rule == $rule and
        .signals.version == 0 and .session_start == false
    ' <<<"$(inspect "$suffix")" >/dev/null
done <<'EOF'
403 exclude.tracker
404 exclude.network
405 exclude.both
EOF
jq -e '
    .device_category == "unknown" and .traffic_class == 4 and
    .classifier_version == 1 and .bot_rule == "exclude.tracker" and
    .signals.version == 0 and .session_start == false
' <<<"$(inspect 406)" >/dev/null

quality=$("$current" report "$live" migration 2026-08-20 2026-08-20 \
    traffic-quality --format json)
jq -e '
    .traffic_classes == [
      {"class":"human-presumed","events":1},
      {"class":"declared-bot","events":1},
      {"class":"automation","events":0},
      {"class":"excluded","events":4},
      {"class":"suspected","events":0}
    ] and ([.signal_evidence[]] | all(. == 0)) and
    (has("shadow") | not) and
    .exclusion_sources == [
      {"source":"tracker","events":2},
      {"source":"network","events":1},
      {"source":"both","events":1}
    ]
' <<<"$quality" >/dev/null

# Current migration is idempotent; rollback is a matched pair restore opened by
# the exact schema-4 predecessor.
test "$("$current" migrate "$live" "$backup")" = \
    "migrated metadata=v9 events=v7"
rolled_back="$fixture/rolled-back"
"$previous" restore "$backup" "$rolled_back" --verify >/dev/null
test "$("$previous" doctor "$rolled_back")" = \
    "ok metadata=v4 events=v4 sites=1 goals=0 funnels=0 stored_events=6 key=ok"
test "$("$previous" report "$rolled_back" migration 2026-08-20 2026-08-20 \
    overview --format json)" = "$before"

# Exercise migration 5 itself at the release-scale row count. The exact
# predecessor creates a canonical schema-4 database, then the candidate is
# killed only after it has the event database open and has consumed CPU in the
# migration. Retrying must recover the interrupted file and preserve metric-v1
# output exactly.
million="$fixture/million"
"$previous" init "$million" >/dev/null
"$previous" site add "$million" million Million https://million.example \
    --timezone UTC >/dev/null
million_site_id=$("$previous" site list "$million" |
    awk -F '\t' '$1 == "million" { print $2 }')
"$previous" m3 million "$million" "$million_site_id" >/dev/null
million_before=$("$previous" report "$million" million \
    2025-01-01 2025-01-31 overview --format json)
million_backup="$fixture/million-schema4-backup"
"$current" backup "$million" "$million_backup" >/dev/null
"$current" migrate "$million" "$million_backup" \
    >"$fixture/million-migrate.stdout" \
    2>"$fixture/million-migrate.stderr" &
migration_pid=$!
opened_at_ticks=
for _ in {1..500}; do
    if ! kill -0 "$migration_pid" 2>/dev/null; then
        echo "schema-5 million-row migration completed before interruption" >&2
        wait "$migration_pid" || true
        exit 1
    fi
    for fd in /proc/"$migration_pid"/fd/*; do
        if [[ "$(readlink "$fd" 2>/dev/null || true)" == \
            "$million/events.duckdb"* ]]; then
            ticks=$(awk '{ print $14 + $15 }' /proc/"$migration_pid"/stat)
            if [[ -z "$opened_at_ticks" ]]; then
                opened_at_ticks=$ticks
            elif (( ticks >= opened_at_ticks + 2 )); then
                break 2
            fi
        fi
    done
    sleep 0.01
done
if [[ -z "$opened_at_ticks" ]] ||
    (( $(awk '{ print $14 + $15 }' /proc/"$migration_pid"/stat) < opened_at_ticks + 2 )); then
    echo "schema-5 million-row migration never became active on the event database" >&2
    kill -KILL "$migration_pid" 2>/dev/null || true
    wait "$migration_pid" 2>/dev/null || true
    exit 1
fi
kill -KILL "$migration_pid"
if wait "$migration_pid" 2>/dev/null; then
    echo "interrupted schema-5 migration unexpectedly exited successfully" >&2
    exit 1
fi
migration_pid=
test "$("$current" migrate "$million" "$million_backup")" = \
    "migrated metadata=v9 events=v7"
test "$("$current" doctor "$million")" = \
    "ok metadata=v9 events=v7 sites=1 goals=0 funnels=0 stored_events=1000000 key=ok"
test "$("$current" report "$million" million \
    2025-01-01 2025-01-31 overview --format json)" = "$million_before"
test "$("$current" migrate "$million" "$million_backup")" = \
    "migrated metadata=v9 events=v7"

printf '%s\n' "$quality"
echo "exact schema-4 mapping, million-row interruption/retry, repeat, backup, restore, and rollback passed"
