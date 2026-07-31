# M0 viability result

M0 accepts the proposed architecture: one Zig process, a Turso metadata file,
and a DuckDB analytics file. These are initial viability observations, not
production percentile claims.

## Reproducibility

- Zig: `0.17.0-dev.1509+bb296ab9b`
- turso.zig: `f1b82da9f9207bee085808ad6a8686a9780ed76d`
- Turso Database: `0.8.0-pre.2`,
  `6e527a75595576790566f3d36560fbe95c5d87a2`
- DuckDB: official `1.4.5` Linux AMD64 release
- Optimize mode: ReleaseSafe
- Fixture generator: M0 v1, fixed SQL sequence, 1,000,000 rows
- DuckDB: one thread, 128 MiB memory limit, 256 MiB temp limit, external
  access and community extensions disabled

`versions.json` records the immutable package and artifact hashes. No native
binary is checked into Git.

## Environment

- Linux `7.0.12-arch1-1`, x86-64
- 4 visible cores, AMD EPYC 9354P
- 15 GiB RAM
- Btrfs on `/dev/sda3`
- Base commit `b86c4bdca00e7a6df5d3a85a55a2fcfeda4ae902`; measured tree was dirty with
  the M0 implementation being recorded

## Observations

| Observation | Result |
| --- | ---: |
| Executable | 24,478,632 bytes |
| Private DuckDB runtime | 64,775,472 bytes |
| Installed executable + runtime | 89,254,104 bytes (85.1 MiB) |
| `version` cold process, one sample | 0.01 s, 17,964 KiB peak RSS |
| Generate, checkpoint, and report 1M rows | 0.82 s, 70,392 KiB peak RSS |
| Million-row overview + funnel report, one sample | 42,358,685 ns |
| Million-row DuckDB file | 3,944,448 bytes |

The repeated Debug and ReleaseSafe end-to-end gates observed report samples
between roughly 34 and 36 ms. This is comfortably below the 500 ms overview
and 2 s funnel budgets, but M3 must collect multiple separated samples before
calling a result p50/p95/p99.

## Correctness and failure evidence

The real executable:

- creates, migrates, writes, checkpoints, closes, and reopens both engines;
- returns 6 fixture events, 4 page views, 2 daily uniques, 2 entry sessions,
  and 1 completed funnel;
- returns 800,000 page views, 5,000 daily uniques, and 5,000 completed funnels
  for the million-event fixture;
- verifies committed data in a second process; and
- rejects separately truncated copies of both database files.

The architecture therefore remains substantially lighter operationally than a
Postgres plus ClickHouse service stack: it adds one private 61.8 MiB shared
library, no database daemon, no container, and no background service.
