# Agent tree and workspace-cwd reaping, plus the BEAM-death watchdog. Sourced by aiur-engine.sh.

# Echo $1 and every descendant pid, depth-first. Mac-safe (`pgrep -P`, no
# /proc), mirroring Aiur.RemoteControl.collect_descendants so the launcher reaps
# the same tree the BEAM-side reaper would. The recorded agent pid is a bash
# `-c` wrapper; the model process (claude --print / codex) is its child and
# reparents to init if only the wrapper is signalled — orphan-and-survive is
# exactly the bug — so the whole tree must be collected before any kill lands.
agent_pid_tree() {
  local root="$1" child
  printf '%s\n' "$root"
  for child in $(pgrep -P "$root" 2>/dev/null || true); do
    agent_pid_tree "$child"
  done
}

# pid-reuse guard: succeeds when pid $1 is alive AND its command still contains
# the comm substring $2 the BEAM recorded. An empty comm kills unconditionally.
# Mirrors the BEAM-side cmdline guard (Aiur.ProcessReaper) but Mac-safe via
# `ps -o command=`, so a recycled pid whose command no longer matches is spared.
agent_pid_matches() {
  local pid="$1" comm="$2" cmd
  kill -0 "$pid" 2>/dev/null || return 1
  [ -n "$comm" ] || return 0
  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$cmd" in *"$comm"*) return 0 ;; *) return 1 ;; esac
}

# Reap every aiur agent the BEAM can no longer reap itself.
#
#   $1 socket   aiur tmux socket (-L); kill-server nukes all panes (may be empty)
#   $2 pidfile  AIUR_AGENT_TMPFILE (BEAM-written agent refs; may be empty/missing)
#
# tmux runs on aiur's PRIVATE socket (-L aiur-$USER), so kill-server tears down
# every REPL/chat pane agent in one shot AND leaves no live aiur tmux server —
# never touching the Executor’s own default tmux. Headless agents (claude/codex
# app-servers spawned via Port) are bare OS processes that reparent to init on a
# BEAM crash; kill-server can't see them, so they're reaped from the pidfile by
# process tree, checking the recorded command. A recycled pid with a matching
# command is still possible (#2844). Idempotent.
reap_aiur_agents() {
  local socket="$1" pidfile="${2:-}"
  local tmux_bin
  tmux_bin="$(command -v tmux || true)"

  if [ -n "$tmux_bin" ] && [ -n "$socket" ]; then
    "$tmux_bin" -L "$socket" kill-server 2>/dev/null || true
  fi

  [ -n "$pidfile" ] && [ -r "$pidfile" ] || return 0

  # Snapshot the full process tree of every still-matching headless agent before
  # signalling, so descendants that reparent mid-reap are already on the list.
  local kind pid comm tree=() p
  while read -r kind pid comm; do
    [ "$kind" = "pid" ] && [ -n "$pid" ] || continue
    agent_pid_matches "$pid" "$comm" || continue
    while IFS= read -r p; do tree+=("$p"); done < <(agent_pid_tree "$pid")
  done <"$pidfile"

  [ "${#tree[@]}" -gt 0 ] || return 0

  for p in "${tree[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
  local waited=0
  while [ "$waited" -lt 20 ]; do
    local any=0
    for p in "${tree[@]}"; do kill -0 "$p" 2>/dev/null && { any=1; break; }; done
    [ "$any" -eq 0 ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  for p in "${tree[@]}"; do kill -KILL "$p" 2>/dev/null || true; done
}

canonical_workspace_root() {
  local root="$1"
  # The BEAM hands off Config.workspace_root() verbatim, which may be a `~/...`
  # path (e.g. this repo's `workspace.root: ~/code/aiur-workspaces`). `cd` does
  # not expand `~` inside a quoted variable, so without this a `~`-rooted cwd
  # sweep compared against the literal `~/...` string, matched no /proc cwd, and
  # silently reaped nothing — the exact backstop that must catch workspace-rooted
  # agents on stop. Expand a leading `~` before canonicalizing so the sweep and
  # the /proc cwd values (always absolute) agree.
  case "$root" in
    "~" | "~/"*) root="${HOME:-}${root#\~}" ;;
  esac
  if [ -d "$root" ]; then
    (cd "$root" 2>/dev/null && pwd -P) || printf '%s\n' "$root"
  else
    printf '%s\n' "$root"
  fi
}

workspace_root_is_shallow() {
  local root="${1%/}" trimmed
  trimmed="${root#/}"
  [ -n "$trimmed" ] || return 0
  case "$trimmed" in
    */*) return 1 ;;
    *) return 0 ;;
  esac
}

workspace_cwd_pids() {
  local root="${1%/}" proc_dir="${2:-/proc}" entry pid cwd
  [ -d "$proc_dir" ] || return 0

  for entry in "$proc_dir"/[0-9]*; do
    [ -d "$entry" ] || continue
    pid="${entry##*/}"
    cwd="$(readlink "$entry/cwd" 2>/dev/null || true)"
    [ -n "$cwd" ] || continue
    cwd="${cwd%/}"
    if [ "$cwd" != "$root" ] && [[ "$cwd/" == "$root/"* ]]; then
      printf '%s\n' "$pid"
    fi
  done
}

shell_protected_pid_list() {
  local p
  printf '%s\n' "$$"
  [ "${BASHPID:-$$}" = "$$" ] || printf '%s\n' "$BASHPID"
  [ -n "${PPID:-}" ] && printf '%s\n' "$PPID"
  for p in $(agent_pid_tree "$$" 2>/dev/null || true); do
    printf '%s\n' "$p"
  done
}

reap_workspace_cwd_agents() {
  local root="${1:-}"
  [ -n "$root" ] || return 0
  [ -d /proc ] || return 0

  root="$(canonical_workspace_root "$root")"
  if workspace_root_is_shallow "$root"; then
    echo "⚠️ refusing shallow workspace cwd sweep root: $root" >&2
    return 0
  fi

  local max_sweeps="${AIUR_WORKSPACE_REAP_SWEEPS:-6}"
  case "$max_sweeps" in '' | *[!0-9]*) max_sweeps=6 ;; esac
  [ "$max_sweeps" -gt 0 ] || return 0

  local protected pids=() filtered=() pid p sweep waited any
  protected=" $(shell_protected_pid_list | tr '\n' ' ') "

  sweep=0
  while [ "$sweep" -lt "$max_sweeps" ]; do
    mapfile -t pids < <(workspace_cwd_pids "$root" /proc)
    filtered=()
    for pid in "${pids[@]}"; do
      case "$protected" in *" $pid "*) continue ;; esac
      kill -0 "$pid" 2>/dev/null && filtered+=("$pid")
    done

    [ "${#filtered[@]}" -gt 0 ] || return 0

    for p in "${filtered[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
    waited=0
    while [ "$waited" -lt 10 ]; do
      any=0
      for p in "${filtered[@]}"; do kill -0 "$p" 2>/dev/null && { any=1; break; }; done
      [ "$any" -eq 0 ] && break
      sleep 0.1
      waited=$((waited + 1))
    done
    for p in "${filtered[@]}"; do kill -KILL "$p" 2>/dev/null || true; done

    sweep=$((sweep + 1))
    sleep 0.1
  done
}

reap_workspace_cwd_from_file() {
  local root_file="${1:-}" root
  [ -n "$root_file" ] && [ -s "$root_file" ] || return 0
  IFS= read -r root <"$root_file" || root=""
  reap_workspace_cwd_agents "$root"
}

workspace_root_file_from_instance_record() {
  load_aiur_instance_record "$(aiur_instance_record_path)" || return 1
  [ -n "${AIUR_RECORD_WORKSPACE_ROOT_FILE:-}" ] || return 1
  printf '%s\n' "$AIUR_RECORD_WORKSPACE_ROOT_FILE"
}

agent_pidfile_from_instance_record() {
  load_aiur_instance_record "$(aiur_instance_record_path)" || return 1
  if [ -n "${AIUR_RECORD_AGENT_TMPFILE:-}" ]; then
    printf '%s\n' "$AIUR_RECORD_AGENT_TMPFILE"
    return 0
  fi

  # Records written before the pidfile field still carry the handoff created
  # by the same launcher: aiur-PID-workspace-root and aiur-PID-agents share a
  # runtime directory. Derive that one file only when the old path has the
  # exact launch shape under this runtime root; never scan other instances.
  local session_root="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}" handoff pid
  session_root="${session_root%/}"
  [ -n "$session_root" ] || session_root=/
  handoff="${AIUR_RECORD_WORKSPACE_ROOT_FILE:-}"
  case "$handoff" in
    "$session_root"/aiur-*-workspace-root) ;;
    *) return 1 ;;
  esac
  pid="${handoff#"$session_root"/aiur-}"
  pid="${pid%-workspace-root}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  printf '%s/aiur-%s-agents\n' "$session_root" "$pid"
}

# Background watchdog that survives the BEAM. Polls for the release BEAM by
# command pattern and, once it has SEEN the BEAM and then the BEAM disappears
# (orderly halt OR :emfile-style crash), reaps every agent. Polling the pattern
# rather than a captured pid avoids two failure modes: a recycled BEAM pid the
# watchdog would poll forever, and an empty pid at arm time that would silently
# disarm the only crash reaper. The `seen` latch prevents a startup race from
# reaping before the BEAM has come up. kill-server collapses the orphaned tmux
# session, which returns the foreground `tmux attach` so the EXIT trap
# (session_cleanup) runs its idempotent reap too.
#
#   $1 beam_pattern  $2 socket  $3 pidfile  $4 interval_s  $5 initial_seen
#   $6 node  $7 run_log_dir  $8 stop_sentinel  $9 crash_marker
#   $10 workspace_root_file  $11 alert_ledger_path_file  $12 dump_baseline_file
# Any of args 6-9 or 11 arm crash recording. Foreground supplies only the node
# and alert-ledger handoff, so it can alert on a new dump without writing the
# background-only run marker.
# Prints the watchdog's own pid so the caller can kill it on a clean teardown.
start_beam_death_watchdog() {
  local beam_pattern="$1" socket="$2" pidfile="$3" interval="${4:-1}" initial_seen="${5:-0}"
  local node="${6:-}" run_log_dir="${7:-}" stop_sentinel="${8:-}" crash_marker="${9:-}" workspace_root_file="${10:-}"
  local alert_ledger_path_file="${11:-}" dump_baseline_file="${12:-}"
  # Redirect the subshell's stdout so a command-substitution caller
  # (`pid=$(start_beam_death_watchdog ...)`) returns immediately instead of
  # blocking on the still-open pipe until the watchdog finishes.
  (
    seen="$initial_seen"
    while :; do
      if pgrep -f -- "$beam_pattern" >/dev/null 2>&1; then
        seen=1
      elif [ "$seen" = 1 ]; then
        break
      fi
      sleep "$interval"
    done
    # The BEAM we had seen is gone. A clean `aiur stop` drops the sentinel first;
    # its presence means an intentional exit (consume it, no crash record).
    # Anything else is an unexpected exit worth a durable record before reaping.
    if [ -n "$stop_sentinel" ] && [ -f "$stop_sentinel" ]; then
      rm -f "$stop_sentinel" 2>/dev/null || true
    elif [ -n "$crash_marker" ] || [ -n "$run_log_dir" ] || [ -n "$alert_ledger_path_file" ]; then
      record_beam_crash "$node" "$run_log_dir" "$crash_marker" "$alert_ledger_path_file" "$dump_baseline_file"
    fi
    reap_aiur_agents "$socket" "$pidfile"
    reap_workspace_cwd_from_file "$workspace_root_file"
    rm -f "$alert_ledger_path_file" "$dump_baseline_file" 2>/dev/null || true
  ) >/dev/null 2>&1 &
  printf '%s\n' "$!"
}
