# Analytico 0.2.1

Analytico 0.2.1 consolidates collection, owner login, security controls, and
the dashboard under one canonical origin.

## Deployment

- Canonical URL: `https://analytico.plosca.ru`
- `/` redirects to `/admin`.
- Public collection remains limited to the two tracker assets, `POST /v1/event`,
  and `GET /v1/p.gif`.
- `/admin` and `/admin/*` are authorized by Analytico's server-side passkey
  session.
- Every unknown path returns `404`; health endpoints remain loopback-only.
- The release ships one `deploy/Caddyfile` and no second dashboard vhost.

Because WebAuthn credentials are bound to an RP ID and origin, an existing
credential from a separate dashboard hostname must be reset after a verified
backup and enrolled once at the canonical host. Analytics data, site IDs,
tracker URLs, and site CSP rules do not change.

The executable, Turso metadata, DuckDB event store, systemd service, tracker,
and server-rendered UI otherwise retain their 0.2.0 behavior.
