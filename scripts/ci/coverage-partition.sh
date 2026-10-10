#!/usr/bin/env bash
# Run one coverage shard, bounded and logged. Env: PARTITION. Runs in src/.
#
# Capture the full log for the known-flaky reporter, but write it to a file
# instead of piping through `tee`: tests that leave orphaned background
# processes (opencode/sleep CLI harnesses) hold the pipe's write end open, so
# `tee` never sees EOF and the step hangs until the job dies as a
# non-informative cancelled red (#2397). A file redirect lets those orphans
# inherit the file FD harmlessly while the step completes the moment `make`
# exits.
#
# The bound lives here, in the step, not on the job. A job-level timeout
# cancels the job and a cancelled job skips every remaining step, so `Print
# partition log` and the known-flaky report are lost exactly when a wedge makes
# them most valuable. `timeout` makes the step exit normally with 124, which is
# an ordinary step *failure*, so the `failure()` steps after it still run and
# the red names what it is.
#
# `tail -F` mirrors the log to the live job output while the partition runs. A
# partition that takes its own runner down (#2560) ends the job mid-step, skips
# every remaining step, and used to report as a bare exit 143 with not one line
# of test output. Streaming means the log GitHub has already ingested names the
# test that was running. This is a `tail`, not a `tee`: nothing downstream of
# `make` holds a pipe open, so the orphaned-background-process hang of #2397
# cannot recur.
set -euo pipefail
log="$RUNNER_TEMP/coverage-partition-$PARTITION.log"
: > "$log"
tail -n +1 -F "$log" &
tail_pid=$!
status=0
timeout --signal=TERM --kill-after=60s 20m \
  make coverage-partition > "$log" 2>&1 || status=$?
sleep 2
kill "$tail_pid" 2>/dev/null || true
wait "$tail_pid" 2>/dev/null || true
if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
  echo "::error::coverage partition $PARTITION exceeded its 20m bound and was terminated; partial log follows in the next step"
elif [ "$status" -ne 0 ]; then
  echo "::error::coverage partition $PARTITION failed with status $status; full log follows in the next step"
fi
exit "$status"
