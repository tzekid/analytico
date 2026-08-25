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
command -v jq >/dev/null
command -v sqlite3 >/dev/null

fixture=$(mktemp -d "$PWD/.zig-cache/onboarding.XXXXXX")
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
while [[ "$proxy_port" == "$server_port" ]]; do proxy_port=$(pick_port); done
upstream="http://127.0.0.1:$server_port"
dashboard="http://localhost:$proxy_port"
data="$fixture/data"

"$binary" init "$data" >"$fixture/init.txt"
grep -Fq 'metadata=v9 events=v7' "$fixture/init.txt"
"$binary" auth configure "$data" "$dashboard" >/dev/null
setup_url=$("$binary" auth bootstrap "$data" --ttl 10m | sed -n '2p')
case "$setup_url" in
    "$dashboard/admin/setup#token="*) ;;
    *) echo "invalid setup URL" >&2; exit 1 ;;
esac

"$binary" serve --listen "127.0.0.1:$server_port" \
    --meta "$data/meta.db" \
    --events "$data/events.duckdb" \
    --temp "$data/tmp" \
    --visitor-key-file "$data/visitor.key" \
    >"$fixture/server.stdout" 2>"$fixture/server.stderr" &
server_pid=$!
for _ in {1..250}; do
    curl --silent --fail "$upstream/readyz" >/dev/null 2>&1 && break
    sleep 0.02
done
curl --silent --fail "$upstream/readyz" >/dev/null

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

cold_rss_before=$(awk '$1 == "VmRSS:" { print $2 }' "/proc/$server_pid/status")
TMPDIR=/tmp NODE_PATH="$module_root" \
    PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
    ANALYTICO_CHROMIUM_PATH="$chromium_path" \
    node tests/e2e-onboarding-browser.cjs \
    "$dashboard" "$setup_url" "$server_pid" "$data/events.duckdb" \
    >"$fixture/browser.json"
cold_rss_after=$(awk '$1 == "VmRSS:" { print $2 }' "/proc/$server_pid/status")
cold_onboarding_rss_growth_kib=$((cold_rss_after - cold_rss_before))

jq -e '
    .engine == "chromium" and
    .passkey_bootstrap == "real-virtual-authenticator" and
    .site_creation_javascript == "disabled" and
    .metadata_schema == 9 and .event_schema == 7 and
    .exact_retry == "existing-outcome" and
    .unavailable_store_honest and
    .startup_data_requests == 0 and .mobile_width == 360 and
    .html_gzip_bytes <= 32768 and .css_gzip_bytes <= 12288 and
    .warm_100_view_rss_growth_kib <= 8192
' "$fixture/browser.json" >/dev/null

site_id=$(jq -r .site_id "$fixture/browser.json")
test "${#site_id}" = 36

occurred_ms=$(date +%s%3N)
event='{"v":2,"site":"'"$site_id"'","event_id":"00000000-0000-4000-8000-000000000019","anonymous_id":"00000000-0000-4000-8000-000000000119","identity_quality":"persistent","session_id":"00000000-0000-4000-8000-000000000219","sequence":0,"occurred_at_ms":'"$occurred_ms"',"type":"pageview","page":{"path":"/onboarding","title":"Onboarding","hostname":"browser.example"}}'
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    -X POST "$dashboard/v2/event" \
    -H 'Content-Type: text/plain;charset=UTF-8' \
    -H 'Origin: https://browser.example' \
    -H 'User-Agent: Mozilla/5.0 Chrome/140.0.0.0 Safari/537.36' \
    --data-binary "$event")" = 204

kill -TERM "$caddy_pid"
wait "$caddy_pid"
caddy_pid=
kill -TERM "$server_pid"
wait "$server_pid"
server_pid=

site_list=$("$binary" site list "$data")
test "$(printf '%s\n' "$site_list" | wc -l)" = 1
printf '%s\n' "$site_list" |
    awk -F '\t' -v id="$site_id" \
        '$1 == "browser-site" && $2 == id && $4 == "Browser Site" { found = 1 } END { exit !found }'
doctor=$("$binary" doctor "$data")
test "$doctor" = \
    "ok metadata=v9 events=v7 sites=1 goals=0 funnels=0 stored_events=1 key=ok"

test "$(sqlite3 "$data/meta.db" \
    "SELECT default_currency FROM site_settings WHERE site_id='$site_id';")" = EUR
test "$(sqlite3 "$data/meta.db" \
    "SELECT count(*) FROM site_origins WHERE site_id='$site_id' AND origin='https://browser.example';")" = 1
sqlite3 "$data/meta.db" \
    "SELECT name FROM sqlite_master WHERE type='index' AND name='site_origins_unique_origin';" |
    grep -Fxq site_origins_unique_origin

printf 'onboarding_e2e=pass metadata=9 events=7 sites=1 events_stored=1 cold_onboarding_rss_growth_kib=%s browser=%s\n' \
    "$cold_onboarding_rss_growth_kib" "$(<"$fixture/browser.json")"
