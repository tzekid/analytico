# Decision register

## A01. Clean break

Status: accepted.

The Turso/DuckDB/passkey/dashboard implementation is archived at
`archive/pre-sqlite-overhaul-2026-08-28`. The new engine has no compatibility
protocol or dual-store migration. The legacy data has a matched verified
read-only backup outside the repository.

This avoids carrying two metric models and two operational paths. Rollback is
checkout/deploy of the archived release with its matched data backup; new
SQLite data is not backward-converted.

## A02. SQLite-only storage

Status: accepted.

Candidates were Turso plus DuckDB, system SQLite, and a vendored SQLite
amalgamation. Analytico uses the official SQLite 3.53.4 amalgamation because it
keeps one durable file, one C boundary, offline builds, window functions, JSON
queries, online backup, and a very small operational surface. The source ZIP
and `sqlite3.c` SHA3 values are recorded in `vendor/sqlite/README.md`.

A second engine is considered only after schema, index, query, transaction,
and result-bound work fails a real workload.

## A03. Direct durable ingestion

Status: accepted.

The collector validates a complete batch, begins one short SQLite transaction,
inserts evidence and idempotency receipts, and commits before 204. A queue or
worker would create accepted-but-not-durable state without solving a current
traffic problem.

## A04. Lite and Session identity

Status: accepted.

Lite stores nothing in the browser and derives one keyed site/day visitor ID.
Session stores one random ID in `sessionStorage`. There is no second current
identity model. Product identity is reserved until consent, persistence,
deletion, and conflict semantics are decided together.

## A05. CLI metric surface

Status: accepted.

Reports are fixed commands with fixed SQL and typed parameters. The CLI and a
future server-rendered UI will share these definitions. There is no generic
filter grammar, request-selected SQL, SQL console, or dashboard metric model.

## A06. Trusted server outcomes

Status: accepted.

Browser events may describe intent and interaction, but registration, payment,
refund, attendance, and matching outcomes are authoritative only when accepted
through signed `/i`. Replay is bounded by timestamp and event IDs are
idempotent/conflict-detecting.
