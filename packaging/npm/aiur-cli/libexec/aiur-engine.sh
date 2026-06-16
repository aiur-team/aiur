#!/usr/bin/env bash
#
# Shared aiur launcher engine.
#
# This file owns every aiur subcommand (init, run/default/<profile>, --bg, stop,
# list, status, pause, resume, build, sweep, --help). Both the installed `aiur`
# (packaging/npm/aiur-cli) and the dev `aiurdev` (scripts/aiurdev) exec this one
# engine, differing only in their **distribution identity** and which release
# directory they run.
#
# Identity is read from the environment so the two callers keep their own
# node/cookie/session naming without forking the command logic. Unset values
# default to the installed `aiur` identity, so the installed wrapper stays thin.
#
#   AIUR_RELEASE_DIR    release dir whose bin/aiur is exec'd (required at run time)
#   AIUR_NODE_PREFIX    BEAM node short-name prefix          (default: aiur)
#   AIUR_BG_STATE_DIR   cookie + background-state dir         (default: ~/.config/aiur)
#   AIUR_SESSION_PREFIX tmux session-name prefix             (default: $AIUR_NODE_PREFIX)
#   AIUR_PROFILES_FILE  profiles file                        (default: ~/.config/aiur/aiur.profiles)
#   AIUR_RELEASE_NODE   full node name                       (default: <prefix>-$USER@127.0.0.1)
#
# Command extraction from scripts/aiurdev lands in a follow-up unit; this file
# currently owns only identity resolution + the internal `__identity` probe the
# tests assert against.

set -euo pipefail

# Resolve the distribution identity, filling installed-`aiur` defaults for any
# unset var. Idempotent and export-only: callers (aiurdev / installed aiur) set
# their overrides before sourcing/exec'ing the engine.
aiur_resolve_identity() {
  local config_home="${XDG_CONFIG_HOME:-$HOME/.config}"

  : "${AIUR_NODE_PREFIX:=aiur}"
  : "${AIUR_BG_STATE_DIR:=$config_home/aiur}"
  : "${AIUR_SESSION_PREFIX:=$AIUR_NODE_PREFIX}"
  : "${AIUR_PROFILES_FILE:=$config_home/aiur/aiur.profiles}"
  : "${AIUR_RELEASE_NODE:=${AIUR_NODE_PREFIX}-${USER}@127.0.0.1}"
  : "${AIUR_COOKIE_FILE:=$AIUR_BG_STATE_DIR/cookie}"

  export AIUR_NODE_PREFIX AIUR_BG_STATE_DIR AIUR_SESSION_PREFIX \
    AIUR_PROFILES_FILE AIUR_RELEASE_NODE AIUR_COOKIE_FILE
}

# Print the resolved identity as KEY=VALUE lines (used by tests and `--doctor`).
aiur_print_identity() {
  aiur_resolve_identity
  printf 'AIUR_RELEASE_DIR=%s\n' "${AIUR_RELEASE_DIR:-}"
  printf 'AIUR_NODE_PREFIX=%s\n' "$AIUR_NODE_PREFIX"
  printf 'AIUR_BG_STATE_DIR=%s\n' "$AIUR_BG_STATE_DIR"
  printf 'AIUR_SESSION_PREFIX=%s\n' "$AIUR_SESSION_PREFIX"
  printf 'AIUR_PROFILES_FILE=%s\n' "$AIUR_PROFILES_FILE"
  printf 'AIUR_RELEASE_NODE=%s\n' "$AIUR_RELEASE_NODE"
  printf 'AIUR_COOKIE_FILE=%s\n' "$AIUR_COOKIE_FILE"
}

aiur_engine_main() {
  case "${1:-}" in
    __identity)
      aiur_print_identity
      ;;
    *)
      echo "aiur-engine: command surface not yet extracted (got: ${1:-<none>})" >&2
      return 64
      ;;
  esac
}

# Only dispatch when executed directly (allows sourcing the helpers in tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  aiur_engine_main "$@"
fi
