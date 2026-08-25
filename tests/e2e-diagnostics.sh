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
module_root=${ANALYTICO_PLAYWRIGHT_NODE_PATH:-"$PWD/.zig-cache/playwright-node/node_modules"}
browser_root=${PLAYWRIGHT_BROWSERS_PATH:-"$PWD/.zig-cache/ms-playwright"}
chromium_path=${ANALYTICO_CHROMIUM_PATH:-"$browser_root/chromium-1234/chrome-linux64/chrome"}
if [[ ! -d "$module_root/playwright" || ! -x "$chromium_path" ]]; then
    echo "browser fixture missing; run tests/setup-browser-e2e.sh" >&2
    exit 2
fi

fixture=$(mktemp -d "$PWD/.zig-cache/diagnostics-e2e.XXXXXX")
server_pid=
browser_pid=
cleanup() {
    if [[ -n "$browser_pid" ]] && kill -0 "$browser_pid" 2>/dev/null; then
        kill -TERM "$browser_pid" 2>/dev/null || true
        wait "$browser_pid" 2>/dev/null || true
    fi
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT

wait_file() {
    local path=$1
    for _ in {1..9000}; do
        [[ -f "$path" ]] && return
        if [[ -n "$browser_pid" ]] && ! kill -0 "$browser_pid" 2>/dev/null; then
            wait "$browser_pid" || true
            browser_pid=
            cat "$fixture/browser.stderr" >&2
            echo "browser exited before $path" >&2
            exit 1
        fi
        sleep 0.01
    done
    echo "timed out waiting for $path" >&2
    exit 1
}

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
    shift 2
    "$binary" serve --listen "127.0.0.1:$port" \
        --meta "$data/meta.db" \
        --events "$data/events.duckdb" \
        --temp "$data/tmp" \
        --visitor-key-file "$data/visitor.key" \
        "$@" \
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
"$binary" goal add "$data" diag "Diagnostic conversion" event \
    diagnostic_custom >/dev/null
for prefix in A B C D E F; do
    "$binary" goal add "$data" diag "$prefix mirror" event \
        diagnostic_custom >/dev/null
done
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
    -H 'User-Agent: Mozilla/5.0 Chrome/127.0.0.0 Safari/537.36' \
    --data-binary "$page_body"
custom_body=$(printf \
    '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000002104","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":1,"occurred_at_ms":%s,"type":"event","name":"diagnostic_custom","properties":{"plan":"v2-secret-value","amount":1.25}}' \
    "$diag_site" "$anonymous_id" "$session_id" "$occurred_ms")
expect_code 204 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://diag.example' \
    -H 'User-Agent: Mozilla/5.0 Chrome/127.0.0.0 Safari/537.36' \
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
    -H 'User-Agent: Mozilla/5.0 Chrome/127.0.0.0 Safari/537.36' \
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
grep -Fq 'id="live-region"' "$fixture/live.html"
grep -Fq 'Active now</span><strong>2</strong>' "$fixture/live.html"
grep -Fq 'Page views</span><strong>2</strong>' "$fixture/live.html"
grep -Fq 'Custom events</span><strong>1</strong>' "$fixture/live.html"
grep -Fq 'Conversions</span><strong>7</strong>' "$fixture/live.html"
for expected_goal in 'A mirror' 'B mirror' 'C mirror' 'D mirror' \
    'Diagnostic conversion'; do
    grep -Fq "$expected_goal" "$fixture/live.html"
done
if rg -n 'E mirror|F mirror' "$fixture/live.html" >/dev/null; then
    echo "Live rendered more than the ordered top five goals" >&2
    exit 1
fi
grep -Fq '/v2-private-path' "$fixture/live.html"
grep -Fq 'diagnostic_custom' "$fixture/live.html"
grep -Fq 'plan:string' "$fixture/live.html"
grep -Fq 'attacker-secret.example' "$fixture/live.html"
grep -Fq 'restart, are capped at 200 globally' "$fixture/live.html"
grep -Fq 'hx-status:5xx="swap:none"' "$fixture/live.html"
grep -Fq 'Traffic quality' "$fixture/live.html"

expect_code 200 --cookie "$cookie" \
    -H 'HX-Request: true' -H 'HX-Target: section#live-region' "$live"
cp "$fixture/response.body" "$fixture/live.fragment.html"
grep -Fq 'id="live-region"' "$fixture/live.fragment.html"
if rg -n '<!doctype|id="report"|Traffic quality' \
    "$fixture/live.fragment.html" >/dev/null; then
    echo "Live poll returned more than the exact current region" >&2
    exit 1
fi
expect_code 200 --cookie "$cookie" \
    -H 'HX-Request: true' -H 'HX-Target: report' "$live"
grep -Fq '<!doctype html>' "$fixture/response.body"

if rg -n 'v2-secret-value|operator-secret-trait|fixture-user-a|fixture-user-b|other-site-secret|private\?token|rejected-secret|203\.0\.113\.10|PrivateAgent' \
    "$fixture/live.html" "$log" >/dev/null; then
    echo "diagnostics fixture leaked input-derived values to HTML or logs" >&2
    exit 1
fi

control="$fixture/browser-control"
mkdir -p "$control"
TMPDIR=/tmp NODE_PATH="$module_root" \
    PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
    ANALYTICO_CHROMIUM_PATH="$chromium_path" \
    node tests/e2e-diagnostics-browser.cjs \
        "$base" "$session_token" "$live" "$control" \
        >"$fixture/browser.json" 2>"$fixture/browser.stderr" &
browser_pid=$!
wait_file "$control/ready-for-outage"
stop_server
stopped=$(jq -R -c 'fromjson? | select(.code == "serve_stopped")' "$log")
jq -e '.diagnostics_retained == 10 and .diagnostics_overwritten == 0 and
    .diagnostics_accepted == 6 and .diagnostics_rejected == 3 and
    .diagnostics_duplicates == 1 and .diagnostics_store_failures == 0 and
    .diagnostic_snapshots >= 7 and
    .diagnostic_snapshot_rows == (.diagnostic_snapshots * 9)' \
    <<<"$stopped" >/dev/null
: >"$control/server-stopped"
wait_file "$control/failure-observed"

restart_log="$fixture/restart.log"
start_server "$fixture/restart.stdout" "$restart_log"
: >"$control/server-restarted"
wait_file "$control/recovery-observed"
wait "$browser_pid"
browser_pid=
cat "$fixture/browser.json"
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
    .diagnostic_snapshots == 3 and .diagnostic_snapshot_rows == 0' \
    <<<"$restarted" >/dev/null

wrap_log="$fixture/wrap.log"
start_server "$fixture/wrap.stdout" "$wrap_log"
for index in {1..205}; do
    expect_code 204 -X POST "$base/v1/event" \
        -H 'Content-Type: text/plain' -H 'Origin: https://diag.example' \
        -H "X-Forwarded-For: 198.18.$index.1" \
        --data-binary "$v1_body"
done
expect_code 200 --cookie "$cookie" "$live"
cp "$fixture/response.body" "$fixture/wrapped-live.html"
grep -Fq '<dt>Selected-site retained</dt><dd>200</dd>' \
    "$fixture/wrapped-live.html"
grep -Fq '<dt>Newest rows shown</dt><dd>50</dd>' \
    "$fixture/wrapped-live.html"
grep -Fq '<span class="muted">#205</span>' "$fixture/wrapped-live.html"
test "$(rg -o 'data-label="Receipt"' "$fixture/wrapped-live.html" | wc -l)" = 50
stop_server
wrapped=$(jq -R -c 'fromjson? | select(.code == "serve_stopped")' "$wrap_log")
jq -e '.diagnostics_retained == 200 and .diagnostics_overwritten == 5 and
    .diagnostics_accepted == 200 and .diagnostics_rejected == 0 and
    .diagnostics_duplicates == 0 and .diagnostics_store_failures == 0 and
    .diagnostic_snapshots == 1 and .diagnostic_snapshot_rows == 200' \
    <<<"$wrapped" >/dev/null

scale_data="$fixture/scale-data"
data="$scale_data"
"$binary" init "$data" >/dev/null
"$binary" site add "$data" scale Scale https://scale.example \
    --timezone UTC >/dev/null
scale_site=$("$binary" site list "$data" |
    awk -F '\t' '$1 == "scale" { print $2 }')
"$binary" goal add "$data" scale Signup event signup >/dev/null
predicate_goal_output=$("$binary" goal add \
    "$data" scale "Predicate probe" event signup)
predicate_goal_id=${predicate_goal_output##* }
sqlite3 "$data/meta.db" <<SQL
UPDATE goal_definitions_v2
SET canonical_predicates_json =
  '{"schema":1,"predicates":["plan~is~string~scale"]}'
WHERE id = '$predicate_goal_id';
SQL
"$binary" auth configure "$data" "$base" >/dev/null
seed_session "$data" "$session_token"
"$binary" m3 million "$data" "$scale_site" >/dev/null
scale_now_micros=$(($(date -u +%s) * 1000000))
"$binary" m3 live-scale-fixture \
    "$data" "$scale_site" "$scale_now_micros" >/dev/null
normal_profile=$("$binary" m3 live-profile \
    "$data" scale "$scale_now_micros" normal)
strict_profile=$("$binary" m3 live-profile \
    "$data" scale "$scale_now_micros" strict)
jq -e '
    .strict_mode == false and .page_views > 0 and .custom_events > 0 and
    .conversions > 0 and .page_rows == 5 and .goal_rows == 1 and
    .timeout_interrupted and .connection_reused and
    (if .performance_enforced then
        (.sample_micros | length) == 10 and .p95_micros < 150000
     else
        (.sample_micros | length) == 0 and .p95_micros == null
     end)
' <<<"$normal_profile" >/dev/null
jq -e '
    .strict_mode and .page_views > 0 and .custom_events > 0 and
    .conversions > 0 and .page_rows == 5 and .goal_rows == 1 and
    .timeout_interrupted and .connection_reused and
    (if .performance_enforced then
        (.sample_micros | length) == 10 and .p95_micros < 150000
     else
        (.sample_micros | length) == 0 and .p95_micros == null
     end)
' <<<"$strict_profile" >/dev/null
jq -n -e --argjson normal "$normal_profile" --argjson strict "$strict_profile" '
    $normal.page_views == $strict.page_views and
    $normal.conversions == $strict.conversions and
    $normal.active_sessions > $strict.active_sessions and
    $normal.custom_events > $strict.custom_events
' >/dev/null
performance_enforced=$(jq -r '.performance_enforced' <<<"$normal_profile")
scale_live="$base/admin/sites/scale/live?from=$today&to=$today&compare=previous"

measure_live_fragment() {
    local mode=$1
    local samples=$2
    local timings="$fixture/${mode}-fragment-micros"
    : >"$timings"
    expect_code 200 --cookie "$cookie" \
        -H 'HX-Request: true' -H 'HX-Target: section#live-region' \
        "$scale_live"
    for _ in $(seq 1 "$samples"); do
        local seconds micros
        seconds=$(curl --silent --fail --cookie "$cookie" \
            -H 'HX-Request: true' -H 'HX-Target: section#live-region' \
            --output "$fixture/${mode}-fragment.html" \
            --write-out '%{time_total}' "$scale_live")
        micros=$(awk -v value="$seconds" 'BEGIN { printf "%.0f", value * 1000000 }')
        printf '%s\n' "$micros" >>"$timings"
    done
    grep -Fq 'id="live-region"' "$fixture/${mode}-fragment.html"
    grep -Fq 'Signup' "$fixture/${mode}-fragment.html"
    if grep -Fq '<!doctype' "$fixture/${mode}-fragment.html"; then
        echo "million-row Live fragment returned a complete document" >&2
        exit 1
    fi
    sort -n "$timings" | tail -1
}

start_server "$fixture/scale-normal.stdout" "$fixture/scale-normal.log"
normal_fragment_p95=$(measure_live_fragment normal \
    "$([[ "$performance_enforced" == true ]] && printf 10 || printf 1)")
normal_fragment_bytes=$(wc -c <"$fixture/normal-fragment.html")
stop_server
"$binary" site traffic-policy "$data" scale strict 10000000 >/dev/null
start_server "$fixture/scale-strict.stdout" "$fixture/scale-strict.log"
strict_fragment_p95=$(measure_live_fragment strict \
    "$([[ "$performance_enforced" == true ]] && printf 10 || printf 1)")
strict_fragment_bytes=$(wc -c <"$fixture/strict-fragment.html")
stop_server
start_server "$fixture/scale-timeout.stdout" "$fixture/scale-timeout.log" \
    --report-timeout-ms 1
expect_code 503 --cookie "$cookie" \
    -H 'HX-Request: true' -H 'HX-Target: section#live-region' \
    "$scale_live"
grep -Fq 'Live update timed out' "$fixture/response.body"
stop_server
if [[ "$performance_enforced" == true ]]; then
    test "$normal_fragment_p95" -lt 150000
    test "$strict_fragment_p95" -lt 150000
    "$binary" m3 live-explain "$data" scale \
        "$scale_now_micros" normal >"$fixture/live-explain.txt"
    grep -Fq 'Total Time' "$fixture/live-explain.txt"
fi
printf '{"live_scale":true,"normal_profile":%s,"strict_profile":%s,' \
    "$normal_profile" "$strict_profile"
printf '"normal_fragment_p95_micros":%s,"strict_fragment_p95_micros":%s,' \
    "$normal_fragment_p95" "$strict_fragment_p95"
printf '"normal_fragment_bytes":%s,"strict_fragment_bytes":%s}\n' \
    "$normal_fragment_bytes" "$strict_fragment_bytes"

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
