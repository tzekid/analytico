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
module_root=${ANALYTICO_PLAYWRIGHT_NODE_PATH:-"$PWD/.zig-cache/playwright-node/node_modules"}
browser_root=${PLAYWRIGHT_BROWSERS_PATH:-"$PWD/.zig-cache/ms-playwright"}
chromium_path=${ANALYTICO_CHROMIUM_PATH:-"$browser_root/chromium-1234/chrome-linux64/chrome"}
if [[ ! -d "$module_root/playwright" || ! -x "$chromium_path" ]]; then
    echo "browser fixture missing; run tests/setup-browser-e2e.sh" >&2
    exit 2
fi
command -v caddy >/dev/null
caddyfile=${ANALYTICO_CADDYFILE:-deploy/Caddyfile}
test -f "$caddyfile"

fixture=$(mktemp -d "$PWD/.zig-cache/m6-e2e.XXXXXX")
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
        sed -n '1,240p' "$fixture/server.stderr" >&2 || true
        sed -n '1,120p' "$fixture/caddy.stderr" >&2 || true
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT

server_port=${ANALYTICO_TEST_SERVER_PORT:-$((47000 + ($$ % 700)))}
proxy_port=${ANALYTICO_TEST_PROXY_PORT:-$((48000 + ($$ % 700)))}
upstream="http://127.0.0.1:$server_port"
dashboard="http://localhost:$proxy_port"
data="$fixture/data"

"$binary" init "$data" >/dev/null
"$binary" site add "$data" example Example https://example.com \
    --timezone UTC >/dev/null
"$binary" site add "$data" second "Second Site" https://second.example \
    --timezone Europe/Berlin >/dev/null
"$binary" site add "$data" empty "Empty Site" https://empty.example \
    --timezone UTC >/dev/null
"$binary" site add "$data" broken "Broken Tracking" https://broken.example \
    --timezone UTC >/dev/null
"$binary" site add "$data" currency "Currency Overflow" \
    https://currency.example --timezone UTC >/dev/null
"$binary" site add "$data" properties "Property Breakdown" \
    https://properties-ui.example --timezone UTC >/dev/null
site_id=$("$binary" site list "$data" |
    awk -F '\t' '$1 == "example" { print $2 }')
broken_site_id=$("$binary" site list "$data" |
    awk -F '\t' '$1 == "broken" { print $2 }')
currency_site_id=$("$binary" site list "$data" |
    awk -F '\t' '$1 == "currency" { print $2 }')
property_site_id=$("$binary" site list "$data" |
    awk -F '\t' '$1 == "properties" { print $2 }')
"$binary" goal add "$data" example Signup event signup >/dev/null
unsafe_goal_output=$("$binary" goal add "$data" example \
    '<script>alert(1)</script> "&' event escaped)
unsafe_goal_id=${unsafe_goal_output##* }
test "${#unsafe_goal_id}" = 36
"$binary" funnel add "$data" example Journey \
    path=/ path=/pricing event=signup >/dev/null
"$binary" m3 seed "$data" "$site_id" >/dev/null
"$binary" site traffic-policy "$data" example off 1 >/dev/null
"$binary" event add "$data" second pageview /second \
    1735776000000000 2025-01-02 203.0.113.20 Safari macOS desktop >/dev/null
"$binary" event add "$data" second pageview /another \
    1735776060000000 2025-01-02 203.0.113.21 Safari iOS mobile >/dev/null
"$binary" auth configure "$data" "$dashboard" >/dev/null
setup_url=$("$binary" auth bootstrap "$data" --ttl 10m | sed -n '2p')

start_server() {
    "$binary" serve --listen "127.0.0.1:$server_port" \
        --meta "$data/meta.db" \
        --events "$data/events.duckdb" \
        --temp "$data/tmp" \
        --visitor-key-file "$data/visitor.key" \
        "$@" \
        >"$fixture/server.stdout" 2>"$fixture/server.stderr" &
    server_pid=$!
    for _ in {1..100}; do
        curl --silent --fail "$upstream/readyz" >/dev/null 2>&1 && return
        sleep 0.02
    done
    echo "server did not become ready" >&2
    exit 1
}

start_server
received_date=$(date -u +%F)
received_end_date=$(date -u -d "$received_date + 1 day" +%F)
occurred_ms=$(date -u +%s%3N)
for index in {0..104}; do
    case $((index % 5)) in
        0) mixed='"alpha"' ;;
        1) mixed='42' ;;
        2) mixed='42.500000' ;;
        3) mixed='true' ;;
        4) mixed='null' ;;
    esac
    optional=
    if (( index % 2 == 0 )); then
        optional=',"optional":"present"'
    fi
    property_body=$(printf \
        '{"v":2,"site":"%s","event_id":"00000000-0000-4000-9000-%012d","anonymous_id":"00000000-0000-4000-9000-000000000201","identity_quality":"persistent","session_id":"00000000-0000-4000-9000-000000000301","sequence":%d,"occurred_at_ms":%s,"type":"event","name":"property_probe","properties":{"high":"Value-%03d","plan":"%s","mixed":%s,"nullable":null%s}}' \
        "$property_site_id" "$((index + 1))" "$index" "$occurred_ms" \
        "$index" "$([[ $((index % 2)) == 0 ]] && printf Pro || printf Free)" \
        "$mixed" "$optional")
    test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
        -X POST "$upstream/v2/event" -H 'Content-Type: text/plain' \
        -H 'Origin: https://properties-ui.example' \
        -H "X-Forwarded-For: 198.18.$index.1" \
        -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) Chrome/140.0' \
        --data-binary "$property_body")" = 204
done
currencies=(AUD EUR GBP USD)
for index in "${!currencies[@]}"; do
    sequence=$((index + 1))
    event_id=$(printf '00000000-0000-4000-8000-%012d' "$sequence")
    currency_body=$(printf \
        '{"v":2,"site":"%s","event_id":"%s","anonymous_id":"00000000-0000-4000-8000-000000000101","identity_quality":"persistent","session_id":"00000000-0000-4000-8000-000000000201","sequence":%s,"occurred_at_ms":%s,"type":"event","name":"purchase","value":{"amount":"1.00","currency":"%s"}}' \
        "$currency_site_id" "$event_id" "$sequence" "$occurred_ms" \
        "${currencies[$index]}")
    test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
        -X POST "$upstream/v2/event" -H 'Content-Type: text/plain' \
        -H 'Origin: https://currency.example' \
        -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) Chrome/140.0' \
        --data-binary "$currency_body")" = 204
done
broken_body=$(printf \
    '{"v":1,"site":"%s","type":"pageview","path":"/rejected"}' \
    "$broken_site_id")
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    -X POST "$upstream/v1/event" \
    -H 'Content-Type: text/plain' \
    -H 'Origin: https://attacker.example' \
    --data-binary "$broken_body")" = 403
{
    printf '{\n\tadmin off\n}\n'
    sed \
        -e "s|^analytics\\.example {|http://localhost:$proxy_port {|" \
        -e "s|127\\.0\\.0\\.1:4318|127.0.0.1:$server_port|" \
        "$caddyfile"
} >"$fixture/Caddyfile"
caddy validate --config "$fixture/Caddyfile" >"$fixture/caddy.validate" 2>&1
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
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "$dashboard/")" = 303
test "$(curl --silent --output /dev/null --write-out '%{redirect_url}' \
    "$dashboard/")" = "$dashboard/admin"
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "$dashboard/tracker.aef65945.js")" = 200
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "$dashboard/not-a-route")" = 404

cookie_file="$fixture/session.cookie"
TMPDIR=/tmp NODE_PATH="$module_root" \
    PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
    ANALYTICO_CHROMIUM_PATH="$chromium_path" \
    node tests/e2e-passkey-session.cjs "$dashboard" "$setup_url" "$cookie_file"
session_cookie=$(<"$cookie_file")
cookie="analytico_session=$session_cookie"

range='site=example&start=2025-01-01&end=2025-01-02&report=overview'
dates='from=2025-01-01&to=2025-01-02&compare=previous'
overview="$dashboard/admin/sites/example/overview?v=1&$dates&metric=visitors"
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --cookie "$cookie" "$dashboard/admin?$range")" = 303
test "$(curl --silent --output /dev/null --write-out '%{redirect_url}' \
    --cookie "$cookie" "$dashboard/admin?$range")" = "$overview"
curl --silent --fail --cookie "$cookie" \
    "$overview" >"$fixture/page-one.html"
curl --silent --fail --cookie "$cookie" \
    "$overview" >"$fixture/page-two.html"
cmp "$fixture/page-one.html" "$fixture/page-two.html"
while IFS='|' read -r path label extra; do
    route_page="$fixture/route-${label,,}.html"
    curl --silent --fail --location --cookie "$cookie" \
        "$dashboard/admin/sites/example/$path?$dates$extra" \
        >"$route_page"
    grep -Fq "<h1>$label</h1>" "$route_page"
    grep -Fq 'class="primary-navigation" aria-label="Primary"' "$route_page"
    grep -Fq "<span class=\"nav-label\">$label</span>" "$route_page"
done <<'ROUTES'
overview|Overview|
analyze|Analyze|
journeys/goals|Journeys|
sessions|Sessions|
live|Live|
settings/general|Settings|
ROUTES
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --cookie "$cookie" "$dashboard/admin/sites/example/not-a-destination")" = 404
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --cookie "$cookie" "$overview&site=second")" = 400
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --cookie "$cookie" \
    "$dashboard/admin/sites/example/overview?start=2025-01-01&end=2025-01-02")" = 303
test "$(curl --silent --output /dev/null --write-out '%{redirect_url}' \
    --cookie "$cookie" \
    "$dashboard/admin/sites/example/overview?start=2025-01-01&end=2025-01-02")" = "$overview"
default_location=$(curl --silent --output /dev/null --write-out '%{redirect_url}' \
    --cookie "$cookie" "$dashboard/admin/sites/example/overview")
[[ "$default_location" == "$dashboard/admin/sites/example/overview?v=1&from="* ]]
[[ "$default_location" == *'&to='*'&compare=previous&metric=visitors' ]]
status=$(curl --silent --output "$fixture/invalid-calendar.html" \
    --write-out '%{http_code}' --cookie "$cookie" \
    "$dashboard/admin/sites/example/overview?from=2025-01-01")
test "$status" = 400
grep -Fq 'Invalid calendar or report state' "$fixture/invalid-calendar.html"
grep -Fq 'Reset to the site' "$fixture/invalid-calendar.html"
status=$(curl --silent --output "$fixture/invalid-highlight.html" \
    --write-out '%{http_code}' --cookie "$cookie" \
    "$dashboard/admin/sites/example/analyze?v=1&$dates&mode=trend&interval=hour&series=sessions&highlight=2025-01-03T00%3A00")
test "$status" = 400
grep -Fq 'Invalid report request' "$fixture/invalid-highlight.html"
status=$(curl --silent --output "$fixture/malformed-highlight.html" \
    --write-out '%{http_code}' --cookie "$cookie" \
    "$dashboard/admin/sites/example/analyze?v=1&$dates&mode=trend&interval=hour&series=sessions&highlight=2025-01-01T00%3A30")
test "$status" = 400
grep -Fq 'Invalid analysis request' "$fixture/malformed-highlight.html"
test "$(curl --silent --output /dev/null --write-out '%{redirect_url}' \
    --cookie "$cookie" \
    "$dashboard/admin?site=example&start=2025-01-01&end=2025-01-02&report=pages")" = \
    "$dashboard/admin/sites/example/analyze?v=1&from=2025-01-01&to=2025-01-02&compare=none&mode=breakdown&metric=page-views&dimension=page&interval=auto&sort=value-desc&page=1&limit=25"
test "$(curl --silent --output /dev/null --write-out '%{redirect_url}' \
    --cookie "$cookie" \
    "$dashboard/admin?site=example&start=2025-01-01&end=2025-01-02&report=goal&subject=Signup")" = \
    "$dashboard/admin/sites/example/journeys/goals?$dates&subject=Signup"
test "$(curl --silent --output /dev/null --write-out '%{redirect_url}' \
    --cookie "$cookie" \
    "$dashboard/admin?site=example&start=2025-01-01&end=2025-01-02&report=traffic-quality")" = \
    "$dashboard/admin/sites/example/live?$dates"
curl --silent --fail --cookie "$cookie" \
    --dump-header "$fixture/page.headers" --output /dev/null \
    "$overview"
grep -Fiq 'Content-Security-Policy:' "$fixture/page.headers"
html_gzip_bytes=$(gzip --stdout "$fixture/page-one.html" | wc -c)
css_path=$(grep -o 'href="/admin/[^"]*\.css"' \
    "$fixture/page-one.html" | head -1 | cut -d '"' -f 2)
curl --silent --fail --cookie "$cookie" \
    "$dashboard$css_path" >"$fixture/app.css"
css_gzip_bytes=$(gzip --stdout "$fixture/app.css" | wc -c)
test "$html_gzip_bytes" -le 32768
test "$css_gzip_bytes" -le 12288
currency_overflow="$dashboard/admin/sites/currency/analyze?v=1&from=$received_date&to=$received_end_date&compare=none&mode=trend&interval=day&series=revenue"
status=$(curl --silent --output "$fixture/currency-overflow.html" \
    --write-out '%{http_code}' --cookie "$cookie" "$currency_overflow")
test "$status" = 422
grep -Fq 'Too many visual series' "$fixture/currency-overflow.html"
maximum_trend="$dashboard/admin/sites/empty/analyze?v=1&from=2025-01-01&to=2026-02-04&compare=previous&mode=trend&interval=day&series=visitors&series=sessions&series=page-views"
curl --silent --fail --cookie "$cookie" "$maximum_trend" \
    >"$fixture/maximum-trend.html"
test "$(grep -o 'class="chart-figure trend-figure"' \
    "$fixture/maximum-trend.html" | wc -l)" = 3
maximum_trend_gzip_bytes=$(gzip --stdout "$fixture/maximum-trend.html" | wc -c)
test "$maximum_trend_gzip_bytes" -le 32768
rss_before=$(awk '$1 == "VmRSS:" { print $2 }' "/proc/$server_pid/status")
typed_small="$dashboard/admin/sites/example/analyze?v=1&from=2025-01-01&to=2025-01-02&compare=previous&mode=trend&interval=day&series=visitors&series=sessions&series=page-views"
for _ in {1..50}; do
    curl --silent --fail --cookie "$cookie" \
        "$overview" >/dev/null
    curl --silent --fail --cookie "$cookie" \
        "$typed_small" >/dev/null
done
rss_after=$(awk '$1 == "VmRSS:" { print $2 }' "/proc/$server_pid/status")
rss_growth_kib=$((rss_after - rss_before))
test "$rss_growth_kib" -le 8192

TMPDIR=/tmp NODE_PATH="$module_root" \
    PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
    ANALYTICO_CHROMIUM_PATH="$chromium_path" \
    node tests/e2e-m6-browser.cjs \
    "$dashboard" "$session_cookie" "$unsafe_goal_id" \
    >"$fixture/browser.json"

csrf=$(grep -Eo 'name="csrf" value="[A-Za-z0-9_-]{43}"' \
    "$fixture/page-one.html" | head -1 | cut -d '"' -f 4)
test "${#csrf}" = 43
status=$(curl --silent --output "$fixture/cross-origin.html" \
    --write-out '%{http_code}' --cookie "$cookie" \
    -X POST "$dashboard/admin/goals" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -H 'Origin: https://attacker.example' \
    --data-urlencode "csrf=$csrf" \
    --data-urlencode 'site=example' \
    --data-urlencode 'from=2025-01-01' \
    --data-urlencode 'to=2025-01-02' \
    --data-urlencode 'compare=none' \
    --data-urlencode 'name=Cross origin' \
    --data-urlencode 'entity=event' \
    --data-urlencode 'match=exact' \
    --data-urlencode 'value=cross-origin')
test "$status" = 403
grep -Fq 'modifying form did not come from this dashboard origin' \
    "$fixture/cross-origin.html"
curl --silent --fail --cookie "$cookie" \
    "$overview" >"$fixture/after-cross-origin.html"
if grep -Fq 'Cross origin' "$fixture/after-cross-origin.html"; then
    echo "cross-origin mutation was persisted" >&2
    exit 1
fi

kill -TERM "$server_pid"
wait "$server_pid"
server_pid=
"$binary" m3 million "$data" "$site_id" >/dev/null
start_server
trend_query='v=1&from=2025-01-01&to=2025-01-12&compare=none&mode=trend&interval=day&series=visitors&series=sessions&series=page-views'
trend_url="$dashboard/admin/sites/example/analyze?$trend_query"
trend_fresh_process_seconds=$(curl --silent --fail --cookie "$cookie" \
    --output "$fixture/trend-million-warm.html" \
    --write-out '%{time_total}' "$trend_url")
grep -Fq '<h2 id="analyze-trend-heading">Trend</h2>' \
    "$fixture/trend-million-warm.html"
test "$(grep -o 'class="chart-figure trend-figure"' \
    "$fixture/trend-million-warm.html" | wc -l)" = 3
trend_html_gzip_bytes=$(gzip --stdout "$fixture/trend-million-warm.html" | wc -c)
test "$trend_html_gzip_bytes" -le 32768
: >"$fixture/trend-million-seconds"
for _ in {1..10}; do
    read -r trend_status trend_seconds < <(curl --silent --output /dev/null \
        --write-out '%{http_code} %{time_total}\n' --cookie "$cookie" \
        "$trend_url")
    test "$trend_status" = 200
    awk -v elapsed="$trend_seconds" 'BEGIN { exit !(elapsed < 2.0) }'
    printf '%s\n' "$trend_seconds" >>"$fixture/trend-million-seconds"
done
trend_p95_seconds=$(sort -n "$fixture/trend-million-seconds" | sed -n '10p')
kill -TERM "$server_pid"
wait "$server_pid"
server_pid=
start_server --report-timeout-ms 1
status=$(curl --silent --output "$fixture/timeout.html" \
    --write-out '%{http_code}' --cookie "$cookie" \
    "$overview")
test "$status" = 503
grep -Fq 'Report timed out' "$fixture/timeout.html"
grep -Fq 'Narrow the selected date range and retry' "$fixture/timeout.html"
grep -Fq 'from=2025-01-01' "$fixture/timeout.html"
status=$(curl --silent --output "$fixture/trend-timeout.html" \
    --write-out '%{http_code}' --cookie "$cookie" "$trend_url")
test "$status" = 503
grep -Fq 'Analysis timed out' "$fixture/trend-timeout.html"
grep -Fq 'shared server deadline' "$fixture/trend-timeout.html"
grep -Fq 'series=visitors' "$fixture/trend-timeout.html"
breakdown_timeout_url="$dashboard/admin/sites/example/analyze?v=1&from=2025-01-01&to=2025-01-12&compare=none&mode=breakdown&metric=page-views&dimension=page&interval=auto&sort=value-desc&page=1&limit=25"
status=$(curl --silent --output "$fixture/breakdown-timeout.html" \
    --write-out '%{http_code}' --cookie "$cookie" "$breakdown_timeout_url")
test "$status" = 503
grep -Fq 'Report timed out' "$fixture/breakdown-timeout.html"
grep -Fq 'Breakdown result, conditional empty-site check, and property catalog exceeded their shared server deadline' \
    "$fixture/breakdown-timeout.html"
grep -Fq 'mode=breakdown' "$fixture/breakdown-timeout.html"
post_timeout_body=$(printf \
    '{"v":2,"site":"%s","event_id":"ffffffff-ffff-4fff-8fff-fffffffffff1","anonymous_id":"ffffffff-ffff-4fff-8fff-fffffffffff2","identity_quality":"persistent","session_id":"ffffffff-ffff-4fff-8fff-fffffffffff3","sequence":1,"occurred_at_ms":%s,"type":"event","name":"post_timeout"}' \
    "$site_id" "$(date -u +%s%3N)")
for _ in 1 2; do
    test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
        -X POST "$upstream/v2/event" -H 'Content-Type: text/plain' \
        -H 'Origin: https://example.com' \
        -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) Chrome/140.0' \
        --data-binary "$post_timeout_body")" = 204
done

cat "$fixture/browser.json"
printf '{"html_gzip_bytes":%s,"css_gzip_bytes":%s,' \
    "$html_gzip_bytes" "$css_gzip_bytes"
printf '"rss_growth_kib_after_100_views":%s,' "$rss_growth_kib"
printf '"trend_million_p95_seconds":%s,' "$trend_p95_seconds"
printf '"trend_million_fresh_process_seconds":%s,' \
    "$trend_fresh_process_seconds"
printf '"trend_million_html_gzip_bytes":%s,' "$trend_html_gzip_bytes"
printf '"maximum_trend_gzip_bytes":%s,' "$maximum_trend_gzip_bytes"
printf '"passkey_session":"enforced","csrf":"enforced",'\
'"timeout_page":"rendered",'\
'"post_interrupt_store":"accepted-and-idempotent"}\n'
echo "M6 server-rendered dashboard real-browser checks passed"
