# Merge the integration branch, then report every cheap gate in one final block.
cmd_pre_pr() {
  [ "$#" -eq 0 ] || { echo "aiur: pre-pr does not accept arguments" >&2; exit 64; }
  local root base_ref base_sha merge_output result=0 name gate_log temp_dir test_home test_config test_path cleanup_command affected selection pr_json
  local -a results=() failures=() test_files=() test_env=()
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "aiur pre-pr is for Aiur source checkouts; run it inside an Aiur repository." >&2; exit 64; }
  if [ ! -f "$root/src/mix.exs" ] || [ ! -f "$root/scripts/check-pr-structure.py" ]; then
    echo "aiur pre-pr is for Aiur source checkouts; this repository does not contain the Aiur gates." >&2
    exit 64
  fi
  cd "$root"
  [ -z "$(git status --porcelain)" ] || { echo "pre-pr requires a clean working tree (commit or stash changes first)" >&2; exit 1; }
  base_ref="${AIUR_BASE_BRANCH:-main}"
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/aiur-pre-pr.XXXXXX")"
  printf -v cleanup_command 'rm -rf -- %q' "$temp_dir"
  trap "$cleanup_command" EXIT
  test_home="$temp_dir/home"
  test_config="$temp_dir/config"
  mkdir -p "$test_home" "$test_config"
  # Keep fixture repositories and identity tests out of the agent host context.
  test_path="$PATH"
  if [ "${AIUR_AGENT_WORKSPACE:-}" = "$root" ] && [ -x "$root/.aiur-runtime/bin/git" ]; then test_path="/usr/bin:/bin:$PATH"; fi
  test_env=(
    env -u AIUR_AGENT_WORKSPACE -u AIUR_INSTANCE_KEY -u AIUR_REPO_ROOT
    -u AIUR_PROJECT_ROOT -u AIUR_PROJECT_ROOT_SOURCE -u AIUR_ARGV_FILE
    -u AIUR_BIN -u AIUR_RELEASE_DIR -u AIUR_NODE -u AIUR_OPERATOR_PID
    -u AIUR_BG_STATE_DIR -u AIUR_COOKIE_FILE -u AIUR_SESSION_PREFIX
    -u AIUR_PROFILES_FILE -u AIUR_RELEASE_NODE -u AIUR_DEFAULT_DASHBOARD_HOST
    -u AIUR_AGENT_BIN -u AIUR_AGENT_QUOTA_STATE_PATH -u AIUR_AGENT_TMPFILE
    -u AIUR_ALERT_LEDGER_PATH_FILE -u AIUR_REPO_STATE_PATH -u AIUR_SESSION_TMPFILE
    -u AIUR_WORKSPACE_ROOT_FILE -u AIUR_TMUX_CONF -u AIUR_TMUX_SESSION -u AIUR_TMUX_SOCKET
    "HOME=$test_home" "XDG_CONFIG_HOME=$test_config" "TMPDIR=/tmp"
    "PATH=$test_path"
  )
  if ! git fetch origin "$base_ref" >"$temp_dir/fetch.log" 2>&1; then
    results+=("FAIL fetch origin/$base_ref")
    failures+=("$temp_dir/fetch.log")
    pre_pr_report "unknown" FAIL
    return 1
  fi
  base_sha="$(git rev-parse "FETCH_HEAD^{commit}")"
  if ! merge_output="$(git merge --no-edit "$base_sha" 2>&1)"; then
    local conflict_files
    conflict_files="$(git diff --name-only --diff-filter=U | tr '\n' ' ')"
    git merge --abort >/dev/null 2>&1 || true
    results+=("FAIL merge conflict: ${conflict_files:-unknown files}")
    pre_pr_report "$base_sha" FAIL
    return 1
  fi
  results+=("PASS merge origin/$base_ref ($(git rev-parse --short HEAD))")

  run_gate() {
    name="$1"; shift
    gate_log="$temp_dir/gate-${#results[@]}.log"
    if "$@" >"$gate_log" 2>&1; then
      results+=("PASS $name")
    else
      results+=("FAIL $name")
      failures+=("$gate_log")
      result=1
    fi
  }

  run_gate "mix format --check-formatted" bash -c 'cd src && mise exec -- mix format --check-formatted'
  run_gate "mix compile --warnings-as-errors" bash -c 'cd src && mise exec -- mix compile --warnings-as-errors'
  run_gate "check-pr-structure" python3 scripts/check-pr-structure.py --base "$base_sha"
  run_gate "check-file-size" python3 scripts/check-file-size.py --base "$base_sha"
  run_gate "check-config-docs" python3 scripts/check-config-docs.py
  run_gate "check-hot-list-format" python3 scripts/check-hot-list-format.py
  run_gate "architectural guard tests" "${test_env[@]}" bash -c 'cd src && mise exec -- mix test --max-cases 4 test/aiur/base_branch_literal_guard_test.exs test/aiur/orchestrator/state_owners_test.exs test/aiur/events/placement_rule_test.exs test/aiur/orchestrator/non_transition_facade_test.exs test/aiur/orchestrator/waiting_descriptor_test.exs test/aiur/application_child_order_test.exs test/aiur/pr_lifecycle/health_scanner_child_order_test.exs'

  if ! affected="$(cd src && AIUR_BASE_BRANCH="$base_ref" mise exec -- mix aiur.affected_tests "origin/$base_ref" --json)"; then
    results+=("FAIL affected tests selection")
    printf '%s\n' "$affected" >"$temp_dir/affected-selection.log"
    failures+=("$temp_dir/affected-selection.log")
    result=1
  else
    if ! selection="$(jq -er '.status' <<<"$affected" 2>"$temp_dir/selector-json.log")"; then
      results+=("FAIL affected tests selection (invalid JSON)")
      printf '%s\n' "$affected" >"$temp_dir/affected-selection.log"
      cat "$temp_dir/selector-json.log" >>"$temp_dir/affected-selection.log"
      failures+=("$temp_dir/affected-selection.log")
      result=1
      selection=invalid
    fi
    case "$selection" in
      full)
        run_gate "full test suite (affected-test selector fallback: $(jq -r '.reason' <<<"$affected"))" "${test_env[@]}" bash -c 'cd src && mise exec -- make ci'
        ;;
      scoped)
        while IFS= read -r test_path; do test_files+=("$test_path"); done < <(jq -r '.tests[]' <<<"$affected")
        if [ "${#test_files[@]}" -eq 0 ]; then
          results+=("PASS affected tests (no test files selected)")
        else
          local -a mix_paths=()
          for test_path in "${test_files[@]}"; do mix_paths+=("${test_path#src/}"); done
          run_gate "affected tests" "${test_env[@]}" bash -c 'cd src && mise exec -- mix test --max-cases 4 "$@"' _ "${mix_paths[@]}"
        fi
        ;;
      invalid) ;;
      *)
        results+=("FAIL affected tests selection (invalid selector response)")
        printf '%s\n' "$affected" >"$temp_dir/affected-selection.log"
        failures+=("$temp_dir/affected-selection.log")
        result=1
        ;;
    esac
  fi

  if command -v gh >/dev/null && pr_json="$(gh pr view --json createdAt,body,headRefOid --jq '{created_at: .createdAt, body: .body, head: {sha: .headRefOid}}' 2>"$temp_dir/gh-pr.log")"; then
    printf '%s\n' "$pr_json" >"$temp_dir/pr.json"
    run_gate "check-pr-body" python3 scripts/check-pr-body.py --pr-json "$temp_dir/pr.json" --base "$base_sha"
  elif [ -s "$temp_dir/gh-pr.log" ]; then
    results+=("SKIP check-pr-body (could not read PR with gh)")
  else
    results+=("SKIP check-pr-body (no PR for this branch)")
  fi

  pre_pr_report "$base_sha" "$result"
  return "$result"
}

pre_pr_report() {
  local base_sha="$1" result="$2" line log status=FAIL
  if [ "$result" = PASS ] || [ "$result" = 0 ]; then status=PASS; fi
  printf '%s\n' '--- aiur pre-pr result (paste into the PR body) ---'
  printf 'Merged main SHA: %s\n' "$base_sha"
  printf 'Result: %s\n' "$status"
  for line in "${results[@]}"; do printf '%s\n' "$line"; done
  for log in "${failures[@]}"; do
    printf '%s\n' '--- failed gate output ---'
    cat "$log"
  done
  printf '%s\n' '--- end aiur pre-pr result ---'
}
