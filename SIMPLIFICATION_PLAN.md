# Analytico simplification plan

Planning snapshot: 2026-09-04. Implemented and locally verified on 2026-09-04. Changes are limited to test tooling, packaging, and documentation; runtime and tracker asset bytes are unchanged, so deployment is not required.

## Current state and evidence

- The retained repository is `analytico-cutover`, on `master` at `f8f2252`; the old checkout was removed after preserving its history and local work. Do not recreate or revive that implementation.
- One Zig executable, vendored SQLite, a CLI, and four generated tracker variants. `AGENTS.md` and `PRODUCT.md` explicitly exclude the old dashboard, Turso, DuckDB, and persistent Product identity.
- `tests/e2e.sh` already exercises ingestion, origin rejection, duplicate/conflicting events, signed internal outcomes, reports, shutdown, and backup/restore. Its tracker check only requires more than 10,000 bytes; its final report loop discards output.
- `tools/build-trackers.sh` generates the four assets from one source. Generated variants are intentional build outputs, not four independent implementations to consolidate.

## Intended result

Keep the existing product and storage model. Replace weak assertions with a small amount of real outcome coverage. No rewrite, dashboard, new analytics protocol, shared framework, or arbitrary reduction target.

## Implementation sequence

1. Refresh GitHub `master`, compare with the running release, and record the existing working-tree changes. Keep this plan and unrelated work. Use the pinned compiler. Establish the existing focused test and real-process journey baseline on disposable data.
2. Replace the tracker byte-count threshold with useful verification: the snippet resolves to its selected asset, the asset is valid JavaScript, and an actual page using the tracker produces a persisted page view. Serve that page from a disposable allowed origin and use a local proxy that supplies the authoritative client-address header, matching Caddy; do not weaken the collector to accommodate the test. Exercise Lite without browser storage and Session with its session ID; keep RUM generation/syntax checks without multiplying identical browser runs. Reuse an available browser driver or pin one small test-only driver if none is suitable.
3. Extend the existing report fixture with explicit expected values for the reports currently checked only for successful exit. Assert stable values/fields and empty-result behavior, not incidental whitespace or whole-output snapshots.
4. Review shell error handling so a failed generator or command on the left side of a pipeline cannot silently pass. Prefer small direct assertions; do not introduce a shell testing framework.
5. Keep changes limited to tests, their minimal fixture setup, and necessary documentation unless this work demonstrates a product defect. Fix any demonstrated defect narrowly and re-run the affected journey.

## Verification and delivery

- Run `zig build test -Doptimize=ReleaseSafe`, `zig build e2e -Doptimize=ReleaseSafe`, and the production build with the exact pin. A browser case must use the built binary, a disposable site/database, and local HTTP; never submit synthetic data to production.
- Check deterministic regeneration of all four trackers and JavaScript syntax. Preserve privacy fields, client-address rejection, signatures, idempotency, report semantics, and database-plus-key restore.
- Finish with the implementation review loop: inspect the actual diff for lost assertions/features, attempt relevant counterexamples, fix findings, and repeat until a complete pass has no unresolved or new blockers. Do not erase failures by weakening expectations.
- Commit only this task's changes and push the existing default branch without force-pushing. Verify the remote commit. Test/documentation-only changes need no deployment. If runtime or generated assets change, use the existing release layout and `docs/OPERATIONS.md`, retain rollback, verify the running executable and local health/readiness, and check the intended public routing boundary.
- Tracker paths contain content hashes and the server serves only the current variants. Default to leaving tracker bytes unchanged. If a proven defect requires different bytes, inventory consumer snippets (including plosca.ru and Sparkdate), prepare their exact replacement hashes, and coordinate engine/consumer publication and rollback before releasing. An engine-only release that breaks existing snippets is unacceptable.

## Planning review

- Pass 1 found two blockers: a browser calling the collector directly would fail its required client-address boundary; a changed tracker could invalidate deployed consumer URLs. The plan now specifies the local proxy and coordinated hash/rollback handling.
- Pass 2 rechecked the generator, hashed route selection, operations instructions, retained assertions, and scope. No unresolved or new planning blockers were found. Runtime/build acceptance remains work for implementation; no tests or deployment are claimed complete here.

## Implementation and review results

- Replaced the minimum tracker byte count with served-asset syntax validation and a real Chromium journey using the actual executable, isolated SQLite data, and a loopback proxy. Lite makes no storage/cookie accesses; Session retains its stored identity across navigation; a real click appears in the actions report.
- Replaced the eight discarded report outputs with explicit JSON values and empty filtered-result checks. Existing ingestion rejection, signatures, duplicate/conflict, funnel/economics, graceful shutdown, and database-plus-key restore checks remain.
- Enabled pipeline failure propagation in the E2E script and tracker generator. Pinned the browser driver as a test-only dependency and included its manifests in the source package; documented installation and Chromium selection.
- Review pass 1 corrected writer-lock sequencing and the test's assumption that actions flush immediately. Browser setup now precedes the test server, and action acceptance waits for durable output after actual navigation. Cleanup also stops the backend if browser shutdown fails.
- Review pass 2 verified the full ReleaseSafe test/E2E/build sequence, report values, browser outcomes, shell/JavaScript syntax, and byte-identical regeneration of all four assets. Injecting an `awk` failure returns its failing status and preserves the prior generated asset. No unresolved implementation blockers remained in this scope.
- Delivery requires only committing/pushing these changes. No production restart or tracker-consumer update is needed because executable sources and generated trackers are unchanged.
- Final adversarial check removed the tracker from fixture snippets: browser acceptance failed as expected and cleaned up its isolated files. The final packaging review also retained the documented `.zigversion` file in exported source packages. No new blockers were found.
