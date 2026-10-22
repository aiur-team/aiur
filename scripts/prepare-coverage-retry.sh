#!/usr/bin/env bash
set -euo pipefail

partition="${1:?usage: prepare-coverage-retry.sh <partition> <failed-log>}"
failed_log="${2:?usage: prepare-coverage-retry.sh <partition> <failed-log>}"
partition_status_file="${3:?usage: prepare-coverage-retry.sh <partition> <failed-log> <status-file>}"
workspace="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must be set}"
changed="$RUNNER_TEMP/pr-changed-paths.txt"
mkdir -p "$RUNNER_TEMP/shard-evidence"

git -C "$workspace" fetch --no-tags --depth=1 origin "$BASE_SHA"
git -C "$workspace" diff --name-only "$BASE_SHA" HEAD > "$changed"
git -C "$workspace" show "$BASE_SHA:.github/known-flaky-tests.txt" > "$RUNNER_TEMP/base-known-flaky-tests.txt"
git -C "$workspace" show "$BASE_SHA:src/test/quarantine.txt" > "$RUNNER_TEMP/base-test-quarantine.txt"
python3 "$workspace/scripts/ci-flake-retry.py" \
  "$failed_log" "$changed" "$RUNNER_TEMP/base-known-flaky-tests.txt" \
  "$RUNNER_TEMP/base-test-quarantine.txt" \
  "$RUNNER_TEMP/shard-evidence/retry-plan.json" "$GITHUB_STEP_SUMMARY" \
  --repo "$REPOSITORY" --base-branch "$BASE_BRANCH" \
  --pull-request --partition "$partition" \
  --partition-status "$(<"$partition_status_file")" \
  > "$RUNNER_TEMP/shard-evidence/retry-tests.txt"
