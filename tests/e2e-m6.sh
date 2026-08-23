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
    if [[ -n "$caddy_pid" ]] && kill -0 "$caddy_pid" 2>/dev/null; then
        kill -TERM "$caddy_pid" 2>/dev/null || true
        wait "$caddy_pid" 2>/dev/null || true
    fi
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT

server_port=$((47000 + ($$ % 700)))
proxy_port=$((48000 + ($$ % 700)))
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
site_id=$("$binary" site list "$data" |
    awk -F '\t' '$1 == "example" { print $2 }')
broken_site_id=$("$binary" site list "$data" |
    awk -F '\t' '$1 == "broken" { print $2 }')
"$binary" goal add "$data" example Signup event signup >/dev/null
"$binary" goal add "$data" example \
    '<script>alert(1)</script> "&' event escaped >/dev/null
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
overview="$dashboard/admin/sites/example/overview?$dates"
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
    curl --silent --fail --cookie "$cookie" \
        "$dashboard/admin/sites/example/$path?$dates$extra" \
        >"$route_page"
    grep -Fq "<h1>$label</h1>" "$route_page"
    grep -Fq 'class="primary-navigation" aria-label="Primary"' "$route_page"
    grep -Fq "<span class=\"nav-label\">$label</span>" "$route_page"
done <<'ROUTES'
overview|Overview|
analyze|Analyze|&report=pages&sort=count&limit=25&page=1
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
[[ "$default_location" == "$dashboard/admin/sites/example/overview?from="* ]]
[[ "$default_location" == *'&to='*'&compare=previous' ]]
status=$(curl --silent --output "$fixture/invalid-calendar.html" \
    --write-out '%{http_code}' --cookie "$cookie" \
    "$dashboard/admin/sites/example/overview?from=2025-01-01")
test "$status" = 400
grep -Fq 'Invalid calendar or report state' "$fixture/invalid-calendar.html"
grep -Fq 'Reset to the site' "$fixture/invalid-calendar.html"
status=$(curl --silent --output "$fixture/invalid-highlight.html" \
    --write-out '%{http_code}' --cookie "$cookie" \
    "$dashboard/admin/sites/example/analyze?$dates&report=pages&sort=count&limit=25&page=1&focus=sessions&highlight=2025-01-03T00%3A00")
test "$status" = 400
grep -Fq 'Invalid report request' "$fixture/invalid-highlight.html"
status=$(curl --silent --output "$fixture/malformed-highlight.html" \
    --write-out '%{http_code}' --cookie "$cookie" \
    "$dashboard/admin/sites/example/analyze?$dates&report=pages&sort=count&limit=25&page=1&focus=sessions&highlight=2025-01-01T00%3A30")
test "$status" = 400
grep -Fq 'Invalid calendar or report state' "$fixture/malformed-highlight.html"
test "$(curl --silent --output /dev/null --write-out '%{redirect_url}' \
    --cookie "$cookie" \
    "$dashboard/admin?site=example&start=2025-01-01&end=2025-01-02&report=pages")" = \
    "$dashboard/admin/sites/example/analyze?$dates&report=pages&sort=count&limit=25&page=1"
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
rss_before=$(awk '$1 == "VmRSS:" { print $2 }' "/proc/$server_pid/status")
for _ in {1..100}; do
    curl --silent --fail --cookie "$cookie" \
        "$overview" >/dev/null
done
rss_after=$(awk '$1 == "VmRSS:" { print $2 }' "/proc/$server_pid/status")
rss_growth_kib=$((rss_after - rss_before))
test "$rss_growth_kib" -le 8192

TMPDIR=/tmp NODE_PATH="$module_root" \
    PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
    ANALYTICO_CHROMIUM_PATH="$chromium_path" \
    node tests/e2e-m6-browser.cjs "$dashboard" "$session_cookie" \
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
    --data-urlencode 'name=Cross origin' \
    --data-urlencode 'kind=event' \
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
start_server --report-timeout-ms 1
status=$(curl --silent --output "$fixture/timeout.html" \
    --write-out '%{http_code}' --cookie "$cookie" \
    "$overview")
test "$status" = 503
grep -Fq 'Report timed out' "$fixture/timeout.html"
grep -Fq 'Narrow the selected date range and retry' "$fixture/timeout.html"
grep -Fq 'from=2025-01-01' "$fixture/timeout.html"
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --cookie "$cookie" "$dashboard$css_path")" = 200

cat "$fixture/browser.json"
printf '{"html_gzip_bytes":%s,"css_gzip_bytes":%s,' \
    "$html_gzip_bytes" "$css_gzip_bytes"
printf '"rss_growth_kib_after_100_views":%s,' "$rss_growth_kib"
printf '"passkey_session":"enforced","csrf":"enforced","timeout_page":"rendered"}\n'
echo "M6 server-rendered dashboard real-browser checks passed"
