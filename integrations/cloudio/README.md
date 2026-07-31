# Optional Cloudio link candidate

This directory preserves the selected M8 integration as a reviewed, executable
prototype. It is intentionally not applied to the sibling Cloudio worktree.

`REVISION` pins the exact clean Cloudio commit used by the acceptance gate.
`standalone-link.patch` adds:

- an optional `[integrations].analytico_url` setting and
  `CLOUDIO_ANALYTICO_URL` equivalent;
- HTTPS-only external URLs, with plain HTTP accepted only on loopback;
- one context-safely escaped ordinary `Analytics` link in authenticated
  Cloudio navigation; and
- no HTTP client, proxy route, forwarded identity, database access, shared
  state, or JavaScript.

The stored patch uses zero-context hunks so the patch file itself has no
whitespace-only context lines; apply it with `git apply --unidiff-zero`.

The patch is reference integration code, not a promise that it applies to a
future Cloudio revision without review. When the owner wants the link, rebase
the tiny change onto current Cloudio, run its full gates, and repeat the M8
acceptance scenario.

From the Analytico repository, with the sibling Cloudio repository available:

```sh
zig build -Doptimize=ReleaseSafe
tests/e2e-m8-cloudio.sh \
  zig-out/bin/analytico \
  /home/kid/Projects/cloudio
```

The gate exports the pinned Cloudio revision into a disposable directory,
applies and builds the patch there, enrolls a real virtual passkey through
Chromium, exercises the link with JavaScript disabled through Caddy Basic Auth,
stops Analytico to prove Cloudio remains complete, verifies one DuckDB owner,
then removes the link and proves standalone rollback.
