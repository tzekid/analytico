#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <current-binary> <schema5-binary>" >&2
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

fixture=$(mktemp -d)
server_pid=
migration_pid=
cleanup() {
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    if [[ -n "$migration_pid" ]]; then
        kill -KILL "$migration_pid" 2>/dev/null || true
        wait "$migration_pid" 2>/dev/null || true
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT

live="$fixture/live"
"$previous" init "$live" >/dev/null
"$previous" site add "$live" migration Migration https://migration.example \
    --timezone UTC >/dev/null
site_id=$("$previous" site list "$live" |
    awk -F '\t' '$1 == "migration" { print $2 }')
port=$((47500 + ($$ % 500)))
base="http://127.0.0.1:$port"
"$previous" serve --listen "127.0.0.1:$port" \
    --meta "$live/meta.db" \
    --events "$live/events.duckdb" \
    --temp "$live/tmp" \
    --visitor-key-file "$live/visitor.key" \
    >"$fixture/server.stdout" 2>"$fixture/server.stderr" &
server_pid=$!
for _ in {1..100}; do
    curl --silent --fail "$base/readyz" >/dev/null 2>&1 && break
    sleep 0.02
done
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "$base/readyz")" = 200

occurred_ms=$(date +%s%3N)
send_event() {
    local suffix=$1
    local user_agent=$2
    local path=$3
    local optional=${4-}
    local body
    body=$(printf '{"v":2,"site":"%s","event_id":"00000000-0000-4000-8000-0000000005%s","anonymous_id":"00000000-0000-4000-8000-0000000006%s","identity_quality":"persistent","session_id":"00000000-0000-4000-8000-0000000007%s","sequence":0,"occurred_at_ms":%s,%s"type":"pageview","page":{"path":"%s","hostname":"migration.example"}}' \
        "$site_id" "$suffix" "$suffix" "$suffix" "$occurred_ms" \
        "$optional" "$path")
    curl --silent --output /dev/null --write-out '%{http_code}' \
        -X POST "$base/v2/event" \
        -H 'Content-Type: text/plain' \
        -H 'Origin: https://migration.example' \
        -H 'X-Forwarded-For: 198.51.100.42' \
        -H "User-Agent: $user_agent" \
        --data-binary "$body"
}

test "$(send_event 01 'Mozilla/5.0 Safari/605.1.15' /both-human)" = 204
test "$(send_event 02 'Mozilla/5.0 (Linux; Android 14; Cubot X70) AppleWebKit Chrome/120 Mobile' /legacy-only)" = 204
test "$(send_event 03 'curl/8.12.1' /classifier-only)" = 204
test "$(send_event 04 'Googlebot/2.1' /both-bot)" = 204
test "$(send_event 05 'Googlebot/2.1' /excluded '"self_excluded":true,')" = 204

kill -TERM "$server_pid"
wait "$server_pid"
server_pid=

test "$("$previous" doctor "$live")" = \
    "ok metadata=v4 events=v5 sites=1 goals=0 funnels=0 stored_events=5 key=ok"
today=$(date --utc +%F)
before=$("$previous" report "$live" migration "$today" "$today" \
    overview --format json)
jq -e '
    .page_views == 2 and .visitor_days == 2 and .sessions == 2 and
    .bot_events == 2
' <<<"$before" >/dev/null
before_quality=$("$previous" report "$live" migration "$today" "$today" \
    traffic-quality --format json)
jq -e '
    .traffic_classes == [
      {"class":"human-presumed","events":2},
      {"class":"declared-bot","events":1},
      {"class":"automation","events":1},
      {"class":"excluded","events":1},
      {"class":"suspected","events":0}
    ] and .classifier_v1_events == 4 and
    .shadow == {
      "both_human":1,
      "legacy_only":1,
      "classifier_only":1,
      "both_bot":1
    }
' <<<"$before_quality" >/dev/null

backup="$fixture/pre-schema6"
test "$("$current" backup "$live" "$backup")" = \
    "backup complete destination=$backup metadata=v4 events=v5"
test "$(jq -r .event_schema "$backup/manifest.json")" = 5
verified="$fixture/verified-schema5"
"$current" restore "$backup" "$verified" --verify >/dev/null
test "$("$previous" doctor "$verified")" = \
    "ok metadata=v4 events=v5 sites=1 goals=0 funnels=0 stored_events=5 key=ok"
test "$("$previous" report "$verified" migration "$today" "$today" \
    overview --format json)" = "$before"

test "$("$current" migrate "$live" "$backup")" = \
    "migrated metadata=v10 events=v7"
test "$("$current" doctor "$live")" = \
    "ok metadata=v10 events=v7 sites=1 goals=0 funnels=0 stored_events=5 key=ok"

inspect() {
    "$current" m2 v2-inspect "$live" "$site_id" \
        "00000000-0000-4000-8000-0000000005$1"
}
for suffix in 01 02 03 04 05; do
    jq -e '
        .event_schema_version == 7 and
        .signals == {
          "version":0,
          "navigator_webdriver":false,
          "trusted_interactions":0,
          "was_visible":false,
          "was_prerendered":false,
          "viewport_bucket":0,
          "beacon_timing_bucket":0
        } and .client_hint_consistency == 0 and
        .accept_language_present == false and
        (has("legacy_bot_verdict") | not)
    ' <<<"$(inspect "$suffix")" >/dev/null
done
jq -e '
    .traffic_class == 1 and .classifier_version == 1 and .bot_rule == "" and
    .session_start == false
' <<<"$(inspect 02)" >/dev/null
jq -e '
    .traffic_class == 3 and .classifier_version == 1 and
    .bot_rule == "client.curl" and .session_start == true
' <<<"$(inspect 03)" >/dev/null
jq -e '
    .traffic_class == 4 and .classifier_version == 1 and
    .bot_rule == "exclude.tracker" and .session_start == false
' <<<"$(inspect 05)" >/dev/null

after=$("$current" report "$live" migration "$today" "$today" \
    overview --format json)
jq -e '
    .page_views == 2 and .visitor_days == 1 and .sessions == 1 and
    .bot_events == 2
' <<<"$after" >/dev/null
quality=$("$current" report "$live" migration "$today" "$today" \
    traffic-quality --format json)
jq -e '
    .traffic_quality_version == 5 and
    .traffic_classes == [
      {"class":"human-presumed","events":2},
      {"class":"declared-bot","events":1},
      {"class":"automation","events":1},
      {"class":"excluded","events":1},
      {"class":"suspected","events":0}
    ] and ([.signal_evidence[]] | all(. == 0)) and
    (has("shadow") | not) and (has("classifier_v1_events") | not)
' <<<"$quality" >/dev/null

test "$("$current" migrate "$live" "$backup")" = \
    "migrated metadata=v10 events=v7"
rolled_back="$fixture/rolled-back"
"$previous" restore "$backup" "$rolled_back" --verify >/dev/null
test "$("$previous" doctor "$rolled_back")" = \
    "ok metadata=v4 events=v5 sites=1 goals=0 funnels=0 stored_events=5 key=ok"
test "$("$previous" report "$rolled_back" migration "$today" "$today" \
    overview --format json)" = "$before"

million="$fixture/million"
"$previous" init "$million" >/dev/null
"$previous" site add "$million" million Million https://million.example \
    --timezone UTC >/dev/null
million_site_id=$("$previous" site list "$million" |
    awk -F '\t' '$1 == "million" { print $2 }')
"$previous" m3 million "$million" "$million_site_id" >/dev/null
test "$("$previous" doctor "$million")" = \
    "ok metadata=v4 events=v5 sites=1 goals=0 funnels=0 stored_events=1000000 key=ok"
million_backup="$fixture/million-schema5-backup"
"$current" backup "$million" "$million_backup" >/dev/null
"$current" migrate "$million" "$million_backup" \
    >"$fixture/million-migrate.stdout" \
    2>"$fixture/million-migrate.stderr" &
migration_pid=$!
opened_at_ticks=
for _ in {1..500}; do
    if ! kill -0 "$migration_pid" 2>/dev/null; then
        echo "schema-6 million-row migration completed before interruption" >&2
        wait "$migration_pid" || true
        exit 1
    fi
    for fd in /proc/"$migration_pid"/fd/*; do
        if [[ "$(readlink "$fd" 2>/dev/null || true)" == \
            "$million/events.duckdb"* ]]; then
            ticks=$(awk '{ print $14 + $15 }' /proc/"$migration_pid"/stat)
            if [[ -z "$opened_at_ticks" ]]; then
                opened_at_ticks=$ticks
            elif (( ticks >= opened_at_ticks + 2 )); then
                break 2
            fi
        fi
    done
    sleep 0.01
done
if [[ -z "$opened_at_ticks" ]] ||
    (( $(awk '{ print $14 + $15 }' /proc/"$migration_pid"/stat) < opened_at_ticks + 2 )); then
    echo "schema-6 million-row migration never became active on the event database" >&2
    kill -KILL "$migration_pid" 2>/dev/null || true
    wait "$migration_pid" 2>/dev/null || true
    exit 1
fi
kill -KILL "$migration_pid"
if wait "$migration_pid" 2>/dev/null; then
    echo "interrupted schema-6 migration unexpectedly exited successfully" >&2
    exit 1
fi
migration_pid=
test "$("$current" migrate "$million" "$million_backup")" = \
    "migrated metadata=v10 events=v7"
test "$("$current" doctor "$million")" = \
    "ok metadata=v10 events=v7 sites=1 goals=0 funnels=0 stored_events=1000000 key=ok"
million_quality=$("$current" report "$million" million \
    2025-01-01 2025-01-31 traffic-quality --format json)
jq -e '
    .traffic_quality_version == 5 and
    .signal_evidence.client_signal_v1_events == 0 and
    .signal_evidence.webdriver_events == 0
' <<<"$million_quality" >/dev/null
test "$("$current" migrate "$million" "$million_backup")" = \
    "migrated metadata=v10 events=v7"
million_rollback="$fixture/million-rollback"
"$previous" restore "$million_backup" "$million_rollback" --verify >/dev/null
test "$("$previous" doctor "$million_rollback")" = \
    "ok metadata=v4 events=v5 sites=1 goals=0 funnels=0 stored_events=1000000 key=ok"

printf '%s\n' "$quality"
echo "exact schema-5 mapping, disposition, million-row interruption/retry, repeat, backup, restore, and rollback passed"
