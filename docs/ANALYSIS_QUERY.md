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

### Calendar and comparison resolution

The server samples the clock once for a request and converts that instant with
the selected site's already validated D27 timezone. Calendar resolution is a
pure operation over that instant, the bounded timezone, and validated local
dates. It never reads the process timezone, contacts a network service, or
lets the browser resolve reporting dates.

The shared presets resolve to explicit inclusive local dates:

- Today: the current site-local date;
- Yesterday: the preceding local date;
- Last 7, Last 30, and Last 90 days: respectively 7, 30, and 90 local dates,
  including today;
- Month to date: the first local date of today's month through today;
- Custom: the submitted inclusive `from` and `to`, capped at 400 dates.

When a site-scoped route omits calendar state, it resolves Last 30 days with
Previous period and redirects to the resulting explicit canonical dates. A
site switch preserves those explicit local dates; it does not silently
reinterpret an old bookmark as a moving preset in the new timezone.

`previous` is the adjacent range immediately before `from` and contains the
same number of local dates as the current range. `previous-year` maps both
endpoints to the same month and day in the preceding calendar year, clamping
February 29 to February 28. It is calendar-aligned rather than duration-based,
so a leap-year range may intentionally contain a different number of dates.
If a requested comparison cannot be represented inside the supported calendar,
the current range remains valid and comparison is explicitly unavailable; it
never becomes a zero-valued period.

Every current and available comparison range also carries the D27 half-open
UTC bounds. A range containing the current site-local date is marked
incomplete. Canonical shared query state is ordered `from`, `to`, `compare`
with explicit values. The previously shipped `start`/`end` spelling is accepted
only as an equivalent input and redirected to that canonical representation.
Preset identity is not stored in the URL: bookmarks retain exact dates, and a
range is labeled as a preset only while it still matches that preset for the
selected site's current local date.

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

Metric v2 uses `site_local_date`, applies D34's versioned product-eligibility
relation, and treats only page-view/custom-event rows as independently
meaningful. Stored declared bots, automation, and exclusions are always out.
With site strict mode off, D33's `traffic_class IN (human-presumed, suspected)`
base remains compatible and D34's derived suspected sessions stay included.
With strict mode on, the same bound query relation additionally excludes only
query-classifier-v1 current suspects after trusted interaction, engagement,
scroll, active-goal conversion, and persistent-return vetoes. Session and
visitor-day metrics derive distinct eligible facts rather than relying only on
stored start flags. Traffic class never overloads the device dimension.
Canonical person identity follows D26 and D28:

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

Except for D35's one exact, mutation-invalidated complete Overview-result entry,
no cache, rollup, projection, EAV table, background worker, extension, or new
dependency is accepted by this contract. A measured miss follows the
optimization order in `PERFORMANCE.md` and requires a later decision where
consequential. D35 does not authorize caching ordinary `AnalysisQuery`
results.

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

Current ordinary report concepts have typed presets. The fixed Overview is a
specialized closed metric-v2 result for Visitors, Sessions, Page views,
Engagement rate, all-active-goal Conversions, visitor Conversion rate, exact
per-currency Revenue, and identity coverage. It reuses the same canonical
person, full-session, active-goal, product-traffic, local-date, comparison, and
deadline contracts as ordinary queries, but compiles the fixed aggregates into
one statement instead of issuing one `AnalysisQuery` per card. Its received-UTC
traffic-quality diagnostic remains outside metric-v2 product metrics. The
existing metric-v1 CLI/report renderer and its UTC visitor-day/session
semantics stay unchanged until an explicit compatibility-removal issue. Funnel,
path, retention, session/profile, and Live queries reuse closed
FilterSet/EventSelector helpers where appropriate but retain specialized
query/result types.

The fixed Overview detail result is a second specialized closed consumer, not
an ordinary user-authored `AnalysisQuery`. It contains exactly one selected
Visitors, Sessions, Page views, all-active-goal Conversions, or
currency-explicit Revenue trend; five Content, Acquisition, Conversions, and
Audience rows apiece; and one compact data-health row. On a cold result-key
miss, the KPI and detail statements execute sequentially on the single serving
connection under one shared request deadline. They do not become per-panel HTTP
requests or independent timeout budgets.

Under decision D35, the Store retains at most one exact complete Overview result
in a dedicated arena. Its length-prefixed key covers site, current/comparison
dates, strict policy, configured daily ceiling, the complete ordered
active-goal snapshot including every selector predicate property/type/operator/
value, selected metric/currency, interval, and every current/comparison bucket.
Every successful event-store insert, rebucket,
deletion, or migration destroys the entry synchronously; goal and traffic-
policy changes necessarily change the key. There is no TTL, stale fallback,
durable cache table, background refresh, or separate KPI cache. A hit
deep-copies the complete bounded result into the request allocator so rendering
cannot mutate or outlive the entry. A miss executes and combines the KPI and
details statements under the existing shared deadline.

Overview interval rows are dense for count and exact-value semantics. The
controller supplies a bounded, ordered set of site-local bucket labels derived
from the already-loaded D27 zone, including spring gaps and collapsed repeated
local-hour labels that match the receipt-time SQL bucket. Current and
comparison bucket labels remain separate when their calendar lengths differ.
Revenue selection always names one observed currency; no implicit default,
cross-currency sum, or exchange conversion is allowed.

The fixed automatic interval follows the authoritative visualization contract:
hour for at most two inclusive local dates, day for at most 90, and week for
91–400. Month remains an explicit typed interval for a later offline/export
range beyond the current 400-date interactive bound; automatic interactive
Overview does not silently coarsen 181–400 dates to month.

Content rows rank normalized page paths by page views and include distinct
modeled visitors and share of all current page views. Acquisition rows use the
first page view's external referrer source for each full session and include
sessions plus the session conversion ratio. Conversion rows rank active goals
by distinct modeled converting people and use all current visitors as the
rate denominator. Audience rows use the first meaningful session event's
country and include sessions. All four panels use the same product-traffic,
strict-mode, range, identity, session, and active-goal contracts as the fixed
KPIs; path/source/country ties are label-ascending, conversion ties preserve
the controller's name-ascending resolved-goal order, and each result is capped
at five rows.

Issue #27 links those rows to the existing native Pages, Sources, Goals, and
Countries report destinations and keeps the existing Devices report reachable
from Audience. Issue #31 owns later entity-detail routes,
annotation persistence/CRUD, and actual trend markers. No placeholder storage,
hidden filter, or non-working detail route is part of the fixed Overview.

Every visible current/comparison trend interval has a bounded native Analyze
handoff. It preserves the complete site/range/comparison context and carries a
visible `focus` metric plus `highlight` interval label. Until issue #28 ships
the full typed Trend route, the current Analyze page renders that focus as an
explicit non-filtering callout above its existing working report: the full
range remains unchanged, and the highlighted interval is never a hidden SQL
predicate. SVG point links are pointer-reachable; the exact table provides the
ordinary keyboard/link baseline for every point. Issue #28 may consume the
same canonical handoff when it replaces the report surface with full Trend
mode.

`highlight` accepts only an exact bucket label generated for the resolved
current or comparison range and site zone: canonical `YYYY-MM-DDTHH:00`,
`YYYY-MM-DD`, or `YYYY-MM` as selected by the automatic interval. A merely
well-shaped label outside those generated buckets is a normal 400 invalid
request. When the current range includes today, the last current bucket is
marked `Incomplete` in the exact table and uses a distinct square SVG marker;
the text/shape distinction does not rely on color or mark the comparison
bucket. For hourly ranges, the resolved request-time UTC instant is retained in
the calendar context and current buckets stop after the bucket containing that
instant. Future local hours are not rendered or accepted as highlights;
comparison hours remain complete. Day, week, and month series retain their
final current bucket and mark it incomplete.

## 8. Analyze Trend browser consumer

Issue #28 keeps the single-query canonical grammar above as the saved/query
compiler boundary and adds the D37 browser-only Trend-set envelope over one
through three ordered queries. Its canonical scalar order is
`v,from,to,compare,mode,interval`, followed by one through three repeated
`series` tuples and an optional exact generated `highlight`. The tuple grammar,
goal resolution, bounds, native builder redirect, shared deadline, currency
expansion limit, and legacy `report=` compatibility are normative in D37.
Both the visible builder and the shared date/context form submit numbered
metric/event/goal fields and redirect to canonical state. They do not place a
whole `~`-separated canonical tuple in a hidden control, because native HTML
form encoding may encode those structural delimiters as `%7E`.

The #28 route supplies the existing validated empty `FilterSet`. It rejects
nonempty filter or segment route state rather than silently hiding it; issue
#30 owns the visible universal filter/segment/saved-view extension. The
canonical Trend set is already the typed save/export handoff, but #28 renders
no dead action: #30 owns persistence and #31 owns actual export responses.

Sparse Trend rows are aligned to the same site-local generated bucket calendar
used by Overview. Missing counts are zero, zero-denominator rates are
unavailable, and a known exact currency has an exact zero when that bucket has
no value row. Hourly current ranges stop after the real current hour while
preserving TZif gaps/overlaps. When a day, week, or month range extends beyond
today, its future buckets remain visible but only the bucket containing the
sampled site-local current instant is visibly incomplete. A future final bucket
is never mislabeled. `highlight` visibly marks one generated primary-series
bucket without filtering the query. An overlapping current/comparison label
selects current deterministically. A date-context or builder submission clears
the old highlight rather than carrying an interval that may not exist in the
new generated calendar.

The controller splits the existing amount rows into exact-currency visual
series. No `Metric.currency` field, currency URL scalar, or `goal-matches`
metric is added. Overview's all-goal Conversions and currency-specific Revenue
point handoffs remain on the working non-filtering compatibility callout because
they do not equal #28's selected-goal unique-conversion or all-currency typed
metrics. Visitor, session, and page-view handoffs translate to typed Trend.

Each returned rate keeps its exact numerator and denominator; chart basis
points are derived display coordinates. Each average-value point keeps its
exact summed `DECIMAL(18,6)` amount and value-row denominator. A deterministic
six-decimal quotient truncated toward zero may be used for chart geometry,
while the exact table prints the source numerator and denominator and does not
relabel that quotient as an exact stored amount.

The empty-filter browser set executes its identical identity-completeness query
once under the same deadline, then attaches that result to each ordinary
one-metric row/total result. This does not change D29's query grammar or the
semantics of a standalone query. The compiler may omit unused session facts for
an empty-filter Trend metric that cannot consume them; engagement metrics and
all nonempty-filter queries retain the full plan.

Legacy Overview visitors and legacy coverage are the exact distinct legacy
anonymous identities with at least one product-eligible page-view or custom
event inside each site-local period. Stored `visitor_day_start` is a metric-v1
receipt-UTC compatibility boundary, not a metric-v2 person shortcut: its row may
fall outside the local period, be product-ineligible, or be a non-meaningful
event while a different same-identity row determines metric-v2 eligibility.

While metric-v1 dashboard results remain on other report routes, the shared
shell may carry the new local calendar context only when the result is visibly
identified as UTC compatibility data. It must not relabel or partially convert
a metric-v1 total. Issue #26 moves every Overview headline value together to
the resolved site-local range. Overview presents a compact, site-filtered data
health summary and a native link to Live. The full separate traffic-quality
section remains on Live with its local received-UTC disclosure rather than
applying a false page-wide warning.

D30 adds one explicitly versioned `traffic-quality` diagnostic bundle on the
existing report transport. It is not an ordinary `AnalysisQuery` product
metric: it deliberately uses the current received-UTC report range so its
canonical-person count is comparable to the frozen visitor-day headline. It
does not change any existing metric-v1 output. Issue #26 completes the required
site-local Overview migration by removing both compatibility values from the
headline together; the diagnostic bundle remains received-UTC, explicitly
labeled, and fully available from Live. Overview's compact health summary
shows the D34 configured daily cap, total stored accepted rows, site-local days
in the selected current range that have reached that cap, and a visible warning
when any day has reached it. It may also show last accepted receipt, protocol
distribution, and selected-site recent collection outcomes, but it does not
relabel those operational facts as site-local product metrics or duplicate the
full diagnostic query. Reject and
store-failure counts copied from the bounded #21 ring are explicitly labeled
`since process restart`; they are volatile operator evidence, not durable
history.

When a site has no durable events, #27 gives direct installation guidance and
a working native Live verification action. Issue #20 owns the canonical
generated snippet and installation-verification route; #27 does not invent a
dead setup URL before that route exists. A selected-site rejection with no
accepted event is a distinct tracking-broken state and links to the same Live
evidence.

## 9. Acceptance evidence

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
