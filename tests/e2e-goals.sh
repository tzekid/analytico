#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <analytico-binary>" >&2
    exit 2
fi
binary=$1
case "$binary" in /*) ;; *) binary="$PWD/$binary" ;; esac

module_root=${ANALYTICO_PLAYWRIGHT_NODE_PATH:-"$PWD/.zig-cache/playwright-node/node_modules"}
browser_root=${PLAYWRIGHT_BROWSERS_PATH:-"$PWD/.zig-cache/ms-playwright"}
chromium_path=${ANALYTICO_CHROMIUM_PATH:-"$browser_root/chromium-1234/chrome-linux64/chrome"}
caddyfile=${ANALYTICO_CADDYFILE:-deploy/Caddyfile}
if [[ ! -d "$module_root/playwright" || ! -x "$chromium_path" ]]; then
    echo "browser fixture missing; run tests/setup-browser-e2e.sh" >&2
    exit 2
fi
command -v caddy >/dev/null
test -f "$caddyfile"

fixture=$(mktemp -d "$PWD/.zig-cache/goals-e2e.XXXXXX")
server_pid=
caddy_pid=
cleanup() {
    cleanup_status=$?
    if [[ -n "$caddy_pid" ]] && kill -0 "$caddy_pid" 2>/dev/null; then
        kill -TERM "$caddy_pid" 2>/dev/null || true
        wait "$caddy_pid" 2>/dev/null || true
    fi
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    if [[ "$cleanup_status" -ne 0 ]]; then
        sed -n '1,260p' "$fixture/server.stderr" >&2 || true
        sed -n '1,120p' "$fixture/caddy.stderr" >&2 || true
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT

server_port=${ANALYTICO_TEST_SERVER_PORT:-$((46600 + ($$ % 300)))}
proxy_port=${ANALYTICO_TEST_PROXY_PORT:-$((46900 + ($$ % 300)))}
upstream="http://127.0.0.1:$server_port"
dashboard="http://localhost:$proxy_port"
data="$fixture/data"

"$binary" init "$data" >/dev/null
"$binary" site add "$data" alpha Alpha https://alpha.example \
    --timezone UTC >/dev/null
"$binary" site add "$data" beta Beta https://beta.example \
    --timezone Europe/Berlin >/dev/null
alpha_id=$("$binary" site list "$data" |
    awk -F '\t' '$1 == "alpha" { print $2 }')
beta_id=$("$binary" site list "$data" |
    awk -F '\t' '$1 == "beta" { print $2 }')
test "${#alpha_id}" = 36
test "${#beta_id}" = 36
"$binary" m3 seed "$data" "$alpha_id" >/dev/null
"$binary" m3 goal-predicates-fixture "$data" "$alpha_id" >/dev/null
for index in $(seq 0 54); do
    path=$(printf '/goal-value-%02d' "$index")
    micros=$((1735776000000000 + index * 1000000))
    "$binary" event add "$data" alpha pageview "$path" "$micros" \
        2025-01-02 "198.18.$index.1" Chrome Linux desktop >/dev/null
done
"$binary" event add "$data" beta pageview /beta-secret \
    1735776000000000 2025-01-02 203.0.113.10 Safari macOS desktop >/dev/null

"$binary" goal add "$data" alpha "Active Signup" event signup >/dev/null
archived_goal_output=$("$binary" goal add "$data" alpha "Archived Purchase" event purchase)
archived_goal_id=${archived_goal_output##* }
reference_goal_output=$("$binary" goal add "$data" alpha "Referenced goal" event signup)
reference_goal_id=${reference_goal_output##* }
sqlite3 "$data/meta.db" <<SQL
UPDATE goal_definitions_v2
SET archived_at_utc_micros = created_at_utc_micros + 1,
    updated_at_utc_micros = created_at_utc_micros + 1
WHERE id = '$archived_goal_id';
INSERT INTO saved_views
  (id, site_id, name, query_schema_version, canonical_query_json,
   created_at_utc_micros, updated_at_utc_micros)
VALUES
  ('00000000-0000-4000-8000-000000000390', '$alpha_id',
   'Referenced trend', 1,
   '{"schema":1,"mode":"trend","series":["conversions~visitor~goal~$reference_goal_id"]}',
   90, 90),
  ('00000000-0000-4000-8000-000000000391', '$alpha_id',
   'Referenced breakdown', 1,
   '{"schema":1,"mode":"breakdown","selector":{"kind":"goal","value":"$reference_goal_id"}}',
   91, 91);
INSERT INTO segments
  (id, site_id, name, filter_schema_version, canonical_filter_json,
   created_at_utc_micros, updated_at_utc_micros)
VALUES
  ('00000000-0000-4000-8000-000000000392', '$alpha_id',
   'Germany', 1,
   '{"schema":1,"match":"all","filters":["event~country~is~string~DE"]}',
   92, 92),
  ('00000000-0000-4000-8000-000000000393', '$alpha_id',
   'Stale goal race', 1,
   '{"schema":1,"match":"all","filters":["event~country~is~string~DE"]}',
   93, 93);
WITH RECURSIVE indexes(value) AS (
  SELECT 0 UNION ALL SELECT value + 1 FROM indexes WHERE value < 31
)
INSERT INTO goal_definitions_v2
  (id, site_id, name, match_kind, match_value,
   canonical_predicates_json,
   created_at_utc_micros, updated_at_utc_micros,
   archived_at_utc_micros)
SELECT printf('40000000-0000-4000-8000-%012d', value),
       '$beta_id', printf('Beta goal %02d', value), 2,
       '/beta-secret', '{"schema":1,"predicates":[]}',
       100 + value, 100 + value, NULL
FROM indexes;
SQL
test "$(sqlite3 "$data/meta.db" \
    "SELECT count(*) FROM goal_definitions_v2 WHERE id='$archived_goal_id' AND archived_at_utc_micros IS NOT NULL;")" = 1
test "$(sqlite3 "$data/meta.db" \
    "SELECT count(*) FROM goal_definitions_v2 WHERE site_id='$beta_id' AND archived_at_utc_micros IS NULL;")" = 32

"$binary" auth configure "$data" "$dashboard" >/dev/null
setup_url=$("$binary" auth bootstrap "$data" --ttl 10m | sed -n '2p')

start_server() {
    : >"$fixture/server.stdout"
    : >"$fixture/server.stderr"
    if [[ ${1:-} == "timeout" ]]; then
        "$binary" serve --listen "127.0.0.1:$server_port" \
            --meta "$data/meta.db" --events "$data/events.duckdb" \
            --temp "$data/tmp" --visitor-key-file "$data/visitor.key" \
            --report-timeout-ms 1 \
            >"$fixture/server.stdout" 2>"$fixture/server.stderr" &
    else
        "$binary" serve --listen "127.0.0.1:$server_port" \
            --meta "$data/meta.db" --events "$data/events.duckdb" \
            --temp "$data/tmp" --visitor-key-file "$data/visitor.key" \
            >"$fixture/server.stdout" 2>"$fixture/server.stderr" &
    fi
    server_pid=$!
    for _ in {1..100}; do
        curl --silent --fail "$upstream/readyz" >/dev/null 2>&1 && break
        sleep 0.02
    done
    curl --silent --fail "$upstream/readyz" >/dev/null
}

stop_server() {
    kill -TERM "$server_pid"
    wait "$server_pid"
    server_pid=
}

start_server normal
{
    printf '{\n\tadmin off\n}\n'
    sed \
        -e "s|^analytics\\.example {|http://localhost:$proxy_port {|" \
        -e "s|127\\.0\\.0\\.1:4318|127.0.0.1:$server_port|" \
        "$caddyfile"
} >"$fixture/Caddyfile"
XDG_DATA_HOME="$fixture/caddy-data" \
    XDG_CONFIG_HOME="$fixture/caddy-config" \
    caddy run --config "$fixture/Caddyfile" \
    >"$fixture/caddy.stdout" 2>"$fixture/caddy.stderr" &
caddy_pid=$!
for _ in {1..100}; do
    status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
        "$dashboard/admin" || true)
    [[ "$status" == 303 ]] && break
    sleep 0.02
done
test "$status" = 303

cookie_file="$fixture/session.cookie"
TMPDIR=/tmp NODE_PATH="$module_root" \
    PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
    ANALYTICO_CHROMIUM_PATH="$chromium_path" \
    node tests/e2e-passkey-session.cjs "$dashboard" "$setup_url" "$cookie_file"
session_cookie=$(<"$cookie_file")
cookie="analytico_session=$session_cookie"

unauthenticated_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "$dashboard/admin/sites/alpha/journeys/goals?from=2025-01-01&to=2025-01-02&compare=none")
test "$unauthenticated_status" = 303
bad_origin_status=$(curl --silent --output "$fixture/bad-origin.html" \
    --write-out '%{http_code}' --cookie "$cookie" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -H 'Origin: https://attacker.example' \
    --data 'csrf=invalid' "$dashboard/admin/goals")
test "$bad_origin_status" = 403
bad_csrf_status=$(curl --silent --output "$fixture/bad-csrf.html" \
    --write-out '%{http_code}' --cookie "$cookie" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -H "Origin: $dashboard" \
    --data 'csrf=invalid' "$dashboard/admin/goals")
test "$bad_csrf_status" = 403

TMPDIR=/tmp NODE_PATH="$module_root" \
    PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
    ANALYTICO_CHROMIUM_PATH="$chromium_path" \
    node tests/e2e-goals-browser.cjs "$dashboard" "$session_cookie" \
    "$archived_goal_id" "$reference_goal_id" \
    "$fixture/goals-desktop.png" "$fixture/goals-mobile.png" \
    >"$fixture/browser.json"
cat "$fixture/browser.json"
jq -e '
    .native_crud and .discovered_page_size == 50 and
    .discovery_order == "count-desc-label-asc" and
    .zero_seen_confirmation and .reference_conflict_status == 409 and
    .typed_predicate_preview and .predicate_context_preserved and
    .predicate_event_row_semantics and .exact_goal_result and
    .predicate_edit_and_duplicate and
    .stale_context_recovery and
    .archived_trend_and_breakdown and .default_active_isolation and
    .site_isolation and .active_cap_recovery and
    .enhanced_double_submit_requests == 1 and
    .mobile_width == 390 and .mobile_overflow == false and
    .startup_data_requests == 0
' "$fixture/browser.json" >/dev/null
stop_server
"$binary" goal list "$data" alpha >"$fixture/goals-after-browser.txt"
test "$(sqlite3 "$data/meta.db" \
    "SELECT count(*) FROM goal_definitions_v2 WHERE site_id='$alpha_id' AND name='Stale segment must not save';")" = 0
test "$(grep -Fc $'Enhanced double submit\t' \
    "$fixture/goals-after-browser.txt")" = 1
grep -Fq "$reference_goal_id" "$fixture/goals-after-browser.txt"
if "$binary" report "$data" alpha 2025-01-01 2025-01-02 \
    goal "Pro purchases" --format json \
    >"$fixture/predicate-metric-v1.stdout" \
    2>"$fixture/predicate-metric-v1.stderr"; then
    echo "predicate-bearing metric-v1 goal unexpectedly executed" >&2
    exit 1
fi
grep -Fq 'UnsupportedMetricV1GoalPredicates' \
    "$fixture/predicate-metric-v1.stderr"

"$binary" site traffic-policy "$data" alpha strict 10000000 >/dev/null
"$binary" m3 million "$data" "$alpha_id" >/dev/null
start_server timeout
timeout_status=$(curl --silent --output "$fixture/timeout.html" \
    --write-out '%{http_code}' --cookie "$cookie" \
    "$dashboard/admin/sites/alpha/journeys/goals/new?from=2025-01-01&to=2025-01-12&compare=none&entity=page")
test "$timeout_status" = 503
grep -Fq 'Report timed out' "$fixture/timeout.html"
csrf_page="$fixture/timeout-form.html"
curl --silent --fail --cookie "$cookie" \
    "$dashboard/admin/sites/alpha/journeys/goals?from=2025-01-01&to=2025-01-12&compare=none" \
    >"$csrf_page"
csrf=$(sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' "$csrf_page")
test -n "$csrf"
preview_timeout_status=$(curl --silent --output "$fixture/preview-timeout.html" \
    --write-out '%{http_code}' --cookie "$cookie" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -H "Origin: $dashboard" \
    --data-urlencode "csrf=$csrf" \
    --data-urlencode 'site=alpha' \
    --data-urlencode 'from=2025-01-01' \
    --data-urlencode 'to=2025-01-12' \
    --data-urlencode 'compare=none' \
    --data-urlencode 'entity=event' \
    --data-urlencode 'match=exact' \
    --data-urlencode 'value=purchase' \
    --data-urlencode 'name=Timeout must not save' \
    --data-urlencode 'property_1=plan' \
    --data-urlencode 'rule_1=string:is' \
    --data-urlencode 'predicate_value_1=pro' \
    --data-urlencode 'intent=preview' \
    "$dashboard/admin/goals")
test "$preview_timeout_status" = 503
grep -Fq 'Nothing was saved' "$fixture/preview-timeout.html"
list_after_timeout_status=$(curl --silent --output "$fixture/list-after-timeout.html" \
    --write-out '%{http_code}' --cookie "$cookie" \
    "$dashboard/admin/sites/alpha/journeys/goals?from=2025-01-01&to=2025-01-12&compare=none")
test "$list_after_timeout_status" = 200
stop_server
"$binary" goal list "$data" alpha >"$fixture/goals-after-timeout.txt"
if grep -Fq 'Timeout must not save' "$fixture/goals-after-timeout.txt"; then
    echo "timed-out goal preview unexpectedly wrote metadata" >&2
    exit 1
fi

"$binary" m3 goal-discovery "$data" alpha 2025-01-01 2025-01-12 \
    >"$fixture/discovery.json"
cat "$fixture/discovery.json"
jq -e '
    .strict_mode and .page_entities == 8 and .custom_event_entities == 2 and
    .strict_signup_count == 100000 and .strict_purchase_count == 100000 and
    .purchase_goal_base_evidence and
    .timeout_interrupted and .connection_reused and
    .search_value == "/pricing" and .search_count == 100000
' "$fixture/discovery.json" >/dev/null
"$binary" m3 goal-predicates-profile "$data" alpha \
    2025-01-01 2025-01-12 >"$fixture/goal-predicate-profile.json"
cat "$fixture/goal-predicate-profile.json"
jq -e '
    .strict_mode and
    (if .performance_enforced then
        .total_matches == 100000 and .path_cardinality == 1 and
        (.sample_micros | length) == 10 and .p95_micros < 700000 and
        .preview_micros < 2000000 and .preview_property_count >= 0 and
        .preview_timeout_interrupted and .connection_reused
     else
        .total_matches == null and (.sample_micros | length) == 0 and
        .preview_micros == null and .preview_property_count == null
     end)
' "$fixture/goal-predicate-profile.json" >/dev/null
"$binary" m3 goal-predicates-explain "$data" alpha \
    2025-01-01 2025-01-12 >"$fixture/goal-predicate-explain.txt"
grep -Fq 'GOAL RESULT STATEMENT' "$fixture/goal-predicate-explain.txt"
grep -F 'Total Time' "$fixture/goal-predicate-explain.txt"

printf '{"goals_e2e":"pass","metadata":9,"events":7,'
printf '"auth":"passkey+origin+csrf","native_crud":true,'
printf '"discovery":"bounded+site-isolated+strict","timeout_no_write_reuse":true,'
printf '"goal_result_profile":"million+p95-under-700ms+explain",'
printf '"screenshots":"desktop+mobile","browser":%s,"probe":%s}\n' \
    "$(<"$fixture/browser.json")" "$(<"$fixture/discovery.json")"
