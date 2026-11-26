#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../../../.." && pwd)"
script="$root/.claude/skills/aiur-run/scripts/check-stack-order.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export STACK_FIXTURE="$tmp/fx"
mkdir -p "$tmp/bin"
cp "$root/scripts/test-fixtures/stack-order/gh" "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MERGE_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# fixture <base> <head-ref> <blocked_by json>
fixture() {
  rm -rf "$STACK_FIXTURE"
  mkdir -p "$STACK_FIXTURE"
  echo 10 >"$STACK_FIXTURE/pr-number"
  printf '{"baseRefName":"%s","headRefName":"%s","headRefOid":"%s"}\n' "$1" "$2" "$HEAD_SHA" >"$STACK_FIXTURE/pr.json"
  printf '%s\n' "$3" >"$STACK_FIXTURE/blocked_by.json"
}

# blocker_prs <id> <json>
blocker_prs() { printf '%s\n' "$2" >"$STACK_FIXTURE/prs-$1.json"; }
merged_pr() { printf '{"number":%s,"state":"MERGED","headRefName":"aiur/%s-x","mergeCommit":{"oid":"%s"}}' "$2" "$1" "$MERGE_SHA"; }

# expect <name> <exit> <output-substring> [extra args]
expect() {
  local name="$1" want="$2" needle="$3" out rc=0
  shift 3
  out="$("$script" 10 o/r --base main "$@" 2>&1)" || rc=$?
  [[ "$rc" -eq "$want" ]] || fail "$name: exit $rc, want $want; output: $out"
  [[ "$out" == *"$needle"* ]] || fail "$name: output lacks '$needle': $out"
}

BLOCKER='[{"number":5,"state":"closed","state_reason":"completed"}]'
OPEN='[{"number":5,"state":"open","state_reason":null}]'

fixture main aiur/9-thing '[]'
expect "no blockers" 0 PASS

fixture main some-feature "$OPEN"
expect "non-ticket branch" 0 PASS

fixture aiur/5-blocker aiur/9-thing "$BLOCKER"
blocker_prs 5 "[$(merged_pr 5 20)]"
echo '{"status":"ahead"}' >"$STACK_FIXTURE/compare-$MERGE_SHA.json"
expect "base is blocker branch" 2 "REFUSE base"

fixture main aiur/9-thing "$OPEN"
blocker_prs 5 '[{"number":20,"state":"OPEN","headRefName":"aiur/5-x","mergeCommit":null}]'
expect "blocker open" 2 "REFUSE blocker #5 is not landed"

fixture main aiur/9-thing "$BLOCKER"
blocker_prs 5 "[$(merged_pr 5 20)]"
echo '{"status":"diverged"}' >"$STACK_FIXTURE/compare-$MERGE_SHA.json"
expect "merged but not contained" 2 "REFUSE restack-needed #5"

echo '{"status":"ahead"}' >"$STACK_FIXTURE/compare-$MERGE_SHA.json"
expect "merged and contained" 0 PASS

echo '{"oops":1}' >"$STACK_FIXTURE/compare-$MERGE_SHA.json"
expect "compare unreadable" 3 "UNDECIDED containment #5"

blocker_prs 5 '[]'
expect "closed completed without PR" 0 PASS

fixture main aiur/9-thing '[{"number":5,"state":"closed","state_reason":"not_planned"}]'
blocker_prs 5 '[]'
expect "not_planned" 2 "closed not_planned"

fixture main aiur/9-thing '[{"number":5,"state":"closed","state_reason":"duplicate"}]'
expect "duplicate" 2 "closed duplicate"

fixture main aiur/9-thing "$OPEN"
blocker_prs 5 '[{"number":20,"state":"CLOSED","headRefName":"aiur/5-x","mergeCommit":null}]'
expect "blocker PR closed unmerged" 2 "REFUSE blocker #5 is not landed"

fixture main aiur/9-thing "$BLOCKER"
blocker_prs 5 '[{"number":20,"state":"CLOSED","headRefName":"aiur/5-x","mergeCommit":null}]'
expect "closed completed but PR unmerged" 2 "ambiguous blocker #5"

fixture main aiur/9-thing "$BLOCKER"
blocker_prs 5 "[$(merged_pr 5 20),$(merged_pr 5 21)]"
expect "two merged PRs" 2 "ambiguous blocker #5 has 2 merged PRs"

fixture main aiur/9-thing "$BLOCKER"
blocker_prs 5 '[{"number":30,"state":"OPEN","headRefName":"aiur/50-x","mergeCommit":null}]'
expect "prefix-collision PR is ignored" 0 PASS

fixture main aiur/9-thing "$BLOCKER"
touch "$STACK_FIXTURE/blocked_by.fail"
expect "blocked_by read 500" 3 "UNDECIDED blocked_by #9"

# --- RESTACK-ONLY: real git history, recomputed tree ---
git_repo="$tmp/repo"
git init -q -b main "$git_repo"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# The agent git guard refuses to mutate a scratch repo outside the workspace.
PATH="$(tr ':' '\n' <<<"$PATH" | grep -v '/\.aiur-runtime/bin$' | paste -sd: -)"
g() { git -C "$git_repo" "$@"; }
printf 'one\ntwo\nthree\n' >"$git_repo/f.txt"
g add f.txt && g commit -qm base
g checkout -qb blocker && echo blocker >"$git_repo/b.txt" && g add b.txt && g commit -qm blocker
blocker_head="$(g rev-parse HEAD)"
g checkout -q main && g checkout -qb dep && echo dep >"$git_repo/d.txt" && g add d.txt && g commit -qm dep
approved="$(g rev-parse HEAD)"
g checkout -q main && g merge -q --squash blocker && g commit -qm "blocker squash (#20)"
g update-ref refs/remotes/origin/main main
base_sha="$(g rev-parse main)"
g checkout -q dep

restack() { # restack <extra-file-or-empty>: build a restack commit on dep
  local lb tree
  lb="$(g merge-base dep "$blocker_head")"
  tree="$(g merge-tree --write-tree --merge-base="$lb" "$base_sha" dep)"
  g commit-tree "$tree" -p dep -p "$base_sha" -m "Restack after #20 merged

Aiur-Restack: blocker=#20 blocker-head=$blocker_head base=$base_sha"
}

restack_fixture() { # restack_fixture <head sha>
  HEAD_SHA="$1"
  fixture main aiur/9-thing '[]'
  echo "$blocker_head" >"$STACK_FIXTURE/prhead-20.txt"
}

c_ok="$(restack)"
restack_fixture "$c_ok"
expect "honest restack" 0 "RESTACK-ONLY $approved..$c_ok" --repo-dir "$git_repo" --approved "$approved"

# tampered tree: same parents and trailer, extra file in the tree
tampered_tree="$(g rev-parse "$c_ok^{tree}")"
echo evil >"$tmp/evil.txt"
blob="$(g hash-object -w "$tmp/evil.txt")"
tampered_tree="$(printf '100644 blob %s\tevil.txt\n%s' "$blob" "$(g ls-tree "$tampered_tree")" | g mktree)"
c_bad="$(g commit-tree "$tampered_tree" -p dep -p "$base_sha" -m "$(g log -1 --format=%B "$c_ok")")"
restack_fixture "$c_bad"
out="$("$script" 10 o/r --base main --repo-dir "$git_repo" --approved "$approved")"
[[ "$out" != *RESTACK-ONLY* ]] || fail "tampered tree printed RESTACK-ONLY"

# restack plus an ordinary commit on top
g checkout -q -b onto "$c_ok" && echo more >"$git_repo/m.txt" && g add m.txt && g commit -qm extra
restack_fixture "$(g rev-parse HEAD)"
out="$("$script" 10 o/r --base main --repo-dir "$git_repo" --approved "$approved")"
[[ "$out" != *RESTACK-ONLY* ]] || fail "extra commit printed RESTACK-ONLY"

# missing trailer
tree_ok="$(g rev-parse "$c_ok^{tree}")"
c_notrailer="$(g commit-tree "$tree_ok" -p dep -p "$base_sha" -m "Restack after #20 merged")"
restack_fixture "$c_notrailer"
out="$("$script" 10 o/r --base main --repo-dir "$git_repo" --approved "$approved")"
[[ "$out" != *RESTACK-ONLY* ]] || fail "missing trailer printed RESTACK-ONLY"

# forged blocker-head (not the blocker PR's real head)
restack_fixture "$c_ok"
echo "$HEAD_SHA" >"$STACK_FIXTURE/prhead-20.txt"
out="$("$script" 10 o/r --base main --repo-dir "$git_repo" --approved "$approved")"
[[ "$out" != *RESTACK-ONLY* ]] || fail "forged blocker-head printed RESTACK-ONLY"

echo "check-stack-order tests passed"
