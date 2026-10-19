#!/usr/bin/env bash
# Markdown list of failed Playwright cells under the current directory's .artifacts-run-*.
set -euo pipefail
echo "### Failed parity cells: $1"
echo 'Each entry names its artifact folder; *-diff.png, *-actual.png and *-expected.png sit beside it.'
{ find .artifacts-run-* -name error-context.md 2>/dev/null || true; } | sort | while read -r context; do
  echo "- $(grep -m1 -- '^- Name: ' "$context" | sed 's/^- Name: //') (\`$(dirname "$context")\`)"
done
