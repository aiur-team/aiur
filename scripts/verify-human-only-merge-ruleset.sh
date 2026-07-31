#!/usr/bin/env bash
set -euo pipefail

repo="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
name="human-only-merge-gate"

ruleset_id="$(gh api "repos/$repo/rulesets" --paginate | jq -r --arg name "$name" '.[] | select(.name == $name) | .id')"

if [[ -z "$ruleset_id" ]]; then
  echo "missing required ruleset: $name" >&2
  exit 1
fi

if [[ "$(wc -l <<<"$ruleset_id")" -ne 1 ]]; then
  echo "expected exactly one ruleset named: $name" >&2
  exit 1
fi

ruleset="$(gh api "repos/$repo/rulesets/$ruleset_id")"

if ! jq -e '
  .target == "branch" and
  .enforcement == "active" and
  (.conditions.ref_name.include | type == "array") and
  (.conditions.ref_name.include | index("refs/heads/main")) and
  (.conditions.ref_name.include | index("refs/heads/develop"))
' >/dev/null <<<"$ruleset"; then
  echo "ruleset must target branches and actively protect main and develop" >&2
  exit 1
fi

if ! jq -e '
  (.conditions.ref_name | has("exclude")) and
  .conditions.ref_name.exclude == []
' >/dev/null <<<"$ruleset"; then
  echo "ruleset ref_name.exclude must be present and exactly empty" >&2
  exit 1
fi

if ! jq -e '
  has("bypass_actors") and
  .bypass_actors == []
' >/dev/null <<<"$ruleset"; then
  echo "ruleset bypass_actors must be visible, present, and exactly empty" >&2
  exit 1
fi

if ! jq -e '
  [.rules[] | select(.type == "pull_request") | .parameters] |
  length == 1 and
  .[0].required_approving_review_count >= 1 and
  .[0].require_code_owner_review == true and
  .[0].require_last_push_approval == true and
  .[0].dismiss_stale_reviews_on_push == true
' >/dev/null <<<"$ruleset"; then
  echo "ruleset must require current CODEOWNER approval and dismiss stale reviews" >&2
  exit 1
fi

required_checks='[
  "browser harness",
  "build",
  "coverage",
  "coverage (1/4)",
  "coverage (2/4)",
  "coverage (3/4)",
  "coverage (4/4)",
  "dialyzer",
  "layout release smoke",
  "lint",
  "streamdeck",
  "test",
  "workflow security"
]'

if ! jq -e --argjson required_checks "$required_checks" '
  [.rules[] | select(.type == "required_status_checks") | .parameters] |
  length == 1 and
  .[0].do_not_enforce_on_create == false and
  .[0].strict_required_status_checks_policy == false and
  (.[0].required_status_checks | map(.context) | sort) == ($required_checks | sort) and
  (.[0].required_status_checks | all(.integration_id == 15368))
' >/dev/null <<<"$ruleset"; then
  echo "ruleset must require every blocking GitHub Actions status check" >&2
  exit 1
fi
