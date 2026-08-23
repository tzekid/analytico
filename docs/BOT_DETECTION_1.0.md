# Bot detection and traffic-quality plan (1.0)

This plan corrects inflated visitor counts and establishes layered bot
detection. It is sequenced so each phase delivers value alone and every
detection change is measurable before it affects product metrics. Tracked in
GitHub issues #66–#70; execute in that order. Phases 0–2 describe the shipped
#68 candidate, while phases 3–4 remain planned work.

## Motivation

- The Overview "Daily visitors" headline is a visitor-day total, not a person
  count, and is not comparable to GA-style monthly users.
- Before phase 1, the tracker fired during Chrome prerendering;
  ephemeral-storage visitors minted a fresh visitor-day per page load; owner
  self-visits counted.
- Before phase 2, the UA classifier was six case-sensitive substrings: it
  missed HTTP libraries, HeadlessChrome, and tokenless named bots, and could
  false-positive on real devices ("Cubot" phones). Raw UAs are discarded at
  ingest, so misclassified history is unrecoverable and cannot be replayed
  through the corrected versioned classifier.

## Doctrine

- Measure first, classify second, heuristics last.
- Store and classify; never silently drop. Exclusion from product metrics is
  visible in diagnostics.
- Hard signals (declared-bot UA, `navigator.webdriver`, client-hint mismatch)
  classify alone. Soft signals (viewport, timing, missing language) never
  classify alone.
- Positive human evidence (trusted interaction, engagement, scroll) vetoes any
  soft-signal classification. This is the false-positive guarantee.
- Soft classification is computed at query time in versioned SQL: retroactive
  and reversible.
- No fingerprinting: no canvas/WebGL/audio probing, raw screen size, battery,
  or precise timezone-vs-geo cross-checks. No runtime network calls or data
  files on the collection path. Datacenter CIDR lists are deferred pending
  diagnostic evidence (iCloud Private Relay false-positive risk).

## Phases

### Phase 0 — Truth and diagnostics (#66, P0)

Distinct-persons-in-range metric from canonical person keys next to the
honestly labeled visitor-day headline. Traffic-quality diagnostics report:
identity-quality split, zero-engagement single-event sessions, identity mint
rate per day, bot events per day.

### Phase 1 — Close non-bot inflation leaks (#67, P0)

Prerender guard and localhost guard in the tracker. Ephemeral
(`identity_quality = ephemeral`) events derive their visitor-day from the
network prefix + coarse client key instead of the per-load anonymous id.
Self-visit exclusion: dashboard-set localStorage flag plus internal
network-prefix classification at collection. Every self-excluded event remains
stored under the bounded temporary `exclusion_source` classification and is
reported in diagnostics while product metrics omit it. #68 migrates that
temporary representation to `traffic_class=excluded`; no observed event is
dropped between phases.

### Phase 2 — Traffic class and versioned classifier (#68, P0)

Schema 5 adds `traffic_class`
(`human-presumed | declared-bot | automation | excluded | suspected`),
`classifier_version`, and matched `bot_rule` per event; `device_category`
returns to a pure device dimension. Vendored, versioned, compile-time UA rule
list with case-insensitive word-boundary matching and false-positive traps in
fixtures. Empty UA classifies as declared-bot. Every otherwise accepted event
is stored; there is no self-opt-out or bot drop-at-ingest policy. One release
stores the exact old verdict beside the permanent class and exposes bounded
old/new disagreement diagnostics plus fixed restart-scoped serve counters
before #69 may promote the product predicate.
The accepted mechanism and pinned rule provenance are D32 and
`UA_CLASSIFIER_V1.md`.

### Phase 3 — Bounded signals (#69, P1)

Protocol v2: `navigator.webdriver`, trusted-interaction bitmask,
`was_visible`/`was_prerendered`, coarse viewport bucket, time-to-beacon
bucket. Server-side: `Sec-CH-UA` consistency enum, `Accept-Language`
presence boolean.

### Phase 4 — Query-time heuristics and verification (#70, P1)

Suspected classification (zero-engagement single-event sessions with agreeing
soft signals and no human evidence), strict-mode toggle default off,
identity-mint anomaly flag, per-site daily accepted-event ceiling with a
data-health warning, and the classifier-health contradiction-rate metric as
the standing precision check. Explicitly out: ML scoring, IP-reputation
feeds, JS challenges.

## Sequencing against the milestone

Phases 0–1 land before the sessions/live UI (#41–#43). Phase 2 lands before
the exact-baseline upgrade fixtures (#47) and the 1.0 cut (#50) so baselines
freeze on the corrected, versioned classifier. Phase 4 may trail 1.0 if the
Phase 0 diagnostics show it is not needed.
