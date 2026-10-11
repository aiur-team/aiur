# Instance records, the launch lock, crash markers and crash-dump alerts. Sourced by aiur-engine.sh.

# Stable, per-instance state paths the background BEAM-death machinery shares
# across `run`, `stop`, and `status`. Keyed by the (instance-keyed) release node
# rather than the tmux socket so `status` — which resolves the node but not the
# socket — agrees on the same files. AIUR_BG_STATE_DIR and AIUR_RELEASE_NODE are
# resolved by aiur_resolve_identity, which every one of those paths calls first.
aiur_state_slug() {
  printf '%s' "${AIUR_RELEASE_NODE:-aiur}" | tr -c 'A-Za-z0-9._-' '_'
}

aiur_instances_dir() {
  printf '%s/instances' "${AIUR_BG_STATE_DIR:?}"
}

aiur_instance_record_path() {
  printf '%s/%s.instance' "$(aiur_instances_dir)" "$(aiur_state_slug)"
}

aiur_launch_lock_path() {
  printf '%s/locks/%s.launch' "${AIUR_BG_STATE_DIR:?}" "$(aiur_state_slug)"
}

acquire_aiur_launch_lock() {
  local lock="$1" owner_file="$1/owner" recovery_lock="$1.recovery"
  local owner tick lock_age
  local max_ticks="${AIUR_LAUNCH_LOCK_TICKS:-${AIUR_NODE_GRACE_TICKS:-1200}}"
  local ownerless_stale_seconds="${AIUR_OWNERLESS_LOCK_STALE_SECONDS:-120}"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || return 1

  for ((tick = 0; tick < max_ticks; tick++)); do
    if mkdir "$lock" 2>/dev/null; then
      printf '%s\n' "$$" >"$owner_file" || { rmdir "$lock" 2>/dev/null || true; return 1; }
      return 0
    fi

    owner="$(sed -n '1p' "$owner_file" 2>/dev/null || true)"
    if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
      sleep 0.1
      continue
    fi

    lock_age="$(aiur_lock_age_seconds "$lock")"
    if [ -z "$owner" ] && { [ -z "$lock_age" ] || [ "$lock_age" -lt "$ownerless_stale_seconds" ]; }; then
      sleep 0.1
      continue
    fi

    # Only one contender may reclaim a dead lock. Re-read ownership while the
    # recovery mutex is held so another contender cannot delete a newly claimed
    # launch directory after losing the original stale-lock race.
    if mkdir "$recovery_lock" 2>/dev/null; then
      owner="$(sed -n '1p' "$owner_file" 2>/dev/null || true)"
      lock_age="$(aiur_lock_age_seconds "$lock")"
      if { [ -z "$owner" ] && [ -n "$lock_age" ] && [ "$lock_age" -ge "$ownerless_stale_seconds" ]; } || \
        { [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; }; then
        rm -f "$owner_file" 2>/dev/null || true
        rmdir "$lock" 2>/dev/null || true
      fi
      rmdir "$recovery_lock" 2>/dev/null || true
    fi
    sleep 0.1
  done

  echo "aiur: another launch for this directory is still in progress; retry aiur" >&2
  return 1
}

aiur_lock_age_seconds() {
  local path="$1" now modified
  now="$(date +%s 2>/dev/null || true)"
  modified="$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null || true)"
  [[ "$now" =~ ^[0-9]+$ ]] && [[ "$modified" =~ ^[0-9]+$ ]] || return 0
  [ "$now" -ge "$modified" ] || return 0
  printf '%s' "$((now - modified))"
}

release_aiur_launch_lock() {
  local lock="${1:-}" owner_file owner
  [ -n "$lock" ] || return 0
  owner_file="$lock/owner"
  owner="$(sed -n '1p' "$owner_file" 2>/dev/null || true)"
  [ "$owner" = "$$" ] || return 0
  rm -f "$owner_file" 2>/dev/null || true
  rmdir "$lock" 2>/dev/null || true
}

write_aiur_instance_record() {
  local session="$1" socket="$2" write_mode="${3:-replace}" surface_mode="${4:-unknown}" record_dir record tmp root
  record_dir="$(aiur_instances_dir)"
  record="$(aiur_instance_record_path)"
  root="$(canonical_workspace_root "${AIUR_PROJECT_ROOT:-}")"
  mkdir -p "$record_dir" 2>/dev/null || return 0
  tmp="$(mktemp "$record_dir/.${AIUR_INSTANCE_KEY:-aiur}.XXXXXX" 2>/dev/null)" || return 0
  {
    printf 'AIUR_RECORD_NODE=%q\n' "$AIUR_RELEASE_NODE"
    printf 'AIUR_RECORD_INSTANCE_KEY=%q\n' "$AIUR_INSTANCE_KEY"
    printf 'AIUR_RECORD_SESSION=%q\n' "$session"
    printf 'AIUR_RECORD_SOCKET=%q\n' "$socket"
    printf 'AIUR_RECORD_AGENT_TMPFILE=%q\n' "${AIUR_AGENT_TMPFILE:-}"
    printf 'AIUR_RECORD_SURFACE_MODE=%q\n' "$surface_mode"
    printf 'AIUR_RECORD_WORKSPACE_ROOT_FILE=%q\n' "${AIUR_WORKSPACE_ROOT_FILE:-}"
    printf 'AIUR_RECORD_PROJECT_ROOT=%q\n' "$root"
    printf 'AIUR_RECORD_PROJECT_ROOT_SOURCE=%q\n' "${AIUR_PROJECT_ROOT_SOURCE:-}"
    printf 'AIUR_RECORD_WRITTEN_AT=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  } >"$tmp" || { rm -f "$tmp" 2>/dev/null || true; return 0; }
  chmod 0600 "$tmp" 2>/dev/null || true
  if [ "$write_mode" = "if-absent" ]; then
    # Same-directory hard-link creation is atomic: a concurrent live launcher
    # can win without an attaching shell overwriting its workspace handoff.
    ln "$tmp" "$record" 2>/dev/null || true
    rm -f "$tmp" 2>/dev/null || true
  else
    mv "$tmp" "$record" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  fi
}

# Marker `status` reads to tell "daemon crashed, agents may be orphaned" apart
# from "nothing was ever running". Written by the watchdog on an unexpected exit,
# cleared on a clean stop and on the next successful background start.
aiur_crash_marker_path() {
  printf '%s/%s.last-crash' "${AIUR_BG_STATE_DIR:?}" "$(aiur_state_slug)"
}

# Sentinel `stop` drops before killing the BEAM so the watchdog knows the exit
# was intentional and does not record a false crash.
aiur_stop_sentinel_path() {
  printf '%s/%s.stopping' "${AIUR_BG_STATE_DIR:?}" "$(aiur_state_slug)"
}

json_escape_alert_field() {
  LC_ALL=C printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

crash_dump_identity() {
  local dump_path="${1:-}"
  [ -n "$dump_path" ] && [ -f "$dump_path" ] || return 0
  # Constant-time and replacement-sensitive. GNU stat supplies nanosecond
  # timestamps; BSD/macOS stat still includes device + inode, so an atomic
  # replacement with byte-identical contents cannot match the launch baseline.
  stat -Lc '%d:%i:%s:%y:%z' "$dump_path" 2>/dev/null || \
    stat -f '%d:%i:%z:%m:%c:%B' "$dump_path" 2>/dev/null || true
}

new_completed_crash_dump_slogan() {
  local dump_path="${1:-}" baseline_file="${2:-}" baseline="" current_identity="" slogan=""
  [ -n "$baseline_file" ] && [ -r "$baseline_file" ] && IFS= read -r baseline <"$baseline_file" || true
  current_identity="$(crash_dump_identity "$dump_path")"
  [ -n "$current_identity" ] && [ "$current_identity" != "$baseline" ] || return 0
  tail -n 1 "$dump_path" 2>/dev/null | grep -q '^=end$' || return 0
  slogan="$(LC_ALL=C awk '/^Slogan: / { sub(/^Slogan: /, ""); print substr($0, 1, 512); exit }' "$dump_path" 2>/dev/null || true)"
  LC_ALL=C printf '%s' "$slogan" | tr -d '\000-\037'
}

write_crash_dump_alert() {
  local ledger_path_file="$1" timestamp="$2" dump_path="$3" slogan="$4" ledger_path=""
  local escaped_timestamp escaped_path escaped_slogan escaped_message escaped_reason
  [ -n "$ledger_path_file" ] && [ -s "$ledger_path_file" ] || return 0
  # File.write/2 handoffs are valid without a trailing newline. `read` returns
  # nonzero at EOF in that case but still assigns the complete path.
  IFS= read -r ledger_path <"$ledger_path_file" || true
  [ -n "$ledger_path" ] || return 0

  escaped_timestamp="$(json_escape_alert_field "$timestamp")"
  escaped_path="$(json_escape_alert_field "$dump_path")"
  escaped_slogan="$(json_escape_alert_field "$slogan")"
  escaped_message="$(json_escape_alert_field "BEAM crash dump: $slogan")"
  escaped_reason="$(json_escape_alert_field "Unexpected daemon exit wrote $dump_path")"

  mkdir -p "$(dirname "$ledger_path")" 2>/dev/null || return 0
  printf '{"event":"alert","agent":"system","timestamp":"%s","name":"system.beam.crash_dump","topic":"system.beam.crash_dump","message":"%s","reason":"%s","severity":"warning","needs_attention":true,"dump_path":"%s","slogan":"%s"}\n' \
    "$escaped_timestamp" "$escaped_message" "$escaped_reason" "$escaped_path" "$escaped_slogan" \
    >>"$ledger_path" 2>/dev/null || true
}

record_new_crash_dump_alert() {
  local ledger_path_file="${1:-}" baseline_file="${2:-}" crash_dump_path="${ERL_CRASH_DUMP:-}"
  local crash_dump_slogan="" ts=""
  crash_dump_slogan="$(new_completed_crash_dump_slogan "$crash_dump_path" "$baseline_file")"
  [ -n "$crash_dump_slogan" ] || return 0
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  write_crash_dump_alert "$ledger_path_file" "${ts:-unknown}" "$crash_dump_path" "$crash_dump_slogan"
}

# Write a durable record that the background BEAM exited unexpectedly. Two sinks:
# the run log dir (full record next to aiur.log, for forensics) and the stable
# per-instance marker (for `status` to surface). Best-effort throughout — this
# runs in the disowned watchdog after the BEAM is already gone, so it must never
# fail loudly or block the reap that follows.
record_beam_crash() {
  local node="$1" run_log_dir="$2" marker="$3" ledger_path_file="${4:-}" baseline_file="${5:-}"
  local ts boot_tail="" crash_dump_path="" crash_dump_slogan=""
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  if [ -n "$run_log_dir" ] && [ -r "$run_log_dir/log/boot.out.log" ]; then
    boot_tail="$(tail -n 20 "$run_log_dir/log/boot.out.log" 2>/dev/null || true)"
  fi
  crash_dump_path="${ERL_CRASH_DUMP:-}"
  crash_dump_slogan="$(new_completed_crash_dump_slogan "$crash_dump_path" "$baseline_file")"

  local body
  body="$(
    printf 'aiur background BEAM exited unexpectedly\n'
    printf 'timestamp: %s\n' "${ts:-unknown}"
    printf 'node: %s\n' "${node:-unknown}"
    printf 'run_log_dir: %s\n' "${run_log_dir:-unknown}"
    printf 'detected_by: background BEAM-death watchdog (no clean stop sentinel)\n'
    if [ -n "$crash_dump_slogan" ]; then
      printf 'crash_dump_path: %s\n' "$crash_dump_path"
      printf 'crash_dump_slogan: %s\n' "$crash_dump_slogan"
    fi
    if [ -n "$boot_tail" ]; then
      printf -- '--- last 20 lines of boot.out.log ---\n%s\n' "$boot_tail"
    fi
  )"

  if [ -n "$run_log_dir" ]; then
    mkdir -p "$run_log_dir/log" 2>/dev/null || true
    printf '%s\n' "$body" >>"$run_log_dir/log/aiur.crash" 2>/dev/null || true
  fi
  if [ -n "$marker" ]; then
    printf '%s\n' "$body" >"$marker" 2>/dev/null || true
  fi
  if [ -n "$crash_dump_slogan" ]; then
    write_crash_dump_alert "$ledger_path_file" "${ts:-unknown}" "$crash_dump_path" "$crash_dump_slogan"
  fi
}
