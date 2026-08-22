# Data model and metric semantics

> **Status:** Sections 1–9 define the shipped analytics-metadata subset in
> Turso, DuckDB event schema 3, and metric semantics v1. Authentication storage
> remains governed by its own specification. The daily-pseudonym and UTC-day
> rules remain the compatibility contract for existing rows and current
> reports. Section 10 records the remaining 1.0 transition; event schema 3 does
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
DeviceCategory       desktop | mobile | tablet | bot | other | unknown
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
```

An origin is an exact normalized `scheme://host[:port]`. Wildcards are not
accepted in the MVP.

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

### `goals`

```sql
CREATE TABLE goals (
    id TEXT PRIMARY KEY,
    site_id TEXT NOT NULL,
    name TEXT NOT NULL,
    match_kind INTEGER NOT NULL,
    match_value TEXT NOT NULL,
    created_at_utc_micros INTEGER NOT NULL,
    FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
    UNIQUE (site_id, name)
);
```

Closed `match_kind` values:

1. exact custom-event name;
2. exact page path;
3. page-path prefix.

Regexes and property predicates are not in the MVP.

### `funnels` and `funnel_steps`

```sql
CREATE TABLE funnels (
    id TEXT PRIMARY KEY,
    site_id TEXT NOT NULL,
    name TEXT NOT NULL,
    created_at_utc_micros INTEGER NOT NULL,
    FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE,
    UNIQUE (site_id, name)
);

CREATE TABLE funnel_steps (
    funnel_id TEXT NOT NULL,
    step_index INTEGER NOT NULL,
    name TEXT NOT NULL,
    match_kind INTEGER NOT NULL,
    match_value TEXT NOT NULL,
    PRIMARY KEY (funnel_id, step_index),
    FOREIGN KEY (funnel_id) REFERENCES funnels(id) ON DELETE CASCADE,
    CHECK (step_index BETWEEN 0 AND 7)
);
```

A funnel has 2–8 steps. Steps use the same closed match kinds as goals.

## 3. DuckDB events

### `event_migrations`

```sql
CREATE TABLE event_migrations (
    version INTEGER PRIMARY KEY,
    name VARCHAR NOT NULL,
    applied_at_utc_micros BIGINT NOT NULL
);
```

### `events` — event schema migration 3

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
    event_payload_digest VARCHAR NOT NULL
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
- `event_schema_version=3`; protocol/tracker versions are 1 for compatibility
  events and 2 for v2 envelopes.
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

Count non-bot `visitor_day_start` rows. This is equivalent to counting distinct
daily pseudonyms because the one writer sets exactly one start for each
site/date/pseudonym. For a multi-day headline, sum those daily counts. The value
is a visitor-day total, not a cross-day person count.

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

Use the first non-bot event in each session as the session dimension. Return
session count and distinct daily pseudonyms. Unknown is a visible category.
Bots are excluded from product reports and counted separately in diagnostics.

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

- Metric-v1 compatibility reports over event schema 3 use UTC only.
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
   rows, checkpoint, then delete the Turso configuration in a transaction.

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
legacy migration, mixed-data coverage, and rollback evidence; issue #12 owns
the remaining tracker SPA/engagement behavior.

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
