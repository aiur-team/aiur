#!/usr/bin/env bash
set -euo pipefail

repo="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
config="${1:-docs/security/human-only-merge-ruleset.json}"
name="$(jq -r '.name' "$config")"

ruleset_id="$(gh api "repos/$repo/rulesets" --paginate | jq -r --arg name "$name" '.[] | select(.name == $name) | .id')"

if [[ -n "$ruleset_id" ]]; then
  gh api --method PUT "repos/$repo/rulesets/$ruleset_id" --input "$config"
else
  gh api --method POST "repos/$repo/rulesets" --input "$config"
fi
