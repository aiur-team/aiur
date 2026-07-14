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

run concurrent 60 record first unchanged > "$state_root/first.out" &
first_pid=$!
run concurrent 60 record second unchanged > "$state_root/second.out" &
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

if grep -q 'date -d' "$script"; then
  fail "GNU-only date parsing returned"
fi

printf 'executor-retrospective tests passed\n'
