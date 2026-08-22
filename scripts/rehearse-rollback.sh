#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <current-binary>" >&2
    exit 2
fi

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bash "$project_root/scripts/run-v0.3-gate.sh" \
    "$1" "$project_root/tests/e2e-rollback.sh"
