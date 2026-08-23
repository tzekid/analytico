#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <current-binary> <schema6-binary>" >&2
    exit 2
fi
current=$1
previous=$2
case "$current" in /*) ;; *) current="$PWD/$current" ;; esac
case "$previous" in /*) ;; *) previous="$PWD/$previous" ;; esac

fixture=$(mktemp -d)
server_pid=
migration_pid=
cleanup() {
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
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
site_id=$("$previous" site list "$live" | \
    awk -F '\t' '$1 == "migration" { print $2 }')
port=$((49100 + ($$ % 500)))
base="http://127.0.0.1:$port"
start_server() {
    local binary=$1
    "$binary" serve --listen "127.0.0.1:$port" \
        --meta "$live/meta.db" --events "$live/events.duckdb" \
        --temp "$live/tmp" --visitor-key-file "$live/visitor.key" \
        >"$fixture/server.stdout" 2>"$fixture/server.stderr" &
    server_pid=$!
    for _ in {1..100}; do
        curl --silent --fail "$base/readyz" >/dev/null 2>&1 && break
        sleep 0.02
    done
    test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
        "$base/readyz")" = 200
}
send_event() {
    local suffix=$1
    local body
    body=$(printf '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000b%s","anonymous_id":"00000000-0000-4000-8000-000000000c%s","identity_quality":"persistent","session_id":"00000000-0000-4000-8000-000000000d%s","sequence":0,"occurred_at_ms":%s,"type":"pageview","page":{"path":"/migration-%s","hostname":"migration.example"}}' \
        "$site_id" "$suffix" "$suffix" "$suffix" "$(date +%s%3N)" "$suffix")
    curl --silent --output /dev/null --write-out '%{http_code}' \
        -X POST "$base/v2/event" -H 'Content-Type: text/plain' \
        -H 'Origin: https://migration.example' \
        -H 'X-Forwarded-For: 203.0.113.42' \
        -H 'User-Agent: Mozilla/5.0 Firefox/140.0' --data-binary "$body"
}

start_server "$previous"
test "$(send_event 01)" = 204
kill -TERM "$server_pid"
wait "$server_pid"
server_pid=
test "$("$previous" doctor "$live")" = \
    "ok metadata=v4 events=v6 sites=1 goals=0 funnels=0 stored_events=1 key=ok"
today=$(date --utc +%F)
before=$("$previous" report "$live" migration "$today" "$today" \
    overview --format json)

backup="$fixture/pre-schema7"
test "$("$current" backup "$live" "$backup")" = \
    "backup complete destination=$backup metadata=v4 events=v6"
test "$(jq -r .event_schema "$backup/manifest.json")" = 6
verified="$fixture/verified-schema6"
"$current" restore "$backup" "$verified" --verify >/dev/null
test "$("$previous" doctor "$verified")" = \
    "ok metadata=v4 events=v6 sites=1 goals=0 funnels=0 stored_events=1 key=ok"
test "$("$current" migrate "$live" "$backup")" = \
    "migrated metadata=v5 events=v7"
test "$("$current" doctor "$live")" = \
    "ok metadata=v5 events=v7 sites=1 goals=0 funnels=0 stored_events=1 key=ok"
inspect=$("$current" m2 v2-inspect "$live" "$site_id" \
    00000000-0000-4000-8000-000000000b01)
jq -e '.event_schema_version == 7 and (has("network_day_id") | not)' \
    <<<"$inspect" >/dev/null
quality=$("$current" report "$live" migration "$today" "$today" \
    traffic-quality --format json)
jq -e '.traffic_quality_version == 5 and .strict_mode == false and
    .daily_event_ceiling == 100000 and .maximum_minted_identities == 0' \
    <<<"$quality" >/dev/null

start_server "$current"
test "$(send_event 02)" = 204
kill -TERM "$server_pid"
wait "$server_pid"
server_pid=
quality=$("$current" report "$live" migration "$today" "$today" \
    traffic-quality --format json)
jq -e '.accepted_events == 2 and .maximum_minted_identities == 1 and
    .mint_anomaly_groups == 0' <<<"$quality" >/dev/null

rolled_back="$fixture/rolled-back"
"$previous" restore "$backup" "$rolled_back" --verify >/dev/null
test "$("$previous" doctor "$rolled_back")" = \
    "ok metadata=v4 events=v6 sites=1 goals=0 funnels=0 stored_events=1 key=ok"
test "$("$previous" report "$rolled_back" migration "$today" "$today" \
    overview --format json)" = "$before"

million="$fixture/million"
"$previous" init "$million" >/dev/null
"$previous" site add "$million" million Million https://million.example \
    --timezone UTC >/dev/null
million_site_id=$("$previous" site list "$million" |
    awk -F '\t' '$1 == "million" { print $2 }')
"$previous" m3 million "$million" "$million_site_id" >/dev/null
test "$("$previous" doctor "$million")" = \
    "ok metadata=v4 events=v6 sites=1 goals=0 funnels=0 stored_events=1000000 key=ok"
million_before_evidence=$("$current" m3 legacy-evidence "$million")
test "$(jq -r .event_migration_version <<<"$million_before_evidence")" = 6
test "$(jq -r .rows <<<"$million_before_evidence")" = 1000000
million_before=$("$previous" report "$million" million \
    2025-01-01 2025-01-12 overview --format json)
million_backup="$fixture/million-schema6-backup"
test "$("$current" backup "$million" "$million_backup")" = \
    "backup complete destination=$million_backup metadata=v4 events=v6"
"$current" migrate "$million" "$million_backup" \
    >"$fixture/million-migrate.stdout" \
    2>"$fixture/million-migrate.stderr" &
migration_pid=$!
opened_at_ticks=
for _ in {1..500}; do
    if ! kill -0 "$migration_pid" 2>/dev/null; then
        echo "schema-7 million-row migration completed before interruption" >&2
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
    echo "schema-7 million-row migration never became active on the event database" >&2
    exit 1
fi
kill -KILL "$migration_pid"
if wait "$migration_pid" 2>/dev/null; then
    echo "interrupted schema-7 migration unexpectedly exited successfully" >&2
    exit 1
fi
migration_pid=
test "$("$current" migrate "$million" "$million_backup")" = \
    "migrated metadata=v5 events=v7"
test "$("$current" doctor "$million")" = \
    "ok metadata=v5 events=v7 sites=1 goals=0 funnels=0 stored_events=1000000 key=ok"
million_after_evidence=$("$current" m3 legacy-evidence "$million")
test "$(jq -r .event_migration_version <<<"$million_after_evidence")" = 7
test "$(jq -r .rows <<<"$million_after_evidence")" = 1000000
test "$(jq -r .preserved_fingerprint <<<"$million_after_evidence")" = \
    "$(jq -r .preserved_fingerprint <<<"$million_before_evidence")"
test "$("$current" report "$million" million \
    2025-01-01 2025-01-12 overview --format json)" = "$million_before"
test "$("$current" migrate "$million" "$million_backup")" = \
    "migrated metadata=v5 events=v7"
million_rollback="$fixture/million-rollback"
"$previous" restore "$million_backup" "$million_rollback" --verify >/dev/null
test "$("$previous" doctor "$million_rollback")" = \
    "ok metadata=v4 events=v6 sites=1 goals=0 funnels=0 stored_events=1000000 key=ok"
test "$("$previous" report "$million_rollback" million \
    2025-01-01 2025-01-12 overview --format json)" = "$million_before"

echo "schema-6 to metadata-5/event-7 one-row and interrupted million-row migration, retry, repeat, restore, and rollback passed"
