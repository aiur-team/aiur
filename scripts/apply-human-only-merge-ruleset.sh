#!/usr/bin/env bash
set -euo pipefail

repo="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -eq 0 ]]; then
  set -- "$root/docs/security/human-only-merge-ruleset.json" "$root/docs/security/main-merge-queue-ruleset.json"
fi

rulesets="$(gh api "repos/$repo/rulesets" --paginate)"

for config in "$@"; do
  name="$(jq -r '.name' "$config")"
  ruleset_id="$(jq -r --arg name "$name" '.[] | select(.name == $name) | .id' <<<"$rulesets")"

  if [[ -n "$ruleset_id" ]]; then
    gh api --method PUT "repos/$repo/rulesets/$ruleset_id" --input "$config"
  else
    gh api --method POST "repos/$repo/rulesets" --input "$config"
  fi
done
