#!/usr/bin/env bash
set -euo pipefail

workflow_dir="${1:-.github/workflows}"

# Bare-substring scan catches flow-map and list-form YAML in addition to key-colon form.
# Use two --glob flags instead of brace alternation for broader rg version compatibility.
if rg -n --glob '*.yml' --glob '*.yaml' 'pull_request_target|workflow_run' "$workflow_dir"; then
  echo "workflow security guard: pull_request_target and workflow_run are forbidden" >&2
  exit 1
fi

# Third-party actions must be pinned to a full 40-hex-char commit SHA.
# Local (./) references are safe by definition and are excluded by the uses: pattern below.
if rg -nP --glob '*.yml' --glob '*.yaml' '^\s*(?:-\s*)?uses:\s+(?!\./)(\S+)@(?!(?:[0-9a-fA-F]{40})(?:\s|#|$))' "$workflow_dir"; then
  echo "workflow security guard: third-party actions must use full commit SHA pins" >&2
  exit 1
fi
