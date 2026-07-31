# Data model and metric semantics

This document is the contract for durable fields and reported numbers. SQL
shown here is a logical schema; M1 must validate the exact syntax against the
pinned Turso and DuckDB versions and compile the final numbered migrations into
the binary.

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

### `events`

```sql
CREATE TABLE events (
    schema_version UTINYINT NOT NULL,
    event_id UUID NOT NULL,
    site_id VARCHAR NOT NULL,
    received_at_utc_micros BIGINT NOT NULL,
    received_date_utc DATE NOT NULL,
    kind UTINYINT NOT NULL,
    event_name VARCHAR NOT NULL,
    path VARCHAR NOT NULL,
    visitor_day_id BLOB NOT NULL,
    session_id UUID NOT NULL,
    visitor_day_start BOOLEAN NOT NULL,
    session_start BOOLEAN NOT NULL,
    referrer_host VARCHAR NOT NULL,
    country_code VARCHAR NOT NULL,
    browser_family VARCHAR NOT NULL,
    os_family VARCHAR NOT NULL,
    device_category VARCHAR NOT NULL,
    utm_source VARCHAR NOT NULL,
    utm_medium VARCHAR NOT NULL,
    utm_campaign VARCHAR NOT NULL,
    utm_term VARCHAR NOT NULL,
    utm_content VARCHAR NOT NULL,
    properties_json VARCHAR NOT NULL
);
```

Conventions:

- `kind = 1` is a page view and `event_name = 'pageview'`.
- `kind = 2` is a custom event.
- Absent optional strings are empty rather than `NULL` to simplify bounded
  grouping and decoding.
- `properties_json` is canonical flat JSON produced by the application. The
  MVP stores it for export but does not run goal or funnel SQL against it.
- `event_id` is an application-generated UUID. It supports audit
  correlation and later deduplication but no index is added without evidence.
- `session_id` is the UUID of the first accepted event in the session.
  `visitor_day_start` and `session_start` are event-local boundary facts, not
  aggregate counters. DuckDB event migration v2 derives all three for v1 rows.
- `received_at_utc_micros` is the server clock. Client time is not accepted as
  authoritative.
- `site_id` is duplicated deliberately. DuckDB does not enforce a foreign key
  into Turso.

No secondary index is selected initially. The expected workload is an
append-oriented table scanned by site and date; M0 measures the actual plan.

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
- Invalid, absent, or policy-suppressed referrers become empty/direct.

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

- Event name: 1–64 bytes, ASCII letters/digits plus `_`, `-`, `.`, and `:`.
- Property count: at most 16.
- Property key: 1–64 bytes and must be allowlisted for the site.
- Property scalar value: string, integer, boolean, or null.
- Encoded value: at most 256 bytes.
- Canonical total JSON: at most 4,096 bytes.
- Arrays, nested objects, floating-point special values, and duplicate keys are
  rejected.

## 5. Visitor pseudonym

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

## 6. Sessionization

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

## 7. Metric definitions

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

## 8. Time ranges

- Storage and MVP reports use UTC only.
- CLI date input is `[start_date, end_date]`, converted to the half-open instant
  range `[start 00:00:00Z, day_after_end 00:00:00Z)`.
- Maximum interactive range is 400 days.
- Export may exceed 400 days only with an explicit offline flag and service
  stopped.
- Site-local time zones and DST-aware grouping are deferred because they would
  require a timezone-data dependency and change session semantics.

## 9. Deletion

Deleting a site is two-phase:

1. Disable it in Turso so new events are rejected.
2. With the service stopped, delete its DuckDB rows, checkpoint, then delete the
   Turso configuration in a transaction.

The command reports row counts and produces a signed/hashed operator audit
record without visitor data. A failed second phase remains safely retryable.
