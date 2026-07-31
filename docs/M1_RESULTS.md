# M1 durable core result

M1 establishes the product's durable domain boundary without HTTP, HTML,
in-memory database substitutes, or repository mocks.

## Shipped core

- Numbered v1 Turso metadata and initial v1 DuckDB event migrations compiled
  into the binary. M3 later adds the compatible DuckDB v2 session-boundary
  migration.
- Validated site slugs, names, exact normalized origins, paths, event/property
  identifiers, UUIDs, UTC dates, goal predicates, and two-to-eight-step
  funnels.
- Local administration for site create/list/disable/delete, origin and
  property allowlists, goal create/list/delete, funnel create/show/delete,
  direct event insertion, initialization, and store diagnostics.
- A 32-byte visitor key created once with mode `0600`.
- Keyed BLAKE3 visitor-day IDs scoped by site and UTC day, with IPv4 `/24` and
  IPv6 `/48` normalization.
- Direct DuckDB event commits followed by real process reopen verification.

## Acceptance evidence

`tests/e2e-m1.sh` launches the installed executable separately for every
operation against disposable real files. It covers:

- idempotent initialization without key replacement;
- exact origin/default-port normalization and duplicate rejection;
- malformed slug, origin, UTF-8, property, match kind, funnel length, and path
  rejection;
- all three goal/funnel match kinds;
- deterministic same-prefix pseudonyms and site/day/key/prefix separation;
- one committed event surviving close/reopen;
- exact destructive confirmation for goals, funnels, and sites;
- foreign-key cascade of relational metadata while the analytics event remains
  an explicit independently retained fact; and
- final schema versions and row counts through `doctor`.

The suite passes in Debug and ReleaseSafe. No mock store, fake database, or
in-memory acceptance path exists.

## Pinned Turso transaction observation

On this filesystem, the exact Turso `0.8.0-pre.2` pin returns
`I/O error (pwrite): quota exceeded` for the tested explicit multi-write
transactions even when ordinary writes and the same autocommit statements
succeed with ample disk space. Decision D19 records the measured workaround:
durable autocommits, synchronous compensating deletion on a returned child
failure, replayable `IF NOT EXISTS` migrations, and a future re-test on engine
upgrade.
