# Milestone 0.3: Analytico on every platform

Status: plan. Nothing here is built yet.

Analytico gets native applications on macOS, iOS and iPadOS, Windows,
Linux and Android, next to the web workspace. Each platform uses its own
modern UI toolkit (architecture A of the October client study: native per platform rather than one shared toolkit), and all
of them read the same server-owned reports. The web workspace stays
complete and remains the only place for settings and administration.

Rules for every item: YAGNI, less code wins, never at the cost of a
feature, UX or performance. Every item names its verification, end to end
first. Analytical meaning (visitors, sessions, attribution, revenue,
consent) is computed only on the server; clients present it.

---

## Part A — Scope and decisions

### A1. What the native apps do in 0.3

Read, watch and get notified. Concretely, on every platform:

1. **Set up**: enter an instance address, have it checked, sign in through
   the instance's own passkey page (Part E).
2. **Sites**: the sites the account can see, with today's visitors.
3. **Reports**: Overview, Pages (with the page sheet), Sources and
   Campaigns, Audience, Paths, Events and Goals, Revenue, Performance,
   Errors, Retention, all with period, comparison and filters.
4. **Live**: people online now and the latest page views.
5. **Notes**: read chart notes; add one; keep or dismiss a drafted
   anomaly note.
6. **Notifications**: alert thresholds, goal completions and anomaly notes.
7. **Glanceable surfaces**: one widget per platform (today's visitors and
   the trend), plus the menu bar on macOS and the tray on Windows and
   Linux.
8. **Open in workspace**: every screen links to the identical web view.

Not in 0.3, and reachable through "Open in workspace": settings, team,
consent, integrations, imports, backups, People, replays and the heatmap
overlay. Replays and heatmaps are browser features (rrweb and the live
page), so native apps hand them to the system browser.

### A2. Toolkit per platform

| Platform | UI | Language | Notes |
|---|---|---|---|
| macOS 14+, iOS and iPadOS 17+ | SwiftUI, AppKit/UIKit where needed | Swift | One multiplatform target with per-platform navigation |
| Windows 10 22H2+, Windows 11 | WinUI 3 (Windows App SDK 2.x) | **Zig**, see Part F | Fallback C++/WinRT if the Phase 0 spike fails |
| Linux | Qt 6.8 LTS Quick with Kirigami | C++ and QML over the Zig client core | KDE-aligned; shipped as a Flatpak on the KDE runtime |
| Android 9+ | Jetpack Compose, Material 3 | Kotlin | Glance widget |

### A3. What is shared, and what is not

- **Shared by all: the server contract.** Report output schemas,
  reference responses and display strings come from the server
  (Part B3). Every client renders `"display": "6.4×"` instead of
  re-implementing number formatting.
- **Shared by Windows and Linux: the Zig client core** (`clients/core`):
  HTTP client, OAuth with PKCE, the setup check, view state and URLs, the
  bounded cache, the live stream. Windows imports it as a Zig module;
  Linux links it through a C ABI.
- **Not shared: Swift and Kotlin clients** use URLSession and OkHttp
  directly with models generated from the catalog schema. A Zig library
  behind FFI would cost more there than the HTTP calls it wraps.
- **No local replica in 0.3.** Clients keep a bounded cache of report
  responses scoped by instance, account, site, report and view, and show
  "updated N min ago" when offline. A synced summary replica (offline
  ranges, range scrubbing) is a 0.4 candidate, decided by usage.

---

## Part B — Server foundation (this repository)

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
"needs an update" and "not set up yet" apart (Part E). It reveals nothing
a visitor of the sign-in page does not already see.

Verification: `tests/cli.mjs` fetches it on a fresh and on a set-up
instance; the version comes from `cli.version`.

### B2. Native sign-in (OAuth 2.1 with PKCE)

The MCP connector already implements authorization codes, PKCE, refresh
rotation and grants (`src/web/mcp.zig`). Native apps reuse that machinery
with three changes:

- **Registered public clients**: `analytico-apple`, `analytico-windows`,
  `analytico-linux`, `analytico-android`, created by the server, no
  dynamic registration needed.
- **Redirects**: `analytico://oauth` (all platforms) and loopback
  `http://127.0.0.1:<port>/oauth` (desktop). Today's validation accepts
  HTTPS and loopback only; add the custom scheme for these clients only.
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
  minimal HTTP/2 client), FCM v1 (OAuth service account; needs RS256
  signing) and WNS. It stores nothing and logs no payloads.
- **UnifiedPush** on Linux and on Android without Google services: the
  instance posts the same encrypted payload to the user's distributor
  directly, no relay.
- Alerts, goal completions and anomaly notes get "push" as a channel next
  to Slack and webhooks.

Verification: a stand-in relay in the harness receives a payload that
decrypts with the device's private key to the expected alert; revoking
the device stops delivery.

---

## Part C — Client core for Windows and Linux (`clients/core`)

A Zig module with a C ABI, written in the style of the server (arena per
request, bounded everything, no hidden threads):

- `Instance`: address normalisation and the discovery check (Part E).
- `Auth`: authorization URL with PKCE, loopback listener for the
  redirect, token exchange and refresh; tokens go to the platform secret
  store through a callback (Windows Credential Manager, Secret Service).
- `Api`: typed requests for the catalog reports, with cancellation and
  coalescing of identical in-flight requests.
- `Cache`: bounded in-memory LRU plus an optional on-disk snapshot of the
  last response per screen; cleared on sign-out.
- `Live`: one SSE stream per visible site, with backoff.
- `View`: period, comparison and filters, and their workspace URL form,
  so "Open in workspace" and incoming `analytico://` links round-trip.

```c
typedef struct an_client an_client;
an_client *an_open(const an_platform *platform);
int  an_check_instance(an_client *, const char *address, an_buf *json);
int  an_sign_in_url(an_client *, const char *origin, an_buf *url);
int  an_finish_sign_in(an_client *, const char *redirect);
int  an_report(an_client *, const char *view_url, an_buf *json);
int  an_live(an_client *, const char *site, an_event_fn, void *user);
void an_free(an_buf *);
```

Verification: `zig build test` in `clients/core` against the real server
executable started by the existing harness, checking the contract
fixtures.

---

## Part D — Platforms

### D1. Apple (`clients/apple`)

- One SwiftUI multiplatform target: sidebar navigation on macOS and iPad,
  tab bar on iPhone; Swift Charts drawing the series from the report
  responses.
- Sign-in with `ASWebAuthenticationSession`; tokens in the Keychain,
  shared with the widget extension through an app group.
- WidgetKit: today's visitors and a 7-day sparkline (small and medium,
  lock screen on iPhone, desktop on macOS).
- `MenuBarExtra` on macOS: people online now for a chosen site.
- App Intents: "Visitors today on {site}", "Open {report} for {site}", so
  Siri and Shortcuts can use them.
- Notifications through the relay; a Notification Service Extension
  decrypts the payload.
- Tests: XCTest for the API client against the contract fixtures;
  XCUITest for setup → sign-in (stub instance) → overview.

### D2. Windows (`clients/windows`), Zig on WinUI 3

The design and its risks are in Part F. Product scope as A1: NavigationView
with the reports, a tray icon (people online now), toast notifications
through WNS, a Windows widget (Adaptive Card) for today's visitors, tokens
in Credential Manager, charts drawn with XAML shapes from the series.

Tests: UI Automation end to end (setup → overview) driven from a small
test runner on a GitHub Actions Windows runner; development in a Windows
11 on Arm VM on the Mac (WinUI 3 and Zig both support arm64).

### D3. Linux (`clients/linux`), Qt Quick with Kirigami

- C++ is limited to a thin model layer exposing the core's results to QML
  (`QAbstractListModel` per table); views are QML with Kirigami pages.
- Charts with Qt Quick Shapes from the series. Qt Graphs is GPL or
  commercial only, so it is not used.
- Tray via StatusNotifierItem, notifications via the freedesktop D-Bus
  interface, tokens via Secret Service, push via UnifiedPush.
- Packaged as a Flatpak on the KDE runtime, so Qt is shared with other KDE
  apps and the app itself stays a few megabytes.
- Tests: Qt Quick Test for the setup screen; an end-to-end run against
  the harness server under Xvfb.

### D4. Android (`clients/android`)

- Compose with Material 3, adaptive layouts for phones, foldables and
  tablets.
- Sign-in with Custom Tabs; tokens in the Android Keystore.
- Glance widget for today's visitors.
- FCM through the relay; UnifiedPush when the user has a distributor.
- Tests: Compose UI tests for setup; the API client against the contract
  fixtures.

---

## Part E — The setup flow (first screen on every platform)

The only first-run screen a native app has, designed in the Sketch
document ("Native clients — setup", desktop and mobile).

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
   page (passkey, Google or ChatGPT, as configured); the redirect brings
   the person back signed in.
5. **Choose a site** (skipped when there is one): the list with today's
   visitors; then the Overview.

Later: "Add another instance" in the account menu; every screen keeps
the instance and site in its title.

Verification: each platform's UI test walks the happy path against the
harness server and the "not Analytico" error against a stand-in.

---

## Part F — Zig on Windows with WinUI 3 (exploration, 7 October 2026)

### F1. What was checked

- **Zig 0.17 can call WinRT.** A test program cross-compiled from macOS
  (`x86_64-windows-gnu`, 431 KB) links the WinRT API sets
  (`api-ms-win-core-winrt-l1-1-0`, `…-winrt-string-l1-1-0`), activates
  `Windows.Foundation.Uri` through its activation factory and vtable, and
  loads `MddBootstrapInitialize2` from the Windows App SDK bootstrapper.
  It was compiled, not run; the first Windows run is Phase 0.
- **Nobody ships a Zig WinRT projection.** There are generators for C#,
  C++, Rust, Swift (`swift-winui` from The Browser Company) and a dynamic
  one for JS and Python (`microsoft/dynwinrt`).
- **Microsoft does exactly this for Rust now.** `windows-reactor` in
  `microsoft/windows-rs` (preview, commits daily in October 2026) is a
  declarative WinUI 3 library that needs neither the XAML compiler nor
  Visual Studio. `windows-reactor-setup` stages a self-contained Windows
  App Runtime from the NuGet package. It is MIT/Apache-2.0 and is the
  reference for every step below.
- **The C++ route needs MSVC and MSBuild** for the XAML compiler; C#'s
  costs are measured in the October study (startup, memory, size).

### F2. What a Zig WinUI 3 app needs

| Piece | What it is | Size |
|---|---|---|
| `winmd` reader | ECMA-335 metadata tables and signature blobs (TypeDef, MethodDef, Param, InterfaceImpl, CustomAttribute) | M |
| Projection generator | `zig build winrt` emits Zig for an allowlist: `Microsoft.UI.Xaml` (Controls, Media, Shapes, Input), `Microsoft.UI.Dispatching`, `Microsoft.UI.Windowing`, `Windows.Foundation(.Collections)`, `Microsoft.Windows.AppNotifications`. Interface vtables, activation factories, events and delegates; generic interface IDs computed at comptime (the WinRT pinterface SHA-1 rule) | L |
| COM objects in Zig | Reference-counted objects implementing `IUnknown`, `IInspectable`, `IAgileObject` for delegates and event handlers | S |
| Hosting | `MddBootstrapInitialize2` for framework-dependent builds, or a build step that stages the runtime from the NuGet package like `windows-reactor-setup`; an app manifest | S |
| Application | `Application.Start` with an initialisation callback; an outer object aggregating `Application` that implements `OnLaunched` and `IXamlMetadataProvider`, forwarding to `XamlControlsXamlMetaDataProvider`, and merges `XamlControlsResources` for the default styles | M |
| UI | Controls built in code, with per-screen update functions (no binding engine, no reconciler until one is needed) | L |

### F3. Options and decision

| Option | Languages | Toolchain | Risk |
|---|---|---|---|
| **W2. Zig + generated WinRT projection** | Zig only | `zig build` | Unsupported by Microsoft; the generator is ours |
| W1. C++/WinRT shell, Zig core as a DLL | C++, Zig | Visual Studio, MSBuild | Supported; two languages and a heavy toolchain |
| W3. `windows-reactor` shell, Zig core | Rust, Zig | Cargo | Preview API; a third language |

**Decision: W2**, gated. Phase 0 must show, on Windows 11, an unpackaged
Zig executable opening a WinUI 3 window with a NavigationView, a TextBlock
updated by a Button, a toast, and the window reachable by Narrator. If the
gate fails after two weeks, fall back to W1, keeping the same
`clients/core`.

---

## Part G — Sequencing

Sizes: S is days, M about a week, L several weeks. Each phase ends with
its verification green, deployed to dev and prod, and pushed.

| Phase | Contents | Exit criterion | Size |
|---|---|---|---|
| 0. Spikes | Zig WinUI 3 window (F3 gate); SwiftUI app reading `/api/v1` with an API key; Qt Quick app linking `clients/core` | All three show the Overview of the load-test site; the Windows gate holds | M |
| 1. Server foundation | B1–B5 | Contract fixtures green; the native sign-in flow works end to end in `workspace.mjs` | L |
| 2. Apple | D1 and the setup flow | XCUITest setup → overview; VoiceOver walk-through; widget and menu bar show live numbers | L |
| 3. Push | B6, relay, Apple notifications | An alert reaches a real iPhone, encrypted end to end | M |
| 4. Windows | Projection generator, hosting, D2 | UI Automation run green on the CI runner; Narrator reaches every control | L |
| 5. Linux | `clients/core` C ABI, D3, Flatpak | Xvfb end-to-end run green; installs from the Flatpak bundle | M |
| 6. Android | D4 | Compose UI tests green; widget and push on a real device | L |
| 7. Release 0.3 | Store listings, signing, docs, the tour extended to native screenshots | Each app installs from its store or bundle and passes the setup checklist | M |

Apple comes first: it is the primary platform and its toolkit carries the
least risk. Windows comes before Linux because the gate decides the
toolchain early, and both reuse `clients/core`.

---

## Part H — Repository layout

```text
analytico/
  src/                server (unchanged layout)
  relay/              push relay (Zig, its own build step)
  clients/
    core/             Zig client core, C ABI in include/analytico.h
    apple/            Xcode project: app, widget, intents, notification extension
    windows/          Zig app, tools/winrt-gen, generated projection (committed)
    linux/            CMake, QML, Flatpak manifest
    android/          Gradle project
  tests/
    contracts/        reference responses shared by every client
```

Directories are created by the phase that needs them, not up front.

---

## Part I — Decisions made here (say if any is wrong)

1. Architecture A: native toolkit per platform, web workspace unchanged.
2. Windows in Zig on WinUI 3 (W2), behind the Phase 0 gate; C++/WinRT as
   the fallback; no C#.
3. Linux on Qt Quick with Kirigami, packaged as a Flatpak.
4. No local summary replica in 0.3; a bounded response cache instead.
5. Display strings come from the server; clients do not re-implement
   number formatting.
6. Push through a publisher-run relay with end-to-end encryption, and
   UnifiedPush where available.
7. Settings, team and administration stay web-only in 0.3.

## Sources

- [microsoft/windows-rs: windows-reactor](https://github.com/microsoft/windows-rs/blob/master/docs/crates/windows-reactor.md) and [windows-reactor-setup](https://github.com/microsoft/windows-rs/blob/master/docs/crates/windows-reactor-setup.md)
- [microsoft/dynwinrt](https://github.com/microsoft/dynwinrt)
- [thebrowsercompany/swift-winui](https://github.com/thebrowsercompany/swift-winui)
- [WinUI 3 in C++ without XAML](https://github.com/sotanakamura/winui3-without-xaml)
- [MddBootstrapInitialize2](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/win32/mddbootstrap/nf-mddbootstrap-mddbootstrapinitialize2)
- [XamlReader.Load](https://learn.microsoft.com/en-us/UWP/api/windows.ui.xaml.markup.xamlreader.load?view=winrt-22621)
- [RFC 8291: Message Encryption for Web Push](https://www.rfc-editor.org/rfc/rfc8291)
- [UnifiedPush](https://unifiedpush.org/)
