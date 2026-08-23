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
command -v curl >/dev/null
command -v jq >/dev/null
command -v sqlite3 >/dev/null
command -v prlimit >/dev/null

fixture=$(mktemp -d "$PWD/.zig-cache/diagnostics-e2e.XXXXXX")
server_pid=
cleanup() {
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT

seed_session() {
    local data=$1
    local token=$2
    local now token_hash
    now=$(date -u +%s)
    token_hash=$(printf '%s' "$token" | sha256sum | cut -d ' ' -f 1)
    sqlite3 "$data/meta.db" <<SQL
PRAGMA foreign_keys = ON;
INSERT INTO auth_users(id, display_name, created_at_utc_seconds)
VALUES ('diagnostics-fixture-user-000000000000', 'Diagnostics fixture', $now);
INSERT INTO auth_sessions(
  token_hash, user_id, csrf_token, created_at_utc_seconds,
  expires_at_utc_seconds, last_seen_at_utc_seconds, revoked_at_utc_seconds
) VALUES (
  '$token_hash', 'diagnostics-fixture-user-000000000000',
  'diagnostics-fixture-csrf-000000000000000000', $now,
  $((now + 3600)), $now, NULL
);
SQL
}

wait_ready() {
    local base=$1
    for _ in {1..100}; do
        curl --silent --fail "$base/readyz" >/dev/null 2>&1 && return
        sleep 0.02
    done
    echo "diagnostics server did not become ready" >&2
    exit 1
}

stop_server() {
    kill -TERM "$server_pid"
    wait "$server_pid"
    server_pid=
}

start_server() {
    local stdout=$1
    local stderr=$2
    "$binary" serve --listen "127.0.0.1:$port" \
        --meta "$data/meta.db" \
        --events "$data/events.duckdb" \
        --temp "$data/tmp" \
        --visitor-key-file "$data/visitor.key" \
        >"$stdout" 2>"$stderr" &
    server_pid=$!
    wait_ready "$base"
}

expect_code() {
    local expected=$1
    shift
    local actual
    actual=$(curl --silent --output "$fixture/response.body" \
        --write-out '%{http_code}' "$@")
    test "$actual" = "$expected"
}

port=$((52000 + ($$ % 500)))
base="http://127.0.0.1:$port"
data="$fixture/data"
log="$fixture/server.log"
session_token='diagnostics-session-token-000000000000000000'
cookie="analytico_session=$session_token"
today=$(date -u +%F)
occurred_ms=$(date -u +%s%3N)

"$binary" init "$data" >/dev/null
"$binary" site add "$data" diag Diagnostics https://diag.example \
    --timezone UTC >/dev/null
"$binary" site add "$data" other Other https://other.example \
    --timezone UTC >/dev/null
diag_site=$("$binary" site list "$data" | awk -F '\t' '$1 == "diag" { print $2 }')
other_site=$("$binary" site list "$data" | awk -F '\t' '$1 == "other" { print $2 }')
"$binary" auth configure "$data" "$base" >/dev/null
seed_session "$data" "$session_token"

start_server "$fixture/server.stdout" "$log"

live="$base/admin/sites/diag/live?from=$today&to=$today&compare=previous"
expect_code 303 "$live"
expect_code 303 --cookie 'analytico_session=invalid-session-token-that-is-long-enough' "$live"

v1_body=$(printf \
    '{"v":1,"site":"%s","type":"pageview","path":"/v1-private-path"}' \
    "$diag_site")
expect_code 204 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' \
    -H 'Origin: https://diag.example' \
    -H 'X-Forwarded-For: 203.0.113.10' \
    -H 'User-Agent: PrivateAgent/1.0' \
    --data-binary "$v1_body"
expect_code 200 "$base/v1/p.gif?site=$diag_site&path=%2Fpixel-private-path" \
    -H 'Referer: https://diag.example/private?token=pixel-secret' \
    -H 'X-Forwarded-For: 203.0.113.11'

anonymous_id='00000000-0000-4000-8000-000000002101'
session_id='00000000-0000-4000-8000-000000002102'
page_body=$(printf \
    '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000002103","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":0,"occurred_at_ms":%s,"type":"pageview","page":{"path":"/v2-private-path","hostname":"diag.example"}}' \
    "$diag_site" "$anonymous_id" "$session_id" "$occurred_ms")
expect_code 204 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://diag.example' \
    --data-binary "$page_body"
custom_body=$(printf \
    '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000002104","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":1,"occurred_at_ms":%s,"type":"event","name":"diagnostic_custom","properties":{"plan":"v2-secret-value","amount":1.25}}' \
    "$diag_site" "$anonymous_id" "$session_id" "$occurred_ms")
expect_code 204 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://diag.example' \
    --data-binary "$custom_body"
identify_body=$(printf \
    '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000002105","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":2,"occurred_at_ms":%s,"type":"identify","user":{"id":"fixture-user-a","traits":{"role":"operator-secret-trait"}}}' \
    "$diag_site" "$anonymous_id" "$session_id" "$occurred_ms")
expect_code 204 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://diag.example' \
    -H 'User-Agent: Mozilla/5.0 Chrome/127.0.0.0 Safari/537.36' \
    --data-binary "$identify_body"
expect_code 204 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://diag.example' \
    --data-binary "$custom_body"
expect_code 403 "$base/v1/p.gif?site=$diag_site&path=%2Frejected-pixel-private" \
    -H 'Referer: https://attacker-secret.example/private?token=rejected-secret'
invalid_property=$(printf \
    '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000002106","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":3,"occurred_at_ms":%s,"type":"event","name":"invalid_property","properties":{"secret":{"nested":true}}}' \
    "$diag_site" "$anonymous_id" "$session_id" "$occurred_ms")
expect_code 400 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://diag.example' \
    --data-binary "$invalid_property"
identity_conflict=$(printf \
    '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000002107","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":4,"occurred_at_ms":%s,"type":"identify","user":{"id":"fixture-user-b"}}' \
    "$diag_site" "$anonymous_id" "$session_id" "$occurred_ms")
expect_code 409 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://diag.example' \
    -H 'User-Agent: Mozilla/5.0 Chrome/127.0.0.0 Safari/537.36' \
    --data-binary "$identity_conflict"
other_body=$(printf \
    '{"v":1,"site":"%s","type":"pageview","path":"/other-site-secret"}' \
    "$other_site")
expect_code 204 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://other.example' \
    --data-binary "$other_body"

expect_code 200 --cookie "$cookie" "$live"
cp "$fixture/response.body" "$fixture/live.html"
if rg -n 'v1-private-path|pixel-private-path|rejected-pixel-private|v2-private-path|v2-secret-value|operator-secret-trait|other-site-secret|attacker-secret|rejected-secret' \
    "$fixture/live.html" "$log" >/dev/null; then
    echo "diagnostics fixture leaked input-derived values to HTML or logs" >&2
    exit 1
fi
stop_server
stopped=$(jq -R -c 'fromjson? | select(.code == "serve_stopped")' "$log")
jq -e '.diagnostics_retained == 10 and .diagnostics_overwritten == 0 and
    .diagnostics_accepted == 6 and .diagnostics_rejected == 3 and
    .diagnostics_duplicates == 1 and .diagnostics_store_failures == 0 and
    .diagnostic_snapshots == 1 and .diagnostic_snapshot_rows == 9' \
    <<<"$stopped" >/dev/null

restart_log="$fixture/restart.log"
start_server "$fixture/restart.stdout" "$restart_log"
expect_code 200 --cookie "$cookie" "$live"

oversized_v1=$(printf '%09000d' 0)
oversized_v2=$(printf '%017000d' 0)
oversized_pixel_query=$(printf '%04100d' 0)
expect_code 413 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' --data-binary "$oversized_v1"
expect_code 413 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' --data-binary "$oversized_v2"
expect_code 413 "$base/v1/p.gif?padding=$oversized_pixel_query"
expect_code 200 --cookie "$cookie" "$live"
stop_server
restarted=$(jq -R -c 'fromjson? | select(.code == "serve_stopped")' "$restart_log")
jq -e '.diagnostics_retained == 3 and .diagnostics_overwritten == 0 and
    .diagnostics_accepted == 0 and .diagnostics_rejected == 3 and
    .diagnostics_duplicates == 0 and .diagnostics_store_failures == 0 and
    .diagnostic_snapshots == 2 and .diagnostic_snapshot_rows == 0' \
    <<<"$restarted" >/dev/null

wrap_log="$fixture/wrap.log"
start_server "$fixture/wrap.stdout" "$wrap_log"
for index in {1..205}; do
    expect_code 204 -X POST "$base/v1/event" \
        -H 'Content-Type: text/plain' -H 'Origin: https://diag.example' \
        -H "X-Forwarded-For: 198.18.$index.1" \
        --data-binary "$v1_body"
done
stop_server
wrapped=$(jq -R -c 'fromjson? | select(.code == "serve_stopped")' "$wrap_log")
jq -e '.diagnostics_retained == 200 and .diagnostics_overwritten == 5 and
    .diagnostics_accepted == 200 and .diagnostics_rejected == 0 and
    .diagnostics_duplicates == 0 and .diagnostics_store_failures == 0 and
    .diagnostic_snapshots == 0 and .diagnostic_snapshot_rows == 0' \
    <<<"$wrapped" >/dev/null

fault_port=$((52500 + ($$ % 500)))
fault_base="http://127.0.0.1:$fault_port"
fault_data="$fixture/fault-data"
fault_log="$fixture/fault.log"
"$binary" init "$fault_data" >/dev/null
"$binary" site add "$fault_data" fault Fault https://fault.example \
    --timezone UTC >/dev/null
fault_site=$("$binary" site list "$fault_data" | awk -F '\t' '$1 == "fault" { print $2 }')
prlimit --fsize=0 -- "$binary" serve --listen "127.0.0.1:$fault_port" \
    --meta "$fault_data/meta.db" \
    --events "$fault_data/events.duckdb" \
    --temp "$fault_data/tmp" \
    --visitor-key-file "$fault_data/visitor.key" \
    > >(:) 2> >(cat >"$fault_log") &
server_pid=$!
wait_ready "$fault_base"
fault_body=$(printf \
    '{"v":1,"site":"%s","type":"pageview","path":"/store-failure-secret"}' \
    "$fault_site")
expect_code 500 -X POST "$fault_base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://fault.example' \
    --data-binary "$fault_body"
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "$fault_base/readyz")" = 503
stop_server
fault_stopped=$(jq -R -c 'fromjson? | select(.code == "serve_stopped")' "$fault_log")
jq -e '.diagnostics_retained == 1 and .diagnostics_store_failures == 1 and
    .diagnostic_snapshots == 0 and .diagnostic_snapshot_rows == 0' \
    <<<"$fault_stopped" >/dev/null
if rg -n 'store-failure-secret|203\.0\.113\.10|PrivateAgent|v2-secret-value|operator-secret-trait' \
    "$fixture"/*.log "$fixture"/*.html >/dev/null; then
    echo "diagnostics logs or HTML retained a forbidden input" >&2
    exit 1
fi

echo "bounded collection diagnostics, authenticated site filter, wrap, restart, and store failure passed"
