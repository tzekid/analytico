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
browser_image='mcr.microsoft.com/playwright@sha256:baed2032d533817f3dbe6425de795788430ba345e819a1201337009ba17c9d07'
if [[ ! -d "$module_root/playwright" ]]; then
    echo "browser fixture missing; run tests/setup-browser-e2e.sh" >&2
    exit 2
fi

fixture=$(mktemp -d "$PWD/.zig-cache/tracker-browser.XXXXXX")
collector_pid=
collector_port=$((49000 + ($$ % 500)))
fixture_port=$((50000 + ($$ % 500)))
collector="http://127.0.0.1:$collector_port"
cleanup() {
    if [[ -n "$collector_pid" ]] && kill -0 "$collector_pid" 2>/dev/null; then
        kill -TERM "$collector_pid" 2>/dev/null || true
        wait "$collector_pid" 2>/dev/null || true
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT

"$binary" init "$fixture" >/dev/null
"$binary" site add "$fixture" tracker "Tracker browser" \
    "http://127.0.0.2:$fixture_port" --timezone UTC >/dev/null
site=$("$binary" site list "$fixture" |
    awk -F '\t' '$1 == "tracker" { print $2 }')

"$binary" serve --listen "127.0.0.1:$collector_port" \
    --meta "$fixture/meta.db" \
    --events "$fixture/events.duckdb" \
    --temp "$fixture/tmp" \
    --visitor-key-file "$fixture/visitor.key" \
    >"$fixture/server.stdout" 2>"$fixture/server.stderr" &
collector_pid=$!
ready=false
for _ in {1..100}; do
    if curl --silent --fail "$collector/readyz" >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 0.02
done
test "$ready" = true

if command -v docker >/dev/null 2>&1 &&
    docker image inspect "$browser_image" >/dev/null 2>&1
then
    docker run --rm --network host --ipc host \
        --volume "$PWD/tests:/work/tests:ro" \
        --volume "$module_root:/work/node_modules:ro" \
        --env NODE_PATH=/work/node_modules \
        --env PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
        "$browser_image" \
        node /work/tests/e2e-tracker-browser.cjs \
        "$collector" "$site" "$fixture_port" \
        >"$fixture/browser-result.json"
else
    if [[ ! -d "$browser_root" ]]; then
        echo "browser binaries missing; run tests/setup-browser-e2e.sh" >&2
        exit 2
    fi
    TMPDIR="$fixture" NODE_PATH="$module_root" \
        PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
        ANALYTICO_CHROMIUM_PATH="$chromium_path" \
        node tests/e2e-tracker-browser.cjs \
        "$collector" "$site" "$fixture_port" \
        >"$fixture/browser-result.json"
fi

jq -e '
    .engine == "chromium" and
    .spa.pageviews == 4 and
    .engagement.hidden_network_events == 0 and
    .engagement.idle_network_events == 0 and
    (.engagement.active_window_events >= 1 and
      .engagement.active_window_events <= 4) and
    .automatic.automatic_opt_in_only and
    .automatic.form_values_absent and
    .automatic.requests == 6 and .automatic.disabled_requests == 1 and
    .signals.trusted_interactions == 7
' "$fixture/browser-result.json" >/dev/null

kill -TERM "$collector_pid"
wait "$collector_pid" 2>/dev/null || true
collector_pid=

inspect() {
    local result_key=$1
    local event_id
    event_id=$(jq -r "$result_key" "$fixture/browser-result.json")
    "$binary" m2 v2-inspect "$fixture" "$site" "$event_id"
}

first_engagement=$(inspect '.engagement.first')
scrolled_engagement=$(inspect '.engagement.scrolled')
resumed_engagement=$(inspect '.engagement.resumed')
lifecycle_engagement=$(inspect '.engagement.lifecycle')
download=$(inspect '.automatic.download')
form=$(inspect '.automatic.form')
purchase=$(inspect '.automatic.purchase')
automation_signal=$(inspect '.signals.automation')
human_signal=$(inspect '.signals.human')

jq -e '
    .kind == 3 and .event_name == "engagement" and
    .engagement_ms >= 14900 and .engagement_ms <= 15100 and
    .max_scroll_depth >= 0 and .max_scroll_depth <= 100
' <<<"$first_engagement" >/dev/null
jq -e '
    .kind == 3 and .engagement_ms >= 14900 and .engagement_ms <= 15100 and
    .max_scroll_depth == 100
' <<<"$scrolled_engagement" >/dev/null
jq -e '
    .kind == 3 and .engagement_ms >= 14900 and .engagement_ms <= 15100 and
    .max_scroll_depth == 100
' <<<"$resumed_engagement" >/dev/null
jq -e '
    .kind == 3 and .engagement_ms >= 4900 and .engagement_ms <= 5100 and
    .max_scroll_depth == 100
' <<<"$lifecycle_engagement" >/dev/null
jq -e '
    .kind == 2 and .event_name == "file_download" and
    .properties_json == "{\"extension\":\"pdf\",\"url_path\":\"/files/report.pdf\"}"
' <<<"$download" >/dev/null
jq -e '
    .kind == 2 and .event_name == "form_submit" and
    .properties_json == "{\"action_host\":\"forms.example\",\"action_path\":\"/submit\",\"form_id\":\"signup\"}"
' <<<"$form" >/dev/null
jq -e '
    .kind == 2 and .event_name == "purchase" and
    .properties_json == "{\"plan\":\"pro\"}" and
    .value_amount == "49.000000" and .value_currency == "EUR"
' <<<"$purchase" >/dev/null
jq -e '
    .traffic_class == 3 and .classifier_version == 2 and
    .bot_rule == "signal.webdriver" and
    .signals.version == 1 and .signals.navigator_webdriver and
    .signals.trusted_interactions == 0 and .signals.was_visible and
    (.signals.viewport_bucket == 4)
' <<<"$automation_signal" >/dev/null
jq -e '
    .traffic_class == 1 and .classifier_version == 2 and .bot_rule == "" and
    .signals.version == 1 and (.signals.navigator_webdriver | not) and
    .signals.trusted_interactions == 7 and
    .signals.was_visible and (.signals.was_prerendered | not)
' <<<"$human_signal" >/dev/null

doctor=$("$binary" doctor "$fixture")
[[ "$doctor" == ok\ metadata=v7\ events=v7\ sites=1\ goals=0\ funnels=0\ stored_events=*\ key=ok ]]
stored_events=$(sed -n 's/.*stored_events=\([0-9][0-9]*\).*/\1/p' <<<"$doctor")
expected_events=$(jq -r .stored_events_expected "$fixture/browser-result.json")
if [[ "$stored_events" != "$expected_events" ]]; then
    echo "stored event count mismatch: doctor=$stored_events browser=$expected_events" >&2
    exit 1
fi
test "$("$binary" m2 identity-links "$fixture")" = 0
if grep -aE '(supersecret|password|token=secret)' \
    "$fixture/events.duckdb" "$fixture/server.stdout" \
    "$fixture/server.stderr" >/dev/null
then
    echo "automatic tracker fixture leaked a field value or query" >&2
    exit 1
fi

cmp public/tracker.js src/http/tracker.min.js
cmp public/tracker.js.br src/http/tracker.min.js.br
cmp public/tracker.js.gz src/http/tracker.min.js.gz
brotli --test public/tracker.js.br
gzip --test public/tracker.js.gz
test "$(stat -c '%s' public/tracker.js)" -le 8192
test "$(stat -c '%s' public/tracker.js.br)" -le 5120
test "$(sha256sum public/tracker.js | cut -d' ' -f1)" = \
    "bc506cfe6ffe27f1004d62a5552cd9ca095d5d2fc1da87d1457130eab99f8a19"
test "$(sha256sum public/tracker.js.br | cut -d' ' -f1)" = \
    "71503963d3dd7ddacc05882e82bb5ef81e3aa714d605f342400f3924628c8fd3"
test "$(sha256sum public/tracker.js.gz | cut -d' ' -f1)" = \
    "d19eeddb6fb30589ba95602be21a6b46c3167685a49b83fa89592613b517d8d9"
test "$(sha256sum src/http/tracker.6de111c9.min.js | cut -d' ' -f1)" = \
    "6de111c93fb57ccef475d7716e1eff1f1eaa1367b6135d4c8910bb74ead141a6"
test "$(sha256sum src/http/tracker.d9e94247.min.js | cut -d' ' -f1)" = \
    "d9e94247f97fa84795f5a9bb493a0d383b2aac11565e80e6ceb670b4e9e05c2c"
if grep -aE '(document\.cookie|FormData|innerHTML|XMLHttpRequest|import\()' \
    public/tracker.js >/dev/null
then
    echo "tracker contains a forbidden browser mechanism" >&2
    exit 1
fi

cat "$fixture/browser-result.json"
printf '{"tracker_raw_bytes":%s,"tracker_brotli_bytes":%s,"tracker_gzip_bytes":%s}\n' \
    "$(stat -c '%s' public/tracker.js)" \
    "$(stat -c '%s' public/tracker.js.br)" \
    "$(stat -c '%s' public/tracker.js.gz)"
echo "tracker SPA, engagement, automatic event, value, and real signal checks passed"
