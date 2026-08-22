#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: e2e-analysis.sh <analytico-binary>" >&2
    exit 2
fi

analytico_binary=$1
fixture_dir=$(mktemp -d)
trap 'rm -rf -- "$fixture_dir"' EXIT

result=$("$analytico_binary" analysis semantic-probe "$fixture_dir")
jq -e '
    .metric_version == 2 and
    .visitors == 4 and
    .engaged_sessions == 2 and
    .returning_visitors == 1 and
    .desktop_sessions == 1 and
    .identified_trait_visitors == 1 and
    .event_filter_cardinality == 2 and
    .event_filter_next_page == 2 and
    .typed_property_conversions == 1 and
    .currencies == 2 and
    .persistent_people == 2 and
    .ephemeral_people == 1 and
    .legacy_people == 1 and
    .comparison_points == 1 and
    .comparison_total == 1 and
    .comparison_persistent_people == 1 and
    .cross_midnight_landing_preserved == true and
    .channel_v1_paid_search == true and
    (.semantic_elapsed_ms | type) == "number" and
    .timeout_interrupted_and_reused == true
' <<<"$result" >/dev/null
printf '%s\n' "$result"
