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

predecessor=d58316145ff2e7fecb834bedc2e5ea7034349952
test "$(git -C "$project_root" rev-parse "$predecessor^{commit}")" = "$predecessor"
mkdir -p "$project_root/.zig-cache"
fixture=$(mktemp -d "$project_root/.zig-cache/metadata9-release.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT
source="$fixture/source"
mkdir "$source"
git -C "$project_root" archive "$predecessor" | tar -x -C "$source"
previous="$source/zig-out/bin/analytico"
(
    cd "$source"
    zig build -Doptimize=ReleaseSafe
)
test "$("$previous" version)" = "analytico 0.3.0"
bash "$gate" "$current" "$previous"
