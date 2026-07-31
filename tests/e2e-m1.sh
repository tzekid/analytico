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

mkdir -p .zig-cache
fixture_dir=$(mktemp -d "$PWD/.zig-cache/m1-e2e.XXXXXX")
trap 'rm -rf -- "$fixture_dir"' EXIT

expect_failure() {
    if "$@" >"$fixture_dir/rejected.stdout" 2>"$fixture_dir/rejected.stderr"; then
        echo "command unexpectedly succeeded: $*" >&2
        exit 1
    fi
}

init_output=$("$binary" init "$fixture_dir")
test "$init_output" = "initialized metadata=v2 events=v2 key=created"
test -s "$fixture_dir/meta.db"
test -s "$fixture_dir/events.duckdb"
test "$(stat -c '%a' "$fixture_dir/visitor.key")" = "600"
test "$(stat -c '%s' "$fixture_dir/visitor.key")" = "32"
key_hash=$(sha256sum "$fixture_dir/visitor.key" | cut -d' ' -f1)
test "$("$binary" init "$fixture_dir")" = \
    "initialized metadata=v2 events=v2 key=existing"
test "$(sha256sum "$fixture_dir/visitor.key" | cut -d' ' -f1)" = "$key_hash"

site_output=$(
    "$binary" site add "$fixture_dir" example "Example Site" \
        "https://Example.COM:443"
)
[[ "$site_output" == "site added example "* ]]
site_list=$("$binary" site list "$fixture_dir")
[[ "$site_list" == example$'\t'*$'\tactive\tExample Site' ]]
site_id=$(printf '%s\n' "$site_list" | cut -f2)
[[ "$site_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]

expect_failure "$binary" site add "$fixture_dir" example Duplicate https://other.example
expect_failure "$binary" site add "$fixture_dir" Bad-Slug Invalid https://bad.example
expect_failure "$binary" site add "$fixture_dir" other Invalid https://bad.example/path
expect_failure "$binary" site add "$fixture_dir" other $'bad\xff' https://bad.example

test "$("$binary" site origin-add "$fixture_dir" example http://localhost:8080)" = \
    "origin added example http://localhost:8080"
expect_failure "$binary" site origin-add "$fixture_dir" example https://example.com
test "$("$binary" site property-add "$fixture_dir" example plan)" = \
    "property added example plan"
expect_failure "$binary" site property-add "$fixture_dir" example nested/value
install_snippet=$("$binary" site install "$fixture_dir" example \
    https://analytics.example)
[[ "$install_snippet" == *\
'<script defer src="https://analytics.example/tracker.aef65945.js" data-site="'"$site_id"'"></script>'* ]]
[[ "$install_snippet" == *\
'src="https://analytics.example/v1/p.gif?site='"$site_id"'&amp;path=%2F"'* ]]
[[ "$install_snippet" == *$'CSP merge:\n  script-src https://analytics.example\n  connect-src https://analytics.example\n  img-src https://analytics.example' ]]
expect_failure "$binary" site install "$fixture_dir" example \
    'https://analytics.example/path'

[[ "$("$binary" goal add "$fixture_dir" example Signup event signup)" == \
    "goal added Signup "* ]]
[[ "$("$binary" goal add "$fixture_dir" example Pricing path /pricing)" == \
    "goal added Pricing "* ]]
[[ "$("$binary" goal add "$fixture_dir" example Docs prefix /docs)" == \
    "goal added Docs "* ]]
goal_list=$("$binary" goal list "$fixture_dir" example)
[[ "$goal_list" == *$'Signup\tevent\tsignup\t'* ]]
[[ "$goal_list" == *$'Pricing\tpath\t/pricing\t'* ]]
[[ "$goal_list" == *$'Docs\tprefix\t/docs\t'* ]]
expect_failure "$binary" goal add "$fixture_dir" example Bad regex '.*'

[[ "$("$binary" funnel add "$fixture_dir" example Checkout \
    path=/pricing event=signup path=/thanks)" == "funnel added Checkout "* ]]
funnel=$("$binary" funnel show "$fixture_dir" example Checkout)
test "$funnel" = $'0\t/pricing\tpath\t/pricing\n1\tsignup\tevent\tsignup\n2\t/thanks\tpath\t/thanks'
expect_failure "$binary" funnel add "$fixture_dir" example TooShort event=signup

key1=$(printf '11%.0s' {1..32})
key2=$(printf '22%.0s' {1..32})
visitor_a=$("$binary" pseudonym "$key1" "$site_id" 2026-07-31 \
    203.0.113.1 Firefox-Linux-desktop)
visitor_same_prefix=$("$binary" pseudonym "$key1" "$site_id" 2026-07-31 \
    203.0.113.254 Firefox-Linux-desktop)
visitor_other_prefix=$("$binary" pseudonym "$key1" "$site_id" 2026-07-31 \
    203.0.114.1 Firefox-Linux-desktop)
visitor_other_day=$("$binary" pseudonym "$key1" "$site_id" 2026-08-01 \
    203.0.113.1 Firefox-Linux-desktop)
visitor_other_key=$("$binary" pseudonym "$key2" "$site_id" 2026-07-31 \
    203.0.113.1 Firefox-Linux-desktop)
visitor_other_site=$("$binary" pseudonym "$key1" \
    00000000-0000-4000-8000-000000000002 2026-07-31 \
    203.0.113.1 Firefox-Linux-desktop)
test "$visitor_a" = "$visitor_same_prefix"
test "$visitor_a" != "$visitor_other_prefix"
test "$visitor_a" != "$visitor_other_day"
test "$visitor_a" != "$visitor_other_key"
test "$visitor_a" != "$visitor_other_site"
test "${#visitor_a}" = 32
expect_failure "$binary" pseudonym "$key1" not-a-uuid 2026-07-31 \
    203.0.113.1 Firefox-Linux-desktop
expect_failure "$binary" pseudonym "$key1" "$site_id" 2026-02-29 \
    203.0.113.1 Firefox-Linux-desktop

ipv6_a=$("$binary" pseudonym "$key1" "$site_id" 2026-07-31 \
    2001:db8:abcd:1234::1 Firefox-Linux-desktop)
ipv6_same_prefix=$("$binary" pseudonym "$key1" "$site_id" 2026-07-31 \
    2001:db8:abcd:ffff::1 Firefox-Linux-desktop)
test "$ipv6_a" = "$ipv6_same_prefix"

event_output=$("$binary" event add "$fixture_dir" example pageview \
    '/pricing?utm_source=discarded' 1700000000000000 2023-11-14 \
    203.0.113.42 Firefox Linux desktop)
[[ "$event_output" == "event committed "* ]]
doctor=$("$binary" doctor "$fixture_dir")
test "$doctor" = \
    "ok metadata=v2 events=v2 sites=1 goals=3 funnels=1 stored_events=1 key=ok"
expect_failure "$binary" event add "$fixture_dir" example pageview \
    'not-a-path' 1700000000000001 2023-11-14 203.0.113.42 Firefox Linux desktop
test "$("$binary" doctor "$fixture_dir")" = "$doctor"

expect_failure "$binary" goal delete "$fixture_dir" example Signup --confirm Wrong
test "$("$binary" goal delete "$fixture_dir" example Signup --confirm Signup)" = \
    "goal deleted Signup"
expect_failure "$binary" funnel delete "$fixture_dir" example Checkout --confirm Wrong
test "$("$binary" funnel delete "$fixture_dir" example Checkout --confirm Checkout)" = \
    "funnel deleted Checkout"
test "$("$binary" site disable "$fixture_dir" example)" = "site disabled example"
[[ "$("$binary" site list "$fixture_dir")" == *$'\tdisabled\tExample Site' ]]
expect_failure "$binary" site delete "$fixture_dir" example --confirm Wrong
test "$("$binary" site delete "$fixture_dir" example --confirm example)" = \
    "site deleted example"
test "$("$binary" doctor "$fixture_dir")" = \
    "ok metadata=v2 events=v2 sites=0 goals=0 funnels=0 stored_events=0 key=ok"

echo "M1 durable-domain real-process end-to-end checks passed"
