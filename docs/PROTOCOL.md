# Collection protocol

This is the frozen v1 wire contract. Breaking changes require a new protocol
version.

## 1. Routes

| Method | Route | Purpose | Success |
| --- | --- | --- | --- |
| `GET` | `/tracker.aef65945.js` | Immutable optional tracker | `200` JavaScript |
| `GET` | `/tracker.js` | Short-cache installation alias | `200` JavaScript |
| `POST` | `/v1/event` | Page view or custom event | `204` empty |
| `GET` | `/v1/p.gif` | JavaScript-free page view | `200` transparent GIF |
| `GET` | `/healthz` | Process liveness, loopback only | `200` text |
| `GET` | `/readyz` | Store readiness, loopback only | `200` or `503` |

All other routes return a small `404`. Methods not listed for a route return
`405` with `Allow`.

## 2. Request limits

Limits are checked before dynamic allocation where possible:

| Input | Maximum |
| --- | ---: |
| Request target | 4,096 bytes |
| Header count | 32 |
| Total header bytes | 16 KiB |
| POST body | 8 KiB |
| Site UUID text | 36 bytes |
| Origin or referrer URL input | 2,048 bytes |
| Path | 1,024 bytes |
| Event name | 64 bytes |
| Properties | 16 entries / 4 KiB canonical total |
| Each UTM value | 256 bytes |

Chunked bodies are accepted only when the decoded total remains within 8 KiB.
Compressed request bodies are not accepted.

## 3. POST event

### Headers

```http
POST /v1/event HTTP/1.1
Content-Type: text/plain;charset=UTF-8
Origin: https://example.com
```

`text/plain` keeps the cross-origin beacon a simple request. The server parses
the body as strict UTF-8 JSON after enforcing the byte limit. It echoes
`Access-Control-Allow-Origin` only when the exact normalized origin belongs to
the site. Credentials are not enabled.

### Page-view body

```json
{
  "v": 1,
  "site": "00000000-0000-4000-8000-000000000000",
  "type": "pageview",
  "path": "/pricing",
  "referrer": "https://search.example/results?q=private",
  "utm": {
    "source": "newsletter",
    "medium": "email",
    "campaign": "summer"
  }
}
```

Only recognized fields are accepted. The referrer is reduced to its external
host. The collector never persists the shown path/query from the referrer.

### Custom-event body

```json
{
  "v": 1,
  "site": "00000000-0000-4000-8000-000000000000",
  "type": "event",
  "name": "signup",
  "path": "/welcome",
  "properties": {
    "plan": "basic"
  }
}
```

Unknown top-level keys, duplicate JSON keys, nested properties, and non-finite
numbers are rejected. The exact JSON parser behavior is covered by a corpus.

### Responses

| Status | Meaning |
| --- | --- |
| `204` | Event committed |
| `400` | Malformed or semantically invalid |
| `403` | Origin is not allowed |
| `404` | Site is unknown or disabled |
| `413` | Target, headers, or body exceed limits |
| `415` | Unsupported content type or encoding |
| `429` | Bounded rate limit exceeded |
| `500` | Durable write failed |
| `503` | Store unavailable or shutting down |

Error bodies are fixed small text and do not echo request content.

## 4. Pixel page view

Example server-rendered fallback:

```html
<noscript>
  <img
    src="https://analytics.example/v1/p.gif?site=00000000-0000-4000-8000-000000000000&amp;path=%2Fpricing"
    alt=""
    width="1"
    height="1"
    loading="eager"
  >
</noscript>
```

Allowed query keys are:

```text
site, path, utm_source, utm_medium, utm_campaign, utm_term, utm_content
```

The exact `Referer` origin must match a configured site origin. Unknown keys are
rejected. The response has:

```http
Content-Type: image/gif
Cache-Control: no-store, max-age=0
X-Content-Type-Options: nosniff
Referrer-Policy: no-referrer
```

The endpoint returns the GIF only after the event commits. Invalid requests use
the corresponding error status rather than claiming a view.

## 5. Tracker behavior

The tracker is not needed by Analytico's later admin UI; it is the optional
collection helper embedded in measured sites.

MVP requirements:

- self-hosted by Analytico or copied byte-for-byte to the measured site;
- loaded with `defer`;
- no cookies, local storage, fingerprint API, dynamic import, or third-party
  request;
- no DOM mutation;
- one page-view request per ordinary document load;
- custom events only through an explicit small function;
- request payload constructed from `location.pathname`, `document.referrer`,
  and the five recognized UTM parameters;
- tracker errors never break the measured page;
- minified and compressed bytes recorded by the performance gate.

Usage:

```html
<script
  defer
  src="https://analytics.example/tracker.aef65945.js"
  data-site="00000000-0000-4000-8000-000000000000"
></script>
```

```js
window.analytico?.event("signup", { plan: "basic" });
```

The global API is `window.analytico.event(name, properties)` and the site
attribute is exactly `data-site`.

## 6. Origin and proxy trust

- POST requires an exact `Origin` match.
- Pixel GET requires the origin parsed from `Referer` to match.
- Requests without the applicable browser header are rejected in production.
- Caddy overwrites, rather than forwards, any client-supplied proxy-IP or
  country trust header.
- The application binds only to loopback, so only the local reverse proxy or an
  equally privileged local operator can supply the overwritten forwarding
  headers.
- Country is read only from the specifically configured trusted header.

The site identifier is public and appears in browser markup. It is not an
authorization credential.

## 7. Rate limiting

M2 begins with:

- per-site and normalized network-prefix limit of 120 events/minute;
- burst capacity of 30;
- a fixed-capacity table of at most 4,096 active buckets;
- entries expire after ten idle minutes;
- when the table is full, an unknown bucket is rejected rather than allocating
  unbounded memory.

Rate limits are deployment defaults and may be changed only within documented
hard maxima. Caddy may add a coarser outer limit, but correctness does not rely
on it.

## 8. Caching and CSP

- `/tracker.aef65945.js`: one-year immutable cache with Brotli/gzip variants.
- `/tracker.js`: identical bytes with a five-minute cache.
- Event and pixel routes: `no-store`.
- No collector route sets a cookie.
- Measured sites must add the collector origin to `script-src` and
  `connect-src` when the tracker is hosted on a separate origin; the pixel
  origin must be present in `img-src`.

## 9. Protocol versioning

`v: 1` is required. Additive optional fields still require an explicit
acceptance test. A breaking payload or metric change uses a new protocol or
metric version; the server may temporarily accept two versions only with a
dated removal milestone. Compatibility code is removed after migration.
