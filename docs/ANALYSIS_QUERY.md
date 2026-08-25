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
- Breakdown search: empty or at most 256 control-free UTF-8 bytes.
- FilterSet: `all` mode, at most 12 clauses and 20 OR values per clause.
- EventSelector: at most three typed property predicates.
- Execution context: at most 32 resolved active-goal selectors.
- Explicit saved-goal resolution: at most three selected goal IDs outside the
  active snapshot; these may be archived definitions. An active selected ID
  resolves from the active set and is not duplicated across both inputs.
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
- optional Breakdown result-label search;
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
An archived saved goal is resolvable only when its UUID is explicitly selected
by the current Trend or Breakdown state. It remains absent from the active-goal
snapshot used for default conversions, engaged-session evidence, Overview, and
D34. The controller owns both bounded sets before DuckDB execution; the query
grammar does not gain an archive flag or a second selector kind.
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
string/number conversion is permitted. Exact string filter values are bounded
valid UTF-8 and may contain percent-encoded control bytes so legacy observed
dimensions remain exactly filterable; they stay escaped in HTML, bound in SQL,
and absent from request logging. Search text remains control-free.

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
7. apply optional bound aggregate-label search before stable ordering and
   pagination;
8. bound rows and return exact cardinality/truncation metadata.

Request values, enum names parsed from requests, SQL identifiers, functions,
sort expressions, and JSON paths are never interpolated. A compiler test must
prove adversarial values appear in bindings but not compiled SQL.

Except for D35's one exact, mutation-invalidated complete Overview-result entry
as filter-keyed by D40 and D39's one short-lived sampled property-suggestion
catalog entry, no cache,
rollup, projection, EAV table, background worker, extension, or new dependency
is accepted by this contract. A measured miss follows the optimization order
in `PERFORMANCE.md` and requires a later decision where consequential. Neither
exception authorizes caching an ordinary `AnalysisQuery` result.

When a segment ID is present, the controller composes the resolved segment and
ad-hoc clauses into FilterSet and marks the execution context resolved. An
unresolved segment rejects; its ID is provenance and never reaches DuckDB SQL.
Compiler plans and decoded results allocate from the caller's request-lifetime
arena.

## 6. Canonical serialization

Canonical saved JSON uses a fixed field order, explicit schema/metric versions,
enum names from this contract, sorted clauses, sorted/deduplicated values, and
no transient page number. Optional Breakdown search follows dimension in that
fixed order and is absent when empty. Unknown fields, duplicate logical fields,
invalid UTF-8, noncanonical numbers, and out-of-bound arrays reject.

D40 additionally defines canonical FilterSet JSON as exactly schema 1,
`match="all"`, and sorted/deduplicated encoded clauses. Trend-set saved JSON
uses schema 1 and metric version 2 with the set's site, explicit dates,
comparison, `mode="trend"`, interval, ordered series, optional segment, and
sorted ad-hoc filters. It omits the transient highlighted interval. Stored
segment, Breakdown, and Trend bytes are accepted only when parsing and exact
reserialization reproduce the original bytes; a merely normalizable stored
encoding is corrupt rather than silently rewritten.

Canonical URL state is a query component, not a full route. The site lives in
the route and is not duplicated. Scalar parameters occur once in this order:

```text
v,from,to,compare,mode,metric,conversion-basis,selector,selector-value,dimension,
property,property-type,search,interval,segment,sort,page,limit
```

Absent optional fields are omitted. Selector predicates use repeated `p=` and
filters use repeated `f=` after the scalar fields. A filter is a raw `~`-joined
sequence of scope, field, optional property name, operator, scalar type, and
values. Each component is percent-encoded independently; the parser splits
`&`, `=`, and `~` before percent-decoding, so encoded delimiters cannot alter
structure. Percent escapes use uppercase hex and spaces use `%20`, never `+`.

Native GET forms may encode the structural `~` bytes in repeated `p=` or `f=`
values once as `%7E` while encoding component escapes as `%25`. The parser
accepts exactly that one well-formed browser layer and redirects to the raw-`~`
canonical spelling. Missing separators, lowercase/noncanonical escapes, extra
encoding layers, and malformed components reject before DuckDB.

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

## 8. Analyze Breakdown browser consumer

Issue #29 renders one ordinary D29 query directly; it does not add a
Breakdown-set envelope or retain report-kind SQL as a second product model.
Bare Analyze remains D37 Trend. A native mode link opens the canonical Page
views by Page preset, and accepted builder state redirects to the canonical
single-query component.

The optional `search` field is valid only in Breakdown, is at most 256 bytes,
and contains no control characters. It performs a case-insensitive substring
match against the typed aggregate label after grouping and before stable
sort/page/limit. The value is bound. Exact cardinality is the number of matching
buckets before pagination; with no search it is the complete bucket
cardinality. Search affects saved/result state and therefore participates in
canonical URL and JSON. Empty search is omitted, preserving pre-D39 schema-1
state.

The page also loads at most 100 bytewise-ordered custom-event property names
and their observed scalar types/counts from the latest 2,000 eligible custom
events in the selected range. Discovery uses the same selected site,
site-local range, product traffic relation, strict classifier, active-goal veto
context, and shared request deadline as the result. The sample bound and its
counts are labeled; direct typed input remains available for a property outside
the sample. Missing is a selectable typed absence, not an observed JSON type. A
multi-type property is visibly a conflict and requires one explicit type; no
coercion occurs.

The Store retains at most one sampled property catalog for 30 seconds. Its
length-prefixed key covers the selected site and local dates, strict mode, and
every active goal selector, predicate, type, operator, and value. A key miss or
expiry runs the bounded catalog statement under the result's remaining shared
deadline; a hit deep-copies the bounded catalog. Event inserts intentionally do
not evict this suggestion-only entry, so active collection cannot turn every
request into a cold catalog rebuild. The exact Breakdown result and exact
cardinality are always queried and never come from this cache. When exact
cardinality is zero, one `LIMIT 1` selected-site event-presence probe under the
same remaining deadline distinguishes an empty installation from a valid
no-match result; the controller performs no post-deadline event-bounds scan.

Known legacy list URLs redirect to typed presets. Explicit campaign source,
medium, campaign, term, and content states map exactly. The old combined
`campaign=all` tuple visibly maps to Sessions by UTM campaign rather than
expanding the closed dimension inventory. Metric-v1 CLI/report output remains
unchanged.

The server-rendered result includes the native builder, bounded catalog,
search/sort controls, exact matched cardinality, high-cardinality warning,
stable pagination, in-cell proportional bars, and an exact typed table in the
first response. Count, ratio numerator/denominator, and exact amount/currency/
value-count components remain visible. No filter/segment/save/export/entity
placeholder, client fetch, result cache, projection, EAV table, migration, or
new dependency is introduced.

Direct canonical subjects may already contain D29 typed predicates. Native
date and Breakdown-builder submissions preserve those bounded repeated fields
and state their presence; they never silently broaden the subject. #30 owns a
visible predicate/filter editor. The #29 browser consumer accepts only the
builder's exact-event or saved-goal subject shapes and visitor-basis
conversion metrics; other valid core D29 selector/basis combinations reject
before execution rather than becoming state the visible builder cannot
preserve.

## 9. Analyze Trend browser consumer

Issue #28 keeps the single-query canonical grammar above as the query
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

D40 and issue #30 extend the set with one shared ad-hoc FilterSet and optional
segment UUID. Canonical Trend URL state places optional `segment` after the
ordered series and repeated sorted `f=` clauses after scalar fields. Each
materialized ordinary query receives the complete resolved composed set and
marks the segment resolved; an unresolved/stale segment never executes. The
canonical Trend set and its exact JSON counterpart are the typed save handoff.
#31 owns actual export responses.

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

## 10. Universal filters, suggestions, segments, and saved views

D40 and issue #30 make the same visible FilterSet context executable on the
current Overview, Analyze Trend, and Analyze Breakdown surfaces. “Current” is
intentional: Funnel, Path, Retention, and Sessions keep specialized future
engines, consume this closed FilterSet when implemented, and are not invented
as placeholders by #30.

The URL contains one optional selected segment UUID plus zero or more ad-hoc
`f=` clauses. The controller loads the segment for the selected site, validates
its exact canonical JSON and property references, composes it with the ad-hoc
clauses, canonicalizes/deduplicates, and then enforces the existing 12-clause
total. The selected segment and ad-hoc chips remain distinguishable in the view
model. Only the composed FilterSet reaches `Execution`; the segment UUID is
provenance and never reaches SQL.

Canonical Overview state is ordered
`v,from,to,compare,metric,segment,f...`; `v=1` is mandatory after #30 and an
accepted older filter-empty URL redirects once. Canonical Trend state is
ordered `v,from,to,compare,mode,interval,series...,segment,highlight,f...`.
Breakdown retains the D29 order in section 6. Mode/date/site links preserve the
selected segment and ad-hoc filters whenever the destination can execute them;
no control hides state that the destination would ignore.

Overview's fixed metric-v2 result uses a period-aware finite filtered plan with
the same event/session/person clause semantics. Its compact data-health row is
explicitly outside product filters. D35 remains exactly one complete entry;
its key includes the entire canonical composed FilterSet, while the established
empty-filter SQL stays unchanged. Trend attaches the same set to each ordinary
query under its one deadline. Breakdown executes one direct bounded statement;
filtered Page Views by Page applies page-view qualification before pagination,
so a custom event cannot emit a zero-page-view path.

One suggestion request selects a closed field, scope, scalar type, optional
property, and control-free search text under the selected site/range and all
preceding resolved clauses. It returns at most 50 exact typed values plus
`has_more` from one finite bound plan and one interrupt deadline. Values and
JSON pointers are bound; enums choose reviewed expressions. Null, missing, and
boolean operators need no arbitrary text value. No suggestion/result cache,
projection, EAV table, worker, dependency, or client fetch is introduced.

Turso metadata schema 7 stores at most 32 exact segments and 32 exact saved
views per site. Breakdown views use canonical Query JSON; Trend views use
canonical Trend-set JSON. Segment changes affect future view loads because a
view retains its segment ID plus ad-hoc clauses. Page and highlight are not
saved. Creating a new segment snapshots the complete currently composed
FilterSet and never creates a segment-to-segment reference. Missing segments,
removed allowed properties, goals missing outside D41's protected delete path,
site mismatches, malformed JSON, and noncanonical stored bytes are visible
typed stale/corrupt states. They block execution and provide an explicit
remove/reset path; no clause is silently discarded.

D41 metadata schema 8 replaces raw goal rows with stable active/archived
definitions. An ordinary application delete is refused while a current valid
saved Trend or Breakdown view contains that exact goal selector; archive
preserves the UUID and reportability. D40's stale state still covers corrupt,
restored, or externally missing references. Editing a goal intentionally
changes future evaluation over raw historical events; the saved view keeps the
UUID and no historical selector snapshot is introduced.

The guided goal builder's discovered-entity lookup is not an ordinary
`AnalysisQuery` result and cannot become a second metric grammar. One finite
bound plan chooses either qualifying page-view paths or qualifying custom-event
names under the selected site's resolved local range, product traffic policy,
and shared two-second deadline. It binds search and pagination, returns at most
50 rows plus `has_more`, exposes exact eligible count and last receipt time,
and orders count descending then label ascending. It has no cache, projection,
EAV table, worker, network request, or new dependency. Issue #34 owns property
predicate discovery and historical preview.

Native apply and suggestion forms are authenticated, exact-origin and CSRF
checked, and bounded to the route-specific 64 KiB body accepted by D40.
Successful application uses POST/303/canonical GET. Chip removal and row
`Filter`/`Exclude` actions are ordinary inspectable canonical links. HTMX may
boost the same routes and history but does not retain a shadow copy.

## 11. Acceptance evidence

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

Issue #29 additionally proves the D39 browser consumer: every current list
preset/redirect, canonical search bounds, stable pagination, typed property
null/missing/conflict behavior, exact cardinality and source components,
million-row result-plus-catalog latency, and JavaScript-off/enhanced mobile
browser operation.

Issue #33 additionally proves active/archive selector isolation, explicit
archived Trend/Breakdown resolution, exact saved-view delete conflicts without
UUID-text false positives, and bounded Page/Event discovery semantics,
deadline interruption, and post-interrupt connection reuse.

D42 metadata schema 9 persists each goal's zero-to-three D29 predicates as one
exact schema-1 canonical JSON document beside the closed base kind/value. Every
active or explicitly selected goal resolves to one complete `EventSelector`;
the selected saved-goal UUID still never reaches DuckDB SQL. Predicate order
and values are canonicalized exactly, and a noncanonical/corrupt stored
document rejects rather than broadening the selector.

The D42 goal result is a specialized closed consumer, not another
`AnalysisQuery` grammar or metric. It reuses the selected site's resolved
site-local range, ad-hoc FilterSet plus segment, product traffic relation,
strict classifier context, person/session semantics, event-row selector, bound
values, and one interrupt budget. One statement returns the exact match count,
distinct converting and eligible people/sessions, converting-person identity
coverage, at most 16 exact revenue currencies, and at most ten matching paths
with exact path cardinality. Revenue is never summed across currencies. Path
rows order count descending then label ascending and are visibly capped.

Builder preview runs that result and then one selector-scoped property sample
under the same remaining deadline. The sample examines at most the latest
2,000 eligible events matching the base selector, returns at most 100 property
names with every observed scalar type/count, and labels conflicts without
coercion. It has no cache, projection, EAV table, background work, or network
request. `intent=save` reruns the result before the metadata write; timeout
cannot save and a zero result requires explicit confirmation.

Predicate-free metric-v1 goal output remains unchanged. A predicate-bearing
goal is unsupported by that frozen grammar and rejects explicitly rather than
reporting the broader base selector.

Issue #34 additionally proves canonical predicate JSON collision separation,
event-row versus same-session semantics, filter/segment composition, typed
errors, exact result components, zero/timeout no-write and reuse, selector-
scoped property conflicts, and the goal-detail million-row budget.
