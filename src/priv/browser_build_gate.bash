# Loaded by build_gate.bash; npm/npx Playwright CLIs use /usr/bin/env node.
node() (
  local node_binary script workspace browser_lock_fd browser=0 lock_result
  local timeout_seconds=${AIUR_BUILD_GATE_TIMEOUT_SECONDS:-900} started_seconds=$SECONDS
  node_binary=$(aiur_build_gate_real_command node) || {
    aiur_build_gate_command_unavailable node
    return $?
  }

  for script in "$@"; do
    case $script in
    */@playwright/test/cli.js | */playwright/cli.js | */playwright-core/cli.js | */playwright/cli.mjs | */.bin/playwright | playwright)
      browser=1; break ;;
    esac
  done
  if ((browser == 0)); then
    "$node_binary" "$@"
    return $?
  fi

  [[ $timeout_seconds =~ ^[0-9]+$ ]] || {
    aiur_build_gate_fail invalid_configuration "${AIUR_BUILD_GATE_DIR:-}"
    return 125
  }

  workspace=${AIUR_BUILD_GATE_BIN%/.aiur-runtime/build-bin}
  if [[ ${AIUR_BROWSER_GATE_WORKSPACE:-} == "$workspace" ]] && aiur_build_gate_live_lease; then
    "$node_binary" "$@"
    return $?
  fi

  # Lock before host admission so one workspace cannot occupy multiple slots while waiting.
  if [[ -z ${AIUR_BUILD_GATE_BIN:-} || ! -d $workspace/.aiur-runtime ]] ||
    ! exec {browser_lock_fd}>>"$workspace/.aiur-runtime/browser-test.lock"; then
    aiur_build_gate_fail browser_workspace_lock_unavailable "$workspace"
    return 125
  fi

  if ! command flock -n "$browser_lock_fd"; then
    aiur_build_gate_log "browser_workspace_wait workspace=$workspace"
    command flock -E 124 -w "$timeout_seconds" "$browser_lock_fd" || {
      lock_result=$?
      if ((lock_result == 124)); then
        aiur_build_gate_log "browser_workspace_timeout workspace=$workspace status=124"
        return 124
      fi
      aiur_build_gate_fail browser_workspace_lock_failed "$workspace"
      return 125
    }
  fi

  timeout_seconds=$((timeout_seconds - SECONDS + started_seconds))
  ((timeout_seconds >= 0)) || timeout_seconds=0
  AIUR_BUILD_GATE_TIMEOUT_SECONDS=$timeout_seconds aiur_build_gate_run_or_reuse browser env "AIUR_BROWSER_GATE_WORKSPACE=$workspace" "$node_binary" "$@"
)
