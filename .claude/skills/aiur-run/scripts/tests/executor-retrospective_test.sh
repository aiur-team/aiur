#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/executor-retrospective.sh"
state_root="$(mktemp -d)"
trap 'rm -rf "$state_root"' EXIT

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

process_start_identity() {
  local pid="$1" identity stat rest

  if [ -r "/proc/$pid/stat" ]; then
    IFS= read -r stat < "/proc/$pid/stat" || return 1
    rest="${stat##*) }"
    set -- $rest
    [ "$#" -ge 20 ] || return 1
    printf 'proc:%s\n' "${20}"
    return
  fi

  identity="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$pid")" || return 1
  identity="${identity#"${identity%%[![:space:]]*}"}"
  identity="${identity%"${identity##*[![:space:]]}"}"
  [ -n "$identity" ] || return 1
  printf 'ps:%s\n' "$identity"
}

if AIUR_EXECUTOR_STATE_DIR="$state_root" "$script" due >/dev/null 2>&1; then
  fail "missing run ID was accepted"
fi

mkdir -p "$state_root/invalid-run-id"
for invalid_run_id in . ..; do
  if AIUR_EXECUTOR_STATE_DIR="$state_root/invalid-run-id" \
    AIUR_EXECUTOR_RUN_ID="$invalid_run_id" "$script" due >/dev/null 2>&1; then
    fail "run ID $invalid_run_id was accepted"
  fi
done
[ ! -e "$state_root/retrospective-state.json" ] ||
  fail "invalid run ID escaped its state directory"

run run-a 3600 arm >/dev/null
run run-a 3600 observe action reviewed-pr >/dev/null
run run-a 3600 observe no-action ci-pending >/dev/null

if run run-a 3600 observe no-action ci still pending >/dev/null 2>&1; then
  fail "observe accepted an unquoted multi-argument reason"
fi
run run-a 3600 observe no-action "ci still pending" >/dev/null

summary="$(run run-a 3600 summarize)"
jq -e '
  .total_wakes == 3 and
  .action_wakes == 1 and
  .no_action_wakes == 2 and
  any(.no_action_reasons[]; .reason == "ci still pending" and .count == 1)
' <<< "$summary" >/dev/null ||
  fail "run-a summary counts are wrong"

run run-b 3600 arm >/dev/null
jq -e '.total_wakes == 0' <<< "$(run run-b 3600 summarize)" >/dev/null ||
  fail "run-b inherited run-a history"

printf '%s\n' 'not-json' >> "$state_root/run-a/history.ndjson"
printf '%s\n' '"valid-json-but-not-an-event"' >> "$state_root/run-a/history.ndjson"
jq -e '.malformed_lines == 2 and .total_wakes == 3' <<< "$(run run-a 3600 summarize)" >/dev/null ||
  fail "malformed history was not isolated"

# The atomic count sentence lets `record` embed one window boundary, so a
# preflight summarize and a later record cannot report divergent counts.
jq -e '.count_sentence == "3 wakes (1 action / 2 no-action) since \(.since)"' \
  <<< "$(run run-a 3600 summarize)" >/dev/null ||
  fail "summary count sentence did not match its own counts"
jq -e '.count_sentence == "0 wakes (0 action / 0 no-action) since \(.since)"' \
  <<< "$(run empty-window 3600 summarize)" >/dev/null ||
  fail "empty-window count sentence was wrong"

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

run concurrent 60 record first unchanged > "$state_root/first.out" 2> "$state_root/first.err" &
first_pid=$!
run concurrent 60 record second unchanged > "$state_root/second.out" 2> "$state_root/second.err" &
second_pid=$!
wait "$first_pid"
wait "$second_pid"

recorded="$(jq -s '[.[] | select(.type == "hourly_retrospective")] | length' "$state_root/first.out" "$state_root/second.out")"
skipped="$(jq -s '[.[] | select(.recorded == false and .reason == "not_due")] | length' "$state_root/first.out" "$state_root/second.out")"
[ "$recorded" -eq 1 ] && [ "$skipped" -eq 1 ] || fail "concurrent record was not serialized"

signal_bin="$state_root/signal-bin"
signal_marker="$state_root/signal-date.started"
real_date="$(command -v date)"
mkdir -p "$signal_bin"
cat > "$signal_bin/date" <<'EOF'
#!/usr/bin/env bash
: > "$AIUR_TEST_DATE_MARKER"
sleep 1
exec "$AIUR_TEST_REAL_DATE" "$@"
EOF
chmod +x "$signal_bin/date"

AIUR_EXECUTOR_STATE_DIR="$state_root" \
  AIUR_EXECUTOR_RUN_ID=signal \
  AIUR_EXECUTOR_RETROSPECTIVE_SECONDS=60 \
  AIUR_TEST_DATE_MARKER="$signal_marker" \
  AIUR_TEST_REAL_DATE="$real_date" \
  PATH="$signal_bin:$PATH" \
  "$script" record interrupted unchanged > "$state_root/signal.out" &
signal_pid=$!

attempt=0
while [ ! -e "$signal_marker" ] && kill -0 "$signal_pid" 2>/dev/null && [ "$attempt" -lt 100 ]; do
  sleep 0.01
  attempt=$((attempt + 1))
done
[ -e "$signal_marker" ] || fail "signal test did not enter the locked section"
kill -TERM "$signal_pid"
set +e
wait "$signal_pid"
signal_status=$?
set -e
[ "$signal_status" -eq 143 ] || fail "TERM did not stop the locked operation"
[ ! -d "$state_root/signal/.retrospective-lock" ] || fail "TERM left the retrospective lock behind"
[ ! -s "$state_root/signal/history.ndjson" ] || fail "TERM allowed the locked operation to continue"

publish_signal_bin="$state_root/publish-signal-bin"
publish_signal_marker="$state_root/publish-signal-ln.started"
mkdir -p "$publish_signal_bin"
cat > "$publish_signal_bin/ln" <<'EOF'
#!/usr/bin/env bash
: > "$AIUR_TEST_LN_MARKER"
sleep 1
exit 1
EOF
chmod +x "$publish_signal_bin/ln"

AIUR_EXECUTOR_STATE_DIR="$state_root" \
  AIUR_EXECUTOR_RUN_ID=publish-signal \
  AIUR_EXECUTOR_RETROSPECTIVE_SECONDS=60 \
  AIUR_TEST_LN_MARKER="$publish_signal_marker" \
  PATH="$publish_signal_bin:$PATH" \
  "$script" record interrupted unchanged \
  > "$state_root/publish-signal.out" 2> "$state_root/publish-signal.err" &
publish_signal_pid=$!

attempt=0
while [ ! -e "$publish_signal_marker" ] && kill -0 "$publish_signal_pid" 2>/dev/null && [ "$attempt" -lt 100 ]; do
  sleep 0.01
  attempt=$((attempt + 1))
done
[ -e "$publish_signal_marker" ] || fail "publication signal test did not enter the mkdir-to-owner gap"
kill -TERM "$publish_signal_pid"
set +e
wait "$publish_signal_pid"
publish_signal_status=$?
set -e
[ "$publish_signal_status" -eq 143 ] || fail "TERM did not stop owner publication"
[ ! -d "$state_root/publish-signal/.retrospective-lock" ] ||
  fail "TERM left the unpublished lock directory behind"
if compgen -G "$state_root/publish-signal/.retrospective-lock.claim.*" >/dev/null; then
  fail "TERM left an owner claim behind"
fi

abandoned_bin="$state_root/abandoned-bin"
abandoned_marker="$state_root/abandoned-date.started"
mkdir -p "$abandoned_bin"
cat > "$abandoned_bin/date" <<'EOF'
#!/usr/bin/env bash
: > "$AIUR_TEST_DATE_MARKER"
sleep 1
exec "$AIUR_TEST_REAL_DATE" "$@"
EOF
chmod +x "$abandoned_bin/date"

AIUR_EXECUTOR_STATE_DIR="$state_root" \
  AIUR_EXECUTOR_RUN_ID=abandoned \
  AIUR_EXECUTOR_RETROSPECTIVE_SECONDS=60 \
  AIUR_TEST_DATE_MARKER="$abandoned_marker" \
  AIUR_TEST_REAL_DATE="$real_date" \
  PATH="$abandoned_bin:$PATH" \
  "$script" record abandoned unchanged \
  > "$state_root/abandoned.out" 2> "$state_root/abandoned.err" &
abandoned_pid=$!

attempt=0
while [ ! -e "$abandoned_marker" ] && kill -0 "$abandoned_pid" 2>/dev/null && [ "$attempt" -lt 100 ]; do
  sleep 0.01
  attempt=$((attempt + 1))
done
[ -e "$abandoned_marker" ] || fail "abandoned-lock test did not enter the locked section"
kill -KILL "$abandoned_pid"
set +e
wait "$abandoned_pid" 2>/dev/null
abandoned_status=$?
set -e
[ "$abandoned_status" -eq 137 ] || fail "KILL did not abandon the locked operation"
[ -d "$state_root/abandoned/.retrospective-lock" ] || fail "KILL did not leave a lock to reclaim"
compgen -G "$state_root/abandoned/.retrospective-lock/owner.*" >/dev/null ||
  fail "abandoned lock did not retain immutable owner metadata"

run abandoned 60 observe action "recovered abandoned lock" \
  > "$state_root/abandoned-recovered.out" 2> "$state_root/abandoned-recovered.err"
jq -e '.outcome == "action" and .reason == "recovered abandoned lock"' \
  "$state_root/abandoned-recovered.out" >/dev/null || fail "abandoned lock was not reclaimed"
grep -q 'reclaimed abandoned retrospective lock' "$state_root/abandoned-recovered.err" ||
  fail "abandoned-lock recovery was not reported"
[ ! -d "$state_root/abandoned/.retrospective-lock" ] || fail "recovered lock was not released"

run recycled-owner 60 due >/dev/null
recycled_lock_dir="$state_root/recycled-owner/.retrospective-lock"
mkdir "$recycled_lock_dir"
printf 'pid=%s\nstarted=not-the-current-process\ntoken=recycled-owner\n' "$$" \
  > "$recycled_lock_dir/owner.$$-recycled-owner"
run recycled-owner 60 observe action "recovered recycled owner" \
  > "$state_root/recycled-owner.out" 2> "$state_root/recycled-owner.err"
jq -e '.outcome == "action" and .reason == "recovered recycled owner"' \
  "$state_root/recycled-owner.out" >/dev/null || fail "recycled PID kept an abandoned lock alive"

run abandoned-window 60 due >/dev/null
abandoned_window_dir="$state_root/abandoned-window/.retrospective-lock"
abandoned_claim="$state_root/abandoned-window/.retrospective-lock.claim.999999999-dead"
mkdir "$abandoned_window_dir"
printf 'pid=999999999\nstarted=dead\ntoken=dead\n' > "$abandoned_claim"
run abandoned-window 60 observe action "recovered abandoned publication" \
  > "$state_root/abandoned-window.out" 2> "$state_root/abandoned-window.err"
jq -e '.outcome == "action" and .reason == "recovered abandoned publication"' \
  "$state_root/abandoned-window.out" >/dev/null ||
  fail "abandoned owner-publication window was not reclaimed"

run live-window 60 due >/dev/null
live_window_dir="$state_root/live-window/.retrospective-lock"
live_claim="$state_root/live-window/.retrospective-lock.claim.$$-live-window"
live_started="$(process_start_identity $$)"
mkdir "$live_window_dir"
printf 'pid=%s\nstarted=%s\ntoken=live-window\n' "$$" "$live_started" > "$live_claim"
run live-window 60 observe action "waited for live publication" \
  > "$state_root/live-window.out" 2> "$state_root/live-window.err" &
live_window_waiter_pid=$!
sleep 0.2
kill -0 "$live_window_waiter_pid" 2>/dev/null || fail "contender stole a publishing owner's lock"
[ -d "$live_window_dir" ] || fail "contender removed a publishing owner's lock directory"
[ -e "$live_claim" ] || fail "contender removed a live owner claim"
rm "$live_claim"
rmdir "$live_window_dir"
wait "$live_window_waiter_pid"

run live-lock 60 due >/dev/null
live_lock_dir="$state_root/live-lock/.retrospective-lock"
live_owner_marker="$live_lock_dir/owner.$$-live-owner"
mkdir "$live_lock_dir"
printf 'pid=%s\ntoken=live-owner\n' "$$" > "$live_owner_marker"

run live-lock 60 observe action "waited for live lock" \
  > "$state_root/live-lock.out" 2> "$state_root/live-lock.err" &
live_waiter_pid=$!
sleep 0.2
kill -0 "$live_waiter_pid" 2>/dev/null || fail "contender stole a live retrospective lock"
[ ! -s "$state_root/live-lock.out" ] || fail "contender wrote while the live lock was held"
[ -e "$live_owner_marker" ] || fail "contender removed a live owner marker"

rm "$live_owner_marker"
rmdir "$live_lock_dir"
wait "$live_waiter_pid"
jq -e '.outcome == "action" and .reason == "waited for live lock"' \
  "$state_root/live-lock.out" >/dev/null || fail "contender did not proceed after live lock release"

if grep -q 'date -d' "$script"; then
  fail "GNU-only date parsing returned"
fi

printf 'executor-retrospective tests passed\n'
