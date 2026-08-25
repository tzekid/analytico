# Data model and metric semantics

> **Status:** Sections 1–9 define the shipped analytics-metadata subset in
> Turso metadata schema 10, DuckDB event schema 7, and metric semantics v1. Authentication storage
> remains governed by its own specification. The daily-pseudonym and UTC-day
> rules remain the compatibility contract for existing rows and current
> reports. Section 10 records the remaining 1.0 transition; event schema 7 does
> not by itself claim that metric v2 or site-local reporting is shipped.

This document is the contract for durable fields and reported numbers. SQL
shown here is the logical schema implemented and validated by the compiled
numbered migrations against the pinned Turso and DuckDB versions.

## 1. Shared Zig types

The application uses explicit types rather than passing database rows through
the system:

```text
SiteId              canonical lowercase UUID text
SiteSlug            validated operator-facing identifier
UtcMicros            signed 64-bit microseconds since Unix epoch
UtcDate              YYYY-MM-DD derived from server receipt time
NormalizedPath       owned UTF-8 path, no query or fragment
EventName            validated ASCII identifier
VisitorDayId         16 opaque bytes
CountryCode          ISO-like two-letter code or ZZ
BrowserFamily        closed enum with Other and Unknown
OsFamily             closed enum with Other and Unknown
DeviceCategory       desktop | mobile | tablet | other | unknown
TrafficClass         human-presumed | declared-bot | automation | excluded | suspected
NetworkDayId         16 opaque site/receipt-UTC-day keyed prefix bytes; zero is unknown
ReportRange          inclusive start date, exclusive end instant
```

Database adapters decode into owned values before releasing a result row.

## 2. Turso metadata

### `meta_migrations`

```sql
CREATE TABLE meta_migrations (
    version INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    applied_at_utc_micros INTEGER NOT NULL
);
```

Migration numbers are append-only. A binary refuses to start when the database
contains a newer unknown version.

### `sites`

```sql
CREATE TABLE sites (
    id TEXT PRIMARY KEY,
    slug TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    created_at_utc_micros INTEGER NOT NULL,
    disabled_at_utc_micros INTEGER,
    CHECK (length(id) = 36),
    CHECK (length(slug) BETWEEN 1 AND 48),
    CHECK (length(name) BETWEEN 1 AND 120)
);
```

The UUID is public and unguessable but is not treated as an authentication
secret.

### `site_origins`

```sql
CREATE TABLE site_origins (
    site_id TEXT NOT NULL,
    origin TEXT NOT NULL,
    PRIMARY KEY (site_id, origin),
    FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX site_origins_unique_origin ON site_origins(origin);
```

An origin is an exact normalized `scheme://host[:port]`. Wildcards are not
accepted in the MVP. Metadata schema 6 makes one origin belong to exactly one
site so browser creation cannot produce ambiguous collector authorization.

### `site_timezones`

```sql
CREATE TABLE site_timezones (
    site_id TEXT PRIMARY KEY,
    zone_name TEXT NOT NULL,
    revision INTEGER NOT NULL,
    rebucket_pending INTEGER NOT NULL,
    FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
    CHECK (length(zone_name) BETWEEN 1 AND 255),
    CHECK (revision >= 1),
    CHECK (rebucket_pending IN (0, 1))
);
```

Every new site receives one explicitly selected zone during creation. Metadata
migration 3 deliberately creates no row for an existing site: the operator
must select a zone, and serving fails closed until that choice and any required
rebucket complete. `rebucket_pending=1` is a narrow recovery marker for the
cross-store offline operation; it is never a usable site policy.

### `site_excluded_networks`

```sql
CREATE TABLE site_excluded_networks (
    site_id TEXT NOT NULL,
    network_prefix TEXT NOT NULL,
    created_at_utc_micros INTEGER NOT NULL,
    PRIMARY KEY (site_id, network_prefix),
    FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
    CHECK (length(network_prefix) BETWEEN 9 AND 64)
);
```

Metadata migration 4 adds this bounded D31 policy. Each site has at most 16
rows. The application canonicalizes operator input to an IPv4 `/24` or IPv6
`/48` before insertion. These rows are explicit configuration; visitor IP
addresses and hashes are never persisted. Successful authenticated changes
refresh the collector's in-memory policy without restart.

### `site_traffic_policy`

```sql
CREATE TABLE site_traffic_policy (
    site_id TEXT PRIMARY KEY,
    strict_mode INTEGER NOT NULL,
    daily_event_ceiling INTEGER NOT NULL,
    updated_at_utc_micros INTEGER NOT NULL,
    FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
    CHECK (strict_mode IN (0, 1)),
    CHECK (daily_event_ceiling BETWEEN 1 AND 10000000)
);
```

Metadata migration 5 backfills every site with strict mode off and a daily
accepted-event ceiling of 100,000; new sites receive the same row. The
authenticated native settings form may change only those closed values and
refreshes the in-memory collector policy before its 303 response. Missing or
invalid policy fails closed. No diagnostic or migration enables strict mode.

### `site_settings`

```sql
CREATE TABLE site_settings (
    site_id TEXT PRIMARY KEY,
    default_currency TEXT NOT NULL,
    FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
    CHECK (default_currency = '' OR (
        length(default_currency) = 3 AND
        default_currency NOT GLOB '*[^A-Z]*'
    ))
);
```

Metadata migration 6 backfills exactly one row per existing site with an empty
currency. Empty means no owner preference was recorded; it is not an inferred
EUR or an instruction to combine currencies. Browser-created sites persist the
owner's explicit empty or three-uppercase-ASCII value. D36 adds no settings
revision, tracking-option bitset, or second configuration model.

### `site_event_properties`

```sql
CREATE TABLE site_event_properties (
    site_id TEXT NOT NULL,
    property_name TEXT NOT NULL,
    PRIMARY KEY (site_id, property_name),
    FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE
);
```

This table allowlists custom-event properties. An empty allowlist means no
properties are accepted.

### `segments` and `saved_views`

```sql
CREATE TABLE segments (
    id TEXT PRIMARY KEY,
    site_id TEXT NOT NULL,
    name TEXT NOT NULL,
    filter_schema_version INTEGER NOT NULL CHECK (filter_schema_version = 1),
    canonical_filter_json TEXT NOT NULL,
    created_at_utc_micros INTEGER NOT NULL,
    updated_at_utc_micros INTEGER NOT NULL,
    FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
    UNIQUE (site_id, name),
    CHECK (length(id) = 36),
    CHECK (length(name) BETWEEN 1 AND 120),
    CHECK (length(canonical_filter_json) BETWEEN 1 AND 32768)
);

CREATE TABLE saved_views (
    id TEXT PRIMARY KEY,
    site_id TEXT NOT NULL,
    name TEXT NOT NULL,
    query_schema_version INTEGER NOT NULL CHECK (query_schema_version = 1),
    canonical_query_json TEXT NOT NULL,
    created_at_utc_micros INTEGER NOT NULL,
    updated_at_utc_micros INTEGER NOT NULL,
    FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
    UNIQUE (site_id, name),
    CHECK (length(id) = 36),
    CHECK (length(name) BETWEEN 1 AND 120),
    CHECK (length(canonical_query_json) BETWEEN 1 AND 32768)
);
```

Metadata migration 7 is additive and backfills no saved object. The
application permits at most 32 segments and 32 saved views per site, generates
canonical JSON before insertion, and verifies exact parse/reserialization on
load. A segment owns one schema-1 FilterSet. A saved view owns one canonical
Breakdown Query or Trend-set and may reference a segment UUID inside that
state; the UUID is not a database foreign key because deletion must leave a
visible stale view rather than cascade or silently rewrite it. D41 separately
refuses an ordinary deletion of a goal referenced by current valid canonical
saved state; restored corrupt or otherwise missing references retain D40's
visible stale behavior. All operations remain site-scoped D19 autocommits. No
owner/team, public token, widget layout, or DuckDB table is added.

### `goal_definitions_v2`

```sql
CREATE TABLE goal_definitions_v2 (
    id TEXT PRIMARY KEY,
    site_id TEXT NOT NULL,
    name TEXT NOT NULL,
    match_kind INTEGER NOT NULL,
    match_value TEXT NOT NULL,
    canonical_predicates_json TEXT NOT NULL,
    created_at_utc_micros INTEGER NOT NULL,
    updated_at_utc_micros INTEGER NOT NULL,
    archived_at_utc_micros INTEGER,
    FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
    UNIQUE (site_id, name),
    CHECK (length(id) = 36),
    CHECK (length(name) BETWEEN 1 AND 120),
    CHECK (match_kind IN (1, 2, 3)),
    CHECK (length(match_value) BETWEEN 1 AND 1024),
    CHECK (length(canonical_predicates_json) BETWEEN 2 AND 32768),
    CHECK (updated_at_utc_micros >= created_at_utc_micros),
    CHECK (
        archived_at_utc_micros IS NULL OR
        archived_at_utc_micros >= created_at_utc_micros
    )
);
```

Closed `match_kind` values:

1. exact custom-event name;
2. exact page path;
3. page-path prefix.

Metadata migration 8 deterministically copies every schema-7 `goals` row into
the retired `goal_definitions` table with the same ID, site, name, selector,
and creation
time. The initial update time equals the creation time and the archived time is
null. It verifies count and complete row equality, removes the retired table,
then writes ledger 8 last. Retry repairs a deterministic partial copy under
D19 durable autocommits. If retry finds the retired source already removed, it
accepts only the exact validated replacement shape before writing the missing
ledger; every other mixed state fails closed. No explicit multi-write Turso
transaction is claimed.

An active goal has no archived time. Archive preserves the row and stable ID,
removes it from the default active snapshot, and keeps it explicitly
reportable. Editing changes future evaluation over historical raw events and
updates the timestamp; no semantic version history is retained. At most 32
active goals may exist for one site, and create/duplicate/reactivate enforce
the bound in their single write statement. Page-bounded management reads keep
archived rows finite. Exact custom-event, exact page, and page-prefix remain
the only #33 selectors. Regexes and arbitrary expressions are excluded; issue
#34 owns up to three typed property predicates rather than that base migration.

Metadata migration 9 deterministically copies every schema-8
`goal_definitions` row into `goal_definitions_v2` with identical lifecycle and
base-selector fields plus the exact schema-1 empty predicate document
`{"schema":1,"predicates":[]}`. It verifies complete row equality, removes
the retired table, and writes ledger 9 last. Retry repairs a genuinely partial
copy; after source removal it accepts only the exact replacement shape and
canonical predicate documents. No explicit multi-write Turso transaction is
claimed.

`canonical_predicates_json` contains zero to three bytewise ordered,
deduplicated D29 predicate components. Every load parses, validates, and
reserializes the document and requires identical bytes. Property name, scalar
type, operator, and bounded canonical values therefore retain one typed
representation without child-row write races. Create/edit/duplicate remain one
statement; duplicate copies the complete document. Regex, nested logic, and
arbitrary expressions remain excluded.

A pre-migration overflow is copied without loss and shown as an operator state.
It blocks create/duplicate/reactivate and keeps D34 heuristic diagnostics and
strict enablement unavailable until archiving reduces the active count to 32
or fewer. No query silently truncates or selects a subset of those definitions.

Deletion refuses a current valid saved Trend or Breakdown reference to the
exact goal UUID and offers archive. The UUID is not a database foreign key
because D40 canonical state remains the source of truth. The guard compares
the structured Breakdown selector or a finite exact Trend-series form, never a
whole-document UUID substring. D43 extends that same guard to the exact
site-owned Goal-step shape in canonical funnel definitions.

### `funnel_definitions`

```sql
CREATE TABLE funnel_definitions (
    id TEXT PRIMARY KEY,
    site_id TEXT NOT NULL,
    name TEXT NOT NULL,
    canonical_definition_json TEXT NOT NULL,
    created_at_utc_micros INTEGER NOT NULL,
    updated_at_utc_micros INTEGER NOT NULL,
    archived_at_utc_micros INTEGER,
    FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
    UNIQUE (site_id, name),
    CHECK (length(id) = 36),
    CHECK (length(name) BETWEEN 1 AND 120),
    CHECK (length(canonical_definition_json) BETWEEN 2 AND 8192),
    CHECK (updated_at_utc_micros >= created_at_utc_micros),
    CHECK (
        archived_at_utc_micros IS NULL OR
        archived_at_utc_micros >= created_at_utc_micros
    )
);
```

Metadata schema 10 replaces the schema-9 `funnels` plus `funnel_steps`
pair with one complete mutable row. `canonical_definition_json` is exact
schema-1 JSON containing closed order, scope, window, and two through eight
ordered steps. Direct steps use exact Page, page-prefix, or Event selectors
with zero through three canonical D29 predicates of at most one scalar value
each. Goal steps store only a
stable goal UUID and resolve its complete current D42 selector.

Every load parses and reserializes the document and requires byte-identical
content. The decoded definition owns every step, selector, goal ID, property,
and predicate value for its allocator lifetime; it never borrows Turso row
storage. This is required because D44 may compile current and comparison
statements after the metadata cursor is closed. Direct predicate strings are
bytewise sorted and deduplicated. The
closed window seconds are `0`, `3600`, `86400`, `604800`, and `2592000`; zero
means same session. An active funnel has no archived timestamp.

Migration maps every valid predecessor definition to sequential, Sessions,
same-session, direct, predicate-free, active state with updated time equal to
created time. It requires two through eight contiguous steps and the original
application invariant `name = match_value` for each step. Invalid or
crash-incomplete predecessor rows fail closed. Copy verification precedes the
two source-table drops, and replay validates partial-copy,
child-dropped/parent-retained, and fully after-drop states before ledger 10.

Goal deletion checks only `kind=goal` step objects for the exact UUID in every
site-owned active or archived funnel. A matching string in a direct value or
predicate is not a reference. Archive preserves the row and reference; a
referenced archived or missing goal makes preview and execution stale until
the goal is reactivated or the step is replaced.

D44 changes no stored schema. Ordered funnel evaluation reads the same
append-oriented events through D34's product relation. Its plausible order is
`occurred_at_utc_micros`, `sequence`, `received_at_utc_micros`, then
`event_id`; this is a metric-v2 result and does not alter metric-v1's frozen
receipt ordering. Session scope uses stored `session_id`. Visitor scope uses
only the canonical persistent person derived from `identity_quality=1`,
`anonymous_id`, `user_id`, and `identity_links`; ephemeral and `legacy_daily`
step-one identities remain separate bounded coverage counts. All participating
events have `kind IN (1, 2)`, an eligible traffic class, and a
`site_local_date` inside the selected result range.

## 3. DuckDB events

### `event_migrations`

```sql
CREATE TABLE event_migrations (
    version INTEGER PRIMARY KEY,
    name VARCHAR NOT NULL,
    applied_at_utc_micros BIGINT NOT NULL
);
```

### `events` — event schema migration 7

```sql
CREATE TABLE events (
    event_schema_version UTINYINT NOT NULL,
    protocol_version UTINYINT NOT NULL,
    tracker_version UTINYINT NOT NULL,
    event_id UUID NOT NULL,
    site_id VARCHAR NOT NULL,
    received_at_utc_micros BIGINT NOT NULL,
    occurred_at_utc_micros BIGINT NOT NULL,
    received_date_utc DATE NOT NULL,
    site_local_date DATE NOT NULL,
    site_utc_offset_minutes SMALLINT NOT NULL,
    kind UTINYINT NOT NULL,
    event_name VARCHAR NOT NULL,
    path VARCHAR NOT NULL,
    page_title VARCHAR NOT NULL,
    hostname VARCHAR NOT NULL,
    anonymous_id UUID NOT NULL,
    identity_quality UTINYINT NOT NULL,
    user_id VARCHAR NOT NULL,
    session_id UUID NOT NULL,
    sequence UINTEGER NOT NULL,
    session_start BOOLEAN NOT NULL,
    referrer_host VARCHAR NOT NULL,
    country_code VARCHAR NOT NULL,
    language VARCHAR NOT NULL,
    browser_family VARCHAR NOT NULL,
    os_family VARCHAR NOT NULL,
    device_category VARCHAR NOT NULL,
    utm_source VARCHAR NOT NULL,
    utm_medium VARCHAR NOT NULL,
    utm_campaign VARCHAR NOT NULL,
    utm_term VARCHAR NOT NULL,
    utm_content VARCHAR NOT NULL,
    properties_json VARCHAR NOT NULL,
    user_traits_json VARCHAR NOT NULL,
    value_amount DECIMAL(18,6),
    value_currency VARCHAR NOT NULL,
    engagement_ms UINTEGER NOT NULL,
    max_scroll_depth UTINYINT NOT NULL,

    visitor_day_id BLOB NOT NULL,
    visitor_day_start BOOLEAN NOT NULL,
    event_payload_digest VARCHAR NOT NULL,
    traffic_class UTINYINT NOT NULL,
    classifier_version USMALLINT NOT NULL,
    bot_rule VARCHAR NOT NULL,
    signal_version UTINYINT NOT NULL,
    navigator_webdriver BOOLEAN NOT NULL,
    trusted_interactions UTINYINT NOT NULL,
    was_visible BOOLEAN NOT NULL,
    was_prerendered BOOLEAN NOT NULL,
    viewport_bucket UTINYINT NOT NULL,
    beacon_timing_bucket UTINYINT NOT NULL,
    client_hint_consistency UTINYINT NOT NULL,
    accept_language_present BOOLEAN NOT NULL,
    network_day_id BLOB NOT NULL,
    CHECK (traffic_class BETWEEN 1 AND 5),
    CHECK (signal_version BETWEEN 0 AND 1),
    CHECK (trusted_interactions BETWEEN 0 AND 15),
    CHECK (viewport_bucket BETWEEN 0 AND 4),
    CHECK (beacon_timing_bucket BETWEEN 0 AND 4),
    CHECK (client_hint_consistency BETWEEN 0 AND 3),
    CHECK (octet_length(network_day_id) = 16),
    CHECK (length(bot_rule) <= 64)
);

CREATE TABLE identity_links (
    site_id VARCHAR NOT NULL,
    anonymous_id UUID NOT NULL,
    user_id VARCHAR NOT NULL,
    linked_at_utc_micros BIGINT NOT NULL,
    event_id UUID NOT NULL,
    PRIMARY KEY (site_id, anonymous_id)
);
```

Conventions:

- `kind` values 1–4 are page view, custom event, engagement, and identify.
- `identity_quality` values 1–3 are persistent, ephemeral, and migrated
  legacy daily identity.
- `event_schema_version=7`; protocol/tracker versions are 1 for compatibility
  events and 2 for v2 envelopes.
- `traffic_class` values 1–5 are human-presumed, declared-bot, automation,
  excluded, and suspected. Classifier version zero marks honest historical
  rows, version 1 identifies D32 UA/exclusion classification, and version 2
  identifies D33 UA plus hard-signal evaluation. `bot_rule` is an empty or
  bounded classifier/exclusion rule ID. D32, D33, and
  `docs/UA_CLASSIFIER_V1.md` govern the permanent classifier.
- `signal_version=0` means the browser bundle was absent or historical and its
  client fields are unknown zeros/false values. Version 1 contains the closed
  D33 bundle. Trusted-interaction bits are 1 pointer move, 2 key down, 4 scroll,
  and 8 touch start. Viewport/timing codes use D33's four coarse positive
  buckets plus zero unknown.
- `client_hint_consistency` is 0 historical unknown, 1 consistent or not
  applicable, 2 mismatch, or 3 absent when expected. Only presence of a
  nonempty `Accept-Language` is stored. Raw hints, language, viewport, precise
  timing, and their hashes are never stored.
- `network_day_id` is secret-keyed and scoped to site plus receipt UTC date and
  normalized /24 or /48. Sixteen zero bytes mean historical unknown. Raw
  prefix, network-day bytes, and the rate limiter's unkeyed hash are never
  logged, rendered, or exported.
- Default-off product queries require stored `traffic_class IN (1, 5)` and keep
  D34 query-time suspects compatible. Strict mode additionally excludes only
  current query-classifier-v1 suspected sessions after every human-evidence
  veto. Exclusion remains diagnostic-only, and declared bots/automation are
  outside product metrics.
- `device_category` is again only a device dimension. Traffic classification
  never overloads it with `bot`.
- Absent optional strings are empty rather than `NULL` to simplify bounded
  grouping and decoding; only absent exact value amount is `NULL`.
- `properties_json` and `user_traits_json` are canonical bounded flat JSON.
  Keys are bytewise sorted. Strings, signed integers, exact scale-six decimals,
  booleans, and null retain distinct JSON types; absent remains distinct from
  explicit null.
- Property discovery, filters, and breakdown primitives use DuckDB 1.4.5's
  built-in JSON functions over these columns. Property names become bound JSON
  Pointer values after identifier validation; no request value becomes SQL and
  no extension download or EAV projection is used.
- `event_id` is supplied by protocol v2 and is site-idempotent. The internal
  digest is BLAKE3 over length-delimited normalized fields. D20's one writer
  checks `(site_id,event_id)` before insert; no secondary unique index is added
  to the million-row table without measured need.
- `session_id` is supplied by protocol v2. `session_start` is true only for the
  first committed `(site_id,session_id)` row. Protocol-v1 insertion retains its
  frozen derived session behavior.
- `received_at_utc_micros` is the authoritative server clock. Plausible client
  time is stored separately for timeline ordering.
- An identify event and a new `identity_links` row commit atomically. Repeating
  the same link is idempotent; a different user for the same anonymous identity
  rejects before either write.
- Canonical person keys are derived rather than stored: `u:<user_id>` for a
  linked identity, otherwise `a:<uuid>`, `e:<uuid>`, or `l:<uuid>` for
  persistent anonymous, ephemeral, or migrated legacy identity. Prefixes make
  the key spaces disjoint; only an explicit equal user ID combines devices.
- Latest user traits are derived from successful identify events for the same
  site and linked user. Selection is deterministic by plausible occurrence
  time, sequence, receipt time, and event ID in descending order. No mutable
  profile row or identity graph duplicates those events.
- `site_id` is duplicated deliberately. DuckDB does not enforce a foreign key
  into Turso.
- `visitor_day_id` and `visitor_day_start` are temporary compatibility columns
  consumed only by metric-v1 queries. They never define persistent identity.

Migration 3 performs a transactional create/backfill/swap. Existing rows keep
event IDs, receipt time/date, kind/name/path, sessions, dimensions, UTM, and
property bytes; occurrence equals receipt; protocol/tracker are 1; identity is
`legacy_daily` with one deterministic synthetic UUID per existing
`(site,date,visitor_day_id)`, derived from a fixed namespace and the exact tuple;
sequence follows stored session order; other new fields are empty/zero. Before
the source table is dropped, the same transaction proves the complete
preserved-field multiset, the new-field mapping, group/identity isolation,
and an empty identity-link table. Sequence is produced directly by the bounded
`row_number` backfill; an out-of-range cast fails the transaction. Migration 3
initially writes the shipped UTC date and offset zero. Issue #11 replaces those
placeholders under an explicit site zone before the site may serve; the
exact-baseline gate proves the rebucket and metric-v1 compatibility before
metric-v2 date queries consume those values.

Migration 4 performs a transactional create/backfill/swap. Before the swap it
compares source and target row counts plus XOR, sum, minimum, and maximum
aggregate fingerprints over every preserved field, then verifies every new row
has row schema 4 and `exclusion_source=0`. The streaming check stays inside the
fixed DuckDB memory budget even for the million-event gate. The migration
neither reclassifies historical traffic nor changes identity, session, time,
property, value, or metric-v1 compatibility facts.

Migration 5 performs another transactional create/backfill/swap and removes
`exclusion_source`. Nonzero sources map exactly to class excluded,
classifier version 1, legacy false, and rules `exclude.tracker`,
`exclude.network`, or `exclude.both`. Every old device `bot` value becomes
`unknown`, including excluded rows, because the lost UA cannot reconstruct the
device. Source-zero rows formerly marked with device `bot` map to class
declared-bot, classifier version 0, rule
`legacy-device-bot`, legacy true, and device `unknown`. Every other source-zero
row maps to class human-presumed, classifier version 0, empty rule, and legacy
false. No historical row is presented as classifier-v1 coverage.

Before swap, the streaming verifier checks source and target row counts plus
XOR, sum, minimum, and maximum aggregate fingerprints for all preserved
fields. The only permitted preserved-field exception is the documented legacy
device `bot` to `unknown` rewrite; a separate mapping check proves it exactly.
It also proves identity links unchanged, every row at schema 5, all closed
class/version/rule/legacy mappings, and absence of the temporary source column.
The million-row, interrupted, and repeated-upgrade gates stay inside the fixed
DuckDB limits. Rollback restores the verified pre-schema-5 database pair.

Migration 6 performs the same transactional create/backfill/swap from the
exact deployed schema-5 predecessor. It preserves every field except the
completed `legacy_bot_verdict` shadow byte, advances each row to schema 6, and
adds `signal_version=0`, false booleans, and zero buckets/consistency. These
values mean unavailable historical evidence and never claim that a discarded
header or browser fact was negative. Traffic class, classifier version, rule,
identity links, and every unrelated event fact remain byte-for-byte or
value-for-value preserved.

Before swap, the streaming verifier checks count plus XOR, sum, minimum, and
maximum fingerprints over all preserved fields, the complete zero-state
mapping, unchanged identity-link count/hash, and absence of
`legacy_bot_verdict` on the target table. The million-row interruption/retry,
repeat, matched backup, isolated restore, and old-binary rollback gates use the
exact schema-5 release. Product-query changes after migration are the explicit
D33 permanent-class promotion, not evidence loss or migration drift.

Migration 7 performs the same transactional create/backfill/swap from the
exact deployed schema-6 predecessor. It preserves every schema-6 field and
identity link, advances each row to schema 7, and adds a 16-byte all-zero
`network_day_id`. Zero means unavailable historical receipt evidence and is
never treated as a real prefix group. The verifier proves count plus XOR, sum,
minimum, and maximum preserved-field fingerprints, complete zero mapping,
unchanged links, and the target column length before swap.

Metadata migration 5 is separately append-only and backfills one default-off
traffic policy per site without modifying site, origin, timezone, exclusion,
auth, goal, or funnel facts. The exact metadata-4/event-6 upgrade gate kills
and retries the million-row event migration, verifies fresh/repeated upgrades,
backs up and independently restores the pair, and opens the restored pair with
the exact old binary. Rollback restores both old stores; neither database may
be rolled back alone.

## 4. Normalization

### Path

- Must be valid UTF-8 and begin with `/`.
- Maximum 1,024 encoded bytes.
- Query and fragment are discarded before persistence.
- Repeated slashes, case, and percent-encoding are not rewritten; changing
  those can change application semantics.
- A missing or invalid path rejects the event rather than becoming `/`.

### Referrer

- Parse using a URL parser with bounded input.
- Keep only the lowercase ASCII/punycode host.
- If the host matches any configured site origin, store an empty external
  referrer.
- Discard user info, port, path, query, and fragment.
- Protocol v1: invalid, absent, or policy-suppressed referrers become
  empty/direct.
- Protocol v2: absent and same-origin referrers become empty; a malformed
  referrer URL rejects the event.

### Campaigns

Only these case-sensitive query keys are retained:

```text
utm_source
utm_medium
utm_campaign
utm_term
utm_content
```

Each decoded value is valid UTF-8 and at most 256 bytes. All other URL query
keys are discarded.

### Custom events

Shared rules:

- Event name: 1–64 bytes, ASCII letters/digits plus `_`, `-`, `.`, and `:`.
- Property count: at most 16 unique identifier keys of 1–64 bytes.
- Scalar values only. Protocol v1 accepts string, signed integer, boolean, or
  null. Protocol v2 additionally accepts the exact decimal form below.
- Arrays, nested objects, non-finite/out-of-range numbers, and duplicate keys
  reject the whole event.

Protocol-v1 additional rules:

- Property keys must be allowlisted for the site.
- Encoded string value: at most 256 bytes.
- Canonical total JSON: at most 4,096 bytes.

Protocol-v2 additional rules:

- Property keys are not allowlisted at ingest; bounded DuckDB discovery reads
  the canonical JSON directly.
- Encoded string value: at most 512 UTF-8 bytes without control characters.
- Exact decimal property tokens use an optional minus, 1–12 integer digits, an
  explicit decimal point, and 1–6 fractional digits. Plus signs and exponents
  reject. Canonical JSON stores six fractional digits, matching
  `DECIMAL(18,6)` query values. Exact `value.amount` uses the same scale.

### Typed property query primitives

Property queries are site-scoped, use a half-open UTC instant range no longer
than 400 days, and optionally prefilter one exact event name. Event properties
read only custom-event rows; user traits read only identify rows. The source
column and every SQL fragment are selected by closed Zig enums.

- Discovery returns at most 100 bytewise-ordered property names and observed
  scalar types, with total-name metadata when more exist.
- Exact typed filters distinguish string, integer, decimal, boolean, null, and
  missing without coercion. Numeric compatibility beyond exact typed equality
  belongs to the typed AnalysisQuery work.
- Breakdown groups by `(type,value)`, includes separate null and missing
  buckets, orders by count then stable type/value ties, returns at most 100
  rows, and reports exact bucket cardinality/truncation.
- Property names use bound JSON Pointer paths. Site, time, event, value, and
  limits are bound values; arbitrary SQL and request-selected identifiers are
  impossible.

The million-event property fixture benchmarks this JSON-first design before an
EAV/projection table, cache, or new dependency may be considered.

## 5. Visitor pseudonym — metric v1

For each accepted event:

```text
day_key = BLAKE3_KEYED(master_key, "analytico/day/v1" || site_id || utc_date)
visitor_day_id = first_16_bytes(
    BLAKE3_KEYED(day_key, normalized_ip_prefix || coarse_client_key)
)
```

- `master_key` is a 32-byte secret file readable only by the service user.
- IPv4 is normalized to `/24`; IPv6 to `/48`.
- `coarse_client_key` is derived in memory from the user-agent into browser,
  OS, and device categories.
- Inputs and `day_key` are erased or released after derivation and never logged.
- A key change breaks unique/session continuity; rotation therefore begins at a
  UTC day boundary and is recorded as an operational event.

This is an approximation. People sharing a network prefix and coarse client
can collide; one person changing network/client can split. The product reports
daily pseudonyms, not identified humans.

## 6. Sessionization — metric v1

The collector commits events sequentially and server receipt time is
authoritative. In the same single bound insert statement that writes an event:

1. Find the latest already-committed event for the same site, UTC date, and
   `visitor_day_id`.
2. Set `visitor_day_start` when no such event exists.
3. Reuse its `session_id` when its receipt time is no more than 30 minutes
   earlier.
4. Otherwise set `session_start` and use the new event UUID as `session_id`.

Sessions never cross a UTC day boundary because the visitor pseudonym rotates.
The exact 30-minute boundary remains in the prior session; 30 minutes plus one
microsecond begins another. Report queries scan raw events and use these
persisted boundary facts instead of reconstructing the same windows. There is
no rollup table, background task, or cache. This rule is deterministic and
versioned as metric semantics v1.

## 7. Metric definitions — metric v1

### Page views

Count accepted `kind = 1` rows in the requested range.

### Daily unique visitors

Count product-eligible `visitor_day_start` rows. Under D33 this means
`traffic_class IN (1, 5)`. This is
equivalent to counting distinct daily pseudonyms because the one writer sets
exactly one eligible start for each site/date/pseudonym. For a multi-day
headline, sum those daily counts. The value is a visitor-day total, not a
cross-day person count.

### Popular pages

Group page views by normalized `path`. Return page views and distinct daily
pseudonyms, ordered by views descending then path ascending.

### Entry and exit pages

Within each computed session, entry is the first page-view path and exit is the
last page-view path. Sessions containing only custom events do not contribute.
Group and order by session count descending then path ascending.

### Referral sources

Use only the first page view in each session:

- empty external referrer is `Direct / Unknown`;
- otherwise group by normalized external referrer host.

This prevents internal navigation from inflating source counts.

### Campaigns

Use UTM values on the first page view in each session. Group by the requested
campaign dimension or by the full five-field tuple. Empty tuples are omitted
from campaign reports.

### Country, browser, OS, and device

Use the first product-eligible event in each session as the session dimension.
Return session count and distinct daily pseudonyms. Unknown is a visible
category. Traffic class is reported separately in diagnostics and never
appears as a device value.

### Custom events

Count `kind = 2` rows by exact `event_name`. A separate value reports distinct
sessions containing the event.

### Goal conversion

A goal matches the closed predicate stored in Turso. Report:

- total matching events/pageviews;
- sessions with at least one match;
- conversion rate = matching sessions / all eligible sessions in range.

A session converts a goal at most once.

### Funnel

For each session, steps must match in configured order with monotonically
increasing `(received_at_utc_micros, event_id)`. Other events may occur between
steps. One event cannot satisfy two steps. A session contributes at most once
to each step.

Report entrants, completions at each step, step-to-step rate, and overall rate.
Funnel evaluation is capped at eight steps and the requested date range is
bounded by the report contract.

## 8. Time ranges — metric v1

- Metric-v1 compatibility reports over event schemas 3, 4, and 5 use UTC only.
- CLI date input is `[start_date, end_date]`, converted to the half-open instant
  range `[start 00:00:00Z, day_after_end 00:00:00Z)`.
- Maximum interactive range is 400 days.
- Export may exceed 400 days only with an explicit offline flag and service
  stopped.
- The M0–M4 implementation deferred site-local time and DST-aware grouping.
  Decision D27 uses a bounded host-TZif reader for metric v2; the metric-v1
  compatibility query remains UTC-based.

## 9. Deletion

Deleting a site is two-phase:

1. Disable it in Turso so new events are rejected.
2. With the service stopped, delete its DuckDB `identity_links` and `events`
   rows, checkpoint, then delete the Turso parent with its foreign-key cascades
   as one durable statement.

Retention deletes expired `events` rows, then deletes `identity_links` whose
`(site_id, anonymous_id)` no longer exists in `events`.

The command reports row counts and produces a signed/hashed operator audit
record without visitor data. A failed second phase remains safely retryable.

## 10. Accepted Analytico 1.0 transition

Decisions D26–D28 establish protocol v2, DuckDB event schema 3, and metric
semantics v2 as a versioned extension rather than a reinterpretation of the
legacy fields. Issue #6 provides the collector/storage foundation, issue #7
provides tracker anonymous identity and `reset()`, and issue #8 provides
30-minute client session rotation. Issue #9 provides explicit identify,
canonical-person resolution, and latest-trait selection. Issue #10 provides
typed property canonicalization and DuckDB query primitives, and issue #11
provides explicit TZif-backed site-local dates. Issue #13 provides the exact
legacy migration, mixed-data coverage, and rollback evidence. Issue #12
provides the tracker SPA, engagement/scroll, exact value, and opt-in automatic
event producers for those schema-3 fields. D31 and issue #67 advance the table
to schema 4 with a temporary stored self-exclusion source while preserving the
schema-3 facts. D32 and issue #68 consume every temporary source into schema 5,
separate the permanent traffic class from device, and retain one deployed
release of observable old/new classifier shadow evidence.
D33 and issue #69 advance to schema 6 with bounded browser/receipt evidence,
end the completed shadow, and promote permanent-class product eligibility.
D34 and issue #70 advance to event schema 7 and metadata 5, add only keyed
daily-prefix evidence plus explicit site safeguards, and keep soft verdicts in
the reversible query layer. D36 and issue #19 advance metadata to schema 6,
store the explicit optional site currency, and make origin ownership unique;
event schema 7 and every stored event fact remain unchanged. D40 and issue #30
advance metadata to schema 7 with exact site-owned segments and saved views.
D41 and issue #33 advance metadata to schema 8 with a guided active/archive
goal lifecycle while preserving selectors and stable IDs. D42 and issue #34
advance metadata to schema 9 with one exact canonical property-predicate
document per goal. The controller resolves canonical state before DuckDB, so
neither store queries the other;
current valid saved-goal references block deletion, while genuinely stale or
corrupt references remain visible rather than disappearing.

### Identity and sessions

- New compatible tracker events carry a random site-scoped first-party
  anonymous UUID and a random session UUID plus sequence. Sessions rotate
  after more than 30 minutes of inactivity and may cross UTC midnight.
- An optional bounded application user ID may link several anonymous IDs. One
  anonymous ID maps to at most one user until `reset()` creates a new anonymous
  identity; a conflicting link is rejected rather than merged.
- Storage-unavailable events use a page-lifetime ephemeral identity. No IP/UA
  fingerprint, cross-site identity, or claim of real-person identity is added.
- Visitor and user identifiers remain untrusted analytics data. They are
  bounded, escaped, unavailable to authorization decisions, and visible only
  to the authenticated operator.

### Legacy compatibility

- Schema-2 rows migrate with `identity_quality=legacy_daily`. A deterministic
  synthetic anonymous UUID is scoped only to `(site_id, received_date_utc,
  visitor_day_id)` and is never linked across dates.
- Existing event IDs, timestamps, fields, session IDs, and metric-v1 report
  totals remain preserved. Mixed-data reports expose compatibility coverage.
- New/returning classification, retention, cross-session visitor funnels, and
  user profiles exclude legacy or ephemeral identities unless the result is
  explicitly limited and labeled.

### Site-local dates

- Every site stores an explicitly selected IANA timezone. UTC is a valid
  explicit choice; a server-inferred zone may be suggested but is never
  silently selected.
- Ingestion keeps authoritative UTC receipt time and also stores the derived
  site-local date and UTC offset using a bounded TZif v2/v3 reader. Reports use
  those stable stored dates for date-level metric-v2 grouping.
- The reader uses the configured absolute zoneinfo root (default
  `/usr/share/zoneinfo`), the 64-bit TZif data block, and a bounded footer rule
  when future transitions depend on it. Leap-second files, malformed data,
  traversal-bearing names, missing files, and offsets that cannot be stored as
  exact minutes fail closed.
- A site's zone is locked after its first event during ordinary operation.
  Initial assignment or a later change with events requires the service to be
  stopped, an explicit offline rebucket, validation, and checkpoint. The
  metadata stays pending until the DuckDB transaction succeeds, so a partial
  cross-store operation cannot become a serving policy.

### Migration and rollback

Migration requires the service to be stopped or not ready, an explicit zone
for every existing site, and a verified Turso/DuckDB backup pair. It validates
row counts, preserved bytes and IDs, metric-v1 totals, session IDs, local dates
around DST, and absence of legacy identity links before swap. Rollback restores
the pre-migration database pair because an older binary may not read schema 3.

Backup manifest schema 1 remains the pair format for supported historical and
current stores; it records the actual metadata/event migration versions. A
real legacy upgrade accepts only a verified backup whose hashes and versions
match the live legacy files. Ordinary commands require current schemas and
never trigger the upgrade. The event file's conservative copy/WAL allowance is
checked against filesystem availability before DuckDB begins the transaction.

For a bounded site-local meaningful-event range, identity coverage reports
distinct canonical people split into persistent-compatible, ephemeral, and
`legacy_daily` counts, plus persistent basis points and the site's first
persistent local date. Metric-v1 result shapes remain frozen; metric-v2 callers
compose this metadata rather than reinterpreting old visitor-day totals.

Metric-v2 ordinary Trend/Breakdown queries follow `ANALYSIS_QUERY.md` and D29.
They read schema-3 facts in place, use site-local dates, canonical identity,
explicit session/person filter scopes, and exact value/currency groups. They do
not add a projection, EAV table, rollup, cache table, or migration. Existing
metric-v1 queries continue to read their UTC visitor-day compatibility columns.

D39 adds no event fact or projection. Its browser property catalog reads the
latest 2,000 eligible schema-7 custom-event JSON documents under the same
site-local product/strict relation and shared deadline as the selected
Breakdown. One process-local entry may retain that sampled catalog for 30
seconds; it is suggestion state, not an analytics fact, and exact results are
never cached. One optional bound search matches aggregate labels before stable
pagination; exact result cardinality is the matching typed bucket count. Null
and missing remain distinct explicit scalar states, and conflicting observed
types are displayed rather than coerced.

`METRIC_SEMANTICS_V2.md` and D30 define the additive traffic-quality diagnostic
bridge. D31 version 2 adds explicit stored exclusions. D32 version 3 reports
schema-5 classes, classifier coverage, bounded rule totals, and the one-release
legacy/new disagreement cells while retaining the same received-UTC Overview
range. D33 version 4 replaces that completed shadow with permanent class/rule
totals plus fixed bounded signal-evidence counts. It never reinterprets legacy
daily identities as persistent people and no accepted event is dropped.
D34 version 5 adds query candidate/current-suspect/contradiction evidence,
strict state, accepted-ceiling health, and keyed identity-mint anomaly counts.
The operational ceiling returns an explicit 429 for a new over-cap request;
every successfully accepted event remains stored and visible.

## 17. Derived session-list facts

D45 adds no durable session row. A list request derives candidate session UUIDs
from schema-7 product-eligible Page/custom events in one site-local range, then
expands only the bounded page from the same `events` and `identity_links`
tables. Full retained summaries use the site plus session UUID as the key;
session UUID alone is never treated as globally authoritative.

Derived fields are start/last plausible occurrence, latest authoritative
receipt, Page/custom counts, engagement sum, first-page acquisition and
landing, first-meaningful geography/client dimensions, canonical identity,
current active-Goal match count, and exact per-currency value totals. These are
query results, not mutable facts. Retention or a late accepted event may change
a later result honestly. Event schema 7, metadata schema 10, backup format, and
all migration rows remain unchanged.
