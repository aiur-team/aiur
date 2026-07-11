#!/usr/bin/env bash
# Sourced through BASH_ENV for local Aiur coding-agent shells. It intentionally
# gates only Mix compile/test work; editing, Git, and other shell commands stay
# free to run while a verification command holds a lease.

if [[ -z ${AIUR_BUILD_GATE_HOOK_LOADED:-} ]]; then
  AIUR_BUILD_GATE_HOOK_LOADED=1

  aiur_build_gate_log() {
    printf 'aiur_build_gate %s\n' "$*" >&2
  }

  aiur_build_gate_needs_slot() {
    case ${1:-} in
      compile | test) return 0 ;;
      *) return 1 ;;
    esac
  }

  aiur_build_gate_owner_pid() {
    local owner_file=$1 first_line

    [[ -f $owner_file ]] || return 1
    IFS= read -r first_line <"$owner_file" || return 1
    [[ $first_line =~ ^pid=([1-9][0-9]*)$ ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
  }

  aiur_build_gate_available_memory_mb() {
    local meminfo_path=${AIUR_MEMINFO_PATH:-/proc/meminfo}
    local key value unit remainder

    [[ -r $meminfo_path ]] || return 1

    while read -r key value unit remainder; do
      [[ $key == MemAvailable: ]] || continue
      [[ $value =~ ^[0-9]+$ && $unit == kB ]] || return 1
      printf '%s\n' "$((value / 1024))"
      return 0
    done <"$meminfo_path"

    return 1
  }

  aiur_build_gate_memory_hold_log() {
    local available_mb=$1 threshold_mb=$2
    printf 'aiur_perf memory_hold surface=build available_mb=%s threshold_mb=%s\n' \
      "$available_mb" "$threshold_mb" >&2
  }

  aiur_build_gate_memory_unavailable_log() {
    printf 'aiur_perf memory_unavailable surface=build action=fail_open path=%s\n' \
      "${AIUR_MEMINFO_PATH:-/proc/meminfo}" >&2
  }

  aiur_build_gate_now_seconds() {
    local now

    now=$(date +%s 2>/dev/null) || return 1
    [[ $now =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$now"
  }

  aiur_build_gate_phase_hold_log() {
    local phase=$1 wait_seconds=$2
    printf 'aiur_perf phase_stagger_hold surface=build phase=%s wait_seconds=%s\n' \
      "$phase" "$wait_seconds" >&2
  }

  aiur_build_gate_phase_clock_unavailable_log() {
    printf 'aiur_perf phase_clock_unavailable surface=build action=fail_open\n' >&2
  }

  aiur_build_gate_reclaim_stale_slot() {
    local slot_path=$1 slot=$2 owner_file="$slot_path/owner" owner_pid

    owner_pid=$(aiur_build_gate_owner_pid "$owner_file")

    if [[ -n $owner_pid ]]; then
      kill -0 "$owner_pid" 2>/dev/null && return 1

      rm -f "$owner_file"
      if rmdir "$slot_path" 2>/dev/null; then
        aiur_build_gate_log "stale_owner_recovered slot=$slot owner_pid=$owner_pid"
        return 0
      fi

      return 1
    fi

    # A process can die between mkdir and writing its owner file. Waiting
    # contenders safely reclaim only an empty slot; a delayed owner write then
    # fails and retries rather than running without a lease.
    if rmdir "$slot_path" 2>/dev/null; then
      aiur_build_gate_log "stale_owner_recovered slot=$slot owner_pid=unknown"
      return 0
    fi

    return 1
  }

  aiur_build_gate_release_phase_lock() {
    local lock_path=$1

    if ! rm -rf "$lock_path" 2>/dev/null; then
      aiur_build_gate_log "gate_error reason=phase_lock_release_failed path=$lock_path"
      return 1
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

  aiur_build_gate_wait_for_phase_start() {
    local gate_dir=$1 phase=$2 stagger_seconds=$3 deadline=$4
    local lock_path="$gate_dir/phase-start.lock"
    local owner_pid=${BASHPID:-$$}
    local owner_candidate="$gate_dir/.phase-start-owner.$owner_pid.$RANDOM"
    local next_start_file="$gate_dir/phase-next-start"
    local now next_start wait_seconds max_wait_seconds

    while :; do
      if ! printf 'pid=%s\nphase=%s\n' "$owner_pid" "$phase" >"$owner_candidate"; then
        aiur_build_gate_log "gate_error reason=phase_owner_write_failed path=$owner_candidate"
        return 2
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
        aiur_build_gate_log "gate_error reason=phase_lock_unavailable path=$lock_path"
        return 2
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
      return 2
    fi

    wait_seconds=0
    next_start=""

    if [[ -f $next_start_file ]]; then
      IFS= read -r next_start <"$next_start_file" || next_start=""

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
        return 2
      fi

      wait_seconds=$((next_start > now ? next_start - now : 0))
    done

    if ! printf '%s\n' "$((now + stagger_seconds + 1))" >"$next_start_file"; then
      aiur_build_gate_release_phase_lock "$lock_path" || true
      aiur_build_gate_log "gate_error reason=phase_state_write_failed path=$next_start_file"
      return 2
    fi

    aiur_build_gate_release_phase_lock "$lock_path" || true
    return 0
  }

  aiur_build_gate_maybe_wait_for_phase_start() {
    local gate_dir=$1 phase=$2 slots=$3 stagger_seconds=$4 deadline=$5

    if ((stagger_seconds == 0 || slots == 1)); then
      return 0
    fi

    aiur_build_gate_wait_for_phase_start \
      "$gate_dir" "$phase" "$stagger_seconds" "$deadline"
  }

  aiur_build_gate_run() {
    local phase=$1 executable=$2
    shift 2

    local gate_dir=${AIUR_BUILD_GATE_DIR:-}
    local slots=${AIUR_BUILD_GATE_SLOTS:-0}
    local stagger_seconds=${AIUR_BUILD_START_STAGGER_SECONDS:-0}
    local timeout_seconds=${AIUR_BUILD_GATE_TIMEOUT_SECONDS:-900}
    local min_free_memory_mb=${AIUR_MIN_FREE_MEMORY_MB:-0}
    local queue_dir queue_file deadline slot slot_path owner_file result pacing_result
    local available_memory_mb memory_deferred=0 memory_unavailable_logged=0

    if [[ ! $slots =~ ^[0-9]+$ ]] ||
      [[ ! $stagger_seconds =~ ^[0-9]+$ ]] ||
      [[ ! $timeout_seconds =~ ^[0-9]+$ ]] ||
      [[ ! $min_free_memory_mb =~ ^[0-9]+$ ]] ||
      [[ -z $gate_dir ]]; then
      aiur_build_gate_log "gate_error reason=invalid_configuration"
      "$executable" "$@"
      return
    fi

    queue_dir="$gate_dir/queue"
    if ! mkdir -p "$queue_dir" 2>/dev/null; then
      aiur_build_gate_log "gate_error reason=directory_unavailable path=$gate_dir"
      "$executable" "$@"
      return
    fi

    queue_file="$queue_dir/$$"
    if ! printf 'pid=%s\ncommand=%s\n' "$$" "$*" >"$queue_file"; then
      aiur_build_gate_log "gate_error reason=queue_record_failed path=$queue_file"
      "$executable" "$@"
      return
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
        aiur_build_gate_maybe_wait_for_phase_start \
          "$gate_dir" "$phase" "$slots" "$stagger_seconds" "$deadline"
        pacing_result=$?

        if ((pacing_result == 124)); then
          rm -f "$queue_file"
          aiur_build_gate_log "timeout slots=$slots command=$*"
          return 124
        fi

        rm -f "$queue_file"
        "$executable" "$@"
        result=$?
        aiur_build_gate_log "completed status=$result"
        return "$result"
      fi

      for ((slot = 1; slot <= slots; slot++)); do
        slot_path="$gate_dir/slot-$slot"

        if mkdir "$slot_path" 2>/dev/null; then
          owner_file="$slot_path/owner"

          if ! printf 'pid=%s\ncommand=%s\n' "$$" "$*" >"$owner_file"; then
            rmdir "$slot_path" 2>/dev/null || true
            continue
          fi

          rm -f "$queue_file"
          aiur_build_gate_log "acquired slot=$slot command=$*"

          aiur_build_gate_maybe_wait_for_phase_start \
            "$gate_dir" "$phase" "$slots" "$stagger_seconds" "$deadline"
          pacing_result=$?

          if ((pacing_result == 124)); then
            rm -rf "$slot_path" 2>/dev/null || true
            aiur_build_gate_log "released slot=$slot status=124"
            aiur_build_gate_log "timeout slots=$slots command=$*"
            return 124
          fi

          "$executable" "$@"
          result=$?

          if ! rm -rf "$slot_path" 2>/dev/null; then
            aiur_build_gate_log "gate_error reason=release_failed slot=$slot"
          fi

          aiur_build_gate_log "released slot=$slot status=$result"
          return "$result"
        fi

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

  aiur_build_gate_mise_phase() {
    local command=${1:-}
    shift || true

    case $command in
      exec | x) ;;
      *) return 1 ;;
    esac

    while (($#)); do
      if [[ $1 == -- ]]; then
        shift
        break
      fi

      shift
    done

    [[ ${1:-} == mix ]] || return 1
    shift
    aiur_build_gate_needs_slot "${1:-}" || return 1
    printf '%s\n' "$1"
  }

  mix() {
    local mix_binary
    mix_binary=$(type -P mix)

    if [[ -n $mix_binary ]] && aiur_build_gate_needs_slot "${1:-}"; then
      aiur_build_gate_run "${1:-}" "$mix_binary" "$@"
    elif [[ -n $mix_binary ]]; then
      "$mix_binary" "$@"
    else
      command mix "$@"
    fi
  }

  mise() {
    local mise_binary phase
    mise_binary=$(type -P mise)

    if [[ -n $mise_binary ]] && phase=$(aiur_build_gate_mise_phase "$@"); then
      aiur_build_gate_run "$phase" "$mise_binary" "$@"
    elif [[ -n $mise_binary ]]; then
      "$mise_binary" "$@"
    else
      command mise "$@"
    fi
  }
fi
