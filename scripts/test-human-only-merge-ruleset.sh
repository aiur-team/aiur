#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures="$root/scripts/test-fixtures/human-only-merge-ruleset"
verifier="$root/scripts/verify-human-only-merge-ruleset.sh"
declaration="$root/docs/security/human-only-merge-ruleset.json"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

run_verifier() {
  local fixture="$1"

  PATH="$fixtures:$PATH" \
    GITHUB_REPOSITORY="example/repository" \
    RULESET_FIXTURE="$fixture" \
    bash "$verifier"
}

expect_rejected() {
  local name="$1"
  local jq_filter="$2"
  local expected_error="$3"
  local fixture="$test_dir/$name.json"
  local output
  shift 3

  jq "$@" "$jq_filter" "$declaration" >"$fixture"

  if output="$(run_verifier "$fixture" 2>&1)"; then
    echo "expected verifier to reject $name" >&2
    exit 1
  fi

  if ! grep -Fq "$expected_error" <<<"$output"; then
    echo "verifier rejected $name for the wrong reason: $output" >&2
    exit 1
  fi
}

run_verifier "$declaration"

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

expect_rejected \
  "tag-target" \
  '.target = "tag"' \
  "ruleset must target branches and actively protect main and develop"

expect_rejected \
  "missing-ref-exclusions" \
  'del(.conditions.ref_name.exclude)' \
  "ruleset ref_name.exclude must be present and exactly empty"
expect_rejected \
  "null-ref-exclusions" \
  '.conditions.ref_name.exclude = null' \
  "ruleset ref_name.exclude must be present and exactly empty"
expect_rejected \
  "wildcard-ref-exclusion" \
  '.conditions.ref_name.exclude = ["refs/heads/*"]' \
  "ruleset ref_name.exclude must be present and exactly empty"
expect_rejected \
  "missing-bypass-actors" \
  'del(.bypass_actors)' \
  "ruleset bypass_actors must be visible, present, and exactly empty"
expect_rejected \
  "null-bypass-actors" \
  '.bypass_actors = null' \
  "ruleset bypass_actors must be visible, present, and exactly empty"
expect_rejected \
  "nonempty-bypass-actors" \
  '.bypass_actors = [{"actor_id": 1, "actor_type": "Integration", "bypass_mode": "always"}]' \
  "ruleset bypass_actors must be visible, present, and exactly empty"
expect_rejected \
  "missing-required-checks-rule" \
  '.rules |= map(select(.type != "required_status_checks"))' \
  "ruleset must require every blocking GitHub Actions status check"

expect_rejected \
  "empty-required-checks" \
  '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) = []' \
  "ruleset must require every blocking GitHub Actions status check"

# Inverted when the merge queue was adopted (#1381): the queue builds each
# candidate merged with the base and runs the required checks against that
# result, which is a stronger guarantee than strict's "up to date at merge
# time". A strict-true live ruleset is now the drift. See the reasoning block
# in test-human-only-merge-ruleset-live.sh.
expect_rejected \
  "strict-required-checks" \
  '(.rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy) = true' \
  "ruleset must require every blocking GitHub Actions status check"
expect_rejected \
  "missing-workflow-security-check" \
  '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) |= map(select(.context != "workflow security"))' \
  "ruleset must require every blocking GitHub Actions status check"
expect_rejected \
  "missing-coverage-partition" \
  '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) |= map(select(.context != "coverage (4/4)"))' \
  "ruleset must require every blocking GitHub Actions status check"
expect_rejected \
  "untrusted-check-source" \
  '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[0].integration_id) = 1' \
  "ruleset must require every blocking GitHub Actions status check"
