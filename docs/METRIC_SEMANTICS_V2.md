# Metric semantics v2

Metric semantics version 2 uses canonical identities, explicit compatibility
coverage, and the site's configured local-date context for ordinary
`AnalysisQuery` product metrics. Exports state their metric version and exact
range basis. Metric-v1 CLI reports retain their documented UTC compatibility
semantics until a separate removal issue.

## Traffic

### Page views

Count accepted page-view rows.

### Distinct people in range

Count distinct canonical person keys with at least one accepted meaningful
page-view or custom event in range. Engagement and identify rows do not create
a person independently. A linked persistent identity uses `u:<user_id>`;
otherwise persistent, ephemeral, and migrated legacy identities use disjoint
`a:`, `e:`, and `l:` namespaces around their anonymous ID. Product-ineligible
traffic is excluded under the versioned predicate below.

This is a modeled pseudonymous identity count, not a claim about physical
humans. The result therefore carries persistent, ephemeral, and legacy person
counts plus persistent coverage. Legacy daily identities remain separate
across days and are never linked into a persistent person.

### Visitor-days

A visitor-day counts a product-eligible daily identity once per date. With D34
strict mode off, eligibility retains `traffic_class IN (human-presumed,
suspected)` and includes derived query-time suspects. Strict mode additionally
excludes current query-classifier-v1 suspect sessions. It is not a person
count: one person present on three dates contributes three visitor-days. The
default metric-v1 compatibility value retains stored `visitor_day_start` rows;
strict reports derive distinct eligible daily identities so a suspect first
row cannot hide later human activity. It must be labeled
`visitor-days`, never `daily visitors` or `people`.

The #66 traffic-quality diagnostic remains an intentional compatibility
surface: both its visitor-day value and its distinct-person selection use the
existing received-UTC report range so they are comparable. Issue #26 removes
those diagnostic values from the Overview headline and replaces the complete
headline set with one site-local metric-v2 result. The diagnostic remains
visible below the headline with its received-UTC basis stated locally; it does
not relabel or change any metric-v1 output.

For new protocol-v2 rows marked `identity_quality=ephemeral`, D31 derives the
metric-v1 compatibility visitor-day from the same keyed site, receipt-UTC date,
normalized network prefix, and coarse client categories as protocol v1. The
page-lifetime anonymous UUID remains stored and visible as ephemeral identity,
but no longer makes every storage-blocked page load a distinct visitor-day.

### New and returning visitors

New visitors are compatible persistent people whose first accepted meaningful
event for the site occurs in range. Returning visitors are compatible people in
range whose first accepted meaningful event predates the range.

### Sessions

Count distinct session IDs with at least one meaningful event in range. A
session crossing a range boundary is included when activity occurs in range.

### Page views per session

Page views divided by sessions, with zero-safe formatting.

## Traffic-quality diagnostics version 5

The bounded `traffic-quality` report makes no network or runtime-data-file
request. Version 1 was measure-only, version 2 added D31 exclusion accounting,
version 3 carried D32's one-release classifier shadow, and version 4 replaced
it with D33's permanent class plus bounded signal evidence. Version 5 retains
those stored facts and adds D34's reversible query classifier, site policy, and
fixed data-health fields.

The product-eligible base predicate is exactly:

```text
traffic_class IN (human-presumed, suspected)
```

Declared bots, automation, and excluded rows are outside every product metric.
Default-off reports also include D34 query-time suspected sessions. Strict-on
reports omit only current suspects after the complete human-evidence veto. The
schema-7 migration preserves stored classes and maps network-day evidence to
unknown; it reconstructs neither discarded inputs nor soft verdicts.

Query classifier version 1 evaluates the first meaningful signal-v1
human-presumed event in a session. At least two of fast beacon, narrow
viewport, never visible, expected hint absent, and language absent create a raw
candidate. A current suspect additionally has exactly one meaningful event and
no trusted interaction, engagement, scroll, active-goal conversion, second page
view, or persistent return. Prerendering and unknown evidence never count.
The raw cohort remains visible; later veto evidence records a contradiction.

For the inclusive received-UTC report range, it exposes:

- distinct people and their persistent/ephemeral/legacy coverage as defined
  above;
- product-eligible accepted events and metric-v1 visitor-days split
  by raw `identity_quality` (`persistent`, `ephemeral`, `legacy_daily`);
  bot-class and excluded observations are reported separately so they do not silently
  overlap the quality split;
- product-eligible sessions with a meaningful event in range and exactly one meaningful
  page-view or custom event across the whole stored session, total
  `engagement_ms = 0`, and maximum `max_scroll_depth = 0`; this is a diagnostic
  observation, not a bot or suspected-traffic classification;
- new anonymous identities per receipt UTC day: the first product-eligible
  meaningful event for each persistent or ephemeral anonymous ID over the
  site's full history, excluding migrated legacy daily IDs; and
- all declared-bot and automation rows per receipt UTC day;
- all five stored traffic-class totals;
- fixed counts for client-signal-v1 coverage, webdriver, any trusted
  interaction, ever-visible, prerendered, client-hint mismatch,
  client-hint absent-when-expected, and Accept-Language presence; and
- grouped class/version/rule totals, ordered deterministically and capped at 64
  rows;
- heuristic availability/version, raw candidates, current low-quality sessions,
  contradicted candidates, contradiction basis points, and the current-suspect
  versus declared-bot shadow counts;
- strict mode, the configured daily accepted-event ceiling, total accepted
  events, and days whose site-local accepted count reached the ceiling; and
- for each received-UTC day, the number of keyed network-prefix groups over 64
  fresh persistent/ephemeral anonymous identities and the maximum group count.
  The prefix pseudonym is never returned.

It continues to report stored exclusions by the permanent rules
`exclude.tracker`, `exclude.network`, and `exclude.both`. Excluded rows remain
in DuckDB and diagnostics but are ineligible for
product visitor, person, session, page, event, goal, funnel, property, and
analysis metrics. The operator choice is not a bot verdict and does not weaken
the positive-human-evidence veto used by later heuristic classification.
An excluded row never consumes the persisted visitor-day or session-start
boundary needed by a later eligible row with the same compatibility identity
or client session. An excluded identify row does not create an identity link,
so later eligible traffic cannot inherit product identity from an excluded
observation.

Every date in the requested range appears, including zero days. Daily rows
include accepted events, declared bots, current suspects, identity-mint anomaly
groups/maxima, and ceiling state. The daily page and bounded rule groups remain
one bound query plan under one deadline. The request is limited to 400 dates;
CLI and dashboard results page daily rows at no more than 100. Diagnostics are
independent of strict mode so the owner can compare the shadow before enabling
filtering. A goal overflow reports unavailable heuristics and produces zero
suspects rather than partially evaluating the conversion veto.

## Engagement

An engaged session has at least 10 seconds of active engagement, at least two
page views, or an active goal conversion. Engagement rate is engaged sessions
divided by sessions; bounce rate is its complement.

## Conversions and revenue

Conversions retain explicit event/session/person denominators. Revenue sums
exact stored decimal values per currency; currencies are never silently
combined and no foreign-exchange conversion occurs.

The fixed Overview conversion count is the sum of matches across every active
goal. One accepted meaningful event contributes once for each active goal
definition it satisfies; two distinct goals with the same selector therefore
still contribute two conversions. The Overview conversion rate counts distinct
canonical people
with at least one active-goal match and divides by all visitors under the same
site-local range and product-traffic policy. With no active goals, both the
conversion count and converting-person numerator are zero.

Overview revenue is one exact value per observed three-letter currency. A
currency observed on eligible value-bearing traffic before the selected range
remains visible with an exact current zero, while a site that has never received
eligible value data has no Revenue card. Current and comparison amounts in
different currencies are never combined. The site-default currency added by
the site-creation/settings work may later identify the ordinary card without
changing these exact per-currency rows.

## Overview comparison

The fixed Overview result contains Visitors, Sessions, Page views, Engagement
rate, Conversions, visitor Conversion rate, conditional Revenue, and current/
comparison identity coverage. Counts and exact values use signed percentage
change when the comparison is nonzero and a signed absolute `new` state when it
is zero. Rates use percentage-point differences only when both denominators are
nonzero. A rate with no denominator is unavailable, not zero. An unresolved or
unselected comparison is unavailable rather than a zero period. A resolved
period with no eligible rows is a valid zero for count and exact-value metrics.

All fixed fields execute through one bounded DuckDB statement and one interrupt
deadline. Current and comparison ranges each derive full-session engagement
facts independently, so adjacent or overlapping ranges do not share mutable
state. The existing maximums of 32 active goals, 16 currency series, 400 local
dates, one report thread, and a two-second deadline apply.

## Overview trend and answer panels

The fixed Overview trend selects exactly one of Visitors, Sessions, Page views,
all-active-goal Conversions, or Revenue. Revenue always selects one explicit
observed currency. Its exact signed decimal is preserved in the visible table
and in server-side layout input; currencies are never combined. Count and
exact-value intervals with no eligible rows are exact zero intervals, while an
unavailable comparison remains unavailable. Current and comparison retain
their own ordered calendar labels when a leap or DST boundary gives them
different shapes.

An Overview point handoff does not change metric semantics. Its highlighted
interval is presentation context only until the full Trend consumer ships; the
working Analyze report retains the original complete date range and states
that no interval filter was applied.

The answer panels use these fixed semantics:

- Content ranks paths by accepted page views, shows distinct canonical people
  with a page view for the path, and divides each row's page views by all
  current page views for share.
- Acquisition attributes each included session to its deterministic first page
  view's external referrer host, or Direct when absent. It shows sessions and
  converting sessions divided by sessions.
- Conversions counts distinct canonical people separately for every active
  goal selector. Identical selectors under different goal IDs remain distinct
  rows. The displayed rate divides each goal's converting people by all
  current visitors.
- Audience attributes each included session to the country on its first
  meaningful event, using Unknown for the stored `ZZ` value, and ranks by
  sessions. The companion Devices destination remains directly reachable.

Each panel uses the same current site-local range, canonical identity,
product-traffic/strict policy, full-session attribution, and active-goal
snapshot as the headline. Each returns at most five rows ordered by its primary
count descending and label ascending.

## Bots

Traffic classification is versioned by D32, D33, D34, and
`UA_CLASSIFIER_V1.md`. Historical source-zero rows use classifier version zero
because their discarded UAs cannot be recovered. Classifier version 1 is the
D32 UA boundary; version 2 adds D33 hard browser/receipt evidence. Exclusions
retain their explicit version-1 rules and take precedence. The permanent
product predicate above supersedes the completed D32 shadow. D34's soft result
exists only in versioned query SQL and is human-evidence-vetoed. Every
successfully accepted event remains stored. A new event beyond the explicit
daily operator ceiling receives 429 and is never falsely acknowledged.

## Session list records

D45 selects a session when at least one product-eligible Page or custom event
inside the chosen site-local range satisfies the complete FilterSet and any
selected active Goal. The returned record then summarizes every retained
product-eligible event for that same site and session UUID, including retained
activity outside the range. Crossing sessions therefore keep their full
context without allowing an out-of-range-only session into the list.

Start and last activity are the minimum and maximum plausible occurrence times
in the retained session. Duration is their nonnegative difference; active
engagement is the sum of retained engagement fragments. Page/custom counts are
separate. Acquisition and landing use the first retained page view; a
custom-event-only session is Direct / Unknown with no landing. Country,
device, and browser use the first retained meaningful event.

The record conversion count is the sum of matches across current active Goal
definitions, including one count per distinct Goal when selectors overlap.
The converted state is count greater than zero. Exact value rows sum each
currency independently and retain its contributing value count. The list does
not combine currencies, apply exchange rates, or relabel archived definitions
as active conversions.

Current state is inferred only from the latest authoritative receipt. It is
true through exactly 30 minutes after that receipt, false after the boundary,
and false for a future receipt relative to the precise microsecond request
clock. It does not assert a live connection. Persistent, ephemeral, and legacy
identity qualities remain visibly distinct; only an explicit stored identity
link produces an identified user.
