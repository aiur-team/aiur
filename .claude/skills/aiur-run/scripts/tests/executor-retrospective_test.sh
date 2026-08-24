#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/executor-retrospective.sh"
visual_test="$(cd "$(dirname "$0")/../../../aiur-meta/scripts/tests" && pwd)/capture-dashboard_test.mjs"
state_root="$(mktemp -d)"
export AIUR_EXECUTOR_RETRO_FILE="$state_root/test-retros.md"
export AIUR_EXECUTOR_RETROSPECTIVE_VISUAL_CHECK=0
export AIUR_EXECUTOR_RETROSPECTIVE_CLI_CHECK=0
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

if AIUR_EXECUTOR_STATE_DIR="$state_root" "$script" due >"$state_root/missing-run.out" 2> "$state_root/missing-run.err"; then
  fail "missing run ID was accepted"
else
  missing_run_status=$?
fi
[ "$missing_run_status" -eq 68 ] || fail "missing run ID did not return its distinct precondition status (got $missing_run_status)"
grep -q 'AIUR_EXECUTOR_RUN_ID is required' "$state_root/missing-run.err" || fail "missing run ID did not print the stderr precondition line"

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

# Dashboard evidence is stored beside the run retrospective and its short
# verdict is appended to the narrative. A fake browser command keeps this
# shell-level contract independent of a locally installed Chromium.
fake_capture="$state_root/fake-dashboard-capture.mjs"
cat > "$fake_capture" <<'EOF'
import { writeFileSync } from 'node:fs'

const out = process.argv[2]
writeFileSync(`${out}/report.json`, '{"verdict":"attention","pages":[]}\n')
writeFileSync(`${out}/verdict.md`, '# Dashboard visual check\n\n- build-orders: **attention** — metric-column-missing: Tickets is — for all 4 rows.\n\nOverall: **attention**.\n')
writeFileSync(`${out}/build-orders.png`, 'fake png evidence\n')
EOF

visual_retro="$state_root/visual-retrospective.md"
AIUR_EXECUTOR_STATE_DIR="$state_root" \
  AIUR_EXECUTOR_RUN_ID=visual \
  AIUR_EXECUTOR_RETROSPECTIVE_SECONDS=1 \
  AIUR_EXECUTOR_RETRO_FILE="$visual_retro" \
  AIUR_EXECUTOR_DASHBOARD_CAPTURE_SCRIPT="$fake_capture" \
  AIUR_DASHBOARD_URL="http://127.0.0.1:4017" \
  AIUR_DASHBOARD_USERNAME="test-user" \
  AIUR_DASHBOARD_PASSWORD="test-password" \
  AIUR_EXECUTOR_RETROSPECTIVE_VISUAL_CHECK=1 \
  "$script" record "visual check" unchanged > "$state_root/visual.out"
jq -e '.type == "hourly_retrospective"' "$state_root/visual.out" >/dev/null || fail "record did not preserve its hourly report"
grep -q 'metric-column-missing' "$visual_retro" || fail "visual verdict was not appended to retrospective"
visual_evidence_dir="$visual_retro.d"
find "$visual_evidence_dir" -name build-orders.png -print -quit | grep -q . || fail "visual capture was not retained beside retrospective"

# A missing capture helper is attention evidence, not a process exit: `record`
# still has to print the event whose durable state it has already written.
missing_capture_out="$state_root/missing-capture.out"
AIUR_EXECUTOR_STATE_DIR="$state_root" \
  AIUR_EXECUTOR_RUN_ID=missing-capture \
  AIUR_EXECUTOR_RETROSPECTIVE_SECONDS=1 \
  AIUR_EXECUTOR_RETRO_FILE="$state_root/missing-capture.md" \
  AIUR_EXECUTOR_DASHBOARD_CAPTURE_SCRIPT="$state_root/does-not-exist.mjs" \
  AIUR_EXECUTOR_RETROSPECTIVE_VISUAL_CHECK=1 \
  "$script" record "missing capture" unchanged > "$missing_capture_out"
jq -e '.type == "hourly_retrospective"' "$missing_capture_out" >/dev/null || fail "record lost its hourly report when the capture helper was missing"

# A missing daemon-published URL is a precondition failure: it must exit with
# its own code (67), print a one-line stderr that names the variable to set,
# and write a "did not run" verdict — never an "attention" one that an empty
# log could be mistaken for a healthy capture. Every discovery rung reads a
# URL that Aiur itself published, so a host with an unrelated listener still
# reports "could not discover" rather than auditing a stranger.
# AIUR_TMUX_SOCKET_DIR keeps the socket sweep off the developer's real sockets
# so the assertion means the same thing on a laptop running a live daemon as
# it does on a bare CI runner.
empty_socket_dir="$state_root/empty-sockets"
mkdir -p "$empty_socket_dir"
url_missing_retro="$state_root/url-missing-retrospective.md"
AIUR_EXECUTOR_STATE_DIR="$state_root" \
  AIUR_EXECUTOR_RUN_ID=url-missing \
  AIUR_EXECUTOR_RETRO_FILE="$url_missing_retro" \
  AIUR_EXECUTOR_DASHBOARD_CAPTURE_SCRIPT="$fake_capture" \
  AIUR_TMUX_SOCKET="no-such-aiur-tmux-socket" \
  AIUR_TMUX_SOCKET_DIR="$empty_socket_dir" \
  "$script" visual-check > "$state_root/url-missing.out" 2> "$state_root/url-missing.err" &
url_missing_pid=$!
set +e
wait "$url_missing_pid"
url_missing_status=$?
set -e
[ "$url_missing_status" -eq 67 ] || fail "missing dashboard URL did not return its explicit failure status"
grep -q 'could not discover the daemon dashboard URL' "$url_missing_retro" || fail "missing dashboard URL did not produce explicit evidence"
grep -q 'did not run' "$url_missing_retro" || fail "missing dashboard URL verdict did not say did-not-run"
grep -qiE 'attention|healthy' "$url_missing_retro" && fail "missing dashboard URL verdict must say neither attention nor healthy"
grep -q 'AIUR_DASHBOARD_URL is required' "$state_root/url-missing.err" || fail "missing dashboard URL did not print the stderr precondition line"
[ -s "$state_root/url-missing.out" ] && fail "missing dashboard URL must not print a capture report on stdout"
url_missing_report="$(find "$state_root/url-missing-retrospective.md.d" -name report.json -print -quit)"
[ -n "$url_missing_report" ] || fail "missing dashboard URL did not write a did-not-run report.json"
jq -e '.verdict == "did-not-run" and (.pages | length) == 0 and (.precondition | contains("AIUR_DASHBOARD_URL"))' "$url_missing_report" >/dev/null ||
  fail "missing dashboard URL report.json did not say did-not-run"

# The missing password is the third precondition, with its own code (69), its
# own stderr line, and a did-not-run verdict — distinct from a missing URL (67)
# or a missing run ID (68). Without the daemon environment fallback it is a
# hard failure: a capture that cannot authenticate must never look like one
# that ran.
password_missing_retro="$state_root/password-missing-retrospective.md"
set +e
AIUR_EXECUTOR_STATE_DIR="$state_root" \
  AIUR_EXECUTOR_RUN_ID=password-missing \
  AIUR_EXECUTOR_RETRO_FILE="$password_missing_retro" \
  AIUR_EXECUTOR_DASHBOARD_CAPTURE_SCRIPT="$fake_capture" \
  AIUR_DASHBOARD_URL="http://127.0.0.1:4019" \
  AIUR_DASHBOARD_USERNAME="test-user" \
  AIUR_TMUX_SOCKET_DIR="$empty_socket_dir" \
  "$script" visual-check > "$state_root/password-missing.out" 2> "$state_root/password-missing.err"
password_missing_status=$?
set -e
[ "$password_missing_status" -eq 69 ] || fail "missing dashboard password did not return its explicit failure status"
grep -q 'did not run' "$password_missing_retro" || fail "missing dashboard password verdict did not say did-not-run"
grep -qiE 'attention|healthy' "$password_missing_retro" && fail "missing dashboard password verdict must say neither attention nor healthy"
grep -q 'AIUR_DASHBOARD_PASSWORD is required' "$state_root/password-missing.err" || fail "missing dashboard password did not print the stderr precondition line"
password_missing_report="$(find "$state_root/password-missing-retrospective.md.d" -name report.json -print -quit)"
[ -n "$password_missing_report" ] || fail "missing dashboard password did not write a did-not-run report.json"
jq -e '.verdict == "did-not-run" and (.pages | length) == 0 and (.precondition | contains("AIUR_DASHBOARD_PASSWORD"))' "$password_missing_report" >/dev/null ||
  fail "missing dashboard password report.json did not say did-not-run"
[ -e "$state_root/password-missing-retrospective.md.d" ] && \
  find "$state_root/password-missing-retrospective.md.d" -name build-orders.png -print -quit | grep -q . \
  && fail "password-missing run must not invoke the capture"

# The hourly `record` path must not swallow the precondition line the way a
# wrapper redirecting stdout+stderr to a log does. record still completes and
# still writes the did-not-run narrative, but it forwards one stderr line
# naming the failing precondition (its status plus the variable to set), so a
# redirected log is never silently empty next to a bare exit code.
record_precondition_retro="$state_root/record-precondition-retrospective.md"
set +e
AIUR_EXECUTOR_STATE_DIR="$state_root" \
  AIUR_EXECUTOR_RUN_ID=record-precondition \
  AIUR_EXECUTOR_RETROSPECTIVE_SECONDS=1 \
  AIUR_EXECUTOR_RETRO_FILE="$record_precondition_retro" \
  AIUR_EXECUTOR_DASHBOARD_CAPTURE_SCRIPT="$fake_capture" \
  AIUR_TMUX_SOCKET="no-such-aiur-tmux-socket" \
  AIUR_TMUX_SOCKET_DIR="$empty_socket_dir" \
  AIUR_EXECUTOR_RETROSPECTIVE_VISUAL_CHECK=1 \
  "$script" record "visual check" unchanged > "$state_root/record-precondition.out" 2> "$state_root/record-precondition.err"
record_precondition_status=$?
set -e
[ "$record_precondition_status" -eq 0 ] || fail "record exited $record_precondition_status when the visual-check precondition failed"
jq -e '.type == "hourly_retrospective"' "$state_root/record-precondition.out" >/dev/null ||
  fail "record did not emit its hourly report when the visual-check precondition failed"
grep -q 'visual check did not run (status 67)' "$state_root/record-precondition.err" ||
  fail "record did not forward the visual-check precondition line to its stderr"
grep -q 'AIUR_DASHBOARD_URL is required' "$state_root/record-precondition.err" ||
  fail "record did not forward the failing variable name to its stderr"

# The no-guessed-port invariant above is only as strong as the script's
# refusal to hardcode one. This is the regression that shipped once already:
# a fallback rung reading a literal :4000 passes on a CI runner with nothing
# listening while silently capturing whatever answers on a developer's host.
if grep -q '4000' "$script"; then
  fail "discovery reintroduced a hardcoded dashboard port"
fi

# Discovery ladder. The daemon publishes @aiur_control_url on its own tmux
# server, and the Executor normally runs outside that server, so these rungs
# are stubbed with a PATH tmux shim plus a scoped socket directory.
tmux_shim_dir="$state_root/bin"
mkdir -p "$tmux_shim_dir"
cat > "$tmux_shim_dir/tmux" <<'EOF'
#!/usr/bin/env bash
# Stand-in for tmux show-options/list-panes. FAKE_TMUX_URLS maps socket name
# to the published control URL, one "socket=url" pair per line. A socket with
# no entry answers empty, exactly as a server that never bound a dashboard
# does. FAKE_TMUX_PANE_PID is the newline-separated pane PID list list-panes
# reports, so the daemon-environment fallback reads exactly the process(es)
# the test chooses — including an inert first pane to prove the fallback does
# not stop at the first candidate.
socket=""
if [ "${1:-}" = "-L" ]; then
  socket="$2"
  shift 2
fi
case "${1:-}" in
  show-options)
    [ -n "$socket" ] || exit 0
    while IFS= read -r pair; do
      [ -n "$pair" ] || continue
      if [ "${pair%%=*}" = "$socket" ]; then
        printf '%s\n' "${pair#*=}"
        exit 0
      fi
    done <<< "${FAKE_TMUX_URLS:-}"
    exit 0
    ;;
  list-panes)
    printf '%s\n' "${FAKE_TMUX_PANE_PID:-1}"
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$tmux_shim_dir/tmux"

make_socket() {
  python3 -c 'import socket,sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])' "$1"
}

sweep_socket_dir="$state_root/socks"
mkdir -p "$sweep_socket_dir"
make_socket "$sweep_socket_dir/aiur-alpha"
make_socket "$sweep_socket_dir/aiur-quiet"

# A live aiur-* server that publishes a URL is discovered even though the
# Executor's own tmux server (the ambient one) publishes nothing. This is the
# rung that was missing entirely: without it the hourly check never ran.
sweep_retro="$state_root/sweep-retrospective.md"
set +e
PATH="$tmux_shim_dir:$PATH" \
  FAKE_TMUX_URLS="aiur-alpha=http://127.0.0.1:4021" \
  AIUR_EXECUTOR_STATE_DIR="$state_root" \
  AIUR_EXECUTOR_RUN_ID=sweep \
  AIUR_EXECUTOR_RETRO_FILE="$sweep_retro" \
  AIUR_EXECUTOR_DASHBOARD_CAPTURE_SCRIPT="$fake_capture" \
  AIUR_DASHBOARD_USERNAME="test-user" \
  AIUR_DASHBOARD_PASSWORD="test-password" \
  AIUR_TMUX_SOCKET_DIR="$sweep_socket_dir" \
  "$script" visual-check >/dev/null 2>&1
sweep_status=$?
set -e
[ "$sweep_status" -eq 0 ] || fail "socket sweep did not discover a publishing aiur tmux server"
grep -q 'metric-column-missing' "$sweep_retro" || fail "socket sweep did not append its capture verdict"

# Two live daemons publishing different dashboards is ambiguous. Picking by
# glob order would silently audit the wrong fleet, so discovery must refuse
# and send the operator to AIUR_TMUX_SOCKET.
make_socket "$sweep_socket_dir/aiur-beta"
ambiguous_retro="$state_root/ambiguous-retrospective.md"
set +e
PATH="$tmux_shim_dir:$PATH" \
  FAKE_TMUX_URLS="aiur-alpha=http://127.0.0.1:4021
aiur-beta=http://127.0.0.1:4022" \
  AIUR_EXECUTOR_STATE_DIR="$state_root" \
  AIUR_EXECUTOR_RUN_ID=ambiguous \
  AIUR_EXECUTOR_RETRO_FILE="$ambiguous_retro" \
  AIUR_EXECUTOR_DASHBOARD_CAPTURE_SCRIPT="$fake_capture" \
  AIUR_TMUX_SOCKET_DIR="$sweep_socket_dir" \
  "$script" visual-check >/dev/null 2>&1
ambiguous_status=$?
set -e
[ "$ambiguous_status" -eq 67 ] || fail "ambiguous multi-daemon sweep did not refuse to guess"
grep -q 'could not discover the daemon dashboard URL' "$ambiguous_retro" || fail "ambiguous sweep did not produce explicit attention evidence"

# A socket naming this run resolves the same ambiguity in the Executor's
# favour rather than failing.
make_socket "$sweep_socket_dir/aiur-gamma"
run_id_retro="$state_root/run-id-retrospective.md"
set +e
PATH="$tmux_shim_dir:$PATH" \
  FAKE_TMUX_URLS="aiur-alpha=http://127.0.0.1:4021
aiur-beta=http://127.0.0.1:4022
aiur-gamma=http://127.0.0.1:4023" \
  AIUR_EXECUTOR_STATE_DIR="$state_root" \
  AIUR_EXECUTOR_RUN_ID=gamma \
  AIUR_EXECUTOR_RETRO_FILE="$run_id_retro" \
  AIUR_EXECUTOR_DASHBOARD_CAPTURE_SCRIPT="$fake_capture" \
  AIUR_DASHBOARD_USERNAME="test-user" \
  AIUR_DASHBOARD_PASSWORD="test-password" \
  AIUR_TMUX_SOCKET_DIR="$sweep_socket_dir" \
  "$script" visual-check >/dev/null 2>&1
run_id_status=$?
set -e
[ "$run_id_status" -eq 0 ] || fail "run-id-named socket did not win the sweep"

# The daemon-environment credential fallback. When the wrapper carries no
# credentials but the daemon's BEAM does, visual-check must read them from the
# running daemon's /proc/<beam>/environ instead of failing — that is the "run
# standalone with nothing set up by hand" path. The fake daemon keeps the
# credentials off the pane shell's own environment (so the pane-env fallback
# cannot satisfy the read) and puts them only on a beam.smp-named child, the
# shape the real launcher chain produces when the BEAM loads .env itself.
daemon_env_socket_dir="$state_root/denv"
mkdir -p "$daemon_env_socket_dir"
make_socket "$daemon_env_socket_dir/aiur-d"
daemon_beam_pidfile="$state_root/daemon-beam.pid"
cat > "$state_root/fake-daemon.sh" <<'EOF'
#!/usr/bin/env bash
# Stands in for the daemon's tmux pane. The shell itself does not carry the
# dashboard credentials; the beam.smp child does, as when the BEAM loaded .env.
AIUR_DASHBOARD_USERNAME=daemon-user AIUR_DASHBOARD_PASSWORD=daemon-secret \
  bash -c 'exec -a beam.smp sleep 300' &
echo $! > "$FAKE_DAEMON_BEAM_PIDFILE"
exec sleep 300
EOF
chmod +x "$state_root/fake-daemon.sh"
FAKE_DAEMON_BEAM_PIDFILE="$daemon_beam_pidfile" "$state_root/fake-daemon.sh" &
fake_daemon_pid=$!
daemon_beam_pid=""
attempt=0
while [ ! -s "$daemon_beam_pidfile" ] && [ "$attempt" -lt 100 ]; do
  sleep 0.01
  attempt=$((attempt + 1))
done
daemon_beam_pid="$(cat "$daemon_beam_pidfile" 2>/dev/null || true)"

env_dump_capture="$state_root/env-dump-capture.mjs"
cat > "$env_dump_capture" <<'EOF'
import { writeFileSync } from 'node:fs'
const out = process.argv[2]
writeFileSync(`${out}/env.json`, JSON.stringify({
  username: process.env.AIUR_DASHBOARD_USERNAME,
  password: process.env.AIUR_DASHBOARD_PASSWORD
}))
writeFileSync(`${out}/report.json`, '{"verdict":"healthy","pages":[]}\n')
writeFileSync(`${out}/verdict.md`, '# Dashboard visual check\n\n- capture: **healthy**\n\nOverall: **healthy**.\n')
EOF

daemon_env_retro="$state_root/daemon-env-retrospective.md"
set +e
PATH="$tmux_shim_dir:$PATH" \
  FAKE_TMUX_URLS="aiur-d=http://127.0.0.1:4024" \
  FAKE_TMUX_PANE_PID=$'999999\n'"$fake_daemon_pid" \
  AIUR_EXECUTOR_STATE_DIR="$state_root" \
  AIUR_EXECUTOR_RUN_ID=daemonenv \
  AIUR_EXECUTOR_RETRO_FILE="$daemon_env_retro" \
  AIUR_EXECUTOR_DASHBOARD_CAPTURE_SCRIPT="$env_dump_capture" \
  AIUR_TMUX_SOCKET_DIR="$daemon_env_socket_dir" \
  "$script" visual-check >/dev/null 2>&1
daemon_env_status=$?
set -e
[ "$daemon_env_status" -eq 0 ] || fail "daemon-environment credential fallback failed with status $daemon_env_status"
daemon_env_evidence="$(find "$daemon_env_retro.d" -name env.json -print -quit)"
[ -n "$daemon_env_evidence" ] || fail "daemon-environment fallback did not invoke the capture"
jq -e '.username == "daemon-user" and .password == "daemon-secret"' "$daemon_env_evidence" >/dev/null ||
  fail "daemon-environment credentials did not reach the capture"

# The pane-env fallback must not masquerade as the beam read: the pane shell
# has no credentials here, so if the capture received them it can only have
# come from the daemon BEAM's environment. And because the pane list put an
# inert PID first, reaching the daemon proves the fallback walks every pane
# rather than stopping at the first candidate.
[ -n "$fake_daemon_pid" ] && kill "$fake_daemon_pid" 2>/dev/null || true
[ -n "$daemon_beam_pid" ] && kill "$daemon_beam_pid" 2>/dev/null || true

# The documented URL override works as an argument, not only as an env var.
# The dispatcher never shifts, so "$@" still carries the subcommand word and
# the override arrives as $2.
arg_retro="$state_root/arg-override-retrospective.md"
set +e
AIUR_EXECUTOR_STATE_DIR="$state_root" \
  AIUR_EXECUTOR_RUN_ID=arg-override \
  AIUR_EXECUTOR_RETRO_FILE="$arg_retro" \
  AIUR_EXECUTOR_DASHBOARD_CAPTURE_SCRIPT="$fake_capture" \
  AIUR_DASHBOARD_USERNAME="test-user" \
  AIUR_DASHBOARD_PASSWORD="test-password" \
  AIUR_TMUX_SOCKET_DIR="$empty_socket_dir" \
  "$script" visual-check "http://127.0.0.1:4018" >/dev/null 2>&1
arg_status=$?
set -e
[ "$arg_status" -eq 0 ] || fail "visual-check rejected its documented dashboard-url argument"
grep -q 'metric-column-missing' "$arg_retro" || fail "argument override did not append its capture verdict"

# A non-URL argument and an extra argument are still usage errors.
set +e
AIUR_EXECUTOR_STATE_DIR="$state_root" AIUR_EXECUTOR_RUN_ID=arg-bad \
  "$script" visual-check not-a-url >/dev/null 2>&1
arg_bad_status=$?
AIUR_EXECUTOR_STATE_DIR="$state_root" AIUR_EXECUTOR_RUN_ID=arg-many \
  "$script" visual-check http://127.0.0.1:4018 extra >/dev/null 2>&1
arg_many_status=$?
set -e
[ "$arg_bad_status" -eq 64 ] || fail "visual-check accepted a non-URL argument"
[ "$arg_many_status" -eq 64 ] || fail "visual-check accepted too many arguments"

# The terminal evidence is appended to the same narrative and retains the
# command timing/output shape plus the pane/config coupling.
fake_cli="$state_root/fake-cli"
cat > "$fake_cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  status) printf 'ISSUE STATE   TITLE\nAGENTS 0/16 (binding: none)\n' ;;
  agents) printf 'ISSUE  STATE      RUNTIME  ACTIVITY\n(no active agents)\n' ;;
  alerts) printf '{"topic":"ticket.1.agent.progress","needs_attention":false}\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$fake_cli"
fake_tmux="$state_root/fake-tmux"
cat > "$fake_tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *" has-session "*) exit 0 ;;
  *" list-panes "*) printf '%%1\n%%2\n%%3\n%%4\n%%5\n%%6\n' ;;
  *" capture-pane "*) printf 'Agents: 0/16 ← →\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$fake_tmux"
cli_retro="$state_root/cli-retrospective.md"
cli_config="$state_root/cli-config"
printf 'pre_warmed_sessions: 3\nagent:\n  max_concurrent_agents: 16\n' > "$cli_config"
AIUR_EXECUTOR_STATE_DIR="$state_root" \
  AIUR_EXECUTOR_RUN_ID=cli \
  AIUR_EXECUTOR_RETROSPECTIVE_SECONDS=1 \
  AIUR_EXECUTOR_RETRO_FILE="$cli_retro" \
  AIUR_EXECUTOR_RETROSPECTIVE_CLI_CHECK=1 \
  AIUR_EXECUTOR_CLI_CHECK_DIR="$cli_retro.d/cli" \
  AIUR_EXECUTOR_REPO_ROOT="$state_root" \
  AIUR_EXECUTOR_CONFIG="$cli_config" \
  AIUR_CMD="$fake_cli" \
  AIUR_TMUX_BIN="$fake_tmux" \
  AIUR_EXECUTOR_TMUX="$fake_tmux" \
  AIUR_TMUX_SOCKET=aiur-test \
  AIUR_TMUX_SESSION=aiur-test-default \
  "$script" record "cli check" unchanged > "$state_root/cli.out"
grep -q 'Interactive CLI check' "$cli_retro" || fail "CLI check heading was not appended"
grep -q 'aiur status' "$cli_retro" || fail "CLI command evidence was not appended"
grep -q 'elapsed_ms=' "$cli_retro" || fail "CLI elapsed time was not appended"
grep -q 'first_lines:' "$cli_retro" || fail "CLI first output lines were not appended"
grep -q 'panes=6' "$cli_retro" || fail "pane count was not appended"
grep -q 'pre_warmed_sessions=3' "$cli_retro" || fail "warm-pool count was not appended"
grep -q 'live_agent_cap=16' "$cli_retro" || fail "live cap was not appended"
grep -q 'TUI: attached=true, agents_row=true, cap_controls=true' "$cli_retro" || fail "TUI surface was not appended"

# Both optional checks are best-effort. An unavailable helper must degrade the
# evidence, never terminate `record` after the timer has already advanced —
# otherwise the caller loses the hourly report for the whole window.
missing_retro="$state_root/missing-helper-retrospective.md"
set +e
AIUR_EXECUTOR_STATE_DIR="$state_root" \
  AIUR_EXECUTOR_RUN_ID=missing-helper \
  AIUR_EXECUTOR_RETROSPECTIVE_SECONDS=1 \
  AIUR_EXECUTOR_RETRO_FILE="$missing_retro" \
  AIUR_EXECUTOR_RETROSPECTIVE_VISUAL_CHECK=1 \
  AIUR_EXECUTOR_DASHBOARD_CAPTURE_SCRIPT="$state_root/absent-capture.mjs" \
  AIUR_EXECUTOR_RETROSPECTIVE_CLI_CHECK=1 \
  AIUR_EXECUTOR_CLI_CHECK_SCRIPT="$state_root/absent-cli-check.sh" \
  "$script" record "missing helpers" unchanged > "$state_root/missing.out" 2>/dev/null
missing_status=$?
set -e
[ "$missing_status" -eq 0 ] || fail "record exited $missing_status when an optional check helper was unavailable"
jq -e '.type == "hourly_retrospective"' "$state_root/missing.out" >/dev/null ||
  fail "record did not emit its hourly report when an optional check helper was unavailable"

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
