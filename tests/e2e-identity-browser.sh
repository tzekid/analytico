#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <analytico-binary>" >&2
    exit 2
fi

binary=$1
case "$binary" in
    /*) ;;
    *) binary="$PWD/$binary" ;;
esac

module_root=${ANALYTICO_PLAYWRIGHT_NODE_PATH:-"$PWD/.zig-cache/playwright-node/node_modules"}
browser_root=${PLAYWRIGHT_BROWSERS_PATH:-"$PWD/.zig-cache/ms-playwright"}
chromium_path=${ANALYTICO_CHROMIUM_PATH:-"$browser_root/chromium-1234/chrome-linux64/chrome"}
browser_image='mcr.microsoft.com/playwright@sha256:baed2032d533817f3dbe6425de795788430ba345e819a1201337009ba17c9d07'
if [[ ! -d "$module_root/playwright" ]]; then
    echo "browser fixture missing; run tests/setup-browser-e2e.sh" >&2
    exit 2
fi

fixture_dir=$(mktemp -d "$PWD/.zig-cache/identity-browser.XXXXXX")
collector_pid=
collector_port=$((45000 + ($$ % 1000)))
fixture_port=$((47000 + ($$ % 1000)))
collector="http://127.0.0.1:$collector_port"
cleanup() {
    if [[ -n "$collector_pid" ]] && kill -0 "$collector_pid" 2>/dev/null; then
        kill -TERM "$collector_pid" 2>/dev/null || true
        wait "$collector_pid" 2>/dev/null || true
    fi
    rm -rf -- "$fixture_dir"
}
trap cleanup EXIT

"$binary" init "$fixture_dir" >/dev/null
"$binary" site add "$fixture_dir" alpha "Identity A" \
    "http://127.0.0.1:$fixture_port" >/dev/null
"$binary" site add "$fixture_dir" beta "Identity B" \
    "http://127.0.0.1:$fixture_port" >/dev/null
site_a=$("$binary" site list "$fixture_dir" |
    awk -F '\t' '$1 == "alpha" { print $2 }')
site_b=$("$binary" site list "$fixture_dir" |
    awk -F '\t' '$1 == "beta" { print $2 }')

"$binary" serve --listen "127.0.0.1:$collector_port" \
    --meta "$fixture_dir/meta.db" \
    --events "$fixture_dir/events.duckdb" \
    --temp "$fixture_dir/tmp" \
    --visitor-key-file "$fixture_dir/visitor.key" \
    >"$fixture_dir/server.stdout" 2>"$fixture_dir/server.stderr" &
collector_pid=$!
ready=false
for _ in {1..100}; do
    if curl --silent --fail "$collector/readyz" >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 0.02
done
test "$ready" = true

if command -v docker >/dev/null 2>&1 &&
    docker image inspect "$browser_image" >/dev/null 2>&1
then
    docker run --rm --network host --ipc host \
        --volume "$PWD/tests:/work/tests:ro" \
        --volume "$module_root:/work/node_modules:ro" \
        --env NODE_PATH=/work/node_modules \
        --env PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
        "$browser_image" \
        node /work/tests/e2e-identity-browser.cjs \
        "$collector" "$site_a" "$site_b" "$fixture_port" \
        >"$fixture_dir/browser-result.json"
else
    if [[ ! -d "$browser_root" ]]; then
        echo "browser binaries missing; run tests/setup-browser-e2e.sh" >&2
        exit 2
    fi
    TMPDIR="$fixture_dir" NODE_PATH="$module_root" \
        PLAYWRIGHT_BROWSERS_PATH="$browser_root" \
        ANALYTICO_CHROMIUM_PATH="$chromium_path" \
        node tests/e2e-identity-browser.cjs \
        "$collector" "$site_a" "$site_b" "$fixture_port" \
        >"$fixture_dir/browser-result.json"
fi

grep -q '"persistent_anonymous_after_reload":true' \
    "$fixture_dir/browser-result.json"
grep -q '"persistent_anonymous_after_storage_restore":true' \
    "$fixture_dir/browser-result.json"
grep -q '"storage_exception_ephemeral":true' \
    "$fixture_dir/browser-result.json"
grep -q '"storage_exception_host_survived":true' \
    "$fixture_dir/browser-result.json"
grep -q '"reset_new_anonymous_and_session":true' \
    "$fixture_dir/browser-result.json"
grep -q '"reset_cleared_identified_key":true' \
    "$fixture_dir/browser-result.json"
grep -q '"distinct_site_keys":true' \
    "$fixture_dir/browser-result.json"
grep -q '"uuid_getRandomValues_fallback":true' \
    "$fixture_dir/browser-result.json"

kill -TERM "$collector_pid"
wait "$collector_pid" 2>/dev/null || true
collector_pid=

doctor=$("$binary" doctor "$fixture_dir")
[[ "$doctor" == ok\ metadata=v2\ events=v3\ sites=2\ * ]]
[[ "$doctor" == *key=ok ]]

if grep -aE '(prior-user|blocked)' \
    "$fixture_dir/events.duckdb" "$fixture_dir/server.stdout" \
    "$fixture_dir/server.stderr" >/dev/null
then
    echo "identity fixture detail leaked" >&2
    exit 1
fi

cat "$fixture_dir/browser-result.json"
echo "identity browser persistence, reset, and storage-failure checks passed"
