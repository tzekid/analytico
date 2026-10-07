# Product

Analytico is the analytics tool an individual, a small team or a mid-sized
business can pick instead of Google Analytics: traffic, sources, geography,
conversions, revenue, returning visitors, replays and heatmaps — with privacy
as a mode you choose, not a feature you lose.

For general websites: how many people visited, where they came from and where
they are, what they read, how far they got, what they searched for on Google
and on the site, which links and files they followed, and whether performance
changed by release.

For shops and products: which campaign and creative acquired a visit, what it
earned, where checkout and forms lost people, which errors and rage clicks
caused friction (and what that looked like, in a replay), whether people come
back, and one identified user's journey across devices.

## Tracking modes

**Full** (the default for new websites) starts every visit as Lite and
remembers a visitor only once consent is known: granted by the visitor, or not
required under the site's policy for that visitor. The policy is "ask in the
EU, UK and Switzerland" (default; the country is decided at collection),
"ask everyone", or "consent not required". Consent comes from the built-in
banner, `analytico.consent("granted" | "denied")` from any consent tool, or
Google Consent Mode's `analytics_storage`. Global Privacy Control and Do Not
Track keep a visitor in Lite, and the server enforces it. Remembered visitors
get a first-party ID in `localStorage` (13 months) and 30-minute sessions,
which unlock returning visitors and retention, people, revenue per person,
replays, heatmaps, form analytics and cross-domain visits across the
website's own domains.

**Session** adds one random ID in `sessionStorage`: same-visit paths,
funnels, landing and exit pages, without cross-day identity or consent.

**Lite** uses no browser storage: page views, acquisition, geography, page
summaries, section exposure, actions, errors, optional RUM, and a
server-derived site/day visitor pseudonym.

All modes track single-page-app route changes (opt out with
`data-spa="false"`), site search terms, outbound link hosts and download file
names, and JavaScript errors.

## Identity and deletion

`analytico.identify(userId)` links the current visitor to the operator's own
user ID, stored only as a keyed hash; a visitor belongs to the most recent
identify until `analytico.reset()`. Links are never rewritten, so one person
can span several devices. `analytico.forget()` erases the current visitor;
a `forget` record to `/i` erases a user or visitor from the backend; the
workspace and `analytico forget` do the same, including replays. A person's
data can be exported as JSON from their page.

## Replays and heatmaps

Replays record consented Full-mode sessions on websites that turn recording
on: a sampled share, plus (optionally) every session with a rage click, an
error, a goal or a purchase. Text is masked unless marked
`data-analytico-unmask` (or the site chooses "inputs only"), every input value
always, and images, media, canvases and frames are replaced. Sessions are
capped at 30 minutes and 5 MB, kept in `replays.db` and pruned after 30 days by
default. Heatmaps aggregate clicks per element on a 5% grid, scroll reach and
attention per tenth of the page, per screen class — never a trail per person
— and draw on the real, current page through a short-lived overlay link.

## Workspace

Overview with comparison, annotations and returning visitors; Pages (with
outbound links and downloads), Acquisition, Search (Google queries from
Search Console, and site search), Audience (devices, languages, countries,
regions, cities); Events & goals with experiments; Funnels with form
analytics; Sessions & replays with the player; Heatmaps; Revenue (orders,
products, checkout, revenue by source and ROAS); Retention cohorts; People;
Performance (Core Web Vitals); Errors; Data health; dashboards, alerts,
scheduled emails, segments, ⌘K search. View state lives in the URL, so every
view can be shared, scheduled or alerted on.

Teams have roles (owner, admin, editor, viewer) and may be limited to chosen
websites; a Google Workspace domain can let colleagues join as viewers.
Read-only public links (optional password and expiry, embeddable), a
token-scoped read API, and an audit log cover clients, other tools and
accountability.

Optional AI answers questions, explains chart points and triggered alerts,
and writes summaries for scheduled emails. It uses an operator-supplied key
(Anthropic, OpenAI, or any OpenAI-compatible endpoint) or, through the
read-only MCP connector, the operator's own Claude or ChatGPT plan. Only
aggregates leave the instance.

## Integrations

Search Console (queries per page), a one-time Google Analytics 4 import of
daily history, Google Ads and Meta (daily cost in; purchases from consented
visitors with an ad click ID out — value, currency, time, order ID and click
ID only), Slack and signed webhooks (alerts, goals), and a daily CSV export.
Each lists what leaves the server; nothing is sent until it is connected.

## Signing in

The first account is created from a one-time setup link printed by
`analytico init --origin`. Passkeys (Face ID, Touch ID, Windows Hello, security
keys) are the default; Google and ChatGPT sign-in (OpenID Connect, once a
client is configured) and email + password are the other ways. Everyone
manages their own methods under Settings → Sign-in.

## Never

No fingerprinting, no third-party cookies, no recording of what people type,
no following people across other people's websites, no selling or sharing of
data, no raw IP addresses or full URLs stored, no SQL console, and no AI with
access to raw events.
