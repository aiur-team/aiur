#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/aiur-classify-ci.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/workspace/src"
cat > "$test_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  'pr view 7 --repo o/r --json reviewDecision --jq .reviewDecision') echo "${TEST_REVIEW-APPROVED}" ;;
  *'/rules/branches/'*)
    if [[ "${TEST_LEGACY:-false}" == true ]]; then
      echo '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"test"}]}}]'
    else
      echo '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci gate"}]}}]'
    fi ;;
  *'/files'*)
    if [[ "${TEST_OVERSIZED_PATHS:-false}" == true ]]; then
      python3 -c 'import json; print(json.dumps([[{"filename":"src/test/aiur/affected_tests_test.exs","previous_filename":"docs/"+str(i)+"x"*1000+".md"} for i in range(1000)]]))'
    elif [[ "${TEST_BIGPATCH:-false}" == true ]]; then
      python3 -c 'import json; print(json.dumps([[{"filename":"src/lib/aiur/config.ex","patch":"x"*200000}]]))'
    elif [[ "${TEST_FILE_CAP:-false}" == true ]]; then
      python3 -c 'import json; print(json.dumps([[{"filename":"website/docs-app/guide/a.md"}]*3000]))'
    else
      printf '[%s]\n' "$TEST_FILES"
    fi ;;
  *) printf '{"base":{"sha":"base-sha","ref":"main"},"labels":%s,"draft":%s}\n' "$TEST_LABELS" "$TEST_DRAFT" ;;
esac
STUB
cat > "$test_dir/bin/git" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == *'base-sha:.aiur/config' ]] || exit 2
cat <<'YAML'
merge_policy:
  full_ci_labels: [main-fix, urgent]
  full_ci_paths: [".github/workflows/**", "src/mix.exs", "**/mix.lock"]
YAML
STUB
mkdir "$test_dir/failbin"
printf '#!/bin/sh\nexit 1\n' > "$test_dir/failbin/mix"
cat > "$test_dir/failbin/mix" <<'STUB'
#!/usr/bin/env bash
echo 'fixture selector diagnostic' >&2
exit 1
STUB
chmod +x "$test_dir/bin/gh" "$test_dir/bin/git" "$test_dir/failbin/mix"
cat > "$test_dir/bin/mix" <<'STUB'
#!/usr/bin/env bash
[[ "$PWD" == */src ]] || { echo "selection ran from unexpected directory: $PWD" >&2; exit 3; }
[[ "$1 $2 $3" == 'run --no-start ../scripts/ci-test-selection.exs' ]] || { echo "unexpected Mix arguments: $*" >&2; exit 4; }
if [[ "${TEST_FAIL_SELECTOR:-false}" == true ]]; then
  echo 'fixture selector diagnostic' >&2
  exit 1
fi
# A cold _build makes Mix print compile output before the result line.
printf '==> aiur\nCompiling 3 files (.ex)\nGenerated aiur app\n'
if [[ -n "${TEST_SELECTOR:-}" ]]; then
  echo "$TEST_SELECTOR" >> "$GITHUB_STEP_SUMMARY"
  echo "$TEST_SELECTOR"
  if [[ "${TEST_SELECTOR_TRAILING_NOISE:-false}" == true ]]; then
    echo 'Generated trailing compile output'
  fi
else
  echo scoped:1
fi
STUB
chmod +x "$test_dir/bin/mix"
classify() {
  : > "$test_dir/out"
  : > "$test_dir/summary"
  EVENT_NAME="$1" TEST_DRAFT="$2" TEST_FILES="$3" TEST_LABELS="${4:-[]}" \
    TEST_SELECTOR="${5:-scoped:1}" TEST_OVERSIZED_PATHS="${6:-false}" TEST_FAIL_SELECTOR="${7:-false}" \
    REPO=o/r PR_NUMBER=7 \
    GITHUB_WORKSPACE="$test_dir/workspace" \
    GITHUB_OUTPUT="$test_dir/out" GITHUB_STEP_SUMMARY="$test_dir/summary" MIX_BIN="$test_dir/bin/mix" \
    PATH="$test_dir/bin:$PATH" bash "$root/scripts/classify-ci-changes.sh" || return $?
  grep -E '^(full_ci|docs_only|browser_smoke)=' "$test_dir/out" | sort | paste -sd' ' -
}
expect() {
  local want="$1" got; shift
  got="$(classify "$@")"
  [[ "$got" == "$want" ]] || { echo "expected '$want', got '$got'" >&2; exit 1; }
}
for draft in true false; do
  expect 'browser_smoke=false docs_only=false full_ci=false' pull_request "$draft" '[{"filename":"src/lib/aiur/config.ex"}]'
  grep -Fxq 'dialyzer=true' "$test_dir/out"
  expect 'browser_smoke=false docs_only=true full_ci=false' pull_request "$draft" '[{"filename":"website/docs-app/guide/a.md"}]'
  grep -Fxq 'dialyzer=false' "$test_dir/out"
  expect 'browser_smoke=true docs_only=false full_ci=true' pull_request "$draft" '[{"filename":".github/workflows/ci.yml"}]'
  expect 'browser_smoke=false docs_only=false full_ci=true' pull_request "$draft" '[{"filename":"src/mix.lock"}]'
  expect 'browser_smoke=false docs_only=false full_ci=true' pull_request "$draft" '[{"filename":"mix.lock"}]'
  expect 'browser_smoke=false docs_only=false full_ci=true' pull_request "$draft" '[{"filename":"website/new.md","previous_filename":"src/mix.exs"}]'
  expect 'browser_smoke=false docs_only=false full_ci=true' pull_request "$draft" '[{"filename":"website/new.md"}]' '[{"name":"MAIN-FIX"}]'
  expect 'browser_smoke=false docs_only=false full_ci=true' pull_request "$draft" '[{"filename":"website/new.md"}]' '[{"name":"urgent"}]'
  expect 'browser_smoke=false docs_only=false full_ci=true' pull_request false '[{"filename":"src/lib/aiur/config.ex"}]' '[{"name":"CI:FULL"}]'
  expect 'browser_smoke=false docs_only=false full_ci=true' pull_request "$draft" '[]'
  expect 'browser_smoke=false docs_only=false full_ci=true' pull_request "$draft" '[{"filename":"src/test/support/helper.exs"}]' '[]' full
  expect 'browser_smoke=false docs_only=false full_ci=true' pull_request "$draft" '[{"filename":"scripts/example.sh"}]' '[]' full
done
for path in src/browser/tests/example.browser.spec.mjs src/lib/aiur_web/router.ex src/priv/static/js/app.js; do
  expect 'browser_smoke=true docs_only=false full_ci=false' pull_request false "[{\"filename\":\"$path\"}]"
done
for path in .github/workflows/ci.yml scripts/check-ci-gate.py scripts/ci-policy.rb scripts/classify-ci-changes.sh; do
  expect 'browser_smoke=true docs_only=false full_ci=true' pull_request false "[{\"filename\":\"$path\"}]"
done
expect 'browser_smoke=false docs_only=false full_ci=false' pull_request false '[{"filename":"src/lib/aiur/orchestrator.ex"}]'
expect 'browser_smoke=false docs_only=false full_ci=false' pull_request false '[{"filename":"src/lib/aiur/config.exs"}]'
grep -Fxq 'dialyzer=false' "$test_dir/out"
for path in scripts/ci-test-selection.exs scripts/run-ci-affected-tests.py src/lib/aiur/affected_tests.ex src/lib/mix/tasks/aiur.affected_tests.ex; do
  expect 'browser_smoke=false docs_only=false full_ci=true' pull_request false "[{\"filename\":\"$path\"}]"
done
for event in push workflow_dispatch; do
  if [[ "$event" == push ]]; then
    GITHUB_REF=refs/heads/v2 expect 'browser_smoke=true docs_only=false full_ci=true' "$event" true '[]'
  else
    expect 'browser_smoke=true docs_only=false full_ci=true' "$event" true '[]'
  fi
done
GITHUB_REF=refs/heads/main expect 'browser_smoke=true docs_only=false full_ci=true' push true '[]'
GITHUB_REF=refs/heads/main expect 'browser_smoke=false docs_only=false full_ci=false' schedule true '[]'
GITHUB_REF=refs/heads/v2 expect 'browser_smoke=true docs_only=false full_ci=true' push true '[]'
TEST_BIGPATCH=true expect 'browser_smoke=false docs_only=false full_ci=false' pull_request false '[]'
TEST_LEGACY=true expect 'browser_smoke=false docs_only=false full_ci=true' pull_request false '[{"filename":"website/new.md"}]'
TEST_LEGACY=true expect 'browser_smoke=false docs_only=false full_ci=true' pull_request false '[{"filename":"src/lib/aiur/config.ex"}]'
TEST_FILE_CAP=true expect 'browser_smoke=false docs_only=false full_ci=true' pull_request false '[]'
expect 'browser_smoke=false docs_only=false full_ci=true' pull_request false '[]' '[]' '' true
expect 'browser_smoke=false docs_only=false full_ci=true' pull_request false '[{"filename":"src/lib/aiur/config.ex"}]' '[]' scoped:401
expect 'browser_smoke=false docs_only=false full_ci=false' pull_request false '[{"filename":"src/lib/aiur/config.ex"}]' '[]' scoped:400
TEST_SELECTOR_TRAILING_NOISE=true expect 'browser_smoke=false docs_only=false full_ci=false' pull_request false '[{"filename":"src/lib/aiur/config.ex"}]' '[]' scoped:1
TEST_SELECTOR_TRAILING_NOISE=true expect 'browser_smoke=false docs_only=false full_ci=true' pull_request false '[{"filename":"src/lib/aiur/config.ex"}]' '[]' full
classify pull_request false '[{"filename":"src/lib/aiur/config.ex"}]' >/dev/null
grep -Fxq 'scoped:1' "$test_dir/summary"
classify pull_request false '[{"filename":"src/test/aiur/config_test.exs"},{"filename":"src/lib/aiur/config.ex"}]' >/dev/null
expected_paths="$(printf '["src/lib/aiur/config.ex","src/test/aiur/config_test.exs"]' | base64 -w0)"
grep -Fxq "affected_paths_b64=$expected_paths" "$test_dir/out"
classify pull_request false '[{"filename":"src/lib/aiur/config.ex"}]' '[]' scoped:1 false true >/dev/null
grep -Fq 'fixture selector diagnostic' "$test_dir/summary"
grep -Fq '```text' "$test_dir/summary"
grep -Fq '### Affected-test selection warning' "$test_dir/summary"
# Unapproved heads run the fast set unless a full-CI label is present.
for review in REVIEW_REQUIRED CHANGES_REQUESTED ''; do
  for path in .github/workflows/ci.yml src/mix.lock scripts/ci-policy.rb src/browser/tests/example.browser.spec.mjs; do
    TEST_REVIEW="$review" expect 'browser_smoke=false docs_only=false full_ci=false' pull_request false "[{\"filename\":\"$path\"}]"
    grep -Fxq 'dialyzer=false' "$test_dir/out"
  done
  TEST_REVIEW="$review" expect 'browser_smoke=false docs_only=false full_ci=false' pull_request false '[{"filename":"src/lib/aiur/config.ex"}]'
  grep -Fxq 'dialyzer=false' "$test_dir/out"
  grep -Fq 'fast checks only' "$test_dir/summary"
  TEST_REVIEW="$review" expect 'browser_smoke=false docs_only=false full_ci=false' pull_request false '[{"filename":"src/test/support/helper.exs"}]' '[]' full
  TEST_REVIEW="$review" expect 'browser_smoke=false docs_only=false full_ci=false' pull_request false '[{"filename":"src/lib/aiur/config.ex"}]' '[]' scoped:401
  TEST_REVIEW="$review" expect 'browser_smoke=false docs_only=true full_ci=false' pull_request false '[{"filename":"website/docs-app/guide/a.md"}]'
  TEST_REVIEW="$review" expect 'browser_smoke=true docs_only=false full_ci=true' pull_request false '[{"filename":".github/workflows/ci.yml"}]' '[{"name":"ci:full"}]'
  TEST_REVIEW="$review" expect 'browser_smoke=false docs_only=false full_ci=true' pull_request false '[{"filename":"src/lib/aiur/config.ex"}]' '[{"name":"main-fix"}]'
  TEST_REVIEW="$review" expect 'browser_smoke=false docs_only=false full_ci=true' pull_request false '[]'
  TEST_REVIEW="$review" TEST_FILE_CAP=true expect 'browser_smoke=false docs_only=false full_ci=true' pull_request false '[]'
  TEST_REVIEW="$review" TEST_LEGACY=true expect 'browser_smoke=false docs_only=false full_ci=true' pull_request false '[{"filename":"src/lib/aiur/config.ex"}]'
done
TEST_REVIEW=APPROVED expect 'browser_smoke=false docs_only=false full_ci=false' pull_request false '[{"filename":"src/lib/aiur/config.ex"}]'
! grep -Fq 'fast checks only' "$test_dir/summary"
workflow="$root/.github/workflows/ci.yml"
! grep -q 'outputs.draft\|pull_request.draft' "$workflow"
grep -Fq 'uses: ./.github/actions/setup-elixir' "$workflow"
grep -Eq 'outputs:.*full_ci:.*steps\.classify\.outputs\.full_ci' "$workflow"
grep -Eq 'outputs:.*affected_paths_b64:.*steps\.classify\.outputs\.affected_paths_b64' "$workflow"
grep -Fq 'run: bash scripts/classify-ci-changes.sh' "$workflow"
grep -Fq "needs.changes.outputs.browser_smoke == 'true'" "$workflow"
grep -Fq 'run: bash scripts/test-classify-ci-changes.sh' "$workflow"
echo 'CI classifier event, policy, rename and draft tests passed'
