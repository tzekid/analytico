#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <analytico-binary> <libduckdb.so> <dist-directory>" >&2
    exit 2
fi

binary=$1
duckdb=$2
dist=$3
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
version=$("$binary" version)
version=${version#analytico }
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
    echo "refusing unsafe release version: $version" >&2
    exit 1
fi
name="analytico-$version-linux-x86_64"

mkdir -p "$dist"
dist=$(cd "$dist" && pwd)
temporary=$(mktemp -d "$dist/.package-$name.XXXXXX")
cleanup() {
    rm -rf -- "$temporary"
}
trap cleanup EXIT
stage="$temporary/$name"
mkdir -p "$stage/bin" "$stage/lib" "$stage/deploy" "$stage/docs" \
    "$stage/public" "$stage/LICENSES"

install -m 0755 "$binary" "$stage/bin/analytico"
install -m 0644 "$duckdb" "$stage/lib/libduckdb.so"
install -m 0644 "$project_root/deploy/analytico.service" "$stage/deploy/"
install -m 0644 "$project_root/deploy/Caddyfile" "$stage/deploy/"
install -m 0644 "$project_root/public/tracker.js" "$stage/public/"
install -m 0644 "$project_root/public/tracker.js.br" "$stage/public/"
install -m 0644 "$project_root/public/tracker.js.gz" "$stage/public/"
install -m 0644 "$project_root/README.md" "$stage/"
install -m 0644 "$project_root/LICENSE" "$stage/"
install -m 0644 "$project_root/THIRD_PARTY_NOTICES.md" "$stage/"
install -m 0644 "$project_root/versions.json" "$stage/"
install -m 0644 "$project_root/LICENSES/"* "$stage/LICENSES/"
install -m 0644 "$project_root/docs/"*.md "$stage/docs/"

checksums="$temporary/SHA256SUMS"
(
    cd "$stage"
    find . -type f ! -name SHA256SUMS -print0 |
        sort -z |
        xargs -0 sha256sum >"$checksums"
)
mv "$checksums" "$stage/SHA256SUMS"

archive="$dist/$name.tar.gz"
temporary_archive="$temporary/$name.tar.gz"
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
    -C "$temporary" -czf "$temporary_archive" "$name"
mv -f -- "$temporary_archive" "$archive"
sha256sum "$archive" >"$dist/$name.tar.gz.sha256"
printf '%s\n' "$archive"
