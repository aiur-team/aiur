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

# Structural, not literal (#docs-only CI).
#
# This guard used to pin each reporter step as one exact multi-line literal,
# including its whole `if:` expression. That made it fail the moment an
# unrelated condition was ANDed into the gate -- which is not a regression in
# failure reporting, and is not what this guard exists to catch. What is
# load-bearing is kept exact: the reporter invocation, its job-name regex and
# its result argument, because naming the wrong jobs is the actual defect. The
# `if:` is asserted only for the predicate that makes the step a *failure*
# reporter, so an added, unrelated condition does not have to be re-pasted here.

# Print one step block: its `- name:` line through the line before the next step.
step_block() {
  awk -v heading="      - name: $1" '
    $0 == heading { inside = 1; print; next }
    inside && /^      - name: / { inside = 0 }
    inside { print }
  '
}

require() {
  local reason="$1"
  shift
  if ! grep -Fq -- "$1" <<<"$2"; then
    echo "$reason" >&2
    exit 1
  fi
}

coverage_step="$(step_block 'Report failed coverage partitions' <<<"$coverage_job")"
test_step="$(step_block 'Report failed coverage gate' <<<"$test_job")"

if [[ -z "$coverage_step" ]]; then
  echo "the coverage job must report its failed partitions" >&2
  exit 1
fi
if [[ -z "$test_step" ]]; then
  echo "the test job must report a failed coverage gate" >&2
  exit 1
fi

require 'the coverage partition reporter must run only when a partition did not succeed' \
  "needs.coverage-partition.result != 'success'" "$coverage_step"
require 'the coverage partition reporter needs a token' \
  'GH_TOKEN: ${{ github.token }}' "$coverage_step"
require 'the coverage partition reporter must run from the repository root' \
  'working-directory: .' "$coverage_step"
require 'the coverage partition reporter must name the partition jobs exactly' \
  'run: bash scripts/report-ci-failures.sh '"'"'^coverage \([1-4]/4\)$'"'"' "${{ needs.coverage-partition.result }}"' \
  "$coverage_step"

require 'the coverage gate reporter must run only when the gate did not succeed' \
  "needs.coverage.result != 'success'" "$test_step"
require 'the coverage gate reporter needs a token' \
  'GH_TOKEN: ${{ github.token }}' "$test_step"
require 'the coverage gate reporter must run from the repository root' \
  'working-directory: .' "$test_step"
require 'the coverage gate reporter must name the coverage jobs exactly' \
  'run: bash scripts/report-ci-failures.sh '"'"'^coverage( \([1-4]/4\))?$'"'"' "${{ needs.coverage.result }}"' \
  "$test_step"

# The rollups must still depend on what they report on. The dependency list may
# carry other jobs (the docs-only path classifier), so match the edge, not the
# whole `needs:` line.
if ! grep -Eq '^    needs: (coverage-partition$|\[[^]]*\bcoverage-partition\b[^]]*\])' <<<"$coverage_job"; then
  echo "the coverage rollup must depend on coverage-partition" >&2
  exit 1
fi
if ! grep -Eq '^    needs: (coverage$|\[[^]]*\bcoverage\b[^]]*\])' <<<"$test_job"; then
  echo "the test rollup must depend on coverage" >&2
  exit 1
fi
grep -Fq 'actions: read' <<<"$coverage_job"
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
