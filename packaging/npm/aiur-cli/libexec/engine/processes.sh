# Pid helpers, BEAM kills and the stale manual-smoke inventory and reaping. Sourced by aiur-engine.sh.

# TERM-then-KILL every BEAM whose command line matches $1. Reaps a stale node by
# name (covers orphans from any release dir): under the unified identity a dev
# `_build` BEAM and an installed BEAM both claim the same node name, so a
# release-path pgrep misses whichever one this run didn't launch.
# TERM the node(s) matching $pattern, give them $grace_ticks (0.1s) to exit
# gracefully, then SIGKILL whatever remains. The default grace is short (3s)
# because startup reclaim wants to clear a stale BEAM quickly; the stop paths
# pass a longer grace so the BEAM can finish its own agent reap + session
# deletion instead of being SIGKILLed mid-cleanup (which is what orphaned agent
# processes on `aiur stop`). Callers may override the grace internally; invalid
# or excessive values fall back to the 3s startup-reclaim default instead of
# skipping the wait and jumping straight to SIGKILL.
kill_beams_matching() {
  local pattern="$1" grace_ticks="${2:-30}" pids pid waited=0
  case "$grace_ticks" in
    "" | *[!0-9]*) grace_ticks=30 ;;
    *)
      # Reject overlong digit strings before numeric comparison so shell integer
      # overflow cannot turn an excessive grace into an immediate SIGKILL.
      if [ "${#grace_ticks}" -gt 5 ] ||
        { [ "${#grace_ticks}" -eq 5 ] && [ "$grace_ticks" -gt 36000 ]; }; then
        grace_ticks=30
      fi
      ;;
  esac
  pids="$(pgrep -f -- "$pattern" 2>/dev/null || true)"
  [ -n "$pids" ] || return 0
  for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done
  while [ "$waited" -lt "$grace_ticks" ]; do
    pids="$(pgrep -f -- "$pattern" 2>/dev/null || true)"
    [ -z "$pids" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  pids="$(pgrep -f -- "$pattern" 2>/dev/null || true)"
  for pid in $pids; do kill -KILL "$pid" 2>/dev/null || true; done
}

pid_owner() {
  ps -p "$1" -o user= 2>/dev/null | awk '{print $1}' || true
}

pid_command() {
  ps -p "$1" -o command= 2>/dev/null || true
}

pid_ppid() {
  ps -p "$1" -o ppid= 2>/dev/null | awk '{print $1}' || true
}

pid_cwd() {
  local pid="$1" cwd
  if [ -e "/proc/$pid/cwd" ]; then
    readlink "/proc/$pid/cwd" 2>/dev/null || true
    return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1 || true)"
    [ -n "$cwd" ] && printf '%s\n' "$cwd"
  fi
}

kill_pid_with_escalation() {
  local pid="$1" waited=0
  [ -n "$pid" ] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$waited" -lt 20 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  kill -KILL "$pid" 2>/dev/null || true
}

aiur_node_from_command() {
  local cmd="$1" node
  node="$(printf '%s\n' "$cmd" | sed -n "s/.*--name[[:space:]]\\(aiur-${USER}[-A-Za-z0-9_]*@127\\.0\\.0\\.1\\).*/\\1/p" | head -n 1)"
  [ -n "$node" ] && printf '%s\n' "$node"
}

aiur_release_root_from_command() {
  local cmd="$1"
  if [[ "$cmd" =~ --boot-var[[:space:]]+RELEASE_LIB[[:space:]]+([^[:space:]]+)/lib ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$cmd" =~ ([^[:space:]]*/src/_build/dev/rel/aiur)/releases/ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$cmd" =~ ([^[:space:]]*/release)/releases/ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

workspace_root_from_aiur_release_root() {
  local release_root="${1%/}"
  case "$release_root" in
    */src/_build/dev/rel/aiur)
      printf '%s\n' "${release_root%/src/_build/dev/rel/aiur}"
      ;;
    *)
      printf '%s\n' "$release_root"
      ;;
  esac
}

aiur_node_tmux_session_alive() {
  local node="$1" short tmux_bin
  short="${node%@*}"
  tmux_bin="$(command -v tmux || true)"
  [ -n "$tmux_bin" ] || return 1
  "$tmux_bin" -L "$short" has-session -t "${short}-default" 2>/dev/null
}

stale_manual_smoke_beam_inventory() {
  local pid cmd node release_root workspace_root owner
  aiur_resolve_identity

  for pid in $(pgrep -f -- "beam\\.smp.*--name aiur-${USER}.*@127\\.0\\.0\\.1" 2>/dev/null || true); do
    [ -n "$pid" ] || continue
    owner="$(pid_owner "$pid")"
    [ "$owner" = "$USER" ] || continue

    cmd="$(pid_command "$pid")"
    node="$(aiur_node_from_command "$cmd")"
    [ -n "$node" ] || continue

    release_root="$(aiur_release_root_from_command "$cmd" || true)"
    [ -n "$release_root" ] || continue
    workspace_root="$(workspace_root_from_aiur_release_root "$release_root")"

    # Scope this broad cleanup to stale issue/manual-smoke workspaces. The
    # current instance cleanup path handles the active daemon's own node.
    case "$workspace_root" in
      */aiur-workspaces/*) ;;
      *) continue ;;
    esac

    # A matching live aiur tmux session means this node may still be in use.
    aiur_node_tmux_session_alive "$node" && continue

    printf '%s\t%s\t%s\t%s\n' "$pid" "$node" "$workspace_root" "$release_root"
  done
}

manual_smoke_wrapper_tmux_sockets() {
  local tmux_bin sockdir path name panes current pane_path start manual_context all_sleep
  tmux_bin="$(command -v tmux || true)"
  [ -n "$tmux_bin" ] || return 0
  sockdir="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
  [ -d "$sockdir" ] || return 0

  for path in "$sockdir"/*; do
    [ -S "$path" ] || continue
    name="${path##*/}"
    case "$name" in
      codex-driver-* | codex-aiur* | codex-[0-9]* | claude-driver*) ;;
      *) continue ;;
    esac
    panes="$("$tmux_bin" -L "$name" list-panes -a -F '#{pane_current_command}	#{pane_current_path}	#{pane_start_command}' 2>/dev/null || true)"
    [ -n "$panes" ] || continue
    manual_context=0
    all_sleep=1
    while IFS=$'\t' read -r current pane_path start; do
      case "$start" in
        *aiurdev\ --test* | *scripts/aiurdev\ --test*) manual_context=1 ;;
      esac
      [ "$current" = "sleep" ] || all_sleep=0
    done <<<"$panes"
    [ "$manual_context" -eq 1 ] && [ "$all_sleep" -eq 1 ] && printf '%s\n' "$name"
  done
}

orphaned_opencode_attach_inventory() {
  local pid owner ppid cmd cwd
  for pid in $(pgrep -f -- "opencode attach http://127\\.0\\.0\\.1:" 2>/dev/null || true); do
    owner="$(pid_owner "$pid")"
    [ "$owner" = "$USER" ] || continue
    ppid="$(pid_ppid "$pid")"
    [ "$ppid" = "1" ] || continue
    cwd="$(pid_cwd "$pid")"
    case "$cwd" in
      */aiur-workspaces/*) ;;
      *) continue ;;
    esac
    cmd="$(pid_command "$pid")"
    case "$cmd" in
      *"opencode attach http://127.0.0.1:"*) printf '%s\t%s\t%s\n' "$pid" "$cwd" "$cmd" ;;
    esac
  done
}

report_stale_manual_smoke() {
  local found=0 pid node workspace_root release_root socket cwd cmd

  while IFS=$'\t' read -r pid node workspace_root release_root; do
    [ -n "$pid" ] || continue
    if [ "$found" -eq 0 ]; then
      echo "aiur: stale manual-smoke leftovers detected:" >&2
      found=1
    fi
    echo "  BEAM pid=${pid} node=${node} workspace=${workspace_root} release=${release_root}" >&2
  done < <(stale_manual_smoke_beam_inventory)

  while IFS= read -r socket; do
    [ -n "$socket" ] || continue
    if [ "$found" -eq 0 ]; then
      echo "aiur: stale manual-smoke leftovers detected:" >&2
      found=1
    fi
    echo "  wrapper tmux socket=${socket}" >&2
  done < <(manual_smoke_wrapper_tmux_sockets)

  while IFS=$'\t' read -r pid cwd cmd; do
    [ -n "$pid" ] || continue
    if [ "$found" -eq 0 ]; then
      echo "aiur: stale manual-smoke leftovers detected:" >&2
      found=1
    fi
    echo "  orphan opencode attach pid=${pid} workspace=${cwd}" >&2
  done < <(orphaned_opencode_attach_inventory)

  if [ "$found" -eq 1 ]; then
    echo "aiur: run 'aiur cleanup-stale' to TERM/KILL only these same-user Aiur leftovers." >&2
  fi

  return "$found"
}

preflight_stale_manual_smoke() {
  report_stale_manual_smoke >/dev/null || true
}

reap_stale_manual_smoke() {
  local include_wrappers="${1:-0}"
  local pid node workspace_root release_root socket cwd cmd tmux_bin reaped=0

  while IFS=$'\t' read -r pid node workspace_root release_root; do
    [ -n "$pid" ] || continue
    echo "aiur: reaping stale BEAM pid=${pid} node=${node} workspace=${workspace_root}" >&2
    kill_pid_with_escalation "$pid"
    reaped=$((reaped + 1))
  done < <(stale_manual_smoke_beam_inventory)

  tmux_bin="$(command -v tmux || true)"
  if [ "$include_wrappers" = "1" ] && [ -n "$tmux_bin" ]; then
    while IFS= read -r socket; do
      [ -n "$socket" ] || continue
      echo "aiur: reaping stale wrapper tmux socket=${socket}" >&2
      "$tmux_bin" -L "$socket" kill-server 2>/dev/null || true
      reaped=$((reaped + 1))
    done < <(manual_smoke_wrapper_tmux_sockets)
  fi

  while IFS=$'\t' read -r pid cwd cmd; do
    [ -n "$pid" ] || continue
    echo "aiur: reaping orphan opencode attach pid=${pid}" >&2
    kill_pid_with_escalation "$pid"
    reaped=$((reaped + 1))
  done < <(orphaned_opencode_attach_inventory)

  if [ "$reaped" -eq 0 ]; then
    echo "aiur: no stale manual-smoke leftovers found" >&2
  fi
}
