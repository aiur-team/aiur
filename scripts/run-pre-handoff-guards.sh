#!/usr/bin/env bash
set -euo pipefail

case "${GITHUB_EVENT_NAME:?}" in
  pull_request)
    # pr-body.yml checks the body and reruns on edits; ci gate requires its newest run.
    scripts/pre-handoff-guards --skip-pr-body "${AIUR_PR_BASE_SHA:?}"
    ;;
  merge_group)
    code_base="${AIUR_MERGE_BASE_SHA:?}"
    ;;
  push)
    code_base="${AIUR_PUSH_BEFORE:?}"
    if [[ "$code_base" =~ ^0+$ ]]; then code_base="$(git rev-parse HEAD^1)"; fi
    ;;
  workflow_dispatch)
    upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo origin/main)"
    code_base="$(git merge-base HEAD "$upstream")"
    ;;
  schedule)
    code_base="$(git merge-base HEAD origin/main)"
    ;;
  *) echo "Unsupported pre-handoff guard event: $GITHUB_EVENT_NAME" >&2; exit 1 ;;
esac

if [[ "$GITHUB_EVENT_NAME" != pull_request ]]; then
  # Merge-queue, main and scheduled runs execute the full suite and Dialyzer;
  # selected tests here would only repeat them.
  AIUR_PRE_HANDOFF_SKIP_CODE_CHECKS=1 scripts/pre-handoff-guards --skip-pr-body "$code_base"
fi

python3 scripts/check-config-docs.py
node scripts/check-docs-prose.mjs
