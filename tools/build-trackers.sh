#!/usr/bin/env bash
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_file=$root/assets/tracker-source.js
output_dir=$root/assets/generated
mkdir -p "$output_dir"

generate() {
  name=$1
  session=$2
  rum=$3
  temporary=$output_dir/.$name.tmp
  if [ "$session" = true ]; then
    mode=session
    session_id='loadSession()'
    session_required=' || !sessionId'
  else
    mode=lite
    session_id=null
    session_required=
  fi
  awk -v include_session="$session" -v include_rum="$rum" '
    /\/\* @session-begin \*\// { in_session=1; next }
    /\/\* @session-end \*\// { in_session=0; next }
    /\/\* @rum-begin \*\// { in_rum=1; next }
    /\/\* @rum-end \*\// { in_rum=0; next }
    (!in_session || include_session == "true") && (!in_rum || include_rum == "true") { print }
  ' "$source_file" | sed \
    -e "s/__MODE__/$mode/" \
    -e "s/__SESSION_ID__/$session_id/" \
    -e "s/__SESSION_REQUIRED__/$session_required/" > "$temporary"
  mv "$temporary" "$output_dir/$name.js"
}

generate tracker-lite false false
generate tracker-lite-rum false true
generate tracker-session true false
generate tracker-session-rum true true

for asset in "$output_dir"/*.js; do
  raw=$(wc -c < "$asset")
  gzip_size=$(gzip -9 -c "$asset" | wc -c)
  if command -v brotli >/dev/null 2>&1; then
    brotli_size=$(brotli -q 11 -c "$asset" | wc -c)
  else
    brotli_size=unavailable
  fi
  printf '%s raw=%s gzip=%s brotli=%s\n' "$(basename "$asset")" "$raw" "$gzip_size" "$brotli_size"
done
