#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/aiur-classify-ci.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
mkdir "$test_dir/bin"
cat > "$test_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
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
printf '#!/bin/sh\nexit 1\n' > "$test_dir/failbin/elixir"
chmod +x "$test_dir/bin/gh" "$test_dir/bin/git" "$test_dir/failbin/elixir"
cat > "$test_dir/bin/elixir" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${TEST_SELECTOR:-}" ]]; then
  [[ "$TEST_SELECTOR" != fail ]] || exit 1
  echo "$TEST_SELECTOR"
else
  echo scoped:1
fi
STUB
chmod +x "$test_dir/bin/elixir"
classify() {
  : > "$test_dir/out"
  EVENT_NAME="$1" TEST_DRAFT="$2" TEST_FILES="$3" TEST_LABELS="${4:-[]}" \
    TEST_SELECTOR="${5:-scoped:1}" TEST_OVERSIZED_PATHS="${6:-false}" \
    REPO=o/r PR_NUMBER=7 \
    GITHUB_OUTPUT="$test_dir/out" GITHUB_STEP_SUMMARY="$test_dir/summary" \
    PATH="$test_dir/bin:$PATH" bash "$root/scripts/classify-ci-changes.sh" || return $?
  grep -E '^(full_ci|docs_only)=' "$test_dir/out" | sort | paste -sd' ' -
}
expect() {
  local want="$1" got; shift
  got="$(classify "$@")"
  [[ "$got" == "$want" ]] || { echo "expected '$want', got '$got'" >&2; exit 1; }
}
for draft in true false; do
  expect 'docs_only=false full_ci=false' pull_request "$draft" '[{"filename":"src/lib/aiur/config.ex"}]'
  grep -Fxq 'dialyzer=true' "$test_dir/out"
  expect 'docs_only=true full_ci=false' pull_request "$draft" '[{"filename":"website/docs-app/guide/a.md"}]'
  grep -Fxq 'dialyzer=false' "$test_dir/out"
  expect 'docs_only=false full_ci=true' pull_request "$draft" '[{"filename":".github/workflows/ci.yml"}]'
  expect 'docs_only=false full_ci=true' pull_request "$draft" '[{"filename":"src/mix.lock"}]'
  expect 'docs_only=false full_ci=true' pull_request "$draft" '[{"filename":"mix.lock"}]'
  expect 'docs_only=false full_ci=true' pull_request "$draft" '[{"filename":"website/new.md","previous_filename":"src/mix.exs"}]'
  expect 'docs_only=false full_ci=true' pull_request "$draft" '[{"filename":"website/new.md"}]' '[{"name":"MAIN-FIX"}]'
  expect 'docs_only=false full_ci=true' pull_request "$draft" '[{"filename":"website/new.md"}]' '[{"name":"urgent"}]'
  expect 'docs_only=false full_ci=true' pull_request false '[{"filename":"src/lib/aiur/config.ex"}]' '[{"name":"CI:FULL"}]'
  expect 'docs_only=false full_ci=true' pull_request "$draft" '[]'
  expect 'docs_only=false full_ci=true' pull_request "$draft" '[{"filename":"src/test/support/helper.exs"}]' '[]' full
  expect 'docs_only=false full_ci=true' pull_request "$draft" '[{"filename":"scripts/example.sh"}]' '[]' full
done
expect 'docs_only=false full_ci=false' pull_request false '[{"filename":"src/lib/aiur/config.exs"}]'
grep -Fxq 'dialyzer=false' "$test_dir/out"
for path in scripts/check-ci-gate.py scripts/classify-ci-changes.sh scripts/ci-policy.rb scripts/ci-test-selection.exs scripts/run-ci-affected-tests.py src/lib/aiur/affected_tests.ex src/lib/mix/tasks/aiur.affected_tests.ex; do
  expect 'docs_only=false full_ci=true' pull_request false "[{\"filename\":\"$path\"}]"
done
for event in push merge_group workflow_dispatch; do
  if [[ "$event" == push ]]; then
    GITHUB_REF=refs/heads/v2 expect 'docs_only=false full_ci=true' "$event" true '[]'
  else
    expect 'docs_only=false full_ci=true' "$event" true '[]'
  fi
done
GITHUB_REF=refs/heads/main expect 'docs_only=false full_ci=true' push true '[]'
GITHUB_REF=refs/heads/main expect 'docs_only=false full_ci=false' schedule true '[]'
GITHUB_REF=refs/heads/v2 expect 'docs_only=false full_ci=true' push true '[]'
TEST_BIGPATCH=true expect 'docs_only=false full_ci=false' pull_request false '[]'
TEST_LEGACY=true expect 'docs_only=false full_ci=true' pull_request false '[{"filename":"website/new.md"}]'
TEST_LEGACY=true expect 'docs_only=false full_ci=true' pull_request false '[{"filename":"src/lib/aiur/config.ex"}]'
TEST_FILE_CAP=true expect 'docs_only=false full_ci=true' pull_request false '[]'
expect 'docs_only=false full_ci=true' pull_request false '[]' '[]' '' true
expect 'docs_only=false full_ci=true' pull_request false '[{"filename":"src/lib/aiur/config.ex"}]' '[]' scoped:401
classify pull_request false '[{"filename":"src/test/aiur/config_test.exs"},{"filename":"src/lib/aiur/config.ex"}]' >/dev/null
expected_paths="$(printf '["src/lib/aiur/config.ex","src/test/aiur/config_test.exs"]' | base64 -w0)"
grep -Fxq "affected_paths_b64=$expected_paths" "$test_dir/out"
if classify pull_request false '[{"filename":"src/lib/aiur/config.ex"}]' '[]' fail >/dev/null; then
  echo 'selector failure must not publish a fast classification' >&2
  exit 1
fi
workflow="$root/.github/workflows/ci.yml"
! grep -q 'outputs.draft\|pull_request.draft' "$workflow"
grep -Eq 'outputs:.*full_ci:.*steps\.classify\.outputs\.full_ci' "$workflow"
grep -Eq 'outputs:.*affected_paths_b64:.*steps\.classify\.outputs\.affected_paths_b64' "$workflow"
grep -Fq 'run: bash scripts/classify-ci-changes.sh' "$workflow"
grep -Fq 'run: bash scripts/test-classify-ci-changes.sh' "$workflow"
echo 'CI classifier event, policy, rename and draft tests passed'
