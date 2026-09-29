#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

workflow="$root/.github/workflows/trusted-pr-deletions.yml"
required_job="$(sed -n '/^  workflow-security:$/,/^  merge-ruleset-drift:$/p' "$root/.github/workflows/ci.yml")"
grep -q 'run: bash scripts/test-trusted-pr-deletion-gate.sh' <<<"$required_job"
grep -Fqx '  pull_request_target:' "$workflow"
grep -Fqx '    branches: [main]' "$workflow"
grep -Fqx '    types: [opened, synchronize, reopened, edited, ready_for_review]' "$workflow"
grep -Fq 'ref: ${{ github.event.pull_request.base.sha }}' "$workflow"
grep -Fq 'permission-statuses: write' "$workflow"
grep -Fq 'run: bash scripts/trusted-pr-deletion-gate.sh --publish' "$workflow"
if grep -Eq 'ref:.*(head\.sha|head\.ref|github\.head_ref)' "$workflow"; then
  echo 'trusted workflow checks out untrusted PR head' >&2
  exit 1
fi

git init --bare -q -b main "$tmp/origin.git"
git init -q -b main "$tmp/work"
cd "$tmp/work"
git config user.name 'Aiur Test'
git config user.email 'aiur@example.test'
git remote add origin "$tmp/origin.git"
printf 'base\n' >README.md
for number in $(seq 1 51); do
  printf 'base\n' >"file-$number.txt"
done
git add .
git commit -qm base
git push -q origin main
base="$(git rev-parse HEAD)"

# Same-repo PR: the server-side PR ref points to a branch that deletes 51 files.
git checkout -qb delete-files
git rm -q file-*.txt
git commit -qm 'delete 51 files'
deleted_head="$(git rev-parse HEAD)"
git push -q origin HEAD:refs/pull/17/head
export GITHUB_REPOSITORY='aiur-team/aiur'
if bash "$root/scripts/trusted-pr-deletion-gate.sh" --check "$base" "$deleted_head" 17 >"$tmp/deleted" 2>&1; then
  echo 'trusted gate accepted 51 real PR deletions' >&2
  exit 1
fi
grep -q 'refusing 51 deleted files' "$tmp/deleted"

# Fork PR: GitHub mirrors its head under the base repository's pull ref. No
# fork file is checked out or executed, even when it names the guard script.
git clone -q "$tmp/origin.git" "$tmp/fork"
git -C "$tmp/fork" config user.name 'Fork Test'
git -C "$tmp/fork" config user.email 'fork@example.test'
git -C "$tmp/fork" checkout -qb fork-pr
mkdir -p "$tmp/fork/scripts"
printf 'touch %s\n' "$tmp/untrusted-executed" >"$tmp/fork/scripts/trusted-pr-deletion-gate.sh"
git -C "$tmp/fork" add .
git -C "$tmp/fork" commit -qm 'add untrusted script as data'
fork_head="$(git -C "$tmp/fork" rev-parse HEAD)"
git -C "$tmp/fork" push -q origin HEAD:refs/pull/18/head
bash "$root/scripts/trusted-pr-deletion-gate.sh" --check "$base" "$fork_head" 18 >"$tmp/fork-pass"
grep -q '0 deleted files' "$tmp/fork-pass"
test ! -e "$tmp/untrusted-executed"

# Protected base advances after the fork branch split. Its new files are not
# PR deletions, and a fixed head has the same merge base.
git checkout -q main
for number in $(seq 1 51); do
  printf 'new base\n' >"new-$number.txt"
done
git add .
git commit -qm 'advance base with 51 files'
new_base="$(git rev-parse HEAD)"
git push -q origin main
bash "$root/scripts/trusted-pr-deletion-gate.sh" --check "$new_base" "$fork_head" 18 >"$tmp/stale-base-pass"
grep -q '0 deleted files' "$tmp/stale-base-pass"

# The event SHA must match the fetched PR ref. A moved ref publishes error,
# never success for an event that no longer names that ref.
git -C "$tmp/fork" commit --allow-empty -qm 'move fork head'
git -C "$tmp/fork" push -q -f origin HEAD:refs/pull/18/head
if bash "$root/scripts/trusted-pr-deletion-gate.sh" --check "$base" "$fork_head" 18 >"$tmp/moved" 2>&1; then
  echo 'trusted gate accepted a moved PR head ref' >&2
  exit 1
fi
grep -q 'PR head moved since event delivery' "$tmp/moved"

mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STATUS_LOG"
EOF
chmod +x "$tmp/bin/gh"
if env -u GH_TOKEN bash "$root/scripts/trusted-pr-deletion-gate.sh" --publish "$base" "$deleted_head" 17 >"$tmp/no-token" 2>&1; then
  echo 'trusted gate accepted a missing dedicated App token' >&2
  exit 1
fi
grep -q 'dedicated App token unavailable' "$tmp/no-token"
export PATH="$tmp/bin:$PATH" GH_TOKEN='test-app-token' STATUS_LOG="$tmp/statuses"

if bash "$root/scripts/trusted-pr-deletion-gate.sh" --publish "$base" "$deleted_head" 17 >"$tmp/published-failure" 2>&1; then
  echo 'trusted gate published success for 51 deletions' >&2
  exit 1
fi
grep -q "repos/aiur-team/aiur/statuses/$deleted_head.*state=pending.*context=aiur/trusted-pr-deletions" "$STATUS_LOG"
grep -q "repos/aiur-team/aiur/statuses/$deleted_head.*state=failure.*context=aiur/trusted-pr-deletions" "$STATUS_LOG"

: >"$STATUS_LOG"
if bash "$root/scripts/trusted-pr-deletion-gate.sh" --publish "$base" "$fork_head" 18 >"$tmp/published-error" 2>&1; then
  echo 'trusted gate published success for a moved PR ref' >&2
  exit 1
fi
grep -q "repos/aiur-team/aiur/statuses/$fork_head.*state=error.*context=aiur/trusted-pr-deletions" "$STATUS_LOG"

: >"$STATUS_LOG"
fork_current="$(git -C "$tmp/fork" rev-parse HEAD)"
bash "$root/scripts/trusted-pr-deletion-gate.sh" --publish "$new_base" "$fork_current" 18 >"$tmp/published-success"
grep -q "repos/aiur-team/aiur/statuses/$fork_current.*state=success.*context=aiur/trusted-pr-deletions" "$STATUS_LOG"
test ! -e "$tmp/untrusted-executed"

export REAL_GIT="$(command -v git)"
cat >"$tmp/bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == diff ]]; then exit 1; fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$tmp/bin/git"
: >"$STATUS_LOG"
if bash "$root/scripts/trusted-pr-deletion-gate.sh" --publish "$new_base" "$fork_current" 18 >"$tmp/diff-error" 2>&1; then
  echo 'trusted gate accepted a failed git diff' >&2
  exit 1
fi
grep -q "repos/aiur-team/aiur/statuses/$fork_current.*state=error.*context=aiur/trusted-pr-deletions" "$STATUS_LOG"
if grep -q 'state=failure' "$STATUS_LOG"; then
  echo 'trusted gate mislabeled a git failure as excessive deletions' >&2
  exit 1
fi

echo 'trusted PR deletion gate covers same-repo, fork, stale-base and status outcomes'
