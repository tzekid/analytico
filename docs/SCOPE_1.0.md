# Analytico 1.0 scope contract

Status: approved target scope, not a description of currently shipped behavior.

This document is the repository's normative product-scope contract for
Analytico 1.0. The current implementation and its accepted evidence remain
documented by the existing specifications, milestones, decisions, and release
notes until individual 1.0 issues change them. Engineering doctrine in
[`AGENTS.md`](../AGENTS.md) and existing operational guarantees remain in force.

The release is tracked by the
[`Analytico 1.0` milestone](https://github.com/tzekid/analytico/milestone/1)
and the
[`Analytico 1.0` project](https://github.com/users/tzekid/projects/2).
The plan begins with the
[foundation epic](https://github.com/tzekid/analytico/issues/1).

## Product outcome

Analytico 1.0 is a lightweight, self-hosted web and product analytics
application for an individual operator or small project portfolio. It gives a
casual owner a useful default answer and lets a professional user move from an
aggregate change to its causes, journeys, sessions, and identified-user
history without turning the frontend or deployment into a platform of its own.

The product is simple by default and deep by drill-down. It does not provide a
separate novice mode, an arbitrary dashboard builder, or a general analytics
platform.

## Questions 1.0 must answer

1. How much traffic did the site receive, and how did it change?
2. Which pages, sources, campaigns, devices, and countries explain that
   change?
3. Which declared actions converted, and which traffic produced those
   conversions?
4. Where do people drop out of a known flow?
5. Which paths do people take when no flow was predefined?
6. Do people return and perform a meaningful action after their first action?
7. What happened in a specific session or across an explicitly identified
   person's sessions?
8. Is tracking healthy, and why was an event rejected?

## Required capabilities

### Tracking and data truth

- Collector protocol v2 with protocol-v1 compatibility during the documented
  migration window.
- Persistent, site-scoped, first-party anonymous identity for new compatible
  events.
- Optional application-supplied identified-user IDs and bounded traits.
- Explicit reset and identity-conflict behavior that cannot silently merge two
  real users.
- Client session identity that survives navigation and can cross UTC midnight.
- Reporting dates derived from a configured IANA site timezone.
- Flat typed custom properties available to filters, breakdowns, goals,
  funnels, sessions, profiles, and exports.
- Page title, hostname, language, active engagement, maximum scroll depth,
  exact value, and currency fields.
- SPA navigation tracking and bounded, opt-in automatic events.
- Honest marking and coverage reporting for legacy daily-pseudonym rows; old
  visitor-days are never presented as persistent people.

### Product shell and onboarding

- Browser-based first-run site creation and core site settings after passkey
  setup.
- Settings for general site data, tracking, events and properties, path rules,
  exclusions, and data access.
- Tracker snippet, copy action, first-event verification, and recent bounded
  accepted/rejected diagnostics.
- Six stable destinations: Overview, Analyze, Journeys, Sessions, Live, and
  Settings.
- Shared site, local-date range, comparison, segment, and filter context in
  canonical URLs and server-owned view models.
- Complete desktop and phone behavior.

### Overview and analysis

- A fixed useful Overview with KPI comparison, one primary trend, and Content,
  Acquisition, Conversions, and Audience answer panels.
- Typed Trend and Breakdown analysis modes.
- Universal bounded filters, click-to-filter, saved segments, and saved views.
- Page, event, source, and campaign detail views.
- CSV and JSON export of the visible bounded analysis.
- Annotations, unless explicitly descoped through the scope-change process.

### Journeys, sessions, and live activity

- Guided property-aware goals with historical match preview.
- Visual funnels with sequential and consecutive modes, same-session and
  bounded visitor windows, step metrics, time-to-convert, and session
  drill-through.
- Bounded forward and reverse path exploration with deterministic
  normalization and a usable mobile fallback.
- Daily and weekly retention over compatible persistent identity.
- Session list, event timeline, and cross-session identified-user profile.
- Live activity and a bounded, redacted tracking debugger.

### Quality and operations

- Useful server-rendered first responses and working native links/forms for
  every core flow with JavaScript disabled.
- Accessible server-rendered SVG charts with exact tabular alternatives.
- Explicit response, asset, latency, memory, disk, and cardinality budgets.
- A representative one-million-event performance fixture.
- Fresh install, exact-baseline upgrade, repeated upgrade, backup, restore,
  and database-pair rollback acceptance.
- Real executable, on-disk Turso and DuckDB, loopback HTTP, and real-browser
  evidence where the feature crosses those boundaries.
- Mobile, keyboard, contrast, timeout, error, stale, corrupt-data, disk-full,
  and high-cardinality acceptance.

## Operational contract that 1.0 must preserve

- One Zig executable remains the normal deployment unit.
- Turso owns relational metadata, configuration, authentication, and saved
  entities. DuckDB owns analytics events, identity links, and report queries.
  Neither database reaches into the other.
- Exactly one process owns the writable DuckDB file.
- HTML is the application baseline. JavaScript and HTMX are optional,
  removable enhancement and never a second application state model.
- No frontend framework, frontend package manager, hydration layer, client
  state store, or client-side charting framework is introduced.
- Domain and application code remain independent of HTTP and HTML. Controllers
  create owned typed view models; deterministic renderers perform no I/O.
- Inputs, allocations, work, result sizes, cardinality, pagination, and query
  duration remain explicitly bounded.
- No raw IP address, full user-agent string, or arbitrary URL query string is
  persisted.
- No untrusted SQL, request-selected SQL structure, runtime extension download,
  or arbitrary user query language is introduced.
- Migrations remain forward-only, numbered, compiled into the executable, and
  covered by fresh-database and exact-upgrade tests.
- Existing CLI, export, backup, restore, maintenance, readiness, deployment,
  release packaging, and rollback capabilities remain valid while the web
  product grows.
- Passkey authentication, authorization, exact-origin checks, CSRF defense,
  output escaping, and the explicit reverse-proxy trust boundary remain
  enforced server-side.
- Compiler and dependency versions remain exact. A new dependency or service
  requires an accepted decision with measured justification.
- Release gates continue to use real disposable stores, processes, HTTP, and
  browsers rather than mocked substitutes for the production path.

## Optional polish

The following may be considered only after every required capability passes
its acceptance gates. None may delay the required 1.0 release:

- keyboard shortcuts for date presets or navigation;
- public read-only saved views;
- a simple scheduled email summary;
- basic Core Web Vitals collection;
- bounded path-normalization suggestions;
- import of one explicitly bounded historical CSV format.

Optional polish is not implicitly authorized by appearing in this list. It
still requires the scope-change process below.

## Explicit non-goals

Analytico 1.0 does not include:

- session replay, DOM recording, heatmaps, cursor tracking, rage-click
  detection, full click autocapture, fingerprinting, or cross-site identity;
- feature flags, experiments, surveys, in-product messaging, or
  personalization;
- error tracking, log management, or application-performance monitoring;
- arbitrary dashboard grids, user-authored widgets, SQL, formulas, notebooks,
  or general business intelligence;
- data-warehouse connectors, reverse ETL, CDP behavior, or workflow automation;
- Redis, Kafka, ClickHouse, message queues, distributed ingestion,
  multi-process DuckDB writes, multi-region writes, or speculative background
  aggregation infrastructure;
- teams, organizations, invitations, granular roles, billing, or subscription
  management;
- new third-party product integrations beyond the core tracker and documented
  bounded exports; the accepted optional Cloudio link remains unchanged;
- ad-platform, Search Console, CRM, alerting, anomaly-detection, or AI-insight
  integrations;
- mobile native SDKs;
- multi-touch attribution;
- legal or GDPR workflow productization.

The final item does not weaken privacy or security requirements. The product
must still avoid accidental sensitive-data collection, enforce authentication
and authorization server-side, and retain explicit data-safety controls.

## Plan traceability

Every active 1.0 child issue has one native parent epic. The epic mapping below
connects every issue to one or more required product questions; the native
parent and dependency relationships on GitHub are the issue-level trace.

| Epic | Child issues | Product questions or cross-cutting outcome |
| --- | ---: | --- |
| [Foundation and scope #1](https://github.com/tzekid/analytico/issues/1) | #2–#4 | Governs questions 1–8 and their release contract |
| [Tracking and data truth #5](https://github.com/tzekid/analytico/issues/5) | #6–#13 | Supplies trustworthy data for questions 1–8, especially identity and time for 6–7 |
| [Design system and shell #14](https://github.com/tzekid/analytico/issues/14) | #15–#17 | Makes answers to questions 1–8 usable, responsive, and accessible |
| [Onboarding and settings #18](https://github.com/tzekid/analytico/issues/18) | #19–#22 | Establishes collection and verification, directly serving question 8 |
| [Overview and analysis #23](https://github.com/tzekid/analytico/issues/23) | #24–#31 | Answers questions 1–3 |
| [Journeys #32](https://github.com/tzekid/analytico/issues/32) | #33–#39 | Answers questions 3–6 |
| [Sessions and Live #40](https://github.com/tzekid/analytico/issues/40) | #41–#44 | Answers questions 7–8 |
| [Hardening and release #45](https://github.com/tzekid/analytico/issues/45) | #46–#50 | Proves questions 1–8 on the release artifact without weakening operations |

An issue that cannot be traced through this table to a required question or
cross-cutting release guarantee is not active 1.0 scope.

## Scope-change rule

A capability may enter the active 1.0 scope only when all of these are true:

1. It directly enables one of the eight required product questions.
2. The approved scope cannot answer that question coherently without it.
3. Its implementation, conceptual, runtime, security, migration, maintenance,
   and operational costs are documented.
4. A lower-complexity alternative was compared and rejected with evidence.
5. The owner explicitly approves the change.
6. This document and the affected GitHub issues are updated before
   implementation begins. Consequential choices also update
   `docs/DECISIONS.md` with the required candidate comparison.

Otherwise, record the idea outside the active milestone and continue the
approved plan. Do not implement future-issue features incidentally while
completing a narrower ticket.

## Authority and implementation boundary

This document decides product scope, not every data or architecture mechanism.
Consequential identity, timezone, migration, dependency, security, and storage
choices still require the candidate comparison and recommendation required by
[`docs/DECISIONS.md`](DECISIONS.md). Issue
[#3](https://github.com/tzekid/analytico/issues/3) reconciles the repository's
historical doctrine and records the first 1.0 semantic decisions before those
changes are implemented.

If this document, an issue, current repository doctrine, or an accepted
operational contract conflicts materially, stop and resolve the written
conflict. Do not silently weaken an existing guarantee or claim planned 1.0
behavior as shipped.
