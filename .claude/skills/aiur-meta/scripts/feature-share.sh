#!/usr/bin/env bash
# Measure feature work among merged PRs in a time window.
# Usage: feature-share.sh [hours] (default 24)
#        feature-share.sh --self-test
set -euo pipefail

classify() {
  case "$1" in
    *build-lane:*|*feature:*|*build-order*) printf feature ;;
    *) if [[ $1 =~ ^MP-[A-Z0-9]+(-[A-Z0-9]+)* ]]; then printf feature
      elif printf '%s' "$1" | grep -qiE 'flak|test|quarantin|(^|[^a-z])ci([^a-z]|$)|merge.group|soak|coverage'; then printf test_ci
      else printf other
      fi ;;
  esac
}

window_count() {
  local prs=$1 cutoff=$2
  jq --arg cutoff "$cutoff" '[.[] | select(.mergedAt >= $cutoff)] | length' <<<"$prs"
}

issue_number() {
  jq -r '
    (try (.closingIssuesReferences | if type == "array" then .[0].number
      elif type == "object" then .nodes[0].number else null end) catch null)
    // (try ((.body // "") | capture("(?i)(closes|fixes|resolves) #(?<n>[0-9]+)").n | tonumber) catch null)
    // (try ((.headRefName // "") | capture("^aiur/(?<n>[0-9]+)").n | tonumber) catch null)
    // empty
  ' <<<"$1"
}

classify_pr() {
  local pr=$1 labels=$2 issue title
  issue=$(issue_number "$pr") || return 1
  title=$(jq -r '.title // ""' <<<"$pr") || return 1
  if [[ -n $issue ]]; then
    classify "$labels $title"
  else
    case $(classify "$title") in feature|test_ci) classify "$title" ;; *) printf unclassified ;; esac
  fi
}

if [[ ${1:-} == --self-test ]]; then
  cutoff=2026-10-22T00:00:00Z
  fixture=$(jq -cn '[range(0;30)] | ("2026-10-22T00:00:00Z" | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $cutoff | [ .[] | {mergedAt: ((if . < 20 then $cutoff + (. * 360) else $cutoff - 7200 + ((. - 20) * 720) end) | gmtime | strftime("%Y-%m-%dT%H:%M:%SZ"))} ]')
  inspected=$(window_count "$fixture" "$cutoff")
  array_pr='{"closingIssuesReferences":[{"number":5866}],"body":"","headRefName":"","title":"Repair server"}'
  nodes_pr='{"closingIssuesReferences":{"nodes":[{"number":5867}]},"body":"","headRefName":""}'
  body_pr='{"closingIssuesReferences":[],"body":"Closes #5868","headRefName":""}'
  branch_pr='{"closingIssuesReferences":[],"body":"","headRefName":"aiur/5869-example"}'
  mp_pr='{"closingIssuesReferences":[],"body":"","headRefName":"","title":"MP-E8-C11-T06 Composer: send to the agent"}'
  if [[ $inspected == 20 ]] && [[ $(issue_number "$array_pr") == 5866 ]] && \
    [[ $(issue_number "$nodes_pr") == 5867 ]] && [[ $(issue_number "$body_pr") == 5868 ]] && \
    [[ $(issue_number "$branch_pr") == 5869 ]] && [[ $(classify_pr "$array_pr" 'build-lane:home') == feature ]] && \
    [[ $(classify_pr "$mp_pr" '') == feature ]] && [[ $(classify_pr "$array_pr" '') == other ]] && \
    [[ $(classify 'build-lane:home') == feature ]] && \
    [[ $(classify 'flake') == test_ci ]] && [[ $(classify 'docs') == other ]]; then
    printf 'feature-share self-test: ok (30 merges, %s inspected)\n' "$inspected"
    exit 0
  fi
  printf 'feature-share self-test: FAILED (inspected=%s)\n' "$inspected" >&2
  exit 1
fi

hours=${1:-24}
[[ $hours =~ ^[1-9][0-9]*$ ]] || { echo 'usage: feature-share.sh [positive-hours]' >&2; exit 2; }
cutoff=$(date -u -d "$hours hours ago" +%Y-%m-%dT%H:%M:%SZ)
gh_safe() { env -u GITHUB_TOKEN -u GH_TOKEN gh "$@"; }
repo=$(gh_safe repo view --json nameWithOwner --jq .nameWithOwner)
prs='[]'
limit=100
while :; do
  prs=$(gh_safe pr list --repo "$repo" --state merged --limit "$limit" --json number,title,mergedAt,closingIssuesReferences,body,headRefName)
  oldest=$(jq -r '[.[].mergedAt] | map(select(. != null)) | min // empty' <<<"$prs")
  [[ -n $oldest && $oldest < $cutoff ]] && break
  [[ $(jq length <<<"$prs") -lt $limit ]] && break
  limit=$((limit + 100))
done

inspected=$(window_count "$prs" "$cutoff")
feature=0 test_ci=0 other=0 unclassified=0
while IFS= read -r pr; do
  if ! issue=$(issue_number "$pr"); then
    unclassified=$((unclassified + 1))
    continue
  fi
  title=$(jq -r '.title // ""' <<<"$pr") || { unclassified=$((unclassified + 1)); continue; }
  labels=''
  if [[ -n $issue ]]; then
    if ! labels=$(gh_safe issue view "$issue" --repo "$repo" --json labels --jq '[.labels[].name] | join(",")'); then
      unclassified=$((unclassified + 1))
      continue
    fi
  fi
  case $(classify_pr "$pr" "$labels") in
    feature) feature=$((feature + 1)) ;;
    test_ci) test_ci=$((test_ci + 1)) ;;
    other) other=$((other + 1)) ;;
    *) unclassified=$((unclassified + 1)) ;;
  esac
done < <(jq -c --arg cutoff "$cutoff" '.[] | select(.mergedAt >= $cutoff)' <<<"$prs")

if (( inspected == 0 )); then
  printf 'window=%sh merges=0 inspected=0 feature_share=not_captured\n' "$hours"
else
  printf 'window=%sh merges=%d inspected=%d feature=%d test_ci=%d other=%d unclassified=%d feature_share=%d%%\n' \
    "$hours" "$inspected" "$inspected" "$feature" "$test_ci" "$other" "$unclassified" "$((100 * feature / inspected))"
fi
