# Passkey P1 evidence

Measured on 2026-07-31 against the exact Zig, Turso, Passcay, zbor, DuckDB,
and Chromium pins recorded in `versions.json`.

P1 adds the durable owner-auth boundary without changing public collection or
DuckDB ownership:

- metadata schema v2 adds one-owner auth configuration, credential, challenge,
  session, and bootstrap records in Turso;
- `auth configure`, `auth status`, `auth bootstrap`, and guarded `auth reset`
  are real CLI operations;
- setup is complete server-rendered HTML plus one 4,323-byte local WebAuthn
  adapter;
- Passcay requires user presence and user verification and zbor restricts COSE
  keys to ES256 or RS256;
- raw session and bootstrap tokens are never stored; the setup fragment is
  removed before any network request.

`zig build e2e-passkey-p1` passed in Debug and ReleaseSafe. The scenario:

1. creates a real on-disk v1 metadata fixture with a configured site;
2. migrates it forward and proves the site remains readable;
3. configures `http://localhost` auth and creates a ten-minute bootstrap URL;
4. starts the real loopback HTTP service;
5. uses Chromium's CTAP2 virtual authenticator with resident credentials and
   user verification enabled;
6. enrolls the passkey, receives an HttpOnly/SameSite=Strict session, and proves
   no request contains the fragment;
7. proves one credential, one active session, and a consumed bootstrap;
8. rejects an invalid bootstrap header, an oversized 200,000-byte auth body,
   an otherwise valid CTAP2 registration made at the wrong origin, and replay
   of the consumed failed-verification challenge;
9. scans the actual Turso file for the raw bootstrap token;
10. creates and verifies the normal matched Turso/DuckDB/key backup before auth
   reset, restores it, and runs `doctor` against the restored stores;
11. proves reset preserves the configured origin but removes all credentials,
    sessions, challenges, and bootstrap state.

The pre-existing M1 real-process durability scenario and M2 bounded real-HTTP
collector scenario pass against metadata v2. `zig build test` passes in Debug.
ReleaseSafe compiles and runs from the exact source-mode Turso cache. The host's
`/tmp` user quota prevented a fresh Debug Rust rebuild, so Debug validation used
the already-built exact pinned Turso SDK archive; its runtime version check
passed. A different parent-checkout Turso archive was deliberately rejected by
the runtime version guard and was not used.

No production route or Caddy authentication directive changes in P1. Basic
Auth remains the deployment gate until P2 authorization and P3 cutover pass.
