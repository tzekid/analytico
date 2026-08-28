# SQLite data model

Schema version 1 is compiled into the executable and created by `init`.

- `sites` and `site_origins` hold closed tracking modes, enabled state, exact
  browser origins, public IDs, and site-specific `/i` secrets.
- `record_receipts` owns `(site,event_id)` idempotency and payload conflicts.
- `page_views` stores normalized acquisition, page, release, coverage, coarse
  client, traffic, and daily visitor evidence.
- `page_summaries` stores one bounded engagement/RUM summary per page.
- `events` stores bounded flat semantic browser events and authoritative server
  outcomes with integer money.
- `goals`, `funnels`, and `funnel_steps` store constrained ordered definitions.
- `campaign_spend` stores integer daily costs by source/campaign/content and
  currency.
- `ingest_counters` stores safe aggregate diagnostics, never rejected payloads.

Sessions are derived from page views and events. Marked sections and event
properties use canonical bounded JSON. There are no rollup or persistent
identity tables in schema 1.

All analytical evidence retains both client occurrence and server receipt
time. Receipt time controls acceptance ranges and report storage windows.
