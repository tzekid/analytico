#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <analytico-binary>" >&2
    exit 2
fi

binary=$1
fixture_dir=$(mktemp -d)
trap 'rm -rf -- "$fixture_dir"' EXIT

"$binary" init "$fixture_dir" >/dev/null
"$binary" analysis traffic-quality-seed "$fixture_dir" >/dev/null
"$binary" site add "$fixture_dir" empty Empty https://empty.example \
    --timezone UTC >/dev/null

quality_json=$(
    "$binary" report "$fixture_dir" quality 2025-12-31 2026-01-03 \
        traffic-quality --format json
)
expected_json='{"metric_version":2,"traffic_quality_version":4,"site":"quality","start_date":"2025-12-31","end_date":"2026-01-03","report":"traffic-quality","page":1,"limit":25,"next_page":null,"distinct_people":3,"visitor_days":5,"persistent_people":1,"ephemeral_people":1,"legacy_people":1,"persistent_basis_points":3333,"zero_engagement_single_event_sessions":3,"identity_quality":[{"quality":"persistent","events":9,"visitor_days":3},{"quality":"ephemeral","events":1,"visitor_days":1},{"quality":"legacy_daily","events":1,"visitor_days":1}],"exclusion_sources":[{"source":"tracker","events":1},{"source":"network","events":1},{"source":"both","events":1}],"traffic_classes":[{"class":"human-presumed","events":11},{"class":"declared-bot","events":1},{"class":"automation","events":0},{"class":"excluded","events":3},{"class":"suspected","events":0}],"signal_evidence":{"client_signal_v1_events":0,"webdriver_events":0,"trusted_interaction_events":0,"visible_events":0,"prerendered_events":0,"client_hint_mismatch_events":0,"client_hint_absent_expected_events":0,"accept_language_present_events":0},"classifier_rules":[{"class":"human-presumed","classifier_version":0,"rule":"","events":11},{"class":"declared-bot","classifier_version":0,"rule":"legacy-device-bot","events":1},{"class":"excluded","classifier_version":1,"rule":"exclude.both","events":1},{"class":"excluded","classifier_version":1,"rule":"exclude.network","events":1},{"class":"excluded","classifier_version":1,"rule":"exclude.tracker","events":1}],"days":[{"date":"2025-12-31","new_anonymous_identities":1,"bot_events":0},{"date":"2026-01-01","new_anonymous_identities":0,"bot_events":0},{"date":"2026-01-02","new_anonymous_identities":0,"bot_events":0},{"date":"2026-01-03","new_anonymous_identities":2,"bot_events":1}]}'
test "$quality_json" = "$expected_json"

boundary_json=$(
    "$binary" report "$fixture_dir" quality 2026-01-02 2026-01-02 \
        traffic-quality --format json
)
jq -e '
    .distinct_people == 1 and
    .visitor_days == 1 and
    .zero_engagement_single_event_sessions == 0 and
    .days == [{"date":"2026-01-02","new_anonymous_identities":0,"bot_events":0}]
' <<<"$boundary_json" >/dev/null

quality_table=$(
    "$binary" report "$fixture_dir" quality 2025-12-31 2026-01-03 \
        traffic-quality --format table
)
[[ "$quality_table" == *$'metric_version=2\ttraffic_quality_version=4\tsite=quality\tutc_range=2025-12-31..2026-01-03\treport=traffic-quality'* ]]
[[ "$quality_table" == *$'distinct_people\tvisitor_days\tpersistent_people\tephemeral_people\tlegacy_people\tpersistent_basis_points\tzero_engagement_single_event_sessions\n3\t5\t1\t1\t1\t3333\t3'* ]]
[[ "$quality_table" == *$'persistent\t9\t3\nephemeral\t1\t1\nlegacy_daily\t1\t1'* ]]
[[ "$quality_table" == *$'exclusion_source\tevents\ntracker\t1\nnetwork\t1\nboth\t1'* ]]
[[ "$quality_table" == *$'traffic_class\tevents\nhuman-presumed\t11\ndeclared-bot\t1\nautomation\t0\nexcluded\t3\nsuspected\t0'* ]]
[[ "$quality_table" == *$'signal_evidence\tevents\nclient_signal_v1\t0\nwebdriver\t0\ntrusted_interaction\t0\nvisible\t0\nprerendered\t0\nclient_hint_mismatch\t0\nclient_hint_absent_expected\t0\naccept_language_present\t0'* ]]
[[ "$quality_table" == *$'classifier_rule\ttraffic_class\tclassifier_version\tevents\n(none)\thuman-presumed\t0\t11'* ]]
[[ "$quality_table" == *$'2025-12-31\t1\t0\n2026-01-01\t0\t0\n2026-01-02\t0\t0\n2026-01-03\t2\t1'* ]]

quality_csv=$(
    "$binary" report "$fixture_dir" quality 2025-12-31 2026-01-03 \
        traffic-quality --format csv
)
[[ "$quality_csv" == *'2,4,summary,all,,,,,3,1,1,1,3333,3,,,'* ]]
[[ "$quality_csv" == *'2,4,traffic_class,human-presumed,11'* ]]
[[ "$quality_csv" == *'2,4,signal_evidence,client_signal_v1,0'* ]]
[[ "$quality_csv" == *'2,4,classifier_rule,legacy-device-bot,1'* ]]
[[ "$quality_csv" == *'2,4,day,2026-01-03,,,2,1'* ]]
awk -F, 'NF != 17 { exit 1 }' <<<"$quality_csv"

empty_json=$(
    "$binary" report "$fixture_dir" empty 2025-12-31 2026-01-03 \
        traffic-quality --format json
)
jq -e '
    .distinct_people == 0 and
    .visitor_days == 0 and
    .zero_engagement_single_event_sessions == 0 and
    ([.identity_quality[] | .events, .visitor_days] | all(. == 0)) and
    ([.exclusion_sources[] | .events] | all(. == 0)) and
    ([.traffic_classes[] | .events] | all(. == 0)) and
    ([.signal_evidence[]] | all(. == 0)) and
    (.classifier_rules | length) == 0 and
    (.days | length) == 4 and
    ([.days[] | .new_anonymous_identities, .bot_events] | all(. == 0))
' <<<"$empty_json" >/dev/null

page_one=$(
    "$binary" report "$fixture_dir" empty 2025-01-01 2026-02-04 \
        traffic-quality --format json --limit 100 --page 1
)
page_four=$(
    "$binary" report "$fixture_dir" empty 2025-01-01 2026-02-04 \
        traffic-quality --format json --limit 100 --page 4
)
jq -e '.page == 1 and .next_page == 2 and (.days | length) == 100' \
    <<<"$page_one" >/dev/null
jq -e '.page == 4 and .next_page == null and (.days | length) == 100' \
    <<<"$page_four" >/dev/null

overview=$(
    "$binary" report "$fixture_dir" quality 2025-12-31 2026-01-03 \
        overview --format json
)
test "$overview" = \
    '{"metric_version":1,"site":"quality","start_date":"2025-12-31","end_date":"2026-01-03","report":"overview","page_views":6,"visitor_days":5,"sessions":5,"custom_events":3,"bot_events":1}'

if grep -Eiq '[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}|user-a' \
    <<<"$quality_json$quality_table$quality_csv"; then
    echo "traffic-quality output leaked a stored identity" >&2
    exit 1
fi

if "$binary" report "$fixture_dir/not-opened" quality \
    2025-12-31 2026-01-03 traffic-quality --sort label >/dev/null 2>&1; then
    echo "non-list traffic-quality report accepted list options" >&2
    exit 1
fi
test ! -e "$fixture_dir/not-opened"

printf '%s\n' "$quality_json"
