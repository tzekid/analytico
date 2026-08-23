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

**Status:** Accepted for Analytico 1.0 issue #24

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
  remain in their issue-backed consumers. No generic AST, ORM, cache, rollup,
  projection, service, table, migration, or dependency is introduced.

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
- Schema 4 traffic class work may replace the current device-bot predicate, but
  it must preserve visible diagnostic accounting and version the new meaning.
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
