#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/retrospective-test-helpers.sh"

node --test "$visual_test"

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

default_run_root="$state_root/default-run-id"
env -u AIUR_EXECUTOR_RUN_ID -u AIUR_TMUX_SOCKET AIUR_TMUX_SESSION=stale-session \
  AIUR_EXECUTOR_STATE_DIR="$default_run_root" "$script" due >/dev/null
[ -s "$default_run_root/default/retrospective-state.json" ] ||
  fail "missing run ID did not use the documented default"
[ ! -e "$default_run_root/stale-session/retrospective-state.json" ] ||
  fail "stale tmux session name was used outside a live Aiur tmux session"

tmux_stub_dir="$state_root/tmux-bin"
mkdir -p "$tmux_stub_dir"
cat > "$tmux_stub_dir/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$TMUX_TEST_SESSION_ID"
EOF
chmod +x "$tmux_stub_dir/tmux"
session_state_root="$state_root/session-run-id"
for session_id in '$7' '$7' '$8'; do
  TMUX_TEST_SESSION_ID="$session_id" PATH="$tmux_stub_dir:$PATH" \
    AIUR_EXECUTOR_STATE_DIR="$session_state_root" AIUR_TMUX_SOCKET=aiur-test \
    AIUR_TMUX_SESSION=aiur-test-default env -u AIUR_EXECUTOR_RUN_ID "$script" due >/dev/null
done
[ -s "$session_state_root/tmux-aiur-test-7/retrospective-state.json" ] ||
  fail "live tmux session ID was not used as the retrospective identity"
[ -s "$session_state_root/tmux-aiur-test-8/retrospective-state.json" ] ||
  fail "a recreated tmux session reused the previous retrospective identity"

mkdir -p "$state_root/invalid-run-id"
for invalid_run_id in . ..; do
  if AIUR_EXECUTOR_STATE_DIR="$state_root/invalid-run-id" \
    AIUR_EXECUTOR_RUN_ID="$invalid_run_id" "$script" due >/dev/null 2>&1; then
    fail "run ID $invalid_run_id was accepted"
  fi
done
[ ! -e "$state_root/retrospective-state.json" ] ||
  fail "invalid run ID escaped its state directory"

default_home="$state_root/default-home"
default_run="boot-default-$RANDOM"
env -u AIUR_EXECUTOR_STATE_DIR -u AIUR_EXECUTOR_RETRO_FILE \
  HOME="$default_home" AIUR_EXECUTOR_REPO=owner/repo \
  AIUR_EXECUTOR_RUN_ID="$default_run" AIUR_EXECUTOR_RETROSPECTIVE_SECONDS=1 \
  "$script" record "critical path waited on CI" "reduced admission" >/dev/null
default_node="$default_home/.aiur/repo/owner/repo"
[ -s "$default_node/executor/$default_run/retrospective-state.json" ] ||
  fail "default retrospective state did not use the repository state node"
default_retro="$default_node/meta/retros/$default_run.md"
[ -s "$default_retro" ] || fail "record did not write the default narrative retrospective"
grep -q 'critical path waited on CI' "$default_retro" || fail "narrative omitted the assessment"
grep -q 'reduced admission' "$default_retro" || fail "narrative omitted the adjustment"

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

lock_held_file="$state_root/first-lock-held"
release_lock_file="$state_root/release-first-lock"
AIUR_EXECUTOR_RETROSPECTIVE_TEST_LOCK_HELD_FILE="$lock_held_file" \
  AIUR_EXECUTOR_RETROSPECTIVE_TEST_RELEASE_FILE="$release_lock_file" \
  run concurrent 60 record first unchanged > "$state_root/first.out" 2> "$state_root/first.err" &
first_pid=$!
for _ in $(seq 1 200); do
  [ -e "$lock_held_file" ] && break
  kill -0 "$first_pid" 2>/dev/null || fail "first recorder exited before holding the lock"
  sleep 0.01
done
[ -e "$lock_held_file" ] || fail "first recorder did not reach the lock barrier"
run concurrent 60 record second unchanged > "$state_root/second.out" 2> "$state_root/second.err" &
second_pid=$!
sleep 0.1
kill -0 "$second_pid" 2>/dev/null || fail "second recorder exited while first held the lock"
: > "$release_lock_file"
wait "$first_pid"
wait "$second_pid"

jq -e '.type == "hourly_retrospective"' "$state_root/first.out" >/dev/null ||
  fail "first recorder did not record while holding the lock"
jq -e '.recorded == false and .reason == "not_due"' "$state_root/second.out" >/dev/null ||
  fail "second recorder did not skip while first held the lock"

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
for _ in $(seq 1 200); do
  [ ! -d "$live_window_dir" ] && break
  sleep 0.01
done
[ ! -d "$live_window_dir" ] || fail "contender did not reclaim the released publication lock"
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
for _ in $(seq 1 200); do
  [ ! -d "$live_lock_dir" ] && break
  sleep 0.01
done
[ ! -d "$live_lock_dir" ] || fail "contender did not reclaim the released live lock"
wait "$live_waiter_pid"
jq -e '.outcome == "action" and .reason == "waited for live lock"' \
  "$state_root/live-lock.out" >/dev/null || fail "contender did not proceed after live lock release"

if grep -q 'date -d' "$script" "$(dirname "$script")"/lib/*.sh; then
  fail "GNU-only date parsing returned"
fi

printf 'executor-retrospective tests passed\n'
