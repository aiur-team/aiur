#!/usr/bin/env bash
set -euo pipefail

script="${AIUR_EXECUTOR_RETROSPECTIVE_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/executor-retrospective.sh}"
visual_test="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../aiur-meta/scripts/tests" && pwd)/capture-dashboard_test.mjs"
state_root="$(mktemp -d)"
export AIUR_EXECUTOR_RETRO_FILE="$state_root/test-retros.md"
export AIUR_EXECUTOR_RETROSPECTIVE_VISUAL_CHECK=0
export AIUR_EXECUTOR_RETROSPECTIVE_CLI_CHECK=0
first_pid=""
second_pid=""
cleanup() {
  : > "$state_root/release-first-lock"
  for pid in "$first_pid" "$second_pid"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$state_root"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

run() {
  AIUR_EXECUTOR_STATE_DIR="$state_root" \
    AIUR_EXECUTOR_RUN_ID="$1" \
    AIUR_EXECUTOR_RETROSPECTIVE_SECONDS="${2:-3600}" \
    "$script" "${@:3}"
}
