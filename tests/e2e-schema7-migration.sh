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
cleanup() {
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
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

echo "schema-6 to metadata-5/event-7 migration and rollback passed"
