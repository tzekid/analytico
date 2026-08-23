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

"$binary" report "$fixture_dir" scale \
    2025-01-01 2025-01-12 overview --format json >/dev/null
"$binary" report "$fixture_dir" scale \
    2025-01-01 2025-01-12 funnel signup-flow --format json >/dev/null

printf '{'
printf '"events":1000000,'
printf '"seed_ms":%d,' "$(((seed_finished - seed_started) / 1000000))"
measure_series overview 10 "$binary" report "$fixture_dir" scale \
    2025-01-01 2025-01-12 overview --format json
measure pages "$binary" report "$fixture_dir" scale \
    2025-01-01 2025-01-12 pages --format json
measure goal "$binary" report "$fixture_dir" scale \
    2025-01-01 2025-01-12 goal signups --format json
measure_series funnel 10 "$binary" report "$fixture_dir" scale \
    2025-01-01 2025-01-12 funnel signup-flow --format json
printf '"database_bytes":%d}\n' "$(stat -c '%s' "$fixture_dir/events.duckdb")"

grep -q '"page_views":800000' "$fixture_dir/overview.json"
grep -q '"custom_events":200000' "$fixture_dir/overview.json"
grep -q '"path":"/","page_views":100000' "$fixture_dir/pages.json"
grep -q '"total_matches":100000' "$fixture_dir/goal.json"
grep -q '"name":"/checkout","sessions":100000' "$fixture_dir/funnel.json"

overview_p95=$(sort -n "$fixture_dir/overview.durations" | tail -n 1)
funnel_p95=$(sort -n "$fixture_dir/funnel.durations" | tail -n 1)
test "$overview_p95" -le 500
test "$funnel_p95" -le 2000
