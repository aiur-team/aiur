# Startup rollback helpers for `aiur restart`. Sourced by aiur-engine.sh.

restart_first_error_line() {
  local capture="$1" line
  line="$(awk 'NF { sub(/^[[:space:]]+/, ""); print; exit }' "$capture" 2>/dev/null || true)"
  [ -n "$line" ] || line="startup exited before the daemon became ready"
  printf '%s' "$line"
}

record_restart_rollback_alert() {
  local message="$1" ledger_path="${2:-}" timestamp
  if [ -z "$ledger_path" ] && [ -n "${AIUR_ALERT_LEDGER_PATH_FILE:-}" ] && [ -r "$AIUR_ALERT_LEDGER_PATH_FILE" ]; then
    IFS= read -r ledger_path <"$AIUR_ALERT_LEDGER_PATH_FILE" || true
  fi
  [ -n "$ledger_path" ] || return 0
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf unknown)"
  mkdir -p "$(dirname "$ledger_path")" 2>/dev/null || return 0
  printf '{"event":"alert","agent":"system","timestamp":"%s","name":"system.restart.rollback","topic":"system.restart.rollback","message":"%s","reason":"The refreshed release failed during startup; the previous release was restored","severity":"critical","needs_attention":true}\n' \
    "$timestamp" "$(json_escape_alert_field "$message")" >>"$ledger_path" 2>/dev/null || true
}

rollback_restart_release() {
  local previous_sha="$1" first_error="$2" failed_release="${AIUR_RELEASE_DIR:-}"
  [ -n "$aiur_restart_previous_release" ] && [ -x "$aiur_restart_previous_release/bin/aiur" ] || return 1
  AIUR_RESTART_HANDOFF_ID="${aiur_restart_handoff_id:-${AIUR_RESTART_HANDOFF_ID:-}}"
  AIUR_RELEASE_DIR="$aiur_restart_previous_release"
  export AIUR_RELEASE_DIR AIUR_RESTART_HANDOFF_ID
  local rollback_status=0
  dispatch_run --bg "${run_args[@]+"${run_args[@]}"}" || rollback_status=$?
  if [ "$rollback_status" -ne 0 ]; then
    AIUR_RELEASE_DIR="$failed_release"
    export AIUR_RELEASE_DIR
    return "$rollback_status"
  fi
  printf 'aiur: rolled back to %s: new release failed with %s\n' "$previous_sha" "$first_error" >&2
  AIUR_RELEASE_DIR="$failed_release"
  export AIUR_RELEASE_DIR
  return 0
}

restart_release_snapshot() {
  local release_dir="$1" source_sha
  [ -n "$release_dir" ] && [ -d "$release_dir" ] || return 0
  source_sha="$(sed -n 's/^source_sha=//p' "$release_dir/AIUR_BUILD_STAMP" 2>/dev/null | head -n 1)"
  RESTART_PREVIOUS_SHA="${source_sha:-unknown}"
  RESTART_SNAPSHOT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiur-previous-release.XXXXXX")" || return 1
  if ! cp -a "$release_dir/." "$RESTART_SNAPSHOT_DIR/"; then
    rm -rf "$RESTART_SNAPSHOT_DIR"
    RESTART_SNAPSHOT_DIR=""
    return 1
  fi
  aiur_restart_previous_release="$RESTART_SNAPSHOT_DIR"
}

restart_after_start_attempt() {
  local status="$1" capture="$2" previous_sha="$3" snapshot_dir="$4" keep_agents="$5" first_error
  if [ "$status" -eq 0 ]; then
    aiur_restart_daemon_state="running"
    trap - EXIT INT TERM
    [ -n "$snapshot_dir" ] && rm -rf "$snapshot_dir"
    [ "$keep_agents" -eq 0 ] || report_restart_handoff
    return 0
  fi

  if [ -z "$snapshot_dir" ]; then return "$status"; fi
  first_error="$(restart_first_error_line "$capture")"
  local failed_ledger_file="${AIUR_ALERT_LEDGER_PATH_FILE:-}" failed_ledger_path=""
  if [ -r "$failed_ledger_file" ]; then IFS= read -r failed_ledger_path <"$failed_ledger_file" || true; fi
  AIUR_RESTART_HANDOFF_ID="${aiur_restart_handoff_id:-${AIUR_RESTART_HANDOFF_ID:-}}"
  export AIUR_RESTART_HANDOFF_ID
  echo "aiur: new release failed during startup; attempting rollback to $previous_sha" >&2
  if ! rollback_restart_release "$previous_sha" "$first_error"; then
    echo "aiur: rollback to $previous_sha failed; the daemon remains stopped" >&2
    return "$status"
  fi
  AIUR_RESTART_HANDOFF_ID="${aiur_restart_handoff_id:-${AIUR_RESTART_HANDOFF_ID:-}}"
  aiur_restart_daemon_state="running"
  trap - EXIT INT TERM
  rm -rf "$snapshot_dir"
  record_restart_rollback_alert "rolled back to $previous_sha: new release failed with $first_error" "$failed_ledger_path"
  [ "$keep_agents" -eq 0 ] || report_restart_handoff
}
