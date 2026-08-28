# Overhaul milestones

## Implemented

- M0: archived legacy code/data and replaced governing scope.
- M1: vendored SQLite build, schema, keys, sites, doctor, integrity,
  backup/restore, prune, vacuum, stats, and one-writer lock.
- M2: immutable tracker assets, strict `/e`, exact origins, normalization,
  daily visitor IDs, page views, events, classification, and durable inserts.
- M3: page summaries, sections, engagement, universal actions, friction
  helpers, optional RUM, and coverage.
- M4: fixed overview/pages/acquisition/campaigns/sections/actions/events/recent/
  performance/coverage/traffic reports with table, JSON, and CSV output.
- M5: Session tracker, timelines, flows, derived abandonment, friction,
  paths, goals, and ordered funnels.
- M6: signed `/i`, authoritative outcomes, spend import/add, and campaign
  economics through attendance and ROAS.

## Deliberately deferred

- M7 Product identity: requires the explicit identity/privacy decision in A04.
- M9 web product: begins only after real use has validated the CLI semantics;
  it reuses these report functions and does not restore the archived dashboard.

## Hardening still expected before a production cutover

M8 covers larger deterministic fixtures, disk-full/corruption exercises,
repeated backup/restore, request-parser fuzzing, packaging, and controlled
replacement of the archived production service. These are qualification work,
not new product architecture.
