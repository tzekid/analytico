#!/usr/bin/env bash
set -euo pipefail

playwright_version=1.62.0
module_prefix=${ANALYTICO_PLAYWRIGHT_PREFIX:-"$PWD/.zig-cache/playwright-node"}
browser_root=${PLAYWRIGHT_BROWSERS_PATH:-"$PWD/.zig-cache/ms-playwright"}
browser_image='mcr.microsoft.com/playwright@sha256:baed2032d533817f3dbe6425de795788430ba345e819a1201337009ba17c9d07'
mkdir -p "$module_prefix"

npm install --prefix "$module_prefix" --no-package-lock --no-save \
    "playwright@$playwright_version"
if command -v docker >/dev/null 2>&1; then
    docker pull "$browser_image"
else
    mkdir -p "$browser_root"
    PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
        "$module_prefix/node_modules/.bin/playwright" install \
        chromium firefox webkit
fi
