#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/promote-develop-to-main.sh"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/aiur-promote.XXXXXX")"
calls="$test_dir/calls"
trap 'rm -rf "$test_dir"' EXIT

cat >"$test_dir/gh" <<'FAKEGH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$FAKE_GH_CALLS"

case "$*" in
  "api user --jq .login")
    printf '%s\n' "${FAKE_GH_USER:?}"
    ;;
  "api repos/example/repository/compare/main...develop --jq .ahead_by")
    printf '%s\n' "${FAKE_AHEAD:?}"
    ;;
  "pr list --repo example/repository --base main --head develop --state open --json number --jq .[0].number // empty")
    printf '%s\n' "${FAKE_EXISTING_PR:-}"
    ;;
  "pr create --repo example/repository --base main --head develop"*)
    printf '%s\n' '{"number":42,"url":"https://github.com/example/repository/pull/42","baseRefName":"main","headRefName":"develop","author":{"login":"its-applekid"}}'
    ;;
  "pr view "*" --repo example/repository --json baseRefName,headRefName,author,state,isDraft,reviewDecision,mergeStateStatus,statusCheckRollup,url")
    jq -cn \
      --arg base "${PR_BASE:-main}" \
      --arg head "${PR_HEAD:-develop}" \
      --arg author "${PR_AUTHOR:-its-applekid}" \
      --arg state "${PR_STATE:-OPEN}" \
      --arg draft "${PR_DRAFT:-false}" \
      --arg decision "${PR_DECISION:-REVIEW_REQUIRED}" \
      --arg merge "${PR_MERGE:-BLOCKED}" \
      --arg failing "${PR_FAILING_CHECKS:-}" \
      '{baseRefName:$base,headRefName:$head,author:{login:$author},state:$state,
        isDraft:($draft == "true"),reviewDecision:$decision,mergeStateStatus:$merge,
        statusCheckRollup: ([{name:"quarantined tests (non-blocking)",conclusion:"FAILURE"}]
          + (($failing | split(",")) | map(select(length > 0) | {name: ., conclusion:"FAILURE"}))),
        url:"https://github.com/example/repository/pull/42"}'
    ;;
  *)
    echo "unexpected gh invocation: $*" >&2
    exit 91
    ;;
esac
FAKEGH
chmod +x "$test_dir/gh"

run_promote() {
  local call_log="$1"
  shift
  : >"$call_log"
  PATH="$test_dir:$PATH" \
    FAKE_GH_CALLS="$call_log" \
    GITHUB_TOKEN="$FAKE_GH_TOKEN" \
    GH_TOKEN="$FAKE_GH_TOKEN" \
    bash "$script" "$@"
}

expect_success() {
  local name="$1"
  local output
  shift
  if ! output="$(run_promote "$calls" "$@" 2>&1)"; then
    echo "$name: expected success, got failure: $output" >&2
    exit 1
  fi
  printf '%s\n' "$output"
}

expect_rejection() {
  local name="$1"
  local expected="$2"
  shift 2
  local output
  if output="$(run_promote "$calls" "$@" 2>&1)"; then
    echo "$name: expected rejection, got success: $output" >&2
    exit 1
  fi
  if ! grep -Fq "$expected" <<<"$output"; then
    echo "$name: rejected for the wrong reason: $output" >&2
    exit 1
  fi
  printf '%s\n' "$output"
}

has_call() {
  local pattern="$1"
  grep -Eq "$pattern" "$calls"
}

FAKE_GH_TOKEN="bot-token"
export FAKE_GH_TOKEN

# 1. Creates a promotion PR when none exists, and prints the next steps.
output="$(FAKE_GH_USER="its-applekid" FAKE_AHEAD=97 FAKE_EXISTING_PR="" \
  expect_success "creates promotion PR" example/repository)"
if ! grep -Fq "created promotion PR #42" <<<"$output"; then
  echo "creates promotion PR: did not report the created PR: $output" >&2
  exit 1
fi
if ! grep -Fq "next steps:" <<<"$output"; then
  echo "creates promotion PR: did not print next steps: $output" >&2
  exit 1
fi
if ! has_call 'pr create --repo example/repository --base main --head develop'; then
  echo "creates promotion PR: gh pr create was not invoked" >&2
  exit 1
fi

# 2. Reuses an existing open promotion PR instead of creating a duplicate.
: >"$calls"
output="$(PR_AUTHOR="its-applekid" PR_DECISION="APPROVED" PR_MERGE="CLEAN" \
  FAKE_GH_USER="its-applekid" FAKE_AHEAD=5 FAKE_EXISTING_PR=7 \
  expect_success "reuses existing promotion PR" example/repository)"
if ! grep -Fq "reusing existing promotion PR #7" <<<"$output"; then
  echo "reuses existing promotion PR: did not report reuse: $output" >&2
  exit 1
fi
if has_call 'pr create'; then
  echo "reuses existing promotion PR: created a duplicate" >&2
  exit 1
fi

# 3. Refuses a human token: the promotion PR must be authored by the agent
#    account so the human can approve it.
output="$(FAKE_GH_USER="its-everdred" FAKE_AHEAD=97 expect_rejection \
  "refuses human token" "promotion PR must be authored by its-applekid" \
  example/repository)"
if has_call 'pr create'; then
  echo "refuses human token: created a PR despite the identity guard" >&2
  exit 1
fi

# 4. Nothing to promote: develop is not ahead of main, no PR is created.
output="$(FAKE_GH_USER="its-applekid" FAKE_AHEAD=0 expect_success \
  "nothing to promote" example/repository)"
if ! grep -Fq "nothing to promote" <<<"$output"; then
  echo "nothing to promote: wrong output: $output" >&2
  exit 1
fi
if has_call 'pr create'; then
  echo "nothing to promote: created a PR with an empty delta" >&2
  exit 1
fi

# 5. --verify reports READY when the human approval is current and the PR is
#    mergeable.
output="$(PR_AUTHOR="its-applekid" PR_DECISION="APPROVED" PR_MERGE="CLEAN" \
  FAKE_GH_USER="its-applekid" \
  expect_success "--verify ready" --verify 42 example/repository)"
if ! grep -Fq "READY" <<<"$output"; then
  echo "--verify ready: did not report READY: $output" >&2
  exit 1
fi

# 6. --verify reports NOT READY when the human approval is missing.
output="$(PR_AUTHOR="its-applekid" PR_DECISION="REVIEW_REQUIRED" PR_MERGE="BLOCKED" \
  FAKE_GH_USER="its-applekid" \
  expect_rejection "--verify missing approval" "NOT READY" --verify 42 example/repository)"
if ! grep -Fq "missing: human approval on exact head" <<<"$output"; then
  echo "--verify missing approval: wrong reason: $output" >&2
  exit 1
fi

# 7. --verify fails when the PR is authored by the human (deadlock shape).
output="$(PR_AUTHOR="its-everdred" PR_DECISION="APPROVED" PR_MERGE="CLEAN" \
  FAKE_GH_USER="its-applekid" \
  expect_rejection "--verify human author" "NOT READY" --verify 42 example/repository)"
if ! grep -Fq "missing: authored by its-applekid" <<<"$output"; then
  echo "--verify human author: wrong reason: $output" >&2
  exit 1
fi

# 8. The human operator can run --verify with their own token: the identity
#    guard only applies to the create/reuse path, and --verify checks the PR
#    author instead.
output="$(PR_AUTHOR="its-applekid" PR_DECISION="APPROVED" PR_MERGE="CLEAN" \
  FAKE_GH_USER="its-everdred" \
  expect_success "--verify with human token" --verify 42 example/repository)"
if ! grep -Fq "READY" <<<"$output"; then
  echo "--verify with human token: did not report READY: $output" >&2
  exit 1
fi

# 8b. UNSTABLE caused only by the expected non-blocking quarantined failure is
#     still mergeable.
output="$(PR_AUTHOR="its-applekid" PR_DECISION="APPROVED" PR_MERGE="UNSTABLE" \
  PR_FAILING_CHECKS="" FAKE_GH_USER="its-applekid" \
  expect_success "--verify unstable but non-blocking only" --verify 42 example/repository)"
if ! grep -Fq "READY" <<<"$output"; then
  echo "--verify unstable but non-blocking only: did not report READY: $output" >&2
  exit 1
fi

# 8c. UNSTABLE with a required check failing is NOT ready.
output="$(PR_AUTHOR="its-applekid" PR_DECISION="APPROVED" PR_MERGE="UNSTABLE" \
  PR_FAILING_CHECKS="test" FAKE_GH_USER="its-applekid" \
  expect_rejection "--verify unstable required failure" "NOT READY" \
  --verify 42 example/repository)"
if ! grep -Fq "required checks failing: test" <<<"$output"; then
  echo "--verify unstable required failure: wrong reason: $output" >&2
  exit 1
fi

# 9. --verify is read-only: it must never create a PR or mutate anything.
: >"$calls"
PR_AUTHOR="its-applekid" PR_DECISION="APPROVED" PR_MERGE="CLEAN" \
  FAKE_GH_USER="its-applekid" \
  run_promote "$calls" --verify 42 example/repository >/dev/null 2>&1 || true
if grep -Eq 'pr create|--method|api -X|update-branch' "$calls"; then
  echo "--verify must be read-only; saw a mutating call: $(cat "$calls")" >&2
  exit 1
fi

echo "promote-develop-to-main checks passed"
