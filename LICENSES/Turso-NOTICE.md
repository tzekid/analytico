# Turso

Upstream: <https://github.com/tursodatabase/turso>

Analytico's pinned `turso.zig` dependency builds the Turso SDK Kit from Turso
commit `6e527a75595576790566f3d36560fbe95c5d87a2`, declared version
`0.8.0-pre.2`. The SDK Kit and its Rust dependencies are linked into the
Analytico executable. The upstream project is MIT licensed; its source tree
and dependency notices are available at that exact commit.

The binding source is `https://github.com/tzekid/turso.zig` commit
`f1b82da9f9207bee085808ad6a8686a9780ed76d`. Its vendored SDK headers were
copied from the Turso commit above:

- `sdk-kit/turso.h`, SHA-256
  `14ee49b4f6c00e3f8c3c710b4df1c316ecc0802e1d8b19815d8caab09f2b70cb`
- `sync/sdk-kit/turso_sync.h`, SHA-256
  `f9de9cb7ab356e59fd7efdbc02c6a35598588202297535436ecfeaa8ad7bda1`

`versions.json` is the authoritative release provenance record. Full
corresponding source can be obtained from the repositories and immutable
commits above.
