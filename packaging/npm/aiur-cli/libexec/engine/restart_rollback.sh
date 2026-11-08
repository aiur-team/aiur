# Startup rollback helpers for `aiur restart`. Sourced by aiur-engine.sh.
aiur_restart_previous_release=""
aiur_restart_snapshot_dir=""
aiur_restart_startup_capture_file=""
aiur_restart_alert_path_capture_file=""
aiur_restart_failed_release_backup=""

preserve_restart_failure_artifacts() {
  local startup_capture="$1" alert_path_file="$2"
  if [ -n "${AIUR_RESTART_STARTUP_CAPTURE:-}" ] && [ ! -s "$AIUR_RESTART_STARTUP_CAPTURE" ] && [ -r "$startup_capture" ]; then
    cp "$startup_capture" "$AIUR_RESTART_STARTUP_CAPTURE" 2>/dev/null || true
  fi
  if [ -n "${AIUR_RESTART_ALERT_PATH_CAPTURE:-}" ] && [ -r "$alert_path_file" ]; then
    cp "$alert_path_file" "$AIUR_RESTART_ALERT_PATH_CAPTURE" 2>/dev/null || true
  fi
}

aiur_restart_cleanup_artifacts() {
  [ -z "$aiur_restart_snapshot_dir" ] || rm -rf "$aiur_restart_snapshot_dir"
  [ -z "$aiur_restart_failed_release_backup" ] || rm -rf "$aiur_restart_failed_release_backup"
  [ -z "$aiur_restart_startup_capture_file" ] || rm -f "$aiur_restart_startup_capture_file"
  [ -z "$aiur_restart_alert_path_capture_file" ] || rm -f "$aiur_restart_alert_path_capture_file"
  aiur_restart_snapshot_dir=""
  aiur_restart_failed_release_backup=""
  aiur_restart_startup_capture_file=""
  aiur_restart_alert_path_capture_file=""
  unset AIUR_RESTART_STARTUP_CAPTURE AIUR_RESTART_ALERT_PATH_CAPTURE
}

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
  [ -n "$ledger_path" ] || return 1
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf unknown)"
  mkdir -p "$(dirname "$ledger_path")" 2>/dev/null || return 1
  printf '{"event":"alert","agent":"system","timestamp":"%s","name":"system.restart.rollback","topic":"system.restart.rollback","message":"%s","reason":"The refreshed release failed during startup; the previous release was restored","severity":"critical","needs_attention":true}\n' \
    "$timestamp" "$(json_escape_alert_field "$message")" >>"$ledger_path" 2>/dev/null
}

restore_restart_release_snapshot() {
  local release_dir="$1" snapshot_dir="$2" parent backup
  parent="$(dirname "$release_dir")"
  backup="$(mktemp -d "$parent/.aiur-failed-release.XXXXXX")" || return 1
  rmdir "$backup" || return 1
  if [ -e "$release_dir" ]; then
    mv "$release_dir" "$backup" || return 1
    aiur_restart_failed_release_backup="$backup"
  fi
  if ! mv "$snapshot_dir" "$release_dir"; then
    if [ -n "$aiur_restart_failed_release_backup" ]; then
      mv "$aiur_restart_failed_release_backup" "$release_dir" || true
      aiur_restart_failed_release_backup=""
    fi
    return 1
  fi
  aiur_restart_snapshot_dir=""
  aiur_restart_previous_release="$release_dir"
}

restore_failed_restart_release() {
  local release_dir="$1"
  [ -n "$aiur_restart_failed_release_backup" ] || return 0
  rm -rf "$release_dir"
  mv "$aiur_restart_failed_release_backup" "$release_dir" || return 1
  aiur_restart_failed_release_backup=""
}

rollback_restart_release() {
  local previous_sha="$1" first_error="$2" release_dir="${AIUR_RELEASE_DIR:-}" snapshot_dir="$3"
  [ -n "$aiur_restart_previous_release" ] && [ -x "$aiur_restart_previous_release/bin/aiur" ] || return 1
  restore_restart_release_snapshot "$release_dir" "$snapshot_dir" || return 1
  AIUR_RESTART_HANDOFF_ID="${aiur_restart_handoff_id:-${AIUR_RESTART_HANDOFF_ID:-}}"
  AIUR_RELEASE_DIR="$release_dir"
  export AIUR_RELEASE_DIR AIUR_RESTART_HANDOFF_ID
  local rollback_status=0
  aiur_restart_start_with_retry || rollback_status=$?
  if [ "$rollback_status" -ne 0 ]; then
    restore_failed_restart_release "$release_dir" || echo "aiur: could not restore the failed release directory after rollback failure" >&2
    AIUR_RELEASE_DIR="$release_dir"
    export AIUR_RELEASE_DIR
    return "$rollback_status"
  fi
  printf 'aiur: rolled back to %s: new release failed with %s\n' "$previous_sha" "$first_error" >&2
  AIUR_RELEASE_DIR="$release_dir"
  export AIUR_RELEASE_DIR
  return 0
}

restart_release_snapshot() {
  local release_dir="$1" source_sha
  RESTART_PREVIOUS_SHA="unknown"
  RESTART_SNAPSHOT_DIR=""
  [ -n "$release_dir" ] && [ -d "$release_dir" ] || return 0
  source_sha="$(sed -n 's/^source_sha=//p' "$release_dir/AIUR_BUILD_STAMP" 2>/dev/null | head -n 1)"
  RESTART_PREVIOUS_SHA="${source_sha:-unknown}"
  RESTART_SNAPSHOT_DIR="$(mktemp -d "$(dirname "$release_dir")/.aiur-previous-release.XXXXXX" 2>/dev/null)" ||
    RESTART_SNAPSHOT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiur-previous-release.XXXXXX")" || return 1
  if ! cp -a "$release_dir/." "$RESTART_SNAPSHOT_DIR/"; then
    rm -rf "$RESTART_SNAPSHOT_DIR"
    RESTART_SNAPSHOT_DIR=""
    return 1
  fi
  aiur_restart_previous_release="$RESTART_SNAPSHOT_DIR"
  aiur_restart_snapshot_dir="$RESTART_SNAPSHOT_DIR"
}

restart_after_start_attempt() {
  local status="$1" capture="$2" previous_sha="$3" snapshot_dir="$4" keep_agents="$5" first_error
  if [ "$status" -eq 0 ]; then
    aiur_restart_daemon_state="running"
    [ "$keep_agents" -eq 0 ] || report_restart_handoff
    aiur_restart_cleanup_artifacts
    trap - EXIT INT TERM
    return 0
  fi

  if [ -z "$snapshot_dir" ]; then return "$status"; fi
  first_error="$(restart_first_error_line "$capture")"
  AIUR_RESTART_HANDOFF_ID="${aiur_restart_handoff_id:-${AIUR_RESTART_HANDOFF_ID:-}}"
  export AIUR_RESTART_HANDOFF_ID
  echo "aiur: new release failed during startup; attempting rollback to $previous_sha" >&2
  if ! rollback_restart_release "$previous_sha" "$first_error" "$snapshot_dir"; then
    echo "aiur: rollback to $previous_sha failed; the daemon remains stopped" >&2
    return "$status"
  fi
  AIUR_RESTART_HANDOFF_ID="${aiur_restart_handoff_id:-${AIUR_RESTART_HANDOFF_ID:-}}"
  aiur_restart_daemon_state="running"
  local failed_ledger_path=""
  if [ -r "$aiur_restart_alert_path_capture_file" ]; then
    IFS= read -r failed_ledger_path <"$aiur_restart_alert_path_capture_file" || true
  fi
  if ! record_restart_rollback_alert "rolled back to $previous_sha: new release failed with $first_error" "$failed_ledger_path"; then
    echo "aiur: critical rollback alert could not be recorded because the alert ledger path is unavailable or unwritable" >&2
  fi
  [ "$keep_agents" -eq 0 ] || report_restart_handoff
  aiur_restart_cleanup_artifacts
  trap - EXIT INT TERM
}
