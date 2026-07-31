# Analytico 0.2.0

Analytico 0.2.0 replaces the temporary private-dashboard Basic Auth boundary
with one application-owned, passkey-only owner account. There is still no
password, email recovery flow, role model, identity proxy, or general user
system.

## Authentication

- One-use, expiring CLI bootstrap for the first discoverable passkey.
- Passkey-only returning login with user verification required.
- Random server-side sessions with hashed tokens, fixed 12-hour expiry, secure
  host-only cookies, exact-origin enforcement, and session-bound CSRF.
- Native sign-out, credential rename/revoke, second-passkey enrollment, other
  session revocation, and refusal to revoke the final credential.
- A server-rendered security page and dashboard; JavaScript remains limited to
  the WebAuthn ceremonies and removable HTMX enhancement.
- Verified backup/reset and prior-release rollback paths.

The protocol suite used real Turso files, real HTTP processes, Caddy, Chromium,
Firefox, WebKit, two independent virtual authenticators, and the published
0.1.0 release. Production acceptance additionally used Safari, Touch ID, an
iCloud Keychain-backed credential, native sign-out, and a fresh returning
login on the owner's Mac.

## Production deployment

- Public collector: `https://analytico.plosca.ru`
- Private dashboard: `https://analytico-admin.plosca.ru`
- `plosca.ru` site ID: `43c76c6d-1b75-4459-8b77-fcfb8a29a0c7`
- `sparkdate.love` site ID: `a394e61b-e416-4988-884f-cf301ef6c84a`

The collector hostname exposes only the versioned tracker and collection
routes. The dashboard hostname exposes only `/admin` routes. Both applications
ship the content-addressed tracker, a no-JavaScript pixel, and CSP permission
for the public collector. Live production writes returned `204` and read back
through the on-demand DuckDB reports.

The VPS runs one loopback-bound Zig process with embedded Turso metadata and
DuckDB analytics. Plausible's former containers remain stopped; no ClickHouse,
PostgreSQL, Redis, analytics container, or background aggregation worker is
required.
