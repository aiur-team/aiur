#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

required_job="$(sed -n '/^  workflow-security:$/,/^  merge-ruleset-drift:$/p' "$root/.github/workflows/ci.yml")"
grep -q 'run: bash scripts/check-pr-deletions.sh' <<<"$required_job"
grep -q 'fetch-depth: 0' <<<"$required_job"

git init --bare -q "$tmp/origin.git"
git init -q -b seed "$tmp/work"
cd "$tmp/work"
git config user.name "Aiur Test"
git config user.email "aiur@example.test"
git remote add origin "$tmp/origin.git"
printf 'seed\n' >README.md
git add README.md
git commit -qm seed
seed="$(git rev-parse HEAD)"

git checkout -qb develop
for number in $(seq 1 51); do
  printf 'base\n' >"base-$number.txt"
done
git add .
git commit -qm 'add base files'
git push -q origin develop
base="$(git rev-parse HEAD)"

git checkout -qb feature "$seed"
git update-ref refs/aiur/branch-start "$seed"
printf 'feature\n' >feature.txt
git add feature.txt
git commit -qm feature
head="$(git rev-parse HEAD)"

# This is the observed failure shape: the local guard refuses, tail succeeds,
# and the worker's shell then pushes the branch anyway.
set +o pipefail
"$root/scripts/guard-pr-deletions" develop 2>&1 | tail -n 3 >"$tmp/piped-guard-output" && git push -q origin feature
set -o pipefail
test "$(git --git-dir="$tmp/origin.git" rev-parse refs/heads/feature)" = "$head"

if "$root/scripts/check-pr-deletions.sh" "$base" "$head" >"$tmp/refusal" 2>&1; then
  echo "server-side check accepted the 51 deleted files after a piped guard refusal" >&2
  exit 1
fi
grep -q 'refusing PR with 51 deleted files' "$tmp/refusal"

# The threshold itself is intentional: exactly 50 net deletions are allowed.
git checkout -qb feature-50 "$seed"
git checkout "$base" -- base-51.txt
git add base-51.txt
git commit -qm 'retain one base file'
"$root/scripts/check-pr-deletions.sh" "$base" HEAD >"$tmp/allowed"
grep -q '50 deleted files' "$tmp/allowed"

echo 'PR deletion check rejects a piped-guard push and allows the threshold'
