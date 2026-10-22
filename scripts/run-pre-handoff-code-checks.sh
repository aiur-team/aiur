#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base="${1:?base SHA required}"
pr_json="${2:-}"
head="$(git -C "$repo_root" rev-parse HEAD)"
scratch="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pre-handoff-code-checks.XXXXXX")"
evidence="$scratch/evidence"
active_pid=
active_command=
active_log=
interrupted=false
: > "$evidence"
# The terminal can vanish with the session; this file keeps the last known evidence.
result_file="$(git -C "$repo_root" rev-parse --absolute-git-dir)/aiur-pre-handoff/evidence.md"
echo "run-pre-handoff-code-checks: evidence file: $result_file"

# Atomic replace; an INCOMPLETE file outliving its pid means the run died without a trappable signal.
persist_evidence() {
  local temp_file="$result_file.tmp.$$"
  if ! { mkdir -p "${result_file%/*}" && {
      printf 'Status: %s\n' "$1"
      render_evidence
    } > "$temp_file" && mv -f "$temp_file" "$result_file"; } 2>/dev/null; then
    rm -f "$temp_file"
    echo "run-pre-handoff-code-checks: could not write evidence file $result_file" >&2
  fi
}

render_evidence() {
  echo '## Local tests evidence (paste into the PR body)'
  echo 'Policy: partial'
  printf 'Tested head: %s\n' "${tested_head:-$head}"
  printf 'Base: %s @ %s\n' "${AIUR_BASE_BRANCH:-main}" \
    "$(git -C "$repo_root" rev-parse "$base")"
  printf 'Selection: `mix aiur.affected_tests` selected %s test files using xref/module callers and shared-support consumers, plus pinned child-order tests for explicit child-list paths.\n' "${selected_count:-0}"
  cat "$evidence"
}

on_exit() {
  local status=$?
  [[ "$interrupted" == true ]] || persist_evidence "FINISHED (exit $status)"
  rm -rf "$scratch"
}
trap on_exit EXIT

# Without setsid the checks share our session, so a dead PTY's HUP reaches them;
# signal the whole tree for a TERM aimed at this pid alone.
kill_tree() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null || true); do kill_tree "$child"; done
  kill -TERM "$1" 2>/dev/null || true
}

handoff_interrupted() {
  local signal="$1" status
  status=$((128 + $(kill -l "$signal" 2>/dev/null || echo 1)))
  interrupted=true
  if [[ -n "$active_pid" ]]; then
    kill_tree "$active_pid"
    wait "$active_pid" 2>/dev/null || true
  fi
  if [[ -n "$active_command" ]]; then
    printf -- '- `%s` -> interrupted by %s (exit %s)\n' "$active_command" "$signal" "$status" >> "$evidence"
  fi
  persist_evidence "INTERRUPTED by $signal (exit $status)"
  printf 'run-pre-handoff-code-checks: INTERRUPTED by %s (exit %s); completed evidence follows\n' "$signal" "$status" >&2
  if [[ -f "$active_log" ]]; then cat "$active_log" >&2; fi
  if [[ -f "$evidence" ]]; then
    printf '%s\n' '--- Local tests evidence (partial; later checks not run) ---' >&2
    cat "$evidence" >&2
    printf '%s\n' '--- end Local tests evidence ---' >&2
  fi
  exit "$status"
}
trap 'handoff_interrupted INT' INT
trap 'handoff_interrupted TERM' TERM
trap 'handoff_interrupted HUP' HUP
persist_evidence "INCOMPLETE (pid $$ still running or ended without a result)"

git -C "$repo_root" diff --name-only "$base" "$head" -- > "$scratch/changed"
if [[ ! -s "$scratch/changed" ]]; then
  echo "run-pre-handoff-code-checks: no changed files"
  exit 0
fi

# mix aiur.affected_tests owns test-file selection. Keep only the pinned order
# checks below as an explicit path-based addition.
selector_paths=()
while IFS= read -r path; do
  case "$path" in
    src/*) selector_paths+=("$path") ;;
  esac
done < "$scratch/changed"
selector_paths_json="$(python3 - "${selector_paths[@]}" <<'PY'
import json, sys
print(json.dumps(sys.argv[1:]))
PY
)"
selector_paths_b64="$(printf '%s' "$selector_paths_json" | base64 | tr -d '\n')"
if (export AIUR_CI_CHANGED_PATHS_B64="$selector_paths_b64"; \
  cd "$repo_root/src" && mise exec -- mix aiur.affected_tests "$base") > "$scratch/selection"; then
  :
else
  status=$?
  echo "run-pre-handoff-code-checks: affected-test selector failed (exit $status)" >&2
  exit "$status"
fi
cat "$scratch/selection"
tests_file="$scratch/tests"
: > "$tests_file"
tested_head="$head"
if [[ -n "$pr_json" ]]; then
  tested_head="$(python3 - "$pr_json" "$head" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as source:
    pr = json.load(source)
print(pr.get("head", {}).get("sha", sys.argv[2]))
PY
)"
fi

record_result() {
  printf -- '- `%s` -> %s\n' "$1" "$2" >> "$evidence"
  persist_evidence "INCOMPLETE (pid $$ still running or ended without a result)"
}

print_evidence() {
  local block="$scratch/evidence-block.md"
  render_evidence > "$block"
  cat "$block"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then cat "$block" >> "$GITHUB_STEP_SUMMARY"; fi
}

run_check() {
  local command="$1"
  shift
  active_command="$command"
  active_log=
  (cd "$repo_root/src" && exec "$@") &
  active_pid=$!
  if wait "$active_pid"; then
    active_pid=
    active_command=
    record_result "$command" passed
  else
    local status=$?
    active_pid=
    active_command=
    record_result "$command" "failed (exit $status)"
    print_evidence
    exit "$status"
  fi
}

deferred=false
partition_fallback=false
defer_selection() {
  local notice="$1; deferred to the merge-queue full suite"
  echo "run-pre-handoff-code-checks: $notice"
  record_result 'mix aiur.affected_tests' "$notice"
  deferred=true
  : > "$tests_file"
}

selected_command() {
  python3 - "$@" <<'PY'
import shlex, sys
print(" ".join(shlex.quote(arg) for arg in sys.argv[1:]))
PY
}

while IFS= read -r line; do
  case "$line" in
    "cd src && mise exec -- mix test --max-cases 4 "*)
      python3 - "${line#cd src && mise exec -- }" >> "$tests_file" <<'PY'
import shlex, sys
command = shlex.split(sys.argv[1])
if command[:4] != ["mix", "test", "--max-cases", "4"]:
    raise SystemExit("unexpected affected-test command")
print("\n".join(command[4:]))
PY
      ;;
    "cd src && mise exec -- make ci"*)
      reason="$(sed -n 's/^# full suite recommended: //p' "$scratch/selection" | head -n 1)"
      partition_fallback=true
      selected_count="$(find "$repo_root/src/test" -name '*_test.exs' -type f | wc -l | tr -d ' ')"
      echo "run-pre-handoff-code-checks: full selection (${reason:-unsafe change}); running all 4 CI coverage partitions"
      record_result 'affected tests' "full selection (${selected_count} test files); ran all 4 CI coverage partitions"
      break
      ;;
  esac
done < "$scratch/selection"

run_order_tests=false
order_sensitive_paths=(
  src/lib/aiur/application/children.ex
  src/lib/aiur/experiments/auto.ex
  src/lib/aiur/opencode/bridge_supervisor.ex
  src/lib/aiur/opencode/prewarm_supervisor.ex
  src/lib/aiur/run_telemetry/supervisor.ex
  src/lib/aiur/usage_ledger.ex
  src/lib/aiur_web/financial_data/supervisor.ex
)
for path in "${order_sensitive_paths[@]}"; do
  if grep -Fxq "$path" "$scratch/changed"; then
    run_order_tests=true
    break
  fi
done

if [[ "$run_order_tests" == true ]]; then
  printf '%s\n' \
    test/aiur/build_order/component_test.exs \
    test/aiur/voice_quota_test.exs \
    test/aiur/application_child_order_test.exs >> "$tests_file"
fi

if [[ "$partition_fallback" != true ]]; then
  selected_count="$(grep -c . "$tests_file" || true)"
fi

if [[ "$partition_fallback" == true ]]; then
  tests=()
elif [[ -s "$tests_file" ]]; then
  sort -u "$tests_file" -o "$tests_file"
  mapfile -t tests < "$tests_file"
  selected_count="${#tests[@]}"
  if [[ ${#tests[@]} -gt 400 ]]; then
    partition_fallback=true
  fi
fi

if [[ "$partition_fallback" == true ]]; then
  if [[ "$selected_count" -gt 400 ]]; then
    echo "run-pre-handoff-code-checks: $selected_count affected files exceed the 400-file worker limit; running all 4 CI coverage partitions"
    record_result 'affected tests' "$selected_count selected files; ran all 4 CI coverage partitions"
  fi
  partition_failed=false
  for partition in 1 2 3 4; do
    active_command="MIX_TEST_ARGS='--max-cases 4' MIX_TEST_PARTITION=$partition TEST_PARTITIONS=4 nice -n 10 timeout --signal=TERM --kill-after=60s 60m mise exec -- make -C src coverage-partition"
    active_log="$scratch/partition-$partition.log"
    MIX_TEST_ARGS='--max-cases 4' MIX_TEST_PARTITION="$partition" TEST_PARTITIONS=4 \
      nice -n 10 timeout --signal=TERM --kill-after=60s 60m mise exec -- make -C "$repo_root/src" coverage-partition \
      > "$active_log" 2>&1 &
    active_pid=$!
    if wait "$active_pid"; then
      active_pid=
      active_command=
      record_result "MIX_TEST_ARGS='--max-cases 4' MIX_TEST_PARTITION=$partition TEST_PARTITIONS=4 nice -n 10 timeout --signal=TERM --kill-after=60s 60m mise exec -- make -C src coverage-partition" passed
      echo "run-pre-handoff-code-checks: coverage partition $partition/4 complete (passed)"
    else
      status=$?
      active_pid=
      active_command=
      record_result "MIX_TEST_ARGS='--max-cases 4' MIX_TEST_PARTITION=$partition TEST_PARTITIONS=4 nice -n 10 timeout --signal=TERM --kill-after=60s 60m mise exec -- make -C src coverage-partition" "failed (exit $status)"
      partition_failed=true
      echo "run-pre-handoff-code-checks: coverage partition $partition/4 complete (failed, exit $status)"
    fi
    cat "$active_log"
  done
  if [[ "$partition_failed" == true ]]; then print_evidence; exit 1; fi
elif [[ -s "$tests_file" ]]; then
  test_args=(mix test --max-cases 4 "${tests[@]}")
  command="$(selected_command nice -n 10 timeout --signal=TERM --kill-after=60s 60m mise exec -- "${test_args[@]}")"
  echo "run-pre-handoff-code-checks: running selected tests (${#tests[@]} files)"
  run_check "$command" nice -n 10 timeout --signal=TERM --kill-after=60s 60m mise exec -- "${test_args[@]}"
elif [[ "$deferred" == false ]]; then
  if grep -Eq '^src/test/support/|^src/test/test_helper\.exs$' "$scratch/changed"; then
    echo "run-pre-handoff-code-checks: shared test-support change selected no tests; refusing handoff" >&2
    record_result 'affected tests' 'failed: shared-support changes selected no tests'
    print_evidence
    exit 1
  fi
  echo "run-pre-handoff-code-checks: no affected tests selected"
  record_result 'mix aiur.affected_tests' 'no affected test files selected'
fi

if grep -q '^src/lib/' "$scratch/changed"; then
  echo "run-pre-handoff-code-checks: running dialyzer for src/lib changes"
  run_check 'timeout --signal=TERM --kill-after=60s 15m mise exec -- mix dialyzer' \
    timeout --signal=TERM --kill-after=60s 15m mise exec -- mix dialyzer
fi

print_evidence
