# Analytico

Analytico is a small, self-hosted web analytics engine for low-traffic sites.
It aims to provide the useful part of Plausible without a ClickHouse service,
an administrative JavaScript application, or a multi-container runtime.

Milestones M0 through M2 are complete. The executable now owns the exact embedded
stores, numbered schemas, validated sites/origins/property allowlists,
goals/funnels, a private visitor key, daily visitor pseudonyms, direct durable
event insertion, a bounded loopback HTTP collector, a tiny self-hosted tracker,
a JavaScript-free pixel, and an operator `doctor` command. Complete analytical
reports begin in M3.

## Selected shape

- One Zig process.
- One embedded Turso file for sites, goals, funnels, and schema metadata.
- One embedded DuckDB file for append-only events and on-demand analytical SQL.
- A small HTTP collector plus a CLI for configuration, reports, backup, and
  maintenance.
- No dashboard in the MVP.
- Later dashboard work starts as server-rendered HTML; HTMX 4 may enhance it
  only after native links and forms are complete.

At the expected 20–50 unique visitors per week, Turso alone could technically
handle the traffic. DuckDB is nevertheless a deliberate product choice: this
project is a good, bounded use case for an in-process OLAP engine, and its
window and aggregation behavior fits entry/exit analysis and funnels. M0 proves
the real integration and records its footprint; it does not rerun the project
as a competing Turso-only implementation.

## Product scope

The production MVP covers:

- page views and privacy-preserving daily unique visitors;
- popular, entry, and exit pages;
- referral hosts and UTM campaigns;
- country, browser, operating system, and device categories;
- bounded custom events;
- conversion goals and ordered, same-session funnels;
- CLI reports and machine-readable exports;
- backup, restore, resource limits, and a single-service VPS deployment.

The MVP intentionally excludes a web dashboard, teams, billing, email reports,
real-time views, session replay, arbitrary user SQL, and distributed ingestion.

## Documentation

- [Product specification](docs/SPEC.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Decision register](docs/DECISIONS.md)
- [Milestones and definitions of done](docs/MILESTONES.md)
- [Data model and metric semantics](docs/DATA_MODEL.md)
- [Collection protocol](docs/PROTOCOL.md)
- [Performance contract](docs/PERFORMANCE.md)
- [Operations and deployment](docs/OPERATIONS.md)
- [M0 viability evidence](docs/M0_RESULTS.md)
- [M1 durable-core evidence](docs/M1_RESULTS.md)
- [M2 collection evidence](docs/M2_RESULTS.md)

The machine-readable dependency intentions are in
[`versions.json`](versions.json). A dependency is not considered adopted until
its milestone integrates it and the Debug and ReleaseSafe gates pass.

## Repository map

```text
src/                 Zig source
tests/               Real-process end-to-end gates
bench/results/       Compact measured baselines
docs/                Product, architecture, decisions, milestones, and contracts
AGENTS.md             Normative server-first engineering doctrine
versions.json         Exact evaluated tool and dependency versions
```

## Current build

The scaffold uses the exact Zig toolchain in `.zigversion`:

```sh
zig build
zig build test
zig build -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe
```

Run the M0 viability probe with:

```sh
zig build e2e-m0 -Doptimize=ReleaseSafe
```

Run the durable administration scenario with:

```sh
zig build e2e-m1 -Doptimize=ReleaseSafe
```

Run the collector protocol and real-browser scenarios with:

```sh
zig build e2e-m2 -Doptimize=ReleaseSafe
tests/setup-browser-e2e.sh
zig build e2e-m2-browser -Doptimize=ReleaseSafe
```

The browser setup is acceptance tooling only. Analytico itself has no Node,
Playwright, browser, container, or JavaScript runtime dependency.

After `init` and `site add`, start the loopback collector with:

```sh
analytico serve ./data 127.0.0.1 4318
```

Use the content-hashed production tracker:

```html
<script defer
  src="https://analytics.example/tracker.aef65945.js"
  data-site="YOUR-SITE-UUID"></script>
<noscript>
  <img alt="" width="1" height="1"
    src="https://analytics.example/v1/p.gif?site=YOUR-SITE-UUID&amp;path=%2F">
</noscript>
```

## MVP boundary

M0 through M3 produce a functional collector and complete CLI report surface.
M4 makes that system practical to operate and is the production-MVP gate. M5
packages the direct-cutover handoff; it does not require a parallel Plausible
trial. The HTML and HTMX work begins only in M6 and M7.
