# Passkey P3 evidence

Measured and accepted on 2026-07-31 for the `0.2.0` release against the exact
pins in `versions.json`.

## Implemented behavior

- `/admin/security` server-renders active passkeys and sessions in its first
  response.
- A second independent authenticator can add a passkey through the only
  additional WebAuthn JavaScript island.
- Ordinary forms rename and revoke credentials, revoke other sessions, and
  sign out with session-bound CSRF and exact configured-Origin checks.
- The last active passkey cannot be revoked.
- Registration challenges are bound to the session that requested them.
- Setup, login, and add-passkey endpoints share a bounded process-local global
  attempt window and return 429 when exhausted.
- The final Caddy dashboard vhost contains no Basic Auth, limits request bodies
  to 192 KiB, applies HSTS, exposes only `/admin` paths, and proxies to the
  loopback service.

## Real acceptance

The real on-disk/browser gate used two separate Chromium CTAP2 virtual
authenticators with resident credentials and user verification. It enrolled
both, authenticated with each independently, renamed and revoked one, refused
last-passkey removal, created and revoked other real server sessions, signed
out, and proved the revoked session was denied. The same scenario exercises
wrong origin, replay, invalid cookies, anonymous and unknown private routes,
bounded return paths, oversized bodies, throttling, and verified auth reset.

The existing server-first gates now bootstrap a real passkey session instead
of relying on Caddy Basic Auth. They passed with JavaScript disabled, all 13
report families, five native form mutations, HTMX failure fallback, no startup
API request, and the unchanged public collector.

The extracted ReleaseSafe `0.2.0` archive passed M0, M1, M2 HTTP, Chromium,
Firefox, WebKit, M3 reports, M4 lifecycle/faults, M6 server rendering, M7 HTMX,
and the complete passkey lifecycle. The rollback gate downloaded and verified
the actual published `v0.1.0` release, restored its real pre-migration v1
backup, ran its report, and started its collector successfully.

Production owner acceptance used Safari on the owner's Mac with Touch ID and
the iCloud Keychain passkey. The owner created the first credential, reached
the authenticated dashboard, signed out through the native form, completed a
fresh discoverable-credential login, and returned to the dashboard. The stored
credential reports both backup eligibility and backup state, and its last-used
time advanced during the returning login. Server-side status then reported one
active credential, one fresh active session, no active bootstrap, and the exact
`https://analytico-admin.plosca.ru` origin and RP ID.

The consumed bootstrap file was removed. A post-enrollment backup was restored
into an isolated directory and passed schema, site, event, visitor-key, and
authentication checks before the verification copy was removed.

## Measurements

| Item | Result | Budget |
| --- | ---: | ---: |
| ReleaseSafe binary | 30,144,376 bytes | informational; packaged once |
| Release archive | 30,961,342 bytes | informational |
| Passkey adapter | 8,015 bytes raw | 12 KiB raw |
| Authenticated dashboard HTML | 1,483 bytes gzip | 32 KiB gzip |
| Dashboard CSS | 936 bytes gzip | 12 KiB gzip |
| HTMX | 13,014 bytes gzip | 16 KiB gzip |
| First dashboard requests | 3 | HTML + CSS + local HTMX only |
| Startup API requests | 0 | 0 |
| RSS growth after 100 views | 136 KiB | 8 MiB |
| Slow-link first view | useful at simulated 64 KiB/s, 180 ms RTT | required |
| Maximum virtual passkey login | 138 ms | 2 seconds locally |

The Apple-specific check is necessarily manual and cannot be replaced by the
virtual-authenticator suite. Both forms of evidence are now recorded: the
repeatable multi-browser protocol lifecycle and the owner's production
Safari/Touch ID enrollment, sign-out, and returning login.
