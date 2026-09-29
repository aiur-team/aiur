#!/usr/bin/env bash
set -euo pipefail

# CI has no trustworthy workspace branch-start ref. Compare the PR head with
# the merge base so files added only to the target branch are not miscounted.
readonly deletion_threshold=50
base_sha="${1:-}"
head_sha="${2:-}"

if [[ -z "$base_sha" || -z "$head_sha" ]]; then
  echo "check-pr-deletions: base and head commit SHAs are required" >&2
  exit 2
fi

for sha in "$base_sha" "$head_sha"; do
  if ! git rev-parse --verify --quiet "$sha^{commit}" >/dev/null; then
    echo "check-pr-deletions: commit $sha is unavailable; fetch complete PR history" >&2
    exit 2
  fi
done

merge_base="$(git merge-base "$base_sha" "$head_sha")"
if [[ -z "$merge_base" ]]; then
  echo "check-pr-deletions: base and head have no common ancestor" >&2
  exit 2
fi

deleted_count="$(git diff --name-only --diff-filter=D -z "$merge_base" "$head_sha" | python3 -c 'import sys; print(sys.stdin.buffer.read().count(b"\0"))')"

if ((deleted_count > deletion_threshold)); then
  echo "check-pr-deletions: refusing PR with $deleted_count deleted files (limit: $deletion_threshold)" >&2
  git diff --name-only --diff-filter=D "$merge_base" "$head_sha" | sed -n '1,20p' >&2
  exit 1
fi

echo "check-pr-deletions: $deleted_count deleted files (limit: $deletion_threshold)"
