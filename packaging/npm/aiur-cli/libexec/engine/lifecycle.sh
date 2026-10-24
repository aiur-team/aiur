# tmux and tmp sweeps, stop and restart. Sourced by aiur-engine.sh.
sweep_dead_tmux_sockets() {
  local tmux_bin
  tmux_bin="$(command -v tmux || true)"
  [ -n "$tmux_bin" ] || return 0

  local sockdir="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
  [ -d "$sockdir" ] || return 0

  local removed=0 name path
  for path in "$sockdir"/*; do
    [ -S "$path" ] || continue
    name="${path##*/}"
    case "$name" in
      aiur* | *-driver | *-driver-*) ;;
      *) continue ;;
    esac
    if ! "$tmux_bin" -L "$name" list-sessions >/dev/null 2>&1; then
      rm -f "$path" 2>/dev/null && removed=$((removed + 1))
    fi
  done

  [ "$removed" -gt 0 ] && echo "🧹 swept $removed dead aiur tmux socket(s)" >&2
  return 0
}

# Reap stale aiur /tmp debris so a tmpfs /tmp can't fill from accumulated per-run
# tempfiles and leaked test artifacts. Runs at launch, on foreground teardown
# (session_cleanup) and on `aiur stop`. Bounded and safe:
#
#   * Only exact top-level Aiur artifact families under the temp roots the engine
#     and BEAM write to. Arbitrary Executor worktrees/checkouts like
#     `/tmp/aiur-pr490` are not candidates.
#   * Age-gated by AIUR_TMP_REAP_MINUTES (default 1440 = 24h). An entry is removed
#     only when NOTHING in its subtree was modified within the window, so a live
#     run's shared debug dir (aiur-rc / aiur-claude-hooks / aiur-debug) holding a
#     fresh file is spared even when the dir's own mtime is stale. A non-numeric or
#     0 value disables the sweep.
#   * Ownership-gated: if anything in the tree is not owned by the effective user,
#     the whole tree is spared.
#   * A live run's pid-named session, agent, crash-ledger, and dump-baseline
#     handoffs are kept while its launcher pid is alive, regardless of age.
is_aiur_tmp_artifact_candidate() {
  local base="$1" pid
  case "$base" in
    aiur-argv.* | aiur-startup.* | aiur-pane.* | aiur-launcher.* | aiur-capture.* | \
      aiur-trap.*.log | aiur-tree.*.json | aiur-wrapper.pid | aiur-*-frames.bin | \
      aiur-rc | aiur-claude-hooks | aiur-debug | aiur-test-budget.* | aiur-test-state.*)
      return 0
      ;;
    aiur-*-sessions | aiur-*-agents | aiur-*-alert-ledger | aiur-*-crash-dump-baseline)
      pid="${base#aiur-}"
      pid="${pid%-sessions}"
      pid="${pid%-agents}"
      pid="${pid%-alert-ledger}"
      pid="${pid%-crash-dump-baseline}"
      [ -n "$pid" ] && [ -z "${pid//[0-9]/}" ]
      return
      ;;
    *)
      return 1
      ;;
  esac
}

sweep_stale_tmp_artifacts() {
  local minutes="${AIUR_TMP_REAP_MINUTES:-1440}"
  case "$minutes" in '' | *[!0-9]*) return 0 ;; esac
  [ "$minutes" -gt 0 ] || return 0

  # The dirs the engine + BEAM target: ${TMPDIR:-/tmp} (argv/startup/pane tempfiles
  # plus the BEAM's System.tmp_dir debug dirs) and ${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}
  # (the session/agent pidfiles' session_root). Deduped — a typical box scans one dir.
  local roots=() d seen
  for d in "${TMPDIR:-/tmp}" "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"; do
    [ -d "$d" ] || continue
    seen=0
    local root
    if [ "${#roots[@]}" -gt 0 ]; then
      for root in "${roots[@]}"; do
        [ "$root" = "$d" ] && { seen=1; break; }
      done
    fi
    [ "$seen" -eq 1 ] || roots+=("$d")
  done
  [ "${#roots[@]}" -gt 0 ] || return 0

  local removed=0 path base pid uid found
  uid="$(id -u)"
  for d in "${roots[@]}"; do
    while IFS= read -r -d '' path; do
      base="${path##*/}"
      is_aiur_tmp_artifact_candidate "$base" || continue

      # Spare mixed-ownership trees; cleanup should never cross user boundaries.
      if ! found="$(find "$path" ! -user "$uid" -print -quit 2>/dev/null)"; then
        continue
      fi
      if [ -n "$found" ]; then
        continue
      fi
      # Spare anything modified within the window anywhere in its subtree.
      if ! found="$(find "$path" -mmin "-$minutes" -print -quit 2>/dev/null)"; then
        continue
      fi
      if [ -n "$found" ]; then
        continue
      fi
      # Spare a live run's pid-named bookkeeping and crash handoffs.
      case "$base" in
        aiur-*-sessions | aiur-*-agents | aiur-*-alert-ledger | aiur-*-crash-dump-baseline)
          pid="${base#aiur-}"
          pid="${pid%-sessions}"
          pid="${pid%-agents}"
          pid="${pid%-alert-ledger}"
          pid="${pid%-crash-dump-baseline}"
          if [ -n "$pid" ] && [ -z "${pid//[0-9]/}" ] && kill -0 "$pid" 2>/dev/null; then
            continue
          fi
          ;;
      esac
      rm -f -- "$path/agent-token" 2>/dev/null # a --test budget dir's token copy goes first
      if rm -rf -- "$path" 2>/dev/null; then
        removed=$((removed + 1))
      fi
    done < <(find "$d" -maxdepth 1 -mindepth 1 -name 'aiur-*' -print0 2>/dev/null)
  done

  [ "$removed" -gt 0 ] && echo "🧹 swept $removed stale aiur tmp artifact(s)" >&2
  return 0
}

# A stop only reaps the daemon whose node name matches this project root's
# instance key (keys are sha256(project_root), so instances can't reap each
# other). A daemon launched from a different directory therefore survives a stop
# invoked elsewhere — the silent orphan that keeps holding the dashboard port and
# serving stale code/credentials. Surface it loudly (we warn, not reap, to
# respect the deliberate isolation) so the operator can stop it explicitly.
warn_other_aiur_daemons() {
  local self_node="$1" me pids pid cmd node port found=0
  me="${USER:-$(id -un 2>/dev/null)}"
  pids="$(pgrep -u "$me" -f -- "-name aiur-${me}" 2>/dev/null || true)"
  for pid in $pids; do
    cmd="$(pid_command "$pid")"
    case "$cmd" in *beam.smp*) : ;; *) continue ;; esac
    node="$(printf '%s' "$cmd" | grep -oE -- '-name [^ ]+' | awk '{print $2}' | head -1)"
    [ -z "$node" ] && continue
    [ "$node" = "$self_node" ] && continue
    port="$(ss -tlnpH 2>/dev/null | awk -v p="pid=$pid," '$0 ~ p {print $4}' \
      | grep -oE '[0-9]+$' | head -1 || true)"
    if [ "$found" -eq 0 ]; then
      echo "aiur: heads up — another aiur daemon is still running that this stop did not touch" >&2
      echo "      (launched from a different directory, so it has a different instance key):" >&2
      found=1
    fi
    echo "      pid=$pid node=$node${port:+ dashboard-port=$port} — stop it with:  kill $pid" >&2
  done
}

# Set when cmd_stop returns nonzero only because there was nothing to stop. It
# lets a caller (cmd_restart) tell that benign outcome apart from a stop that
# failed for a real reason, without changing `aiur stop`'s own exit code.
AIUR_STOP_FOUND_NOTHING=0

# Stop the running session: kill this instance's tmux + BEAM, then sweep.
cmd_stop() {
  [ "$#" -eq 0 ] || die "stop does not accept arguments; use restart --keep-agents"
  AIUR_STOP_FOUND_NOTHING=0
  resolve_release
  aiur_resolve_identity
  RELEASE_NODE="$AIUR_RELEASE_NODE"
  ERL_EPMD_ADDRESS="${ERL_EPMD_ADDRESS:-127.0.0.1}"
  export RELEASE_NODE ERL_EPMD_ADDRESS
  resolve_control_identity_from_records
  load_aiur_instance_record "$(aiur_instance_record_path)" >/dev/null 2>&1 || true

  local workspace_root_file agent_pidfile
  workspace_root_file="$(workspace_root_file_from_instance_record 2>/dev/null || true)"
  agent_pidfile="$(agent_pidfile_from_instance_record 2>/dev/null || true)"

  # The --test3 timing poller is a launcher-owned child, not part of the BEAM
  # tree. Stop it with its daemon so no detached GitHub polling survives.
  local test_ticket_ids="${AIUR_DEV_TEST_TICKET_IDS:-${AIUR_RECORD_TEST_TICKET_IDS:-}}"
  if [ "$test_ticket_ids" != "" ]; then
    local timer_pid_file="${AIUR_CONTROL_CALLER_ROOT:-$AIUR_PROJECT_ROOT}/.aiur-test3-timer.pid"
    local timer_pid
    if [ -r "$timer_pid_file" ]; then
      timer_pid="$(cat "$timer_pid_file" 2>/dev/null || true)"
      if [[ "$timer_pid" =~ ^[0-9]+$ ]]; then
        kill -- "-$timer_pid" 2>/dev/null || true
      fi
      rm -f "$timer_pid_file" 2>/dev/null || true
    fi
  fi

  local tmux_bin
  tmux_bin="$(command -v tmux || true)"
  local session="${AIUR_ADOPTED_TMUX_SESSION:-${AIUR_SESSION_PREFIX}-${USER:-user}${AIUR_INSTANCE_KEY:+-$AIUR_INSTANCE_KEY}-default}"
  local socket="${AIUR_ADOPTED_TMUX_SOCKET:-${AIUR_SESSION_PREFIX}-${USER:-user}${AIUR_INSTANCE_KEY:+-$AIUR_INSTANCE_KEY}}"

  local AIUR_AGENT_TMUX_SOCKET="${AIUR_RECORD_AGENT_SOCKET:-${socket}-agents}"
  local has_session=0
  if [ -n "$tmux_bin" ] && "$tmux_bin" -L "$socket" has-session -t "$session" 2>/dev/null || { [ -n "$tmux_bin" ] && "$tmux_bin" -L "$AIUR_AGENT_TMUX_SOCKET" has-session 2>/dev/null; }; then
    has_session=1
  fi

  if [ "${AIUR_CONTROL_ADOPTED_RECORD:-0}" -ne 1 ] && \
    [ "${AIUR_CONTROL_CURRENT_NODE_STATE:-}" = "down" ] && \
    [ "${AIUR_PROJECT_ROOT_SOURCE:-}" = "cwd" ] && \
    [ "$has_session" -eq 0 ] && \
    [ ! -f "$(aiur_crash_marker_path)" ]; then
    echo "aiur: no running aiur node at ${AIUR_RELEASE_NODE}; nothing stopped" >&2
    warn_other_aiur_daemons "$AIUR_RELEASE_NODE"
    print_global_config_control_hint
    cleanup_test_private_state; rm -f "$(aiur_instance_record_path)" 2>/dev/null || true
    AIUR_STOP_FOUND_NOTHING=1
    return 1
  fi

  # Tell the background BEAM-death watchdog this exit is intentional before we
  # kill the BEAM, so it consumes the sentinel instead of recording a crash. The
  # watchdog removes the sentinel when it fires; a fresh start also clears it.
  # Clear any prior crash marker too — `status` should report a clean stop, not
  # a stale orphan from an earlier dead run.
  mkdir -p "$AIUR_BG_STATE_DIR" 2>/dev/null || true
  if [ -n "${AIUR_RESTART_HANDOFF_ID:-}" ]; then
    write_handoff_stop "$(aiur_stop_sentinel_path)" "$agent_pidfile" || die "cannot protect handoff stop; nothing stopped"
  else
    : >"$(aiur_stop_sentinel_path)" 2>/dev/null || true
  fi
  if [ "${aiur_restart_keep_agents:-0}" -eq 1 ]; then
    aiur_restart_phase="stop_observed"
    aiur_restart_reason="stop_command_observed_daemon_state"
    local crash_marker evidence_file
    crash_marker="$(aiur_crash_marker_path)"
    evidence_file="$(aiur_restart_crash_evidence_path)"
    if [ -s "$crash_marker" ]; then
      cp "$crash_marker" "$evidence_file" 2>/dev/null && chmod 600 "$evidence_file" 2>/dev/null || true
    fi
    aiur_write_restart_diagnostic
  fi
  rm -f "$(aiur_crash_marker_path)" 2>/dev/null || true

  if [ -n "$tmux_bin" ]; then
    "$tmux_bin" -L "$socket" kill-session -t "$session" 2>/dev/null || true
  fi

  # Reap any BEAM holding our node name regardless of which release dir launched
  # it. Do not sweep by release dir: sibling instances share dev releases. Use
  # the generous stop TERM grace: the BEAM, once TERM'd, runs its own graceful
  # shutdown (ProcessReaper reaping the agent tree, opencode session deletes,
  # then the BEAM-side workspace sweep) and the short 3s startup default would
  # SIGKILL it mid-cleanup, orphaning exactly the agents this stop must reap.
  # The loop exits the moment the BEAM is gone, so a fast stop costs nothing.
  kill_beams_matching "-name ${AIUR_RELEASE_NODE}" 300

  if [ -n "${AIUR_RESTART_HANDOFF_ID:-}" ]; then
    [ -z "$tmux_bin" ] || "$tmux_bin" -L "$socket" kill-server 2>/dev/null || true
    return 0
  fi

  # Final cwd-sweep backstop after the BEAM is dead. The launcher's instance
  # record points to the BEAM-written root handoff, so degraded stop never has
  # to wait for an overloaded daemon before it starts tearing workers down.
  reap_workspace_cwd_from_file "$workspace_root_file"

  # The BEAM (alive until the TERM above) reaped its own headless agents through
  # ProcessReaper on Application.stop. kill-server is the guarantee the earlier
  # kill-session can't give for mid-turn agents: every pane agent across all
  # windows dies and no live aiur tmux server is left behind.
  if [ -n "$tmux_bin" ]; then
    "$tmux_bin" -L "$socket" kill-server 2>/dev/null || true
    "$tmux_bin" -L "$AIUR_AGENT_TMUX_SOCKET" kill-server 2>/dev/null || true
  fi

  # Belt-and-suspenders for this run's headless agents after the BEAM exits.
  # The instance record owns its pidfile; a global sweep can kill live agents
  # belonging to another instance that shares the runtime directory.
  if [ -n "$agent_pidfile" ] && [ -e "$agent_pidfile" ]; then
    reap_aiur_agents "" "$agent_pidfile"
    rm -f "$agent_pidfile" 2>/dev/null || true
  fi

  reap_stale_manual_smoke 0
  sweep_dead_tmux_sockets
  sweep_stale_tmp_artifacts
  rm -f "$(aiur_instance_record_path)" 2>/dev/null || true; cleanup_test_private_state
  warn_other_aiur_daemons "$AIUR_RELEASE_NODE"
}
