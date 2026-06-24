#!/usr/bin/env bash
#
# Gather a recent tail of every ACTIVE aiur agent's log, for status
# summarization by the agent-status skill.
#
# The first block is always a daemon-health line the skill turns into a
# status row, followed by one block per active agent:
#
#   ===== DAEMON node <up|down> | last activity <N>m ago | roots <...> =====
#   [warning: ... mismatch ...]
#
#   ===== AGENT <id> | last activity <N>m ago | session <yes|no> | root <dir> =====
#   <last $TAIL_LINES lines of logs/agent.md>
#
# "Active" = a workspace whose logs/agent.md was modified within the recency
# window. Tune with env vars:
#   AIUR_ACTIVE_WINDOW_MIN  (default 15)  — how recent counts as active
#   AIUR_TAIL_LINES         (default 45)  — log lines per agent
#   AIUR_INCLUDE_STALE=1                  — include stale agents too (status-only)
#
# Why multiple roots (#489): the configured `.aiur/config` workspace.root is
# the SOURCE repo's default and frequently does NOT match where the live aiur
# instance actually writes. A `--bg` run mints workspaces under
# `~/.aiur/workspaces/<namespace>/<repo>/<id>/logs/agent.md` and session logs
# under `~/.aiur/logs/<session>/log/`. Scanning only the config root produces a
# false "no active agents" while a run is in flight. So we scan the config root
# AND the canonical `~/.aiur/workspaces` tree, dedupe, and warn on mismatch.
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

# mtime in epoch seconds, portable across GNU (stat -c) and macOS (stat -f).
# GNU first: on GNU coreutils `-f` means --file-system (NOT a format string),
# so a macOS-first probe silently succeeds with filesystem garbage on Linux.
mtime_epoch() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

now="$(date +%s)"

# --- Resolve candidate workspace roots ------------------------------------
# config_root is the static default from `.aiur/config`; it may be empty or
# stale. The home root (`~/.aiur/workspaces`) is where a live instance actually
# materializes per-issue workspaces, so it's always scanned.
config_root=""
if [ -f "$config" ]; then
  config_root="$(awk '
    /^[^[:space:]#]/ { in_ws = ($1 == "workspace:") }
    in_ws && $1 == "root:" { print $2; exit }
  ' "$config")"
  config_root="${config_root/#\~/$HOME}"
fi

home_root="$HOME/.aiur/workspaces"

# Deduped, existing roots to scan. Keep config_root first so it wins labeling.
roots=()
add_root() {
  local r="$1"
  [ -n "$r" ] || return 0
  [ -d "$r" ] || return 0
  local existing
  for existing in "${roots[@]:-}"; do
    [ "$existing" = "$r" ] && return 0
  done
  roots+=("$r")
}
add_root "$config_root"
add_root "$home_root"

# --- Daemon health probe ---------------------------------------------------
# A live aiur runs the BEAM from a `rel/aiur` release; tmux sessions (one per
# agent) are a secondary signal. If neither is present but recent logs exist,
# the node is DOWN and we must say so loudly rather than report nothing.
node_up=no
if pgrep -f 'rel/aiur/.*beam' >/dev/null 2>&1; then
  node_up=yes
fi
sessions="$(tmux ls 2>/dev/null | cut -d: -f1 || true)"

# Track the most recent activity across everything we can see, so a downed
# node still yields a "last activity X ago" rather than silence.
latest_mtime=0
note_mtime() {
  local m="$1"
  [ -n "$m" ] || return 0
  # Guard the comparison's exit code: a "not greater" result returns 1, which
  # under `set -e` would abort the whole run mid-scan. Always return 0.
  if [ "$m" -gt "$latest_mtime" ]; then latest_mtime="$m"; fi
  return 0
}

# Session logs under ~/.aiur/logs/<session>/log/aiur.log also mark liveness
# even before any per-agent workspace log appears.
if [ -d "$HOME/.aiur/logs" ]; then
  while IFS= read -r slog; do
    [ -f "$slog" ] || continue
    note_mtime "$(mtime_epoch "$slog")"
  done < <(find "$HOME/.aiur/logs" -maxdepth 3 -type f -name 'aiur.log' 2>/dev/null)
fi

# --- Collect active agents across all roots --------------------------------
# Emit AGENT blocks into a buffer first so the DAEMON header (which needs the
# aggregate "last activity" and mismatch verdict) can be printed before them.
agent_blocks=""
found=0
seen_logs=""        # |-delimited absolute paths, for cross-root dedupe
roots_with_agents=""

for root in "${roots[@]:-}"; do
  [ -n "$root" ] || continue
  while IFS= read -r log; do
    [ -f "$log" ] || continue
    abs="$(cd "$(dirname "$log")" 2>/dev/null && pwd)/$(basename "$log")"
    case "$seen_logs" in
      *"|${abs}|"*) continue ;;
    esac
    seen_logs="${seen_logs}|${abs}|"

    ws="$(dirname "$(dirname "$log")")"
    id="$(basename "$ws")"

    m="$(mtime_epoch "$log")"; m="${m:-0}"
    note_mtime "$m"
    age_min=$(( (now - m) / 60 ))
    if [ "$include_stale" != "1" ] && [ "$age_min" -gt "$window_min" ]; then
      continue
    fi

    has_session=no
    printf '%s\n' "$sessions" | grep -qx -- "$id" && has_session=yes

    found=$((found + 1))
    case "$roots_with_agents" in
      *"|${root}|"*) : ;;
      *) roots_with_agents="${roots_with_agents}|${root}|" ;;
    esac

    agent_blocks="${agent_blocks}===== AGENT ${id} | last activity ${age_min}m ago | session ${has_session} | root ${root} =====
$(tail -n "$tail_lines" "$log")

"
    # maxdepth 6 spans both layouts: legacy flat <root>/<id>/logs/agent.md,
    # repo-namespaced <root>/<repo>/<id>/logs/agent.md (#406), and the
    # owner-namespaced <root>/<owner>/<repo>/<id>/logs/agent.md the live
    # ~/.aiur/workspaces tree uses (#489).
  done < <(find "$root" -maxdepth 6 -type f -name agent.md 2>/dev/null)
done

# --- Mismatch warning ------------------------------------------------------
# Active agents found under a root other than the configured workspace.root
# means the operator's static config is lying about where the run lives.
warning=""
if [ -n "$config_root" ] && [ -n "$roots_with_agents" ]; then
  case "$roots_with_agents" in
    *"|${config_root}|"*) : ;;
    *)
      active_roots="$(printf '%s' "${roots_with_agents}" | tr '|' ' ' | tr -s ' ' | sed 's/^ //;s/ $//')"
      warning="warning: active agents are under ${active_roots} but .aiur/config workspace.root is ${config_root} (mismatch — config root is stale/unused)"
      ;;
  esac
fi

# --- Emit -------------------------------------------------------------------
roots_list=""
[ "${#roots[@]}" -gt 0 ] && roots_list="$(printf '%s ' "${roots[@]}")"
[ -n "$roots_list" ] || roots_list="(none existed) "

if [ "$latest_mtime" -gt 0 ]; then
  last_age=$(( (now - latest_mtime) / 60 ))
  last_activity="${last_age}m ago"
else
  last_activity="never (no logs seen)"
fi

echo "===== DAEMON node ${node_up} | last activity ${last_activity} | roots ${roots_list}====="
[ -n "$warning" ] && echo "$warning"
# A downed node with recent activity is the headline failure mode the skill
# must render red — make it explicit rather than relying on inference.
if [ "$node_up" = "no" ] && [ "$latest_mtime" -gt 0 ]; then
  echo "daemon down: no aiur BEAM process; last activity ${last_activity}"
fi
echo

if [ "$found" -gt 0 ]; then
  printf '%s' "$agent_blocks"
else
  if [ "${#roots[@]}" -eq 0 ]; then
    echo "(no workspace roots exist yet — looked for config workspace.root and ${home_root})"
  else
    echo "(no active agents — nothing modified in the last ${window_min}m under ${roots_list})"
  fi
fi
