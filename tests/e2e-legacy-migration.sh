#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <current-binary> <v0.3.0-binary>" >&2
    exit 2
fi

current=$1
baseline=$2
case "$current" in
    /*) ;;
    *) current="$PWD/$current" ;;
esac
case "$baseline" in
    /*) ;;
    *) baseline="$PWD/$baseline" ;;
esac

mkdir -p .zig-cache
fixture=$(mktemp -d "$PWD/.zig-cache/legacy-migration-e2e.XXXXXX")
server_pid=
cleanup() {
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT

expect_failure() {
    if "$@" >"$fixture/rejected.stdout" 2>"$fixture/rejected.stderr"; then
        echo "command unexpectedly succeeded: $*" >&2
        exit 1
    fi
}

live="$fixture/live"
"$baseline" init "$live" >/dev/null
"$baseline" site add "$live" berlin Berlin https://berlin.example >/dev/null
"$baseline" site add "$live" utc UTC https://utc.example >/dev/null
berlin_id=$("$baseline" site list "$live" |
    awk -F '\t' '$1 == "berlin" { print $2 }')

# A verified but stale pair must not authorize migration after live data changes.
"$current" backup "$live" "$fixture/stale-backup" >/dev/null
"$baseline" event add "$live" berlin pageview /before-midnight \
    1774740600000000 2026-03-28 203.0.113.10 Chrome Linux desktop >/dev/null
"$baseline" event add "$live" berlin pageview /before-gap \
    1774744200000000 2026-03-29 203.0.113.10 Chrome Linux desktop >/dev/null
"$baseline" event add "$live" berlin signup /after-gap \
    1774747800000001 2026-03-29 203.0.113.10 Chrome Linux desktop >/dev/null

before_evidence=$("$current" m3 legacy-evidence "$live")
test "$(jq -r .event_migration_version <<<"$before_evidence")" = 2
test "$(jq -r .rows <<<"$before_evidence")" = 3
before_day_one=$(
    "$baseline" report "$live" berlin 2026-03-28 2026-03-28 overview \
        --format json
)
before_day_two=$(
    "$baseline" report "$live" berlin 2026-03-29 2026-03-29 overview \
        --format json
)
test "$before_day_one" = \
    '{"metric_version":1,"site":"berlin","start_date":"2026-03-28","end_date":"2026-03-28","report":"overview","page_views":1,"visitor_days":1,"sessions":1,"custom_events":0,"bot_events":0}'
test "$before_day_two" = \
    '{"metric_version":1,"site":"berlin","start_date":"2026-03-29","end_date":"2026-03-29","report":"overview","page_views":1,"visitor_days":1,"sessions":2,"custom_events":1,"bot_events":0}'

before_ordinary_hashes=$(sha256sum \
    "$live/meta.db" "$live/events.duckdb" "$live/visitor.key")
expect_failure "$current" init "$live"
expect_failure "$current" site list "$live"
expect_failure "$current" report "$live" berlin 2026-03-28 2026-03-29 \
    overview --format json
test "$(sha256sum "$live/meta.db" "$live/events.duckdb" "$live/visitor.key")" = \
    "$before_ordinary_hashes"
missing_key="$fixture/missing-key"
cp -a "$live" "$missing_key"
rm "$missing_key/visitor.key"
expect_failure "$current" init "$missing_key"
test ! -e "$missing_key/visitor.key"
incomplete="$fixture/incomplete"
mkdir "$incomplete"
cp "$live/events.duckdb" "$live/visitor.key" "$incomplete/"
expect_failure "$current" migrate "$incomplete" "$fixture/stale-backup"
test ! -e "$incomplete/meta.db"
expect_failure "$current" migrate "$live"
expect_failure "$current" migrate "$live" "$fixture/stale-backup"
test "$("$current" m3 legacy-evidence "$live")" = "$before_evidence"

pre_upgrade="$fixture/pre-upgrade"
test "$("$current" backup "$live" "$pre_upgrade")" = \
    "backup complete destination=$pre_upgrade metadata=v2 events=v2"
test "$(jq -r .metadata_schema "$pre_upgrade/manifest.json")" = 2
test "$(jq -r .event_schema "$pre_upgrade/manifest.json")" = 2

# Candidate restore validates the historical pair without upgrading it.
restored_legacy="$fixture/restored-legacy"
"$current" restore "$pre_upgrade" "$restored_legacy" --verify >/dev/null
test "$("$current" m3 legacy-evidence "$restored_legacy")" = \
    "$before_evidence"

test "$("$current" migrate "$live" "$pre_upgrade")" = \
    "migrated metadata=v10 events=v7"
after_evidence=$("$current" m3 legacy-evidence "$live")
test "$(jq -r .event_migration_version <<<"$after_evidence")" = 7
test "$(jq -r .rows <<<"$after_evidence")" = 3
test "$(jq -r .preserved_fingerprint <<<"$after_evidence")" = \
    "$(jq -r .preserved_fingerprint <<<"$before_evidence")"
test "$("$current" m2 identity-links "$live")" = 0
test "$("$current" migrate "$live" "$pre_upgrade")" = \
    "migrated metadata=v10 events=v7"

# No site can serve until its explicit migration timezone choice is complete.
expect_failure "$current" doctor "$live"
"$current" site timezone-set "$live" berlin Europe/Berlin \
    --offline-rebucket >/dev/null
"$current" site timezone-set "$live" utc UTC >/dev/null
test "$("$current" doctor "$live")" = \
    "ok metadata=v10 events=v7 sites=2 goals=0 funnels=0 stored_events=3 key=ok"
test "$("$current" report "$live" berlin 2026-03-28 2026-03-28 \
    overview --format json)" = "$before_day_one"
test "$("$current" report "$live" berlin 2026-03-29 2026-03-29 \
    overview --format json)" = "$before_day_two"
test "$("$current" m2 time-buckets "$live" "$berlin_id")" = \
    $'1774740600000000\t2026-03-28\t2026-03-29\t60\n1774744200000000\t2026-03-29\t2026-03-29\t60\n1774747800000001\t2026-03-29\t2026-03-29\t120'

port=$((54000 + ($$ % 500)))
base="http://127.0.0.1:$port"
"$current" serve --listen "127.0.0.1:$port" \
    --meta "$live/meta.db" \
    --events "$live/events.duckdb" \
    --temp "$live/tmp" \
    --visitor-key-file "$live/visitor.key" \
    >"$fixture/server.stdout" 2>"$fixture/server.stderr" &
server_pid=$!
ready=false
for _ in {1..100}; do
    if curl --silent --fail "$base/readyz" >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 0.02
done
test "$ready" = true

occurred_ms=$((EPOCHSECONDS * 1000))
persistent='00000000-0000-4000-8000-000000001301'
ephemeral='00000000-0000-4000-8000-000000001302'
post_v2() {
    local event_id=$1
    local anonymous_id=$2
    local quality=$3
    local session_id=$4
    local code
    code=$(curl --silent --show-error --output "$fixture/body" \
        --write-out '%{http_code}' -X POST "$base/v2/event" \
        -H 'Content-Type: text/plain;charset=UTF-8' \
        -H 'Origin: https://berlin.example' \
        -H 'X-Forwarded-For: 203.0.113.40' \
        -H 'User-Agent: Mozilla/5.0 Firefox/140.0' \
        --data-binary \
        "{\"v\":2,\"site\":\"$berlin_id\",\"event_id\":\"$event_id\",\"anonymous_id\":\"$anonymous_id\",\"identity_quality\":\"$quality\",\"session_id\":\"$session_id\",\"sequence\":0,\"occurred_at_ms\":$occurred_ms,\"type\":\"pageview\",\"page\":{\"path\":\"/mixed\",\"hostname\":\"berlin.example\"}}")
    test "$code" = 204
}
post_v2 00000000-0000-4000-8000-000000001311 "$persistent" persistent \
    00000000-0000-4000-8000-000000001321
post_v2 00000000-0000-4000-8000-000000001312 "$ephemeral" ephemeral \
    00000000-0000-4000-8000-000000001322

kill -TERM "$server_pid"
wait "$server_pid"
server_pid=

today=$(TZ=Europe/Berlin date +%F)
coverage=$("$current" m3 identity-coverage "$live" "$berlin_id" \
    2026-03-29 "$today")
jq -e --arg today "$today" '
    .total_people == 4 and
    .persistent_people == 1 and
    .ephemeral_people == 1 and
    .legacy_people == 2 and
    .persistent_basis_points == 2500 and
    .persistent_since_local_date == $today
' <<<"$coverage" >/dev/null

post_upgrade="$fixture/post-upgrade"
"$current" backup "$live" "$post_upgrade" >/dev/null
restored_current="$fixture/restored-current"
"$current" restore "$post_upgrade" "$restored_current" --verify >/dev/null
test "$("$current" doctor "$restored_current")" = \
    "ok metadata=v10 events=v7 sites=2 goals=0 funnels=0 stored_events=5 key=ok"

# The candidate-created schema-2 backup remains consumable by the exact old binary.
rolled_back="$fixture/rolled-back"
"$baseline" restore "$pre_upgrade" "$rolled_back" --verify >/dev/null
test "$("$baseline" doctor "$rolled_back")" = \
    "ok metadata=v2 events=v2 sites=2 goals=0 funnels=0 stored_events=3 key=ok"
test "$("$baseline" report "$rolled_back" berlin 2026-03-28 2026-03-28 \
    overview --format json)" = "$before_day_one"
test "$("$baseline" report "$rolled_back" berlin 2026-03-29 2026-03-29 \
    overview --format json)" = "$before_day_two"

printf '%s\n' "$coverage"
echo "exact v0.3.0 legacy migration, mixed coverage, backup, restore, and rollback passed"
