#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 || (${3:-} != "" && ${3:-} != "--full") ]]; then
    echo "usage: $0 <source-binary> <dist-directory> [--full]" >&2
    exit 2
fi

source_binary=$1
dist=$2
case "$source_binary" in
    /*) ;;
    *) source_binary="$PWD/$source_binary" ;;
esac
case "$dist" in
    /*) ;;
    *) dist="$PWD/$dist" ;;
esac
version=$("$source_binary" version)
version=${version#analytico }
name="analytico-$version-linux-x86_64"
archive="$dist/$name.tar.gz"

test -f "$archive"
test -f "$archive.sha256"
(cd "$dist" && sha256sum -c "$name.tar.gz.sha256")

mkdir -p .zig-cache
fixture=$(mktemp -d "$PWD/.zig-cache/release-e2e.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT
tar --same-permissions -xzf "$archive" -C "$fixture"
release_root="$fixture/$name"
release_binary="$release_root/bin/analytico"

test ! -L "$release_root"
test "$(find "$release_root" -type l -print -quit)" = ""
test "$(stat -c '%a' "$release_binary")" = 755
test "$(stat -c '%a' "$release_root/lib/libduckdb.so")" = 644
(cd "$release_root" && sha256sum -c SHA256SUMS)
test "$("$release_binary" version)" = "analytico $version"
ldd "$release_binary" | grep -Fq "$release_root/bin/../lib/libduckdb.so"

caddy validate --config "$release_root/deploy/Caddyfile" \
    >"$fixture/caddy.stdout" 2>"$fixture/caddy.stderr"
ANALYTICO_ADMIN_HASH=$(caddy hash-password --plaintext release-fixture-password) \
    caddy validate --config "$release_root/deploy/Caddyfile.dashboard" \
    >"$fixture/caddy-dashboard.stdout" 2>"$fixture/caddy-dashboard.stderr"
systemd-analyze security --offline=yes --no-pager \
    "$release_root/deploy/analytico.service" \
    >"$fixture/systemd-security.txt"
grep -q 'Overall exposure level.*OK' "$fixture/systemd-security.txt"

data="$fixture/data"
"$release_binary" init "$data" >/dev/null
"$release_binary" site add "$data" release Release https://release.example >/dev/null
"$release_binary" event add "$data" release pageview / \
    1785456000000000 2026-07-31 203.0.113.1 Chrome Linux desktop >/dev/null
test "$("$release_binary" doctor "$data")" = \
    "ok metadata=v2 events=v2 sites=1 goals=0 funnels=0 stored_events=1 key=ok"
report=$("$release_binary" report "$data" release 2026-07-31 2026-07-31 \
    overview --format json)
test "$report" = \
    '{"metric_version":1,"site":"release","start_date":"2026-07-31","end_date":"2026-07-31","report":"overview","page_views":1,"visitor_days":1,"sessions":1,"custom_events":0,"bot_events":0}'

if [[ ${3:-} == "--full" ]]; then
    for gate in \
        tests/e2e-m0.sh \
        tests/e2e-m1.sh \
        tests/e2e-m2.sh \
        tests/e2e-m2-browser.sh \
        tests/e2e-m3.sh \
        tests/e2e-m4.sh \
        tests/e2e-m6.sh \
        tests/e2e-m7.sh
    do
        ANALYTICO_DASHBOARD_CADDYFILE="$release_root/deploy/Caddyfile.dashboard" \
            bash "$gate" "$release_binary"
    done
fi

echo "release archive checksum, linkage, proxy, and fresh-data checks passed"
