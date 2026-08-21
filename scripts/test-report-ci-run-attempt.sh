#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
reporter="$root/scripts/report-ci-run-attempt.sh"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/aiur-ci-run-attempt.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

first_summary="$test_dir/first.md"
second_summary="$test_dir/second.md"
invalid_stderr="$test_dir/invalid.stderr"

if bash "$reporter" 0 "$test_dir/invalid.md" 2>"$invalid_stderr"; then
  echo "zero must be rejected as an invalid CI run attempt" >&2
  exit 1
fi

grep -Fqx 'run attempt must be a positive integer: 0' "$invalid_stderr"

bash "$reporter" 1 "$first_summary"
if [[ -e "$first_summary" ]]; then
  echo "initial CI attempts must not add a rerun marker" >&2
  exit 1
fi

bash "$reporter" 2 "$second_summary"
grep -Fqx '> CI rerun: attempt 2 of this workflow run.' "$second_summary"

workflow="$root/.github/workflows/ci.yml"

job_block() {
  local job="$1"

  awk -v heading="  $job:" '
    $0 == heading { selected = 1 }
    selected && $0 != heading && /^  [[:alnum:]_-]+:$/ { exit }
    selected { print }
  ' "$workflow"
}

mapfile -t jobs < <(
  awk '
    /^jobs:$/ { jobs = 1; next }
    jobs && /^  [[:alnum:]_-]+:$/ {
      name = $1
      sub(/:$/, "", name)
      print name
    }
  ' "$workflow"
)

for job in "${jobs[@]}"; do
  block="$(job_block "$job")"

  if grep -Fq '    continue-on-error: true' <<<"$block"; then
    continue
  fi

  if [[ "$(grep -Fc '      - name: Disclose rerun attempt' <<<"$block")" -ne 1 ]]; then
    echo "blocking CI job $job must disclose rerun attempts exactly once" >&2
    exit 1
  fi

  grep -Fq '        run: bash scripts/report-ci-run-attempt.sh "${{ github.run_attempt }}" "$GITHUB_STEP_SUMMARY"' <<<"$block"

  checkout_line="$(grep -n '      - name: Checkout' <<<"$block" | head -1 | cut -d: -f1)"
  report_line="$(grep -n '      - name: Disclose rerun attempt' <<<"$block" | cut -d: -f1)"

  if [[ "$report_line" -ne $((checkout_line + 2)) ]]; then
    echo "blocking CI job $job must disclose reruns immediately after checkout" >&2
    exit 1
  fi
done

echo "CI run-attempt reporter tests passed"
