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
fixture_dir=$(mktemp -d "$PWD/.zig-cache/m3-bench.XXXXXX")
trap 'rm -rf -- "$fixture_dir"' EXIT

"$binary" init "$fixture_dir" >/dev/null
"$binary" site add "$fixture_dir" scale "Scale" https://scale.example \
    --timezone UTC >/dev/null
site_id=$("$binary" site list "$fixture_dir" |
    awk -F '\t' '$1 == "scale" { print $2 }')
"$binary" goal add "$fixture_dir" scale signups event signup >/dev/null
"$binary" funnel add "$fixture_dir" scale signup-flow \
    'path=/' 'path=/pricing' 'path=/docs' 'path=/features' \
    'path=/download' 'path=/install' 'path=/account' 'path=/checkout' \
    >/dev/null

seed_started=$(date +%s%N)
"$binary" m3 million "$fixture_dir" "$site_id" >/dev/null
seed_finished=$(date +%s%N)

measure() {
    local name=$1
    shift
    local started finished elapsed output
    started=$(date +%s%N)
    output=$("$@")
    finished=$(date +%s%N)
    elapsed=$(((finished - started) / 1000000))
    printf '"%s_ms":%d,' "$name" "$elapsed"
    printf '%s\n' "$output" >"$fixture_dir/$name.json"
}

measure_series() {
    local name=$1
    local samples=$2
    shift 2
    local started finished elapsed
    : >"$fixture_dir/$name.durations"
    for ((sample = 1; sample <= samples; sample++)); do
        started=$(date +%s%N)
        "$@" >"$fixture_dir/$name.json"
        finished=$(date +%s%N)
        elapsed=$(((finished - started) / 1000000))
        printf '%d\n' "$elapsed" >>"$fixture_dir/$name.durations"
    done
    mapfile -t sorted < <(sort -n "$fixture_dir/$name.durations")
    local p50=${sorted[$(((samples * 50 + 99) / 100 - 1))]}
    local p95=${sorted[$(((samples * 95 + 99) / 100 - 1))]}
    local p99=${sorted[$(((samples * 99 + 99) / 100 - 1))]}
    printf '"%s_samples":%d,' "$name" "$samples"
    printf '"%s_p50_ms":%d,' "$name" "$p50"
    printf '"%s_p95_ms":%d,' "$name" "$p95"
    printf '"%s_p99_ms":%d,' "$name" "$p99"
}

measure_overview_series() {
    local name=$1
    shift
    local started finished elapsed micros percentile
    started=$(date +%s%N)
    "$@" >"$fixture_dir/$name.json"
    finished=$(date +%s%N)
    elapsed=$(((finished - started) / 1000000))
    printf '"%s_process_ms":%d,' "$name" "$elapsed"
    printf '"%s_samples":%d,' "$name" \
        "$(jq -r '.query_samples' "$fixture_dir/$name.json")"
    for percentile in 50 95 99; do
        micros=$(jq -r ".query_p${percentile}_micros" \
            "$fixture_dir/$name.json")
        printf '"%s_server_p%s_ms":%d,' "$name" "$percentile" \
            "$(((micros + 999) / 1000))"
    done
}

"$binary" report "$fixture_dir" scale \
    2025-01-01 2025-01-12 overview --format json >/dev/null
"$binary" report "$fixture_dir" scale \
    2025-01-01 2025-01-12 funnel signup-flow --format json >/dev/null
"$binary" report "$fixture_dir" scale \
    2025-01-01 2025-01-12 traffic-quality --format json >/dev/null
"$binary" m3 traffic-quality-profile "$fixture_dir" scale \
    2025-01-01 2025-01-12 >"$fixture_dir/traffic-quality.profile"

printf '{'
printf '"events":1000000,'
printf '"seed_ms":%d,' "$(((seed_finished - seed_started) / 1000000))"
measure_overview_series overview_v2 "$binary" m3 overview-v2-series \
    "$fixture_dir" scale \
    2025-01-07 2025-01-12 2025-01-01 2025-01-06
measure_series overview 10 "$binary" report "$fixture_dir" scale \
    2025-01-01 2025-01-12 overview --format json
measure pages "$binary" report "$fixture_dir" scale \
    2025-01-01 2025-01-12 pages --format json
measure goal "$binary" report "$fixture_dir" scale \
    2025-01-01 2025-01-12 goal signups --format json
measure_series funnel 10 "$binary" report "$fixture_dir" scale \
    2025-01-01 2025-01-12 funnel signup-flow --format json
measure_series traffic_quality 10 "$binary" report "$fixture_dir" scale \
    2025-01-01 2025-01-12 traffic-quality --format json
"$binary" m3 overview-v2-profile "$fixture_dir" scale \
    2025-01-07 2025-01-12 2025-01-01 2025-01-06 \
    >"$fixture_dir/overview-v2.profile"
"$binary" site traffic-policy "$fixture_dir" scale strict 100000 >/dev/null
"$binary" report "$fixture_dir" scale \
    2025-01-01 2025-01-12 overview --format json >/dev/null
"$binary" report "$fixture_dir" scale \
    2025-01-01 2025-01-12 funnel signup-flow --format json >/dev/null
"$binary" report "$fixture_dir" scale \
    2025-01-01 2025-01-12 traffic-quality --format json >/dev/null
measure_overview_series strict_overview_v2 "$binary" m3 overview-v2-series \
    "$fixture_dir" scale \
    2025-01-07 2025-01-12 2025-01-01 2025-01-06
measure_series strict_overview 10 "$binary" report "$fixture_dir" scale \
    2025-01-01 2025-01-12 overview --format json
measure_series strict_funnel 10 "$binary" report "$fixture_dir" scale \
    2025-01-01 2025-01-12 funnel signup-flow --format json
measure_series strict_traffic_quality 10 "$binary" report "$fixture_dir" scale \
    2025-01-01 2025-01-12 traffic-quality --format json
profile_seconds=$(sed -n \
    's/.*Total Time: \([0-9.]*\)s.*/\1/p' \
    "$fixture_dir/traffic-quality.profile" | head -n 1)
[[ "$profile_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]
awk -v value="$profile_seconds" 'BEGIN { exit !(value + 0 <= 2.0) }'
printf '"traffic_quality_profile_seconds":%s,' "$profile_seconds"
printf '"traffic_quality_profile_bytes":%d,' \
    "$(stat -c '%s' "$fixture_dir/traffic-quality.profile")"
overview_profile_seconds=$(sed -n \
    's/.*Total Time: \([0-9.]*\)s.*/\1/p' \
    "$fixture_dir/overview-v2.profile" | head -n 1)
[[ "$overview_profile_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]
awk -v value="$overview_profile_seconds" \
    'BEGIN { exit !(value + 0 <= 1.0) }'
printf '"overview_v2_profile_seconds":%s,' "$overview_profile_seconds"
printf '"overview_v2_profile_bytes":%d,' \
    "$(stat -c '%s' "$fixture_dir/overview-v2.profile")"
printf '"database_bytes":%d}\n' "$(stat -c '%s' "$fixture_dir/events.duckdb")"

jq -e '.page_views == 800000 and .custom_events == 200000 and
    .sessions == 100000' "$fixture_dir/overview.json" >/dev/null
jq -e '.metric_version == 2 and .strict_mode == false and
    .visitors > 0 and .comparison_visitors > 0 and
    .sessions > 0 and .comparison_sessions > 0 and
    .page_views > 0 and .engaged_sessions > 0 and
    .conversion_matches > 0 and .converting_visitors > 0 and
    .revenue_currencies == 0 and .legacy_people == .visitors and
    .query_elapsed_micros > 0 and .query_samples == 10 and
    .query_p50_micros > 0 and .query_p95_micros >= .query_p50_micros and
    .query_p99_micros >= .query_p95_micros' \
    "$fixture_dir/overview_v2.json" >/dev/null
jq -e '.rows[] | select(.path == "/" and .page_views == 100000)' \
    "$fixture_dir/pages.json" >/dev/null
jq -e '.total_matches == 100000 and .eligible_sessions == 100100' \
    "$fixture_dir/goal.json" >/dev/null
jq -e '.eligible_sessions == 100100 and
    any(.steps[]; .name == "/checkout" and .sessions == 100000)' \
    "$fixture_dir/funnel.json" >/dev/null
jq -e '.traffic_quality_version == 5 and .strict_mode == false and
    .accepted_events == 1000000 and .raw_candidates == 100 and
    .current_suspected_sessions == 100 and
    .signal_evidence.client_signal_v1_events == 100' \
    "$fixture_dir/traffic_quality.json" >/dev/null
jq -e '.traffic_quality_version == 5 and .strict_mode == true and
    .accepted_events == 1000000 and .raw_candidates == 100 and
    .current_suspected_sessions == 100 and
    .signal_evidence.client_signal_v1_events == 100' \
    "$fixture_dir/strict_traffic_quality.json" >/dev/null
jq -e '.page_views == 800000 and .custom_events == 199900 and
    .sessions == 100000' "$fixture_dir/strict_overview.json" >/dev/null
jq -e --slurpfile default "$fixture_dir/overview_v2.json" '
    .metric_version == 2 and .strict_mode == true and
    .sessions == ($default[0].sessions - 100) and
    .visitors == $default[0].visitors and
    .page_views == $default[0].page_views and
    .conversion_matches == $default[0].conversion_matches and
    .revenue_currencies == 0 and .legacy_people == .visitors and
    .query_elapsed_micros > 0 and .query_samples == 10 and
    .query_p50_micros > 0 and .query_p95_micros >= .query_p50_micros and
    .query_p99_micros >= .query_p95_micros
' "$fixture_dir/strict_overview_v2.json" >/dev/null
jq -e '.eligible_sessions == 100000 and
    any(.steps[]; .name == "/checkout" and .sessions == 100000)' \
    "$fixture_dir/strict_funnel.json" >/dev/null
grep -q 'site_product_events AS NOT MATERIALIZED' \
    "$fixture_dir/traffic-quality.profile"
grep -q 'd34_signal_sessions' "$fixture_dir/traffic-quality.profile"
grep -q 'range_sessions' "$fixture_dir/overview-v2.profile"
grep -q 'person_events' "$fixture_dir/overview-v2.profile"
grep -q 'value_events' "$fixture_dir/overview-v2.profile"

overview_p95=$(sort -n "$fixture_dir/overview.durations" | tail -n 1)
overview_v2_server_p95=$(jq -r \
    '((.query_p95_micros + 999) / 1000 | floor)' \
    "$fixture_dir/overview_v2.json")
funnel_p95=$(sort -n "$fixture_dir/funnel.durations" | tail -n 1)
traffic_quality_p95=$(sort -n "$fixture_dir/traffic_quality.durations" | tail -n 1)
strict_overview_p95=$(sort -n "$fixture_dir/strict_overview.durations" | tail -n 1)
strict_overview_v2_server_p95=$(jq -r \
    '((.query_p95_micros + 999) / 1000 | floor)' \
    "$fixture_dir/strict_overview_v2.json")
strict_funnel_p95=$(sort -n "$fixture_dir/strict_funnel.durations" | tail -n 1)
strict_traffic_quality_p95=$(sort -n \
    "$fixture_dir/strict_traffic_quality.durations" | tail -n 1)
test "$overview_p95" -le 500
test "$overview_v2_server_p95" -le 250
test "$funnel_p95" -le 2000
test "$traffic_quality_p95" -le 2000
test "$strict_overview_p95" -le 500
test "$strict_overview_v2_server_p95" -le 500
test "$strict_funnel_p95" -le 2000
test "$strict_traffic_quality_p95" -le 2000
