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

mkdir -p .zig-cache
fixture_dir=$(mktemp -d "$PWD/.zig-cache/m2-e2e.XXXXXX")
server_pid=
port=$((39000 + ($$ % 1000)))
base="http://127.0.0.1:$port"
cleanup() {
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf -- "$fixture_dir"
}
trap cleanup EXIT

request() {
    response_code=$(curl --silent --show-error \
        --output "$fixture_dir/body" \
        --dump-header "$fixture_dir/headers" \
        --write-out '%{http_code}' "$@")
}

expect_code() {
    local expected=$1
    shift
    request "$@"
    if [[ "$response_code" != "$expected" ]]; then
        echo "expected HTTP $expected, got $response_code for: $*" >&2
        cat "$fixture_dir/headers" >&2
        cat "$fixture_dir/body" >&2
        exit 1
    fi
}

"$binary" init "$fixture_dir" >/dev/null
"$binary" site add "$fixture_dir" example "Example Site" \
    "https://example.com" >/dev/null
"$binary" site property-add "$fixture_dir" example plan >/dev/null
"$binary" site property-add "$fixture_dir" example z >/dev/null
"$binary" site origin-add "$fixture_dir" example \
    "https://xn--bcher-kva.example" >/dev/null
site_id=$("$binary" site list "$fixture_dir" | awk -F '\t' '$1 == "example" { print $2 }')
"$binary" site add "$fixture_dir" disabled "Disabled Site" \
    "https://disabled.example" >/dev/null
disabled_id=$("$binary" site list "$fixture_dir" | awk -F '\t' '$1 == "disabled" { print $2 }')
"$binary" site disable "$fixture_dir" disabled >/dev/null

"$binary" serve "$fixture_dir" 127.0.0.1 "$port" \
    >"$fixture_dir/server.stdout" 2>"$fixture_dir/server.stderr" &
server_pid=$!
ready=false
for _ in {1..100}; do
    if curl --silent --fail "$base/readyz" >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 0.02
done
test "$ready" = true

expect_code 200 "$base/healthz"
test "$(cat "$fixture_dir/body")" = "ok"
grep -qi '^Cache-Control: no-store, max-age=0' "$fixture_dir/headers"
expect_code 200 "$base/readyz"
test "$(cat "$fixture_dir/body")" = "ready"
expect_code 404 "$base/does-not-exist"
expect_code 405 -X GET "$base/v1/event"
grep -qi '^Allow: POST' "$fixture_dir/headers"
expect_code 405 -X OPTIONS "$base/v1/event"
grep -qi '^Allow: POST' "$fixture_dir/headers"

expect_code 200 "$base/tracker.js"
cmp "$fixture_dir/body" public/tracker.js
grep -qi '^Vary: Accept-Encoding' "$fixture_dir/headers"
expect_code 200 -H 'Accept-Encoding: br' "$base/tracker.js"
grep -qi '^Content-Encoding: br' "$fixture_dir/headers"
cmp "$fixture_dir/body" public/tracker.js.br
expect_code 200 -H 'Accept-Encoding: gzip' "$base/tracker.js"
grep -qi '^Content-Encoding: gzip' "$fixture_dir/headers"
cmp "$fixture_dir/body" public/tracker.js.gz
expect_code 200 -H 'Accept-Encoding: zebra' "$base/tracker.js"
test "$(grep -ci '^Content-Encoding:' "$fixture_dir/headers")" = 0
cmp "$fixture_dir/body" public/tracker.js
expect_code 200 -H 'Accept-Encoding: br;q=0, gzip' "$base/tracker.js"
grep -qi '^Content-Encoding: gzip' "$fixture_dir/headers"
cmp "$fixture_dir/body" public/tracker.js.gz
expect_code 200 -H 'Accept-Encoding: br' "$base/tracker.aef65945.js"
grep -qi '^Cache-Control: public, max-age=31536000, immutable' \
    "$fixture_dir/headers"
grep -qi '^Content-Encoding: br' "$fixture_dir/headers"
cmp "$fixture_dir/body" public/tracker.js.br

pageview=$(
    printf '{"v":1,"site":"%s","type":"pageview","path":"/pricing?current-private-token","referrer":"https://Search.Example/results?q=referrer-private-token","utm":{"source":"newsletter"}}' \
        "$site_id"
)
expect_code 204 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain;charset=UTF-8' \
    -H 'Origin: https://Example.COM:443' \
    -H 'X-Forwarded-For: 203.0.113.42' \
    -H 'X-Analytico-Country: de' \
    -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) Firefox/140.0' \
    --data-binary "$pageview"
test ! -s "$fixture_dir/body"
grep -q '^Access-Control-Allow-Origin: https://example.com' "$fixture_dir/headers"

custom=$(
    printf '{"v":1,"site":"%s","type":"event","name":"signup","path":"/welcome","properties":{"z":2,"plan":"basic"}}' \
        "$site_id"
)
expect_code 204 -X POST "$base/v1/event" \
    -H 'Transfer-Encoding: chunked' \
    -H 'Content-Type: text/plain' \
    -H 'Origin: https://example.com' \
    -H 'X-Forwarded-For: 203.0.114.42' \
    -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0) Chrome/140.0' \
    --data-binary "$custom"

expect_code 415 -X POST "$base/v1/event" \
    -H 'Content-Type: application/json' -H 'Origin: https://example.com' \
    --data-binary "$pageview"
expect_code 415 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Content-Encoding: gzip' \
    -H 'Origin: https://example.com' --data-binary "$pageview"
expect_code 403 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' --data-binary "$pageview"
expect_code 403 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://attacker.example' \
    --data-binary "$pageview"
expect_code 403 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: null' \
    --data-binary "$pageview"
expect_code 403 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://[bad' \
    --data-binary "$pageview"
expect_code 403 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com:444' \
    --data-binary "$pageview"
expect_code 400 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    -H 'Origin: https://example.com' --data-binary "$pageview"
expect_code 400 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    -H 'X-Forwarded-For: 192.0.2.1' \
    -H 'X-Forwarded-For: 192.0.2.2' --data-binary "$pageview"
expect_code 400 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    -H 'X-Forwarded-For: 192.0.2.1, 192.0.2.2' --data-binary "$pageview"
expect_code 204 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' \
    -H 'Origin: https://XN--BCHER-KVA.EXAMPLE:443' \
    -H 'X-Forwarded-For: 192.0.8.1' --data-binary "$pageview"

unknown_site=00000000-0000-4000-8000-000000000099
unknown=$(
    printf '{"v":1,"site":"%s","type":"pageview","path":"/"}' "$unknown_site"
)
expect_code 404 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$unknown"
disabled=$(
    printf '{"v":1,"site":"%s","type":"pageview","path":"/"}' "$disabled_id"
)
expect_code 404 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://disabled.example' \
    --data-binary "$disabled"

duplicate_json=$(
    printf '{"v":1,"site":"%s","site":"%s","type":"pageview","path":"/"}' \
        "$site_id" "$site_id"
)
expect_code 400 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$duplicate_json"
unknown_field=$(
    printf '{"v":1,"site":"%s","type":"pageview","path":"/","extra":true}' "$site_id"
)
expect_code 400 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$unknown_field"
nested_property=$(
    printf '{"v":1,"site":"%s","type":"event","name":"signup","path":"/","properties":{"plan":{"nested":true}}}' \
        "$site_id"
)
expect_code 400 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$nested_property"
unknown_property=$(
    printf '{"v":1,"site":"%s","type":"event","name":"signup","path":"/","properties":{"secret":"no"}}' \
        "$site_id"
)
expect_code 400 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$unknown_property"
floating_property=$(
    printf '{"v":1,"site":"%s","type":"event","name":"signup","path":"/","properties":{"z":1.5}}' \
        "$site_id"
)
expect_code 400 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$floating_property"
overflow_property=$(
    printf '{"v":1,"site":"%s","type":"event","name":"signup","path":"/","properties":{"z":9223372036854775808}}' \
        "$site_id"
)
expect_code 400 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$overflow_property"
printf '{"v":1,"site":"%s","type":"pageview","path":"/\377"}' \
    "$site_id" >"$fixture_dir/invalid-utf8.json"
expect_code 400 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "@$fixture_dir/invalid-utf8.json"
expect_code 400 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    -H 'Content-Length: 1' -H 'Content-Length: 1' \
    --data-binary x

oversized=$(head -c 8200 /dev/zero | tr '\0' x)
expect_code 413 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$oversized"
long_target="/$(head -c 4100 /dev/zero | tr '\0' x)"
expect_code 413 "$base$long_target"

header_args=()
for index in {1..33}; do
    header_args+=(-H "X-Bounded-$index: x")
done
expect_code 413 "${header_args[@]}" "$base/healthz"

expect_code 200 \
    -H 'Referer: https://example.com/rendered/page?private=yes' \
    -H 'X-Forwarded-For: 203.0.115.9' \
    "$base/v1/p.gif?site=$site_id&path=%2Fdocs&utm_source=noscript"
test "$(stat -c '%s' "$fixture_dir/body")" = "43"
grep -qi '^Content-Type: image/gif' "$fixture_dir/headers"
grep -qi '^Cache-Control: no-store, max-age=0' "$fixture_dir/headers"
expect_code 403 "$base/v1/p.gif?site=$site_id&path=%2Fdocs"
expect_code 403 -H 'Referer: https://attacker.example/' \
    "$base/v1/p.gif?site=$site_id&path=%2Fdocs"
expect_code 403 -H 'Referer: https://user@example.com/' \
    "$base/v1/p.gif?site=$site_id&path=%2Fdocs"
expect_code 403 -H 'Referer: not-a-url' \
    "$base/v1/p.gif?site=$site_id&path=%2Fdocs"
expect_code 400 -H 'Referer: https://example.com/' \
    "$base/v1/p.gif?site=$site_id&path=%2Fdocs&unknown=yes"
expect_code 400 -H 'Referer: https://example.com/' \
    "$base/v1/p.gif?site=$site_id&path=%ZZ"

rate_body=$(
    printf '{"v":1,"site":"%s","type":"pageview","path":"/rate"}' "$site_id"
)
for index in {1..30}; do
    expect_code 204 -X POST "$base/v1/event" \
        -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
        -H 'X-Forwarded-For: 198.51.100.9' --data-binary "$rate_body"
done
expect_code 429 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    -H 'X-Forwarded-For: 198.51.100.9' --data-binary "$rate_body"
grep -qi '^Retry-After: 1' "$fixture_dir/headers"

# Finish with inspectable events after the rate bucket scenario.
expect_code 204 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    -H 'X-Forwarded-For: 192.0.2.10' -H 'X-Analytico-Country: de' \
    -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) Firefox/140.0' \
    --data-binary "$pageview"
expect_code 204 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    -H 'X-Forwarded-For: 192.0.3.10' -H 'X-Analytico-Country: us' \
    -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0) Chrome/140.0' \
    --data-binary "$custom"

# Hold a bounded request open to prove SIGTERM interrupts active I/O without
# manufacturing or acknowledging an event.
exec 9<>"/dev/tcp/127.0.0.1/$port"
printf 'POST /v1/event HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: text/plain\r\nOrigin: https://example.com\r\nContent-Length: 100\r\n\r\n{' >&9
sleep 0.02
shutdown_started=$(date +%s%N)
kill -TERM "$server_pid"
wait "$server_pid"
shutdown_elapsed_ms=$((($(date +%s%N) - shutdown_started) / 1000000))
test "$shutdown_elapsed_ms" -le 2000
exec 9>&-
exec 9<&-
server_pid=

test "$("$binary" doctor "$fixture_dir")" = \
    "ok metadata=v1 events=v1 sites=2 goals=0 funnels=0 stored_events=36"
pageview_row=$("$binary" event inspect "$fixture_dir" pageview)
test "$pageview_row" = $'pageview\t/pricing\tsearch.example\tDE\tFirefox\tLinux\tdesktop\tnewsletter\t{}'
custom_row=$("$binary" event inspect "$fixture_dir" signup)
test "$custom_row" = $'signup\t/welcome\t\tUS\tChrome\tWindows\tdesktop\t\t{\"plan\":\"basic\",\"z\":2}'

probe=$("$binary" m2 rate-probe)
test "$probe" = \
    '{"attempted":100000,"capacity":4096,"accepted":4096,"rejected":95904}'

cmp public/tracker.js src/http/tracker.min.js
test "$(stat -c '%s' public/tracker.js)" -le 3072
test "$(stat -c '%s' public/tracker.js.br)" -le 1536
test "$(sha256sum public/tracker.js | cut -d' ' -f1)" = \
    "aef659456671d0dbc0a63e7732b14edc40ad0b08523fd91081f36004c99aa116"

for forbidden in \
    '203.0.113.42' \
    'Firefox/140.0' \
    'current-private-token' \
    'referrer-private-token'
do
    if grep -aF "$forbidden" "$fixture_dir/meta.db" \
        "$fixture_dir/events.duckdb" "$fixture_dir/server.stdout" \
        "$fixture_dir/server.stderr" >/dev/null
    then
        echo "private request input leaked: $forbidden" >&2
        exit 1
    fi
done

# Remove the store path under a second live process to exercise the real
# DuckDB commit-failure path. A write failure makes readiness dishonest until
# restart, returns fixed 500/503 bodies, and never creates an event.
fault_dir="$fixture_dir/fault"
fault_away="$fixture_dir/fault-away"
fault_port=$((port + 1000))
fault_base="http://127.0.0.1:$fault_port"
"$binary" init "$fault_dir" >/dev/null
"$binary" site add "$fault_dir" fault "Fault fixture" \
    "https://fault.example" >/dev/null
fault_site=$("$binary" site list "$fault_dir" |
    awk -F '\t' '$1 == "fault" { print $2 }')
"$binary" serve "$fault_dir" 127.0.0.1 "$fault_port" \
    >"$fault_dir/server.stdout" 2>"$fault_dir/server.stderr" &
server_pid=$!
ready=false
for _ in {1..100}; do
    if curl --silent --fail "$fault_base/readyz" >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 0.02
done
test "$ready" = true
mv "$fault_dir" "$fault_away"
fault_payload=$(
    printf '{"v":1,"site":"%s","type":"pageview","path":"/fault"}' \
        "$fault_site"
)
expect_code 500 -X POST "$fault_base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://fault.example' \
    --data-binary "$fault_payload"
test "$(cat "$fixture_dir/body")" = "internal error"
grep -qi '^Cache-Control: no-store, max-age=0' "$fixture_dir/headers"
expect_code 503 "$fault_base/readyz"
test "$(cat "$fixture_dir/body")" = "unavailable"
mv "$fault_away" "$fault_dir"
kill -TERM "$server_pid"
wait "$server_pid"
server_pid=
test "$("$binary" doctor "$fault_dir")" = \
    "ok metadata=v1 events=v1 sites=1 goals=0 funnels=0 stored_events=0"

echo "M2 bounded real-HTTP collection checks passed"
