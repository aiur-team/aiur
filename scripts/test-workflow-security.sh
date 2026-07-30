#!/usr/bin/env bash
set -euo pipefail

fixture_root="scripts/test-fixtures/workflow-security"

fixtures=("$fixture_root"/*.yml "$fixture_root"/*.yaml)
found=0
for fixture in "${fixtures[@]}"; do
  [[ -f "$fixture" ]] || continue
  found=$((found + 1))
  if scripts/verify-workflow-security.sh "$fixture" >/dev/null 2>&1; then
    echo "expected workflow guard to reject $fixture" >&2
    exit 1
  fi
done

if [[ "$found" -eq 0 ]]; then
  echo "no security fixtures found in $fixture_root" >&2
  exit 1
fi

scripts/verify-workflow-security.sh .github/workflows
