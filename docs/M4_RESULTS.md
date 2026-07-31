# M4 production-MVP evidence

Measured on 2026-07-31 on the same Linux x86-64 VPS-style host used for the M0
through M3 baselines. The implementation base was M3 commit `e56c0a4`; all
commands below ran against the complete M4 worktree before its milestone
commit.

## Release artifact

The ReleaseSafe package is
`analytico-0.1.0-linux-x86_64.tar.gz`. Its exact archive SHA-256 is emitted
beside it in the `.tar.gz.sha256` sidecar; the archive additionally carries a
checksum for every internal file.

Its required installed runtime is 91,116,816 bytes:

| File | Bytes |
| --- | ---: |
| `bin/analytico` | 26,341,344 |
| `lib/libduckdb.so` | 64,775,472 |

The required 91,116,816-byte installed runtime is below the 100 MiB contract.
`ldd` from an isolated extraction resolves
DuckDB through the archive's `$ORIGIN/../lib/libduckdb.so`. The outer checksum,
all 18 internal file checksums, file modes, license/provenance files, Caddy
configuration, and fresh-data report pass `tests/e2e-release.sh`.

## Lifecycle and failure evidence

`tests/e2e-m4.sh` uses only disposable real files and processes. It proves:

- two stop/checkpoint/hash backups and two isolated restores preserve two
  stores, one key, metadata, all events, and representative reports;
- an existing destination is never overwritten and failed restore/backup
  attempts leave no partial public destination;
- appended database bytes and an incompatible manifest are rejected before
  restore;
- both stores reject schema version 999 in `doctor`, `migrate`, and production
  startup;
- a mode-`0644` visitor key rejects doctor/backup, while restoring `0600`
  recovers;
- `maintain` refuses a 211-day cutoff without changing counts, then a valid
  cutoff deletes exactly one `< cutoff` event and one disabled site's event and
  metadata while preserving the recent event;
- normalized CSV is mode `0600`, excludes visitor/session identifiers, and is
  created exclusively;
- moving either live store makes readiness return `503` immediately;
- a kernel `RLIMIT_FSIZE=0` causes the real DuckDB write to return fixed `500`,
  latches readiness and subsequent collection at `503`, keeps the process
  alive through shutdown, and preserves zero committed events;
- the captured JSON logs contain none of the request IP, user agent, path,
  visitor key name, or database filename.

The interruption drill creates a real one-million-row DuckDB v1 database,
kills `analytico migrate` during its transactional v1-to-v2 rewrite, reruns
the same migration, and verifies schema v2 with all 1,000,000 events.

`zig build e2e-rollback` builds the actual prior M3 commit (`e56c0a4`), creates
a pre-upgrade backup, adds post-backup state, restores the backup, and proves
the prior binary can report and serve readiness from the rolled-back data.

## Deployment evidence

`caddy validate` accepts `deploy/Caddyfile`. Its only proxied paths are the two
tracker and two event endpoints; both visitor-classification trust headers are
overwritten.

`systemd-analyze security --offline=yes` rates
`deploy/analytico.service`:

```text
Overall exposure level for analytico.service: 3.2 OK
```

The unit has no capabilities, writes only the data directory, and enforces a
256 MiB memory maximum.

## Current resource evidence

The current ReleaseSafe collector benchmark used five warmups and 100 real
durable loopback POSTs:

| Observation | Result | Budget |
| --- | ---: | ---: |
| Startup to readiness | 53 ms | p95 target ≤ 1,000 ms |
| Idle RSS after 30 seconds | 50,228 KiB | ≤ 128 MiB |
| Loaded RSS | 60,228 KiB | ≤ 256 MiB service ceiling |
| Durable insert p50 | 6.629 ms | — |
| Durable insert p95 | 8.907 ms | ≤ 25 ms |
| Durable insert p99 | 9.169 ms | ≤ 100 ms |
| SIGTERM shutdown | 21 ms | ≤ 2,000 ms |
| Committed events | 105/105 | all |

The accepted M3 million-event baseline remains overview p95 111 ms and
eight-step funnel p95 982 ms, below 500/2,000 ms. The full extracted-release
M0 probe repeated the million-row workload in both Debug and ReleaseSafe and
reported a 33 ms analytical probe on each run.

## Complete gates

Both commands completed from a package extracted into a new temporary
directory:

```sh
zig build test e2e-release-full \
  -Dturso-native-path=.zig-cache/turso-exact-prefix
zig build test e2e-release-full -Doptimize=ReleaseSafe \
  -Dturso-native-path=.zig-cache/turso-exact-prefix
```

Each extracted binary passed M0, M1, M2 HTTP, M2 Chromium/Firefox/WebKit, M3,
and M4. No browser or test dependency is present in the release archive or
needed at runtime.
