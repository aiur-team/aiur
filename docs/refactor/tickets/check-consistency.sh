#!/usr/bin/env bash
# Consistency checks for the refactor ticket backlog (docs/refactor/tickets/).
# Verifies: (1) every ticket file's Depends-on IDs resolve to a real ticket;
# (2) the ticket index in 00-overview.md and the ticket files are in 1:1 sync;
# (3) each ticket's Phase header matches its index row.
# Exits non-zero if any check fails. Run from repo root or this directory.
set -u
cd "$(dirname "$0")" || exit 2
OVERVIEW="../00-overview.md"
fail=0

# All ticket IDs that have a file (T-031 etc). Zero-padded 3-digit.
mapfile -t IDS < <(ls T-*.md 2>/dev/null | grep -oE 'T-[0-9]{3}' | sort -u)
have() { printf '%s\n' "${IDS[@]}" | grep -qx "$1"; }

echo "== 1. Depends-on references resolve =="
for f in T-*.md; do
  dep_line=$(grep -m1 -E '^\*\*Depends-on:\*\*' "$f")
  # strip label, split on commas, extract T-NNN tokens
  deps=$(printf '%s' "$dep_line" | grep -oE 'T-[0-9]{3}')
  for d in $deps; do
    if ! have "$d"; then
      echo "  FAIL $f: Depends-on $d has no ticket file"; fail=1
    fi
  done
done
[ "$fail" -eq 0 ] && echo "  ok"

echo "== 2. Index <-> files in sync =="
# IDs referenced in the overview index table rows: | T-NNN | ...
mapfile -t INDEX_IDS < <(grep -oE '^\| T-[0-9]{3} ' "$OVERVIEW" | grep -oE 'T-[0-9]{3}' | sort -u)
for id in "${IDS[@]}"; do
  printf '%s\n' "${INDEX_IDS[@]}" | grep -qx "$id" || { echo "  FAIL $id: file exists but not in index"; fail=1; }
done
for id in "${INDEX_IDS[@]}"; do
  have "$id" || { echo "  FAIL $id: in index but no ticket file"; fail=1; }
done
[ "$fail" -eq 0 ] && echo "  ok (${#IDS[@]} files, ${#INDEX_IDS[@]} index rows)"

echo "== 3. Phase header matches index row =="
for f in T-*.md; do
  id=$(grep -oE 'T-[0-9]{3}' <<<"$f" | head -1)
  file_phase=$(grep -m1 -E '^\*\*Phase:\*\*' "$f" | grep -oE '[0-9]+' | head -1)
  # index row: | T-NNN | title | PHASE | deps |
  idx_phase=$(grep -E "^\| $id " "$OVERVIEW" | head -1 | awk -F'|' '{gsub(/ /,"",$4); print $4}')
  if [ -n "$idx_phase" ] && [ "$file_phase" != "$idx_phase" ]; then
    echo "  FAIL $id: file Phase=$file_phase but index Phase=$idx_phase"; fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "  ok"

echo
[ "$fail" -eq 0 ] && echo "ALL CHECKS PASSED" || echo "CONSISTENCY FAILURES ABOVE"
exit $fail
