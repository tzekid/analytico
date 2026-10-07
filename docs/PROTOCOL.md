# Collection protocol v2

Routes:

- `GET /t/<variant>.<hash>.js` serves immutable tracker assets: the trackers
  (`lite`, `session`, `full`, each optionally `-rum`), the lazily loaded
  replay recorder (`replay`) and the heatmap overlay (`overlay`).
- `POST /e` accepts browser batches after exact-Origin validation.
- `POST /i` accepts authoritative server batches after signature validation.
- `POST /r` accepts one session replay chunk.
- `POST /h` returns heatmap aggregates for the live overlay.
- `GET /healthz` reports process liveness.
- `GET /readyz` reports current-schema database readiness.

## Batches

Bodies are strict UTF-8 JSON, at most 8 KiB, with no unknown fields. A batch
contains the protocol version (`v`: 2, or 1 for snippets deployed before
v2), site public ID, client send time, and 1-16 closed records. Identifiers
are canonical lowercase UUIDs. Strings, arrays, paths, properties,
timestamps, and monetary values have fixed bounds. Full URLs and arbitrary
query strings are rejected rather than normalized into storage.

Version 1 allows the record types `page_view`, `page_summary` and `event`
with the fields they had in v1. Version 2 adds:

- `visitor_id` on any record of a Full-mode site, with consent only;
- `page_view`: `search_term`, `search_results`, `click_id` (consented only,
  `gclid:…`, `gbraid:…`, `wbraid:…`, `fbclid:…` or `msclkid:…`) and `link`
  (a cross-domain token);
- `page_summary`: `clicks` (at most 32 cells of element selector, 5% grid
  position inside the element, count and rage clicks), `attention` (visible
  milliseconds per tenth of the page) and `form_fields` (per field: time,
  validation errors, abandoned, submitted; never values), consented only;
- `event`: `order_id`, `items` (at most 32 of `id`, `name`, `category`,
  `price_minor`, `quantity`) and, from `/i` only, `user_id`;
- `consent` with `state` (`granted`, `not_required`, `denied`): attaches the
  page view it names to the consented visitor, or records the refusal;
- `error` with `path`, `message`, `file`, `line`, `column`;
- `identify` with `user_id`: links the visitor to the operator's user ID,
  which is stored only as a keyed hash;
- `forget`: erases everything stored about `visitor_id`, or from `/i`,
  everything linked to `user_id`.

Semantic event names are canonical identifiers. Flat event properties allow
at most eight keys with string, integer, boolean, or null values. Money uses
integer `value_minor` plus three-letter currency.

Each `(site,event_id)` is idempotent. Reusing an event ID with the same
canonical payload is a duplicate and succeeds. Reusing it with different
content is a 409 conflict. A 204 means the whole batch committed durably.

## Consent in Full mode

The server, not only the tracker, decides whether a Full-mode record may keep
its identity:

- `Sec-GPC: 1` removes `visitor_id` and `session_id` from every record (except
  `forget`) and stores it as Lite with consent `gpc`.
- `consent_mode` `granted` keeps the identity.
- `consent_mode` `not_required` keeps it only when the site's policy does not
  require consent for this visitor (`none`, or `regional` and the visitor's
  country is outside the EU, EEA, UK and Switzerland). Unknown countries are
  asked.
- Any other consent mode with an identity is rejected.
- A `link` token must be valid, unexpired and name the record's visitor and
  session, or the identity is removed.

For a Full-mode site, a v2 browser batch that commits returns `200` with
JSON instead of `204`:

```json
{"upgrade":"grant|ask|never","drop":true,"banner":{"text":"","privacy_url":""},
 "link":"<token>","domains":["https://other.example"],
 "replay":{"rate":10,"triggers":true,"goals":["purchase"]}}
```

`drop` means the server removed an identity the tracker sent; `banner` is
present when the site shows the built-in banner and the visitor must be
asked; `link`, `domains` and `replay` are present only for consented
visitors.

## Server batches

The loopback proxy must replace `X-Forwarded-For` with the immediate client's
validated network address. Browser collection fails closed when this header is
missing or invalid; Analytico never substitutes the loopback address. The
address is used for the place lookup and the site/day pseudonym, then
discarded.

Internal requests include `X-Analytico-Timestamp` (Unix seconds) and
`X-Analytico-Signature` (lowercase hex HMAC-SHA256 of
`timestamp + "." + body`). The timestamp must be within five minutes. `/i`
also requires loopback or an explicitly configured trusted proxy boundary.

## Replay chunks

`POST /r?site=&session=&visitor=&page=&seq=&first=&last=` with a body of at
most 256 KiB: one JSON array of rrweb events, masked in the browser, gzip
compressed (or plain, for the last chunk of a closing page).
The origin must be one of the site's, the site must be in Full mode with
recording on, the request must not carry `Sec-GPC: 1`, and a consented page
view with that session and visitor must exist. A session is capped at 5 MiB
and 30 minutes; chunks past either cap get `413`.

## Heatmap overlay

`POST /h?site=&token=&path=&vp=desktop|tablet|phone&days=` (empty body; a POST so
browsers always send `Origin`) returns click
cells, scroll reach in 5% steps and average attention per tenth of the page.
The token comes from the workspace, names the site and expires after two
hours; the response is readable only from the site's own origins.
