# Analytico 0.1.0

The first public release is a complete small-site Plausible replacement built
for a single low-traffic VPS.

## Included

- page views, privacy-preserving daily visitors, and sessions;
- popular, entry, and exit pages;
- referral sources and UTM campaigns;
- country, browser, operating system, and device reports;
- bounded custom events, conversion goals, and ordered funnels;
- embedded Turso metadata plus embedded DuckDB analytics;
- a bounded collector, self-hosted tracker, and no-JavaScript pixel;
- complete table, JSON, and CSV CLI reporting;
- backup, verified restore, migration, retention, export, doctor, and rollback;
- a server-rendered private dashboard whose native links/forms work without
  JavaScript; and
- an exact self-hosted HTMX 4 progressive enhancement with native fallback.

The deployment is one service process behind Caddy. It does not require
ClickHouse, PostgreSQL, Redis, Docker, a CDN, or a frontend runtime.

Use the archive checksum companion before extraction, then follow
`docs/OPERATIONS.md` for installation or `docs/CUTOVER.md` for a fresh direct
cutover from Plausible. Historical import is optional. Stopping Plausible is an
explicit owner action after acceptance.
