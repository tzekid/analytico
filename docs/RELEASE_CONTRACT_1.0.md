# Analytico 1.0 release contract

Status: normative target gate. This document does not claim that Analytico 1.0
is currently shipped.

Analytico may be tagged `1.0.0` only when every rule below is demonstrably true
for one exact release-candidate commit and its exact packaged artifact. Passing
a compiler or unit-test command alone is never sufficient.

This contract is subordinate to [`AGENTS.md`](../AGENTS.md),
[`SCOPE_1.0.md`](SCOPE_1.0.md), and accepted entries in
[`DECISIONS.md`](DECISIONS.md). Detailed target behavior comes from the
integrity-verified planning package under the authority order recorded in those
documents. The machine-readable capability map is
[`REQUIREMENT_TRACEABILITY_1.0.csv`](REQUIREMENT_TRACEABILITY_1.0.csv).

## 1. Evidence rules

Every claimed pass records:

- the exact candidate commit and whether the checkout was clean;
- the exact binary or release-artifact checksum when executable behavior is
  involved;
- compiler, dependency, database, browser, operating-system, and hardware
  versions relevant to the result;
- the exact command or manual procedure, fixture, and environment;
- pass/fail outcome plus compact durable evidence in the repository or an
  owner-approved release record;
- any limitation, skipped branch, or variance from the standard environment;
- the issue that owns a failure or incomplete item.

Evidence from an older commit proves only that older commit. Fixture success is
not production-path evidence when the requirement crosses the real executable,
on-disk stores, loopback HTTP, browser, reverse proxy, or packaged artifact.
Screenshots aid review but never replace semantic, keyboard, or data checks.

An item is either passed, failed, or explicitly not applicable with a written
reason accepted by the owner. “Not run,” “works locally,” and “code compiles”
are not passes.

## 2. Definition of Done

### Product

- Every row in `REQUIREMENT_TRACEABILITY_1.0.csv` has accepted implementation
  and the required evidence for the same candidate.
- A blank installation reaches a verified first event through the browser after
  passkey setup without requiring the CLI for site creation, origins, timezone,
  or tracker installation. A newly issued D38 watermark rejects old rows and
  duplicate retries as proof; ordinary GET refresh, protocol-v1 compatibility,
  protocol-v2 success, and safe actionable rejection guidance remain usable
  with JavaScript disabled.
- Overview, Analyze, Journeys, Sessions, Live, and Settings answer their scoped
  questions with shared canonical context and useful empty/error states.
- Goals and funnels require no raw syntax. Paths, retention, sessions, and
  identified-user history use only compatible persistent identity.
- Meaningful aggregate-to-detail paths work, including required session
  drill-through, bounded CSV/JSON export, and annotations.
- Every core flow has an accepted phone presentation; mobile is not a clipped
  desktop layout.

### Data semantics

- Protocol version 2, event schema version 7, metadata schema version 10, and
  metric version 2 are
  documented and exercised together while schema-3 rows upgrade without lost
  facts and the documented protocol-v1 and metric-v1 compatibility paths
  remain honest.
- Persistent anonymous identity, optional identification, reset, conflicts,
  session rotation, cross-midnight sessions, and multi-device links match D26
  without inferred fingerprint joins.
- Site-local date grouping, range bounds, DST gaps/overlaps, stored offsets,
  timezone locking, and offline rebucketing match D27.
- Shared calendar state uses explicit canonical `from`, `to`, and `compare`
  values. Presets resolve under the selected site timezone; previous-period and
  previous-year semantics, leap/month boundaries, unavailable comparison, and
  current-day incompleteness match `ANALYSIS_QUERY.md`. Native and enhanced
  back/forward/bookmark behavior reproduce the same server-owned context.
- Legacy rows are marked `legacy_daily`, never linked across dates, and excluded
  or coverage-labeled wherever persistent identity is required.
- Typed properties, exact value/currency behavior, attribution, goals, funnels,
  paths, retention, and engagement match hand-checkable fixtures. Metric
  definitions and versions appear in applicable exports.
- Ordinary metric-v2 Trend/Breakdown state follows
  [`ANALYSIS_QUERY.md`](ANALYSIS_QUERY.md): closed types, canonical bounded
  serialization, explicit filter scopes, finite reviewed SQL fragments, bound
  values, typed unsupported-state failures, and preserved metric-v1 output.
- The D37 Analyze Trend route reproduces one through three ordered typed
  series from its canonical direct GET, keeps one request deadline, preserves
  exact rate/amount components and currencies, marks generated
  highlight/incomplete buckets visibly, and retains explicit metric-v1 list
  compatibility through D39's one-redirect typed presets.
- The D39 Analyze Breakdown route reproduces one canonical single-metric query,
  applies only bound aggregate-label search, shares one deadline with its
  labeled latest-2,000-event, 30-second property suggestion catalog, exposes
  exact result cardinality and raw measure components, keeps its conditional
  empty-site presence check inside that deadline, and preserves metric-v1
  CLI output without a second browser report engine or result cache.
- The D42 goal builder persists zero to three exact typed event-row predicates,
  previews the selected local-date/filter/segment/traffic context before save,
  exposes observed type conflicts without coercion, and reports exact total,
  visitor, session, identity-coverage, and per-currency revenue results. Preview
  timeout performs no metadata write and leaves the analysis connection usable.
- The D43 funnel builder persists one exact bounded definition with two through
  eight ordered Page, Event, or Goal steps, guarded lifecycle state, and exact
  Goal references. Preview reports independent selector availability under the
  current context. D44 adds restart-capable sequential/consecutive progression,
  Sessions or persistent-Visitor scope, bounded windows, exact drop-off/timing,
  explicit incompatible-identity coverage, and current/comparison results.
  All participating events remain inside the selected local-date range.
  Its two full-draft routes reuse the exact 65,536-byte saved-state proxy and
  application bound; all other funnel actions retain the ordinary 8 KiB limit.
- D34 query classification is reversible, default-off parity is exact, every
  documented human-evidence veto wins, strict mode uses one shared product
  predicate, and traffic-quality v5 exposes bounded contradiction/cap/anomaly
  evidence without raw or rendered network identifiers.

### Architecture and security

- One Zig executable remains the normal deployment unit and the sole writable
  DuckDB owner. Turso and DuckDB retain their documented responsibilities.
- The first useful response is server-rendered HTML. Native links and forms work
  without JavaScript; HTMX and small browser islands do not create another
  application state model.
- No frontend framework/package manager, hydration layer, client state store,
  client chart framework, queue, distributed component, or cache service is
  introduced without an approved scope and decision change.
- Authentication, authorization, exact-origin validation, CSRF, CSP, escaping,
  SQL structure, request limits, and proxy trust are enforced server-side.
- No raw IP address, full user-agent string, arbitrary query string, unbounded
  payload/cardinality/work, runtime CDN, runtime extension download, or
  untrusted SQL enters the product.
- Every added dependency has an accepted decision plus exact provenance,
  license, runtime, security, maintenance, and rollback evidence.

### Failure behavior

- Invalid/oversized input, origin failure, duplicate/conflicting events,
  identity conflict, stale forms, missing entities, high cardinality, report
  timeout, authentication expiry, and HTMX/JavaScript failure have bounded and
  honest outcomes.
- Turso/DuckDB unavailability, newer/corrupt schemas, disk/temp exhaustion,
  interrupted migration/checkpoint, backup failure, restore mismatch, and
  shutdown during work never claim success or guess a recovery.
- Safe page context survives errors where possible. Destructive work is never a
  GET and always has explicit confirmation and audit context.
- Tracker storage/network/serialization failures never break the measured site.
  Diagnostics remain bounded and redact sensitive input.

### Quality and operations

- Clean Debug and ReleaseSafe build/test gates pass from a clean checkout.
- Fresh installation, exact inspected-baseline upgrade, repeated upgrade,
  pre/post row validation, backup, restore, candidate promotion, and
  database-pair rollback pass with disposable real files.
- Metadata schema 6 additionally proves D19 replayable autocommits from the
  exact metadata-5/event-7 predecessor, one empty settings row per existing
  site, preserved site policy, unique origin ownership, old-binary restore and
  pair rollback, and no silent assignment when predecessor origins conflict.
- Metadata schema 7 additionally proves an exact `a2d71c0` metadata-6/event-7
  predecessor, replayable additive tables, preserved rows/reports, site-isolated
  canonical segment/view CRUD, stale/corrupt handling, backup plus independent
  restore, old-binary read of the restored pair, refusal of migrated metadata,
  and matched-pair rollback before a binary switch.
- Metadata schema 8 additionally proves exact `54f49ed` metadata-7/event-7
  predecessor behavior, complete goal-definition copy, interrupted retry,
  repeated migration, stable IDs/selectors/timestamps, backup plus independent
  restore, old-binary read of the restored pair, refusal of migrated metadata,
  event/report and pre-existing overflow preservation, and matched-pair
  rollback before a binary switch.
- Metadata schema 9 additionally proves exact
  `f1609073444e204f6767a9621f87f2f24c2e0f3d` metadata-8/event-7
  predecessor behavior, complete empty-predicate copy, genuine partial-copy and
  after-drop replay, canonical-corruption refusal, repeated migration, stable
  lifecycle/selectors, 34-active overflow preservation, backup plus independent
  restore, old-binary read of the restored pair, refusal of migrated metadata,
  event/report preservation, and matched-pair rollback before a binary switch.
- Metadata schema 10 additionally proves exact `d583161` metadata-9/event-7
  predecessor behavior, complete canonical parent/step copy, genuine partial,
  child-dropped, and after-drop replay, invalid/noncanonical refusal, repeated
  migration, stable lifecycle and order, backup plus independent restore,
  predecessor read and migrated-store refusal, Goal reference guards,
  event/report preservation, and matched-pair rollback before a binary switch.
- Core real-browser journeys pass with JavaScript enabled; the complete native
  baseline passes with JavaScript disabled. Mobile, keyboard, focus, contrast,
  reduced-motion, chart/table, zoom, and screen-reader checks meet the written
  accessibility contract.
- Analyze Trend's native GET builder, canonical redirect, direct URL, legacy
  list route, empty/overflow/timeout states, and server SVG/exact tables pass
  through the real authenticated loopback service with JavaScript disabled.
- Universal-filter acceptance runs the real authenticated Overview, Trend, and
  Breakdown routes with the same event/session/person FilterSet; exact AND/OR,
  null/missing/type, maximum bounds, suggestions, chips, explicit row actions,
  segment/view CRUD, stale recovery, canonical refresh/back/forward, HTMX
  equivalence, JavaScript-disabled use, and mobile layout all pass. No filter is
  silently ignored and no startup API/JSON request is added.
- Guided-goal acceptance runs the real authenticated list/new/detail/edit and
  lifecycle routes with discovered Page/Event values, explicit zero-seen
  confirmation, reference conflict/archive recovery, active-cap and site
  isolation, archived explicit reporting, JavaScript-disabled operation,
  enhanced equivalence, keyboard use, and phone layout. No raw selector syntax,
  hidden client state, or startup API/JSON request is added.
- Predicate-goal acceptance extends that journey with observed property/type
  discovery, conflict and typed-operator errors, zero/timeout no-write,
  preview/save/edit/duplicate, exact filtered detail results and currencies,
  same-session false-positive traps, and a native Analyze handoff.
- Guided-funnel acceptance runs the real authenticated list/new/detail/edit
  lifecycle with two and eight steps, native reorder, Page/Event/Goal selectors,
  predicates, settings, zero/stale/timeout states, site isolation, Goal delete
  conflicts, JavaScript-disabled operation, enhanced equivalence, keyboard use,
  phone layout, and no startup data request. Selector availability is visibly
  distinct from D44's ordered result. The on-disk corpus additionally proves
  modes, retries, repeated steps, one-event traps, deterministic timestamp
  ties, scope/windows, filters, identity links, legacy/ephemeral coverage, and
  populated comparison. The ordered SVG and exact table agree in desktop and
  mobile browser states. In default and strict modes, each populated
  eight-step range has p95 below 1.2 seconds on one million events with ten
  active goals, the paired samples remain below two seconds, and a real preview
  returns all eight availability rows plus current and comparison under the
  shared interrupt deadline. Exact
  65,536/65,537-byte Caddy requests
  prove complete matcher coverage, application reachability, and deterministic
  413 rather than 502.
- Sessions acceptance runs the real authenticated direct list with the same
  event/session/person FilterSet and optional active Goal. Its on-disk corpus
  proves crossing/custom-only sessions, full summaries, identities, exact
  currencies, late/tied ordering, current-time edges, site isolation, strict
  traffic, stable pagination, timeout, and reuse. A same-second nonzero-microsecond
  receipt proves the production clock does not mislabel it as future.
  JavaScript-disabled desktop and 390-pixel browser paths use native
  context/filter/segment/Goal/page controls with no startup data request. Three
  warmed 200-request RSS cohorts retain the 8 MiB-per-200 sustained-growth
  limit. Each RSS read follows a database-free sequential health round-trip so
  the preceding heavy request's deferred cleanup is complete. Default and
  strict complete two-statement p95 remain below 400 ms on one million events
  and 100,000 sessions with ten active Goals.
- Session detail/profile acceptance extends that same real executable and
  browser gate with the package's direct routes, one full summary, deterministic
  50-entry paged timeline, per-visit engagement aggregation, active-Goal names,
  escaped properties/traits/exact values, current/missing-engagement states,
  and related sessions. Two explicit anonymous devices may combine only through
  an equal user ID; reset creates a separate user and a rejected conflict never
  merges. Persistent-anonymous history remains one device identity; legacy and
  ephemeral sessions have no profile link. Retained-history/profile-context
  labels, site isolation, encoded IDs, JavaScript-off/keyboard/390-pixel use,
  timeout/reuse, response/RSS bounds, detail p95 below 250 ms, and unchanged
  contextual list p95 below 400 ms all pass on the standard fixture.
- Live acceptance uses one authenticated complete first response and one exact
  current-region fragment. Its real on-disk/HTTP/browser fixture proves the
  fixed 30-minute receipt window, five-minute Active now, product/strict
  semantics, current pages/sources/events/Goals/audience, stored protocol
  distribution, and the separately retained D30 date-range section. The
  selected-site ring shows only its newest 50 safe summaries plus exact
  since-restart counts; two-site isolation, escaping, restart clear, 205-row
  wrap, store failure, and absence of sensitive fields remain blocking.
  Five-second polling makes no startup data request, stops while paused/hidden,
  retains and labels the last successful timestamp on failure, and recovers.
  JavaScript-disabled Refresh, keyboard/focus, 390-pixel layout,
  timeout/reuse, and default/strict statement plus fragment p95 below 150 ms
  pass on the standard million-event fixture.
- The named `e2e-filters`, `e2e-goals`, `e2e-metadata7-migration`,
  `e2e-metadata8-migration`, `e2e-metadata9-migration`, `e2e-funnels`,
  `e2e-metadata10-migration`, `e2e-sessions`, and `e2e-diagnostics` gates pass
  independently. All nine are mandatory parts of `e2e-release-full`; the full
  packaged gate is not a substitute for reproducing any focused boundary.
- Server-rendered chart families validate bounded typed inputs and stable IDs,
  handle empty/single/constant/missing data honestly, expose no inline handlers,
  and pair every visual value with an exact captioned table/details alternative.
- Wide tables preserve captions and scoped headers when they become labeled
  mobile records. Server form failures preserve submitted values, focus one
  error summary, and associate the affected controls without making JavaScript
  part of validation or recovery.
- Calendar preset, custom-range, comparison, and site-switch controls remain
  usable with JavaScript disabled at desktop and phone widths. The selected
  timezone, exact dates, incomplete marker, and any UTC metric-v1 compatibility
  basis are visible text rather than color- or client-only state.
- The one-million-event mixed-data fixture passes the accepted latency, memory,
  disk, cardinality, asset, and response-size budgets. Measurements record the
  standard environment and any variance.
- Disk-full, corrupt/newer database, timeout, stale, high-cardinality, and
  sensitive-data failure gates pass through the real boundary they exercise.
- Existing CLI, health, export, maintenance, deployment, backup/restore,
  rollback, and packaged-release behavior remains accepted or is changed by an
  explicit approved compatibility decision.

### Release

- Each of the exactly 50 planned milestone issues is closed or is individually
  removed from active scope through the owner-approved scope/decision process
  before the candidate is declared ready.
- Normative documents describe the candidate's shipped behavior. Target-only
  language is not presented as already implemented; known limitations and
  legacy coverage are explicit.
- Every scheduled compatibility removal satisfies section 4. Temporary code
  whose removal condition is met is removed with its tests and documentation.
- Release notes name protocol/schema/metric changes, migrations, limitations,
  compatibility windows, backup, restore, and rollback.
- The exact packaged artifact—not only a workspace binary—passes the release
  acceptance environment before the owner approves the tag.
- The owner review in section 5 is recorded and every actionable finding is
  resolved or moved through the approved scope process.

## 3. Mandatory gate ownership

| Gate | Minimum evidence | Owning issues |
| --- | --- | --- |
| Scope and traceability | Closed/descoped milestone; shipped docs; validated matrix; limitations | #4, #50 |
| Debug and ReleaseSafe | Clean build and tests plus formatter/diff/license checks | #47, #50 |
| Real executable and HTTP | On-disk Turso/DuckDB; loopback collector/admin; real routes and forms | #47, #48, #70 |
| Performance and assets | Standard million-event fixture; latency/RSS/disk/cardinality; response and asset bytes | #46, #50, #70 |
| Migration and time | Fresh/exact-baseline/repeated upgrade; row/metric preservation; TZif/DST | #47, #49, #70 |
| JavaScript-off and browser | Required enabled journeys; complete native baseline; history/focus/error behavior | #47, #48 |
| Mobile and accessibility | 390×844 journey; responsive transformations; keyboard/contrast/zoom/screen-reader evidence | #47, #48 |
| Security and privacy | Passkey/session/origin/CSRF/CSP; escaping; collector limits; identity conflicts; sensitive-data audit | #48, #70 |
| Backup and rollback | Verified database pair; restore; old/candidate binary rehearsal; disk/corrupt/newer-schema failures | #49, #70 |
| Release artifact | Checksums/provenance/licenses; extracted-artifact full gates; migration and rollback notes | #49, #50, #70 |
| Owner product/design review | Desktop/mobile/light/dark review record with all findings disposed | #48, #50 |

The owning issue must convert each minimum-evidence phrase into exact commands,
fixtures, artifacts, or review records. A later issue may strengthen a gate but
may not silently weaken it.

## 4. Compatibility removal conditions

Compatibility code has a named replacement and remains until all of these are
true:

1. The replacement is shipped and accepted through the real production path.
2. A specific removal issue names the earliest release/date and measurable
   usage or retained-data precondition.
3. Current installations can reach the replacement through a tested upgrade;
   backup/restore and supported rollback no longer require the old path.
4. Repository docs, generated snippets, links, exports, fixtures, and operator
   runbooks no longer depend on it.
5. Release notes explain the removal and owner action; the owner explicitly
   accepts it.
6. The code, tests, documentation, and diagnostics are removed together. Dead
   dormant compatibility branches are not retained “just in case.”

| Compatibility surface | Earliest valid removal condition |
| --- | --- |
| Protocol-v1 collector and tracker | A future removal issue records the window and proves all active installations use v2; stored legacy rows remain readable independently |
| Metric-v1 and `legacy_daily` query support | No retained legacy row or supported export/report requires v1 semantics; replacement totals and coverage remain verified |
| Event-schema-2 upgrade reader/migrator | The minimum supported upgrade baseline has explicitly advanced beyond schema 2; it remains required for the 1.0 exact-baseline upgrade |
| Old `/admin` analytical URLs | The replacement routes have shipped for at least one accepted compatibility release; redirects and external/internal links have verified successors |
| Current CLI/report routes | Replacement commands/routes are accepted and documented; operator automation and rollback no longer require the old form |

A traffic lull, passing build, or desire to simplify code does not satisfy a
removal condition by itself.

## 5. Owner desktop/mobile/design review

Owner review is a release gate, not inferred approval. The review record names
the candidate checksum/commit, date, browser/device/viewport, theme,
JavaScript state, routes/states reviewed, decision, and every resulting issue.

### Desktop

- Review Overview, Trend, Breakdown, Goals, Funnels, Paths, Retention, Sessions,
  Live, onboarding/install, Settings, authentication, and representative
  empty/loading/error/legacy states.
- Review light and dark themes, canonical navigation/context, information
  hierarchy, readable density, complete first response, keyboard/focus behavior,
  and exact table alternatives.

### Mobile

- Review the required 390×844 automated journey and at least one real owner
  mobile device/browser. Separate accessibility evidence must prove 200% zoom
  and large-text behavior.
- Confirm navigation/context access, 44 px targets, forms, stacked records,
  vertical funnel, path fallback, retention alternative, session timeline,
  settings, and primary actions without unavoidable page-level horizontal
  overflow.

### Design disposition

- Compare against written design language, tokens, components, responsive
  transformations, and accessibility rules.
- Use deterministic prototype screenshots to review hierarchy and behavior, not
  pixel identity. AI boards remain directional and cannot override written
  semantics, accessibility, responsive behavior, or feasible server rendering.
- Every actionable finding blocks release until fixed or explicitly descoped by
  the approved scope-change process. Silence or an old screenshot is not owner
  acceptance.

## 6. Traceability validation and final decision

Validate the repository matrix against the integrity-verified package and live
GitHub plan:

```sh
scripts/validate-1.0-traceability.sh \
  tzekid/analytico \
  ./analytico-1.0-specification
```

The validator proves structure, sequential unique requirement IDs, package spec
paths, and live issue number/slug pairs. It does not prove implementation or
evidence; issues #46–#50 and the owner must do that.

Issue #50 assembles the final evidence record and may cut `1.0.0` only after
every matrix row, mandatory gate, compatibility condition, and owner review is
green for the same artifact. Any failed, missing, stale, or unexplained item
keeps the release open.
