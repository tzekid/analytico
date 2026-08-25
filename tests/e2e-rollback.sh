#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <current-binary> <previous-binary>" >&2
    exit 2
fi

current=$1
previous=$2
case "$current" in
    /*) ;;
    *) current="$PWD/$current" ;;
esac
case "$previous" in
    /*) ;;
    *) previous="$PWD/$previous" ;;
esac

mkdir -p .zig-cache
fixture=$(mktemp -d "$PWD/.zig-cache/rollback-e2e.XXXXXX")
previous_pid=
cleanup() {
    if [[ -n "$previous_pid" ]] && kill -0 "$previous_pid" 2>/dev/null; then
        kill -TERM "$previous_pid" 2>/dev/null || true
        wait "$previous_pid" 2>/dev/null || true
    fi
    if [[ ${ANALYTICO_KEEP_ROLLBACK_FIXTURE:-0} != 1 ]]; then
        rm -rf -- "$fixture"
    else
        echo "kept rollback fixture: $fixture" >&2
    fi
}
trap cleanup EXIT

live="$fixture/live"
"$previous" init "$live" >/dev/null
"$previous" site add "$live" rollback Rollback https://rollback.example >/dev/null
"$previous" event add "$live" rollback pageview /before \
    1785456000000000 2026-07-31 203.0.113.1 Chrome Linux desktop >/dev/null
backup="$fixture/pre-upgrade"
"$previous" backup "$live" "$backup" >/dev/null

# Represent post-upgrade state which must not survive the operator rollback.
"$current" migrate "$live" "$backup" >/dev/null
"$current" site timezone-set "$live" rollback UTC \
    --offline-rebucket >/dev/null
"$current" auth configure "$live" http://localhost:4318 >/dev/null
"$current" event add "$live" rollback signup /after \
    1785456000000001 2026-07-31 203.0.113.2 Firefox Linux desktop >/dev/null
test "$("$current" doctor "$live")" = \
    "ok metadata=v10 events=v7 sites=1 goals=0 funnels=0 stored_events=2 key=ok"

rolled_back="$fixture/rolled-back"
"$previous" restore "$backup" "$rolled_back" --verify >/dev/null
test "$("$previous" doctor "$rolled_back")" = \
    "ok metadata=v2 events=v2 sites=1 goals=0 funnels=0 stored_events=1 key=ok"
report=$("$previous" report "$rolled_back" rollback 2026-07-31 2026-07-31 \
    overview --format json)
test "$report" = \
    '{"metric_version":1,"site":"rollback","start_date":"2026-07-31","end_date":"2026-07-31","report":"overview","page_views":1,"visitor_days":1,"sessions":1,"custom_events":0,"bot_events":0}'

port=$((47000 + ($$ % 1000)))
"$previous" serve --listen "127.0.0.1:$port" \
    --meta "$rolled_back/meta.db" \
    --events "$rolled_back/events.duckdb" \
    --temp "$rolled_back/tmp" \
    --visitor-key-file "$rolled_back/visitor.key" \
    >"$fixture/previous.stdout" 2>"$fixture/previous.stderr" &
previous_pid=$!
for _ in {1..100}; do
    curl --silent --fail "http://127.0.0.1:$port/readyz" >/dev/null 2>&1 &&
        break
    sleep 0.02
done
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "http://127.0.0.1:$port/readyz")" = 200
kill -TERM "$previous_pid"
wait "$previous_pid"
previous_pid=

echo "previous binary and pre-upgrade backup rollback passed"
