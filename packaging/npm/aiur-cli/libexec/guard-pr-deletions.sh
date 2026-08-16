#!/usr/bin/env bash
set -euo pipefail

readonly deletion_threshold=50
base_branch="${1:-${AIUR_BASE_BRANCH:-}}"

if [[ -z "$base_branch" ]]; then
  echo "guard-pr-deletions: base branch is required (argument or AIUR_BASE_BRANCH)" >&2
  exit 2
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "guard-pr-deletions: tracked changes must be committed before checking PR deletions" >&2
  exit 2
fi

if ! git fetch --quiet --no-tags origin "refs/heads/$base_branch"; then
  echo "guard-pr-deletions: could not fetch origin/$base_branch; refusing to use a stale base" >&2
  exit 2
fi

if ! base_sha="$(git rev-parse --verify 'FETCH_HEAD^{commit}')"; then
  echo "guard-pr-deletions: fetched base commit is unavailable" >&2
  exit 2
fi

scratch_dir="$(mktemp -d)"
trap 'rm -rf "$scratch_dir"' EXIT

git diff --diff-filter=D --name-only "$base_sha"..HEAD | LC_ALL=C sort -u >"$scratch_dir/deleted"
deleted_count="$(wc -l <"$scratch_dir/deleted" | tr -d ' ')"

if ((deleted_count <= deletion_threshold)); then
  echo "guard-pr-deletions: $deleted_count untouched file deletions (limit: $deletion_threshold)"
  exit 0
fi

branch_start="${AIUR_BRANCH_START_SHA:-}"

if [[ -z "$branch_start" ]] && git rev-parse --verify --quiet 'refs/aiur/branch-start^{commit}' >/dev/null; then
  branch_start="$(git rev-parse --verify 'refs/aiur/branch-start^{commit}')"
fi

if [[ -z "$branch_start" ]]; then
  echo "guard-pr-deletions: refusing $deleted_count deletions because the workspace branch-start ref is unavailable" >&2
  exit 1
fi

if ! git merge-base --is-ancestor "$branch_start" HEAD; then
  echo "guard-pr-deletions: workspace branch-start $branch_start is not an ancestor of HEAD" >&2
  exit 2
fi

git log --format= --name-only "$branch_start"..HEAD | sed '/^$/d' | LC_ALL=C sort -u >"$scratch_dir/touched"
# Both inputs are sorted with LC_ALL=C, so comm must compare with the same
# collation. Under a UTF-8 locale comm reads C-sorted input as unsorted (any
# mix of upper- and lower-case initial paths, e.g. README.md beside src/...)
# and its output on unsorted input is undefined -- it can drop rows, which
# would make this guard under-count untouched deletions and fail open.
LC_ALL=C comm -23 "$scratch_dir/deleted" "$scratch_dir/touched" >"$scratch_dir/untouched-deletions"

untouched_count="$(wc -l <"$scratch_dir/untouched-deletions" | tr -d ' ')"

if ((untouched_count > deletion_threshold)); then
  echo "guard-pr-deletions: refusing PR with $untouched_count untouched file deletions (limit: $deletion_threshold)" >&2
  sed -n '1,20p' "$scratch_dir/untouched-deletions" >&2
  exit 1
fi

echo "guard-pr-deletions: $untouched_count untouched file deletions (limit: $deletion_threshold)"
