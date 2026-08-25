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

fixture=$(mktemp -d "$PWD/.zig-cache/filters-e2e.XXXXXX")
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

server_port=${ANALYTICO_TEST_SERVER_PORT:-$((45000 + ($$ % 400)))}
proxy_port=${ANALYTICO_TEST_PROXY_PORT:-$((45400 + ($$ % 400)))}
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
"$binary" goal add "$data" alpha Signup event signup >/dev/null
"$binary" m3 seed "$data" "$alpha_id" >/dev/null
for index in $(seq 0 54); do
    path=$(printf '/value-%02d' "$index")
    micros=$((1735776000000000 + index * 1000000))
    "$binary" event add "$data" alpha pageview "$path" "$micros" \
        2025-01-02 "198.18.$index.1" Chrome Linux desktop >/dev/null
done
"$binary" event add "$data" beta pageview /beta-secret \
    1735776000000000 2025-01-02 203.0.113.10 Safari macOS desktop >/dev/null
"$binary" auth configure "$data" "$dashboard" >/dev/null
setup_url=$("$binary" auth bootstrap "$data" --ttl 10m | sed -n '2p')

"$binary" serve --listen "127.0.0.1:$server_port" \
    --meta "$data/meta.db" \
    --events "$data/events.duckdb" \
    --temp "$data/tmp" \
    --visitor-key-file "$data/visitor.key" \
    >"$fixture/server.stdout" 2>"$fixture/server.stderr" &
server_pid=$!
for _ in {1..100}; do
    curl --silent --fail "$upstream/readyz" >/dev/null 2>&1 && break
    sleep 0.02
done
curl --silent --fail "$upstream/readyz" >/dev/null

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

bad_origin_status=$(curl --silent --output "$fixture/bad-origin.html" \
    --write-out '%{http_code}' --cookie "$cookie" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -H 'Origin: https://attacker.example' \
    --data 'csrf=invalid' "$dashboard/admin/filters/apply")
test "$bad_origin_status" = 403

bad_csrf_status=$(curl --silent --output "$fixture/bad-csrf.html" \
    --write-out '%{http_code}' --cookie "$cookie" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -H "Origin: $dashboard" \
    --data 'csrf=invalid' "$dashboard/admin/filters/apply")
test "$bad_csrf_status" = 403

saved_state_paths=(
    /admin/filters/apply
    /admin/filters/suggest
    /admin/filters/remove
    /admin/segments
    /admin/segments/update
    /admin/segments/rename
    /admin/segments/duplicate
    /admin/segments/delete
    /admin/saved-views
    /admin/saved-views/duplicate
    /admin/saved-views/rename
    /admin/saved-views/delete
    /admin/funnels
    /admin/funnels/edit
)
head -c 65536 /dev/zero | tr '\0' x >"$fixture/body-64k"
for route in "${saved_state_paths[@]}"; do
    route_name=${route//\//-}
    body_64k_status=$(curl --silent \
        --output "$fixture/body-64k$route_name.html" \
        --write-out '%{http_code}' --cookie "$cookie" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -H "Origin: $dashboard" --data-binary @"$fixture/body-64k" \
        "$dashboard$route")
    test "$body_64k_status" = 400
    unauthenticated_64k_status=$(curl --silent \
        --output "$fixture/body-64k-unauthenticated$route_name.html" \
        --write-out '%{http_code}' \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -H "Origin: $dashboard" --data-binary @"$fixture/body-64k" \
        "$dashboard$route")
    test "$unauthenticated_64k_status" = 401
done
printf x >>"$fixture/body-64k"
for route in "${saved_state_paths[@]}"; do
    route_name=${route//\//-}
    body_64k_plus_status=$(curl --silent \
        --output "$fixture/body-64k-plus$route_name.html" \
        --write-out '%{http_code}' --cookie "$cookie" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -H "Origin: $dashboard" --data-binary @"$fixture/body-64k" \
        "$dashboard$route")
    test "$body_64k_plus_status" = 413
    unauthenticated_64k_plus_status=$(curl --silent \
        --output "$fixture/body-64k-plus-unauthenticated$route_name.html" \
        --write-out '%{http_code}' \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -H "Origin: $dashboard" --data-binary @"$fixture/body-64k" \
        "$dashboard$route")
    test "$unauthenticated_64k_plus_status" = 413
    missing_length_status=$(curl --silent \
        --output "$fixture/body-missing-length$route_name.html" \
        --write-out '%{http_code}' \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -H 'Content-Length:' -H 'Transfer-Encoding: chunked' \
        --data-binary @"$fixture/body-64k" "$dashboard$route")
    test "$missing_length_status" = 411
done

TMPDIR=/tmp NODE_PATH="$module_root" \
    PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
    ANALYTICO_CHROMIUM_PATH="$chromium_path" \
    node tests/e2e-filters-browser.cjs "$dashboard" "$session_cookie" \
    "$fixture/mobile.png" >"$fixture/browser.json"

cat "$fixture/browser.json"
printf '{"origin":"enforced","csrf":"enforced",'
printf '"saved_route_count":14,"saved_route_body_bytes":65536,'
printf '"saved_route_plus_one_status":413,'
printf '"unauthenticated_exact_status":401,'
printf '"unauthenticated_plus_one_status":413,'
printf '"missing_content_length_status":411}\n'
echo "Universal filters and saved state real-browser checks passed"
