#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: diagnose-pr-merge-gate.sh <pr-number> [owner/repo]" >&2
  exit 64
}

[[ "$#" -ge 1 && "$#" -le 2 ]] || usage
pr="$1"
[[ "$pr" =~ ^[0-9]+$ ]] || usage

# Ruleset suites require repository Administration: read. Keep that authority
# out of the daemon/agent credential: prefer the operator-only readiness token,
# otherwise use the operator's gh keyring with tracker-token env overrides
# removed. Every call in this script is read-only.
operator_gh() {
  if [[ -n "${AIUR_CI_READINESS_TOKEN:-}" ]]; then
    env -u GITHUB_TOKEN GH_TOKEN="$AIUR_CI_READINESS_TOKEN" gh "$@"
  else
    env -u GITHUB_TOKEN -u GH_TOKEN gh "$@"
  fi
}

repo="${2:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$repo" ]]; then
  repo="$(operator_gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi

pr_state="$(operator_gh pr view "$pr" --repo "$repo" --json baseRefName,potentialMergeCommit)"
base="$(jq -r '.baseRefName // empty' <<<"$pr_state")"
if [[ -z "$base" || "$base" == "null" ]]; then
  echo "could not resolve the base branch for PR #$pr" >&2
  exit 1
fi
merge_sha="$(jq -r '.potentialMergeCommit.oid // empty' <<<"$pr_state")"

time_period="${AIUR_RULE_SUITE_TIME_PERIOD:-day}"
case "$time_period" in
  hour | day | week | month) ;;
  *)
    echo "AIUR_RULE_SUITE_TIME_PERIOD must be hour, day, week, or month" >&2
    exit 64
    ;;
esac

suites="$(
  operator_gh api \
    "repos/$repo/rulesets/rule-suites?ref=refs/heads/$base&time_period=$time_period&rule_suite_result=fail&per_page=100" \
    --jq '.[] | [.id, .after_sha] | @tsv'
)"

diagnose_suite() {
  local suite_id="$1"
  local after_sha="$2"
  local verify_headline="$3"

  if [[ "$verify_headline" == true ]]; then
    local commit headline
    if ! commit="$(operator_gh api "repos/$repo/git/commits/$after_sha" 2>/dev/null)"; then
      return 1
    fi

    headline="$(jq -r '.message | split("\n")[0]' <<<"$commit")"
    if [[ "$headline" != *"(#$pr)"* && "$headline" != "Merge pull request #$pr "* ]]; then
      return 1
    fi
  fi

  local suite details
  suite="$(operator_gh api "repos/$repo/rulesets/rule-suites/$suite_id")"
  details="$(
    jq -r '
      .rule_evaluations[]
      | select(.result == "fail" and (.enforcement // "active") == "active")
      | .details // empty
    ' <<<"$suite" | awk 'NF && !seen[$0]++'
  )"

  if [[ -n "$details" ]]; then
    printf '%s\n' "$details"
    return 0
  fi

  return 1
}

# The ordinary refusal evaluates the PR's current generated merge commit. That
# SHA is already present in list summaries, so the normal path needs one detail
# request instead of scanning every failed suite and commit in the time window.
while IFS=$'\t' read -r suite_id after_sha; do
  [[ -n "$merge_sha" && "$after_sha" == "$merge_sha" ]] || continue
  if diagnose_suite "$suite_id" "$after_sha" false; then exit 0; fi
done <<<"$suites"

# If the base moved after the refusal, GitHub may already expose a new generated
# merge SHA. Retain historical correlation within the 100 most recent failures
# by merge-commit headline, fetching full rule evaluations only after its
# summary SHA matches this PR. The fixed candidate bound prevents an old window
# from turning one diagnostic into an unbounded series of API requests.
while IFS=$'\t' read -r suite_id after_sha; do
  [[ -n "$suite_id" && -n "$after_sha" && "$after_sha" != "$merge_sha" ]] || continue
  if diagnose_suite "$suite_id" "$after_sha" true; then exit 0; fi
done <<<"$suites"

echo "no recent failed ruleset evaluation could be matched to PR #$pr" >&2
exit 2
