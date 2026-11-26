#!/usr/bin/env bash
# shellcheck shell=bash
#
# aiurdev toolchain: mise lookup, pinned opencode, Hex deps.
# Sourced by scripts/aiurdev (dev-only; not part of the npm package). Shares its
# variables and functions; do not execute directly.

require_mise() {
  if [ -z "$mise_bin" ] || [ ! -x "$mise_bin" ]; then
    echo "❌ mise not found on PATH. Install mise (https://mise.jdx.dev) or set AIUR_MISE_BIN." >&2
    return 64
  fi
}

# The release inherits this script's environment. Put the version pinned by
# this repository ahead of any globally-installed opencode so the server and
# its SQLite migrations use the schema Aiur has validated.
ensure_pinned_opencode() {
  local opencode_dir

  require_mise || return 64
  opencode_dir="$("$mise_bin" where -C "$repo_root" opencode 2>/dev/null || true)"

  if [ -z "$opencode_dir" ] || [ ! -x "$opencode_dir/opencode" ]; then
    echo "❌ pinned opencode is unavailable; run mise install in $repo_root" >&2
    return 64
  fi

  export PATH="$opencode_dir:$PATH"
}

requires_pinned_opencode() {
  local cmd="${1:-}"

  # Match the shared engine's dispatch boundary: only commands that can start
  # an Aiur session need OpenCode. Control and utility commands must remain
  # usable against an existing daemon when the local tool install is missing.
  case "$cmd" in
    "" | run | restart | --bg) return 0 ;;
    help | -h | -help | --h | --help | --version | --todo | --only | init | findings) return 1 ;;
    doctor | agents | alerts | status | set | pause | resume | stop | message | cleanup-stale | watch | reset-budget | epic | pre-pr) return 1 ;;
    -*) return 0 ;;
    *) [ -e "$cmd" ] ;;
  esac
}

elixir_deps_ready() {
  local deps_dir="$elixir_dir/deps" dep
  [ -d "$elixir_dir/_build" ] && [ -d "$deps_dir" ] || return 1
  [ -f "$elixir_dir/mix.lock" ] || return 0
  while IFS= read -r dep; do
    [ -n "$dep" ] && [ ! -d "$deps_dir/$dep" ] && return 1
  done < <(sed -n 's/^  "\([^"]*\)":.*/\1/p' "$elixir_dir/mix.lock")
  return 0
}

elixir_deps_lock_sha() {
  [ -r "$elixir_dir/mix.lock" ] || return 1
  { shasum -a 256 "$elixir_dir/mix.lock" 2>/dev/null || sha256sum "$elixir_dir/mix.lock"; } | awk '{print $1}'
}

elixir_deps_match_lock() {
  local lock_sha stamp="$elixir_dir/_build/dev/aiurdev-deps-lock-sha"

  [ -r "$stamp" ] || return 1
  lock_sha="$(elixir_deps_lock_sha)" || return 1
  [ "$(cat "$stamp")" = "$lock_sha" ]
}

ensure_elixir_deps() {
  if ! elixir_deps_ready || { [ -r "$elixir_dir/mix.lock" ] && ! elixir_deps_match_lock; }; then
    require_mise || return 64
    echo "🔨 fetching and compiling Hex dependencies" >&2
    if (cd "$elixir_dir" && "$mise_bin" exec -- mix deps.get && "$mise_bin" exec -- mix compile) >&2; then
      local lock_sha
      lock_sha="$(elixir_deps_lock_sha || true)"
      if [ -n "$lock_sha" ]; then
        mkdir -p "$elixir_dir/_build/dev"
        printf '%s\n' "$lock_sha" >"$elixir_dir/_build/dev/aiurdev-deps-lock-sha"
      fi
    else
      return $?
    fi
  fi
}
