# Architecture

> **Status:** Sections 1–10 describe the shipped one-process runtime, its frozen
> protocol-v1 compatibility path, additive protocol-v2 collector foundation,
> event schema 3, protocol-v2 tracker anonymous identity, and 30-minute client
> sessions. The remaining 1.0 evolution is stated separately below; it
> preserves this runtime shape and lands only with its issue evidence.

## 1. Runtime shape

```mermaid
flowchart LR
    B["Visitor browser"] -->|"POST event or GET pixel"| H["HTTP adapter"]
    C["Local operator CLI"] --> A["Application commands"]
    H --> A
    A --> D["Domain types and rules"]
    A --> T["Turso metadata store"]
    A --> Q["DuckDB event store"]
    Q --> R["Typed report models"]
    T --> R
    R --> C
    R --> V["Deterministic HTML renderer"]
```

The deployed MVP has one operating-system process and two local database files.
Turso and DuckDB are linked libraries, not services. Caddy terminates TLS,
exposes only documented collection and `/admin` routes on one canonical
hostname, redirects `/` to `/admin`, and rejects every unknown path. Analytico
protects dashboard state with its server-side passkey session.

## 2. Dependency direction

```text
domain
  ↑
application
  ↑
adapters: cli, http, turso, duckdb
  ↑
composition root

renderer <- typed view models <- controller <- application
```

- Domain code knows plain Zig types, validation rules, and metric semantics.
- Application code coordinates explicit operations and owns timeouts.
- Adapters translate CLI, HTTP, Turso, and DuckDB details.
- The composition root creates concrete handles and passes them directly.
- There is no service locator, dependency-injection container, ORM, generic
  repository framework, or generic middleware chain.

An interface is introduced only when a second real implementation or a
deterministic test seam needs the same semantics. Until then, functions accept
the concrete store or a narrow function pointer owned by the caller.

## 3. Source layout

This is a destination, not permission to create empty placeholder modules:

```text
src/
  domain/             event, site, goal, funnel, range, validation
  app/                ingest, report, administration, backup
  store/turso/        metadata connection and numbered migrations
  store/duckdb/       C bridge, event schema, inserts, report SQL
  cli/                command parsing and terminal/JSON/CSV output
  http/               collector routes, origin checks, rate limits
  tracker/            source used to produce the small vendored tracker
  web/                dashboard adapter, controller, view models, renderer
  main.zig            composition root
```

A folder is created only when its first concrete module is implemented.

## 4. Database responsibilities

### Turso

Turso contains relational state with small cardinality and ordinary
transactions:

- site identity and allowed origins;
- goal and funnel definitions;
- protocol-v1 custom-property allowlists;
- passkey credentials and revocable owner sessions;
- database migration ledger.

Remote synchronization, encryption, FTS, and Cloud access remain disabled until
a separately accepted requirement needs them.

### DuckDB

The shipped DuckDB schema contains:

- one append-oriented event table;
- the protocol-v2 anonymous-identity link table;
- its own migration ledger;
- report SQL over bounded site and time filters.

Event schema 3 adds the accepted protocol-v2 event and identity-link foundation
through the same DuckDB ownership boundary. It does not move configuration into
DuckDB or permit Turso to query analytics rows. Temporary visitor-day columns
keep metric-v1 report SQL honest until versioned metric-v2 queries replace it.

The serving process configures one query thread, a bounded memory limit, a
bounded temporary directory, no community extensions, and no external file or
network access. It never executes request-supplied SQL.

### No cross-database transaction

No user action requires atomic writes to both files:

- site/goal/funnel administration writes only Turso;
- event ingestion reads already-loaded site policy and writes only DuckDB;
- reporting reads immutable configuration and event snapshots.

If a goal changes while a report runs, that report uses the owned goal snapshot
loaded at its start. This is deterministic and avoids pretending the two files
offer distributed transactions.

## 5. Collection flow

1. The HTTP adapter rejects an oversized request before allocation.
2. It resolves the site by public identifier from a bounded in-memory snapshot
   populated from Turso at startup and refreshed only by an explicit local
   administration operation or process restart.
3. It validates the exact `Origin` or request referrer origin.
4. It parses a bounded payload into a domain `IncomingEvent`.
5. Domain normalization removes arbitrary query strings, canonicalizes the
   path and referral host, validates the event name and bounded flat
   properties, and derives coarse dimensions. The frozen v1 path additionally
   enforces its configured property allowlist.
6. On the shipped protocol-v1 path, a keyed daily pseudonym is derived from
   site, UTC date, normalized network prefix, and coarse user-agent input. Raw
   inputs are then discarded.
7. The DuckDB adapter inserts one event in a short transaction. V2 checks its
   canonical digest for site-scoped idempotency and commits an identify link
   atomically when applicable.
8. Only after commit does the adapter return success.

At the target traffic level, direct durable inserts are simpler and more honest
than an in-memory queue. A queue is reconsidered only after measured write
latency violates the budget.

### 1.0 collection evolution

The shipped protocol-v2 foundation accepts a random site-scoped first-party
anonymous UUID, an optional bounded application user ID, and a random client
session UUID plus sequence. The server validates and stores those values; it
never derives a long-lived fingerprint. The protocol-v2 tracker persists
site-scoped anonymous identity and a session record in first-party
`localStorage`, exposes `identify()` and `reset()`, and rotates the session
after more than 30 minutes of inactivity without splitting at UTC midnight.
Identity links remain server-authoritative. Canonical people and latest traits
are derived from links and accepted identify events rather than a mutable
profile store. Server receipt time remains authoritative for acceptance. The
runtime loads each site's explicitly configured TZif policy once at startup
and derives the stable local date and exact minute offset for both protocol
paths from receipt time. Missing, pending, or invalid zone policy prevents
startup rather than falling back to process-local time.

Protocol-v1 rows keep their daily visitor and session meaning under metric v1.
Migration marks them `legacy_daily`, never links them across dates, and retains
their existing session IDs. Decisions D26–D28 govern this version boundary;
issues #10–#13 own properties, SPA, metric, timezone, and the remaining
migration acceptance.

## 6. Report flow

1. Parse and validate site, date range, pagination, filters, and report kind.
2. Load the site and any goal/funnel definition from Turso with an application
   timeout.
3. Build one of a closed set of report query plans.
4. Bind all data values and execute on DuckDB with a deadline and interrupt.
5. Decode into an owned typed report.
6. Render table, JSON, or CSV in the CLI, or deterministic HTML from the same
   report type in the dashboard.

The shipped metric-v1 reports continue to convert UTC dates directly. The D27
range resolver converts inclusive local dates into half-open UTC instants with
defined gap/overlap behavior, and metric-v2 report work consumes that resolver
and the stored site-local date/offset while retaining UTC timestamps. Loading
the resolver does not silently reinterpret metric-v1 totals.

No report accepts arbitrary SQL, column names, sort expressions, or templates
from the request. Enumerated sorts select a compiled query template.

## 7. Concurrency

- Exactly one process opens the DuckDB file read-write.
- The process owns a small fixed set of connections.
- Appends and reports may run in the same process; report concurrency is
  bounded.
- The collector never starts an unbounded task per request.
- Shutdown stops accepting requests, waits for a bounded grace period,
  interrupts remaining reports, checkpoints, and closes both stores.

DuckDB supports concurrent appends within one process, but that capability is
not a reason to add a worker pool before load requires it.

## 8. Failure behavior

| Failure | Required behavior |
| --- | --- |
| Invalid or oversized event | Reject before storage; bounded log counter |
| Unknown/disabled site | Reject without revealing site details |
| Country/client cannot be derived | Store `unknown`; accept otherwise valid event |
| DuckDB write fails | Return failure; never claim acceptance |
| Report exceeds deadline | Interrupt query and return an honest timeout |
| Turso unavailable/corrupt | Readiness fails; administration/reporting unavailable |
| DuckDB unavailable/corrupt | Readiness fails; collection and reports unavailable |
| Disk full | Reject writes, expose readiness failure, preserve existing files |
| Renderer error | Return a small escaped server-rendered error page |

## 9. Caching

The MVP has no report cache. The expected dataset makes on-demand queries the
simpler choice. M6 did not add a cache because measurements did not require
one. Any later cache key must include site, exact time
range, metric-version, filters, sort, and page; its invalidation watermark is
the latest accepted event time for that site.

## 10. Dashboard and Cloudio boundary

DuckDB's writable-file ownership rules prohibit a later Cloudio process from
opening the same file concurrently. The supported candidates are:

1. Keep Analytico standalone and link to its server-rendered dashboard.
2. Compile the Analytico application modules into Cloudio so Cloudio becomes
   the one process that owns both stores.
3. Have Cloudio request complete HTML from Analytico with a strict timeout,
   while Analytico remains the database owner.

M8 selected candidate 1: Analytico remains standalone and Cloudio may expose an
ordinary link to it. Decision D22 records the evidence. No identity forwarding,
shared session, generic API, or shared package was added.
