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
command -v caddy >/dev/null
command -v openssl >/dev/null

fixture=$(mktemp -d /tmp/analytico-x67.XXXXXX)
server_pid=
caddy_pid=
cleanup() {
    if [[ -n "$caddy_pid" ]] && kill -0 "$caddy_pid" 2>/dev/null; then
        kill -TERM "$caddy_pid" 2>/dev/null || true
        wait "$caddy_pid" 2>/dev/null || true
    fi
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT

server_port=$((50500 + ($$ % 300)))
proxy_port=$((50900 + ($$ % 300)))
site_port=$((51300 + ($$ % 300)))
secure_site_port=$((51700 + ($$ % 300)))
upstream="http://127.0.0.1:$server_port"
dashboard="http://localhost:$proxy_port"
self_origin="http://127.0.0.2:$site_port"
ephemeral_origin="http://127.0.0.4:$site_port"
prerender_origin="http://127.0.0.5:$site_port"
real_prerender_origin="https://prerender.test:$secure_site_port"
data="$fixture/data"
today=$(date -u +%F)

"$binary" init "$data" >/dev/null
"$binary" site add "$data" self "self fixture" "$self_origin" \
    --timezone UTC >/dev/null
"$binary" site add "$data" ephemeral "ephemeral fixture" "$ephemeral_origin" \
    --timezone UTC >/dev/null
"$binary" site add "$data" prerender "prerender fixture" "$prerender_origin" \
    --timezone UTC >/dev/null
"$binary" site origin-add "$data" self "http://127.0.0.3:$site_port" >/dev/null
"$binary" site add "$data" real-prerender "real prerender fixture" \
    "$real_prerender_origin" --timezone UTC >/dev/null
self_site=$("$binary" site list "$data" | awk -F '\t' '$1 == "self" { print $2 }')
ephemeral_site=$("$binary" site list "$data" | awk -F '\t' '$1 == "ephemeral" { print $2 }')
prerender_site=$("$binary" site list "$data" | awk -F '\t' '$1 == "prerender" { print $2 }')
real_prerender_site=$("$binary" site list "$data" |
    awk -F '\t' '$1 == "real-prerender" { print $2 }')
"$binary" auth configure "$data" "$dashboard" >/dev/null
setup_url=$("$binary" auth bootstrap "$data" --ttl 10m | sed -n '2p')

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

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$fixture/prerender.key" -out "$fixture/prerender.crt" \
    -subj '/CN=prerender.test' \
    -addext 'subjectAltName=DNS:prerender.test' \
    >"$fixture/openssl.stdout" 2>"$fixture/openssl.stderr"
{
    printf '{\n\tadmin off\n\tauto_https off\n}\n'
    sed -e "s|^analytics\\.example {|http://localhost:$proxy_port {|" \
        -e "s|127\\.0\\.0\\.1:4318|127.0.0.1:$server_port|" deploy/Caddyfile
    printf '\nhttps://prerender.test:%s {\n' "$secure_site_port"
    printf '\ttls %s %s\n' "$fixture/prerender.crt" "$fixture/prerender.key"
    printf '\t@collector path /tracker.bc506cfe.js /v2/event\n'
    printf '\thandle @collector {\n\t\treverse_proxy 127.0.0.1:%s {\n' "$server_port"
    printf '\t\t\theader_up X-Forwarded-For {http.request.remote.host}\n'
    printf '\t\t}\n\t}\n'
    printf '\thandle {\n\t\treverse_proxy 127.0.0.1:%s\n\t}\n}\n' "$site_port"
} >"$fixture/Caddyfile"
caddy validate --config "$fixture/Caddyfile" >"$fixture/caddy.validate" 2>&1
XDG_DATA_HOME="$fixture/caddy-data" XDG_CONFIG_HOME="$fixture/caddy-config" \
    caddy run --config "$fixture/Caddyfile" \
    >"$fixture/caddy.stdout" 2>"$fixture/caddy.stderr" &
caddy_pid=$!
for _ in {1..100}; do
    status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
        "$dashboard/admin" || true)
    [[ "$status" == 303 ]] && break
    sleep 0.02
done
if [[ "$status" != 303 ]]; then
    cat "$fixture/caddy.stderr" >&2
    exit 1
fi
curl --silent --fail "$dashboard/tracker.6de111c9.js" \
    --output "$fixture/tracker-old.js"
cmp "$fixture/tracker-old.js" src/http/tracker.6de111c9.min.js
curl --silent --fail "$dashboard/tracker.bc506cfe.js" \
    --output "$fixture/tracker-current.js"
cmp "$fixture/tracker-current.js" src/http/tracker.min.js

cookie_file="$fixture/session.cookie"
TMPDIR="$fixture" NODE_PATH="$module_root" \
    PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
    ANALYTICO_CHROMIUM_PATH="$chromium_path" \
    node tests/e2e-passkey-session.cjs \
    "$dashboard" "$setup_url" "$cookie_file"
session_token=$(<"$cookie_file")
TMPDIR="$fixture" NODE_PATH="$module_root" \
    PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
    ANALYTICO_CHROMIUM_PATH="$chromium_path" \
    node tests/e2e-exclusion-browser.cjs \
    "$dashboard" "$session_token" "$dashboard" \
    "$self_site" "$ephemeral_site" "$prerender_site" \
    "$real_prerender_site" "$real_prerender_origin" "$site_port" \
    >"$fixture/browser.json"
jq -e '
    .engine == "chromium" and
    .self.first_party_flag_set_and_cleared and
    (.self.excluded_event_ids | length) == 3 and
    .localhost.requests == 0 and .localhost.storage_entries == 0 and
    .simulated_prerender_api_path.never_activated_requests == 0 and
    .real_prerender.activation_start_positive and
    .real_prerender.candidate_executed_while_prerendering and
    .real_prerender.activated_speculative_request and
    .real_prerender.never_activated_speculative_request and
    .real_prerender.never_candidate_remained_unactivated and
    .ephemeral.page_loads == 2
' "$fixture/browser.json" >/dev/null

page="$fixture/admin.html"
cookie="analytico_session=$session_token"
curl --silent --fail --cookie "$cookie" \
    "$dashboard/admin/sites/self/settings/general?from=$today&to=$today&compare=previous" >"$page"
csrf=$(grep -Eo 'name="csrf" value="[A-Za-z0-9_-]{43}"' "$page" |
    head -1 | cut -d '"' -f 4)
test "${#csrf}" = 43
status=$(curl --silent --output "$fixture/network-add.txt" \
    --write-out '%{http_code}' --cookie "$cookie" \
    -X POST "$dashboard/admin/exclusions/networks" \
    -H "Origin: $dashboard" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "csrf=$csrf" --data-urlencode 'site=self' \
    --data-urlencode "from=$today" --data-urlencode "to=$today" \
    --data-urlencode 'compare=previous' \
    --data-urlencode 'network=203.0.113.9')
test "$status" = 303

send_v2() {
    local event_id=$1
    local anonymous_id=$2
    local session_id=$3
    local self_excluded=$4
    local path=$5
    local now_ms
    now_ms=$(date -u +%s%3N)
    local optional=
    if [[ "$self_excluded" == true ]]; then
        optional=',"self_excluded":true'
    fi
    local body
    body=$(printf '{"v":2,"site":"%s","event_id":"%s","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":0,"occurred_at_ms":%s%s,"type":"pageview","page":{"path":"%s","title":"Fixture","hostname":"127.0.0.2"}}' \
        "$self_site" "$event_id" "$anonymous_id" "$session_id" \
        "$now_ms" "$optional" "$path")
    test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
        -X POST "$upstream/v2/event" -H "Origin: $self_origin" \
        -H 'X-Forwarded-For: 203.0.113.9' \
        -H 'User-Agent: Mozilla/5.0 Chrome/151.0' \
        -H 'Content-Type: text/plain' --data-binary "$body")" = 204
}

send_excluded_identify() {
    local now_ms
    now_ms=$(date -u +%s%3N)
    local body
    body=$(printf '{"v":2,"site":"%s","event_id":"%s","anonymous_id":"%s","identity_quality":"persistent","session_id":"%s","sequence":0,"occurred_at_ms":%s,"self_excluded":true,"type":"identify","page":{"path":"/account","title":"Account","hostname":"127.0.0.2"},"user":{"id":"operator","traits":{"role":"owner"}}}' \
        "$self_site" "$identify_event" "$identify_anon" \
        "$identify_session" "$now_ms")
    test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
        -X POST "$upstream/v2/event" -H "Origin: $self_origin" \
        -H 'X-Forwarded-For: 198.51.100.9' \
        -H 'User-Agent: Mozilla/5.0 Chrome/151.0' \
        -H 'Content-Type: text/plain' --data-binary "$body")" = 204
}

network_event='00000000-0000-4000-8000-000000000671'
network_anon='00000000-0000-4000-8000-000000000672'
network_session='00000000-0000-4000-8000-000000000673'
both_event='00000000-0000-4000-8000-000000000674'
both_anon='00000000-0000-4000-8000-000000000675'
both_session='00000000-0000-4000-8000-000000000676'
send_v2 "$network_event" "$network_anon" "$network_session" false /network
send_v2 "$both_event" "$both_anon" "$both_session" true /both
status=$(curl --silent --output "$fixture/network-delete.txt" \
    --write-out '%{http_code}' --cookie "$cookie" \
    -X POST "$dashboard/admin/exclusions/networks/delete" \
    -H "Origin: $dashboard" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "csrf=$csrf" --data-urlencode 'site=self' \
    --data-urlencode "from=$today" --data-urlencode "to=$today" \
    --data-urlencode 'compare=previous' \
    --data-urlencode 'network=203.0.113.0/24')
test "$status" = 303
identify_event='00000000-0000-4000-8000-000000000680'
identify_anon='00000000-0000-4000-8000-000000000681'
identify_session='00000000-0000-4000-8000-000000000682'
send_excluded_identify
included_event='00000000-0000-4000-8000-000000000677'
included_anon=$identify_anon
included_session='00000000-0000-4000-8000-000000000679'
send_v2 "$included_event" "$included_anon" "$included_session" false /included-network
kill -TERM "$caddy_pid"
wait "$caddy_pid"
caddy_pid=
kill -TERM "$server_pid"
wait "$server_pid"
server_pid=

ephemeral_overview=$("$binary" report "$data" ephemeral "$today" "$today" \
    overview --format json)
jq -e '.page_views == 2 and .visitor_days == 1 and .sessions == 2' \
    <<<"$ephemeral_overview" >/dev/null
prerender_overview=$("$binary" report "$data" prerender "$today" "$today" \
    overview --format json)
jq -e '.page_views == 1 and .visitor_days == 1 and .sessions == 1' \
    <<<"$prerender_overview" >/dev/null
real_prerender_overview=$("$binary" report "$data" real-prerender \
    "$today" "$today" overview --format json)
jq -e '.page_views == 1 and .visitor_days == 1 and .sessions == 1' \
    <<<"$real_prerender_overview" >/dev/null
real_prerender_quality=$("$binary" report "$data" real-prerender \
    "$today" "$today" traffic-quality --format json)
jq -e '
    .traffic_classes == [
      {"class":"human-presumed","events":1},
      {"class":"declared-bot","events":0},
      {"class":"automation","events":0},
      {"class":"excluded","events":0},
      {"class":"suspected","events":0}
    ] and
    .signal_evidence.client_signal_v1_events == 1 and
    .signal_evidence.webdriver_events == 0 and
    .signal_evidence.visible_events == 1 and
    .signal_evidence.prerendered_events == 1
' <<<"$real_prerender_quality" >/dev/null
self_overview=$("$binary" report "$data" self "$today" "$today" \
    overview --format json)
jq -e '.page_views == 2 and .visitor_days == 2 and .sessions == 2' \
    <<<"$self_overview" >/dev/null
self_quality=$("$binary" report "$data" self "$today" "$today" \
    traffic-quality --format json)
jq -e '
    .exclusion_sources == [
      {"source":"tracker","events":4},
      {"source":"network","events":1},
      {"source":"both","events":1}
    ]
' <<<"$self_quality" >/dev/null
network_row=$("$binary" m2 v2-inspect "$data" "$self_site" "$network_event")
jq -e '
    .traffic_class == 4 and .classifier_version == 1 and
    .bot_rule == "exclude.network"
' <<<"$network_row" >/dev/null
both_row=$("$binary" m2 v2-inspect "$data" "$self_site" "$both_event")
jq -e '
    .traffic_class == 4 and .classifier_version == 1 and
    .bot_rule == "exclude.both"
' <<<"$both_row" >/dev/null
included_row=$("$binary" m2 v2-inspect "$data" "$self_site" "$included_event")
jq -e '
    .traffic_class == 1 and .classifier_version == 2 and .bot_rule == ""
' <<<"$included_row" >/dev/null
test "$("$binary" m2 identity-links "$data")" = 0
person=$("$binary" m2 person-inspect "$data" "$self_site" "$identify_anon")
jq -e --arg key "a:$identify_anon" '
    .canonical_key == $key and .user_id == "" and
    .latest_traits_json == "{}" and .linked_anonymous_ids == 0
' <<<"$person" >/dev/null
if grep -aF '203.0.113.9' "$data/meta.db" "$data/events.duckdb" \
    "$fixture/server.stdout" "$fixture/server.stderr" >/dev/null; then
    echo "observed raw IP was persisted or logged" >&2
    exit 1
fi
test "$("$binary" doctor "$data")" = \
    "ok metadata=v10 events=v7 sites=4 goals=0 funnels=0 stored_events=12 key=ok"
grep -Fq '"accepted":12' "$fixture/server.stderr"
grep -Fq '"excluded":6' "$fixture/server.stderr"

cat "$fixture/browser.json"
printf '%s\n' "$self_quality"
echo "stored self-exclusion real-browser and live-policy checks passed"
