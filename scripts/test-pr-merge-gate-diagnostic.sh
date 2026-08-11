#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
diagnostic="$root/.claude/skills/aiur-run/scripts/diagnose-pr-merge-gate.sh"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/aiur-merge-gate-diagnostic.XXXXXX")"
calls="$test_dir/calls"
trap 'rm -rf "$test_dir"' EXIT

cat >"$test_dir/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${DIAGNOSTIC_CALLS:?}"
printf '%s\n' "$*" >>"$DIAGNOSTIC_CALLS"

if [[ "${GH_TOKEN:-}" != "operator-only" || -n "${GITHUB_TOKEN:-}" ]]; then
  echo "diagnostic did not isolate the operator credential" >&2
  exit 90
fi

case "$*" in
  "pr view 1405 --repo example/repository --json baseRefName,potentialMergeCommit")
    jq -cn --arg sha "${POTENTIAL_SHA:?}" '{baseRefName:"develop",potentialMergeCommit:{oid:$sha}}'
    ;;
  "api repos/example/repository/rulesets/rule-suites?ref=refs/heads/develop&time_period=day&rule_suite_result=fail&per_page=100 --jq .[] | [.id, .after_sha] | @tsv")
    printf '22\tother-sha\n11\ttarget-sha\n'
    ;;
  "api repos/example/repository/git/commits/other-sha")
    printf '%s\n' '{"message":"Other change (#99)"}'
    ;;
  "api repos/example/repository/rulesets/rule-suites/11")
    jq -cn --arg details "${RULE_DETAIL:?}" '{after_sha:"target-sha",rule_evaluations:[{enforcement:"active",result:"fail",details:$details},{enforcement:"evaluate",result:"fail",details:"Evaluate-only detail must not alert."}]}'
    ;;
  "api repos/example/repository/git/commits/target-sha")
    printf '%s\n' '{"message":"Human-only merge gate diagnostics (#1405)\n\nBody."}'
    ;;
  *)
    echo "unexpected gh invocation: $*" >&2
    exit 91
    ;;
esac
EOF
chmod +x "$test_dir/gh"

run_diagnostic() {
  local detail="$1"
  local potential_sha="$2"
  local call_log="$3"

  PATH="$test_dir:$PATH" \
    DIAGNOSTIC_CALLS="$call_log" \
    RULE_DETAIL="$detail" \
    POTENTIAL_SHA="$potential_sha" \
    AIUR_CI_READINESS_TOKEN="operator-only" \
    GITHUB_TOKEN="agent-only" \
    GH_TOKEN="agent-override" \
    bash "$diagnostic" 1405 example/repository
}

expected="New changes require approval from someone other than its-everdred because they were the last pusher."
direct_calls="$calls-direct"
output="$(run_diagnostic "$expected" target-sha "$direct_calls")"
if [[ "$output" != "$expected" ]]; then
  echo "diagnostic returned the wrong rule violation: $output" >&2
  exit 1
fi

second_expected="Required deployment approval is missing."
fallback_calls="$calls-fallback"
second_output="$(run_diagnostic "$second_expected" current-sha "$fallback_calls")"
if [[ "$second_output" != "$second_expected" ]]; then
  echo "diagnostic did not pass through GitHub's current rule detail: $second_output" >&2
  exit 1
fi

if grep -Eq 'pr merge|--admin' "$direct_calls" "$fallback_calls"; then
  echo "diagnostic must stay read-only" >&2
  exit 1
fi

if grep -q -- '--paginate' "$direct_calls" "$fallback_calls"; then
  echo "diagnostic candidate scan must remain bounded to one page" >&2
  exit 1
fi

if grep -Eq '/git/commits/|rule-suites/22' "$direct_calls"; then
  echo "current merge commits must use the one-request diagnostic path" >&2
  exit 1
fi

if grep -q 'rule-suites/22' "$fallback_calls"; then
  echo "fallback correlation must fetch rule details only after the commit matches" >&2
  exit 1
fi

echo "PR merge-gate diagnostic tests passed"
