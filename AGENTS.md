# Analytico engineering doctrine

This file is normative. `PRODUCT.md`, `docs/PROTOCOL.md`, and
`docs/OPERATIONS.md` follow it in that order. The schema and source define
implementation detail. The archived Turso/DuckDB product survives in Git
history and does not govern this implementation.

## Product boundary

Analytico is one Zig executable, one vendored SQLite database engine, one
analytics database file plus one replay database file, and small generated
browser trackers. Passkey verification uses two small pure-Zig libraries
vendored like SQLite (`vendor/passcay`, `vendor/zbor`). Session replay uses
the vendored rrweb recorder and player (`vendor/rrweb`, MIT), loaded lazily
and only for consented Full-mode visitors; it is never part of the Lite or
Session trackers. The build stays offline. An optional `geo.bin`, built by
`analytico geo import` from the DB-IP Lite database, places visitors by
country, region and city at ingest. The CLI and the
server-rendered web workspace are the product interfaces; both read the same
fixed queries. Caddy owns TLS and public routing.

The workspace renders complete HTML in Zig. One small embedded script makes
navigation, forms, dialogs and charts feel instant; every page also works as
plain HTML. AI is optional: each person's own ChatGPT plan (Sign in with
ChatGPT, OpenAI's open-source program, straight to the Responses API), an
operator key for Anthropic, OpenAI or any OpenAI-compatible endpoint, or a
read-only MCP connector for Claude and ChatGPT. `web/agent.zig` is the one
loop for every provider: the report catalog is its tools, run in-process, and
answers stream to the browser. Plan errors stop; nothing falls back to another
provider. Only aggregates leave the instance, and every AI call is logged with
the exact text sent.

Until measured evidence and a current consumer require otherwise, do not add
another storage engine, runtime dependency, process, queue, cache, rollup,
ORM, generic query language, plugin system, frontend framework, client-side
rendering, or compatibility protocol.

Three tracking modes are current. Lite stores nothing in the browser.
Session adds a per-tab ID in `sessionStorage`. Full, the default for new
websites, starts every visit as Lite and adds a first-party visitor ID only
once consent is known: granted by the visitor, or not required under the
site's policy for that visitor ("ask in the EU, UK and Switzerland" by
default, "ask everyone", or "consent not required"). Global Privacy Control
and a withdrawn consent always keep a visitor in Lite, and the server enforces
this, not only the tracker. Identified users are stored as a keyed hash of
the operator's own ID; a visitor belongs to the most recent `identify()`
until `reset()`, links are never rewritten, and deleting a user removes every
linked visitor's events and replays.

## Architecture

The defining path is explicit:

browser or trusted application -> closed envelope -> strict validation ->
normalization -> durable SQLite transaction -> fixed report query -> CLI or
workspace.

- Server receipt time determines acceptance and storage date.
- Client time is retained only for bounded ordering.
- Browser events never establish authoritative commercial outcomes.
- Unknown traffic remains unknown. Classification never silently discards it.
- Raw events are evidence; report meanings are fixed, versioned definitions.
- One process owns writes. Request workers read through their own
  connections; every write goes through the single write connection under one
  lock, and network calls (AI, SMTP, integrations, webhooks) never happen
  while holding it. Replay writes use their own connection and lock. WAL,
  foreign keys, prepared statements, bounded inputs, and short transactions
  are mandatory.
- Tracker batches commit in groups: whichever batch arrives while no commit
  runs takes every waiting batch, runs each in its own savepoint and commits
  once. A lone batch never waits; a failed batch rolls back alone. WAL with
  `synchronous=NORMAL`: no sync per commit, consistent after any crash,
  only a power cut can lose the last moments of writes.
- A page's independent report queries may run in parallel (`data.prefetch`)
  on a small pool of extra read connections, each task with its own arena;
  rendering then reads the results from a request-scoped memo. Pages list
  exactly the calls they make, so the memo and the render agree. Only views
  with at least 20,000 raw rows past the rollup cut fan out; on smaller ones
  the hand-off costs more than the queries, so they run inline.
- Live updates use one broadcaster thread: a worker checks access and hands
  the connection over, so an open stream never holds a worker. Streams are
  capped; a slow reader is dropped.
- Every workspace response carries `Server-Timing`, and statements slower
  than 250 ms are logged with their SQL text (values are always bound, never
  part of it). The planner gets statistics from `PRAGMA optimize` at start
  and nightly; when it still picks badly, pin the index and say why.
- A later schema change adds its numbered compiled migration and explicit
  migration command together. Normal `serve` refuses a non-current schema.
- Collection protocol v2 is current; v1 stays accepted for snippets already
  deployed and gains no new fields.
- Daily rollups exist because measurement required them: at ten million page
  views a month, raw scans made a 30-day overview take minutes. A closed UTC
  day never changes (acceptance uses receipt time), so the background job
  summarises it once per dimension, plus each remembered visitor's active
  weeks for cohorts. The current day is summarised up to a cut 30 seconds
  behind the clock every five minutes. Reports read rollups up to the cut
  and raw rows after it; distinct visitors and sessions after the cut skip
  anyone the partial summary already counted under the same key (an indexed
  lookup), so totals stay exact. Views with more than one filter read raw
  rows. Raw events stay the source of truth; rollups are rebuilt from them
  and pruned with them.
- Each summarised day also keeps its visits' entry, exit and next pages
  and the sections each page's readers reached (as rollup dimensions), and
  each page's Web Vitals as counts of values
  rounded up to two significant figures (`vitals_daily`; rounding up keeps
  every good and poor threshold exact). Paths reads whole days of them,
  since visits are split at midnight; Performance reads them up to the cut.
  Retention (the last eight weeks, 11 s at 2.5 million page views a month)
  is computed once a day into `cache`; nothing else is cached.
- Browser events store their page view's traffic class when they arrive,
  so leaving out bots never looks up each event's page view in a report.
- Page views, summaries and events are clustered by `(site_id,
  received_at_ms, event_id)`, not by their random event ids: a time range
  must be one contiguous read. Keyed by event id, each row of "today" cost a
  random lookup and one day of raw rows took about a second per query. A
  page's engagement (active time, scroll, interactions) is copied onto its
  page view, so reports never join summaries for those three numbers.
- The workspace stays server-rendered HTML; `app.js` only makes it feel
  instant. It prefetches on hover, touch and press, keeps recent pages to
  show at once (then refreshes them in place), patches the page instead of
  replacing it (so focus and open menus survive), and remembers each
  website's period (never filters). Without it every link and form still
  works as a plain page load.

## Data safety

Never persist raw IP addresses, full user agents, full URLs, arbitrary query
strings, form values, selected text, profile text, names, email addresses,
birth dates, dating preferences, uploaded files, payment credentials, or
browser fingerprints. Site search keeps the bounded, lowercased term only,
and drops anything shaped like an email address or long number.

DOM snapshots and mouse movement exist only as session replays: Full mode,
consented visitors, sites that turn recording on, masked in the browser
before they leave (all text unless explicitly unmasked, every input value
always, images and media replaced), capped per session, stored in the replay
database with their own retention, and deleted with the visitor. Heatmaps
store aggregated click cells, scroll reach and attention per page, never a
per-visitor trail.

Operator accounts store operator emails, passkey public keys, linked
Google/ChatGPT subjects and optional argon2id password hashes; that is account
data, never visitor data. Passkeys and provider callbacks are bound to the
`public_origin` pinned by the CLI, never to request headers. A provider
identity is linked only by a signed-in user, an invite or first run — never by
matching email addresses. The native apps sign in as built-in OAuth clients
(`analytico-*`, redirect `analytico://oauth`); their tokens read `/api/v1`
and write chart notes, never `/mcp`, and MCP tokens never read `/api/v1`.
Session, invite and OAuth tokens are stored
only as SHA-256 hashes. API keys and the SMTP password are encrypted at rest
with a key derived from the instance key.

Exact origins and site state are checked server-side. Internal ingestion uses
a site-specific secret, timestamp, and body signature. Rejection diagnostics
never echo user-controlled payload data. Cross-domain links and heatmap
overlays use short-lived tokens signed with the instance key.

Teams have roles (owner, admin, editor, viewer) and may be limited to chosen
websites. API keys and public share links are stored as SHA-256 hashes. A
Google Workspace domain rule may create viewer accounts for that verified
hosted domain; it never links an existing account by email address.
Settings changes, invitations, role changes, exports, deletions, keys and
share links are written to the audit log.

## Simplicity and verification

- Apply YAGNI before every abstraction or feature.
- Prefer plain Zig types and explicit SQL.
- Extract shared code after two real consumers demonstrate matching semantics.
- Do not add fallbacks that hide corrupt configuration or missing data.
- Prefer a few end-to-end checks using the real executable, on-disk SQLite,
  and loopback HTTP. Add narrow tests only where they catch distinct failures.
- A compile alone is not delivery, but avoid ceremonial test matrices and
  workflow churn.
- Preserve unrelated work and never add tool branding to commits or artifacts.

## Operations

Backups use SQLite's online backup API and cover both database files.
Restore writes a new data directory. Prune and vacuum require a newly
created, verified backup. Replays are pruned on their own schedule (30 days
by default). Graceful shutdown
stops accepting work, finishes the active transaction, and checkpoints WAL.
