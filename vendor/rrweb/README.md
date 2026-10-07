# rrweb 2.1.7 (vendored)

Session replay recorder and player, MIT License (see LICENSE).

- `record.min.js`: `@rrweb/record` 2.1.7, `dist/record.umd.min.cjs`
- `replay.min.js`: `@rrweb/replay` 2.1.7, `dist/replay.umd.min.cjs`
- `replay.min.css`: `@rrweb/replay` 2.1.7, `dist/style.min.css`

Taken unchanged from the npm registry tarballs, except that the trailing
source map comments are removed. The recorder is wrapped into the
collector's replay script by `tools/gen_trackers.zig` at build time; the player and its
stylesheet are embedded in the workspace.
