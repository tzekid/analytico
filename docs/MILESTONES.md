# Milestones

Milestones are sequential unless a task explicitly says otherwise. “Done”
means every checkbox passes in both Debug and ReleaseSafe where applicable;
demonstrating a happy path is not sufficient.

## Release map

```text
M0 viability
  → M1 durable core
    → M2 collection
      → M3 complete reports (functional MVP)
        → M4 production hardening (production MVP)
          → M5 direct-cutover handoff
            → M6 server HTML
              → M7 HTMX enhancement
                → M8 optional Cloudio integration

M9 scale work is trigger-based, not scheduled.
```

## M0. Architecture and embedded-storage viability

### Outcome

Prove or reject the proposed one-process Turso + DuckDB architecture with the
real pins and target VPS constraints.

### Work

- Integrate the exact `turso.zig` commit from `versions.json`.
- Integrate DuckDB 1.4.5 LTS through a minimal direct C wrapper.
- Record immutable package/artifact hashes and licenses.
- Open, migrate, write, query, checkpoint, close, reopen, and recover one file
  for each engine.
- Generate a deterministic million-event fixture that exercises scan,
  distinct-visitor, and ordered-funnel workloads. M3 owns the complete semantic
  fixture across every promised report dimension.
- Implement enough real two-store SQL to exercise overview, entry, and funnel
  workloads.
- Build the benchmark and recovery harness.

### Definition of done

- [x] A clean checkout fetches exact inputs and never resolves a moving branch.
- [x] No generated native binary is committed; the official DuckDB runtime is
      fetched by verified package hash and Turso is built from exact source.
- [x] `zig build`, `zig build test`, and both ReleaseSafe equivalents pass.
- [x] Both engines pass fresh-file, reopen, and corrupt/truncated-copy failure
      tests through separate real processes without touching original fixtures.
- [x] The direct C wrapper has explicit database, result, and statement owners,
      and exercised native failures clean up before returning.
- [x] The million-row benchmark record follows `PERFORMANCE.md` and states
      where the initial one-sample evidence is not yet a percentile claim.
- [x] The two-store build satisfies the installed-size, peak-RSS, settings, and
      report-latency budgets using actual measurements.
- [x] Report fixture results match hand-computed expected values through the
      real executable and real on-disk databases.
- [x] DuckDB disables external access/community extensions and enforces one
      thread plus explicit memory and temp limits. M3 owns deadline interruption.
- [x] D04 and D05 are Accepted using measured evidence.

## M1. Durable domain and administration core

### Outcome

Create sites, goals, funnels, and events without HTTP or a web UI.

### Work

- Implement plain domain types and bounded validation.
- Compile numbered Turso and DuckDB migrations into the binary.
- Implement explicit metadata operations for sites, origins, property
  allowlists, goals, funnels, and steps.
- Implement direct durable event insertion and owned decoding.
- Implement CLI commands: `init`, `site`, `goal`, `funnel`, `doctor`.
- Implement visitor pseudonym derivation with injected clock/network fixtures.

### Definition of done

- [x] All schemas in `DATA_MODEL.md` have reviewed migration equivalents.
- [x] Fresh migration and the only supported v0-to-v1 path are replayable and
      produce schema version 1 in both stores.
- [x] Newer unknown schema versions fail closed with a useful local error.
- [x] CLI creates/lists/disables/deletes metadata using explicit confirmation
      for destructive actions.
- [x] Real CLI scenarios cover funnel, origin, slug, path, event, property,
      UUID, time-range, malformed UTF-8, and duplicate-input boundaries against
      disposable on-disk databases.
- [x] Pseudonym fixtures prove site scoping, daily rotation, IPv4 `/24`, IPv6
      `/48`,
      normalization, determinism, and key sensitivity without logging raw data.
- [x] An accepted event survives process termination after commit and reopening.
- [x] No M1 domain or application module imports HTTP, HTML, or CLI modules.
- [x] Debug/ReleaseSafe builds and real-process fault/recovery scenarios pass.
- [x] Temporary unit tests, mock stores, or in-memory substitutes used during
      feature development are removed unless they still catch a distinct
      production-path failure not covered end to end.

## M2. Collection MVP

### Outcome

Low-traffic websites can send page views and custom events safely, with or
without JavaScript for ordinary page views.

### Work

- Implement the narrow standard-library HTTP server and route switch.
- Implement protocol v1 POST and pixel endpoints.
- Implement exact-origin validation and proxy trust.
- Implement fixed-capacity rate limiting.
- Implement country/client classification with explicit unknown categories.
- Produce, minify, precompress, checksum, and license the tracker.
- Provide copy-paste ordinary and `<noscript>` snippets.

### Definition of done

- [x] Every status and header in `PROTOCOL.md` has a byte-level integration test.
- [x] Oversized target/header/body requests are rejected before unbounded
      allocation or database work.
- [x] Real HTTP requests cover duplicate keys, nesting, invalid UTF-8, numeric
      edges, unknown fields, and content-type/encoding variants.
- [x] Origin/referrer tests cover allowed, cross-site, absent, malformed,
      default ports, punycode, spoofed forwarded headers, and disabled sites.
- [x] Rate-limit memory remains fixed under at least 100,000 distinct spoofed
      prefixes, and excess input gets `429`.
- [x] Raw IP, raw UA, complete URLs, referrer paths, query strings, and payloads
      are absent from database files and captured logs in an end-to-end audit.
- [x] Tracker works in current Chromium/Firefox/WebKit fixtures, stays within
      byte budgets, creates no storage, and causes exactly one page-view request.
- [x] `<noscript>` fixture records a correct page view with JavaScript disabled.
- [x] A custom `signup` event with an allowlisted property is committed; a
      disallowed property is rejected.
- [x] Collection latency/resource budgets pass in Debug diagnostics and
      ReleaseSafe measurement runs.
- [x] SIGTERM drains/interrupts within the shutdown budget without accepting an
      uncommitted event.

## M3. Complete CLI reporting — functional MVP

### Outcome

Every promised analytics question can be answered correctly from the CLI.

### Work

- Implement typed report requests/results.
- Implement on-demand DuckDB SQL for overview, pages, entry/exit, sources,
  campaigns, geography/client, custom events, goals, and funnels.
- Implement stable pagination and table/JSON/CSV renderers.
- Implement the two-second interactive query deadline and interruption.
- Version metric semantics as v1.

### Definition of done

- [ ] Every metric in `DATA_MODEL.md` matches hand-checkable fixtures including
      midnight, 30-minute boundary, tie timestamps, internal referrer, direct
      traffic, unknown client/country, bots, repeated goal events, and interleaved
      funnel events.
- [ ] Multi-day unique output is visibly named/described as daily uniques or
      visitor-days.
- [ ] Every list has deterministic order, stable tie-break, default limit,
      maximum limit, and next-page behavior.
- [ ] Empty sites/ranges produce useful zero/empty output, not errors or missing
      fields.
- [ ] Invalid ranges, sort values, filters, and funnel definitions fail before
      DuckDB query work.
- [ ] JSON and CSV stream without materializing unbounded results; escaping and
      formula-injection policy are tested.
- [ ] No report query contains request-formatted SQL; values are bound and sort
      choices select closed templates.
- [ ] Slow-query fixture is interrupted at the deadline and the connection
      remains reusable or is safely replaced.
- [ ] Million-event overview and funnel budgets pass.
- [ ] Debug and ReleaseSafe checks pass from a clean checkout.

At this point Analytico is a functional MVP for a developer/operator, but it is
not yet approved for unattended production.

## M4. Production hardening and VPS deployment — production MVP

### Outcome

The functional MVP can safely replace a small self-hosted analytics stack.

### Work

- Implement explicit `migrate`, `backup`, `restore --verify`, `maintain`,
  `export`, and production `doctor`.
- Ship hardened systemd and Caddy examples.
- Add structured non-sensitive logs, readiness, counters, and disk-full
  behavior.
- Add release packaging, checksums, notices, and an upgrade/rollback runbook.
- Rehearse isolated backup, restore, migration, and prior-binary rollback.

### Definition of done

- [ ] A fresh VPS-style directory can be installed from the release artifact
      with one service process and no database container.
- [ ] The service runs unprivileged with the intended filesystem and cgroup
      restrictions.
- [ ] Caddy exposes only collection/tracker routes and overwrites trust headers.
- [ ] Readiness fails within five seconds of either store becoming unusable and
      recovers honestly after restart.
- [ ] Stop/checkpoint/copy/hash/isolated-restore procedure is automated and
      succeeds twice on representative data.
- [ ] A deliberately corrupted backup, wrong manifest, newer schema, wrong key
      permission, disk-full fixture, and interrupted migration each fail safely.
- [ ] `maintain` enforces the 400-day rule and site deletion, reports counts, and
      does not touch rows outside its explicit predicate.
- [ ] Previous binary plus pre-migration backup rollback is rehearsed.
- [ ] Logs pass a denylist scan for raw visitor/request data and secrets.
- [ ] Installed size, idle/peak RSS, startup, insert, report, and shutdown
      budgets pass on the target VPS.
- [ ] Dependency license/notices and exact source provenance are included.
- [ ] Debug and ReleaseSafe full gates pass from the release archive.

Completion of M4 is the **proper production MVP**.

## M5. Direct-cutover package and handoff

### Outcome

Prepare the finished product for the owner to replace Plausible directly.

### Work

- Produce the final release archive and checksums.
- Generate per-site tracker/CSP installation examples.
- Measure operational resource use with a real local/VPS-style deployment.
- Make optional Plausible history export a separate documented command.
- Rehearse fresh initialization, site setup, backup, restore, and rollback.

### Definition of done

- [ ] A fresh disposable deployment accepts real browser events and renders all
      required reports from the resulting on-disk databases.
- [ ] Release archive, SHA-256 manifest, systemd unit, Caddy snippet, tracker
      snippet, CSP guidance, backup, restore, and rollback steps agree.
- [ ] Observed RSS/CPU/disk is recorded beside the previously observed
      Plausible/Postgres/ClickHouse footprint.
- [ ] The cutover checklist starts Analytico fresh; importing history is
      explicitly optional.
- [ ] Plausible is not stopped or removed automatically; that remains the
      owner's action after accepting the project.

## M6. Server-rendered HTML dashboard

### Outcome

Add a useful no-JavaScript dashboard without changing domain or storage
semantics.

### Work

- Keep the dashboard loopback-only and document Caddy Basic Auth for the
  single-owner private deployment.
- Add controllers, owned typed view models, deterministic escaped renderers,
  native links/forms, and server-side pagination.
- Render overview and every M3 report as complete HTML.
- Add HTML goal/funnel administration using POST/redirect/GET and CSRF defense.

### Definition of done

- [ ] With JavaScript disabled, login, logout, site selection, date filters,
      report navigation, pagination, goal/funnel changes, validation errors, and
      authorization failures all work.
- [ ] First HTML response contains all server-known useful state and performs no
      startup JSON request.
- [ ] Renderers have no database, network, session, clock, random, or filesystem
      access and are deterministic under snapshot tests.
- [ ] Context-specific HTML/attribute/URL escaping passes through real HTTP and
      browser scenarios.
- [ ] Direct public access is prevented by loopback binding; Caddy Basic Auth
      and exact-origin checks protect the private dashboard and modifying forms.
- [ ] Slow reports return a complete honest timeout page preserving safe form
      state.
- [ ] HTML/CSS/request/allocation budgets pass on low-end browser/device tests.
- [ ] Debug and ReleaseSafe checks pass.

## M7. HTMX 4 progressive enhancement

### Outcome

Improve local navigation and form feedback while preserving the exact M6
server state model.

### Work

- Re-evaluate the then-current HTMX 4 releases.
- Vendor one exact core asset and license with SHA-256 and precompressed bytes.
- Enhance ordinary links/forms using full-page endpoints and scoped HTML
  fragments.
- Add focus, history, loading, error, retry, and accessibility behavior.

### Definition of done

- [ ] Decision D13 records candidates and the exact selected HTMX version.
- [ ] No CDN or runtime package manager is used.
- [ ] Every enhanced control remains an ordinary working link or form when the
      asset is absent, blocked, corrupt, or JavaScript is disabled.
- [ ] HTMX and native requests invoke the same controller/application operation;
      there is no JSON mirror or client state store.
- [ ] History back/forward, deep links, focus, scroll, validation, double-submit,
      timeout, offline, and server-error browser tests pass.
- [ ] First view still has zero API waterfall and meets JS/request budgets.
- [ ] Removing HTMX attributes and the script restores the complete M6 product.

## M8. Optional Cloudio integration

### Outcome

Decide and, only if valuable, make analytics feel like a Cloudio expansion
without violating DuckDB ownership.

### Candidates to prototype

1. Cloudio navigation links to the standalone Analytico HTML UI.
2. Analytico modules are linked into Cloudio and Cloudio becomes the single
   process owning the databases.
3. Cloudio requests complete/fragment HTML from the Analytico service with a
   strict server-side timeout.

Opening the writable DuckDB file from both processes is not a candidate.

### Definition of done

- [ ] The decision compares real integration code, failure modes, deployment
      count, auth boundary, first-view latency, and upgrade coupling.
- [ ] There remains exactly one writable DuckDB owner process.
- [ ] Cloudio's first response is complete or contains an honest
      server-rendered upstream failure state.
- [ ] Authorization is enforced at the owning server; forwarded identity has a
      signed and bounded contract if used.
- [ ] Native navigation/forms and no-JavaScript behavior remain complete.
- [ ] No shared abstraction is extracted without the two concrete consumers
      demonstrating identical semantics.
- [ ] Independent rollback to standalone Analytico is rehearsed.

## M9. Trigger-based scale and optional features

There is no scheduled M9 implementation. A new milestone is written only when
measurements trigger one of:

- batched durable ingestion;
- report cache or daily rollups;
- Parquet archival;
- access-log import;
- richer offline GeoIP/UA classification;
- SPA navigation tracking;
- revenue metrics;
- scheduled reports;
- longer-range/cross-day identity semantics;
- server analytics database.

Its definition of done must name the observed bottleneck or user requirement,
the simpler candidates considered, the accepted cost, migration/rollback, and
new performance/security/privacy gates.
