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
fixture=$(mktemp -d "$PWD/.zig-cache/properties-e2e.XXXXXX")
server_pid=
port=$((53000 + ($$ % 500)))
base="http://127.0.0.1:$port"
cleanup() {
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT

post() {
    local expected=$1
    local payload=$2
    local code
    code=$(curl --silent --show-error --output "$fixture/body" \
        --write-out '%{http_code}' -X POST "$base/v2/event" \
        -H 'Content-Type: text/plain;charset=UTF-8' \
        -H 'Origin: https://properties.example' \
        -H 'X-Forwarded-For: 203.0.113.10' \
        -H 'User-Agent: Mozilla/5.0 Firefox/140.0' \
        --data-binary "$payload")
    if [[ "$code" != "$expected" ]]; then
        echo "expected HTTP $expected, got $code" >&2
        cat "$fixture/body" >&2
        exit 1
    fi
}

"$binary" init "$fixture" >/dev/null
"$binary" site add "$fixture" properties Properties \
    https://properties.example --timezone UTC >/dev/null
site_id=$("$binary" site list "$fixture" |
    awk -F '\t' '$1 == "properties" { print $2 }')

"$binary" serve --listen "127.0.0.1:$port" \
    --meta "$fixture/meta.db" \
    --events "$fixture/events.duckdb" \
    --temp "$fixture/tmp" \
    --visitor-key-file "$fixture/visitor.key" \
    >"$fixture/server.stdout" 2>"$fixture/server.stderr" &
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

occurred_ms=$((EPOCHSECONDS * 1000))
start_micros=$((occurred_ms * 1000 - 60000000))
end_micros=$((occurred_ms * 1000 + 60000000))
anonymous_id=00000000-0000-4000-8000-000000000a10
session_id=00000000-0000-4000-8000-000000000a11

event_payload() {
    local event_id=$1
    local sequence=$2
    local properties_json=$3
    printf \
        '{"v":2,"site":"%s","event_id":"%s","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":%s,"occurred_at_ms":%s,"type":"event","name":"sample"%s}' \
        "$site_id" "$event_id" "$anonymous_id" "$session_id" "$sequence" \
        "$occurred_ms" "$properties_json"
}

post 204 "$(event_payload \
    00000000-0000-4000-8000-000000000a01 0 \
    ',"properties":{"typed":"14","high":"v1"}')"
post 204 "$(event_payload \
    00000000-0000-4000-8000-000000000a02 1 \
    ',"properties":{"typed":14,"high":"v2"}')"
post 204 "$(event_payload \
    00000000-0000-4000-8000-000000000a03 2 \
    ',"properties":{"typed":14.2500,"high":"v3"}')"
post 204 "$(event_payload \
    00000000-0000-4000-8000-000000000a04 3 \
    ',"properties":{"typed":true,"high":"v4"}')"
post 204 "$(event_payload \
    00000000-0000-4000-8000-000000000a05 4 \
    ',"properties":{"typed":null,"high":"v5"}')"
post 204 "$(event_payload \
    00000000-0000-4000-8000-000000000a06 5 \
    ',"properties":{"high":"v6"}')"

# Equivalent decimal spelling and key order produce the same canonical digest.
post 204 "$(event_payload \
    00000000-0000-4000-8000-000000000a03 2 \
    ',"properties":{"high":"v3","typed":14.250000}')"

identify=$(printf \
    '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000a07","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":6,"occurred_at_ms":%s,"type":"identify","user":{"id":"property-user","traits":{"typed":14.25}}}' \
    "$site_id" "$anonymous_id" "$session_id" "$occurred_ms")
post 204 "$identify"

post 400 "$(event_payload \
    00000000-0000-4000-8000-000000000a08 7 \
    ',"properties":{"typed":1e2}')"
post 400 "$(event_payload \
    00000000-0000-4000-8000-000000000a09 8 \
    ',"properties":{"typed":1.1234567}')"
post 400 "$(event_payload \
    00000000-0000-4000-8000-000000000a0a 9 \
    ',"properties":{"typed":9223372036854775808}')"
post 400 "$(event_payload \
    00000000-0000-4000-8000-000000000a0b 10 \
    ',"properties":{"typed":1,"typed":2}')"

kill -TERM "$server_pid"
wait "$server_pid"
server_pid=

stored=$("$binary" m2 v2-inspect "$fixture" "$site_id" \
    00000000-0000-4000-8000-000000000a03)
test "$(jq -r '.properties_json' <<<"$stored")" = \
    '{"high":"v3","typed":14.250000}'

result=$("$binary" m2 property-semantics "$fixture" "$site_id" \
    "$start_micros" "$end_micros")
jq -e '
    .catalog.property_count == 2 and
    .catalog.truncated == false and
    ([.catalog.entries[] | select(.name == "typed") | .scalar_type] | sort) ==
        ["boolean", "decimal", "integer", "null", "string"] and
    .filters == {
        "string": 1,
        "integer": 1,
        "decimal": 1,
        "boolean": 1,
        "null_value": 1,
        "missing": 1
    } and
    .breakdown.bucket_count == 6 and
    (.breakdown.rows | length) == 6 and
    .breakdown.truncated == false and
    ([.breakdown.rows[].scalar_type] | sort) ==
        ["boolean", "decimal", "integer", "missing", "null", "string"] and
    .high_cardinality.bucket_count == 6 and
    (.high_cardinality.rows | length) == 3 and
    .high_cardinality.truncated == true and
    .trait_breakdown.bucket_count == 1 and
    .trait_breakdown.rows[0].scalar_type == "decimal" and
    .trait_breakdown.rows[0].value == "14.250000" and
    .trait_breakdown.rows[0].event_count == 1
' <<<"$result" >/dev/null

mkdir -p "$fixture/million"
million_result=$("$binary" m2 property-million "$fixture/million")
jq -e '
    .metric_v2_breakdown.rows == 4 and
    .metric_v2_breakdown.cardinality == 4 and
    .metric_v2_breakdown.property_count == 12 and
    .metric_v2_breakdown.mixed_types == 4 and
    .metric_v2_breakdown.sampled_plan_events == 2000 and
    .metric_v2_breakdown.samples == 10 and
    .metric_v2_breakdown.cold_ms < 2000 and
    .metric_v2_breakdown.p95_ms < 700 and
    .metric_v2_breakdown.ordinary_p95_ms < 400 and
    .metric_v2_breakdown.search_rows == 10 and
    .metric_v2_breakdown.search_cardinality == 10 and
    .metric_v2_breakdown.search_ms < 2000 and
    .metric_v2_breakdown.missing_events == 500000 and
    .metric_v2_breakdown.null_events == 1000000
' <<<"$million_result" >/dev/null

printf '%s\n' "$result"
printf '%s\n' "$million_result"
echo "typed property real-HTTP and on-disk DuckDB checks passed"
