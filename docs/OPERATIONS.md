# Operations

## Data directory

`analytico init /var/lib/analytico` creates:

```text
analytico.db   SQLite configuration and evidence
secret.key     32-byte daily visitor key, mode 0600
writer.lock    advisory single-writer lock, created on first write
```

The directory is mode 0700. Protect `secret.key` and every site's internal
secret. `site secret-show` intentionally prints a secret only to the local
terminal; do not put it in browser markup or a public proxy configuration.

## Service

```sh
analytico doctor --data /var/lib/analytico
analytico serve --data /var/lib/analytico --listen 127.0.0.1:4318
```

`serve` requires the current schema and takes the exclusive writer lock.
Reports, stats, tail, doctor, and integrity remain available. Site changes,
goals, funnels, spend changes, backup, prune, and vacuum refuse to run until
the service stops. This is the explicit one-writer boundary.

Caddy exposes only the immutable `/t/*` assets and browser `/e`. Applications
send signed authoritative facts to loopback `/i`; do not publish `/i` unless a
separate trusted network boundary is explicitly designed.

## Backup and restore

Stop the writer, then:

```sh
analytico backup /var/lib/analytico /var/backups/analytico/2026-08-28.db
analytico restore /var/backups/analytico/2026-08-28.db \
  /var/lib/analytico-restored --verify
analytico doctor --data /var/lib/analytico-restored
```

Backup uses SQLite's online backup API and verifies integrity. It produces the
database plus `2026-08-28.db.key`; both are required for restore. Destinations
must not exist and are never overwritten.

Prune and vacuum create and verify a new backup first:

```sh
analytico prune /var/lib/analytico --before 2026-01-01 \
  --backup /var/backups/analytico/pre-prune.db
analytico vacuum /var/lib/analytico \
  --backup /var/backups/analytico/pre-vacuum.db
```

## Browser collection

Create a site and use the emitted snippet exactly:

```sh
analytico site add plosca https://plosca.ru --mode lite --data /var/lib/analytico
analytico site snippet plosca https://analytico.example --rum --data /var/lib/analytico
```

Add authored page metadata with `data-page-type`, `data-content-id`,
`data-release`, `data-consent`, and `data-internal` on the script. Mark sections
with `data-analytics-section` and controls with `data-analytics-action`.

## Internal signatures

For body bytes `BODY` and Unix timestamp `T`, send lowercase hex
`HMAC-SHA256(site_secret, T + "." + BODY)` in
`X-Analytico-Signature`, and `T` in `X-Analytico-Timestamp`. The body must use
the site's public ID and must arrive within five minutes.

## Diagnostics

```sh
analytico stats --data /var/lib/analytico
analytico tail plosca --follow --data /var/lib/analytico
analytico report coverage plosca --days 7 --data /var/lib/analytico
analytico report traffic plosca --days 7 --data /var/lib/analytico
```

Normal analytics reports exclude internal traffic and known bots/monitors by
default while retaining unknown traffic. `report traffic` exposes every class
and the internal flag so that the exclusion remains visible and auditable.

Rejection counters contain safe reason names only. Logs report codes and
counts, never request bodies, paths, event properties, or user-controlled
values.
