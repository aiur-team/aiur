#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base="${1:?base SHA required}"
pr_json="${2:-}"
head="$(git -C "$repo_root" rev-parse HEAD)"
scratch="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pre-handoff-code-checks.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

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
evidence="$scratch/evidence"
: > "$tests_file"
: > "$evidence"
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
}

print_evidence() {
  local block="$scratch/evidence-block.md"
  {
    echo '## Local tests evidence (paste into the PR body)'
    echo 'Policy: partial'
    printf 'Tested head: %s\n' "$tested_head"
    printf 'Base: %s @ %s\n' "${AIUR_BASE_BRANCH:-main}" \
      "$(git -C "$repo_root" rev-parse "$base")"
    printf 'Selection: `mix aiur.affected_tests` selected %s test files using xref/module callers and shared-support consumers, plus pinned child-order tests for explicit child-list paths.\n' "${selected_count:-0}"
    cat "$evidence"
  } > "$block"
  cat "$block"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then cat "$block" >> "$GITHUB_STEP_SUMMARY"; fi
}

in_src() { (cd "$repo_root/src" && "$@"); }

run_check() {
  local command="$1"
  shift
  if in_src "$@"; then
    record_result "$command" passed
  else
    local status=$?
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
    if MIX_TEST_ARGS='--max-cases 4' MIX_TEST_PARTITION="$partition" TEST_PARTITIONS=4 \
      nice -n 10 timeout --signal=TERM --kill-after=60s 60m mise exec -- make -C "$repo_root/src" coverage-partition \
      > "$scratch/partition-$partition.log" 2>&1; then
      record_result "MIX_TEST_ARGS='--max-cases 4' MIX_TEST_PARTITION=$partition TEST_PARTITIONS=4 nice -n 10 timeout --signal=TERM --kill-after=60s 60m mise exec -- make -C src coverage-partition" passed
    else
      status=$?
      record_result "MIX_TEST_ARGS='--max-cases 4' MIX_TEST_PARTITION=$partition TEST_PARTITIONS=4 nice -n 10 timeout --signal=TERM --kill-after=60s 60m mise exec -- make -C src coverage-partition" "failed (exit $status)"
      partition_failed=true
    fi
    cat "$scratch/partition-$partition.log"
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
