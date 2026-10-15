#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/pre-handoff-test.XXXXXX")"
fixture=""
cleanup() {
  [[ -z "$fixture" ]] || rm -f "$fixture"
  rm -rf "$tmp"
}
trap cleanup EXIT

base="$(git -C "$repo_root" rev-parse HEAD)"
head="$base"
cat > "$tmp/pr.json" <<JSON
{"created_at":"1970-01-01T00:00:00Z","body":"","head":{"sha":"$head"}}
JSON

cd "$repo_root"
scripts/pre-handoff-guards "$tmp/pr.json" "$base" > "$tmp/clean.log"
scripts/pre-handoff-guards --skip-pr-body "$base" > "$tmp/non-pr.log"

fail() {
  echo "test-pre-handoff-guards: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1" expected="$2" description="$3"
  grep -F -- "$expected" "$file" >/dev/null || fail "$description (expected '$expected' in $file)"
}

assert_absent() {
  local file="$1" unexpected="$2" description="$3"
  if grep -F -- "$unexpected" "$file" >/dev/null; then
    fail "$description (unexpected '$unexpected' in $file)"
  fi
}

for output in "$tmp/clean.log" "$tmp/non-pr.log"; do
  for guard in check-on-exit-rm-rf.py check-bare-assert-receive.py check-browser-smoke-shards.mjs check-hot-list-format.py check-file-size.py; do
    assert_contains "$output" "scripts/$guard" "shared guard list entry missing"
  done
done
assert_contains "$tmp/clean.log" 'scripts/check-pr-body.py' 'PR path omitted body guard'
assert_absent "$tmp/non-pr.log" 'scripts/check-pr-body.py' 'non-PR path included body guard'

events_repo="$tmp/events-repo"
mkdir -p "$events_repo/scripts" "$tmp/bin"
cp "$repo_root/scripts/run-pre-handoff-guards.sh" "$events_repo/scripts/run-pre-handoff-guards.sh"
cat > "$events_repo/scripts/pre-handoff-guards" <<'GUARDS'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$EVENT_LOG"
printf 'pre-handoff-guards: %s\n' "$*"
GUARDS
cat > "$events_repo/scripts/check-config-docs.py" <<'PYTHON'
raise SystemExit(0)
PYTHON
cat > "$events_repo/scripts/check-docs-prose.mjs" <<'NODE'
process.exit(0)
NODE
chmod +x "$events_repo/scripts/pre-handoff-guards"

cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$GH_LOG"
cat "$PR_METADATA"
GH
chmod +x "$tmp/bin/gh"
cat > "$tmp/bin/git" <<'GIT'
#!/usr/bin/env bash
case "$*" in
  *'@{upstream}'*) printf '%s\n' "${EXPECTED_UPSTREAM:?}" ;;
  *'merge-base'*) printf '%s\n' "${EXPECTED_DISPATCH_BASE:?}" ;;
  *'HEAD^1'*) printf '%s\n' "${EXPECTED_PARENT:?}" ;;
  *) echo "test-pre-handoff-guards: unexpected git lookup: $*" >&2; exit 97 ;;
esac
GIT
chmod +x "$tmp/bin/git"

pr_base="$(printf '1%.0s' {1..40})"
merge_base="$(printf '2%.0s' {1..40})"
push_before="$(printf '3%.0s' {1..40})"
dispatch_base="$(printf '4%.0s' {1..40})"
run_event() {
  local name="$1" event="$2" pr_sha="$3" merge_sha="$4" push_sha="$5"
  : > "$tmp/$name.log"
  if ! (
    cd "$events_repo"
    env GITHUB_EVENT_NAME="$event" GITHUB_REPOSITORY=example/repo AIUR_PR_NUMBER=1 \
      AIUR_PR_BASE_SHA="$pr_sha" AIUR_MERGE_BASE_SHA="$merge_sha" AIUR_PUSH_BEFORE="$push_sha" \
      RUNNER_TEMP="$tmp" PR_METADATA="$tmp/pr.json" EVENT_LOG="$tmp/$name.args" \
      GH_LOG="$tmp/$name.gh" \
      EXPECTED_UPSTREAM=origin/main EXPECTED_DISPATCH_BASE="$dispatch_base" EXPECTED_PARENT="$pr_base" \
      PATH="$tmp/bin:$PATH" bash scripts/run-pre-handoff-guards.sh > "$tmp/$name.log" 2>&1
  ); then
    fail "$event runner failed: $(cat "$tmp/$name.log")"
  fi
}
run_event pull_request pull_request "$pr_base" "$merge_base" "$push_before"
run_event merge_group merge_group "$pr_base" "$merge_base" "$push_before"
run_event push push "$pr_base" "$merge_base" "$push_before"
run_event push_zero push "$pr_base" "$merge_base" "$(printf '0%.0s' {1..40})"
run_event workflow_dispatch workflow_dispatch "$pr_base" "$merge_base" "$push_before"
run_event schedule schedule "$pr_base" "$merge_base" "$push_before"
assert_contains "$tmp/pull_request.gh" "repos/example/repo/pulls/1" 'pull-request event did not fetch PR metadata'
assert_contains "$tmp/pull_request.args" "$pr_base" 'pull-request event used the wrong base'
assert_contains "$tmp/merge_group.args" "--skip-pr-body $merge_base" 'merge-group event did not use its supplied base'
assert_contains "$tmp/push.args" "--skip-pr-body $push_before" 'push event did not use its before SHA'
assert_contains "$tmp/push_zero.args" "--skip-pr-body $pr_base" 'new-branch push did not use the parent SHA'
assert_contains "$tmp/workflow_dispatch.args" "--skip-pr-body $dispatch_base" 'manual event used the wrong merge base'
assert_contains "$tmp/schedule.args" "--skip-pr-body $dispatch_base" 'scheduled event used the wrong merge base'
for event in merge_group push push_zero workflow_dispatch schedule; do
  assert_absent "$tmp/$event.log" 'scripts/check-pr-body.py' "$event event included PR body guard"
done
assert_contains "$tmp/merge_group.log" "pre-handoff-guards: --skip-pr-body $merge_base" 'merge-group event runner did not execute its guard command'

fixture="$(mktemp "$repo_root/src/test/aiur/pre_handoff_guard_fixture.XXXXXX.exs")"
cat > "$fixture" <<'ELIXIR'
on_exit(fn -> File.rm_rf!("/tmp/pre-handoff-guard-fixture") end)
ELIXIR

if scripts/pre-handoff-guards "$tmp/pr.json" "$base" > "$tmp/bare-rm-rf.log" 2>&1; then
  echo "test-pre-handoff-guards: expected bare File.rm_rf! fixture to fail" >&2
  exit 1
fi
grep -F 'check-on-exit-rm-rf: bare File.rm_rf in on_exit; use Aiur.TestCleanup.rm_rf!/1:' "$tmp/bare-rm-rf.log" >/dev/null
grep -F "${fixture#"$repo_root/"}:1:" "$tmp/bare-rm-rf.log" >/dev/null

echo "test-pre-handoff-guards: clean PR and non-PR paths pass; bare cleanup fails with CI diagnostic"
