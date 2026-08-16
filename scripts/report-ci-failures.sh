#!/usr/bin/env bash
set -euo pipefail

job_pattern="${1:?usage: report-ci-failures.sh <job-name-regex> <dependency-result>}"
dependency_result="${2:?usage: report-ci-failures.sh <job-name-regex> <dependency-result>}"
repository="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
run_id="${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
server_url="${GITHUB_SERVER_URL:-https://github.com}"
run_url="${server_url}/${repository}/actions/runs/${run_id}"

echo "Upstream CI dependency ended with result: ${dependency_result}"
echo "Failed upstream jobs:"

if ! jobs="$(gh api --paginate "repos/${repository}/actions/runs/${run_id}/jobs")"; then
  echo "GitHub did not return job diagnostics. Inspect the complete run: ${run_url}" >&2
  exit 1
fi

if ! failures="$(
  jq -r --arg pattern "$job_pattern" '
    .jobs[]
    | select(
        (.name | test($pattern))
        and (.conclusion != null)
        and (.conclusion != "success")
        and (.conclusion != "skipped")
      )
    | [.name, .conclusion, .html_url]
    | @tsv
  ' <<<"$jobs"
)"; then
  echo "GitHub job diagnostics could not be parsed. Inspect the complete run: ${run_url}" >&2
  exit 1
fi

if [[ -z "$failures" ]]; then
  echo "No matching failed job was returned. Inspect the complete run: ${run_url}" >&2
  exit 1
fi

while IFS=$'\t' read -r name conclusion url; do
  printf '  - %s [%s]: %s\n' "$name" "$conclusion" "$url"
done <<<"$failures"

exit 1
