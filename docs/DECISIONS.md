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
| D04 | DuckDB integration | Direct pinned LTS C API | Accepted |
| D05 | Zig and Turso channel | Exact local development pins | Accepted |
| D06 | Ingestion durability | Direct synchronous insert | Accepted |
| D07 | Visitor/session identity | Cookieless site-scoped daily pseudonym | Accepted |
| D08 | Persisted visitor data | Derived dimensions only | Accepted |
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
| D21 | Session boundaries | Persist event-local boundaries at commit | Accepted |
| D22 | Cloudio integration | Optional ordinary link to standalone Analytico | Accepted |

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
multi-user requirement.

### M6 evidence

Accepted. A separate Caddy vhost challenges unauthenticated requests before
proxying only `/admin` routes. The application remains loopback-only and uses
POST/redirect/GET, a per-installation CSRF token, exact `Origin` comparison,
and context-specific escaping. Basic Auth has no server logout operation, so
the dashboard deliberately has no fake logout route or second session model;
the browser owns cached credential lifetime. Real Chromium with JavaScript
disabled proves challenged and authenticated access plus all modifying forms.

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
