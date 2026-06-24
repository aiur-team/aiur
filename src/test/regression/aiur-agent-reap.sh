#!/usr/bin/env bash
# Automated, hermetic regression for #423: reap tmux-pane + headless agents on
# orchestrator teardown (crash AND stop).
#
# Simulates BEAM death WITHOUT a real release or an actual :emfile: it sources
# aiur-engine.sh and drives reap_aiur_agents + the BEAM-death watchdog against
#
#   * fake PANE agents     — real tmux panes on a throwaway socket
#   * fake HEADLESS agents — sleep process *trees* recorded in a pidfile, the
#                            way Aiur.ProcessReaper writes AIUR_AGENT_TMPFILE
#
# Asserts that after teardown there are zero surviving pane/headless agents and
# no live aiur tmux server, while a pid-reuse decoy (a live process whose
# command no longer matches the recorded comm) is deliberately spared.
#
#   bash src/test/regression/aiur-agent-reap.sh
#
# Exits 0 on success, 1 on failure. Cleans up on exit.

set -u

ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../packaging/npm/aiur-cli/libexec" && pwd)/aiur-engine.sh"
[ -f "$ENGINE" ] || { echo "FAIL: engine not found at $ENGINE"; exit 1; }
command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 0; }

# shellcheck source=/dev/null
source "$ENGINE"
# The engine sets -euo pipefail at load; the harness drives its own control flow.
set +e +u +o pipefail

SOCKET="aiur-reaptest-$$"
SPAWNED=()

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  local p
  for p in "${SPAWNED[@]}"; do [ -n "$p" ] && kill -KILL "$p" 2>/dev/null; done
  rm -f /tmp/aiur-reaptest.$$.* 2>/dev/null
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }
gone() { ! kill -0 "$1" 2>/dev/null; }

wait_gone() { # pid, timeout_tenths(default 50 = 5s)
  local pid="$1" n="${2:-50}"
  while [ "$n" -gt 0 ]; do gone "$pid" && return 0; sleep 0.1; n=$((n - 1)); done
  gone "$pid"
}
server_dead() { ! tmux -L "$SOCKET" list-sessions >/dev/null 2>&1; }

# Build the fake aiur tmux server with two pane agents; echo their pane pids.
build_panes() {
  tmux -L "$SOCKET" new-session -d -s reap "sleep 600" || fail "could not start tmux server"
  tmux -L "$SOCKET" new-window -t reap "sleep 600" || fail "could not add pane agent"
  tmux -L "$SOCKET" list-panes -s -t reap -F '#{pane_pid}'
}

echo "=== Test 1: reap_aiur_agents (crash-equivalent — BEAM already gone) ==="

PIDFILE1="/tmp/aiur-reaptest.$$.1"
: >"$PIDFILE1"

PANE_PIDS=()
while IFS= read -r _pp; do [ -n "$_pp" ] && PANE_PIDS+=("$_pp"); done < <(build_panes)
[ "${#PANE_PIDS[@]}" -ge 2 ] || fail "expected >=2 pane agents, got ${#PANE_PIDS[@]}"

# Two headless agent trees (a parent that also has a child, to prove the reaper
# kills the whole tree the way Aiur.RemoteControl.graceful_kill_tree does).
bash -c 'sleep 600 & exec -a aiur-fake-claude sleep 600' & CLAUDE=$!
disown 2>/dev/null
bash -c 'sleep 600 & exec -a aiur-fake-codex  sleep 600' & CODEX=$!
disown 2>/dev/null
# A headless agent recorded with NO comm (the BEAM writes a bare `pid N` line for
# os_pids registered without a :comm) must be reaped unconditionally.
sleep 600 & BARE=$!
disown 2>/dev/null
SPAWNED+=("$CLAUDE" "$CODEX" "$BARE")
sleep 0.3
CLAUDE_CHILD="$(pgrep -P "$CLAUDE" | head -n1)"
CODEX_CHILD="$(pgrep -P "$CODEX" | head -n1)"
[ -n "$CLAUDE_CHILD" ] || fail "claude agent has no child to tree-reap"
printf 'pid %s claude\n' "$CLAUDE" >>"$PIDFILE1"
printf 'pid %s codex\n' "$CODEX" >>"$PIDFILE1"
printf 'pid %s\n' "$BARE" >>"$PIDFILE1" # bare line, no comm → unconditional reap
printf 'pane %%9\n' >>"$PIDFILE1" # pane refs are ignored by the launcher reaper

# Decoy: a live process recorded with comm "claude" whose command is NOT claude.
# The pid-reuse guard must spare it.
sleep 600 & DECOY=$!
disown 2>/dev/null
SPAWNED+=("$DECOY")
printf 'pid %s claude\n' "$DECOY" >>"$PIDFILE1"

reap_aiur_agents "$SOCKET" "$PIDFILE1"

server_dead || fail "aiur tmux server still alive after reap"
for p in "${PANE_PIDS[@]}"; do wait_gone "$p" || fail "pane agent $p survived reap"; done
wait_gone "$CLAUDE" || fail "claude agent $CLAUDE survived reap"
wait_gone "$CODEX" || fail "codex agent $CODEX survived reap"
wait_gone "$BARE" || fail "bare (no-comm) agent $BARE survived reap"
wait_gone "$CLAUDE_CHILD" || fail "claude child $CLAUDE_CHILD survived reap (tree not killed)"
[ -n "$CODEX_CHILD" ] && { wait_gone "$CODEX_CHILD" || fail "codex child survived reap"; }
gone "$DECOY" && fail "pid-reuse decoy $DECOY was killed (comm guard failed)"
echo "  ok: panes + headless trees (incl. bare) reaped, server gone, decoy spared"

echo "=== Test 2: BEAM-death watchdog (simulates crash mid-turn) ==="

PIDFILE2="/tmp/aiur-reaptest.$$.2"
: >"$PIDFILE2"

PANE_PIDS2=()
while IFS= read -r _pp; do [ -n "$_pp" ] && PANE_PIDS2+=("$_pp"); done < <(build_panes)
[ "${#PANE_PIDS2[@]}" -ge 1 ] || fail "expected pane agents in test 2"

bash -c 'sleep 600 & exec -a aiur-fake-claude sleep 600' & AGENT2=$!
disown 2>/dev/null
SPAWNED+=("$AGENT2")
sleep 0.2
printf 'pid %s claude\n' "$AGENT2" >>"$PIDFILE2"

# Stand-in for the BEAM, with a command the watchdog can match by pattern (the
# real watchdog polls the release-BEAM command pattern, not a captured pid).
bash -c 'exec -a aiur-fake-beam.smp sleep 600' & FAKE_BEAM=$!
disown 2>/dev/null
SPAWNED+=("$FAKE_BEAM")

WD="$(start_beam_death_watchdog "aiur-fake-beam.smp" "$SOCKET" "$PIDFILE2" 0.2)"
SPAWNED+=("$WD")

# Before the BEAM dies the watchdog must touch nothing.
sleep 0.5
server_dead && fail "watchdog reaped while the BEAM was still alive"
gone "$AGENT2" && fail "watchdog killed an agent while the BEAM was still alive"

kill "$FAKE_BEAM" 2>/dev/null # simulate the crash

wait_gone "$AGENT2" || fail "agent survived BEAM death (watchdog did not reap)"
for p in "${PANE_PIDS2[@]}"; do wait_gone "$p" || fail "pane agent $p survived BEAM death"; done
n=50
while [ "$n" -gt 0 ]; do server_dead && break; sleep 0.1; n=$((n - 1)); done
server_dead || fail "aiur tmux server survived BEAM death"
echo "  ok: watchdog reaped panes + headless agent and collapsed the server"

echo "=== Test 3: background BEAM-death leaves a durable crash record (#488) ==="

STATE_DIR="/tmp/aiur-reaptest.$$.state"
mkdir -p "$STATE_DIR"
RUN_LOG_DIR="/tmp/aiur-reaptest.$$.runlog"
mkdir -p "$RUN_LOG_DIR/log"
printf 'boot line one\nboot line two\n' >"$RUN_LOG_DIR/log/boot.out.log"
MARKER="$STATE_DIR/node.last-crash"
SENTINEL="$STATE_DIR/node.stopping"

PIDFILE3="/tmp/aiur-reaptest.$$.3"
: >"$PIDFILE3"
bash -c 'sleep 600 & exec -a aiur-fake-claude sleep 600' & AGENT3=$!
disown 2>/dev/null
SPAWNED+=("$AGENT3")
sleep 0.2
printf 'pid %s claude\n' "$AGENT3" >>"$PIDFILE3"

# Crash path: no stop sentinel → the watchdog must record the crash AND reap.
bash -c 'exec -a aiur-fake-beam3.smp sleep 600' & FAKE_BEAM3=$!
disown 2>/dev/null
SPAWNED+=("$FAKE_BEAM3")
WD3="$(start_beam_death_watchdog "aiur-fake-beam3.smp" "" "$PIDFILE3" 0.2 0 \
  "fake-node@127.0.0.1" "$RUN_LOG_DIR" "$SENTINEL" "$MARKER")"
SPAWNED+=("$WD3")

# Let the watchdog latch onto the live BEAM before we kill it.
sleep 0.5
kill "$FAKE_BEAM3" 2>/dev/null # simulate the unexpected crash
wait_gone "$AGENT3" || fail "agent survived crash (watchdog did not reap)"
n=50
while [ "$n" -gt 0 ]; do [ -f "$MARKER" ] && break; sleep 0.1; n=$((n - 1)); done
[ -f "$MARKER" ] || fail "crash marker was not written on unexpected exit"
grep -q "exited unexpectedly" "$MARKER" || fail "crash marker missing headline"
grep -q "node: fake-node@127.0.0.1" "$MARKER" || fail "crash marker missing node identity"
grep -q "run_log_dir: $RUN_LOG_DIR" "$MARKER" || fail "crash marker missing run log dir"
grep -q "boot line two" "$MARKER" || fail "crash marker missing boot.out.log tail"
[ -f "$RUN_LOG_DIR/log/aiur.crash" ] || fail "crash record not written next to aiur.log"
echo "  ok: crash record written to marker + run log dir, agent reaped"

echo "=== Test 4: a clean stop writes NO crash record (#488) ==="

rm -f "$MARKER"
PIDFILE4="/tmp/aiur-reaptest.$$.4"
: >"$PIDFILE4"
bash -c 'sleep 600 & exec -a aiur-fake-claude sleep 600' & AGENT4=$!
disown 2>/dev/null
SPAWNED+=("$AGENT4")
sleep 0.2
printf 'pid %s claude\n' "$AGENT4" >>"$PIDFILE4"

bash -c 'exec -a aiur-fake-beam4.smp sleep 600' & FAKE_BEAM4=$!
disown 2>/dev/null
SPAWNED+=("$FAKE_BEAM4")
WD4="$(start_beam_death_watchdog "aiur-fake-beam4.smp" "" "$PIDFILE4" 0.2 0 \
  "fake-node@127.0.0.1" "$RUN_LOG_DIR" "$SENTINEL" "$MARKER")"
SPAWNED+=("$WD4")

sleep 0.5
# Intentional stop: drop the sentinel first, then kill the BEAM.
: >"$SENTINEL"
kill "$FAKE_BEAM4" 2>/dev/null
wait_gone "$AGENT4" || fail "agent survived clean stop (watchdog did not reap)"
# Give the watchdog room to (not) write a marker and to consume the sentinel.
sleep 0.6
[ -f "$MARKER" ] && fail "crash marker written on a clean stop (false positive)"
[ -f "$SENTINEL" ] && fail "stop sentinel was not consumed by the watchdog"
echo "  ok: clean stop reaped agent, consumed sentinel, recorded no crash"

echo ""
echo "PASS"
exit 0
