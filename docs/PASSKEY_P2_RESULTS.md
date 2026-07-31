# Passkey P2 evidence

Measured on 2026-07-31 against the exact compiler, storage, browser, and
WebAuthn dependency pins recorded in `versions.json`.

P2 makes the Turso-backed passkey session the authorization boundary for the
entire private application:

- an unconfigured installation fails every `/admin` request closed with 503;
- the public allowlist is limited to setup, login, their WebAuthn endpoints,
  the content-hashed passkey adapter, and the login/setup stylesheet;
- anonymous navigations receive a bounded same-site return redirect while
  enhanced and unsafe requests receive 401 without dashboard state;
- passkey login rotates to a fresh HttpOnly, SameSite=Strict session token;
- dashboard forms use the session's independent CSRF secret and compare the
  request Origin to the configured canonical origin;
- native logout revokes the server-side session, expires the cookie, and is
  deliberately not intercepted by HTMX;
- the dashboard remains complete server-rendered HTML and ordinary forms, with
  no startup JSON request or client-side state model.

The real-browser acceptance scenario now performs setup, logout, discoverable
passkey login, goal and funnel mutations with JavaScript disabled, another
native logout, denial of the revoked token, and another passkey login. It also
checks anonymous data isolation, invalid cookies, unknown private routes,
malicious return paths, exact-origin rejection, cookie attributes, bootstrap
fragment removal, wrong-origin WebAuthn rejection, and challenge replay.

The same real-process scenario proves the public collector still accepts an
event while admin auth is deliberately unconfigured. Debug and ReleaseSafe
execute the scenario against real Turso and DuckDB files and Chromium's CTAP2
virtual authenticator with resident credentials and user verification.

P3 remains the deployment gate: it adds the security page, second-passkey and
session controls, final operational rehearsal, measurements, and production
cutover.
