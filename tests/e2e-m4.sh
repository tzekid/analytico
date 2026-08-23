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
fixture_root=$(mktemp -d "$PWD/.zig-cache/m4-e2e.XXXXXX")
server_pid=
cleanup() {
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf -- "$fixture_root"
}
trap cleanup EXIT

expect_failure() {
    if "$@" >"$fixture_root/rejected.stdout" 2>"$fixture_root/rejected.stderr"; then
        echo "command unexpectedly succeeded: $*" >&2
        exit 1
    fi
}

assert_absent_destination() {
    if [[ -e "$1" ]]; then
        echo "failed operation left destination behind: $1" >&2
        exit 1
    fi
}

source_dir="$fixture_root/source"
"$binary" init "$source_dir" >/dev/null
"$binary" site add "$source_dir" active Active https://active.example \
    --timezone UTC >/dev/null
"$binary" site add "$source_dir" retired Retired https://retired.example \
    --timezone UTC >/dev/null
"$binary" goal add "$source_dir" active signup event signup >/dev/null
"$binary" funnel add "$source_dir" active journey path=/ event=signup >/dev/null

"$binary" event add "$source_dir" active pageview /old \
    1735689600000000 2025-01-01 203.0.113.1 Chrome Linux desktop >/dev/null
"$binary" event add "$source_dir" active signup /welcome \
    1785456000000000 2026-07-31 203.0.113.2 Firefox Linux desktop >/dev/null
"$binary" event add "$source_dir" retired pageview /retired \
    1785456000000001 2026-07-31 203.0.113.3 Safari macOS mobile >/dev/null
"$binary" site disable "$source_dir" retired >/dev/null

test "$("$binary" doctor "$source_dir")" = \
    "ok metadata=v4 events=v5 sites=2 goals=1 funnels=1 stored_events=3 key=ok"

export_path="$fixture_root/active.csv"
test "$("$binary" export "$source_dir" active 2025-01-01 2026-07-31 "$export_path")" = \
    "export complete destination=$export_path events=2"
test "$(stat -c '%a' "$export_path")" = 600
test "$(wc -l <"$export_path")" = 3
head -1 "$export_path" | grep -q \
    '^received_at_utc_micros,received_date_utc,event_name,path,'
grep -Fq '"2025-01-01","pageview","/old"' "$export_path"
grep -Fq '"2026-07-31","signup","/welcome"' "$export_path"
if rg -n 'visitor|session' "$export_path" >/dev/null; then
    echo "normalized export leaked a visitor/session identifier" >&2
    exit 1
fi
expect_failure "$binary" export "$source_dir" active \
    2025-01-01 2026-07-31 "$export_path"

backup_one="$fixture_root/backup-one"
backup_two="$fixture_root/backup-two"
"$binary" backup "$source_dir" "$backup_one" >/dev/null
"$binary" backup "$source_dir" "$backup_two" >/dev/null
for backup in "$backup_one" "$backup_two"; do
    test "$(find "$backup" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)" = \
        $'events.duckdb\nmanifest.json\nmeta.db\nvisitor.key'
    test "$(stat -c '%a' "$backup/visitor.key")" = 600
    test "$(jq -r '.schema' "$backup/manifest.json")" = 1
    test "$(jq -r '.metadata_schema' "$backup/manifest.json")" = 4
    test "$(jq -r '.event_schema' "$backup/manifest.json")" = 5
    for name in meta.db events.duckdb visitor.key; do
        expected=$(jq -r \
            --arg name "$name" \
            'if $name == "meta.db" then .meta.sha256
             elif $name == "events.duckdb" then .events.sha256
             else .visitor_key.sha256 end' \
            "$backup/manifest.json")
        test "$(sha256sum "$backup/$name" | awk '{print $1}')" = "$expected"
    done
done

restored_one="$fixture_root/restored-one"
restored_two="$fixture_root/restored-two"
"$binary" restore "$backup_one" "$restored_one" --verify >/dev/null
"$binary" restore "$backup_one" "$restored_two" --verify >/dev/null
for restored in "$restored_one" "$restored_two"; do
    test "$("$binary" doctor "$restored")" = \
        "ok metadata=v4 events=v5 sites=2 goals=1 funnels=1 stored_events=3 key=ok"
    report=$("$binary" report "$restored" active 2026-07-31 2026-07-31 \
        overview --format json)
    test "$report" = \
        '{"metric_version":1,"site":"active","start_date":"2026-07-31","end_date":"2026-07-31","report":"overview","page_views":0,"visitor_days":1,"sessions":1,"custom_events":1,"bot_events":0}'
done

expect_failure "$binary" backup "$source_dir" "$backup_one"
expect_failure "$binary" restore "$backup_one" "$restored_one" --verify

corrupt_backup="$fixture_root/corrupt-backup"
cp -a "$backup_one" "$corrupt_backup"
printf 'corrupt' >>"$corrupt_backup/events.duckdb"
corrupt_destination="$fixture_root/corrupt-destination"
expect_failure "$binary" restore "$corrupt_backup" "$corrupt_destination" --verify
assert_absent_destination "$corrupt_destination"

wrong_manifest="$fixture_root/wrong-manifest"
cp -a "$backup_one" "$wrong_manifest"
jq '.event_schema = 999' "$wrong_manifest/manifest.json" \
    >"$wrong_manifest/manifest.new"
mv "$wrong_manifest/manifest.new" "$wrong_manifest/manifest.json"
wrong_destination="$fixture_root/wrong-destination"
expect_failure "$binary" restore "$wrong_manifest" "$wrong_destination" --verify
assert_absent_destination "$wrong_destination"

chmod 0644 "$source_dir/visitor.key"
expect_failure "$binary" doctor "$source_dir"
permission_backup="$fixture_root/permission-backup"
expect_failure "$binary" backup "$source_dir" "$permission_backup"
assert_absent_destination "$permission_backup"
chmod 0600 "$source_dir/visitor.key"
test "$("$binary" doctor "$source_dir")" = \
    "ok metadata=v4 events=v5 sites=2 goals=1 funnels=1 stored_events=3 key=ok"

newer_events="$fixture_root/newer-events"
"$binary" restore "$backup_one" "$newer_events" --verify >/dev/null
"$binary" m4 poison-newer "$newer_events" events >/dev/null
expect_failure "$binary" doctor "$newer_events"
expect_failure "$binary" migrate "$newer_events"
expect_failure "$binary" serve --listen 127.0.0.1:49991 \
    --meta "$newer_events/meta.db" \
    --events "$newer_events/events.duckdb" \
    --temp "$newer_events/tmp" \
    --visitor-key-file "$newer_events/visitor.key"

newer_metadata="$fixture_root/newer-metadata"
"$binary" restore "$backup_one" "$newer_metadata" --verify >/dev/null
"$binary" m4 poison-newer "$newer_metadata" metadata >/dev/null
expect_failure "$binary" doctor "$newer_metadata"
expect_failure "$binary" migrate "$newer_metadata"

before_recent=$("$binary" doctor "$source_dir")
expect_failure "$binary" maintain "$source_dir" 2026-01-01
test "$("$binary" doctor "$source_dir")" = "$before_recent"
test "$("$binary" maintain "$source_dir" 2025-01-02)" = \
    "maintenance cutoff=2025-01-02 before=3 expired=1 site_events=1 sites=1 after=1"
test "$("$binary" doctor "$source_dir")" = \
    "ok metadata=v4 events=v5 sites=1 goals=1 funnels=1 stored_events=1 key=ok"
recent_report=$("$binary" report "$source_dir" active 2026-07-31 2026-07-31 \
    overview --format json)
test "$recent_report" = \
    '{"metric_version":1,"site":"active","start_date":"2026-07-31","end_date":"2026-07-31","report":"overview","page_views":0,"visitor_days":1,"sessions":1,"custom_events":1,"bot_events":0}'

legacy_dir="$fixture_root/interrupted-migration"
"$binary" init "$legacy_dir" >/dev/null
mv "$legacy_dir/events.duckdb" "$legacy_dir/events.initial-v2"
"$binary" m4 legacy-million "$legacy_dir" >/dev/null
legacy_backup="$fixture_root/interrupted-migration-backup"
"$binary" backup "$legacy_dir" "$legacy_backup" >/dev/null
"$binary" migrate "$legacy_dir" "$legacy_backup" \
    >"$fixture_root/migrate.stdout" 2>"$fixture_root/migrate.stderr" &
migration_pid=$!
for _ in {1..100}; do
    if ! kill -0 "$migration_pid" 2>/dev/null; then
        echo "million-row migration completed before interruption" >&2
        wait "$migration_pid" || true
        exit 1
    fi
    if [[ -s "$legacy_dir/events.duckdb.wal" ]]; then
        break
    fi
    sleep 0.01
done
kill -KILL "$migration_pid"
if wait "$migration_pid" 2>/dev/null; then
    echo "interrupted migration unexpectedly exited successfully" >&2
    exit 1
fi
test "$("$binary" migrate "$legacy_dir" "$legacy_backup")" = \
    "migrated metadata=v4 events=v5"
test "$("$binary" doctor "$legacy_dir")" = \
    "ok metadata=v4 events=v5 sites=0 goals=0 funnels=0 stored_events=1000000 key=ok"

port=$((45000 + ($$ % 1000)))
base="http://127.0.0.1:$port"
readiness_dir="$fixture_root/readiness"
"$binary" restore "$backup_one" "$readiness_dir" --verify >/dev/null
"$binary" serve --listen "127.0.0.1:$port" \
    --meta "$readiness_dir/meta.db" \
    --events "$readiness_dir/events.duckdb" \
    --temp "$readiness_dir/tmp" \
    --visitor-key-file "$readiness_dir/visitor.key" \
    >"$fixture_root/readiness.stdout" 2>"$fixture_root/readiness.log" &
server_pid=$!
for _ in {1..100}; do
    curl --silent --fail "$base/readyz" >/dev/null 2>&1 && break
    sleep 0.02
done
test "$(curl --silent --output /dev/null --write-out '%{http_code}' "$base/readyz")" = 200
mv "$readiness_dir/meta.db" "$readiness_dir/meta.away"
test "$(curl --silent --output /dev/null --write-out '%{http_code}' "$base/readyz")" = 503
mv "$readiness_dir/meta.away" "$readiness_dir/meta.db"
test "$(curl --silent --output /dev/null --write-out '%{http_code}' "$base/readyz")" = 200
mv "$readiness_dir/events.duckdb" "$readiness_dir/events.away"
test "$(curl --silent --output /dev/null --write-out '%{http_code}' "$base/readyz")" = 503
mv "$readiness_dir/events.away" "$readiness_dir/events.duckdb"
kill -TERM "$server_pid"
wait "$server_pid"
server_pid=
grep -q '"code":"serve_started"' "$fixture_root/readiness.log"
grep -q '"code":"serve_stopped"' "$fixture_root/readiness.log"

fault_dir="$fixture_root/file-limit"
"$binary" init "$fault_dir" >/dev/null
"$binary" site add "$fault_dir" fault Fault https://fault.example \
    --timezone UTC >/dev/null
fault_site=$("$binary" site list "$fault_dir" |
    awk -F '\t' '$1 == "fault" { print $2 }')
fault_port=$((46000 + ($$ % 1000)))
fault_base="http://127.0.0.1:$fault_port"
fault_log="$fixture_root/file-limit.log"
prlimit --fsize=0 -- "$binary" serve --listen "127.0.0.1:$fault_port" \
    --meta "$fault_dir/meta.db" \
    --events "$fault_dir/events.duckdb" \
    --temp "$fault_dir/tmp" \
    --visitor-key-file "$fault_dir/visitor.key" \
    > >(:) 2> >(cat >"$fault_log") &
server_pid=$!
for _ in {1..100}; do
    curl --silent --fail "$fault_base/readyz" >/dev/null 2>&1 && break
    sleep 0.02
done
payload=$(printf \
    '{"v":1,"site":"%s","type":"pageview","path":"/private-path"}' \
    "$fault_site")
test "$(curl --silent --output "$fixture_root/fault.body" \
    --write-out '%{http_code}' -X POST "$fault_base/v1/event" \
    -H 'Content-Type: text/plain' \
    -H 'Origin: https://fault.example' \
    -H 'X-Forwarded-For: 203.0.113.42' \
    -H 'User-Agent: secret-user-agent' \
    --data-binary "$payload")" = 500
test "$(cat "$fixture_root/fault.body")" = "internal error"
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "$fault_base/readyz")" = 503
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    -X POST "$fault_base/v1/event" \
    -H 'Content-Type: text/plain' \
    -H 'Origin: https://fault.example' \
    --data-binary "$payload")" = 503
kill -TERM "$server_pid"
wait "$server_pid"
server_pid=
grep -q '"write_failures":1' "$fault_log"
if rg -n 'private-path|secret-user-agent|203\\.0\\.113\\.42|visitor\\.key|events\\.duckdb' \
    "$fixture_root"/*.log >/dev/null; then
    echo "structured log denylist detected private request or storage data" >&2
    exit 1
fi
test "$("$binary" doctor "$fault_dir")" = \
    "ok metadata=v4 events=v5 sites=1 goals=0 funnels=0 stored_events=0 key=ok"

expect_failure "$binary" serve --listen 0.0.0.0:49992 \
    --meta "$source_dir/meta.db" \
    --events "$source_dir/events.duckdb" \
    --temp "$source_dir/tmp" \
    --visitor-key-file "$source_dir/visitor.key"
expect_failure "$binary" serve --listen 127.0.0.1:49992 \
    --meta relative/meta.db \
    --events "$source_dir/events.duckdb" \
    --temp "$source_dir/tmp" \
    --visitor-key-file "$source_dir/visitor.key"
expect_failure "$binary" serve --listen 127.0.0.1:49992 \
    --listen 127.0.0.1:49993 \
    --meta "$source_dir/meta.db" \
    --events "$source_dir/events.duckdb" \
    --temp "$source_dir/tmp" \
    --visitor-key-file "$source_dir/visitor.key"

echo "M4 real-process lifecycle and failure checks passed"
