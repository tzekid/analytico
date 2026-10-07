# Milestone 0.3: the web workspace on Mac, iPhone and iPad

Status: plan. Nothing here is built yet.

Analytico gets native apps for macOS, iOS and iPadOS, next to the web
workspace, and the server gains what native apps need: instance discovery,
native sign-in, report contracts, a live stream and end-to-end encrypted
push. Windows, Linux and Android follow in 0.4
([MILESTONE-0.4.md](MILESTONE-0.4.md)) on the same server contract.

Rules for every item: YAGNI, less code wins, never at the cost of a
feature, UX or performance. Every item names its verification, end to end
first. Analytical meaning (visitors, sessions, attribution, revenue,
consent) is computed only on the server; the apps present it.

---

## Part A — Scope

### A1. What the Apple apps do

Read, watch and get notified:

1. **Set up**: enter an instance address, have it checked, sign in through
   the instance's own passkey page (part D).
2. **Sites**: the sites the account can see, with today's visitors.
3. **Reports**: Overview, Pages (with the page sheet), Sources and
   Campaigns, Audience, Paths, Events and Goals, Revenue, Performance,
   Errors, Retention, all with period, comparison and filters.
4. **Live**: people online now and the latest page views.
5. **Notes**: read chart notes; add one; keep or dismiss a drafted
   anomaly note.
6. **Notifications**: alert thresholds, goal completions and anomaly notes.
7. **Glanceable surfaces**: a widget (today's visitors and the 7-day
   trend) on the home and lock screen and the Mac desktop, the menu bar on
   macOS, and Siri and Shortcuts actions.
8. **Open in workspace**: every screen links to the identical web view.

Not in 0.3, and reachable through "Open in workspace": settings, team,
consent, integrations, imports, backups, People, replays and the heatmap
overlay. Replays and heatmaps are browser features (rrweb and the live
page), so the apps hand them to the browser.

### A2. Platforms and toolkit

- **iOS and iPadOS 26+, macOS 26+**: one SwiftUI multiplatform target,
  AppKit or UIKit only where SwiftUI falls short. Swift 6 with strict
  concurrency; no third-party dependencies.
- The minimum is one release back, so the current SwiftUI APIs and design
  apply without compatibility branches.

### A3. What the web workspace gains

- Settings → Devices: every signed-in app with its name, platform and
  last use, and "Sign out" (part B2).
- The consent page an app opens when it signs in (part B2).
- Push as a channel for alerts, goals and anomaly notes (part B6).

---

## Part B — Server and web workspace

### B1. Instance discovery

`GET /.well-known/analytico`, public, cached for a minute:

```json
{
  "product": "analytico",
  "name": "Plosca analytics",
  "version": "0.3.0",
  "api": { "min_client": "0.3.0", "base": "/api/v1" },
  "oauth": { "issuer": "https://analytics.example.com", "authorization_endpoint": "…/oauth/authorize", "token_endpoint": "…/oauth/token" },
  "sign_in": ["passkey", "google", "chatgpt"],
  "setup_complete": true
}
```

The setup screen uses it to tell "not reachable", "not Analytico",
"needs an update" and "not set up yet" apart (part D). It reveals nothing
a visitor of the sign-in page does not already see.

Verification: `tests/cli.mjs` fetches it on a fresh and on a set-up
instance; the version comes from `cli.version`.

### B2. Native sign-in (OAuth 2.1 with PKCE)

The MCP connector already implements authorization codes, PKCE, refresh
rotation and grants (`src/web/mcp.zig`). Native apps reuse that machinery
with three changes:

- **A registered public client**, `analytico-apple`, created by the
  server, no dynamic registration needed. 0.4 adds one per platform.
- **Redirect**: `analytico://oauth`, used by `ASWebAuthenticationSession`
  on both macOS and iOS. Today's validation accepts HTTPS and loopback
  only; the custom scheme is allowed for the registered client only.
- **A separate scope, `app:read`** (plus `app:notes` for notes and note
  decisions). MCP grants keep `analytics:read`; neither upgrades into the
  other. `/api/v1` accepts both `an_…` API keys and app access tokens
  through one bearer check.

The consent page names the device ("MacBook Pro, macOS app") and
Settings → Devices lists every signed-in device with "Sign out", which
revokes its refresh token and push registration.

Verification: `tests/workspace.mjs` runs the full code flow with a
loopback redirect, uses the token on `/api/v1`, refreshes it, revokes it
from Settings and sees the next call fail with 401.

### B3. Report contracts and display strings

- `analytico catalog --json` and `GET /api/v1/catalog`: every report with
  its parameters and its **output schema**, meaning field names, types,
  units, currency and nullability.
- Every report response gains an `effective` block (site, period,
  comparison, filters, generated at, freshness such as "summaries until
  14:05" or "updated daily") and an `availability` note per section
  ("Unavailable in Lite mode", never zero).
- Numbers that the workspace formats gain a `display` twin: changes
  ("+12.4%", "6.4×"), durations, money, percentages and dates. The strings
  come from the same functions as the workspace (`html.Change` and
  friends), so every surface shows identical text.
- `tests/contracts/`: one reference response per report for a seeded
  fixture site, checked byte for byte by `tests/cli.mjs`. Client test
  suites load the same files.

Verification: the contract test fails when a report's fields change
without an updated fixture.

### B4. Missing reads and two writes

Native screens need reads the catalog does not have yet: `retention`
(served from the daily cache), `notes` (chart notes and drafted ones),
`live` (online now and the last 20 page views), and `sites` with today's
visitors. Writes: add a note, keep or dismiss a drafted note. They call the
same functions, permission checks and audit entries as the workspace
forms.

### B5. Live stream for apps

`GET /api/v1/sites/{slug}/live` as server-sent events for app tokens, on
the existing broadcaster (its 64-stream cap stays; apps count against
it). Events: `online` (count), `view` (path, source, country) and `stale`
(report names whose numbers changed: new rollup cut, new note). Clients
refresh only the visible report on `stale`.

### B6. Devices and push

Self-hosted instances cannot hold Apple's or Google's push credentials,
so:

- **`devices` table**: account, client, name, push token, push platform,
  the device's P-256 public key and auth secret, last seen.
- **Encrypted payloads**: the instance encrypts each notification to the
  device's key with RFC 8291 (`aes128gcm`, as Web Push does), using the
  Zig standard library's P-256, HKDF and AES-GCM. Only the device can read
  it.
- **`relay/`**: a small separate Zig service, run by the app publisher,
  that forwards ciphertext to APNs (HTTP/2 with an ES256 token; needs a
  minimal HTTP/2 client). It stores nothing and logs no payloads. Google,
  Microsoft and UnifiedPush routes come in 0.4.
- Alerts, goal completions and anomaly notes get "push" as a channel next
  to Slack and webhooks.

Verification: a stand-in relay in the harness receives a payload that
decrypts with the device's private key to the expected alert; revoking
the device stops delivery.

---

## Part C — The Apple apps (`clients/apple`)

### C1. Project

- `clients/apple/project.yml` generates the Xcode project with XcodeGen,
  so the repository holds no `.pbxproj` merge conflicts.
- **AnalyticoKit** (a local Swift package): the API client
  (`URLSession`, async/await, cancellation, coalescing of identical
  requests), models generated from `/api/v1/catalog`, OAuth with PKCE, the
  Keychain store shared through an app group, the bounded response cache,
  the live stream and view state with its workspace URL form.
- **Analytico** (the app, macOS and iOS), **AnalyticoWidgets** (WidgetKit),
  **AnalyticoIntents** (App Intents, in the app target), and
  **NotificationService** (decrypts pushes).

### C2. Screens

- Setup, sign-in and site choice (part D).
- Sidebar navigation on macOS and iPad, a tab bar on iPhone: Overview,
  Pages, Acquisition, Audience, Paths, Events, Revenue, Performance,
  Errors, Retention, Live.
- The period, comparison and filter bar mirrors the workspace; changes
  update the URL form, so "Open in workspace" and incoming
  `analytico://` links round-trip.
- Charts with Swift Charts from the series in the report responses;
  values come with the server's display strings.
- Notes on the Overview chart: read, add, keep or dismiss drafts.
- macOS: a `MenuBarExtra` with people online now for a chosen site,
  keyboard shortcuts matching the workspace (⌘K search, ⌘1–⌘9 reports),
  and multiple windows.

### C3. Glance and system integration

- WidgetKit: today's visitors and a 7-day sparkline, small and medium,
  lock screen on iPhone, desktop on macOS; refreshed from the cache and
  on push.
- App Intents: "Visitors today on {site}", "Open {report} for {site}",
  usable from Siri, Shortcuts and Spotlight.
- Notifications through the relay; the Notification Service Extension
  decrypts the payload with the device key held in the Keychain.

### C4. Tests

- AnalyticoKit: XCTest against the contract fixtures (`tests/contracts/`)
  and, end to end, against a real instance started by the harness.
- XCUITest on iOS and macOS: setup → sign-in (against a test instance) →
  site choice → Overview; the "not Analytico" error against a stand-in.
- Accessibility: a VoiceOver walk-through of every screen before release.
- Idle: Instruments shows no timers or redraws with the app open and idle.

---

## Part D — The setup flow (the apps' first screen)

The only first-run screen a native app has, designed in the Analytico Sketch
document (page "v4 · Apps · Setup", desktop and phone).

1. **Address.** One field: "Your Analytico address", placeholder
   `analytics.example.com`. Accepts a bare host, a full URL or a pasted
   workspace link; normalised to `https://host[:port]`. `http://` is only
   accepted for `localhost` and `.local` (development), with a warning.
2. **Check**, as the person types (debounced) or on Continue:
   - DNS and connection, then TLS: "Can't reach analytics.example.com" or
     "The certificate for … is not valid";
   - `GET /.well-known/analytico`: "This address isn't an Analytico
     instance" for anything else;
   - `api.min_client` against the app version: "This instance runs
     0.2. Ask its owner to update to 0.3 or later";
   - `setup_complete`: "This instance isn't set up yet. Open it in a
     browser to create the first account."
3. **Instance card.** Name, host, version and the sign-in methods,
   with a green "Analytico 0.3.0 · ready".
4. **Sign in.** "Continue in browser" opens the instance's own sign-in
   page in an `ASWebAuthenticationSession` sheet (passkey, Google or ChatGPT, as configured); the redirect brings
   the person back signed in.
5. **Choose a site** (skipped when there is one): the list with today's
   visitors; then the Overview.

Later: "Add another instance" in the account menu; every screen keeps
the instance and site in its title.

Verification: the XCUITest suites walk the happy path against the
harness server and the "not Analytico" error against a stand-in.

---

---

## Part E — Sequencing

Sizes: S is days, M about a week, L several weeks. Each phase ends with
its verification green, deployed to dev and prod, and pushed.

| Phase | Contents | Exit criterion | Size |
|---|---|---|---|
| 1. Server and web | B1–B5, Settings → Devices | Contract fixtures green; the native sign-in flow works end to end in `workspace.mjs` | L |
| 2. Apple app | C1, C2, part D | XCUITest setup → Overview on iOS and macOS; every report screen against the load-test site | L |
| 3. Glance | C3 widgets, menu bar, App Intents | Widget and menu bar show live numbers; Shortcuts runs "Visitors today" | M |
| 4. Push | B6, the relay, the notification extension | An alert reaches a real iPhone and Mac, encrypted end to end | M |
| 5. Release 0.3 | TestFlight and App Store, a notarized Mac build, docs, the tour extended to app screenshots | Both apps install from TestFlight and pass the setup checklist | M |

---

## Part F — Repository layout

```text
analytico/
  src/                server
  relay/              push relay (Zig, its own build step), phase 4
  clients/apple/      project.yml, AnalyticoKit, app, widgets, extension
  tests/contracts/    reference responses shared by every client
```

---

## Part G — Decisions made here (say if any is wrong)

1. Architecture A: a native toolkit per platform, the web workspace
   unchanged. 0.3 ships the Apple apps; 0.4 ships Windows, Linux and
   Android.
2. iOS, iPadOS and macOS 26 or later; SwiftUI; no third-party
   dependencies.
3. No local summary replica in 0.3; a bounded response cache instead.
4. Display strings come from the server; the apps do not re-implement
   number formatting.
5. Push through a publisher-run relay with end-to-end encryption.
6. Settings, team and administration stay web-only.

## Sources

- [RFC 8291: Message Encryption for Web Push](https://www.rfc-editor.org/rfc/rfc8291)
- [ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)
- [RFC 8252: OAuth 2.0 for Native Apps](https://www.rfc-editor.org/rfc/rfc8252)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
