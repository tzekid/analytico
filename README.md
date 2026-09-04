# Analytico

Analytico is a small self-hosted analytics engine for websites and products.
It captures acquisition, page and product behaviour, real-user performance,
and authoritative server outcomes without replay, DOM recording, cookies in
Lite mode, or a heavyweight runtime.

The current clean-break implementation is CLI-first:

- one Zig executable;
- the vendored SQLite 3.53.4 amalgamation;
- one SQLite database and one local key file;
- Lite and Session browser trackers;
- public `/e` and signed internal `/i` ingestion;
- fixed administration, operations, session, funnel, and report commands.

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

The focused checks need only Zig. The end-to-end journey also needs Bash,
curl, OpenSSL, Node.js 22 or newer, and Chromium. Install the pinned test-only
browser driver once with `npm ci`; no Node dependency is used by the product.
Chromium defaults to `/usr/bin/chromium`; set `CHROMIUM_PATH` for another
installed executable.

```sh
npm ci
zig build test -Doptimize=ReleaseSafe
zig build e2e -Doptimize=ReleaseSafe
```

The journey uses disposable SQLite data and loopback HTTP. It verifies report
values, backup/restore, Lite tracking with browser storage disabled, Session
identity across navigation, and an actual browser action. Regenerate tracker
assets with `tools/build-trackers.sh`; commit generated changes only when the
tracker source intentionally changes.

## First run

```sh
analytico init ./data
analytico site add plosca https://plosca.ru --data ./data --mode lite
analytico site snippet plosca https://analytico.example --data ./data --rum
analytico serve --data ./data --listen 127.0.0.1:4318
```

Run `analytico help`, or see [PRODUCT.md](PRODUCT.md), the collection
[protocol](docs/PROTOCOL.md), and [operations](docs/OPERATIONS.md).
