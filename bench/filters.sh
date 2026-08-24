#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <analytico-binary>" >&2
    exit 2
fi
binary=$1
case "$binary" in /*) ;; *) binary="$PWD/$binary" ;; esac

fixture=$(mktemp -d "$PWD/.zig-cache/filters-bench.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT
"$binary" init "$fixture" >/dev/null
"$binary" site add "$fixture" scale Scale https://scale.example \
    --timezone UTC >/dev/null
site_id=$("$binary" site list "$fixture" |
    awk -F '\t' '$1 == "scale" { print $2 }')
"$binary" goal add "$fixture" scale signups event signup >/dev/null
"$binary" m3 million "$fixture" "$site_id" >/dev/null

printf 'measuring default filtered execution\n' >&2
default_json=$("$binary" m3 filters-v2-series "$fixture" scale \
    2025-01-07 2025-01-12 2025-01-01 2025-01-06)
printf 'profiling default filtered Overview\n' >&2
"$binary" m3 filters-v2-profile "$fixture" scale \
    2025-01-07 2025-01-12 2025-01-01 2025-01-06 \
    >"$fixture/default.profile"
"$binary" site traffic-policy "$fixture" scale strict 100000 >/dev/null
printf 'measuring strict filtered execution\n' >&2
strict_json=$("$binary" m3 filters-v2-series "$fixture" scale \
    2025-01-07 2025-01-12 2025-01-01 2025-01-06)

jq -e '.metric_version == 2 and .strict_mode == false and
    .cold_overview_micros < 2000000 and
    .warm_overview_p95_micros < 250000 and
    .trend_micros < 2000000 and .trend_points == 6 and
    .breakdown_micros < 2000000 and .breakdown_rows > 0 and
    .suggestion_micros < 2000000 and
    .suggestion_values > 0 and .suggestion_values <= 50' \
    <<<"$default_json" >/dev/null
jq -e '.metric_version == 2 and .strict_mode == true and
    .cold_overview_micros < 2000000 and
    .warm_overview_p95_micros <= 500000 and
    .trend_micros < 2000000 and .trend_points == 6 and
    .breakdown_micros < 2000000 and .breakdown_rows > 0 and
    .suggestion_micros < 2000000 and
    .suggestion_values > 0 and .suggestion_values <= 50' \
    <<<"$strict_json" >/dev/null
profile_seconds=$(sed -n \
    's/.*Total Time: \([0-9.]*\)s.*/\1/p' "$fixture/default.profile" |
    awk '{ total += $1 } END { printf "%.6f", total }')
awk -v value="$profile_seconds" 'BEGIN { exit !(value + 0 < 2.0) }'
grep -q 'session_facts' "$fixture/default.profile"
grep -q 'qualified' "$fixture/default.profile"

printf '{"events":1000000,"default":%s,"strict":%s,' \
    "$default_json" "$strict_json"
printf '"default_cold_profile_seconds":%s,' "$profile_seconds"
printf '"default_cold_profile_bytes":%d}\n' \
    "$(stat -c '%s' "$fixture/default.profile")"
