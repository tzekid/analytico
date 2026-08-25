# Decision register

This register covers consequential product and architecture decisions. It does
not require an ADR for reversible local implementation details. A new
dependency, process, protocol, durable schema, security boundary, metric
semantic, or application state model is consequential and must be added here.

## Summary

| ID | Decision | Recommendation | Status |
| --- | --- | --- | --- |
| D01 | Historical M0–M4 interface | Collector + local CLI before dashboard work | Superseded after M4 by D13/D23/D24 |
| D02 | ClickHouse replacement | DuckDB | Accepted |
| D03 | Storage topology | Turso metadata + DuckDB events | Accepted |
| D04 | DuckDB integration | Direct pinned LTS C API | Accepted |
| D05 | Zig and Turso channel | Exact local development pins | Accepted |
| D06 | Ingestion durability | Direct synchronous insert | Accepted |
| D07 | Metric-v1 visitor/session identity | Cookieless site-scoped daily pseudonym | Accepted for v1; superseded for new 1.0 data by D26 |
| D08 | Metric-v1 persisted visitor data | Derived dimensions and daily pseudonym only | Accepted for v1; extended by D26 |
| D09 | Country and client classification | Trusted country header + small local classifiers | Accepted |
| D10 | Collection transport | POST beacon plus optional GET pixel | Accepted |
| D11 | Aggregation | Query raw events on demand | Accepted |
| D12 | HTTP implementation | Zig standard library plus local narrow routing | Accepted |
| D13 | Dashboard and HTMX | Server HTML first; HTMX 4 later | Accepted |
| D14 | Deployment | One binary under systemd behind Caddy | Accepted |
| D15 | Administration/auth | Local CLI for MVP | Accepted |
| D16 | Backup and retention | Stop-the-service verified snapshots; explicit maintenance | Accepted |
| D17 | Scale path | Measure, then batch/Parquet/server DB | Accepted |
| D18 | Plausible migration | Fresh start and direct cutover | Accepted |
| D19 | Metadata writes on pinned Turso | Durable autocommits with compensation | Accepted |
| D20 | Collector concurrency | One bounded sequential accept loop | Accepted |
| D21 | Metric-v1 session boundaries | Persist event-local boundaries at commit | Accepted for v1; extended by D26 |
| D22 | Cloudio integration | Optional ordinary link to standalone Analytico | Accepted |
| D23 | Private dashboard authentication | Passkey-only owner gate after staged Basic Auth cutover | Accepted and deployed |
| D24 | Public and dashboard URL topology | One canonical hostname with strict path routing | Accepted and deployed |
| D25 | Dashboard functional-quality pass | Separate native state transitions with minimal enhancement | Accepted for U1 |
| D26 | 1.0 identity and sessions | Persistent first-party anonymous identity, explicit identify/reset, cross-midnight client sessions | Accepted for 1.0; implemented by #6–#9 and #13 |
| D27 | 1.0 site-local time | Explicit IANA zone with bounded host-TZif reader and stored local dates | Accepted; implemented by #11 with #13 migration evidence |
| D28 | Protocol-v2 and event-schema-3 foundation | Separate bounded route, explicit identity quality, single-writer idempotency, transactional schema swap | Accepted for 1.0 issue #6 |
| D29 | Typed metric-v2 analysis boundary | Separate closed domain model and finite bound-SQL compiler; preserve metric-v1 reports | Accepted for 1.0 issue #24 |
| D30 | Traffic-quality compatibility diagnostics | Add a versioned bounded diagnostic bundle aligned to the frozen UTC Overview range | Accepted for 1.0 issue #66 |
| D31 | Stored self-exclusion and non-bot inflation | Prerender/localhost guards, keyed ephemeral visitor-days, and stored bounded exclusion sources | Accepted for 1.0 issue #67 |
| D32 | Permanent traffic class and UA classifier | Schema-5 stored classes with a pinned local classifier and one-release legacy shadow | Accepted for 1.0 issue #68 |
| D33 | Bounded browser and receipt traffic evidence | Schema-6 closed signal fields, classifier v2, and permanent class eligibility | Accepted for 1.0 issue #69 |
| D34 | Query-time suspected traffic and site safeguards | Reversible suspected-session filtering, keyed network-day evidence, and a daily accepted-event ceiling | Accepted for 1.0 issue #70 |
| D35 | Exact one-entry Overview result cache | Narrowly supersede D29's cache prohibition after measured cold SQL misses | Accepted for 1.0 issue #27 |
| D36 | Browser site creation and metadata schema 6 | D19 durable autocommits, exact retry, stored settings, and unique origin ownership | Accepted for 1.0 issue #19 |
| D37 | Bounded Analyze Trend query set | Preserve one-metric queries under one server-rendered shared-deadline envelope | Accepted for 1.0 issue #28 |
| D38 | Installation verification state | Session-bound signed URL watermark plus durable event lookup and restart-scoped rejection guidance | Accepted for 1.0 issue #20 |
| D39 | Server-rendered Analyze Breakdown | Extend the single D29 query with bounded aggregate-label search and a shared-deadline typed property catalog | Accepted for 1.0 issue #29 |
| D40 | Universal filters, segments, and saved views | Resolve one canonical FilterSet context; persist exact site-owned state in metadata schema 7 | Accepted for 1.0 issue #30 |
| D41 | Guided goal lifecycle and metadata schema 8 | Replace raw goal administration with bounded discovery, archive-first lifecycle, and reference-safe deletion | Accepted for 1.0 issue #33 |

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

### Historical status

M6, M7, and the passkey milestones are now shipped. This decision remains the
M0–M4 sequencing record, not a current claim that Analytico lacks a dashboard.
Decisions D13, D23, and D24 govern the deployed server-rendered `/admin` UI.

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

### M0 evidence

Accepted. The verified official Linux AMD64 artifact is linked as a private
shared runtime because its single static archive is not self-contained. The
application still runs as one process; DuckDB remains in-process and stores
events in one ordinary file. The direct wrapper configures one query thread,
128 MiB of buffer memory, a 256 MiB temp limit, and disables external access
and community extensions. Exact artifact, library, header, and Zig package
hashes are recorded in `versions.json`.

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

Accepted after Debug and ReleaseSafe builds used the immutable Zig package
hash and compiled the pinned Turso engine source. A mismatched prebuilt parent
library was deliberately rejected by the binding's runtime version check. A
stable-channel migration is a deliberate later decision, not an automatic
upgrade.

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

### Version boundary

D07 remains authoritative for protocol-v1/event-schema-2 rows and metric-v1
compatibility reports. D26 supersedes it only for new compatible 1.0 data.
Migration must mark old rows `legacy_daily`, preserve visitor-day totals, and
never link their pseudonyms across UTC dates.

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

D26 extends this choice for protocol-v2 rows with random first-party anonymous
IDs and optional bounded application user IDs. The enduring boundary remains:
never persist raw IP addresses, full user-agent strings, or a fingerprint
derived from them.

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

### M2 evidence

Accepted. Country and UA inputs are reduced in the request arena and discarded.
The end-to-end privacy audit finds neither raw value in either database or
captured log. Unknown and bot fixtures use explicit categories; no enrichment
network or data-file dependency exists.

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

### M2 evidence

Accepted. Real Chromium, Firefox, and WebKit each emit one POST page view, and
each JavaScript-disabled fixture emits one pixel view. Both paths commit the
same event shape. The tracker uses no browser storage and is 383 bytes Brotli.

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

### M2 evidence

Accepted. The local parser and route switch enforce the complete fixed protocol
surface without a framework or middleware model. ReleaseSafe collection p95 is
5.807 ms through real HTTP, and adversarial target/header/body inputs remain
bounded.

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

### M7 selection

At M7 there was still no stable HTMX 4 release. The candidates were:

| Candidate | Advantages | Costs |
| --- | --- | --- |
| Keep complete M6 HTML only | Zero new browser bytes and risk | Does not deliver the requested HTMX 4 enhancement |
| HTMX 2 stable | Mature | Does not satisfy the HTMX 4 requirement and creates a migration |
| HTMX 4.0.0-beta5 | Earlier prerelease | Superseded by beta6 fixes |
| HTMX 4.0.0-beta6 core | Current exact 4.x release; removal-safe over M6 | Prerelease behavior may still change |

Select `4.0.0-beta6` core at tag commit
`6ca11fbdc881a96c5fbeb0d7094a77183120ea22`. It is an optional enhancement,
not an application state model: ordinary links/forms remain canonical and the
server returns its complete HTML through the same controller. The exact npm
artifact is pinned by Zig package hash; the 36,282-byte minified core has
SHA-256 `28fae7bbe8e8142b702debb9d5234a9a436d9435a4b5165b195aa1a7ed840d25`.
A pinned-Zig build tool produces the 13,014-byte gzip representation, SHA-256
`74cc4013d2f7a7d072fdcc0f3ac61929ee4254798b0f6750adad6d34b137da1b`.
No extension, CDN, runtime package manager, compatibility layer, or
application-authored JavaScript is loaded. Re-evaluate only for a stable 4.x
release or an observed beta defect.

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

### M4 evidence

Accepted. The checksummed archive carries one executable and one private
DuckDB shared library. The checked-in unit uses an unprivileged fixed user,
strict filesystem access, empty capabilities, and a 256 MiB cgroup ceiling;
`systemd-analyze security --offline` scores it 3.2/10, `OK`. The validated
Caddy vhost exposes only the two tracker and two event routes and overwrites
both headers that influence derived visitor data. Release extraction proves
`$ORIGIN/../lib` selects the archive's DuckDB library.

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
owner requirement.

### M6 evidence

Accepted. A separate Caddy vhost challenges unauthenticated requests before
proxying only `/admin` routes. The application remains loopback-only and uses
POST/redirect/GET, a per-installation CSRF token, exact `Origin` comparison,
and context-specific escaping. Basic Auth has no server logout operation, so
the dashboard deliberately has no fake logout route or second session model;
the browser owns cached credential lifetime. Real Chromium with JavaScript
disabled proves challenged and authenticated access plus all modifying forms.

This was the accepted `0.1.0` boundary. The owner's later requirement for a
Touch ID/Face ID login and application logout supersedes the permanent-auth
part of this decision for post-`0.1.0` work; see D23. Basic Auth remains the
deployed gate until that cutover is implemented and accepted.

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

### M4 evidence

Accepted. The real-process gate checkpoints and creates two independent
backups, verifies all manifest hashes, restores each in isolation, and matches
reports. Corrupted content, an incompatible manifest, an existing destination,
and wrong key mode leave no partial destination. Maintenance refuses a
too-recent cutoff without touching data, deletes exactly the `< cutoff` event,
and completes a disabled-site delete. A previous binary built from the actual
M3 commit successfully starts against the restored pre-upgrade snapshot.

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

## D19. Metadata writes on the pinned Turso engine

### Candidates

| Candidate | Advantages | Costs |
| --- | --- | --- |
| Explicit multi-write transactions | Ideal all-or-nothing metadata changes | The pinned `0.8.0-pre.2` engine reports a false `pwrite: quota exceeded` on this filesystem for these transactions |
| Durable autocommits plus compensating delete | Uses the requested engine and each successful row is durable | A process crash between parent and child writes can leave an incomplete row until `doctor`/retry repairs it |
| Replace Turso with SQLite or DuckDB metadata | Avoids the pin-specific behavior | Discards the requested Torso binding and changes the accepted storage topology |
| Wait for an upstream engine update | May restore transaction behavior | Blocks a small private project on a development-channel fix |

### Recommendation

Use individual durable autocommits for metadata on the current pin. Multi-row
commands insert the parent first and synchronously delete it if a child insert
returns an error. Numbered `CREATE TABLE IF NOT EXISTS` migrations are replayable
and write their ledger row last. `doctor` remains the place to detect incomplete
state after an actual process crash.

This is a narrow workaround for a measured pin/filesystem interaction, not a
generic transaction abstraction. Re-test explicit transactions when upgrading
Turso; remove the compensation path if the real end-to-end scenario passes.

## D20. Collector concurrency

### Candidates

| Candidate | Advantages | Costs |
| --- | --- | --- |
| One sequential accept loop | Smallest ownership model; one DuckDB writer; naturally bounded | One slow connection can delay later connections |
| Fixed worker pool | Bounded parallel connections | Synchronization, multiple connection state, coordinated shutdown |
| Task per connection | Familiar server shape | Input can create unbounded work without another admission layer |
| General async HTTP framework | Mature concurrency features | New dependency and application model before load needs it |

### Recommendation

Use one sequential loop for the expected 20–50 weekly visitors. It owns one
active connection, keeps DuckDB write ordering obvious, and lets SIGTERM
interrupt the listener and active socket deterministically. Caddy supplies
outer connection and timeout limits.

Accepted after the M2 real-browser, malformed-request, and 100-request
ReleaseSafe runs. Revisit a fixed worker pool only if measured proxy queueing or
collection latency breaches its budget under representative concurrency.

## D21. Session-boundary computation

### Candidates

| Candidate | Advantages | Costs |
| --- | --- | --- |
| Recompute sessions with report windows | Pure raw events; naturally handles arbitrary late inserts | Repeats two ordered windows; measured funnel exhausted 128 MiB and exceeded its deadline at one million rows |
| Materialized daily/session rollups | Fast reports | New tables, invalidation, migration semantics, and background work |
| Persist session UUID and two boundary booleans per event | One writer already knows the prior event; reports remain raw scans | The receipt-time write order becomes an explicit invariant |

### Recommendation

Persist `session_id`, `visitor_day_start`, and `session_start` in the same bound
DuckDB insert that commits the event. These are local facts about that event,
not cached aggregate results. The collector remains sequential, uses no worker,
and returns success only after the one statement commits.

The v1-to-v2 DuckDB migration reconstructs the facts with the original
timestamp/UUID ordering. Hand fixtures prove the exact 30-minute boundary,
tied timestamps, UTC midnight, restart, and migration behavior. On the
million-event ReleaseSafe fixture, the accepted design measured overview p95
at 111 ms and an eight-step funnel p95 at 982 ms across ten full CLI processes.
The changed durable insert path measured 11.326 ms p95, within its 25 ms
budget. All remain within the existing gates.

D21 remains the metric-v1 and legacy-row contract. D26 lets new compatible
events supply a validated random session UUID and sequence, preserves the
event-local `session_start` fact, and permits that client session to cross UTC
midnight. Existing session IDs are not recomputed during migration.

## D22. Optional Cloudio integration

### Candidates

| Candidate | Runtime/deployment | Failure and authorization boundary | Coupling |
| --- | --- | --- | --- |
| Ordinary Cloudio link to standalone Analytico | Two existing processes; no upstream request in Cloudio's first view | Cloudio keeps passkeys; Analytico keeps Caddy Basic Auth; either application can fail independently | One optional URL and one escaped anchor |
| Link Analytico modules into Cloudio | One process after a substantial merge | Cloudio must own DuckDB, adopt Analytico lifecycle operations, and reconcile passkey authorization with the dashboard | One release, dependency graph, backup contract, and rollback unit |
| Server-side HTML proxy with a strict timeout | Two processes plus an upstream request per analytics view | Needs an honest timeout page and either a second login or a signed, expiring forwarded identity contract | Cloudio availability and first-view latency depend on Analytico response semantics |

Two processes opening the writable DuckDB file is rejected rather than treated
as a fourth candidate.

### Recommendation

Keep Analytico standalone and, when the owner wants the affordance, expose one
optional ordinary `Analytics` link in Cloudio. Do not proxy HTML, forward
identity, share a session, import modules, or extract a common web framework.
This keeps exactly one writable DuckDB owner and lets both products upgrade and
roll back independently.

The reviewed integration is retained as a patch against an exact clean Cloudio
revision rather than applied to Cloudio now. The owner described this expansion
as later work, and Cloudio had concurrent settings changes during M8. The patch
therefore proves the integration without coupling either current worktree or
release.

### M8 evidence

The ReleaseSafe candidate was built from Cloudio commit
`cad77b48119cdedbc1b1370067141a07c9b5dc06`. Real Chromium enrolled a disposable
passkey, disabled JavaScript, loaded a complete authenticated Cloudio first
view, and followed the ordinary link through Analytico's real Basic Auth
boundary. One measured run observed 16.6 ms to Cloudio's first response and
961.3 ms to Analytico's first response; these are local single-run observations,
not percentile claims.

Cloudio made zero Analytico requests for its first view. With Analytico stopped,
Cloudio still returned a complete `200` page. `/proc` file descriptors showed
only the Analytico process owning `events.duckdb`. Removing the optional URL and
restarting only Cloudio removed the link, while direct standalone Analytico
remained healthy. No identity is forwarded and no shared abstraction was added.

## D23. Passkey-only private dashboard authentication

### Candidates

| Candidate | Advantages | Costs |
| --- | --- | --- |
| Retain Caddy Basic Auth | Already released and operationally small | Password UX, cached browser credential lifetime, no real logout/revocation |
| Passkey-only owner gate in Analytico | Touch ID/Face ID, origin-bound WebAuthn, revocable sessions, no password | Small browser API island plus verifier/session state |
| External identity proxy | Mature authentication features | Another runtime and substantially more machinery than one owner needs |
| Share Cloudio identity/session | One apparent login | Couples origins, cookies, releases, availability, and authorization |

### Recommendation

Add one discoverable, user-verified passkey owner and server-side revocable
sessions inside Analytico. Keep the collector public and unchanged; keep all
auth metadata in Turso; keep Caddy as the TLS, hostname, limit, and loopback
boundary. Retain Caddy Basic Auth only during migration, then remove it after a
real passkey enrollment/login/logout acceptance run.

Port Cloudio's narrow, exercised WebAuthn verification semantics without
sharing sessions or copying its unrelated framework. Extract shared code only
after both concrete consumers demonstrate identical semantics. The complete
route, storage, recovery, migration, threat-boundary, and end-to-end acceptance
contract is in the [passkey authentication specification](PASSKEY_AUTH_SPEC.md).

## D24. Public and dashboard URL topology

### Candidates

| Candidate | Advantages | Costs |
| --- | --- | --- |
| Separate collector and dashboard hostnames | Coarse hostname-level routing boundary | A second URL and certificate path, a dead-looking dashboard root, and WebAuthn origin churn |
| One hostname with strict path allowlists | One discoverable URL and one WebAuthn origin while preserving explicit proxy routes | Collector and dashboard share the TLS origin |
| Move the dashboard itself to `/` | Shortest dashboard URL | Application route migration, redirects, and needless compatibility code |

### Recommendation

Use one canonical hostname. Caddy publicly forwards only the documented
tracker and collection paths, forwards `/admin` and `/admin/*` to the same
loopback process, redirects exact `/` to `/admin`, and returns `404` for every
unknown path. Analytico remains the server-side authorization boundary for all
dashboard state. This removes the second hostname without adding a proxy auth
model or changing the stable application route tree.

## D25. Dashboard functional-quality pass

### Candidates

| Candidate | Advantages | Costs |
| --- | --- | --- |
| Keep one combined filter form | Smallest markup | Site, date, report subject, and pagination state remain coupled and ambiguous |
| Separate native forms plus minimal auto-submit enhancement | Explicit server state, useful without JavaScript, immediate site switching when available | One tiny browser-only script and slightly more markup |
| Build a client-side dashboard state model | Richest interaction freedom | Duplicates server state and violates the product doctrine |

For definition management, U1 also considered leaving both large forms always
visible, moving them to a new settings route, and placing the existing native
forms in a collapsed disclosure. A separate route belongs in the later journey
and information-architecture work; always-visible forms obscure the reports.

### Recommendation

Use separate native GET forms for site and date/report context. A site change
always resolves to the destination overview, while a date change preserves the
current applicable report and resets pagination. A tiny self-hosted script may
call the site form's native `requestSubmit`; the visible submit button remains
the baseline. Keep goal and funnel management in one native collapsed
disclosure for U1. Apply a consistency pass now, then make the visual and
information-architecture decisions in the planned follow-on design milestone.

That recommendation records the U1 boundary. U1 is now accepted, and the
Analytico 1.0 design-system and shell epic #14 supersedes the U2 label for
follow-on design work. Written responsive/accessibility contracts govern;
exploration images are non-binding.

## D26. Persistent first-party identity and cross-midnight sessions

**Status:** Accepted for Analytico 1.0; collector/schema (#6), tracker
anonymous identity/`reset()` (#7), and 30-minute client session rotation (#8)
implemented; explicit identify/conflict/person resolution (#9) implemented;
exact legacy identity migration and mixed-data coverage implemented by #13

**Date:** 2026-08-21

**Issues:** #6–#9 and #13

### Context

Retention, returning visitors, cross-session funnels, session timelines, and
identified-user history cannot be represented honestly by D07's rotating
visitor-day pseudonym. The 1.0 scope requires those answers while retaining the
one-process runtime, explicit privacy limits, protocol-v1 compatibility, and
honest treatment of existing rows.

### Candidates

| Candidate | Advantages | Costs and risks |
| --- | --- | --- |
| Keep the daily IP-prefix/client pseudonym | No browser storage; current privacy boundary and metrics remain unchanged | Cannot answer required cross-day or cross-session questions |
| Random site-scoped first-party anonymous UUID plus explicit `identify()`/`reset()` and client session UUID | Stable anonymous continuity without fingerprinting; explicit cross-device link; sessions can cross midnight | Adds bounded first-party storage, identity migration, conflict rules, and compatible-data coverage |
| Stable server hash of IP and user agent | No tracker storage | Creates a long-lived fingerprint, remains inaccurate, and increases privacy risk |
| Application-supplied user ID only | Strong meaning when logged in | Excludes anonymous traffic and pushes identity requirements onto every measured site |
| Browser fingerprint graph | Broad continuity | Explicitly outside scope and unacceptable |

### Recommendation

Select the random first-party design for protocol-v2 compatible events:

- The tracker stores a random anonymous UUID in `localStorage` under a per-site
  key on the measured origin. When storage is unavailable, it uses a
  page-lifetime random ID and marks the event `ephemeral`; analytics failure
  never breaks the site.
- The tracker stores a random session UUID, last-activity time, and sequence.
  It rotates the session after more than 30 minutes of inactivity, not at
  midnight. The server validates and persists the supplied UUID/sequence and
  marks the first accepted event as the session start.
- `identify(user_id, traits)` accepts bounded untrusted application data. One
  anonymous ID may link to at most one user until `reset()` creates a new
  anonymous and session ID. Repeating the same link is idempotent; a different
  user without reset is rejected as `identity_conflict` and never merged. The
  tracker does not overwrite its first local identified-user state with the
  conflicting ID; DuckDB links, not browser state, remain authoritative.
- One user ID may link multiple anonymous IDs only through explicit equal IDs.
  Anonymous devices are never joined by inference. User IDs and traits are not
  authentication or authorization inputs.
- Canonical person keys and latest bounded traits are derived from accepted
  links and identify events. No mutable profile table or inferred identity
  graph is introduced.
- No tracker cookie, raw IP, full user agent, fingerprint API, cross-site
  identifier, or claim that an anonymous ID equals a real person is introduced.

Protocol v1 remains accepted during a documented compatibility window. Schema
2 rows migrate with `identity_quality=legacy_daily` and a deterministic
synthetic UUID scoped only to `(site_id, received_date_utc, visitor_day_id)`.
They are never linked across dates. Traffic totals retain metric-v1
compatibility; new/returning classification, retention, user profiles, and
cross-session visitor funnels exclude incompatible rows or expose an explicit
coverage-limited result.

The upgrade is an explicit offline operation. A candidate may create and
verify a schema-2 backup using the existing manifest format, but it must not
rewrite legacy stores through `report`, `site`, `event`, authentication, or
other ordinary commands. Migration requires the matching verified database
pair, checks conservative free space, validates the complete preserved-field
mapping before the table swap, and keeps the backup usable by the v0.3.0
binary. Mixed-data coverage is the share of distinct canonical people with
persistent identity among all meaningful-event people in the bounded range;
legacy and ephemeral counts remain explicit rather than being coerced into
persistent people.

### Consequences

- D07, D08, and D21 remain authoritative for metric-v1 and legacy rows and are
  superseded only for new compatible 1.0 events.
- DuckDB event schema 3 and `identity_links` remain inside the single owning
  process. Turso does not query them. The browser tracker gains no dependency
  or background communication primitive.
- A new tracker revision receives a new content-hashed path. Every previously
  published immutable tracker path continues to serve its exact original bytes;
  only the short-cache alias advances.
- Identity, traits, storage, payload, sequence, and conflict work is bounded
  and output-escaped. The existing origin, CSRF, passkey, SQL, and raw-request
  privacy boundaries remain in force.
- Migration requires a verified database-pair backup and preserves event IDs,
  current fields, session IDs, and metric-v1 totals. Rollback restores the
  pre-migration pair rather than opening schema 3 with the old binary.

**Affected contracts:** `SCOPE_1.0.md`, `SPEC.md`, `ARCHITECTURE.md`,
`DATA_MODEL.md`, and `PROTOCOL.md`.

### Acceptance evidence

Issues #6–#9 and #13 must prove protocol compatibility, storage-unavailable and
multi-tab behavior, exact 30-minute and midnight boundaries, reset and conflict
handling, no inferred cross-device link, legacy coverage, repeated migration,
and database-pair rollback through the real tracker, collector, executable,
and on-disk stores. Issue #6 landed collector/schema evidence. Issue #7 landed
real-browser persistence, storage-unavailable ephemeral marking, reset, and
site-scoped keys. Issue #8 landed 30-minute inactivity rotation, persisted
sequence, and cross-midnight reuse. Issue #9 landed two-browser same-user,
shared-browser conflict/reset, derived person/latest-trait, and transactional
store-failure evidence. Issue #13 lands the exact v0.3.0 upgrade, legacy
isolation, mixed coverage, interruption/retry, and database-pair rollback.

## D27. Explicit site-local dates through bounded TZif parsing

**Status:** Accepted for Analytico 1.0; implemented by issue #11 with exact
migration evidence from issue #13

**Date:** 2026-08-21

**Issues:** #6, #11, and #13

### Context

UTC-only metric-v1 dates split ordinary local days and make range presets,
comparisons, retention, and session presentation surprising. Analytico 1.0
requires each site to use an explicit IANA reporting timezone without adding a
large internationalization runtime or allowing timezone changes to silently
rewrite historical totals.

### Candidates

| Candidate | Advantages | Costs and risks |
| --- | --- | --- |
| Keep UTC-only reporting | No parser, data, or migration change | Does not meet the approved reporting contract |
| Process-global libc timezone conversion | Uses host data | Global mutable state is unsafe for multiple sites and behavior is difficult to bound |
| Bundle a timezone library and tzdb | Broad mature API and reproducible data | Adds dependency, binary/data size, update, provenance, and maintenance cost |
| Read configured host TZif v2/v3 files with a narrow Zig parser | Small auditable surface; supports multiple sites; no runtime download | Requires careful bounds, DST policy, corrupt-file handling, and host tzdb operations |

### Recommendation

Select a small Zig reader for IANA TZif v2/v3 files from a configured zoneinfo
root, defaulting to `/usr/share/zoneinfo`:

- Validate zone-name segments and reject absolute paths, `.`, `..`, NUL, and
  traversal. Bound file bytes, transition/type counts, and abbreviations; parse
  the 64-bit transition section. A bounded POSIX footer rule supplies future
  transitions when the TZif table delegates to it; malformed, leap-second, or
  unsupported data fails closed.
- A site stores an explicitly selected IANA zone. A server-derived zone may be
  offered as a form suggestion but is never silently selected. Existing sites
  must receive an explicit migration choice; `UTC` is valid.
- UTC receipt time remains authoritative. At ingestion, store the derived
  `site_local_date` and UTC offset from the site-policy snapshot so ordinary
  historical grouping does not change when host tzdb later changes.
- Inclusive local-date UI ranges resolve to UTC instants with explicit DST
  gap/overlap behavior. A nonexistent local midnight advances to the first
  valid instant; tests define earliest-start and latest-next-boundary behavior
  for an ambiguous midnight.
- Missing or corrupt configured zone data fails site creation or site-policy
  loading. It never falls back to the process/server timezone.
- Offsets persisted in the schema's minute field must be exactly representable;
  historical second-resolution offsets fail rebucketing rather than rounding.
- A timezone locks after the site's first accepted event. A change requires an
  offline backup, service stop, full rebucket from receipt time, count/date
  validation, setting revision, and checkpoint.

### Consequences

- Turso gains explicit site timezone metadata; DuckDB schema 3 stores the
  derived local date and offset while retaining UTC timestamps.
- A narrow pending marker keeps the site non-runnable while the two-file
  offline rebucket is incomplete. Retry is idempotent; no distributed
  transaction is implied.
- No network lookup, runtime extension download, ICU dependency, process-global
  timezone mutation, or speculative shared abstraction is introduced. The host
  zoneinfo installation becomes an explicit readiness and deployment input.
- Metric-v1 compatibility queries remain UTC-based. Migration derives local
  dates under the operator-selected site zone and records that choice; it does
  not alter existing event timestamps or session IDs.
- Rollback restores the verified pre-migration Turso/DuckDB pair. An older
  binary is not expected to understand the new metadata or schema.

**Affected contracts:** `SCOPE_1.0.md`, `SPEC.md`, `ARCHITECTURE.md`,
`DATA_MODEL.md`, `PROTOCOL.md`, `OPERATIONS.md`, and `PERFORMANCE.md`.

### Acceptance evidence

Issues #6, #11, and #13 cover bounded pure-parser fixtures, real zoneinfo,
UTC and Europe/Berlin across DST and leap day, invalid/traversal/missing/corrupt
zones, local range boundaries, ingestion stability, locked-zone behavior,
legacy backfill, repeated migration, and database-pair rollback. Issues #11 and
#13 land that evidence without changing frozen metric-v1 dates.

## D28. Protocol-v2 route and event-schema-3 foundation

**Status:** Accepted for Analytico 1.0 issue #6

**Date:** 2026-08-21

**Issue:** #6

### Context

The package deliberately leaves the v2 route name and exact DuckDB enforcement
mechanism open, and its sample envelope does not include the signal needed to
distinguish persistent from storage-unavailable identity. Issue #6 must settle
those details without changing the frozen protocol-v1 body limit, presenting a
temporary UTC backfill as completed site-timezone work, or accepting identify
events that violate D26's one-user-per-anonymous-ID rule.

### Route candidates

| Candidate | Advantages | Costs and risks |
| --- | --- | --- |
| Accept `v:2` on `/v1/event` | One POST route | The parser cannot select the v1 8 KiB versus v2 16 KiB limit before reading the body; the route name and compatibility telemetry are ambiguous |
| Add `/v2/event` and keep `/v1/event` unchanged | Preserves the complete v1 contract; makes limits, tests, proxy policy, and later removal explicit | One additional narrow route |
| Replace both with an unversioned `/event` | Clean future name | Adds redirects/compatibility behavior with no product benefit |

Select `/v2/event`. The payload must still contain exactly `v:2`; a route never
implies or repairs a missing/unknown version.

### Identity-quality candidates

| Candidate | Advantages | Costs and risks |
| --- | --- | --- |
| Infer persistence from UUID shape or protocol version | No new field | Impossible: persistent and page-lifetime ephemeral identities use the same random UUID grammar |
| Send an `ephemeral` boolean | Small | Negative naming becomes unclear as more quality states exist |
| Require `identity_quality` as `persistent` or `ephemeral` | Matches the stored concept and is explicit at the trust boundary | Adds one bounded string to every v2 event |

Require the string field. It is untrusted analytics metadata, not an
authentication claim. `legacy_daily` is storage-only and is rejected on the
public v2 route. Identify requires persistent quality; an ephemeral identity
cannot create a durable link.

### Idempotency and migration candidates

| Candidate | Advantages | Costs and risks |
| --- | --- | --- |
| Unique index plus raw-body comparison | Database-enforced uniqueness | Index cost over the million-row migration; semantically equal JSON with different key order conflicts |
| Compare every stored column on reuse | No internal digest | Large duplicate query that must evolve in lockstep with every column |
| Canonical normalized-field digest plus single-writer precheck | Small bounded comparison; semantically equal normalized payloads deduplicate; uses D20's established writer invariant | Direct out-of-process SQL writers would bypass it, but they are already forbidden |

Use a BLAKE3 digest over length-delimited normalized fields and check it before
the transactional insert. The same `(site_id,event_id)` and digest returns
`204` without another row; any other reuse returns fixed `409`. The digest is an
internal schema column, not user data. A v2 identify link and event commit in
one transaction. The first accepted `(site_id,session_id)` event is marked as
the session start. Issue #9 supplies the tracker identify API, stable identity
conflict classification, derived person/latest-trait resolution, and remaining
identity end-to-end acceptance.

Migration 3 uses one transactional create/backfill/swap and retains the two
metric-v1 visitor-day compatibility facts until their queries are retired.
Legacy rows receive protocol/tracker version 1, `legacy_daily`, occurrence equal
to receipt, a namespaced tuple-derived synthetic anonymous UUID, and their
existing event/session/data bytes. Before dropping the source table, the
transaction proves exact preserved rows and session IDs, one anonymous
identity per legacy day group, no cross-group identity reuse, and no identity
links. The same backfill directly derives sequence from stored session order.
Migration 3 initially records the shipped UTC date and offset zero. This is a
labeled compatibility value until issue #11's explicit-zone rebucket replaces
it; issue #13 provides the backup, mixed-quality, repeated-migration, and
rollback evidence required before metric v2 uses those columns.

### Wire and storage boundary

- The server stamps event schema 3 and tracker version 2 for protocol-v2
  envelopes. Protocol-v1 rows remain protocol/tracker version 1.
- V2 property and trait values in this foundation are bounded strings, signed
  integers, booleans, or null. Exact decimal event properties and query/type
  discovery remain issue #10; exact `value.amount` is implemented now as
  normalized `DECIMAL(18,6)`.
- The server derives a temporary visitor-day compatibility key for v2 rows so
  the shipped metric-v1 queries remain usable. It does not reinterpret that key
  as persistent-person identity.
- Protocol v1 is not removed in 1.0. Removal requires a later recorded decision,
  an explicit migration issue, deployed v2 tracker coverage for every active
  site, and operator evidence of no required v1 traffic for 30 consecutive
  days.

### Acceptance evidence

Issue #6 must prove all four v2 event kinds, normalization and parser bounds,
same/different-payload reuse, identity-link conflict atomicity, v1 compatibility,
fresh and legacy DuckDB migration, the real loopback executable, and Debug and
ReleaseSafe gates. The public Caddy allowlist and operational route inventory
must change in the same release.

## D29. Separate closed metric-v2 query model and finite compiler

**Status:** Accepted for Analytico 1.0 issue #24; D35 narrowly supersedes
the cache prohibition for one exact complete Overview-result entry only

**Date:** 2026-08-22

**Issue:** #24

### Context

The shipped report engine is intentionally frozen at metric v1: UTC report
dates, visitor-day identity, report-kind branching, and compatibility columns.
Analytico 1.0 needs site-local metric v2, persistent-person coverage, scoped
filters, selectors, Trend/Breakdown results, and canonical saved state without
allowing user-selected SQL or silently reinterpreting the operational CLI.

### Candidates

| Candidate | Advantages | Costs and risks |
| --- | --- | --- |
| Rename/generalize `report.Kind` in place | Small initial diff and immediate reuse | Couples metric v2 to UTC/visitor-day assumptions; risks changing frozen output; still cannot express scope or canonical state cleanly |
| General SQL AST or expression visitor | Broad future expressiveness | Creates an open query language, validation/optimization framework, larger attack surface, and abstractions with no accepted consumers |
| Separate closed `AnalysisQuery` domain model plus finite store compiler; map current concepts to presets | Keeps metric versions honest; enum-selected reviewed plans; future screens share one bounded contract | Some local SQL/semantic duplication remains until two real consumers prove safe extraction |

### Recommendation

Select the separate closed model and compiler defined by
`ANALYSIS_QUERY.md`:

- Pure Zig domain types own validation, canonicalization, canonical JSON, and
  canonical URL components. They have no database, HTTP, renderer, filesystem,
  or clock dependency.
- The store layer chooses from a finite metric/dimension/scope matrix and
  composes only literal reviewed SQL fragments. Every external value is bound.
- Metric-v2 execution uses stored site-local dates, schema-3 identity/session/
  engagement/value facts, explicit goal resolution, exact currencies, bounded
  result/cardinality metadata, and the existing DuckDB interrupt boundary.
- The existing metric-v1 report API, SQL, CLI output, and compatibility columns
  remain unchanged. Ordinary report concepts gain typed presets; specialized
  funnel/path/retention/session/Live engines remain separate.
- Route/calendar comparison resolution, saved Turso entities, and product UI
  remain in their issue-backed consumers. No generic AST, ORM, rollup,
  projection, service, table, migration, or dependency is introduced. D35
  later permits one exact, mutation-invalidated complete Overview-result cache after
  the complete cold SQL path was measured and rejected; it does not permit a
  generic metric-v2 cache.

### Consequences

- Metric versions cannot be selected by request text or silently coerced. A
  query is either a validated metric-v2 plan or a typed pre-database failure.
- Filter event/session/person scope becomes explicit and testable instead of an
  accidental row predicate.
- Canonical JSON/URL grammar and bounds become versioned compatibility
  contracts for later routes, segments, and views.
- Current report parity can be proved without forcing unsafe sharing or a
  big-bang UI/CLI cutover.
- Rollback removes the additive code/docs only; no store restoration or schema
  compatibility step is required.

**Affected contracts:** `SPEC.md`, `ARCHITECTURE.md`, `DATA_MODEL.md`,
`ANALYSIS_QUERY.md`, `PERFORMANCE.md`, and `RELEASE_CONTRACT_1.0.md`.

### Acceptance evidence

Issue #24 must prove pure parser/canonical bounds, plan inventory and unsupported
combination rejection, real on-disk metric-v2 semantics, scoped filters, exact
currency behavior, current report preset/parity, timeout/interrupt reuse, and
Debug/ReleaseSafe gates. Later issues prove route, browser, rendering, saved
state, and specialized-analysis consumers rather than broadening this compiler
silently.

## D30. Additive traffic-quality diagnostics beside metric-v1 Overview

**Status:** Accepted for Analytico 1.0 issue #66

**Date:** 2026-08-23

**Issue:** #66

### Context

The current Overview's `visitor_days` value is a metric-v1 receipt-UTC
compatibility total, but its UI calls the value "Daily visitors." #66 must
label that total honestly, place a canonical distinct-person count beside it,
and expose traffic composition before later classifier changes. D29 also
freezes existing metric-v1 report output and defines ordinary metric-v2
analysis over site-local dates.

### Candidates

| Candidate | Advantages | Costs and risks |
| --- | --- | --- |
| Add fields to the metric-v1 Overview SQL/output | One query and one report shape | Breaks exact metric-v1 compatibility and D29; silently versions an operational interface |
| Put a site-local person count beside the UTC visitor-day total | Reuses ordinary metric-v2 range semantics | Two values under one date filter can cover different boundary events and cannot be compared honestly |
| Add a separately versioned diagnostics result on the existing bounded report transport, using the current received-UTC range for both values | Preserves every old output; keeps the comparison honest; supplies CLI and dashboard consumers without a schema or service | A later site-local Overview migration must move both values together and retain the documented diagnostic version |

### Recommendation

Select the additive diagnostics result:

- Existing report kinds' SQL and table/JSON/CSV bytes remain unchanged. The new
  `traffic-quality` kind declares metric semantics 2 and traffic-quality
  diagnostics version 1.
- The report uses one static bound DuckDB statement, the existing 400-day input
  limit, at most 100 decoded daily rows per page, and one existing query
  deadline. Values never become SQL text.
- Canonical people use meaningful non-bot events and identity links. Coverage
  remains explicit so ephemeral and legacy pseudo-people are not presented as
  compatible persistent users.
- Identity-quality composition excludes current bot rows, while bot events are
  shown separately. No event is dropped or reclassified by #66.
- The dashboard keeps its UTC date label, renames "Daily visitors" to
  "Visitor-days," and renders the diagnostics in the first server response.
- No schema, migration, cache, rollup, background process, collector behavior,
  dependency, network request, fingerprint, or runtime data file is added.

### Consequences

- A future site-local Overview migration cannot change only one of the two
  headline ranges. It must migrate visitor-days and distinct people together.
- D32's schema-5 traffic class replaces the device-bot predicate while
  preserving visible diagnostic accounting and versioning the new meaning.
- Rollback removes the additive report, renderer, and documentation only. No
  database restore or compatibility fallback is required.

**Affected contracts:** `BOT_DETECTION_1.0.md`, `METRIC_SEMANTICS_V2.md`,
`DATA_MODEL.md`, and `ANALYSIS_QUERY.md`.

### Acceptance evidence

Issue #66 must prove exact traffic-quality table/JSON/CSV output through the
real CLI and on-disk Turso/DuckDB files, canonical-person collapse, identity
coverage, zero days, zero-engagement observation, identity mint dates, current
bot accounting, unchanged metric-v1 output, server-rendered dashboard behavior,
and Debug/ReleaseSafe execution.

## D31. Store explicit self-exclusion and close non-bot inflation leaks

**Status:** Accepted for Analytico 1.0 issue #67

**Date:** 2026-08-23

**Issues:** #67 and #68

### Context

Three independent behaviors inflate product traffic: speculative prerenders
send a page view before activation, storage-unavailable pages mint a new
anonymous UUID for every load and therefore a new compatibility visitor-day,
and the operator cannot distinguish their own visits. The traffic-quality plan
requires store-and-classify: an observed self-excluded event must not disappear
merely because permanent `traffic_class` arrives in the following issue.

The dashboard and measured site commonly have different origins, so the
dashboard cannot directly write the site's localStorage. Network exclusions
must use only transient trusted-proxy IP input, apply without restart, and
never persist an observed raw IP or hash.

### Stored-classification candidates

| Candidate | Advantages | Costs and risks |
| --- | --- | --- |
| Drop self-excluded requests with a process counter | No event migration | Violates store-and-classify; history and diagnostics cannot inspect the events |
| Reserve a value in `language`, `device_category`, or `properties_json` | Avoids a schema migration | Corrupts an unrelated semantic field and can lose the original device or property value |
| Add a companion exclusion table | Preserves event columns and reasons | Adds a second event relation, join, lifecycle, and consistency surface for one short transition |
| Add one closed `exclusion_source` byte to each event | Direct, queryable, lossless reason bits; one predicate in product queries | Advances event schema 4, so #68's permanent classifier becomes schema 5 |

Select the one-byte field. Values are 0 none, 1 tracker self-flag, 2 configured
network prefix, and 3 both. Migration 4 transactionally preserves every
schema-3 field, stamps schema 4, initializes existing rows to zero, and proves
the mapping before swap with bounded row-count and aggregate fingerprints over
all preserved fields. All received events are inserted. Product queries
require zero, while traffic-quality diagnostics report stored excluded events
by source. #68 maps every nonzero value to `traffic_class=excluded`, preserves
the matched exclusion reason in its versioned rule identifier, then removes the
temporary field in event schema 5.

The classification belongs to the first committed event. Protocol-v2's
canonical digest adds a component for a true client self-flag; absent and false
retain the pre-D31 digest so ordinary retries remain compatible across the
upgrade, while changing an existing event to true conflicts. A duplicate replay
from a different network does not mutate the already committed row or its
receipt-context classification.

### Tracker-control candidates

| Candidate | Advantages | Costs and risks |
| --- | --- | --- |
| Dashboard writes localStorage directly | Minimal code | Impossible across origins under browser same-origin policy |
| A fragment alone sets the durable flag | No dashboard script change | Anyone who copies the public site UUID could durably exclude another browser |
| Site-bound fragment plus origin-checked opener handshake | No request or secret; runs in the site's first-party context | One small dashboard/tracker message island; self-exclusion intrinsically requires JavaScript |

Select the handshake. The exact control fragment marks that page's envelope as
self-excluded immediately. Because localStorage is origin-scoped, the dashboard
exposes the same bounded control for every configured measured origin rather
than inventing a primary-origin order. A durable set/clear is accepted only
through `postMessage` from the tracker asset's collector/dashboard origin and
the opening window, then the fragment is stripped. Ordinary native dashboard
navigation and forms remain the baseline; this narrow control is JavaScript
because localStorage itself is a browser API.

### Recommendation

- The current tracker returns before identity or network activity on localhost
  and defers initial page-view/not-found behavior until a prerender activates.
  A document never activated produces no visit because it was never observed.
- The tracker stores `anl:<site>:x`. Flagged events still send with bounded
  `self_excluded:true`; no fingerprint or configuration fetch is added.
- Storage-unavailable v2 rows retain their random page-lifetime anonymous and
  session IDs, but their metric-v1 compatibility visitor-day uses the existing
  keyed site/date/network-prefix/coarse-client derivation.
- Metadata migration 4 stores at most 16 canonical IPv4 `/24` or IPv6 `/48`
  rows per site. The collector combines the tracker and network bits after
  exact site/origin validation and before insertion. Raw IP is transient.
- Excluded rows never consume the visitor-day or session-start boundary needed
  by a later eligible row. Product base relations filter exclusion before
  visitor, session, identity, property, goal, funnel, and analysis semantics.
  An excluded identify row remains stored but does not create an identity link;
  a later eligible row therefore cannot inherit product identity from it.
- Authenticated add/delete forms use POST/303/GET, CSRF, exact dashboard Origin,
  and an immediate bounded site-policy refresh. There is no runtime network
  call, CIDR data file, background process, or arbitrary range engine.

### Consequences

- Metric-v1 report bytes change only where stored self-excluded rows are
  deliberately omitted. Existing nonexcluded rows and semantics remain exact.
- Traffic-quality diagnostics advance to version 2 and retain exclusion counts
  even though product reports omit those rows.
- Event and metadata schema 4 require a verified pre-migration pair for
  rollback. Deployment stops the sole writer, backs up, migrates, verifies, and
  starts one exact release artifact.
- #68 is renumbered to event schema 5 and must consume every temporary marker
  before dropping `exclusion_source`. #69 retains the no-fingerprinting and
  no-runtime-network boundaries.

**Affected contracts:** `BOT_DETECTION_1.0.md`, `METRIC_SEMANTICS_V2.md`,
`PROTOCOL.md`, `ARCHITECTURE.md`, `DATA_MODEL.md`, and `OPERATIONS.md`.

### Acceptance evidence

Issue #67 must prove real Chromium prerender activation/non-activation,
localhost silence, two storage-blocked page loads collapsing to one
visitor-day, dashboard-to-site flag set/clear, stored-but-product-excluded
flagged traffic, configured network and combined source rows, immediate policy
refresh, raw-IP absence, exact schema-3 upgrade preservation, backup/rollback,
and Debug/ReleaseSafe gates through the real executable and on-disk stores.

## D32. Store permanent traffic class and run one legacy shadow release

**Status:** Accepted for Analytico 1.0 issue #68

**Date:** 2026-08-23

**Issues:** #68 and #69

### Context

The shipped six-substring, case-sensitive User-Agent classifier overloads
`device_category=bot`. It misses common HTTP clients, headless browsers,
case variants, and tokenless named crawlers, while strings such as `Cubot` can
false-positive. Raw User-Agent strings are deliberately discarded, so old
source-zero rows cannot be honestly reclassified. Event schema 4 also carries
D31's deliberately temporary `exclusion_source`; #68 must consume every marker
without losing an observed event.

The corrected classifier needs measurable disagreement evidence before its
expanded bot verdict changes product metrics. That requirement does not
authorize storing raw User-Agents, loading an unbounded runtime rules file, or
calling a classification service.

### Rule-source candidates

| Candidate | Advantages | Costs and risks |
| --- | --- | --- |
| Fetch or load the complete upstream regular-expression corpus at runtime | Broad and readily updated | Adds network/file availability, regex/dependency, privacy, and unbounded-rule work to collection |
| Keep the current six substrings | No migration or new rule table | Known false positives and false negatives remain; device and traffic semantics stay conflated |
| Vendor a small reviewed table derived from one pinned upstream revision plus explicit client/headless rules | Deterministic, auditable, bounded, dependency-free, and fixtureable | Updates require an intentional source review and classifier-version change |

Select the small compiled table. `docs/UA_CLASSIFIER_V1.md` records the source
commit, content hash, license, reviewed rule families, match modes, bounds, and
fixtures. Matching is ASCII case-insensitive. Named crawler, monitor, and
headless discriminants require token boundaries; only narrow slash-bearing
HTTP-client markers use explicit prefix or substring modes. There is no regex
engine, allocation, runtime file, runtime network call, fingerprint, or raw-UA
persistence. Empty UA is a declared bot. Device, browser, and operating-system
parsing remains an independent coarse dimension operation.

### Schema and historical mapping

Event schema 5 replaces `exclusion_source` with:

- `traffic_class` (`1 human-presumed`, `2 declared-bot`, `3 automation`,
  `4 excluded`, `5 suspected`);
- `classifier_version` (`0` honest legacy/unknown source, `1` UA classifier
  v1 or D31 exclusion mapping); and
- `bot_rule`, an ASCII rule identifier no longer than 64 bytes.

For exactly the #68 comparison release it also stores
`legacy_bot_verdict BOOLEAN`. New nonexcluded rows record the permanent
classification and the exact old six-substring verdict from the same bounded
request header. Exclusion takes precedence, stores the applicable exclusion
rule, and canonicalizes the legacy boolean to false so the row sits wholly
outside UA shadow evidence.
`traffic_class` and the first receipt's rule/version are immutable on an
idempotent replay; the UA and network receipt context are not added to the
payload digest.

Migration 5 maps all rows transactionally:

| Schema-4 row | Schema-5 traffic fields | Preserved-field exception |
| --- | --- | --- |
| `exclusion_source=1` | excluded, v1, `exclude.tracker`, legacy false | old device `bot` becomes `unknown`; otherwise none |
| `exclusion_source=2` | excluded, v1, `exclude.network`, legacy false | old device `bot` becomes `unknown`; otherwise none |
| `exclusion_source=3` | excluded, v1, `exclude.both`, legacy false | old device `bot` becomes `unknown`; otherwise none |
| source zero and `device_category=bot` | declared-bot, v0, `legacy-device-bot`, legacy true | device becomes `unknown` |
| every other source-zero row | human-presumed, v0, empty rule, legacy false | none |

The device rewrite applies to every old `device_category=bot` row regardless
of exclusion because the discarded UA cannot reconstruct its actual device.
It is the only permitted preserved-field difference and removes the old
category from the pure device dimension. The streaming
verifier proves row count plus XOR, sum, minimum, and maximum fingerprints over
every other field, the complete mapping above, identity-link preservation, and
the absence of `exclusion_source` before swap. Interrupted and repeated
migrations remain safe. Rollback requires the verified pre-schema-5 database
pair and the prior binary.

### One-release compatibility shadow

Issue #68 stores and exposes the permanent verdict immediately but deliberately
keeps the product predicate compatible for one deployed release:

```text
traffic_class != excluded AND legacy_bot_verdict = false
```

Thus migrated and newly observed self-excluded events remain diagnostic-only,
and traffic rejected by the old classifier remains outside product metrics.
Classifier-only disagreements remain product-compatible until the measured
promotion decision in #69. Excluded rows take precedence over UA classes and
do not participate in UA disagreement cells.

Traffic-quality diagnostics advance to version 3. In the same bounded
statement and deadline they report the five stored class totals, classifier-v1
coverage, bounded class/version/rule totals, and four nonexcluded v1 shadow
cells: both human, legacy only, classifier only, and both bot. The existing
identity/exclusion observations remain visible. At most 64 grouped rule rows
are returned; no raw UA can appear in any output.

The serving process also keeps fixed-cardinality, restart-scoped counters for
newly inserted nonexcluded rows: `legacy_bot_positive`,
`classifier_bot_positive`, `shadow_both_human`, `shadow_legacy_only`,
`shadow_classifier_only`, and `shadow_both_bot`. They are emitted only in
`serve_stopped`, contain no UA or rule strings, and complement rather than
replace the durable date-range diagnostics. Existing `bots` retains its legacy
request-attempt meaning for operational compatibility. Duplicate, conflicting,
rejected, failed, and excluded rows do not enter the six new shadow counters.

Excluded and legacy-bot rows do not consume visitor-day or session-start
boundaries and cannot create identity links. Classifier-only rows retain the
compatibility behavior during the shadow release. #69 may remove
`legacy_bot_verdict` and promote product eligibility to
`traffic_class IN (human-presumed, suspected)` only after reviewing deployed
#68 diagnostics and recording that disposition. The positive-human-evidence
veto remains mandatory for later soft-signal work.

### Consequences

- Every otherwise accepted event is stored. There is no per-site drop mode or
  self-opt-out collection suppression.
- The source corpus is attributed and licensed but is not shipped as a runtime
  data file. Updates require a new classifier version and fixtures.
- Metadata remains schema 4; #68 adds no site setting, tracker change, Caddy
  change, dependency, process, or background task.
- A schema-5 binary refuses an older event store until explicit migration;
  an older binary requires matched-store restore for rollback.

**Affected contracts:** `UA_CLASSIFIER_V1.md`, `BOT_DETECTION_1.0.md`,
`METRIC_SEMANTICS_V2.md`, `ANALYSIS_QUERY.md`, `PROTOCOL.md`,
`ARCHITECTURE.md`, `DATA_MODEL.md`, `OPERATIONS.md`, `PERFORMANCE.md`, and
`RELEASE_CONTRACT_1.0.md`.

### Acceptance evidence

Issue #68 must prove the bounded rule corpus (including case variants, empty
UA, and false-positive traps), real loopback collection into on-disk schema 5,
stored rule/version/class fields, no raw-UA persistence, compatibility product
filtering, diagnostics and bounded `serve_stopped` disagreement output, exact schema-4 migration,
million-row/interrupted/repeated upgrade, backup/restore/rollback, unchanged
eligible metric-v1 results, extracted-release execution, and Debug plus
ReleaseSafe gates.

## D33. Store bounded browser and receipt evidence and end the UA shadow

**Status:** Accepted for Analytico 1.0 issue #69

**Date:** 2026-08-23

**Issues:** #69 and #70

### Context and deployed shadow disposition

UA rules cannot identify a browser that exposes an ordinary UA while running
under automation. Issue #69 adds only coarse evidence needed by the later
reversible #70 heuristics and the two hard observations approved in the bot
plan. The evidence must not become a fingerprint, raw client-hint store, or a
second application state model.

Issue #68 completed one production release of the D32 shadow. At the #69 start,
production contained one classifier-v1 `both-human` event and zero disagreement
events. That sparse POC sample is not a statistical precision measurement. It
does establish that the deployed diagnostic path works; deterministic rule,
migration, HTTP, and browser fixtures remain the governing classifier evidence.
D32 deliberately authorized #69 to end the shadow after that deployed review.
The permanent traffic class is therefore promoted now, without claiming that
later soft heuristics have been validated.

### Storage candidates

| Candidate | Advantages | Costs and risks |
| --- | --- | --- |
| Encode evidence in event properties | No schema migration | Collides with user-owned property semantics and weakens closed bounds |
| Add first-class fields but keep the D32 legacy boolean and predicate | Smaller immediate query diff | Contradicts the one-release boundary, keeps duplicate classifier work/counters, and forces another migration |
| Add one schema-6 evidence boundary and remove the completed shadow | Closed, honest, queryable, and leaves #70 reversible | Requires an exact schema-5 migration and deliberate product-predicate change |

Select schema 6. Metadata remains schema 4. There is no session table, mutable
signal upsert, dependency, background job, setting, or additional process.

### Protocol and stored evidence

Protocol v2 accepts one optional `signals` object. Version 1 contains:

- `webdriver`, the exact boolean observation of `navigator.webdriver`;
- `trusted_interactions`, a four-bit mask for trusted pointer move, key down,
  scroll, and touch start observations accumulated before this beacon;
- `was_visible` and `was_prerendered` page-lifetime latches;
- `viewport_bucket` (`0 unknown`, `1 under 480`, `2 480–767`,
  `3 768–1199`, `4 at least 1200` CSS pixels); and
- `beacon_timing_bucket` (`0 unknown`, `1 under 100 ms`, `2 under 1 s`,
  `3 under 5 s`, `4 at least 5 s` after navigation start).

The bundle is closed and bounded. An absent bundle stores `signal_version=0`
and zeros/false values; it is unknown evidence, not a negative observation.
The current tracker sends version 1. Its mask is page-lifetime state; #70 may
aggregate later events over a session, but #69 performs no session mutation.
Client-carried evidence is not authenticated and a custom sender can omit or
forge it. It may protect a session from future soft suspicion but never proves
a human, identity, authorization, or entitlement; deterministic hard evidence
only classifies the sending observation itself.
An absent bundle preserves the pre-D33 payload digest. When present, every
bundle field enters the digest, so a changed payload conflicts. Receipt-derived
fields do not enter the digest and the first committed receipt remains
immutable.

The collector derives two additional closed values without retaining their
inputs:

- `client_hint_consistency`: `0 unknown historical`, `1 consistent or not
  applicable`, `2 mismatch`, `3 absent when a Chromium-family UA expects the
  low-entropy hint`; and
- `accept_language_present`, true only when a nonempty header was received.

`Sec-CH-UA` work is limited to 512 bytes. A longer or structurally contradictory
value is mismatch. Matching checks only the bounded Chromium, Chrome, Edge,
and HeadlessChrome brands needed for consistency. Raw hint values,
`Accept-Language`, viewport dimensions, precise timing, normalized copies, and
hashes are never persisted or logged. There is no canvas, WebGL, audio,
battery, precise timezone/geo, runtime file, or classifier network access.

### Classifier v2 and product predicate

All new nonexcluded receipts record classifier version 2. A specific UA-v1
declared-bot or automation rule remains authoritative and keeps its rule ID.
Otherwise `webdriver=true` produces automation rule `signal.webdriver`; then a
client-hint mismatch produces automation rule `signal.client-hint-mismatch`.
An absent-when-expected hint, missing language, viewport/timing bucket,
visibility, and lack of interaction do not classify in #69. Exclusion still
takes precedence and retains its version-1 exclusion rule.

Hard observations are not overridden by interaction. The positive-human-
evidence veto applies to future soft classification only. Issue #70 must keep
soft combination query-time, visible, reversible, and vetoed by trusted
interaction, engagement, scroll, return, or conversion evidence.

Schema 6 removes `legacy_bot_verdict`. Product eligibility becomes exactly:

```text
traffic_class IN (human-presumed, suspected)
```

This intentionally excludes UA-v1/v2 declared bots and automation and includes
corrected human-presumed rows that the old six-substring predicate had rejected.
`serve_stopped.bots` becomes the permanent declared-bot/automation request-
attempt counter; the six D32 shadow counters are removed.

Traffic-quality diagnostics advance to version 4. They retain identity,
exclusion, permanent class, classifier version/rule, and daily permanent bot
totals; remove legacy comparison fields; and add fixed counts for client-signal
v1 coverage, webdriver, any trusted interaction, visible, prerendered,
client-hint mismatch/absent-expected, and Accept-Language presence. No result
key or group is input-derived; class/version/rule groups remain capped at 64.

### Migration, tracker cutover, and rollback

Migration 6 transactionally preserves every schema-5 row, identity link,
traffic class, classifier version, rule, and unrelated-field fingerprint. It
adds unknown/zero evidence and removes only `legacy_bot_verdict`. Historical
headers and browser state are never reconstructed. The verifier proves row
count plus XOR, sum, minimum, and maximum fingerprints, the complete zero-state
mapping, link preservation, and absence of the shadow column before swap.

The current tracker receives a new content hash. The `6de111c9` asset remains
embedded and immutable for installed sites; `/tracker.js`, installation output,
and the new hash select the current tracker. Caddy adds the new public path
without removing an old one. Raw tracker size remains at most 8 KiB and Brotli
at most 5 KiB.

Deployment stops the sole writer, creates and independently restores a matched
schema-5 backup with the exact prior binary, migrates, verifies the deliberate
predicate disposition and real browser/HTTP evidence, then switches one exact
release. Rollback restores that matched pair before starting the prior binary;
switching only the executable is forbidden.

**Affected contracts:** `BOT_DETECTION_1.0.md`, `UA_CLASSIFIER_V1.md`,
`PROTOCOL.md`, `DATA_MODEL.md`, `METRIC_SEMANTICS_V2.md`,
`ANALYSIS_QUERY.md`, `ARCHITECTURE.md`, `OPERATIONS.md`, `PERFORMANCE.md`,
`SPEC.md`, and `RELEASE_CONTRACT_1.0.md`.

### Acceptance evidence

Issue #69 must prove closed payload presence/absence/bounds and digest behavior,
bounded receipt-header consistency, hard-rule precedence, real Chromium
webdriver and trusted-interaction facts, genuine prerender/visibility evidence,
stored schema-6 fields without raw inputs, permanent product filtering and
diagnostics, exact schema-5 million-row interrupted/repeated migration,
backup/restore/rollback, immutable old/new tracker paths, collection/report
budgets, extracted-release execution, and Debug plus ReleaseSafe gates.

## D34 — Query-time suspected traffic, explicit site safeguards, and keyed daily network evidence

**Status:** Accepted

**Date:** 2026-08-23

**Issue:** #70

### Context

D33 deliberately stored only closed evidence and left soft classification to a
later reversible query. The deployed schema-6 sample proves the diagnostic
path but is too small to justify default filtering. Issue #70 also requires a
per-site accepted-event ceiling and a network-prefix identity-mint warning.
Schema 6 cannot group a prefix without either retaining raw network data or
adding one privacy-bounded receipt fact.

D32 rejected a per-site drop mode. This decision supersedes that sentence only
for the explicit operational ceiling below. It does not authorize bot drops,
self-opt-out suppression, a silent success response, deletion, or arbitrary
collection policy.

### Mechanism candidates

| Candidate | Advantages | Costs and risks |
| --- | --- | --- |
| Persist `traffic_class=suspected` and later correct rows | Simple report predicate | Stale/mutable classification, rewrites history, and contradicts query-time reversibility |
| Keep scoring and prefix counts only in process memory | No migrations | Restart/date-range evidence is dishonest and strict results cannot be reproduced |
| Compute a versioned query relation; persist only keyed daily prefix evidence and small site policy | Reversible verdicts, durable bounded diagnostics, explicit operator control | Requires metadata 5, event schema 7, goal snapshots, and exact pair migration evidence |

Select the third candidate. There is no new process, worker, queue, service,
runtime corpus, configuration fetch, cache table, or rollup.

### Query classifier version 1

Stored event class/version/rule remain immutable first-receipt evidence. The
query classifier derives a separate session-level low-quality band. Its raw
candidate is the earliest product-compatible meaningful event in a session and
requires all of:

- stored class `human-presumed` and `signal_version=1`;
- no trusted-interaction bit, engagement, or scroll evidence on that event; and
- at least two soft observations: beacon timing under 100 ms, viewport under
  480 CSS pixels, never visible, Chromium client hint absent when expected, or
  Accept-Language absent.

Prerendering is never negative evidence. Missing historical bundles,
`signal_version=0`, unknown buckets, and one soft observation cannot trigger.
UA, webdriver, and client-hint mismatch remain hard stored classifications and
are never cleared by positive evidence.

A raw candidate is currently suspected only while the complete stored session
has exactly one meaningful page-view/custom event and no trusted interaction,
engagement, scroll, second page view, active-goal conversion, or persistent
person observed in another session. The application loads at most 32 active
goal selectors from Turso and binds their closed event/path/prefix values into
DuckDB; neither database reaches into the other. A pre-existing site with more
than 32 goals retains every goal, reports heuristic unavailability, and cannot
enable strict mode. New goal creation stops at 32.

The candidate cohort remains diagnostic after a later veto. A contradicted
candidate is one that now has later/more meaningful activity, interaction,
engagement, scroll, an active-goal match, or a persistent return. The standing
contradiction rate is contradicted candidates divided by raw candidates. This
measures false-positive pressure without freezing a verdict that human evidence
has already cleared.

### Strict mode and product predicates

Metadata schema 5 adds one `site_traffic_policy` row per site with:

- `strict_mode`, default false; and
- `daily_event_ceiling`, default 100,000 and explicitly bounded from 1 through
  10,000,000.

No migration or diagnostic automatically enables strict mode. Default-off
queries retain D33 eligibility and include the derived suspected band. Strict
mode excludes only currently suspected sessions in addition to stored
declared-bot, automation, and exclusion classes. It never changes stored rows,
exports, diagnostic class totals, or backups.

Strict visitor-day and session totals derive distinct eligible daily identity
and session facts from the query relation. They do not count only persisted
`visitor_day_start` or `session_start` flags: a candidate first row may have
consumed a boundary before later human activity cleared or replaced its
eligibility. Goal, funnel, list, Overview, and metric-v2 queries use the same
versioned relation and goal snapshot.

### Keyed network-day evidence and anomaly threshold

Event schema 7 adds a 16-byte `network_day_id`. For new collection receipts it
is the first 16 bytes of keyed BLAKE3 over a domain-separated key, site ID,
receipt UTC date, and normalized IPv4 /24 or IPv6 /48. The master key remains
the existing private visitor key. The value cannot link sites or UTC dates.
Raw prefixes, the existing unkeyed rate-limit hash, network-day bytes, and
input-derived group keys are never logged, rendered, or exported.

Schema-6 history maps to sixteen zero bytes, meaning unknown. It is not
reconstructed. Traffic-quality ignores unknown values and reports only fixed
counts: daily prefixes over the threshold and the maximum fresh identities for
one prefix. More than 64 first-seen persistent/ephemeral anonymous identities
for one site/receipt-UTC-day prefix is an anomaly warning. It does not classify
or filter any event.

### Daily accepted-event ceiling

The ceiling counts every durably stored event for the receipt-derived
site-local date, including bots and explicit exclusions. Duplicate v2 IDs that
already committed retain their idempotent result. Before a new identity link
or event is committed, the single DuckDB writer checks the count inside the
transaction. At the configured count, a new event is rejected with HTTP 429,
increments one fixed `daily_ceiling_rejected` process counter, and never
returns a false 204. No row below the cap is discarded or deleted.

Traffic-quality version 5 and Overview report the configured cap, accepted
rows, reached days, and a visible data-health warning. This is an explicit
operator safety bound, not a bot verdict. The existing per-prefix rate limiter
remains independent.

### Migrations, failure behavior, and rollback

Metadata migration 5 backfills every existing site with strict off and the
100,000 default and makes new-site creation populate the same row. Event
migration 7 transactionally preserves every schema-6 event and identity link,
adds only the zero/unknown network-day value, and verifies count plus XOR, sum,
minimum, and maximum fingerprints before swap.

Collection fails closed if traffic policy is absent/invalid. A ceiling check or
event write failure never creates an orphan identity link. A goal overflow
fails human-safe by producing no suspected classification and refusing strict
enablement while keeping diagnostics explicit. Query deadlines and all
existing input/result bounds remain.

Deployment stops the sole writer, backs up and independently restores the
metadata-4/event-6 pair, and proves the exact prior binary can open the restored
pair and reproduce pre-migration reports. Rollback restores that matched pair
before starting the prior binary; switching only the executable is forbidden.
No tracker or Caddy path changes in this decision.

**Affected contracts:** `BOT_DETECTION_1.0.md`, `PROTOCOL.md`,
`DATA_MODEL.md`, `METRIC_SEMANTICS_V2.md`, `ANALYSIS_QUERY.md`,
`ARCHITECTURE.md`, `OPERATIONS.md`, `PERFORMANCE.md`, `SPEC.md`, and
`RELEASE_CONTRACT_1.0.md`.

### Acceptance evidence

Issue #70 must prove candidate/one-soft/history traps; every veto; hard-rule
precedence; contradiction and declared-bot shadow evidence; exact strict-off
parity and strict-on scope; distinct boundary repair; keyed prefix site/day
separation and non-disclosure; >64 mint warning; exact ceiling, duplicate, 429,
counter, and Overview warning behavior; authenticated native settings; fresh
and exact metadata-4/event-6 million-row migration, interruption/retry,
backup/restore/pair rollback; real headless/human journeys; performance budgets;
extracted-release execution; and Debug plus ReleaseSafe gates.

## D35. Permit one exact mutation-invalidated Overview-result cache

**Status:** Accepted for Analytico 1.0 issue #27

**Date:** 2026-08-23

**Issue:** #27

**Supersedes:** D29 only where D29 prohibited a cache for the fixed complete
metric-v2 Overview consumer. D29's closed query model, finite compiler,
and prohibition on a generic report cache remain authoritative.

### Context

D29 deliberately introduced metric-v2 without a cache, projection, rollup,
table, worker, service, migration, or dependency. Issue #27 adds a fixed
Overview consumer whose KPI and details statements must share one request
deadline and meet the million-row complete-path budgets: normal p95 below
250 ms and optional strict p95 at or below 500 ms.

The first wide details plan exhausted the locked 128 MiB DuckDB limit. After
narrowing the exact SQL, the uncached complete path still measured
769/842/842 ms in normal mode and 1,071/1,274/1,274 ms in strict mode at
p50/p95/p99. Materializing the narrowed range worsened normal p95 to 1,701 ms.
These are cold failures and remain recorded as such; a cached sample must never
be described as cold-query performance.

Caching only the bounded details statement initially measured normal
221/249/249 ms and strict 344/367/367 ms, but a fresh independent normal run
reached 261 ms and failed the unchanged below-250-ms gate. Further narrowing
and materialization of the KPI inputs remained noise-sensitive, including a
fresh 262 ms normal p95. Those candidates are rejected evidence, not accepted
headroom.

### Candidates

| Candidate | Runtime and correctness | Maintenance, migration, and rollback |
| --- | --- | --- |
| Keep the exact cold SQL only | Smallest state model and always current, but fails both accepted complete-path p95 budgets on the million-row fixture | No invalidation work; no migration; rollback is unnecessary, but the issue cannot meet its performance contract |
| Retain only one exact Overview-details result in the writable event Store | Avoids the measured details scan but leaves the KPI statement on every read; one fresh normal p95 reached 261 ms | Same arena, key, clone, and invalidation obligations as the complete-result entry without stable accepted headroom |
| Retain one exact complete Overview result in the writable event Store | Exact repeated reads avoid both measured statements; synchronous mutation invalidation and a full semantic key prevent stale cross-context reuse | One bounded arena, key builder, deep clone, and mutation hooks; no schema or deployment component; rollback deletes the cache fields and hooks, returning to the measured cold behavior |
| Add a projection or rollup | Can make cold reads consistently fast and avoid dependence on cache locality | Introduces stored derived semantics, forward migration, write/update rules, verification and restore work, and a larger rollback surface before one screen proves that cost necessary |

### Recommendation

Select the exact one-entry cache before a projection or rollup:

- The Store owns at most one entry. Its length-prefixed key contains the site,
  current and comparison dates, strict policy, configured daily ceiling, full
  ordered active-goal snapshot including every selector predicate's property,
  scalar type, operator, value count, and values, selected metric and currency,
  interval, and every current/comparison bucket label. It therefore cannot answer a
  different site, policy, goal, metric, currency, calendar, or timezone-derived
  bucket context.
- The entry contains only the already bounded complete typed Overview result:
  fixed KPI and completeness fields, at most 16 exact-currency totals, at most
  400 current and 400 comparison buckets, five rows in each of four panels,
  and one health row. It lives in one dedicated process-memory arena;
  replacement or invalidation releases the whole arena. A hit deep-copies the
  complete result into the request allocator, so rendering cannot mutate or
  outlive it.
- Every successful event insert, rebucket, deletion, and migration destroys
  the entry synchronously. Goal, strict-policy, and daily-ceiling changes alter
  the complete key. Duplicate/no-op event
  writes do not invalidate because they do not change report facts.
- A miss executes the exact KPI and details statements sequentially under the
  existing deadline and stores their combined typed result. There is no TTL,
  stale fallback, background refresh, durable cache table, separate KPI cache,
  generic analysis cache, extra thread, dependency, network path, or log of
  cached report data.

The million-row gate intentionally measures ten repeated complete Store calls
after one explicit cold warmup per traffic policy. That workload represents a
private POC owner reloading the same canonical Overview while the underlying
file is stable; it is the accepted warm-read budget, not a claim that a metric
switch or a read following an accepted event is warm. Event ingestion and
metric switches can cause a cold miss. The recorded 0.772-second combined cold
profile from the rejected details-only candidate remains honest evidence for
that case under the two-second request deadline.

The first three complete-result stability runs preceded the final YAGNI
cleanup. They measured normal p95 at 12, 8, and 8 microseconds, strict p95 at
8, 8, and 9 microseconds, and cold profiles at 0.818, 0.728, and 0.858 seconds.
The fourth independent run used the exact post-YAGNI source under PR review. It
measured normal p95 at 29 microseconds, strict p95 at 8 microseconds, and the
cold profile at 0.814 seconds. If real operation shows that invalidations make
cold misses the normal user path or that the deadline becomes unacceptable,
the cache is not to be widened: a new decision must reconsider a
projection/rollup with measured production evidence.

### Consequences

- Runtime memory is bounded to one exact typed result plus the one
  request-lifetime clone in this sequential serving architecture. There is no
  unbounded key population or eviction policy.
- Maintenance is localized to the Store cache type, exact key construction,
  typed cloning, and the existing event-mutation boundaries. New event mutation
  paths must invalidate before they can be accepted.
- Security and privacy do not gain a new data source or trust boundary. The
  cache holds only the bounded resolved input key, including any selector
  predicate values, and authenticated report output already available to the
  process. It never persists or logs either, includes the site in its exact
  key, and never adds raw network, user-agent, or request-payload data.
- No database migration, backup change, deployment component, or rollback data
  step is required. Code rollback removes the cache and resumes the correct but
  slower cold SQL path.
- D29 remains unchanged for user-authored Analysis queries and every other
  report. Issue #28 receives no permission to generalize or multiply the cache
  without a new measured decision.

**Affected contracts:** `ANALYSIS_QUERY.md`, `ARCHITECTURE.md`,
`PERFORMANCE.md`, and `RELEASE_CONTRACT_1.0.md`.

### Acceptance evidence

Issue #27 must preserve the rejected cold/OOM and details-only-cache
observations, label cold and warm evidence separately, prove exact-key
separation including semantically different selector predicates and accepted-mutation
invalidation on the real on-disk Store, retain the cold profile under the
existing deadline, meet the normal and strict warm-read budgets, and pass
Debug plus ReleaseSafe real-browser and report-parity gates. Any later cache
expansion is out of scope.

## D36. Browser site creation and metadata schema 6

**Status:** Accepted for Analytico 1.0 issue #19

**Date:** 2026-08-23

**Issue:** #19

**Preserves:** D19. No explicit multi-write Turso transaction is introduced or
implied by this decision.

### Context

The authenticated no-site dashboard currently tells the owner to use the CLI
and restart the service. The 1.0 onboarding contract instead requires a native
browser form for name, slug, primary origin, timezone, and optional default
currency, followed by an in-process collection-policy refresh and an Install
destination. Metadata schema 5 has no durable default-currency field and does
not prevent one exact origin from belonging to several sites.

The planning package says creation occurs in one Turso transaction. That
wording is lower authority than D19. On the exact pinned Turso Database
`0.8.0-pre.2` and owner filesystem, explicit multi-write transactions produced
the measured false `pwrite: quota exceeded` failure while the same autocommit
writes succeeded. This decision corrects the mechanism without weakening the
user-visible all-or-cleanly-reported outcome.

### Write-mechanism candidates

| Candidate | Runtime and failure behavior | Maintenance and rollback |
| --- | --- | --- |
| Re-test and use an explicit multi-write transaction | Ideal atomicity if the measured engine/filesystem behavior changed | The pin and environment evidence have not changed; superseding D19 would require a new successful real-store result and a different rollback contract |
| Preserve D19 durable autocommits plus synchronous parent compensation | Uses the shipped engine, makes each successful row durable, and deletes a newly inserted parent after a returned child-write error | A process crash can expose incomplete configuration until `doctor` or exact retry repairs it; the code must never swallow a failed compensation |
| Add an operation log, idempotency table, or generic saga | Could identify every interrupted attempt | Adds durable states, cleanup policy, and abstractions for one sequential private-owner form without a second consumer |

Select D19 durable autocommits with synchronous compensation. Insert the site
parent first, then its required origin, timezone, settings, and traffic-policy
children. If a child returns an error for a newly inserted parent, issue one
explicit cascading parent delete. If that delete also fails, return a distinct
compensation failure so `doctor` can report the incomplete site. This sequence
is not called a transaction.

### Settings-shape candidates

| Candidate | Data semantics | Migration and extension cost |
| --- | --- | --- |
| Keep currency only in the submitted form or infer EUR | No migration | Loses explicit owner configuration and can silently mislabel later revenue |
| Add nullable/default columns directly to `sites` | Direct lookup | Couples unrelated settings to the identity row and makes future bounded settings alter the core table repeatedly |
| Add one `site_settings` row per site with only `default_currency` | Explicit one-to-one ownership and honest empty value | One small forward migration and one required child lookup |

Select the one-to-one table. Metadata schema 6 adds:

```sql
CREATE TABLE site_settings (
    site_id TEXT PRIMARY KEY,
    default_currency TEXT NOT NULL,
    FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
    CHECK (default_currency = '' OR (
        length(default_currency) = 3 AND
        default_currency NOT GLOB '*[^A-Z]*'
    ))
);
CREATE UNIQUE INDEX site_origins_unique_origin ON site_origins(origin);
```

Existing sites receive the empty currency because no earlier fact proves an
EUR or other preference. New browser-created sites store either empty or
exactly three uppercase ASCII bytes. No settings revision, tracking-options
bitset, background task, cache, dependency, or second configuration model is
added by #19.

### Idempotency, validation, and refresh

The server validates every field before metadata writes. HTTPS is required
except for explicit loopback HTTP development origins, and the selected IANA
timezone must load through the configured bounded TZif reader. A blank slug is
derived deterministically from the trimmed display name; the editable value
uses the existing slug grammar.

The single sequential owner process resolves an exact completed resubmission
by comparing the stored name, slug, origin, timezone, and currency and resolves
the existing site outcome. A missing child with no conflicting stored value may
be filled by the same input after a process interruption. A differing slug
owner, origin owner, name, timezone, or currency is a field conflict and is
never overwritten as an idempotent retry. The unique slug and origin
constraints are the durable final guard; no request token becomes persistent
state.

Only after the durable site outcome does the serving process rebuild and swap
its bounded in-memory collection-policy snapshot. A refresh failure returns an
honest recoverable error that says the site exists. Repeating the same form
resolves that stored outcome before another refresh attempt and never inserts
a second site. The renderer receives typed drafts, field errors, and stored
configuration; it performs no database, clock, filesystem, or network work.

### Migration, security, and rollback

Metadata migration 6 uses D19 replayable autocommits: create the table, backfill
one empty settings row per site with conflict-safe insertion, create the unique
origin index, and write the migration ledger row last. A predecessor containing
cross-site duplicate origins fails before the v6 ledger rather than assigning
ownership silently. Re-running after correction is safe.

The migration requires the normal verified pair backup. Acceptance uses the
exact deployed metadata-5/event-7 predecessor, proves an independent restore
with its old binary, preserves every site/origin/timezone/policy row, repeats
the candidate migration, and proves rollback by restoring the matched pair for
the old binary. No DuckDB schema or event fact changes.

Creation remains behind the existing passkey session, exact dashboard Origin
check, CSRF token, bounded form parser, and context-safe renderer. Site IDs are
public random UUIDs, not secrets. No request query, raw network identifier,
user agent, passkey material, or form body is logged or added to analytics.
The unique origin index prevents ambiguous collector authorization without
creating a new trust boundary.

Runtime cost is a handful of bounded metadata writes and one existing policy
reload only when the owner creates or exactly retries a site. Memory adds no
persistent process structure beyond the already required policy snapshot.
Maintenance is limited to the numbered migration, required-child validation,
and the concrete onboarding routes. Code rollback requires the matched
metadata-5/event-7 database restore because the old binary rejects metadata 6.

**Affected contracts:** `DATA_MODEL.md`, `ARCHITECTURE.md`, `SPEC.md`,
`OPERATIONS.md`, `RELEASE_CONTRACT_1.0.md`, issue #19, and downstream issue
#20. The package flow's “one Turso transaction” sentence is superseded by D19
and this decision; the visible form outcome remains all complete, compensated,
or honestly recoverable.

### Acceptance evidence

Issue #19 must prove fresh passkey-authenticated browser creation with
JavaScript disabled, preserved field values, no partial site after validation
or returned child failure, exact completed resubmission, slug and origin
conflicts, resolvable timezone and secure/loopback origin rules, a post-commit
refresh failure that leaves one durable retryable site, immediate collection
without restart, a working Install handoff, exact metadata-5/event-7 migration
and pair rollback, response/asset/accessibility budgets, and Debug plus
ReleaseSafe gates.

## D37. Bounded Analyze Trend query set and server-rendered route

**Status:** Accepted for Analytico 1.0 issue #28

**Date:** 2026-08-24

**Issue:** #28

**Preserves:** D29's one-metric `AnalysisQuery`, finite compiler, and ordinary
analysis-cache prohibition. D35 remains limited to the fixed Overview result.

### Context

The accepted metric-v2 domain and store execute one typed query with one
metric. The 1.0 Analyze Trend surface must run one through three explicit
current series, reproduce the complete state from a direct URL, and keep one
interactive deadline. The existing browser Analyze route still serves the
frozen metric-v1 list reports, while Overview trend points carry the temporary
`focus` and `highlight` handoff accepted by issue #27.

Calling the existing store entry point three times would allocate three full
deadlines. Replacing `AnalysisQuery.metric` with an array would break the
accepted single-query serialization, presets, compiler, CLI probes, and later
Breakdown consumer. Overlaying unlike count, rate, and exact-value units would
also require the multiple axes that issue #28 explicitly excludes.

### Query-set candidates

| Candidate | Runtime and correctness | URL, maintenance, and rollback |
| --- | --- | --- |
| Replace the query metric with an array | One domain value could describe the page | Breaks D29 and every single-query consumer; forces mode-specific arrays into Breakdown and saved-query state |
| Repeat a complete encoded canonical query per series | Reuses the existing parser unchanged | Duplicates range, comparison, filters, and pagination; makes native forms and canonical equivalence difficult; consumes the 32-field bound quickly |
| Add one bounded Trend-set envelope over existing queries | Preserves each query and finite SQL plan; permits one shared deadline | One small parser/serializer and batch adapter; no migration; rollback removes the additive route and returns bare Analyze to metric-v1 presets |

Select the bounded envelope. It owns shared site, local range, comparison,
interval, empty typed `FilterSet`, and one through three ordered, distinct
`Metric` values. It materializes each series as an ordinary validated Trend
query. Issue #30 owns nonempty universal filters, segments, and saved-view
state; issue #28 rejects those route fields rather than ignoring hidden state.

Canonical browser state is a query component in this order:

```text
v,from,to,compare,mode,interval,series...,highlight
```

`v=1` and `mode=trend` are mandatory. `series` repeats one through three times
and order is meaningful; the first item is primary. A series is one
percent-encoded `~`-separated tuple selected from these finite forms:

```text
metric
event-count~event~event_name
event-visitors~event~event_name
conversions~visitor~goal~goal_uuid
conversion-rate~visitor~goal~goal_uuid
revenue~goal~goal_uuid
average-value~goal~goal_uuid
revenue~event~event_name
average-value~event~event_name
```

Revenue and average value may also use the one-component form for all accepted
value-bearing events. Goal UUIDs resolve only through the selected site's
bounded active-goal snapshot; custom event names use the existing identifier
grammar. No tuple component controls SQL text. Unknown components, empty
tuples, duplicate series, missing subjects, subject/metric mismatches, more
than three series, malformed encoding, unknown fields, duplicate scalar
fields, more than 32 parameters, or more than 16 KiB reject before DuckDB.

A native GET builder may submit three numbered metric/event/goal slots. That
builder shape is not durable state: after validation the server redirects to
the canonical repeated-series form. The shared date/context form uses the same
builder-shaped hidden fields so ordinary HTML form encoding never turns the
structural `~` delimiters into `%7E`; direct canonical URLs retain the strict
component-before-delimiter grammar. The route-generated canonical component is
the bounded hook that issues #30 and #31 later persist or export. Issue #28 does
not render dead Save or Export controls and introduces no placeholder entity or
endpoint.

### Execution and rendering

The store validates and compiles each materialized query, then executes them
sequentially on the existing single writable DuckDB owner with one
`deadline.Budget`. Because #28 fixes one empty filter and one site/range/traffic
context for the whole set, its metric-independent identity coverage statement
runs once and is attached to each series; every series still uses its ordinary
D29 row and total plans. Empty-filter Trend plans omit the existing
`session_facts` relation only for metrics that never consume session-derived
fields. Engagement metrics and every nonempty-filter D29 query retain the full
plan. Coverage, rows, comparisons, and totals all consume the same configured
maximum. A timeout interrupts the current statement, returns the ordinary
report-timeout page with the complete URL, and leaves the connection reusable.
There is no thread, worker, cache, projection, rollup, table, durable state,
dependency, client fetch, or second query engine.

Each visual series uses one existing deterministic server SVG. One shared
captioned exact table aligns the same generated buckets and exposes every
series' raw/source components plus one native interval link, avoiding three
copies of labels and canonical URLs at the 400-point bound. Each figure has one
primary current line and, when selected, one neutral comparison line. Separate
figures keep unlike units on separate axes. An amount query's currencies are
separate visual series and are never added or converted. The complete page may
contain at most three visual series after currency expansion. A larger valid
result returns an explicit 422 bounded result error that asks for a narrower
subject; it is never truncated or rendered into an oversized page.

The controller aligns sparse SQL rows to exact generated site-local buckets:

- absent count buckets are zero;
- a rate with a zero denominator is unavailable, not zero;
- once an exact currency is present in current or comparison data, an absent
  bucket for that currency is exact `0.000000` with zero value rows;
- hourly buckets preserve TZif gap/overlap behavior and stop after the bucket
  containing the request-time instant; day, week, and month retain every
  generated bucket in the requested range, including future buckets.

When the range contains today, the bucket containing the sampled request-time
instant is marked `Incomplete`. A later future bucket is never marked
incomplete merely because it is the last generated bucket.
An optional `highlight` must equal one generated current or comparison bucket
and visibly marks the primary figure without changing SQL. If a long current
and comparison range contain the same label, current takes deterministic
precedence. Changing the date context or rerunning the builder clears a stale
highlight; direct canonical links retain it. Known issue-#27
visitor, session, and page-view `focus`/`highlight` URLs translate once to the
canonical one-series state. Overview's all-active-goal Conversions count is not
the selected-goal unique-conversion metric accepted for Analyze, and an
Overview Revenue point names one exact currency while the accepted core query
returns separate rows for every observed currency. Those two handoff shapes
therefore keep the existing explicit non-filtering Analyze compatibility
callout with the same range/highlight instead of inventing an undocumented
metric or currency query dimension. Explicit legacy `report=` list URLs remain
the working metric-v1 compatibility surface only until D39 translates them once
to typed Breakdown presets; bare Analyze opens typed Trend.

The page distinguishes a site with no stored event from a valid selection with
no matching row in the range by using the existing selected-site event bounds.
Both states preserve the configuration form and canonical context. A site with
no goals keeps traffic/event metrics usable and labels goal subjects as
unavailable; it does not invent a conversion definition or zero-result goal.

Counts remain integers. Rates retain and display their exact numerator and
denominator; basis points are only the deterministic chart coordinate and
formatted percentage. Revenue retains exact `DECIMAL(18,6)` values per
currency. Average value retains its exact summed amount and value-row
denominator; a deterministic six-decimal quotient truncated toward zero may
drive the chart, but the exact table also prints the numerator and denominator
and never calls the quotient an exact stored amount.

D37 does not add a metric kind or field to `Metric`. In particular there is no
`goal-matches` canonical metric and no core currency query dimension. The
controller splits the existing exact amount rows by currency before rendering;
the three-visual-series cap applies after that split. This preserves the D29
single-metric grammar/compiler inventory and keeps later saved/CLI consumers
compatible.

### Consequences

- Runtime work is bounded by three ordinary plans and one existing request
  deadline. The maximum rendered current points are three times 400, with the
  same number of comparison points when available.
- Maintenance is confined to the pure Trend-set grammar, the shared-budget
  store adapter, typed controller/view models, and the existing renderer.
- Security remains behind the passkey session and the current context-safe
  renderer. The parser allocates only in the request arena, values remain
  bound, and no raw request query, user agent, network identifier, or selector
  value is persisted or logged.
- There is no schema, backup-format, deployment-component, or data rollback
  change. Code rollback removes the additive typed route and restores bare
  Analyze to the retained metric-v1 page-presets path.
- D39 and #29 translate the explicit legacy list presets to typed Breakdown.
  #30 later extends the visible shared context with nonempty filters, segments,
  and saved views. #31 later consumes the canonical state for real exports and
  detail routes.

**Affected contracts:** `ANALYSIS_QUERY.md`, `ARCHITECTURE.md`,
`DESIGN_SYSTEM.md`, `PERFORMANCE.md`, `RELEASE_CONTRACT_1.0.md`, and issue #28.

### Acceptance evidence

Issue #28 must prove canonical parser/form round trips; one, two, and three
metric/event/goal series; automatic and every valid manual interval; exact
count/rate/amount semantics; currency overflow; generated current/comparison
highlights; legacy list compatibility; one shared timeout and post-interrupt
reuse; no startup data request; JavaScript-off desktop/mobile/keyboard behavior;
bounded response/assets; repeated million-row three-series HTTP latency; and
separately captured Debug and ReleaseSafe gates.

## D38. Signed stateless installation-verification watermark

**Status:** Accepted for Analytico 1.0 issue #20

**Date:** 2026-08-24

**Issue:** #20

### Context

After browser site creation, the authenticated Install destination must show
the exact current tracker snippet and distinguish a newly accepted collector
event from every row that existed before the owner began that verification.
The result must survive ordinary fragment refreshes and a process restart, work
through a normal GET with JavaScript disabled, and show bounded actionable
rejection guidance without turning the process-local diagnostics ring into
durable product truth.

DuckDB already owns committed events. The issue-#21 diagnostics ring owns only
200 safe process-local summaries and intentionally clears on restart. Turso has
no installation-session entity. The current event table has receipt time and
event ID but no monotonic installation sequence. Reusing only a receipt-time
cutoff would leave an exact timestamp tie ambiguous; accepting an unsigned URL
cutoff would let edited fields make an old row appear new.

### State candidates

| Candidate | Runtime and correctness | Maintenance, migration, and rollback |
| --- | --- | --- |
| Persist each verification session and result in Turso | Durable independently of browser history and can remember a named completion | Adds a schema, cleanup/expiry policy, write failure state, and cross-store reconciliation for one transient owner-only flow |
| Use only the diagnostics ring and its correlation numbers | No query fields or new durable writes | Accepted truth disappears on restart or wrap; malformed attempts often have no validated site and must remain unattributed |
| Carry an authenticated-session-bound signed watermark in the no-store URL and read committed success from DuckDB | A bare GET establishes one exact session; full GET and fragment GET reproduce it; restart preserves committed event truth; edited or cross-site fields fail before DuckDB | Adds no schema or background state; browser history retains only the current authenticated flow; code rollback makes the new URL inert |

Select the signed stateless watermark. It contains a server clock sample for
recent-diagnostic filtering and the selected site's latest committed
`(received_at_utc_micros, event_id)` position. HMAC-SHA-256 binds the versioned
field serialization to the site ID and the current passkey session's random
CSRF secret. The signature is authorization-adjacent integrity only: every
full and fragment request still requires the normal passkey session. A new
bare Install GET always issues a new watermark; reloading its signed URL keeps
that same verification session. Session rotation invalidates the old URL and
the owner starts again from the bare route.

The canonical full target uses the fixed order
`?started=MICROS&count=ROWS&after=MICROS&event=UUID&sig=LOWERCASE_HEX`; the
fragment target adds `&fragment=verification`. An empty event store uses count
and receipt zero plus the all-zero UUID. The signed message is the unambiguous
newline-delimited sequence `analytico-install-v1`, site ID, start receipt,
selected-site row count, high-water receipt, and event ID. No decoded field may
contain a newline, and the closed field grammars make length-prefixing
unnecessary for this version.

The success query selects the first committed selected-site protocol-v1 or
protocol-v2 row strictly after the compound position. An exact duplicate adds
no row and cannot confirm a new installation. A valid stored event remains
collector acceptance even when its permanent traffic class excludes it from
product metrics. Receipt-time clock rollback fails closed: it may delay
confirmation but cannot make a pre-watermark row new. An exact receipt-time tie
confirms only when its UUID sorts after the signed high-water UUID; a newly
committed lower tie likewise fails closed until a later compound position is
stored. Offline retention, migration, and site deletion continue to require the
service to be stopped; they do not become concurrent installation state
transitions.

### Rendering and polling candidates

| Candidate | First response and accessibility | Runtime and maintenance |
| --- | --- | --- |
| Timed full-page reload | Ordinary GET remains functional | Disrupts selection/focus, reloads the whole document, and does not meet the bounded-fragment contract |
| HTMX polling plus a second clipboard/pause script | Reuses the accepted enhancement library | Loads the larger optional asset on a page that needs one small behavior and splits pause/copy ownership across two mechanisms |
| Dedicated Install-only script over the same typed verification model | Complete HTML and manual GET are useful before the script runs; selectable text remains the copy fallback | One bounded same-origin fragment request every five seconds only while waiting, visible, and unpaused |

Select the dedicated Install-only script. It adds clipboard copy with a
selectable manual fallback and replaces only the server-rendered verification
region. It schedules no data request at startup, stops after success or an
explicit pause, suspends while the document is hidden, and resumes only when
visible and unpaused. A normal **Check again** GET retains the signed fields and
is the JavaScript-disabled baseline. The renderer receives a complete typed
model and performs no database, clock, session, or network work.

### Diagnostics, security, and failure behavior

Only selected-site summaries whose server receipt time is at or after the
verification start sample can supply recent guidance. Origin, property,
identity/session, value, rate-limit, and attributable store failures map to a
closed category, consequence, and correction. Protocol-only oversized or
malformed attempts that lack a validated site remain absent from the selected
site snapshot; static safe payload guidance covers that failure without
weakening site isolation. The page labels ring-derived evidence as since
process restart. That guidance never displays raw IP, user agent,
identity/session/event ID, referrer, query, payload, property value, or
unrestricted input.

Install HTML and fragments are private/no-store and use
`Referrer-Policy: no-referrer`, so the signed fields are not sent to same-origin
assets. Query size/count, names, decimal integers, lowercase UUID, fragment
mode, and fixed-length lowercase signature are validated before store access;
duplicates, unknowns, empty values, bad signatures, and cross-site tokens
return the normal bounded invalid-request response. The HMAC uses the standard
library and the already required random session secret; no dependency, new
key, network call, or persisted token is added. The authenticated URL visibly
carries only the pre-session high-water event UUID, count, and receipt time;
`no-store` and `no-referrer` limit their propagation. It never renders the new
event UUID or any diagnostics identity, session, payload, query, referrer,
user-agent, or property value.

If the event store or policy is unavailable, the page keeps the generated
snippet and reports collection/verification unavailable without claiming
success. Fragment transport failure leaves the last honest server state in
place and tells the owner to use manual refresh. Ring restart merely removes
recent rejection guidance; it never removes a committed success. Memory is one
bounded request model and the existing ring snapshot, with no cache or process
table.

### Consequences

- Runtime adds selected-site read-only DuckDB statements: count/latest compound
  position when a bare session starts, a count guard on each check, and the
  first tied/later row only after that count increases. The million-row warm
  fragment must remain below the existing 150 ms operational-fragment budget.
- There is no Turso or DuckDB migration, backup-format change, deployment
  component, background task, cache, or invalidation protocol.
- Code rollback restores the placeholder Install page. Existing metadata,
  events, tracker assets, collector routes, CLI snippets, and database-pair
  rollback remain valid; signed new-page URLs have no meaning to the old code.
- Issue #43 still owns the full Live recent-event/debugger list and its refresh
  controls. Issue #20 consumes only one latest safe attributable setup outcome.
  Issue #22 later owns broader Settings editing and does not replace this
  verification state model.

**Affected contracts:** `SPEC.md`, `ARCHITECTURE.md`, `PROTOCOL.md`,
`OPERATIONS.md`, `PERFORMANCE.md`, `RELEASE_CONTRACT_1.0.md`, and issue #20.

### Acceptance evidence

Issue #20 must prove an old row and a duplicate cannot satisfy a newly issued
watermark; v1 and v2 success states; actionable origin/property/payload
guidance; bad/duplicate/tampered query rejection before DuckDB; clipboard and
manual-copy behavior; JavaScript-off manual GET; visible/unpaused five-second
polling and stop behavior; no startup data request; real immutable tracker page
collection; million-row fragment latency; bounded HTML/assets/RSS; Debug and
ReleaseSafe gates; and the normal release/deployment verification.

## D39. Extend the single metric-v2 query for server-rendered Breakdown

**Status:** Accepted for Analytico 1.0 issue #29

**Date:** 2026-08-24

**Issue:** #29

**Extends:** D29's single-metric `AnalysisQuery` and finite compiler. This
decision narrowly supersedes D29's cache prohibition for one sampled property-
suggestion catalog entry only. D35 remains limited to the fixed Overview
result, and D37 remains the Trend-only multi-series browser envelope.

### Context

D29 already represents and executes one metric grouped by one standard or
explicitly typed event-property dimension. It returns exact typed measures,
stable sort/page/limit state, next-page state, exact bucket cardinality, and
identity completeness. The browser still renders explicit metric-v1
`report=` lists, however, and the D29 grammar has no result-label search even
though the accepted Breakdown product contract requires bounded server search.

The older property-query helper discovers types in an occurrence-UTC window
under a pre-D34 traffic relation. Reusing it beside a site-local metric-v2
result could show a property or type that the selected result cannot contain.
The old five-field campaign tuple likewise has no accepted D29 dimension; new
canonical state deliberately selects exactly one UTM field.

### Query-state candidates

| Candidate | Runtime and correctness | Maintenance, compatibility, and rollback |
| --- | --- | --- |
| Keep metric-v1 list routes and replace only their store calls | Small browser diff | Retains report-kind product branching, cannot express custom properties or canonical search, and leaves two visible analysis models |
| Add a second browser-only Breakdown envelope | Could leave D29 serialization untouched | Duplicates a complete single-query model and parser, complicates saved/export consumers, and creates a second state boundary without a second metric |
| Render one D29 query directly and add one optional bounded search scalar | Search, sort, pagination, and saved/export handoff share the same validated state; the finite compiler binds one extra value | Small compatible grammar extension; rollback removes the route and optional field without touching data |

Select the direct D29 query. `search` is empty or a control-free valid UTF-8
value of at most 256 bytes. It is valid only for Breakdown. The compiler groups
the typed metric first, then applies a case-insensitive substring match to the
result label with one bound parameter before stable ordering and pagination.
It never interpolates a value, identifier, function, or sort expression.
Cardinality is the exact number of matching typed buckets before pagination;
an empty search therefore preserves the full exact cardinality, while a
nonempty search reports its own exact matched cardinality. Search participates
in canonical URL and saved JSON because it changes the result. Its omission is
the compatible representation of the pre-D39 empty state, so query schema 1
does not need a speculative version bump before saved views exist.

### Property-catalog candidates

| Candidate | Semantic fit | Runtime and maintenance |
| --- | --- | --- |
| Reuse the occurrence-UTC property helper | Conflicts with site-local dates and current strict product eligibility | No new statement, but produces a misleading builder |
| Require an unassisted property name and type | The eventual query remains exact | Hides observed conflicts and makes the accepted type-discovery behavior unusable |
| Expand every eligible event into an exact uncached catalog | Shows every type in the range | The million fixture expands 12 million key rows and cannot satisfy the request deadline |
| Query a recent bounded sample on every request | Keeps suggestion work finite and the exact result unchanged | A 2,000-event cold sample is safe but still consumes material repeated latency |
| Retain one recent sampled catalog for 30 seconds | Keeps suggestions site/range/policy specific while the exact result always runs | One bounded arena and full semantic key; suggestions may lag collection by at most 30 seconds |
| Add a property projection/EAV table | Makes cold discovery consistently cheap | Adds a migration, write path, restore/rollback semantics, and stored derived state before the POC needs it |

Select the recent bounded sample plus one short-lived entry. The cold statement
reads the latest 2,000 eligible custom-event canonical JSON documents directly,
returns at most 100 bytewise-ordered property names plus string/integer/decimal/
boolean/null type rows and counts within that sample, and exposes truncation
metadata. The UI labels the sample, 30-second update window, and sampled counts;
the user may directly enter a property outside it. Missing remains an explicit
selectable scalar state rather than an observed JSON key type. The user must
choose one exact scalar type; a name with multiple sampled types is visibly a
conflict, never coerced. A selected null or missing query still runs the exact
metric query and renders its distinct typed bucket.

The Store retains at most one catalog arena. Its length-prefixed key covers
site, selected local dates, strict mode, and every active goal ID, selector
kind/value, predicate property/type/operator, and predicate value. A key miss or
30-second expiry runs the bounded catalog under the result's remaining shared
deadline; a hit deep-copies it into the request allocator. Event inserts do not
evict this suggestion-only entry, because doing so would make active collection
eliminate every useful hit. Expiry, key change, eviction, restart, or code
rollback removes it. No exact Breakdown row, measure, or cardinality is cached.

On a catalog miss, the exact Breakdown result and bounded catalog execute
sequentially on the one writable DuckDB owner under one shared existing
interrupt budget. A zero-cardinality result also runs one selected-site
`LIMIT 1` presence probe under that same remaining budget so the server can
distinguish no events from no matches without a count/min/max scan after the
deadline. Event/property-only plans may omit session facts only when
their metric, dimension, selector, and empty filter cannot consume them;
session dimensions, engagement/rate metrics, and nonempty filters retain the
full accepted plan. This is a measured narrow optimization boundary, not a
second semantic engine.

### Browser and compatibility behavior

Bare Analyze continues to open D37 Trend. A normal native link opens the
canonical Page views by Page Breakdown preset. One GET builder selects the
metric, optional exact event or saved goal, one dimension, explicit property
name/type where applicable, sort, search, and page size. It redirects accepted
builder state to the existing canonical D29 component. Native date, builder,
search, sort, and pagination controls work without JavaScript; optional HTMX
uses the same complete route and browser history. The first response contains
the property catalog, cardinality/truncation state, typed result, in-cell bar,
and exact table. There is no startup data request, client state, result cache,
projection, EAV table, migration, dependency, or entity-detail placeholder.
Existing typed selector predicates in a direct canonical URL are preserved by
both native context and builder forms and disclosed as preserved state; #30
owns their visible editing surface. Direct browser state with a page selector
or non-visitor conversion basis rejects before execution because the #29
builder cannot preserve those otherwise-valid core D29 combinations.

Known metric-v1 list URLs translate once to typed presets: Page views by Page;
Sessions by Landing page, Exit page, Referrer, each selected UTM dimension,
Country, Browser, Operating system, or Device; and Custom events by Event name.
Count sort maps to descending typed value, label sort to ascending label, and
page/limit remain bounded. The legacy combined five-field `campaign=all`
state redirects visibly to Sessions by UTM campaign. It is not silently
preserved as an undocumented dimension; explicit source/medium/campaign/term/
content states map exactly. Metric-v1 CLI/report SQL and output remain frozen.

### Consequences

- Runtime always includes one exact ordinary Breakdown result, conditionally
  includes one `LIMIT 1` site-presence probe for a zero-cardinality result, and
  includes one bounded catalog query on a key miss. All share one deadline. The
  uncached all-row catalog timed out after the exact result had completed in
  559 ms even with more than 9.4 seconds remaining. A 10,000-event sample still
  cost 479–635 ms per catalog query. A 2,000-event sample made the cold path
  safe, but full property p95 was 843 ms and ordinary p95 was 397 ms. With the
  exact keyed 30-second entry, the post-YAGNI ReleaseSafe million-row candidate
  measured the cold path at 829 ms, property p50/p95/p99 at 484/528/528 ms,
  ordinary p95 at 97 ms, and exact high-cardinality search at 333 ms. The
  repeated measurements are warm catalog-hit calls after one explicit cold
  warmup; they are not represented as cold SQL. A later miss follows the
  documented order before a projection or migration is proposed.
- Input work remains bounded by the existing 16 KiB/32-field URL, 400-day
  range, 100-row page, latest 2,000 eligible catalog events, 100-property
  catalog, one 30-second process entry, 2,000 ms deadline, and the new 256-byte
  search value. Values are bound and rendered only through the existing
  context-safe HTML helpers.
- Exact table cells retain count, rate numerator/denominator, or exact decimal
  amount/currency/value-count. Bar geometry is derived and cannot replace the
  source components. High cardinality is a visible exact warning, never silent
  truncation or hundreds of bars.
- There is no Turso/DuckDB schema, backup format, process, network, dependency,
  durable state, or security-boundary change. Cache memory contains only the
  bounded selected-site property suggestions and full semantic key; it is never
  logged or shared across keys. Code rollback removes the entry, restores the
  D37 Trend route and previous explicit list compatibility, and leaves schema-7
  data plus the frozen metric-v1 CLI readable.
- #30 owns filters, segments, and saved-view persistence. #31 owns entity
  detail routes and export responses. #44 and #46 retain the broader mobile
  and representative mixed-fixture acceptance passes.

**Affected contracts:** `SPEC.md`, `ARCHITECTURE.md`, `DATA_MODEL.md`,
`ANALYSIS_QUERY.md`, `DESIGN_SYSTEM.md`, `PERFORMANCE.md`,
`RELEASE_CONTRACT_1.0.md`, and issue #29.

### Acceptance evidence

Issue #29 must prove canonical search round trips and adversarial bounds;
every current list preset and compatibility redirect; exact property string,
integer, decimal, boolean, null, and missing states plus visible type conflict;
bound high-cardinality search and exact matched cardinality; stable tie/page
behavior; exact table/bar equivalence; timeout and post-interrupt reuse; real
on-disk million-row Breakdown/catalog latency; JavaScript-off and enhanced
desktop/mobile browser behavior; no startup data request; metric-v1 CLI
preservation; and separate Debug and ReleaseSafe gates.

## D40. Resolve one canonical filter context and persist exact saved state

**Status:** Accepted for Analytico 1.0 issue #30

**Date:** 2026-08-24

**Issue:** #30

**Extends:** D29's closed `FilterSet`, D37's Trend-set browser envelope, D39's
direct Breakdown consumer, and D35's one exact complete Overview-result entry.
It preserves D19's durable Turso autocommit boundary.

### Context

D29 already validates, canonicalizes, and compiles event-, session-, and
person-scoped clauses, but no shipped browser surface accepts a nonempty
FilterSet. D37 fixes Trend to an empty set, D39 makes Breakdown reject filters
and segments that it cannot display, and the specialized Overview has neither
filter input nor filter-aware cache identity. Metadata schema 6 has no durable
segment or saved-view entity. Adding only chips or URL parameters would claim
universal filtering while returning unfiltered Overview data; saving opaque
URLs would also bypass the accepted canonical-JSON compatibility boundary.

### Candidates

| Candidate | Runtime and product behavior | Maintenance, migration, and rollback |
| --- | --- | --- |
| Add separate filter parsers and saved URL strings to each route | Small first route diff | Duplicates semantics, makes stale state and canonical equivalence route-specific, and gives later consumers no typed context |
| Introduce a generic expression/query/dashboard framework | Could model future screens and arbitrary saved state | Breaks D29's closed grammar, enlarges the SQL and validation surface, and adds abstractions without accepted consumers |
| Extend the existing FilterSet plus the two real browser envelopes, resolve one controller-owned context, and persist exact canonical JSON in Turso | Reuses finite bound SQL; current Overview, Trend, and Breakdown share visible semantics; future specialized engines receive the same closed input | One additive metadata migration and bounded controller/store/UI work; rollback requires the matched pre-migration database pair |

Select the third candidate.

### Canonical and persisted state

- A segment is exactly one schema-1 `FilterSet` in `all` mode. Its canonical
  JSON has fixed field order, sorted/deduplicated clauses and values, no unknown
  fields, and at most 32 KiB. Stored bytes must parse, validate, and reserialize
  byte-for-byte before use.
- A saved Breakdown view stores D29 canonical query JSON. A saved Trend view
  stores an exact schema-1/metric-v2 Trend-set JSON counterpart containing its
  ordered one-to-three series, shared range/comparison/interval, optional
  segment, and sorted ad-hoc filters. Page number and highlighted interval are
  transient and are never saved.
- A saved view references its selected segment ID and stores ad-hoc clauses.
  Segment edits therefore affect future loads. The controller resolves the
  selected site's segment, composes segment clauses before ad-hoc clauses,
  canonicalizes/deduplicates them, and enforces the existing total of 12
  clauses and 20 OR values per clause. Only the composed FilterSet enters an
  execution value. Segment IDs remain provenance and never enter DuckDB SQL.
- Creating a segment snapshots the complete currently composed FilterSet and
  creates no nested segment reference. Canonical Overview parameters are
  `v,from,to,compare,metric,segment,f...`; canonical Trend parameters are
  `v,from,to,compare,mode,interval,series...,segment,highlight,f...`.
  Existing filter-empty Overview URLs redirect once to mandatory `v=1`.
- Missing segments, removed property keys, removed saved goals, malformed
  canonical bytes, and site mismatches are typed stale/corrupt states before
  DuckDB. The server shows the affected clause/entity and an explicit remove or
  reset action. It never silently omits a stale clause or converts the result
  to zero.

### Metadata schema 7 and mutations

Metadata schema 7 adds `segments` and `saved_views`. Each row has a canonical
UUID, site foreign key with cascade deletion, unique site/name, explicit schema
version, bounded canonical JSON, and created/updated UTC microseconds. Each
site has at most 32 rows of either kind. Names retain the existing 120-byte
validated UTF-8 bound. Public sharing, teams, ownership tables, revisions,
layout/widgets, and background synchronization are not added.

Create, rename, duplicate, and delete are individual D19 durable autocommits.
No operation writes DuckDB or requires a cross-store or explicit Turso
transaction. Delete requires an exact typed name. Canonical state is generated
and validated by the application before insertion; site-scoped reads and
mutation predicates prevent cross-site inference or modification.

### Execution and suggestions

Trend materializes each series from the same D29 grammar with the complete
resolved FilterSet under its existing shared deadline. Breakdown executes one
bounded statement after controller resolution; filtered Page Views by Page uses
a direct page-view-qualified statement so custom-only paths cannot create zero
rows. The fixed Overview gains a period-aware finite filtered plan so
event/session/person scope has the same meaning as D29. Health facts remain
visibly outside product filters.

The accepted D35 unfiltered SQL remains unchanged. A nonempty resolved set may
use the same single complete-result cache entry, whose length-prefixed key adds
the complete canonical composed FilterSet. The cache is not multiplied, made
durable, or generalized to ordinary AnalysisQuery results. A segment rename
does not affect result identity; a changed definition produces different
canonical bytes. Filtered cold execution must remain inside the two-second
deadline, and repeated normal/strict Overview calls retain the existing
below-250-ms and at-most-500-ms p95 gates.

The accepted million-row plan keeps count and bit-mask goal projections
separate. Deriving the count with `bit_count(goal_mask)` repeated every active
selector only once but worsened the strict profile from 2.03 to 2.14 seconds;
it was rejected rather than accepted on appearance. Strict classifier work
materializes persistent candidate keys before looking for cross-session
contradictions, so an empty persistent build side does not scan the million
identity rows. When every clause is a stored session fact, session cardinality
comes from the existing one-row-per-session relation; mixed, event, and person
filters retain the exact qualified-event path.

The native builder requests suggestions for one validated field, scope, scalar
type, search value, selected site/range, and the already resolved preceding
filters. One finite reviewed SQL plan binds every value, runs under a two-second
interrupt, returns at most 50 values plus a `has_more` flag, and exposes exact
typed values for the resulting canonical clause. There is no preload-all,
suggestion/result cache, projection, EAV table, worker, network request, or new
dependency. Null, missing, and boolean operators remain explicit even when no
text value is required.

### Browser, security, and rollback

Overview, Trend, and Breakdown render the same selected segment and filter
chips in the first authenticated HTML. Native POST applies or previews a
filter, verifies exact origin and CSRF, and redirects successful application
with 303 to an inspectable canonical GET. Removal and explicit row `Filter` /
`Exclude` actions are ordinary canonical links. HTMX may boost the same forms
and links but owns no state. Renderer inputs contain owned labels and URLs;
renderers perform no allocation or I/O.

The accepted 32 KiB saved JSON cannot fit the general 8 KiB body limit after
form encoding. Only the authenticated filter/saved-state routes receive a
64 KiB body ceiling and a specialized bounded field parser; the canonical
saved-state matcher mirrors that exact ceiling. Inside only that route handle,
declared `Content-Length` above 65,536 returns 413 and a missing length returns
411 before proxy dispatch; exact `max_size 65536` remains the read-time bound.
Native URL-encoded browser forms provide their finite length. Pre-reading
65,536 or 65,537 bytes was rejected after each candidate still raced an early
authenticated or unauthenticated upstream response into 502. No generic or
global request buffering is retained. Every other route keeps its existing
application limit, and passkey routes retain their 192 KiB outer proxy ceiling.
Stored/query values remain behind the passkey owner boundary, are
context-safely escaped, are never logged as raw query strings, and never become
SQL structure. Bounded exact string values may retain percent-encoded control
bytes present in legacy observed dimensions so
every rendered Breakdown row remains filterable; suggestion search itself
remains control-free.

The proxy boundary was selected from these measured candidates:

| Candidate | Result |
| --- | --- |
| `max_size 65536` alone | Bounds Caddy's body read but can race an early upstream close into 502 |
| Saved-state-only `request_buffers` at 65,536 or 65,537 bytes | Still produced a measured authenticated or unauthenticated 502; rejected |
| Saved-state-only declared-length preflight plus `max_size 65536` | Returns 413 before dispatch above the declared limit, 411 when length is absent, preserves exact-limit requests, and retains the read-time bound; selected |

The metadata-schema-7 migration is metadata-only; event schema 7, tracker,
process topology, and backup format do not change. The complete #30 release
changes Caddy only for the 12 saved-state mutation paths described above.
Deployment stops the sole writer, backs up and independently restores the
exact metadata-6/event-7 pair, proves the `a2d71c0` predecessor opens the
restored pair, then migrates and verifies the candidate. The old binary must
refuse migrated metadata. Rollback stops the writer, restores the matched pair
and the backed-up predecessor Caddy configuration, and only then switches to
the predecessor; switching the executable alone is forbidden.

### Consequences and acceptance evidence

Runtime gains bounded metadata reads, at most one suggestion statement per
preview, and filtered report work under existing deadlines. Maintenance gains
one numbered migration, pure serializers, site-scoped CRUD, one resolved
context seam, filtered Overview SQL, and explicit browser models. Memory and
input work remain bounded by 32 saved entities per kind/site, 32 KiB canonical
JSON, a 64 KiB route-specific form body, 12 clauses, 20 values, 50 suggestions,
and the existing URL/query/result limits.

Issue #30 must prove exact AND/OR/scope/type semantics; URL and JSON delimiter,
canonicality, and size bounds; composed-limit and stale/corrupt behavior;
two-site CRUD isolation; exact metadata-6-to-7 upgrade, replay, backup, restore,
and pair rollback; real JavaScript-off and enhanced desktop/mobile/history
flows; explicit row actions; timeout/reuse; million-row filtered Overview,
Trend, Breakdown, and suggestion budgets; metric-v1 preservation; and separate
Debug and ReleaseSafe gates.

**Affected contracts:** `SPEC.md`, `ARCHITECTURE.md`, `DATA_MODEL.md`,
`ANALYSIS_QUERY.md`, `DESIGN_SYSTEM.md`, `PERFORMANCE.md`, `OPERATIONS.md`,
`RELEASE_CONTRACT_1.0.md`, and issue #30. Issues #31, #38, #39, #41, #47, and
#48 consume or verify this boundary later without broadening its grammar.

## D41. Replace raw goal administration with a guided, reference-safe lifecycle

**Status:** Accepted for Analytico 1.0 issue #33

**Date:** 2026-08-24

**Issue:** #33

**Extends:** D19's durable Turso autocommits, D29's closed event-selector
grammar, D34's bounded active-goal snapshot, and D40's exact saved state. It
supersedes D40 only where an ordinary goal deletion would knowingly invalidate
a current valid saved view.

### Context

Metadata schema 7 stores a goal as an immutable name and raw selector tuple.
The CLI and authenticated browser can add, list, or delete that row, but cannot
edit, duplicate, archive, reactivate, browse an entity, or preserve a stable
detail destination. `listGoals` also feeds both default conversion metrics and
D34's human-evidence veto, so simply retaining an archived row in that snapshot
would change analytics semantics. Conversely, deleting a goal selected by a
valid saved Trend or Breakdown view would knowingly create the stale state that
#33's reference-safe deletion requirement forbids.

The package target also includes property predicates and historical preview,
but #34 explicitly owns those additions. Funnel goal-ID references do not
exist yet; #35 owns creating them and extending the deletion guard. Issue #33
must deliver a complete base Page/Event lifecycle without prebuilding either
downstream feature.

### Lifecycle storage and migration candidates

| Candidate | Runtime behavior | Migration, maintenance, and rollback |
| --- | --- | --- |
| Add lifecycle columns directly to `goals` | Compact single-row mutations | Interrupted replay cannot safely repeat the required `ALTER TABLE ADD COLUMN` sequence on the pinned Turso evidence |
| Add a one-to-one lifecycle child | Replayable additive migration | Create and repair become multi-write mutations with a crash-visible mixed state |
| Replace `goals` with `goal_definitions` | Every post-migration mutation remains one statement | Deterministic copy and verification are replayable; rollback restores the matched predecessor pair |

Select the replacement table. Metadata schema 8 creates
`goal_definitions`, copies every schema-7 row as active with identical IDs,
sites, names, selectors, and creation times, sets its initial update time to the
creation time, verifies count and complete row equality, removes the retired
table, and writes migration ledger 8 last. Retry may repair deterministic
partial copies. If interruption lands after the verified retired-table removal
but before the ledger write, retry accepts only the exact validated replacement
shape and completes the ledger; any other source/replacement combination fails
closed. These are D19 durable autocommits, not an explicit multi-write Turso
transaction. The exact schema-7 predecessor is commit `54f49ed`; that binary
must refuse migrated metadata, and rollback restores the matched
metadata-7/event-7 backup before it starts.

### Mutations, capacity, and references

Create, edit, duplicate, archive, reactivate, and delete are site-scoped
single-statement mutations. IDs remain immutable. Name, selector, state, and
update time are compared or guarded in the write predicate so a stale form
never reports a different stored outcome as success. The application permits
at most 32 active goals per site; create, duplicate, and reactivate enforce
that cap inside the write rather than with a preceding race-prone count.
Duplicate copies the source selector in that same timestamp-guarded insert and
accepts only a new unique display name; it is not a second edit builder.
Archiving frees one active slot and preserves historical reportability.
Archived definitions never enter default Overview conversion totals or D34
classifier evidence.

Schema 7 already treats an externally created pre-migration overflow as data to
preserve rather than silently discard. Schema 8 copies every such row, shows
the over-cap state, blocks create/duplicate/reactivate, and keeps D34 strict
enablement unavailable until archive brings the active count to 32 or fewer.
It never truncates the active snapshot or chooses goals on the owner's behalf.

A current saved Trend or Breakdown view can contain one exact saved-goal UUID
inside D40's bounded, canonical schema-1 JSON. Deletion therefore performs one
conditional statement that refuses the exact site-owned UUID reference with an
HTTP 409 outcome and offers archive. It does not cascade or rewrite the saved
view. The check uses the fixed canonical selector representation and must prove
that the same UUID in unrelated property/filter text is not a reference. For
Breakdown it compares the structured selector kind and value. For Trend it
examines only the `series` array and compares the finite accepted canonical
series forms. A raw whole-document UUID substring is not a reference check.
Archive remains available and preserves the UUID. Corrupt restored state,
retention outside this application path, or future removed entities may still
produce D40's explicit stale state; D41 does not hide or normalize those cases.
A normalized reference table would duplicate canonical state and add mutation
and backfill machinery for one bounded existing consumer, so it is not added.
When #35 creates funnel goal-ID references, it must extend the same atomic
deletion predicate rather than weaken this rule.

### Reporting and discovered entities

The active-goal snapshot remains capped at 32 and continues to govern default
conversion metrics and D34. A separate request-owned explicit resolution set
contains at most the three goal IDs selected by the existing Trend/Breakdown
envelope and absent from the active set; an active selected ID resolves from
the active snapshot rather than being duplicated across both inputs. The
explicit set may resolve archived definitions for a direct or saved report but
never makes them active again. Editing a definition intentionally changes
future evaluation over raw historical events; no definition version history
or snapshot is introduced.

The guided builder queries DuckDB for Page or custom-event entities under the
selected site's resolved local range, traffic policy, and one existing
two-second request deadline. It returns at most 50 rows plus `has_more`, with
exact label, eligible count, and last receipt time, ordered by count descending
then label ascending. Page discovery reads qualifying page-view paths; Event
discovery reads qualifying custom-event names. Search and pagination remain
bound values. No Turso query reaches DuckDB, no raw URL query or user agent is
retained, and no cache, projection, background work, network request, or new
dependency is added.

A manual exact value absent from the current result is allowed only after an
explicit zero-seen confirmation. Exact-page, page-prefix, and exact-event are
the only #33 selectors. Predicate rows, type-conflict handling, historical
preview, and expanded goal result metrics remain #34 work.

### Browser, security, and rollback

The authenticated route family exposes stable list, new, detail, and edit GET
destinations beneath `/admin/sites/{site}/journeys/goals`. Native bounded forms
perform POST/303/GET create, edit, duplicate, archive, reactivate, and delete.
They preserve valid submitted state and field errors, verify the selected site,
session, exact origin, and CSRF token, and require exact destructive
confirmation. The server produces one owned typed view model; deterministic
renderers allocate nothing and perform no database, filesystem, session,
network, or clock work. JavaScript may enhance the same routes but owns no
state, and the first response contains the useful management or builder state.

The metadata migration changes neither DuckDB event schema 7 nor tracker,
Caddy, service topology, dependencies, or backup format. Deployment stops the
sole writer, creates and independently restores the metadata-7/event-7 pair,
proves `54f49ed` opens the restored predecessor and reproduces selected
reports, then migrates and verifies schema 8. Executable-only rollback is
forbidden; the matched pair must be restored before starting the predecessor.

### Consequences and acceptance evidence

Runtime adds bounded goal CRUD reads plus at most one deadline-controlled
discovery statement on builder search. Durable state gains one numbered
replacement migration but no second lifecycle table, reference index, audit
process, draft store, or version history. Memory and work remain bounded by 32
active goals, page-sized archived reads, three explicit resolved goals, 50
discovered entities plus next-page state, existing form/URL limits, and the
two-second analysis deadline.

Issue #33 must prove exact schema-7-to-8 copy, interrupted retry, repeated
migration, backup/restore, predecessor read and refusal, matched rollback, and
event/report preservation. It must also prove site-isolated lifecycle CRUD,
stable IDs across rename, exact active-cap and preserved-overflow behavior,
saved Trend and Breakdown
delete conflicts without false UUID collisions, archived explicit reports with
active Overview/D34 isolation, discovery semantics/bounds/deadline/reuse,
authentication/origin/CSRF/idempotent submission, JavaScript-disabled and
enhanced desktop/mobile flows, and separate Debug and ReleaseSafe gates.

**Affected contracts:** `SPEC.md`, `ARCHITECTURE.md`, `DATA_MODEL.md`,
`ANALYSIS_QUERY.md`, `DESIGN_SYSTEM.md`, `PERFORMANCE.md`, `OPERATIONS.md`,
`RELEASE_CONTRACT_1.0.md`, and issue #33. Issues #34 and #35 extend this
boundary without broadening #33.
