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
fixture_dir=$(mktemp -d "$PWD/.zig-cache/m3-e2e.XXXXXX")
trap 'rm -rf -- "$fixture_dir"' EXIT

expect_failure() {
    if "$@" >"$fixture_dir/rejected.stdout" 2>"$fixture_dir/rejected.stderr"; then
        echo "command unexpectedly succeeded: $*" >&2
        exit 1
    fi
}

assert_contains() {
    local actual=$1
    local expected=$2
    if [[ "$actual" != *"$expected"* ]]; then
        echo "missing expected report fragment: $expected" >&2
        printf '%s\n' "$actual" >&2
        exit 1
    fi
}

report_json() {
    "$binary" report "$fixture_dir" demo 2025-01-01 2025-01-02 \
        "$@" --format json
}

"$binary" init "$fixture_dir" >/dev/null
"$binary" site add "$fixture_dir" demo "Demo" https://demo.example \
    --timezone UTC >/dev/null
"$binary" site add "$fixture_dir" empty "Empty" https://empty.example \
    --timezone UTC >/dev/null
site_id=$("$binary" site list "$fixture_dir" |
    awk -F '\t' '$1 == "demo" { print $2 }')

"$binary" goal add "$fixture_dir" demo signups event signup >/dev/null
"$binary" goal add "$fixture_dir" demo pricing path /pricing >/dev/null
"$binary" goal add "$fixture_dir" demo pricing-prefix prefix /pr >/dev/null
"$binary" funnel add "$fixture_dir" demo signup-flow \
    'path=/' 'path=/pricing' 'event=signup' >/dev/null
"$binary" m3 seed "$fixture_dir" "$site_id" >/dev/null

overview=$(report_json overview)
test "$overview" = \
    '{"metric_version":1,"site":"demo","start_date":"2025-01-01","end_date":"2025-01-02","report":"overview","page_views":8,"visitor_days":4,"sessions":5,"custom_events":5,"bot_events":1}'

pages=$(report_json pages)
assert_contains "$pages" \
    '"rows":[{"path":"/pricing","page_views":3,"visitor_days":3},{"path":"/","page_views":2,"visitor_days":2},{"path":"/docs","page_views":1,"visitor_days":1},{"path":"/exit-a","page_views":1,"visitor_days":1},{"path":"/landing","page_views":1,"visitor_days":1}]'

entries=$(report_json entries)
assert_contains "$entries" \
    '"rows":[{"path":"/","sessions":2,"visitor_days":2},{"path":"/exit-a","sessions":1,"visitor_days":1},{"path":"/landing","sessions":1,"visitor_days":1},{"path":"/pricing","sessions":1,"visitor_days":1}]'

exits=$(report_json exits)
assert_contains "$exits" \
    '"rows":[{"path":"/pricing","sessions":3,"visitor_days":3},{"path":"/docs","sessions":1,"visitor_days":1},{"path":"/exit-a","sessions":1,"visitor_days":1}]'

sources=$(report_json sources)
assert_contains "$sources" \
    '"rows":[{"source":"Direct / Unknown","sessions":2,"visitor_days":2},{"source":"search.example","sessions":2,"visitor_days":2},{"source":"social.example","sessions":1,"visitor_days":1}]'

campaigns=$(report_json campaigns source)
assert_contains "$campaigns" \
    '"rows":[{"utm_source":"newsletter","sessions":2,"visitor_days":2},{"utm_source":"=SUM(\"x\")\nnext","sessions":1,"visitor_days":1},{"utm_source":"social","sessions":1,"visitor_days":1}]'
assert_contains "$(report_json campaigns medium)" \
    '"utm_medium":"(not set)","sessions":2'
assert_contains "$(report_json campaigns campaign)" \
    '"utm_campaign":"winter","sessions":2'
assert_contains "$(report_json campaigns term)" '"report":"campaigns"'
assert_contains "$(report_json campaigns content)" '"report":"campaigns"'
assert_contains "$(report_json campaigns all)" '"campaign_tuple":'

assert_contains "$(report_json countries)" \
    '"rows":[{"country":"US","sessions":2,"visitor_days":2},{"country":"CA","sessions":1,"visitor_days":1},{"country":"DE","sessions":1,"visitor_days":1},{"country":"Unknown","sessions":1,"visitor_days":1}]'
assert_contains "$(report_json browsers)" \
    '"rows":[{"browser":"Chrome","sessions":2,"visitor_days":2},{"browser":"Firefox","sessions":1,"visitor_days":1},{"browser":"Safari","sessions":1,"visitor_days":1},{"browser":"Unknown","sessions":1,"visitor_days":1}]'
assert_contains "$(report_json operating-systems)" \
    '"rows":[{"operating_system":"Linux","sessions":3,"visitor_days":2},{"operating_system":"Unknown","sessions":1,"visitor_days":1},{"operating_system":"macOS","sessions":1,"visitor_days":1}]'
assert_contains "$(report_json devices)" \
    '"rows":[{"device":"desktop","sessions":3,"visitor_days":2},{"device":"mobile","sessions":1,"visitor_days":1},{"device":"unknown","sessions":1,"visitor_days":1}]'
assert_contains "$(report_json events)" \
    '"rows":[{"event":"signup","event_count":4,"sessions":3},{"event":"download","event_count":1,"sessions":1}]'

test "$(report_json goal signups)" = \
    '{"metric_version":1,"site":"demo","start_date":"2025-01-01","end_date":"2025-01-02","report":"goal","goal":"signups","total_matches":4,"matching_sessions":3,"eligible_sessions":5,"conversion_rate":0.600000}'
assert_contains "$(report_json goal pricing)" \
    '"total_matches":3,"matching_sessions":3'
assert_contains "$(report_json goal pricing-prefix)" \
    '"total_matches":4,"matching_sessions":3'
test "$(report_json funnel signup-flow)" = \
    '{"metric_version":1,"site":"demo","start_date":"2025-01-01","end_date":"2025-01-02","report":"funnel","funnel":"signup-flow","eligible_sessions":5,"steps":[{"name":"/","sessions":2,"step_rate":0.400000,"overall_rate":0.400000},{"name":"/pricing","sessions":2,"step_rate":1.000000,"overall_rate":0.400000},{"name":"signup","sessions":2,"step_rate":1.000000,"overall_rate":0.400000}]}'

page_one=$(report_json pages --limit 2 --page 1)
page_two=$(report_json pages --limit 2 --page 2)
page_three=$(report_json pages --limit 2 --page 3)
assert_contains "$page_one" \
    '"page":1,"limit":2,"next_page":2,"rows":[{"path":"/pricing"'
assert_contains "$page_two" \
    '"page":2,"limit":2,"next_page":3,"rows":[{"path":"/docs"'
assert_contains "$page_three" \
    '"page":3,"limit":2,"next_page":null,"rows":[{"path":"/landing"'
assert_contains "$(report_json pages --sort label)" \
    '"rows":[{"path":"/","page_views":2'

empty_overview=$(
    "$binary" report "$fixture_dir" empty 2025-01-01 2025-01-02 \
        overview --format json
)
assert_contains "$empty_overview" \
    '"page_views":0,"visitor_days":0,"sessions":0,"custom_events":0,"bot_events":0'
empty_pages=$(
    "$binary" report "$fixture_dir" empty 2025-01-01 2025-01-02 \
        pages --format json
)
assert_contains "$empty_pages" '"next_page":null,"rows":[]'

table=$(
    "$binary" report "$fixture_dir" demo 2025-01-01 2025-01-02 \
        overview --format table
)
assert_contains "$table" \
    $'metric_version=1\tsite=demo\tutc_range=2025-01-01..2025-01-02'
assert_contains "$table" \
    $'page_views\tvisitor_days\tsessions\tcustom_events\tbot_events'
campaign_table=$(
    "$binary" report "$fixture_dir" demo 2025-01-01 2025-01-02 \
        campaigns source --format table
)
assert_contains "$campaign_table" '=SUM("x")\nnext'

csv=$(
    "$binary" report "$fixture_dir" demo 2025-01-01 2025-01-02 \
        campaigns source --format csv
)
assert_contains "$csv" $'"\'=SUM(""x"")\nnext",1,1'
goal_csv=$(
    "$binary" report "$fixture_dir" demo 2025-01-01 2025-01-02 \
        goal signups --format csv
)
assert_contains "$goal_csv" '"signups",4,3,5,0.600000'

no_io_dir="$fixture_dir/request-parser-must-not-open"
expect_failure "$binary" report "$no_io_dir" demo \
    2025-01-03 2025-01-02 overview
expect_failure "$binary" report "$no_io_dir" demo \
    2025-01-01 2026-02-05 overview
expect_failure "$binary" report "$no_io_dir" demo \
    2025-02-29 2025-03-01 overview
expect_failure "$binary" report "$no_io_dir" demo \
    2025-01-01 2025-01-02 unknown
expect_failure "$binary" report "$no_io_dir" demo \
    2025-01-01 2025-01-02 campaigns unknown
expect_failure "$binary" report "$no_io_dir" demo \
    2025-01-01 2025-01-02 pages --format yaml
expect_failure "$binary" report "$no_io_dir" demo \
    2025-01-01 2025-01-02 pages --sort random
expect_failure "$binary" report "$no_io_dir" demo \
    2025-01-01 2025-01-02 pages --limit 0
expect_failure "$binary" report "$no_io_dir" demo \
    2025-01-01 2025-01-02 pages --limit 101
expect_failure "$binary" report "$no_io_dir" demo \
    2025-01-01 2025-01-02 pages --page 0
expect_failure "$binary" report "$no_io_dir" demo \
    2025-01-01 2025-01-02 pages --mystery value
expect_failure "$binary" report "$no_io_dir" demo \
    2025-01-01 2025-01-02 goal
expect_failure "$binary" report "$no_io_dir" demo \
    2025-01-01 2025-01-02 overview --sort label
test ! -e "$no_io_dir"

mv "$fixture_dir/events.duckdb" "$fixture_dir/events.saved.duckdb"
expect_failure "$binary" report "$fixture_dir" demo \
    2025-01-01 2025-01-02 goal missing
expect_failure "$binary" report "$fixture_dir" demo \
    2025-01-01 2025-01-02 funnel missing
test ! -e "$fixture_dir/events.duckdb"
mv "$fixture_dir/events.saved.duckdb" "$fixture_dir/events.duckdb"

timeout_output=$(
    "$binary" m3 timeout "$fixture_dir" 2>"$fixture_dir/timeout.stderr"
)
test "$timeout_output" = "report timeout interrupted and connection reused"
grep -q 'Interrupted' "$fixture_dir/timeout.stderr"
test "$("$binary" doctor "$fixture_dir")" = \
    "ok metadata=v4 events=v5 sites=2 goals=3 funnels=1 stored_events=14 key=ok"

legacy_dir="$fixture_dir/legacy"
mkdir "$legacy_dir"
test "$("$binary" m3 legacy-create "$legacy_dir")" = \
    "legacy event schema v1 fixture committed"
test "$("$binary" m3 legacy-verify "$legacy_dir")" = \
    "legacy event schema v1 migrated to v3"
test "$("$binary" m3 legacy-verify "$legacy_dir")" = \
    "legacy event schema v1 migrated to v3"

if rg -n 'allocPrint.*SELECT|fmt.*SELECT' src/store/reports.zig >/dev/null; then
    echo "report SQL unexpectedly contains request-formatted query text" >&2
    exit 1
fi

echo "M3 real-process report checks passed"
