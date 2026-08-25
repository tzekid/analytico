# Performance and resource contract

> **Status:** These are the shipped v0.3 budgets and measured baselines. They
> remain regression guards; the written package's stricter Analytico 1.0 target
> budgets govern new feature paths and must be reconciled with measured evidence
> by their implementation issues. D26 explicitly replaces protocol v1's
> zero-persistent-storage tracker rule for new compatible events. The 1.0 target
> keeps zero dependencies and a tracker-v2 budget below 5 KiB Brotli. Issue #7
> bounds identity storage to two site-scoped `localStorage` keys, and issue #8
> stores a bounded session JSON record. Issue #9 adds the optional identified
> key and measures `identify()`; issue #12 adds measured SPA, engagement,
> scroll, value, and opt-in automatic behavior. D31 adds one bounded
> self-exclusion key; the current tracker remains below the 5 KiB Brotli budget.
> D32 adds a compile-time UA rule table only; it adds no tracker bytes or
> runtime data load. D34 adds one secret-keyed network-day derivation, one
> bounded site/day ceiling check in the existing event transaction, and one
> bounded query-time session-quality relation; it adds no tracker, dependency,
> network request, worker, or rollup.

The numbers in this file are budgets, not claims. M0 records the first measured
baseline on the target VPS. A release passes both the absolute budget and the
regression comparison against its checked-in baseline.

## 1. Measurement rules

Every benchmark record contains:

- Git commit and dirty-state flag;
- exact Zig, Turso binding, Turso engine, and DuckDB versions;
- optimize mode;
- OS, kernel, CPU model/count, RAM, filesystem, and storage device class;
- fixture generator version, seed, row count, and date distribution;
- process command line and DuckDB settings;
- warm-up count, sample count, p50, p95, p99 where applicable;
- executable and linked-runtime sizes;
- peak and idle RSS measurement method;
- raw observations or a link to them.

Shared CI can enforce regressions but does not establish final VPS claims.

## 2. M0 runtime budgets

Measured using the two-store ReleaseSafe spike on the current VPS:

| Metric | Absolute budget |
| --- | ---: |
| Installed executable plus required private runtime libraries | ≤ 100 MiB |
| Idle RSS after readiness and 30 seconds idle | ≤ 128 MiB |
| DuckDB query threads | 1 |
| DuckDB configured buffer-manager memory limit | 128 MiB |
| DuckDB maximum temporary-directory use | 256 MiB |
| Median readiness over 20 warm-filesystem restarts | ≤ 500 ms |
| p95 readiness over the same 20 restarts | ≤ 1,000 ms |
| p95 durable event insert, 1 request/second | ≤ 25 ms |
| p99 durable event insert, 1 request/second | ≤ 100 ms |
| p95 overview report over 1,000,000 deterministic events | ≤ 500 ms |
| p95 eight-step funnel over 1,000,000 deterministic events | ≤ 2,000 ms |
| Clean shutdown after SIGTERM with no active slow report | ≤ 2 seconds |

The report deadline is two seconds for interactive reports. The application
interrupts DuckDB and returns a timeout rather than allowing unbounded work.
Offline export and maintenance have separate explicit limits.

If the two-store implementation misses an initial budget, record the actual
measurement and reduce unnecessary compile/runtime features first. A modest
budget revision is acceptable for this private low-traffic service when the
measured footprint remains materially below the Plausible stack; it must be
documented rather than silently changed.

## 3. Collection request budgets

| Property | Budget |
| --- | ---: |
| Dynamic request-body bytes | 8 KiB maximum |
| Headers | 32 / 16 KiB maximum |
| User-Agent classification input | 1,024 bytes maximum |
| Sec-CH-UA consistency input | 512 bytes classified; longer is mismatch |
| Per-request temporary allocation retained after response | 0 bytes |
| Database work for a valid event | 1 transaction with 1 bounded site/day count plus insert/link work |
| Collector response body | 0 bytes for POST; fixed GIF for pixel |
| Upstream network requests | 0 |
| Background jobs created | 0 |

The rate-limit table, site-policy snapshot, and connection count are fixed or
configuration-bounded. An attacker cannot increase them without limit by
varying request input.

UA classifier v1 contains at most 64 compile-time rule entries. Matching is one
bounded pass over the at-most-1,024-byte header per rule, with no allocation,
regex, runtime file, or network request. Only the closed class, numeric version,
at-most-64-byte rule ID reach the event row. A
future measured collection-latency regression must first reduce or reorganize
the concrete table; it does not justify a service or downloaded corpus.
D33 adds constant-time validation of one closed client bundle and one bounded
client-hint scan. It removes the six D32 shadow counters and adds no per-rule
map, input-derived counter name, retained raw input, dependency, or background
work. The current tracker remains within 8 KiB raw and 5 KiB Brotli after its
four trusted-interaction listeners remove themselves on first trusted evidence.

## 4. Report work bounds

- Interactive date range: at most 400 UTC days for metric v1. Metric v2 retains
  an explicit bounded site-local range; issue #25 must record the exact bound
  rather than inheriting UTC semantics by accident.
- List page size: default 25, maximum 100.
- Funnel steps: 2–8.
- Concurrent interactive reports: default 2, hard maximum 4.
- Query deadline: 2 seconds.
- Result rows decoded before pagination: query-specific and covered by `LIMIT`;
  never a full unbounded collection in Zig memory.
- Traffic-quality version 5 returns at most 100 daily rows and 64 class/rule
  rows from one static bound statement under the same deadline. D34 binds at
  most 32 active goal selectors and returns only fixed prefix-anomaly counts;
  network-day group keys never enter the result.
- JSON/CSV export uses streaming output and a separate offline command.

Report SQL must begin with site and time predicates. Query plans and timings for
the million-row fixture are checked whenever schema or SQL changes.

## 5. DuckDB hardening and resources

The serving connection configures and then locks:

```sql
SET threads = 1;
SET memory_limit = '128MB';
SET max_temp_directory_size = '256MB';
SET allocator_flush_threshold = '8MiB';
SET preserve_insertion_order = false;
SET allow_community_extensions = false;
SET enable_external_access = false;
SET lock_configuration = true;
```

Exact support is verified against the pinned LTS build in M0. The application
does not rely on `memory_limit` as a complete process limit; cgroup/systemd
limits and measured peak RSS provide the outer bound. DuckDB documents that
some allocations sit outside its buffer manager and recommends reducing thread
count and memory limit under constraints:
[DuckDB out-of-memory guidance](https://duckdb.org/docs/current/guides/performance/oom).

Explicit report ordering makes insertion-order preservation unnecessary.
Disabling it also keeps analytical intermediates within the configured memory
limit; it does not change event or metric ordering.

The allocator threshold does not reduce the 128 MiB query-memory limit. It
makes the pinned engine flush freed native allocations after 8 MiB instead of
retaining its 128 MiB default. D45 records the repeated-view evidence and why
the explicit value is part of the serving contract. The separate bulk-
deallocation threshold retains the pinned default because the review found no
measured need to change it.

## 6. Protocol-v1 tracker budgets

M2 gates the production tracker:

| Asset | Budget |
| --- | ---: |
| Minified JavaScript | ≤ 3 KiB |
| Brotli JavaScript | ≤ 1.5 KiB |
| Third-party dependencies | 0 |
| Startup network requests caused by tracker | 1 event request |
| Persistent browser storage | 0 bytes |

The embedding page loads it with `defer`; analytics failure cannot delay or
break the host page's useful HTML.

Protocol-v1 retains the zero-storage contract at `/tracker.aef65945.js`.
Protocol-v2 identity storage is two required site-scoped `localStorage` keys:
`anl:<site-uuid>:a` (anonymous UUID) and `anl:<site-uuid>:s` (JSON session
record `{id,last_activity_ms,sequence}`), plus optional identified-user key
`anl:<site-uuid>:u`, cleared by `reset()`. The identified key stores the first
user ID only; traits are not duplicated in the browser. Sessions rotate after
more than 30 minutes of inactivity. Issue #12 adds SPA/engagement without new
dependencies. Its accepted current tracker is 6,266 bytes minified, 2,386
bytes Brotli, and 2,649 bytes gzip. The post-#12 ceilings are 8 KiB minified
and strictly below 5 KiB Brotli; historical content-hashed assets retain their
original smaller bytes.

The issue #12 real-Chromium gate runs the production executable against
on-disk Turso and DuckDB files. It proves path-only SPA deduplication, 15-second
visible activity deltas, hidden-time exclusion, scroll depth, opt-in automatic
events, absence of form/query secrets, exact value/currency storage, and the
measured compressed assets above. The existing collection-browser gate also
loads the current v2 asset in the Chromium, Firefox, and WebKit versions pinned
by `versions.json` while retaining its frozen-v1 and no-JavaScript checks.

### M2 measured baseline

The clean ReleaseSafe baseline at commit `82fba08` measured 53,832 KiB idle RSS
after 30 seconds, 5.807 ms durable-insert p95 across 100 real HTTP samples,
7.329 ms p99, and 26 ms shutdown. The tracker is 734 bytes raw and 383 bytes
Brotli. Full environment and fixture details are in
`bench/results/m2-collection-release-safe.json`.

### M3 measured baseline

The ReleaseSafe M3 fixture contains 1,000,000 events in 100,000 sessions and an
eight-step ordered funnel. After one warmup, ten full CLI-process samples
measured overview p50/p95/p99 at 86/111/111 ms and the funnel at
920/982/982 ms. The DuckDB file was 15,740,928 bytes. Full environment and
fixture details are in `bench/results/m3-reports-release-safe.json`.

### Traffic classifier and traffic-quality v3 confirmation

Issue #68's same-host ReleaseSafe collection runs measured durable-insert p95
at 15.362 ms and 17.504 ms (p99 21.734 ms and 18.811 ms). The deployed
schema-4 artifact measured 11.169 ms p95 in the same harness. The relative
increase remains below the absolute 25 ms p95 and 100 ms p99 budgets, so it
does not cross the regression policy's combined blocking condition.

The schema-5 million-event report fixture now includes ten traffic-quality v3
samples in `bench-m3`. Narrow required-column materialization plus one combined
traffic summary pass measured p50/p95/p99 at 1,146/1,262/1,262 ms, below the
canonical two-second interactive deadline. The same run measured Overview p95
94 ms and the eight-step funnel p95 900 ms. The gate fails if any sampled
traffic-quality run exceeds the deadline.

### Bounded signals and traffic-quality v4 confirmation

Issue #69's ReleaseSafe collection run measured 100 real loopback inserts at
11.245/17.227/22.960 ms p50/p95/p99. Startup was 41 ms, clean shutdown was
29 ms, and idle RSS after 30 seconds was 54,604 KiB. All remain inside the
absolute budgets above. The current tracker measured 8,071 bytes raw, 2,988
bytes Brotli, and 3,334 bytes gzip.

The schema-6 million-event fixture measured traffic-quality v4 at
1,146/1,226/1,226 ms p50/p95/p99 across ten full CLI processes, below the
two-second deadline. The same exact run measured Overview p95 at 81 ms and the
eight-step funnel p95 at 923 ms; the checkpointed DuckDB file was 23,605,248
bytes. These results include the fixed signal-evidence totals and permanent
traffic predicate rather than reusing the schema-5 measurements.

### Query-time classifier and traffic-quality v5 gate

Issue #70 records new same-host ReleaseSafe measurements rather than inferring
them from schema 6. The schema-7 fixture contains exactly 1,000,000 events and
100 isolated query-classifier-v1 candidate sessions. The benchmark asserts the
candidate totals and default-off/strict-on product semantics, captures the
exact bound traffic-quality `EXPLAIN ANALYZE` plan, and runs ten process samples
for Overview, the eight-step funnel, and traffic-quality in each policy mode.

The corrected ReleaseSafe run based on `ad63f19` measured default-off p95 at
96 ms for Overview, 883 ms for the funnel, and 824 ms for traffic-quality.
Strict-on p95 was 336 ms, 1,145 ms, and 848 ms respectively. The profiled
traffic-quality plan completed in 0.948 seconds. Before the measured fix the
wide traffic-quality relation intermittently crossed the two-second deadline;
the accepted query keeps the site/product, classifier-first-event, and
date-range relations non-materialized or explicitly narrow so DuckDB can prune
unneeded columns. The separate migration gate remains focused on preservation
and uses Overview for report parity. Full environment, plan size, fixture, and
raw observations are in
`bench/results/traffic-quality-v5-release-safe.json`.

The gate also retains 100 real loopback collection requests. Existing absolute
insert and two-second interactive deadlines remain blocking; a miss follows
the documented regression policy before any cache, projection, rollup,
dependency, or service is proposed.

### Analytico 1.0 property-query gate

Issue #10 adds a separate ReleaseSafe fixture with 1,000,000 event-schema-4
rows and 12 flat properties spanning string, signed integer, exact decimal,
boolean, null/missing, mixed-type conflict, and one high-cardinality value. It
uses the serving DuckDB limits above, one warmup, and ten samples for the
bounded low-cardinality property breakdown. Its p95 budget is 700 ms.

The same run exercises exact typed filters, type discovery, a 100-row bounded
high-cardinality breakdown, cardinality/truncation metadata, database bytes,
and fixture generation time. High-cardinality latency is recorded rather than
silently treated as an ordinary-cardinality budget; a miss must follow the
regression policy before any projection, cache, or schema change is proposed.

The issue #10 ReleaseSafe confirmation run on Linux 7.1.4, an AMD EPYC 9354P,
eight visible cores, 32 GiB RAM, and Btrfs measured the low-cardinality
breakdown at 362/442/442 ms p50/p95/p99. A separate complete run measured p95
415 ms; both pass the 700 ms budget. The 100,000-bucket property returned 100
rows plus exact truncation/cardinality metadata in 383 ms. Fixture generation
took 4,269 ms and the checkpointed DuckDB file was 52,703,232 bytes. The
compact reproducible record is `bench/results/properties-release-safe.json`.

### Analytico 1.0 typed-analysis gate

Issue #24 retains the 400-day range, 100-row interactive result, one-thread
DuckDB, 128 MiB memory, bounded temp, and two-second interrupt ceilings for the
closed metric-v2 compiler. Canonical URL state is at most 16 KiB/32 parameters;
saved canonical JSON is at most 32 KiB; filters are at most 12 clauses with 20
OR values each; EventSelector property predicates are at most three.
Resolved active-goal execution context is at most 32 selectors.

The issue gate uses a hand-checkable real schema-3 corpus for semantic breadth
and records ordinary Trend/Breakdown elapsed time. Million-event p95 budgets
remain issue #46's representative mixed-data benchmark; a miss there follows
the optimization order before any cache, projection, rollup, table, service, or
memory-limit change.

Issue #28 adds no analysis cache. Its server-rendered Trend route executes one
through three ordinary queries sequentially under one shared two-second
interrupt budget. The real HTTP gate uses the standard million-event fixture,
one warmup, and repeated three-series requests through the serving binary. It
records every complete response time, requires each response inside the
unchanged deadline, and keeps compressed HTML within the 32 KiB dashboard
budget. A fresh serving-process HTTP request is labeled as such and is not
misreported as cold disk or cold SQL; any separately recorded SQL profile must
retain its own cold/warm conditions. Overview's D35 warm-cache evidence cannot
stand in for this route. A failure follows the existing optimization order; it
does not authorize a cache, projection, rollup, thread, worker, larger deadline,
memory change, or client fetch.

Issue #29 adds no `AnalysisQuery` result cache. One exact metric-v2 Breakdown
result and, on a miss, one sampled property/type catalog execute under one
shared two-second interrupt budget. A zero-cardinality result uses one
selected-site `LIMIT 1` event-presence probe under the same remaining budget;
there is no post-deadline count/min/max scan. The catalog reads the latest
2,000 eligible custom events and the Store retains at most one complete
site/range/strict/goal-keyed sample for 30 seconds. Inserts do not evict this
suggestion-only entry; the rendered page labels the sample, update window, and
sampled counts. The exact result and cardinality always execute.

The first exact all-row catalog expanded 12 million property rows and timed out
after the result query completed in 559 ms, even with a temporary diagnostic
budget leaving more than 9.4 seconds. A 10,000-event prefilter still measured
479–635 ms per catalog query. A 2,000-event uncached sample kept the cold path
inside the interactive deadline but measured full property p50/p95/p99 at
751/843/843 ms and ordinary p95 at 397 ms. These are retained rejected results.
They justify D39's package-prescribed short catalog cache, not a result cache or
projection.

The million-property fixture performs one explicit cold warmup and ten complete
catalog-hit calls. The exact post-YAGNI ReleaseSafe candidate measured a cold
path at 829 ms, property p50/p95/p99 at 484/528/528 ms, ordinary p95 at 97 ms,
and exact high-cardinality search at 333 ms. The sampled `plan` type count was
exactly 2,000. The blocking gates remain ordinary below 400 ms p95 and property
result plus catalog below 700 ms p95; they were not widened. Event/property-only
plans may omit session facts only when the metric, dimension, selector, and
empty filter cannot consume them. A later miss preserves this evidence and
follows the SQL/column/prefilter order before a projection, rollup, dependency,
memory change, larger deadline, or client fetch is considered.

The first Debug million-row three-series route candidate failed with an honest
503 at the unchanged two-second deadline. The measured plans were rebuilding
the full session-facts relation and identical empty-filter identity coverage
for simple visitor/session/page-view queries. The bounded correction shares
that coverage once and omits session facts only when the metric and empty
filter cannot consume them; engagement metrics and nonempty-filter D29 queries
retain the full plan. A post-correction Debug real-HTTP run measured a
0.508131-second fresh serving-process request and 0.483925-second p95 across ten
complete samples after one warmup. The million-row HTML was 3,708 bytes gzip;
the maximum legal 400-day, three-series comparison page was 23,489 bytes gzip.
These are Debug implementation measurements, not ReleaseSafe evidence.

The exact post-review source candidate was then measured independently in both
optimization modes on Linux 7.1.4, an AMD EPYC 9354P, Zig
0.17.0-dev.1509+bb296ab9b, Caddy 2.11.4, Playwright 1.62.0, and Chrome for
Testing 151.0.7922.34. The final Debug run measured a 0.471847-second fresh
serving-process request and 0.509004-second p95 across ten complete samples;
the million-row and maximum legal pages were 3,713 and 23,516 bytes gzip. The
final ReleaseSafe run measured 0.463579 seconds fresh and 0.472859 seconds p95;
the same pages were 3,711 and 23,510 bytes gzip. Both runs kept the stylesheet
at 5,857 bytes gzip, stayed below the 8 MiB repeated-view RSS-growth ceiling,
made zero startup fetch/XHR requests, rendered byte-identical desktop/mobile
screenshots, returned the forced shared-deadline timeout page, and then accepted
a new event plus its idempotent duplicate through the same DuckDB owner.

### Analytico 1.0 Overview KPI confirmation

Issue #26 adds one coordinated metric-v2 Overview statement under the same
two-second interrupt deadline. The default product path must keep its
million-event server-query p95 below 250 ms. Strict query-time classifier mode
retains a 500 ms p95 ceiling: it is an optional compatibility mode whose
accepted metric-v1 predecessor already measured 336 ms on this fixture. Both
paths remain inside the two-second interactive deadline, and the complete CLI
process time is recorded separately from the query itself.

The first semantically correct wide plan measured 7.34 seconds under
`EXPLAIN ANALYZE` and timed out in the serving path. A first combined rewrite
still crossed two seconds. A faster `visitor_day_start` legacy shortcut reached
224 ms default and 452 ms strict p95, but was rejected: a receipt-UTC boundary
can lie outside a site-local range, an ineligible boundary can precede an
eligible meaningful row, and an eligible non-meaningful boundary does not make
a person. Exploratory exact candidates observed 273, 385, 365, and 295 ms on
the default path; cold-process exact runs later observed 345/397 ms and 268/417
ms default/strict, and one sustained experiment observed 313/487 ms. These are
retained failed evidence, not accepted baselines.

The accepted statement groups exact in-range legacy identities after both the
meaningful-kind and product-traffic predicates. It keeps finite period,
session, identity, goal, and exact-value relations narrow. The production-shaped
gate opens one real on-disk Store and DuckDB connection, performs one warmup,
then runs ten complete `executeOverview` calls; every call still validates,
compiles, binds, prepares, executes, and decodes the statement. This matches the
single-process serving ownership instead of charging process/database opening to
each query. Batch wall time remains recorded separately. No cache, projection,
rollup, schema, dependency, worker, service, or memory-limit change was
introduced.

On the standard owner host, the final ReleaseSafe one-million-event run
measured default query p50/p95/p99 at 214/228/228 ms and strict query
p50/p95/p99 at 344/376/376 ms after one warmup per policy. Two preceding
complete confirmation runs measured 216/246/246 and 214/243/243 ms default,
with 329/351/351 and 354/405/405 ms strict. The retained default
`EXPLAIN ANALYZE` plan completed in 0.227 seconds and
asserts the narrow range-session, person, and value relations. Metric-v1
Overview, funnel, and traffic-quality parity remained within their existing
gates. The compact environment, fixture, plan-size, accepted runs, and rejected
observations are in `bench/results/overview-kpis-release-safe.json`.

Issue #27 must time the complete fixed Overview server data path rather than
relabeling the KPI-only measurement. The accepted KPI statement and one bounded
details statement share one request deadline on the serving DuckDB connection.
The normal-mode combined p95 remains below 250 ms and the already reconciled
optional strict-mode combined p95 remains at or below 500 ms on the million-row
fixture. The full traffic-quality v5 report stays on Live and is measured by
its own two-second gate; Overview consumes only its compact site-filtered
health facts and must not hide that report's cost inside an unrelated timing.

The first #27 million-row details candidates failed honestly: the initial two
overlapping wide materializations exhausted the locked 128 MiB limit; after
narrowing, the exact uncached complete path measured 769/842/842 ms
default and 1,071/1,274/1,274 ms strict p50/p95/p99. The combined default
profile was 0.830 seconds: 0.219 seconds for the accepted KPI statement and
0.616 seconds for details, led by full-session attribution and exact Content
people. Materializing the narrowed range relation avoided no semantics but
worsened p95 to 1,701 ms. These rejected observations do not justify a memory,
schema, thread, or budget change.

Following the governing 1.0 regression order and the explicit D35 exception to
D29, #27 adds one exact, mutation-invalidated in-process complete-result entry
before considering a projection/rollup. A details-only entry first measured
221/249/249 ms default and 344/367/367 ms strict, but an independent default
repeat reached 261 ms and failed the unchanged below-250-ms gate. Narrow KPI
materialization also produced a fresh 262 ms failure, so neither candidate is
accepted.
The benchmark still performs one explicit cold warmup per policy and then ten
complete Store calls. Every measured call after the warmup deep-clones the
complete bounded Overview result only when its full typed key matches. The gate
separately profiles both cold SQL statements, proves an accepted
insert invalidates KPI, trend, and health facts, distinguishes selector
predicates and configured ceiling in the key, and records cold miss time under
the existing two-second deadline. This cache is removable and adds no durable
state, worker, dependency, or stale TTL behavior.

The first three independently seeded ReleaseSafe stability runs preceded the
final YAGNI cleanup. They measured complete-result cache-hit normal p95 at 12,
8, and 8 microseconds, strict p95 at 8, 8, and 9 microseconds, and cold
KPI-plus-details profiles at 0.818, 0.728, and 0.858 seconds. The fourth
independent run used the exact post-YAGNI source under PR review. It measured
normal p95 at 29 microseconds, strict p95 at 8 microseconds, and the cold
profile at 0.814 seconds.

Three additional process runs against one fixed million-row fixture measured
normal p95 at 8, 8, and 42 microseconds. The cold profiles are not warm-cache
measurements and are not presented as satisfying the warm p95 budget. Metric
switches and reads after accepted-event invalidation are cold misses under the
existing two-second deadline. Metric-v1 Overview, funnel, and full Live
traffic-quality parity remained inside their existing gates.
Environment, fixture, rejected candidates, raw observations, and cache-
invalidation evidence are in `bench/results/overview-panels-release-safe.json`.

### Analytico 1.0 universal-filter and saved-state gate

D40 keeps the D29 limits of 12 clauses, 20 OR values per clause, a 16 KiB URL,
32 query parameters, 32 KiB canonical JSON, and a two-second interactive
deadline. Metadata schema 7 permits at most 32 segments and 32 saved views per
site. Only authenticated filter/saved-state form routes accept a 64 KiB body so
form encoding can carry the already-bounded canonical JSON; the application and
canonical Caddy matcher enforce the same ceiling. Inside only that route
handle, a declared `Content-Length` above 65,536 returns 413 and a missing
length returns 411 before proxy dispatch; the exact `max_size 65536` remains the
read-time bound. Native URL-encoded browser forms always provide their finite
length. The rejected 65,536- and 65,537-byte `request_buffers` candidates both
still raced an early authenticated or unauthenticated upstream response into
502, so no request buffering is retained. All other ordinary dashboard routes
retain the 8 KiB application request-body ceiling; passkey routes retain
Caddy's 192 KiB outer ceiling.

One suggestion request returns at most 50 typed values plus `has_more`, runs
one finite bound statement under the same two-second interrupt mechanism, and
uses no cache, projection, EAV table, background worker, dependency, or client
data request. The scale gate records cold and repeated search conditions rather
than presenting one as the other.

The established empty-filter Overview SQL and its one-entry D35 cache remain
unchanged. A nonempty composed FilterSet uses a period-aware finite plan and
adds its entire canonical byte representation to that one entry's exact key.
The million-row gate performs one explicit cold call and ten repeated calls in
each policy mode: cold must remain below the two-second request deadline,
normal repeated p95 remains below 250 ms, and strict repeated p95 remains at or
below 500 ms. Filtered Trend, Breakdown, and suggestion HTTP calls must each
remain below two seconds. A miss follows the existing optimization order and
does not authorize a second cache, wider memory limit, rollup, service, or
client fetch.

The first strict combined candidates did not provide acceptable margin. The
retained baseline profile was 2.03 seconds; deriving conversion counts with
`bit_count(goal_mask)` measured 2.14 seconds, a meaningful-first struct measured
2.04 seconds, a combined catalog path measured 2.18 seconds, and a struct person
key measured 2.28 seconds. Grouping-set and combined event/revenue candidates
measured 2.22 and 2.25 seconds wall time; a two-stage Content candidate measured
2.32 seconds, and fully inlining the qualified relation measured 2.21 seconds.
One later candidate profiled at 1.99 seconds but then timed out in a fresh real
request. These are rejected observations and do not relax the deadline or
authorize more memory.

The accepted bounded corrections remove duplicate aggregate states, put exact
revenue predicates on the narrow source path, build strict cross-session
contradictions only from persistent candidate keys, and derive session
cardinality directly from `session_facts` only when every clause is a true
session fact. Predicate-bearing goals still project `properties_json`, and the
specialized Page Views-by-Page statement excludes custom-only paths. Five
separate strict processes against the retained fixture measured cold Overview
between 1.763 and 1.989 seconds. An earlier qualifying fresh-fixture run measured
default/strict cold Overview at 1.695/1.736 seconds. The exact final-candidate
ReleaseSafe gate measured default/strict cold Overview at 1.709/1.895 seconds,
warm p95 at 15/32 microseconds, Trend at 1.064/1.129 seconds, Breakdown at
0.555/0.637 seconds, and suggestions at 1.396/1.397 seconds. The default
`EXPLAIN ANALYZE` completed in 1.79 seconds and produced 174,639 bytes. A
separate strict profile against the retained fixture completed in 1.67 seconds;
its empty persistent-candidate build side yielded zero cross-session rows rather
than scanning the million-row identity relation. Exact final samples are in
`bench/results/filters-release-safe.json`.

### Analytico 1.0 guided-goal gate

D41 keeps the execution snapshot at no more than 32 active goals and loads at
most three explicitly selected IDs for one Trend/Breakdown request. Management
reads return at most 50 definitions plus `has_more`; archive therefore cannot
turn the first response into an unbounded list. Create, duplicate, and
reactivate enforce the active cap in their single metadata write rather than
after a count/read.
A preserved schema-7 overflow blocks create/duplicate/reactivate and active
analysis rather than being truncated; archiving is the bounded recovery path.

One builder search returns at most 50 qualifying Page paths or custom-event
names plus `has_more`, exact count, and last receipt time. It uses the selected
site/local range/strict traffic policy, bound search and offset, stable
count-descending then label-ascending order, and the existing two-second
interrupt deadline. The deadline includes every discovery statement and any
empty/cardinality work; timeout must leave the connection reusable. The Page
plan scans qualifying page views only and the Event plan scans qualifying
custom events only.

The gate exercises real on-disk discovery for empty, searched, and next-page
states and separately runs the strict million-event query through a fresh CLI
process. It does not label browser-process reuse as cold SQL evidence. It adds
no cache, projection, rollup, EAV table, background work, network request,
dependency, memory-limit change, or client fetch. A measured miss follows the
existing optimization order before any such mechanism is proposed.

D42 adds no deadline or memory increase. Goal detail executes one closed result
statement and must remain below 700 ms p95 on the standard one-million-event
fixture in ReleaseSafe. It returns one summary, at most 16 currency rows, and
at most ten matching paths. Preview adds one selector-scoped catalog over only
the latest 2,000 matching eligible events and shares the same two-second budget
with the result. Timeout must interrupt the real DuckDB statement, perform no
metadata write, and leave the connection reusable.

The performance gate records fresh-process and repeated measurements
separately and retains rejected evidence. It profiles the exact production
statement with a predicate-bearing goal and current filter context before any
optimization. No result cache, property cache, projection, rollup, EAV table,
background process, broader memory limit, or relaxed timeout is accepted
without a new measured decision.

The first ReleaseSafe million-event candidate failed the production two-second
deadline; its retained `EXPLAIN ANALYZE` evidence measured 2.41 seconds. The
plan showed DuckDB materializing the generic 55-column qualified event rowset
for one million rows. D42 therefore takes the package's next documented
optimization step only for an unfiltered goal result: project the selector,
identity, revenue, and path columns, derive both eligible counts in one
aggregate, and materialize only the narrow matched rows. Filtered goal results
retain the existing D29 compiler path and semantics.

The exact final post-review ReleaseSafe production binary measured a
0.161-second fresh `EXPLAIN ANALYZE`. Four independent ten-sample fixture and
browser processes measured p95 values of 231,307, 189,418, 161,019, and
169,414 microseconds; every sample was below the 700,000-microsecond target.
Each run returned 100,000 exact predicate matches and one path. The same
processes ran the complete result-plus-catalog preview in 574,605, 602,663,
559,075, and 533,909 microseconds under the unchanged two-second deadline.
Earlier passing review measurements preceded the final stale-context journey
and are not presented as final-candidate evidence. These are repeated
warm-database statement measurements, not a cold database-open claim; the
separate explain process preserves the fresh-process evidence.

### Analytico 1.0 guided-funnel gate

D43 keeps one canonical funnel definition at no more than 8 KiB, two through
eight steps, and three predicates per direct step. The full-draft
`/admin/funnels` and `/admin/funnels/edit` forms reuse D40's exact 65,536-byte
saved-state request boundary with at most 128 fields because percent-encoding
can expand the canonical values; all other funnel forms retain the ordinary
8 KiB ceiling. Management reads return at most 50 definitions plus `has_more`.
Create, edit, archive, and reactivate each use one guarded metadata statement;
no draft, revision history, reference index, cache, projection, rollup, worker,
dependency, network request, or larger deadline is introduced.

Builder preview resolves at most eight selectors and returns exactly one
independent matching-event count per step from one specialized statement under
the unchanged two-second interrupt deadline. The production-path gate uses the
standard million-event fixture, records the exact statement plan and repeated
ReleaseSafe timings, and asserts timeout plus connection reuse. This is
selector-availability evidence only. D44 retains the 1.2-second ordered funnel
target and separately owns progression, scope/window semantics, timing,
comparison, and result visualization.

Two independent 2026-08-25 post-review ReleaseSafe runs exercised the same
final code. The focused run measured the eight-selector strict statement at
`96,379`, `97,990`, `103,120`, `107,127`, `109,646`, `111,407`, `113,186`,
`113,478`, `115,762`, and `118,031` microseconds. The extracted full-package
run measured `93,947`, `95,415`, `100,143`, `103,925`, `105,152`, `105,504`,
`110,146`, `110,488`, `110,765`, and `135,700` microseconds. The larger p95 was
`135,700` microseconds against the unchanged two-second ceiling. Earlier
pre-final candidates measured `91,023` through `102,856` and `92,457` through
`109,454` microseconds; those observations remain evidence but are not
presented as the final code. The separate analyzed plan and compiler assertion
prove one specialized statement with every selector aggregated over one
`qualified` relation. The Debug gate executes the same semantic/browser path
but explicitly does not present Debug timings as performance evidence.

The authenticated browser gate measures response bytes and startup requests
for list, new, edit, preview, and lifecycle states. A stale segment or property
between GET and POST must preserve the bounded draft, remove only the stale
context, return 422, and perform no metadata write. A miss keeps the original
plan and samples visible and follows the existing SQL column/prefilter order;
it does not authorize a larger deadline or speculative storage mechanism.
The same production-path gate proves every full-draft route is in the bounded
Caddy matcher, an exact 65,536-byte declared request reaches the application,
and 65,537 bytes returns 413 rather than 502.

### Analytico 1.0 ordered-funnel gate

D44 keeps the existing two-through-eight step, 400-day local-range, one-thread,
128 MB memory, 256 MB temporary-space, and two-second interrupt ceilings. Ten
complete samples of each populated eight-step range over the million-event
fixture with ten active goals must have p95 below the package's 1.2-second
Funnel target. Current and comparison ranges are measured independently in
default and strict traffic modes; an empty comparison is not accepted as
evidence. Their paired sample
cost must remain below two seconds, and a real populated preview must return
all eight availability rows plus the pair under one shared interrupt budget
after an intentional timeout. D44 records
the target interpretation and rejected stronger combined target explicitly.
D43 availability and D44 progression share one request budget during preview.

The plan may number the filtered meaningful relation once and emit at most
eight fixed position-link CTEs. It may not use a per-entrant query, recursive
general engine, cache, projection, rollup, extra thread, larger memory/temp
limit, or wider deadline to meet the target. The profile must retain the
selector and traffic predicates plus current row counts so a fast but broader
or narrower result cannot pass. Debug executes the same semantic path but does
not claim performance. Final measured observations and any rejected candidates
are appended here before #36 release acceptance.

The first ReleaseSafe compiler used full-relation next-selector windows. Its
current and comparison profiles took 3.84 and 4.10 seconds and the real paired
request timed out. All-start position joins improved those profiles to 1.79
and 1.81 seconds; materialized candidate ASOF links measured 1.75 and 1.85
seconds. Both still timed out as pairs. Struct-key participant selection and a
tuple-only ordering experiment each exhausted the locked 128 MiB limit near
121 MiB used. The first memory-safe greedy same-session plan passed the hard
deadline but measured paired p95 at 1,940,503 microseconds default and
1,968,804 microseconds strict, which lacked stable headroom.

An earlier otherwise final run used only one active goal, below the package's
standard-fixture minimum. Its default current/comparison/paired p95 values were
709,104/789,551/1,451,073 microseconds; strict values were
768,047/853,704/1,574,438 microseconds. Those values remain rejected fixture
evidence in the result JSON and are not the accepted qualification.

The accepted plan evaluates selectors once for eligible progression rows and
keeps narrow candidates. Visitor coverage separately evaluates only step one
over excluded identity qualities. Sequential same-session requests greedily
retain the earliest valid prefix; session scope
then omits a redundant participant rank because its chain and count keys are
identical. Timed sequential requests retain all starts and nearest later
candidate links, while consecutive requests require the exact next meaningful
position. The final ten-goal ReleaseSafe default current/comparison p95 values
were 723,300/786,253 microseconds, with paired p95 1,509,553 microseconds.
Strict values were 851,091/882,645 microseconds, with paired p95 1,733,714
microseconds. Each mode completed a real populated preview, including all eight
availability rows and both ranges, after an intentional one-millisecond timeout
on the same connection. Exact arrays, environment,
row counts, and rejected observations are in
`bench/results/funnel-result-release-safe.json`.

### M4 production-MVP baseline

The current ReleaseSafe package contains a 26,341,344-byte executable and a
64,775,472-byte private DuckDB runtime: 91,116,816 installed bytes. The
100-request collector run measured 53 ms startup, 50,228 KiB idle RSS after 30
seconds, 60,228 KiB loaded RSS, 8.907 ms durable-insert p95, 9.169 ms p99, and
21 ms shutdown. Full lifecycle, deployment, failure, rollback, and
extracted-archive evidence is in `M4_RESULTS.md`.

## 7. M6/M7 web budgets

These apply only when the dashboard exists:

| First dashboard view | Budget |
| --- | ---: |
| Useful state in first HTML response | 100% |
| API/JSON refetches on startup | 0 |
| Compressed HTML | ≤ 32 KiB |
| Compressed CSS | ≤ 12 KiB |
| Compressed application-authored JS | ≤ 2 KiB |
| Compressed vendored HTMX core | ≤ 16 KiB |
| Blocking third-party requests | 0 |
| Initial requests | ≤ 3: HTML, CSS, optional HTMX or page-specific JS |
| Install verification fragment p95 over 1,000,000 events | < 150 ms |
| Largest server-rendered table page | 100 rows |
| Trend points per rendered series | ≤ 400 |
| Breakdown/property catalog | ≤ 100 rows / latest 2,000 eligible events / ≤ 100 property names / one 30-second entry |
| Filter suggestions | ≤ 50 values plus has-more; one request deadline |
| Saved state | ≤ 32 segments and 32 views per site; ≤ 32 KiB canonical JSON each |
| Goal management | ≤ 50 definitions per page; ≤ 32 active per site |
| Goal entity discovery | ≤ 50 values plus has-more; one request deadline |
| Funnel steps | 2–8 |
| Path plot | 3–5 columns; ≤ 10 nodes per column; ≤ 400 edges |
| Retention matrix | ≤ 12 cohorts × 12 visible periods |

With JavaScript disabled, the same navigation, filters, date forms,
pagination, goal management, and funnel management must work.

D38's Install page may use one dedicated application-authored script instead
of HTMX. It remains within the compressed application-JavaScript budget and
makes no data request at startup; the first verification fragment is scheduled
five seconds after load only while the page is visible, waiting, and unpaused.

### M6 measured baseline

The ReleaseSafe no-JavaScript dashboard measured 1,283 compressed bytes for
the complete first HTML response and 905 compressed bytes for CSS, with two
initial requests and zero startup API requests. After 100 complete authenticated
views, RSS was 1,388 KiB below the warmed starting observation. The first view
also passed in a 360×640 Chromium viewport under 180 ms latency and a 64 KiB/s
download ceiling. Full real-Caddy, browser, escaping, form, authorization, and
timeout evidence is in `M6_RESULTS.md`.

### M7 measured baseline

The exact HTMX 4.0.0-beta6 core is 36,282 bytes raw and 13,014 bytes under the
precomputed gzip representation, below the 16 KiB compressed budget. The
enhanced first view makes three requests—complete HTML, CSS, and self-hosted
HTMX—and no API/JSON request. It adds zero application-authored JavaScript and
no local/session storage entries. Enhanced navigation and forms use the same
full HTML controller as M6. Full browser failure/fallback evidence is in
`M7_RESULTS.md`.

### Analytico 1.0 application-shell confirmation

Issue #16's ReleaseSafe real-Caddy, on-disk-store, and no-JavaScript browser
run measured 2,177 compressed bytes for the complete canonical Overview HTML
and 3,850 compressed bytes for the versioned shell CSS. The page exposed all
six direct site-scoped destinations, made zero startup API/JSON requests, kept
the mobile primary navigation within a 360 px viewport, and grew RSS by 4,884
KiB after 100 authenticated views. The existing application-authored browser
island remains 1,802 bytes raw and 696 bytes gzip; the shell adds no script,
dependency, API request, or client state.

### Shared component and chart gate

Issue #17 keeps the existing HTML, CSS, request, and RSS ceilings. Pure chart
tests cover the maximum bounded inputs as well as empty, single, constant,
missing, and all-zero cases. The real ReleaseSafe dashboard gate renders the
existing funnel result through the SVG/table path, transforms a real report
table into labeled mobile records, and verifies exact semantic alternatives,
JavaScript-off operation, dark/mobile styling, error focus, and reduced motion.
It records the compressed HTML/CSS bytes and 100-view RSS observation rather
than inferring them from issue #16. No chart allocates a client runtime, adds a
request, or changes report SQL.

On 2026-08-23, the accepted ReleaseSafe M6 run on the standard owner host
measured 2,418 bytes gzip for the authenticated Overview HTML, 4,934 bytes gzip
for the v5 CSS, and 776 KiB RSS growth after 100 authenticated Overview views.
The corresponding final Debug run measured 2,416 bytes, 4,934 bytes, and
-2,320 KiB (allocator/process sampling may produce a negative observation).
Both real Chromium runs used JavaScript-off first navigation, exercised the
native mutation/error paths, and passed the same response/request ceilings.

### Site-local calendar confirmation

Issue #25 keeps the M6/M7 request, response, and process ceilings unchanged.
The accepted ReleaseSafe real-Caddy/on-disk-store/Chromium run measured 2,759
bytes gzip for the complete authenticated Overview HTML, 5,014 bytes gzip for
the versioned v6 CSS, and 5,040 KiB RSS growth after 100 authenticated views.
The expanded server-rendered context adds no startup API/JSON request, script,
dependency, or client state. Its native preset and custom/comparison GET paths
passed at 360 px with JavaScript disabled; the same canonical state passed HTMX
back/forward restoration.

One Debug observation crossed the 8,192 KiB growth gate at 10,372 KiB. The
unchanged binary did not reproduce it in isolated reruns (2,904, 6,588, 2,864,
7,620, 5,016, and 8,056 KiB), and the final ReleaseSafe observation above
passed. The gate and regression policy were not weakened.

### Overview KPI first-response confirmation

Issue #26's final ReleaseSafe real-Caddy, on-disk-store, and JavaScript-disabled
Chromium run measured 3,142 compressed bytes for the complete authenticated
Overview HTML, 5,094 compressed bytes for the versioned v7 CSS, and 728 KiB RSS
growth after 100 authenticated Overview views. The first response contained all
six available fixed KPIs, definitions, deltas, identity coverage, incomplete and
comparison states, native drill links, and the separately disclosed received-UTC
traffic-quality diagnostic. It made zero startup API/JSON requests and kept the
primary navigation, calendar controls, and KPI content unclipped at 360 px.

### Overview trend and answer-panel first-response confirmation

Issue #27's final ReleaseSafe real-Caddy, on-disk-store, and
JavaScript-disabled Chromium run measured 6,450 compressed bytes for the
complete authenticated Overview HTML, 5,476 compressed bytes for the versioned
v8 CSS, and 0 KiB observed RSS growth after 100 authenticated Overview views.
The first response contained the selected trend and exact table, all four
answer panels, compact site-filtered health, distinct empty/broken states, and
working native point/panel destinations. It made zero startup API/JSON requests
and kept the chart, metric form, stacked panel records, data health, and primary
navigation unclipped at 360 px.

### First-run and site-creation confirmation

Issue #19's final ReleaseSafe real-Caddy, on-disk-store, and Chromium run
measured 734 compressed bytes for the complete first-run HTML and 5,722
compressed bytes for the versioned v9 CSS. The JavaScript-disabled site
creation path made only document and stylesheet requests, accepted one event
without a process restart, remained unclipped at 360 px, and showed 0 KiB RSS
growth after 100 authenticated Install views. The separate cold workflow
observation was 17,012 KiB and is recorded as non-steady process evidence, not
as the warm-view measurement.

The final Debug run measured the same 734-byte HTML and 5,722-byte CSS, with
0 KiB warm-view RSS growth. Its separate cold workflow observation was 23,008
KiB. Both modes passed the same response, request, JavaScript-off, keyboard,
authentication, validation, and immediate-collection assertions.

### Installation verification confirmation

Issue #20's PR-readiness Debug run measured a 17.781 ms warm
p95 for 30 signed verification fragments over 1,000,000 stored events and
18.099 ms for the first successful post-watermark event lookup. The real
passkey-authenticated Caddy/Chromium journey made zero startup data requests,
measured 1,783 bytes gzip for the complete success HTML, and measured the
Install-only enhancement at 3,891 bytes raw and 1,204 bytes gzip. The 100-view
RSS observation was 11,432 KiB below the warmed starting sample. The same signed
success URL remained valid after the real writer process stopped and restarted.

The exact ReleaseSafe candidate measured 15.948 ms fragment p95, 14.539 ms
first-success latency, the same 1,783-byte gzip HTML and 1,204-byte gzip script,
zero startup data requests, and a 13,468 KiB-below-warm RSS observation. It
passed the same real passkey, Caddy, on-disk store, restart, tracked-page,
JavaScript-disabled, desktop, and mobile assertions as Debug.

The accepted query shape was selected from measured failures, not treated as a
cold result. A per-row UUID cast plus compound predicate measured 358.825 ms
p95, and native UUID ordering under one compound `OR` measured 417.711 ms p95;
both violated the unchanged 150 ms gate. Adding the signed row-count guard and
two zone-prunable tie/later queries first passed at 25.359 ms p95, then measured
16.013 ms, 16.641 ms, 17.084 ms, 16.282 ms, 16.399 ms, and 16.061 ms in
independent pre-final runs. The exact PR-readiness candidates above include the
selected-site maximum-receipt equality lookup, explicit excluded-traffic
acceptance, and exact visible type/time assertions.

### Sessions list budget

D45 keeps the package Session-list p95 below 400 ms without changing the
one-thread, 128 MiB DuckDB memory, 256 MiB temporary-space, or two-second
interrupt contracts. The standard fixture has 1,000,000 events, 100,000
sessions, classifier-signal rows, and ten active Goals. The separate semantic
and browser corpus supplies persistent, identified, ephemeral, legacy,
excluded, typed-property, and exact-value cases without misrepresenting the
scale fixture as mixed production traffic.

The focused ReleaseSafe gate opens one real on-disk Store, performs one explicit
warmup, then records ten complete two-statement calls in default mode and ten
in strict mode. It reports p50/p95/p99 for the complete shared-deadline call;
both p95 values are blocking below 400 ms. Separate EXPLAIN ANALYZE evidence
must show the narrow candidate/rank stage and the bounded detail-key stage.
Page-key lookahead, exact currencies, timeout, post-timeout reuse, response
bytes, and repeated-view RSS remain part of the same candidate evidence.

The first ReleaseSafe complete-call candidate applied a session-device filter
and selected Goal inside the scale timing. Its default samples were 746269,
755127, 768473, 784724, 788584, 791436, 798665, 800263, 825118, and 856177
microseconds, so its 856177-microsecond p95 failed. Narrowing materialized
range columns still failed at 752643 microseconds. Those rejected results are
retained as filtered stress evidence; they are not presented as the package's
ordinary first-list budget.

The pre-final post-template candidate measured the canonical unfiltered first
list while retaining all ten active Goals for the bounded detail conversion
work. Its default samples were 110591, 112337, 114986, 115716, 116567, 120285,
120819, 126000, 133103, and 144926 microseconds. Strict samples were 147571,
158308, 162425, 165281, 175977, 177562, 185197, 193405, 194125, and 205011
microseconds.

The exact final candidate also clears the retained statement after every
destroyed result, drives the maximum 25-record page, reuses one resettable
request arena, and fixes the native allocator flush threshold at 8 MiB. Two
independent ReleaseSafe runs measured default samples of 131792, 134253,
138933, 139805, 143012, 154614, 165231, 165564, 173236, and 185488
microseconds, then 114949, 119101, 119511, 121246, 124790, 126026, 128934,
129484, 143326, and 149448 microseconds. Their p95 values were 185488 and
149448 microseconds. Strict samples were 157880, 165893, 169880, 171590,
176790, 177722, 180674, 185546, 191926, and 192028 microseconds, then 159518,
163845, 165377, 175024, 178241, 178429, 179037, 196292, 202609, and 205600
microseconds. Their p95 values were 192028 and 205600 microseconds. All four
remain below the unchanged 400000-microsecond gate.

Final EXPLAIN ANALYZE totals for the same SQL shape were 0.123/0.0820 seconds
for the default key/detail statements and 0.177/0.0396 seconds for strict. The
key compiler omits row-level filter qualification when neither filters nor a
selected Goal exist, carries the retained start in the bounded key relation,
and projects only demanded range columns for filtered requests. The real
one-millisecond interrupt then reused the same connection successfully.

The repeated-view review rejected preparing and destroying the same detail
shape on every request. Debug first grew 52,300 KiB over 50 views and then
48,112 KiB over the next 50; ReleaseSafe grew 96,236 KiB and then 24,920 KiB.
Keeping the statement alive only through result destruction produced isolated
passing samples, but did not converge: a later Debug run grew 14,700 KiB after
50 warmups, ReleaseSafe grew 22,108 KiB after 200, and a one-row detail shape
still grew 29,776 KiB after 200. These measurements falsified row volume and a
shorter lifetime as fixes.

D45 therefore retains one exact-SQL prepared detail template, rebinds every
request value, destroys each result, and clears the statement before reuse.
The repeated-view gate initially treated one endpoint after 200 requests as a
stable observation. That was falsified: one ReleaseSafe process warmed by
85,284 KiB and then grew 21,260 KiB, while another reached 131,048 KiB and then
released 12,148 KiB. A 400-request warmup also later grew 18,008 KiB. Adjacent
cohorts then showed large positive and negative allocator movements, so a
single endpoint and a three-cohort median were both rejected as leak tests.

The final gate reports 600 warmup requests separately, measures three more
200-request cohorts, prints every signed change, and applies the unchanged
8 MiB-per-200 sustained-growth rate to their complete 600-request total. A
candidate without the reusable request arena averaged 20,797 KiB and failed.
After arena reuse, removing the prepared template produced one 6,211 KiB pass
and then a 10,756 KiB failure. The pinned 128/512 MiB native allocator defaults
remained unstable; explicit 16 MiB flush thresholds still averaged 8,472 KiB
and failed.

The exact `8MiB` threshold passed two independent ReleaseSafe processes while
the bulk-deallocation threshold retained its default. Their warmups were
96,776 and 84,428 KiB; cohort changes were -6,988, +4,424, and -21,872 KiB,
then -22,340, +44,216, and -17,172 KiB. Their sustained averages were -8,145
and +1,568 KiB per 200 requests. Debug warmed by 77,348 KiB; its cohorts were
+10,308, -20,324, and +11,076 KiB, averaging +353 KiB. The raw oscillations
remain visible, but continued growth is still blocking. No result, session
membership, event watermark, or request value is cached.

A miss follows the existing regression order: reproduce and profile, preserve
semantics, narrow selected columns/predicates and prefilters, then record a new
decision before any result cache, projection, rollup, index, memory, thread, or
budget change. A warm or partial statement measurement is not presented as
the complete Session-list p95.

### Session detail and profile budget

D46 retains the package's complete session-detail p95 below 250 milliseconds
on the standard one-million-event fixture. The measurement includes bound
existence/start lookup, one exact D45 summary expansion, and one 50-entry
meaningful timeline page under a shared two-second deadline. One explicit
warmup precedes ten complete calls; p50/p95/p99, timeout interruption,
connection reuse, plan evidence, response bytes, and repeated detail/profile
RSS cohorts remain blocking evidence. A timeline-only or prepared-statement
duration is not the complete detail measurement.

The compatible-person retained summary plus contextual 25-record session page
must remain inside the unchanged two-second deadline. Its D45 list component
continues to satisfy the below-400-millisecond p95. The standard fixture must
contain an explicit multi-device user and a persistent anonymous person rather
than presenting legacy-only rows as profile evidence.

No query cache, second prepared-template entry, projection, profile table,
index, memory/thread/deadline increase, or background work is authorized. A
miss follows the existing reproduce, profile, narrow-column/predicate, and
prefilter order before a new decision considers broader machinery.

The ReleaseSafe review retained two failed list-RSS processes at 12,544 and
15,614 KiB average growth against the unchanged 8,192 KiB ceiling. A third
process passed the list at 4,541 KiB but exposed that the new alternating
detail/profile cohort had no warmup: its first 200 requests absorbed the
DuckDB and request-arena high-water allocation and the un-warmed average was
16,929 KiB. The corrected gate mirrors the established list contract with 600
explicit warmup requests before three measured 200-request cohorts. The
accepted process recorded 56,592 KiB list warmup and 2,182 KiB measured
average, then 65,244 KiB detail/profile warmup and -3,361 KiB measured average.
Cold warmup growth remains evidence; it is not mislabeled as a leak or as a
measured cohort. The same real Caddy/passkey/JavaScript-off run produced 4,332
gzip bytes for 25 list records and 3,861 gzip bytes for a 50-entry timeline.

A later accepted-configuration Debug repeat also failed the list boundary at
15,018 KiB per 200 requests. Further Debug and ReleaseSafe processes that
measured the inherited list only after the new collector/profile corpus had
been written failed at 16,225 and 14,326 KiB. The merged #41 ReleaseSafe
control passed its pre-collector list corpus at 5,484 KiB. The final gate
therefore keeps D45's list/RSS phase before #42's collector additions, then
stops the writer, proves the duplicate counter, restarts, and exercises the
persisted detail/profile corpus. This separates two lifetime measurements; it
does not omit either workload or weaken either bound.

Lowering only `allocator_flush_threshold` to
`4MiB` was tested and rejected rather than accepted as a new memory mechanism:
two Debug processes measured list/detail-profile averages of 7,252/0 and
96/1,356 KiB, but the independent ReleaseSafe list measured 18,757 KiB and
failed before its detail/profile cohort. The exact 8 MiB D45 setting remains
authoritative; no bulk-deallocation setting or wider RSS allowance is added.

After separating the lifetimes, the pre-optimization ReleaseSafe source passed
once at -2,498 KiB but two fresh processes missed narrowly at 8,352 and 8,565
KiB. Profiling the #42 list-only delta found that each of 25 visible records
recompiled the identical canonical parameter suffix. The final bounded view
model compiles that suffix once and varies only each validated session UUID;
it adds no cache or lifetime setting.

The exact final lifecycle measured Debug list and detail/profile averages at
-7,140 and -3,888 KiB per 200 requests. ReleaseSafe measured 2,021 and 5,928
KiB. Its 25-record list and 50-entry timeline were 4,330 and 3,860 gzip bytes.
Normal list/detail p95 and complete profile time were 148,859/40,178/587,443
microseconds; strict values were 184,732/40,046/642,536 microseconds. Both modes
interrupted one-millisecond list, detail, and profile requests and reused the
same connection.

On the exact post-YAGNI ReleaseSafe source, two further independent million-
row CLI runs retained one million events while adding identified multi-device
and unlinked persistent-anonymous evidence. Normal-mode list/detail p95 and
complete identified-profile time were respectively 171,459/43,364/634,100
microseconds and 131,491/40,066/568,004 microseconds. Strict-mode values were
198,133/44,438/692,460 microseconds and 184,664/45,414/646,406 microseconds.
All four runs interrupted 1-millisecond list, detail, and profile requests,
then reused the same connection. The detail budget kept more than 200
milliseconds of headroom without a cache, projection, index, or wider limit.

## 8. Regression policy

For a stable benchmark environment:

- latency/RSS/response bytes may not regress by more than 10% and also exceed
  the absolute budget;
- statistically noisy changes are rerun before judgment;
- a deliberate regression needs a decision entry naming the user benefit and
  new measured baseline;
- a performance optimization is not merged without a before/after fixture and
  correctness equivalence tests.

Generated benchmark artifacts live under `bench/results/` once M0 creates the
harness. Only compact baselines and summaries belong in Git; large raw traces
are retained outside the repository with hashes.
