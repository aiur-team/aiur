# Loaded by build_gate.bash; npm/npx Playwright CLIs use /usr/bin/env node.
node() (
  local node_binary script workspace browser_lock_fd browser=0
  node_binary=$(aiur_build_gate_real_command node) || {
    aiur_build_gate_command_unavailable node
    return $?
  }

  for script in "$@"; do
    case $script in
    */playwright/cli.js | */playwright-core/cli.js | */playwright/cli.mjs | */.bin/playwright | playwright)
      browser=1; break ;;
    esac
  done
  if ((browser == 0)); then
    "$node_binary" "$@"
    return $?
  fi

  workspace=${AIUR_BUILD_GATE_BIN%/.aiur-runtime/build-bin}
  if [[ ${AIUR_BROWSER_GATE_WORKSPACE:-} == "$workspace" ]] && aiur_build_gate_live_lease; then
    "$node_binary" "$@"
    return $?
  fi

  # Lock before host admission so one workspace cannot occupy multiple slots while waiting.
  if [[ -z ${AIUR_BUILD_GATE_BIN:-} || ! -d $workspace/.aiur-runtime ]] ||
    ! exec {browser_lock_fd}>"$workspace/.aiur-runtime/browser-test.lock"; then
    aiur_build_gate_fail browser_workspace_lock_unavailable "$workspace"
    return 125
  fi

  if ! command flock -n "$browser_lock_fd"; then
    aiur_build_gate_log "browser_workspace_wait workspace=$workspace"
    command flock -E 125 -w "${AIUR_BUILD_GATE_TIMEOUT_SECONDS:-900}" "$browser_lock_fd" || {
      aiur_build_gate_fail browser_workspace_lock_failed "$workspace"
      return 125
    }
  fi

  aiur_build_gate_run_or_reuse browser env "AIUR_BROWSER_GATE_WORKSPACE=$workspace" "$node_binary" "$@"
)
