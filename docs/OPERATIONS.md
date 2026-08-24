# Operations and deployment

This is the tested production-MVP runbook for a single Linux x86-64 host.
Analytico is one service process with two embedded database files; there is no
database server or container.

## 1. Release layout

The release archive contains:

```text
analytico-<version>-linux-x86_64/
  bin/analytico
  lib/libduckdb.so
  deploy/analytico.service
  deploy/Caddyfile
  public/tracker.*
  docs/
  LICENSES/
  SHA256SUMS
```

Verify both checksum layers before installation:

```sh
sha256sum -c analytico-<version>-linux-x86_64.tar.gz.sha256
tar --same-permissions -xzf analytico-<version>-linux-x86_64.tar.gz
cd analytico-<version>-linux-x86_64
sha256sum -c SHA256SUMS
```

Install the directory at `/opt/analytico`. The executable's `$ORIGIN/../lib`
runpath loads only the packaged DuckDB runtime in a normal installation.

```text
/opt/analytico/bin/analytico
/opt/analytico/lib/libduckdb.so
/var/lib/analytico/meta.db
/var/lib/analytico/events.duckdb
/var/lib/analytico/visitor.key
/var/lib/analytico/tmp/
/var/backups/analytico/<timestamp>/
```

The release directory is root-owned and not writable by the service user. The
data directory and its contents belong to the unprivileged `analytico` user;
the directory and key are mode `0700` and `0600`. Use local block storage, not
NFS, SMB, or a shared filesystem, for writable DuckDB data.

## 2. First installation

Create the service account and initialize data before installing the unit:

```sh
useradd --system --home-dir /var/lib/analytico \
  --shell /usr/bin/nologin analytico
install -d -o analytico -g analytico -m 0700 /var/lib/analytico
sudo -u analytico /opt/analytico/bin/analytico init /var/lib/analytico
sudo -u analytico /opt/analytico/bin/analytico \
  site add /var/lib/analytico example "Example" https://example.com \
  --timezone Europe/Berlin
sudo -u analytico /opt/analytico/bin/analytico \
  doctor /var/lib/analytico
install -m 0644 deploy/analytico.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now analytico
curl --fail http://127.0.0.1:4318/readyz
```

`init` creates the temp directory, both stores, current schemas, and one random
32-byte visitor key. Re-running it preserves the key. Do not copy one
installation's key into another except as part of a matched restore.

The `site add` command above remains the automation and recovery path. After
passkey bootstrap, the normal first-site path is the authenticated browser form
at `/admin`; it stores the same required policy and refreshes the running
collector without a service restart.

## 3. Process contract

The checked-in service invokes the exact production parser:

```sh
analytico serve \
  --listen 127.0.0.1:4318 \
  --meta /var/lib/analytico/meta.db \
  --events /var/lib/analytico/events.duckdb \
  --temp /var/lib/analytico/tmp \
  --visitor-key-file /var/lib/analytico/visitor.key
```

Only loopback listeners and absolute paths are accepted. The optional
`--zoneinfo-root` is absolute and defaults to `/usr/share/zoneinfo`. Every site
policy is loaded from that root before binding. Unknown, duplicate,
or missing flags; missing paths; non-current schemas; and a key with the wrong
type, length, or mode fail before binding the listener. `serve` never migrates.
The optional `--report-timeout-ms 1..2000` flag exists for constrained
deployments and acceptance testing; production defaults to the fixed 2,000 ms
interactive deadline.

Metadata migration 4 adds the bounded per-site network-exclusion policy. Event
migration 4 added its temporary stored source, and event migration 5 consumes
every source into D32's permanent class/version/rule plus the one-release
legacy verdict. Event migration 6 adds D33's bounded evidence, removes that
completed shadow byte, and promotes permanent-class product eligibility.
Metadata migration 5 adds D34's default-off strict policy and bounded daily
ceiling; event migration 7 adds only the keyed, receipt-day network pseudonym.
These are forward-only schema changes: stop the sole writer, create and verify
a matched backup, run `migrate`, then start the candidate. An older binary must
use a restored pre-migration database pair; switching only the executable is
not rollback. Event schema 7 adds no service-unit, environment, dependency,
process, runtime data file, tracker, or Caddy change.

DuckDB is configured before its configuration is locked: one query thread,
128 MiB memory, 256 MiB temp limit, insertion-order preservation off,
community extensions off, and external access off.

### Existing-site timezone assignment

Metadata migration 3 does not guess a timezone for existing sites. With the
service stopped, select one explicitly:

```sh
analytico site timezone-set /var/lib/analytico example Europe/Berlin
```

When the site already has events, first create the required matched backup,
then opt into the offline rewrite:

```sh
analytico backup /var/lib/analytico /var/backups/analytico/before-timezone
analytico site timezone-set /var/lib/analytico example Europe/Berlin \
  --offline-rebucket
analytico doctor /var/lib/analytico
```

The command opens the sole-writer DuckDB file, records a pending metadata
state, rewrites only local date and offset from immutable receipt time in one
DuckDB transaction, validates the row count, checkpoints, and then marks the
policy ready. An interrupted command is safe to retry with the same zone. A
different zone for a site with events is rejected unless the same explicit
offline procedure is used. The exact v0.3.0 upgrade and database-pair rollback
are enforced by the issue #13 release gate.

## 4. systemd boundary

`deploy/analytico.service` runs as `analytico`, writes only
`/var/lib/analytico`, and applies a 256 MiB memory ceiling, task/file limits,
empty capabilities, private devices/temp, a strict read-only system, namespace
and kernel protections, and an `0077` umask. Its offline
`systemd-analyze security` exposure score is gated by the release test.

The 192/256 MiB memory thresholds exceed the measured 48 MiB idle and 59 MiB
loaded collector RSS while remaining small for a VPS. `SIGTERM` stops the
listener, closes any active connection, checkpoints a healthy event store, and
exits; `TimeoutStopSec=3s` exceeds the measured shutdown time by two orders of
magnitude.

## 5. Caddy boundary

Replace `analytics.example` in `deploy/Caddyfile`, then validate and install it:

```sh
caddy validate --config deploy/Caddyfile
```

The vhost exposes `/tracker.aef65945.js`, `/tracker.fb64c486.js`,
`/tracker.78135195.js`, `/tracker.d9e94247.js`, `/tracker.81c3b777.js`,
`/tracker.6de111c9.js`, `/tracker.bc506cfe.js`,
`/tracker.js`, `/v1/event`, `/v2/event`, `/v1/p.gif`, `/admin`, and
`/admin/*`. `/` redirects to `/admin`;
all other paths, including health endpoints, receive `404`.
Caddy overwrites `X-Forwarded-For` and `X-Analytico-Country` before proxying.
Do not trust `CF-IPCountry` unless the origin is network-restricted to
Cloudflare. If Cloudflare is not used, clear the country header and Analytico
will honestly store `ZZ`.

The collector still enforces origins, content type, body/header bounds, rate
limits, and timeouts. Caddy is not an application state or authentication
layer.

## 6. Private dashboard

The dashboard uses `/admin` as its authenticated default/compatibility entry
and redirects to the selected site's canonical
`/admin/sites/{site}/overview` route. The same loopback process and canonical
hostname serve the six-destination site-scoped shell and the collector.
Replace `analytics.example` in `deploy/Caddyfile`, then validate and import
that one vhost:

```sh
caddy validate --config deploy/Caddyfile
```

Before starting the service for the first time, store the exact HTTPS origin
and print one short-lived setup link while the data directory is offline:

```sh
sudo -u analytico /opt/analytico/bin/analytico auth configure \
  /var/lib/analytico https://analytics.example
sudo -u analytico /opt/analytico/bin/analytico auth bootstrap \
  /var/lib/analytico --ttl 10m
```

Open the complete URL directly on the intended Apple device and create the
owner's synced passkey. The fragment is removed before the first subrequest and
the server stores only its hash. Add an independent second passkey from
`/admin/security` when practical. There is no password, email recovery, proxy
login, or public registration route.

The vhost uses explicit allowlists for public collection and `/admin` routes,
caps request bodies, applies HSTS, and has no Basic Auth directive. Analytico
validates every dashboard session and unsafe request server-side. An anonymous
navigation reaches the login page but never report state. Login and
additional-passkey ceremonies are the only JavaScript-required controls
because WebAuthn is a browser API.

Dashboard modifying forms use POST/redirect/GET, a token bound to the active
session, exact configured `Origin` comparison, and a same-origin referrer
policy. All dashboard HTML is complete without JavaScript. When JavaScript is
available, the executable self-hosts the exact content-addressed HTMX 4 core;
it enhances the same native controls and adds no JSON endpoint or client state.
The first enhanced view requests only HTML, CSS, and that local script.

## 7. Health and logs

`/healthz` proves the event loop can answer. `/readyz` checks the healthy-write
latch, the presence and basic properties of all durable paths, and exact schema
versions in both stores. A write failure latches readiness to `503`; the
process returns `503` without retrying later event writes until it is restarted.

The service emits newline-delimited structured JSON to stderr for:

- `serve_started`, containing only host and port;
- `request_failed`, containing only an error category;
- `serve_stopped`, containing accepted, rejected, rate-limited, permanent
  declared-bot/automation request-attempt, unknown classification,
  daily-ceiling-rejected, write-failure, and request-failure counters. D33
  removes the completed D32 shadow counters; durable traffic-quality version 5
  is the bounded date-range evidence for classes, rules, signals, D34 query
  verdicts, policy state, ceilings, and keyed identity-mint anomalies.

Logs never include IPs, user agents, paths, referrers, campaigns, properties,
request bodies, visitor IDs, matched rule IDs, keys, or database paths.
Counter names are closed and do not vary with input. Journald owns rotation.

The collector also owns the process-local 200-slot diagnostics ring documented
in `PROTOCOL.md`. `serve_stopped` reports only closed retained-outcome, wrap,
snapshot, and returned-row counters from that ring. The authenticated dashboard
boundary exposes a typed site-filtered snapshot seam, but issue #21 deliberately
adds no Live recent list, manual refresh control, polling, pause/hidden
behavior, or stale-state UI. D38 and issue #20 consume only one latest safe
post-watermark outcome for bounded Install correction guidance. Issue #43 owns
the full Live list and its refresh behavior.

Ring wrap overwrites the oldest summary and restart clears every slot. No backup
contains the ring, and logs never expand a summary into input-derived strings.
Install verification success instead reads the first committed selected-site
event after a session-bound signed DuckDB high-water position. The signed
private/no-store fields require the same passkey session, are not persisted,
and are suppressed from Referrer headers. A bare Install GET starts a new
verification session; the normal **Check again** GET remains the recovery and
JavaScript-disabled path.

## 8. Backup

The MVP chooses a short honest outage over an online two-store coordinator:

```sh
systemctl stop analytico
sudo -u analytico /opt/analytico/bin/analytico \
  backup /var/lib/analytico /var/backups/analytico/2026-07-31T120000Z
sudo -u analytico /opt/analytico/bin/analytico \
  restore /var/backups/analytico/2026-07-31T120000Z \
  /var/backups/analytico/verify-2026-07-31T120000Z --verify
sudo -u analytico /opt/analytico/bin/analytico \
  doctor /var/backups/analytico/verify-2026-07-31T120000Z
systemctl start analytico
curl --fail http://127.0.0.1:4318/readyz
```

`backup` requires readable supported stores and a secure key; checkpoints both
engines, copies into a unique sibling temp directory, fsyncs files and the
directory, writes the actual migration versions, sizes, and SHA-256 hashes to
`manifest.json`, then atomically renames to a destination which must not exist.
This deliberately allows the 1.0 candidate to create the required v0.3.0
schema-2 upgrade backup without first mutating either store. Never overwrite
the last known-good backup.

Lost-passkey recovery is deliberately local and first performs that same
verified matched backup:

```sh
systemctl stop analytico
sudo -u analytico /opt/analytico/bin/analytico auth reset \
  /var/lib/analytico /var/backups/analytico/pre-auth-reset --confirm
sudo -u analytico /opt/analytico/bin/analytico auth bootstrap \
  /var/lib/analytico --ttl 10m
systemctl start analytico
```

Reset preserves sites, reports, events, and the configured origin while
removing owner credentials, challenges, sessions, and bootstrap state. It
never creates a recovery credential or prints a new token implicitly.

## 9. Restore

`restore ... --verify` rejects an unknown manifest/schema, unsupported recorded
migration version, unexpected file name, size/hash mismatch, insecure key,
unreadable store, or existing destination. It copies into a sibling temp
directory, creates a secure DuckDB temp directory, validates both isolated
stores at the manifest's recorded versions, fsyncs, and atomically renames.

For production recovery:

1. Stop the service.
2. Rename the current data directory; do not delete it.
3. Restore the matched metadata/events/key backup to a new directory.
4. Run `doctor` and a representative report.
5. Rename it to `/var/lib/analytico`, start, and check readiness.

## 10. Upgrade, migration, and rollback

```sh
systemctl stop analytico
/opt/analytico-new/bin/analytico backup \
  /var/lib/analytico /var/backups/analytico/pre-1.0.0
/opt/analytico-new/bin/analytico migrate \
  /var/lib/analytico /var/backups/analytico/pre-1.0.0
# assign every existing site's explicit zone; use --offline-rebucket with events
/opt/analytico-new/bin/analytico site timezone-set \
  /var/lib/analytico example Europe/Berlin --offline-rebucket
/opt/analytico-new/bin/analytico doctor /var/lib/analytico
# atomically switch /opt/analytico to the new verified release
systemctl start analytico
```

The second migration argument is mandatory only while a supported older store
actually needs an upgrade. Its manifest, hashes, key, and legacy versions must
match the live pair before migration starts. The event file also receives a
conservative free-space preflight. `init`, `report`, `site`, `event`, goal,
funnel, and authentication commands never substitute for this explicit step.

Migrations are numbered. DuckDB event migrations use one transactional
create/backfill/swap. Turso metadata migrations follow D19 replayable durable
autocommits and write their ledger row last; compensation is not described as
a database transaction. Event migration 5 must preserve every schema-4 row and
identity link, prove the complete D32 mapping and preserved-field fingerprints,
and remove `exclusion_source` only in the swap transaction. Killing the process
during the million-row DuckDB migration chain and retrying with the same
verified backup is an automated release gate. A binary refuses a database with
a newer unknown schema. Event schemas 3, 4, 5, 6, and 7 require database-pair
restoration before an older binary is started for rollback. Metric-v1 reports
continue to use their original UTC dates; explicit timezone rebucketing
populates the separate site-local date/offset before the service can become
ready.

Event migration 6 must preserve every schema-5 row/link/class/version/rule and
every unrelated-field fingerprint, add only the documented unknown evidence,
and prove the legacy shadow column absent before swap. Its exact-predecessor
million-row interruption/retry and repeated-upgrade path is part of the same
release gate.

Event migration 7 must preserve every schema-6 row and identity link, add only
the sixteen-zero-byte unknown `network_day_id`, and prove row counts plus the
documented XOR, sum, minimum, and maximum fingerprints before swap. Metadata
migration 5 must add exactly one valid default policy for every existing site.
Fresh creation, exact metadata-4/event-6 upgrade, repeated upgrade, and killed
million-row migration/retry all verify the exact metadata-5/event-7 pair.

Keep the previous release directory and the verified pre-upgrade backup.
Rollback means stopping the new binary, restoring both stores and the key from
that backup into a new data directory, switching the data path, and starting
the prior binary. `zig build e2e-rollback` builds the actual prior commit and
rehearses this procedure.

For the schema-5 deployment, the pre-upgrade backup must record metadata schema
4 and event schema 4, and `restore ... --verify` plus the prior schema-4 binary
must open a disposable sibling copy before the production files are migrated.
After migration, `doctor`, metric-v1 parity, traffic-quality version 3, and one
real loopback collection/report journey must pass before the release symlink is
accepted. Verification then proves the service owner, `/proc/<pid>/exe`, the
private DuckDB library, ready/health endpoints, exact deployed commit, and the
authenticated public report path. The release record includes the backup and
artifact hashes. No runtime classifier file or network access is deployed.

For the schema-6 deployment, repeat the stopped-writer procedure with a
manifest recording metadata schema 4 and event schema 5. The exact schema-5
binary must open the independently restored sibling and reproduce the chosen
pre-migration reports. After migration, verify schema 6, permanent class
eligibility, traffic-quality version 4, and real browser/receipt signal rows.
Install the new tracker hash beside every old hash, back up the live Caddy
configuration, add only the new allowlisted path, validate, and use the Caddy
admin reload. Verify old and new immutable tracker paths after the reload.
Rollback restores the matched schema-5 pair, prior release symlink, and backed
up Caddy configuration; switching only one component is forbidden.

For the event-schema-7 deployment, repeat the stopped-writer procedure with a
manifest recording metadata schema 4 and event schema 6. The exact schema-6
binary must open the independently restored sibling and reproduce the chosen
pre-migration reports. After migration, verify metadata 5/event 7, metric-v1
parity, traffic-quality version 5, strict-off parity, strict-on scope, keyed
network-day privacy/anomaly evidence, daily-ceiling 429/idempotency behavior,
and one authenticated native traffic-policy journey. Rollback restores the
matched metadata-4/event-6 pair and prior release symlink. There is no tracker
or Caddy change for event schema 7.

For the metadata-schema-6 deployment, stop the sole writer and create a
verified metadata-5/event-7 pair backup. Independently restore that backup and
prove the exact metadata-5 predecessor opens it before migration. The candidate
must preserve all site, origin, timezone, exclusion, traffic-policy, goal,
funnel, authentication, and event facts; backfill one empty `site_settings` row
per existing site; and create unique origin ownership before writing the v6
ledger. A predecessor with cross-site duplicate origins fails closed before
the ledger and requires operator correction; migration never chooses an owner.

After migration, verify metadata 6/event 7, `doctor`, existing report parity,
authenticated first-site creation, exact completed resubmission, and immediate
collection under the refreshed policy. Rollback restores the matched
metadata-5/event-7 pair before starting the prior binary. There is no DuckDB,
tracker, Caddy, process, or dependency change for metadata schema 6.

For the metadata-schema-7 deployment, repeat the stopped-writer procedure with
a manifest recording metadata 6 and event 7. Independently restore that backup
and prove the exact `a2d71c0` metadata-6 predecessor opens it and reproduces the
selected reports before migration. The additive migration creates empty
`segments` and `saved_views` tables and writes ledger 7 last; it does not alter
site, policy, authentication, goal, funnel, event, identity, tracker, or
service-unit facts. The complete #30 release separately changes Caddy only for
the 12 saved-state mutation routes defined by D40; that configuration change is
not part of the metadata migration.

After migration, verify metadata 7/event 7, `doctor`, metric-v1 parity, exact
saved-state CRUD and site isolation, one filtered Overview/Trend/Breakdown
journey, JavaScript-disabled apply/remove, and the filtered million-row gates.
The exact deployed binary/library, one process/listener, health/readiness,
public passkey boundary, and canonical deep-link return must resolve to the
merged release. The release record includes artifact and backup-manifest
hashes. Rollback stops the writer, restores the matched metadata-6/event-7
pair and the backed-up predecessor Caddy configuration, proves the predecessor
again, and only then switches the release symlink. The metadata-6 binary must
never be started against the migrated metadata-7 file.

## 11. Retention and site deletion

Run maintenance with the service stopped:

```sh
analytico maintain /var/lib/analytico 2025-06-01
```

The cutoff must be a valid UTC date at least 400 days old. The command deletes
event rows with `received_date_utc < cutoff`, then identity links whose
`(site_id, anonymous_id)` no longer exists in `events`. It then removes events,
identity links, and metadata for sites already marked disabled, checkpoints
both stores, and reports exact before/expired/site/after counts. A too-recent
cutoff fails before either store is opened.

Direct site deletion is also two phase:

```sh
analytico site disable /var/lib/analytico example
analytico site delete /var/lib/analytico example --confirm example
```

The second command removes DuckDB identity links and events, checkpoints, then
deletes Turso metadata, making a retry safe.

## 12. Normalized export

```sh
analytico export /var/lib/analytico example \
  2026-01-01 2026-07-31 /secure/path/example.csv
```

Export pages through the real database in bounded 1,000-row chunks and creates
a new mode-`0600` CSV. It includes normalized event dimensions and properties,
traffic class, classifier version, bounded rule, and the release-scoped legacy
verdict, but not visitor/session IDs or the raw User-Agent. Spreadsheet formula
prefixes are escaped. The destination must not already exist.

## 13. Disk-full and corruption response

After any event write failure, collection writes stop, readiness is unhealthy,
and the process does not hot-loop retries. Stop the service, free space outside
database/WAL files, preserve suspect files, and restart. Never truncate a
database or WAL. Run `doctor`; restore a verified snapshot if readability is
not recovered.

The M4 gate uses the kernel's real `RLIMIT_FSIZE=0` to force this path and also
tests corrupted bytes, wrong manifests, wrong key permissions, newer schemas,
missing live paths, and interrupted migrations.

## 14. Build and release gates

For the exact pinned environment:

```sh
zig build test -Doptimize=ReleaseSafe \
  -Dturso-native-path=<exact-prefix>
zig build e2e-m0 e2e-m1 e2e-m2 e2e-timezone e2e-properties \
  e2e-analysis e2e-traffic-quality e2e-classifier e2e-schema5-migration \
  e2e-schema6-migration e2e-schema7-migration e2e-heuristics \
  e2e-exclusion e2e-legacy-migration \
  e2e-m2-browser e2e-identity-browser e2e-tracker-browser e2e-m3 e2e-m4 \
  e2e-m6 e2e-m7 e2e-filters e2e-passkey-p1 \
  e2e-metadata7-migration \
  -Doptimize=ReleaseSafe -Dturso-native-path=<exact-prefix>
zig build bench-properties \
  -Doptimize=ReleaseSafe -Dturso-native-path=<exact-prefix>
zig build e2e-rollback \
  -Doptimize=ReleaseSafe -Dturso-native-path=<exact-prefix>
zig build e2e-release-full \
  -Doptimize=ReleaseSafe -Dturso-native-path=<exact-prefix>
```

`e2e-release-full` checks the outer and inner checksums, private DuckDB linkage,
Caddy syntax, systemd security, and a fresh real-data report from the extracted
archive, then runs the complete packaged real-process set including classifier,
traffic-quality, universal filters, and exact schema-4, schema-5, schema-6,
plus metadata-6 predecessors. The named `e2e-filters` and
`e2e-metadata7-migration` gates run independently above and again inside this
full packaged qualification. Large event/browser fixtures are acceptance
tooling only and are not shipped.
