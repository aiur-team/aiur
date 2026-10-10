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
# tempfiles and leaked test artifacts. Runs alongside sweep_dead_tmux_sockets on
# foreground teardown (session_cleanup) and on `aiur stop`. Bounded and safe:
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
      aiur-rc | aiur-claude-hooks | aiur-debug)
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
  AIUR_STOP_FOUND_NOTHING=0
  resolve_release
  aiur_resolve_identity
  RELEASE_NODE="$AIUR_RELEASE_NODE"
  ERL_EPMD_ADDRESS="${ERL_EPMD_ADDRESS:-127.0.0.1}"
  export RELEASE_NODE ERL_EPMD_ADDRESS
  resolve_control_identity_from_records

  local workspace_root_file agent_pidfile
  workspace_root_file="$(workspace_root_file_from_instance_record 2>/dev/null || true)"
  agent_pidfile="$(agent_pidfile_from_instance_record 2>/dev/null || true)"

  local tmux_bin
  tmux_bin="$(command -v tmux || true)"
  local session="${AIUR_ADOPTED_TMUX_SESSION:-${AIUR_SESSION_PREFIX}-${USER:-user}${AIUR_INSTANCE_KEY:+-$AIUR_INSTANCE_KEY}-default}"
  local socket="${AIUR_ADOPTED_TMUX_SOCKET:-${AIUR_SESSION_PREFIX}-${USER:-user}${AIUR_INSTANCE_KEY:+-$AIUR_INSTANCE_KEY}}"

  local has_session=0
  if [ -n "$tmux_bin" ] && "$tmux_bin" -L "$socket" has-session -t "$session" 2>/dev/null; then
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
    AIUR_STOP_FOUND_NOTHING=1
    return 1
  fi

  # Tell the background BEAM-death watchdog this exit is intentional before we
  # kill the BEAM, so it consumes the sentinel instead of recording a crash. The
  # watchdog removes the sentinel when it fires; a fresh start also clears it.
  # Clear any prior crash marker too — `status` should report a clean stop, not
  # a stale orphan from an earlier dead run.
  mkdir -p "$AIUR_BG_STATE_DIR" 2>/dev/null || true
  : >"$(aiur_stop_sentinel_path)" 2>/dev/null || true
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
  rm -f "$(aiur_instance_record_path)" 2>/dev/null || true
  warn_other_aiur_daemons "$AIUR_RELEASE_NODE"
}

# Stop, refresh the release, start again — `aiur restart`.
#
# The refresh deliberately runs BETWEEN the stop and the start. A dev rebuild
# rewrites the release directory in place, and a BEAM booted from that directory
# is exactly what the control-retry path (EX_TEMPFAIL) exists to survive; doing
# it while the daemon is down means the new daemon boots from a release nothing
# else is holding half-written.
#
# The engine itself never knows how to build: the installed CLI runs a pinned
# platform release with no source tree beside it, so its restart is a plain
# bounce. The dev shim supplies its build-if-stale step through
# AIUR_RESTART_BUILD_CMD, a shell command line run via `bash -c` so the wrapper
# (not this parser) owns quoting.
aiur_restart_daemon_state="untouched"

# Everything between the stop and a confirmed start runs with this armed, so the
# operator hears about a fleet that is down no matter which step failed — a
# rebuild, a missing tmux, a BEAM that would not boot, or a Ctrl-C during the
# minutes-long rebuild. Naming only the step that failed would let "aiur failed
# to start" read as "nothing changed", which is the silently stopped fleet.
aiur_restart_report_state() {
  [ "$aiur_restart_daemon_state" = "stopped" ] || return 0

  # release_dir is resolved by the stop; fall back to the caller's declared dir
  # for the paths that fail before that.
  local dir="${release_dir:-${AIUR_RELEASE_DIR:-}}"

  echo "aiur: the daemon is STOPPED and was NOT restarted" >&2
  if [ -n "$dir" ] && [ -x "$dir/bin/aiur" ]; then
    echo "aiur: fix the cause and run 'aiur restart' again, or 'aiur restart --no-build' to start" >&2
    echo "      on the release already on disk" >&2
  else
    # The dev builder removes an incomplete release, so after a failed rebuild
    # there is nothing for --no-build to start. Advertising it anyway would cost
    # the operator a second failed cycle while the fleet stays down.
    echo "aiur: no complete release is left on disk, so --no-build has nothing to start —" >&2
    echo "      fix the build and run 'aiur restart' again" >&2
  fi
}

# The rebuild runs in a process this command cannot see into, so "the builder
# exited 0" is not the same claim as "the release I am about to boot is the one
# it just built" — a wrapper pointed at another checkout satisfies the first and
# not the second, which is exactly how a bounce ships a stale release while every
# step reports success. The builder leaves a receipt naming the release dir it
# vouches for and the commit it built from; this checks both against the release
# on disk. Anything unverifiable is reported as unverifiable, never as success.
verify_restart_build() {
  local receipt="$1"
  local built_dir built_sha stamped_sha stamp target_dir

  if [ ! -s "$receipt" ]; then
    echo "aiur: the rebuild left no build receipt, so restart cannot confirm which" >&2
    echo "      release it produced" >&2
    return 1
  fi

  built_dir="$(sed -n 's/^release_dir=//p' "$receipt" | head -n 1)"
  built_sha="$(sed -n 's/^source_sha=//p' "$receipt" | head -n 1)"

  # Fail on the missing field rather than on whatever an empty one happens to
  # compare equal to further down.
  if [ -z "$built_dir" ] || [ -z "$built_sha" ]; then
    echo "aiur: the build receipt is malformed; restart cannot confirm what was built" >&2
    return 1
  fi

  # Compare canonical paths: the builder and this engine can reach the same
  # release through different symlinked parents.
  built_dir="$(cd -P "$built_dir" 2>/dev/null && pwd || printf '%s' "$built_dir")"
  target_dir="$(cd -P "${AIUR_RELEASE_DIR:-}" 2>/dev/null && pwd || printf '%s' "${AIUR_RELEASE_DIR:-}")"

  if [ "$built_dir" != "$target_dir" ]; then
    echo "aiur: the rebuild targeted a different release than the one about to boot" >&2
    echo "      rebuilt : $built_dir" >&2
    echo "      booting : $target_dir" >&2
    return 1
  fi

  stamp="$target_dir/AIUR_BUILD_STAMP"
  if [ ! -r "$stamp" ]; then
    echo "aiur: the release carries no build stamp, so restart cannot confirm it is" >&2
    echo "      the one just built ($stamp)" >&2
    return 1
  fi

  stamped_sha="$(sed -n 's/^source_sha=//p' "$stamp" | head -n 1)"
  if [ "$stamped_sha" != "$built_sha" ]; then
    echo "aiur: the release on disk was not built from the commit the rebuild reported" >&2
    echo "      rebuild reported : $built_sha" >&2
    echo "      release stamped  : $stamped_sha" >&2
    return 1
  fi

  # Say what was actually established. "verified ... built from unknown" would be
  # a silent-pass guard reporting success over a release it cannot identify, and
  # a dirty tree means the SHA is a floor rather than an identity.
  if [ "$stamped_sha" = "unknown" ]; then
    echo "aiur: release $target_dir matches the rebuild, but its source commit is" >&2
    echo "      unknown (built outside a git work tree) — provenance unverified" >&2
    return 0
  fi

  if [ "$(sed -n 's/^dirty=//p' "$stamp" | head -n 1)" = "yes" ]; then
    echo "aiur: release $target_dir built from $stamped_sha with uncommitted changes" >&2
    return 0
  fi

  echo "aiur: verified release $target_dir built from $stamped_sha" >&2
}

cmd_restart() {
  local skip_build=0 arg
  local run_args=()

  # Refuse a stale config before stopping a healthy daemon. dispatch_run also
  # checks this for ordinary launches, but restart mutates state before it gets
  # that far.
  reject_legacy_config "$@"

  for arg in "$@"; do
    case "$arg" in
      --no-build) skip_build=1 ;;
      *) run_args+=("$arg") ;;
    esac
  done

  # Restarting something that is already down is a start, not an error: the
  # operator asked for a running daemon on current code, and that is what they
  # get. Any OTHER stop failure is fatal — building and starting on top of a
  # half-stopped instance is the in-place rewrite this ordering exists to avoid.
  local stop_status=0
  cmd_stop || stop_status=$?
  if [ "$stop_status" -ne 0 ]; then
    if [ "${AIUR_STOP_FOUND_NOTHING:-0}" -eq 1 ]; then
      echo "aiur: nothing was running; restart will start a fresh session" >&2
    else
      die "restart aborted: stop failed (exit $stop_status); the daemon may still be running"
    fi
  fi

  # cmd_stop's tmux teardown is best-effort (`|| true`), so a stop can report
  # success while the session survives. Starting from there would rebuild the
  # release under a live BEAM and then hit run_session's idempotent "already
  # running" return — exit 0, stale release, no bounce. Refuse instead.
  # release_bin is unset only when the stop was stubbed out, i.e. in tests.
  if [ -n "${release_bin:-}" ] && [ "$(probe_control_liveness)" = "up" ]; then
    die "restart aborted: the previous session still answers after the stop; nothing was rebuilt or restarted"
  fi

  aiur_restart_daemon_state="stopped"
  trap aiur_restart_report_state EXIT INT TERM

  if [ -n "${AIUR_RESTART_BUILD_CMD:-}" ] && [ "$skip_build" -eq 0 ]; then
    local build_status=0 receipt
    receipt="$(mktemp "${TMPDIR:-/tmp}/aiur-restart-receipt.XXXXXX")"
    AIUR_RESTART_BUILD_RECEIPT="$receipt" bash -c "$AIUR_RESTART_BUILD_CMD" || build_status=$?
    if [ "$build_status" -ne 0 ]; then
      # Exit with the builder's own status rather than a flat 1, so a caller can
      # still tell a failed rebuild from any other abort.
      rm -f "$receipt"
      echo "❌ restart aborted before start: the rebuild failed" >&2
      aiur_restart_report_state
      trap - EXIT INT TERM
      exit "$build_status"
    fi

    # A builder that declares AIUR_RESTART_BUILD_VERIFIES has promised a receipt,
    # so a missing or contradicted one is a real failure and an unverifiable
    # rebuild is not a lesser success — starting anyway would hand back the
    # stale-release outcome this ordering exists to prevent, with a "restarted"
    # line on top of it. A builder that makes no such promise cannot be held to
    # it; say plainly that the guarantee did not apply rather than convert an
    # unknown wrapper into a stopped fleet.
    if [ "${AIUR_RESTART_BUILD_VERIFIES:-0}" = "1" ]; then
      local verify_status=0
      verify_restart_build "$receipt" || verify_status=$?
      rm -f "$receipt"
      if [ "$verify_status" -ne 0 ]; then
        echo "❌ restart aborted before start: the rebuild could not be verified" >&2
        # Naming the builder makes an inherited AIUR_RESTART_BUILD_CMD — a dev
        # shim leaking into another shell — diagnosable from this output alone,
        # instead of an identical refusal on every retry.
        echo "   rebuild command: ${AIUR_RESTART_BUILD_CMD}" >&2
        echo "   Rebuild from the checkout you mean and retry, or 'aiur restart --no-build'" >&2
        echo "   to start the release on disk without the guarantee." >&2
        aiur_restart_report_state
        trap - EXIT INT TERM
        exit 70
      fi
    else
      rm -f "$receipt"
      echo "aiur: UNVERIFIED rebuild — this builder reports no receipt, so restart" >&2
      echo "      cannot confirm the release it is about to boot is the one just built" >&2
    fi
  elif [ "$skip_build" -eq 1 ]; then
    echo "aiur: --no-build — restarting on the release already on disk" >&2
  fi

  # Always detached: the daemon this stopped was itself detached, and a restart
  # that captured the terminal would be a surprise. `--interactive` still opts
  # into the attachable session (`aiur --bg --interactive`), and a purely
  # foreground restart remains `aiur stop && aiur run`.
  dispatch_run --bg "${run_args[@]+"${run_args[@]}"}"

  aiur_restart_daemon_state="running"
  trap - EXIT INT TERM
}
