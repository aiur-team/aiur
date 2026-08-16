#!/usr/bin/env bash
set -euo pipefail

# Read-only CI drift check for the human-only merge gate.
#
# The admin verifier (verify-human-only-merge-ruleset.sh) audits the full
# declaration, including bypass_actors, which GitHub hides from read-only
# tokens. It is deliberately not run in CI: placing a ruleset Administration
# credential in Actions would expand the CI trust boundary.
#
# This script is the CI counterpart. It runs with a read-only GITHUB_TOKEN and
# verifies every ruleset property a read-only token can see, so a regressed
# gate -- a ruleset that stops actively protecting main, drops the
# pull-request approval rule, or loses or weakens the required_status_checks
# rule -- fails CI visibly instead of silently.
#
# One property is deliberately NOT asserted here and stays in the admin
# verifier's domain:
#   - bypass_actors: GitHub returns null without ruleset write visibility, so a
#     read-only token cannot prove the live ruleset has no bypass.

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
  [.rules[] | select(.type == "pull_request") | .parameters] |
  length == 1 and
  .[0].required_approving_review_count >= 1 and
  .[0].dismiss_stale_reviews_on_push == true
' >/dev/null <<<"$ruleset"; then
  echo "ruleset must require one approval and dismiss stale reviews" >&2
  exit 1
fi

# The expected required_status_checks parameters come from the reviewed
# declaration (docs/security/human-only-merge-ruleset.json), the single source
# of truth, so the drift check stays in sync with the admin verifier when the
# blocking check set changes. A declaration that drops the rule produces null
# expectations, which fail against any protected live ruleset (fail-closed).
expected_checks="$(jq -c '
  [.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context]
' "$declaration")"
expected_strict="$(jq -c '
  [.rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy][0]
' "$declaration")"
expected_do_not_enforce="$(jq -c '
  [.rules[] | select(.type == "required_status_checks") | .parameters.do_not_enforce_on_create][0]
' "$declaration")"

if ! jq -e \
  --argjson expected_checks "$expected_checks" \
  --argjson expected_strict "$expected_strict" \
  --argjson expected_do_not_enforce "$expected_do_not_enforce" '
  [.rules[] | select(.type == "required_status_checks") | .parameters] |
  length == 1 and
  .[0].do_not_enforce_on_create == $expected_do_not_enforce and
  .[0].strict_required_status_checks_policy == $expected_strict and
  (.[0].required_status_checks | map(.context) | sort) == ($expected_checks | sort) and
  (.[0].required_status_checks | all(.integration_id == 15368))
' >/dev/null <<<"$ruleset"; then
  echo "ruleset must require every blocking GitHub Actions status check from the declaration" >&2
  exit 1
fi

echo "ruleset drift check passed: $name matches the declaration for all read-only-visible properties"
echo "note: bypass_actors is verified by the admin verifier (scripts/verify-human-only-merge-ruleset.sh), not by this read-only check"
