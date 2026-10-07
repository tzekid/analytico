# Roadmap: from privacy-first to "pick this instead of GA in 80% of cases"

Status: implemented, 2026-10-06. All phases (0–6) are built and covered by
`tests/v3.mjs`; `AGENTS.md` and `PRODUCT.md` carry the doctrine changes from
section 9. This document stays as the record of why.
What comes next: [MILESTONE-0.3.md](MILESTONE-0.3.md), native apps on every
platform.

## 1. Goal and interpretation

Make Analytico the analytics tool an individual, a small team, or a
mid-sized business picks instead of Google Analytics in most cases:

- Everything GA is actually used for day to day: traffic, sources,
  geography, conversions, ecommerce, campaigns, returning visitors.
- The behaviour tools people add on top of GA: session replay, heatmaps,
  identified users.
- The privacy modes stay, as options rather than the default:
  - Lite: cookieless, consent-free.
  - Session: per-tab, no cross-day identity.

The full-featured mode becomes the default for new websites. The catch is
that most of these features need visitor consent in the EU and UK. So
"default" has to mean full when allowed and a graceful fall back to Lite
otherwise, never "always on regardless". Section 4 covers how.

## 2. Where Analytico stands today (exploration)

### Strengths

GA-level or better already:

- Overview with comparison, annotations, segments and shareable URL state.
- Pages with section exposure, actions and paths.
- Acquisition: sources, campaigns, channels, spend and ROAS.
- Events and goals, funnels, and sessions with paths and a live view.
- Audience, Core Web Vitals (RUM), data health.
- Dashboards, alerts, scheduled emails, ⌘K search.
- Bring-your-own AI and an MCP connector for Claude and ChatGPT.
- Passkeys, Google and ChatGPT sign-in, backups and retention.
- Signed server events (`/i`) for authoritative revenue.

### Gaps found while exploring

| Gap | Evidence | Why it matters |
|---|---|---|
| **No geography** | `page_views.country` exists but is empty for all 278 prod page views; there is no IP-to-country lookup | "Where are my visitors?" is a top-3 GA question |
| **No single-page-app tracking** | The tracker sends one `page_view` per full load; no `pushState`/`popstate` handling | React/Next/Vue/Svelte sites, maybe half of new sites, undercount badly |
| **No returning visitors or retention** | Lite has a site/day pseudonym; Session is per tab | "New vs returning", retention and LTV are impossible |
| **No ecommerce model** | Money exists on events, but nothing for products, orders or carts | Shops are a big share of SMB analytics |
| **No site search, outbound or download detail** | The page summary counts outbound clicks and downloads, but not *which* | Common GA reports |
| **No identity** | "Product mode is reserved and not implemented" | SaaS teams need logged-in user journeys |
| **No consent integration or GPC** | `consent_mode` is a free-text tag; Global Privacy Control is ignored | Needed before any persistent ID |
| **No roles or per-site access** | "Everyone here can see every website and change settings" | Agencies, contractors, mid-size teams |
| **No read API or warehouse export** | Only CLI, CSV export per view, and MCP | Mid-size businesses wire analytics into other tools |
| **No migration path** | No GA4 import | Switching costs history |
| **No search keywords** | No Search Console link | SMBs open GA largely for "what do people google to find me" |
| **Ad platforms are manual** | Spend comes in by CSV; no conversion export | Small paid-ads teams live on this |

## 3. The six excluded features: what each would mean

The "What it won't do" list, reframed as what we'd build and what we would
deliberately still not build.

| Excluded today | Build as | Never build | Needs consent (EU/UK) |
|---|---|---|---|
| Session replay | Masked-by-default replay of sampled sessions | Recording typed values, passwords, card fields | Yes |
| DOM recording | Same feature as replay (it *is* the DOM recording) | Unmasked text by default | Yes |
| Heatmaps | Click, scroll and attention maps per page, aggregated | Raw mouse trails stored per visitor | Yes in Full mode, because it rides on the persistent ID |
| Cookies outside Lite | One first-party visitor ID (cookie or localStorage, 13 months max) | Third-party cookies | Yes |
| Cross-site identity | Cross-*domain* tracking across **your own** sites; `identify()` for logged-in users | Following people across other people's sites | Yes |
| Fingerprinting | **Not built.** See below | Canvas/WebGL/font/audio fingerprinting | Would need consent anyway |

### Why fingerprinting stays out

I recommend not building it, even as an option:

1. **It buys nothing legally.** The EDPB's Guidelines 2/2023 treat reading
   device characteristics as "gaining access" under ePrivacy Art. 5(3). It
   needs the same consent as a cookie. Once you have consent, the consented
   first-party ID does the same job more accurately.
2. **It defeats the visitor's own choice.** Its practical purpose is
   re-identifying people who cleared cookies or opted out. That's the one
   thing a trustworthy tool must not do, and the thing that gets analytics
   vendors fined and blocklisted.
3. **It's getting worse technically.** Safari, Firefox and Brave randomise or
   restrict the signals, so accuracy keeps dropping.

What it would have given you, cross-day returning visitors, comes from the
consented persistent ID instead (section 4).

## 4. Tracking modes and consent (the foundation)

| Mode | Identity | Storage | Consent | Unlocks |
|---|---|---|---|---|
| **Lite** (exists) | Site/day pseudonym, computed on the server | None | Exempt where CNIL-style exemptions apply | Traffic, sources, pages, RUM |
| **Session** (exists) | Random per-tab ID | `sessionStorage` | Usually exempt | Paths, funnels, landing and exit pages |
| **Full** (new default) | Random first-party visitor ID, optional `identify()` | First-party cookie or localStorage, 13 months | **Required** in EU/UK | Returning visitors, retention, replay, heatmaps, cross-domain, user explorer |

How Full stays legal by default:

- **It starts as Lite** on every page load. It upgrades to Full only once
  consent is known to be granted, and downgrades the moment it's withdrawn.
  Before consent nothing is stored, and the page view still counts.
- **Consent can come from three places:**
  - an optional built-in, minimal, accessible banner, off by default;
  - `analytico.consent("granted" | "denied")` for sites that already run a CMP
    (Cookiebot, Usercentrics, Klaro, and so on);
  - reading Google Consent Mode `analytics_storage`, if present. Cheap, and
    it covers sites migrating from GA.
- **Per-site policy** in Settings:
  - "Ask in the EU, UK and Switzerland" (default; the country is decided at
    collection and everyone else gets Full right away)
  - "Ask everyone"
  - "Consent not required" (the operator takes responsibility, for example a
    US-only site)
  - "Never upgrade" (equals Lite)
- **Global Privacy Control** (`Sec-GPC: 1`) and an explicit "denied" keep a
  visitor in Lite always.
- **Deletion:** every persistent visitor or user ID can be erased on request.
  That covers the CLI, the workspace, and the `/i` API for server-driven
  deletion.

Known limit: Safari's ITP caps script-set cookies and localStorage at 7 days.
Getting full 13-month persistence on Safari means serving the tracker from
your own subdomain (for example `stats.example.com`) so the server can set a
first-party cookie. We'd document it as an optional setup step.

## 5. Everything else needed for "80% of GA"

Prioritised by how often a typical SMB opens GA for it. Size: S is days,
M is about a week, L is several weeks.

### P0: table stakes

| Feature | What it entails | Size |
|---|---|---|
| Geography | Bundle DB-IP Lite (CC BY 4.0, monthly updates) for country, region and city at ingest. The IP is used and discarded, never stored. Country, region and city columns, plus a map and table under Audience | M |
| SPA tracking | The tracker hooks `history.pushState`/`replaceState`/`popstate` (opt-out attribute). Each route change sends a page summary for the previous route, then a new page view | S |
| New vs returning, retention | Full mode only. A `visitors` table: first seen, last seen, sessions, first touch. Returning share on Overview; weekly cohort grid | M |
| Ecommerce | Standard event names (`view_item`, `add_to_cart`, `begin_checkout`, `purchase`, `refund`) with an item list in a typed `items` field; server-side `/i` purchases stay authoritative. Reports: revenue, orders, AOV, conversion rate, top products, revenue by source and campaign | L |
| Site search | Configure the query parameter(s) per site; store the search term only (bounded, lowercased); report top terms and zero-result terms | S |
| Outbound links and downloads | Store the target host and file name (not full URLs); a report under Pages | S |
| Consent and modes (section 4) | Full mode, banner, consent API, GPC, deletion | L |
| GA4 import | Import daily aggregates (pages, sources, countries, devices, conversions) through the GA Data API with the operator's OAuth, marked as imported history | M |

### P1: small teams and agencies

| Feature | What it entails | Size |
|---|---|---|
| Roles and per-site access | Owner, admin, editor, viewer; invite someone to chosen sites only. Covers agencies and contractors | M |
| Shared and public dashboards | A read-only link (optional password, expiry) for clients and stakeholders | S |
| Search Console | OAuth link; queries, impressions, clicks and position per page, joined to on-site behaviour | M |
| Ads conversions out, cost in | Send conversions to Google Ads and Meta through their conversion APIs (Full mode with consent and click IDs); import daily cost automatically instead of by CSV | L |
| Read API | Token-scoped REST that mirrors the MCP tools; CSV/JSON | S |
| JS error tracking | Error message and normalised stack frame (no PII); count by release; links to replays | M |
| Audit log | Who changed settings, invited people or exported data | S |

### P2: mid-size and product teams

| Feature | What it entails | Size |
|---|---|---|
| User explorer | Full plus `identify()`: one user's sessions, events, replays and revenue; delete-user action | M |
| Form analytics | Field-level focus, abandon and error counts by field name, never values | M |
| Daily warehouse export | Daily Parquet/CSV files of raw events for BigQuery, Snowflake or S3 | M |
| Experiments | Read variant assignments from the site (`analytico.variant("x","b")`); conversion by variant with significance. No feature-flag service | M |
| SSO domain rule | "Anyone signing in with Google at example.com joins as viewer" | S |
| Load-tested scale | Prove 10M page views/month on one box; add rollups only if measured queries need them (doctrine) | M |

## 6. Session replay and heatmaps in detail

### Session replay

- **Recorder:** vendor rrweb's recorder (MIT), the de facto standard. Keep it
  out of the core tracker: it loads on demand, only for sessions picked by
  sampling. The core tracker stays small.
- **Privacy defaults, stricter than Clarity or Hotjar:**
  - every input value masked, always; password and card fields are never
    captured, even if unmasked by mistake;
  - all text masked by default; operators unmask safe regions with
    `data-analytico-unmask`;
  - images and media blocked by default;
  - no recording before consent.
- **Sampling and triggers:**
  - "record 10% of sessions";
  - "always record sessions with rage clicks, errors or a goal reached";
  - cap at 30 minutes and 5 MB per session.
- **Ingest:** a new `/r` endpoint. Compressed chunks up to roughly 256 KB,
  same origin checks as `/e`, separate rate limits.
- **Storage:** a separate `replays.db` next to the main database. Replays are
  big and short-lived, and keeping them separate keeps backups and analytics
  queries fast. That's a doctrine change ("one database file"), see section 9.
  Retention defaults to 30 days and is set independently.
- **Player:** in the workspace (rrweb player, vendored). Timeline marks for
  page changes, clicks, rage clicks, errors and goals. Jump in from a funnel
  drop-off, a rage-click report, an error, a session in Sessions, or a user
  in the explorer.

### Heatmaps

- **Collection:** clicks aggregated per page as element key + relative
  position bucket + viewport class. Scroll depth moves to 5% steps. Attention
  comes from the section-visibility data the tracker already collects.
- **Element keys:** the existing `data-analytics-*` attributes when present,
  otherwise a short, stable element path.
- **Rendering:** an overlay on the live page. From the workspace, "Open
  heatmap" opens the site with a one-time signed token. The tracker loads an
  overlay module that fetches aggregates for that page (CORS only for that
  site's origin), then shows clicks, scroll and attention. Works without
  replay, and shows the real current page rather than a stale snapshot.
- **No per-visitor mouse trails.** They add storage and privacy cost for
  little insight.

## 7. User journeys this enables

| Who | Journey | Needs |
|---|---|---|
| Blogger, solo creator | "Which countries read my posts, what did they search for on Google, which posts bring newsletter signups?" | Geo, Search Console, goals; still Lite, no banner |
| Small online shop | "Which campaign made money this month, which products convert, where does checkout lose people? Let me watch three sessions that abandoned at shipping." | Ecommerce, ROAS, funnels, replay |
| SaaS startup | "Do trial users come back in week 2? What does a user who churned do differently? Why did this customer report a broken button?" | Full mode, retention, `identify()`, user explorer, errors, replay |
| Marketing team (mid-size) | "Push conversions to Google Ads, compare channels by revenue, schedule a weekly report to the CEO, give the agency viewer access to two sites only." | Ads conversions, roles, schedules, shared dashboards |
| Agency | "One instance, ten clients, each sees only their site and a public dashboard." | Per-site roles, public dashboards |
| Designer / UX | "Where do people click on the new pricing page; do they scroll past the plans?" | Heatmaps, scroll maps, sections |
| Support / engineering | "A customer says checkout froze: find their session, watch it, see the JS error and the release." | `identify()`, replay, errors, release IDs |
| Privacy officer | "Prove we only record with consent; delete this person's data; show what's collected." | Consent policy, GPC, deletion, data map, audit log |
| Someone leaving GA | "Bring two years of history over and keep my UTM habits and dashboards." | GA4 import, Consent Mode compatibility |

## 8. Architecture implications

- **Tracker:**
  - one core script per mode, plus lazy modules: replay, heatmap overlay,
    consent banner;
  - the core gains SPA routing and a consent state machine;
  - Full adds the persistent ID and the cross-domain linker. The linker is a
    short-lived signed parameter on links between the operator's configured
    domains, stripped from the URL on arrival.
- **Protocol v2** (closed and strict, like v1):
  - new fields: `visitor_id` (Full only), `user_id_hash`, `items`,
    `search_term`, `link_target`;
  - new record types: `consent`, `error`;
  - `/r` for replay chunks.
- **Data model:**
  - `visitors`, `visitor_identities` (hashed user IDs, link and conflict
    rules), `orders` and `order_items` (from authoritative `/i` or browser
    events, labelled), `click_cells`, `search_terms`, `errors`;
  - geo columns filled at ingest;
  - `replays` in `replays.db`.
- **Identity conflicts** (the blocker Product mode was deferred for):
  - one `user_id` can have many visitor IDs (devices);
  - a visitor ID belongs to the most recent `identify()` until `reset()`;
  - merges never rewrite history; reports use the link table at query time;
  - deleting a user removes linked visitors' events and replays.
- **Load:** heatmap aggregation happens at ingest (cheap upserts), not at
  read time. Replay writes go to the separate file, so the main write lock
  stays short.

## 9. Doctrine changes this needs (`AGENTS.md`, `PRODUCT.md`)

- **Product boundary:** allow a second SQLite file for replays, and two
  vendored front-end libraries (rrweb recorder and player), loaded lazily
  and never in Lite/Session.
- **Data safety:** "never persist DOM snapshots, mouse movement" becomes
  "only in Full mode, only with consent, masked by default, with separate
  retention and deletion". Keep, and strengthen: never store raw IPs, input
  values, full URLs, query strings, or fingerprints.
- **Product mode:** replaced by Full mode, with the consent, persistence,
  deletion and conflict rules in sections 4 and 8 as the required design.
- **Exclusions list:**
  - removes: session replay, heatmap, DOM recording, cross-site identity
    (rescoped to own domains), ad-platform integration;
  - keeps: fingerprinting, third-party tracking, SQL console, raw-event AI.
- **The marketing page:** "What it won't do" becomes "What it does only with
  consent" plus a shorter "What it never does" (fingerprinting, recording
  what people type, following people across other sites, selling or sharing
  data).

## 10. Phases

Each phase ships behind a working end-to-end test with the real executable
and Chromium, like today.

| Phase | Contents | Exit criterion |
|---|---|---|
| 0. Foundation | Doctrine edits, protocol v2, Full mode, consent state machine and API, GPC, banner, deletion, SPA tracking, geo | A Full-mode site counts returning visitors only after consent, drops to Lite on deny or GPC, deletes on request; an SPA counts route changes; countries show up |
| 1. GA parity | Ecommerce, site search, outbound and download detail, new/returning, retention cohorts, GA4 import | A test shop journey matches expected revenue, AOV and top products; imported history renders alongside live data |
| 2. Teams | Roles and per-site access, shared/public dashboards, read API, audit log, SSO domain rule | A viewer sees only granted sites; a public link works logged out and expires |
| 3. Behaviour | Heatmaps (click, scroll, attention, live overlay), JS errors | The overlay shows clicks on the right elements at all three viewport classes |
| 4. Replay | Recorder, `/r`, `replays.db`, player, sampling and triggers, masking, retention | A recorded checkout plays back with every input masked; nothing is recorded before consent or with GPC |
| 5. Identity | `identify()`/`reset()`, user explorer, cross-domain linking, conflict rules | One user across two devices and two own domains shows as one journey; deletion removes all of it |
| 6. Growth | Search Console, Ads conversions and cost import, form analytics, warehouse export, experiments, load test at 10M page views/month | Each against a sandbox account or recorded fixture |

Phase 0 is the prerequisite for everything with consent. Phases 1 to 3 then
deliver most of the "80% of GA" value; replay (phase 4) is the biggest single
build.

## 11. Decisions

Decided:

1. **Default for new websites (2026-10-06): Full with consent fallback.**
   Every visit starts as Lite and upgrades to Full only once consent is
   known. By default, visitors in the EU, UK and Switzerland are asked;
   operators can switch a site to "ask everyone" or "consent not required".
   Global Privacy Control always keeps a visitor in Lite.
2. **Replay storage (2026-10-06): a separate `replays.db`** next to the
   analytics database. Its retention is set on its own (default 30 days) and
   it is pruned at the file level, so analytics backups and reports stay
   small and fast. Backups cover both files. `AGENTS.md` "one database file"
   becomes "one analytics database plus one replay database".

3. **Heatmap rendering (2026-10-06): live overlay on the operator's site.**
   "Open on site" opens the real page with a one-time signed token. The
   tracker loads an overlay module that fetches per-element aggregates
   (CORS only for that site's origin). Replay is not required, and nothing
   is snapshotted.

4. **Order (2026-10-06): everything in one program**, built in dependency
   order (foundation → GA parity → teams → behaviour → replay → identity →
   integrations), each part shipped behind its end-to-end test.
5. **Fingerprinting (2026-10-06): stays out**, replaced by the consented
   first-party ID. The v3 design has no fingerprinting anywhere.

## Sources

- [EDPB Guidelines 2/2023 on the technical scope of Art. 5(3) ePrivacy, v2.0](https://edpb.europa.eu:443/system/files/2024-10/edpb_guidelines_202302_technical_scope_art_53_eprivacydirective_v2_en_0.pdf)
- [CNIL consent exemption for audience measurement (overview)](https://captaincompliance.com/education/cnil-clarifies-when-analytics-cookies-can-be-used-without-consent/)
- [PostHog: protecting user privacy in session replay](https://posthog.com/pocket-guides/session-replay/protecting-user-privacy)
- [Microsoft Clarity and GDPR (masking defaults)](https://cookie-script.com/guides/microsoft-clarity-session-replay-gdpr/amp)
- [Self-hosted Google Analytics alternatives 2026](https://ossalt.com/guides/self-hosted-google-analytics-alternative-2026)
- [DB-IP Lite databases (CC BY 4.0)](https://db-ip.com/db/lite.php)
