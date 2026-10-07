# Operations

Production uses one user service behind Caddy:

```text
~/.local/opt/analytico/current/bin/analytico
~/.local/share/analytico-sqlite/analytico.db   analytics
~/.local/share/analytico-sqlite/replays.db     session replays
~/.local/share/analytico-sqlite/secret.key
~/.local/share/analytico-sqlite/geo.bin        optional location database
~/.local/share/analytico-sqlite/exports/       optional daily CSV exports
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
restarts only after failure. Caddy exposes immutable `/t/*` assets, browser
`/e`, replay chunks `/r`, the heatmap overlay's `/h` and the workspace,
supplies the real client address, and hides `/i`, health and readiness. Trusted applications send signed `/i` requests over
loopback.

Twelve request workers share the listener, each with its own read
connection; writes share one connection behind a lock. Collector requests
have a fixed two-second deadline for network reads and writes, including
partial headers or bodies, and workspace requests thirty seconds (extended
only for AI calls, backups and retention). A stalled connection cannot hold
a worker indefinitely. A background thread sends scheduled emails, checks
alerts daily at 06:00 UTC, delivers goal webhooks every thirty seconds, and
at 03:00 UTC takes the automatic backup, applies retention, prunes replays,
syncs integrations and writes the daily export. Database transactions finish synchronously before
graceful checkpointing.

## Upgrading the schema

A release with a new schema refuses to serve an old database. Stop the
service and migrate with a fresh backup:

```sh
systemctl --user stop analytico.service
analytico migrate --data ~/.local/share/analytico-sqlite \
  --backup ~/.local/share/analytico-backups/pre-migrate.db
systemctl --user start analytico.service
```

Schema 10 lets the Mac, iPhone and iPad apps sign in (a built-in OAuth
client and a device name per sign-in); it is instant.
Schema 9 stores each browser event's traffic class (filled from its page
view in one pass; quick), adds per-day summaries of visit paths, page
sections and Web Vitals, and a small cache for Retention. It then has the background job
summarise every stored day again, 10 seconds of work every 30: a month of
80,000 page views a day takes about 11 minutes. Until it catches up,
reports read raw rows and are slower.
Schema 8 marks chart notes as drafts; it is instant. Schema 7 adds the table
for ChatGPT plan sign-ins; it is instant. Schema 6
adds engagement columns to page views and fills them from the
summaries in one pass; it is quick. Schema 5 rebuilds page views, summaries and events in time order. It takes
about seven minutes per million stored page views (plus the backup), while
the service is stopped; plan the window for a large database.

Snippets pasted before a tracker update keep working: an older tracker hash
gets the current tracker of the same mode, cached for an hour instead of
forever. Switching a website to another mode needs its new snippet.

## Location

Countries, regions and cities come from the free DB-IP "IP to City Lite"
database (CC BY 4.0, updated monthly). Download it and import it while the
service is stopped; the next start picks it up:

```sh
curl -O https://download.db-ip.com/free/dbip-city-lite-2026-10.csv.gz
analytico geo import dbip-city-lite-2026-10.csv.gz \
  --data ~/.local/share/analytico-sqlite
```

The address is looked up at collection and then discarded; only the place
names are stored. Without `geo.bin`, places stay unknown and the regional
consent policy asks every visitor.

## Replays

Replays live in `replays.db`, with their own write lock and retention (30
days by default, under Settings → Recording). Backups copy it next to the
analytics database as `<backup>.replays`; restore brings it back. An
instance migrated from before v3 gets an empty `replays.db` from `migrate`.

## Workspace access

A new instance prints a one-hour link to create the first account:

```sh
analytico init ~/.local/share/analytico-sqlite --origin https://analytico.example
```

`--origin` pins the public address that passkeys and Google/ChatGPT callbacks
are bound to (https, or http://localhost for development). It is set once and
never taken from request headers. On an existing instance, the first
`analytico user invite ... --origin` pins it; invites also recover access for
anyone who lost every way in (stop the service first):

```sh
analytico user invite you@example.com --origin https://analytico.example \
  --data ~/.local/share/analytico-sqlite
```

Everyone else is invited from Settings → Team. Invite and setup links open the
same chooser: create a passkey, or use another allowed method. Sign-in failures
are rate limited per client address. Sessions last thirty days; setting a new
password signs out every other device.

Google sign-in needs an OAuth client (Web application) from Google Cloud with
the redirect URI `https://<your-origin>/auth/google/callback`; paste its ID and
secret under Settings → Sign-in → Google. Sign in with ChatGPT (to Analytico itself) works the
same way once OpenAI issues a client ID (a limited trial today); using a
ChatGPT plan for AI needs none, see below. Nobody can remove
their last way in, and a method can only be turned off for everyone when no
one depends on it alone.

The Analytico apps for Mac, iPhone and iPad connect to an instance by its
address. They read `/.well-known/analytico` to check it, then sign in
through the instance's own sign-in page in a browser sheet and receive
tokens for the read API only (never for `/mcp`). Each signed-in device is
listed under Settings → Sign-in → Signed-in apps, where its owner can sign
it out. Behind Caddy nothing changes: the apps use the public origin.

Email delivery (alerts, scheduled reports, invites) uses any SMTP server:
STARTTLS on 587, TLS on 465, or a plain local relay. Configure it under
Settings → Email delivery, or from the shell with the service stopped; the
password is read from stdin and a test email must arrive before anything is
saved:

```sh
analytico email set --host smtp.fastmail.com --security tls \
  --username you@example.com --from "Analytico <you@example.com>" \
  --data ~/.local/share/analytico-sqlite < smtp-password
```

AI keys, integration tokens and the SMTP
password are stored encrypted with a key derived from `secret.key`, so a
backup without its `.key` companion cannot reveal them.

## AI on a ChatGPT plan

Everyone can run Ask and Why? on their own ChatGPT plan: Settings → AI →
Continue with ChatGPT. No client ID or key is needed; each person's first
sign-in registers this instance with OpenAI. OpenAI only returns to
`http://127.0.0.1:<port>/auth/callback`, so the service listens on loopback
port 1455 (or a free one) for ten minutes after a sign-in starts. When the
browser runs elsewhere, its tab stops at an unreachable `127.0.0.1` address;
paste that address into the waiting dialog. With an SSH tunnel
(`ssh -L 1455:127.0.0.1:1455 server`) it completes by itself. Tokens are
sealed like API keys and revoked at sign-out.

The same AI also fills in the filter popover from a description ("mobile
visitors from Germany last month"; the chips show the result before it is
applied), and summarises a replay from its pages, events, rage clicks and
errors, never from anything typed. Each call is logged under Settings → AI.

Once a day closes, a website whose page views were at least twice or at most
half the previous two weeks' mean (and well outside their spread) gets a draft
chart note naming the largest source, page or device behind it. Editors see
drafts above the overview's chart to keep or dismiss; no AI is involved.

A plan answers only for its owner. Alerts and scheduled emails use the
instance's API key, or, without one, the plan of an admin who ticked "Use my
plan for alerts and scheduled emails". At most four answers stream at once.

The MCP connector lives at `/mcp` with OAuth 2.1 discovery under
`/.well-known/`. It is read-only, scoped to the websites chosen on the consent
screen, and every tool call appears under Settings → AI.

## Integrations

Search Console, the Google Analytics 4 import and Google Ads reuse the Google
OAuth client from Settings → Sign-in; add the redirect URI
`https://<your-origin>/integrations/google/callback` to it and enable the
Search Console, Google Analytics Data and Google Ads APIs in its project.
Google Ads also needs a developer token. Meta uses a system-user access token
with `ads_read` and `ads_management`. Each integration's API endpoint can be
changed under "Advanced", for proxies or test stand-ins. Syncs run nightly and
on "Sync now"; failures show on the integration's card.

Webhooks receive JSON signed like `/i`: lowercase hex
`HMAC-SHA256(channel_secret, timestamp + "." + body)` in
`X-Analytico-Signature`, the Unix timestamp in `X-Analytico-Timestamp`. The
secret is shown once when the webhook is added.

The read API (`/api/v1/...`) uses keys from Settings → API & public links;
each reads with its creator's access, optionally narrowed to one website.

## Administration

The workspace changes sites, goals, funnels, spend and settings while the
service runs. CLI commands that write must stop the service first:

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
  --data ~/.local/share/analytico-sqlite        # Full; or --mode session|lite
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

The workspace also creates verified backups (Settings → Backups, plus an
automatic daily copy that keeps the last fourteen) under `backups/` in the
data directory. Restoring always uses the CLI into a new directory.

Backup uses SQLite's online backup API and verifies the result. It creates the
database plus a `.key` companion (both required) and a `.replays` companion
with the session replays. Destinations must not
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

## Deletion requests

```sh
analytico forget shop --user user-42 --data ~/.local/share/analytico-sqlite
analytico forget shop --visitor 7f3a…-uuid --data ~/.local/share/analytico-sqlite
```

The workspace does the same from a person's page or Settings → Consent &
privacy, and your backend can send a `forget` record to `/i`. Everything
linked is removed: page views, events, orders, errors, replays. Aggregated
heatmaps and form statistics hold no identifier and stay. Deletion is
recorded in the audit log.

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

## Live updates and timing

Open workspace pages receive visitors online and new activity over
server-sent events at `/<site>/stream`, at most 64 at a time. Behind Caddy
nothing extra is needed: the stream is sent with `no-transform`, so it is
never compressed or buffered. Every workspace response has a
`Server-Timing` header (database time, parallel queries, total), visible in
the browser's network panel, and the log names any statement slower than
250 ms (`slow_statement`).
