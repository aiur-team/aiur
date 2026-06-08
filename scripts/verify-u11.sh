#!/usr/bin/env bash
# Manual CLI verification harness for the 6 acceptance examples in
# src/docs/brainstorms/2026-05-21-aiur-pane-lifecycle-and-background-attach-requirements.md.
#
# Drives scripts/aiurdev end-to-end inside an outer tmux session, captures
# phase-log evidence, and reports pass/fail per AE.
#
# Exits 0 if every AE passes, 1 otherwise. Each AE has its own check
# block; logs go to $VERIFY_LOG_ROOT/log/aiur.log so the harness can grep
# for phase=<state> elapsed_ms=<N> markers.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTER_SOCKET="${OUTER_SOCKET:-aiur-u11-outer}"
OUTER_SESSION="u11"
BOOT_TIMEOUT_S=60
# scripts/aiurdev sets --logs-root only when the profile config supplies one.
# For ad-hoc workflows the BEAM defaults to `<elixir_dir>/log/aiur.log`.
LOG_FILE="$REPO_ROOT/src/log/aiur.log"

color_ok='\033[0;32m'
color_fail='\033[0;31m'
color_dim='\033[2m'
color_reset='\033[0m'

ok()    { printf "${color_ok}PASS${color_reset} %s\n" "$1"; }
fail()  { printf "${color_fail}FAIL${color_reset} %s\n" "$1"; failures=$((failures + 1)); }
note()  { printf "${color_dim}note${color_reset} %s\n" "$1"; }

failures=0

# ---- pre-clean ----------------------------------------------------------

echo "=== U11 verification harness ==="
echo "Pre-cleaning state..."

# Kill any outer tmux session from a prior run
tmux -L "$OUTER_SOCKET" kill-server 2>/dev/null || true

# Delete every pre-existing Aiur-owned opencode session
mapfile -t pre_sessions < <(mise exec -- opencode session list 2>/dev/null \
  | awk 'NR>2 {print $1}' \
  | grep '^ses_' || true)

if [ "${#pre_sessions[@]}" -gt 0 ]; then
  note "pre-cleaning ${#pre_sessions[@]} stale sessions"
  for id in "${pre_sessions[@]}"; do
    mise exec -- opencode session delete "$id" >/dev/null 2>&1 || true
  done
fi

mkdir -p "$(dirname "$LOG_FILE")"
: > "$LOG_FILE"

# ---- boot aiur ----------------------------------------------------------

echo "Booting aiur in outer tmux..."

tmux -L "$OUTER_SOCKET" new-session -d -s "$OUTER_SESSION" -x 220 -y 60
# scripts/aiurdev refuses to launch if $TMUX is set (warns "already inside a tmux session").
# The pane we just created inherits $TMUX from the outer tmux server, so unset it for
# this invocation specifically. The inner scripts/aiurdev then creates its own isolated
# tmux server on its own socket.
tmux -L "$OUTER_SOCKET" send-keys -t "$OUTER_SESSION" \
  "cd $REPO_ROOT && unset TMUX TMUX_PANE && scripts/aiurdev '$REPO_ROOT/src/.aiurconfig'" \
  Enter

# Wait for the BEAM to write phase=ready for warm_server + hidden_window + agent_list.
echo "Waiting up to ${BOOT_TIMEOUT_S}s for boot phase logs..."
deadline=$(( $(date +%s) + BOOT_TIMEOUT_S ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if grep -qE "opencode_warm_server phase=ready" "$LOG_FILE" 2>/dev/null \
     && grep -qE "opencode_hidden_window phase=ready" "$LOG_FILE" 2>/dev/null \
     && grep -qE "aiur_agent_list phase=ready" "$LOG_FILE" 2>/dev/null; then
    break
  fi
  sleep 1
done

# ---- AE6: no leaks in phase logs ---------------------------------------

if ! grep -qE "Aiur _warm|Aiur _placeholder" "$LOG_FILE" 2>/dev/null; then
  ok "AE6: no 'Aiur _warm' or 'Aiur _placeholder' strings in BEAM log"
else
  fail "AE6: leaked placeholder marker in log:"
  grep -E "Aiur _warm|Aiur _placeholder" "$LOG_FILE" 2>/dev/null | head -3
fi

# ---- boot timing -------------------------------------------------------

if grep -qE "opencode_warm_server phase=ready" "$LOG_FILE"; then
  warm_ms=$(grep -oE "opencode_warm_server phase=ready elapsed_ms=[0-9]+" "$LOG_FILE" \
    | head -1 | grep -oE "[0-9]+" | head -1)
  ok "warm server ready @ ${warm_ms}ms"
else
  fail "warm_server never became ready"
fi

if grep -qE "opencode_hidden_window phase=ready" "$LOG_FILE"; then
  hidden_ms=$(grep -oE "opencode_hidden_window phase=ready elapsed_ms=[0-9]+" "$LOG_FILE" \
    | head -1 | grep -oE "[0-9]+" | head -1)
  ok "hidden window ready @ ${hidden_ms}ms"
else
  fail "hidden_window never became ready"
fi

if grep -qE "aiur_agent_list phase=ready" "$LOG_FILE"; then
  list_ms=$(grep -oE "aiur_agent_list phase=ready elapsed_ms=[0-9]+" "$LOG_FILE" \
    | head -1 | grep -oE "[0-9]+" | head -1)
  ok "agent list ready @ ${list_ms}ms"
else
  fail "agent_list never became ready"
fi

# ---- AE4: AttachQueue is running ---------------------------------------

if grep -qE "opencode_attach_queue phase=warm_ready" "$LOG_FILE"; then
  ok "AE4: AttachQueue subscribed to warm_server_ready"
else
  fail "AE4: AttachQueue never saw warm_server_ready"
fi

# ---- AE5: Ctrl+C cleanup ----------------------------------------------

echo "Sending Ctrl+C to aiur..."
tmux -L "$OUTER_SOCKET" send-keys -t "$OUTER_SESSION" "" C-c
sleep 5
tmux -L "$OUTER_SOCKET" send-keys -t "$OUTER_SESSION" "" C-c
sleep 8

# Verify cleanup
post_sessions=$(mise exec -- opencode session list 2>/dev/null \
  | awk 'NR>2 {print $1}' \
  | grep -c '^ses_' || true)

if [ "$post_sessions" -eq 0 ]; then
  ok "AE5: opencode session list empty after Ctrl+C (sessions reaped)"
else
  fail "AE5: ${post_sessions} sessions remained after Ctrl+C"
  mise exec -- opencode session list 2>/dev/null | head -10
fi

# ---- cleanup -----------------------------------------------------------

if [ "${KEEP_TMUX:-0}" -ne 1 ]; then
  tmux -L "$OUTER_SOCKET" kill-server 2>/dev/null || true
else
  echo "Leaving outer tmux running: tmux -L $OUTER_SOCKET attach -t $OUTER_SESSION"
fi

# ---- summary -----------------------------------------------------------

echo ""
echo "=== U11 summary ==="
if [ "$failures" -eq 0 ]; then
  echo -e "${color_ok}ALL AE PASSED${color_reset}"
  exit 0
else
  echo -e "${color_fail}${failures} CHECK(S) FAILED${color_reset}"
  echo "Full log: $LOG_FILE"
  exit 1
fi
