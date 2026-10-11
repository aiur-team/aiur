# Loaded by build_gate.bash. Owner, process-group, memory and clock helpers, regular-file IO and lease reuse.
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
  helper="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/build_gate_holder.py"

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
    aiur_build_gate_execute_with_priority "$@"
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
      aiur_build_gate_run_with_priority "$phase" "$executable" "$@"
    else
      return "$lease_result"
    fi
  fi
}

aiur_build_gate_write_reserved_regular() {
  local python_binary=$1 path=$2 contents=$3 helper

  helper="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/build_gate_holder.py"
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
