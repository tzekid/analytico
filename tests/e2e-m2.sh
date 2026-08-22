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

expect_no_store_headers() {
    grep -qi '^Cache-Control: no-store, max-age=0' "$fixture_dir/headers"
    grep -qi '^X-Content-Type-Options: nosniff' "$fixture_dir/headers"
    grep -qi '^Referrer-Policy: no-referrer' "$fixture_dir/headers"
    grep -qi '^Connection: close' "$fixture_dir/headers"
    if grep -qi '^Set-Cookie:' "$fixture_dir/headers"; then
        echo "collector response unexpectedly set a cookie" >&2
        exit 1
    fi
}

expect_fixed_error() {
    local expected=$1
    test "$(cat "$fixture_dir/body")" = "$expected"
    expect_no_store_headers
    grep -qi '^Content-Type: text/plain; charset=utf-8' \
        "$fixture_dir/headers"
}

"$binary" init "$fixture_dir" >/dev/null
"$binary" site add "$fixture_dir" example "Example Site" \
    "https://example.com" --timezone UTC >/dev/null
"$binary" site property-add "$fixture_dir" example plan >/dev/null
"$binary" site property-add "$fixture_dir" example z >/dev/null
"$binary" site origin-add "$fixture_dir" example \
    "https://xn--bcher-kva.example" >/dev/null
site_id=$("$binary" site list "$fixture_dir" | awk -F '\t' '$1 == "example" { print $2 }')
"$binary" site add "$fixture_dir" disabled "Disabled Site" \
    "https://disabled.example" --timezone UTC >/dev/null
disabled_id=$("$binary" site list "$fixture_dir" | awk -F '\t' '$1 == "disabled" { print $2 }')
"$binary" site disable "$fixture_dir" disabled >/dev/null

"$binary" serve --listen "127.0.0.1:$port" \
    --meta "$fixture_dir/meta.db" \
    --events "$fixture_dir/events.duckdb" \
    --temp "$fixture_dir/tmp" \
    --visitor-key-file "$fixture_dir/visitor.key" \
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
expect_no_store_headers
grep -qi '^Content-Length: 3' "$fixture_dir/headers"
expect_code 200 "$base/readyz"
test "$(cat "$fixture_dir/body")" = "ready"
expect_code 404 "$base/does-not-exist"
expect_fixed_error "not found"
expect_code 405 -X GET "$base/v1/event"
grep -qi '^Allow: POST' "$fixture_dir/headers"
expect_fixed_error "method not allowed"
expect_code 405 -X OPTIONS "$base/v1/event"
grep -qi '^Allow: POST' "$fixture_dir/headers"

expect_code 200 "$base/tracker.js"
cmp "$fixture_dir/body" public/tracker.js
grep -qi '^Content-Type: text/javascript; charset=utf-8' \
    "$fixture_dir/headers"
grep -qi '^Content-Length: 3025' "$fixture_dir/headers"
grep -qi '^Cache-Control: public, max-age=300' "$fixture_dir/headers"
grep -qi '^X-Content-Type-Options: nosniff' "$fixture_dir/headers"
grep -qi '^Vary: Accept-Encoding' "$fixture_dir/headers"
grep -qi '^Connection: close' "$fixture_dir/headers"
if grep -qi '^Set-Cookie:' "$fixture_dir/headers"; then
    echo "tracker response unexpectedly set a cookie" >&2
    exit 1
fi
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
cmp "$fixture_dir/body" src/http/tracker.v1.min.js.br
expect_code 200 -H 'Accept-Encoding: br' "$base/tracker.78135195.js"
grep -qi '^Cache-Control: public, max-age=31536000, immutable' \
    "$fixture_dir/headers"
grep -qi '^Content-Encoding: br' "$fixture_dir/headers"
cmp "$fixture_dir/body" src/http/tracker.78135195.min.js.br
expect_code 200 -H 'Accept-Encoding: gzip' "$base/tracker.fb64c486.js"
grep -qi '^Cache-Control: public, max-age=31536000, immutable' \
    "$fixture_dir/headers"
grep -qi '^Content-Encoding: gzip' "$fixture_dir/headers"
cmp "$fixture_dir/body" src/http/tracker.fb64c486.min.js.gz
expect_code 200 -H 'Accept-Encoding: br' "$base/tracker.d9e94247.js"
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
expect_no_store_headers
grep -qi '^Content-Length: 0' "$fixture_dir/headers"
grep -q '^Access-Control-Allow-Origin: https://example.com' "$fixture_dir/headers"
grep -qi '^Vary: Origin' "$fixture_dir/headers"

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
expect_fixed_error "unsupported media type"
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
expect_fixed_error "forbidden"
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
expect_fixed_error "bad request"

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
expect_fixed_error "payload too large"

expect_code 405 -X GET "$base/v2/event"
grep -qi '^Allow: POST' "$fixture_dir/headers"
expect_fixed_error "method not allowed"

occurred_seconds=$EPOCHSECONDS
occurred_ms=$((occurred_seconds * 1000))
occurred_micros=$((occurred_ms * 1000))
v2_anonymous=00000000-0000-4000-8000-000000000202
v2_session=00000000-0000-4000-8000-000000000203
v2_page_id=00000000-0000-4000-8000-000000000201
v2_custom_id=00000000-0000-4000-8000-000000000204
v2_identify_id=00000000-0000-4000-8000-000000000205
v2_engagement_id=00000000-0000-4000-8000-000000000211
v2_ephemeral=00000000-0000-4000-8000-000000000212
v2_ephemeral_session=00000000-0000-4000-8000-000000000213
v2_page=$(
    printf '{"v":2,"site":"%s","event_id":"%s","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":0,"occurred_at_ms":%s,"type":"pageview","page":{"path":"/home?v2-private-token","title":"Home","hostname":"EXAMPLE.COM"},"referrer":"https://Search.Example/results?q=v2-referrer-private-token","utm":{"source":"newsletter","medium":"email"}}' \
        "$site_id" "$v2_page_id" "$v2_anonymous" "$v2_session" \
        "$occurred_ms"
)
expect_code 204 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain;charset=UTF-8' \
    -H 'Origin: https://example.com' \
    -H 'X-Forwarded-For: 198.18.10.1' \
    -H 'X-Analytico-Country: de' \
    -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) Chrome/140.0' \
    --data-binary "$v2_page"
test ! -s "$fixture_dir/body"
expect_no_store_headers
grep -q '^Access-Control-Allow-Origin: https://example.com' \
    "$fixture_dir/headers"

v2_custom=$(
    printf '{"v":2,"site":"%s","event_id":"%s","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":1,"occurred_at_ms":%s,"type":"event","name":"purchase","page":{"path":"/pricing?drop=yes","title":"Pricing","hostname":"EXAMPLE.COM"},"properties":{"z":2,"plan":"pro"},"value":{"amount":"49.00","currency":"EUR"}}' \
        "$site_id" "$v2_custom_id" "$v2_anonymous" "$v2_session" \
        "$occurred_ms"
)
expect_code 204 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    -H 'X-Forwarded-For: 198.18.10.1' \
    -H 'X-Analytico-Country: de' \
    -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) Chrome/140.0' \
    --data-binary "$v2_custom"

v2_engagement=$(
    printf '{"v":2,"site":"%s","event_id":"%s","anonymous_id":"%s","identity_quality":"ephemeral","session_id":"%s","sequence":0,"occurred_at_ms":%s,"type":"engagement","page":{"path":"/article","title":"Article","hostname":"example.com"},"engagement":{"active_ms":15000,"max_scroll_depth":92}}' \
        "$site_id" "$v2_engagement_id" "$v2_ephemeral" \
        "$v2_ephemeral_session" "$occurred_ms"
)
expect_code 204 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    -H 'X-Forwarded-For: 198.18.11.1' \
    -H 'X-Analytico-Country: us' \
    -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) Firefox/140.0' \
    --data-binary "$v2_engagement"

v2_identify=$(
    printf '{"v":2,"site":"%s","event_id":"%s","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":2,"occurred_at_ms":%s,"type":"identify","page":{"path":"/account","title":"Account","hostname":"example.com"},"user":{"id":"user_123","traits":{"tier":2,"plan":"pro"}}}' \
        "$site_id" "$v2_identify_id" "$v2_anonymous" "$v2_session" \
        "$occurred_ms"
)
expect_code 204 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    -H 'X-Forwarded-For: 198.18.10.1' \
    -H 'X-Analytico-Country: de' \
    -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) Chrome/140.0' \
    --data-binary "$v2_identify"

# Protocol v2 does not consult the v1 property allowlist.
v2_unlisted=$(
    printf '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000207","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":5,"occurred_at_ms":%s,"type":"event","name":"docs","properties":{"source":"readme"}}' \
        "$site_id" "$v2_anonymous" "$v2_session" "$occurred_ms"
)
expect_code 204 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    -H 'X-Forwarded-For: 198.18.10.1' \
    -H 'X-Analytico-Country: de' \
    -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) Chrome/140.0' \
    --data-binary "$v2_unlisted"

# Normalized key order, hostname case, and stripped query are part of the
# canonical digest, so this equivalent retry is a success/no-op.
v2_custom_retry=$(
    printf '{"type":"event","occurred_at_ms":%s,"sequence":1,"session_id":"%s","identity_quality":"persistent","anonymous_id":"%s","event_id":"%s","site":"%s","v":2,"name":"purchase","page":{"hostname":"example.com","title":"Pricing","path":"/pricing"},"properties":{"plan":"pro","z":2},"value":{"currency":"EUR","amount":"49.00"}}' \
        "$occurred_ms" "$v2_session" "$v2_anonymous" "$v2_custom_id" \
        "$site_id"
)
expect_code 204 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    -H 'X-Forwarded-For: 198.18.10.1' --data-binary "$v2_custom_retry"

v2_custom_conflict=$(
    printf '{"type":"event","occurred_at_ms":%s,"sequence":9,"session_id":"%s","identity_quality":"persistent","anonymous_id":"%s","event_id":"%s","site":"%s","v":2,"name":"purchase","page":{"hostname":"example.com","title":"Pricing","path":"/pricing"},"properties":{"plan":"pro","z":2},"value":{"currency":"EUR","amount":"49.00"}}' \
        "$occurred_ms" "$v2_session" "$v2_anonymous" "$v2_custom_id" \
        "$site_id"
)
expect_code 409 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    -H 'X-Forwarded-For: 198.18.10.1' --data-binary "$v2_custom_conflict"
expect_fixed_error "conflict"

v2_identity_conflict=$(
    printf '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000206","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":3,"occurred_at_ms":%s,"type":"identify","user":{"id":"user_456"}}' \
        "$site_id" "$v2_anonymous" "$v2_session" "$occurred_ms"
)
expect_code 409 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    -H 'X-Forwarded-For: 198.18.10.1' --data-binary "$v2_identity_conflict"
expect_fixed_error "conflict"
grep -qi '^X-Analytico-Code: identity_conflict' "$fixture_dir/headers"

v2_nested=$(
    printf '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000221","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":4,"occurred_at_ms":%s,"type":"event","name":"bad","properties":{"z":{"nested":true}}}' \
        "$site_id" "$v2_anonymous" "$v2_session" "$occurred_ms"
)
expect_code 400 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$v2_nested"
v2_exponent_property=$(
    printf '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000222","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":4,"occurred_at_ms":%s,"type":"event","name":"bad","properties":{"z":1e2}}' \
        "$site_id" "$v2_anonymous" "$v2_session" "$occurred_ms"
)
expect_code 400 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$v2_exponent_property"
v2_bad_decimal=$(
    printf '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000223","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":4,"occurred_at_ms":%s,"type":"event","name":"bad","value":{"amount":"1e2","currency":"EUR"}}' \
        "$site_id" "$v2_anonymous" "$v2_session" "$occurred_ms"
)
expect_code 400 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$v2_bad_decimal"
v2_unknown_version=$(
    printf '{"v":3,"site":"%s","event_id":"00000000-0000-4000-8000-000000000224","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":4,"occurred_at_ms":%s,"type":"pageview","page":{"path":"/"}}' \
        "$site_id" "$v2_anonymous" "$v2_session" "$occurred_ms"
)
expect_code 400 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$v2_unknown_version"
expect_code 400 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$v2_page"
v2_ephemeral_identify=${v2_identify/persistent/ephemeral}
expect_code 400 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$v2_ephemeral_identify"
v2_future=${v2_page/$occurred_ms/$((occurred_ms + 86460000))}
expect_code 400 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$v2_future"
v2_past=${v2_page/$occurred_ms/$((occurred_ms - 604860000))}
expect_code 400 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$v2_past"
v2_bad_uuid=${v2_page/00000000-0000-4000-8000-000000000201/AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA}
expect_code 400 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$v2_bad_uuid"
v2_sequence_overflow=$(
    printf '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000226","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":4294967296,"occurred_at_ms":%s,"type":"pageview","page":{"path":"/"}}' \
        "$site_id" "$v2_anonymous" "$v2_session" "$occurred_ms"
)
expect_code 400 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$v2_sequence_overflow"
v2_engagement_overflow=${v2_engagement/15000/60001}
expect_code 400 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$v2_engagement_overflow"
v2_decimal_overflow=${v2_bad_decimal/1e2/1234567890123.00}
expect_code 400 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$v2_decimal_overflow"
v2_duplicate_field=$(
    printf '{"v":2,"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000227","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":4,"occurred_at_ms":%s,"type":"pageview","page":{"path":"/"}}' \
        "$site_id" "$v2_anonymous" "$v2_session" "$occurred_ms"
)
expect_code 400 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$v2_duplicate_field"
v2_bad_referrer=$(
    printf '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000228","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":4,"occurred_at_ms":%s,"type":"pageview","page":{"path":"/"},"referrer":"not-a-url"}' \
        "$site_id" "$v2_anonymous" "$v2_session" "$occurred_ms"
)
expect_code 400 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$v2_bad_referrer"
long_property=$(head -c 513 /dev/zero | tr '\0' x)
v2_long_property=$(
    printf '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000225","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":4,"occurred_at_ms":%s,"type":"event","name":"bad","properties":{"value":"%s"}}' \
        "$site_id" "$v2_anonymous" "$v2_session" "$occurred_ms" \
        "$long_property"
)
expect_code 400 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$v2_long_property"

v2_large_invalid=$(head -c 9000 /dev/zero | tr '\0' x)
expect_code 400 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$v2_large_invalid"
v2_oversized=$(head -c 16400 /dev/zero | tr '\0' x)
expect_code 413 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    --data-binary "$v2_oversized"
expect_fixed_error "payload too large"

expect_code 200 \
    -H 'Referer: https://example.com/rendered/page?private=yes' \
    -H 'X-Forwarded-For: 203.0.115.9' \
    "$base/v1/p.gif?site=$site_id&path=%2Fdocs&utm_source=noscript"
test "$(stat -c '%s' "$fixture_dir/body")" = "43"
grep -qi '^Content-Type: image/gif' "$fixture_dir/headers"
grep -qi '^Content-Length: 43' "$fixture_dir/headers"
expect_no_store_headers
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
# Start immediately after an integer-second boundary so the real token bucket
# cannot refill during this short 31-request burst.
rate_second=$EPOCHSECONDS
while (( EPOCHSECONDS == rate_second )); do
    :
done
for index in {1..30}; do
    expect_code 204 -X POST "$base/v1/event" \
        -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
        -H 'X-Forwarded-For: 198.51.100.9' --data-binary "$rate_body"
done
expect_code 429 -X POST "$base/v1/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    -H 'X-Forwarded-For: 198.51.100.9' --data-binary "$rate_body"
grep -qi '^Retry-After: 1' "$fixture_dir/headers"
expect_fixed_error "rate limited"

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

# Same occurred time, reverse arrival: sequence then event ID must order them.
v2_order_later=00000000-0000-4000-8000-000000000240
v2_order_earlier=00000000-0000-4000-8000-000000000241
v2_order_later_body=$(
    printf '{"v":2,"site":"%s","event_id":"%s","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":4,"occurred_at_ms":%s,"type":"event","name":"later"}' \
        "$site_id" "$v2_order_later" "$v2_anonymous" "$v2_session" \
        "$occurred_ms"
)
v2_order_earlier_body=$(
    printf '{"v":2,"site":"%s","event_id":"%s","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":3,"occurred_at_ms":%s,"type":"event","name":"earlier"}' \
        "$site_id" "$v2_order_earlier" "$v2_anonymous" "$v2_session" \
        "$occurred_ms"
)
expect_code 204 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    -H 'X-Forwarded-For: 198.18.10.1' --data-binary "$v2_order_later_body"
expect_code 204 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    -H 'X-Forwarded-For: 198.18.10.1' --data-binary "$v2_order_earlier_body"

midnight_ms=$(( (occurred_seconds / 86400) * 86400 * 1000 ))
before_midnight_ms=$((midnight_ms - 600000))
after_midnight_ms=$((midnight_ms + 600000))
v2_midnight_session=00000000-0000-4000-8000-000000000250
v2_midnight_first=00000000-0000-4000-8000-000000000251
v2_midnight_second=00000000-0000-4000-8000-000000000252
v2_midnight_first_body=$(
    printf '{"v":2,"site":"%s","event_id":"%s","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":0,"occurred_at_ms":%s,"type":"pageview","page":{"path":"/pre-midnight","hostname":"example.com"}}' \
        "$site_id" "$v2_midnight_first" "$v2_anonymous" "$v2_midnight_session" \
        "$before_midnight_ms"
)
v2_midnight_second_body=$(
    printf '{"v":2,"site":"%s","event_id":"%s","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":1,"occurred_at_ms":%s,"type":"pageview","page":{"path":"/post-midnight","hostname":"example.com"}}' \
        "$site_id" "$v2_midnight_second" "$v2_anonymous" "$v2_midnight_session" \
        "$after_midnight_ms"
)
expect_code 204 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    -H 'X-Forwarded-For: 198.18.10.1' --data-binary "$v2_midnight_first_body"
expect_code 204 -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://example.com' \
    -H 'X-Forwarded-For: 198.18.10.1' --data-binary "$v2_midnight_second_body"

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
    "ok metadata=v3 events=v3 sites=2 goals=0 funnels=0 stored_events=45 key=ok"
pageview_row=$("$binary" event inspect "$fixture_dir" pageview)
test "$pageview_row" = $'pageview\t/pricing\tsearch.example\tDE\tFirefox\tLinux\tdesktop\tnewsletter\t{}'
custom_row=$("$binary" event inspect "$fixture_dir" signup)
test "$custom_row" = $'signup\t/welcome\t\tUS\tChrome\tWindows\tdesktop\t\t{\"plan\":\"basic\",\"z\":2}'

received_date=$(date --utc --date="@$occurred_seconds" +%F)
v2_page_row=$("$binary" m2 v2-inspect "$fixture_dir" "$site_id" "$v2_page_id")
test "$v2_page_row" = \
    "{\"event_schema_version\":3,\"protocol_version\":2,\"tracker_version\":2,\"event_id\":\"$v2_page_id\",\"occurred_at_utc_micros\":$occurred_micros,\"received_date_utc\":\"$received_date\",\"site_local_date\":\"$received_date\",\"site_utc_offset_minutes\":0,\"kind\":1,\"event_name\":\"page_view\",\"path\":\"/home\",\"page_title\":\"Home\",\"hostname\":\"example.com\",\"anonymous_id\":\"$v2_anonymous\",\"identity_quality\":1,\"user_id\":\"\",\"session_id\":\"$v2_session\",\"sequence\":0,\"session_start\":true,\"referrer_host\":\"search.example\",\"country_code\":\"DE\",\"language\":\"\",\"browser_family\":\"Chrome\",\"os_family\":\"Linux\",\"device_category\":\"desktop\",\"utm_source\":\"newsletter\",\"utm_medium\":\"email\",\"utm_campaign\":\"\",\"utm_term\":\"\",\"utm_content\":\"\",\"properties_json\":\"{}\",\"user_traits_json\":\"{}\",\"value_amount\":null,\"value_currency\":\"\",\"engagement_ms\":0,\"max_scroll_depth\":0,\"linked_user_id\":\"user_123\"}"
v2_custom_row=$("$binary" m2 v2-inspect "$fixture_dir" "$site_id" "$v2_custom_id")
test "$v2_custom_row" = \
    "{\"event_schema_version\":3,\"protocol_version\":2,\"tracker_version\":2,\"event_id\":\"$v2_custom_id\",\"occurred_at_utc_micros\":$occurred_micros,\"received_date_utc\":\"$received_date\",\"site_local_date\":\"$received_date\",\"site_utc_offset_minutes\":0,\"kind\":2,\"event_name\":\"purchase\",\"path\":\"/pricing\",\"page_title\":\"Pricing\",\"hostname\":\"example.com\",\"anonymous_id\":\"$v2_anonymous\",\"identity_quality\":1,\"user_id\":\"\",\"session_id\":\"$v2_session\",\"sequence\":1,\"session_start\":false,\"referrer_host\":\"\",\"country_code\":\"DE\",\"language\":\"\",\"browser_family\":\"Chrome\",\"os_family\":\"Linux\",\"device_category\":\"desktop\",\"utm_source\":\"\",\"utm_medium\":\"\",\"utm_campaign\":\"\",\"utm_term\":\"\",\"utm_content\":\"\",\"properties_json\":\"{\\\"plan\\\":\\\"pro\\\",\\\"z\\\":2}\",\"user_traits_json\":\"{}\",\"value_amount\":\"49.000000\",\"value_currency\":\"EUR\",\"engagement_ms\":0,\"max_scroll_depth\":0,\"linked_user_id\":\"user_123\"}"
v2_engagement_row=$("$binary" m2 v2-inspect "$fixture_dir" "$site_id" "$v2_engagement_id")
test "$v2_engagement_row" = \
    "{\"event_schema_version\":3,\"protocol_version\":2,\"tracker_version\":2,\"event_id\":\"$v2_engagement_id\",\"occurred_at_utc_micros\":$occurred_micros,\"received_date_utc\":\"$received_date\",\"site_local_date\":\"$received_date\",\"site_utc_offset_minutes\":0,\"kind\":3,\"event_name\":\"engagement\",\"path\":\"/article\",\"page_title\":\"Article\",\"hostname\":\"example.com\",\"anonymous_id\":\"$v2_ephemeral\",\"identity_quality\":2,\"user_id\":\"\",\"session_id\":\"$v2_ephemeral_session\",\"sequence\":0,\"session_start\":true,\"referrer_host\":\"\",\"country_code\":\"US\",\"language\":\"\",\"browser_family\":\"Firefox\",\"os_family\":\"Linux\",\"device_category\":\"desktop\",\"utm_source\":\"\",\"utm_medium\":\"\",\"utm_campaign\":\"\",\"utm_term\":\"\",\"utm_content\":\"\",\"properties_json\":\"{}\",\"user_traits_json\":\"{}\",\"value_amount\":null,\"value_currency\":\"\",\"engagement_ms\":15000,\"max_scroll_depth\":92,\"linked_user_id\":\"\"}"
v2_identify_row=$("$binary" m2 v2-inspect "$fixture_dir" "$site_id" "$v2_identify_id")
test "$v2_identify_row" = \
    "{\"event_schema_version\":3,\"protocol_version\":2,\"tracker_version\":2,\"event_id\":\"$v2_identify_id\",\"occurred_at_utc_micros\":$occurred_micros,\"received_date_utc\":\"$received_date\",\"site_local_date\":\"$received_date\",\"site_utc_offset_minutes\":0,\"kind\":4,\"event_name\":\"identify\",\"path\":\"/account\",\"page_title\":\"Account\",\"hostname\":\"example.com\",\"anonymous_id\":\"$v2_anonymous\",\"identity_quality\":1,\"user_id\":\"user_123\",\"session_id\":\"$v2_session\",\"sequence\":2,\"session_start\":false,\"referrer_host\":\"\",\"country_code\":\"DE\",\"language\":\"\",\"browser_family\":\"Chrome\",\"os_family\":\"Linux\",\"device_category\":\"desktop\",\"utm_source\":\"\",\"utm_medium\":\"\",\"utm_campaign\":\"\",\"utm_term\":\"\",\"utm_content\":\"\",\"properties_json\":\"{}\",\"user_traits_json\":\"{\\\"plan\\\":\\\"pro\\\",\\\"tier\\\":2}\",\"value_amount\":null,\"value_currency\":\"\",\"engagement_ms\":0,\"max_scroll_depth\":0,\"linked_user_id\":\"user_123\"}"
test "$("$binary" m2 identity-links "$fixture_dir")" = 1
test "$("$binary" m2 session-timeline "$fixture_dir" "$site_id" "$v2_session")" = \
    "[\"$v2_page_id\",\"$v2_custom_id\",\"$v2_identify_id\",\"$v2_order_earlier\",\"$v2_order_later\",\"00000000-0000-4000-8000-000000000207\"]"
v2_midnight_first_row=$("$binary" m2 v2-inspect "$fixture_dir" "$site_id" "$v2_midnight_first")
v2_midnight_second_row=$("$binary" m2 v2-inspect "$fixture_dir" "$site_id" "$v2_midnight_second")
[[ "$v2_midnight_first_row" == *'"session_start":true'* ]]
[[ "$v2_midnight_second_row" == *'"session_start":false'* ]]
[[ "$v2_midnight_first_row" == *'"session_id":"'"$v2_midnight_session"'"'* ]]
[[ "$v2_midnight_second_row" == *'"session_id":"'"$v2_midnight_session"'"'* ]]

probe=$("$binary" m2 rate-probe)
test "$probe" = \
    '{"attempted":100000,"capacity":4096,"accepted":4096,"rejected":95904}'

cmp public/tracker.js src/http/tracker.min.js
test "$(stat -c '%s' public/tracker.js)" -le 3072
test "$(stat -c '%s' public/tracker.js.br)" -le 1536
test "$(sha256sum public/tracker.js | cut -d' ' -f1)" = \
    "d9e94247f97fa84795f5a9bb493a0d383b2aac11565e80e6ceb670b4e9e05c2c"
test "$(sha256sum src/http/tracker.78135195.min.js | cut -d' ' -f1)" = \
    "7813519555b9ea0625a90c1d42c1adfb5db78d3d33b5229809e6b654830ffcf7"
test "$(sha256sum src/http/tracker.fb64c486.min.js | cut -d' ' -f1)" = \
    "fb64c48638c240656d0627fb3087bdf84cdd6ed3570efa363869b9eea16c97d2"
test "$(sha256sum src/http/tracker.v1.min.js | cut -d' ' -f1)" = \
    "aef659456671d0dbc0a63e7732b14edc40ad0b08523fd91081f36004c99aa116"

for forbidden in \
    '203.0.113.42' \
    'Firefox/140.0' \
    'current-private-token' \
    'referrer-private-token' \
    'v2-private-token' \
    'v2-referrer-private-token'
do
    if grep -aF "$forbidden" "$fixture_dir/meta.db" \
        "$fixture_dir/events.duckdb" "$fixture_dir/server.stdout" \
        "$fixture_dir/server.stderr" >/dev/null
    then
        echo "private request input leaked: $forbidden" >&2
        exit 1
    fi
done

"$binary" site disable "$fixture_dir" example >/dev/null
test "$("$binary" site delete "$fixture_dir" example --confirm example)" = \
    "site deleted example"
test "$("$binary" m2 identity-links "$fixture_dir")" = 0

# Remove the store path under a second live process to exercise the real
# DuckDB commit-failure path. A write failure makes readiness dishonest until
# restart, returns fixed 500/503 bodies, and never creates an event.
fault_dir="$fixture_dir/fault"
fault_away="$fixture_dir/fault-away"
fault_port=$((port + 1000))
fault_base="http://127.0.0.1:$fault_port"
"$binary" init "$fault_dir" >/dev/null
"$binary" site add "$fault_dir" fault "Fault fixture" \
    "https://fault.example" --timezone UTC >/dev/null
fault_site=$("$binary" site list "$fault_dir" |
    awk -F '\t' '$1 == "fault" { print $2 }')
"$binary" serve --listen "127.0.0.1:$fault_port" \
    --meta "$fault_dir/meta.db" \
    --events "$fault_dir/events.duckdb" \
    --temp "$fault_dir/tmp" \
    --visitor-key-file "$fault_dir/visitor.key" \
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
    printf '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000291","anonymous_id":"00000000-0000-4000-8000-000000000292","identity_quality":"persistent","session_id":"00000000-0000-4000-8000-000000000293","sequence":0,"occurred_at_ms":%s,"type":"identify","user":{"id":"fault_user","traits":{"plan":"private-plan"}}}' \
        "$fault_site" "$(date +%s%3N)"
)
expect_code 500 -X POST "$fault_base/v2/event" \
    -H 'Content-Type: text/plain' -H 'Origin: https://fault.example' \
    --data-binary "$fault_payload"
expect_fixed_error "internal error"
expect_code 503 "$fault_base/readyz"
expect_fixed_error "unavailable"
mv "$fault_away" "$fault_dir"
kill -TERM "$server_pid"
wait "$server_pid"
server_pid=
test "$("$binary" doctor "$fault_dir")" = \
    "ok metadata=v3 events=v3 sites=1 goals=0 funnels=0 stored_events=0 key=ok"
test "$("$binary" m2 identity-links "$fault_dir")" = 0
if grep -aE 'fault_user|private-plan' \
    "$fault_dir/server.stdout" "$fault_dir/server.stderr" >/dev/null
then
    echo "failed identify leaked user or trait data" >&2
    exit 1
fi

echo "M2 bounded real-HTTP collection checks passed"
