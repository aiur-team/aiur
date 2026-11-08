#!/usr/bin/env bash
# T1-T4 from docs/research/MPG-109.md. Override S=path to run against another script.
set -euo pipefail
S=${S:-$(dirname "$0")/mpg-109-count-duplicates.sh}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
eq() { [ "$2" = "$3" ] && echo "ok   $1" || { echo "FAIL $1: got $2 want $3"; fail=1; }; }
tab() { printf '%s\t%s\t%s\t%s\n' "$@"; }

tab 10 pc 10:00 10:20 > "$tmp/a"; tab 10 nook 10:10 10:30 >> "$tmp/a"
eq "T1 overlap found" "$("$S" overlaps "$tmp/a")" '["10"]'

tab 11 pc 10:00 10:05 > "$tmp/b"; tab 11 pc 10:04 10:09 >> "$tmp/b"
eq "T2 cross-gateway empty" "$("$S" overlaps "$tmp/b")" '[]'
eq "T2 same-gateway found" "$("$S" same-overlaps "$tmp/b")" '["11"]'

tab 12 pc 10:00 10:05 > "$tmp/c"; tab 12 nook 10:05 10:09 >> "$tmp/c"
eq "T3 adjacency not overlap" "$("$S" overlaps "$tmp/c")" '[]'

mkdir -p "$tmp/ws/13/logs"
printf '%s\n' '{"event":"session_started","timestamp":"10:00"}' '{"event":"session_started","timestamp":"10:04"}' \
  '{"event":"x","timestamp":"10:09"}' > "$tmp/ws/13/logs/agent.ndjson"
eq "T4 transcript to rows" "$("$S" rows "$tmp/ws" pc | tr '\t\n' ' ;')" '13 pc 10:00 10:04;13 pc 10:04 10:09;'
exit $fail
