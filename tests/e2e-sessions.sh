#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: e2e-sessions.sh <analytico-binary>" >&2
    exit 2
fi

binary=$1
module_root=${ANALYTICO_PLAYWRIGHT_NODE_MODULES:-"$PWD/.zig-cache/playwright-node/node_modules"}
browser_root=${PLAYWRIGHT_BROWSERS_PATH:-"$PWD/.zig-cache/ms-playwright"}
chromium_path=${ANALYTICO_CHROMIUM_PATH:-"$browser_root/chromium-1234/chrome-linux64/chrome"}
caddyfile=${ANALYTICO_CADDYFILE:-deploy/Caddyfile}
if [[ ! -d "$module_root/playwright" || ! -x "$chromium_path" ]]; then
    echo "browser fixture missing; run tests/setup-browser-e2e.sh" >&2
    exit 2
fi
command -v caddy >/dev/null
command -v jq >/dev/null
command -v sqlite3 >/dev/null
test -f "$caddyfile"

fixture=$(mktemp -d "$PWD/.zig-cache/sessions-e2e.XXXXXX")
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
        sed -n '1,260p' "$fixture/server.stderr" >&2 || true
        sed -n '1,120p' "$fixture/caddy.stderr" >&2 || true
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT

server_port=${ANALYTICO_TEST_SERVER_PORT:-$((14000 + ($$ % 200)))}
proxy_port=${ANALYTICO_TEST_PROXY_PORT:-$((14200 + ($$ % 200)))}
upstream="http://127.0.0.1:$server_port"
dashboard="http://localhost:$proxy_port"
data="$fixture/data"

"$binary" init "$data" >/dev/null
"$binary" analysis traffic-quality-seed "$data" >/dev/null
quality_id=$("$binary" site list "$data" |
    awk -F '\t' '$1 == "quality" { print $2 }')
test "${#quality_id}" = 36
"$binary" m3 sessions-fixture "$data" "$quality_id" >/dev/null
goal_output=$("$binary" goal add "$data" quality Purchases event purchase)
goal_id=${goal_output##* }
segment_id=00000000-0000-4000-8000-000000000492
sqlite3 "$data/meta.db" <<SQL
INSERT INTO segments
  (id, site_id, name, filter_schema_version, canonical_filter_json,
   created_at_utc_micros, updated_at_utc_micros)
VALUES
  ('$segment_id', '$quality_id', 'Germany', 1,
   '{"schema":1,"match":"all","filters":["event~country~is~string~DE"]}',
   100, 100);
SQL
"$binary" site add "$data" beta Beta https://beta.example \
    --timezone Europe/Berlin >/dev/null
"$binary" event add "$data" beta pageview /beta-secret \
    1767398400000000 2026-01-03 203.0.113.77 Safari macOS desktop >/dev/null
today=$(date -u +%F)
now_micros="$(date -u +%s)000000"
"$binary" event add "$data" quality pageview /current \
    "$now_micros" "$today" 203.0.113.78 Chrome Linux desktop >/dev/null

"$binary" auth configure "$data" "$dashboard" >/dev/null
setup_url=$("$binary" auth bootstrap "$data" --ttl 10m | sed -n '2p')

start_server() {
    : >"$fixture/server.stdout"
    : >"$fixture/server.stderr"
    "$binary" serve --listen "127.0.0.1:$server_port" \
        --meta "$data/meta.db" --events "$data/events.duckdb" \
        --temp "$data/tmp" --visitor-key-file "$data/visitor.key" \
        >"$fixture/server.stdout" 2>"$fixture/server.stderr" &
    server_pid=$!
    for _ in {1..100}; do
        curl --silent --fail "$upstream/readyz" >/dev/null 2>&1 && break
        sleep 0.02
    done
    curl --silent --fail "$upstream/readyz" >/dev/null
}

stop_server() {
    kill -TERM "$server_pid"
    wait "$server_pid"
    server_pid=
}

start_server
{
    printf '{\n\tadmin off\n}\n'
    sed \
        -e "s|^analytics\.example {|http://localhost:$proxy_port {|" \
        -e "s|127\.0\.0\.1:4318|127.0.0.1:$server_port|" \
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

unauthenticated_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "$dashboard/admin/sites/quality/sessions?v=1&from=2026-01-03&to=2026-01-03&compare=none")
test "$unauthenticated_status" = 303
sessions_page="$dashboard/admin/sites/quality/sessions?v=1&from=2026-01-03&to=2026-01-04&compare=none"
curl --silent --fail --cookie "$cookie" "$sessions_page" \
    >"$fixture/sessions.html"
test "$(grep -o 'class="session-record"' "$fixture/sessions.html" | wc -l)" = 25
sessions_gzip_bytes=$(gzip --stdout "$fixture/sessions.html" | wc -c)
test "$sessions_gzip_bytes" -le 32768
rss_initial=$(awk '$1 == "VmRSS:" { print $2 }' "/proc/$server_pid/status")
for _ in {1..600}; do
    curl --silent --fail --cookie "$cookie" "$sessions_page" >/dev/null
done
rss_before=$(awk '$1 == "VmRSS:" { print $2 }' "/proc/$server_pid/status")
rss_warmup_growth_kib=$((rss_before - rss_initial))
rss_previous=$rss_before
rss_cohort_growth_kib=()
for cohort in 1 2 3; do
    for _ in {1..200}; do
        curl --silent --fail --cookie "$cookie" "$sessions_page" >/dev/null
    done
    rss_current=$(awk '$1 == "VmRSS:" { print $2 }' "/proc/$server_pid/status")
    rss_cohort_growth_kib+=("$((rss_current - rss_previous))")
    rss_previous=$rss_current
done
rss_total_growth_kib=$((${rss_cohort_growth_kib[0]} + \
    ${rss_cohort_growth_kib[1]} + ${rss_cohort_growth_kib[2]}))
rss_average_200_growth_kib=$((rss_total_growth_kib / 3))
printf 'sessions RSS warmup_600_growth_kib=%s cohort_1_200_growth_kib=%s cohort_2_200_growth_kib=%s cohort_3_200_growth_kib=%s total_600_growth_kib=%s average_200_growth_kib=%s\n' \
    "$rss_warmup_growth_kib" "${rss_cohort_growth_kib[0]}" \
    "${rss_cohort_growth_kib[1]}" "${rss_cohort_growth_kib[2]}" \
    "$rss_total_growth_kib" "$rss_average_200_growth_kib" >&2
test "$rss_average_200_growth_kib" -le 8192

profile_anonymous_a=00000000-0000-4000-8000-000000000f01
profile_anonymous_b=00000000-0000-4000-8000-000000000f02
reset_anonymous=00000000-0000-4000-8000-000000000f03
profile_session_a=00000000-0000-4000-8000-000000000f11
profile_session_b=00000000-0000-4000-8000-000000000f12
reset_session=00000000-0000-4000-8000-000000000f13
profile_user='user/A+雪'
profile_user_path='u%3Auser%2FA%2B%E9%9B%AA'
profile_occurred_ms=$(date -u +%s%3N)
profile_event_index=0
send_profile_event() {
    local expected=$1
    local body=$2
    local status
    profile_event_index=$((profile_event_index + 1))
    status=$(curl --silent --output "$fixture/profile-event-$profile_event_index.body" \
        --dump-header "$fixture/profile-event-$profile_event_index.headers" \
        --write-out '%{http_code}' -X POST "$dashboard/v2/event" \
        -H 'Content-Type: text/plain' -H 'Origin: https://quality.example' \
        -H 'User-Agent: Mozilla/5.0 Chrome/139.0.0.0 Safari/537.36' \
        -H 'Accept-Language: en-US,en;q=0.9' \
        --data-binary "$body")
    test "$status" = "$expected"
}

send_profile_event 204 "$(printf \
    '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000f21","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":0,"occurred_at_ms":%s,"type":"pageview","page":{"path":"/profile-start","title":"Profile start","hostname":"quality.example"}}' \
    "$quality_id" "$profile_anonymous_a" "$profile_session_a" "$profile_occurred_ms")"
profile_purchase_body=$(printf \
    '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000f22","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":1,"occurred_at_ms":%s,"type":"event","name":"purchase","page":{"path":"/profile-start","title":"Profile start","hostname":"quality.example"},"properties":{"plan":"team","note":"<img src=x onerror=alert(1)>"},"value":{"amount":"19.99","currency":"USD"}}' \
    "$quality_id" "$profile_anonymous_a" "$profile_session_a" "$((profile_occurred_ms + 1))")
send_profile_event 204 "$profile_purchase_body"
send_profile_event 204 "$profile_purchase_body"
for engagement in '2 5000 40 0f23' '3 7000 80 0f24'; do
    read -r sequence active_ms scroll suffix <<<"$engagement"
    send_profile_event 204 "$(printf \
        '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-00000000%s","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":%s,"occurred_at_ms":%s,"type":"engagement","page":{"path":"/profile-start","title":"Profile start","hostname":"quality.example"},"engagement":{"active_ms":%s,"max_scroll_depth":%s}}' \
        "$quality_id" "$suffix" "$profile_anonymous_a" "$profile_session_a" \
        "$sequence" "$((profile_occurred_ms + sequence))" "$active_ms" "$scroll")"
done
send_profile_event 204 "$(printf \
    '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000f25","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":4,"occurred_at_ms":%s,"type":"identify","page":{"path":"/account","title":"Account","hostname":"quality.example"},"user":{"id":"%s","traits":{"plan":"team","device":"primary"}}}' \
    "$quality_id" "$profile_anonymous_a" "$profile_session_a" \
    "$((profile_occurred_ms + 4))" "$profile_user")"
send_profile_event 204 "$(printf \
    '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000f26","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":5,"occurred_at_ms":%s,"type":"pageview","page":{"path":"/profile-start","title":"Profile revisit","hostname":"quality.example"}}' \
    "$quality_id" "$profile_anonymous_a" "$profile_session_a" "$((profile_occurred_ms + 5))")"
send_profile_event 204 "$(printf \
    '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000f27","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":6,"occurred_at_ms":%s,"type":"engagement","page":{"path":"/profile-start","title":"Profile revisit","hostname":"quality.example"},"engagement":{"active_ms":3000,"max_scroll_depth":25}}' \
    "$quality_id" "$profile_anonymous_a" "$profile_session_a" "$((profile_occurred_ms + 6))")"
send_profile_event 204 "$(printf \
    '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000f28","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":0,"occurred_at_ms":%s,"type":"pageview","page":{"path":"/second-device","title":"Second device","hostname":"quality.example"}}' \
    "$quality_id" "$profile_anonymous_b" "$profile_session_b" "$((profile_occurred_ms + 7))")"
send_profile_event 204 "$(printf \
    '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000f29","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":1,"occurred_at_ms":%s,"type":"identify","page":{"path":"/account","title":"Account","hostname":"quality.example"},"user":{"id":"%s","traits":{"plan":"team","device":"secondary","nickname":"<script>bad</script>"}}}' \
    "$quality_id" "$profile_anonymous_b" "$profile_session_b" \
    "$((profile_occurred_ms + 8))" "$profile_user")"
send_profile_event 204 "$(printf \
    '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000f30","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":0,"occurred_at_ms":%s,"type":"pageview","page":{"path":"/reset-separated","title":"Reset separation","hostname":"quality.example"}}' \
    "$quality_id" "$reset_anonymous" "$reset_session" "$((profile_occurred_ms + 9))")"
send_profile_event 204 "$(printf \
    '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000f33","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":1,"occurred_at_ms":%s,"type":"identify","page":{"path":"/reset-separated","title":"Reset separation","hostname":"quality.example"},"user":{"id":"second-user","traits":{"plan":"separate"}}}' \
    "$quality_id" "$reset_anonymous" "$reset_session" "$((profile_occurred_ms + 10))")"
send_profile_event 204 "$(printf \
    '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000f32","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":7,"occurred_at_ms":%s,"type":"event","name":"late-arrival","page":{"path":"/profile-start","title":"Profile start","hostname":"quality.example"},"properties":{"arrival":"late"}}' \
    "$quality_id" "$profile_anonymous_a" "$profile_session_a" "$((profile_occurred_ms + 1))")"
send_profile_event 409 "$(printf \
    '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-000000000f31","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":8,"occurred_at_ms":%s,"type":"identify","user":{"id":"rejected-user"}}' \
    "$quality_id" "$profile_anonymous_a" "$profile_session_a" "$((profile_occurred_ms + 11))")"
grep -qi '^X-Analytico-Code: identity_conflict' \
    "$fixture/profile-event-$profile_event_index.headers"

stop_server
grep -Fq '"duplicates":1' "$fixture/server.stderr"
start_server

TMPDIR=/tmp NODE_PATH="$module_root" \
    PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
    ANALYTICO_CHROMIUM_PATH="$chromium_path" \
    node tests/e2e-sessions-browser.cjs "$dashboard" "$session_cookie" \
    "$goal_id" "$segment_id" "$today" "$profile_user_path" \
    "$fixture/sessions-desktop.png" "$fixture/sessions-mobile.png" \
    "$fixture/session-detail-desktop.png" "$fixture/profile-mobile.png" \
    >"$fixture/browser.json"
cat "$fixture/browser.json"
jq -e '
    .js_off_full_summary and .goal_filter_native and
    .date_context_preserved and .universal_filter_native and
    .person_filter_native and
    .segment_native and .stable_pagination and .timeline_pagination and
    .current_session and
    .detail_native and .detail_context_mutation_preserved and
    .profile_native and .identity_conflict_not_merged and
    .duplicate_idempotent and
    .per_visit_engagement and .encoded_profile_route and .reset_separation and
    .incompatible_profiles_omitted and
    .site_isolation and .startup_data_requests == 0 and
    .mobile_width == 390 and .mobile_overflow == false and .keyboard_focus
' "$fixture/browser.json" >/dev/null
test -s "$fixture/sessions-desktop.png"
test -s "$fixture/sessions-mobile.png"
test -s "$fixture/session-detail-desktop.png"
test -s "$fixture/profile-mobile.png"

heavy_detail="$dashboard/admin/sites/quality/sessions/42000000-0000-4000-8000-000000000000?v=1&from=2026-01-03&to=2026-01-04&compare=none&page=2"
curl --silent --fail --cookie "$cookie" "$heavy_detail" \
    >"$fixture/heavy-detail.html"
test "$(grep -o 'class="session-timeline"' "$fixture/heavy-detail.html" | wc -l)" = 1
heavy_detail_gzip_bytes=$(gzip --stdout "$fixture/heavy-detail.html" | wc -c)
test "$heavy_detail_gzip_bytes" -le 32768
rich_detail="$dashboard/admin/sites/quality/sessions/$profile_session_a?v=1&from=$today&to=$today&compare=none"
rich_profile="$dashboard/admin/sites/quality/users/$profile_user_path?v=1&from=$today&to=$today&compare=none"
detail_profile_rss_cold=$(awk '$1 == "VmRSS:" { print $2 }' "/proc/$server_pid/status")
for _ in {1..300}; do
    curl --silent --fail --cookie "$cookie" "$rich_detail" >/dev/null
    curl --silent --fail --cookie "$cookie" "$rich_profile" >/dev/null
done
detail_profile_rss_previous=$(awk '$1 == "VmRSS:" { print $2 }' "/proc/$server_pid/status")
detail_profile_rss_warmup_kib=$((detail_profile_rss_previous - detail_profile_rss_cold))
detail_profile_rss_growth_kib=()
for cohort in 1 2 3; do
    for _ in {1..100}; do
        curl --silent --fail --cookie "$cookie" "$rich_detail" >/dev/null
        curl --silent --fail --cookie "$cookie" "$rich_profile" >/dev/null
    done
    detail_profile_rss_current=$(awk '$1 == "VmRSS:" { print $2 }' "/proc/$server_pid/status")
    detail_profile_rss_growth_kib+=("$((detail_profile_rss_current - detail_profile_rss_previous))")
    detail_profile_rss_previous=$detail_profile_rss_current
done
detail_profile_rss_total_kib=$((${detail_profile_rss_growth_kib[0]} + \
    ${detail_profile_rss_growth_kib[1]} + ${detail_profile_rss_growth_kib[2]}))
detail_profile_rss_average_kib=$((detail_profile_rss_total_kib / 3))
printf 'session detail/profile RSS warmup_600_growth_kib=%s cohort_1_200_growth_kib=%s cohort_2_200_growth_kib=%s cohort_3_200_growth_kib=%s total_600_growth_kib=%s average_200_growth_kib=%s\n' \
    "$detail_profile_rss_warmup_kib" "${detail_profile_rss_growth_kib[0]}" \
    "${detail_profile_rss_growth_kib[1]}" \
    "${detail_profile_rss_growth_kib[2]}" \
    "$detail_profile_rss_total_kib" "$detail_profile_rss_average_kib" >&2
test "$detail_profile_rss_average_kib" -le 8192

stop_server
while true; do
    precise_received_micros=$(date -u +%s%6N)
    precise_fraction=${precise_received_micros: -6}
    if ((10#$precise_fraction < 50000)); then
        break
    fi
    sleep 0.005
done
"$binary" event add "$data" quality pageview /current-micros \
    "$precise_received_micros" "$today" 198.51.100.79 Chrome Linux desktop \
    >/dev/null
start_server
persisted_detail="$dashboard/admin/sites/quality/sessions/$profile_session_a?v=1&from=$today&to=$today&compare=none"
curl --silent --fail --cookie "$cookie" "$persisted_detail" \
    >"$fixture/persisted-detail.html"
grep -Fq 'Profile start' "$fixture/persisted-detail.html"
grep -Fq 'Transport fragments combined' "$fixture/persisted-detail.html"
persisted_profile="$dashboard/admin/sites/quality/users/$profile_user_path?v=1&from=$today&to=$today&compare=none"
curl --silent --fail --cookie "$cookie" "$persisted_profile" \
    >"$fixture/persisted-profile.html"
grep -Fq 'Explicitly linked identity' "$fixture/persisted-profile.html"
grep -Fq 'secondary' "$fixture/persisted-profile.html"
if grep -Fq 'rejected-user' "$fixture/persisted-profile.html"; then
    echo "rejected identity conflict was merged into the retained profile" >&2
    exit 1
fi
precise_current_page="$dashboard/admin/sites/quality/sessions?v=1&from=$today&to=$today&compare=none"
curl --silent --fail --cookie "$cookie" "$precise_current_page" \
    >"$fixture/current-micros.html"
precise_request_finished_micros=$(date -u +%s%6N)
if [[ "${precise_received_micros:0:10}" != \
    "${precise_request_finished_micros:0:10}" ]]; then
    echo "same-second Sessions clock fixture crossed a UTC second" >&2
    exit 1
fi
if ! perl -0ne '
    while (m{<article class="session-record">.*?</article>}gs) {
        my $record = $&;
        if ($record =~ /Current · activity received within 30 minutes/ &&
            $record =~ m{/current-micros}) { exit 0 }
    }
    exit 1
' "$fixture/current-micros.html"; then
    echo "same-second Sessions record was not rendered Current" >&2
    grep -o 'Current · activity received within 30 minutes\|/current-micros' \
        "$fixture/current-micros.html" >&2 || true
    exit 1
fi

stale_filter_target="$dashboard/admin/sites/quality/sessions?v=1&from=2026-01-03&to=2026-01-03&compare=none&goal=$goal_id&f=event~event-property~missing~is~string~x"
stale_filter_status=$(curl --silent --output "$fixture/stale-filter.html" \
    --write-out '%{http_code}' --cookie "$cookie" "$stale_filter_target")
test "$stale_filter_status" = 422
grep -Fq 'Filter is stale' "$fixture/stale-filter.html"
grep -Fq "goal=$goal_id" "$fixture/stale-filter.html"
if grep -Fq 'event~event-property~missing~is~string~x' \
    "$fixture/stale-filter.html"; then
    echo "stale Sessions recovery retained the removed property filter" >&2
    exit 1
fi

stop_server
sqlite3 "$data/meta.db" <<SQL
DELETE FROM segments WHERE id = '$segment_id';
SQL
start_server
stale_segment_target="$dashboard/admin/sites/quality/sessions?v=1&from=2026-01-03&to=2026-01-03&compare=none&goal=$goal_id&segment=$segment_id"
stale_segment_status=$(curl --silent --output "$fixture/stale-segment.html" \
    --write-out '%{http_code}' --cookie "$cookie" "$stale_segment_target")
test "$stale_segment_status" = 422
grep -Fq 'Saved segment is stale' "$fixture/stale-segment.html"
grep -Fq "goal=$goal_id" "$fixture/stale-segment.html"
if grep -Fq "segment=$segment_id" "$fixture/stale-segment.html"; then
    echo "stale Sessions recovery retained the deleted segment" >&2
    exit 1
fi

stop_server
sqlite3 "$data/meta.db" <<SQL
UPDATE goal_definitions_v2
SET archived_at_utc_micros = updated_at_utc_micros + 1,
    updated_at_utc_micros = updated_at_utc_micros + 1
WHERE id = '$goal_id';
SQL
start_server
stale_target="$dashboard/admin/sites/quality/sessions?v=1&from=2026-01-03&to=2026-01-03&compare=none&goal=$goal_id"
stale_status=$(curl --silent --output "$fixture/stale-goal.html" \
    --write-out '%{http_code}' --cookie "$cookie" "$stale_target")
test "$stale_status" = 422
grep -Fq 'Selected goal is no longer active' "$fixture/stale-goal.html"
grep -Fq '/admin/sites/quality/sessions?v=1&amp;from=2026-01-03&amp;to=2026-01-03&amp;compare=none' \
    "$fixture/stale-goal.html"
if grep -Fq "goal=$goal_id" "$fixture/stale-goal.html"; then
    echo "stale Sessions recovery retained the archived Goal" >&2
    exit 1
fi
stop_server
kill -TERM "$caddy_pid"
wait "$caddy_pid"
caddy_pid=

scale="$fixture/scale"
"$binary" init "$scale" >/dev/null
"$binary" site add "$scale" scale Scale https://scale.example \
    --timezone UTC >/dev/null
scale_id=$("$binary" site list "$scale" |
    awk -F '\t' '$1 == "scale" { print $2 }')
"$binary" m3 million "$scale" "$scale_id" >/dev/null
"$binary" m3 sessions-scale-fixture "$scale" "$scale_id" >/dev/null
for index in $(seq -w 0 9); do
    "$binary" goal add "$scale" scale "Goal $index" event purchase >/dev/null
done

if ! "$binary" m3 sessions-list "$scale" scale 2025-01-01 2025-01-12 \
    >"$fixture/sessions-default.json"; then
    cat "$fixture/sessions-default.json"
    exit 1
fi
cat "$fixture/sessions-default.json"
jq -e '
    .strict_mode == false and .page_rows == 25 and .has_more and
    .detail_timeline_rows == 2 and (.detail_has_more | not) and
    .profile_retained_sessions == 2 and
    .profile_linked_anonymous_ids == 2 and .profile_context_rows == 2 and
    .anonymous_profile_retained_sessions == 1 and
    .anonymous_profile_context_rows == 1 and
    .anonymous_profile_linked_anonymous_ids == 0 and
    ((.performance_enforced == false and .p50_micros == null and
      .p95_micros == null and .p99_micros == null and
      .detail_p50_micros == null and .detail_p95_micros == null and
      .profile_micros == null) or
     (.performance_enforced and .p95_micros < 400000 and
      .detail_p95_micros < 250000 and .profile_micros < 2000000 and
      .p50_micros <= .p95_micros and .p95_micros <= .p99_micros and
      .timeout_interrupted and .detail_timeout_interrupted and
      .profile_timeout_interrupted and .connection_reused))
' "$fixture/sessions-default.json" >/dev/null
"$binary" m3 sessions-profile "$scale" scale 2025-01-01 2025-01-12 \
    >"$fixture/sessions-profile.txt"
grep -Fq 'SESSION KEY STATEMENT' "$fixture/sessions-profile.txt"
grep -Fq 'SESSION DETAIL STATEMENT' "$fixture/sessions-profile.txt"
grep -Fq 'SESSION DETAIL KEY STATEMENT' "$fixture/sessions-profile.txt"
grep -Fq 'SESSION TIMELINE STATEMENT' "$fixture/sessions-profile.txt"
grep -Fq 'PERSON RETAINED SUMMARY STATEMENT' "$fixture/sessions-profile.txt"
grep -Fq 'PERSON CONTEXT SESSION DETAIL STATEMENT' "$fixture/sessions-profile.txt"

"$binary" site traffic-policy "$scale" scale strict 10000000 >/dev/null
if ! "$binary" m3 sessions-list "$scale" scale 2025-01-01 2025-01-12 \
    >"$fixture/sessions-strict.json"; then
    cat "$fixture/sessions-strict.json"
    exit 1
fi
cat "$fixture/sessions-strict.json"
jq -e '
    .strict_mode and .page_rows == 25 and .has_more and
    .detail_timeline_rows == 2 and (.detail_has_more | not) and
    .profile_retained_sessions == 2 and
    .profile_linked_anonymous_ids == 2 and .profile_context_rows == 2 and
    .anonymous_profile_retained_sessions == 1 and
    .anonymous_profile_context_rows == 1 and
    .anonymous_profile_linked_anonymous_ids == 0 and
    ((.performance_enforced == false and .p50_micros == null and
      .p95_micros == null and .p99_micros == null and
      .detail_p50_micros == null and .detail_p95_micros == null and
      .profile_micros == null) or
     (.performance_enforced and .p95_micros < 400000 and
      .detail_p95_micros < 250000 and .profile_micros < 2000000 and
      .p50_micros <= .p95_micros and .p95_micros <= .p99_micros and
      .timeout_interrupted and .detail_timeout_interrupted and
      .profile_timeout_interrupted and .connection_reused))
' "$fixture/sessions-strict.json" >/dev/null
performance_evidence=$(jq -r '
    if .performance_enforced then "p95+timeout+reuse"
    else "deferred-to-ReleaseSafe"
    end
' "$fixture/sessions-strict.json")

printf 'sessions_e2e=pass browser=js-off+desktop+mobile rows=full-summary filters=event+session+person goal=active pagination=list+timeline stale-filter+segment+goal=422 current_clock=same-second-micros max_25_row_html_gzip_bytes=%s max_50_timeline_html_gzip_bytes=%s rss_warmup_growth_kib_after_600_views=%s rss_cohort_1_200_growth_kib=%s rss_cohort_2_200_growth_kib=%s rss_cohort_3_200_growth_kib=%s rss_total_600_growth_kib=%s rss_average_200_growth_kib=%s detail_profile_rss_warmup_600_growth_kib=%s detail_profile_rss_average_200_growth_kib=%s scale=1000000-events+100000-sessions goals=10 performance_evidence=%s\n' \
    "$sessions_gzip_bytes" "$heavy_detail_gzip_bytes" "$rss_warmup_growth_kib" \
    "${rss_cohort_growth_kib[0]}" "${rss_cohort_growth_kib[1]}" \
    "${rss_cohort_growth_kib[2]}" "$rss_total_growth_kib" \
    "$rss_average_200_growth_kib" "$detail_profile_rss_warmup_kib" \
    "$detail_profile_rss_average_kib" \
    "$performance_evidence"
