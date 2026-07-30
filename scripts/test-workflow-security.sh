#!/usr/bin/env bash
set -euo pipefail

fixture_root="scripts/test-fixtures/workflow-security"

for fixture in "$fixture_root"/*.yml; do
  if scripts/verify-workflow-security.sh "$fixture" >/dev/null 2>&1; then
    echo "expected workflow guard to reject $fixture" >&2
    exit 1
  fi
done

scripts/verify-workflow-security.sh .github/workflows
