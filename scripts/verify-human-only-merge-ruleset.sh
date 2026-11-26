#!/usr/bin/env bash
set -euo pipefail

repo="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
name="human-only-merge-gate"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
declaration="$root/docs/security/human-only-merge-ruleset.json"

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
  (.conditions.ref_name.include | index("refs/heads/main"))
' >/dev/null <<<"$ruleset"; then
  echo "ruleset must target branches and actively protect main" >&2
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
  (.bypass_actors | length == 1) and
  .bypass_actors[0].actor_id == 1020682 and
  .bypass_actors[0].actor_type == "User" and
  .bypass_actors[0].bypass_mode == "pull_request"
' >/dev/null <<<"$ruleset"; then
  echo "ruleset bypass_actors must be exactly its-everdred (pull_request bypass)" >&2
  exit 1
fi

required_checks='["ci gate"]'

# ponytail: accept the exact legacy full gate during rollout; remove after every open PR has ci gate.
legacy_checks="$(cat "$root/docs/security/ci-legacy-required-checks.json")"
if ! jq -e --argjson required_checks "$required_checks" --argjson legacy_checks "$legacy_checks" '
  [.rules[] | select(.type == "required_status_checks") | .parameters] |
  length == 1 and
  .[0].do_not_enforce_on_create == false and
  .[0].strict_required_status_checks_policy == false and
  ((.[0].required_status_checks | map(.context) | sort) == ($required_checks | sort) or
   (.[0].required_status_checks | map(.context) | sort) == ($legacy_checks | sort)) and
  (.[0].required_status_checks | all(.integration_id == 15368))
' >/dev/null <<<"$ruleset"; then
  echo "ruleset must require every blocking GitHub Actions status check" >&2
  exit 1
fi
