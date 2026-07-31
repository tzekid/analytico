# Analytico 0.3.0

Analytico 0.3.0 is the dashboard functional-quality release. It deliberately
fixes interaction, state, consistency, and accessibility problems without
choosing the visual direction reserved for the later Figma-led redesign.

## Functional changes

- Site switching is an independent native GET transition and always lands on
  the destination site's overview.
- A 315-byte self-hosted enhancement submits that same form on selection
  changes and uses event delegation so repeated HTMX body swaps cannot break it.
- Date changes preserve the selected site and applicable report while resetting
  pagination.
- Report links, campaign dimensions, and pagination preserve site/range state.
- Goal and funnel validation/mutations preserve site and dates.
- Goal/funnel forms live in a collapsed native disclosure instead of dominating
  every report.
- Empty authentication error containers are hidden until they contain an
  actual error.

## Consistency pass

Login, dashboard, reports, controls, tables, notices, errors, focus states,
management panels, mobile layouts, and dark mode now share one restrained
component vocabulary. The screen remains server rendered, and every primary
control remains usable without JavaScript.

## Acceptance

The U1 browser fixture contains two sites with deliberately different counts.
It switches between both repeatedly with JavaScript enabled and disabled,
switches away from a site-specific goal without leaking its subject, preserves
report/date state, and reruns the complete M6, M7, and passkey journeys through
real Caddy, HTTP, Turso, DuckDB, Chromium, and virtual WebAuthn.
