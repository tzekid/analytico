# Collection protocol v1

Routes:

- `GET /t/<variant>.<hash>.js` serves immutable tracker assets.
- `POST /e` accepts browser batches after exact-Origin validation.
- `POST /i` accepts authoritative server batches after signature validation.
- `GET /healthz` reports process liveness.
- `GET /readyz` reports current-schema database readiness.

Bodies are strict UTF-8 JSON, at most 8 KiB, with no unknown fields. A batch
contains protocol version 1, site public ID, client send time, and 1-16 closed
records. Identifiers are canonical lowercase UUIDs. Strings, arrays, paths,
properties, timestamps, and monetary values have fixed bounds. Full URLs and
arbitrary query strings are rejected rather than normalized into storage.

Record types are `page_view`, `page_summary`, and `event`. Semantic event names
are canonical identifiers. Flat event properties allow at most eight keys
with string, integer, boolean, or null values. Money uses integer
`value_minor` plus three-letter currency.

Each `(site,event_id)` is idempotent. Reusing an event ID with the same
canonical payload is a duplicate and succeeds. Reusing it with different
content is a 409 conflict. A 204 means the whole batch committed durably.

The loopback proxy must replace `X-Forwarded-For` with the immediate client's
validated network address. Browser collection fails closed when this header is
missing or invalid; Analytico never substitutes the loopback address.

Internal requests include `X-Analytico-Timestamp` (Unix seconds) and
`X-Analytico-Signature` (lowercase hex HMAC-SHA256 of
`timestamp + "." + body`). The timestamp must be within five minutes. `/i`
also requires loopback or an explicitly configured trusted proxy boundary.
