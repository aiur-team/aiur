#!/usr/bin/env bash
#
# Guards `scripts/check-design-extract.py`: it must pass on the real extract and
# fail on a one-byte edit, a missing part, and reordered parts.
#
# Usage: bash scripts/test-check-design-extract.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="$repo_root/scripts/check-design-extract.py"
src="$repo_root/docs/design/streamdeck"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

fresh() {
  rm -rf "$work/d"
  mkdir "$work/d"
  cp "$src"/streamdeck.design.*.js "$src/streamdeck.design.manifest.json" "$work/d/"
}

run() { python3 "$checker" "$work/d/streamdeck.design.manifest.json" >/dev/null 2>&1; }

fresh
run || fail "pristine extract should pass"

fresh
printf 'x' >>"$work/d/streamdeck.design.2-cmd-logs.js"
run && fail "one appended byte should fail"

fresh
rm "$work/d/streamdeck.design.3-init.js"
run && fail "missing part should fail"

fresh
sed -i 's/1-grid/TMP/;s/3-init/1-grid/;s/TMP/3-init/' "$work/d/streamdeck.design.manifest.json"
run && fail "reordered parts should fail"

echo "check-design-extract guard: all cases passed"
