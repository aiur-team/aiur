# Foreground container launch without tmux.

run_session_container() {
  local mode=container no_dashboard=0 surface_mode=headless
  local session socket
  local conf="" launch_lock startup_capture="" supervisor_file="" crash_dump_baseline_file=""
  local launcher="" inner_cmd="" launch_tempfiles=() status=0 child=""

  validate_container_options "$@"
  export AIUR_CONTAINER=1
  aiur_resolve_identity
  session="${AIUR_SESSION_PREFIX}-${USER:-user}${AIUR_INSTANCE_KEY:+-$AIUR_INSTANCE_KEY}-container"
  socket="${AIUR_SESSION_PREFIX}-${USER:-user}${AIUR_INSTANCE_KEY:+-$AIUR_INSTANCE_KEY}"
  prepare_distribution
  launch_lock="$(aiur_launch_lock_path)"
  acquire_aiur_launch_lock "$launch_lock" || return 1

  local control_state node_state
  control_state="$(probe_control_liveness)"
  node_state="$(probe_node_liveness)"
  if [ "$control_state" = "up" ] || [ "$node_state" = "up" ]; then
    echo "aiur container cannot start: node ${AIUR_RELEASE_NODE} is ${node_state} (control plane ${control_state}); leaving it untouched" >&2
    release_aiur_launch_lock "$launch_lock"
    return 1
  fi
  if [ "$node_state" = "unknown" ] && pgrep -f -- "-name ${AIUR_RELEASE_NODE}" >/dev/null 2>&1; then
    echo "aiur container cannot start: node ${AIUR_RELEASE_NODE} is unknown (control plane ${control_state}; a process still holds its name); leaving it untouched" >&2
    release_aiur_launch_lock "$launch_lock"
    return 1
  fi

  run_session_prepare_env "$@"
  run_session_write_pane_launcher
  # EPMD-down confirms an orphan can be reclaimed. When EPMD is unreachable,
  # the exact-name process probe above distinguishes a fresh node from a holder.
  if [ "$node_state" = "down" ]; then
    kill_beams_matching "-name ${AIUR_RELEASE_NODE}"
  fi
  sweep_stale_tmp_artifacts || true
  sweep_orphan_test_private_dirs || true

  set_container_cleanup_context "$session" "$socket" "$launch_lock"
  trap 'session_cleanup' EXIT
  trap 'container_shutdown' TERM INT HUP
  start_container_daemon
  wait_container_startup || { status=$?; return "$status"; }
  mark_container_ready "$session" "$socket" "$launch_lock"
  if wait "$child"; then status=0; else status=$?; fi
  child=""
  return "$status"
}

validate_container_options() {
  local run_arg
  for run_arg in "$@"; do
    case "$run_arg" in
      --interactive) die "--container cannot be combined with --interactive" ;;
      --no-dashboard) die "--container always keeps the dashboard; remove --no-dashboard" ;;
    esac
  done
}

wait_container_startup() {
  local tick control_state child_state startup_limit="${AIUR_NODE_GRACE_TICKS:-1200}"
  for ((tick = 0; tick < startup_limit; tick++)); do
    control_state="$(probe_control_liveness)"
    [ "$control_state" != "up" ] || return 0
    child_state="$(ps -o stat= -p "$child" 2>/dev/null || true)"
    if ! container_child_alive "$child" "$child_state"; then
      container_start_failed
      return $?
    fi
    sleep 0.1
  done
  stop_container_after_startup_timeout "$child" "$startup_limit"
}

container_child_alive() {
  local pid="$1" state="$2"
  kill -0 "$pid" 2>/dev/null || return 1
  [[ "$state" != *Z* ]]
}

container_start_failed() {
  local status
  if wait "$child"; then status=0; else status=$?; fi
  child=""
  echo "aiur container daemon exited during startup (exit $status); captured output:" >&2
  tail -n 30 "$startup_capture" >&2 || true
  [ "$status" -ne 0 ] || status=1
  return "$status"
}

stop_container_after_startup_timeout() {
  local child_pid="$1" startup_limit="$2"
  echo "aiur container daemon did not become ready within $(awk "BEGIN{printf \"%.0f\", ${startup_limit} / 10}")s" >&2
  kill -TERM "$child_pid" 2>/dev/null || true
  wait "$child_pid" || true
  child=""
  return 1
}

set_container_cleanup_context() {
  local session="$1" socket="$2" launch_lock="$3"
  _session_socket="$socket" _session_name="$session" _session_conf="" \
    _session_tmpfile="$AIUR_SESSION_TMPFILE" _session_capture="$startup_capture" \
    _session_argv="$argv_file" _session_release="$release_dir" _session_tmux="" \
    _session_node="$AIUR_RELEASE_NODE" _session_pidfile="$AIUR_AGENT_TMPFILE" \
    _session_workspace_root_file="$AIUR_WORKSPACE_ROOT_FILE" \
    _session_alert_ledger_path_file="$AIUR_ALERT_LEDGER_PATH_FILE" \
    _session_crash_dump_baseline_file="$crash_dump_baseline_file" \
    _session_launch_lock="$launch_lock"
  _session_keep_capture=1
}

start_container_daemon() {
  mkdir -p "$(dirname "$startup_capture")"
  : >"$startup_capture"
  rm -f "$(aiur_stop_sentinel_path)" "$(aiur_crash_marker_path)" 2>/dev/null || true
  exec > >(tee -a "$startup_capture") 2>&1
  "${release_cmd[@]}" &
  child=$!
}

mark_container_ready() {
  local session="$1" socket="$2" launch_lock="$3"
  printf 'ready\n' >"$supervisor_file"
  write_aiur_instance_record "$session" "$socket" replace headless
  release_aiur_launch_lock "$launch_lock"
  _session_launch_lock=""
  print_config_status "$startup_capture"
  print_dashboard_status "$no_dashboard" "$startup_capture"
  maybe_surface_upgrade_notice || true
}

container_shutdown() {
  trap - TERM INT HUP
  local status=0
  if [ -n "${child:-}" ]; then
    kill -TERM "$child" 2>/dev/null || true
    wait_container_child_shutdown "$child"
    child=""
  fi
  session_cleanup
  exit "$status"
}

wait_container_child_shutdown() {
  local pid="$1" tick child_state grace_ticks="${AIUR_CONTAINER_STOP_GRACE_TICKS:-300}"
  for ((tick = 0; tick < grace_ticks; tick++)); do
    child_state="$(ps -o stat= -p "$pid" 2>/dev/null || true)"
    if ! kill -0 "$pid" 2>/dev/null || [[ "$child_state" == *Z* ]]; then
      wait "$pid" 2>/dev/null || return 0
      return 0
    fi
    sleep 0.1
  done

  echo "aiur container daemon did not stop within $(awk "BEGIN{printf \"%.0f\", ${grace_ticks} / 10}")s; sending SIGKILL" >&2
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 0
}
