#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <source-binary> <dist-directory>" >&2
    exit 2
fi

source_binary=$1
dist=$2
case "$source_binary" in
    /*) ;;
    *) source_binary="$PWD/$source_binary" ;;
esac
case "$dist" in
    /*) ;;
    *) dist="$PWD/$dist" ;;
esac

module_root=${ANALYTICO_PLAYWRIGHT_NODE_PATH:-"$PWD/.zig-cache/playwright-node/node_modules"}
browser_root=${PLAYWRIGHT_BROWSERS_PATH:-"$PWD/.zig-cache/ms-playwright"}
chromium_path=${ANALYTICO_CHROMIUM_PATH:-"$browser_root/chromium-1234/chrome-linux64/chrome"}
if [[ ! -d "$module_root/playwright" || ! -x "$chromium_path" ]]; then
    echo "browser fixture missing; run tests/setup-browser-e2e.sh" >&2
    exit 2
fi

version=$("$source_binary" version)
version=${version#analytico }
name="analytico-$version-linux-x86_64"
archive="$dist/$name.tar.gz"
test -f "$archive"
(cd "$dist" && sha256sum -c "$name.tar.gz.sha256")

mkdir -p .zig-cache
fixture=$(mktemp -d "$PWD/.zig-cache/m5-cutover.XXXXXX")
collector_pid=
cleanup() {
    if [[ -n "$collector_pid" ]] && kill -0 "$collector_pid" 2>/dev/null; then
        kill -TERM "$collector_pid" 2>/dev/null || true
        wait "$collector_pid" 2>/dev/null || true
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT
tar --same-permissions -xzf "$archive" -C "$fixture"
release_root="$fixture/$name"
binary="$release_root/bin/analytico"

collector_port=$((41000 + ($$ % 1000)))
fixture_port=$((43000 + ($$ % 1000)))
collector="http://127.0.0.1:$collector_port"
fixture_origin="http://127.0.0.1:$fixture_port"
data="$fixture/data"
"$binary" init "$data" >/dev/null
"$binary" site add "$data" cutover Cutover "$fixture_origin" >/dev/null
"$binary" site property-add "$data" cutover plan >/dev/null
"$binary" goal add "$data" cutover signup event signup >/dev/null
"$binary" funnel add "$data" cutover journey \
    path=/landing path=/pricing event=signup >/dev/null
site_id=$("$binary" site list "$data" |
    awk -F '\t' '$1 == "cutover" { print $2 }')

snippet=$("$binary" site install "$data" cutover "$collector")
[[ "$snippet" == *\
'src="'"$collector"'/tracker.aef65945.js" data-site="'"$site_id"'"'* ]]
[[ "$snippet" == *$'CSP merge:\n  script-src '"$collector"$'\n  connect-src '"$collector"$'\n  img-src '"$collector" ]]

"$binary" serve --listen "127.0.0.1:$collector_port" \
    --meta "$data/meta.db" \
    --events "$data/events.duckdb" \
    --temp "$data/tmp" \
    --visitor-key-file "$data/visitor.key" \
    >"$fixture/collector.stdout" 2>"$fixture/collector.stderr" &
collector_pid=$!
for _ in {1..100}; do
    curl --silent --fail "$collector/readyz" >/dev/null 2>&1 && break
    sleep 0.02
done
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "$collector/readyz")" = 200

TMPDIR="$fixture" NODE_PATH="$module_root" \
    PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
    ANALYTICO_CHROMIUM_PATH="$chromium_path" \
    node tests/e2e-m5-browser.cjs "$collector" "$site_id" "$fixture_port" \
    >"$fixture/browser.json"
grep -q '"accepted_events":3' "$fixture/browser.json"
grep -q '"csp":"enforced"' "$fixture/browser.json"

collector_rss_kib=$(awk '$1 == "VmRSS:" { print $2 }' \
    "/proc/$collector_pid/status")
collector_cpu_ticks=$(awk '{ print $14 + $15 }' \
    "/proc/$collector_pid/stat")
clock_ticks=$(getconf CLK_TCK)
data_bytes=$(du --bytes --summarize "$data" | awk '{ print $1 }')

kill -TERM "$collector_pid"
wait "$collector_pid"
collector_pid=
test "$("$binary" doctor "$data")" = \
    "ok metadata=v1 events=v2 sites=1 goals=1 funnels=1 stored_events=3 key=ok"

today=$(date -u +%F)
report_json() {
    "$binary" report "$data" cutover "$today" "$today" "$@" --format json
}
test "$(report_json overview)" = \
    '{"metric_version":1,"site":"cutover","start_date":"'"$today"'","end_date":"'"$today"'","report":"overview","page_views":2,"visitor_days":1,"sessions":1,"custom_events":1,"bot_events":0}'
[[ "$(report_json pages)" == *'"path":"/landing","page_views":1'* ]]
[[ "$(report_json pages)" == *'"path":"/pricing","page_views":1'* ]]
[[ "$(report_json entries)" == *'"path":"/landing","sessions":1'* ]]
[[ "$(report_json exits)" == *'"path":"/pricing","sessions":1'* ]]
[[ "$(report_json sources)" == *'"source":"search.example","sessions":1'* ]]
[[ "$(report_json campaigns source)" == *\
'"utm_source":"newsletter","sessions":1'* ]]
[[ "$(report_json countries)" == *'"country":"Unknown","sessions":1'* ]]
[[ "$(report_json browsers)" == *'"browser":"Chrome","sessions":1'* ]]
[[ "$(report_json operating-systems)" == *\
'"operating_system":"Linux","sessions":1'* ]]
[[ "$(report_json devices)" == *'"device":"desktop","sessions":1'* ]]
[[ "$(report_json events)" == *\
'"event":"signup","event_count":1,"sessions":1'* ]]
[[ "$(report_json goal signup)" == *\
'"total_matches":1,"matching_sessions":1,"eligible_sessions":1,"conversion_rate":1.000000'* ]]
funnel=$(report_json funnel journey)
[[ "$funnel" == *'"eligible_sessions":1'* ]]
test "$(printf '%s' "$funnel" | grep -o '"sessions":1' | wc -l)" = 3

for report in overview pages entries exits sources countries browsers \
    operating-systems devices events
do
    "$binary" report "$data" cutover "$today" "$today" "$report" \
        --format table >"$fixture/$report.table"
    test -s "$fixture/$report.table"
done
"$binary" report "$data" cutover "$today" "$today" campaigns source \
    --format table >"$fixture/campaigns.table"
"$binary" report "$data" cutover "$today" "$today" goal signup \
    --format table >"$fixture/goal.table"
"$binary" report "$data" cutover "$today" "$today" funnel journey \
    --format table >"$fixture/funnel.table"

backup="$fixture/backup"
restored="$fixture/restored"
"$binary" backup "$data" "$backup" >/dev/null
"$binary" restore "$backup" "$restored" --verify >/dev/null
test "$("$binary" doctor "$restored")" = \
    "ok metadata=v1 events=v2 sites=1 goals=1 funnels=1 stored_events=3 key=ok"
test "$("$binary" report "$restored" cutover "$today" "$today" \
    overview --format json)" = "$(report_json overview)"

grep -Fq '/opt/analytico/bin/analytico' \
    "$release_root/deploy/analytico.service"
grep -Fq '/var/lib/analytico/visitor.key' \
    "$release_root/deploy/analytico.service"
grep -Fq '/var/lib/analytico/visitor.key' \
    "$release_root/docs/OPERATIONS.md"
grep -Fq '/tracker.aef65945.js' "$release_root/deploy/Caddyfile"
grep -Fq '/v1/p.gif' "$release_root/deploy/Caddyfile"

cat "$fixture/browser.json"
printf '{"collector_rss_kib":%s,"collector_cpu_ticks":%s,' \
    "$collector_rss_kib" "$collector_cpu_ticks"
printf '"clock_ticks_per_second":%s,"fresh_data_bytes":%s}\n' \
    "$clock_ticks" "$data_bytes"
echo "M5 extracted-release browser cutover and every report family passed"
