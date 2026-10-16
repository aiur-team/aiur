#!/usr/bin/env bash
set -euo pipefail

case "${GITHUB_EVENT_NAME:?}" in
  pull_request)
    gh api "repos/$GITHUB_REPOSITORY/pulls/${AIUR_PR_NUMBER:?}" > "$RUNNER_TEMP/pr-evidence.json"
    scripts/pre-handoff-guards "$RUNNER_TEMP/pr-evidence.json" "${AIUR_PR_BASE_SHA:?}"
    ;;
  merge_group)
    scripts/pre-handoff-guards --skip-pr-body "${AIUR_MERGE_BASE_SHA:?}"
    ;;
  push)
    base="${AIUR_PUSH_BEFORE:?}"
    if [[ "$base" =~ ^0+$ ]]; then base="$(git rev-parse HEAD^1)"; fi
    scripts/pre-handoff-guards --skip-pr-body "$base"
    ;;
  workflow_dispatch)
    upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo origin/main)"
    scripts/pre-handoff-guards --skip-pr-body "$(git merge-base HEAD "$upstream")"
    ;;
  schedule)
    scripts/pre-handoff-guards --skip-pr-body "$(git merge-base HEAD origin/main)"
    ;;
  *) echo "Unsupported pre-handoff guard event: $GITHUB_EVENT_NAME" >&2; exit 1 ;;
esac

python3 scripts/check-config-docs.py
node scripts/check-docs-prose.mjs
