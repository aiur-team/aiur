#!/usr/bin/env bash
# Refuse to merge a dependent PR before its blockers (BQ-G3-3).
# Exit 0 = PASS, 2 = REFUSE, 3 = UNDECIDED (also a refusal). No override flag:
# remove the blocked_by edge to escape.
set -euo pipefail

usage() {
  echo "usage: check-stack-order.sh <pr-number> [owner/repo] [--base <branch>] [--repo-dir <clone>] [--approved <sha>]" >&2
  exit 64
}

pr="" repo="" base="" repo_dir="" approved=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --base) [[ "$#" -ge 2 ]] || usage; base="$2"; shift 2 ;;
    --repo-dir) [[ "$#" -ge 2 ]] || usage; repo_dir="$2"; shift 2 ;;
    --approved) [[ "$#" -ge 2 ]] || usage; approved="$2"; shift 2 ;;
    -*) usage ;;
    *)
      if [[ -z "$pr" ]]; then pr="$1"; elif [[ -z "$repo" ]]; then repo="$1"; else usage; fi
      shift
      ;;
  esac
done
[[ "$pr" =~ ^[0-9]+$ ]] || usage

# Operator gh with the tracker tokens removed, as diagnose-pr-merge-gate.sh does.
operator_gh() { env -u GITHUB_TOKEN -u GH_TOKEN gh "$@"; }

undecided() {
  echo "UNDECIDED $1"
  exit 3
}

refused=0
refuse() {
  echo "REFUSE $1"
  refused=1
}

repo="${repo:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$repo" ]]; then
  repo="$(operator_gh repo view --json nameWithOwner --jq .nameWithOwner)" || undecided "repo-view"
fi
if [[ -z "$base" ]]; then
  base="$(operator_gh repo view "$repo" --json defaultBranchRef --jq .defaultBranchRef.name)" || undecided "repo-default-branch"
fi
[[ -n "$base" ]] || undecided "integration-branch"

pr_json="$(operator_gh pr view "$pr" --repo "$repo" --json baseRefName,headRefName,headRefOid)" || undecided "pr-view"
pr_base="$(jq -er '.baseRefName' <<<"$pr_json")" || undecided "pr-view"
pr_head_ref="$(jq -er '.headRefName' <<<"$pr_json")" || undecided "pr-view"
pr_head="$(jq -er '.headRefOid' <<<"$pr_json")" || undecided "pr-view"

[[ "$pr_base" == "$base" ]] || refuse "base PR #$pr targets '$pr_base', not the integration branch '$base'"

# contained <merge-sha>: is the blocker's merge commit an ancestor of the PR head?
# Returns 0 contained, 1 not contained, 2 could not tell.
contained() {
  if [[ -n "$repo_dir" ]]; then
    git -C "$repo_dir" cat-file -e "$1^{commit}" 2>/dev/null || return 2
    git -C "$repo_dir" cat-file -e "$pr_head^{commit}" 2>/dev/null || return 2
    git -C "$repo_dir" merge-base --is-ancestor "$1" "$pr_head" && return 0
    return 1
  fi
  local status
  status="$(operator_gh api "repos/$repo/compare/$1...$pr_head" | jq -er .status)" || return 2
  [[ "$status" == ahead || "$status" == identical ]] && return 0
  return 1
}

check_blocker() {
  local b="$1" state="$2" reason="$3" prs open_n merged_n sha rc=0
  case "$reason" in
    not_planned | duplicate)
      refuse "blocker #$b closed $reason; remove the blocked_by edge if it no longer applies"
      return
      ;;
  esac
  prs="$(operator_gh pr list --repo "$repo" --state all --search "head:aiur/$b" \
    --json number,state,headRefName,mergeCommit --limit 30)" || undecided "pr-list #$b"
  prs="$(jq -c --arg b "$b" '[.[] | select(.headRefName == "aiur/\($b)" or (.headRefName | startswith("aiur/\($b)-")))]' <<<"$prs")" \
    || undecided "pr-list #$b"
  merged_n="$(jq '[.[] | select(.state == "MERGED")] | length' <<<"$prs")"
  open_n="$(jq '[.[] | select(.state != "MERGED")] | length' <<<"$prs")"
  if [[ "$merged_n" -gt 1 ]]; then
    refuse "ambiguous blocker #$b has $merged_n merged PRs"
  elif [[ "$merged_n" -eq 1 ]]; then
    sha="$(jq -r '.[] | select(.state == "MERGED") | .mergeCommit.oid // empty' <<<"$prs")"
    [[ -n "$sha" ]] || undecided "merge-commit #$b"
    contained "$sha" || rc=$?
    case "$rc" in
      0) ;;
      1) refuse "restack-needed #$b merge commit $sha is not in PR head $pr_head" ;;
      *) undecided "containment #$b" ;;
    esac
  elif [[ "$state" != closed || "$reason" != completed ]]; then
    refuse "blocker #$b is not landed (state $state)"
  elif [[ "$open_n" -gt 0 ]]; then
    refuse "ambiguous blocker #$b is closed completed but has a PR that is not merged"
  fi
}

if [[ "$pr_head_ref" =~ ^aiur/([0-9]+)(-.*)?$ ]]; then
  ticket="${BASH_REMATCH[1]}"
  blockers="$(operator_gh api "repos/$repo/issues/$ticket/dependencies/blocked_by?per_page=100")" || undecided "blocked_by #$ticket"
  jq -e 'type == "array"' <<<"$blockers" >/dev/null || undecided "blocked_by #$ticket"
  while IFS=$'\t' read -r b state reason; do
    [[ -n "$b" ]] && check_blocker "$b" "$state" "$reason"
  done < <(jq -r '.[] | [.number, .state, (.state_reason // "")] | @tsv' <<<"$blockers")
fi

# Re-approval aid: true only when every commit after the approved head is an Aiur
# restack commit whose tree is recomputed exactly. Output only; it never changes
# the gate's exit code.
restack_only() {
  [[ -n "$approved" && -n "$repo_dir" ]] || return 1
  local g=(git -C "$repo_dir") expect="$approved" c parents p1 p2 trailer blocker_n f tbase lbase tree msg n=0
  "${g[@]}" merge-base --is-ancestor "$approved" "$pr_head" 2>/dev/null || return 1
  while read -r c; do
    n=$((n + 1))
    read -r -a parents < <("${g[@]}" log -1 --format=%P "$c")
    [[ "${#parents[@]}" -eq 2 && "${parents[0]}" == "$expect" ]] || return 1
    p1="${parents[0]}" p2="${parents[1]}"
    msg="$("${g[@]}" log -1 --format=%B "$c")"
    trailer="$(grep -E '^Aiur-Restack: blocker=#[0-9]+ blocker-head=[0-9a-f]{40} base=[0-9a-f]{40}$' <<<"$msg")" || return 1
    [[ "$(wc -l <<<"$trailer")" -eq 1 ]] || return 1
    blocker_n="$(sed -E 's/.*blocker=#([0-9]+).*/\1/' <<<"$trailer")"
    f="$(sed -E 's/.*blocker-head=([0-9a-f]{40}).*/\1/' <<<"$trailer")"
    tbase="$(sed -E 's/.*base=([0-9a-f]{40})$/\1/' <<<"$trailer")"
    [[ "$tbase" == "$p2" ]] || return 1
    # The trailer's blocker head must be that PR's real head, and its base must be
    # integration history, so a forged trailer cannot choose its own merge inputs.
    [[ "$(operator_gh pr view "$blocker_n" --repo "$repo" --json headRefOid --jq .headRefOid 2>/dev/null)" == "$f" ]] || return 1
    "${g[@]}" merge-base --is-ancestor "$p2" "origin/$base" 2>/dev/null || return 1
    lbase="$("${g[@]}" merge-base "$p1" "$f")" || return 1
    tree="$("${g[@]}" merge-tree --write-tree --merge-base="$lbase" "$p2" "$p1")" || return 1
    [[ "$tree" == "$("${g[@]}" rev-parse "$c^{tree}")" ]] || return 1
    expect="$c"
  done < <("${g[@]}" rev-list --first-parent --reverse "$approved..$pr_head")
  [[ "$n" -gt 0 && "$expect" == "$pr_head" ]]
}

if [[ -n "$approved" ]] && restack_only; then
  echo "RESTACK-ONLY $approved..$pr_head"
fi

if [[ "$refused" -eq 1 ]]; then
  exit 2
fi
echo "PASS"
