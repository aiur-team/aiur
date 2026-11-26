#!/usr/bin/env bash
# shellcheck shell=bash
#
# Staged development release builds. Sourced by scripts/aiurdev after the
# toolchain and layout helpers; functions share that shim's variables.

write_release_stamp() {
  local source_sha="$1" deps_lock_sha="$2" stamp_file="${3:-$release_stamp}" dirty="unknown"

  if repo_is_git_root; then
    if [ -n "$(git -C "$repo_root" status --porcelain 2>/dev/null)" ]; then
      dirty="yes"
    else
      dirty="no"
    fi
  fi

  printf 'repo_root=%s\nsource_sha=%s\ndeps_lock_sha=%s\ndirty=%s\nbuilt_at=%s\n' \
    "$repo_root" "$source_sha" "$deps_lock_sha" "$dirty" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >"$stamp_file"
}

release_complete() {
  local candidate="$1" release_vsn epmd epmd_found=0

  [ -x "$candidate/bin/aiur" ] || return 1
  [ -r "$candidate/releases/start_erl.data" ] || return 1

  release_vsn="$(cut -d' ' -f2 "$candidate/releases/start_erl.data" 2>/dev/null || true)"
  [ -n "$release_vsn" ] || return 1
  [ -x "$candidate/releases/$release_vsn/elixir" ] || return 1
  [ -r "$candidate/releases/$release_vsn/start_clean.boot" ] || return 1
  [ -r "$candidate/releases/$release_vsn/vm.args" ] || return 1
  [ -r "$candidate/releases/$release_vsn/sys.config" ] || return 1

  for epmd in "$candidate"/erts-*/bin/epmd; do
    [ -x "$epmd" ] && epmd_found=1 && break
  done
  [ "$epmd_found" -eq 1 ] || return 1
}

release_ready() {
  [ -x "$elixir_dir/bin/aiur" ] || return 1
  release_complete "$release_dir"
}

build_aiur() {
  local log_file status=0 source_sha lock_sha staging_release previous_release staging_launcher

  require_mise || return 64
  source_sha="$(repo_head_sha)"
  lock_sha="$(elixir_deps_lock_sha || true)"
  staging_release="$elixir_dir/_build/dev/rel/.aiur-staging-$$"
  previous_release="$elixir_dir/_build/dev/rel/.aiur-previous-$$"
  staging_launcher="$elixir_dir/bin/.aiur-staging-$$"
  echo "🔨 rebuilding bin/aiur (compile + release)" >&2
  log_file="$(mktemp "${TMPDIR:-/tmp}/aiurdev-release.XXXXXX")"

  rm -rf "$staging_release" "$previous_release" "$staging_launcher"
  if (build_layout_assets "$repo_root" "$mise_bin" exec -- && cd "$elixir_dir" && "$mise_bin" exec -- mix compile --force && AIUR_MIX_RELEASE_FINAL_DIR="$release_dir" AIUR_MIX_CLI_LAUNCHER_PATH="$staging_launcher" "$mise_bin" exec -- mix release --overwrite --path "$staging_release") >"$log_file" 2>&1; then
    status=0
  else
    status=$?
  fi

  grep -v -E "^(\* assembling|\* skipping runtime|Generated aiur app|Release created at|    _build|    # |Once the release is running:|To list all commands:|$)" "$log_file" >&2 || true
  rm -f "$log_file"

  if [ "$status" -ne 0 ]; then
    echo "❌ aiur release rebuild failed; keeping the previous release" >&2
    rm -rf "$staging_release" "$staging_launcher"
    return "$status"
  fi

  if ! release_complete "$staging_release" || [ ! -x "$staging_launcher" ]; then
    echo "❌ aiur release rebuild did not produce a complete release; keeping the previous release" >&2
    rm -rf "$staging_release" "$staging_launcher"
    return 1
  fi

  write_release_stamp "$source_sha" "${lock_sha:-unknown}" "$staging_release/AIUR_BUILD_STAMP"
  mv "$release_dir" "$previous_release" 2>/dev/null || true
  if ! mv "$staging_release" "$release_dir"; then
    [ ! -d "$previous_release" ] || mv "$previous_release" "$release_dir"
    echo "❌ aiur release swap failed; keeping the previous release" >&2
    rm -rf "$staging_release" "$staging_launcher"
    return 1
  fi

  if ! mv "$staging_launcher" "$elixir_dir/bin/aiur"; then
    rm -rf "$release_dir"
    [ ! -d "$previous_release" ] || mv "$previous_release" "$release_dir"
    echo "❌ aiur launcher swap failed; keeping the previous release" >&2
    return 1
  fi

  rm -rf "$previous_release"
}

release_matches_deps_lock() {
  local lock_sha stamped

  lock_sha="$(elixir_deps_lock_sha || printf unknown)"
  stamped="$(read_stamp_field deps_lock_sha "$release_stamp" || true)"
  [ "$stamped" = "$lock_sha" ]
}
