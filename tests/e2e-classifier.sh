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
    local client_hint=${5-}
    local accept_language=${6-}
    local event_id="00000000-0000-4000-8000-0000000001$suffix"
    local anonymous_id="00000000-0000-4000-8000-0000000002$suffix"
    local session_id="00000000-0000-4000-8000-0000000003$suffix"
    local body
    body=$(printf '{"v":2,"site":"%s","event_id":"%s","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":0,"occurred_at_ms":%s,%s"type":"pageview","page":{"path":"%s","hostname":"classifier.example"}}' \
        "$site_id" "$event_id" "$anonymous_id" "$session_id" "$occurred_ms" \
        "$extra" "$path")
    local headers=()
    if [[ -n "$client_hint" ]]; then
        headers+=(-H "Sec-CH-UA: $client_hint")
    fi
    if [[ -n "$accept_language" ]]; then
        headers+=(-H "Accept-Language: $accept_language")
    fi
    curl --silent --output /dev/null --write-out '%{http_code}' \
        -X POST "$base/v2/event" \
        -H 'Content-Type: text/plain' \
        -H 'Origin: https://classifier.example' \
        -H 'X-Forwarded-For: 198.51.100.42' \
        -H "User-Agent: $user_agent" \
        "${headers[@]}" \
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
webdriver_signals='"signals":{"v":1,"webdriver":true,"trusted_interactions":0,"was_visible":false,"was_prerendered":false,"viewport_bucket":3,"beacon_timing_bucket":2},'
human_signals='"signals":{"v":1,"webdriver":false,"trusted_interactions":5,"was_visible":true,"was_prerendered":true,"viewport_bucket":4,"beacon_timing_bucket":3},'
invalid_signals='"signals":{"v":1,"webdriver":false,"trusted_interactions":16,"was_visible":true,"was_prerendered":false,"viewport_bucket":4,"beacon_timing_bucket":3},'
unknown_signals='"signals":{"v":1,"webdriver":false,"trusted_interactions":0,"was_visible":true,"was_prerendered":false,"viewport_bucket":4,"beacon_timing_bucket":3,"raw_width":1280},'
test "$(send_event 12 'Mozilla/5.0 Chrome/140.0 Safari/537.36' \
    /webdriver "$webdriver_signals" '"Chromium";v="140"')" = 204
test "$(send_event 13 'Mozilla/5.0 Chrome/140.0 Safari/537.36' \
    /hint-mismatch '' '"Firefox";v="140"')" = 204
test "$(send_event 14 'Mozilla/5.0 Firefox/140.0' \
    /trusted "$human_signals" '' 'de-DE,de;q=0.9')" = 204
test "$(send_event 15 'Mozilla/5.0 Firefox/140.0' \
    /signals-out-of-range "$invalid_signals")" = 400
test "$(send_event 16 'Mozilla/5.0 Chrome/140.0 Safari/537.36' \
    /signals-absent '' '"Chromium";v="140"')" = 204
test "$(send_event 19 'Mozilla/5.0 Firefox/140.0' \
    /signals-unknown "$unknown_signals")" = 400

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

# A present signal bundle participates in the payload digest: an exact replay
# remains idempotent, while changing only one signal conflicts.
test "$(send_event 12 'Mozilla/5.0 Chrome/140.0 Safari/537.36' \
    /webdriver "$webdriver_signals" '"Chromium";v="140"')" = 204
changed_webdriver_signals='"signals":{"v":1,"webdriver":false,"trusted_interactions":0,"was_visible":false,"was_prerendered":false,"viewport_bucket":3,"beacon_timing_bucket":2},'
test "$(send_event 12 'Mozilla/5.0 Chrome/140.0 Safari/537.36' \
    /webdriver "$changed_webdriver_signals" '"Chromium";v="140"')" = 409

kill -TERM "$server_pid"
wait "$server_pid"
server_pid=
stopped=$(jq -c 'select(.code == "serve_stopped")' "$fixture/server.stderr")
jq -e '
    .accepted == 14 and .duplicates == 2 and .conflicts == 2 and
    .excluded == 1 and .bots == 9 and
    (has("legacy_bot_positive") | not) and
    (has("shadow_both_human") | not)
' <<<"$stopped" >/dev/null

inspect() {
    "$binary" m2 v2-inspect "$data" "$site_id" \
        "00000000-0000-4000-8000-0000000001$1"
}
jq -e '
    .traffic_class == 1 and .classifier_version == 2 and .bot_rule == "" and
    .device_category == "mobile" and .client_hint_consistency == 3
' <<<"$(inspect 02)" >/dev/null
jq -e '
    .traffic_class == 3 and .classifier_version == 2 and
    .bot_rule == "client.curl"
' <<<"$(inspect 03)" >/dev/null
jq -e '
    .traffic_class == 2 and .classifier_version == 2 and
    .bot_rule == "crawler.google" and
    .device_category != "bot"
' <<<"$(inspect 04)" >/dev/null
jq -e '
    .traffic_class == 2 and .classifier_version == 2 and
    .bot_rule == "ua.empty"
' <<<"$(inspect 05)" >/dev/null
jq -e '
    .traffic_class == 1 and .classifier_version == 2 and .bot_rule == ""
' <<<"$(inspect 06)" >/dev/null
jq -e '
    .traffic_class == 1 and .classifier_version == 2 and .bot_rule == ""
' <<<"$(inspect 07)" >/dev/null
jq -e '
    .traffic_class == 3 and .bot_rule == "monitor.uptimerobot" and
    .classifier_version == 2
' <<<"$(inspect 08)" >/dev/null
jq -e '
    .traffic_class == 4 and .classifier_version == 1 and
    .bot_rule == "exclude.tracker" and
    .session_start == false
' <<<"$(inspect 09)" >/dev/null
jq -e '
    .traffic_class == 1 and .classifier_version == 2 and .bot_rule == "" and
    .signals.version == 0
' <<<"$(inspect 10)" >/dev/null
jq -e '
    .traffic_class == 3 and .classifier_version == 2 and
    .bot_rule == "signal.webdriver" and
    .signals == {
      "version":1,
      "navigator_webdriver":true,
      "trusted_interactions":0,
      "was_visible":false,
      "was_prerendered":false,
      "viewport_bucket":3,
      "beacon_timing_bucket":2
    } and .client_hint_consistency == 1 and
    .accept_language_present == false
' <<<"$(inspect 12)" >/dev/null
jq -e '
    .traffic_class == 3 and .classifier_version == 2 and
    .bot_rule == "signal.client-hint-mismatch" and
    .signals.version == 0 and .client_hint_consistency == 2
' <<<"$(inspect 13)" >/dev/null
jq -e '
    .traffic_class == 1 and .classifier_version == 2 and .bot_rule == "" and
    .signals.trusted_interactions == 5 and .signals.was_visible and
    .signals.was_prerendered and .accept_language_present
' <<<"$(inspect 14)" >/dev/null
jq -e '
    .traffic_class == 1 and .classifier_version == 2 and .bot_rule == "" and
    .signals.version == 0 and .client_hint_consistency == 1
' <<<"$(inspect 16)" >/dev/null

today=$(date --utc +%F)
overview=$("$binary" report "$data" classifier "$today" "$today" \
    overview --format json)
jq -e '
    .page_views == 7 and .visitor_days == 7 and .sessions == 7 and
    .bot_events == 6
' <<<"$overview" >/dev/null
quality=$("$binary" report "$data" classifier "$today" "$today" \
    traffic-quality --format json)
jq -e '
    .traffic_classes == [
      {"class":"human-presumed","events":7},
      {"class":"declared-bot","events":2},
      {"class":"automation","events":4},
      {"class":"excluded","events":1},
      {"class":"suspected","events":0}
    ] and
    .signal_evidence == {
      "client_signal_v1_events":2,
      "webdriver_events":1,
      "trusted_interaction_events":1,
      "visible_events":1,
      "prerendered_events":1,
      "client_hint_mismatch_events":1,
      "client_hint_absent_expected_events":1,
      "accept_language_present_events":1
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
    -e 'curl/8.12.1' -e '"Chromium";v="140"' \
    -e '"Firefox";v="140"' -e 'de-DE,de;q=0.9' \
    "$data/events.duckdb" "$fixture/server.stdout" \
    "$fixture/server.stderr" >/dev/null; then
    echo "raw User-Agent was persisted or logged" >&2
    exit 1
fi
test "$("$binary" doctor "$data")" = \
    "ok metadata=v10 events=v7 sites=1 goals=0 funnels=0 stored_events=14 key=ok"

printf '%s\n' "$quality"
echo "classifier v2 real-loopback, bounded-signal, and serve-counter checks passed"
