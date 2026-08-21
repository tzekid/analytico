# Collection protocol

> **Status:** Protocol v1 remains a shipped frozen compatibility contract.
> Protocol v2 is the additive collector/storage foundation defined by D28.
> Protocol-v2 tracker anonymous identity and `reset()` are implemented.
> Session rotation, `identify()`, SPA/engagement, and metric-v2 continue
> through issues #8–#13.

Breaking changes require a new protocol version. They do not reinterpret
accepted v1 events or metric-v1 visitor-day semantics.

## 1. Routes

| Method | Route | Purpose | Success |
| --- | --- | --- | --- |
| `GET` | `/tracker.aef65945.js` | Immutable protocol-v1 tracker | `200` JavaScript |
| `GET` | `/tracker.fb64c486.js` | Immutable protocol-v2 tracker | `200` JavaScript |
| `GET` | `/tracker.js` | Short-cache alias of the protocol-v2 tracker | `200` JavaScript |
| `POST` | `/v1/event` | Page view or custom event | `204` empty |
| `POST` | `/v2/event` | Bounded version-2 event envelope | `204` empty |
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
| Protocol-v1 POST body | 8 KiB |
| Protocol-v2 POST body | 16 KiB |
| Site UUID text | 36 bytes |
| Origin or referrer URL input | 2,048 bytes |
| Path | 1,024 bytes |
| Event name | 64 bytes |
| Protocol-v1 properties | 16 entries / 4 KiB canonical total |
| Protocol-v2 properties or traits | 16 entries each / 512-byte string |
| Each UTM value | 256 bytes |

Chunked bodies are accepted only when the decoded total remains within the
route's limit. Compressed request bodies are not accepted.

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
| `409` | Event-ID reuse or identity link conflicts |
| `413` | Target, headers, or body exceed limits |
| `415` | Unsupported content type or encoding |
| `429` | Bounded rate limit exceeded |
| `500` | Durable write failed |
| `503` | Store unavailable or shutting down |

Error bodies are fixed small text and do not echo request content.

## 4. Protocol-v2 POST event

Protocol v2 uses the same `text/plain;charset=UTF-8`, exact-origin, no-cookie,
no-credentials, and fixed-error boundary as v1. It is accepted only at
`/v2/event`, and `v` must be exactly `2`.

The common required envelope is:

```json
{
  "v": 2,
  "site": "00000000-0000-4000-8000-000000000000",
  "event_id": "00000000-0000-4000-8000-000000000001",
  "anonymous_id": "00000000-0000-4000-8000-000000000002",
  "identity_quality": "persistent",
  "session_id": "00000000-0000-4000-8000-000000000003",
  "sequence": 4,
  "occurred_at_ms": 1787227532123,
  "type": "event",
  "name": "sign_up",
  "page": {
    "path": "/pricing",
    "title": "Pricing",
    "hostname": "example.com"
  },
  "properties": {
    "plan": "pro",
    "trial_days": 14,
    "success": true
  },
  "value": {
    "amount": "49.00",
    "currency": "EUR"
  }
}
```

UUIDs are canonical lowercase text. Sequence is an unsigned 32-bit integer.
Occurrence time must be no more than seven days behind or 24 hours ahead of
server receipt time; receipt time remains authoritative for acceptance and
date bucketing. `identity_quality` is exactly `persistent` or `ephemeral`.

Event-specific fields are closed:

| Type | Required | Optional | Canonical stored name |
| --- | --- | --- | --- |
| `pageview` | `page` | referrer, UTM | `page_view` |
| `event` | `name` | page, referrer, UTM, properties, value | supplied name |
| `engagement` | `page`, `engagement` | none | `engagement` |
| `identify` | persistent identity, `user` | page and flat user traits | `identify` |

Fields outside the selected row are rejected rather than ignored. Page path is
required whenever `page` is present; title and hostname are optional and
bounded to 512 UTF-8 bytes and 253 normalized bytes respectively. Path is
normalized by the repository path contract, hostname is lowercase bounded
ASCII, and referrer stores only a normalized external host. Absent and
same-origin referrers store empty; a malformed referrer URL rejects the event.
Engagement
contains `active_ms` from 0–60,000 and integer `max_scroll_depth` from 0–100.

Property and trait objects have at most 16 unique identifier keys. This
foundation does not consult the protocol-v1 property allowlist. It accepts
strings up to 512 UTF-8 bytes without control characters, signed integers,
booleans, and null; arrays, nested objects, floating JSON numbers, and
duplicate keys reject the whole event. Issue #10 owns exact
decimal property tokens and query/type discovery. Value is available only on a
custom event and requires both a decimal amount and three-uppercase-letter
currency. Amount accepts an optional minus, no plus or exponent, at most 12
integer and six fractional digits, and is stored at exact scale six.
The identify `user` object requires `id` of 1–160 UTF-8 bytes without control
characters and may contain the bounded `traits` object described above.

`event_id` is idempotent within a site. A repeat whose normalized fields have
the same canonical digest returns `204` and writes nothing. Reuse with any
different normalized field, or an anonymous identity already linked to a
different user, returns fixed `409`. An identify link and its event are one
DuckDB transaction. No response echoes a property, trait, identity, or request
body.

## 5. Pixel page view

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

## 6. Tracker behavior

The tracker is not needed by Analytico's later admin UI; it is the optional
collection helper embedded in measured sites.

Protocol-v1 tracker requirements remain for `/tracker.aef65945.js`. That asset
still posts `v:1` to `/v1/event`, uses no browser storage, and exposes
`window.analytico.event(name, properties)`.

Protocol-v2 tracker requirements for `/tracker.js` and `/tracker.fb64c486.js`:

- self-hosted by Analytico or copied byte-for-byte to the measured site;
- loaded with `defer`;
- no cookies, fingerprint API, dynamic import, or third-party request;
- no DOM mutation;
- one page-view request per ordinary document load;
- site-scoped first-party `localStorage` keys `anl:<site-uuid>:a` (anonymous
  UUID) and `anl:<site-uuid>:s` (session UUID);
- when storage throws, in-memory IDs are used and events are marked
  `identity_quality=ephemeral`;
- when UUID generation fails, the tracker does not send;
- storage, serialization, beacon, and fetch failures never throw into the host
  page;
- `analytico.reset()` clears identified storage and creates a new anonymous
  and session UUID;
- custom events through `analytico.track(name, properties)`;
- SPA, engagement, and `identify()` remain later issues;
- minified and compressed bytes recorded by the performance gate.

Usage:

```html
<script
  defer
  src="https://analytics.example/tracker.fb64c486.js"
  data-site="00000000-0000-4000-8000-000000000000"
></script>
```

```js
window.analytico?.track("signup", { plan: "basic" });
window.analytico?.reset();
```

The site attribute is exactly `data-site`. Existing hashed v1 URLs continue to
serve the frozen protocol-v1 bytes.

## 7. Origin and proxy trust

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

## 8. Rate limiting

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

## 9. Caching and CSP

- `/tracker.aef65945.js`: frozen protocol-v1 bytes, one-year immutable cache
  with Brotli/gzip variants.
- `/tracker.fb64c486.js`: protocol-v2 identity tracker, one-year immutable
  cache with Brotli/gzip variants.
- `/tracker.js`: identical protocol-v2 bytes with a five-minute cache.
- Event and pixel routes, including `/v2/event`: `no-store`.
- No collector route sets a cookie.
- Measured sites must add the collector origin to `script-src` and
  `connect-src` when the tracker is hosted on a separate origin; the pixel
  origin must be present in `img-src`.

## 10. Protocol versioning

`v: 1` is required. Additive optional fields still require an explicit
acceptance test. A breaking payload or metric change uses a new protocol or
metric version; the server may temporarily accept two versions only with a
dated removal milestone. Compatibility code is removed after migration.

Protocol v2 adds persistent first-party identity, client session identity,
optional explicit identification, and the event fields required by metric v2.
Protocol-v1 requests continue through their existing bounded validation and
privacy path and migrate as `legacy_daily`; they are never silently treated as
persistent people. V1 is not removed in 1.0. Removal requires a later decision
and issue, deployed v2 tracker coverage for every active site, and operator
evidence that no required v1 traffic was accepted for 30 consecutive days.
