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
fixture=$(mktemp -d "$PWD/.zig-cache/properties-bench.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

result=$("$binary" m2 property-million "$fixture")
jq -e '
    .duckdb_version == "v1.4.5" and
    .events == 1000000 and
    .properties == 12 and
    .catalog.property_count == 12 and
    .catalog.truncated == false and
    .filters == {
        "string": 250000,
        "integer": 1000,
        "decimal": 100000,
        "boolean": 500000,
        "null_value": 1000000,
        "missing": 500000
    } and
    .mixed.bucket_count == 4 and
    .low_breakdown.rows == 4 and
    .low_breakdown.bucket_count == 4 and
    .low_breakdown.samples == 10 and
    .low_breakdown.p95_ms <= 700 and
    .high_breakdown.rows == 100 and
    .high_breakdown.bucket_count == 100000 and
    .high_breakdown.truncated == true
' <<<"$result" >/dev/null

if "$binary" m2 property-million "$fixture" \
    >"$fixture/reseed.stdout" 2>"$fixture/reseed.stderr"
then
    echo "property benchmark unexpectedly accepted a non-empty store" >&2
    exit 1
fi

printf '%s\n' "$result"
