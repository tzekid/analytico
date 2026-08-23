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

The dashboard is served at `/admin` by the same loopback process and canonical
hostname as the collector. Replace `analytics.example` in `deploy/Caddyfile`,
then validate and import that one vhost:

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
- `serve_stopped`, containing accepted, rejected, rate-limited, bot, unknown
  classification, write-failure, and request-failure counters.

Logs never include IPs, user agents, paths, referrers, campaigns, properties,
request bodies, visitor IDs, keys, or database paths. Journald owns rotation.

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

Migrations are numbered and transactional. Killing the process during the
million-row v1-to-v3 DuckDB migration chain and retrying with the same verified
backup is an automated release gate. A binary refuses a database with a newer
unknown schema. Event schema 3 requires database-pair restoration before an
event-schema-2 binary is started for rollback. Metric-v1 reports continue to
use their original UTC dates; explicit timezone rebucketing populates the
separate site-local date/offset before the service can become ready.

Keep the previous release directory and the verified pre-upgrade backup.
Rollback means stopping the new binary, restoring both stores and the key from
that backup into a new data directory, switching the data path, and starting
the prior binary. `zig build e2e-rollback` builds the actual prior commit and
rehearses this procedure.

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
not visitor/session IDs. Spreadsheet formula prefixes are escaped. The
destination must not already exist.

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
zig build e2e-m0 e2e-m1 e2e-m2 e2e-properties e2e-legacy-migration \
  e2e-m2-browser e2e-m3 e2e-m4 e2e-m6 \
  e2e-m7 e2e-passkey-p1 \
  -Doptimize=ReleaseSafe -Dturso-native-path=<exact-prefix>
zig build bench-properties \
  -Doptimize=ReleaseSafe -Dturso-native-path=<exact-prefix>
zig build e2e-rollback \
  -Doptimize=ReleaseSafe -Dturso-native-path=<exact-prefix>
zig build e2e-release \
  -Doptimize=ReleaseSafe -Dturso-native-path=<exact-prefix>
```

`e2e-release` checks the outer and inner checksums, private DuckDB linkage,
Caddy syntax, systemd security, and a fresh real-data report from the extracted
archive. Large event/browser fixtures are acceptance tooling only and are not
shipped.
