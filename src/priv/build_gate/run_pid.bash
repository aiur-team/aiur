# Loaded by build_gate.bash. PID-strategy admission: the fallback when Linux flock leases are unavailable.
aiur_build_gate_run_pid() {
  local phase=$1 executable=$2
  shift 2

  local gate_dir=${AIUR_BUILD_GATE_DIR:-}
  local slots=${AIUR_BUILD_GATE_SLOTS:-0}
  local stagger_seconds=${AIUR_BUILD_START_STAGGER_SECONDS:-0}
  local timeout_seconds=${AIUR_BUILD_GATE_TIMEOUT_SECONDS:-900}
  local min_free_memory_mb=${AIUR_MIN_FREE_MEMORY_MB:-0}
  local queue_dir queue_file deadline slot slot_path owner_candidate owner_pid owner_pgid result pacing_result token
  local available_memory_mb memory_deferred=0 memory_unavailable_logged=0

  if [[ ! $slots =~ ^[0-9]+$ ]] ||
    [[ ! $stagger_seconds =~ ^[0-9]+$ ]] ||
    [[ ! $timeout_seconds =~ ^[0-9]+$ ]] ||
    [[ ! $min_free_memory_mb =~ ^[0-9]+$ ]] ||
    [[ -z $gate_dir ]]; then
    aiur_build_gate_fail "invalid_configuration" "$gate_dir"
    return 125
  fi

  queue_dir="$gate_dir/queue"
  if ! mkdir -p "$queue_dir" 2>/dev/null; then
    aiur_build_gate_fail "directory_unavailable" "$gate_dir"
    return 125
  fi

  queue_file="$queue_dir/$$"
  if ! printf 'pid=%s\ncommand=%s\nstarted_at=%s\n' \
    "$$" "$*" "$(aiur_build_gate_started_at)" >"$queue_file"; then
    aiur_build_gate_fail "queue_record_failed" "$queue_file"
    return 125
  fi

  deadline=$((SECONDS + timeout_seconds))
  aiur_build_gate_log "queued slots=$slots command=$*"

  owner_pid=${BASHPID:-$$}
  owner_pgid=$(ps -o pgid= -p "$owner_pid" 2>/dev/null)
  owner_pgid=${owner_pgid//[[:space:]]/}

  if ((slots > 0)) && [[ ! $owner_pgid =~ ^[1-9][0-9]*$ ]]; then
    rm -f "$queue_file"
    aiur_build_gate_fail "owner_process_group_unavailable" "$owner_pid"
    return 125
  fi

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
            rm -f "$queue_file"
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
        rm -f "$queue_file"

        if ((pacing_result == 124)); then
          aiur_build_gate_log "timeout slots=$slots command=$*"
        fi

        return "$pacing_result"
      fi

      if ! rm -f "$queue_file"; then
        aiur_build_gate_fail "queue_release_failed" "$queue_file"
        return 125
      fi

      if aiur_build_gate_execute_with_ephemeral_lease "$gate_dir" "$phase" "$executable" "$@"; then
        result=0
      else
        result=$?
      fi

      aiur_build_gate_log "completed status=$result"
      return "$result"
    fi

    for ((slot = 1; slot <= slots; slot++)); do
      slot_path="$gate_dir/slot-$slot"
      owner_candidate="$gate_dir/.slot-$slot-owner.$owner_pid.$RANDOM"

      token="$owner_pid.$slot.$RANDOM.$SECONDS"

      if ! printf 'pid=%s\npgid=%s\nversion=2\ntoken=%s\ncommand=%s\nstarted_at=%s\n' \
        "$owner_pid" "$owner_pgid" "$token" "$*" "$(aiur_build_gate_started_at)" >"$owner_candidate"; then
        rm -f "$owner_candidate"
        rm -f "$queue_file"
        aiur_build_gate_fail "owner_write_failed" "$owner_candidate"
        return 125
      fi

      # A hard link makes acquisition and the complete immutable owner record
      # visible in one operation. No delayed writer can target a replacement.
      if [[ ! -d $slot_path ]] && ln "$owner_candidate" "$slot_path" 2>/dev/null; then
        if ! rm -f "$owner_candidate"; then
          rm -rf "$slot_path" 2>/dev/null || true
          rm -f "$queue_file" 2>/dev/null || true
          aiur_build_gate_fail "owner_candidate_release_failed" "$owner_candidate"
          return 125
        fi

        if ! rm -f "$queue_file"; then
          rm -rf "$slot_path" 2>/dev/null || true
          aiur_build_gate_fail "queue_release_failed" "$queue_file"
          return 125
        fi

        aiur_build_gate_log "acquired slot=$slot command=$*"

        if aiur_build_gate_maybe_wait_for_phase_start \
          "$gate_dir" "$phase" "$slots" "$stagger_seconds" "$deadline"; then
          pacing_result=0
        else
          pacing_result=$?
        fi

        if ((pacing_result != 0)); then
          rm -rf "$slot_path" 2>/dev/null || true
          aiur_build_gate_log "released slot=$slot status=$pacing_result"

          if ((pacing_result == 124)); then
            aiur_build_gate_log "timeout slots=$slots command=$*"
          fi

          return "$pacing_result"
        fi

        if aiur_build_gate_execute_under_lease "$slot_path" "$token" "$executable" "$@"; then
          result=0
        else
          result=$?
        fi

        if ! rm -rf "$slot_path" 2>/dev/null; then
          aiur_build_gate_fail "release_failed" "$slot_path"
          result=125
        fi

        aiur_build_gate_log "released slot=$slot status=$result"
        return "$result"
      fi

      rm -f "$owner_candidate"

      aiur_build_gate_reclaim_stale_slot "$slot_path" "$slot" || true
    done

    if ((SECONDS >= deadline)); then
      rm -f "$queue_file"
      aiur_build_gate_log "timeout slots=$slots command=$*"
      return 124
    fi

    sleep 1
  done
}
