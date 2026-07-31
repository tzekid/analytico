# M3 functional-MVP result

M3 completes every promised analytics question through the local CLI. Reports
use the actual Turso metadata and DuckDB event files; the acceptance suite uses
no store mocks or in-memory substitute.

## Report contract

- Metric semantics are version 1.
- Date ranges are inclusive UTC dates and limited to 400 days.
- Daily unique output is named `visitor_days`.
- Sessions use a strict inactivity gap greater than 30 minutes.
- Product reports exclude bots; overview exposes their count separately.
- Lists default to 25 rows, cap at 100, use stable label tie-breaks, and expose
  the next page.
- Formats are terminal-safe tables, escaped JSON, and spreadsheet-safe CSV.
- All request values are bound; sorts and campaign dimensions select closed
  SQL templates.
- DuckDB interrupts an interactive query after two seconds and remains reusable.

The hand fixture covers UTC midnight, the exact 30-minute boundary and the
next-microsecond split, tied event timestamps ordered by UUID, direct and
external referrers, campaigns, unknown country/client values, bot exclusion,
repeated goal matches, and interleaved funnel events. It checks every report,
empty output, pagination, all formats, invalid input before database I/O, and
v1-to-v2 event migration through separate real processes.

## Measured scale evidence

- Zig: `0.17.0-dev.1509+bb296ab9b`
- turso.zig: `f1b82da9f9207bee085808ad6a8686a9780ed76d`
- Turso Database: `0.8.0-pre.2`
- DuckDB: official 1.4.5 Linux AMD64 release
- Optimize mode: ReleaseSafe
- Platform: Linux `7.0.12-arch1-1`, AMD EPYC 9354P, 4 visible cores, 15 GiB
  RAM, Btrfs
- DuckDB: one thread, 128 MiB memory limit, 256 MiB temp limit
- Fixture: 1,000,000 events, 100,000 sessions, 800,000 page views, 200,000
  custom events, fixed SQL sequence
- Warmup: one full CLI invocation per measured report
- Samples: ten separate CLI processes per overview/funnel report

| Observation | Result | Budget |
| --- | ---: | ---: |
| Overview p50 / p95 / p99 | 86 / 111 / 111 ms | p95 ≤ 500 ms |
| Eight-step funnel p50 / p95 / p99 | 920 / 982 / 982 ms | p95 ≤ 2,000 ms |
| Popular-pages process, one sample | 100 ms | query deadline ≤ 2,000 ms |
| Goal process, one sample | 600 ms | query deadline ≤ 2,000 ms |
| Fixture generation, one sample | 3,049 ms | offline |
| DuckDB file | 15,740,928 bytes | informational |
| Durable collector insert p95, 100 samples | 11.326 ms | p95 ≤ 25 ms |

These measurements include process startup, both database opens, migration
version checks, bound query execution, rendering, and close. The compact
machine-readable record is in
`bench/results/m3-reports-release-safe.json`; regenerate it with
`zig build bench-m3 -Doptimize=ReleaseSafe`.

The initial window-only session implementation was rejected by measurement:
overview took roughly 1.5 seconds, the funnel took roughly 4.8 seconds, and one
form exceeded the 128 MiB DuckDB limit. Decision D21 records why the accepted
event-local session boundaries are simpler and faster than adding rollups or a
background process.
