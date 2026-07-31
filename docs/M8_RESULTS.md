# M8 optional Cloudio-integration evidence

Measured on 2026-07-31 with ReleaseSafe Analytico and an isolated ReleaseSafe
Cloudio candidate built from exact commit
`cad77b48119cdedbc1b1370067141a07c9b5dc06`.

## Decision

Select candidate 1: an optional ordinary Cloudio navigation link to the
standalone Analytico dashboard. Keep it unapplied until the owner wants the
affordance. Candidate 2 combines releases, authentication, database lifecycle,
and failure domains for no useful reduction in latency at this traffic.
Candidate 3 adds an upstream request, timeout/failure rendering, and a signed
identity contract without improving the analytics product.

The exact candidate code is stored in
`integrations/cloudio/standalone-link.patch`. The gate applies it only to an
archive of the pinned Cloudio revision. It never edits the sibling Cloudio
worktree.

## Real-process acceptance

The gate used:

- real on-disk Cloudio SQLite, Analytico Turso, and Analytico DuckDB files;
- the real Cloudio and Analytico executables;
- real loopback HTTP and Caddy;
- a real Chromium virtual authenticator and Cloudio passkey enrollment;
- Analytico Caddy Basic Auth; and
- a JavaScript-disabled Chromium context for all product navigation.

| Observation | Result |
| --- | ---: |
| Cloudio first response | 16.6 ms |
| Analytico first response after following link | 961.3 ms |
| Analytico requests during Cloudio first view | 0 |
| Cloudio response with Analytico stopped | complete `200` |
| Writable `events.duckdb` owners | 1, Analytico |
| Forwarded identity/session | none |
| Startup API waterfall | none added |

The latency values are single local observations, not percentile claims.

The no-JavaScript browser followed the ordinary external link, answered the
independent Basic Auth challenge, rendered the seeded overview, and navigated
to the pages report. Cloudio required its own enrolled passkey before rendering
the link. Each owning server therefore continued to enforce its authorization
boundary.

## Failure and rollback

After Analytico stopped, its Caddy route returned `502`, while a fresh
authenticated Cloudio request still returned a complete server-rendered `200`
page and made no upstream analytics request.

The gate then restarted Analytico, removed only the optional URL, and restarted
Cloudio. The Analytics link disappeared and direct standalone Analytico still
returned `200`. No database, migration, shared abstraction, session contract,
or deployment component had to be unwound.
