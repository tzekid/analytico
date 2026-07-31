# Decision register

This register covers consequential product and architecture decisions. It does
not require an ADR for reversible local implementation details. A new
dependency, process, protocol, durable schema, security boundary, metric
semantic, or application state model is consequential and must be added here.

## Summary

| ID | Decision | Recommendation | Status |
| --- | --- | --- | --- |
| D01 | MVP interface | Collector + local CLI, no dashboard | Accepted |
| D02 | ClickHouse replacement | DuckDB | Accepted |
| D03 | Storage topology | Turso metadata + DuckDB events | Accepted |
| D04 | DuckDB integration | Direct pinned LTS C API | Proposed |
| D05 | Zig and Turso channel | Exact local development pins | Accepted for scaffold |
| D06 | Ingestion durability | Direct synchronous insert | Proposed |
| D07 | Visitor/session identity | Cookieless site-scoped daily pseudonym | Proposed |
| D08 | Persisted visitor data | Derived dimensions only | Accepted |
| D09 | Country and client classification | Trusted country header + small local classifiers | Proposed |
| D10 | Collection transport | POST beacon plus optional GET pixel | Proposed |
| D11 | Aggregation | Query raw events on demand | Proposed |
| D12 | HTTP implementation | Zig standard library plus local narrow routing | Proposed |
| D13 | Dashboard and HTMX | Server HTML first; HTMX 4 later | Accepted |
| D14 | Deployment | One binary under systemd behind Caddy | Proposed |
| D15 | Administration/auth | Local CLI for MVP | Accepted |
| D16 | Backup and retention | Stop-the-service verified snapshots; explicit maintenance | Proposed |
| D17 | Scale path | Measure, then batch/Parquet/server DB | Accepted |
| D18 | Plausible migration | Fresh start and direct cutover | Accepted |

## D01. MVP interface

### Candidates

| Candidate | Advantages | Costs |
| --- | --- | --- |
| Full web dashboard | Familiar Plausible-like experience | Auth, sessions, templates, CSS, HTMX, and a much larger acceptance surface |
| JSON API plus separate frontend | Separates components | Creates a second state model and startup waterfall; violates the stated doctrine |
| Collector plus local CLI | Smallest complete product core; scriptable and testable | Less convenient until the later UI |

### Recommendation

Build the collector and complete reporting CLI first. The MVP is useful without
a browser dashboard, and the later HTML UI consumes already-tested typed report
models.

### Revisit

M6, after M4 is deployed and the operator can name the first high-value UI
workflow.

## D02. Analytics engine replacing ClickHouse

### Candidates

| Candidate | Fit at current traffic | Operational shape | Main concern |
| --- | --- | --- | --- |
| Turso only | Excellent; SQLite-style SQL and window functions are enough | One embedded database | Row-oriented engine is less ideal for future broad scans |
| DuckDB | Excellent; designed for embedded OLAP and rich analytical SQL | One in-process library and file | Adds a second engine and prefers one writer process |
| Parquet + DuckDB | Good for archival and large batch scans | Files plus an embedded query engine | Premature file partitioning and compaction |
| chDB | Technically embedded ClickHouse | Large ClickHouse-derived in-process engine | Weak Zig fit and preserves much of the conceptual weight being removed |
| DataFusion/Polars | Capable query/dataframe libraries | Embedded library plus a separate storage design | They are not a complete small durable database choice here |
| ClickHouse server | Proven analytics performance | Additional service, process, memory, logs, upgrades | Solves a scale problem this product does not have |

### Recommendation

Use DuckDB. Its columnar, vectorized SQL is a natural fit for entry/exit and
funnel scans, and this project is intentionally the owner's practical DuckDB
use case. M0 measures binary size, RSS, startup, write latency, recovery, and
report latency so the runtime is understood; it does not build a competing
Turso-only implementation.

### Evidence

- [DuckDB explains its embedded OLAP design](https://duckdb.org/why_duckdb).
- [SQLite supports the window functions needed for sessions and funnels](https://www.sqlite.org/windowfunctions.html).
- [chDB is ClickHouse embedded in process](https://clickhouse.com/chdb).

## D03. Storage topology

### Candidates

| Candidate | Advantages | Costs |
| --- | --- | --- |
| Turso for everything | One file, one backup, one API | Does not exercise the desired OLAP engine |
| DuckDB for everything | One file; straightforward reports | Uses an OLAP engine for mutable relational configuration and leaves the parent Turso binding unused |
| Turso metadata + DuckDB events | Clear workload ownership; matches the requested stack | Two schemas, files, migrations, and backup steps |

### Recommendation

Use Turso only for configuration and DuckDB only for events. Design operations
so no command needs a cross-file atomic transaction. This keeps the boundary
honest and testable.

### Revisit

Only if an operation demonstrably needs cross-store atomicity or DuckDB proves
unusable on the target VPS, not merely because current traffic is small.

## D04. DuckDB integration and version

### Candidates

| Candidate | Advantages | Costs |
| --- | --- | --- |
| Third-party Zig wrapper | More idiomatic calls | Another maintainer, API surface, and version pin |
| Direct DuckDB C API | Maintained by DuckDB; stable ownership contract; small local wrapper | Manual lifetime and error handling |
| C++ API | Richest API | Exposes more C++ ABI/build complexity to Zig |
| Current 1.5.x | Newest features and fixes | Faster storage/API change cadence |
| LTS 1.4.5 | Supported primary C client surface and slower upgrade cadence | Misses nonessential 1.5 features |

### Recommendation

Pin DuckDB 1.4.5 LTS and wrap only the used C calls: open/configure, connect,
prepare/bind/execute, result decoding, interrupt, checkpoint, and close. Use an
exact verified upstream artifact or amalgamation. No community extensions and
no Zig database wrapper.

DuckDB's C client is a primary supported API, and the LTS documentation lists
1.4.5 for C. See the [C client overview](https://duckdb.org/docs/lts/clients/overview).

### Revisit

Patch updates after backup/restore and deterministic report compatibility tests.
Minor updates require a storage-format and C-API audit.

## D05. Zig and Turso channel

### Candidates

| Candidate | Advantages | Costs |
| --- | --- | --- |
| Zig 0.16.0 + stable Turso binding branch | Stable compiler release | Does not use the current parent checkout and needs a second installed toolchain |
| Exact Zig 0.17 development snapshot + current parent binding commit | Matches the present workspace and binding | Development toolchain churn |
| Moving `master` references | Easy updates | Not reproducible |

### Recommendation

For M0, pin Zig `0.17.0-dev.1509+bb296ab9b`, `turso.zig` commit
`f1b82da9f9207bee085808ad6a8686a9780ed76d`, and its exact Turso Database
transitive commit. Never depend on an unqualified branch.

The scaffold records these in `versions.json`; M0 must add the immutable Zig
package hash. A stable-channel migration is a deliberate later decision, not
an automatic upgrade.

## D06. Event write path

### Candidates

| Candidate | Advantages | Costs |
| --- | --- | --- |
| Direct transaction per event | Simple durability; response means committed | More fsync/transaction overhead |
| Bounded in-memory queue and batches | Better throughput | Accepted events can be lost; worker and shutdown protocol |
| Append log then batch into DuckDB | Excellent ingestion isolation | A third durable format, replay, compaction, and more code |

### Recommendation

Commit each event before returning success. The expected request rate makes
throughput optimization irrelevant. If M0 measures unacceptable latency,
first test a short explicit transaction group inside the one process; do not
add a queue without a written loss and backpressure contract.

## D07. Unique visitors and sessions

### Candidates

| Candidate | Accuracy | Privacy/complexity |
| --- | --- | --- |
| First-party random cookie | Better cross-day uniqueness | Cookie policy and cross-origin collection complications |
| Stable IP + UA hash | Cross-day approximation | Long-lived pseudonymous fingerprint |
| Daily site-scoped keyed hash | Daily approximation and sessions within a day | Cannot identify the same visitor across days |
| JavaScript fingerprint | Potentially stable | Explicitly unacceptable |

### Recommendation

Derive a 128-bit keyed BLAKE3 pseudonym from site ID, UTC date, normalized IP
network prefix, and a coarse user-agent input. Use IPv4 `/24` and IPv6 `/48`
network prefixes. Persist only the pseudonym and derived client categories.

Define the public metric as **daily unique visitors**. A multi-day value is the
sum of distinct daily pseudonyms and may count one person on multiple days.
Sessionize within a UTC day using 30 minutes of inactivity.

This trades cross-day accuracy for an honest cookieless privacy boundary.

## D08. Persisted visitor data

### Candidates

| Candidate | Advantages | Costs |
| --- | --- | --- |
| Store raw IP and user agent | Reprocess classifications later | Sensitive data and greater breach impact |
| Store encrypted raw values | Reprocessing plus at-rest protection | Key lifecycle and still-sensitive runtime access |
| Store only derived dimensions and rotating pseudonym | Smallest privacy surface | Classification cannot be retroactively improved |

### Recommendation

Persist only the daily pseudonym, country code, browser family, OS family, and
device category. Unknown values remain unknown. Never log or persist the raw
inputs.

## D09. Country and browser/OS/device classification

### Candidates

| Candidate | Advantages | Costs |
| --- | --- | --- |
| Trusted Cloudflare `CF-IPCountry` + local UA rules | No GeoIP database service; tiny | Unknown when traffic bypasses Cloudflare; coarse UA coverage |
| Local MaxMind database + mature UA regex data | Broader and more accurate | Large recurring data dependency and update process |
| Third-party enrichment API | Easy initial integration | Blocking network work, privacy disclosure, availability and cost |
| Client-supplied fields | Small server | Untrusted and spoofable |

### Recommendation

When the request came through the explicitly trusted Caddy/Cloudflare path,
accept the two-letter Cloudflare country header; otherwise store `ZZ`. Use a
small, test-driven server-side classifier for a documented set of browser, OS,
and device families, falling back to `Other` or `Unknown`.

Do not add MaxMind until measured unknown rates make the maintenance dependency
worthwhile. Never call an enrichment network service on the collection path.

## D10. Collection protocol

### Candidates

| Candidate | Advantages | Costs |
| --- | --- | --- |
| JavaScript POST only | Clean payload and status | No JavaScript-disabled page views |
| Pixel GET only | Works without JavaScript | URL limits, cache concerns, weak custom events |
| Server access-log import | Zero tracker code | Couples to proxy log formats and cannot express custom events |
| POST plus pixel fallback | Complete baseline and bounded custom events | Two narrow endpoints |

### Recommendation

Use a small nonblocking tracker that sends `text/plain` JSON via
`navigator.sendBeacon` or a simple `fetch`, plus a `GET /v1/p.gif` fallback for
server-rendered `<noscript>` markup. Both normalize to the same domain event.
The pixel is `no-store`; the tracker asset is immutable and self-hosted.

Access-log import can be evaluated later as an optional adapter, not as the
canonical event model.

## D11. Aggregation strategy

### Candidates

| Candidate | Advantages | Costs |
| --- | --- | --- |
| Query raw events on demand | No workers or invalidation; always current | Repeats scans |
| Materialized daily rollups | Fast predictable reports | Background work, corrections, versioning, invalidation |
| In-memory cache | Cheap repeated reads | Memory use and stale-data rules |

### Recommendation

Query raw events on demand. With the target traffic, this is the least code and
most trustworthy behavior. Add a bounded cache or daily rollup only after a
recorded report exceeds its latency budget on a representative dataset.

## D12. HTTP implementation

### Candidates

| Candidate | Advantages | Costs |
| --- | --- | --- |
| Zig standard library plus local route switch | No framework dependency; narrow surface | Some local protocol code |
| Copy Cloudio's current HTTP modules | Known nearby code | Copies a broader surface before semantics are proven shared |
| Extract a shared `web.zig` package now | Potential reuse | Premature abstraction and coordinated releases |
| Third-party framework | Features quickly | Dependency and conceptual surface |

### Recommendation

Start with `std.http`/`std.Io` and a small explicit route switch. Local
duplication of a few proven primitives is allowed. Extract shared web code only
after Cloudio and Analytico have two real consumers with the same semantics.

## D13. Dashboard, HTMX, and Cloudio

### Candidates

| Candidate | First-view behavior | State ownership |
| --- | --- | --- |
| SPA/dashboard API | Empty shell then fetch | Client state model |
| Standalone server-rendered dashboard | Complete HTML | Analytico process |
| Cloudio links to standalone dashboard | Complete HTML | Analytico process |
| Analytico compiled into Cloudio | Complete HTML | One Cloudio process |
| Cloudio opens DuckDB separately | Temptingly direct | Violates one-writer process boundary |

### Recommendation

M6 builds complete server-rendered pages in Analytico first. M7 may vendor an
exact HTMX 4 release to enhance native links/forms. M8 decides whether Cloudio
links, embeds the modules as the single database-owning process, or fetches
complete server-rendered HTML with a timeout.

HTMX `4.0.0-beta6` is currently only an evaluated prerelease. Do not put it in
the MVP. At M7, pin the then-selected exact asset and checksum; stable HTMX 4 is
preferred. HTMX's own documentation describes `hx-boost` as progressively
enhancing ordinary links and forms: [HTMX 4 documentation](https://four.htmx.org/htmx-4/).

## D14. Deployment

### Candidates

| Candidate | Advantages | Costs |
| --- | --- | --- |
| Docker Compose | Familiar packaging | Container runtime, image layers, volumes, and health orchestration |
| Native systemd service behind existing Caddy | One process and direct files | Platform-specific unit |
| Integrate into Cloudio immediately | One eventual application | Couples an unproven MVP to the existing project |

### Recommendation

Deploy one ReleaseSafe binary as an unprivileged systemd service behind the
existing Caddy. Keep the executable, configuration, secret, metadata DB, event
DB, and backups in explicit paths. Do not add Docker for this VPS.

## D15. Administration and authentication

### Candidates

| Candidate | Advantages | Costs |
| --- | --- | --- |
| Local CLI only | Unix permissions are the boundary | Requires shell access |
| Password/session web admin | Remote convenience | Credential, cookie, CSRF, reset, and session work |
| Caddy Basic Auth for the later private dashboard | Small and already at the server boundary | Single-owner only |

### Recommendation

Use local CLI administration for the MVP. Public collection identifiers are not
secrets; exact origin validation and rate limits constrain them. For the later
single-owner private dashboard, bind Analytico to loopback and use the existing
Caddy boundary with Basic Auth plus exact-origin checks on modifying forms.
Do not build accounts, password reset, sessions, or passkeys without a real
multi-user requirement.

## D16. Backup and retention

### Candidates

| Candidate | Advantages | Costs |
| --- | --- | --- |
| Copy live files | Easy | Can omit WAL state or capture an inconsistent file |
| Online backup coordinator | No downtime | Additional admin protocol and cross-store coordination |
| Stop service, checkpoint, copy, hash, reopen | Simple and verifiable | Brief collection downtime |

### Recommendation

For the low request rate, stop the service, checkpoint and close both stores,
copy to a new backup directory, write sizes/schema versions/SHA-256 in a
manifest, rehearse restore into an isolated directory, then restart. Never
overwrite the only backup.

Default event retention is 400 days. An explicit offline `maintain` command
deletes older rows and checkpoints. Automation is added only after the manual
procedure is proven and its brief downtime is understood.

DuckDB's `CHECKPOINT` synchronizes WAL data to the database file:
[DuckDB CHECKPOINT](https://duckdb.org/docs/lts/sql/statements/checkpoint).

## D17. Scaling path

### Candidates

| Triggered option | Use when |
| --- | --- |
| Prepared inserts or bounded transaction batches | Measured direct-insert latency misses the collection budget |
| Bounded report cache | Repeated identical reports miss the query budget |
| Daily materialized rollups | Raw scans miss budget and cache hit rate is insufficient |
| Monthly Parquet partitions queried by DuckDB | Retained event file or maintenance time becomes operationally material |
| Separate ingestion log | Collection and analytical write availability need different failure domains |
| Server analytics database | One-process ownership or one-VPS capacity is demonstrably exhausted |

### Recommendation

No scaling component is selected now. Each requires the corresponding measured
trigger and a new decision entry.

## D18. Plausible replacement

### Candidates

| Candidate | Advantages | Costs |
| --- | --- | --- |
| Import ClickHouse history | One continuous dashboard | Mapping effort and migration risk |
| Start fresh and cut over directly | Clean semantics and simplest path | Historical data remains in the old system/export |
| Run both systems in parallel | Comparison data | Delays completion without much value at this traffic |

### Recommendation

Start fresh and hand the owner a direct-cutover runbook after the product and
dashboard milestones are complete. Exporting Plausible history is optional and
does not block Analytico. The agent does not stop or remove Plausible; the owner
will do that after accepting the finished replacement.
