#!/bin/bash
# End-to-end manual regression for Bug A: Ctrl+C leaves stale BEAM node.
#
# Drives scripts/aiur via tmux + a PTY emulator, sends Ctrl+C, asserts
# the aiur BEAM is gone within 10 s. Run manually after touching
# scripts/aiur's __aiur_cleanup or anything that affects BEAM lifecycle.
#
# Usage:
#   bash src/test/regression/aiur-shutdown.sh
#
# Exits 0 on success, 1 on failure. Cleans up tmux + processes on exit.

set -u

SOCKET_DRIVER="claude-aiur-shutdown-test"
SOCKET_AIUR="aiur-orangekid"
SESSION_DRIVER="drv"
WRAPPER="/tmp/aiur-shutdown-wrapper.sh"

cleanup() {
  tmux -L "$SOCKET_DRIVER" kill-server >/dev/null 2>&1 || true
  tmux -L "$SOCKET_AIUR" kill-server >/dev/null 2>&1 || true
  pkill -f "_build/.*rel/aiur/erts.*beam.smp" >/dev/null 2>&1 || true
  pkill -f "opencode" >/dev/null 2>&1 || true
  rm -f "$WRAPPER"
}
trap cleanup EXIT

cleanup
sleep 2

cat > "$WRAPPER" <<'EOF'
#!/bin/bash
unset TMUX TMUX_PANE
set -a
source /home/orangekid/github/aiur/.env
set +a
cd /home/orangekid/github/aiur
exec script -qc "/home/orangekid/github/aiur/scripts/aiur" /dev/null
EOF
chmod +x "$WRAPPER"

echo "=== Boot aiur in a PTY-backed tmux ==="
tmux -L "$SOCKET_DRIVER" new-session -d -s "$SESSION_DRIVER" -x 220 -y 60 "$WRAPPER"

# Wait for BEAM to bind port 4000.
beam_up=0
for i in $(seq 1 30); do
  if pgrep -f "_build/.*rel/aiur/erts.*beam.smp" >/dev/null && \
     lsof -i :4000 2>/dev/null | grep -q LISTEN; then
    echo "  BEAM up + port 4000 listening at t=${i}s"
    beam_up=1
    break
  fi
  sleep 1
done

if [ $beam_up -eq 0 ]; then
  echo "FAIL: BEAM never came up"
  exit 1
fi

echo ""
echo "=== Send Ctrl+C via tmux ==="
tmux -L "$SOCKET_DRIVER" send-keys -t "$SESSION_DRIVER" "C-c"

# Wait up to 15 s for BEAM to exit AND port 4000 to free up.
echo "Waiting for graceful shutdown..."
for i in $(seq 1 30); do
  beams=$(pgrep -f "_build/.*rel/aiur/erts.*beam.smp" 2>/dev/null || true)
  port=$(lsof -i :4000 2>/dev/null | grep LISTEN || true)
  if [ -z "$beams" ] && [ -z "$port" ]; then
    echo "  clean exit at t=${i}s after Ctrl+C"
    echo ""
    echo "PASS"
    exit 0
  fi
  sleep 0.5
done

echo ""
echo "FAIL: BEAM survived Ctrl+C"
echo "Stragglers:"
pgrep -af "_build/.*rel/aiur/erts.*beam.smp"
lsof -i :4000 2>&1 | head -3
exit 1
