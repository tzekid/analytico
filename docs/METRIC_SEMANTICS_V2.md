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
`a:`, `e:`, and `l:` namespaces around their anonymous ID. Bots are excluded.

This is a modeled pseudonymous identity count, not a claim about physical
humans. The result therefore carries persistent, ephemeral, and legacy person
counts plus persistent coverage. Legacy daily identities remain separate
across days and are never linked into a persistent person.

### Visitor-days

A visitor-day counts a product-eligible daily identity once per date. It is not
a person count: one person present on three dates contributes three
visitor-days. The metric-v1 compatibility value counts non-bot
`visitor_day_start` rows over receipt UTC dates. It must be labeled
`visitor-days`, never `daily visitors` or `people`.

The #66 Overview diagnostic is intentionally a compatibility bridge: both its
visitor-day value and its distinct-person selection use the existing received
UTC report range so they are comparable beside the current Overview headline.
This additive metric-v2 diagnostic does not change ordinary `AnalysisQuery`
site-local semantics or any existing metric-v1 output. A later Overview
migration must move both displayed values to one site-local range together.

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

## Traffic-quality diagnostics version 2

The bounded `traffic-quality` report makes no network or runtime-data-file
request. Version 1 was measure-only. Version 2 retains those observations and
adds D31's visible self-exclusion accounting. Until event schema 5 introduces
the permanent `traffic_class`, the current `device_category = 'bot'` verdict is
the only bot boundary and its limitations remain visible.

For the inclusive received-UTC report range, it exposes:

- distinct people and their persistent/ephemeral/legacy coverage as defined
  above;
- non-bot, non-self-excluded accepted events and metric-v1 visitor-days split
  by raw `identity_quality` (`persistent`, `ephemeral`, `legacy_daily`); bot
  events are reported separately so they do not silently overlap the quality
  split;
- non-bot sessions with a meaningful event in range and exactly one meaningful
  page-view or custom event across the whole stored session, total
  `engagement_ms = 0`, and maximum `max_scroll_depth = 0`; this is a diagnostic
  observation, not a bot or suspected-traffic classification;
- new anonymous identities per receipt UTC day: the first accepted non-bot
  meaningful event for each persistent or ephemeral anonymous ID over the
  site's full history, excluding migrated legacy daily IDs; and
- all currently classified bot events per receipt UTC day.

It also reports stored events by the closed event-schema-4
`exclusion_source`: tracker self-flag, configured network prefix, or both.
Self-excluded rows remain in DuckDB and in diagnostics but are ineligible for
product visitor, person, session, page, event, goal, funnel, property, and
analysis metrics. The operator choice is not a bot verdict and does not weaken
the positive-human-evidence veto used by later heuristic classification.
An excluded row never consumes the persisted visitor-day or session-start
boundary needed by a later eligible row with the same compatibility identity
or client session. An excluded identify row does not create an identity link,
so later eligible traffic cannot inherit product identity from an excluded
observation.

Every date in the requested range appears, including zero days. The request is
limited to 400 dates and one DuckDB deadline; CLI and dashboard results page
daily rows at no more than 100 rows. Positive engagement or scroll evidence
necessarily removes a session from the zero-engagement observation; no soft
signal affects product metrics in this phase.

## Engagement

An engaged session has at least 10 seconds of active engagement, at least two
page views, or an active goal conversion. Engagement rate is engaged sessions
divided by sessions; bounce rate is its complement.

## Conversions and revenue

Conversions retain explicit event/session/person denominators. Revenue sums
exact stored decimal values per currency; currencies are never silently
combined and no foreign-exchange conversion occurs.

## Bots

Bots are excluded from product visitor, session, and audience metrics and
counted in diagnostics. Classification is versioned by the governing traffic
class contract. #66 does not reinterpret history. D31's temporary event schema
4 stores self-exclusion explicitly; #68 owns event schema 5 and migrates every
nonzero `exclusion_source` to permanent `traffic_class=excluded` before
removing the temporary field.
