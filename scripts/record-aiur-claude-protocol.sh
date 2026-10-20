#!/usr/bin/env bash
# Compare the checked-in contract with a built sibling checkout; never changes it.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${AIUR_CLAUDE_DIR:?Set AIUR_CLAUDE_DIR to a built claude-app-server checkout}"
exec timeout 60s node "$root/scripts/record-aiur-claude-protocol.mjs" "$AIUR_CLAUDE_DIR" "$@"
