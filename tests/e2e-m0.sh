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
fixture_dir=$(mktemp -d "$PWD/.zig-cache/m0-e2e.XXXXXX")
trap 'rm -rf -- "$fixture_dir"' EXIT

probe_output=$("$binary" m0 probe "$fixture_dir")
printf '%s\n' "$probe_output"

for expected in \
    '"sites":1' \
    '"events":6' \
    '"page_views":4' \
    '"daily_uniques":2' \
    '"entry_sessions":2' \
    '"funnel_completions":1'
do
    if [[ "$probe_output" != *"$expected"* ]]; then
        echo "missing expected probe output: $expected" >&2
        exit 1
    fi
done

test -s "$fixture_dir/meta.db"
test -s "$fixture_dir/events.duckdb"

verify_output=$("$binary" m0 verify "$fixture_dir")
test "$verify_output" = "probe restart verification passed"

benchmark_output=$("$binary" m0 benchmark "$fixture_dir")
printf '%s\n' "$benchmark_output"
for expected in \
    '"events":1000000' \
    '"page_views":800000' \
    '"daily_uniques":5000' \
    '"funnel_completions":5000'
do
    if [[ "$benchmark_output" != *"$expected"* ]]; then
        echo "missing expected benchmark output: $expected" >&2
        exit 1
    fi
done

cp "$fixture_dir/events.duckdb" "$fixture_dir/corrupt.duckdb"
truncate -s 64 "$fixture_dir/corrupt.duckdb"
mv "$fixture_dir/events.duckdb" "$fixture_dir/events.good.duckdb"
mv "$fixture_dir/corrupt.duckdb" "$fixture_dir/events.duckdb"
if "$binary" m0 verify "$fixture_dir" >"$fixture_dir/corrupt.stdout" 2>"$fixture_dir/corrupt.stderr"; then
    echo "verification unexpectedly accepted a truncated DuckDB file" >&2
    exit 1
fi
mv "$fixture_dir/events.duckdb" "$fixture_dir/events.corrupt.duckdb"
mv "$fixture_dir/events.good.duckdb" "$fixture_dir/events.duckdb"

cp "$fixture_dir/meta.db" "$fixture_dir/meta.good.db"
truncate -s 64 "$fixture_dir/meta.db"
if "$binary" m0 verify "$fixture_dir" >"$fixture_dir/corrupt-meta.stdout" 2>"$fixture_dir/corrupt-meta.stderr"; then
    echo "verification unexpectedly accepted a truncated Turso file" >&2
    exit 1
fi

echo "M0 real-process end-to-end checks passed"
