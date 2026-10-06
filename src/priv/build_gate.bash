#!/usr/bin/env bash
# Sourced through BASH_ENV for local Aiur coding-agent shells and by the
# shell-independent Mix/mise command wrappers. It intentionally gates only Mix
# compile/test work; editing, Git, and other shell commands stay free to run
# while a verification command holds a lease.

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

  aiur_build_gate_ambiguous_command() {
    aiur_build_gate_log "gate_error reason=ambiguous_command command=$* status=125"
    return 125
  }

  aiur_build_gate_mix_phase() {
    local token task phase="" expect_task=0

    if aiur_build_gate_needs_slot "${1:-}"; then
      printf '%s\n' "$1"
      return 0
    fi

    [[ ${1:-} == do ]] || return 1
    shift

    while (($#)); do
      case $1 in
        --app)
          shift
          (($#)) && [[ -n $1 && $1 != -* ]] || return 125
          shift
          ;;
        --app=*)
          [[ -n ${1#--app=} ]] || return 125
          shift
          ;;
        *) break ;;
      esac
    done

    (($#)) || return 125
    expect_task=1

    for token in "$@"; do
      if ((expect_task == 1)); then
        [[ $token != + && $token != , ]] || return 125
        [[ $token != *,, ]] || return 125

        task=${token%,}
        [[ -n $task && $task != *","* ]] || return 125
        if [[ -z $phase ]] && aiur_build_gate_needs_slot "$task"; then
          phase=$task
        fi

        if [[ $token == *, ]]; then
          expect_task=1
        else
          expect_task=0
        fi
      else
        case $token in
          + | ,) expect_task=1 ;;
          *,,) return 125 ;;
          *,) expect_task=1 ;;
        esac
      fi
    done

    ((expect_task == 0)) || return 125
    [[ -n $phase ]] || return 1
    printf '%s\n' "$phase"
  }

  aiur_build_gate_is_mix_command() {
    local candidate=${1:-} real_mix

    [[ $candidate == mix ]] && return 0
    [[ $candidate == */* && -x $candidate ]] || return 1
    real_mix=$(aiur_build_gate_real_command mix) || return 1
    [[ $candidate -ef $real_mix ]]
  }

  aiur_build_gate_env_runs_mix() {
    [[ ${1##*/} == env ]] || return 1
    shift

    while (($#)); do
      case $1 in
        --)
          shift
          break
          ;;
        -i | --ignore-environment | -0 | --null | *=*) shift ;;
        -u | --unset | -C | --chdir)
          shift
          (($#)) || return 125
          shift
          ;;
        --unset=* | --chdir=*) shift ;;
        -*) return 125 ;;
        *) break ;;
      esac
    done

    (($#)) && aiur_build_gate_is_mix_command "$1"
  }

  aiur_build_gate_mise_command_string_phase() {
    local command_string=$1
    local -a words=()

    if [[ $command_string == *[';&|<>$`()\']* ]] ||
      [[ $command_string == *'"'* || $command_string == *'*'* ||
        $command_string == *'?'* || $command_string == *'['* ||
        $command_string == *']'* || $command_string == *'~'* ||
        $command_string == *$'\n'* ]]; then
      return 125
    fi

    read -r -a words <<<"$command_string"
    ((${#words[@]})) || return 1

    if aiur_build_gate_is_mix_command "${words[0]}"; then
      aiur_build_gate_mix_phase "${words[@]:1}"
    else
      aiur_build_gate_env_runs_mix "${words[@]}"
      case $? in
        0 | 125) return 125 ;;
        *) return 1 ;;
      esac
    fi
  }

  aiur_build_gate_mise_phase() {
    local command=${1:-} command_string="" command_source="" option
    shift || true

    case $command in
      exec | x) ;;
      *) return 1 ;;
    esac

    while (($#)); do
      option=$1

      case $option in
        --)
          [[ -z $command_source ]] || return 125
          shift
          (($#)) || return 1
          if ! aiur_build_gate_is_mix_command "${1:-}"; then
            aiur_build_gate_env_runs_mix "$@"
            case $? in
              0 | 125) return 125 ;;
              *) return 1 ;;
            esac
          fi
          shift
          aiur_build_gate_mix_phase "$@"
          return $?
          ;;
        -c | --command)
          [[ -z $command_source ]] || return 125
          shift
          (($#)) || return 125
          command_string=$1
          command_source=string
          shift
          ;;
        --command=*)
          [[ -z $command_source && -n ${option#--command=} ]] || return 125
          command_string=${option#--command=}
          command_source=string
          shift
          ;;
        -j | --jobs | -C | --cd | -E | --env | --allow-env | --allow-net | --allow-read | --allow-write)
          shift
          (($#)) || return 125
          shift
          ;;
        --jobs=* | --cd=* | --env=* | --allow-env=* | --allow-net=* | --allow-read=* | --allow-write=*)
          shift
          ;;
        -*) shift ;;
        *)
          [[ -z $command_source ]] || return 125
          aiur_build_gate_is_mix_command "$option" && return 125
          shift
          ;;
      esac
    done

    [[ $command_source == string ]] || return 1
    aiur_build_gate_mise_command_string_phase "$command_string"
  }

  # Mirrors the marker in build_gate_command_wrapper.bash. A candidate carrying
  # it is another copy of the gate wrapper, whatever name it was installed
  # under, and handing the command to it would loop or 127 (#2542).
  aiur_build_gate_wrapper_marker='aiur-build-gate-command-wrapper-marker'

  aiur_build_gate_is_wrapper_file() {
    [[ -r $1 ]] || return 1
    head -c 4096 "$1" 2>/dev/null | grep -q "$aiur_build_gate_wrapper_marker" 2>/dev/null
  }

  aiur_build_gate_path_command() {
    local command_name=$1 candidate
    local wrapper_path="${AIUR_BUILD_GATE_BIN:-}/$command_name"

    while IFS= read -r candidate; do
      if [[ -n ${AIUR_BUILD_GATE_BIN:-} && $candidate -ef $wrapper_path ]]; then
        continue
      fi

      aiur_build_gate_is_wrapper_file "$candidate" && continue

      printf '%s\n' "$candidate"
      return 0
    done < <(type -aP "$command_name" 2>/dev/null)

    return 1
  }

  # PATH first, then the toolchain manager. `mise which` answers for the
  # directory's tool configuration, which is the toolchain the caller meant; it
  # is the escape from a PATH whose only entry for this name is a wrapper.
  aiur_build_gate_real_command() {
    local command_name=$1 mise_binary resolved

    if resolved=$(aiur_build_gate_path_command "$command_name"); then
      printf '%s\n' "$resolved"
      return 0
    fi

    mise_binary=$(aiur_build_gate_path_command mise) || return 1
    resolved=$("$mise_binary" which "$command_name" 2>/dev/null) || return 1

    [[ -n $resolved && -x $resolved ]] || return 1
    aiur_build_gate_is_wrapper_file "$resolved" && return 1

    printf '%s\n' "$resolved"
  }

  aiur_build_gate_owner_pid() {
    local owner_file=$1 line

    [[ -f $owner_file ]] || return 1

    while IFS= read -r line; do
      if [[ $line =~ ^pid=([1-9][0-9]*)$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
      fi
    done <"$owner_file"

    return 1
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

  # Acquisition time stamped into every v2 lease record so an operator surface
  # can report how long a lease has been held. Best effort only: a missing clock
  # writes 0 (unknown) rather than failing the build — the timestamp is
  # advisory, never part of admission.
  aiur_build_gate_started_at() {
    aiur_build_gate_now_seconds || printf '0\n'
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
    local path=$1 contents python_binary helper result metadata_fd

    if [[ ! -e $path && ! -L $path ]]; then
      return 1
    fi

    python_binary=$(type -P python3)
    helper="$(dirname "${BASH_SOURCE[0]}")/build_gate_holder.py"

    if [[ -n $python_binary ]]; then
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
    fi

    # The portable PID fallback must not acquire an undeclared Python runtime.
    # Opening read/write avoids FIFO open blocking; validating /dev/fd checks
    # the opened object rather than trusting a pathname lstat/open sequence.
    if [[ -L $path ]] || ! exec {metadata_fd}<>"$path" 2>/dev/null; then
      aiur_build_gate_fail "metadata_not_regular" "$path"
      return 125
    fi

    if [[ ! -f /dev/fd/$metadata_fd ]]; then
      exec {metadata_fd}>&-
      aiur_build_gate_fail "metadata_not_regular" "$path"
      return 125
    fi

    contents=$(cat <&"$metadata_fd")
    result=$?
    exec {metadata_fd}>&-

    if ((result != 0)) || ((${#contents} >= 4096)); then
      aiur_build_gate_fail "metadata_not_regular" "$path"
      return 125
    fi

    printf '%s\n' "$contents"
  }

  aiur_build_gate_live_lease() {
    local gate_dir=${AIUR_BUILD_GATE_DIR:-} lease_path=${AIUR_BUILD_GATE_LEASE_PATH:-}
    local lease_token=${AIUR_BUILD_GATE_LEASE_TOKEN:-} contents line recorded_token=""

    if [[ -z $lease_path && -z $lease_token ]]; then
      return 1
    fi

    if [[ -z $gate_dir || -z $lease_path || -z $lease_token ]] ||
      [[ ! $lease_token =~ ^[A-Za-z0-9._-]+$ ]] ||
      [[ $lease_path != "$gate_dir"/* ]] ||
      [[ ${lease_path#"$gate_dir"/} == */* ]]; then
      aiur_build_gate_fail "lease_marker_invalid" "${lease_path:-unset}"
      return 125
    fi

    if contents=$(aiur_build_gate_read_regular "$lease_path"); then
      while IFS= read -r line; do
        if [[ $line == token=* ]]; then
          [[ -z $recorded_token ]] || {
            aiur_build_gate_fail "lease_marker_invalid" "$lease_path"
            return 125
          }
          recorded_token=${line#token=}
        fi
      done <<<"$contents"
    else
      case $? in
        1) return 1 ;;
        *) return 125 ;;
      esac
    fi

    [[ $recorded_token == "$lease_token" ]]
  }

  aiur_build_gate_execute_under_lease() {
    local lease_path=$1 lease_token=$2
    shift 2

    AIUR_BUILD_GATE_LEASE_PATH=$lease_path \
      AIUR_BUILD_GATE_LEASE_TOKEN=$lease_token \
      "$@"
  }

  aiur_build_gate_execute_with_ephemeral_lease() {
    local gate_dir=$1 phase=$2 executable=$3 lease_path lease_token result
    shift 3

    lease_path=$(mktemp "$gate_dir/.active-lease.XXXXXXXXXX" 2>/dev/null) || {
      aiur_build_gate_fail "lease_marker_create_failed" "$gate_dir"
      return 125
    }
    lease_token=${lease_path##*/}
    lease_token=${lease_token#.active-lease.}

    if ! printf 'version=2\ntoken=%s\nphase=%s\ncommand=%s\nstarted_at=%s\n' \
      "$lease_token" "$phase" "$*" "$(aiur_build_gate_started_at)" >"$lease_path"; then
      rm -f "$lease_path" 2>/dev/null || true
      aiur_build_gate_fail "lease_marker_write_failed" "$lease_path"
      return 125
    fi

    if aiur_build_gate_execute_under_lease "$lease_path" "$lease_token" "$executable" "$@"; then
      result=0
    else
      result=$?
    fi

    if ! rm -f "$lease_path" 2>/dev/null; then
      aiur_build_gate_fail "lease_marker_release_failed" "$lease_path"
      return 125
    fi

    return "$result"
  }

  aiur_build_gate_run_or_reuse() {
    local phase=$1 executable=$2 lease_result
    shift 2

    if aiur_build_gate_live_lease; then
      "$executable" "$@"
    else
      lease_result=$?

      if ((lease_result == 1)); then
        unset AIUR_BUILD_GATE_LEASE_PATH AIUR_BUILD_GATE_LEASE_TOKEN
        aiur_build_gate_run "$phase" "$executable" "$@"
      else
        return "$lease_result"
      fi
    fi
  }

  aiur_build_gate_write_reserved_regular() {
    local python_binary=$1 path=$2 contents=$3 helper

    helper="$(dirname "${BASH_SOURCE[0]}")/build_gate_holder.py"
    "$python_binary" "$helper" --write-reserved-regular "$path" "$contents" 2>/dev/null
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

    # A Linux subreaper becomes the parent of daemonized Mix descendants. It
    # owns the slot descriptor, reports the direct command status promptly,
    # then keeps the lease until every adopted descendant has exited.
    holder_script="$(dirname "${BASH_SOURCE[0]}")/build_gate_holder.py"

    exec "$python_binary" "$holder_script" "$ready_path" "$started_path" "$command_pid_path" \
      "$command_ready_path" "$status_path" "$status_ack_path" "$owner_path" "$token" \
      "$parent_pid" "$agent_pgid" "$slot_fd" "$handshake_seconds" "$ack_seconds" "$@"
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

  aiur_build_gate_elixir_mix_phase() {
    while (($#)); do
      case $1 in
        -S)
          shift
          [[ ${1:-} == mix ]] || return 1
          shift
          aiur_build_gate_mix_phase "$@"
          return $?
          ;;

        -e | -r | -pr | -pa | -pz | --app | --erl | --cookie)
          shift
          (($#)) || return 1
          shift
          ;;

        --) return 1 ;;
        -*) shift ;;
        *) return 1 ;;
      esac
    done

    return 1
  }

  aiur_build_gate_elixir_uses_mix() {
    while (($#)); do
      case $1 in
        -S)
          shift
          [[ ${1:-} == mix ]]
          return $?
          ;;
        -e | -r | -pr | -pa | -pz | --app | --erl | --cookie)
          shift
          (($#)) || return 1
          shift
          ;;
        --) return 1 ;;
        -*) shift ;;
        *) return 1 ;;
      esac
    done

    return 1
  }

  aiur_build_gate_path_without_wrapper() {
    local remaining=${PATH:-} path_entry filtered_path= separator= more

    while :; do
      path_entry=${remaining%%:*}

      if [[ $remaining == *:* ]]; then
        remaining=${remaining#*:}
        more=1
      else
        more=0
      fi

      [[ -n $path_entry ]] || path_entry=.

      if [[ ! $path_entry/elixir -ef ${AIUR_BUILD_GATE_BIN:-}/elixir ]] &&
        ! aiur_build_gate_is_wrapper_file "$path_entry/elixir"; then
        filtered_path+="$separator$path_entry"
        separator=:
      fi

      ((more == 1)) || break
    done

    printf '%s\n' "$filtered_path"
  }

  aiur_build_gate_command_unavailable() {
    aiur_build_gate_log \
      "gate_error reason=command_unavailable command=$1 wrapper=${AIUR_BUILD_GATE_BIN:-}/$1 status=127"
    aiur_build_gate_log \
      "hint run=\"${AIUR_BUILD_GATE_BIN:-}/$1 __aiur_build_gate_self_check__\""
    return 127
  }

  # ExUnit forces `max_cases: 1` whenever `--trace` is present, silently
  # overriding an explicit `--max-cases N` on the same command line. Strip
  # `--trace` from a mix-level argument list when the two conflict (N > 1):
  # the agent asked for parallelism explicitly and `--trace` is a debugging
  # aid for a single test (#2311). Sets `aiur_build_gate_normalized_args` to
  # the rewritten list; a non-conflicting command is copied verbatim.
  aiur_build_gate_mix_args_without_trace_conflict() {
    aiur_build_gate_normalized_args=()
    local -a args=("$@")
    local i n arg has_trace=0 max_cases=""
    n=${#args[@]}

    for ((i = 0; i < n; i++)); do
      arg=${args[i]}

      if [[ $arg == --max-cases ]]; then
        ((i + 1 < n)) && max_cases=${args[i + 1]}
      elif [[ $arg == --max-cases=* ]]; then
        max_cases=${arg#--max-cases=}
      elif [[ $arg == --trace ]]; then
        has_trace=1
      fi
    done

    if [[ $has_trace == 1 && $max_cases =~ ^[1-9][0-9]*$ && $max_cases -gt 1 ]]; then
      for ((i = 0; i < n; i++)); do
        arg=${args[i]}
        [[ $arg == --trace ]] || aiur_build_gate_normalized_args+=("$arg")
      done
      aiur_build_gate_log "trace_stripped reason=conflict_with_max_cases max_cases=$max_cases"
    else
      aiur_build_gate_normalized_args=("${args[@]}")
    fi
  }

  # Normalize `elixir -S mix ...` arguments, rewriting only the mix-level
  # flags after the `mix` token (mirrors aiur_build_gate_elixir_mix_phase).
  # Initialized verbatim so every early return leaves a non-mix elixir
  # invocation untouched.
  aiur_build_gate_normalize_elixir_args() {
    aiur_build_gate_normalized_args=("$@")
    local -a args=("$@")
    local i n arg
    n=${#args[@]}

    for ((i = 0; i < n; i++)); do
      arg=${args[i]}

      case $arg in
        -S)
          if ((i + 1 < n)) && [[ ${args[i + 1]} == mix ]]; then
            aiur_build_gate_mix_args_without_trace_conflict "${args[@]:i+2}"
            aiur_build_gate_normalized_args=("${args[@]:0:i}" -S mix "${aiur_build_gate_normalized_args[@]}")
          fi
          return 0
          ;;
        -e | -r | -pr | -pa | -pz | --app | --erl | --cookie)
          ((i + 1 < n)) || return 0
          i=$((i + 1))
          ;;
        --) return 0 ;;
        -*) ;;
        *) return 0 ;;
      esac
    done

    return 0
  }

  # Normalize `mise exec -- mix ...` arguments, rewriting only the mix-level
  # flags after `--` (mirrors aiur_build_gate_mise_phase's structural form).
  # `-c`/`--command` strings need no rewrite here: the nested `mix` invocation
  # they produce is normalized by the hook's `mix()` entry point. Initialized
  # verbatim so a non-mix `--` payload is passed through untouched.
  aiur_build_gate_normalize_mise_args() {
    aiur_build_gate_normalized_args=("$@")
    local -a args=("$@")
    local i n arg
    n=${#args[@]}

    for ((i = 0; i < n; i++)); do
      arg=${args[i]}

      if [[ $arg == -- ]]; then
        if ((i + 1 < n)) && aiur_build_gate_is_mix_command "${args[i + 1]}"; then
          aiur_build_gate_mix_args_without_trace_conflict "${args[@]:i+2}"
          aiur_build_gate_normalized_args=("${args[@]:0:i}" -- "${args[i + 1]}" "${aiur_build_gate_normalized_args[@]}")
        fi
        return 0
      fi
    done

    return 0
  }

  elixir() {
    local elixir_binary phase real_path classification
    elixir_binary=$(aiur_build_gate_real_command elixir)

    if [[ -z $elixir_binary ]]; then
      aiur_build_gate_command_unavailable elixir
      return $?
    fi

    aiur_build_gate_normalize_elixir_args "$@"
    set -- "${aiur_build_gate_normalized_args[@]}"

    if phase=$(aiur_build_gate_elixir_mix_phase "$@"); then
      classification=0
    else
      classification=$?
    fi

    case $classification in
      0)
        real_path=$(aiur_build_gate_path_without_wrapper)
        aiur_build_gate_run_or_reuse "$phase" env "PATH=$real_path" "$elixir_binary" "$@"
        ;;
      1)
        if aiur_build_gate_elixir_uses_mix "$@"; then
          real_path=$(aiur_build_gate_path_without_wrapper)
          PATH=$real_path "$elixir_binary" "$@"
        else
          "$elixir_binary" "$@"
        fi
        ;;
      *) aiur_build_gate_ambiguous_command elixir "$@" ;;
    esac
  }

  mix() {
    local mix_binary phase classification
    mix_binary=$(aiur_build_gate_real_command mix)

    if [[ -z $mix_binary ]]; then
      aiur_build_gate_command_unavailable mix
      return $?
    fi

    aiur_build_gate_mix_args_without_trace_conflict "$@"
    set -- "${aiur_build_gate_normalized_args[@]}"

    if phase=$(aiur_build_gate_mix_phase "$@"); then
      classification=0
    else
      classification=$?
    fi

    case $classification in
      0) aiur_build_gate_run_or_reuse "$phase" "$mix_binary" "$@" ;;
      1) "$mix_binary" "$@" ;;
      *) aiur_build_gate_ambiguous_command mix "$@" ;;
    esac
  }

  mise() {
    local mise_binary phase classification
    mise_binary=$(aiur_build_gate_real_command mise)

    if [[ -z $mise_binary ]]; then
      aiur_build_gate_command_unavailable mise
      return $?
    fi

    aiur_build_gate_normalize_mise_args "$@"
    set -- "${aiur_build_gate_normalized_args[@]}"

    if phase=$(aiur_build_gate_mise_phase "$@"); then
      classification=0
    else
      classification=$?
    fi

    case $classification in
      0) aiur_build_gate_run_or_reuse "$phase" "$mise_binary" "$@" ;;
      1) "$mise_binary" "$@" ;;
      *) aiur_build_gate_ambiguous_command mise "$@" ;;
    esac
  }
fi
