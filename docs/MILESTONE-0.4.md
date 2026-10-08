# Milestone 0.4: Windows, Linux and Android

Status: plan. Starts after 0.3 (web, macOS and iOS) ships.

0.4 brings the native apps of 0.3 to Windows, Linux and Android with the
same scope (0.3, part A), the same server contract and the same setup
flow. Everything server-side that these apps need already exists after
0.3, except the push routes for Google, Microsoft and UnifiedPush (part E).

Rules as in 0.3: YAGNI, less code wins, never at the cost of a feature, UX
or performance; every item names its verification, end to end first.

---

## Part A — Toolkit per platform

| Platform | UI | Language | Notes |
|---|---|---|---|
| Windows 10 22H2+, Windows 11 | WinUI 3 (Windows App SDK 2.x) | **Zig**, see part D | Fallback C++/WinRT if the phase 0 gate fails; no C# |
| Linux | Qt 6.8 LTS Quick with Kirigami | C++ and QML over the Zig client core | KDE-aligned; shipped as a Flatpak on the KDE runtime |
| Android 9+ | Jetpack Compose, Material 3 | Kotlin | Glance widget; HTTP client generated from the catalog schema, like the Swift one |

---

## Part B — Client core for Windows and Linux (`clients/core`)

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

---

## Part C — Platforms

### C1. Windows (`clients/windows`), Zig on WinUI 3

The design and its risks are in Part D. Product scope as A1: NavigationView
with the reports, a tray icon (people online now), toast notifications
through WNS, a Windows widget (Adaptive Card) for today's visitors, tokens
in Credential Manager, charts drawn with XAML shapes from the series.

Tests: UI Automation end to end (setup → overview) driven from a small
test runner on a GitHub Actions Windows runner; development in a Windows
11 on Arm VM on the Mac (WinUI 3 and Zig both support arm64).

### C2. Linux (`clients/linux`), Qt Quick with Kirigami

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

### C3. Android (`clients/android`)

- Compose with Material 3, adaptive layouts for phones, foldables and
  tablets.
- Sign-in with Custom Tabs; tokens in the Android Keystore.
- Glance widget for today's visitors.
- FCM through the relay; UnifiedPush when the user has a distributor.
- Tests: Compose UI tests for setup; the API client against the contract
  fixtures.

---

## Part D — Zig on Windows with WinUI 3 (exploration, 7 October 2026)

### D1. What was checked

- **Zig 0.17 can call WinRT.** A test program cross-compiled from macOS
  (`x86_64-windows-gnu`, 431 KB) links the WinRT API sets
  (`api-ms-win-core-winrt-l1-1-0`, `…-winrt-string-l1-1-0`), activates
  `Windows.Foundation.Uri` through its activation factory and vtable, and
  loads `MddBootstrapInitialize2` from the Windows App SDK bootstrapper.
  It was compiled, not run; the first Windows run is phase 0 below.
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

### D2. What a Zig WinUI 3 app needs

| Piece | What it is | Size |
|---|---|---|
| `winmd` reader | ECMA-335 metadata tables and signature blobs (TypeDef, MethodDef, Param, InterfaceImpl, CustomAttribute) | M |
| Projection generator | `zig build winrt` emits Zig for an allowlist: `Microsoft.UI.Xaml` (Controls, Media, Shapes, Input), `Microsoft.UI.Dispatching`, `Microsoft.UI.Windowing`, `Windows.Foundation(.Collections)`, `Microsoft.Windows.AppNotifications`. Interface vtables, activation factories, events and delegates; generic interface IDs computed at comptime (the WinRT pinterface SHA-1 rule) | L |
| COM objects in Zig | Reference-counted objects implementing `IUnknown`, `IInspectable`, `IAgileObject` for delegates and event handlers | S |
| Hosting | `MddBootstrapInitialize2` for framework-dependent builds, or a build step that stages the runtime from the NuGet package like `windows-reactor-setup`; an app manifest | S |
| Application | `Application.Start` with an initialisation callback; an outer object aggregating `Application` that implements `OnLaunched` and `IXamlMetadataProvider`, forwarding to `XamlControlsXamlMetaDataProvider`, and merges `XamlControlsResources` for the default styles | M |
| UI | Controls built in code, with per-screen update functions (no binding engine, no reconciler until one is needed) | L |

### D3. Options and decision

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

---

## Part E — Push

### E1. Turning on Apple push (from 0.3)

0.3 ships the code: device keys, RFC 8291 encryption, the relay and the
notification extension, each tested against stand-ins. Since 8 October
2026 automatic signing includes Push Notifications on `ru.plosca.analytico`,
and the relay runs on plosca as `analytico-relay.service` behind
`push.analytico.plosca.ru` with the "Analytico push" APNs key
([OPERATIONS.md](OPERATIONS.md#the-push-relay)). What is left:

- Exit: an alert, a goal and an unusual-day note reach a real iPhone and
  Mac, decrypted by the extension; signing the device out stops them.

### E2. Beyond Apple

0.3's relay speaks APNs only. 0.4 adds:

- **FCM v1** for Android with Google services: an OAuth service-account
  token signed with RS256 (the Zig standard library verifies RSA but does
  not sign; add a small CRT signer).
- **WNS** for Windows: client-credentials OAuth, then a plain HTTPS post.
- **UnifiedPush** on Linux and on Android without Google services: the
  instance posts the same RFC 8291 payload to the user's distributor
  directly, without the relay.

Verification: the harness's stand-in relay and a stand-in UnifiedPush
distributor each receive a payload that decrypts to the expected alert.

---

## Part F — Sequencing

| Phase | Contents | Exit criterion | Size |
|---|---|---|---|
| 0. Windows gate | Zig WinUI 3 window (part D3) | The gate holds on Windows 11 | M |
| 1. Client core | `clients/core` with its C ABI | `zig build test` green against the harness server and the contract fixtures | M |
| 2. Windows | Projection generator, hosting, C1 | UI Automation run green on a CI runner; Narrator reaches every control | L |
| 3. Linux | C2 and the Flatpak | Xvfb end-to-end run green; installs from the Flatpak bundle | M |
| 4. Android | C3 | Compose UI tests green; widget and push on a real device | L |
| 5. Push | Part E: Apple push turned on (E1), then FCM, WNS and UnifiedPush (E2) | Notifications arrive on Apple devices and all three new platforms | M |
| 6. Release 0.4 | Store listings, signing, docs, tour screenshots | Each app installs and passes the setup checklist | M |

## Sources

- [microsoft/windows-rs: windows-reactor](https://github.com/microsoft/windows-rs/blob/master/docs/crates/windows-reactor.md) and [windows-reactor-setup](https://github.com/microsoft/windows-rs/blob/master/docs/crates/windows-reactor-setup.md)
- [microsoft/dynwinrt](https://github.com/microsoft/dynwinrt)
- [thebrowsercompany/swift-winui](https://github.com/thebrowsercompany/swift-winui)
- [WinUI 3 in C++ without XAML](https://github.com/sotanakamura/winui3-without-xaml)
- [MddBootstrapInitialize2](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/win32/mddbootstrap/nf-mddbootstrap-mddbootstrapinitialize2)
- [XamlReader.Load](https://learn.microsoft.com/en-us/UWP/api/windows.ui.xaml.markup.xamlreader.load?view=winrt-22621)
- [UnifiedPush](https://unifiedpush.org/)
