#!/usr/bin/env bash
# Classifies a CI run for the `changes` job: writes `draft` and `docs_only` to
# $GITHUB_OUTPUT. Reads EVENT_NAME, REPO and PR_NUMBER; calls `gh`.
set -euo pipefail

# Only `pull_request` has a diff to classify. `push`, `merge_group` and
# `workflow_dispatch` always get the full suite: the merge queue builds a
# candidate whose required checks must be the real ones, and `main` must never
# be validated by an empty run.
if [ "$EVENT_NAME" != "pull_request" ]; then
  echo "draft=false" >> "$GITHUB_OUTPUT"
  echo "docs_only=false" >> "$GITHUB_OUTPUT"
  echo "event $EVENT_NAME: running the full suite" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

# Draft state is read live, never from the event payload: a `synchronize`
# payload built while `gh pr ready` lands still says draft, and that run then
# cancels the `ready_for_review` run and skips the suite on a ready PR (#4002).
# An unreadable state counts as ready, so it degrades to running everything.
draft="$(gh api "repos/$REPO/pulls/$PR_NUMBER" --jq '.draft' || echo false)"
echo "draft=$draft" >> "$GITHUB_OUTPUT"
echo "draft=$draft" >> "$GITHUB_STEP_SUMMARY"

# Anything that is not provably docs-only classifies as `false`.
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
