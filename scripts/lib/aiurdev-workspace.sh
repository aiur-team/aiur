#!/usr/bin/env bash
# shellcheck shell=bash
#
# aiurdev agent-workspace IR sandbox.
# Sourced by scripts/aiurdev (dev-only; not part of the npm package). Shares its
# variables and functions; do not execute directly.

in_agent_workspace_tree() {
  local marker="${AIUR_AGENT_WORKSPACE:-}"
  if [ -n "$marker" ]; then
    printf '%s\n' "$marker"
    return 0
  fi

  case "$repo_root" in
    */aiur-workspaces/*)
      printf '%s\n' "$repo_root"
      return 0
      ;;
  esac

  case "$PWD" in
    */aiur-workspaces/*)
      printf '%s\n' "$PWD"
      return 0
      ;;
  esac

  return 1
}

agent_ir_port() {
  local seed="$1" checksum
  checksum="$(printf '%s' "$seed" | cksum | awk '{print $1}')"
  printf '%s\n' "$((45000 + (checksum % 10000)))"
}

enable_agent_ir_sandbox() {
  local marker="$1"
  local pin_bridge_port="${2:-0}"
  local sandbox_root="${AIUR_AGENT_IR_ROOT:-$marker/.aiur-agent-ir}"
  local logs_parent="$sandbox_root/logs"
  local state_dir="$sandbox_root/state"
  local runtime_dir="$sandbox_root/runtime"
  local config_dir="$sandbox_root/config"
  local bridge_port

  mkdir -p "$logs_parent" "$state_dir" "$runtime_dir" "$config_dir"

  export AIUR_AGENT_IR_SANDBOX=1
  export AIUR_AGENT_IR_ROOT="$sandbox_root"
  export AIUR_AGENT_IR_LOGS_PARENT="$logs_parent"
  export AIUR_BG_STATE_DIR="$state_dir"
  export AIUR_COOKIE_FILE="$state_dir/cookie"
  export AIUR_PROFILES_FILE="$config_dir/aiur.profiles"
  export AIUR_AGENT_IR_XDG_CONFIG_HOME="$config_dir"
  export AIUR_AGENT_IR_XDG_STATE_HOME="$state_dir"
  export XDG_RUNTIME_DIR="$runtime_dir"
  export AIUR_LOGS_ROOT="$logs_parent/$(date -u +%Y%m%dT%H%M%SZ)-$$"

  if [ "$pin_bridge_port" -eq 1 ] && [ -z "${AIUR_OPENCODE_BRIDGE_PORT:-}" ]; then
    bridge_port="$(agent_ir_port "$marker")"
    export AIUR_OPENCODE_BRIDGE_PORT="$bridge_port"
  fi

  echo "🧪 agent IR sandbox: $sandbox_root" >&2
  echo "   workspace marker: $marker" >&2
}

apply_agent_ir_xdg_env() {
  if [ "${AIUR_AGENT_IR_SANDBOX:-}" = "1" ]; then
    export XDG_CONFIG_HOME="${AIUR_AGENT_IR_XDG_CONFIG_HOME:?}"
    export XDG_STATE_HOME="${AIUR_AGENT_IR_XDG_STATE_HOME:?}"
  fi
}
