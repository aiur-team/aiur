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
  .enforcement == "active" and
  (.bypass_actors == null or .bypass_actors == []) and
  (.conditions.ref_name.include | index("refs/heads/main")) and
  (.conditions.ref_name.include | index("refs/heads/develop")) and
  ((.conditions.ref_name.exclude // []) | map(select(. == "refs/heads/main" or . == "refs/heads/develop")) | length == 0)
' >/dev/null <<<"$ruleset"; then
  echo "ruleset must actively protect main and develop with no bypass actors" >&2
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
