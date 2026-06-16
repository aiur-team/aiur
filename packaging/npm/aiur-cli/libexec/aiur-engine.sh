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
# There is a single `aiur` distribution identity (node/cookie/session). aiurdev
# shares it — the only thing that differs between installed `aiur` and dev
# `aiurdev` is which release is exec'd:
#
#   AIUR_RELEASE_DIR    release dir whose bin/aiur is exec'd (required at run time)
#
# The identity vars below resolve to the fixed `aiur` values; they remain
# overridable only so tests can redirect state to a temp dir:
#
#   AIUR_BG_STATE_DIR   cookie + background-state dir  (default: ~/.config/aiur)
#   AIUR_COOKIE_FILE    cookie file                    (default: $AIUR_BG_STATE_DIR/cookie)
#   AIUR_SESSION_PREFIX tmux session-name prefix       (default: aiur)
#   AIUR_PROFILES_FILE  profiles file                  (default: ~/.config/aiur/aiur.profiles)
#   AIUR_RELEASE_NODE   full node name                 (default: aiur-$USER@127.0.0.1)
#
# Command extraction from scripts/aiurdev lands in a follow-up unit; this file
# currently owns identity resolution, the BEAM distribution setup, and the
# internal `__identity` probe the tests assert against.

set -euo pipefail

# Resolve the distribution identity, filling installed-`aiur` defaults for any
# unset var. Idempotent and export-only: callers (aiurdev / installed aiur) set
# their overrides before sourcing/exec'ing the engine.
aiur_resolve_identity() {
  local config_home="${XDG_CONFIG_HOME:-$HOME/.config}"

  : "${AIUR_BG_STATE_DIR:=$config_home/aiur}"
  : "${AIUR_COOKIE_FILE:=$AIUR_BG_STATE_DIR/cookie}"
  : "${AIUR_SESSION_PREFIX:=aiur}"
  : "${AIUR_PROFILES_FILE:=$config_home/aiur/aiur.profiles}"
  : "${AIUR_RELEASE_NODE:=aiur-${USER}@127.0.0.1}"

  export AIUR_BG_STATE_DIR AIUR_COOKIE_FILE AIUR_SESSION_PREFIX \
    AIUR_PROFILES_FILE AIUR_RELEASE_NODE
}

# Print the resolved identity as KEY=VALUE lines (used by tests and `--doctor`).
aiur_print_identity() {
  aiur_resolve_identity
  printf 'AIUR_RELEASE_DIR=%s\n' "${AIUR_RELEASE_DIR:-}"
  printf 'AIUR_BG_STATE_DIR=%s\n' "$AIUR_BG_STATE_DIR"
  printf 'AIUR_SESSION_PREFIX=%s\n' "$AIUR_SESSION_PREFIX"
  printf 'AIUR_PROFILES_FILE=%s\n' "$AIUR_PROFILES_FILE"
  printf 'AIUR_RELEASE_NODE=%s\n' "$AIUR_RELEASE_NODE"
  printf 'AIUR_COOKIE_FILE=%s\n' "$AIUR_COOKIE_FILE"
}

# --- BEAM distribution (cookie + named node) ---------------------------------
#
# A stable secret cookie scoped to the identity's state dir, plus a
# 127.0.0.1-pinned long node name so neither BEAM resolves a hostname. Both the
# foreground TUI and any helper node that RPCs into a running Aiur authenticate
# with this cookie + node. Parameterized by AIUR_COOKIE_FILE / AIUR_RELEASE_NODE
# (resolved from the distribution identity).

ensure_bg_state_dir() {
  aiur_resolve_identity
  mkdir -p "$AIUR_BG_STATE_DIR"
}

ensure_erlang_cookie() {
  aiur_resolve_identity
  ensure_bg_state_dir

  local cookie_file="$AIUR_COOKIE_FILE"

  if [ ! -f "$cookie_file" ]; then
    (
      umask 0177
      tmp_file="$(mktemp "$AIUR_BG_STATE_DIR/cookie.XXXXXX")"
      head -c 32 /dev/urandom | base64 | tr -d '\n=+/' | head -c 32 >"$tmp_file"
      mv "$tmp_file" "$cookie_file"
    )
    chmod 0400 "$cookie_file"
  fi

  if [ ! -r "$cookie_file" ]; then
    echo "❌ $cookie_file is not readable" >&2
    return 1
  fi

  if [ "$(stat -c '%U' "$cookie_file" 2>/dev/null || stat -f '%Su' "$cookie_file")" != "$USER" ]; then
    echo "❌ $cookie_file is not owned by $USER" >&2
    return 1
  fi

  local size
  size="$(wc -c <"$cookie_file" | tr -d ' ')"

  if [ "$size" -lt 16 ]; then
    echo "❌ $cookie_file is shorter than 16 bytes" >&2
    return 1
  fi

  printf '%s' "$cookie_file"
}

prepare_distribution() {
  aiur_resolve_identity

  local cookie_file
  cookie_file="$(ensure_erlang_cookie)" || return 1

  local cookie
  cookie="$(cat "$cookie_file")"

  export RELEASE_DISTRIBUTION="name"
  export RELEASE_NODE="$AIUR_RELEASE_NODE"
  export RELEASE_COOKIE="$cookie"
  # Pin the distribution listener to 127.0.0.1 too, matching the node-name IP.
  # {127,0,0,1} is the Erlang tuple — unquoted because bash inside the
  # surrounding double quotes does not brace-expand it.
  export ERL_AFLAGS=" -proto_dist inet_tcp -kernel inet_dist_use_interface {127,0,0,1}"
  export ERL_EPMD_ADDRESS="127.0.0.1"
  export AIUR_NODE="$RELEASE_NODE"
  # Export the cookie under our own name so the pane-side wrapper can pick it
  # up even when it replaces ERL_AFLAGS for its own unique node name.
  export AIUR_ERLANG_COOKIE="$RELEASE_COOKIE"
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
