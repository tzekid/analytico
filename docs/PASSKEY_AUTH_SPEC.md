# Passkey-only owner authentication

Status: accepted and shipped in `0.2.0`; P1–P3 plus owner Apple-platform
acceptance are complete.

This specification replaces the current Caddy Basic Auth dashboard gate with
one application-owned WebAuthn passkey gate. It intentionally serves one owner,
not a user-management product. Touch ID, Face ID, a device passcode, a hardware
security key, or a synced passkey provider can satisfy the gate. There is no
password, username prompt, email recovery, TOTP, invitation system, role model,
or open registration.

The public event collector remains unauthenticated and unchanged. Every auth
record belongs in Turso metadata; DuckDB remains append-only analytics storage
and is never opened by a second process.

## Current state

Analytico `0.1.0` has basic security but no application login page:

- the Zig service binds to loopback;
- a separate Caddy dashboard hostname exposes only `/admin` routes;
- Caddy Basic Auth challenges before proxying;
- modifying forms enforce exact-origin and CSRF checks;
- all authorization is server-side and the HTML dashboard works without
  JavaScript.

Basic Auth is an adequate temporary owner gate, but its credential lifetime is
browser-owned. Analytico cannot show a real login page, revoke a browser
session, or provide a reliable logout action. Passkeys solve those concrete
problems without introducing passwords or a general account system.

## Decision

| Candidate | Benefits | Costs | Decision |
| --- | --- | --- | --- |
| Retain Caddy Basic Auth | Already shipped; no application auth state | Password prompt, awkward Apple-device use, no application logout or revocation | Keep only until cutover |
| Passkey-only auth inside Analytico | Touch ID/Face ID flow, phishing-resistant origin binding, revocable sessions, one-button login | A small unavoidable JavaScript island and security-sensitive verifier/session code | **Recommended** |
| Put an identity proxy in front | Mature login surface | Another service, another configuration/state model, and unnecessary multi-user machinery | Reject for this deployment |
| Share Cloudio sessions or proxy its identity | One apparent login | Couples release, availability, cookie, origin, and authorization boundaries | Reject |
| Immediately extract Cloudio auth as a shared package | May reduce duplicated code | Freezes an abstraction before the second integration proves identical boundaries | Defer |

Port the narrow, already exercised Cloudio WebAuthn semantics into Analytico.
Do not copy Cloudio's unrelated API framework. Once both concrete applications
have passed their real browser suites, compare the implementations and extract
only code whose semantics are actually identical.

The permanent production gate is the passkey session. Caddy still terminates
TLS, isolates the dashboard hostname, applies headers and request limits, and
proxies to loopback, but its Basic Auth directive is removed after acceptance.

## Product and UX contract

### First owner setup

1. The owner stops the service, runs the normal verified backup, and configures
   the exact dashboard origin with `analytico auth configure`.
2. `analytico auth bootstrap --ttl 10m` prints a one-use setup URL. The token is
   carried in the URL fragment so it is not sent in the first HTTP request.
3. `/admin/setup` immediately removes the fragment from browser history and
   sends the token only in `X-Analytico-Bootstrap` during the setup ceremony.
4. The page asks the browser to create a discoverable credential with user
   verification required and attestation set to `none`.
5. Successful verification consumes the bootstrap token, records the first
   passkey, creates a server-side session, and redirects to `/admin`.

The database stores only the SHA-256 hash of a bootstrap token. A token is
single-use, defaults to ten minutes, may never exceed one hour, and a new token
invalidates the previous unused token.

### Returning login

`GET /admin/login` returns a small, complete HTML page with one primary action:
**Use a passkey**. Supporting copy names Touch ID, Face ID, device passcode, and
hardware security keys. Pressing the button starts a discoverable-credential
authentication ceremony; no username is required. Success rotates into a new
session and returns only to a validated same-origin `/admin` path.

If JavaScript or WebAuthn is unavailable, the server still returns useful HTML
that honestly explains the requirement and points to the local recovery
command. It never exposes the dashboard. This is the one justified browser-only
island: WebAuthn itself is a browser API. Every authenticated report,
navigation link, filter, and ordinary form retains the existing HTML-first and
HTMX-optional behavior.

### Security page and logout

`GET /admin/security` server-renders the active passkeys, labels, creation and
last-use times, and current sessions known to the server. It provides:

- add another passkey (the only other JavaScript/WebAuthn ceremony);
- rename a passkey with an ordinary POST form;
- revoke a passkey with an ordinary POST form;
- revoke other sessions with an ordinary POST form;
- sign out with an ordinary POST form.

The server refuses to revoke the last active passkey. It does not guess device
names from user-agent strings. Synced/passkey-backup flags may be displayed as
standards-derived facts, not as proof that recovery will succeed.

## Configuration

`analytico auth configure <data-dir> <dashboard-origin>` validates and stores
the canonical origin and a same-host relying-party ID in Turso. For example:

```sh
analytico auth configure /var/lib/analytico https://analytics.example.com
```

The accepted first version derives the RP ID from the origin host. Supporting a
parent-domain RP ID is deferred until a real cross-subdomain requirement
exists. HTTPS is mandatory except for the WebAuthn loopback development
exceptions (`localhost`, `127.0.0.1`, and `[::1]`). The server refuses to start
private auth routes when configuration is absent, malformed, or differs from
the expected origin stored during credential registration.

`analytico auth status <data-dir>` reports configuration, active credential
count, active session count, and bootstrap expiry without printing sensitive
values.

## HTTP boundary

All routes exist only on the private dashboard hostname. Caddy continues to
return `404` for them on the public collector hostname.

| Method and path | Response | Authentication |
| --- | --- | --- |
| `GET /admin/login` | Complete HTML login page | Anonymous only; authenticated requests redirect to `/admin` |
| `GET /admin/setup` | Complete HTML setup page | Active bootstrap required at ceremony time |
| `POST /admin/auth/setup/options` | WebAuthn JSON options | Valid bootstrap header; rate limited |
| `POST /admin/auth/setup/verify` | Verification result and session cookie | Valid bootstrap header and challenge |
| `POST /admin/auth/login/options` | WebAuthn JSON options | Anonymous; rate limited |
| `POST /admin/auth/login/verify` | Verification result and session cookie | Valid challenge; rate limited |
| `POST /admin/logout` | Redirect and expired cookie | Session, exact origin, CSRF |
| `GET /admin/security` | Complete HTML security page | Session |
| `POST /admin/security/passkeys/options` | WebAuthn JSON options | Session, exact origin, CSRF |
| `POST /admin/security/passkeys/verify` | Add-passkey result | Session, exact origin, CSRF, challenge |
| `POST /admin/security/passkeys/rename` | Redirect | Session, exact origin, CSRF |
| `POST /admin/security/passkeys/revoke` | Redirect | Session, exact origin, CSRF |
| `POST /admin/security/sessions/revoke` | Redirect | Session, exact origin, CSRF |

The WebAuthn JSON routes are ceremony adapters, not a second application state
model and not a duplicate report API. They are the only JSON startup requests,
and only after an explicit login/setup/add-passkey action. All known security
page state arrives in its first HTML response.

Anonymous private requests redirect to `/admin/login` for navigational HTML and
return a small `401` for enhanced/ceremony requests. Unknown private routes use
the same external behavior before authentication so they do not disclose route
existence. A `return` value is length-bounded and accepted only when it is an
absolute-path reference under `/admin`; schemes, hosts, backslashes, encoded
separator tricks, and protocol-relative paths are rejected.

## Turso data model

Numbered replayable migrations add these relational records to the metadata
store:

- `auth_owner`: singleton ID, random stable WebAuthn user handle, display name,
  creation time;
- `auth_config`: singleton exact origin, derived RP ID, creation/update times;
- `auth_credentials`: credential ID, owner ID, public key, algorithm, signature
  counter, transports, AAGUID, backup eligibility/state, owner label,
  created/last-used/revoked times;
- `auth_challenges`: random challenge, purpose, owner/session or
  bootstrap binding, expiry, used time, creation time;
- `auth_sessions`: session-token hash, owner ID, CSRF token, fixed expiry,
  last-seen and revoked times;
- `auth_bootstrap`: singleton token hash, expiry, creation and consumed times.

Credential IDs and challenges have unique constraints. Foreign keys and
singleton checks enforce the one-owner model. Expired challenges, bootstrap
records, revoked sessions, and old revoked credentials are pruned during
bounded auth operations; no background process is introduced. Counts and input
sizes are bounded before allocation or database work.

No credential private key, biometric, device passcode, raw session token, or raw
bootstrap token reaches either database. DuckDB receives no auth tables.

The WebAuthn challenge is stored in clear text until its short expiry because
it is public protocol entropy returned to the browser and the verifier needs
the exact value. It is not an authenticator, session secret, or recovery secret.

## WebAuthn verification contract

P1 starts with the exact pins already exercised by Cloudio on Analytico's exact
Zig compiler:

- `passcay` `3.1.0`, package hash
  `passcay-3.1.0-ckLGcmQzBAC1vu-rL_dmObKye8Fbs8qHsFUeDtRAr1ni`;
- `zbor` `0.21.2` at commit
  `658c1c0ec607557b52d2e2a42acbfad31058ecee`, package hash
  `zbor-0.21.2-kr-CoPF7AwAU2EqWqJzgxd1jHhpaaRBK0_c1LCgiwTbn`.

They remain prospective dependencies until P1 integrates them and passes the
real acceptance gates; implementation records the accepted URLs, versions, and
hashes in `versions.json`. An upgrade or replacement requires a new measured
decision. A narrow adapter must verify:

- exact challenge, ceremony type, configured origin, and RP ID;
- the authenticator signature and registered public key;
- user presence and user verification on registration and login;
- `crossOrigin` is absent/false and `topOrigin` is absent;
- a discoverable credential and stable owner user handle;
- attestation preference `none` and accepted ES256/RS256 algorithms;
- internally consistent backup-eligible and backup-state flags;
- one-use, purpose-bound, short-lived challenges even after failed verification;
- bounded decoded sizes before CBOR or cryptographic work.

Initial bounds are 16 KiB client data, 128 KiB attestation object, 8 KiB each
for authenticator data and signature, and 1,024 bytes for credential IDs. Those
are limits, not allocation targets.

Signature counters are recorded as a risk signal. A zero or non-monotonic
counter from a synced passkey is not rejected by itself because multi-device
credentials do not necessarily provide one monotonic global counter. Any other
verification failure is generic externally and specific only in privacy-safe
internal error categories.

The passkey browser adapter is a small content-addressed local asset. It only
converts bounded base64url values, calls `navigator.credentials.create()` or
`navigator.credentials.get()`, submits the result, and presents the server's
bounded error state. It contains no router, template system, cached domain
state, analytics call, or third-party code.

## Sessions and request security

Successful setup/login creates a random 32-byte session token and stores only
its SHA-256 hash. The cookie is:

```text
__Host-analytico_session=<token>; Path=/; Secure; HttpOnly; SameSite=Strict
```

It has no `Domain` attribute. Production sessions have a fixed 12-hour
expiration; ordinary requests do not silently extend it. Authentication rotates
the token, logout/recovery revokes it server-side, and logout also sends an
expired cookie. Active sessions are bounded and the oldest expired/revoked rows
are pruned.

Every unsafe authenticated request requires both an exact configured `Origin`
and a session-bound CSRF token. Native forms receive a hidden token in their
server-rendered HTML; the WebAuthn adapter sends the same value in a header.
Login uses its single-use challenge rather than a pre-existing session. Setup
requires both the one-use bootstrap secret and its challenge.

Caddy retains TLS, loopback proxying, body/time limits, HSTS, a self-only CSP,
`frame-ancestors 'none'`, and a Permissions Policy that allows public-key
credentials only for the same origin. Login, setup, security, and auth responses
are `Cache-Control: no-store` and cannot be framed. Analytico trusts forwarded
scheme/host information only from its loopback Caddy boundary.

Auth endpoints use small process-local token buckets for global setup/login
attempts. Client-address limits may be added only when the proxy trust chain is
explicitly configured; a forged forwarding header is never accepted directly.

Logs never include WebAuthn request/response payloads, challenges, signatures,
public keys, credential IDs, user handles, cookies, session or CSRF tokens,
bootstrap tokens, or complete setup URLs.

## Recovery

There is deliberately no network recovery route. The owner with shell and data
directory access can run:

```sh
analytico auth reset /var/lib/analytico /safe/new-backup --confirm
```

The service must be stopped. The command first performs and verifies the normal
matched Turso/DuckDB backup into a new destination, then removes credentials,
sessions, challenges, and bootstrap state while preserving analytics data and
the configured origin. It never creates or prints a new bootstrap token
implicitly. The owner separately runs `auth bootstrap` and enrolls again.

This recovery boundary is intentionally equivalent to root/data-directory
control; adding email, security questions, recovery codes, or support bypasses
would make a personal installation less simple without removing that ultimate
boundary.

## Cutover and rollback

1. Create and verify a full pre-auth backup; retain the `0.1.0` binary and Caddy
   configuration.
2. Deploy the auth-capable binary and run its Turso migration while the service
   is stopped.
3. Configure the exact HTTPS dashboard origin.
4. Temporarily retain Caddy Basic Auth while starting the new binary.
5. Generate one bootstrap URL, enroll the owner's synced passkey, add a second
   independent passkey if available, then prove logout and fresh login.
6. Remove only the Caddy `basic_auth` directive, validate/reload Caddy, and prove
   that an anonymous browser reaches `/admin/login` but not dashboard data.
7. Verify public collection and every report before deleting the old credential
   hash or backup.

During rollout, Basic Auth and the passkey gate are intentionally both present.
After acceptance, only the passkey session remains. Rollback restores the
matched pre-auth backup, prior binary, and prior Caddy Basic Auth configuration;
the public collector hostname and tracker snippets do not change.

## Implementation milestones

### P1. Durable verifier and owner bootstrap

Status: implemented and accepted. Evidence is in
[`PASSKEY_P1_RESULTS.md`](PASSKEY_P1_RESULTS.md).

Implement exact dependency pins, Turso migrations, configuration/status,
bounded WebAuthn verification, bootstrap/reset commands, and the setup page.

Definition of done:

- a migration from a real `0.1.0` data directory preserves all sites, goals,
  funnels, events, and report results;
- setup succeeds through a real browser virtual authenticator and rejects wrong
  origin/RP ID, expired/replayed/wrong-purpose challenges, invalid signatures,
  missing user verification, cross-origin responses, and oversized inputs;
- bootstrap storage contains only a hash, is one-use, and is absent from request
  URLs, browser history, logs, and error pages after the setup page loads;
- recovery creates and verifies a real matched backup before resetting auth;
- Debug and ReleaseSafe checks pass with no new long-running process.

### P2. Login, session, and server-first integration

Status: implemented and accepted. Evidence is in
[`PASSKEY_P2_RESULTS.md`](PASSKEY_P2_RESULTS.md).

Implement the login page, fixed server-side sessions, route authorization,
logout, CSRF migration, and the minimal local WebAuthn browser adapter.

Definition of done:

- an anonymous real browser cannot read any dashboard state and a valid passkey
  can log in, navigate, modify goals/funnels, log out, and is denied afterward;
- cookie attributes, token hashing/rotation, fixed expiry, revocation, exact
  origin, CSRF, return-path validation, and anonymous route behavior pass
  real-HTTP end-to-end scenarios;
- with JavaScript disabled, login is an honest inaccessible state while all
  already-authenticated dashboard HTML, links, filters, and ordinary forms
  remain complete without JavaScript;
- no report data is fetched as startup JSON and the first authenticated view
  stays within the existing HTML/CSS/JS/request/allocation budgets;
- the public collector, tracker, pixel, health checks, and CLI reports are
  byte/semantics compatible except for explicitly versioned headers;
- Debug and ReleaseSafe checks pass.

### P3. Credential management and production cutover

Status: complete. Automated acceptance and the production Apple-platform check
passed. Evidence is in
[`PASSKEY_P3_RESULTS.md`](PASSKEY_P3_RESULTS.md).

Implement the server-rendered security page, second-passkey enrollment,
rename/revoke/session controls, hardened Caddy policy, operational docs, and the
rehearsed cutover.

Definition of done:

- a real browser adds two passkeys, logs in with each, renames one, revokes one,
  refuses last-passkey removal, revokes other sessions, and signs out;
- an actual Safari/Apple-device acceptance check proves Touch ID or Face ID and
  the owner's iCloud-synced passkey on the intended devices; this manual
  platform check is recorded rather than mocked;
- the final Caddy configuration has no Basic Auth, exposes auth routes only on
  the dashboard hostname, and passes TLS/header/body/time-limit checks;
- the complete backup, bootstrap, lost-passkey reset, cutover, and rollback
  runbooks are performed against disposable on-disk stores and real processes;
- measured RSS, binary/assets, first-response bytes, requests, and login latency
  are recorded and accepted against explicit budgets;
- the release archive is reproducible and checksummed, Debug and ReleaseSafe
  checks pass, and the result is tagged only after owner acceptance.

No in-memory mock repository or isolated fake auth service counts toward these
definitions. Small deterministic parser/crypto vectors may aid development,
but acceptance runs the real binary, real Turso file, real Caddy boundary, and
real browser ceremony.

## References

- [W3C Web Authentication Level 3](https://www.w3.org/TR/webauthn-3/)
- [Apple passkeys overview](https://developer.apple.com/passkeys/)
- [MDN `PublicKeyCredential`](https://developer.mozilla.org/en-US/docs/Web/API/PublicKeyCredential)
