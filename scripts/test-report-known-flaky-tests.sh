#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
reporter="$root/scripts/report-known-flaky-tests.sh"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/aiur-known-flaky-report.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

# `grep -Fq` under `set -e` fails with no diagnostic, and this script runs in CI
# under `bash -e` as well, so a failed assertion used to surface as exit 1 and a
# completely empty log — indistinguishable from the script crashing before it
# printed anything. Name the assertion instead.
assert_contains() {
  local label="$1" needle="$2" haystack="$3"

  if ! grep -Fq -- "$needle" <<<"$haystack"; then
    echo "ASSERTION FAILED: $label" >&2
    echo "  expected to find: $needle" >&2
    echo "  in:" >&2
    sed 's/^/    /' <<<"$haystack" >&2
    exit 1
  fi
}

assert_file_contains() {
  local label="$1" needle="$2" file="$3"

  assert_contains "$label" "$needle" "$(cat "$file")"
}

# Every name below is fictional and must stay that way. These fixtures used to
# name a real entry from .github/known-flaky-tests.txt, and the scenarios that
# needed a listed test omitted the reporter's third argument, so they read the
# live list instead of the fixture beside them. That coupled the guard to the
# file's contents: de-quarantining the borrowed entry — exactly what the list's
# header instructs — broke the guard, with no output to say why. A fixture that
# names production data is a fixture that fails when production data is
# maintained.
cat >"$test_dir/sample.log" <<'LOG'
Running ExUnit with seed: 123456, max_cases: 4
Excluding tags: [:external, :perf_regression, :quarantine]
..........................................................................
  1) test a listed flake standing in for a quarantine entry (Aiur.KnownFlakeFixtureTest)
     test/aiur/known_flake_fixture_test.exs:585
     match (=) failed
     stacktrace:
       test/aiur/known_flake_fixture_test.exs:594: (test)
  2) test a genuinely new failure the change broke (Aiur.SomeNewTest)
     test/aiur/some_new_test.exs:10
     assert failed
  3) test a listed flake whose entry carries trailing whitespace (Aiur.KnownFlakeFixtureTest)
     test/aiur/known_flake_fixture_test.exs:601
     assert failed
Finished in 214.7 seconds (26.4s async, 188.2s sync)
3 tests, 3 failures
LOG

# Note what is deliberately absent: `Aiur.SomeNewTest`. The previous fixture
# listed it while the assertions below require it to classify as NEW, which is
# only possible because nothing ever read this file.
printf '%s\n' \
  '# A comment line must be ignored.' \
  'Aiur.KnownFlakeFixtureTest :: a listed flake standing in for a quarantine entry' \
  '' \
  '# Trailing whitespace on the next entry must still match.' \
  'Aiur.KnownFlakeFixtureTest :: a listed flake whose entry carries trailing whitespace   ' \
  >"$test_dir/list.txt"

summary="$test_dir/summary.md"
output="$(GITHUB_WORKSPACE="$root" bash "$reporter" "$test_dir/sample.log" "$summary" "$test_dir/list.txt")"

assert_contains 'mixed run counts two known and one new' 'classified known=2 new=1' "$output"
assert_file_contains 'listed fixture test is classified as a known flake' \
  'Aiur.KnownFlakeFixtureTest :: a listed flake standing in for a quarantine entry — **known flake**' "$summary"
assert_file_contains 'a listed entry with trailing whitespace still matches' \
  'Aiur.KnownFlakeFixtureTest :: a listed flake whose entry carries trailing whitespace — **known flake**' "$summary"
assert_file_contains 'unlisted failure is classified as NEW' \
  'Aiur.SomeNewTest :: a genuinely new failure the change broke — **NEW failure**' "$summary"
assert_file_contains 'mixed run warns about the unlisted failure' \
  'At least one failing test is **not** a known flake' "$summary"

# A run where every failure is a known flake must say so explicitly.
cat >"$test_dir/known-only.log" <<'LOG'
  1) test a listed flake standing in for a quarantine entry (Aiur.KnownFlakeFixtureTest)
     test/aiur/known_flake_fixture_test.exs:585
Finished in 1.0 seconds
1 test, 1 failure
LOG

known_summary="$test_dir/known-summary.md"
output="$(GITHUB_WORKSPACE="$root" bash "$reporter" "$test_dir/known-only.log" "$known_summary" "$test_dir/list.txt")"
assert_contains 'known-only run counts one known and no new' 'classified known=1 new=0' "$output"
assert_file_contains 'known-only run says every failure is a known flake' \
  'Every failing test is a known flake' "$known_summary"

# A log with no parseable ExUnit failures must not invent a classification.
cat >"$test_dir/no-failures.log" <<'LOG'
Compiling 1 file (.ex)
Finished in 1.0 seconds
0 tests, 0 failures
LOG

no_failures_summary="$test_dir/no-failures-summary.md"
output="$(GITHUB_WORKSPACE="$root" bash "$reporter" "$test_dir/no-failures.log" "$no_failures_summary" "$test_dir/list.txt")"
assert_file_contains 'a log with no ExUnit failures invents no classification' \
  'No failing ExUnit tests detected in the log' "$no_failures_summary"

# A missing known-flaky list must classify every failure as NEW and say so.
cat >"$test_dir/new-only.log" <<'LOG'
  1) test something else entirely (Aiur.AnotherTest)
     test/aiur/another_test.exs:5
Finished in 1.0 seconds
1 test, 1 failure
LOG

new_summary="$test_dir/new-summary.md"
output="$(GITHUB_WORKSPACE="$root" bash "$reporter" "$test_dir/new-only.log" "$new_summary" "$test_dir/does-not-exist.txt")"
assert_file_contains 'a missing list is reported rather than assumed empty' \
  'classifying every failure as NEW' "$new_summary"
assert_file_contains 'a missing list classifies every failure as NEW' \
  '**NEW failure** (not a known flake)' "$new_summary"

# A missing log is a no-op, not an error.
missing_summary="$test_dir/missing-summary.md"
output="$(GITHUB_WORKSPACE="$root" bash "$reporter" "$test_dir/not-there.log" "$missing_summary" "$test_dir/list.txt")"
assert_contains 'a missing log is a no-op' 'test log not found' "$output"

workflow="$root/.github/workflows/ci.yml"
coverage_partition_job="$(sed -n '/^  coverage-partition:$/,/^  coverage:$/p' "$workflow")"

assert_contains 'ci.yml runs the reporter step' 'Report known-flaky test names' "$coverage_partition_job"
assert_contains 'reporter step runs only on failure' 'if: ${{ failure() }}' "$coverage_partition_job"
assert_contains 'reporter step invokes the script' 'run: bash scripts/report-known-flaky-tests.sh' "$coverage_partition_job"

if [[ "$(grep -Fc 'report-known-flaky-tests.sh' "$workflow")" -lt 1 ]]; then
  echo "workflow must wire the known-flaky reporter" >&2
  exit 1
fi

echo "known-flaky reporter tests passed"
