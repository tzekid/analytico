# Product

Analytico answers two sets of questions.

For general websites: how many people visited, where they came from, what they
read, how far they got, which marked sections and links interested them, and
whether performance changed by release.

For product sites: which campaign and creative acquired a session, where a
registration flow lost people, which controls caused friction, and which
authoritative registrations, payments, refunds, attendance, or revenue came
from the campaign.

## Current modes

Lite uses no browser storage. It records page views, acquisition, final page
summaries, marked-section exposure, universal actions, optional RUM, and a
server-derived site/day visitor pseudonym.

Session adds one random ID in `sessionStorage`. It enables same-session page
sequences, flows, landing/exit pages, duration, and abandonment analysis. It
does not create cross-day identity.

Product mode is reserved and not implemented. It requires a separate decision
covering consent, persistent anonymous identity, identify/reset, deletion, and
link conflicts.

## Current exclusions

No web dashboard, passkeys, HTMX, frontend framework, session replay, heatmap,
raw click or scroll stream, DOM recording, arbitrary query language, SQL
console, custom formula, team/role system, billing, distributed ingestion,
Turso, DuckDB, cross-site identity, fingerprinting, AI insight, or ad-platform
integration is part of this product.
