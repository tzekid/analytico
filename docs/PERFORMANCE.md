# Performance and resource contract

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
| Per-request temporary allocation retained after response | 0 bytes |
| Database statements for a valid event | 1 insert transaction |
| Collector response body | 0 bytes for POST; fixed GIF for pixel |
| Upstream network requests | 0 |
| Background jobs created | 0 |

The rate-limit table, site-policy snapshot, and connection count are fixed or
configuration-bounded. An attacker cannot increase them without limit by
varying request input.

## 4. Report work bounds

- Interactive date range: at most 400 UTC days.
- List page size: default 25, maximum 100.
- Funnel steps: 2–8.
- Concurrent interactive reports: default 2, hard maximum 4.
- Query deadline: 2 seconds.
- Result rows decoded before pagination: query-specific and covered by `LIMIT`;
  never a full unbounded collection in Zig memory.
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

## 6. Tracker budgets

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
