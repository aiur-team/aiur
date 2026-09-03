#!/usr/bin/env bash
# Report whether a failed Elixir test job's failures are known flakes or new.
#
# "CI is red" stops meaning "this change is broken" when load-dependent flakes
# fire arbitrarily. This script restores that signal: it extracts the failing
# test names from the ExUnit log, classifies each against the known-flaky list
# (.github/known-flaky-tests.txt), and writes the classification to the job
# summary so a red run names whether each failure is a known flake or a new one.
#
# Usage:
#   report-known-flaky-tests.sh <test-log-file> <step-summary-file> [known-flaky-list]
#
#   <test-log-file>     capture of `mix test` stdout/stderr
#   <step-summary-file> path to append the classification to ($GITHUB_STEP_SUMMARY)
#   [known-flaky-list]  path to the list (defaults to .github/known-flaky-tests.txt)
#
# Exits 0 always: the test job already failed; this step only adds information.

set -euo pipefail

log_file="${1:?usage: report-known-flaky-tests.sh <test-log-file> <step-summary-file> [known-flaky-list]}"
summary_file="${2:?usage: report-known-flaky-tests.sh <test-log-file> <step-summary-file> [known-flaky-list]}"
default_list="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/.github/known-flaky-tests.txt"
list_file="${3:-$default_list}"

if [[ ! -f "$log_file" ]]; then
  echo "report-known-flaky-tests: test log not found: $log_file"
  exit 0
fi

# ExUnit prints each failure as:
#     1) test <name> (<Module>)
failing_tests="$(
  sed -nE 's/^[[:space:]]*[0-9]+\) test (.*) \(([A-Za-z0-9_.]+)\)[[:space:]]*$/\2 :: \1/p' "$log_file" |
    sort -u
)"

{
  echo ""
  echo "## Test failure classification"
} >> "$summary_file"

if [[ -z "$failing_tests" ]]; then
  echo "No failing ExUnit tests detected in the log (the failure may be a compile, boot, or non-ExUnit error)." >> "$summary_file"
  exit 0
fi

if [[ ! -f "$list_file" ]]; then
  echo "Known-flaky list not found ($list_file); classifying every failure as NEW." >> "$summary_file"
fi

known_file="$(mktemp)"
trap 'rm -f "$known_file"' EXIT
if [[ -f "$list_file" ]]; then
  # Ignore blank lines and `#` comments; keep every other line byte-exact.
  grep -vE '^[[:space:]]*(#|$)' "$list_file" | sed 's/[[:space:]]*$//' > "$known_file"
fi

known=0
new=0
while IFS= read -r test; do
  if [[ -f "$list_file" ]] && grep -Fxq -- "$test" "$known_file"; then
    echo "  - $test — **known flake** (listed in .github/known-flaky-tests.txt)" >> "$summary_file"
    known=$((known + 1))
  else
    echo "  - $test — **NEW failure** (not a known flake)" >> "$summary_file"
    new=$((new + 1))
  fi
done <<< "$failing_tests"

echo "" >> "$summary_file"
if (( new == 0 )); then
  echo "Every failing test is a known flake. Inspect the run for correlation with this change, but treat the red as a flake that fired rather than proof the change is broken." >> "$summary_file"
else
  echo "At least one failing test is **not** a known flake — treat this red as a potential regression from this change." >> "$summary_file"
fi

echo "classified known=$known new=$new"
