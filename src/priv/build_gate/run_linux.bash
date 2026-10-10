# Loaded by build_gate.bash. Linux flock admission through the detached lease holder.
aiur_build_gate_check_legacy_state() {
  local gate_dir=$1 queue_dir=$2 path basename

  for path in "$gate_dir"/slot-[0-9]* "$gate_dir"/phase-start.lock; do
    [[ -e $path || -L $path ]] || continue

    case $path in
      *.owner | *.hold-timeout) continue ;;
    esac

    aiur_build_gate_fail "legacy_state_blocked" "$path"
    return 125
  done

  for path in "$queue_dir"/*; do
    [[ -e $path || -L $path ]] || continue
    basename=${path##*/}
    [[ $basename == lease-v2-* ]] && continue
    aiur_build_gate_fail "legacy_state_blocked" "$path"
    return 125
  done
}

aiur_build_gate_run_linux() (
  local phase=$1 executable=$2
  shift 2

  local gate_dir=${AIUR_BUILD_GATE_DIR:-}
  local slots=${AIUR_BUILD_GATE_SLOTS:-0}
  local stagger_seconds=${AIUR_BUILD_START_STAGGER_SECONDS:-0}
  local timeout_seconds=${AIUR_BUILD_GATE_TIMEOUT_SECONDS:-900}
  local min_free_memory_mb=${AIUR_MIN_FREE_MEMORY_MB:-0}
  local queue_dir locks_dir queue_candidate queue_file queue_token queue_fd
  local command_pid_file="" command_ready_file="" command_status_file="" command_status_ack_file=""
  local holder_ready_file="" holder_started_file=""
  local command_pgid holder_pid parent_pid python_binary retained status
  local deadline handshake_deadline holder_handshake_seconds=2 holder_ack_seconds=5 slot slot_lock slot_owner slot_fd lock_result owner_pid owner_pgid token result pacing_result
  local available_memory_mb memory_deferred=0 memory_unavailable_logged=0

  # Keep descriptor allocation local to this subshell and independent of an
  # invoking agent shell's shopt state. The opened slot descriptor is handed
  # only to the dedicated lease holder.
  shopt -u varredir_close

  if [[ ! $slots =~ ^[0-9]+$ ]] ||
    [[ ! $stagger_seconds =~ ^[0-9]+$ ]] ||
    [[ ! $timeout_seconds =~ ^[0-9]+$ ]] ||
    [[ ! $min_free_memory_mb =~ ^[0-9]+$ ]] ||
    [[ -z $gate_dir ]]; then
    aiur_build_gate_fail "invalid_configuration" "$gate_dir"
    return 125
  fi

  if [[ -z $(type -P flock) ]]; then
    aiur_build_gate_fail "flock_unavailable" "$gate_dir"
    return 125
  fi

  if [[ -z $(type -P mktemp) ]]; then
    aiur_build_gate_fail "mktemp_unavailable" "$gate_dir"
    return 125
  fi

  if ((slots > 0)); then
    python_binary=$(type -P python3)

    if [[ -z $python_binary ]]; then
      aiur_build_gate_fail "lease_holder_runtime_unavailable" "$gate_dir"
      return 125
    fi
  fi

  queue_dir="$gate_dir/queue"
  locks_dir=${AIUR_BUILD_GATE_LOCK_DIR:-}

  if ! mkdir -p "$queue_dir" 2>/dev/null; then
    aiur_build_gate_fail "directory_unavailable" "$gate_dir"
    return 125
  fi

  if aiur_build_gate_linux_locks; then
    if [[ -z $locks_dir || ! -d $locks_dir ]]; then
      aiur_build_gate_fail "lock_directory_unavailable" "${locks_dir:-unset}"
      return 125
    fi
  else
    lock_result=$?

    if ((lock_result != 1)); then
      return "$lock_result"
    fi
  fi

  aiur_build_gate_check_legacy_state "$gate_dir" "$queue_dir" || return $?

  queue_candidate=$(mktemp "$gate_dir/.queue-v2.XXXXXXXXXX" 2>/dev/null) || {
    aiur_build_gate_fail "queue_candidate_failed" "$gate_dir"
    return 125
  }

  if ! exec {queue_fd}<>"$queue_candidate"; then
    rm -f "$queue_candidate" 2>/dev/null || true
    aiur_build_gate_fail "queue_open_failed" "$queue_candidate"
    return 125
  fi

  if ! command flock -n "$queue_fd"; then
    exec {queue_fd}>&-
    rm -f "$queue_candidate" 2>/dev/null || true
    aiur_build_gate_fail "queue_lock_failed" "$queue_candidate"
    return 125
  fi

  owner_pid=${AIUR_BUILD_GATE_DIAGNOSTIC_PID:-}
  [[ $owner_pid =~ ^[1-9][0-9]*$ ]] || owner_pid=${BASHPID:-$$}
  owner_pgid=${AIUR_BUILD_GATE_DIAGNOSTIC_PGID:-}

  if [[ ! $owner_pgid =~ ^[1-9][0-9]*$ ]] &&
    owner_pgid=$(ps -o pgid= -p "${BASHPID:-$$}" 2>/dev/null); then
    owner_pgid=${owner_pgid//[[:space:]]/}
    [[ $owner_pgid =~ ^[1-9][0-9]*$ ]] || owner_pgid=0
  fi

  [[ $owner_pgid =~ ^[1-9][0-9]*$ ]] || owner_pgid=0

  queue_token=${queue_candidate##*/}
  queue_token=${queue_token#.queue-v2.}

  if ! printf 'version=2\ntoken=%s\npid=%s\npgid=%s\nphase=%s\ncommand=%s\nstarted_at=%s\n' \
    "$queue_token" "$owner_pid" "$owner_pgid" "$phase" "$*" "$(aiur_build_gate_started_at)" >&"$queue_fd"; then
    exec {queue_fd}>&-
    rm -f "$queue_candidate" 2>/dev/null || true
    aiur_build_gate_fail "queue_record_failed" "$queue_candidate"
    return 125
  fi

  queue_file="$queue_dir/lease-v2-$queue_token"

  if ! mv "$queue_candidate" "$queue_file" 2>/dev/null; then
    exec {queue_fd}>&-
    rm -f "$queue_candidate" 2>/dev/null || true
    aiur_build_gate_fail "queue_publish_failed" "$queue_file"
    return 125
  fi

  deadline=$((SECONDS + timeout_seconds))
  aiur_build_gate_log "queued slots=$slots command=$*"

  while :; do
    if ((min_free_memory_mb > 0)); then
      if available_memory_mb=$(aiur_build_gate_available_memory_mb); then
        memory_unavailable_logged=0

        if ((available_memory_mb < min_free_memory_mb)); then
          if ((memory_deferred == 0)); then
            aiur_build_gate_memory_hold_log "$available_memory_mb" "$min_free_memory_mb"
          fi

          memory_deferred=1

          if ((SECONDS >= deadline)); then
            rm -f "$queue_file" 2>/dev/null || true
            exec {queue_fd}>&-
            aiur_build_gate_log "timeout slots=$slots command=$*"
            return 124
          fi

          sleep 1
          continue
        fi
      elif ((memory_unavailable_logged == 0)); then
        aiur_build_gate_memory_unavailable_log
        memory_unavailable_logged=1
      fi
    fi

    memory_deferred=0

    if ((slots == 0)); then
      if aiur_build_gate_maybe_wait_for_phase_start \
        "$gate_dir" "$phase" "$slots" "$stagger_seconds" "$deadline"; then
        pacing_result=0
      else
        pacing_result=$?
      fi

      if ((pacing_result != 0)); then
        rm -f "$queue_file" 2>/dev/null || true
        exec {queue_fd}>&-

        if ((pacing_result == 124)); then
          aiur_build_gate_log "timeout slots=$slots command=$*"
        fi

        return "$pacing_result"
      fi

      if ! rm -f "$queue_file" 2>/dev/null; then
        exec {queue_fd}>&-
        aiur_build_gate_fail "queue_release_failed" "$queue_file"
        return 125
      fi

      exec {queue_fd}>&-
      if aiur_build_gate_execute_with_ephemeral_lease "$gate_dir" "$phase" "$executable" "$@"; then
        result=0
      else
        result=$?
      fi

      aiur_build_gate_log "completed status=$result"
      return "$result"
    fi

    for ((slot = 1; slot <= slots; slot++)); do
      slot_lock="$locks_dir/slot-$slot.lock"
      slot_owner="$gate_dir/slot-$slot.owner"

      if ! exec {slot_fd}<"$slot_lock"; then
        rm -f "$queue_file" 2>/dev/null || true
        exec {queue_fd}>&-
        aiur_build_gate_fail "slot_lock_open_failed" "$slot_lock"
        return 125
      fi

      if command flock -n -E 75 "$slot_fd"; then
        token="$queue_token.$slot.$RANDOM"

        if ! aiur_build_gate_publish_owner_v2 \
          "$gate_dir" "$slot_owner" "$token" "$phase" "$owner_pid" "$owner_pgid" "$*" 0 0; then
          exec {slot_fd}>&-
          rm -f "$queue_file" 2>/dev/null || true
          exec {queue_fd}>&-
          return 125
        fi

        if ! rm -f "$queue_file" 2>/dev/null; then
          aiur_build_gate_release_linux_owner "$slot_owner" || true
          exec {slot_fd}>&-
          exec {queue_fd}>&-
          aiur_build_gate_fail "queue_release_failed" "$queue_file"
          return 125
        fi

        exec {queue_fd}>&-
        aiur_build_gate_log "acquired slot=$slot command=$*"

        if aiur_build_gate_maybe_wait_for_phase_start \
          "$gate_dir" "$phase" "$slots" "$stagger_seconds" "$deadline"; then
          pacing_result=0
        else
          pacing_result=$?
        fi

        if ((pacing_result != 0)); then
          aiur_build_gate_release_linux_owner "$slot_owner" || true
          exec {slot_fd}>&-
          aiur_build_gate_log "released slot=$slot status=$pacing_result"

          if ((pacing_result == 124)); then
            aiur_build_gate_log "timeout slots=$slots command=$*"
          fi

          return "$pacing_result"
        fi

        if ! command_pid_file=$(mktemp "$gate_dir/.command-v2.XXXXXXXXXX" 2>/dev/null) ||
          ! command_ready_file=$(mktemp "$gate_dir/.command-ready-v2.XXXXXXXXXX" 2>/dev/null) ||
          ! command_status_file=$(mktemp "$gate_dir/.status-v2.XXXXXXXXXX" 2>/dev/null) ||
          ! command_status_ack_file=$(mktemp "$gate_dir/.status-ack-v2.XXXXXXXXXX" 2>/dev/null) ||
          ! holder_ready_file=$(mktemp "$gate_dir/.holder-ready-v2.XXXXXXXXXX" 2>/dev/null) ||
          ! holder_started_file=$(mktemp "$gate_dir/.holder-started-v2.XXXXXXXXXX" 2>/dev/null); then
          rm -f "$command_pid_file" "$command_ready_file" "$command_status_file" "$command_status_ack_file" \
            "$holder_ready_file" "$holder_started_file" 2>/dev/null || true
          aiur_build_gate_release_linux_owner "$slot_owner" || true
          exec {slot_fd}>&-
          aiur_build_gate_fail "lease_holder_metadata_failed" "$gate_dir"
          return 125
        fi

        parent_pid=${BASHPID:-$$}
        handshake_deadline=$((SECONDS + holder_handshake_seconds))

        aiur_build_gate_hold_linux_lease \
          "$python_binary" "$holder_ready_file" "$holder_started_file" \
          "$command_pid_file" "$command_ready_file" "$command_status_file" "$command_status_ack_file" \
          "$slot_owner" "$token" "$parent_pid" "$owner_pgid" "$slot_fd" \
          "$holder_handshake_seconds" "$holder_ack_seconds" \
          "$executable" "$@" &
        holder_pid=$!

        if ! aiur_build_gate_wait_for_holder_value \
          "$holder_started_file" "$holder_pid" '^started$' "$handshake_deadline"; then
          aiur_build_gate_stop_holder "$holder_pid"
          rm -f "$command_pid_file" "$command_ready_file" "$command_status_file" "$command_status_ack_file" \
            "$holder_ready_file" "$holder_started_file" 2>/dev/null || true
          aiur_build_gate_release_linux_owner "$slot_owner" || true
          exec {slot_fd}>&-
          aiur_build_gate_fail "lease_holder_start_failed" "$gate_dir"
          return 125
        fi

        if ! aiur_build_gate_publish_owner_v2 \
          "$gate_dir" "$slot_owner" "$token" "$phase" "$owner_pid" "$owner_pgid" "$*" \
          "$holder_pid" 0; then
          aiur_build_gate_stop_holder "$holder_pid"
          rm -f "$command_pid_file" "$command_ready_file" "$command_status_file" "$command_status_ack_file" \
            "$holder_ready_file" "$holder_started_file" 2>/dev/null || true
          aiur_build_gate_release_linux_owner "$slot_owner" || true
          exec {slot_fd}>&-
          return 125
        fi

        if ! aiur_build_gate_write_reserved_regular \
          "$python_binary" "$holder_ready_file" "ready"; then
          aiur_build_gate_stop_holder "$holder_pid"
          rm -f "$command_pid_file" "$command_ready_file" "$command_status_file" "$command_status_ack_file" \
            "$holder_ready_file" "$holder_started_file" 2>/dev/null || true
          aiur_build_gate_release_linux_owner "$slot_owner" || true
          exec {slot_fd}>&-
          aiur_build_gate_fail "lease_holder_ready_failed" "$holder_ready_file"
          return 125
        fi

        if ! aiur_build_gate_wait_for_holder_value \
          "$command_pid_file" "$holder_pid" '^[1-9][0-9]*$' "$handshake_deadline" ||
          ! command_pgid=$(aiur_build_gate_read_regular "$command_pid_file" 2>/dev/null) ||
          [[ ! $command_pgid =~ ^[1-9][0-9]*$ ]]; then
          aiur_build_gate_stop_holder "$holder_pid"
          rm -f "$command_pid_file" "$command_ready_file" "$command_status_file" "$command_status_ack_file" \
            "$holder_ready_file" "$holder_started_file" 2>/dev/null || true
          aiur_build_gate_release_linux_owner "$slot_owner" || true
          exec {slot_fd}>&-
          aiur_build_gate_fail "command_process_group_unavailable" "$gate_dir"
          return 125
        fi

        if ! aiur_build_gate_publish_owner_v2 \
          "$gate_dir" "$slot_owner" "$token" "$phase" "$owner_pid" "$owner_pgid" "$*" \
          "$holder_pid" "$command_pgid"; then
          aiur_build_gate_stop_holder "$holder_pid"
          rm -f "$command_pid_file" "$command_ready_file" "$command_status_file" "$command_status_ack_file" \
            "$holder_ready_file" "$holder_started_file" 2>/dev/null || true
          aiur_build_gate_release_linux_owner "$slot_owner" || true
          exec {slot_fd}>&-
          return 125
        fi

        if ! aiur_build_gate_write_reserved_regular \
          "$python_binary" "$command_ready_file" "ready"; then
          aiur_build_gate_stop_holder "$holder_pid"
          rm -f "$command_pid_file" "$command_ready_file" "$command_status_file" "$command_status_ack_file" \
            "$holder_ready_file" "$holder_started_file" 2>/dev/null || true
          aiur_build_gate_release_linux_owner "$slot_owner" || true
          exec {slot_fd}>&-
          aiur_build_gate_fail "command_ready_failed" "$command_ready_file"
          return 125
        fi

        # The subreaper now owns the lock independently from BEAM and will
        # retain it across process-group changes and double-forked children.
        exec {slot_fd}>&-

        if [[ ${AIUR_TEST_STATUS_READ_DELAY_SECONDS:-0} =~ ^[1-9][0-9]*$ ]]; then
          sleep "$AIUR_TEST_STATUS_READ_DELAY_SECONDS"
        fi

        if ! status=$(
          aiur_build_gate_wait_for_command_status "$command_status_file" "$holder_pid"
        ); then
          aiur_build_gate_stop_holder "$holder_pid"
          rm -f "$command_pid_file" "$command_ready_file" "$command_status_file" "$command_status_ack_file" \
            "$holder_ready_file" "$holder_started_file" 2>/dev/null || true
          aiur_build_gate_release_linux_owner "$slot_owner" || true
          aiur_build_gate_fail "lease_holder_status_failed" "$gate_dir"
          return 125
        fi

        if ! aiur_build_gate_write_reserved_regular \
          "$python_binary" "$command_status_ack_file" "ack=$token"; then
          aiur_build_gate_stop_holder "$holder_pid"
          rm -f "$command_pid_file" "$command_ready_file" "$command_status_file" "$command_status_ack_file" \
            "$holder_ready_file" "$holder_started_file" 2>/dev/null || true
          aiur_build_gate_release_linux_owner "$slot_owner" || true
          aiur_build_gate_fail "lease_holder_status_ack_failed" "$gate_dir"
          return 125
        fi

        result=${status%% *}
        retained=${status##* }

        if ((retained == 1)); then
          aiur_build_gate_log \
            "lease_retained slot=$slot status=$result holder_pid=$holder_pid command_pgid=$command_pgid retain_seconds=${AIUR_BUILD_GATE_RETAIN_SECONDS:-120}"
        else
          wait "$holder_pid" 2>/dev/null || true
          aiur_build_gate_log "released slot=$slot status=$result"
        fi

        return "$result"
      else
        lock_result=$?
      fi

      exec {slot_fd}>&-

      if ((lock_result != 75)); then
        rm -f "$queue_file" 2>/dev/null || true
        exec {queue_fd}>&-
        aiur_build_gate_fail "slot_lock_failed" "$slot_lock"
        return 125
      fi
    done

    if ((SECONDS >= deadline)); then
      rm -f "$queue_file" 2>/dev/null || true
      exec {queue_fd}>&-
      aiur_build_gate_log "timeout slots=$slots command=$*"
      return 124
    fi

    sleep 1
  done
)
