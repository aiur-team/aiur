#!/usr/bin/env bash
# Classify a pull request as docs-only. Env: EVENT_NAME, REPO, PR_NUMBER, GH_TOKEN.
#
# Only `pull_request` has a diff to classify. `push`, `merge_group` and
# `workflow_dispatch` always get the full suite: the merge queue builds
# a candidate whose required checks must be the real ones, and `main`
# must never be validated by an empty run.
#
# Anything that is not provably docs-only classifies as `false`, so a
# failure to read the file list degrades to running the whole suite.
set -euo pipefail
if [ "$EVENT_NAME" != "pull_request" ]; then
  echo "docs_only=false" >> "$GITHUB_OUTPUT"
  echo "event $EVENT_NAME: running the full suite" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi
files="$(gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/files" --jq '.[].filename')"
if [ -z "$files" ]; then
  echo "docs_only=false" >> "$GITHUB_OUTPUT"
  echo "no changed files reported: running the full suite" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi
if printf '%s\n' "$files" | grep -qv '^website/\|^packages/aiur-style/'; then
  docs_only=false
else
  docs_only=true
fi
echo "docs_only=$docs_only" >> "$GITHUB_OUTPUT"
{
  echo "### changed paths"
  echo
  echo "docs_only=$docs_only"
  echo
  echo '```'
  printf '%s\n' "$files"
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"
