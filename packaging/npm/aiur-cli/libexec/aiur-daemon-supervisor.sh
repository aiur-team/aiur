#!/usr/bin/env bash
# Sourced by the shared engine and the daemon pane.

supervisor_is_alive() {
  local file="${1:-}" pid=""
  [ -n "$file" ] && [ -r "$file" ] || return 1
  IFS= read -r pid <"$file" || true
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null
}

record_daemon_recovery() {
  local name="$1" message="$2" since="$3" quiet="${4:-}" ledger="" timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s %s; down since %s\n' "$timestamp" "$message" "$since" >>"$AIUR_LOGS_ROOT/log/aiur.recovery"
  [ -z "$quiet" ] || return 0
  IFS= read -r ledger <"$AIUR_ALERT_LEDGER_PATH_FILE" || true
  [ -n "$ledger" ] || return 0
  mkdir -p "$(dirname "$ledger")"
  printf '{"event":"alert","agent":"system","timestamp":"%s","name":"system.daemon.%s","topic":"system.daemon.%s","message":"%s","reason":"Daemon down since %s","severity":"warning","needs_attention":true}\n' \
    "$timestamp" "$name" "$name" "$(json_escape_alert_field "$message")" "$since" >>"$ledger"
}

supervise_daemon() {
  local supervisor_file="$1" capture="$2" baseline="$3"
  shift 3
  local status delay=1 started down_since="" child pane prev_dump giving_up crashes=() now t kept first_dump
  local max_crashes="${AIUR_DAEMON_MAX_RESTARTS:-5}" crash_window=600
  printf '%s\n' "$$" >"$supervisor_file"
  release_bin="$AIUR_RELEASE_DIR/bin/aiur"
  mkdir -p "$AIUR_LOGS_ROOT/log"
  exec 3<&0
  while :; do
    started="$SECONDS"
    (set +e; "$@" 2>&1 | tee -a "$capture"; exit "${PIPESTATUS[0]}") <&3 &
    child=$!
    if [ -n "$down_since" ]; then
      # Bound readiness probes; a boot attempt is not evidence of recovery.
      while kill -0 "$child" 2>/dev/null; do
        if run_release_rpc_with_timeout 'if Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :aiur end), do: IO.puts("__AIUR_RECOVERED__")' &&
          [[ "$AIUR_CONTROL_RPC_OUTPUT" == *"__AIUR_RECOVERED__"* ]]; then
          record_daemon_recovery restarted 'Daemon restarted after crash' "$down_since"
          rm -f "$(aiur_crash_marker_path)"
          down_since=""
          break
        fi
        sleep 1
      done
    fi
    if wait "$child"; then status=0; else status=$?; fi
    # Initial boot failures stay visible to the launcher; normal halts stay stopped.
    if [ "$status" -eq 0 ] || [ -f "$(aiur_stop_sentinel_path)" ] || ! grep -qx ready "$supervisor_file"; then
      rm -f "$supervisor_file"
      return "$status"
    fi
    # One needs-attention alert per outage; later attempts only reach the recovery log.
    local quiet=1
    [ -n "$down_since" ] || { down_since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; quiet=""; }
    record_beam_crash "$RELEASE_NODE" "$AIUR_LOGS_ROOT" "$(aiur_crash_marker_path)" "$AIUR_ALERT_LEDGER_PATH_FILE" "$baseline"
    now="$SECONDS"; kept=()
    for t in "${crashes[@]}"; do [ "$((now - t))" -ge "$crash_window" ] || kept+=("$t"); done
    crashes=("${kept[@]}" "$now")
    giving_up=""
    [ "${#crashes[@]}" -le "$max_crashes" ] || giving_up=1
    if [ -n "$giving_up" ]; then
      record_daemon_recovery gave-up "Daemon crashed ${#crashes[@]} times within ${crash_window}s; not restarting" "$down_since"
    else
      record_daemon_recovery down "Daemon down; retrying in ${delay}s (exit $status)" "$down_since" "$quiet"
    fi
    # Archive before another VM can overwrite even an operator-selected dump path.
    if [ -f "$ERL_CRASH_DUMP" ]; then
      mv "$ERL_CRASH_DUMP" "$ERL_CRASH_DUMP.$(date -u +%Y%m%dT%H%M%SZ).$$.$SECONDS" || return 1
      # Keep only the first and the latest dump; the middle ones are GBs of repeats.
      first_dump="" prev_dump=""
      for t in "$ERL_CRASH_DUMP".*; do
        [ -f "$t" ] || continue
        [ -n "$first_dump" ] || { first_dump="$t"; continue; }
        [ -z "$prev_dump" ] || rm -f "$prev_dump"
        prev_dump="$t"
      done
    fi
    [ -z "$giving_up" ] || { rm -f "$supervisor_file"; return "$status"; }
    crash_dump_identity "$ERL_CRASH_DUMP" >"$baseline" || :
    reap_aiur_agents "" "$AIUR_AGENT_TMPFILE"
    reap_workspace_cwd_from_file "$AIUR_WORKSPACE_ROOT_FILE"
    : >"$AIUR_AGENT_TMPFILE"
    # Keep this pane, remove the dead VM's UI/agent panes before rebuilding the UI.
    while IFS= read -r pane; do
      [ "$pane" = "${TMUX_PANE:-}" ] || tmux -L "$AIUR_TMUX_SOCKET" kill-pane -t "$pane" 2>/dev/null || true
    done < <(tmux -L "$AIUR_TMUX_SOCKET" list-panes -a -F '#{pane_id}' 2>/dev/null)
    [ "$((SECONDS - started))" -lt 60 ] || delay=1
    sleep "$delay"
    [ ! -f "$(aiur_stop_sentinel_path)" ] || { rm -f "$supervisor_file"; return 0; }
    [ "$delay" -ge 30 ] || delay=$((delay * 2))
    [ "$delay" -le 30 ] || delay=30
  done
}
