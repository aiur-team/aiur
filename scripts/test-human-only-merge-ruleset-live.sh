#!/usr/bin/env bash
set -euo pipefail

# Fixture-based regression tests for the read-only CI drift check
# (verify-human-only-merge-ruleset-live.sh). Reuses the same mock `gh` and
# declaration-derived fixtures as the admin verifier tests so both stay in
# sync with the reviewed declaration.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures="$root/scripts/test-fixtures/human-only-merge-ruleset"
drift_check="$root/scripts/verify-human-only-merge-ruleset-live.sh"
declaration="$root/docs/security/human-only-merge-ruleset.json"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

run_drift_check() {
  local fixture="$1"

  PATH="$fixtures:$PATH" \
    GITHUB_REPOSITORY="example/repository" \
    RULESET_FIXTURE="$fixture" \
    bash "$drift_check"
}

expect_rejected() {
  local name="$1"
  local jq_filter="$2"
  local expected_error="$3"
  local fixture="$test_dir/$name.json"
  local output
  shift 3

  jq "$@" "$jq_filter" "$declaration" >"$fixture"

  if output="$(run_drift_check "$fixture" 2>&1)"; then
    echo "expected drift check to reject $name" >&2
    exit 1
  fi

  if ! grep -Fq "$expected_error" <<<"$output"; then
    echo "drift check rejected $name for the wrong reason: $output" >&2
    exit 1
  fi
}

expect_accepted() {
  local name="$1"
  local jq_filter="$2"
  local fixture="$test_dir/$name.json"

  jq "$jq_filter" "$declaration" >"$fixture"

  if ! run_drift_check "$fixture" >/dev/null 2>&1; then
    echo "expected drift check to accept $name" >&2
    exit 1
  fi
}

run_drift_check "$declaration"

while IFS= read -r field; do
  expect_rejected \
    "drifted-$field" \
    '(.rules[] | select(.type == "merge_queue") | .parameters[$field]) |=
      if type == "number" then . + 1
      elif type == "string" then . + "_DRIFT"
      elif type == "boolean" then not
      else "DRIFT"
      end' \
    "ruleset merge_queue parameter mismatch: $field" \
    --arg field "$field"
done < <(jq -r '
  .rules[] | select(.type == "merge_queue") | .parameters | keys[]
' "$declaration")

expect_rejected \
  "unexpected-merge-queue-parameter" \
  '(.rules[] | select(.type == "merge_queue") | .parameters.unexpected_parameter) = 1' \
  "ruleset merge_queue parameter mismatch: unexpected_parameter"

expect_rejected \
  "missing-max-entries-to-build" \
  'del(.rules[] | select(.type == "merge_queue") | .parameters.max_entries_to_build)' \
  "ruleset merge_queue parameter mismatch: max_entries_to_build"

expect_rejected \
  "missing-merge-queue-rule" \
  '.rules |= map(select(.type != "merge_queue"))' \
  "live ruleset must contain exactly one merge_queue rule"

# Regression: a live-ruleset query returning no required_status_checks rule
# must fail the CI drift check (the ticket's acceptance criterion).
expect_rejected \
  "missing-required-checks-rule" \
  '.rules |= map(select(.type != "required_status_checks"))' \
  "ruleset must require every blocking GitHub Actions status check from the declaration"

expect_rejected \
  "tag-target" \
  '.target = "tag"' \
  "ruleset must target branches and actively protect main and develop"

expect_rejected \
  "missing-ref-exclusions" \
  'del(.conditions.ref_name.exclude)' \
  "ruleset ref_name.exclude must be present and exactly empty"

expect_rejected \
  "wildcard-ref-exclusion" \
  '.conditions.ref_name.exclude = ["refs/heads/*"]' \
  "ruleset ref_name.exclude must be present and exactly empty"

expect_rejected \
  "missing-branch-protection" \
  '.conditions.ref_name.include = ["refs/heads/main"]' \
  "ruleset must target branches and actively protect main and develop"

expect_rejected \
  "missing-pull-request-rule" \
  '.rules |= map(select(.type != "pull_request"))' \
  "ruleset must require current CODEOWNER approval and dismiss stale reviews"

expect_rejected \
  "codeowner-review-disabled" \
  '(.rules[] | select(.type == "pull_request") | .parameters.require_code_owner_review) = false' \
  "ruleset must require current CODEOWNER approval and dismiss stale reviews"

expect_rejected \
  "missing-workflow-security-check" \
  '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) |= map(select(.context != "workflow security"))' \
  "ruleset must require every blocking GitHub Actions status check from the declaration"

expect_rejected \
  "missing-coverage-partition" \
  '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) |= map(select(.context != "coverage (4/4)"))' \
  "ruleset must require every blocking GitHub Actions status check from the declaration"

expect_rejected \
  "untrusted-check-source" \
  '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[0].integration_id) = 1' \
  "ruleset must require every blocking GitHub Actions status check from the declaration"

# The drift check runs read-only: GitHub hides bypass_actors (returns null)
# without ruleset write visibility, so that property must be tolerated here and
# stays in the admin verifier's domain. Strict status checks are read-only
# visible and are asserted against the declaration.
#
# The declaration requires strict = FALSE, and the polarity of these two cases
# was deliberately inverted when the merge queue was adopted (#1381). Reasoning,
# recorded here because reversing a security assertion should never look like a
# value tweak:
#
# `strict_required_status_checks_policy` forces a PR to be up to date with the
# base at the instant it merges. It approximates "this change was tested against
# what it will actually land on". The merge queue provides that property
# directly and more strongly: it builds each candidate on a
# gh-readonly-queue ref, merged with the base, and runs the required checks
# against that merged result before anything lands. ALLGREEN grouping means a
# batch merges only if the whole batch is green together.
#
# Holding strict ON alongside the queue is not defence in depth -- it is
# redundant, and it reintroduces the failure it was meant to prevent by hand:
# every merge invalidates every other open PR, forcing a refresh-and-retest
# cycle that races the next merge. That capped this repository at roughly one
# merge per CI cycle.
#
# So a strict-TRUE live ruleset is now the drift, because it no longer matches
# the declaration and it disables the queue's own guarantee.
expect_accepted \
  "hidden-bypass-actors" \
  '.bypass_actors = null'

expect_accepted \
  "non-strict" \
  '(.rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy) = false'

expect_rejected \
  "strict-true" \
  '(.rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy) = true' \
  "ruleset must require every blocking GitHub Actions status check from the declaration"
