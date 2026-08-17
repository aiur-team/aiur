#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
reporter="$root/scripts/report-ci-failures.sh"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/aiur-ci-failure-report.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

cat >"$test_dir/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 || "$1" != "api" || "$2" != "--paginate" || "$3" != "repos/aiur-team/aiur/actions/runs/123/jobs" ]]; then
  printf 'unexpected gh invocation:' >&2
  printf ' <%s>' "$@" >&2
  printf '\n' >&2
  exit 91
fi

case "${GH_RESPONSE:-valid}" in
  api_error)
    echo "simulated API failure" >&2
    exit 92
    ;;
  malformed)
    printf '{'
    exit 0
    ;;
esac

cat <<'JSON'
{
  "jobs": [
    {"name":"coverage (1/4)","conclusion":"success","html_url":"https://example.test/jobs/1"},
    {"name":"coverage (2/4)","conclusion":"timed_out","html_url":"https://example.test/jobs/2"},
    {"name":"coverage (4/4)","conclusion":"failure","html_url":"https://example.test/jobs/4"},
    {"name":"coverage","conclusion":"failure","html_url":"https://example.test/jobs/coverage"},
    {"name":"lint","conclusion":"failure","html_url":"https://example.test/jobs/lint"}
  ]
}
JSON
EOF
chmod +x "$test_dir/gh"

run_reporter() {
  PATH="$test_dir:$PATH" \
    GITHUB_REPOSITORY="aiur-team/aiur" \
    GITHUB_RUN_ID="123" \
    GITHUB_SERVER_URL="https://github.example.test" \
    GH_RESPONSE="${3:-valid}" \
    bash "$reporter" "$1" "$2" 2>&1
}

if output="$(run_reporter '^coverage \([1-4]/4\)$' failure)"; then
  echo "reporter must fail the rollup after printing diagnostics" >&2
  exit 1
fi

grep -Fq "coverage (4/4) [failure]: https://example.test/jobs/4" <<<"$output"
grep -Fq "coverage (2/4) [timed_out]: https://example.test/jobs/2" <<<"$output"
if grep -Fq "coverage (1/4)" <<<"$output" || grep -Fq "coverage [failure]" <<<"$output" || grep -Fq "lint" <<<"$output"; then
  echo "reporter included successful or unrelated jobs:" >&2
  echo "$output" >&2
  exit 1
fi

if combined="$(run_reporter '^coverage( \([1-4]/4\))?$' failure)"; then
  echo "combined reporter must fail after printing diagnostics" >&2
  exit 1
fi
grep -Fq "coverage [failure]: https://example.test/jobs/coverage" <<<"$combined"
grep -Fq "coverage (4/4) [failure]: https://example.test/jobs/4" <<<"$combined"

if api_error="$(run_reporter '^coverage$' failure api_error)"; then
  echo "reporter must fail when the jobs API fails" >&2
  exit 1
fi
grep -Fq "GitHub did not return job diagnostics" <<<"$api_error"
grep -Fq "https://github.example.test/aiur-team/aiur/actions/runs/123" <<<"$api_error"

if malformed="$(run_reporter '^coverage$' failure malformed)"; then
  echo "reporter must fail when job diagnostics cannot be parsed" >&2
  exit 1
fi
grep -Fq "GitHub job diagnostics could not be parsed" <<<"$malformed"
grep -Fq "https://github.example.test/aiur-team/aiur/actions/runs/123" <<<"$malformed"

if fallback="$(run_reporter '^missing$' cancelled)"; then
  echo "reporter must fail when the dependency is cancelled" >&2
  exit 1
fi

grep -Fq "No matching failed job was returned" <<<"$fallback"
grep -Fq "https://github.example.test/aiur-team/aiur/actions/runs/123" <<<"$fallback"

workflow="$root/.github/workflows/ci.yml"
coverage_job="$(sed -n '/^  coverage:$/,/^  quarantine:$/p' "$workflow")"
test_job="$(sed -n '/^  test:$/,/^  analytics:$/p' "$workflow")"

coverage_step='      - name: Report failed coverage partitions
        if: ${{ needs.coverage-partition.result != '\''success'\'' }}
        env:
          GH_TOKEN: ${{ github.token }}
        working-directory: .
        run: bash scripts/report-ci-failures.sh '\''^coverage \([1-4]/4\)$'\'' "${{ needs.coverage-partition.result }}"'
test_step='      - name: Report failed coverage gate
        if: ${{ needs.coverage.result != '\''success'\'' }}
        env:
          GH_TOKEN: ${{ github.token }}
        working-directory: .
        run: bash scripts/report-ci-failures.sh '\''^coverage( \([1-4]/4\))?$'\'' "${{ needs.coverage.result }}"'

grep -Fq "$coverage_step" <<<"$coverage_job"
grep -Fq 'needs: coverage-partition' <<<"$coverage_job"
grep -Fq 'actions: read' <<<"$coverage_job"
grep -Fq "$test_step" <<<"$test_job"
grep -Fq 'needs: coverage' <<<"$test_job"
grep -Fq 'actions: read' <<<"$test_job"

if [[ "$(grep -Fc 'run: bash scripts/report-ci-failures.sh' "$workflow")" -ne 2 ]]; then
  echo "every CI failure reporter invocation must be covered by a structural assertion" >&2
  exit 1
fi

if grep -Fq 'run: test "${{ needs.' "$workflow"; then
  echo "CI rollups still contain a diagnostic-free result assertion" >&2
  exit 1
fi

echo "CI failure reporter tests passed"
