# Session liveness and status probes, startup wait, cleanup and foreground traps. Sourced by aiur-engine.sh.

probe_control_liveness() {
  local expression output status
  # The Orchestrator starts before the dashboard child, so an answering status
  # call alone does not prove startup (or the bind attempt) finished. Wait until
  # OTP marks :aiur started before printing the effective dashboard status.
  expression='aiur_started = Enum.any?(Application.started_applications(), fn {app, _description, _version} -> app == :aiur end); case {Process.whereis(Aiur.Orchestrator), aiur_started} do {pid, true} when is_pid(pid) -> case Aiur.Orchestrator.status(Aiur.Orchestrator, 100) do statuses when is_list(statuses) -> IO.puts("__AIUR_CONTROL_READY__"); _ -> IO.puts("__AIUR_CONTROL_NOT_READY__") end; _ -> IO.puts("__AIUR_CONTROL_NOT_READY__") end'

  set +e
  output="$("$release_bin" rpc "$expression" 2>&1)"
  status=$?
  set -e

  if [ "$status" -eq 0 ] && [[ "$output" == *"__AIUR_CONTROL_READY__"* ]]; then
    printf 'up'
  else
    printf 'down'
  fi
}

# Return the useful URL and effective bind host/port only when the running node
# confirms that Bandit actually bound a listener. An empty result means the
# listener was suppressed or refused; configured server.port alone is never
# proof of service.
probe_dashboard_status() {
  local expression output status marker="__AIUR_DASHBOARD_STATUS__:"
  expression='case {Aiur.HttpServer.base_url(), Aiur.Config.server_host(), Aiur.HttpServer.bound_port()} do {url, host, port} when is_binary(url) and is_binary(host) and is_integer(port) -> IO.puts("__AIUR_DASHBOARD_STATUS__:Dashboard: " <> url <> " (bind host=" <> host <> ", port=" <> Integer.to_string(port) <> ")"); _ -> :ok end'

  set +e
  run_release_rpc_with_timeout "$expression"
  status=$?
  set -e
  output="$AIUR_CONTROL_RPC_OUTPUT"

  if [ "$status" -eq 0 ] && [[ "$output" == *"$marker"* ]]; then
    output="${output#*"$marker"}"
    printf '%s' "${output%%$'\n'*}"
  fi
}

# Replay the exact path selected by the CLI inside tmux. The BEAM's startup
# output is captured rather than shown directly, so the marker crosses that
# boundary without duplicating config-discovery rules in this launcher.
print_config_status() {
  local startup_capture="$1" marker="__AIUR_CONFIG_PATH__:" config_path

  config_path="$(awk -v marker="$marker" 'index($0, marker) == 1 { print substr($0, length(marker) + 1); exit }' "$startup_capture" 2>/dev/null || true)"

  if [ -n "$config_path" ]; then
    echo "Config: ${config_path}" >&2
  else
    echo "⚠️ selected config path unavailable in captured startup output." >&2
  fi
}

print_dashboard_status() {
  local no_dashboard="$1" startup_capture="$2" dashboard_status

  if [ "$no_dashboard" -eq 1 ]; then
    echo "Dashboard disabled by --no-dashboard." >&2
    return
  fi

  dashboard_status="$(probe_dashboard_status)"
  if [ -n "$dashboard_status" ]; then
    echo "${dashboard_status}" >&2
  else
    echo "⚠️ dashboard listener unavailable; inspect ${startup_capture} for bind or authentication refusal." >&2
  fi
}

wait_for_session_startup() {
  local tmux_bin="$1" socket="$2" conf="$3" session="$4" startup_capture="$5" require_control="$6"
  local max_ticks="${AIUR_TMUX_GRACE_TICKS:-30}" tick control_state
  if [ "$require_control" = "1" ]; then
    # 0.1s per tick. The old 100-tick (10s) budget was under a cold control
    # plane's real boot time, so a healthy daemon was killed mid-startup and
    # reported as a failure. Boot time grows with the module count; keep the
    # headroom generous, since the loop exits as soon as the probe says "up".
    max_ticks="${AIUR_NODE_GRACE_TICKS:-1200}"
  fi

  for ((tick = 0; tick < max_ticks; tick++)); do
    if ! "$tmux_bin" -L "$socket" -f "$conf" has-session -t "$session" 2>/dev/null; then
      echo "❌ aiur exited during startup; captured output:" >&2
      tail -n 30 "$startup_capture" 2>/dev/null | sed 's/^/  /' >&2 || true
      return 1
    fi

    if [ "$require_control" != "1" ]; then
      sleep 0.1
      continue
    fi

    control_state="$(probe_control_liveness)"
    if [ "$control_state" = "up" ]; then
      return 0
    fi

    sleep 0.1
  done

  if [ "$require_control" = "1" ]; then
    # A live session at this point means the BEAM never died -- we ran out of
    # patience, not the daemon out of health. Saying so is the difference
    # between "your release is broken" and "give it longer", and the empty
    # capture below is evidence of the latter, not of a silent crash.
    if "$tmux_bin" -L "$socket" -f "$conf" has-session -t "$session" 2>/dev/null; then
      echo "❌ aiur control plane at ${RELEASE_NODE:-unknown} was still booting after $(awk "BEGIN{printf \"%.0f\", ${max_ticks} / 10}")s; the BEAM is alive but not yet answering." >&2
      echo "   Raise the budget with AIUR_NODE_GRACE_TICKS (ticks of 0.1s) if this box is just slow." >&2
    else
      echo "❌ aiur control plane did not become ready at ${RELEASE_NODE:-unknown} during startup; captured output:" >&2
    fi
    tail -n 30 "$startup_capture" 2>/dev/null | sed 's/^/  /' >&2 || true
    return 1
  fi

  return 0
}

# Foreground teardown: kill the session + BEAM and reap opencode sessions on exit.
_session_socket="" _session_name="" _session_conf="" _session_tmpfile=""
_session_capture="" _session_argv="" _session_release="" _session_tmux="" _session_node=""
_session_pidfile="" _session_watchdog_pid="" _session_workspace_root_file=""
_session_alert_ledger_path_file="" _session_crash_dump_baseline_file="" _session_launch_lock=""
_cleanup_ran=0
session_cleanup() {
  [ "$_cleanup_ran" = 1 ] && return 0
  _cleanup_ran=1
  local code=$?

  # Stop the BEAM-death watchdog: cleanup is running, so it has no work left and
  # a lingering poller would outlive this teardown.
  [ -n "$_session_watchdog_pid" ] && kill "$_session_watchdog_pid" 2>/dev/null || true

  # kill-session on the detached aiur session FIRST: this is what propagates
  # SIGHUP to the BEAM in that session so it begins its own orderly shutdown.
  # Without it the BEAM survives Ctrl+C, holding port 4000 + the node name and
  # breaking the next launch (regression test/aiur/regression/shutdown_cleanup_test.exs).
  if [ -n "$_session_tmux" ] && [ -n "$_session_socket" ] && [ -n "$_session_name" ]; then
    "$_session_tmux" -L "$_session_socket" kill-session -t "$_session_name" 2>/dev/null || true
  fi

  # Then kill-server on aiur's private socket: tears down every pane agent across
  # all windows AND leaves no live aiur tmux server, then reaps headless agents
  # from the pidfile. Idempotent with the watchdog's own reap and the kill-session
  # above. reap_aiur_agents re-resolves tmux itself and reaps headless agents even
  # when tmux is absent, so it is not gated on $_session_tmux.
  reap_aiur_agents "$_session_socket" "$_session_pidfile"

  # Reap only this instance's BEAM. Multiple keyed instances can share the same
  # release dir, so release-path pgrep would terminate sibling workflows. Give
  # the BEAM a generous TERM grace (the stop grace, not the 3s startup reclaim
  # default) so its own graceful shutdown — ProcessReaper reaping the agent tree
  # plus the BEAM-side workspace sweep — completes before any SIGKILL lands.
  [ -n "$_session_node" ] && kill_beams_matching "-name ${_session_node}" 300

  # Final cwd-sweep backstop after the BEAM is gone: catches workspace-rooted
  # agents or test children that registered too late, reparented during the
  # BEAM-side sweep, or survived a bounded in-BEAM cleanup.
  reap_workspace_cwd_from_file "$_session_workspace_root_file"

  # Reap the epmd our BEAM spawned for distribution so it doesn't linger after
  # exit. The node is dead by now, so `epmd -kill` succeeds; it safely refuses
  # while any *other* Erlang node is alive, so a daemon shared with an unrelated
  # Erlang program is never disrupted. Use the release's bundled epmd and pin it
  # to the loopback address aiur starts it on.
  for _epmd in "$_session_release"/erts-*/bin/epmd; do
    [ -x "$_epmd" ] || continue
    ERL_EPMD_ADDRESS="${ERL_EPMD_ADDRESS:-127.0.0.1}" "$_epmd" -kill >/dev/null 2>&1 || true
  done

  if command -v opencode >/dev/null 2>&1 && [ -s "$_session_tmpfile" ]; then
    local id
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      opencode session delete "$id" >/dev/null 2>&1 &
    done <"$_session_tmpfile"
    wait 2>/dev/null || true
  fi

  # Reap agent-driver sockets this run orphaned at close, not next launch.
  sweep_dead_tmux_sockets || true

  # Reap stale aiur /tmp debris (per-run tempfiles, leaked test artifacts) so a
  # tmpfs /tmp can't fill across runs. Age-gated + pid-safe; our own still-present
  # tempfiles are spared (fresh + live pid) before the explicit rm below clears them.
  sweep_stale_tmp_artifacts || true

  rm -f "$_session_tmpfile" "$_session_capture" "$_session_argv" "$_session_pidfile" \
    "$_session_workspace_root_file" "$_session_alert_ledger_path_file" \
    "$_session_crash_dump_baseline_file" 2>/dev/null || true
  rm -f "$(aiur_instance_record_path)" 2>/dev/null || true
  release_aiur_launch_lock "$_session_launch_lock"
  _session_launch_lock=""
  return $code
}
install_foreground_traps() {
  trap 'session_cleanup' EXIT
  trap 'trap - EXIT INT TERM HUP; session_cleanup; exit 130' INT
  trap 'trap - EXIT INT TERM HUP; session_cleanup; exit 143' TERM
  trap 'trap - EXIT INT TERM HUP; session_cleanup; exit 129' HUP
}
