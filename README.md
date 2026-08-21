# Analytico

Analytico is a small, self-hosted web analytics engine for low-traffic sites.
It aims to provide the useful part of Plausible without a ClickHouse service,
an administrative JavaScript application, or a multi-container runtime.

Milestones M0 through M8 are complete. M4 is the production-MVP boundary; the
later milestones finish direct-cutover evidence, the private server-rendered
dashboard, removable HTMX enhancement, and the optional Cloudio boundary. The
executable owns the exact embedded
stores, numbered schemas, validated sites/origins/property allowlists,
goals/funnels, a private visitor key, daily visitor pseudonyms, direct durable
event insertion, a bounded loopback HTTP collector, a tiny self-hosted tracker,
a JavaScript-free pixel, complete typed CLI reports, verified lifecycle
commands, a hardened single-service deployment, and checksummed release
packaging.

## Selected shape

- One Zig process.
- One embedded Turso file for sites, goals, funnels, and schema metadata.
- One embedded DuckDB file for append-only events and on-demand analytical SQL.
- A small HTTP collector, a CLI for configuration and operations, and a
  passkey-protected server-rendered dashboard.
- M4's historical production-MVP boundary predated dashboard work. The shipped
  M6/M7 product adds complete HTML first and uses HTMX 4 only as a removable
  enhancement to native links and forms.

At the expected 20–50 unique visitors per week, Turso alone could technically
handle the traffic. DuckDB is nevertheless a deliberate product choice: this
project is a good, bounded use case for an in-process OLAP engine, and its
window and aggregation behavior fits entry/exit analysis and funnels. M0 proves
the real integration and records its footprint; it does not rerun the project
as a competing Turso-only implementation.

## Historical production-MVP scope

The M0–M4 production MVP covered:

- page views and privacy-preserving daily unique visitors;
- popular, entry, and exit pages;
- referral hosts and UTM campaigns;
- country, browser, operating system, and device categories;
- bounded custom events;
- conversion goals and ordered, same-session funnels;
- CLI reports and machine-readable exports;
- backup, restore, resource limits, and a single-service VPS deployment.

That historical boundary excluded a web dashboard, teams, billing, email
reports, real-time views, session replay, arbitrary user SQL, and distributed
ingestion. M6–M8 and the passkey milestones subsequently added the current
private dashboard without changing the one-process storage architecture.

## Analytico 1.0 target

The sections above describe the shipped MVP boundary and its historical
milestones. The approved target product is governed separately by the
[Analytico 1.0 scope contract](docs/SCOPE_1.0.md) and tracked in the
[`Analytico 1.0` GitHub milestone](https://github.com/tzekid/analytico/milestone/1).
That target is a plan, not a claim that the capabilities are already shipped.

## Documentation

- [Normative repository doctrine and authority order](AGENTS.md)
- [Analytico 1.0 scope contract](docs/SCOPE_1.0.md)
- [Product specification](docs/SPEC.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Decision register](docs/DECISIONS.md)
- [Milestones and definitions of done](docs/MILESTONES.md)
- [Data model and metric semantics](docs/DATA_MODEL.md)
- [Collection protocol](docs/PROTOCOL.md)
- [Performance contract](docs/PERFORMANCE.md)
- [Operations and deployment](docs/OPERATIONS.md)
- [Passkey-only owner authentication](docs/PASSKEY_AUTH_SPEC.md)
- [Passkey P1 evidence](docs/PASSKEY_P1_RESULTS.md)
- [Passkey P2 evidence](docs/PASSKEY_P2_RESULTS.md)
- [Passkey P3 and production acceptance evidence](docs/PASSKEY_P3_RESULTS.md)
- [M0 viability evidence](docs/M0_RESULTS.md)
- [M1 durable-core evidence](docs/M1_RESULTS.md)
- [M2 collection evidence](docs/M2_RESULTS.md)
- [M3 report evidence](docs/M3_RESULTS.md)
- [M4 production-MVP evidence](docs/M4_RESULTS.md)
- [M5 direct-cutover evidence](docs/M5_RESULTS.md)
- [M6 server-dashboard evidence](docs/M6_RESULTS.md)
- [M7 HTMX-enhancement evidence](docs/M7_RESULTS.md)
- [M8 Cloudio-boundary evidence](docs/M8_RESULTS.md)
- [Final release evidence](docs/FINAL_RESULTS.md)
- [0.1.0 release notes](docs/RELEASE_0.1.0.md)
- [0.2.0 release notes](docs/RELEASE_0.2.0.md)
- [0.2.1 release notes](docs/RELEASE_0.2.1.md)
- [0.3.0 release notes](docs/RELEASE_0.3.0.md)
- [U1 dashboard functional-quality evidence](docs/U1_RESULTS.md)

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

Run the complete report semantics and million-event performance gates with:

```sh
zig build e2e-m3 -Doptimize=ReleaseSafe
zig build bench-m3 -Doptimize=ReleaseSafe
```

Run lifecycle, rollback, and extracted-release gates with:

```sh
zig build e2e-m4 -Doptimize=ReleaseSafe
zig build e2e-rollback -Doptimize=ReleaseSafe
zig build e2e-release-full -Doptimize=ReleaseSafe
```

For example:

```sh
analytico report ./data example 2026-07-01 2026-07-31 overview
analytico report ./data example 2026-07-01 2026-07-31 pages --format json
analytico report ./data example 2026-07-01 2026-07-31 funnel signup-flow
```

The browser setup is acceptance tooling only. Analytico itself has no Node,
Playwright, browser, container, or JavaScript runtime dependency.

Owner access is passkey-only. Configure the canonical Analytico origin and
print a one-use setup link before the first production start:

```sh
analytico auth configure /var/lib/analytico https://analytics.example
analytico auth bootstrap /var/lib/analytico --ttl 10m
```

The complete setup and login acceptance evidence is recorded in
[`docs/PASSKEY_P1_RESULTS.md`](docs/PASSKEY_P1_RESULTS.md) and
[`docs/PASSKEY_P2_RESULTS.md`](docs/PASSKEY_P2_RESULTS.md).

After `init` and `site add`, start the loopback collector with:

```sh
analytico serve \
  --listen 127.0.0.1:4318 \
  --meta /var/lib/analytico/meta.db \
  --events /var/lib/analytico/events.duckdb \
  --temp /var/lib/analytico/tmp \
  --visitor-key-file /var/lib/analytico/visitor.key
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

The safer site-specific form is generated from stored metadata:

```sh
analytico site install ./data example https://analytics.example
```

For a direct replacement, follow [the cutover runbook](docs/CUTOVER.md).

The same process also serves a complete private dashboard at `/admin`.
`deploy/Caddyfile` exposes the collector and passkey-protected dashboard on one
canonical hostname, redirects `/` to `/admin`, and rejects unknown paths. All
report navigation, UTC date filters, pagination, and goal/funnel forms work
without JavaScript. The pinned self-hosted HTMX 4 core progressively enhances
those exact controls when JavaScript is available.

The U1 functional-quality pass separates site switching from report/date
state, preserves applicable context through navigation and mutations, and
keeps goal/funnel management collapsed until requested. Site selection submits
immediately when the 315-byte local enhancement is available; the visible
native form remains the baseline.

## MVP boundary

M4 is the production-MVP gate. M5 is the completed site-specific direct-cutover
handoff; it does not require a parallel Plausible trial. M6 adds the complete
server-rendered dashboard, M7 adds removable progressive enhancement, and M8
selects an optional ordinary Cloudio link while leaving both deployments and
authorization boundaries independent.
