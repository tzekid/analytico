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
if [[ ! -d "$module_root/playwright" || ! -x "$chromium_path" ]]; then
    echo "browser fixture missing; run tests/setup-browser-e2e.sh" >&2
    exit 2
fi
command -v caddy >/dev/null
command -v curl >/dev/null
command -v jq >/dev/null

fixture=$(mktemp -d "$PWD/.zig-cache/installation.XXXXXX")
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

pick_port() {
    local candidate
    for _ in {1..100}; do
        candidate=$((40000 + RANDOM % 20000))
        if ! ss -H -ltn "sport = :$candidate" | grep -q .; then
            printf '%s\n' "$candidate"
            return
        fi
    done
    return 1
}

server_port=$(pick_port)
proxy_port=$(pick_port)
fixture_port=$(pick_port)
while [[ "$proxy_port" == "$server_port" || "$fixture_port" == "$server_port" ||
    "$fixture_port" == "$proxy_port" ]]; do
    fixture_port=$(pick_port)
done
upstream="http://127.0.0.1:$server_port"
dashboard="http://localhost:$proxy_port"
tracked_origin="http://127.0.0.2:$fixture_port"
data="$fixture/data"

wait_ready() {
    for _ in {1..250}; do
        curl --silent --fail "$upstream/readyz" >/dev/null 2>&1 && return
        sleep 0.02
    done
    echo "installation server did not become ready" >&2
    exit 1
}

start_server() {
    local suffix=$1
    "$binary" serve --listen "127.0.0.1:$server_port" \
        --meta "$data/meta.db" \
        --events "$data/events.duckdb" \
        --temp "$data/tmp" \
        --visitor-key-file "$data/visitor.key" \
        >"$fixture/server-$suffix.stdout" 2>"$fixture/server-$suffix.stderr" &
    server_pid=$!
    wait_ready
}

stop_server() {
    kill -TERM "$server_pid"
    wait "$server_pid"
    server_pid=
}

"$binary" init "$data" >/dev/null
"$binary" site add "$data" install-fixture "Install Fixture" "$tracked_origin" \
    --timezone UTC >/dev/null
site=$(
    "$binary" site list "$data" |
        awk -F '\t' '$1 == "install-fixture" { print $2 }'
)
test "${#site}" = 36
"$binary" auth configure "$data" "$dashboard" >/dev/null
setup_url=$("$binary" auth bootstrap "$data" --ttl 10m | sed -n '2p')

start_server initial
{
    printf '{\n\tadmin off\n}\n'
    sed \
        -e "s|^analytics\\.example {|http://localhost:$proxy_port {|" \
        -e "s|127\\.0\\.0\\.1:4318|127.0.0.1:$server_port|" \
        deploy/Caddyfile
} >"$fixture/Caddyfile"
caddy validate --config "$fixture/Caddyfile" >"$fixture/caddy.validate" 2>&1
XDG_DATA_HOME="$fixture/caddy-data" \
    XDG_CONFIG_HOME="$fixture/caddy-config" \
    caddy run --config "$fixture/Caddyfile" \
    >"$fixture/caddy.stdout" 2>"$fixture/caddy.stderr" &
caddy_pid=$!
for _ in {1..250}; do
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
    node tests/e2e-passkey-session.cjs \
    "$dashboard" "$setup_url" "$cookie_file"
session_token=$(<"$cookie_file")
cookie="analytico_session=$session_token"

old_occurred_ms=$(date +%s%3N)
old_event=$(printf \
    '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000002010","anonymous_id":"00000000-0000-4000-8000-000000002001","identity_quality":"persistent","session_id":"00000000-0000-4000-8000-000000002002","sequence":0,"occurred_at_ms":%s,"type":"pageview","page":{"path":"/old-event","hostname":"127.0.0.2"}}' \
    "$site" "$old_occurred_ms")
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    -X POST "$dashboard/v2/event" \
    -H 'Content-Type: text/plain;charset=UTF-8' \
    -H "Origin: $tracked_origin" \
    -H 'User-Agent: Mozilla/5.0 Chrome/151.0.0.0 Safari/537.36' \
    --data-binary "$old_event")" = 204

desktop_screenshot="$fixture/install-desktop.png"
mobile_screenshot="$fixture/install-mobile.png"
signed_path_file="$fixture/signed-install-path"
TMPDIR=/tmp NODE_PATH="$module_root" \
    PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
    ANALYTICO_CHROMIUM_PATH="$chromium_path" \
    ANALYTICO_INSTALL_DESKTOP_SCREENSHOT="$desktop_screenshot" \
    ANALYTICO_INSTALL_MOBILE_SCREENSHOT="$mobile_screenshot" \
    ANALYTICO_INSTALL_SIGNED_PATH_FILE="$signed_path_file" \
    node tests/e2e-installation-browser.cjs \
    "$dashboard" "$session_token" "$site" "$fixture_port" "$old_occurred_ms" \
    >"$fixture/browser.json"
test -s "$desktop_screenshot"
test -s "$mobile_screenshot"
test -s "$signed_path_file"
jq -e '
    .engine == "chromium" and .old_event_rejected_as_new and
    .tampered_query_status == 400 and .native_refresh and
    .v1_compatibility and .v2_tracker_page and
    .startup_data_requests == 0 and .mobile_width == 360 and
    .html_gzip_bytes <= 32768 and .install_js_raw_bytes == 3891 and
    .install_js_gzip_bytes <= 2048 and
    (.clipboard == ["write", "manual-selection"]) and
    (.polling == ["five-seconds", "pause", "hidden", "resume", "stop-success"])
' "$fixture/browser.json" >/dev/null

stop_server
start_server restarted
curl --silent --fail --cookie "$cookie" \
    "$dashboard$(<"$signed_path_file")" >"$fixture/restarted-success.html"
grep -Fq 'Tracker verified.' "$fixture/restarted-success.html"
grep -Fq '/first-event' "$fixture/restarted-success.html"
stop_server
before_million=$(
    "$binary" doctor "$data" |
        sed -n 's/.*stored_events=\([0-9][0-9]*\).*/\1/p'
)
test "$before_million" -ge 3
"$binary" m3 million "$data" "$site" >/dev/null
start_server million

headers="$fixture/install.headers"
curl --silent --output /dev/null --dump-header "$headers" \
    --cookie "$cookie" "$dashboard/admin/sites/install-fixture/install"
location=$(awk 'BEGIN { IGNORECASE=1 } /^Location:/ { sub(/\r$/, "", $2); print $2 }' "$headers")
case "$location" in
    /admin/sites/install-fixture/install\?started=*\&count=*\&after=*\&event=*\&sig=*) ;;
    *) echo "invalid installation redirect: $location" >&2; exit 1 ;;
esac
page_url="$dashboard$location"
fragment_url="$page_url&fragment=verification"
curl --silent --fail --cookie "$cookie" --dump-header "$fixture/page.headers" \
    "$page_url" >"$fixture/page.html"
grep -Fiq 'Referrer-Policy: no-referrer' "$fixture/page.headers"
grep -Fq 'Waiting for a new committed event' "$fixture/page.html"
for _ in {1..10}; do
    curl --silent --fail --cookie "$cookie" "$fragment_url" >/dev/null
done
: >"$fixture/fragment.samples"
for _ in {1..30}; do
    curl --silent --fail --cookie "$cookie" \
        --output "$fixture/fragment.html" --write-out '%{time_total}\n' \
        "$fragment_url" >>"$fixture/fragment.samples"
done
grep -Fq 'Waiting for a new committed event' "$fixture/fragment.html"
p95=$(
    sort -n "$fixture/fragment.samples" |
        awk '{ sample[NR] = $1 } END { idx = int((NR * 95 + 99) / 100); print sample[idx] }'
)
printf 'installation fragment p95 seconds=%s\n' "$p95" >&2
awk -v value="$p95" 'BEGIN { exit !(value < 0.150) }'

scale_occurred_ms=$(date +%s%3N)
scale_event=$(printf \
    '{"v":2,"site":"%s","event_id":"ffffffff-ffff-4fff-8fff-fffffffff020","anonymous_id":"ffffffff-ffff-4fff-8fff-fffffffff021","identity_quality":"persistent","session_id":"ffffffff-ffff-4fff-8fff-fffffffff022","sequence":0,"occurred_at_ms":%s,"type":"pageview","page":{"path":"/million-success","hostname":"127.0.0.2"}}' \
    "$site" "$scale_occurred_ms")
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    -X POST "$dashboard/v2/event" \
    -H 'Content-Type: text/plain;charset=UTF-8' \
    -H "Origin: $tracked_origin" \
    -H 'User-Agent: Mozilla/5.0 Chrome/151.0.0.0 Safari/537.36' \
    --data-binary "$scale_event")" = 204
scale_success_seconds=$(curl --silent --fail --cookie "$cookie" \
    --output "$fixture/scale-success.html" --write-out '%{time_total}' \
    "$fragment_url")
grep -Fq 'Tracker verified.' "$fixture/scale-success.html"
grep -Fq '/million-success' "$fixture/scale-success.html"
printf 'installation million-row success seconds=%s\n' \
    "$scale_success_seconds" >&2
awk -v value="$scale_success_seconds" 'BEGIN { exit !(value < 0.150) }'

rss_before=$(awk '$1 == "VmRSS:" { print $2 }' "/proc/$server_pid/status")
for _ in {1..100}; do
    curl --silent --fail --cookie "$cookie" "$page_url" >/dev/null
done
rss_after=$(awk '$1 == "VmRSS:" { print $2 }' "/proc/$server_pid/status")
rss_growth_kib=$((rss_after - rss_before))
printf 'installation 100-view RSS growth KiB=%s\n' "$rss_growth_kib" >&2
test "$rss_growth_kib" -le 8192

curl --silent --fail --cookie "$cookie" \
    "$dashboard/admin/install.fe0cc47b.js" >"$fixture/install.js"
test "$(wc -c <"$fixture/install.js")" = 3891
test "$(sha256sum "$fixture/install.js" | awk '{ print $1 }')" = \
    fe0cc47ba8d4a162047879064eb2cdeef4bbf122baf24ced3077f3579add42f9
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "$dashboard/admin/install.fe0cc47b.js")" = 303

stop_server
test "$($binary doctor "$data")" = \
    "ok metadata=v7 events=v7 sites=1 goals=0 funnels=0 stored_events=1000001 key=ok"

printf 'installation_e2e=pass events=1000001 restart_persistence=true fragment_p95_seconds=%s scale_success_seconds=%s rss_growth_kib=%s desktop_png_bytes=%s mobile_png_bytes=%s browser=%s\n' \
    "$p95" "$scale_success_seconds" "$rss_growth_kib" "$(wc -c <"$desktop_screenshot")" \
    "$(wc -c <"$mobile_screenshot")" "$(<"$fixture/browser.json")"
