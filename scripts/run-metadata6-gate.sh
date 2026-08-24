#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <current-binary> <gate-script>" >&2
    exit 2
fi

project_root=$(cd "$(dirname "$0")/.." && pwd)
current=$1
gate=$2
case "$current" in /*) ;; *) current="$project_root/$current" ;; esac
case "$gate" in /*) ;; *) gate="$project_root/$gate" ;; esac

predecessor=a2d71c046a8b8b632429336f58ff0d1eebfea7b3
test "$(git -C "$project_root" rev-parse "$predecessor^{commit}")" = "$predecessor"
mkdir -p "$project_root/.zig-cache"
fixture=$(mktemp -d "$project_root/.zig-cache/metadata6-release.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT
mkdir "$fixture/source"
git -C "$project_root" archive "$predecessor" | tar -x -C "$fixture/source"
previous="$fixture/source/zig-out/bin/analytico"
(
    cd "$fixture/source"
    zig build -Doptimize=ReleaseSafe
)
test "$("$previous" version)" = "analytico 0.3.0"
bash "$gate" "$current" "$previous"
