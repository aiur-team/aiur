# Interactive and background runs: run argv, run_session, tmux attach and conf. Sourced by aiur-engine.sh.

# --- interactive / background run -------------------------------------------
#
# mode=foreground attaches the UI and tears down on exit; mode=background leaves
# the detached tmux session running and returns.

# Dotenv precedence: shell exports win, then ./.env, then ~/.aiur/.env. Each

run_argv=()
# Default dashboard bind host. Remote access is an explicit operator choice.
# The BEAM applies this below `server.host`; `--host` has highest precedence.
default_dashboard_host() {
  printf '%s' "${AIUR_DEFAULT_DASHBOARD_HOST:-127.0.0.1}"
}

build_run_argv() {
  local mode="$1"
  shift

  local has_interactive=0 has_headless=0 has_ack=0 arg
  for arg in "$@"; do
    case "$arg" in
      --interactive) has_interactive=1 ;;
      --headless) has_headless=1 ;;
      --i-understand-that-this-will-be-running-without-the-usual-guardrails) has_ack=1 ;;
    esac
  done

  local injected=()
  if [ "$mode" = "background" ] && [ "$has_interactive" -eq 0 ]; then
    [ "$has_headless" -eq 1 ] || injected+=(--headless)
  else
    [ "$has_interactive" -eq 1 ] || injected+=(--interactive)
  fi
  [ "$has_ack" -eq 1 ] || injected+=(--i-understand-that-this-will-be-running-without-the-usual-guardrails)

  run_argv=("${injected[@]}" "$@")
}

run_session() {
  local mode="$1"
  shift

  # --debug is an engine-level convenience on the run path: turn on verbose
  # logging (AIUR_DEBUG) and strip the flag before the release parses argv.
  local run_args=() run_arg
  for run_arg in "$@"; do
    case "$run_arg" in
      --debug) export AIUR_DEBUG=1 ;;
      *) run_args+=("$run_arg") ;;
    esac
  done
  if [ "${#run_args[@]}" -gt 0 ]; then set -- "${run_args[@]}"; else set --; fi

  resolve_release

  local tmux_bin
  tmux_bin="$(command -v tmux || true)"
  [ -n "$tmux_bin" ] || die "tmux is required to run aiur; install tmux and retry"

  aiur_resolve_identity
  prepare_distribution

  local session="${AIUR_SESSION_PREFIX}-${USER:-user}${AIUR_INSTANCE_KEY:+-$AIUR_INSTANCE_KEY}-default"
  local socket="${AIUR_SESSION_PREFIX}-${USER:-user}${AIUR_INSTANCE_KEY:+-$AIUR_INSTANCE_KEY}"
  local conf launch_lock
  conf="$(resolve_tmux_conf)"
  [ -f "$conf" ] || die "tmux conf not found at $conf"
  launch_lock="$(aiur_launch_lock_path)"
  acquire_aiur_launch_lock "$launch_lock" || return 1

  # An invocation targeting an existing directory session resolves here before
  # fresh-start credentials, argv files, run logs, watchdogs, or teardown traps.
  # Foreground attaches; background exits with explicit attach guidance.
  if "$tmux_bin" -L "$socket" -f "$conf" has-session -t "$session" 2>/dev/null; then
    if [ "$(probe_control_liveness)" = "up" ]; then
      # Preserve the live launch's record and workspace-root handoff. Only
      # backfill old/missing records, without pointing them at this attach
      # invocation's transient state.
      AIUR_WORKSPACE_ROOT_FILE="" write_aiur_instance_record "$session" "$socket" if-absent

      if [ "$mode" = "background" ]; then
        echo "aiur is already running in the background (tmux session ${session})." >&2
        echo "Attach with: aiur" >&2
        echo "Use: aiur status   # inspect agents" >&2
        echo "Use: aiur stop     # stop it before starting a fresh session" >&2
        release_aiur_launch_lock "$launch_lock"
        return 0
      fi

      echo "aiur is already running; attaching to the running session ${session}." >&2
      release_aiur_launch_lock "$launch_lock"
      attach_tmux_session "$tmux_bin" "$socket" "$conf" "$session"
      return $?
    fi

    # A tmux holder can exist while a healthy BEAM is still booting or while
    # epmd itself is temporarily unreachable. Never turn one failed control
    # probe into destructive cleanup unless distribution confirms the keyed
    # node is absent.
    case "$(probe_node_liveness)" in
      down)
        if ! confirm_stale_tmux_session "$tmux_bin" "$socket" "$conf" "$session"; then
          echo "aiur found session ${session}, but it became live while checking stale state; leaving it intact." >&2
          echo "Retry: aiur" >&2
          release_aiur_launch_lock "$launch_lock"
          return 1
        fi
        echo "aiur found stale tmux session ${session}; cleaning it up before restart" >&2
        reap_aiur_agents "$socket" ""
        kill_beams_matching "-name ${AIUR_RELEASE_NODE}"
        ;;
      up | unknown)
        echo "aiur found session ${session}, but its control plane is not ready; leaving the running session intact." >&2
        echo "Retry: aiur" >&2
        release_aiur_launch_lock "$launch_lock"
        return 1
        ;;
    esac
  fi

  # The launch phases below read and set these through bash dynamic scope.
  local no_dashboard=0 surface_mode=interactive session_root crash_dump_baseline_file=""
  local startup_capture launcher inner_cmd launch_tempfiles=()
  run_session_prepare_env "$@"
  run_session_write_pane_launcher

  if [ "$mode" = "foreground" ]; then
    _session_socket="$socket" _session_name="$session" _session_conf="$conf" \
      _session_tmpfile="$AIUR_SESSION_TMPFILE" _session_capture="$startup_capture" \
      _session_argv="$argv_file" _session_release="$release_dir" _session_tmux="$tmux_bin" \
      _session_node="$AIUR_RELEASE_NODE" _session_pidfile="$AIUR_AGENT_TMPFILE" \
      _session_workspace_root_file="$AIUR_WORKSPACE_ROOT_FILE" \
      _session_alert_ledger_path_file="$AIUR_ALERT_LEDGER_PATH_FILE" \
      _session_crash_dump_baseline_file="$crash_dump_baseline_file" \
      _session_launch_lock="$launch_lock"
    install_foreground_traps
  fi

  run_session_reclaim_stale_nodes
  run_session_start_tmux

  # Grace window: surface a boot crash instead of attaching to nothing. Prove
  # the control plane can answer before declaring startup usable: background
  # control commands depend on that RPC path, and foreground automation must not
  # treat a pre-TUI application crash as a successful `tmux attach`.
  local require_control=1
  if ! wait_for_session_startup "$tmux_bin" "$socket" "$conf" "$session" "$startup_capture" "$require_control"; then
    print_config_status "$startup_capture"
    # The application can write the ledger handoff and then crash before its
    # control plane becomes ready. Inspect the completed dump before launcher
    # cleanup removes that handoff; this path intentionally writes no generic
    # crash marker when there is no new completed dump.
    record_new_crash_dump_alert "$AIUR_ALERT_LEDGER_PATH_FILE" "$crash_dump_baseline_file"
    if [ "$mode" = "background" ]; then
      "$tmux_bin" -L "$socket" -f "$conf" kill-session -t "$session" 2>/dev/null || true
      reap_aiur_agents "$socket" "$AIUR_AGENT_TMPFILE"
      kill_beams_matching "-name ${AIUR_RELEASE_NODE}"
    fi
    release_aiur_launch_lock "$launch_lock"
    _session_launch_lock=""
    [ "$mode" = "foreground" ] && return 1
    rm -f "${launch_tempfiles[@]}" 2>/dev/null || true
    exit 1
  fi

  write_aiur_instance_record "$session" "$socket" replace "$surface_mode"
  release_aiur_launch_lock "$launch_lock"
  _session_launch_lock=""
  print_config_status "$startup_capture"
  print_dashboard_status "$no_dashboard" "$startup_capture"
  # The `aiur run` version notice: a cheap local state read (the daemon's
  # `Aiur.Upgrade` check writes it during boot), never a network call, so it
  # can never delay startup. Silent under a dev launcher and when opted out.
  # `|| true` keeps a display failure from ever failing the run — the notice
  # is strictly additive.
  maybe_surface_upgrade_notice || true

  if [ "$mode" = "foreground" ]; then
    echo "aiur foreground tmux socket ${socket}, session ${session}" >&2
  fi

  if [ "$mode" = "background" ]; then
    run_session_arm_background_watchdog
    return 0
  fi

  # Arm the BEAM-death watchdog before attaching. If the BEAM crashes
  # (:emfile) mid-run, agent windows keep the orphaned session alive so the
  # `tmux attach` below never returns and the EXIT trap never fires — the
  # watchdog is the external reaper that survives the dead BEAM, kill-servers
  # the session, and unblocks the attach. It polls the node name rather than a
  # captured pid, so another Aiur instance from the same release cannot hold it open.
  _session_watchdog_pid="$(start_beam_death_watchdog \
    "-name ${AIUR_RELEASE_NODE}" "$socket" "$AIUR_AGENT_TMPFILE" 1 0 \
    "$AIUR_RELEASE_NODE" "" "" "" "$AIUR_WORKSPACE_ROOT_FILE" \
    "$AIUR_ALERT_LEDGER_PATH_FILE" "$crash_dump_baseline_file")"

  # Foreground: attach the UI. Do not exec — that would drop the teardown trap.
  # Avoid process substitution here: some sandboxed non-TTY launchers reject
  # opening /dev/fd/* during the real manual-test wrapper path.
  attach_tmux_session "$tmux_bin" "$socket" "$conf" "$session"
}

# The run_session_* phases run in run_session's shell and share its locals
# (mode, session, socket, conf, tmux_bin, launch_lock and the launch state it
# declares), so none of them may be called from anywhere else.

# Fresh-launch environment: dotenv, run argv, and the tmpfile and crash-dump
# handoffs the BEAM and its watchdog share.
run_session_prepare_env() {
  # Pick up GITHUB_TOKEN / dashboard creds the wizard wrote to ./.env so the
  # running tracker can authenticate. Shell exports still take precedence.
  load_dotenv
  scrub_run_only_env
  export AIUR_DEFAULT_DASHBOARD_HOST="$(default_dashboard_host)"

  # The BEAM lives in tmux, but a fresh foreground run belongs to this shell:
  # it waits on the UI attach and owns the teardown trap. Hand its pid to the
  # pane watchdog so a hard-killed launcher cannot leave agents running.
  # A detached run has no such owner; discard any inherited stale value.
  if [ "$mode" = "foreground" ]; then
    export AIUR_LAUNCHER_PID="$$"
  else
    unset AIUR_LAUNCHER_PID
  fi

  # The daemon's `Aiur.Upgrade` check uses the CLI package version (not the mix
  # version) as the "installed" version, so an npm install's notice names what
  # the user actually has. `run_version` sets the same var for `--version`.
  AIUR_CLI_VERSION="$(cli_package_version || true)"
  export AIUR_CLI_VERSION

  init_argv_file

  # Supply the flags a bare `aiur` needs: UI mode and the no-guardrails ack.
  # The exported dashboard host fills only a missing config value; an explicit
  # server.host or --host remains authoritative. Foreground runs are
  # interactive; `--bg` runs headless (no panes/chat backfill) and is driven
  # over the control RPC (status/agents/message/pause/set). Dashboard binding is
  # independent: it remains enabled in either mode unless `--no-dashboard` is
  # supplied. `aiur --bg --interactive` opts back into the full terminal stack
  # for an attachable background session.
  build_run_argv "$mode" "$@"
  for run_arg in "${run_argv[@]}"; do
    [ "$run_arg" = "--no-dashboard" ] && no_dashboard=1
    [ "$run_arg" = "--headless" ] && surface_mode=headless
  done
  write_argv "${run_argv[@]}"
  export AIUR_ARGV_FILE="$argv_file"

  build_release_cmd

  # Force +fnu when no locale is set so the BEAM does not mangle non-ASCII paths.
  if [ -z "${LANG:-}" ] && [ -z "${LC_ALL:-}" ] && [ -z "${LC_CTYPE:-}" ]; then
    export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-} +fnu"
  fi

  preflight_stale_manual_smoke

  mkdir -p "$AIUR_BG_STATE_DIR"
  printf '%s\n' "$session" >"$AIUR_BG_STATE_DIR/state"
  export AIUR_TMUX_SESSION="$session"
  export AIUR_TMUX_SOCKET="$socket"
  export AIUR_TMUX_CONF="$conf"
  export AIUR_BIN="$engine_source"

  session_root="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
  export AIUR_SESSION_TMPFILE="${session_root}/aiur-${$}-sessions"
  : >"$AIUR_SESSION_TMPFILE"

  # Agent pidfile: the BEAM appends one line per spawned agent (pane or headless
  # os_pid) via Aiur.ProcessReaper. The BEAM-death watchdog and session_cleanup
  # reap from it after the BEAM is gone — a crashed BEAM can kill nothing itself.
  export AIUR_AGENT_TMPFILE="${session_root}/aiur-${$}-agents"
  : >"$AIUR_AGENT_TMPFILE"

  # Workspace-root handoff for the shell cwd-sweep backstop. The BEAM writes the
  # resolved Aiur.Config.workspace_root() here after config loads.
  export AIUR_WORKSPACE_ROOT_FILE="${session_root}/aiur-${$}-workspace-root"
  : >"$AIUR_WORKSPACE_ROOT_FILE"

  # Background runs persist under a known run log dir so (a) the BEAM-death
  # watchdog, which outlives the BEAM, can drop a crash record next to aiur.log,
  # and (b) the post-start boot capture is not lost to /tmp when the launcher
  # removes its startup tempfile. Minting it here and exporting it makes the
  # shell and the BEAM (Aiur.LogFile honors AIUR_LOGS_ROOT) agree on one dir.
  if [ "$mode" = "background" ] && [ -z "${AIUR_LOGS_ROOT:-}" ]; then
    AIUR_LOGS_ROOT="$(printf '%s/%s-%s' "$HOME/.aiur/logs" "$(date -u +%Y%m%dT%H%M%SZ)" "$$")"
    export AIUR_LOGS_ROOT
  fi

  # Capture an erl_crash.dump on daemon BEAM death (#852) so a crash under load
  # is diagnosable instead of vanishing. Written next to the run's aiur.log so it
  # survives the launcher's tempfile cleanup; ERL_CRASH_DUMP_SECONDS bounds the
  # write so a wedged BEAM can't hang the dump indefinitely. Nothing in the
  # release boot disables dumps, and an Executor override of either var is kept.
  # Requires a durable logs root (background run or agent IR sandbox).
  if [ -n "${AIUR_LOGS_ROOT:-}" ]; then
    export ERL_CRASH_DUMP="${ERL_CRASH_DUMP:-$AIUR_LOGS_ROOT/erl_crash.dump}"
    export ERL_CRASH_DUMP_SECONDS="${ERL_CRASH_DUMP_SECONDS:-30}"
  fi
}

# Writes the inner pane script and records every launch tempfile.
run_session_write_pane_launcher() {
  # Crash recording needs two launcher/BEAM handoffs: the canonical alert
  # ledger path and the launch-time identity of the configured dump path. Keep
  # these for foreground launches too: their external watchdog is also the only
  # process left to surface a dump after an unexpected daemon death.
  export AIUR_ALERT_LEDGER_PATH_FILE=""
  crash_dump_baseline_file=""
  if [ -n "${ERL_CRASH_DUMP:-}" ]; then
    AIUR_ALERT_LEDGER_PATH_FILE="${session_root}/aiur-${$}-alert-ledger"
    : >"$AIUR_ALERT_LEDGER_PATH_FILE"
    crash_dump_baseline_file="${session_root}/aiur-${$}-crash-dump-baseline"
    crash_dump_identity "${ERL_CRASH_DUMP:-}" >"$crash_dump_baseline_file" 2>/dev/null || : >"$crash_dump_baseline_file"
  fi

  # Capture sink for BEAM startup (and, in background mode, the whole run's
  # boot stdout/stderr). Foreground uses a throwaway tempfile; background points
  # at a durable file in the run log dir. The dir/file is created lazily just
  # before launch (below) so an idempotent early-return start leaves no empty dir.
  if [ "$mode" = "background" ] && [ -n "${AIUR_LOGS_ROOT:-}" ]; then
    startup_capture="$AIUR_LOGS_ROOT/log/boot.out.log"
  else
    startup_capture="$(mktemp "${TMPDIR:-/tmp}/aiur-startup.XXXXXX")"
  fi

  # Inner pane script: tmux's server may pre-exist and not inherit our env, so
  # re-export every var the BEAM needs. tee preserves a startup capture.
  launcher="$(mktemp "${TMPDIR:-/tmp}/aiur-pane.XXXXXX")"
  chmod +x "$launcher"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -o pipefail\n'
    printf 'unset AIUR_CI_READINESS_TOKEN\n'
    printf 'cd %q || exit 1\n' "$PWD"
    local v
    for v in AIUR_RELEASE_DIR AIUR_ARGV_FILE RELEASE_DISTRIBUTION RELEASE_NODE \
      RELEASE_COOKIE ERL_AFLAGS ERL_EPMD_ADDRESS AIUR_NODE AIUR_ERLANG_COOKIE \
      AIUR_TMUX_SESSION AIUR_TMUX_SOCKET AIUR_TMUX_CONF AIUR_BIN \
      AIUR_SESSION_TMPFILE AIUR_AGENT_TMPFILE AIUR_WORKSPACE_ROOT_FILE AIUR_ALERT_LEDGER_PATH_FILE \
      ELIXIR_ERL_OPTIONS AIUR_LOGS_ROOT AIUR_OPENCODE_BRIDGE_PORT AIUR_DEFAULT_DASHBOARD_HOST AIUR_DEBUG AIUR_DEV_TEST_TICKET_IDS \
      AIUR_OPERATOR_PID AIUR_LAUNCHER_PID AIUR_NOFILE_SOFT_LIMIT ERL_CRASH_DUMP ERL_CRASH_DUMP_SECONDS \
      AIUR_BG_STATE_DIR AIUR_INSTANCE_KEY AIUR_CLI_VERSION; do
      if [ -n "${!v:-}" ]; then printf 'export %s=%q\n' "$v" "${!v}"; fi
    done
    printf 'capture=%q\n' "$startup_capture"
    printf '%q' "${release_cmd[0]}"
    for arg in "${release_cmd[@]:1}"; do printf ' %q' "$arg"; done
    printf ' 2>&1 | tee -a "$capture"\n'
    printf 'exit ${PIPESTATUS[0]}\n'
  } >"$launcher"

  printf -v inner_cmd '%q; rc=$?; rm -f %q; exit $rc' "$launcher" "$launcher"

  launch_tempfiles=(
    "$startup_capture" "$argv_file" "$launcher" "$AIUR_SESSION_TMPFILE"
    "$AIUR_AGENT_TMPFILE" "$AIUR_WORKSPACE_ROOT_FILE"
  )
  [ -n "$AIUR_ALERT_LEDGER_PATH_FILE" ] && launch_tempfiles+=("$AIUR_ALERT_LEDGER_PATH_FILE")
  [ -n "$crash_dump_baseline_file" ] && launch_tempfiles+=("$crash_dump_baseline_file")
  # A false `[ ] &&` as the last statement would fail the launch under `set -e`.
  return 0
}

run_session_reclaim_stale_nodes() {
  # An orphaned BEAM (its tmux session gone) can still hold THIS instance's node
  # name. With no live session on our (instance-keyed) socket, reap the name-holder
  # so the launch isn't blocked by "name seems to be in use". The keyed name means
  # this only ever reaps our own instance's orphan, never another live aiur.
  if ! "$tmux_bin" -L "$socket" -f "$conf" has-session -t "$session" 2>/dev/null; then
    kill_beams_matching "-name ${AIUR_RELEASE_NODE}"
  fi

  # Transition reclaim: a keyed instance also reaps a stale beam under the legacy
  # un-keyed name (aiur-$USER@127.0.0.1) — but only when no live legacy session
  # exists, so a pre-fix run still in progress is never killed. (Runs on every keyed
  # launch, not latched; it's a cheap best-effort sweep guarded by has-session.)
  if [ -n "${AIUR_INSTANCE_KEY:-}" ]; then
    local legacy_socket="${AIUR_SESSION_PREFIX}-${USER:-user}"
    if ! "$tmux_bin" -L "$legacy_socket" -f "$conf" has-session -t "${legacy_socket}-default" 2>/dev/null; then
      kill_beams_matching "-name aiur-${USER}@127.0.0.1"
    fi
  fi
}

run_session_start_tmux() {
  # Create the capture sink now (after the idempotent early-return checks above,
  # so a no-op "already running" start never mints an empty run log dir). The
  # launcher's `tee -a` needs the file's parent to exist when the pane runs.
  mkdir -p "$(dirname "$startup_capture")" 2>/dev/null || true
  : >"$startup_capture" 2>/dev/null || true

  if ! "$tmux_bin" -L "$socket" -f "$conf" new-session -d -s "$session" \
    -x "${COLUMNS:-200}" -y "${LINES:-50}" "$inner_cmd"; then
    echo "❌ aiur failed to start; captured output:" >&2
    tail -n 30 "$startup_capture" 2>/dev/null | sed 's/^/  /' >&2 || true
    rm -f "${launch_tempfiles[@]}" 2>/dev/null || true
    release_aiur_launch_lock "$launch_lock"
    exit 1
  fi

  # Each instance has its own tmux socket. Publish the executable shipped next
  # to this engine before the TUI opens a chat pane; tmux receives the path as
  # one argument, including when the npm install directory contains spaces.
  if [ "$mode" = "foreground" ]; then
    local ctrlc_helper="$engine_dir/aiur-pane-ctrlc"
    if [ ! -x "$ctrlc_helper" ] ||
       ! "$tmux_bin" -L "$socket" -f "$conf" set-option -g @aiur_ctrlc "$ctrlc_helper"; then
      "$tmux_bin" -L "$socket" -f "$conf" kill-session -t "$session" 2>/dev/null || true
      rm -f "${launch_tempfiles[@]}" 2>/dev/null || true
      release_aiur_launch_lock "$launch_lock"
      die "aiur pane control helper is unavailable at $ctrlc_helper"
    fi
  fi

  # Title the agent-list pane (the only pane in the fresh session). The conf's
  # `pane-border-status`/`pane-border-format` render it; PaneManager titles the
  # chat panes it opens. Best-effort — a missing title just shows the default.
  "$tmux_bin" -L "$socket" -f "$conf" select-pane -t "$session" -T "AIUR Agents" 2>/dev/null || true
}

run_session_arm_background_watchdog() {
  # Fresh run: drop any stale crash/stop state from a prior dead instance so
  # `status` doesn't report a phantom orphan and the watchdog starts clean.
  rm -f "$(aiur_stop_sentinel_path)" "$(aiur_crash_marker_path)" 2>/dev/null || true

  local background_watchdog_pid
  background_watchdog_pid="$(start_beam_death_watchdog \
    "-name ${AIUR_RELEASE_NODE}" "$socket" "$AIUR_AGENT_TMPFILE" 1 1 \
    "$AIUR_RELEASE_NODE" "${AIUR_LOGS_ROOT:-}" \
    "$(aiur_stop_sentinel_path)" "$(aiur_crash_marker_path)" "$AIUR_WORKSPACE_ROOT_FILE" \
    "$AIUR_ALERT_LEDGER_PATH_FILE" "$crash_dump_baseline_file")"
  disown "$background_watchdog_pid" 2>/dev/null || true
  echo "aiur started in the background (tmux socket ${socket}, session ${session}). Attach with: aiur" >&2
  # Keep $startup_capture (boot.out.log) for the run's lifetime; only the
  # transient argv file is no longer needed.
  rm -f "$argv_file" 2>/dev/null || true
}

attach_tmux_session() {
  local tmux_bin="$1" socket="$2" conf="$3" session="$4"
  local attach_stderr attach_code
  attach_stderr="$(mktemp "${TMPDIR:-/tmp}/aiur-attach-stderr.XXXXXX")"
  if "$tmux_bin" -L "$socket" -f "$conf" attach -t "$session" 2>"$attach_stderr"; then
    attach_code=0
  else
    attach_code=$?
  fi
  grep -v -F "[server exited]" "$attach_stderr" >&2 || true
  rm -f "$attach_stderr" 2>/dev/null || true
  return "$attach_code"
}

resolve_tmux_conf() {
  if [ -n "${AIUR_TMUX_CONF:-}" ] && [ -f "${AIUR_TMUX_CONF:-}" ]; then
    printf '%s\n' "$AIUR_TMUX_CONF"
    return
  fi
  local user_conf="${XDG_CONFIG_HOME:-$HOME/.config}/aiur/tmux.conf"
  if [ -f "$user_conf" ]; then
    printf '%s\n' "$user_conf"
    return
  fi
  printf '%s\n' "$engine_dir/../share/aiur.tmux.conf"
}
