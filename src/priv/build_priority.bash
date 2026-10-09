# Apply priority only when admitting a fresh lease; nested commands inherit it.
aiur_build_gate_run_with_priority() {
  local phase=$1 executable=$2 adjustment=${AIUR_BUILD_NICE:-10}
  shift 2

  if [[ ! $adjustment =~ ^([0-9]|1[0-9])$ ]]; then
    aiur_build_gate_fail "invalid_build_nice" "$adjustment"
    return 125
  fi

  if ((adjustment == 0)); then
    aiur_build_gate_run "$phase" "$executable" "$@"
  elif command -v nice >/dev/null 2>&1; then
    aiur_build_gate_run "$phase" nice -n "$adjustment" "$executable" "$@"
  else
    aiur_build_gate_fail "nice_unavailable" "nice"
    return 125
  fi
}
