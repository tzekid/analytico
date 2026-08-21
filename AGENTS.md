# Repository doctrine

This file is normative. When code and documentation disagree, stop and resolve
the disagreement rather than silently weakening these rules.

## Documentation authority

Use this order when written sources disagree:

1. `AGENTS.md` defines enduring engineering, safety, testing, and operational
   doctrine.
2. `docs/SCOPE_1.0.md` defines approved Analytico 1.0 product scope and
   non-goals.
3. Accepted entries in `docs/DECISIONS.md` define consequential mechanisms and
   explicitly version or supersede earlier decisions.
4. For detailed 1.0 target behavior, use the integrity-verified planning
   package's written functional/data specifications, then its technical
   specifications, following the package's own hierarchy.
5. Versioned repository product, architecture, data, protocol, performance,
   security, and operations documents define shipped behavior and compatibility
   unless they clearly label a future target.
6. `docs/MILESTONES.md` and GitHub issues define sequencing and acceptance, but
   cannot silently override the sources above.
7. Written package product/design rules and its deterministic prototype may
   clarify presentation only after functional/data/technical contracts. AI
   exploration images are non-binding.
8. Release notes and result documents are immutable historical evidence. They
   may describe an older boundary without governing new work.

The package does not override items 1–3 or newer correct repository work merely
because it was prepared from an older baseline. If package detail, an issue,
and the repository still conflict after applying this hierarchy, stop and
resolve the governing documents before implementation.

When a consequential deviation is required, stop implementation and update the
affected scope or versioned contract plus `docs/DECISIONS.md`. The decision
must compare candidates, recommend one, and record dependency, runtime,
maintenance, migration, rollback, security, and affected-issue consequences.
Do not resolve a conflict only in code, a pull-request comment, or an issue.

## Product objective

Optimize for time to useful, trustworthy information, including on slow
connections, low-end hardware, older browsers, and JavaScript-disabled clients.

## Architecture

- The first HTTP response must contain all useful state already known to the server.
- HTML is the application baseline; JavaScript is optional enhancement.
- Native links and forms must work before HTMX is added.
- HTMX may improve navigation and local updates, but must not become a second application state model.
- Domain and application code must not depend on HTTP or HTML.
- Controllers load state and create typed view models.
- Renderers are deterministic and perform no database, network, session, or filesystem access.
- Large collections use server-side pagination.
- Slow upstream work has explicit timeouts and honest server-rendered failure states.
- Browser-only JavaScript is isolated into small, justified islands.

## Performance

- No startup API waterfall.
- Do not send information as HTML and then immediately refetch the same information as JSON.
- Avoid blocking third-party scripts.
- Keep first-response HTML, CSS, JavaScript, allocations, and request counts measurable.
- Prefer server precomputation and caching when it improves first-view latency.
- Optimize measured bottlenecks, not imagined ones.

## Simplicity

- Apply YAGNI before introducing an abstraction, dependency, protocol, background process, or deployment component.
- Extract shared code only after two real consumers demonstrate the same semantics.
- Prefer explicit data flow and plain Zig types.
- No service container, generic middleware framework, hydration layer, or client state store without a demonstrated requirement.
- A local duplication is preferable to the wrong shared abstraction.

## Dependencies

- Pin exact compiler and package versions.
- Prefer the standard library and small auditable dependencies.
- Every dependency must justify its runtime, security, maintenance, and conceptual cost.
- Optional functionality must not be loaded by applications that do not use it.

## Testing

- Milestone acceptance runs the real executable against real on-disk Turso and
  DuckDB files, real loopback HTTP, and real browsers where a browser is part
  of the feature.
- Do not substitute an in-memory database, mock repository, fake HTTP server,
  or abstract sandbox for the production path in release gates.
- Narrow unit tests or fakes may be used temporarily while developing a
  difficult pure function, but remove them once an end-to-end scenario covers
  the behavior unless they continue to catch a distinct failure cheaply.
- Prefer a small number of high-value end-to-end scenarios over a large mocked
  test suite.
- Test fixtures use temporary directories and disposable database files. They
  must never point at production or user data.

## Definition of done

- Analytico `1.0.0` additionally satisfies every gate in
  `docs/RELEASE_CONTRACT_1.0.md` for one exact candidate artifact. Passing a
  compiler or narrow test command alone is not release acceptance.
- The first view is useful before JavaScript executes.
- Native navigation and ordinary forms work without JavaScript.
- Input-controlled memory and work are bounded.
- Rendering is context-safely escaped.
- Authentication and authorization are enforced server-side.
- Debug and ReleaseSafe checks pass.
- Performance and response-size regressions are measured.
- Temporary compatibility code is removed after migration.

## Project-specific boundaries

- Milestones M0 through M4 in `docs/MILESTONES.md` define the historical MVP.
  The shipped product now includes the M6 server-rendered dashboard, the M7
  removable HTMX enhancement, and passkey-protected owner administration.
  `docs/SCOPE_1.0.md` defines the approved next target.
- Turso owns relational configuration. DuckDB owns append-only analytics events
  and report queries. Neither database reaches into the other.
- DuckDB is a committed product choice, not a provisional alternative to be
  removed merely because Turso could handle the current traffic.
- A single process owns the writable DuckDB file.
- Raw IP addresses, full user-agent strings, and arbitrary URL query strings
  must never be persisted.
- No untrusted SQL is executed.
- Database migrations are forward-only, numbered, compiled into the binary, and
  covered by fresh-database and upgrade tests.
- New consequential decisions require candidate comparison and a recommendation
  in `docs/DECISIONS.md` before implementation.
- Metric semantics v1 and existing event-schema rows retain the daily,
  site-scoped visitor pseudonym and UTC-day session meaning in decision D07.
  Decision D26 accepts persistent site-scoped first-party identity and
  cross-midnight client sessions only for new compatible 1.0 data. Legacy rows
  must remain marked and must never be linked across dates or presented as
  persistent people.
- Decision D27 accepts explicit site-local dates through a bounded TZif v2/v3
  reader. UTC timestamps remain authoritative; a missing or corrupt configured
  zone fails closed rather than falling back to the server timezone.
- Do not add multi-user security, distributed-systems machinery, or enterprise
  controls to this private-project deployment without a concrete need.
