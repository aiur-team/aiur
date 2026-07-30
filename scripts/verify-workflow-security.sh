#!/usr/bin/env bash
set -euo pipefail

workflow_dir="${1:-.github/workflows}"

if rg -n --glob '*.{yml,yaml}' '^\s*(pull_request_target|workflow_run)\s*:' "$workflow_dir"; then
  echo "workflow security guard: pull_request_target and workflow_run are forbidden" >&2
  exit 1
fi

if rg -nP --glob '*.{yml,yaml}' '^\s*(?:-\s*)?uses:\s+\S+@(?!(?:[0-9a-f]{40})(?:\s|#|$))' "$workflow_dir"; then
  echo "workflow security guard: third-party actions must use full commit SHA pins" >&2
  exit 1
fi
