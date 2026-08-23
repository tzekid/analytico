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

data="$fixture/data"
"$binary" init "$data" >/dev/null
"$binary" site add "$data" classifier Classifier https://classifier.example \
    --timezone UTC >/dev/null
site_id=$("$binary" site list "$data" |
    awk -F '\t' '$1 == "classifier" { print $2 }')
port=$((48500 + ($$ % 500)))
base="http://127.0.0.1:$port"
"$binary" serve --listen "127.0.0.1:$port" \
    --meta "$data/meta.db" \
    --events "$data/events.duckdb" \
    --temp "$data/tmp" \
    --visitor-key-file "$data/visitor.key" \
    >"$fixture/server.stdout" 2>"$fixture/server.stderr" &
server_pid=$!
for _ in {1..100}; do
    curl --silent --fail "$base/readyz" >/dev/null 2>&1 && break
    sleep 0.02
done
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "$base/readyz")" = 200

occurred_ms=$(date +%s%3N)
send_event() {
    local suffix=$1
    local user_agent=$2
    local path=$3
    local extra=$4
    local event_id="00000000-0000-4000-8000-0000000001$suffix"
    local anonymous_id="00000000-0000-4000-8000-0000000002$suffix"
    local session_id="00000000-0000-4000-8000-0000000003$suffix"
    local body
    body=$(printf '{"v":2,"site":"%s","event_id":"%s","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":0,"occurred_at_ms":%s,%s"type":"pageview","page":{"path":"%s","hostname":"classifier.example"}}' \
        "$site_id" "$event_id" "$anonymous_id" "$session_id" "$occurred_ms" \
        "$extra" "$path")
    curl --silent --output /dev/null --write-out '%{http_code}' \
        -X POST "$base/v2/event" \
        -H 'Content-Type: text/plain' \
        -H 'Origin: https://classifier.example' \
        -H 'X-Forwarded-For: 198.51.100.42' \
        -H "User-Agent: $user_agent" \
        --data-binary "$body"
}

test "$(send_event 01 'Mozilla/5.0 Safari/605.1.15' /human '')" = 204
test "$(send_event 02 'Mozilla/5.0 (Linux; Android 14; Cubot X70) AppleWebKit Chrome/120 Mobile' /cubot '')" = 204
test "$(send_event 03 'curl/8.12.1' /curl '')" = 204
test "$(send_event 04 'Googlebot/2.1' /googlebot '')" = 204
test "$(send_event 05 '' /empty '')" = 204
test "$(send_event 06 'NotGooglebotLike' /embedded-google '')" = 204
test "$(send_event 07 'MyUptimeRobotTool' /embedded-monitor '')" = 204
test "$(send_event 08 'UptimeRobot/2.0' /monitor '')" = 204
test "$(send_event 09 'Googlebot/2.1' /excluded '"self_excluded":true,')" = 204
ua_1024=$(printf '%1024s' '' | tr ' ' X)
ua_1025=$(printf '%1025s' '' | tr ' ' X)
test "$(send_event 10 "$ua_1024" /ua-limit '')" = 204
test "$(send_event 11 "$ua_1025" /ua-too-long '')" = 400

# First receipt owns classification. The changed-UA replay is a duplicate;
# changed payload conflicts. Neither enters inserted shadow counters.
test "$(send_event 01 'curl/99.0' /human '')" = 204
conflict_body=$(printf '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000101","anonymous_id":"00000000-0000-4000-8000-000000000201","identity_quality":"persistent","session_id":"00000000-0000-4000-8000-000000000301","sequence":0,"occurred_at_ms":%s,"type":"pageview","page":{"path":"/changed","hostname":"classifier.example"}}' \
    "$site_id" "$occurred_ms")
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    -X POST "$base/v2/event" \
    -H 'Content-Type: text/plain' \
    -H 'Origin: https://classifier.example' \
    -H 'X-Forwarded-For: 198.51.100.42' \
    -H 'User-Agent: Mozilla/5.0 Safari/605.1.15' \
    --data-binary "$conflict_body")" = 409

kill -TERM "$server_pid"
wait "$server_pid"
server_pid=
stopped=$(jq -c 'select(.code == "serve_stopped")' "$fixture/server.stderr")
jq -e '
    .accepted == 10 and .duplicates == 1 and .conflicts == 1 and
    .excluded == 1 and .bots == 6 and
    .legacy_bot_positive == 5 and .classifier_bot_positive == 4 and
    .shadow_both_human == 2 and .shadow_legacy_only == 3 and
    .shadow_classifier_only == 2 and .shadow_both_bot == 2
' <<<"$stopped" >/dev/null

inspect() {
    "$binary" m2 v2-inspect "$data" "$site_id" \
        "00000000-0000-4000-8000-0000000001$1"
}
jq -e '
    .traffic_class == 1 and .classifier_version == 1 and .bot_rule == "" and
    .legacy_bot_verdict == true and .device_category == "mobile"
' <<<"$(inspect 02)" >/dev/null
jq -e '
    .traffic_class == 3 and .classifier_version == 1 and
    .bot_rule == "client.curl" and .legacy_bot_verdict == false
' <<<"$(inspect 03)" >/dev/null
jq -e '
    .traffic_class == 2 and .classifier_version == 1 and
    .bot_rule == "crawler.google" and .legacy_bot_verdict == true and
    .device_category != "bot"
' <<<"$(inspect 04)" >/dev/null
jq -e '
    .traffic_class == 2 and .classifier_version == 1 and
    .bot_rule == "ua.empty" and .legacy_bot_verdict == false
' <<<"$(inspect 05)" >/dev/null
jq -e '
    .traffic_class == 1 and .bot_rule == "" and .legacy_bot_verdict == true
' <<<"$(inspect 06)" >/dev/null
jq -e '
    .traffic_class == 1 and .bot_rule == "" and .legacy_bot_verdict == true
' <<<"$(inspect 07)" >/dev/null
jq -e '
    .traffic_class == 3 and .bot_rule == "monitor.uptimerobot" and
    .legacy_bot_verdict == true
' <<<"$(inspect 08)" >/dev/null
jq -e '
    .traffic_class == 4 and .classifier_version == 1 and
    .bot_rule == "exclude.tracker" and .legacy_bot_verdict == false and
    .session_start == false
' <<<"$(inspect 09)" >/dev/null
jq -e '
    .traffic_class == 1 and .classifier_version == 1 and .bot_rule == "" and
    .legacy_bot_verdict == false
' <<<"$(inspect 10)" >/dev/null

today=$(date --utc +%F)
overview=$("$binary" report "$data" classifier "$today" "$today" \
    overview --format json)
jq -e '
    .page_views == 4 and .visitor_days == 4 and .sessions == 4 and
    .bot_events == 5
' <<<"$overview" >/dev/null
quality=$("$binary" report "$data" classifier "$today" "$today" \
    traffic-quality --format json)
jq -e '
    .traffic_classes == [
      {"class":"human-presumed","events":5},
      {"class":"declared-bot","events":2},
      {"class":"automation","events":2},
      {"class":"excluded","events":1},
      {"class":"suspected","events":0}
    ] and
    .classifier_v1_events == 9 and
    .shadow == {
      "both_human":2,
      "legacy_only":3,
      "classifier_only":2,
      "both_bot":2
    } and
    ([.classifier_rules[] |
      select(.rule == "exclude.tracker") | .events] == [1]) and
    ([.classifier_rules[] |
      select(.rule == "client.curl") | .events] == [1]) and
    .exclusion_sources == [
      {"source":"tracker","events":1},
      {"source":"network","events":0},
      {"source":"both","events":0}
    ]
' <<<"$quality" >/dev/null

if grep -aF -e 'NotGooglebotLike' -e 'MyUptimeRobotTool' -e 'Googlebot/2.1' \
    -e 'curl/8.12.1' "$data/events.duckdb" "$fixture/server.stdout" \
    "$fixture/server.stderr" >/dev/null; then
    echo "raw User-Agent was persisted or logged" >&2
    exit 1
fi
test "$("$binary" doctor "$data")" = \
    "ok metadata=v4 events=v5 sites=1 goals=0 funnels=0 stored_events=10 key=ok"

printf '%s\n' "$quality"
echo "UA classifier v1 real-loopback, stored shadow, and serve-counter checks passed"
