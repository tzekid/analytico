#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <analytico-binary> <cloudio-root>" >&2
    exit 2
fi

absolute_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) realpath "$1" ;;
    esac
}

binary=$(absolute_path "$1")
cloudio_root=$(absolute_path "$2")
module_root=${ANALYTICO_PLAYWRIGHT_NODE_PATH:-"$PWD/.zig-cache/playwright-node/node_modules"}
browser_root=${PLAYWRIGHT_BROWSERS_PATH:-"$PWD/.zig-cache/ms-playwright"}
chromium_path=${ANALYTICO_CHROMIUM_PATH:-"$browser_root/chromium-1234/chrome-linux64/chrome"}
dashboard_caddyfile=${ANALYTICO_DASHBOARD_CADDYFILE:-deploy/Caddyfile.dashboard}

test -x "$binary"
test -f "$cloudio_root/web/index.html"
test -f "$dashboard_caddyfile"
if [[ ! -d "$module_root/playwright" || ! -x "$chromium_path" ]]; then
    echo "browser fixture missing; run tests/setup-browser-e2e.sh" >&2
    exit 2
fi
command -v caddy >/dev/null

fixture=$(mktemp -d "$PWD/.zig-cache/m8-e2e.XXXXXX")
cloudio_source="$fixture/cloudio-source"
cloudio_revision=$(<integrations/cloudio/REVISION)
cloudio_patch=$(absolute_path integrations/cloudio/standalone-link.patch)
analytico_pid=
cloudio_pid=
caddy_pid=
cleanup() {
    for pid in "$cloudio_pid" "$caddy_pid" "$analytico_pid"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    rm -rf -- "$fixture"
}
trap cleanup EXIT

git -C "$cloudio_root" cat-file -e "$cloudio_revision^{commit}"
mkdir -p "$cloudio_source"
git -C "$cloudio_root" archive "$cloudio_revision" | tar -x -C "$cloudio_source"
git -C "$cloudio_source" init -q
git -C "$cloudio_source" apply --unidiff-zero --check "$cloudio_patch"
git -C "$cloudio_source" apply --unidiff-zero "$cloudio_patch"
(
    cd "$cloudio_source"
    zig build -Doptimize=ReleaseSafe --system zig-pkg
)
cloudio_root=$cloudio_source
cloudio_binary="$cloudio_source/zig-out/bin/cloudio"
test -x "$cloudio_binary"
echo "M8: isolated Cloudio candidate built" >&2

analytico_port=$((49100 + ($$ % 200)))
dashboard_port=$((49300 + ($$ % 200)))
cloudio_port=$((49500 + ($$ % 200)))
analytico_upstream="http://127.0.0.1:$analytico_port"
dashboard_origin="http://127.0.0.1:$dashboard_port"
cloudio_origin="http://localhost:$cloudio_port"
dashboard_username='admin'
dashboard_password=m8-fixture-password
data="$fixture/analytico"
cloudio_db="$fixture/cloudio/cloudio.db"
cloudio_config="$fixture/cloudio.toml"
storage_state="$fixture/cloudio-state.json"

"$binary" init "$data" >/dev/null
"$binary" site add "$data" example Example https://example.com >/dev/null
site_id=$("$binary" site list "$data" |
    awk -F '\t' '$1 == "example" { print $2 }')
"$binary" m3 seed "$data" "$site_id" >/dev/null

start_analytico() {
    "$binary" serve --listen "127.0.0.1:$analytico_port" \
        --meta "$data/meta.db" \
        --events "$data/events.duckdb" \
        --temp "$data/tmp" \
        --visitor-key-file "$data/visitor.key" \
        >"$fixture/analytico.stdout" 2>"$fixture/analytico.stderr" &
    analytico_pid=$!
    for _ in {1..100}; do
        curl --silent --fail "$analytico_upstream/readyz" >/dev/null 2>&1 &&
            return
        sleep 0.02
    done
    echo "Analytico did not become ready" >&2
    exit 1
}

write_cloudio_config() {
    local include_analytico=$1
    {
        printf 'db_path = "%s"\n' "$cloudio_db"
        printf '[platform]\nrefresh_seconds = 86400\n'
        printf '[auth]\norigin = "%s"\nrp_id = "localhost"\n' "$cloudio_origin"
        if [[ "$include_analytico" == yes ]]; then
            printf '[integrations]\nanalytico_url = "%s/admin?site=example&start=2025-01-01&end=2025-01-02&report=overview"\n' \
                "$dashboard_origin"
        fi
    } >"$cloudio_config"
}

start_cloudio() {
    (
        cd "$cloudio_root"
        CLOUDIO_CONFIG="$cloudio_config" \
            "$cloudio_binary" serve --host 127.0.0.1 --port "$cloudio_port"
    ) >"$fixture/cloudio.stdout" 2>"$fixture/cloudio.stderr" &
    cloudio_pid=$!
    for _ in {1..100}; do
        status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
            "$cloudio_origin/login.html" || true)
        [[ "$status" == 200 ]] && return
        sleep 0.02
    done
    echo "Cloudio did not become ready" >&2
    exit 1
}

run_browser() {
    local mode=$1
    local extra=${2:-}
    TMPDIR="$fixture" \
        NODE_PATH="$module_root" \
        PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
        ANALYTICO_CHROMIUM_PATH="$chromium_path" \
        node tests/e2e-m8-cloudio-browser.cjs \
        "$mode" "$cloudio_origin" "$dashboard_origin" \
        "$dashboard_username" "$dashboard_password" "$storage_state" \
        ${extra:+"$extra"}
}

start_analytico
admin_hash=$(caddy hash-password --plaintext "$dashboard_password")
{
    printf '{\n\tadmin off\n}\n'
    sed \
        -e "s|^analytics-admin\\.example {|http://127.0.0.1:$dashboard_port {|" \
        -e "s|127\\.0\\.0\\.1:4318|127.0.0.1:$analytico_port|" \
        "$dashboard_caddyfile"
} >"$fixture/Caddyfile"
ANALYTICO_ADMIN_HASH=$admin_hash caddy validate \
    --config "$fixture/Caddyfile" >"$fixture/caddy.validate" 2>&1
ANALYTICO_ADMIN_HASH=$admin_hash \
    XDG_DATA_HOME="$fixture/caddy-data" \
    XDG_CONFIG_HOME="$fixture/caddy-config" \
    caddy run --config "$fixture/Caddyfile" \
    >"$fixture/caddy.stdout" 2>"$fixture/caddy.stderr" &
caddy_pid=$!
for _ in {1..100}; do
    status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
        "$dashboard_origin/admin" || true)
    [[ "$status" == 401 ]] && break
    sleep 0.02
done
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "$dashboard_origin/admin")" = 401
echo "M8: standalone Analytico auth boundary ready" >&2

write_cloudio_config yes
mkdir -p "$fixture/cloudio"
(
    cd "$cloudio_root"
    CLOUDIO_CONFIG="$cloudio_config" "$cloudio_binary" init >/dev/null
)
bootstrap_output=$(
    cd "$cloudio_root"
    CLOUDIO_CONFIG="$cloudio_config" "$cloudio_binary" auth bootstrap --ttl 10m
)
setup_url=$(printf '%s\n' "$bootstrap_output" |
    awk '/^http:\/\// { print; exit }')
test -n "$setup_url"
start_cloudio

test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "$cloudio_origin/")" = 302
run_browser setup "$setup_url" >/dev/null
echo "M8: disposable Cloudio passkey enrolled" >&2
connected_result=$(run_browser connected)
echo "M8: no-JavaScript cross-application navigation passed" >&2

analytico_open_files=$(find "/proc/$analytico_pid/fd" -maxdepth 1 -type l \
    -exec readlink {} + 2>/dev/null || true)
cloudio_open_files=$(find "/proc/$cloudio_pid/fd" -maxdepth 1 -type l \
    -exec readlink {} + 2>/dev/null || true)
printf '%s\n' "$analytico_open_files" | grep -Fq "$data/events.duckdb"
if printf '%s\n' "$cloudio_open_files" | grep -Fq "$data/events.duckdb"; then
    echo "Cloudio unexpectedly opened Analytico's writable DuckDB file" >&2
    exit 1
fi

kill -TERM "$analytico_pid"
wait "$analytico_pid"
analytico_pid=
for _ in {1..100}; do
    status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
        --user "$dashboard_username:$dashboard_password" \
        "$dashboard_origin/admin" || true)
    [[ "$status" == 502 ]] && break
    sleep 0.02
done
test "$status" = 502
outage_result=$(run_browser cloudio-only)
echo "M8: Cloudio complete response survived Analytico outage" >&2

start_analytico
kill -TERM "$cloudio_pid"
wait "$cloudio_pid" || [[ $? -eq 143 ]]
cloudio_pid=
write_cloudio_config no
start_cloudio
rollback_result=$(run_browser rollback)
echo "M8: standalone rollback passed" >&2

printf '%s\n%s\n%s\n' \
    "$connected_result" "$outage_result" "$rollback_result"
echo "M8 Cloudio standalone-link integration and rollback checks passed"
