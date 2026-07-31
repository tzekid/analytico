#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <current-binary>" >&2
    exit 2
fi

current=$1
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "$current" in
    /*) ;;
    *) current="$project_root/$current" ;;
esac

mkdir -p "$project_root/.zig-cache"
fixture=$(mktemp -d "$project_root/.zig-cache/previous-release.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT
release=analytico-0.1.0-linux-x86_64
base_url=https://github.com/tzekid/analytico/releases/download/v0.1.0
curl --fail --location --silent --show-error \
    --output "$fixture/$release.tar.gz" "$base_url/$release.tar.gz"
curl --fail --location --silent --show-error \
    --output "$fixture/$release.tar.gz.sha256" "$base_url/$release.tar.gz.sha256"
expected=$(awk 'NR == 1 { print $1 }' "$fixture/$release.tar.gz.sha256")
actual=$(sha256sum "$fixture/$release.tar.gz" | awk '{ print $1 }')
test "$actual" = "$expected"
tar --same-permissions -xzf "$fixture/$release.tar.gz" -C "$fixture"
bash "$project_root/tests/e2e-rollback.sh" \
    "$current" "$fixture/$release/bin/analytico"
