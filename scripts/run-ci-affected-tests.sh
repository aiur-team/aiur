#!/usr/bin/env bash
set -euo pipefail

# Shares the job's 25-minute cap with scripts/run-ci-affected-tests.py: a step
# killed by that cap looks like a failing test, so a setup overrun reports its
# own named timeout instead (#7545). The runner reserves this same 300s
# (SETUP_RESERVE_SECONDS) off its own budget, so setup plus runner plus the
# steps before this one cannot outlive the cap.
SETUP_TIMEOUT_SECONDS=300

PR_BASE="$(git rev-parse HEAD^1)"
echo "::notice::affected-tests merge base: $PR_BASE"
started=$SECONDS
if ! timeout "$SETUP_TIMEOUT_SECONDS" bash ../scripts/install-ci-zsh.sh; then
  echo "::error::affected-tests dependency setup exceeded its ${SETUP_TIMEOUT_SECONDS}s timeout; the run stopped before any test started" >&2
  exit 1
fi
echo "::notice::affected-tests dependency setup duration: $((SECONDS - started))s"
GITHUB_EVENT_NAME="${GITHUB_EVENT_NAME:-}" python3 ../scripts/run-ci-affected-tests.py "$PR_BASE"
