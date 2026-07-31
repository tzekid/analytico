# Third-party notices

Analytico ships five non-system third-party components:

- DuckDB 1.4.5 LTS as `lib/libduckdb.so`, under the MIT License in
  `LICENSES/DuckDB.txt`.
- Turso Database `0.8.0-pre.2` SDK Kit, statically linked into the executable,
  through `turso.zig` 0.1.1. Their MIT licenses and exact source notices are in
  `LICENSES/Turso.txt`, `LICENSES/turso.zig.txt`, and
  `LICENSES/Turso-NOTICE.md`.
- HTMX `4.0.0-beta6` core, embedded and self-hosted as the optional dashboard
  enhancement, under the Zero-Clause BSD license in `LICENSES/HTMX.txt`.
- Passcay `3.1.0`, statically linked for WebAuthn registration and
  authentication verification, under the MIT License in
  `LICENSES/Passcay.txt`.
- zbor `0.21.2`, statically linked to enforce the accepted COSE public-key
  algorithms, under the MIT License in `LICENSES/zbor.txt`.

The tracker and dashboard CSS are original Analytico code. Zig, glibc,
libstdc++, libgcc, and the Linux dynamic loader are build or platform
components and are not bundled in the release archive. Exact evaluated
versions and artifact hashes are recorded in `versions.json`.
