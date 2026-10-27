#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/retrospective-test-helpers.sh"

# Adaptive quiet-audit wait planner. Event-driven wakes stay immediate; the
# quiet fallback interval resets to the floor on an actionable or thrash/stale
# wake and widens multiplicatively on each repeated no-action quiet audit,
# always clamped to the configured [floor, ceiling] bounds.
run_wait() {
  AIUR_EXECUTOR_STATE_DIR="$state_root" \
    AIUR_EXECUTOR_RUN_ID="$1" \
    AIUR_EXECUTOR_WAIT_FLOOR_SECONDS="$2" \
    AIUR_EXECUTOR_WAIT_CEILING_SECONDS="$3" \
    AIUR_EXECUTOR_WAIT_BACKOFF="$4" \
    "$script" "${@:5}"
}

jq -e '.category == "quiet" and .outcome == "no-action" and .prev_interval_seconds == 30 and .next_interval_seconds == 60' \
  <<< "$(run_wait wait 30 900 2 plan-wait quiet nothing-actionable)" >/dev/null ||
  fail "first quiet audit did not widen from the floor"
jq -e '.next_interval_seconds == 120' \
  <<< "$(run_wait wait 30 900 2 plan-wait quiet still-quiet)" >/dev/null ||
  fail "repeated no-action audit did not keep widening"
jq -e '.outcome == "action" and .next_interval_seconds == 30' \
  <<< "$(run_wait wait 30 900 2 plan-wait actionable dispatched-ready-work)" >/dev/null ||
  fail "actionable wake did not reset the interval to the floor"
jq -e '.outcome == "action" and .next_interval_seconds == 30' \
  <<< "$(run_wait wait 30 900 2 plan-wait quiet re-widen && run_wait wait 30 900 2 plan-wait thrash likely-thrash)" >/dev/null ||
  fail "thrash wake did not narrow the interval to the floor"
jq -e '.next_interval_seconds == 30' \
  <<< "$(run_wait wait 30 900 2 plan-wait stale stale-agent)" >/dev/null ||
  fail "stale wake did not narrow the interval to the floor"

# Widening is bounded by the ceiling, not unbounded backoff.
run_wait clamp 10 25 2 plan-wait quiet q1 >/dev/null
jq -e '.prev_interval_seconds == 20 and .next_interval_seconds == 25' \
  <<< "$(run_wait clamp 10 25 2 plan-wait quiet q2)" >/dev/null ||
  fail "widening was not clamped to the ceiling"
jq -e '.prev_interval_seconds == 25 and .next_interval_seconds == 25' \
  <<< "$(run_wait clamp 10 25 2 plan-wait quiet q3)" >/dev/null ||
  fail "interval did not stay pinned at the ceiling"

# plan-wait events feed the same action/no-action retrospective denominator.
jq -e '.total_wakes == 6 and .action_wakes == 3 and .no_action_wakes == 3' \
  <<< "$(run wait 3600 summarize)" >/dev/null ||
  fail "plan-wait outcomes were not counted in the summary"

if run_wait wait 30 900 2 plan-wait sideways bad-category >/dev/null 2>&1; then
  fail "plan-wait accepted an unknown category"
fi
if AIUR_EXECUTOR_STATE_DIR="$state_root" AIUR_EXECUTOR_RUN_ID=wait \
  AIUR_EXECUTOR_WAIT_CEILING_SECONDS=5 AIUR_EXECUTOR_WAIT_FLOOR_SECONDS=10 \
  "$script" due >/dev/null 2>&1; then
  fail "a ceiling below the floor was accepted"
fi

# Each wait bound must reject non-positive-integer values before any arithmetic
# reaches `prev * wait_backoff`.
for bad_floor in 0 abc; do
  if AIUR_EXECUTOR_STATE_DIR="$state_root" AIUR_EXECUTOR_RUN_ID=wait \
    AIUR_EXECUTOR_WAIT_FLOOR_SECONDS="$bad_floor" "$script" due >/dev/null 2>&1; then
    fail "invalid wait floor $bad_floor was accepted"
  fi
done
for bad_ceiling in 0 abc; do
  if AIUR_EXECUTOR_STATE_DIR="$state_root" AIUR_EXECUTOR_RUN_ID=wait \
    AIUR_EXECUTOR_WAIT_CEILING_SECONDS="$bad_ceiling" "$script" due >/dev/null 2>&1; then
    fail "invalid wait ceiling $bad_ceiling was accepted"
  fi
done
for bad_backoff in 0 abc; do
  if AIUR_EXECUTOR_STATE_DIR="$state_root" AIUR_EXECUTOR_RUN_ID=wait \
    AIUR_EXECUTOR_WAIT_BACKOFF="$bad_backoff" "$script" due >/dev/null 2>&1; then
    fail "invalid wait backoff $bad_backoff was accepted"
  fi
done

# A corrupted last_wait_interval_seconds falls back to the floor instead of
# feeding a non-integer into the widening arithmetic.
run corrupt-wait 3600 arm >/dev/null
corrupt_state="$state_root/corrupt-wait/retrospective-state.json"
jq '.last_wait_interval_seconds="not-a-number"' "$corrupt_state" > "$corrupt_state.tmp"
mv "$corrupt_state.tmp" "$corrupt_state"
jq -e '.prev_interval_seconds == 30 and .next_interval_seconds == 60' \
  <<< "$(run_wait corrupt-wait 30 900 2 plan-wait quiet recovered-from-corruption)" >/dev/null ||
  fail "corrupted last_wait_interval_seconds did not fall back to the floor"

printf 'executor-retrospective wait tests passed\n'
