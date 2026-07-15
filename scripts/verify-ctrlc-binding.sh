#!/usr/bin/env bash
# Regression harness for the Ctrl+C bridge binding in scripts/aiur.tmux.conf.
#
# The binding for a non-agent-list pane must route Ctrl+C through the
# `@aiur_ctrlc` helper (which talks to Aiur for the 3-state decision), NOT
# raw `kill-pane` the pane out from under a queued Executor message.
#
# A subtle escaping bug once made the binding reference the helper via a
# `h=...; $h` shell variable. tmux re-parses the double-quoted run-shell
# argument when if-shell dispatches it and expands `$h` to empty, so the
# `[ -x "$h" ]` guard always failed and Ctrl+C silently fell through to the
# `else` branch's raw kill-pane. That bypassed the helper, the control
# endpoint, and the 3-state logic entirely — closing the pane on the first
# press and dropping the queued message.
#
# This harness loads the REAL conf into a throwaway tmux server, fires a real
# Ctrl+C through an attached client (send-keys to the pane process bypasses
# bindings, so we drive a wrapper client), and asserts the helper ran and the
# pane survived. Exits 0 on pass, 1 on fail, 0-with-skip when tmux is absent.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="$REPO_ROOT/scripts/aiur.tmux.conf"

INNER="aiur-ctrlc-test-inner"
WRAP="aiur-ctrlc-test-wrap"
WORK="$(mktemp -d)"
STUB="$WORK/stub-helper.sh"
MARKER="$WORK/helper-ran.log"

color_ok='\033[0;32m'; color_fail='\033[0;31m'; color_dim='\033[2m'; color_reset='\033[0m'
ok()   { printf "${color_ok}PASS${color_reset} %s\n" "$1"; }
fail() { printf "${color_fail}FAIL${color_reset} %s\n" "$1"; failures=$((failures + 1)); }
note() { printf "${color_dim}note${color_reset} %s\n" "$1"; }
failures=0

cleanup() {
  tmux -L "$INNER" kill-server 2>/dev/null || true
  tmux -L "$WRAP" kill-server 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

if ! command -v tmux >/dev/null 2>&1; then
  note "tmux not available; skipping Ctrl+C binding regression check"
  exit 0
fi

cat > "$STUB" <<EOF
#!/usr/bin/env sh
echo "ran pane=\$1 url=\$2" >> "$MARKER"
exit 0
EOF
chmod +x "$STUB"
: > "$MARKER"

# Inner server: the real conf binding, with the helper pointed at our stub.
tmux -L "$INNER" kill-server 2>/dev/null || true
tmux -L "$INNER" new-session -d -s s -x 120 -y 30 "sleep 600"
tmux -L "$INNER" source-file "$CONF"
tmux -L "$INNER" set -g @aiur_ctrlc "$STUB"
tmux -L "$INNER" set -g @aiur_control_url "http://127.0.0.1:4000"
# A second pane so the active pane is NOT the agent-list (index 0) pane.
tmux -L "$INNER" split-window -h -t s "sleep 600"

# Wrapper client: attach drives real keystrokes so the root C-c binding fires
# (send-keys straight to a pane bypasses bindings).
tmux -L "$WRAP" kill-server 2>/dev/null || true
tmux -L "$WRAP" new-session -d -s w -x 130 -y 35 "tmux -L $INNER attach -t s"
sleep 1

panes_before="$(tmux -L "$INNER" list-panes -t s 2>/dev/null | wc -l | tr -d ' ')"
tmux -L "$WRAP" send-keys -t w C-c
sleep 1.5
panes_after="$(tmux -L "$INNER" list-panes -t s 2>/dev/null | wc -l | tr -d ' ')"

if [ -s "$MARKER" ]; then
  ok "Ctrl+C on a non-agent-list pane invoked the bridge helper ($(cat "$MARKER"))"
else
  fail "Ctrl+C did not invoke the bridge helper — fell through to raw kill-pane"
fi

if [ "$panes_before" = "2" ] && [ "$panes_after" = "2" ]; then
  ok "pane survived Ctrl+C (helper owns the close decision, not the binding)"
else
  fail "pane count changed ${panes_before}->${panes_after} — binding raw-killed the pane"
fi

if [ "$failures" -eq 0 ]; then
  echo "=== Ctrl+C binding regression: OK ==="
  exit 0
fi
echo "=== Ctrl+C binding regression: FAILED ($failures) ==="
exit 1
