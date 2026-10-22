#!/usr/bin/env bash
set -euo pipefail

log_file="${1:?usage: run-coverage-partition.sh <log-file> <timings-file>}"
timings_file="${2:?usage: run-coverage-partition.sh <log-file> <timings-file>}"
status_file="${3:?usage: run-coverage-partition.sh <log-file> <timings-file> <status-file>}"
partition="${MIX_TEST_PARTITION:?MIX_TEST_PARTITION must be set}"

: > "$log_file"
tail -n +1 -F "$log_file" &
tail_pid=$!
status=0
AIUR_TEST_TIMINGS_PATH="$timings_file" timeout --signal=TERM --kill-after=60s 20m \
  make coverage-partition > "$log_file" 2>&1 || status=$?
sleep 2
kill "$tail_pid" 2>/dev/null || true
wait "$tail_pid" 2>/dev/null || true
printf '%s\n' "$status" > "$status_file"

if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
  echo "::error::coverage partition $partition exceeded its 20m bound and was terminated; partial log follows in the next step"
elif [ "$status" -ne 0 ]; then
  echo "::error::coverage partition $partition failed with status $status; full log follows in the next step"
fi
exit "$status"
