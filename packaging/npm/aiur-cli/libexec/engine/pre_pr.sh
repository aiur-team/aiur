# Merge the integration branch locally and run cheap PR gates on that snapshot.
cmd_pre_pr() {
  [ "$#" -eq 0 ] || { echo "aiur: pre-pr does not accept arguments" >&2; exit 64; }
  local base_ref base_sha merged_sha result=0 temp_dir worktree name
  base_ref="${AIUR_BASE_BRANCH:-main}"
  if [ -n "$(git status --porcelain)" ]; then echo "pre-pr: FAIL clean working tree required (commit or stash changes first)"; exit 1; fi
  if ! git fetch origin "$base_ref"; then echo "pre-pr: FAIL fetch origin/$base_ref"; exit 1; fi
  base_sha="$(git rev-parse "FETCH_HEAD^{commit}")"
  echo "pre-pr: merging origin/$base_ref $base_sha"
  if ! git merge --no-edit "$base_sha"; then
    local files
    files="$(git diff --name-only --diff-filter=U | tr '\n' ' ')"
    git merge --abort >/dev/null 2>&1 || true
    echo "pre-pr: FAIL merge conflict: ${files:-unknown files}"
    exit 1
  fi
  merged_sha="$(git rev-parse HEAD)"
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/aiur-pre-pr.XXXXXX")"
  worktree="$temp_dir/worktree"
  cleanup_pre_pr() {
    git worktree remove --force "$worktree" >/dev/null 2>&1 || true
    rm -rf "$temp_dir"
  }
  trap cleanup_pre_pr EXIT INT TERM
  if ! git worktree add --detach "$worktree" "$merged_sha" >/dev/null; then
    echo "pre-pr: FAIL create isolated check worktree"
    exit 1
  fi
  echo "pre-pr: merged main SHA $base_sha (local merge commit $merged_sha)"
  run_gate() {
    name="$1"; shift
    if (cd "$worktree" && "$@"); then echo "pre-pr: PASS $name"; else echo "pre-pr: FAIL $name"; result=1; fi
  }
  run_gate "mix format --check-formatted" bash -c 'cd src && mix format --check-formatted'
  run_gate "mix compile --warnings-as-errors" bash -c 'cd src && mix compile --warnings-as-errors'
  run_gate "check-pr-structure" python3 scripts/check-pr-structure.py --base "$base_sha"
  run_gate "check-file-size" python3 scripts/check-file-size.py --base "$base_sha"
  run_gate "check-config-docs" python3 scripts/check-config-docs.py
  run_gate "architectural guard tests" bash -c 'cd src && mix test --max-cases 4 test/aiur/base_branch_literal_guard_test.exs test/aiur/orchestrator/state_owners_test.exs test/aiur/events/placement_rule_test.exs test/aiur/orchestrator/non_transition_facade_test.exs test/aiur/orchestrator/waiting_descriptor_test.exs test/aiur/application_child_order_test.exs test/aiur/pr_lifecycle/health_scanner_child_order_test.exs'
  local affected
  if ! affected="$(cd "$worktree/src" && AIUR_BASE_BRANCH="$base_ref" mix aiur.affected_tests "origin/$base_ref" 2>&1)"; then
    echo "pre-pr: FAIL affected tests selection: $affected"
    result=1
  elif [[ "$affected" == *"no affected test files detected"* ]]; then
    echo "pre-pr: PASS affected tests (none selected)"
  else
    affected="$(printf '%s\n' "$affected" | sed -n 's/^cd src && mise exec -- mix test --max-cases 4 //p' | tail -1)"
    if [ -n "$affected" ]; then
      read -r -a test_paths <<<"$affected"
      run_gate "affected tests" bash -c 'cd src && mix test --max-cases 4 "$@"' _ "${test_paths[@]}"
    else
      echo "pre-pr: FAIL affected tests selection returned no command"
      result=1
    fi
  fi
  cleanup_pre_pr
  trap - EXIT INT TERM
  echo "pre-pr: result $([ "$result" -eq 0 ] && echo PASS || echo FAIL); merged main SHA $base_sha"
  return "$result"
}
