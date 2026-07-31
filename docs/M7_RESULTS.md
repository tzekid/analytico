# M7 HTMX 4 progressive-enhancement evidence

Measured on 2026-07-31 using real Caddy, the loopback ReleaseSafe service, and
Chromium. HTMX 4 had no stable release at evaluation time; the selected
`4.0.0-beta6` release was published 2026-07-23. Upstream provenance is the
[official release](https://github.com/bigskysoftware/htmx/releases/tag/v4.0.0-beta6)
and [HTMX 4 documentation](https://four.htmx.org/htmx-4/).

## Exact self-hosted asset

| Observation | Result | Budget |
| --- | ---: | ---: |
| Complete first-view HTML | 1,419 compressed bytes | ≤ 32 KiB |
| CSS | 936 compressed bytes | ≤ 12 KiB |
| Minified core | 36,282 bytes | — |
| Minified core SHA-256 | `28fae7bbe8e8142b702debb9d5234a9a436d9435a4b5165b195aa1a7ed840d25` | exact |
| Precomputed gzip | 13,014 bytes | ≤ 16 KiB |
| Gzip SHA-256 | `74cc4013d2f7a7d072fdcc0f3ac61929ee4254798b0f6750adad6d34b137da1b` | exact |
| Initial requests | 3 | ≤ 3 |
| Startup API/JSON requests | 0 | 0 |
| Application-authored JavaScript | 0 bytes | ≤ 2 KiB |

The build consumes the immutable npm package through Zig's package hash and
embeds only `dist/htmx.min.js`. A tiny build tool using the pinned Zig standard
library produces deterministic gzip bytes. The runtime needs neither npm,
Node, a CDN, nor a compressor. The checked-in Zero-Clause BSD license ships in
the release archive.

## Same server state model

HTMX 4's explicit `hx-boost` enhancement intercepts the existing native links
and forms. Its body-level `outerSync` request receives the same complete HTML
from the same controller as a native request. There is no `HX-Request` branch,
fragment-only endpoint, JSON representation, hydration step, compatibility
extension, or client state store.

The browser proves:

- a deep-linked overview has useful state before any enhanced request;
- enhanced navigation sends `HX-Request: true` and `HX-Request-Type: full`;
- URLs push correctly and browser back/forward restores pages;
- link focus survives the swap and navigation scroll returns to the top;
- the request class exposes loading state during an intentionally delayed GET;
- native HTML validation sends no request;
- a server `422` swaps a complete error page and preserves safe fields;
- `hx-sync="this:drop"` reduces a real double click to one POST;
- an offline failure leaves the complete current page intact and the same link
  succeeds after reconnect;
- local and session storage remain empty; and
- a real report timeout swaps the complete `503` response and its preserved
  deep-link retry fails honestly again rather than hiding the error.

## Removal and failure equivalence

Separate Chromium contexts abort the HTMX asset and replace it with invalid
JavaScript. In both cases, clicking the same ordinary link performs a normal
document navigation and renders the correct report. The M6 JavaScript-disabled
gate also runs against the enhanced HTML. Therefore deleting the script tag
and `hx-*` attributes restores the full M6 product without a server change.
