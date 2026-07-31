#!/usr/bin/env bash
set -euo pipefail

workflow_dir="${1:-.github/workflows}"

rg_file_args=()
if [[ -d "$workflow_dir" ]]; then
  rg_file_args=(--glob '*.yml' --glob '*.yaml')
elif [[ ! -f "$workflow_dir" ]]; then
  echo "workflow security guard: path not found: $workflow_dir" >&2
  exit 1
fi

# Bare-substring scan catches flow-map and list-form YAML in addition to key-colon form.
# Apply workflow globs only to directories: older rg releases skip explicitly named
# files when --glob is present, which would let fixture and one-file scans pass.
if rg -n "${rg_file_args[@]}" 'pull_request_target|workflow_run' "$workflow_dir"; then
  echo "workflow security guard: pull_request_target and workflow_run are forbidden" >&2
  exit 1
fi

# Third-party actions must be pinned to a full 40-hex-char commit SHA.
# Local (./) references are safe by definition and are excluded by the uses: pattern below.
if rg -nP "${rg_file_args[@]}" '^\s*(?:-\s*)?uses:\s+(?!\./)(\S+)@(?!(?:[0-9a-fA-F]{40})(?:\s|#|$))' "$workflow_dir"; then
  echo "workflow security guard: third-party actions must use full commit SHA pins" >&2
  exit 1
fi
