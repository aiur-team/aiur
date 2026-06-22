#!/usr/bin/env bash
#
# Gather a recent tail of every ACTIVE aiur agent's log, for status
# summarization by the agent-status skill. Prints one block per active agent:
#
#   ===== AGENT <id> | last activity <N>m ago | session <yes|no> =====
#   <last $TAIL_LINES lines of logs/agent.md>
#
# "Active" = a workspace whose logs/agent.md was modified within the recency
# window. Tune with env vars:
#   AIUR_ACTIVE_WINDOW_MIN  (default 15)  — how recent counts as active
#   AIUR_TAIL_LINES         (default 45)  — log lines per agent
#   AIUR_INCLUDE_STALE=1                  — include stale agents too (status-only)
#
# Usage: tail-agents.sh [path/to/config]
#   Defaults to ./.aiur/config (current layout), falling back to ./.aiurconfig (legacy).
set -euo pipefail

config="${1:-}"
if [ -z "$config" ]; then
  if [ -f .aiur/config ]; then config=".aiur/config"
  elif [ -f .aiurconfig ]; then config=".aiurconfig"
  else config=".aiur/config"; fi
fi
window_min="${AIUR_ACTIVE_WINDOW_MIN:-15}"
tail_lines="${AIUR_TAIL_LINES:-45}"
include_stale="${AIUR_INCLUDE_STALE:-0}"

[ -f "$config" ] || { echo "no aiur config found (looked for .aiur/config and .aiurconfig): $config" >&2; exit 1; }

# Resolve workspace.root from the YAML (top-level `workspace:` -> `root:`).
root="$(awk '
  /^[^[:space:]#]/ { in_ws = ($1 == "workspace:") }
  in_ws && $1 == "root:" { print $2; exit }
' "$config")"
[ -n "$root" ] || { echo "workspace.root not found in $config" >&2; exit 1; }
root="${root/#\~/$HOME}"
[ -d "$root" ] || { echo "workspace root does not exist yet: $root" >&2; exit 0; }

# mtime in epoch seconds, portable across macOS (stat -f) and GNU (stat -c).
mtime_epoch() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# Live tmux sessions (the orchestrator opens one per agent); used as an extra
# "is it running" signal beyond log recency.
sessions="$(tmux ls 2>/dev/null | cut -d: -f1 || true)"

now="$(date +%s)"
found=0
for ws in "$root"/*/; do
  log="$ws/logs/agent.md"
  [ -f "$log" ] || continue
  id="$(basename "$ws")"

  m="$(mtime_epoch "$log")"; m="${m:-0}"
  age_min=$(( (now - m) / 60 ))
  if [ "$include_stale" != "1" ] && [ "$age_min" -gt "$window_min" ]; then
    continue
  fi

  has_session=no
  printf '%s\n' "$sessions" | grep -qx -- "$id" && has_session=yes

  found=$((found + 1))
  echo "===== AGENT ${id} | last activity ${age_min}m ago | session ${has_session} ====="
  tail -n "$tail_lines" "$log"
  echo
done

[ "$found" -gt 0 ] || echo "(no active agents — nothing modified in the last ${window_min}m under ${root})"
