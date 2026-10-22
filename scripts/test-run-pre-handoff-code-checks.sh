#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/pre-handoff-code-checks-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fixture="$tmp/repo"
mkdir -p "$fixture/scripts" "$fixture/src/test/aiur/github" "$tmp/bin"
cp "$repo_root/scripts/run-pre-handoff-code-checks.sh" "$fixture/scripts/"
touch "$fixture/src/test/aiur/foo_test.exs" "$fixture/src/test/aiur/github/subsystem_test.exs"

cat > "$tmp/bin/git" <<'GIT'
#!/usr/bin/env bash
case "$*" in
  *"diff --name-only"*) printf '%s\n' "$CHANGED_PATHS" ;;
  *"rev-parse HEAD"*) printf '%s\n' "$HEAD_SHA" ;;
  *"rev-parse $BASE_SHA"*) printf '%s\n' "$BASE_SHA" ;;
  *) echo "unexpected git args: $*" >&2; exit 90 ;;
esac
GIT

cat > "$tmp/bin/mix" <<'MIX'
#!/usr/bin/env bash
case "$*" in
  "aiur.affected_tests "*)
    printf 'selector:%s\n' "${AIUR_CI_CHANGED_PATHS_B64:-}" >> "$COMMAND_LOG"
    if [[ "$CHANGED_PATHS" == *empty-support* ]]; then
      printf '%s\n' '# no affected test files detected for the documentation-only change'
      exit 0
    fi
    if [[ "$CHANGED_PATHS" == *src/test/support/test_support.exs ]]; then
      printf 'cd src && mise exec -- mix test --max-cases 4 test/consumer_a_test.exs test/consumer_b_test.exs\n'
      exit 0
    fi
    if [[ "$CHANGED_PATHS" == *src/test/support/* || "$CHANGED_PATHS" == *src/mix.exs || "$CHANGED_PATHS" == *src/mix.lock || "$CHANGED_PATHS" == *src/config/* ]]; then
      printf '%s\n' '# full suite recommended: shared test support changed' 'cd src && mise exec -- make ci'
      exit 0
    fi
    if [[ "$CHANGED_PATHS" == *src/examples/workflows/* ]]; then
      printf '%s\n' '# full suite recommended: unclassified workflow fixture changed' 'cd src && mise exec -- make ci'
      exit 0
    fi
    if [[ "$CHANGED_PATHS" == *overcap* ]]; then
      printf 'cd src && mise exec -- mix test --max-cases 4'
      printf ' test/aiur/over_%s_test.exs' $(seq 401)
      printf '\n'
      exit 0
    fi
    if [[ "$(printf '%s' "${AIUR_CI_CHANGED_PATHS_B64:-}" | base64 --decode)" == '[]' ]]; then
      printf '%s\n' 'cd src && mise exec -- mix test --max-cases 4'
      exit 0
    fi
    printf '%s\n' "cd src && mise exec -- mix test --max-cases 4 'test/aiur/foo test.exs'"
    ;;
  pr_body.check*) printf 'body-check\n' >> "$COMMAND_LOG" ;;
  "test --max-cases 4 "*)
    printf 'test:%s\n' "$*" >> "$COMMAND_LOG"
    [[ "${FAIL_TEST:-}" != true ]]
    ;;
  dialyzer)
    printf 'dialyzer\n' >> "$COMMAND_LOG"
    [[ "${FAIL_DIALYZER:-}" != true ]]
    ;;
  "make ci")
    printf 'make-ci\n' >> "$COMMAND_LOG"
    [[ "${FAIL_FULL_CI:-}" != true ]]
    ;;
  *) echo "unexpected mix args: $*" >&2; exit 91 ;;
esac
MIX

cat > "$tmp/bin/mise" <<'MISE'
#!/usr/bin/env bash
[[ "$1 $2" == "exec --" ]] || exit 92
shift 2
exec "$@"
MISE
cat > "$tmp/bin/make" <<'MAKE'
#!/usr/bin/env bash
if [[ "$*" == "ci" ]]; then
  printf 'make-ci\n' >> "$COMMAND_LOG"
  [[ "${FAIL_FULL_CI:-}" != true ]]
elif [[ "$*" == "-C "*" coverage-partition" ]]; then
  [[ "$MIX_TEST_ARGS" == '--max-cases 4' ]] || exit 96
  printf 'makeargs:%s\n' "$MIX_TEST_ARGS" >> "$COMMAND_LOG"
  printf 'partition:%s/4\n' "$MIX_TEST_PARTITION" >> "$COMMAND_LOG"
  [[ "${FAIL_PARTITION:-}" != "$MIX_TEST_PARTITION" ]]
else
  echo "unexpected make args: $*" >&2
  exit 93
fi
MAKE
cat > "$tmp/bin/timeout" <<'TIMEOUT'
#!/usr/bin/env bash
printf 'timeout:%s\n' "$*" >> "$COMMAND_LOG"
[[ "$1" == --signal=TERM && "$2" == --kill-after=60s ]] || exit 94
if [[ -n "${TIMEOUT_EXIT:-}" ]]; then
  exit "$TIMEOUT_EXIT"
fi
shift 3
exec "$@"
TIMEOUT
cat > "$tmp/bin/nice" <<'NICE'
#!/usr/bin/env bash
[[ "$1 $2" == "-n 10" ]] || exit 95
printf 'nice:%s\n' "$*" >> "$COMMAND_LOG"
shift 2
exec "$@"
NICE
chmod +x "$tmp/bin/git" "$tmp/bin/mix" "$tmp/bin/mise" "$tmp/bin/make" "$tmp/bin/timeout" "$tmp/bin/nice" "$fixture/scripts/run-pre-handoff-code-checks.sh"

base="$(printf 'a%.0s' {1..40})"
head="$(printf 'b%.0s' {1..40})"
run_check() {
  local name="$1" changed="$2" fail_test="$3" fail_dialyzer="$4" pr_json="${5:-}" fail_full_ci="${6:-false}" timeout_exit="${7:-}"
  : > "$tmp/$name.commands"
  if env BASH_ENV=/dev/null PATH="$tmp/bin:$PATH" TMPDIR="$tmp" COMMAND_LOG="$tmp/$name.commands" \
      CHANGED_PATHS="$changed" HEAD_SHA="$head" BASE_SHA="$base" \
      FAIL_TEST="$fail_test" FAIL_DIALYZER="$fail_dialyzer" FAIL_FULL_CI="$fail_full_ci" TIMEOUT_EXIT="$timeout_exit" \
      bash "$fixture/scripts/run-pre-handoff-code-checks.sh" "$base" ${pr_json:+"$pr_json"} > "$tmp/$name.log" 2>&1; then
    return 0
  else
    return 1
  fi
}

if run_check failing_test src/lib/aiur/github/foo.ex true false; then
  echo 'test-run-pre-handoff-code-checks: expected failing selected test to refuse handoff' >&2
  exit 1
fi
grep -F 'test:' "$tmp/failing_test.commands" >/dev/null
grep -F 'foo test.exs' "$tmp/failing_test.commands" >/dev/null
if grep -F 'subsystem_test.exs' "$tmp/failing_test.commands" >/dev/null; then
  echo 'test-run-pre-handoff-code-checks: selector added subsystem-wide files outside mix aiur.affected_tests' >&2
  exit 1
fi
grep -F 'nice:-n 10 timeout --signal=TERM --kill-after=60s 60m mise exec -- mix test --max-cases 4 test/aiur/foo test.exs' "$tmp/failing_test.commands" >/dev/null
encoded_paths="$(grep '^selector:' "$tmp/failing_test.commands" | cut -d: -f2-)"
decoded_paths="$(printf '%s' "$encoded_paths" | base64 --decode)"
[[ "$decoded_paths" == '["src/lib/aiur/github/foo.ex"]' ]]
if grep -F 'dialyzer' "$tmp/failing_test.commands" >/dev/null; then
  echo 'test-run-pre-handoff-code-checks: Dialyzer ran after selected tests failed' >&2
  exit 1
fi

if run_check failing_dialyzer src/lib/aiur/foo.ex false true; then
  echo 'test-run-pre-handoff-code-checks: expected Dialyzer failure to refuse handoff' >&2
  exit 1
fi
grep -F 'dialyzer' "$tmp/failing_dialyzer.commands" >/dev/null
grep -Fx 'timeout:--signal=TERM --kill-after=60s 15m mise exec -- mix dialyzer' "$tmp/failing_dialyzer.commands" >/dev/null

if run_check interrupted_test src/lib/aiur/github/foo.ex false false "" false 124; then
  echo 'test-run-pre-handoff-code-checks: timed out tests must refuse handoff' >&2
  exit 1
fi
grep -F 'failed (exit 124)' "$tmp/interrupted_test.log" >/dev/null

if ! run_check child_order src/lib/aiur/application/children.ex false false; then
  cat "$tmp/child_order.log" >&2
  echo 'test-run-pre-handoff-code-checks: explicit child-list path was rejected' >&2
  exit 1
fi
grep -F 'application_child_order_test.exs' "$tmp/child_order.commands" >/dev/null
grep -F 'voice_quota_test.exs' "$tmp/child_order.commands" >/dev/null
grep -F 'component_test.exs' "$tmp/child_order.commands" >/dev/null

if ! run_check passing src/lib/aiur/github/foo.ex false false; then
  cat "$tmp/passing.log" >&2
  echo 'test-run-pre-handoff-code-checks: passing checks were rejected' >&2
  exit 1
fi

# Unsafe selections use CI partitions; large scoped selections also use partitions.
if ! run_check full_suite src/test/support/factory.ex false false "" true; then
  cat "$tmp/full_suite.log" >&2
  echo 'test-run-pre-handoff-code-checks: full-suite selection refused handoff' >&2
  exit 1
fi
[[ "$(grep -c '^partition:' "$tmp/full_suite.commands")" == 4 ]]
grep -F 'full selection (shared test support changed)' "$tmp/full_suite.log" >/dev/null
grep -F 'all 4 CI coverage partitions' "$tmp/full_suite.log" >/dev/null
[[ "$(grep -c '^makeargs:--max-cases 4$' "$tmp/full_suite.commands")" == 4 ]]

if ! run_check unknown_full src/examples/workflows/demo.yaml false false; then
  cat "$tmp/unknown_full.log" >&2
  echo 'test-run-pre-handoff-code-checks: unsafe non-support full selection did not run partitions' >&2
  exit 1
fi
[[ "$(grep -c '^partition:' "$tmp/unknown_full.commands")" == 4 ]]
grep -F 'full selection (unclassified workflow fixture changed)' "$tmp/unknown_full.log" >/dev/null

if ! run_check over_cap src/lib/aiur/overcap.ex false false; then
  cat "$tmp/over_cap.log" >&2
  echo 'test-run-pre-handoff-code-checks: over-cap selection refused handoff' >&2
  exit 1
fi
grep -F '401 affected files exceed the 400-file worker limit' "$tmp/over_cap.log" >/dev/null
[[ "$(grep -c '^partition:' "$tmp/over_cap.commands")" == 4 ]]
[[ "$(grep -c '^makeargs:--max-cases 4$' "$tmp/over_cap.commands")" == 4 ]]
grep -Fx 'timeout:--signal=TERM --kill-after=60s 15m mise exec -- mix dialyzer' "$tmp/over_cap.commands" >/dev/null

if ! run_check shared_support src/test/support/test_support.exs false false; then
  cat "$tmp/shared_support.log" >&2
  echo 'test-run-pre-handoff-code-checks: shared-support consumers were not run' >&2
  exit 1
fi
grep -F 'consumer_a_test.exs' "$tmp/shared_support.commands" >/dev/null
grep -F 'consumer_b_test.exs' "$tmp/shared_support.commands" >/dev/null
grep -F 'selected 2 test files' "$tmp/shared_support.log" >/dev/null
grep -F 'nice:-n 10 timeout --signal=TERM --kill-after=60s 60m mise exec -- mix test --max-cases 4 test/consumer_a_test.exs test/consumer_b_test.exs' "$tmp/shared_support.commands" >/dev/null

if run_check empty_shared_support src/test/support/empty-support.exs false false; then
  echo 'test-run-pre-handoff-code-checks: shared-support change with no selected tests must refuse handoff' >&2
  exit 1
fi
grep -F 'shared test-support change selected no tests; refusing handoff' "$tmp/empty_shared_support.log" >/dev/null

if ! run_check script_only scripts/run-pre-handoff-code-checks.sh false false; then
  cat "$tmp/script_only.log" >&2
  echo 'test-run-pre-handoff-code-checks: script-only changes were rejected' >&2
  exit 1
fi
grep -F 'selector:W10=' "$tmp/script_only.commands" >/dev/null
grep -F 'no affected tests selected' "$tmp/script_only.log" >/dev/null

pr_json="$tmp/pr.json"
python3 - "$pr_json" "$head" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump({"head": {"sha": sys.argv[2]}, "body": "## Local tests\nPolicy: partial\nTested head: " + "a" * 40 + "\nBase: main @ " + "a" * 40 + "\nSelection: previous\n- `mix test` -> previous\n"}, output)
PY
if ! run_check evidence src/lib/aiur/foo.ex false false "$pr_json"; then
  cat "$tmp/evidence.log" >&2
  echo 'test-run-pre-handoff-code-checks: evidence output failed' >&2
  exit 1
fi
python3 - "$pr_json" "$head" <<'PY'
import json, sys
pr = json.load(open(sys.argv[1], encoding="utf-8"))
assert pr["body"] == "## Local tests\nPolicy: partial\nTested head: " + "a" * 40 + "\nBase: main @ " + "a" * 40 + "\nSelection: previous\n- `mix test` -> previous\n"
PY
grep -F '## Local tests evidence (paste into the PR body)' "$tmp/evidence.log" >/dev/null
grep -F "Tested head: $head" "$tmp/evidence.log" >/dev/null
grep -F 'mix aiur.affected_tests' "$tmp/evidence.log" >/dev/null
grep -F -- '- `timeout --signal=TERM --kill-after=60s 15m mise exec -- mix dialyzer` -> passed' "$tmp/evidence.log" >/dev/null

echo 'test-run-pre-handoff-code-checks: selected test and Dialyzer failures refuse handoff'
