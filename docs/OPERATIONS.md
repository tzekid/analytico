# Operations

Production uses one user service behind Caddy:

```text
~/.local/opt/analytico/current/bin/analytico
~/.local/share/analytico-sqlite/analytico.db
~/.local/share/analytico-sqlite/secret.key
```

`analytico init ~/.local/share/analytico-sqlite` creates the data directory
with mode 0700 and the key with mode 0600. Protect the key, database, backups,
and site-specific internal secrets.

Install `deploy/analytico-user.service` as
`~/.config/systemd/user/analytico.service`, then:

```sh
systemctl --user daemon-reload
systemctl --user enable --now analytico.service
systemctl --user status analytico.service
```

The unit runs `doctor` before every start, listens on `127.0.0.1:4318`, and
restarts only after failure. Caddy exposes immutable `/t/*` assets and browser
`/e`, supplies the real client address, and hides `/i`, health, readiness, and
all other routes. Trusted applications send signed `/i` requests over
loopback.

## Administration

Stop the service before changing sites, goals, funnels, spend, or data:

```sh
systemctl --user stop analytico.service
analytico site list --data ~/.local/share/analytico-sqlite
systemctl --user start analytico.service
```

The writer lock enforces this boundary. Read-only reports, `stats`, `tail`,
and `doctor` remain available while the service runs.

Create a site and emit its exact immutable snippet:

```sh
analytico site add plosca https://plosca.ru \
  --mode lite --data ~/.local/share/analytico-sqlite
analytico site snippet plosca https://analytico.example \
  --rum --data ~/.local/share/analytico-sqlite
```

`site secret-show` prints the server-ingestion secret. Never place that secret
in browser markup, logs, or public proxy configuration.

## Backup and restore

Stop the service before maintenance:

```sh
analytico backup ~/.local/share/analytico-sqlite \
  ~/.local/share/analytico-backups/2026-08-28.db
analytico restore ~/.local/share/analytico-backups/2026-08-28.db \
  ~/.local/share/analytico-restored
analytico doctor --data ~/.local/share/analytico-restored
```

Backup uses SQLite's online backup API and verifies the result. It creates the
database plus a `.key` companion; both are required. Destinations must not
exist and are never overwritten.

Prune and vacuum create and verify a new backup before changing data:

```sh
analytico prune ~/.local/share/analytico-sqlite --before 2026-01-01 \
  --backup ~/.local/share/analytico-backups/pre-prune.db
analytico vacuum ~/.local/share/analytico-sqlite \
  --backup ~/.local/share/analytico-backups/pre-vacuum.db
```

## Internal signatures

For exact body bytes `BODY` and Unix timestamp `T`, send lowercase hex
`HMAC-SHA256(site_secret, T + "." + BODY)` in `X-Analytico-Signature` and `T`
in `X-Analytico-Timestamp`. The body must use the site's public ID and arrive
within five minutes.

## Diagnostics

```sh
analytico doctor --data ~/.local/share/analytico-sqlite
analytico stats --data ~/.local/share/analytico-sqlite
analytico tail plosca --follow --data ~/.local/share/analytico-sqlite
analytico report coverage plosca --days 7 --data ~/.local/share/analytico-sqlite
analytico report traffic plosca --days 7 --data ~/.local/share/analytico-sqlite
```

Normal reports exclude internal traffic and known bots or monitors while
retaining unknown traffic. `report traffic` exposes every class. Rejection
counters and logs contain safe reason names only, never request bodies or
user-controlled values.
