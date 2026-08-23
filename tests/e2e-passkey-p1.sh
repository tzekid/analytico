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

fixture=$(mktemp -d "$PWD/.zig-cache/passkey-p1.XXXXXX")
server_pid=
cleanup() {
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT

port=$((49000 + ($$ % 500)))
origin="http://localhost:$port"
data="$fixture/data"
"$binary" init "$data" >"$fixture/init.txt"
grep -Fq 'metadata=v6' "$fixture/init.txt"
"$binary" site add "$data" example Example https://example.com \
    --timezone UTC >/dev/null

legacy="$fixture/legacy-v1"
"$binary" init "$legacy" >/dev/null
"$binary" site add "$legacy" preserved Preserved https://preserved.example \
    --timezone UTC >/dev/null
sqlite3 "$legacy/meta.db" <<'SQL'
DROP TABLE site_timezones;
DROP TABLE auth_bootstrap;
DROP TABLE auth_sessions;
DROP TABLE auth_challenges;
DROP TABLE auth_credentials;
DROP TABLE auth_users;
DROP TABLE auth_config;
DELETE FROM meta_migrations WHERE version >= 2;
SQL
legacy_backup="$fixture/legacy-backup"
"$binary" backup "$legacy" "$legacy_backup" >/dev/null
"$binary" migrate "$legacy" "$legacy_backup" >"$fixture/upgrade.txt"
grep -Fq 'metadata=v6 events=v7' "$fixture/upgrade.txt"
"$binary" site timezone-set "$legacy" preserved UTC >/dev/null
"$binary" site list "$legacy" | grep -Fq $'preserved\t'

site_id=$("$binary" site list "$data" | awk -F '\t' '$1 == "example" { print $2 }')
"$binary" serve --listen "127.0.0.1:$port" \
    --meta "$data/meta.db" \
    --events "$data/events.duckdb" \
    --temp "$data/tmp" \
    --visitor-key-file "$data/visitor.key" \
    >"$fixture/unconfigured.stdout" 2>"$fixture/unconfigured.stderr" &
server_pid=$!
for _ in {1..100}; do
    curl --silent --fail "$origin/readyz" >/dev/null 2>&1 && break
    sleep 0.02
done
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "$origin/admin")" = 503
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "$origin/admin/login")" = 503
pageview=$(printf '{"v":1,"site":"%s","type":"pageview","path":"/auth-boundary"}' "$site_id")
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    -X POST "$origin/v1/event" \
    -H 'Content-Type: text/plain;charset=UTF-8' \
    -H 'Origin: https://example.com' \
    -H 'X-Forwarded-For: 203.0.113.42' \
    --data-binary "$pageview")" = 204
kill -TERM "$server_pid"
wait "$server_pid"
server_pid=

"$binary" auth configure "$data" "$origin" >"$fixture/configure.txt"
setup_url=$("$binary" auth bootstrap "$data" --ttl 10m | sed -n '2p')
case "$setup_url" in
    "$origin/admin/setup#token="*) ;;
    *) echo "invalid setup URL" >&2; exit 1 ;;
esac

"$binary" serve --listen "127.0.0.1:$port" \
    --meta "$data/meta.db" \
    --events "$data/events.duckdb" \
    --temp "$data/tmp" \
    --visitor-key-file "$data/visitor.key" \
    >"$fixture/server.stdout" 2>"$fixture/server.stderr" &
server_pid=$!
for _ in {1..100}; do
    curl --silent --fail "$origin/readyz" >/dev/null 2>&1 && break
    sleep 0.02
done
curl --silent --fail "$origin/readyz" >/dev/null
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    -H 'HX-Request: true' "$origin/admin")" = 401
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    -H 'Cookie: analytico_session=invalid-session-token-that-is-long-enough' \
    "$origin/admin/private-unknown")" = 303

TMPDIR=/tmp NODE_PATH="$module_root" \
    PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
    ANALYTICO_CHROMIUM_PATH="$chromium_path" \
    node tests/e2e-passkey-p1-browser.cjs "$origin" "$setup_url" \
    >"$fixture/browser.json"

rate_limited=no
for _ in {1..30}; do
    status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
        -X POST "$origin/admin/auth/login/options" \
        -H 'Content-Type: application/json' --data '{}')
    if [[ "$status" == 429 ]]; then
        rate_limited=yes
        break
    fi
done
test "$rate_limited" = yes

kill -TERM "$server_pid"
wait "$server_pid"
server_pid=
"$binary" auth status "$data" >"$fixture/status.txt"
grep -Fq 'configured=yes credentials=1 active_sessions=1 bootstrap_active=no' \
    "$fixture/status.txt"
if rg -a -F "${setup_url#*#token=}" "$data/meta.db" >/dev/null 2>&1; then
    echo "raw bootstrap token found in metadata" >&2
    exit 1
fi
backup="$fixture/before-auth-reset"
"$binary" auth reset "$data" "$backup" --confirm >"$fixture/reset.txt"
grep -Fq "verified_backup=$backup" "$fixture/reset.txt"
"$binary" restore "$backup" "$fixture/restored" --verify >/dev/null
"$binary" doctor "$fixture/restored" >/dev/null
"$binary" auth status "$data" >"$fixture/reset-status.txt"
grep -Fq 'configured=no credentials=0 active_sessions=0 bootstrap_active=no' \
    "$fixture/reset-status.txt"
grep -Fq "origin=$origin" "$fixture/reset-status.txt"

wrong_port=$((port + 1))
wrong_origin="http://localhost:$((wrong_port + 1))"
actual_origin="http://localhost:$wrong_port"
wrong_data="$fixture/wrong-origin"
"$binary" init "$wrong_data" >/dev/null
"$binary" auth configure "$wrong_data" "$wrong_origin" >/dev/null
wrong_setup_url=$("$binary" auth bootstrap "$wrong_data" --ttl 10m | sed -n '2p')
wrong_token=${wrong_setup_url#*#token=}
"$binary" serve --listen "127.0.0.1:$wrong_port" \
    --meta "$wrong_data/meta.db" \
    --events "$wrong_data/events.duckdb" \
    --temp "$wrong_data/tmp" \
    --visitor-key-file "$wrong_data/visitor.key" \
    >"$fixture/wrong-server.stdout" 2>"$fixture/wrong-server.stderr" &
server_pid=$!
for _ in {1..100}; do
    curl --silent --fail "$actual_origin/readyz" >/dev/null 2>&1 && break
    sleep 0.02
done
curl --silent --fail "$actual_origin/readyz" >/dev/null

test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    -X POST "$actual_origin/admin/auth/setup/options" \
    -H 'Content-Type: application/json' \
    -H 'X-Analytico-Bootstrap: invalid-bootstrap-value-that-is-long-enough' \
    --data '{}')" = 401
test "$(head -c 200000 /dev/zero | tr '\0' x | curl --silent \
    --output /dev/null --write-out '%{http_code}' \
    -X POST "$actual_origin/admin/auth/setup/options" \
    -H 'Content-Type: application/json' \
    -H "X-Analytico-Bootstrap: $wrong_token" \
    --data-binary @-)" = 413

wrong_access_url="$actual_origin/admin/setup#token=$wrong_token"
TMPDIR=/tmp NODE_PATH="$module_root" \
    PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
    ANALYTICO_CHROMIUM_PATH="$chromium_path" \
    node tests/e2e-passkey-p1-browser.cjs \
    "$actual_origin" "$wrong_access_url" reject-origin \
    >"$fixture/wrong-browser.json"
kill -TERM "$server_pid"
wait "$server_pid"
server_pid=
"$binary" auth status "$wrong_data" >"$fixture/wrong-status.txt"
grep -Fq 'configured=no credentials=0 active_sessions=0 bootstrap_active=yes' \
    "$fixture/wrong-status.txt"

cat "$fixture/browser.json"
cat "$fixture/wrong-browser.json"
echo "Passkey P1-P3 on-disk, HTTP, and real-browser checks passed"
