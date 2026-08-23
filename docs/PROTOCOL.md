# Collection protocol

> **Status:** Protocol v1 remains a shipped frozen compatibility contract.
> Protocol v2 is the additive collector/storage foundation defined by D28.
> Protocol-v2 tracker anonymous identity, `identify()`, `reset()`, 30-minute
> client session rotation, explicit site timezone bucketing, and typed property
> storage/query primitives, SPA navigation, engagement/scroll, exact tracker
> value handling, and opt-in automatic events are implemented. Exact legacy
> migration and mixed-data coverage are implemented by issue #13; later
> product queries remain separately issue-backed.

Breaking changes require a new protocol version. They do not reinterpret
accepted v1 events or metric-v1 visitor-day semantics.

## 1. Routes

| Method | Route | Purpose | Success |
| --- | --- | --- | --- |
| `GET` | `/tracker.aef65945.js` | Immutable protocol-v1 tracker | `200` JavaScript |
| `GET` | `/tracker.fb64c486.js` | Immutable protocol-v2 anonymous-identity tracker | `200` JavaScript |
| `GET` | `/tracker.78135195.js` | Immutable protocol-v2 session tracker | `200` JavaScript |
| `GET` | `/tracker.d9e94247.js` | Immutable protocol-v2 identify tracker | `200` JavaScript |
| `GET` | `/tracker.81c3b777.js` | Immutable compatibility SPA/engagement tracker | `200` JavaScript |
| `GET` | `/tracker.6de111c9.js` | Immutable current tracker with stored self-exclusion | `200` JavaScript |
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
| `204` | Event committed, including an explicitly self-excluded event |
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
  "self_excluded": true,
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
bucketing. `received_date_utc` retains the UTC compatibility date, while the
server also derives stable `site_local_date` and `site_utc_offset_minutes`
from the loaded site TZif policy. `identity_quality` is exactly `persistent`
or `ephemeral`. `self_excluded` is an optional boolean common to all four event
types; absent and false mean no tracker self-flag, while true sets the tracker
bit in the stored exclusion source.

The canonical protocol-v2 payload digest adds a component when
`self_excluded=true`. Absent and false preserve the pre-D31 digest so unchanged
events remain idempotent across migration; changing an existing event to true
conflicts. Network-prefix classification comes from the first receipt context:
a later idempotent replay does not rewrite the stored exclusion source.

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

Property and trait objects have at most 16 unique identifier keys and do not
consult the protocol-v1 property allowlist. They accept strings up to 512 UTF-8
bytes without control characters, signed 64-bit integers, exact decimal JSON
tokens, booleans, and null. A decimal accepts an optional minus, no plus or
exponent, at most 12 integer and six fractional digits, and is canonicalized to
six fractional digits. An integer token remains an integer, so `1`, `1.000000`,
`"1"`, null, and an absent key remain distinct. Arrays, nested objects,
out-of-range numbers, and duplicate keys reject the whole event.

Value is available only on a custom event and requires both a decimal amount
and three-uppercase-letter currency. Amount uses the same decimal grammar and
is stored at exact scale six.
The identify `user` object requires `id` of 1–160 UTF-8 bytes without control
characters and may contain the bounded `traits` object described above.

`event_id` is idempotent within a site. A repeat whose normalized fields have
the same canonical digest returns `204` and writes nothing. Reuse with any
different normalized field, or an anonymous identity already linked to a
different user, returns fixed `409`. An identify link and its event are one
DuckDB transaction. No response echoes a property, trait, identity, or request
body. An identity-link conflict additionally carries the stable safe response
header `X-Analytico-Code: identity_conflict`; event-ID conflicts retain the
generic fixed response. The future authenticated diagnostics ring consumes the
same code but is not part of the public identity state model.

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

Protocol-v2 tracker requirements for `/tracker.js` and the current immutable
content-hashed path:

- self-hosted by Analytico or copied byte-for-byte to the measured site;
- loaded with `defer`;
- no cookies, fingerprint API, dynamic import, or third-party request;
- no DOM mutation;
- one page-view request per ordinary document load;
- site-scoped first-party `localStorage` keys `anl:<site-uuid>:a` (anonymous
  UUID) and `anl:<site-uuid>:s` (session record
  `{id,last_activity_ms,sequence}`), plus optional `anl:<site-uuid>:u`
  identified-user state and the operator-controlled `anl:<site-uuid>:x`
  self-exclusion flag;
- exact localhost names (`localhost`, subdomains of `.localhost`, `127.0.0.1`,
  and IPv6 loopback) return before identity setup or network activity;
- an initial page view is deferred while `document.prerendering` is true and
  emitted only after `prerenderingchange`; a document that is never activated
  emits no page view, not-found event, or engagement;
- the session UUID is reused while inactivity is at most 30 minutes, including
  across UTC midnight, and rotates only after more than 30 minutes;
- sequence is persisted with the session record and sent on each event;
- when storage throws, in-memory IDs are used and events are marked
  `identity_quality=ephemeral`;
- when the self-exclusion flag is present, every otherwise valid envelope adds
  `self_excluded:true`; the collector stores and classifies those events rather
  than suppressing the request;
- when UUID generation fails, the tracker does not send;
- storage, serialization, beacon, and fetch failures never throw into the host
  page;
- `analytico.reset()` clears identified storage, discards unsent engagement,
  and creates a new anonymous and session UUID without requiring a network
  request;
- custom events through `analytico.track(name, properties)`. When the second
  argument contains both `value` and `currency`, the tracker sends them through
  protocol v2's exact value object and leaves the remaining keys as ordinary
  properties. The amount must use the protocol decimal-string grammar and the
  currency must be three uppercase ASCII letters; an invalid or incomplete pair
  sends nothing rather than recording misleading revenue;
- `analytico.identify(user_id, traits)` sends a bounded identify event only for
  persistent anonymous identity. The first locally recorded user ID remains
  until `reset()`; a different call is still sent for authoritative server
  rejection but does not overwrite that local state;
- the local identified key is failure-tolerant application state, not proof
  that the collector committed a link. Traits are not duplicated into browser
  storage; accepted bounded traits remain on identify events in DuckDB;
- `data-spa="auto"` wraps `pushState` and `replaceState` and listens to
  `popstate`. It emits once when `location.pathname` changes, suppresses an
  immediate same-path duplicate, and never sends the query string. No
  framework hook or public `page()` API is added;
- `data-engagement="true"` counts time only while the document is visible and
  user activity occurred within the previous 60 seconds. Passive scroll,
  `pointerdown`, `touchstart`, and `keydown` activity update that window. A
  delta and the maximum integer scroll depth are attempted at most every 15
  seconds and when a page becomes hidden, is left, or changes SPA path. Hidden
  and idle time are not carried into the next delta;
- automatic events are off unless their exact attribute is `true`:
  `data-outbound` sends `outbound_click` with only `url_host`,
  `data-downloads` sends `file_download` with bounded query-free `url_path` and
  `extension`, `data-forms` sends `form_submit` with bounded `form_id`,
  query-free `action_path`, and `action_host`, and `data-not-found` sends one
  `not_found` event.
  A matching download takes precedence over outbound classification. No field
  value, generic click, full URL, or query string is inspected or sent;
- the tracker installs no configuration request, dependency, DOM mutation,
  framework integration, high-frequency pointer listener, or every-click
  capture. Multi-tab session races remain an accepted documented limitation;
- the tested compatibility target is the acceptance-tooling versions pinned in
  `versions.json`: Chromium 151, Firefox 153, and WebKit 26.5. The UUID helper
  falls back from `crypto.randomUUID()` to `crypto.getRandomValues()`; no
  legacy-browser compatibility layer is shipped;
- minified and compressed bytes recorded by the performance gate.

The authenticated dashboard sets or clears the flag through a bounded
no-network cross-origin handshake. It opens the site's configured exact origin
with a site-bound control fragment. That fragment marks the control page itself
as self-excluded immediately. The tracker accepts the durable change only from
its own collector/dashboard origin and the opening window through
`postMessage`, strips the fragment locally, and sends no configuration request.
A copied fragment cannot durably change another browser's flag without that
origin-checked opener handshake.

Usage:

```html
<script
  defer
  src="https://analytics.example/tracker.6de111c9.js"
  data-site="00000000-0000-4000-8000-000000000000"
  data-spa="auto"
  data-engagement="true"
></script>
```

```js
window.analytico?.track("signup", { plan: "basic" });
window.analytico?.identify("user_123", { plan: "basic" });
window.analytico?.reset();
```

The site attribute is exactly `data-site`. Every published content-hashed
tracker URL continues to serve its exact original bytes with immutable caching;
the short-cache `/tracker.js` alias alone advances to the current tracker.

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

After site and origin validation, the collector compares only the transient
normalized IPv4 `/24` or IPv6 `/48` prefix with at most 16 explicit per-site
network exclusions. Raw IP input is neither stored nor logged. A match sets the
network bit in the stored event's temporary `exclusion_source`; it never drops
the event. Dashboard mutations refresh the bounded in-memory site-policy
snapshot before returning success.

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
- Published content-hashed protocol-v2 trackers: exact original bytes,
  one-year immutable cache with Brotli/gzip variants.
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
