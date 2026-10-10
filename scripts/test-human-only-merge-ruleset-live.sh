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

# Regression: a live-ruleset query returning no required_status_checks rule
# must fail the CI drift check (the ticket's acceptance criterion).
expect_rejected \
  "missing-required-checks-rule" \
  '.rules |= map(select(.type != "required_status_checks"))' \
  "ruleset must require every blocking GitHub Actions status check from the declaration"

expect_rejected \
  "tag-target" \
  '.target = "tag"' \
  "ruleset must target branches and actively protect main"

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
  '.conditions.ref_name.include = ["refs/heads/some-other-branch"]' \
  "ruleset must target branches and actively protect main"

expect_rejected \
  "reintroduced-pull-request-rule" \
  '.rules += [{"type": "pull_request", "parameters": {"required_approving_review_count": 1}}]' \
  "ruleset rule types must match the declaration"

expect_rejected \
  "missing-deletion-rule" \
  '.rules |= map(select(.type != "deletion"))' \
  "ruleset rule types must match the declaration"

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

# The `main` merge-queue ruleset is served by the mock as id 456 and compared
# with docs/security/main-merge-queue-ruleset.json.
queue_declaration="$root/docs/security/main-merge-queue-ruleset.json"

expect_queue_rejected() {
  local name="$1"
  local jq_filter="$2"
  local fixture="$test_dir/queue-$name.json"
  local output

  jq "$jq_filter" "$queue_declaration" >"$fixture"

  if output="$(MAIN_RULESET_FIXTURE="$fixture" run_drift_check "$declaration" 2>&1)"; then
    echo "expected drift check to reject merge queue $name" >&2
    exit 1
  fi

  if ! grep -Fq "merge queue ruleset must match the declaration: main" <<<"$output"; then
    echo "drift check rejected merge queue $name for the wrong reason: $output" >&2
    exit 1
  fi
}

expect_queue_rejected "disabled" '.enforcement = "disabled"'
expect_queue_rejected "no-queue" '.rules |= map(select(.type != "merge_queue"))'
expect_queue_rejected "batch-size" '(.rules[] | select(.type == "merge_queue") | .parameters.min_entries_to_merge) = 1'
expect_queue_rejected "allgreen" '(.rules[] | select(.type == "merge_queue") | .parameters.grouping_strategy) = "ALLGREEN"'

if output="$(RULESET_LIST_FIXTURE='[{"name":"human-only-merge-gate","id":123}]' run_drift_check "$declaration" 2>&1)" ||
  ! grep -Fq "expected exactly one ruleset named: main" <<<"$output"; then
  echo "expected drift check to reject a missing merge queue ruleset: $output" >&2
  exit 1
fi

# GitHub returns server-side fields and its own rule order; neither is drift.
jq '.id = 456 | .node_id = "x" | .rules |= reverse' "$queue_declaration" >"$test_dir/queue-live-shape.json"
MAIN_RULESET_FIXTURE="$test_dir/queue-live-shape.json" run_drift_check "$declaration" >/dev/null
