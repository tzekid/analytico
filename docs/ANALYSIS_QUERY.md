# Typed analysis query contract

Status: normative Analytico 1.0 query contract. Issue #24 owns the first
implementation and executable evidence. This contract does not change the
frozen metric-v1 CLI report outputs.

## 1. Boundary and versions

`AnalysisQuery` is the closed application model for ordinary metric-v2 Trend
and Breakdown questions. It is not a SQL AST, public analytics API, saved-view
schema migration, or replacement result type for funnels, paths, retention,
sessions, profiles, or Live traffic.

- Query schema: `1`.
- Metric semantics: `2`.
- Site-local inclusive range: at most 400 days.
- One Breakdown dimension.
- At most three explicit Trend series; each series is one validated query.
- At most 16 exact currency series and 6,400 Trend rows; overflow is a typed
  failure rather than silent truncation.
- Interactive limit: 1–100 rows; page: 1–1,000,000.
- FilterSet: `all` mode, at most 12 clauses and 20 OR values per clause.
- EventSelector: at most three typed property predicates.
- Execution context: at most 32 resolved active-goal selectors.
- Canonical URL query component: at most 16 KiB and 32 parameters.
- Canonical saved JSON: at most 32 KiB.
- Interactive execution deadline: positive and at most 2,000 milliseconds.

Controllers resolve a comparison mode into an optional explicit local-date
range before execution. Issue #25 owns preset/calendar resolution and browser
history; the compiler never consults process time or timezone files.
Comparison belongs to Trend in 1.0; Breakdown rejects comparison state before
database preparation.

## 2. Closed model

An `AnalysisQuery` contains:

- site UUID and inclusive local-date range;
- comparison: `none`, `previous`, or `previous_year`;
- mode: `trend` or `breakdown`;
- metric and optional EventSelector subject;
- optional dimension;
- interval: `auto`, `hour`, `day`, `week`, or `month`;
- FilterSet and optional segment UUID;
- sort, page, and limit.

Metrics are closed to:

- visitors, new visitors, returning visitors;
- sessions, engaged sessions, engagement rate, bounce rate;
- page views and custom events;
- conversions for one EventSelector with an explicit event, unique-visitor, or
  unique-session basis; conversion rate explicitly chooses a visitor or session
  denominator;
- revenue and average value for an optional EventSelector;
- event count and event visitors for one EventSelector.

Dimensions are closed to:

- page, landing page, exit page, hostname;
- channel, referrer;
- UTM source, medium, campaign, term, and content;
- country, language, device, browser, and operating system;
- event name;
- one event property with an explicit observed scalar type.

The legacy combined campaign tuple may exist only as an internal compatibility
preset. New canonical state uses one explicit UTM dimension.

An EventSelector is exactly one of:

- exact page;
- page prefix;
- exact custom event;
- saved goal UUID resolved by the controller to one of the selectors above.

It may add zero to three event-property predicates. A saved goal ID is never
placed in DuckDB SQL and an unresolved/deleted goal rejects before execution.
Page selector values must already be normalized stored paths without a query or
fragment; prefix matching is byte-prefix matching after that validation.

## 3. Filters and scopes

Clauses combine with AND. Values inside one clause combine with OR. Clause and
value order has no semantics; canonicalization sorts both and removes duplicate
values. There is no regex, nested group, NOT wrapper, formula, or arbitrary
expression tree.

Every clause declares one scope:

- `event`: the metric event row must match;
- `session`: the counted event/session must belong to a session containing a
  matching event or satisfying the selected session fact;
- `person`: the counted event/session must belong to a canonical person with a
  matching event, identity state, or supported user trait.

Fields are closed to page/path/title/hostname, landing/exit page,
channel/referrer/UTM, country/language/device/browser/operating system, event
name, event property, user trait, identity state, and session conversion,
duration, or engagement facts. The compiler maintains the field-to-scope and
field-to-type compatibility table. A stale property/entity remains representable
in saved state; controller catalog resolution must return a typed validation
failure before constructing execution context, and the compiler never silently
omits the clause.

Operators are closed by scalar type:

- string: `is`, `is_not`, `contains`, `not_contains`, `starts_with`, `exists`,
  `absent`;
- integer/decimal: `is`, `is_not`, `gt`, `gte`, `lt`, `lte`, `exists`,
  `absent`;
- boolean: `is_true`, `is_false`, `exists`, `absent`.
- null: `is`, `is_not`, `exists`, `absent`; missing: `is`, `is_not`.

Property and trait references use validated bound JSON Pointer values. String,
integer, exact decimal, boolean, null, and missing remain distinct. No implicit
string/number conversion is permitted.

## 4. Metric and dimension semantics

Metric v2 uses `site_local_date`, applies D32's versioned product-eligibility
predicate, and treats only page-view/custom-event rows as independently
meaningful. During the one-release #68 shadow that predicate is
`traffic_class <> excluded AND legacy_bot_verdict=false`; traffic class never
overloads the device dimension. Canonical person identity follows D26 and D28:

Trend buckets follow the receipt-time authority in `PROTOCOL.md` and D27.
Day, week, and month intervals derive from the persisted `site_local_date`.
Hour intervals derive from `received_at_utc_micros` plus the persisted,
receipt-derived `site_utc_offset_minutes`. `occurred_at_utc_micros` remains an
ordering input and never selects an analytics bucket.

- linked persistent anonymous IDs use the site-scoped user key;
- otherwise persistent, ephemeral, and legacy identities use distinct
  namespaces;
- legacy and ephemeral people contribute only where the metric definition
  permits and remain explicit in coverage;
- new/returning require persistent-compatible people and an all-history first
  meaningful event check.

Session acquisition, landing, and exit dimensions use deterministic first/last
page-view order by occurrence time, sequence, receipt time, and event ID.
Country/language/device/browser/operating-system session dimensions use the
first meaningful session event. Event dimensions use the matching event row.
When an event metric is grouped by a session dimension, each event inherits its
own session's one deterministic dimension value.

Channel classification version 1 is compiled and visible: no source, medium,
or referrer is Direct; medium `cpc`, `ppc`, or `paidsearch` is Paid Search;
`organic` is Organic Search; `social`, `social-network`, `social-media`, or `sm`
is Social; `email` is Email; `referral` or an otherwise untagged external
referrer is Referral; remaining tagged traffic is Other / Unknown. Raw source,
medium, and referrer dimensions remain available and no carryover is applied.

Engaged sessions satisfy at least one accepted condition: 10,000 ms active
engagement, two page views, or one resolved active-goal conversion. The
application supplies at most 32 active-goal selectors; DuckDB never queries
Turso. Rates return exact numerator and denominator, not a floating-point label.

Revenue sums exact `DECIMAL(18,6)` values only within one currency. Different
currencies are separate result series/rows and are never added. Average value
returns exact amount plus its value-bearing conversion denominator.

Incompatible metric/dimension/filter combinations reject before a DuckDB
statement is prepared. Not every Cartesian combination is meaningful, but
issue #24 must execute every required Trend metric, every required Breakdown
dimension with its documented compatible metric scopes, and every current
ordinary-report preset. A silent fallback to another scope or metric is
forbidden.

## 5. Compilation and execution

The domain model has no HTTP, HTML, Turso, DuckDB, filesystem, or clock
dependency. The store compiler may compose SQL only from a finite inventory of
literal fragments selected by closed enums. It must:

1. validate the complete query and resolved execution context after canonical
   request/saved-state parsing;
2. select an explicit metric/dimension/scope plan;
3. prefilter site and local range before metric aggregation, constraining
   full-session enrichment to session IDs selected in that range;
4. append only literal reviewed predicates/CTEs/order expressions;
5. bind every site, date, entity, property pointer, filter value, selector
   value, limit, and offset;
6. enforce the configured deadline through DuckDB interrupt;
7. bound rows and return exact cardinality/truncation metadata.

Request values, enum names parsed from requests, SQL identifiers, functions,
sort expressions, and JSON paths are never interpolated. A compiler test must
prove adversarial values appear in bindings but not compiled SQL.

No cache, rollup, projection, EAV table, background worker, extension, or new
dependency is accepted by this contract. A measured miss follows the
optimization order in `PERFORMANCE.md` and requires a later decision where
consequential.

When a segment ID is present, the controller composes the resolved segment and
ad-hoc clauses into FilterSet and marks the execution context resolved. An
unresolved segment rejects; its ID is provenance and never reaches DuckDB SQL.
Compiler plans and decoded results allocate from the caller's request-lifetime
arena.

## 6. Canonical serialization

Canonical saved JSON uses a fixed field order, explicit schema/metric versions,
enum names from this contract, sorted clauses, sorted/deduplicated values, and
no transient page number. Unknown fields, duplicate logical fields, invalid
UTF-8, noncanonical numbers, and out-of-bound arrays reject.

Canonical URL state is a query component, not a full route. The site lives in
the route and is not duplicated. Scalar parameters occur once in this order:

```text
v,from,to,compare,mode,metric,conversion-basis,selector,selector-value,dimension,
property,property-type,interval,segment,sort,page,limit
```

Absent optional fields are omitted. Selector predicates use repeated `p=` and
filters use repeated `f=` after the scalar fields. A filter is a raw `~`-joined
sequence of scope, field, optional property name, operator, scalar type, and
values. Each component is percent-encoded independently; the parser splits
`&`, `=`, and `~` before percent-decoding, so encoded delimiters cannot alter
structure. Percent escapes use uppercase hex and spaces use `%20`, never `+`.

Canonicalization orders and deduplicates selector predicates and filters by
their encoded bytes.
Signed integers use their shortest decimal form and exact decimals use six
fractional digits, so numerically equivalent accepted values serialize once.
Equivalent accepted state therefore has one JSON and one URL representation.
The parser rejects malformed/lowercase escapes, unknown/duplicate scalar
parameters, unexpected empty components, forbidden repeats, and input over the
declared byte/field/value bounds.

Parsers allocate returned strings and slices from the supplied request-lifetime
allocator; callers release that arena after the parsed query is no longer used.

## 7. Results and compatibility

`TrendResult` contains current points, optional comparison points, exact current
and comparison totals, resolved interval, and completeness. `BreakdownResult` contains typed labels,
exact measures, next page, exact/known cardinality, and completeness. Measures
are typed as count, ratio `(numerator, denominator)`, or exact decimal amount/
currency plus its value count. Rendering and formatting remain controller/view
concerns.

Current and comparison completeness carry total/persistent/ephemeral/legacy
person counts, persistent basis points, and the site's first persistent local
date. This lets consumers distinguish incompatible prior identity data from a
real zero. Timeout, unsupported/stale state, incompatible prior data, and high
cardinality are distinct outcomes; none become zero.

Current ordinary report concepts have typed presets. Overview is an explicit
bundle of visitor, session, page-view, and custom-event query presets; its bot
diagnostic remains outside metric-v2 product metrics. The existing metric-v1
CLI/report renderer and its UTC visitor-day/session semantics stay unchanged
until an explicit compatibility-removal issue. Funnel, path, retention,
session/profile, and Live queries reuse closed FilterSet/EventSelector helpers
where appropriate but retain specialized query/result types.

D30 adds one explicitly versioned `traffic-quality` diagnostic bundle on the
existing report transport. It is not an ordinary `AnalysisQuery` product
metric: it deliberately uses the current received-UTC report range so its
canonical-person count is comparable to the frozen visitor-day headline. It
does not change any existing metric-v1 output. A later site-local Overview
migration must move both headline values together rather than mixing date
contexts.

## 8. Acceptance evidence

Issue #24 must provide:

- pure validation and canonical JSON/URL round-trip/adversarial bounds;
- a finite plan inventory covering required metrics/dimensions and current
  ordinary presets;
- real on-disk DuckDB semantic fixtures for local dates, persistent/identified/
  ephemeral/legacy identities, sessions, engagement, typed properties, exact
  multi-currency value, scoped filters, pagination/cardinality, and comparison;
- current metric-v1 report regression/parity evidence without output changes;
- timeout/interrupt and post-interrupt connection reuse;
- Debug and ReleaseSafe execution through the real binary.
