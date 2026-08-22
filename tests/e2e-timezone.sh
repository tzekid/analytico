#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <analytico-binary>" >&2
    exit 2
fi

binary=$1
case "$binary" in
    /*) ;;
    *) binary="$PWD/$binary" ;;
esac

fixture=$(mktemp -d "$PWD/.zig-cache/timezone-e2e.XXXXXX")
server_pid=
cleanup() {
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT

expect_failure() {
    if "$@" >"$fixture/rejected.stdout" 2>"$fixture/rejected.stderr"; then
        echo "command unexpectedly succeeded: $*" >&2
        exit 1
    fi
}

data="$fixture/data"
"$binary" init "$data" >/dev/null
expect_failure "$binary" site add "$data" traversal Traversal \
    https://traversal.example --timezone ../UTC
expect_failure "$binary" site add "$data" missing Missing \
    https://missing.example --timezone No/Such_Zone

corrupt_root="$fixture/corrupt-zoneinfo"
mkdir -p "$corrupt_root/Europe"
printf 'not a TZif file\n' >"$corrupt_root/Europe/Berlin"
expect_failure "$binary" site add "$data" corrupt Corrupt \
    https://corrupt.example --timezone Europe/Berlin \
    --zoneinfo-root "$corrupt_root"
test -z "$("$binary" site list "$data")"

"$binary" site add "$data" berlin Berlin https://berlin.example \
    --timezone Europe/Berlin >/dev/null
site_id=$("$binary" site list "$data" | awk -F '\t' '$1 == "berlin" { print $2 }')
"$binary" event add "$data" berlin pageview /before-spring \
    1711841400000000 2024-03-30 203.0.113.1 Chrome Linux desktop >/dev/null
"$binary" event add "$data" berlin pageview /after-spring \
    1711924200000000 2024-03-31 203.0.113.2 Chrome Linux desktop >/dev/null

expected_berlin=$'1711841400000000\t2024-03-30\t2024-03-31\t60\n1711924200000000\t2024-03-31\t2024-04-01\t120'
test "$("$binary" m2 time-buckets "$data" "$site_id")" = "$expected_berlin"
report=$("$binary" report "$data" berlin 2024-03-30 2024-03-30 \
    overview --format json)
[[ "$report" == *'"metric_version":1'*'"page_views":1'* ]]
"$binary" doctor "$data" >/dev/null
expect_failure "$binary" doctor "$data" --zoneinfo-root "$fixture/missing-root"

port=$((51000 + ($$ % 500)))
base="http://127.0.0.1:$port"
"$binary" serve --listen "127.0.0.1:$port" \
    --meta "$data/meta.db" \
    --events "$data/events.duckdb" \
    --temp "$data/tmp" \
    --visitor-key-file "$data/visitor.key" \
    >"$fixture/server.stdout" 2>"$fixture/server.stderr" &
server_pid=$!
ready=false
for _ in {1..100}; do
    if curl --silent --fail "$base/readyz" >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 0.02
done
test "$ready" = true

event_id=00000000-0000-4000-8000-000000000b11
anonymous_id=00000000-0000-4000-8000-000000000b12
session_id=00000000-0000-4000-8000-000000000b13
occurred_seconds=$(date -u +%s)
occurred_ms=$((occurred_seconds * 1000))
expected_local_date=$(TZ=Europe/Berlin date -d "@$occurred_seconds" +%F)
offset_text=$(TZ=Europe/Berlin date -d "@$occurred_seconds" +%z)
payload=$(printf \
    '{"v":2,"site":"%s","event_id":"%s","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":0,"occurred_at_ms":%s,"type":"pageview","page":{"path":"/live"}}' \
    "$site_id" "$event_id" "$anonymous_id" "$session_id" "$occurred_ms")
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain;charset=UTF-8' \
    -H 'Origin: https://berlin.example' \
    -H 'X-Forwarded-For: 203.0.113.3' \
    --data-binary "$payload")" = 204

expect_failure "$binary" site timezone-set "$data" berlin UTC \
    --offline-rebucket
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "$base/readyz")" = 200

kill -TERM "$server_pid"
wait "$server_pid"
server_pid=
"$binary" doctor "$data" >/dev/null
live_row=$("$binary" m2 v2-inspect "$data" "$site_id" "$event_id")
offset_sign=1
if [[ ${offset_text:0:1} == - ]]; then offset_sign=-1; fi
expected_offset=$((offset_sign * (10#${offset_text:1:2} * 60 + 10#${offset_text:3:2})))
test "$(jq -r '.site_local_date' <<<"$live_row")" = "$expected_local_date"
test "$(jq -r '.site_utc_offset_minutes' <<<"$live_row")" = "$expected_offset"

expect_failure "$binary" site timezone-set "$data" berlin UTC
"$binary" site timezone-set "$data" berlin UTC --offline-rebucket >/dev/null
expected_utc=$'1711841400000000\t2024-03-30\t2024-03-30\t0\n1711924200000000\t2024-03-31\t2024-03-31\t0'
test "$("$binary" m2 time-buckets "$data" "$site_id" | head -n 2)" = "$expected_utc"
"$binary" site timezone-set "$data" berlin UTC >/dev/null
sqlite3 "$data/meta.db" \
    "UPDATE site_timezones SET rebucket_pending = 1 WHERE site_id = '$site_id'"
expect_failure "$binary" doctor "$data"
"$binary" site timezone-set "$data" berlin UTC --offline-rebucket >/dev/null
"$binary" doctor "$data" >/dev/null

echo "Timezone TZif, DST ingestion, locking, and rebucket checks passed"
