#!/usr/bin/env bash
#
# Guards `scripts/archive-historical-doc.py`: duplicate-heading slugs, fence
# skipping, punctuation slugs, frontmatter copy and the already-archived refusal.
#
# Usage: bash scripts/test-archive-historical-doc.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tool="$repo_root/scripts/archive-historical-doc.py"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

cd "$work"
git init -q .
git config user.email t@example.com
git config user.name t
mkdir docs
cat >docs/plan.md <<'EOF'
---
title: Fixture plan
status: active
---
# Fixture plan

Body.

## Overview
text
## Overview
```
# not a heading
```
### What's next? (v2)
EOF
git add . && git commit -qm fixture
sha="$(git rev-parse HEAD)"

python3 -I "$tool" "$sha" docs/plan.md
out="$(cat docs/plan.md)"
base="https://github.com/aiur-team/aiur/blob/$sha/docs/plan.md"

has() { grep -qxF -- "$1" <<<"$out" || fail "missing line: $1"; }

has "title: Fixture plan"
has "archived: $sha (U8-P25-T01)"
has "# Fixture plan"
has "> Historical record. Full text: $base"
has "[Section text at ${sha:0:9}]($base#overview)"
has "[Section text at ${sha:0:9}]($base#overview-1)"
has "[Section text at ${sha:0:9}]($base#whats-next-v2)"
! grep -q "not a heading" <<<"$out" || fail "fenced line was treated as a heading"
[ "$(grep -c '^## Overview$' <<<"$out")" = 2 ] || fail "headings not repeated in order"

git add . && git commit -qm archive
if python3 -I "$tool" HEAD docs/plan.md 2>/dev/null; then
  fail "tool re-archived an index"
fi

echo "ok"
