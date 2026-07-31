# U1 dashboard functional-quality evidence

U1 was accepted on 2026-07-31 against the exact 0.3.0 ReleaseSafe candidate
and the unified production deployment.

## Failures reproduced and fixed

- The former combined filter form coupled site, date, report subject, and page
  state behind one ambiguous `Apply` action.
- A site change could retain a goal/funnel subject belonging only to the prior
  site.
- The first enhanced site change replaced the body and discarded a listener
  attached directly to the old select, so a later change could do nothing.
- Goal/funnel mutations returned to the default date range.
- Empty authentication error containers rendered visible error chrome.
- Definition forms visually dominated every report.

The accepted flow uses separate native site and date forms. Site selection
always resolves to that site's overview; date changes preserve applicable
report state and reset the page; mutations preserve site and dates. The
315-byte enhancement delegates the selection listener from `document`, so it
survives every HTMX body replacement. Goal/funnel administration is a native
collapsed disclosure.

## Executed acceptance

- Debug build and tests passed.
- ReleaseSafe build and tests passed.
- The full extracted-release gate passed M0–M7 plus passkey P1–P3 against real
  processes and on-disk stores.
- A separate M8 run rebuilt the pinned Cloudio candidate and passed ordinary
  no-JavaScript navigation, Analytico outage isolation, one-writer inspection,
  and rollback.
- JavaScript-disabled Chromium switched both ways between two sites with
  deliberately different metrics, preserved the site across reports, changed
  dates, and safely switched away from a site-specific goal.
- JavaScript-enabled Chromium switched both ways repeatedly through HTMX,
  proving the delegated enhancement survives body swaps.
- The passkey suite proved setup, both credential logins, rename/revoke,
  last-passkey protection, session revocation, logout, no-JavaScript dashboard
  use, CSRF/origin enforcement, and bounded return paths.

## Measured release view

- Complete overview HTML: 1,784 gzip bytes in the accepted full-release run.
- Complete CSS: 2,305 gzip bytes.
- Site enhancement: 315 raw bytes, zero dependencies.
- Enhanced first view: four requests (HTML, CSS, HTMX, site enhancement), zero
  startup API requests.
- JavaScript-disabled first view: HTML and CSS only, zero startup API requests.

## Production

- Canonical origin: `https://analytico.plosca.ru`
- Release: 0.3.0 from `master`
- Stores: metadata v2, events v2, two sites, 17 stored events at deployment
- Auth: one unified-origin passkey and its active session preserved
- Service: one loopback Zig process, healthy at roughly 14 MiB RSS immediately
  after restart
- Verified pre-deployment backup:
  `/home/kid/.local/share/analytico-backups/pre-u1-dashboard-20260731-152923`

The future U2 redesign remains intentionally separate: define user journeys
and information architecture, iterate in Figma, then implement an accepted
direction. U1 supplies a functional baseline rather than pre-empting that work.
