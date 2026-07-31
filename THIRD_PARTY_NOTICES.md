# Third-party notices

Analytico ships two non-system runtime dependencies:

- DuckDB 1.4.5 LTS as `lib/libduckdb.so`, under the MIT License in
  `LICENSES/DuckDB.txt`.
- Turso Database `0.8.0-pre.2` SDK Kit, statically linked into the executable,
  through `turso.zig` 0.1.1. Their MIT licenses and exact source notices are in
  `LICENSES/Turso.txt`, `LICENSES/turso.zig.txt`, and
  `LICENSES/Turso-NOTICE.md`.

The tracker is original Analytico code. Zig, glibc, libstdc++, libgcc, and the
Linux dynamic loader are build or platform components and are not bundled in
the release archive. Exact evaluated versions and artifact hashes are recorded
in `versions.json`.
