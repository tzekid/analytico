#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <current-binary> <turso-native-prefix|source>" >&2
    exit 2
fi

current=$1
turso_native=$2
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "$current" in
    /*) ;;
    *) current="$project_root/$current" ;;
esac

mkdir -p "$project_root/.zig-cache"
fixture=$(mktemp -d "$project_root/.zig-cache/previous-source.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT
git -C "$project_root" archive e56c0a4 | tar -x -C "$fixture"

build_args=(zig build -Doptimize=ReleaseSafe)
if [[ "$turso_native" != source ]]; then
    case "$turso_native" in
        /*) ;;
        *) turso_native="$project_root/$turso_native" ;;
    esac
    build_args+=("-Dturso-native-path=$turso_native")
fi
(
    cd "$fixture"
    "${build_args[@]}"
)
bash "$project_root/tests/e2e-rollback.sh" \
    "$current" "$fixture/zig-out/bin/analytico"
