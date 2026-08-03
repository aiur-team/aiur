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

  jq "$jq_filter" "$declaration" >"$fixture"

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
# without ruleset write visibility, and the strict flag is being reconciled by
# #1487. Both must be tolerated here; the admin verifier owns those checks.
expect_accepted \
  "hidden-bypass-actors" \
  '.bypass_actors = null'

expect_accepted \
  "strict-true" \
  '(.rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy) = true'
