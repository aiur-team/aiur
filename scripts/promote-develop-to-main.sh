#!/usr/bin/env bash
# Promote develop to main through the human-only merge gate.
#
# With * @its-everdred @its-applekid as the only CODEOWNERS and the
# human-only-merge-gate requiring CODEOWNER review, last-push approval, and
# one approving review, the human operator cannot approve a promotion PR they
# authored or last pushed (#1437). The satisfiable path, proven by #1696, is
# to author the develop -> main promotion as the agent account and have the
# human approve the exact head and merge.
#
# This script reuses or creates the promotion PR as the agent account (the
# create/reuse path refuses a human token) and verifies the gate is
# satisfiable before printing next steps. --verify checks an existing PR's
# author, base, head, and approval with any token. It never disables, weakens,
# or toggles the ruleset.
#
# usage:
#   scripts/promote-develop-to-main.sh [owner/repo]
#   scripts/promote-develop-to-main.sh --verify <pr-number> [owner/repo]
#
# Environment:
#   GITHUB_TOKEN / GH_TOKEN   token resolving to the agent account (the PR
#                             author) for the create/reuse path; a human
#                             token is refused there.
#   BOT_ACCOUNT               agent account that must author the PR (default
#                             its-applekid).
#   GITHUB_REPOSITORY         owner/repo (inferred from the remote when unset).
set -euo pipefail

usage() {
  echo "usage: scripts/promote-develop-to-main.sh [--verify <pr-number>] [owner/repo]" >&2
  exit 64
}

verify_mode=""
pr_number=""
case "${1:-}" in
  --verify)
    verify_mode=1
    pr_number="${2:-}"
    [[ "$pr_number" =~ ^[0-9]+$ ]] || usage
    shift 2
    ;;
  "")
    ;;
  -*)
    usage
    ;;
  *)
    ;;
esac

repo="${1:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$repo" ]]; then
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi

bot="${BOT_ACCOUNT:-its-applekid}"
base_branch="main"
head_branch="develop"

# Print one "gate condition" line. Callers track failures themselves; this
# helper only renders the condition and its current detail.
gate_ok() {
  local ok="$1"
  local label="$2"
  local detail="$3"
  if [[ "$ok" == "1" ]]; then
    printf '  ok: %s (%s)\n' "$label" "$detail"
  else
    printf '  missing: %s (%s)\n' "$label" "$detail" >&2
  fi
}

# Verify an existing promotion PR. Exits non-zero when it is not ready to
# merge through the gate on the exact head. Prints a stable, greppable
# summary of every gate condition.
verify_promotion_pr() {
  local pr="$1"
  local state
  state="$(gh pr view "$pr" --repo "$repo" \
    --json baseRefName,headRefName,author,state,isDraft,reviewDecision,mergeStateStatus,statusCheckRollup,url)"

  local base head author state_open draft decision merge_status url
  base="$(jq -r '.baseRefName' <<<"$state")"
  head="$(jq -r '.headRefName' <<<"$state")"
  author="$(jq -r '.author.login' <<<"$state")"
  state_open="$(jq -r '.state' <<<"$state")"
  draft="$(jq -r '.isDraft' <<<"$state")"
  decision="$(jq -r '.reviewDecision // "NONE"' <<<"$state")"
  merge_status="$(jq -r '.mergeStateStatus // "UNKNOWN"' <<<"$state")"
  url="$(jq -r '.url' <<<"$state")"

  echo "promotion PR #$pr: $url"
  echo "  base=$base head=$head author=$author state=$state_open draft=$draft"
  echo "  reviewDecision=$decision mergeStateStatus=$merge_status"

  local failures=0

  if [[ "$base" == "$base_branch" ]]; then
    gate_ok 1 "base is $base_branch" "baseRefName=$base"
  else
    gate_ok 0 "base is $base_branch" "baseRefName=$base"
    failures=1
  fi

  if [[ "$head" == "$head_branch" ]]; then
    gate_ok 1 "head is $head_branch" "headRefName=$head"
  else
    gate_ok 0 "head is $head_branch" "headRefName=$head"
    failures=1
  fi

  if [[ "$author" == "$bot" ]]; then
    gate_ok 1 "authored by $bot" "author=$author"
  else
    gate_ok 0 "authored by $bot" "author=$author"
    failures=1
  fi

  if [[ "$state_open" == "OPEN" && "$draft" == "false" ]]; then
    gate_ok 1 "open and not draft" "state=$state_open draft=$draft"
  else
    gate_ok 0 "open and not draft" "state=$state_open draft=$draft"
    failures=1
  fi

  if [[ "$decision" == "APPROVED" ]]; then
    gate_ok 1 "human approval on exact head" "reviewDecision=$decision"
  else
    gate_ok 0 "human approval on exact head" "reviewDecision=$decision"
    failures=1
  fi

  # The "quarantined tests (non-blocking)" check is expected to fail and must
  # not block; every other failing check is a required-check failure.
  local failing failing_required
  failing="$(jq -r '[.statusCheckRollup[] | select(.conclusion == "FAILURE" or .conclusion == "TIMED_OUT" or .conclusion == "ACTION_REQUIRED" or .conclusion == "CANCELLED") | .name] | if length == 0 then "" else join(", ") end' <<<"$state")"
  failing_required="$(jq -r --arg nonblocking 'quarantined tests (non-blocking)' '
    [.statusCheckRollup[]
      | select(.conclusion == "FAILURE" or .conclusion == "TIMED_OUT" or .conclusion == "ACTION_REQUIRED" or .conclusion == "CANCELLED")
      | .name
      | select(. != $nonblocking)]
    | if length == 0 then "" else join(", ") end
  ' <<<"$state")"

  # UNSTABLE can be caused solely by the non-blocking quarantined-tests
  # failure, so a required-check failure is what makes the PR unmergeable.
  case "$merge_status" in
    CLEAN)
      gate_ok 1 "mergeable" "mergeStateStatus=$merge_status"
      ;;
    UNSTABLE)
      if [[ -n "$failing_required" ]]; then
        gate_ok 0 "mergeable" "mergeStateStatus=$merge_status (required checks failing)"
        failures=1
      else
        echo "  warning: mergeStateStatus=UNSTABLE but only non-blocking checks are failing" >&2
        gate_ok 1 "mergeable" "mergeStateStatus=$merge_status (only non-blocking checks failing)"
      fi
      ;;
    PENDING)
      gate_ok 0 "mergeable" "mergeStateStatus=$merge_status (checks pending)"
      failures=1
      ;;
    *)
      gate_ok 0 "mergeable" "mergeStateStatus=$merge_status"
      failures=1
      ;;
  esac

  if [[ -n "$failing" ]]; then
    echo "  checks failing: $failing" >&2
  fi
  if [[ -n "$failing_required" ]]; then
    echo "  required checks failing: $failing_required" >&2
    failures=1
  fi

  if [[ $failures -eq 0 ]]; then
    echo "  READY: approval is current on the exact head; merge through the queue."
    return 0
  fi

  echo "  NOT READY: resolve the missing conditions above, then re-run --verify." >&2
  return 1
}

if [[ -n "$verify_mode" ]]; then
  verify_promotion_pr "$pr_number"
  exit $?
fi

# The promotion PR must be authored by the agent account so the human — the
# only other CODEOWNER — can approve it. A human-authored promotion deadlocks:
# the human cannot approve their own PR, and the only remaining code owner is
# the bot, which must never approve a human-only merge. --verify above instead
# checks the existing PR's author, so the human operator can run it with any
# token before merging.
token_user="$(gh api user --jq .login)"
if [[ "$token_user" != "$bot" ]]; then
  echo "promotion PR must be authored by $bot (the agent account) so the human can approve it; GITHUB_TOKEN resolves to $token_user" >&2
  exit 1
fi

ahead="$(gh api "repos/$repo/compare/$base_branch...$head_branch" --jq .ahead_by)"
if [[ "$ahead" -le 0 ]]; then
  echo "nothing to promote: $head_branch is not ahead of $base_branch" >&2
  exit 0
fi

existing="$(gh pr list --repo "$repo" --base "$base_branch" --head "$head_branch" --state open --json number --jq '.[0].number // empty')"
if [[ -n "$existing" ]]; then
  echo "reusing existing promotion PR #$existing ($head_branch -> $base_branch)"
  verify_promotion_pr "$existing"
  status=$?
  if [[ $status -ne 0 ]]; then
    echo "promotion PR #$existing is not yet mergeable; complete the missing conditions above." >&2
    exit 1
  fi
  exit 0
fi

created="$(gh pr create --repo "$repo" --base "$base_branch" --head "$head_branch" \
  --title "Promote $head_branch to $base_branch ($ahead commits)" \
  --body "Release promotion of \`$head_branch\` into \`$base_branch\` ($ahead commits).

Promotion PRs are authored by the agent account so the human operator can
approve the exact head and merge through the human-only merge gate (#1437).
See docs/security/develop-to-main-promotion.md." \
  --json number,url,baseRefName,headRefName,author)"

number="$(jq -r '.number' <<<"$created")"
url="$(jq -r '.url' <<<"$created")"
created_base="$(jq -r '.baseRefName' <<<"$created")"
created_head="$(jq -r '.headRefName' <<<"$created")"
created_author="$(jq -r '.author.login' <<<"$created")"
echo "created promotion PR #$number ($created_head -> $created_base, authored by $created_author): $url"

echo
echo "next steps:"
echo "  1. $bot pushes no further commits to $head_branch after the PR is opened (a push dismisses the human's approval)."
echo "  2. the human operator approves the exact head of PR #$number."
echo "  3. confirm the blocking CI checks are green, then merge PR #$number through the merge queue."
echo "  4. re-check readiness any time with: scripts/promote-develop-to-main.sh --verify $number"
