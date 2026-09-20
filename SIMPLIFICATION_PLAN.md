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


## Follow-up: 2026-09-20

### Current facts and scope

- Clean `master` and refreshed `origin/master` both start at `ad10716`;
  GitHub's default is `master`, with no configured Actions workflows. The only
  worktree is this retained repository. No obsolete checkout is recreated.
- Pin: Zig `0.17.0-dev.2085+5e36170b5`; vendored SQLite, no package dependencies,
  test-only Playwright `1.58.2`. Use the installed pinned compiler, not PATH Zig.
- Production `current/REVISION` is `ad10716`; PID 3340661 matches the installed
  executable SHA-256 `781ff4343e3d4c6e5168fbffbf44b5e914f62e1cba095f7f01797c7d40955cbb`.
  Local health/readiness and read-only doctor pass, with zero service restarts.
  The existing previous release is `1.0.0-f8f2252`.
- Reproduced on an isolated database with the deployed binary: a partial POST
  body blocks readiness beyond four seconds and TERM beyond two seconds. The
  one-connection collector has no network deadline. Caddy's response-header
  timeout does not establish a collector-side read deadline.
- Fix this demonstrated availability/shutdown defect and its acceptance gap.
  Preserve single-writer transactions, tracker bytes/hashes, privacy, CLI,
  schema, and consumer pins. No concurrency framework or new configuration.

### Acceptance and implementation

1. Give each accepted connection a fixed two-second monotonic network deadline,
   shared by request head, body, and response writes. Progress must not reset
   the deadline. Keep transactions synchronous and finish/checkpoint them
   normally; bound network waiting rather than canceling database operations.
2. Extend real-process acceptance using disposable data: incomplete headers,
   incomplete bodies, trickled input, subsequent readiness, and TERM during
   a stalled request. Require clean exit/checkpoint within the service's
   three-second shutdown window; cleanup must kill/reap only owned processes.
   Keep existing browser, reports, authentication/origin, duplicate/conflict,
   backup/restore, and generator-failure coverage.
3. Verify pinned ReleaseSafe tests/E2E/build and exported source completeness;
   inspect failure diagnostics for payload disclosure and ownership/lifetime.
   Verify deterministic unchanged trackers and current consumer asset routes.
4. Complete two consecutive clean implementation reviews from functional and
   operational/failure perspectives. Commit only scoped changes, push master,
   verify exact remote commit and any configured hosted checks.
5. Use the established immutable release layout. Stop for verified database
   plus key backup/restore qualification; retain data identity. Build the
   committed source, record REVISION and executable digest, atomically promote,
   start, compare running hash, local health/readiness, public route boundary,
   served tracker bytes, database integrity and fresh logs. Retain the previous
   current release as rollback; restore it if promotion fails. Synthetic requests
   go only to disposable instances, never production.

### Plan reviews

- Pass 1, availability and failure semantics: an idle timeout would be extended
  by trickled bytes, and canceling the whole request could interrupt a database
  transaction. Resolved with one monotonic deadline on network I/O only. A
  runtime change requires real deployment, replacing the historical test-only
  delivery assumption. Clean-pass count reset to zero.
- Pass 2, complete contract review: traced HTTP parsing, transactional ingestion,
  immutable assets, reports and E2E against the plan. Fixed deadlines cover
  incomplete heads/bodies and writes without changing schema or tracker assets;
  existing product acceptance remains required. Zero findings; clean pass 1.
- Pass 3, complete operational/adversarial review: checked pinned I/O APIs,
  process cleanup, package paths, Caddy timeouts, systemd stop window, backup/key
  restore, revision/hash promotion and rollback. Network-only cancellation
  preserves synchronous SQLite ownership; tests and production are separated.
  Zero findings; clean pass 2. Implementation may proceed.


### Implementation reviews

- Pass 1, full contract and failure review: the initial pinned-library timeout
  waits for socket readiness but then performs a blocking send. That does not
  fully bound response writes to a slow reader. Replaced network operations
  with deadline-aware poll and nonblocking recv/send, retaining the existing
  HTTP parser and synchronous database path. Clean-pass count reset to zero.
  Initial ReleaseSafe product/browser journey and stalled-input acceptance
  passed; the new acceptance fails against the original executable as expected.
- Pass 2, complete functional/package review: pinned ReleaseSafe test/E2E and
  the exported source package passed all 9 build steps and 3 focused tests,
  including the real browser, reports, backup/restore and new socket journeys.
  Fragmented valid requests succeed; incomplete heads/bodies and trickled input
  expire; readiness recovers; TERM exits cleanly and doctor verifies the database.
  A disposable 8 MiB tracker response with a non-reading peer forces send-buffer
  backpressure: the deadline releases the collector and readiness/TERM pass.
  No production asset was enlarged. Zero findings; clean pass 1.
- Pass 3, complete ownership/security/operations review: checked the final diff
  against the full acceptance plan, buffered partial-write accounting, absolute
  deadline retries and EINTR handling, socket/arena cleanup, synchronous
  commit/rollback/checkpoint, safe diagnostics and owned test-process cleanup.
  Exported runtime/tests/pins match the working tree. All four regenerated
  trackers match baseline bytes; injected awk failure returns 73 without
  changing outputs. Public assets match those bytes and private routes remain
  404. No new dependencies or configuration surface. Zero findings; clean pass 2.

### Delivery

The runtime fix requires a release. Deliver the reviewed commit through the
existing immutable `~/.local/opt/analytico/releases` layout, retaining `ad10716`
as rollback. Exact revision, backup/restore and live verification results are
recorded in the task checkpoint and delivery evidence outside the source tree.
