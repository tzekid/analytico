#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <analytico-binary>" >&2
    exit 2
fi

binary=$1
fixture=$(mktemp -d)
server_pid=
cleanup() {
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT

heuristics="$fixture/heuristics"
"$binary" init "$heuristics" >/dev/null
"$binary" analysis heuristics-seed "$heuristics" >/dev/null
quality=$("$binary" report "$heuristics" heuristics 2026-08-23 2026-08-23 \
    traffic-quality --format json)
jq -e '
    .traffic_quality_version == 5 and .heuristic_available == true and
    .raw_candidates == 5 and .current_suspected_sessions == 1 and
    .contradicted_candidates == 4 and .contradiction_basis_points == 8000 and
    .mint_anomaly_groups == 1 and .maximum_minted_identities == 65 and
    .days == [{"date":"2026-08-23","new_anonymous_identities":71,
      "bot_events":2,"suspected_sessions":1,"accepted_events":76,
      "mint_anomaly_groups":1,"maximum_minted_identities":65,
      "ceiling_reached":false}]
' <<<"$quality" >/dev/null

default_overview=$("$binary" report "$heuristics" heuristics \
    2026-08-23 2026-08-23 overview --format json)
jq -e '.page_views == 72 and .visitor_days == 72 and .sessions == 72 and
    .custom_events == 1 and .bot_events == 2' <<<"$default_overview" >/dev/null
test "$("$binary" analysis heuristics-check "$heuristics")" = \
    '{"metric_version":2,"default_page_views":72,"strict_page_views":71}'
"$binary" site traffic-policy "$heuristics" heuristics strict 100000 >/dev/null
strict_overview=$("$binary" report "$heuristics" heuristics \
    2026-08-23 2026-08-23 overview --format json)
jq -e '.page_views == 71 and .visitor_days == 71 and .sessions == 71 and
    .custom_events == 1 and .bot_events == 2' <<<"$strict_overview" >/dev/null
strict_pages=$("$binary" report "$heuristics" heuristics \
    2026-08-23 2026-08-23 pages --format json)
jq -e '([.rows[].path] | index("/candidate")) == null' \
    <<<"$strict_pages" >/dev/null
if grep -Eiq 'network_day_id|198\.51\.100|[[:xdigit:]]{32}' \
    <<<"$quality$default_overview$strict_overview$strict_pages"; then
    echo "heuristic reports exposed private network evidence" >&2
    exit 1
fi

cap="$fixture/cap"
"$binary" init "$cap" >/dev/null
"$binary" site add "$cap" cap Cap https://cap.example --timezone UTC >/dev/null
site_id=$("$binary" site list "$cap" | awk -F '\t' '$1 == "cap" { print $2 }')
"$binary" site traffic-policy "$cap" cap off 2 >/dev/null
port=$((48600 + ($$ % 500)))
base="http://127.0.0.1:$port"
"$binary" serve --listen "127.0.0.1:$port" \
    --meta "$cap/meta.db" --events "$cap/events.duckdb" --temp "$cap/tmp" \
    --visitor-key-file "$cap/visitor.key" \
    >"$cap/server.stdout" 2>"$cap/server.stderr" &
server_pid=$!
for _ in {1..100}; do
    curl --silent --fail "$base/readyz" >/dev/null 2>&1 && break
    sleep 0.02
done
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "$base/readyz")" = 200
occurred_ms=$(date +%s%3N)
send() {
    local suffix=$1
    local path=${2:-/cap-$suffix}
    local body
    body=$(printf '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-0000000008%s","anonymous_id":"00000000-0000-4000-8000-0000000009%s","identity_quality":"persistent","session_id":"00000000-0000-4000-8000-000000000a%s","sequence":0,"occurred_at_ms":%s,"type":"pageview","page":{"path":"%s","hostname":"cap.example"}}' \
        "$site_id" "$suffix" "$suffix" "$suffix" "$occurred_ms" "$path")
    curl --silent --output "$cap/body" --write-out '%{http_code}' \
        -X POST "$base/v2/event" -H 'Content-Type: text/plain' \
        -H 'Origin: https://cap.example' -H 'X-Forwarded-For: 198.51.100.42' \
        -H 'User-Agent: Mozilla/5.0 Firefox/140.0' \
        --data-binary "$body"
}
test "$(send 01)" = 204
test "$(send 02)" = 204
test "$(send 01)" = 204
test "$(send 01 /conflicting-replay)" = 409
test "$(send 03)" = 429
test "$(cat "$cap/body")" = "daily event ceiling reached"
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "$base/readyz")" = 200
kill -TERM "$server_pid"
wait "$server_pid"
server_pid=
stopped=$(jq -c 'select(.code == "serve_stopped")' "$cap/server.stderr")
jq -e '.accepted == 2 and .duplicates == 1 and .conflicts == 1 and
    .daily_ceiling_rejected == 1 and .write_failures == 0' \
    <<<"$stopped" >/dev/null
test "$("$binary" m2 identity-links "$cap")" = 0
today=$(date --utc +%F)
cap_quality=$("$binary" report "$cap" cap "$today" "$today" \
    traffic-quality --format json)
jq -e '.accepted_events == 2 and .ceiling_reached_days == 1 and
    .daily_event_ceiling == 2 and .days[0].accepted_events == 2 and
    .days[0].ceiling_reached == true and .maximum_minted_identities == 2' \
    <<<"$cap_quality" >/dev/null

echo "query heuristics, strict filtering, anomaly diagnostics, and daily cap passed"
