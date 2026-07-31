# Operations and deployment

This is the target M4 runbook. Commands and paths become executable/tested
artifacts during implementation; they must not be applied to the VPS merely
because they appear here.

## 1. Runtime inventory

```text
/usr/local/bin/analytico
/etc/analytico/visitor-key
/var/lib/analytico/meta.db
/var/lib/analytico/events.duckdb
/var/lib/analytico/tmp/
/var/backups/analytico/<timestamp>/
```

Ownership:

- executable: root-owned, not writable by service user;
- configuration directory/key: `analytico` service user, mode `0700/0600`;
- data and temp directories: `analytico`, mode `0700`;
- backups: separate operator-controlled path, not served by Caddy.

The database files are on local block storage. NFS/SMB/shared filesystems are
not supported for writable DuckDB files.

## 2. Process configuration

Use explicit flags in the service unit rather than a general configuration
language:

```text
analytico serve
  --listen 127.0.0.1:4318
  --meta /var/lib/analytico/meta.db
  --events /var/lib/analytico/events.duckdb
  --temp /var/lib/analytico/tmp
  --visitor-key-file /etc/analytico/visitor-key
  --trusted-proxy 127.0.0.1
  --country-header CF-IPCountry
```

The actual parser accepts the equivalent single-line command. Unknown flags,
duplicate singleton flags, missing values, relative production paths, and
world-readable key files fail startup.

## 3. Startup sequence

1. Parse and validate all flags without opening a listener.
2. Load the 32-byte visitor key from its exact file.
3. Initialize the Turso library and open metadata.
4. Verify metadata schema version and load the bounded site-policy snapshot.
5. Open DuckDB, apply resource/security settings, verify its schema version,
   and recover WAL if required.
6. Run readiness queries with deadlines.
7. Bind the loopback listener.
8. Mark ready.

Migrations are not applied implicitly by `serve`. The operator runs
`analytico migrate` after a verified backup and before starting the new binary.

## 4. Illustrative systemd shape

M4 ships and tests a real unit based on:

```ini
[Unit]
Description=Analytico embedded web analytics
After=network.target

[Service]
Type=simple
User=analytico
Group=analytico
ExecStart=/usr/local/bin/analytico serve --listen 127.0.0.1:4318 --meta /var/lib/analytico/meta.db --events /var/lib/analytico/events.duckdb --temp /var/lib/analytico/tmp --visitor-key-file /etc/analytico/visitor-key --trusted-proxy 127.0.0.1 --country-header CF-IPCountry
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/analytico
MemoryHigh=192M
MemoryMax=256M
TasksMax=64
LimitNOFILE=1024

[Install]
WantedBy=multi-user.target
```

The memory limits are validated against M0 measurements before adoption. A
failed report must not cause the process to hit `MemoryMax`.

## 5. Reverse proxy

Caddy:

- terminates TLS;
- proxies only `/tracker.aef65945.js`, `/tracker.js`, `/v1/event`, and
  `/v1/p.gif`;
- keeps health routes on loopback;
- overwrites client-IP/country trust headers;
- sets conservative request and timeout limits;
- does not cache event routes;
- may cache the content-hashed tracker asset.

The collector performs its own origin, body, rate, and timeout checks; Caddy is
defense in depth.

## 6. Health and logs

`/healthz` proves only that the event loop can answer. `/readyz` performs bounded
constant work against both stores or uses a recent readiness result no older
than five seconds.

Structured logs include:

- timestamp, level, stable event code, request ID;
- route, status class, bounded duration, site ID only when safe;
- database error category, never SQL values or native error strings that may
  include input;
- aggregate counters for accepted, rejected, rate-limited, bot, unknown
  classification, report timeout, and write failure.

Logs exclude IPs, visitor pseudonyms, user agents, paths, referrers, campaigns,
custom properties, request bodies, and secrets.

## 7. Backup

The MVP favors a short honest outage over an online coordinator:

1. Confirm a prior verified backup exists.
2. Stop the service and verify no Analytico process owns either file.
3. Run `analytico backup` with explicit source paths and a new destination.
4. The command opens each store, verifies schema, checkpoints, closes, copies
   files to a temporary destination, fsyncs files/directories, and atomically
   renames the destination.
5. Write `manifest.json` containing binary version, schema versions, byte
   sizes, SHA-256 values, and UTC creation time.
6. Run `analytico restore --verify` into a separate temporary directory and run
   `doctor` against it.
7. Restart the service and verify readiness plus a known report.

Never copy a live DuckDB file or omit its WAL. Never write a new backup over the
last known-good backup.

## 8. Restore

1. Stop service.
2. Preserve the failed/current data directory by renaming it; do not delete it.
3. Verify manifest hashes and schema compatibility.
4. Restore into a new data directory on the same filesystem.
5. Run `doctor` and representative report fixtures.
6. Atomically switch the service-visible directory.
7. Start and verify.

Rollback restores both metadata and events from the same backup directory even
though the stores do not require cross-file transactions during ordinary work.

## 9. Upgrade

1. Read schema and metric changes.
2. Build exact pins in Debug and ReleaseSafe.
3. Run real-binary end-to-end, recovery, browser where applicable, and
   performance gates against disposable on-disk databases.
4. Produce and verify backup.
5. Stop service.
6. Run explicit migrations with the new binary.
7. Start, verify readiness and reports.
8. Keep the previous binary and compatible backup until the observation window
   passes.

A binary refuses a newer unknown database schema. Destructive migration needs a
separate decision and rehearsed reverse path.

## 10. Retention and deletion

The default event retention window is 400 days. `analytico maintain`, run while
the service is stopped:

- deletes expired events in a bounded site/date operation;
- completes pending disabled-site deletions;
- checkpoints DuckDB;
- reports before/after counts and file sizes;
- runs integrity/readability checks.

At the expected traffic, monthly manual maintenance is sufficient. A systemd
timer that stops the service is introduced only if operations show the manual
schedule is unreliable and the downtime is acceptable.

## 11. Disk-full and corruption response

- Stop accepting collection writes after a disk-full error.
- Readiness becomes unhealthy.
- Existing report reads may continue only if proven safe.
- Do not repeatedly retry a failing write in a hot loop.
- Record a non-sensitive operator event and rely on journald alerting.
- Free space outside the database files first; never truncate a DB/WAL.
- Restore only after copying the suspect files for diagnosis.

## 12. Plausible replacement handoff

M5 prepares a direct replacement:

- build and verify the final release artifact;
- provide snippets and CSP changes for each selected site;
- provide a fresh-data initialization and rollback checklist;
- record measured RSS, CPU, disk, and request latency;
- optionally export Plausible history for archival reference;
- leave the actual Plausible shutdown/removal to the owner after acceptance.

No parallel-running period is required.
