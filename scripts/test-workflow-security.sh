#!/usr/bin/env bash
set -euo pipefail

fixture_root="scripts/test-fixtures/workflow-security"

expect_rejection() {
  local fixture="$1"
  local expected_reason="$2"
  local output

  if output="$(scripts/verify-workflow-security.sh "$fixture" 2>&1)"; then
    echo "expected workflow guard to reject $fixture" >&2
    exit 1
  fi

  if ! grep -Fq "$expected_reason" <<<"$output"; then
    echo "workflow guard rejected $fixture for the wrong reason:" >&2
    echo "$output" >&2
    exit 1
  fi
}

expect_rejection \
  "$fixture_root/pull_request_target.yml" \
  "pull_request_target and workflow_run are forbidden"
expect_rejection \
  "$fixture_root/workflow_run.yml" \
  "pull_request_target and workflow_run are forbidden"
expect_rejection \
  "$fixture_root/unpinned-action.yml" \
  "third-party actions must use full commit SHA pins"
expect_rejection \
  "$fixture_root/composite-actions/example/action.yml" \
  "third-party actions must use full commit SHA pins"
expect_rejection \
  "$fixture_root/quoted-uses-key.yml" \
  "third-party actions must use full commit SHA pins"
expect_rejection \
  "$fixture_root/flow-mapping.yml" \
  "third-party actions must use full commit SHA pins"
expect_rejection \
  "$fixture_root/escaped-trigger-key.yml" \
  "escaped double-quoted YAML keys are forbidden"
expect_rejection \
  "$fixture_root/escaped-uses-key.yml" \
  "escaped double-quoted YAML keys are forbidden"
expect_rejection \
  "$fixture_root/explicit-uses-key.yml" \
  "explicit YAML mapping keys are forbidden"
expect_rejection \
  "$fixture_root/outside-local-action.yml" \
  "local actions must live under .github/actions"

if output="$(
  PATH="$fixture_root/failing-grep:$PATH" \
    scripts/verify-workflow-security.sh "$fixture_root/pull_request_target.yml" 2>&1
)"; then
  echo "expected workflow guard to fail closed when grep fails" >&2
  exit 1
fi

if ! grep -Fq "workflow security guard: scanner failed" <<<"$output"; then
  echo "workflow guard did not report the scanner failure:" >&2
  echo "$output" >&2
  exit 1
fi

symlink_fixture="$(mktemp -d "${TMPDIR:-/tmp}/aiur-workflow-security.XXXXXX")"
trap 'rm -rf "$symlink_fixture"' EXIT
ln -s / "$symlink_fixture/escape"

if output="$(scripts/verify-workflow-security.sh "$symlink_fixture" 2>&1)"; then
  echo "expected workflow guard to reject a symlinked scan tree" >&2
  exit 1
fi

if ! grep -Fq "workflow security guard: scanner refused symlink" <<<"$output"; then
  echo "workflow guard rejected a symlinked scan tree for the wrong reason:" >&2
  echo "$output" >&2
  exit 1
fi

# The PR body is checked only by pr-body.yml, which reruns on edits (#4687).
require_body_wiring() {
  local file="$1" pattern="$2" reason="$3"
  if ! grep -Eq -- "$pattern" "$file"; then
    echo "PR body wiring: $reason" >&2
    exit 1
  fi
}
require_body_wiring .github/workflows/pr-body.yml '^    types: \[.*\bedited\b.*\]' 'pr-body.yml must run on edited'
require_body_wiring .github/workflows/ci.yml 'run: python3 scripts/check-pr-body-check-run.py' 'ci gate must require the newest pr body check'
require_body_wiring scripts/run-pre-handoff-guards.sh '^    scripts/pre-handoff-guards --skip-pr-body "\$\{AIUR_PR_BASE_SHA:\?\}"' 'workflow security must not check the PR event body'
if grep -Eq 'pull_request\.body|AIUR_PR_NUMBER' .github/workflows/ci.yml; then
  echo "PR body wiring: ci.yml must not read the PR body" >&2
  exit 1
fi

scripts/verify-workflow-security.sh
