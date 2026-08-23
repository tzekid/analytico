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
    .overview_visitors == 4 and
    .overview_comparison_visitors == 1 and
    .overview_sessions == 4 and
    .overview_page_views == 4 and
    .overview_engaged_sessions == 2 and
    .overview_conversions == 4 and
    .overview_converting_visitors == 1 and
    .overview_revenue_currencies == 3 and
    .overview_history_only_currency == "GBP" and
    .overview_detail_trend_visitors == 4 and
    .overview_detail_comparison_visitors == 1 and
    .overview_detail_content_rows > 0 and .overview_detail_content_rows <= 5 and
    .overview_detail_acquisition_rows > 0 and .overview_detail_acquisition_rows <= 5 and
    .overview_detail_conversion_rows == 2 and
    .overview_detail_audience_rows > 0 and .overview_detail_audience_rows <= 5 and
    .overview_detail_revenue_eur == "12.500000" and
    .overview_detail_health_protocol_total > 0 and
    .overview_detail_ceiling_reached_days == 1 and
    .overview_detail_empty_dense_zero == true and
    .overview_detail_cache_invalidated == true and
    .overview_detail_ceiling_cache_key_exact == true and
    .overview_no_comparison == true and
    .overview_empty_revenue_omitted == true and
    .overview_legacy_local_boundary_exact == true and
    .overview_ineligible_boundary_later_eligible_exact == true and
    .overview_non_page_boundary_excluded == true and
    .overview_nonmeaningful_goal_not_engaged == true and
    .delayed_event_delay_micros == 3600000000 and
    .delayed_event_offset_minutes == 60 and
    .delayed_event_hour == "2026-01-03T01:00" and
    .cross_midnight_landing_preserved == true and
    .channel_v1_paid_search == true and
    (.semantic_elapsed_ms | type) == "number" and
    .timeout_interrupted_and_reused == true
' <<<"$result" >/dev/null
printf '%s\n' "$result"
