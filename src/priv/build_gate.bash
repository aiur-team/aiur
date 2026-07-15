#!/usr/bin/env bash
# Sourced through BASH_ENV for local Aiur coding-agent shells. It intentionally
# gates only Mix compile/test work; editing, Git, and other shell commands stay
# free to run while a verification command holds a lease.

if [[ -z ${AIUR_BUILD_GATE_HOOK_LOADED:-} ]]; then
  AIUR_BUILD_GATE_HOOK_LOADED=1

  aiur_build_gate_log() {
    printf 'aiur_build_gate %s\n' "$*" >&2
  }

  aiur_build_gate_fail() {
    local reason=$1 path=${2:-unknown}

    aiur_build_gate_log \
      "gate_error reason=$reason path=$path status=125" \
      "recovery=repair_gate_or_disable_all_build_admission" \
      "disable=max_concurrent_builds_0,build_start_stagger_seconds_0,min_free_memory_mb_unset"
    return 125
  }

  aiur_build_gate_linux_locks() {
    local platform

    case ${AIUR_BUILD_GATE_LEASE_STRATEGY:-auto} in
      linux) return 0 ;;
      pid) return 1 ;;
    esac

    if ! platform=$(uname -s 2>/dev/null); then
      aiur_build_gate_fail "platform_detection_failed" "uname"
      return 125
    fi

    [[ $platform == Linux ]]
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

  aiur_build_gate_owner_pgid() {
    local owner_file=$1 line

    [[ -f $owner_file ]] || return 1

    while IFS= read -r line; do
      if [[ $line =~ ^pgid=([1-9][0-9]*)$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
      fi
    done <"$owner_file"

    return 1
  }

  aiur_build_gate_process_group_alive() {
    local pgid=$1

    [[ $pgid =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 -- "-$pgid" 2>/dev/null
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
    printf 'aiur_perf phase_clock_unavailable surface=build action=fail_closed status=125\n' >&2
  }

  aiur_build_gate_read_regular() {
    local path=$1 contents python_binary helper result

    if [[ ! -e $path && ! -L $path ]]; then
      return 1
    fi

    python_binary=$(type -P python3)
    helper="$(dirname "${BASH_SOURCE[0]}")/build_gate_holder.py"

    if [[ -z $python_binary ]]; then
      aiur_build_gate_fail "metadata_reader_unavailable" "$path"
      return 125
    fi

    if contents=$("$python_binary" "$helper" --read-regular "$path" 2>/dev/null); then
      printf '%s\n' "$contents"
      return 0
    else
      result=$?
    fi

    if ((result == 1)); then
      return 1
    else
      aiur_build_gate_fail "metadata_not_regular" "$path"
      return 125
    fi
  }

  aiur_build_gate_replace_regular() {
    local candidate=$1 destination=$2 invalid_reason=$3 publish_reason=$4 mv_help

    if [[ -e $destination || -L $destination ]]; then
      if [[ -L $destination || ! -f $destination ]]; then
        rm -f "$candidate" 2>/dev/null || true
        aiur_build_gate_fail "$invalid_reason" "$destination"
        return 125
      fi
    fi

    mv_help=$(command mv --help 2>&1 || true)

    if [[ $mv_help == *--no-target-directory* ]]; then
      command mv -fT "$candidate" "$destination" 2>/dev/null
    else
      command mv -f "$candidate" "$destination" 2>/dev/null
    fi

    if (($? != 0)) || [[ -e $candidate || -L $candidate ]] ||
      [[ -L $destination || ! -f $destination ]]; then
      rm -f "$candidate" 2>/dev/null || true
      aiur_build_gate_fail "$publish_reason" "$destination"
      return 125
    fi
  }

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
    local owner_candidate

    owner_candidate=$(mktemp "$gate_dir/.owner-v2.XXXXXXXXXX" 2>/dev/null) || {
      aiur_build_gate_fail "owner_candidate_failed" "$gate_dir"
      return 125
    }

    if ! printf \
      'version=2\ntoken=%s\npid=%s\npgid=%s\nholder_pid=%s\ncommand_pgid=%s\nphase=%s\ncommand=%s\n' \
      "$token" "$owner_pid" "$owner_pgid" "$holder_pid" "$command_pgid" "$phase" "$command" \
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
    local command_ready_path=$5 status_path=$6 owner_path=$7 token=$8 parent_pid=$9
    local slot_fd=${10}
    local holder_script
    shift 10

    # A Linux subreaper becomes the parent of daemonized Mix descendants. It
    # owns the slot descriptor, reports the direct command status promptly,
    # then keeps the lease until every adopted descendant has exited.
    holder_script="$(dirname "${BASH_SOURCE[0]}")/build_gate_holder.py"

    exec "$python_binary" "$holder_script" "$ready_path" "$started_path" "$command_pid_path" \
      "$command_ready_path" "$status_path" "$owner_path" "$token" "$parent_pid" "$slot_fd" "$@"
  }

  aiur_build_gate_wait_for_holder_file() {
    local path=$1 holder_pid=$2 attempt

    for ((attempt = 0; attempt < 100; attempt++)); do
      [[ -f $path ]] && return 0
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
    local status_path=$1 holder_pid=$2 status

    while :; do
      if IFS= read -r status 2>/dev/null <"$status_path" &&
        [[ $status =~ ^[0-9]+\ [01]$ ]]; then
        printf '%s\n' "$status"
        return 0
      fi

      kill -0 "$holder_pid" 2>/dev/null || return 1
      sleep 0.01
    done
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

  aiur_build_gate_run_pid() {
    local phase=$1 executable=$2
    shift 2

    local gate_dir=${AIUR_BUILD_GATE_DIR:-}
    local slots=${AIUR_BUILD_GATE_SLOTS:-0}
    local stagger_seconds=${AIUR_BUILD_START_STAGGER_SECONDS:-0}
    local timeout_seconds=${AIUR_BUILD_GATE_TIMEOUT_SECONDS:-900}
    local min_free_memory_mb=${AIUR_MIN_FREE_MEMORY_MB:-0}
    local queue_dir queue_file deadline slot slot_path owner_candidate owner_pid owner_pgid result pacing_result
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
    if ! printf 'pid=%s\ncommand=%s\n' "$$" "$*" >"$queue_file"; then
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

        if "$executable" "$@"; then
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

        if ! printf 'pid=%s\npgid=%s\ncommand=%s\n' "$owner_pid" "$owner_pgid" "$*" >"$owner_candidate"; then
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

          if "$executable" "$@"; then
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

  aiur_build_gate_check_legacy_state() {
    local gate_dir=$1 queue_dir=$2 path basename

    for path in "$gate_dir"/slot-[0-9]* "$gate_dir"/phase-start.lock; do
      [[ -e $path || -L $path ]] || continue

      case $path in
        *.owner) continue ;;
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
    local command_pid_file="" command_ready_file="" command_status_file=""
    local holder_ready_file="" holder_started_file=""
    local command_pgid holder_pid parent_pid python_binary retained status
    local deadline slot slot_lock slot_owner slot_fd lock_result owner_pid owner_pgid token result pacing_result
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

    if ! printf 'version=2\ntoken=%s\npid=%s\npgid=%s\nphase=%s\ncommand=%s\n' \
      "$queue_token" "$owner_pid" "$owner_pgid" "$phase" "$*" >&"$queue_fd"; then
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
        if "$executable" "$@"; then
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
            ! holder_ready_file=$(mktemp "$gate_dir/.holder-ready-v2.XXXXXXXXXX" 2>/dev/null) ||
            ! holder_started_file=$(mktemp "$gate_dir/.holder-started-v2.XXXXXXXXXX" 2>/dev/null); then
            rm -f "$command_pid_file" "$command_ready_file" "$command_status_file" \
              "$holder_ready_file" "$holder_started_file" 2>/dev/null || true
            aiur_build_gate_release_linux_owner "$slot_owner" || true
            exec {slot_fd}>&-
            aiur_build_gate_fail "lease_holder_metadata_failed" "$gate_dir"
            return 125
          fi

          rm -f "$command_pid_file" "$command_ready_file" "$command_status_file" \
            "$holder_ready_file" "$holder_started_file" 2>/dev/null || true
          parent_pid=${BASHPID:-$$}

          aiur_build_gate_hold_linux_lease \
            "$python_binary" "$holder_ready_file" "$holder_started_file" \
            "$command_pid_file" "$command_ready_file" "$command_status_file" "$slot_owner" "$token" \
            "$parent_pid" "$slot_fd" "$executable" "$@" &
          holder_pid=$!

          if ! aiur_build_gate_wait_for_holder_file "$holder_started_file" "$holder_pid"; then
            aiur_build_gate_stop_holder "$holder_pid"
            rm -f "$command_pid_file" "$command_ready_file" "$command_status_file" \
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
            rm -f "$command_pid_file" "$command_ready_file" "$command_status_file" \
              "$holder_ready_file" "$holder_started_file" 2>/dev/null || true
            aiur_build_gate_release_linux_owner "$slot_owner" || true
            exec {slot_fd}>&-
            return 125
          fi

          if ! (set -o noclobber; : >"$holder_ready_file") 2>/dev/null; then
            aiur_build_gate_stop_holder "$holder_pid"
            rm -f "$command_pid_file" "$command_ready_file" "$command_status_file" \
              "$holder_ready_file" "$holder_started_file" 2>/dev/null || true
            aiur_build_gate_release_linux_owner "$slot_owner" || true
            exec {slot_fd}>&-
            aiur_build_gate_fail "lease_holder_ready_failed" "$holder_ready_file"
            return 125
          fi

          if ! aiur_build_gate_wait_for_holder_file "$command_pid_file" "$holder_pid" ||
            ! IFS= read -r command_pgid <"$command_pid_file" ||
            [[ ! $command_pgid =~ ^[1-9][0-9]*$ ]]; then
            aiur_build_gate_stop_holder "$holder_pid"
            rm -f "$command_pid_file" "$command_ready_file" "$command_status_file" \
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
            rm -f "$command_pid_file" "$command_ready_file" "$command_status_file" \
              "$holder_ready_file" "$holder_started_file" 2>/dev/null || true
            aiur_build_gate_release_linux_owner "$slot_owner" || true
            exec {slot_fd}>&-
            return 125
          fi

          if ! (set -o noclobber; : >"$command_ready_file") 2>/dev/null; then
            aiur_build_gate_stop_holder "$holder_pid"
            rm -f "$command_pid_file" "$command_ready_file" "$command_status_file" \
              "$holder_ready_file" "$holder_started_file" 2>/dev/null || true
            aiur_build_gate_release_linux_owner "$slot_owner" || true
            exec {slot_fd}>&-
            aiur_build_gate_fail "command_ready_failed" "$command_ready_file"
            return 125
          fi

          # The subreaper now owns the lock independently from BEAM and will
          # retain it across process-group changes and double-forked children.
          exec {slot_fd}>&-

          if ! status=$(
            aiur_build_gate_wait_for_command_status "$command_status_file" "$holder_pid"
          ); then
            aiur_build_gate_stop_holder "$holder_pid"
            rm -f "$command_pid_file" "$command_ready_file" "$command_status_file" \
              "$holder_ready_file" "$holder_started_file" 2>/dev/null || true
            aiur_build_gate_release_linux_owner "$slot_owner" || true
            aiur_build_gate_fail "lease_holder_status_failed" "$gate_dir"
            return 125
          fi
          rm -f "$command_status_file" 2>/dev/null || true
          result=${status%% *}
          retained=${status##* }

          if ((retained == 1)); then
            aiur_build_gate_log \
              "lease_retained slot=$slot status=$result holder_pid=$holder_pid command_pgid=$command_pgid"
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

  aiur_build_gate_run() {
    local strategy_result

    if aiur_build_gate_linux_locks; then
      aiur_build_gate_run_linux "$@"
    else
      strategy_result=$?

      if ((strategy_result == 1)); then
        aiur_build_gate_run_pid "$@"
      else
        return "$strategy_result"
      fi
    fi
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
