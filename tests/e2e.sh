#!/usr/bin/env bash
set -euo pipefail

app=$1
journey_root=$(mktemp -d)
data_dir=$journey_root/data
port=$((24000 + $$ % 10000))
server_pid=

cleanup() {
  if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
    kill -TERM "$server_pid"
    wait "$server_pid" || true
  fi
  rm -rf "$journey_root"
}
trap cleanup EXIT

"$app" init "$data_dir"
site_output=$("$app" site add example https://example.test --mode session --data "$data_dir")
public_id=$(printf '%s\n' "$site_output" | sed -n 's/.*public_id=\([^ ]*\).*/\1/p')
internal_secret=$(printf '%s\n' "$site_output" | sed -n 's/^internal_secret=//p')
test -n "$public_id"
test -n "$internal_secret"
"$app" campaign spend-add example "$(date -u +%F)" search launch hero 1000 EUR --data "$data_dir" >/dev/null
"$app" goal add example registration-start event registration_started --data "$data_dir" >/dev/null
"$app" goal add example paid event payment_confirmed --data "$data_dir" >/dev/null
"$app" funnel add example registration-to-paid registration-start paid --data "$data_dir" >/dev/null

"$app" serve --data "$data_dir" --listen "127.0.0.1:$port" >"$journey_root/server.log" 2>&1 &
server_pid=$!
for attempt in 1 2 3 4 5; do
  if curl --fail --silent "http://127.0.0.1:$port/readyz" >/dev/null; then break; fi
  sleep 1
done
curl --fail --silent "http://127.0.0.1:$port/readyz" | grep -q ready
snippet=$("$app" site snippet example "http://127.0.0.1:$port" --rum --data "$data_dir")
asset_url=$(printf '%s\n' "$snippet" | sed -n 's/.*src="\([^"]*\)".*/\1/p')
test -n "$asset_url"
curl --fail --silent "$asset_url" > "$journey_root/tracker.js"
node --check "$journey_root/tracker.js"

now_ms=$(date +%s%3N)
browser_body=$(printf '{"v":1,"site":"%s","sent_at_ms":%s,"records":[{"event_id":"550e8400-e29b-41d4-a716-446655440000","type":"page_view","page_id":"550e8400-e29b-41d4-a716-446655440001","session_id":"550e8400-e29b-41d4-a716-446655440002","occurred_at_ms":%s,"tracking_mode":"session","consent_mode":"analytics","tracker_version":"1","release_id":"test","internal":false,"path":"/landing","page_type":"landing","utm_source":"search","utm_campaign":"launch","utm_content":"hero","navigation_type":"navigate","viewport_class":"desktop","language":"en"},{"event_id":"550e8400-e29b-41d4-a716-446655440003","type":"event","page_id":"550e8400-e29b-41d4-a716-446655440001","session_id":"550e8400-e29b-41d4-a716-446655440002","occurred_at_ms":%s,"tracking_mode":"session","consent_mode":"analytics","tracker_version":"1","release_id":"test","internal":false,"name":"registration_started","path":"/register","properties":{"flow":"registration"}},{"event_id":"550e8400-e29b-41d4-a716-446655440006","type":"event","page_id":"550e8400-e29b-41d4-a716-446655440001","session_id":"550e8400-e29b-41d4-a716-446655440002","occurred_at_ms":%s,"tracking_mode":"session","consent_mode":"analytics","tracker_version":"1","release_id":"test","internal":false,"name":"flow_started","path":"/register","properties":{"flow":"registration","step":"start"}},{"event_id":"550e8400-e29b-41d4-a716-446655440004","type":"page_summary","page_id":"550e8400-e29b-41d4-a716-446655440001","session_id":"550e8400-e29b-41d4-a716-446655440002","occurred_at_ms":%s,"tracking_mode":"session","consent_mode":"analytics","tracker_version":"1","release_id":"test","internal":false,"visible_ms":12000,"active_ms":10000,"interaction_count":2,"max_scroll":75,"sections":["hero"],"last_section":"hero","selection_count":0,"copy_count":0,"outbound_clicks":0,"downloads":0,"form_attempts":1,"lcp_ms":500}]}' "$public_id" "$now_ms" "$now_ms" "$now_ms" "$now_ms" "$now_ms")

missing_client=$(curl --silent -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/e" \
  -H 'Origin: https://example.test' -H 'Content-Type: text/plain;charset=UTF-8' --data-binary "$browser_body")
test "$missing_client" = 400
curl --fail --silent -o /dev/null -X POST "http://127.0.0.1:$port/e" \
  -H 'Origin: https://example.test' -H 'X-Forwarded-For: 198.51.100.10' \
  -H 'Content-Type: text/plain;charset=UTF-8' --data-binary "$browser_body"
curl --fail --silent -o /dev/null -X POST "http://127.0.0.1:$port/e" \
  -H 'Origin: https://example.test' -H 'X-Forwarded-For: 198.51.100.10' \
  -H 'Content-Type: text/plain;charset=UTF-8' --data-binary "$browser_body"
denied=$(curl --silent -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/e" \
  -H 'Origin: https://denied.test' -H 'X-Forwarded-For: 198.51.100.10' \
  -H 'Content-Type: text/plain;charset=UTF-8' --data-binary "$browser_body")
test "$denied" = 403
conflict_body=$(printf '%s' "$browser_body" | sed 's#/landing#/changed#')
conflict=$(curl --silent -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/e" \
  -H 'Origin: https://example.test' -H 'X-Forwarded-For: 198.51.100.10' \
  -H 'Content-Type: text/plain;charset=UTF-8' --data-binary "$conflict_body")
test "$conflict" = 409

now_s=$(date +%s)
now_ms=$(date +%s%3N)
server_body=$(printf '{"v":1,"site":"%s","sent_at_ms":%s,"records":[{"event_id":"550e8400-e29b-41d4-a716-446655440005","type":"event","session_id":"550e8400-e29b-41d4-a716-446655440002","occurred_at_ms":%s,"tracking_mode":"session","consent_mode":"server","tracker_version":"backend-1","release_id":"test","internal":false,"name":"payment_confirmed","value_minor":4900,"currency":"EUR","properties":{"source":"search","campaign":"launch","content":"hero"}}]}' "$public_id" "$now_ms" "$now_ms")
signature=$(printf '%s.%s' "$now_s" "$server_body" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$internal_secret" | awk '{print $2}')
curl --fail --silent -o /dev/null -X POST "http://127.0.0.1:$port/i" \
  -H 'Content-Type: application/json' -H "X-Analytico-Timestamp: $now_s" \
  -H "X-Analytico-Signature: $signature" --data-binary "$server_body"

"$app" report overview example --days 7 --data "$data_dir" | grep -q $'1\t1\t1\t3\t10000\t1'
"$app" report traffic example --days 7 --data "$data_dir" | grep -q $'human_like\t0\t1\t1'
"$app" report performance example --days 7 --data "$data_dir" | grep -q $'lcp\t1\t500\t500\t500'
"$app" session show example 550e8400-e29b-41d4-a716-446655440002 --data "$data_dir" | grep -q registration_started
"$app" report flow example registration --days 7 --data "$data_dir" | grep -q flow_started
"$app" funnel show example registration-to-paid --days 7 --data "$data_dir" | grep -q $'2\tevent\tpayment_confirmed\t1'
"$app" report campaign-economics example --days 7 --data "$data_dir" | grep -q $'search\tlaunch\thero\t1000\tEUR\t1\t1\t1\t0\t1\t0\t0\t4900'
node tests/reports.mjs "$app" "$data_dir"
"$app" stats --data "$data_dir" | grep -q $'duplicate_records\t4'
"$app" backup "$data_dir" "$journey_root/backup.db"

kill -TERM "$server_pid"
wait "$server_pid"
server_pid=
grep -q serve_stopped "$journey_root/server.log"

"$app" restore "$journey_root/backup.db" "$journey_root/restored"
"$app" doctor --data "$journey_root/restored" | grep -q 'page_views=1 summaries=1 events=3'

node tests/browser.mjs "$app"
printf 'e2e ok\n'
