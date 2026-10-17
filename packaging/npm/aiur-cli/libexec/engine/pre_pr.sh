# Merge the integration branch, then report every cheap gate in one final block.
cmd_pre_pr() {
  [ "$#" -eq 0 ] || { echo "aiur: pre-pr does not accept arguments" >&2; exit 64; }
  local root base_ref base_sha merge_output result=0 name gate_log temp_dir test_home test_config test_path cleanup_command affected selection pr_json full_suite_recommended=0 required
  local -a results=() failures=() test_files=() test_env=()
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "aiur pre-pr is for Aiur source checkouts; run it inside an Aiur repository." >&2; exit 64; }
  if [ ! -f "$root/src/mix.exs" ] || [ ! -f "$root/scripts/check-pr-structure.py" ]; then
    echo "aiur pre-pr is for Aiur source checkouts; this repository does not contain the Aiur gates." >&2
    exit 64
  fi
  cd "$root"
  [ -z "$(git status --porcelain)" ] || { echo "pre-pr requires a clean working tree (commit or stash changes first)" >&2; exit 1; }
  for required in jq rg; do
    if ! command -v "$required" >/dev/null 2>&1; then
      results+=("FAIL required command: $required")
      pre_pr_report "unknown" FAIL
      return 1
    fi
  done
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
    -u AIUR_CONTROL_RELEASE_RETRYABLE -u AIUR_CONTROL_RELEASE_RETRY_SIGNAL
    "HOME=$test_home" "XDG_CONFIG_HOME=$test_config" "TMPDIR=$temp_dir"
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
        full_suite_recommended=1
        results+=("NOTE full suite recommended ($(jq -r '.reason' <<<"$affected")); runs in merge queue")
        while IFS= read -r edited; do
          [ -n "$edited" ] || continue
          while IFS= read -r reader_test; do
            if rg -n --fixed-strings -e "$edited" -e "${edited##*/}" "$reader_test" | rg -q 'Path\.(expand|join)|File\.read|System\.cmd'; then
              test_files+=("$reader_test")
            fi
          done < <(rg -l --glob '*_test.exs' --fixed-strings -e "$edited" -e "${edited##*/}" src/test || true)
        done < <(git diff --name-only "$base_sha...HEAD")
        mapfile -t test_files < <(printf '%s\n' "${test_files[@]}" | sort -u | awk 'NF')
        if [ "${#test_files[@]}" -eq 0 ]; then
          results+=("PASS reader tests (no test names an edited file)")
        else
          local -a mix_paths=()
          for test_path in "${test_files[@]}"; do mix_paths+=("${test_path#src/}"); done
          run_gate "reader tests" "${test_env[@]}" bash -c 'cd src && mise exec -- mix test --max-cases 4 "$@"' _ "${mix_paths[@]}"
          report_unedited_test_failures "$base_sha"
        fi
        ;;
      scoped)
        while IFS= read -r test_path; do test_files+=("$test_path"); done < <(jq -r '.tests[]' <<<"$affected")
        if [ "${#test_files[@]}" -eq 0 ]; then
          results+=("PASS affected tests (no test files selected)")
        else
          local -a mix_paths=()
          for test_path in "${test_files[@]}"; do mix_paths+=("${test_path#src/}"); done
          run_gate "affected tests" "${test_env[@]}" bash -c 'cd src && mise exec -- mix test --max-cases 4 "$@"' _ "${mix_paths[@]}"
          report_unedited_test_failures "$base_sha"
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

  if command -v gh >/dev/null && pr_json="$(gh pr view --json number,createdAt,body,headRefOid --jq '{number: .number, created_at: .createdAt, body: .body, head: {sha: .headRefOid}}' 2>"$temp_dir/gh-pr.log")"; then
    printf '%s\n' "$pr_json" >"$temp_dir/pr.json"
    if ! refresh_pr_body_evidence "$temp_dir/pr.json" "$base_ref" "$base_sha" >"$temp_dir/refresh.log" 2>&1; then
      results+=("FAIL refresh-pr-body-evidence")
      failures+=("$temp_dir/refresh.log")
      result=1
    else
      results+=("PASS refresh-pr-body-evidence")
      results+=("PASS check-pr-body")
    fi
  elif ! command -v gh >/dev/null || grep -q 'no pull requests found' "$temp_dir/gh-pr.log"; then
    # The handoff guard refuses ci-wait/human-review until a rerun after `gh pr create` refreshes the body.
    results+=("SKIP refresh-pr-body-evidence (no PR yet; rerun aiur pre-pr after gh pr create)")
  else
    results+=("FAIL refresh-pr-body-evidence (could not read PR with gh)")
    failures+=("$temp_dir/gh-pr.log")
    result=1
  fi

  pre_pr_report "$base_sha" "$result"
  return "$result"
}

# Refresh Local-tests refs only once GitHub has acknowledged the final pushed HEAD.
# The checker intentionally consumes exact plain text, so preserve that format.
refresh_pr_body_evidence() {
  local json_file="$1" base_ref="$2" base_sha="$3" merge_base number pushed_sha live_sha pr_json body_file update_json
  number="$(jq -er '.number' "$json_file")" || return 1
  pushed_sha="$(git rev-parse HEAD)" || return 1
  merge_base="$(git merge-base HEAD "$base_sha")" || return 1
  local attempt
  for ((attempt = 1; attempt <= ${AIUR_PRE_PR_REFRESH_ATTEMPTS:-20}; attempt++)); do
    pr_json="$(gh pr view "$number" --json headRefOid --jq '{head: {sha: .headRefOid}}' 2>/dev/null)" || return 1
    live_sha="$(jq -er '.head.sha' <<<"$pr_json")" || return 1
    [ "$live_sha" = "$pushed_sha" ] && break
    sleep "${AIUR_PRE_PR_REFRESH_INTERVAL:-3}"
  done
  [ "$live_sha" = "$pushed_sha" ] || { echo "GitHub PR #$number did not report pushed head $pushed_sha" >&2; return 1; }
  if ! python3 - "$json_file" "$pushed_sha" "$base_ref" "$merge_base" <<'PY'
import json, pathlib, re, sys
path = pathlib.Path(sys.argv[1])
pr = json.loads(path.read_text(encoding="utf-8"))
body = pr.get("body") or ""
head, base_ref, base_sha = sys.argv[2:]
body, head_count = re.subn(r"(?m)^Tested head:.*$", "Tested head: " + head, body)
body, base_count = re.subn(r"(?m)^Base:.*$", "Base: " + base_ref + " @ " + base_sha, body)
if head_count != 1 or base_count != 1:
    raise SystemExit("PR body must contain exactly one Tested head: and Base: line")
pathlib.Path(path.parent, "body.md").write_text(body, encoding="utf-8")
PY
  then
    return 1
  fi
  body_file="$(dirname "$json_file")/body.md"
  update_json="$(dirname "$json_file")/body-update.json"
  if ! python3 - "$body_file" "$update_json" <<'PY'
import json, pathlib, sys
body = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
pathlib.Path(sys.argv[2]).write_text(json.dumps({"body": body}), encoding="utf-8")
PY
  then
    return 1
  fi
  gh api "repos/{owner}/{repo}/pulls/$number" --method PATCH --input "$update_json" >/dev/null || return 1
  pr_json="$(gh pr view "$number" --json createdAt,body,headRefOid --jq '{created_at: .createdAt, body: .body, head: {sha: .headRefOid}}')" || return 1
  printf '%s\n' "$pr_json" >"$json_file"
  [ "$(jq -r '.head.sha' "$json_file")" = "$pushed_sha" ] || { echo "PR #$number head moved during evidence refresh" >&2; return 1; }
  python3 scripts/check-pr-body.py --pr-json "$json_file" --base "$base_sha"
}

pre_pr_report() {
  local base_sha="$1" result="$2" line log status=FAIL
  if [ "$result" = PASS ] || [ "$result" = 0 ]; then status=PASS; fi
  printf '%s\n' '--- aiur pre-pr result (paste into the PR body) ---'
  printf 'Merged main SHA: %s\n' "$base_sha"
  if [ "$status" = PASS ] && [ "${full_suite_recommended:-0}" -eq 1 ]; then
    printf '%s\n' 'Result: PASS (full suite not run)'
  else
    printf 'Result: %s\n' "$status"
  fi
  printf '%s\n' 'Not run: Credo and specs (make lint), dialyzer, full suite'
  for line in "${results[@]}"; do printf '%s\n' "$line"; done
  printf '%s\n' '--- end aiur pre-pr result ---'
  for log in "${failures[@]}"; do
    printf '%s\n' '--- failed gate output ---'
    cat "$log"
  done
}

report_unedited_test_failures() {
  local base_sha="$1" result_index test_file
  local -a failing_files=() unedited_files=()
  result_index=$((${#results[@]} - 1))
  [[ "${results[$result_index]}" == FAIL\ *tests ]] || return 0
  mapfile -t failing_files < <(sed -nE 's/.*(test\/[^[:space:]]+\.exs):[0-9]+.*/src\/\1/p' "${failures[-1]}" | sort -u)
  for test_file in "${failing_files[@]}"; do
    if git diff --quiet "$base_sha...HEAD" -- "$test_file"; then unedited_files+=("$test_file"); fi
  done
  if [ "${#unedited_files[@]}" -gt 0 ]; then
    results+=("NOTE failing test files not edited by this branch: ${unedited_files[*]}")
  fi
}
