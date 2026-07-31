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
caddyfile=${ANALYTICO_CADDYFILE:-deploy/Caddyfile}
if [[ ! -d "$module_root/playwright" || ! -x "$chromium_path" ]]; then
    echo "browser fixture missing; run tests/setup-browser-e2e.sh" >&2
    exit 2
fi
command -v caddy >/dev/null
test -f "$caddyfile"

fixture=$(mktemp -d "$PWD/.zig-cache/m7-e2e.XXXXXX")
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

server_port=$((49000 + ($$ % 500)))
proxy_port=$((49500 + ($$ % 400)))
upstream="http://127.0.0.1:$server_port"
dashboard="http://localhost:$proxy_port"
data="$fixture/data"

"$binary" init "$data" >/dev/null
"$binary" site add "$data" example Example https://example.com >/dev/null
"$binary" site add "$data" second "Second Site" https://second.example >/dev/null
site_id=$("$binary" site list "$data" |
    awk -F '\t' '$1 == "example" { print $2 }')
"$binary" goal add "$data" example Signup event signup >/dev/null
"$binary" funnel add "$data" example Journey \
    path=/ path=/pricing event=signup >/dev/null
"$binary" m3 seed "$data" "$site_id" >/dev/null
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
TMPDIR="$fixture" NODE_PATH="$module_root" \
    PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
    ANALYTICO_CHROMIUM_PATH="$chromium_path" \
    node tests/e2e-passkey-session.cjs "$dashboard" "$setup_url" "$cookie_file"
session_cookie=$(<"$cookie_file")
cookie="analytico_session=$session_cookie"

page="$fixture/page.html"
curl --silent --fail --cookie "$cookie" \
    "$dashboard/admin?site=example&start=2025-01-01&end=2025-01-02&report=overview" \
    >"$page"
grep -Fq 'hx-boost:inherited="true"' "$page"
grep -Fq '/admin/htmx.28fae7bb.js' "$page"
grep -Fq '/admin/dashboard.5f88a716.js' "$page"
if grep -Eq 'https?://[^"]+htmx|cdn\\.' "$page"; then
    echo "dashboard referenced a remote HTMX asset" >&2
    exit 1
fi

curl --silent --fail --cookie "$cookie" \
    -H 'Accept-Encoding: identity' \
    "$dashboard/admin/htmx.28fae7bb.js" >"$fixture/htmx.js"
test "$(wc -c <"$fixture/htmx.js")" = 36282
test "$(sha256sum "$fixture/htmx.js" | awk '{ print $1 }')" = \
    28fae7bbe8e8142b702debb9d5234a9a436d9435a4b5165b195aa1a7ed840d25
curl --silent --fail --cookie "$cookie" \
    --dump-header "$fixture/htmx.headers" \
    -H 'Accept-Encoding: gzip' \
    "$dashboard/admin/htmx.28fae7bb.js" >"$fixture/htmx.js.gz"
grep -Fiq 'Content-Encoding: gzip' "$fixture/htmx.headers"
test "$(wc -c <"$fixture/htmx.js.gz")" = 13014
test "$(sha256sum "$fixture/htmx.js.gz" | awk '{ print $1 }')" = \
    74cc4013d2f7a7d072fdcc0f3ac61929ee4254798b0f6750adad6d34b137da1b
gzip --test "$fixture/htmx.js.gz"
gzip --decompress --stdout "$fixture/htmx.js.gz" >"$fixture/htmx.unpacked.js"
cmp "$fixture/htmx.js" "$fixture/htmx.unpacked.js"
test "$(wc -c <"$fixture/htmx.js.gz")" -le 16384
curl --silent --fail --cookie "$cookie" \
    "$dashboard/admin/dashboard.5f88a716.js" >"$fixture/dashboard.js"
test "$(wc -c <"$fixture/dashboard.js")" = 315
test "$(sha256sum "$fixture/dashboard.js" | awk '{ print $1 }')" = \
    5f88a716358d2672418fb55c4cc4f08389dfa1467304741787474b54e121cbde

TMPDIR="$fixture" NODE_PATH="$module_root" \
    PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
    ANALYTICO_CHROMIUM_PATH="$chromium_path" \
    node tests/e2e-m7-browser.cjs "$dashboard" "$session_cookie" normal \
    >"$fixture/browser-normal.json"

kill -TERM "$server_pid"
wait "$server_pid"
server_pid=
"$binary" m3 million "$data" "$site_id" >/dev/null
start_server --report-timeout-ms 1
TMPDIR="$fixture" NODE_PATH="$module_root" \
    PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
    ANALYTICO_CHROMIUM_PATH="$chromium_path" \
    node tests/e2e-m7-browser.cjs "$dashboard" "$session_cookie" timeout \
    >"$fixture/browser-timeout.json"

cat "$fixture/browser-normal.json"
cat "$fixture/browser-timeout.json"
printf '{"htmx_raw_bytes":36282,"htmx_gzip_bytes":13014,'
printf '"startup_requests":4,"startup_api_requests":0}\n'
echo "M7 HTMX 4 progressive-enhancement browser checks passed"
