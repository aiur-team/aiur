#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
reporter="$root/scripts/report-known-flaky-tests.sh"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/aiur-known-flaky-report.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

cat >"$test_dir/sample.log" <<'LOG'
Running ExUnit with seed: 123456, max_cases: 4
Excluding tags: [:external, :perf_regression, :quarantine]
..........................................................................
  1) test normalize_issue/4 marks malformed configured repositories explicitly nonjoinable (Aiur.GitHub.IssuesTest)
     test/aiur/github/issues_test.exs:585
     match (=) failed
     stacktrace:
       test/aiur/github/issues_test.exs:594: (test)
  2) test a genuinely new failure the change broke (Aiur.SomeNewTest)
     test/aiur/some_new_test.exs:10
     assert failed
Finished in 214.7 seconds (26.4s async, 188.2s sync)
2 tests, 2 failures
LOG

cat >"$test_dir/list.txt" <<'LIST'
# A comment line must be ignored.
Aiur.GitHub.IssuesTest :: normalize_issue/4 marks malformed configured repositories explicitly nonjoinable

# Trailing whitespace after this entry must also match.
Aiur.SomeNewTest :: a genuinely new failure the change broke
LIST

summary="$test_dir/summary.md"
output="$(GITHUB_WORKSPACE="$root" bash "$reporter" "$test_dir/sample.log" "$summary")"

grep -Fq 'classified known=1 new=1' <<<"$output"
grep -Fq 'Aiur.GitHub.IssuesTest :: normalize_issue/4 marks malformed configured repositories explicitly nonjoinable — **known flake**' "$summary"
grep -Fq 'Aiur.SomeNewTest :: a genuinely new failure the change broke — **NEW failure**' "$summary"
grep -Fq 'At least one failing test is **not** a known flake' "$summary"

# A run where every failure is a known flake must say so explicitly.
cat >"$test_dir/known-only.log" <<'LOG'
  1) test normalize_issue/4 marks malformed configured repositories explicitly nonjoinable (Aiur.GitHub.IssuesTest)
     test/aiur/github/issues_test.exs:585
Finished in 1.0 seconds
1 test, 1 failure
LOG

known_summary="$test_dir/known-summary.md"
output="$(GITHUB_WORKSPACE="$root" bash "$reporter" "$test_dir/known-only.log" "$known_summary")"
grep -Fq 'classified known=1 new=0' <<<"$output"
grep -Fq 'Every failing test is a known flake' "$known_summary"

# A log with no parseable ExUnit failures must not invent a classification.
cat >"$test_dir/no-failures.log" <<'LOG'
Compiling 1 file (.ex)
Finished in 1.0 seconds
0 tests, 0 failures
LOG

no_failures_summary="$test_dir/no-failures-summary.md"
output="$(GITHUB_WORKSPACE="$root" bash "$reporter" "$test_dir/no-failures.log" "$no_failures_summary")"
grep -Fq 'No failing ExUnit tests detected in the log' "$no_failures_summary"

# A missing known-flaky list must classify every failure as NEW and say so.
cat >"$test_dir/new-only.log" <<'LOG'
  1) test something else entirely (Aiur.AnotherTest)
     test/aiur/another_test.exs:5
Finished in 1.0 seconds
1 test, 1 failure
LOG

new_summary="$test_dir/new-summary.md"
output="$(GITHUB_WORKSPACE="$root" bash "$reporter" "$test_dir/new-only.log" "$new_summary" "$test_dir/does-not-exist.txt")"
grep -Fq 'classifying every failure as NEW' "$new_summary"
grep -Fq '**NEW failure** (not a known flake)' "$new_summary"

# A missing log is a no-op, not an error.
missing_summary="$test_dir/missing-summary.md"
output="$(GITHUB_WORKSPACE="$root" bash "$reporter" "$test_dir/not-there.log" "$missing_summary")"
grep -Fq 'test log not found' <<<"$output"

workflow="$root/.github/workflows/ci.yml"
coverage_partition_job="$(sed -n '/^  coverage-partition:$/,/^  coverage:$/p' "$workflow")"

grep -Fq 'Report known-flaky test names' <<<"$coverage_partition_job"
grep -Fq 'if: ${{ failure() }}' <<<"$coverage_partition_job"
grep -Fq 'run: bash scripts/report-known-flaky-tests.sh' <<<"$coverage_partition_job"

if [[ "$(grep -Fc 'report-known-flaky-tests.sh' "$workflow")" -lt 1 ]]; then
  echo "workflow must wire the known-flaky reporter" >&2
  exit 1
fi

echo "known-flaky reporter tests passed"
