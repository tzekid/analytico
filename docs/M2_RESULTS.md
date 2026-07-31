# M2 collection result

M2 provides the complete low-traffic collection path: bounded HTTP parsing,
exact-origin enforcement, privacy-preserving classification, direct durable
DuckDB writes, a JavaScript tracker, and a JavaScript-free pixel.

## Shipped collector

- One explicit HTTP/1.1 route switch bound only to `127.0.0.1` or `::1`.
- An 8 KiB POST protocol and bounded chunk decoder, 4,096-byte request target,
  32-header/16 KiB header limits, strict content types, and fixed error bodies.
- Site policy loaded from Turso once at startup; accepted event requests do not
  query the relational store.
- Exact normalized POST `Origin` and pixel `Referer` checks.
- A fixed 4,096-entry per-site/network-prefix token-bucket table. When full,
  new identities receive `429`; request input cannot grow the table.
- Server receipt time, daily keyed pseudonyms, trusted two-letter country,
  small local browser/OS/device classification, and unknown fallbacks.
- One synchronous DuckDB insert before `204` or GIF success.
- A 734-byte project-authored tracker, plus 383-byte Brotli and 493-byte gzip
  variants, with no third-party or persistent-storage dependency.
- Graceful SIGTERM that stops the listener, interrupts an active partial
  request, checkpoints DuckDB, and closes both embedded stores.

`/tracker.aef65945.js` is the immutable production route.
`/tracker.js` serves identical bytes with a five-minute cache for manual
installation convenience.

## Real acceptance paths

`tests/e2e-m2.sh` drives the installed executable through real TCP sockets and
real on-disk databases. It covers every protocol status (`200`, `204`, `400`,
`403`, `404`, `405`, `413`, `415`, `429`, `500`, and `503`) and their required
headers. The corpus includes:

- unknown and duplicate JSON/header/query keys, nested properties, floating and
  overflowing numbers, malformed UTF-8, malformed percent encoding, and
  unsupported request compression;
- exact/default-port/punycode, absent, cross-site, malformed, disabled-site,
  duplicate forwarding, and multi-hop forwarding cases;
- oversized targets, headers, fixed and chunked bodies;
- committed custom properties in canonical order and rejected non-allowlisted
  properties;
- 100,000 distinct spoofed prefixes proving the 4,096-entry fixed capacity;
- database/log denylist scans for raw IP, full UA, query strings, referrer
  paths, and complete payloads;
- an intentionally half-sent request interrupted by SIGTERM with no phantom
  event; and
- a genuine DuckDB commit failure created by removing the live store path,
  producing `500`, then dishonest readiness `503`, and zero stored events.

`tests/e2e-m2-browser.sh` uses Playwright 1.62.0 in an immutable test image.
Current Chromium 151, Firefox 153, and WebKit 26.5 each:

- load a server-rendered page and immutable tracker;
- cause exactly one committed page-view request;
- leave local storage, session storage, Cache Storage, IndexedDB, and service
  worker registrations empty; and
- record one correct pixel page view when JavaScript is disabled.

The image is acceptance tooling only. It is not a product dependency or
deployment component.

## ReleaseSafe baseline

The clean source commit was
`82fba08286075ffa21717acafb0b67a654695aac`. The environment and command are in
`bench/results/m2-collection-release-safe.json`.

| Observation | Result | Budget |
| --- | ---: | ---: |
| Startup | 34 ms | 1,000 ms p95 |
| Idle RSS after 30 seconds | 53,832 KiB | 128 MiB |
| RSS after measured load | 54,544 KiB | 128 MiB |
| Durable insert p50 | 3.884 ms | — |
| Durable insert p95 | 5.807 ms | 25 ms |
| Durable insert p99 | 7.329 ms | 100 ms |
| Clean shutdown | 26 ms | 2,000 ms |
| Tracker, raw/Brotli/gzip | 734 / 383 / 493 bytes | 3,072 / 1,536 / — |

The 100 latency observations include loopback connect, request parsing,
classification, DuckDB autocommit, response, and curl timing. They are a local
VPS baseline, not an internet-latency claim.

## Reproduction

```sh
zig build test -Dturso-native-path=<exact-local-prefix>
zig build e2e-m2 -Dturso-native-path=<exact-local-prefix>
zig build e2e-m2-browser -Dturso-native-path=<exact-local-prefix>
zig build test -Doptimize=ReleaseSafe -Dturso-native-path=<exact-local-prefix>
zig build e2e-m2 -Doptimize=ReleaseSafe -Dturso-native-path=<exact-local-prefix>
zig build e2e-m2-browser -Doptimize=ReleaseSafe -Dturso-native-path=<exact-local-prefix>
zig build bench-m2 -Doptimize=ReleaseSafe -Dturso-native-path=<exact-local-prefix>
```
