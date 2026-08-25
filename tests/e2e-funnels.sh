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

fixture=$(mktemp -d "$PWD/.zig-cache/funnels-e2e.XXXXXX")
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
        sed -n '1,160p' "$fixture/caddy.stderr" >&2 || true
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT

server_port=${ANALYTICO_TEST_SERVER_PORT:-$((47200 + ($$ % 300)))}
proxy_port=${ANALYTICO_TEST_PROXY_PORT:-$((47500 + ($$ % 300)))}
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
test "${#beta_id}" = 36
"$binary" m3 seed "$data" "$alpha_id" >/dev/null
"$binary" m3 goal-predicates-fixture "$data" "$alpha_id" >/dev/null
"$binary" event add "$data" beta pageview /beta-secret \
    1735776000000000 2025-01-02 203.0.113.10 Safari macOS desktop >/dev/null
goal_output=$("$binary" goal add "$data" alpha "Active Signup" event signup)
goal_id=${goal_output##* }
sqlite3 "$data/meta.db" <<SQL
UPDATE goal_definitions_v2
SET canonical_predicates_json =
  '{"schema":1,"predicates":["plan~is~string~pro"]}'
WHERE id = '$goal_id';
SQL
segment_id=00000000-0000-4000-8000-000000000692
stale_segment_id=00000000-0000-4000-8000-000000000693
sqlite3 "$data/meta.db" <<SQL
INSERT INTO segments
  (id, site_id, name, filter_schema_version, canonical_filter_json,
   created_at_utc_micros, updated_at_utc_micros)
VALUES
  ('$segment_id', '$alpha_id', 'Germany', 1,
   '{"schema":1,"match":"all","filters":["event~country~is~string~DE"]}',
   92, 92),
  ('$stale_segment_id', '$alpha_id', 'Stale funnel race', 1,
   '{"schema":1,"match":"all","filters":["event~country~is~string~DE"]}',
   93, 93);
SQL

"$binary" auth configure "$data" "$dashboard" >/dev/null
setup_url=$("$binary" auth bootstrap "$data" --ttl 10m | sed -n '2p')

start_server() {
    : >"$fixture/server.stdout"
    : >"$fixture/server.stderr"
    if [[ ${1:-} == timeout ]]; then
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
caddy adapt --config "$fixture/Caddyfile" --pretty \
    >"$fixture/caddy.json" 2>"$fixture/caddy-adapt.stderr"
jq -e '
  [.. | objects | .path? // empty |
    select(index("/admin/funnels") and index("/admin/funnels/edit"))][0] ==
  ["/admin/filters/apply", "/admin/filters/suggest", "/admin/filters/remove",
   "/admin/segments", "/admin/segments/update", "/admin/segments/rename",
   "/admin/segments/duplicate", "/admin/segments/delete",
   "/admin/saved-views", "/admin/saved-views/duplicate",
   "/admin/saved-views/rename", "/admin/saved-views/delete",
   "/admin/funnels", "/admin/funnels/edit"] and
  ([.. | objects | select(.max_size? == 65536)] | length) == 1
' "$fixture/caddy.json" >/dev/null
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
    "$dashboard/admin/sites/alpha/journeys/funnels?from=2025-01-01&to=2025-01-02&compare=none")
test "$unauthenticated_status" = 303
bad_origin_status=$(curl --silent --output "$fixture/bad-origin.html" \
    --write-out '%{http_code}' --cookie "$cookie" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -H 'Origin: https://attacker.example' \
    --data 'csrf=invalid' "$dashboard/admin/funnels")
test "$bad_origin_status" = 403
bad_csrf_status=$(curl --silent --output "$fixture/bad-csrf.html" \
    --write-out '%{http_code}' --cookie "$cookie" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -H "Origin: $dashboard" \
    --data 'csrf=invalid' "$dashboard/admin/funnels")
test "$bad_csrf_status" = 403

curl --silent --fail --cookie "$cookie" \
    "$dashboard/admin/sites/alpha/journeys/funnels/new?from=2025-01-01&to=2025-01-02&compare=none" \
    >"$fixture/invalid-goal-form.html"
csrf=$(sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' \
    "$fixture/invalid-goal-form.html")
test -n "$csrf"
invalid_goal_status=$(curl --silent --output "$fixture/invalid-goal.html" \
    --write-out '%{http_code}' --cookie "$cookie" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -H "Origin: $dashboard" \
    --data-urlencode "csrf=$csrf" \
    --data-urlencode 'site=alpha' \
    --data-urlencode 'from=2025-01-01' \
    --data-urlencode 'to=2025-01-02' \
    --data-urlencode 'compare=none' \
    --data-urlencode 'name=Invalid goal reference must not save' \
    --data-urlencode 'order=sequential' \
    --data-urlencode 'scope=sessions' \
    --data-urlencode 'window_seconds=0' \
    --data-urlencode 'step_count=2' \
    --data-urlencode 'step_kind_1=goal' \
    --data-urlencode 'step_goal_1=not-a-uuid' \
    --data-urlencode 'step_kind_2=event' \
    --data-urlencode 'step_value_2=signup' \
    --data-urlencode 'intent=save' \
    "$dashboard/admin/funnels")
test "$invalid_goal_status" = 422
! grep -Fq 'Internal Server Error' "$fixture/invalid-goal.html"

head -c 65536 /dev/zero | tr '\0' x >"$fixture/body-64k"
for route in /admin/funnels /admin/funnels/edit; do
    exact_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
        --cookie "$cookie" -H 'Content-Type: application/x-www-form-urlencoded' \
        -H "Origin: $dashboard" --data-binary @"$fixture/body-64k" \
        "$dashboard$route")
    test "$exact_status" = 400
done
printf x >>"$fixture/body-64k"
for route in /admin/funnels /admin/funnels/edit; do
    plus_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
        --cookie "$cookie" -H 'Content-Type: application/x-www-form-urlencoded' \
        -H "Origin: $dashboard" --data-binary @"$fixture/body-64k" \
        "$dashboard$route")
    test "$plus_status" = 413
    test "$plus_status" != 502
done

TMPDIR=/tmp NODE_PATH="$module_root" \
    PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
    ANALYTICO_CHROMIUM_PATH="$chromium_path" \
    node tests/e2e-funnels-browser.cjs "$dashboard" "$session_cookie" \
    "$goal_id" "$segment_id" "$stale_segment_id" \
    "$fixture/funnels-desktop.png" "$fixture/funnels-mobile.png" \
    >"$fixture/browser.json"
cat "$fixture/browser.json"
jq -e '
  .native_builder and .step_bounds == "2-8" and
  .oversized_definition_recovery and
  .settings_and_reorder and .predicate_goal_and_zero_preview and
  .goal_reference_conflict and .stale_goal_recovery and
  .archive_reactivate and .stale_context_recovery and .site_isolation and
  .enhanced_equivalent and .mobile_width == 390 and
  .mobile_overflow == false and .startup_data_requests == 0 and
  .maximum_response_bytes > 0
' "$fixture/browser.json" >/dev/null

curl --silent --fail --cookie "$cookie" \
    "$dashboard/admin/sites/alpha/journeys/funnels?from=2025-01-01&to=2025-01-02&compare=none" \
    >"$fixture/funnel-list.html"
curl --silent --fail --cookie "$cookie" \
    "$dashboard/admin/sites/alpha/journeys/funnels/new?from=2025-01-01&to=2025-01-02&compare=none" \
    >"$fixture/funnel-new.html"
list_gzip_bytes=$(gzip --stdout "$fixture/funnel-list.html" | wc -c)
new_gzip_bytes=$(gzip --stdout "$fixture/funnel-new.html" | wc -c)
test "$list_gzip_bytes" -le 32768
test "$new_gzip_bytes" -le 32768
stop_server

test "$(sqlite3 "$data/meta.db" \
    "SELECT count(*) FROM funnel_definitions WHERE name='Stale segment must not save';")" = 0
test "$(sqlite3 "$data/meta.db" \
    "SELECT count(*) FROM funnel_definitions WHERE name='Stale structural draft';")" = 0
test "$(sqlite3 "$data/meta.db" \
    "SELECT count(*) FROM funnel_definitions WHERE name='Oversized draft must not save';")" = 0
test "$(sqlite3 "$data/meta.db" \
    "SELECT count(*) FROM funnel_definitions WHERE name='Invalid goal reference must not save';")" = 0
test "$(sqlite3 "$data/meta.db" \
    "SELECT count(*) FROM funnel_definitions WHERE name='Checkout journey renamed' AND archived_at_utc_micros IS NULL;")" = 1
definition=$(sqlite3 "$data/meta.db" \
    "SELECT canonical_definition_json FROM funnel_definitions WHERE name='Checkout journey renamed';")
printf '%s\n' "$definition" | jq -e \
    --arg goal "$goal_id" '
  .schema == 1 and .order == "consecutive" and .scope == "visitors" and
  .window_seconds == 86400 and (.steps | length) == 4 and
  .steps[0].kind == "page" and .steps[0].predicates == ["plan~is~string~pro"] and
  .steps[1].kind == "event" and .steps[1].predicates == ["plan~is~string~pro"] and
  .steps[2].kind == "goal" and .steps[2].goal_id == $goal and
  .steps[3].value == "never"
' >/dev/null
if "$binary" funnel show "$data" alpha "Checkout journey renamed" \
    >"$fixture/richer.stdout" 2>"$fixture/richer.stderr"; then
    echo "richer funnel unexpectedly executed through the legacy CLI grammar" >&2
    exit 1
fi
grep -Fq 'UnsupportedLegacyFunnel' "$fixture/richer.stderr"

"$binary" site traffic-policy "$data" alpha strict 10000000 >/dev/null
"$binary" m3 million "$data" "$alpha_id" >/dev/null
"$binary" m3 funnel-availability-profile "$data" alpha \
    2025-01-01 2025-01-12 >"$fixture/profile.json"
cat "$fixture/profile.json"
jq -e '
  .strict_mode and .selector_count == 8 and
  (if .performance_enforced then
     (.sample_micros | length) == 10 and .p95_micros < 2000000 and
     .timeout_interrupted and .connection_reused
   else
     (.sample_micros | length) == 0 and .p95_micros == null and
     (.timeout_interrupted | not) and (.connection_reused | not)
   end)
' "$fixture/profile.json" >/dev/null
"$binary" m3 funnel-availability-explain "$data" alpha \
    2025-01-01 2025-01-12 >"$fixture/explain.txt"
grep -Fq 'FUNNEL SELECTOR AVAILABILITY STATEMENT' "$fixture/explain.txt"
grep -Fq 'Total Time' "$fixture/explain.txt"

start_server timeout
csrf_page="$fixture/timeout-form.html"
curl --silent --fail --cookie "$cookie" \
    "$dashboard/admin/sites/alpha/journeys/funnels?from=2025-01-01&to=2025-01-12&compare=none" \
    >"$csrf_page"
csrf=$(sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' "$csrf_page")
test -n "$csrf"
timeout_status=$(curl --silent --output "$fixture/timeout.html" \
    --write-out '%{http_code}' --cookie "$cookie" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -H "Origin: $dashboard" \
    --data-urlencode "csrf=$csrf" \
    --data-urlencode 'site=alpha' \
    --data-urlencode 'from=2025-01-01' \
    --data-urlencode 'to=2025-01-12' \
    --data-urlencode 'compare=none' \
    --data-urlencode 'name=Timeout must not save' \
    --data-urlencode 'order=sequential' \
    --data-urlencode 'scope=sessions' \
    --data-urlencode 'window_seconds=0' \
    --data-urlencode 'step_count=2' \
    --data-urlencode 'step_kind_1=page' \
    --data-urlencode 'step_value_1=/' \
    --data-urlencode 'step_kind_2=event' \
    --data-urlencode 'step_value_2=signup' \
    --data-urlencode 'intent=preview' \
    "$dashboard/admin/funnels")
test "$timeout_status" = 503
grep -Fq 'Nothing was saved' "$fixture/timeout.html"
list_after_timeout=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --cookie "$cookie" \
    "$dashboard/admin/sites/alpha/journeys/funnels?from=2025-01-01&to=2025-01-12&compare=none")
test "$list_after_timeout" = 200
stop_server
test "$(sqlite3 "$data/meta.db" \
    "SELECT count(*) FROM funnel_definitions WHERE name='Timeout must not save';")" = 0

printf '{"funnels_e2e":"pass","metadata":10,"events":7,'
printf '"auth":"passkey+origin+csrf","body_boundary":"65536+65537",'
printf '"migration_contract":"separate-gate","preview":"million+timeout+reuse+explain",'
printf '"list_gzip_bytes":%s,"new_gzip_bytes":%s,' \
    "$list_gzip_bytes" "$new_gzip_bytes"
printf '"screenshots":"desktop+mobile","browser":%s}\n' "$(<"$fixture/browser.json")"
