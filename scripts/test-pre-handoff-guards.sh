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

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
cat "$PR_METADATA"
GH
chmod +x "$tmp/bin/gh"
pr_base="$(git rev-parse HEAD^1)"
merge_base="$(git rev-parse HEAD)"
main_base="$(git rev-parse origin/main)"
dispatch_base="$(git merge-base "$merge_base" "$main_base")"
push_before="$main_base"
run_event() {
  local name="$1" event="$2" pr_sha="$3" merge_sha="$4" push_sha="$5"
  env GITHUB_EVENT_NAME="$event" GITHUB_REPOSITORY=example/repo AIUR_PR_NUMBER=1 \
    AIUR_PR_BASE_SHA="$pr_sha" AIUR_MERGE_BASE_SHA="$merge_sha" AIUR_PUSH_BEFORE="$push_sha" \
    RUNNER_TEMP="$tmp" PR_METADATA="$tmp/pr.json" PATH="$tmp/bin:$PATH" \
    scripts/run-pre-handoff-guards.sh > "$tmp/$name.log"
}
run_event pull_request pull_request "$pr_base" "$merge_base" "$push_before"
run_event merge_group merge_group "$pr_base" "$merge_base" "$push_before"
run_event push push "$pr_base" "$merge_base" "$push_before"
run_event push_zero push "$pr_base" "$merge_base" "$(printf '0%.0s' {1..40})"
run_event workflow_dispatch workflow_dispatch "$pr_base" "$merge_base" "$push_before"
run_event schedule schedule "$pr_base" "$merge_base" "$push_before"
grep -F 'scripts/check-pr-body.py' "$tmp/pull_request.log" >/dev/null
for event in merge_group push push_zero workflow_dispatch schedule; do
  ! grep -F 'scripts/check-pr-body.py' "$tmp/$event.log" >/dev/null
done
for event in pull_request merge_group push push_zero workflow_dispatch schedule; do
  for guard in check-on-exit-rm-rf.py check-bare-assert-receive.py check-browser-smoke-shards.mjs check-hot-list-format.py check-file-size.py; do
    grep -F "scripts/$guard" "$tmp/$event.log" >/dev/null
  done
done
grep -F -- "check-file-size.py --base $pr_base" "$tmp/pull_request.log" >/dev/null
grep -F -- "check-file-size.py --base $merge_base" "$tmp/merge_group.log" >/dev/null
grep -F -- "check-file-size.py --base $push_before" "$tmp/push.log" >/dev/null
grep -F -- "check-file-size.py --base $pr_base" "$tmp/push_zero.log" >/dev/null
grep -F -- "check-file-size.py --base $dispatch_base" "$tmp/workflow_dispatch.log" >/dev/null
grep -F -- "check-file-size.py --base $dispatch_base" "$tmp/schedule.log" >/dev/null

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
