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
| Initial requests | ≤ 3: HTML, CSS, optional HTMX |
| Largest server-rendered table page | 100 rows |
| Trend points per rendered series | ≤ 400 |
| Funnel steps | 2–8 |
| Path plot | 3–5 columns; ≤ 10 nodes per column; ≤ 400 edges |
| Retention matrix | ≤ 12 cohorts × 12 visible periods |

With JavaScript disabled, the same navigation, filters, date forms,
pagination, goal management, and funnel management must work.

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
