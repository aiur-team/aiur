#!/usr/bin/env bash
set -euo pipefail

# Run only from a pull_request_target checkout pinned to the protected base.
# The PR ref is fetched as Git data; no file from it is executed or sourced.
readonly context='aiur/trusted-pr-deletions'
mode="${1:-}"
repo="${GITHUB_REPOSITORY:-}"
base_sha="${2:-}"
head_sha="${3:-}"
pr_number="${4:-}"

if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ||
      ! "$base_sha" =~ ^[0-9a-fA-F]{40}$ ||
      ! "$head_sha" =~ ^[0-9a-fA-F]{40}$ ||
      ! "$pr_number" =~ ^[0-9]+$ ]]; then
  echo 'trusted deletion gate: invalid repository, SHA, or PR number' >&2
  exit 2
fi

post_status() {
  local state="$1"
  local description="$2"
  gh api --method POST "repos/$repo/statuses/$head_sha" \
    -f "state=$state" -f "context=$context" -f "description=$description" >/dev/null
}

check_deletions() {
  local fetched_head merge_base deleted_count

  if ! git cat-file -e "$base_sha^{commit}"; then
    echo 'trusted deletion gate: pinned base commit unavailable' >&2
    return 2
  fi

  if ! git fetch --no-tags --quiet origin "refs/pull/$pr_number/head"; then
    echo 'trusted deletion gate: PR head ref unavailable' >&2
    return 2
  fi

  fetched_head="$(git rev-parse 'FETCH_HEAD^{commit}')"
  if [[ "$fetched_head" != "$head_sha" ]]; then
    echo 'trusted deletion gate: PR head moved since event delivery' >&2
    return 2
  fi

  if ! merge_base="$(git merge-base "$base_sha" "$head_sha")"; then
    echo 'trusted deletion gate: base and PR head have no common ancestor' >&2
    return 2
  fi

  deleted_count="$(git diff --name-only --diff-filter=D -z "$merge_base" "$head_sha" | python3 -c 'import sys; print(sys.stdin.buffer.read().count(b"\0"))')"
  if ((deleted_count > 50)); then
    echo "trusted deletion gate: refusing $deleted_count deleted files (limit: 50)" >&2
    return 1
  fi

  echo "trusted deletion gate: $deleted_count deleted files (limit: 50)"
}

case "$mode" in
  --check)
    check_deletions
    ;;
  --publish)
    if [[ -z "${GH_TOKEN:-}" ]]; then
      echo 'trusted deletion gate: dedicated App token unavailable' >&2
      exit 2
    fi
    post_status pending 'Checking PR file deletions from protected base'
    if bash "$0" --check "$base_sha" "$head_sha" "$pr_number"; then
      post_status success 'PR deletion count is within the 50-file limit'
    else
      result="$?"
      if [[ "$result" -eq 1 ]]; then
        post_status failure 'PR deletes more than 50 files'
      else
        post_status error 'PR deletion check could not complete'
      fi
      exit "$result"
    fi
    ;;
  *)
    echo "usage: $0 --publish|--check BASE_SHA HEAD_SHA PR_NUMBER" >&2
    exit 2
    ;;
esac
