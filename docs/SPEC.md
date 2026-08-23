# Product specification

> **Status:** This document defines the shipped MVP and its later accepted
> dashboard increments. The target product scope for Analytico 1.0 is
> [`SCOPE_1.0.md`](SCOPE_1.0.md); planned 1.0 behavior is not shipped behavior
> until its implementation and acceptance evidence land. Statements labeled
> “MVP” below are the historical M0–M4 and metric-v1 contract, not timeless
> constraints on the approved 1.0 target.

## Version boundary

- The frozen protocol-v1 path uses cookieless daily pseudonyms, UTC report
  dates, and sessions that cannot cross UTC midnight. Those semantics remain
  metric v1 and continue to govern compatibility rows and current reports.
- Decision D28 implements the additive protocol-v2 collector and event-schema-3
  storage foundation. Issue #7 implements protocol-v2 tracker anonymous identity
  and `reset()`. Issue #8 implements 30-minute client session rotation. Issue #9
  implements explicit identify, conflict handling, and derived person/trait
  resolution. Issue #10 implements typed property canonicalization and bounded
  DuckDB property primitives, while issue #11 implements explicit TZif-backed
  local dates. Issue #13 implements the exact legacy migration and mixed-data
  coverage evidence. Issue #12 implements bounded SPA, engagement/scroll,
  exact value/currency, and opt-in automatic tracker behavior.
  Issue #24 defines the separate closed metric-v2 AnalysisQuery/compiler
  boundary without changing metric-v1 reports. Schema 3 does not retroactively
  turn visitor-days into people or claim the later product routes and views are
  complete. D31 and issue #67 advance stored events to schema 4 for explicit
  self-exclusion, close prerender and ephemeral-identity inflation, and retain
  every observed self-excluded row for diagnostics. D32 and issue #68 advance
  to schema 5, consume every temporary marker into permanent traffic class,
  separate device from traffic classification, and retain one release of
  visible old/new classifier shadow evidence without storing raw UAs.
  D33 and issue #69 advance to schema 6, store only bounded browser/receipt
  evidence, add webdriver and client-hint-mismatch hard rules, end the completed
  shadow, and promote the permanent class predicate. D34 and issue #70 advance
  to event schema 7 plus metadata schema 5, derive reversible query-time
  suspected sessions, add an explicit default-off strict policy and daily
  ceiling, and retain only secret-keyed site/receipt-day network evidence for
  bounded identity-mint warnings.
- The server-rendered dashboard now uses the six-destination, site-scoped
  shell: Overview, Analyze, Journeys, Sessions, Live, and Settings. `/admin`
  and the bounded legacy `site`/`report` query form redirect to the closest
  canonical route for one compatibility release. HTML, native navigation, and
  ordinary forms remain the application baseline; HTMX is optional enhancement
  over the same complete documents.

## 1. Product statement

Analytico answers a small set of website-usage questions without requiring a
general analytics platform:

1. How many pages were viewed?
2. Roughly how many people visited each day?
3. Which pages brought them in and where did they leave?
4. Which referrers and campaigns brought useful traffic?
5. What coarse country and client categories were used?
6. Which declared actions and ordered funnels converted?

It is optimized for a handful of sites receiving approximately 20–50 unique
visitors per week in total. The design must remain correct if the event count
grows by several orders of magnitude, but it does not pay the operational cost
of a distributed analytics system in advance.

## 2. Users

### Site owner

The site owner registers a site, installs the tracker, defines goals or
funnels, runs reports, exports data, and removes data. In the MVP those actions
are local CLI commands.

### Website visitor

The visitor may generate a page view or a custom event. No account, cookie,
local-storage identifier, or persisted raw IP address is required.

### Operator

The operator deploys one service, protects secrets, monitors health, creates
verified backups, upgrades the binary, and can restore the two embedded files.

## 3. Functional requirements

### F1. Sites

- Create, list, disable, and delete sites.
- Give each site a public random identifier.
- Allow one or more exact origins per site.
- Treat all configured origins as operator-controlled input, not request input.

### F2. Page views

- Accept a page view through a small POST request.
- Provide a non-JavaScript pixel endpoint for server-rendered sites.
- Store the normalized path, receipt time, external referrer host, recognized
  UTM fields, daily visitor pseudonym, and coarse dimensions.
- Never persist the full current URL or arbitrary query parameters.

### F3. Custom events

- Protocol v1 accepts a declared event name and a bounded allowlisted flat
  property map. Protocol v2 accepts bounded non-allowlisted flat properties and
  identify traits for later authenticated analysis.
- Support events such as `signup`, `download`, and `purchase`.
- Reject nested values, oversized names or values, and disallowed property
  keys where the selected protocol requires an allowlist before database work
  begins.
- Protocol-v2 string, signed-integer, exact scale-six decimal, boolean, and null
  values retain type; missing remains distinct from null. Bounded discovery,
  exact typed filtering, and breakdown query canonical JSON in DuckDB without
  property pre-registration.
- Do not add revenue accounting to the MVP; a purchase is initially a named
  conversion event with optional allowlisted descriptive properties.

### F4. Reports

For a site and inclusive UTC date range under metric v1, report:

- page views;
- daily unique visitors;
- views and daily uniques by page;
- entry and exit pages based on 30-minute sessions;
- direct traffic and external referral hosts;
- UTM source, medium, campaign, term, and content;
- country, browser family, operating-system family, and device category;
- custom-event counts;
- goal conversions and converting sessions;
- ordered same-session funnel entrants, step completions, and conversion rates.

Every list has an explicit order, stable tie-breaker, default limit, and maximum
limit. Exact metric semantics are defined in [DATA_MODEL.md](DATA_MODEL.md).
Default reports include query-time suspected sessions. An explicitly enabled
strict policy excludes only current suspects through the shared versioned
product relation; trusted interaction, engagement, scroll, later activity,
goal conversion, or persistent return vetoes that verdict. Traffic-quality
diagnostics remain visible independently of strict mode.

### F5. CLI

The production MVP provides these command families:

```text
analytico init
analytico site add|list|disable|delete|timezone-set
analytico goal add|list|delete
analytico funnel add|show|delete
analytico serve
analytico report
analytico export
analytico backup
analytico restore --verify
analytico maintain
analytico doctor
```

Commands use explicit paths or the same validated configuration file as the
service. Destructive commands require the exact site slug and an explicit
confirmation flag when stdin is not interactive.

Site creation requires an explicit IANA timezone. Existing sites upgraded to
metadata schema 3 require `site timezone-set`; a site that already has events
requires the service to be stopped and the explicit offline-rebucket flag.

### F6. Tracker

- A vendored, cacheable tracker is a small browser-only island.
- The tracker sends only data that the collector protocol permits.
- It handles ordinary navigation and explicitly reported custom events.
- Single-page-application navigation is not an MVP requirement.
- A documented `<noscript>` pixel records ordinary page views without
  JavaScript when the embedding site supplies the path.

### F7. Operations

- Run as one unprivileged process behind Caddy.
- Use local persistent storage, not network-mounted database files.
- Expose loopback-only liveness and readiness endpoints.
- Produce bounded structured logs without visitor identifiers or payloads.
- Expose the explicit per-site daily accepted-event ceiling and strict traffic
  setting through authenticated native forms, with visible bounded health
  evidence rather than silent collection loss.
- Support a tested stop-the-service backup and restore procedure.

## 4. Non-functional requirements

### Trustworthiness

- Server receipt time is authoritative.
- Metric definitions are versioned and tested with hand-checkable fixtures.
- Unknown country or client dimensions remain `unknown`; they are never guessed.
- Daily uniques are explicitly described as an approximation and never marketed
  as identified people.
- Reports expose their UTC range and applied filters.
- Partial upstream/enrichment failure does not invent data.
- Query-time traffic suspicion is labeled rather than asserted as a person
  verdict, remains reversible, and exposes its standing contradiction rate.

### Historical metric-v1 privacy

- No cookies or local storage in the MVP.
- No raw IP address or full user-agent string is persisted.
- A network prefix used for schema-7 anomaly evidence is persisted only as a
  secret-keyed 16-byte value scoped to site and receipt UTC date; the bytes are
  never logged, rendered, or exported.
- Visitor pseudonyms rotate at the UTC day boundary and are site-scoped.
- Only recognized UTM keys survive URL parsing.
- Referrers are reduced to a normalized host; paths and query strings are
  discarded.
- Custom property names and values are bounded and allowlisted per site.

### Security

- Origin validation, input validation, rate limiting, and request-size limits
  happen before database writes.
- The reverse-proxy trust boundary for the client IP and country header is
  explicit.
- SQL structure comes only from compiled application templates. Request values
  are bound.
- DuckDB external access and extension loading are disabled in the serving
  process.
- Administration is available through the local CLI and the loopback dashboard;
  passkey sessions plus exact-origin/CSRF checks protect the latter. Caddy
  forwards only the documented public collection and `/admin` path sets.

### Performance

- A valid collection request performs one bounded parse, one classification,
  and one transaction containing the bounded site/day ceiling check plus its
  durable event/link work.
- Reports query on demand; there is no always-running aggregation worker.
- The performance and resource budgets in
  [PERFORMANCE.md](PERFORMANCE.md) are release gates.

## 5. Historical M0–M4 non-goals

The following were not part of the M0–M4 production MVP. They do not override
the later accepted dashboard increments or the 1.0 scope contract:

- HTMX or any other browser application runtime;
- organization, team, invitation, or billing systems;
- real-time concurrent-view counters;
- session replay, heat maps, fingerprinting, or cross-site identity;
- automatic email reports;
- arbitrary user-defined SQL;
- custom dimensions without an allowlist;
- multi-region or multi-process DuckDB writes;
- mobile SDKs;
- automatic import of Plausible history;
- exact identification of a person across multiple days.

## 6. Success criteria

The production MVP is successful when:

1. A new site can be registered and begin recording page views using one
   documented snippet.
2. Every required report can be produced from the CLI after a real browser and
   collector write to disposable on-disk databases.
3. Restart, crash-recovery, backup, restore, and upgrade rehearsals pass.
4. Input and query limits hold under adversarial tests.
5. Debug and ReleaseSafe gates pass from a clean checkout with exact pins.
6. The measured footprint remains within the M0 budgets.
7. A release artifact and direct-cutover runbook are ready for the owner to
   replace Plausible without requiring a parallel collection period.

## 7. Server-rendered UI

The M6 UI remains deliberately downstream of the product core:

1. A controller loads Turso configuration and DuckDB report rows.
2. It creates an owned, typed view model.
3. A deterministic renderer writes a full HTML response without I/O.
4. Links and forms work with JavaScript disabled.
5. M7 may enhance the same endpoints with body-level swaps of the same complete
   server HTML; it does not introduce a fragment renderer or second state model.

The implemented UI does not fetch JSON after receiving the same state in HTML.
It does not open the DuckDB file from a second process. The later Cloudio
integration selected the ownership-safe ordinary-link boundary in decision
D22.
