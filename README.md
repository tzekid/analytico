# Analytico

Analytico is a small self-hosted analytics engine for websites, shops and
products: traffic, sources, geography, conversions, revenue, returning
visitors, session replays and heatmaps — in Full mode for visitors who
consent, and privately (no storage at all) for everyone else.

The implementation is deliberately small:

- one Zig executable;
- the vendored SQLite 3.53.4 amalgamation;
- one analytics database, one replay database and one local key file;
- Full, Session and Lite browser trackers, plus a lazily loaded replay
  recorder (rrweb, vendored) and heatmap overlay;
- public `/e`, `/r` and `/h`, and signed internal `/i` ingestion;
- fixed administration, operations, session, funnel, and report commands;
- a server-rendered web workspace with optional AI (your own ChatGPT plan or
  an API key) and a read-only MCP connector for Claude and ChatGPT.

The archived Turso/DuckDB/dashboard implementation is tagged
`archive/pre-sqlite-overhaul-2026-08-28`. It is intentionally not migrated or
kept as a compatibility layer.

## Build

The pinned Zig version is in `.zigversion`. A clean checkout builds offline:

```sh
zig build
zig build -Doptimize=ReleaseSafe
```

## Verification

The focused checks need only Zig. The end-to-end journeys also need
Node.js 22 or newer and Chromium. Install the pinned test-only
browser driver once with `npm ci`; no Node dependency is used by the product.
Chromium defaults to `/usr/bin/chromium`; set `CHROMIUM_PATH` for another
installed executable.

```sh
npm ci
zig build test -Doptimize=ReleaseSafe
zig build e2e -Doptimize=ReleaseSafe
```

The journeys (`tests/*.mjs`, run in turn by `tests/e2e.mjs`; shared setup in
`tests/harness.mjs`) use disposable SQLite data and loopback HTTP. The CLI
journey verifies collection, report values, every catalog report alike
through the CLI and the read API, and backup/restore; the browser journey
checks Lite tracking with browser storage disabled, Session
identity across navigation, and an actual browser action. The v3 journey
covers Full mode end to end: consent by region, banner, GPC, decline and
deletion; geography; SPA routes; errors; ecommerce; identity across devices
and domains; heatmaps and the live overlay; forms; masked replays; roles,
public links, the API and the audit log; and every integration against
stand-in endpoints. The UX journey checks the speed features: group commit
under concurrent batches, live updates, prefetching on hover and touch,
instant back with scroll restore, in-place page updates, remembered periods,
undoable deletes, keyboard shortcuts (press `?` in the workspace), chart
drill-down and a drafted note for a day that broke the trend. `tests/load.mjs` measures ingest and reads at ten million page
views a month (run by hand). The workspace
journey signs in through an invite and exercises pages, goals, funnels,
filters, alerts, notes, Ask through a stand-in OpenAI-compatible endpoint,
and the OAuth + MCP connector; the AI journey signs in with a stand-in
ChatGPT (paste and loopback, forged tokens, refresh, revoke), streams Ask
with tool calls on the plan and on an Anthropic key, turns a description
into filters and summarises a session. It also verifies
recovery after stalled or trickled HTTP requests and graceful shutdown with
an incomplete request. The tracker variants are cut from
`assets/tracker-source.js` by `tools/gen_trackers.zig` during every build.

## First run

```sh
analytico init ./data --origin https://analytico.example
analytico geo import dbip-city-lite-2026-10.csv.gz --data ./data   # optional
analytico site add plosca https://plosca.ru --data ./data      # Full mode
analytico site snippet plosca https://analytico.example --data ./data --rum
analytico serve --data ./data --listen 127.0.0.1:4318
```

`init --origin` prints a one-time link to create your account with a passkey
(or another method); add websites, teammates, sign-in methods and email
delivery from the workspace.

Run `analytico help`, or see [PRODUCT.md](PRODUCT.md), the collection
[protocol](docs/PROTOCOL.md), and [operations](docs/OPERATIONS.md).
