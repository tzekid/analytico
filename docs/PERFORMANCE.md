# Performance model

The browser tracker becomes idle when the visitor is idle. It may use one
delegated click listener, one delegated submit listener, one passive
animation-frame-coalesced scroll listener, `visibilitychange`, one
`IntersectionObserver` for marked sections, and optional
`PerformanceObserver`. It must not poll, heartbeat, watch mouse movement, scan
the DOM broadly, attach per-element listeners, or retain unbounded data.

A normal page sends one page view, one final summary, and at most one bounded
semantic-event batch. Each batch has at most 16 records and an 8 KiB body.
Final sends use `sendBeacon`, falling back to keepalive `fetch`.

The database begins with raw tables and useful indexes. Before adding rollups
or another engine, inspect query shape, indexes, stored fields, transaction
boundaries, and result bounds with deterministic fixtures. Budgets are
evidence and tuning guides, not an excuse to delay a working vertical slice.
