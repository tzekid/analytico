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

fixture_dir=$(mktemp -d "$PWD/.zig-cache/m2-bench.XXXXXX")
server_pid=
port=$((45000 + ($$ % 1000)))
base="http://127.0.0.1:$port"
cleanup() {
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf -- "$fixture_dir"
}
trap cleanup EXIT

"$binary" init "$fixture_dir" >/dev/null
"$binary" site add "$fixture_dir" benchmark "Collection benchmark" \
    "https://benchmark.example" >/dev/null
site_id=$("$binary" site list "$fixture_dir" |
    awk -F '\t' '$1 == "benchmark" { print $2 }')
payload=$(printf \
    '{"v":1,"site":"%s","type":"pageview","path":"/benchmark"}' \
    "$site_id")

startup_started=$(date +%s%N)
"$binary" serve "$fixture_dir" 127.0.0.1 "$port" \
    >"$fixture_dir/server.stdout" 2>"$fixture_dir/server.stderr" &
server_pid=$!
ready=false
for _ in {1..200}; do
    if curl --silent --fail "$base/readyz" >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 0.005
done
test "$ready" = true
startup_ms=$((($(date +%s%N) - startup_started) / 1000000))

# The contract calls for the actual 30-second idle footprint, not an
# extrapolated immediate sample.
sleep 30
idle_rss_kib=$(ps -o rss= -p "$server_pid" | tr -d ' ')

for index in {1..5}; do
    code=$(curl --silent --output /dev/null --write-out '%{http_code}' \
        -X POST "$base/v1/event" \
        -H 'Content-Type: text/plain' \
        -H 'Origin: https://benchmark.example' \
        -H "X-Forwarded-For: 10.0.$index.1" \
        --data-binary "$payload")
    test "$code" = 204
done

for index in {1..100}; do
    curl --silent --output /dev/null \
        --write-out '%{http_code}\t%{time_total}\n' \
        -X POST "$base/v1/event" \
        -H 'Content-Type: text/plain' \
        -H 'Origin: https://benchmark.example' \
        -H "X-Forwarded-For: 10.1.$index.1" \
        --data-binary "$payload" >>"$fixture_dir/observations.tsv"
done
if awk -F '\t' '$1 != 204 { bad = 1 } END { exit bad }' \
    "$fixture_dir/observations.tsv"
then
    :
else
    echo "collection benchmark received a non-204 response" >&2
    exit 1
fi
cut -f2 "$fixture_dir/observations.tsv" |
    sort -n >"$fixture_dir/times.sorted"
latency_p50_ms=$(awk 'NR == 50 { printf "%.3f", $1 * 1000 }' \
    "$fixture_dir/times.sorted")
latency_p95_ms=$(awk 'NR == 95 { printf "%.3f", $1 * 1000 }' \
    "$fixture_dir/times.sorted")
latency_p99_ms=$(awk 'NR == 99 { printf "%.3f", $1 * 1000 }' \
    "$fixture_dir/times.sorted")
loaded_rss_kib=$(ps -o rss= -p "$server_pid" | tr -d ' ')

shutdown_started=$(date +%s%N)
kill -TERM "$server_pid"
wait "$server_pid"
server_pid=
shutdown_ms=$((($(date +%s%N) - shutdown_started) / 1000000))
stored_events=$("$binary" doctor "$fixture_dir" |
    sed -n 's/.*stored_events=//p')

cat <<JSON
{
  "schema": 1,
  "mode": "ReleaseSafe",
  "sample_count": 100,
  "startup_ms": $startup_ms,
  "idle_rss_kib_after_30s": $idle_rss_kib,
  "loaded_rss_kib": $loaded_rss_kib,
  "durable_insert_p50_ms": $latency_p50_ms,
  "durable_insert_p95_ms": $latency_p95_ms,
  "durable_insert_p99_ms": $latency_p99_ms,
  "shutdown_ms": $shutdown_ms,
  "stored_events": $stored_events,
  "tracker_raw_bytes": $(stat -c '%s' public/tracker.js),
  "tracker_brotli_bytes": $(stat -c '%s' public/tracker.js.br),
  "tracker_gzip_bytes": $(stat -c '%s' public/tracker.js.gz)
}
JSON
