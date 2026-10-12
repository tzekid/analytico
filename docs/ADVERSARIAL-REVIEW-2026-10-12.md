# Adversarial review — 12 October 2026

Review target: the complete working tree at `2c7d1ba`, including the existing edits in `tests/tour-seed.mjs` and `tests/workspace.mjs`.

Review method: each pass searches for concrete failures; every candidate is checked against the implementation and, where feasible, reproduced through the real executable or client. Only confirmed, distinct findings enter the list. Duplicates and rejected candidates do not count as new findings. The loop stops after two consecutive completed passes add no new confirmed findings.

The review records issues and does not fix them. A pass without new findings does not mean the outstanding issues are resolved.

Validation uses synthetic data and disposable services. No production databases, settings, or deployments are changed. Reproduction scripts and logs live in `/Users/tzekid/Projects/analytico-review-2026-10-12/`.

## Confirmed findings

1. **Viewer could change instance-wide sign-in policy and provider credentials.** Reproduced through the real HTTP server. Fixed by requiring Admin for provider, enable/disable and preferred-method actions.
2. **A password change left native-app and MCP grants active.** Reproduced: the old web session stopped while both access and refresh tokens remained usable. Fixed by revoking every web session, OAuth grant and registered push device for the account before issuing its replacement browser session.
3. **AI source-sharing controls leaked referrers through `recent`.** Reproduced with a distinctive referrer through MCP. Fixed by replacing catalog-wide AI exposure with an explicit aggregate-report allowlist.
4. **AI and MCP exposed stable session IDs and row-level timelines.** Reproduced with `sessions` and `session`. Fixed by removing those tools, `recent`, site-search terms and the individual-session AI summarizer from every model-facing surface.
5. **Replay snapshots could contain URL credentials, hidden input values and arbitrary attributes.** Reproduced in a real browser with the vendored recorder. Fixed by stripping values and arbitrary attributes and removing queries/fragments from every URL at the final serialization boundary.
6. **Cross-domain URL claims persisted identity and manufactured `granted` consent before server validation.** Reproduced in a real browser. Fixed by keeping the claim in memory, authenticating it on the server before browser persistence, and preserving `granted` versus `not_required` in the signed claim.
7. **Replay uploads were not bound to the supplied page or server-side exclusion rules.** Fixed by requiring the exact consented page, visitor and session tuple and applying the website's exclusion patterns before accepting a chunk. The client also rechecks the current SPA path after its recorder finishes loading.
8. **The public APNs relay accepted unauthenticated requests.** Fixed by making the relay loopback-only and removing the documented public proxy. The instance now uses the local relay by default.
9. **Automatic observation was broader than needed.** Fixed by making Lite the default for new websites, making form analytics opt-in per marked form, excluding password/payment/token-like fields, and reducing captured errors to exception classes rather than arbitrary application messages.
10. **ChatGPT plan sign-in copied callback credentials through the workspace and fabricated a client version.** Fixed by removing clipboard/manual callback submission and the synthetic version. Completion now occurs only through the loopback listener, locally or over an operator-created SSH tunnel.
11. **The production CLI minted browser sessions without an authentication ceremony.** It existed for tests and scripts. Removed outright, together with workspace-session load checks that depended on it.
12. **Unbounded share expiry and replay timestamps could overflow.** Fixed with a one-year share limit and bounded replay timestamps before arithmetic or storage.
13. **A pending cross-domain claim still touched active state and could race a later consent denial.** Fixed by keeping the claim in a separate object carried only by its bootstrap page view, binding adoption to that request's callback, requiring current consent to remain eligible and clearing it on denial, GPC or forgetting.
14. **Replay still exposed CSS and DOM identifiers through secondary rrweb structures.** Fixed by removing identifier/style attributes, stylesheet text and every rule, declaration and replacement payload at serialization. Browser fixtures cover static CSS, inline CSS and both stylesheet replacement APIs.
15. **Ask leaked detail-route identifiers in its screen label.** Fixed by mapping only the first route component through a fixed screen-name allowlist.
16. **Historical arbitrary error messages remained model-readable.** Fixed by removing the errors report from the AI/MCP allowlist; browser ingestion also stores only exception classes going forward.
17. **Automatic heatmap selectors copied DOM IDs into durable aggregates.** Fixed by using only structural selectors; operator-controlled `data-analytics-action` remains the explicit naming mechanism.
18. **The local-compatible AI endpoint check accepted a remote authority through URL userinfo.** Fixed by parsing and validating the complete authority, rejecting userinfo, validating the port and matching only `localhost` or `127.0.0.1`.
19. **The replay loader could remain stuck after an excluded SPA route.** Fixed by treating its flag as pending-load state, clearing it on load/error and allowing an already-loaded recorder to start again on an eligible page.
20. **Stale decision responses could override a newer denial, forget or reset.** Fixed with an identity/consent generation captured by every decision-bearing request; responses from older generations are discarded in full.
21. **Reset and denial left usable continuation tokens in memory or decorated links.** Fixed by clearing tokens and actively removing tracker-added `_an` parameters whenever identity changes.
22. **Replay retained checkbox/radio state and stylesheet declaration names.** Fixed by removing checked/selected state and dropping the entire stylesheet-declaration event class before buffering.
23. **Form analytics copied field DOM names and IDs into durable aggregates.** Fixed by using only explicit `data-analytics-field` labels or structural ordinals.

The obsolete milestone documents were also removed. One contained extensive discussion of shell-capable coding agents and experimental access paths that no longer described the product and was a strong false-positive source.

## Pass log

- Pass 1 — identity, sign-in methods, roles, site scope, OAuth, API and AI access: 4 findings added and reproduced.
- GPT-6.1 Sol baseline pass — replay privacy, cross-domain identity, model boundaries, push relay and optional capture: 8 additional actionable findings added; no evidence of deliberate credential theft, cookie theft, arbitrary file extraction or model-controlled shell execution.
- Pass 2 — 5 incomplete or additional findings added and fixed.
- Pass 3 — 4 incomplete or additional findings added and fixed.
- Pass 4 — 4 additional browser-state findings added and fixed.
- Pass 5 — 3 additional stale-response/token/CSS findings added and fixed.
- Pass 6 — cancelled at the user's request to stop the review loop and hand the repository to a fresh GPT-6.1 Sol chat. The original two-clean-pass stop condition was therefore not reached; all findings actually returned by passes 1–5 were fixed.

## Validation and limits

- The server is documented as Linux-only. A native macOS build fails in Linux clock code; this is an environment mismatch, not a finding.
- The native client package's existing 16 tests pass on this Mac.
- Linux `ReleaseSafe`, focused Zig tests, the complete end-to-end journeys and all 16 Swift package tests passed after remediation through pass 4. A final targeted privacy journey is recorded separately after pass 5.

