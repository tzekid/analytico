# Repository doctrine

This file is normative. When code and documentation disagree, stop and resolve
the disagreement rather than silently weakening these rules.

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

- The first view is useful before JavaScript executes.
- Native navigation and ordinary forms work without JavaScript.
- Input-controlled memory and work are bounded.
- Rendering is context-safely escaped.
- Authentication and authorization are enforced server-side.
- Debug and ReleaseSafe checks pass.
- Performance and response-size regressions are measured.
- Temporary compatibility code is removed after migration.

## Project-specific boundaries

- The MVP is milestones M0 through M4 in `docs/MILESTONES.md`.
- The MVP has no administrative web UI and therefore no HTMX runtime.
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
- Do not add multi-user security, distributed-systems machinery, or enterprise
  controls to this private-project deployment without a concrete need.
