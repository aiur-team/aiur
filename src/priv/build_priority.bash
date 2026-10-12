# Build priority applies to the command, leaving admission and lease holders responsive.
aiur_build_gate_priority_args() {
  local adjustment=${AIUR_BUILD_NICE:-10}
  aiur_build_gate_prioritized_command=("$@")

  if [[ ! $adjustment =~ ^([0-9]|1[0-9])$ ]]; then
    aiur_build_gate_fail "invalid_build_nice" "$adjustment"
    return 125
  fi

  if ((adjustment != 0)); then
    if ! command -v nice >/dev/null 2>&1; then
      aiur_build_gate_fail "nice_unavailable" "nice"
      return 125
    fi
    aiur_build_gate_prioritized_command=(nice -n "$adjustment" "$@")
  fi
}

aiur_build_gate_execute_with_priority() {
  aiur_build_gate_priority_args "$@" || return $?
  "${aiur_build_gate_prioritized_command[@]}"
}

aiur_build_gate_run_with_priority() {
  local phase=$1 executable=$2
  shift 2
  aiur_build_gate_priority_args "$executable" "$@" || return $?
  aiur_build_gate_run "$phase" "$executable" "$@"
}
