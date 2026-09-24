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

  disclose_step="$(
    awk '
      $0 == "      - name: Disclose rerun attempt" { inside = 1; print; next }
      inside && /^      - name: / { inside = 0 }
      inside { print }
    ' <<<"$block"
  )"

  # Semantic, not literal (#docs-only CI). The disclosure must still be limited
  # to reruns, but its `if:` may carry further, unrelated conditions -- the
  # docs-only path gate ANDs one in. Pinning the whole line made this guard fail
  # on a change that does not touch rerun disclosure at all, so assert only the
  # predicate that keeps the step a *rerun* disclosure.
  if ! grep -Eq '^        if: .*github\.run_attempt > 1' <<<"$disclose_step"; then
    echo "blocking CI job $job must skip rerun disclosure on the first attempt" >&2
    exit 1
  fi

  # Exact, and deliberately so: the reporter invocation and both of its
  # arguments are the thing this guard exists to pin down.
  grep -Fq '        run: bash scripts/report-ci-run-attempt.sh "${{ github.run_attempt }}" "$GITHUB_STEP_SUMMARY"' <<<"$disclose_step"

  # Disclosure must be the first step after checkout. Compare step positions,
  # not line offsets: the old `checkout_line + 2` arithmetic encoded the number
  # of lines in the checkout step, so it broke the moment that step grew an
  # `if:` line.
  mapfile -t step_names < <(sed -n 's/^      - name: //p' <<<"$block")
  checkout_index=-1
  disclose_index=-1
  for index in "${!step_names[@]}"; do
    if [[ "${step_names[$index]}" == "Checkout" && "$checkout_index" -lt 0 ]]; then
      checkout_index="$index"
    fi
    if [[ "${step_names[$index]}" == "Disclose rerun attempt" ]]; then
      disclose_index="$index"
    fi
  done

  if [[ "$checkout_index" -lt 0 || "$disclose_index" -ne $((checkout_index + 1)) ]]; then
    echo "blocking CI job $job must disclose reruns immediately after checkout" >&2
    exit 1
  fi
done

echo "CI run-attempt reporter tests passed"
