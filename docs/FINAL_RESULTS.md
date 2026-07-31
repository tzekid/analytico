# Final 0.1.0 release evidence

Analytico 0.1.0 completes every scheduled milestone from M0 through M8. M9
remains deliberately trigger-based: it has no scheduled implementation and
adds work only after a measured limit or concrete product requirement appears.

## Final gates

The final source passed:

```sh
TMPDIR="$PWD/.zig-cache/task-tmp" \
  zig build test e2e-release-full \
  -Dturso-native-path=.zig-cache/turso-exact-prefix

TMPDIR="$PWD/.zig-cache/task-tmp" \
  zig build test e2e-release-full e2e-rollback e2e-m5 \
  -Doptimize=ReleaseSafe \
  -Dturso-native-path=.zig-cache/turso-exact-prefix
```

Those commands exercised the real executable and real on-disk databases for
fresh setup, migrations, collection, every report family, lifecycle failures,
backup/restore, prior-version rollback, extracted-release linkage, and the
direct-cutover scenario. The browser portions used Chromium, Firefox, and
WebKit for collection, JavaScript-disabled Chromium for the complete dashboard,
and JavaScript-enabled Chromium for HTMX plus blocked/corrupt asset fallback.

M8 separately built the exact isolated Cloudio candidate in ReleaseSafe and
used a real virtual passkey, Caddy Basic Auth, JavaScript-disabled Chromium,
an Analytico outage, one-writer file-descriptor inspection, and standalone
rollback.

## Accepted release shape

- One Zig service process owns one Turso metadata file and one writable DuckDB
  events file.
- Caddy exposes the public tracker/collector boundary and a separate private
  Basic-Auth dashboard boundary.
- The first dashboard response is complete HTML. Native links and forms are
  the product; the exact self-hosted HTMX 4 beta is removable enhancement.
- There is no ClickHouse, PostgreSQL, Redis, container, CDN, Node runtime,
  client state store, startup JSON waterfall, or background aggregation
  service.
- Plausible was inspected read-only and never stopped, restarted, or removed.
  Its shutdown remains the owner's explicit cutover action.

The last ReleaseSafe cutover run accepted three browser events under CSP,
rendered every report family, backed up and restored the real files, measured
61,640 KiB collector RSS, and used 981,728 bytes for its fresh disposable data
directory. These are individual local observations, not percentile claims.

## Artifact

The release command produces:

```text
dist/analytico-0.1.0-linux-x86_64.tar.gz
dist/analytico-0.1.0-linux-x86_64.tar.gz.sha256
```

The extracted-archive gate verifies the outer checksum, every packaged file
checksum, executable mode, private DuckDB linkage, Caddy configurations,
systemd hardening score, fresh database setup, one committed event, and a real
report. The public GitHub release attaches both files.
