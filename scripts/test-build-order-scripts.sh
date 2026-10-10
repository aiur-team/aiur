#!/usr/bin/env bash
# Run the Build Order publication script suites (stdlib unittest, no network).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# The receipt validator reads its pinned contract commit, which is on no branch a
# shallow CI checkout fetches.
pin="$(sed -n 's/^PINNED_SKILL_COMMIT = "\(.*\)"$/\1/p' .claude/skills/aiur-build/scripts/publication/publication_core_receipt.py)"
git cat-file -e "${pin}^{commit}" 2>/dev/null || git fetch --quiet --no-tags --depth=1 origin "$pin"
python3 -m unittest discover -s .claude/skills/aiur-build/scripts/tests
python3 -m unittest discover -s docs/build-order/scripts/tests
