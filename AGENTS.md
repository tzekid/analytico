# Analytico engineering doctrine

This file is normative. `PRODUCT.md`, `docs/ARCHITECTURE.md`,
`docs/PROTOCOL.md`, and `docs/PERFORMANCE.md` follow it in that order.
Historical release documents describe the archived Turso/DuckDB product and
do not govern this implementation.

## Product boundary

Analytico is one Zig executable, one vendored SQLite database engine, one
database file, and small generated browser trackers. The CLI is the product
interface. Caddy owns TLS and public routing.

Until measured evidence and a current consumer require otherwise, do not add
another storage engine, runtime dependency, process, queue, cache, rollup,
ORM, generic query language, plugin system, frontend framework, web dashboard,
or compatibility protocol.

Product identity mode is deferred until consent, persistence, deletion, and
identity-conflict semantics are explicitly designed. Lite and Session modes
are current.

## Architecture

The defining path is explicit:

browser or trusted application -> closed envelope -> strict validation ->
normalization -> durable SQLite transaction -> fixed report query -> CLI.

- Server receipt time determines acceptance and storage date.
- Client time is retained only for bounded ordering.
- Browser events never establish authoritative commercial outcomes.
- Unknown traffic remains unknown. Classification never silently discards it.
- Raw events are evidence; report meanings are fixed, versioned definitions.
- One process owns writes. WAL, foreign keys, prepared statements, bounded
  inputs, and short transactions are mandatory.
- Migrations are numbered, compiled in, and run only by an explicit command.
  Normal `serve` refuses a non-current schema.

## Data safety

Never persist raw IP addresses, full user agents, full URLs, arbitrary query
strings, form values, selected text, profile text, names, email addresses,
birth dates, dating preferences, uploaded files, payment credentials, DOM
snapshots, mouse movement, or browser fingerprints.

Exact origins and site state are checked server-side. Internal ingestion uses
a site-specific secret, timestamp, and body signature. Rejection diagnostics
never echo user-controlled payload data.

## Simplicity and verification

- Apply YAGNI before every abstraction or feature.
- Prefer plain Zig types and explicit SQL.
- Extract shared code after two real consumers demonstrate matching semantics.
- Do not add fallbacks that hide corrupt configuration or missing data.
- Prefer a few end-to-end checks using the real executable, on-disk SQLite,
  and loopback HTTP. Add narrow tests only where they catch distinct failures.
- A compile alone is not delivery, but avoid ceremonial test matrices and
  workflow churn.
- Preserve unrelated work and never add tool branding to commits or artifacts.

## Operations

Backups use SQLite's online backup API. Restore writes a new data directory.
Prune and vacuum require a newly created, verified backup. Graceful shutdown
stops accepting work, finishes the active transaction, and checkpoints WAL.
