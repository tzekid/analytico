# Milestone 0.2: "Continue with ChatGPT", one engine, less code

Status: plan. Nothing here is built yet.

Two tracks, sequenced so the first pays for the second:

1. **ChatGPT plan inside Analytico.** "Continue with ChatGPT" in Settings → AI.
   Ask, "Why?", alert triage and digests then run on the user's own ChatGPT
   plan — no API key, no extra bill — and Ask becomes an analyst that
   queries the data itself and streams its answer.
2. **Codebase overhaul.** One report engine behind every surface, one way to
   query SQLite, one way to render HTML, one asset pipeline, one HTTP
   client, one test harness. Fewer lines, faster pages, nothing lost.

Rules for every item: YAGNI, less code wins, never at the cost of a feature,
UX or performance. Every item names its verification (end-to-end first).

---

## Part A — ChatGPT plan usage

### A1. What exists today (measured)

- `src/web/ai.zig` (714 lines): bring-your-own-key AI. Providers:
  `anthropic`, `openai` (Chat Completions), `compatible`. One synchronous
  `call()` per request; no tools, no streaming.
- AI features: **Ask** (`ai.ask`, one call with a text "packet" of the
  view), **Why?** on a chart point (`ai.why`, drivers + one call), **alert
  triage** (`ai.triageText`, from the jobs thread) and the **weekly digest**
  (`ai.digest`, jobs thread).
- "Use my ChatGPT subscription" today means the **MCP connector**: ChatGPT
  calls Analytico's tools from chatgpt.com (`src/web/mcp.zig`, four tools).
  The in-app features cannot use the plan.

### A2. How others do it (looked up, not guessed)

**T3 Code** (pingdotgg/t3code, TypeScript):

- **Two modes.** It either drives Codex CLI's own login (the user runs
  `codex login`), or it runs a **managed** sign-in of its own.
- **Managed sign-in** (`apps/server/src/provider/CodexChatGptAuth.ts`):
  - a `127.0.0.1` loopback listener on a random port, with PKCE;
  - `client_id=dynamic_agent_client`, `agent_name_hint: "T3 Code"` and an
    `ext_agent_host_id`;
  - scopes `openid profile email offline_access resource.invoke
    chatgpt.tokens.use.direct`, resource `https://api.openai.com/v1`.
- **Running Codex with those tokens** (`CodexManagedRuntime.ts`): it spawns
  `codex app-server` with a custom Responses provider
  (`env_key="ACCESS_TOKEN"`, `wire_api="responses"`,
  `requires_openai_auth=false`, `supports_websockets=false`) and passes the
  token in the child's environment.
- **Remote machines** (`CodexChatGptHandoff.ts`): a "primary" with a browser
  owns OAuth and hands the session to the remote destination, which then
  owns refreshes.
- T3 needs Codex because it is a coding-agent harness: shell, files, diffs.

**OpenAI's program**, "Sign in with ChatGPT → ChatGPT plan usage for
open-source apps" (developers.openai.com/siwc/token-sharing-open-source):

- **Who it's for.** It explicitly covers open-source and self-hosted apps.
  Paid or remotely hosted apps go through the interest form instead.
- **No client ID to request.** Each installation registers itself:
  - first sign-in sends `client_id=dynamic_agent_client`, `agent_name_hint`
    (the app's name) and `ext_agent_host_id` (stable per host,
    `urn:uuid:…`);
  - the callback returns an issued `client_id` (`oaiapp_…`), reused for
    every later sign-in;
  - no client secret, no partner key.
- **Endpoints:**
  - authorize `https://auth.openai.com/api/accounts/authorize`;
  - token `https://auth.openai.com/api/accounts/oauth/token`;
  - discovery `https://auth.openai.com/.well-known/openid-configuration`
    (gives the JWKS and `revocation_endpoint`).
- **Redirect URI** must be loopback: `http://127.0.0.1:<port>/auth/callback`.
  Only the port may vary, and `localhost` is not accepted. OpenAI's own
  self-hosted VM guide says: "A `127.0.0.1` callback reaches the computer
  running the browser, not the remote VM."
- **Checks after sign-in:**
  - verify the ID token's signature against the JWKS, plus `iss`, `aud`
    (the issued client ID), `exp` and `nonce`;
  - require `chatgpt.tokens.use.direct` among the granted scopes.
- **Tokens:**
  - access tokens last 1 hour;
  - refresh tokens last 30 days, **rotate on every refresh**, and refreshes
    must be serialised per session;
  - revoke at sign-out with `token=<refresh>`,
    `token_type_hint=refresh_token` and `client_id`.
- **Inference** is plain HTTPS: `POST https://api.openai.com/v1/responses`
  with `Authorization: Bearer <access_token>`, `store:false` and
  `stream:true`.
  - **Rejected:** `max_output_tokens`, `temperature`, `metadata`,
    `previous_response_id`, system-role items, and several more.
  - **Tools:** function tools must be grouped in a
    `{"type":"namespace", …}`. Tool search, hosted MCP, file search, code
    interpreter and image generation are unsupported.
  - **Success** is only a terminal `response.completed` event.
- **Models:** `GET https://api.openai.com/v1/models`; show entries with
  `visibility:"list"`, using `slug` and `display_name`.
- **Errors** worth handling specifically:
  - `subscription_sharing_usage_limit_exceeded` (429): link to
    chatgpt.com/settings/usage;
  - `subscription_sharing_user_not_eligible` (403);
  - `subscription_sharing_usage_unavailable` (503): back off;
  - refresh failures `invalid_grant` and `refresh_token_reused`: sign in
    again.
- **UI rules:**
  - a black or white **Continue with ChatGPT** button with OpenAI's logo;
  - a first-time "You're using your ChatGPT plan" / **Got it** confirmation;
  - **Using ChatGPT plan** shown near the composer, and **Manage usage**
    linking to chatgpt.com/settings/usage.
- **Limits:** for Plus users, the 5-hour usage limit is shared across every
  app using the plan.

**Codex app-server** (OpenAI's `codex-rs/app-server-protocol`), relevant
parts:

- **Transport:** JSON-RPC over stdio, starting with `initialize` →
  `initialized`.
- **Login** with `account/login/start` takes one of:
  - `{"type":"chatgpt"}` → `{loginId, authUrl}`, with a localhost:1455
    callback;
  - `{"type":"chatgptDeviceCode"}` → `{loginId, verificationUrl, userCode}`
    (the user must enable device codes in ChatGPT's security settings);
  - `chatgptAuthTokens`, which is marked "FOR OPENAI INTERNAL USE ONLY".
- **Conversation:** `thread/start`, then `turn/start`, then
  `item/agentMessage/delta` and `turn/completed`.

### A3. Decision: talk to the Responses API directly; no Codex

| | Direct (OpenAI's documented OSS flow) | Codex app-server (T3's way) |
|---|---|---|
| Runtime | Inside the single binary | A second program (Node/Rust) to install, update and supervise |
| What we need from it | Streaming text plus function tools | A whole coding agent with shell and files, which we must lock down so it can't read `secret.key` |
| Tools | Our own report catalog, called in-process | Via MCP or the experimental `dynamicTools` |
| Login on a remote server | Loopback (see A4) | Device code via Codex's own client, not our registration |
| Attribution | Our own `agent_name_hint`, "Analytico" | Codex |

We need a model that can call our tools and stream an answer, not an agent
that edits files. The direct route is the documented one for exactly this,
keeps "one binary, one file", and avoids running a shell-capable agent next
to the database. **No Codex.**

### A4. The login flow on a self-hosted server

The loopback rule is the one hard part, since Analytico usually runs on a
remote server. One mechanism covers every case:

1. **Click.** The user clicks **Continue with ChatGPT** (Settings → AI, or
   the Ask panel).
2. **Server prepares.** The server creates a sign-in attempt: fresh
   `state`, `nonce` and PKCE verifier, stored for 10 minutes. It also starts
   a **temporary listener on `127.0.0.1:1455`** (or a free port) for that
   attempt.
3. **Browser authorises.** A new tab opens OpenAI's authorize URL with
   `redirect_uri=http://127.0.0.1:<port>/auth/callback`.
4. **Completion**, whichever happens first:
   - **Workspace opened on the same machine** (local install, or an SSH
     tunnel `ssh -L 1455:127.0.0.1:1455 server`): the listener receives the
     callback and the dialog completes by itself.
   - **Remote server** (analytico.plosca.ru): the browser lands on
     "can't connect to 127.0.0.1". The waiting dialog says so in advance and
     offers **Paste the address**: one click reads the clipboard (or the
     user pastes manually). The server validates `state` and exchanges the
     code with its own PKCE verifier. The code is single-use and useless
     without that verifier, which never leaves the server.
5. **Validate and store.** Check the signature, claims and scope, then
   store the account (A5). Show the one-time confirmation:
   **You're using your ChatGPT plan** · **Got it**.

Net effect for a remote install: Continue, approve, copy the address,
click Paste. No CLI, no second program. Re-authorisation later uses
`id_token_hint` and skips account selection.

### A5. Data model

- **Host ID.** `settings.chatgpt.host_id` = `urn:uuid:<v4>`, generated once
  per instance (one Analytico instance is one agent host).
- **Accounts.** A new table `chatgpt_accounts`, one row per (Analytico
  user, issued client):
  - `user_id`, `client_id`, `subject` (validated `sub`), `email`, `plan_ok`
    (has `chatgpt.tokens.use.direct`);
  - `tokens` (sealed blob: access, refresh, ID token, expiry, scopes);
  - `model`, `created_at_ms`, `updated_at_ms`, `last_used_ms`.
  - Sealed with the existing master-key sealing (`src/web/secret.zig`), as
    API keys are today. Tokens never reach the browser, URLs or logs.
- **Sign-in attempts.** Reuse `auth_challenges` (already used by Google
  integration OAuth, with intent `integration:<kind>`) under intent
  `chatgpt:<user>`.

### A6. Who uses whose plan

A ChatGPT plan is personal; OpenAI binds each client to one user and
workspace. So:

- **Interactive AI uses the signed-in Analytico user's own ChatGPT
  account.** That covers Ask, Why? and the filter assistant (C-stretch).
  Teammates connect their own.
- **Background AI** (alert triage, weekly digest) uses, in order:
  1. the instance API key, if one is set;
  2. otherwise the plan of the person who created the alert or schedule,
     **only if they ticked** "Use my ChatGPT plan for my alerts and
     reports".
  - Usage shows in the AI log either way.
- **No pooling,** no "one account for the whole team".

### A7. Inference: one agent loop for every provider

A new `src/web/agent.zig` (about 350 lines) replaces `ai.call` for Ask and
Why?:

- **Providers:**
  - `chatgpt` (plan) → Responses, with OAuth bearer and plan rules;
  - `openai` (API key) → **also Responses**, the same code path with
    `max_output_tokens` allowed. Chat Completions is dropped for OpenAI.
  - `anthropic` (API key) → Messages with tools and streaming;
  - `compatible` (local or other models) → Chat Completions, one call, no
    tools, the packet only, as today.
- **Tools** come from the report catalog (B1), described once and exposed as:
  - a Responses `namespace` called `analytico`, with its functions inside;
  - an Anthropic `tools` array;
  - MCP `tools/list`.
- **The loop:**
  1. stream the request;
  2. text deltas go straight to the browser;
  3. collect `function_call` output items, then run each tool in-process
     against the request's read connection (the AI-sharing settings still
     apply);
  4. append `function_call` plus `function_call_output` items to `input`
     (no `previous_response_id`) and go again;
  5. stop at 6 rounds or `response.completed`.
- **Streaming to the workspace.** Ask posts and gets back a
  `text/event-stream` (chunked) carrying `delta`, `tool` (e.g. "looking at
  sources, 30 days") and `done` events. At most 4 concurrent AI streams; a
  fifth gets "busy, try again" rather than taking a worker.
- **Answers link back.** Tool results carry workspace URLs, so the answer
  can link "Pages filtered by /pricing" directly. The prompt asks for links.
- **Models.** `GET /v1/models` per account, cached 1 hour, shown as a
  picker. The default is the first listed model.
- **Errors** map to the UI rules: a limit gives **Usage limit reached** with
  **Manage usage**; ineligible gives an explanation; unavailable gives a
  retry. None of them silently falls back to the API key: OpenAI says plan
  errors "stop inference", so we stop too.

### A8. Shared pieces this needs (built once, B5/B6)

- `net.zig`: one process-wide `std.http.Client` (thread-safe connection
  pool; the CA bundle loads once), JSON POST/GET helpers, and an **SSE
  reader** over `Response.reader()`. It replaces three private clients
  (ai, oidc, integrations).
- **JWKS verification** in `oidc.zig`: fetch `jwks_uri`, cache by `kid`, and
  verify RS256 with `std.crypto.Certificate.rsa.PKCS1v1_5Signature`
  (`rsa.PublicKey.fromBytes(exponent, modulus)`). Google sign-in gains real
  signature checks at the same time; today it checks claims only.

### A9. Tests (end to end)

`tests/ai.mjs` adds a stand-in OpenAI, following the pattern of the existing
stand-in Google, Meta and Slack:

- authorize, which redirects with `code`, `state` and `client_id`;
- token, refresh and revocation endpoints;
- JWKS with a test RSA key (Node `crypto` signs the ID token);
- `/v1/models`;
- `/v1/responses`, streaming a `function_call` then text then
  `response.completed`, and on demand `response.failed` with
  `subscription_sharing_usage_limit_exceeded`.

Endpoints come from `settings.chatgpt.auth_origin` and
`settings.chatgpt.api_base` (production defaults, set by the test only).

The test asserts, in a real browser:

1. paste-to-complete sign-in, plus listener completion through the loopback
   port;
2. the ID-token signature check, including a wrong key being refused;
3. the scope check;
4. tokens sealed in the database, never in HTML;
5. Ask streams and runs a tool;
6. a refresh at expiry rotates the refresh token;
7. the usage-limit message with **Manage usage**;
8. sign-out revokes;
9. a teammate cannot use the owner's plan.

Expected size of Part A: about +1,000 lines (OAuth and JWKS ~250, agent loop
~350, UI ~200, test ~250), minus about 150 removed from `ai.zig`.

---

## Part B — The overhaul

Findings first (measured on today's tree: 19,845 lines of Zig, 1,344 of
`app.js`, 760 of CSS, 1,161 of tracker source, 1,700 of tests).

### B1. One report engine for every surface (biggest coherence win)

**Found:**
- The same three reports (overview, breakdown, time series) exist **twice**:
  in `share.zig` (read API) and in `mcp.zig` (MCP tools).
- `ai.zig` builds a third, text version.
- The CLI has a **fourth engine**, `src/reports.zig` (493 lines) plus
  `src/product.zig` (268 lines), with its own SQL. It ignores rollups, so it
  is slow at scale, and its semantics drift from the workspace.

**Do:** `src/web/catalog.zig`, the report catalog. Each entry has:
- a name, a JSON-Schema of parameters, and a description (written once);
- `run(view, args) → Result`: typed rows and series built on `data.zig`
  (rollups, prefetch, the memo);
- the access needed (AI sharing settings, role).

Renderers: JSON (`/api/v1/<name>`), CSV, text for AI and MCP, and tables
for the CLI.

**Surfaces built on it:**
- **Read API:** `share.zig` keeps routing and auth only.
- **MCP:** `mcp.zig` keeps the protocol only. `tools/list` is generated
  from the catalog, which grows from 4 tools to all of them.
- **AI tools:** Part A.
- **CLI:** `analytico report <name> <site> [--json|--csv]` uses the same
  catalog. `reports.zig` and the report half of `product.zig` are deleted;
  goal and funnel admin moves to store functions shared with the workspace.

**Catalog v1** (each maps to something the workspace already computes):
- `list_sites`, `overview`, `breakdown`, `timeseries`;
- `pages` (with time and scroll), `sources`, `campaigns`, `events`, `goals`,
  `funnel`, `paths`;
- `audience` (devices, languages, places), `retention`, `revenue` (orders,
  products), `errors`, `performance` (Core Web Vitals), `search`
  (site search and Search Console), `sessions` (list, no replay data),
  `consent`.

**Win:** about −900 lines net (−761 CLI engine, −150 API/MCP duplicates,
+~300 catalog). One meaning per number everywhere, and the CLI becomes as
fast as the workspace.

**Verify:**
- `tests/reports.mjs` is rewritten to compare the CLI, API and MCP outputs
  for the same view; they must be byte-identical in JSON.
- The existing `e2e.sh` CLI assertions are kept; they change to the
  catalog's names.

### B2. One way to query SQLite

**Found:**
- 244 `prepare` blocks with 557 `bind*` and 712 `column*` calls, each
  wrapped in `defer deinit`.
- The usual shape is about 6 lines of ceremony around one SQL string.

**Do:** comptime-typed helpers in `db.zig`:
- `db.all(arena, Row, sql, args)` → `[]Row`, where `Row` is a struct whose
  fields map to columns by position (`i64`, `f64`, `bool`, `[]const u8`
  (duplicated into the arena), and optionals for NULL);
- `db.one(…) → ?Row`, `db.value(i64, …)`, `db.exec(sql, args)`;
- `args` is a tuple bound by type.
- It replaces the ad-hoc `data.count` and `data.exec` with their
  `Bind` unions.
- **Statement cache** per connection, keyed by SQL text and sized to the
  number of distinct statements. Prepared statements are reused across
  requests: the pages run 7–18 statements, mostly the same SQL every time.

**Win:**
- about −700 lines;
- no more column-index bugs (types are checked at comptime);
- prepare cost removed from every request.

**Verify:** the full e2e suite (behaviour must not change), plus
`Server-Timing` before and after on dev.

### B3. One way to render HTML

**Found:**
- 626 `w.print` and 556 `writeAll("<…")` calls with long `\"`-escaped
  format strings (14 lines over 600 characters; the longest is 1,154).
- 360 manual `esc()` calls, so a missed one is an XSS bug.
- Positional arguments: we hit an arity bug this week in `manage.zig`.
- 440 inline `style="…"` attributes. The top repeats: `flex-wrap:nowrap`
  ×20, `color:var(--ink-2)` ×19, `margin-top:16px` ×18,
  `margin-bottom:16px` ×17.

This is my reading of "showing the HTML or whatever": a proper rendering
system.

**Do:**
1. **Comptime templates** (`html.zig`): `try h.render(w, tpl, .{ .name =
   value, … })`.
   - The template is a Zig multiline string (no `\"`), and `{name}` slots
     are **escaped by default**; `{!name}` is raw (pre-rendered HTML only).
   - Slots are named and checked at comptime against the struct, so a
     missing or extra field is a compile error.
   - No logic in templates: loops and conditions stay in Zig, which calls
     `render` per row.
2. **Components** (`ui.zig`): `card`, `cardHead`, `table`/`thead`, `metric`,
   `tabs`, `seg`, `pill`, `emptyState`, `dialog`, `field`, `switch`,
   `button`, `toast`, `rankRow`. They replace the 193 hand-written
   `class="card"` openings, 49 card heads, 20 tables, 18 dialogs and 49 POST
   forms. Several already exist half-formed (`layout.empty`,
   `analyze.tabs`, `layout.delta`, `sectionHead`); they move into `ui.zig`.
3. **CSS utilities and layout primitives** for the repeated inline styles:
   `.stack`/`.stack-s` spacing, `.nowrap`, `.muted` and friends, a
   `.cols-auto` grid. Target: under 60 inline styles (only data-driven
   widths and colours remain).
4. **Delete** the 4 unreferenced CSS classes (`cell-link`, `chart-empty`,
   `no-print`, `w3`). Merge the four separate `@media (max-width:720px)`
   blocks.

**Migration** goes file by file, small first (settings pages), each one its
own change with the e2e suite green.

**Win:**
- an estimated −1,500 lines of Zig, and pages ~10–15% smaller (inline
  styles gone);
- escaping becomes structural rather than remembered.

**Verify:**
- the e2e suite;
- a new `tests/html.mjs` that loads every page and checks for unescaped
  test markers and broken markup;
- page byte size before and after.

### B4. Page scaffolding that runs once

**Found:**
- Every page builds `app.shell()` **twice**: once in `layout.begin` and
  again in `layout.end`, which needs it only for the mobile tab bar. Each
  call runs the site list, the health check and, in Full mode, the consent
  share.
- The `siteBySlug` + `canSee` + role-check pattern repeats in handlers (11 ×
  `siteBySlug`, 8 × `canSee`, 25 × `ctx.can`).
- Settings POST handlers repeat validate → lock → write → audit → flash →
  redirect (70 × `ctx.flash`, 32 × `redirectFmt`).

**Do:**
- `ctx.shell` is computed once and `layout.end` reads it.
- `ctx.siteFor(role)` resolves the site from the path or form, checks
  access, and renders the standard 404/403 by itself.
- `ctx.saved(.{ .audit = …, .flash = …, .back = … })` finishes a settings
  write in one call.

**Win:** 2–4 fewer statements on every page, and an estimated −300 lines.

**Verify:** `Server-Timing` statement count per page drops (baseline: 7 on
simple pages, 18 on the overview); the e2e suite.

### B5. One outbound HTTP client

**Found:**
- `ai.zig`, `oidc.zig` and `integrations.zig` each build a fresh
  `std.http.Client` **per call**: new TLS and a certificate-store load every
  time.
- `jsonString` is defined twice.
- `base64url` is used ad hoc in five files.

**Do:** `src/net.zig`:
- one client in `Shared`, `postJson`, `postForm`, `getJson`, an SSE
  iterator, and timeouts;
- `jsonString` and the `b64url` helpers live here once.

**Win:** faster AI and integration calls (TLS reuse), about −120 lines, and
it is a prerequisite for Part A streaming.

### B6. One asset pipeline, built at compile time

**Found:**
- **Per-request hashing.** `tracker_assets.parsePath()` computes **SHA-256
  of every tracker variant on every `/t/…` request** until it finds a match
  (up to ~250 KB hashed per hit). Tracker requests are the hottest public
  path.
- **Shell-script generation.** `tools/build-trackers.sh` (awk/sed) writes
  eight files into `assets/generated/`, about 250 KB of committed output
  that has to be regenerated by hand.
- **Two registries.** `tracker_assets.zig` (`/t/`, 12-hex hash) and
  `web/assets.zig` (`/_/`, 10-hex hash, font URLs rewritten at runtime with
  `replaceOwned`).

**Do:**
- One `assets.zig`. Tracker variants are cut from `tracker-source.js` **at
  comptime**, using the same `@session`/`@sessiononly`/`@full`/`@rum`
  markers. The rrweb wrapping and the hashes are also computed at comptime.
- The stylesheet's font URLs are rewritten at comptime.
- Lookup is a comptime-built table.
- **Delete** `tools/build-trackers.sh` and `assets/generated/`.
- **Keep** `parseOlder` (old snippets must keep working).

**Win:**
- tracker requests become a table lookup (CPU per hit down by roughly
  100×);
- −8 generated files, −71 lines of shell, no "forgot to regenerate" class of
  bug.

**Verify:**
- a unit test that every path round-trips;
- `tests/browser.mjs` (the trackers load);
- `curl` the old snippet paths on dev.

### B7. Squash the migration history

**Found:**
- `schema.zig` is 781 lines: five SQL blocks plus table rebuilds.
- Both existing databases, prod and dev, are on schema 6, and there are no
  other installs.

**Do:**
- One baseline that creates schema 6 directly.
- `migrate` refuses anything older with "upgrade through release 0.1 first".
- Future migrations start at 7.

**Win:** about −400 lines; fresh installs no longer rebuild empty tables.

**Verify:**
- a test that `init` creates exactly the schema a migrated prod copy has
  (comparing normalised `sqlite_master`);
- `doctor` on prod after deploy.

### B8. Ingest and query performance

- **Adaptive parallel prefetch.**
  - **Found:** on a small site the overview spends 5.8 ms coordinating 16
    parallel tasks that take under 1 ms of SQLite work (`Server-Timing` on
    dev: overview 7.3 ms, Pages 2.6 ms).
  - **Do:** run inline when the view's raw part is small (the rows after
    the rollup cut fit a budget), and in parallel only when it is worth it.
- **Receipts window.**
  - **Found:** `record_receipts` (idempotency and conflict detection) is
    another random-key B-tree insert per record, kept as long as the data
    itself.
  - **Do:** prune receipts after 30 days. Retries happen within minutes,
    and the unique keys on page views, summaries and events still refuse
    late duplicates. The table stays small and hot, so every insert gets
    cheaper.
- **Statement cache:** see B2.
- **Shared HTTP client:** see B5.
- **Re-measure** with `tests/load.mjs` after B2 and B6. Targets:
  - ingest ≥ 600 batches/s at p50 < 50 ms;
  - all workspace pages < 50 ms at 2.5 M page views a month.

### B9. Browser code

**Found:** in `app.js`, 17 separate document click listeners, 22 `fetch`
calls repeating `credentials`/headers, and polling remnants already gone.

**Do:**
- **One delegated action table**
  (`data-action="copy|dialog|close|seek|…"` → handler), replacing the 17
  listeners.
- **One `get(url)`/`post(url, body)` helper** that adds the headers.
- **Fold the replay and passkey sections** into the action table.

**Win:** about −150 lines; one place to look for "what does this click
do". The no-page-transitions rule stays.

### B10. One test harness

**Found:**
- `workspace.mjs`, `v3.mjs`, `ux.mjs`, `browser.mjs` and `http.mjs` each
  re-implement starting the server, waiting until ready, port reservation,
  `until()`, the virtual passkey sign-in and the error-capturing browser
  context.
- `e2e.sh` carries a long CLI journey in shell.

**Do:**
- `tests/harness.mjs` provides `start({ geo, sites })`, `signIn(page)`,
  `until`, `newContext`, `api()`, `row()` and the stand-in servers.
- Each journey keeps only its story.
- The CLI journey moves into `tests/cli.mjs` using the catalog (B1).

**Win:** about −350 lines of test code, and new journeys are short.

### B11. Small cleanups

- Remove `html.Params.getOr` and `domain.validOrigin` (unused).
- One `ctx.now()`/`domain.nowMs()`; there are 27 call sites of
  `nowMilliseconds()`, some with `catch 0`.
- `data.setting`/`putSetting` (84 uses) get typed accessors for the dozen
  known keys, so typos become compile errors.
- `jobs.zig` gets its own `now`.

---

## Part C — Stretch ("aim for Mars")

Each builds on A plus B1 and is worth doing only after them.

- **Analyst panel everywhere.** ⌘K → "Ask" opens a side panel on any page,
  pre-loaded with that page's view (range, filters, page). It streams, uses
  catalog tools, and answers with links that open filtered views. This is
  Part A's Ask, made ambient.
- **Plain-language filters.** In the filter popover, typing "mobile visitors
  from Germany last month" makes one tool-free call that returns a view URL,
  shown as chips before applying. Cheap, and on the user's plan.
- **Session summaries.** On a replay page, "What happened?" turns the masked
  rrweb event stream (navigation, clicks, rage clicks, errors; never text
  or inputs) into a 3-line summary with timestamps you can click.
  Privacy-safe by construction: the recorder masks everything first.
- **Anomaly notes.** When the nightly job sees a day that breaks the trend,
  it drafts a chart annotation ("Traffic from news.ycombinator.com, 4× usual
  on /blog/x") for a human to keep or dismiss. It uses alert triage's
  drivers.
- **MCP parity for free.** Because MCP's tool list comes from the catalog,
  ChatGPT and Claude, used through the connector, get every report the
  workspace has.

---

## Part D — Sequencing

| Phase | Contents | Why this order |
|---|---|---|
| 0 | Baselines: line counts, `Server-Timing` per page on dev, `tests/load.mjs` at 100 k and 2.5 M, e2e duration | To prove the wins |
| 1 | B5 net, B6 assets, B7 squash, B11 | Small, mechanical, and B5 unblocks A |
| 2 | B2 typed queries + statement cache, B4 scaffolding | Every later change gets shorter |
| 3 | B1 report catalog, with CLI, API and MCP moved onto it | A's tools are the catalog |
| 4 | **A**: ChatGPT sign-in, the agent loop, streaming Ask, tests | The headline feature |
| 5 | B3 templates, components and CSS, file by file; B9 app.js | The largest diff, done once the code it touches has settled |
| 6 | B8 performance pass, B10 harness, re-measure | Close out with numbers |
| 7 | Part C, chosen by use | |

Each phase ships on its own: full e2e on a ReleaseSafe build, then deploy
to dev and prod (the standing rule).

**Expected outcome:**
- Zig from ~19,850 lines to roughly **15,500**, while gaining Part A;
- `app.js` −150, tests −350;
- 9 generated or shell files gone;
- one report engine, one query style, one rendering style, one asset
  pipeline, one HTTP client.

## Part E — Decisions made here (say if any is wrong)

1. **No Codex app-server.** We talk to the Responses API directly (A3).
2. **Remote sign-in is "Paste the address"**, with automatic completion
   when the loopback is reachable (A4). There is no device code: OpenAI's
   OSS flow doesn't offer one, and Codex's device code would sign in as
   Codex, not Analytico.
3. **The plan is personal.** Background use is opt-in per person (A6).
4. **The OpenAI API-key path moves from Chat Completions to Responses**,
   sharing the plan's code.
5. **CLI reports stay as commands** but run on the catalog; their output
   columns change to the catalog's names.
6. **The migration history is squashed** (prod and dev are the only
   databases).
7. **OpenAI's logo asset** for the "Continue with ChatGPT" button comes from
   OpenAI's brand resources. Downloading it is a separate, explicit step.

## Sources

- OpenAI, Sign in with ChatGPT — plan usage for open-source apps:
  https://developers.openai.com/siwc/token-sharing-open-source
  (pages: `/sign-in`, `/profiles-and-sessions`, `/models-and-inference`,
  `/self-hosted-vms`, `/token-reference`, `/errors-and-recovery`,
  `/preview-limitations`, `/codex-app-server`), and the UI guidelines,
  https://developers.openai.com/siwc/ui-ux-guidelines
- OpenAI, Responses API namespaces:
  https://developers.openai.com/api/docs/guides/tools-tool-search
- OpenAI Codex app-server: https://learn.chatgpt.com/docs/app-server and
  `codex-rs/app-server-protocol/src/protocol/v2/account.rs`
  (github.com/openai/codex)
- T3 Code: github.com/pingdotgg/t3code — `apps/server/src/provider/`
  `CodexChatGptAuth.ts`, `CodexManagedRuntime.ts`,
  `CodexChatGptHandoff.ts`
- Zig 0.17 standard library: `std/http/Client.zig` (thread-safe connection
  pool, streaming `Response.reader`) and `std/crypto/Certificate.zig`
  (`rsa.PKCS1v1_5Signature`, `rsa.PublicKey.fromBytes`)
