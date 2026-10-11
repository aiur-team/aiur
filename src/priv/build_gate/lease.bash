# Loaded by build_gate.bash. Phase state, slot and phase-lock reclaim, start pacing and the Linux lease holder handshake.
aiur_build_gate_publish_phase_state() {
  local gate_dir=$1 destination=$2 value=$3 candidate

  candidate=$(mktemp "$gate_dir/.phase-state-v2.XXXXXXXXXX" 2>/dev/null) || {
    aiur_build_gate_fail "phase_state_candidate_failed" "$gate_dir"
    return 125
  }

  if ! printf '%s\n' "$value" >"$candidate"; then
    rm -f "$candidate" 2>/dev/null || true
    aiur_build_gate_fail "phase_state_write_failed" "$destination"
    return 125
  fi

  aiur_build_gate_replace_regular \
    "$candidate" "$destination" "phase_state_not_regular" "phase_state_write_failed"
}

aiur_build_gate_reclaim_stale_slot() {
  local slot_path=$1 slot=$2 owner_file=$slot_path owner_pid owner_pgid

  [[ -e $slot_path || -L $slot_path ]] || return 1

  # Accept the original directory-plus-owner shape while new leases publish
  # one immutable owner record atomically at slot-N.
  if [[ -d $slot_path ]]; then
    owner_file="$slot_path/owner"
  fi

  owner_pid=$(aiur_build_gate_owner_pid "$owner_file")
  owner_pgid=$(aiur_build_gate_owner_pgid "$owner_file")

  if [[ -n $owner_pid ]]; then
    kill -0 "$owner_pid" 2>/dev/null && return 1
  fi

  # The wrapper can exit before a Mix descendant. Its recorded process group
  # remains authoritative until every member is gone.
  if [[ -n $owner_pgid ]] && aiur_build_gate_process_group_alive "$owner_pgid"; then
    return 1
  fi

  if rm -rf "$slot_path" 2>/dev/null; then
    aiur_build_gate_log "stale_owner_recovered slot=$slot owner_pid=${owner_pid:-unknown}"
    return 0
  fi

  return 1
}

aiur_build_gate_release_phase_lock() {
  local lock_path=$1

  if ! rm -rf "$lock_path" 2>/dev/null; then
    aiur_build_gate_fail "phase_lock_release_failed" "$lock_path"
    return 125
  fi
}

aiur_build_gate_reclaim_stale_phase_lock() {
  local lock_path=$1 owner_file=$lock_path owner_pid

  [[ -e $lock_path ]] || return 1

  # Older releases used a directory plus owner file. Accept that shape while
  # new locks publish one immutable owner record atomically via a hard link.
  if [[ -d $lock_path ]]; then
    owner_file="$lock_path/owner"
  fi

  owner_pid=$(aiur_build_gate_owner_pid "$owner_file")

  if [[ -n $owner_pid ]]; then
    kill -0 "$owner_pid" 2>/dev/null && return 1

    if rm -rf "$lock_path" 2>/dev/null; then
      aiur_build_gate_log "stale_phase_lock_recovered owner_pid=$owner_pid"
      return 0
    fi

    return 1
  fi

  if rm -rf "$lock_path" 2>/dev/null; then
    aiur_build_gate_log "stale_phase_lock_recovered owner_pid=unknown"
    return 0
  fi

  return 1
}

aiur_build_gate_wait_for_phase_start_pid() {
  local gate_dir=$1 phase=$2 stagger_seconds=$3 deadline=$4
  local lock_path="$gate_dir/phase-start.lock"
  local owner_pid=${BASHPID:-$$}
  local owner_candidate="$gate_dir/.phase-start-owner.$owner_pid.$RANDOM"
  local next_start_file="$gate_dir/phase-next-start"

  [[ $owner_pid =~ ^[1-9][0-9]*$ ]] || owner_pid=${BASHPID:-$$}
  local now next_start wait_seconds max_wait_seconds

  while :; do
    if ! printf 'pid=%s\nphase=%s\n' "$owner_pid" "$phase" >"$owner_candidate"; then
      aiur_build_gate_fail "phase_owner_write_failed" "$owner_candidate"
      return 125
    fi

    # The hard link makes lock ownership and its complete PID record visible
    # in one filesystem operation. A crash before the link leaves no lock; a
    # crash afterward leaves a reclaimable immutable owner record.
    if [[ ! -d $lock_path ]] && ln "$owner_candidate" "$lock_path" 2>/dev/null; then
      rm -f "$owner_candidate"
      break
    fi

    if aiur_build_gate_reclaim_stale_phase_lock "$lock_path"; then
      rm -f "$owner_candidate"
      continue
    fi

    # If no contender owns the path, retry once to distinguish a release
    # race from a filesystem that cannot publish the lock record.
    if [[ ! -e $lock_path ]] && ln "$owner_candidate" "$lock_path" 2>/dev/null; then
      rm -f "$owner_candidate"
      break
    fi

    if [[ ! -e $lock_path ]]; then
      rm -f "$owner_candidate"
      aiur_build_gate_fail "phase_lock_unavailable" "$lock_path"
      return 125
    fi

    rm -f "$owner_candidate"

    if ((SECONDS >= deadline)); then
      return 124
    fi

    sleep 1
  done

  if ! now=$(aiur_build_gate_now_seconds); then
    aiur_build_gate_release_phase_lock "$lock_path" || true
    aiur_build_gate_phase_clock_unavailable_log
    return 125
  fi

  wait_seconds=0
  next_start=""

  if next_start=$(aiur_build_gate_read_regular "$next_start_file"); then

    if [[ $next_start =~ ^(0|[1-9][0-9]*)$ ]]; then
      if ((next_start > now)); then
        wait_seconds=$((next_start - now))
        max_wait_seconds=$((stagger_seconds + 1))

        if ((wait_seconds > max_wait_seconds)); then
          aiur_build_gate_log "gate_error reason=phase_state_invalid path=$next_start_file"
          wait_seconds=0
        fi
      fi
    else
      aiur_build_gate_log "gate_error reason=phase_state_invalid path=$next_start_file"
    fi
  else
    local phase_state_result=$?

    if ((phase_state_result == 125)); then
      aiur_build_gate_release_phase_lock "$lock_path" || true
      return 125
    fi
  fi

  if ((wait_seconds > 0)); then
    aiur_build_gate_phase_hold_log "$phase" "$wait_seconds"
  fi

  while ((wait_seconds > 0)); do
    if ((SECONDS >= deadline)); then
      aiur_build_gate_release_phase_lock "$lock_path" || true
      return 124
    fi

    sleep 1

    if ! now=$(aiur_build_gate_now_seconds); then
      aiur_build_gate_release_phase_lock "$lock_path" || true
      aiur_build_gate_phase_clock_unavailable_log
      return 125
    fi

    wait_seconds=$((next_start > now ? next_start - now : 0))
  done

  if ! aiur_build_gate_publish_phase_state \
    "$gate_dir" "$next_start_file" "$((now + stagger_seconds + 1))"; then
    aiur_build_gate_release_phase_lock "$lock_path" || true
    return 125
  fi

  if ! aiur_build_gate_release_phase_lock "$lock_path"; then
    return 125
  fi

  return 0
}

aiur_build_gate_publish_owner_v2() {
  local gate_dir=$1 owner_path=$2 token=$3 phase=$4 owner_pid=$5 owner_pgid=$6 command=$7
  local holder_pid=${8:-0} command_pgid=${9:-0}
  local owner_candidate started_at

  started_at=$(aiur_build_gate_started_at)

  owner_candidate=$(mktemp "$gate_dir/.owner-v2.XXXXXXXXXX" 2>/dev/null) || {
    aiur_build_gate_fail "owner_candidate_failed" "$gate_dir"
    return 125
  }

  if ! printf \
    'version=2\ntoken=%s\npid=%s\npgid=%s\nholder_pid=%s\ncommand_pgid=%s\nphase=%s\ncommand=%s\nstarted_at=%s\n' \
    "$token" "$owner_pid" "$owner_pgid" "$holder_pid" "$command_pgid" "$phase" "$command" "$started_at" \
    >"$owner_candidate"; then
    rm -f "$owner_candidate" 2>/dev/null || true
    aiur_build_gate_fail "owner_write_failed" "$owner_path"
    return 125
  fi

  aiur_build_gate_replace_regular \
    "$owner_candidate" "$owner_path" "owner_destination_invalid" "owner_publish_failed"
}

aiur_build_gate_release_linux_owner() {
  local owner_path=$1

  if ! rm -f "$owner_path" 2>/dev/null; then
    aiur_build_gate_fail "owner_release_failed" "$owner_path"
    return 125
  fi
}

aiur_build_gate_hold_linux_lease() {
  local python_binary=$1 ready_path=$2 started_path=$3 command_pid_path=$4
  local command_ready_path=$5 status_path=$6 status_ack_path=$7 owner_path=$8 token=$9
  local parent_pid=${10} agent_pgid=${11} slot_fd=${12} handshake_seconds=${13} ack_seconds=${14}
  local holder_script
  shift 14

  # The subreaper owns the lease until every adopted descendant has exited.
  aiur_build_gate_priority_args "$@" || return $?
  holder_script="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/build_gate_holder.py"

  exec "$python_binary" "$holder_script" "$ready_path" "$started_path" "$command_pid_path" \
    "$command_ready_path" "$status_path" "$status_ack_path" "$owner_path" "$token" \
    "$parent_pid" "$agent_pgid" "$slot_fd" "$handshake_seconds" "$ack_seconds" "${aiur_build_gate_prioritized_command[@]}"
}

aiur_build_gate_wait_for_holder_value() {
  local path=$1 holder_pid=$2 expected_pattern=$3 deadline=$4 value result

  while ((SECONDS <= deadline)); do
    if value=$(aiur_build_gate_read_regular "$path" 2>/dev/null); then
      [[ $value =~ $expected_pattern ]] && return 0
    else
      result=$?
      ((result == 125)) && return 1
    fi
    kill -0 "$holder_pid" 2>/dev/null || break
    sleep 0.01
  done

  return 1
}

aiur_build_gate_stop_holder() {
  local holder_pid=$1 attempt

  kill -TERM "$holder_pid" 2>/dev/null || true

  # The holder gives a TERM-resistant command tree one second before SIGKILL.
  # Leave a second bounded margin so the parent never kills the holder first.
  for ((attempt = 0; attempt < 200; attempt++)); do
    kill -0 "$holder_pid" 2>/dev/null || break
    sleep 0.01
  done

  if kill -0 "$holder_pid" 2>/dev/null; then
    kill -KILL "$holder_pid" 2>/dev/null || true
  fi

  wait "$holder_pid" 2>/dev/null || true
}

aiur_build_gate_wait_for_command_status() {
  local status_path=$1 holder_pid=$2 status result

  while true; do
    if status=$(aiur_build_gate_read_regular "$status_path" 2>/dev/null) &&
      [[ $status =~ ^[0-9]+\ [01]$ ]]; then
      printf '%s\n' "$status"
      return 0
    else
      result=$?
      ((result == 125)) && return 1
    fi

    kill -0 "$holder_pid" 2>/dev/null || return 1
    sleep 0.01
  done

  return 1
}

aiur_build_gate_wait_for_phase_start_linux() {
  local gate_dir=$1 phase=$2 stagger_seconds=$3 deadline=$4
  local lock_path="${AIUR_BUILD_GATE_LOCK_DIR:-}/phase-start.lock"
  local owner_path="$gate_dir/phase-start.owner"
  local legacy_lock_path="$gate_dir/phase-start.lock"
  local owner_pid=${AIUR_BUILD_GATE_DIAGNOSTIC_PID:-${BASHPID:-$$}}
  local owner_pgid=${AIUR_BUILD_GATE_DIAGNOSTIC_PGID:-0}
  local token="${BASHPID:-$$}.$RANDOM.$RANDOM"
  local phase_fd lock_result now next_start wait_seconds max_wait_seconds
  local next_start_file="$gate_dir/phase-next-start"

  if [[ -e $legacy_lock_path || -L $legacy_lock_path ]]; then
    aiur_build_gate_fail "legacy_state_blocked" "$legacy_lock_path"
    return 125
  fi

  if ! exec {phase_fd}<"$lock_path"; then
    aiur_build_gate_fail "phase_lock_open_failed" "$lock_path"
    return 125
  fi

  while :; do
    if command flock -n -E 75 "$phase_fd"; then
      break
    else
      lock_result=$?
    fi

    if ((lock_result != 75)); then
      exec {phase_fd}>&-
      aiur_build_gate_fail "phase_lock_failed" "$lock_path"
      return 125
    fi

    if ((SECONDS >= deadline)); then
      exec {phase_fd}>&-
      return 124
    fi

    sleep 1
  done

  if ! aiur_build_gate_publish_owner_v2 \
    "$gate_dir" "$owner_path" "$token" "$phase" "$owner_pid" "$owner_pgid" "phase-start"; then
    exec {phase_fd}>&-
    return 125
  fi

  if ! now=$(aiur_build_gate_now_seconds); then
    aiur_build_gate_release_linux_owner "$owner_path" || true
    exec {phase_fd}>&-
    aiur_build_gate_log \
      "gate_error reason=phase_clock_unavailable status=125" \
      "recovery=repair_gate_or_disable_all_build_admission" \
      "disable=max_concurrent_builds_0,build_start_stagger_seconds_0,min_free_memory_mb_unset"
    return 125
  fi

  wait_seconds=0
  next_start=""

  if next_start=$(aiur_build_gate_read_regular "$next_start_file"); then

    if [[ $next_start =~ ^(0|[1-9][0-9]*)$ ]]; then
      if ((next_start > now)); then
        wait_seconds=$((next_start - now))
        max_wait_seconds=$((stagger_seconds + 1))

        if ((wait_seconds > max_wait_seconds)); then
          aiur_build_gate_log "gate_error reason=phase_state_invalid path=$next_start_file"
          wait_seconds=0
        fi
      fi
    else
      aiur_build_gate_log "gate_error reason=phase_state_invalid path=$next_start_file"
    fi
  else
    local phase_state_result=$?

    if ((phase_state_result == 125)); then
      aiur_build_gate_release_linux_owner "$owner_path" || true
      exec {phase_fd}>&-
      return 125
    fi
  fi

  if ((wait_seconds > 0)); then
    aiur_build_gate_phase_hold_log "$phase" "$wait_seconds"
  fi

  while ((wait_seconds > 0)); do
    if ((SECONDS >= deadline)); then
      aiur_build_gate_release_linux_owner "$owner_path" || true
      exec {phase_fd}>&-
      return 124
    fi

    sleep 1

    if ! now=$(aiur_build_gate_now_seconds); then
      aiur_build_gate_release_linux_owner "$owner_path" || true
      exec {phase_fd}>&-
      aiur_build_gate_log \
        "gate_error reason=phase_clock_unavailable status=125" \
        "recovery=repair_gate_or_disable_all_build_admission" \
        "disable=max_concurrent_builds_0,build_start_stagger_seconds_0,min_free_memory_mb_unset"
      return 125
    fi

    wait_seconds=$((next_start > now ? next_start - now : 0))
  done

  if ! aiur_build_gate_publish_phase_state \
    "$gate_dir" "$next_start_file" "$((now + stagger_seconds + 1))"; then
    aiur_build_gate_release_linux_owner "$owner_path" || true
    exec {phase_fd}>&-
    return 125
  fi

  if ! aiur_build_gate_release_linux_owner "$owner_path"; then
    exec {phase_fd}>&-
    return 125
  fi

  exec {phase_fd}>&-
  return 0
}

aiur_build_gate_maybe_wait_for_phase_start() {
  local gate_dir=$1 phase=$2 slots=$3 stagger_seconds=$4 deadline=$5
  local strategy_result

  if ((stagger_seconds == 0 || slots == 1)); then
    return 0
  fi

  if aiur_build_gate_linux_locks; then
    aiur_build_gate_wait_for_phase_start_linux \
      "$gate_dir" "$phase" "$stagger_seconds" "$deadline"
  else
    strategy_result=$?

    if ((strategy_result == 1)); then
      aiur_build_gate_wait_for_phase_start_pid \
        "$gate_dir" "$phase" "$stagger_seconds" "$deadline"
    else
      return "$strategy_result"
    fi
  fi
}
