# M5 direct-cutover evidence

Measured on 2026-07-31 on the target Linux x86-64 VPS. The release under test
was `analytico-0.1.0-linux-x86_64.tar.gz`; its exact SHA-256 is emitted in the
adjacent `.tar.gz.sha256` sidecar.

## Extracted-release cutover

`zig build e2e-m5 -Doptimize=ReleaseSafe` performs the complete cutover against
a fresh archive extraction and disposable on-disk databases. It:

- initializes Turso metadata, DuckDB events, temp storage, and visitor key;
- configures a site, custom property, conversion goal, and three-step funnel;
- generates and validates the site's tracker and CSP installation output;
- serves a real fixture page under an enforced Content-Security-Policy;
- uses real Chromium to record landing and pricing pageviews plus a signup;
- proves the tracker leaves local and session storage empty;
- queries overview, pages, entries, exits, sources, campaigns, countries,
  browsers, operating systems, devices, events, goal, and funnel reports;
- renders every report family in table form;
- performs a verified two-store/key backup and isolated restore; and
- checks agreement among the packaged service, Caddy, tracker, and operations
  paths.

The accepted fixture produced exactly two pageviews, one visitor-day, one
session, one custom event, one converted goal, and all three funnel steps.

## Resource comparison

The Analytico observations use the ReleaseSafe collector and fresh databases.
The Plausible observations are read-only measurements of the Docker state that
already existed on this host. Plausible, PostgreSQL, and ClickHouse were
already stopped before M5; they were not restarted, so a comparable live
Plausible CPU or RSS measurement is deliberately reported as unavailable.

| Observation | Analytico | Existing Plausible stack |
| --- | ---: | ---: |
| Required application processes | 1 | 3 when running |
| Collector RSS | 50,228 KiB idle; 61,680 KiB cutover fixture | unavailable: services already stopped |
| Collector durable POST p95 | 8.907 ms | unavailable: services already stopped |
| Collector CPU through cutover fixture | 0.04 process CPU seconds | unavailable: services already stopped |
| Installed runtime/images | 91,119,192 bytes | about 1.34 GB unique Docker image data |
| Fresh/live data | 981,728 bytes after setup and fixture | about 14.41 GB in four retained Docker volumes |

The Docker volume breakdown observed without starting anything was:

| Volume | Data |
| --- | ---: |
| ClickHouse event data | 13.68 GB |
| ClickHouse event logs | 638.5 MB |
| PostgreSQL data | 84.43 MB |
| Plausible application data | 3.306 MB |

These sizes describe this host's retained history and are not a normalized
empty-install benchmark. The process measurements and million-event report
benchmarks remain recorded in `M4_RESULTS.md`.

## Handoff boundary

`CUTOVER.md` starts Analytico with empty history, makes Plausible's full CSV
export and aggregate API snapshot explicitly optional, and ends at an owner
checkpoint. No Analytico command or shipped script stops or removes Plausible
or its data.
