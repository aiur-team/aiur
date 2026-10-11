# Legacy config rejection, package versions, distribution identity, release resolution and argv round-trip. Sourced by aiur-engine.sh.

legacy_config_path() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --logs-root | --host | --port | --max-agents)
        if [ "$#" -ge 2 ]; then
          shift 2
        else
          shift
        fi
        ;;
      --)
        shift
        [ "$#" -gt 0 ] || return
        case "$1" in
          *.aiurconfig) printf '%s' "$1" ;;
        esac
        return
        ;;
      --logs-root=* | --host=* | --port=* | --max-agents=* | --*)
        shift
        ;;
      *.aiurconfig)
        printf '%s' "$1"
        return
        ;;
      *)
        # A positional non-legacy config is authoritative. Let the Elixir CLI
        # validate it instead of rejecting an unrelated ambient legacy file.
        return
        ;;
    esac
  done

  local target_root="${AIUR_REPO_ROOT:-}" home_real
  home_real="$(cd "${HOME:-}" 2>/dev/null && pwd -P || printf '%s' "${HOME:-}")"

  if [ -n "$target_root" ]; then
    if [ -f "$target_root/.aiur/config" ]; then
      return
    fi
    if [ -f "$target_root/.aiurconfig" ]; then
      printf '%s' "$target_root/.aiurconfig"
      return
    fi
  else
    local pwd_real d
    pwd_real="$(pwd -P 2>/dev/null || printf '%s' "$PWD")"
    d="$pwd_real"

    while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "$home_real" ]; do
      if [ -f "$d/.aiur/config" ]; then
        return
      fi
      if [ -f "$d/.aiurconfig" ]; then
        printf '%s' "$d/.aiurconfig"
        return
      fi
      d="$(dirname "$d")"
    done
  fi

  if [ -n "$home_real" ] && [ ! -f "$home_real/.aiur/config" ] && [ -f "$home_real/.aiurconfig" ]; then
    printf '%s' "$home_real/.aiurconfig"
  fi
}

reject_legacy_config() {
  local legacy legacy_basename canonical
  legacy="$(legacy_config_path "$@")"
  [ -z "$legacy" ] && return
  legacy_basename="${legacy##*/}"

  if [ "$legacy_basename" = ".aiurconfig" ]; then
    canonical="$(dirname "$legacy")/.aiur/config"
  else
    canonical="${legacy%.aiurconfig}.yaml"
  fi

  die "$legacy is no longer supported. Move it to $canonical. Keep relative prompt_file and hooks_file paths valid from the new config directory."
}

package_version() {
  local package_file="$1"
  [ -r "$package_file" ] || return 1
  sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$package_file" | head -n 1
}

cli_package_version() {
  package_version "$engine_dir/../package.json"
}

version_is_older() {
  local installed="$1" available="$2"
  local installed_major installed_minor installed_patch installed_pre
  local available_major available_minor available_patch available_pre

  if [[ ! "$installed" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9A-Za-z.-]+))?(\+[0-9A-Za-z.-]+)?$ ]]; then return 1; fi
  installed_major="${BASH_REMATCH[1]}"
  installed_minor="${BASH_REMATCH[2]}"
  installed_patch="${BASH_REMATCH[3]}"
  installed_pre="${BASH_REMATCH[5]}"

  if [[ ! "$available" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9A-Za-z.-]+))?(\+[0-9A-Za-z.-]+)?$ ]]; then return 1; fi
  available_major="${BASH_REMATCH[1]}"
  available_minor="${BASH_REMATCH[2]}"
  available_patch="${BASH_REMATCH[3]}"
  available_pre="${BASH_REMATCH[5]}"

  [ "$installed_major" -lt "$available_major" ] ||
    { [ "$installed_major" -eq "$available_major" ] && [ "$installed_minor" -lt "$available_minor" ]; } ||
    { [ "$installed_major" -eq "$available_major" ] && [ "$installed_minor" -eq "$available_minor" ] && [ "$installed_patch" -lt "$available_patch" ]; } ||
    {
      [ "$installed_major" -eq "$available_major" ] &&
        [ "$installed_minor" -eq "$available_minor" ] &&
        [ "$installed_patch" -eq "$available_patch" ] &&
        {
          { [ -n "$installed_pre" ] && [ -z "$available_pre" ]; } ||
            { [ -n "$installed_pre" ] && [ -n "$available_pre" ] && [[ "$installed_pre" < "$available_pre" ]]; }
        }
    }
}

warn_if_cli_behind_release_checkout() {
  local stamp="${AIUR_RELEASE_DIR:-}/AIUR_BUILD_STAMP"
  local repo_root installed_version checkout_version

  [ -r "$stamp" ] || return 0
  repo_root="$(sed -n 's/^repo_root=//p' "$stamp" | head -n 1)"
  [ -n "$repo_root" ] || return 0

  installed_version="$(cli_package_version || true)"
  checkout_version="$(package_version "$repo_root/packaging/npm/aiur-cli/package.json" || true)"

  if version_is_older "$installed_version" "$checkout_version"; then
    echo "aiur: installed CLI $installed_version is older than checkout CLI $checkout_version; update aiur-cli before retrying" >&2
  fi
}


# The aiur project root used to key this instance. AIUR_REPO_ROOT (set by the dev
# shim) wins. Otherwise walk up from $PWD to the first dir holding a REPO-LOCAL
# config — but the walk STOPS at $HOME: the global config at ~/.aiur/config is
# not a repo root, and treating it as one would collapse every
# project under $HOME onto one key (#443). When no repo-local config is found, the
# BEAM serves this run via the global config (mirroring its discovery order in
# src/lib/aiur/workflow.ex) — or via none — and in both cases the project being
# served is the cwd, so we key by realpath($PWD). That gives each global-config
# project a distinct identity instead of an empty key (legacy aiur-$USER@…) or $HOME.
#
# Caveat: a global-config run's key is cwd-derived (there is no repo root to
# converge on), so control commands (status/pause/stop) must be run from the SAME
# directory the run was launched from. A repo with a repo-local .aiur/config keeps
# the walk-up, so its control commands still resolve from any subdir.
aiur_project_root() {
  if [ -n "${AIUR_REPO_ROOT:-}" ]; then printf '%s' "$AIUR_REPO_ROOT"; return; fi

  # Canonicalize $PWD and $HOME so the home-boundary test below holds even when
  # either is reached through a symlink.
  local pwd_real home_real
  pwd_real="$(pwd -P 2>/dev/null || printf '%s' "$PWD")"
  # ${HOME:-} (not bare $HOME) so an unset HOME under `set -u` can't abort the
  # script here; an empty home_real simply disables the boundary (walk to /).
  home_real="$(cd "${HOME:-}" 2>/dev/null && pwd -P || printf '%s' "${HOME:-}")"

  local d="$pwd_real"
  while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "$home_real" ]; do
    if [ -f "$d/.aiur/config" ]; then
      printf '%s' "$d"
      return
    fi
    d="$(dirname "$d")"
  done

  printf '%s' "$pwd_real"
}

aiur_project_root_source() {
  if [ -n "${AIUR_REPO_ROOT:-}" ]; then printf 'env'; return; fi

  local pwd_real home_real
  pwd_real="$(pwd -P 2>/dev/null || printf '%s' "$PWD")"
  home_real="$(cd "${HOME:-}" 2>/dev/null && pwd -P || printf '%s' "${HOME:-}")"

  local d="$pwd_real"
  while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "$home_real" ]; do
    if [ -f "$d/.aiur/config" ]; then
      printf 'repo'
      return
    fi
    d="$(dirname "$d")"
  done

  printf 'cwd'
}

# Short, stable, node-name-legal (lowercase hex) key for the project root, so two
# aiur instances for the same user get distinct node/session/socket names and can't
# reap each other. Any real cwd now resolves a key (global-config runs key by
# realpath($PWD), #443); only a degenerate unreadable cwd yields empty, falling back
# to the legacy un-keyed name.
aiur_instance_key() {
  local root
  root="$(aiur_project_root)"
  [ -n "$root" ] || return 0
  # Canonicalize (resolve symlinks) so launch and control commands invoked via
  # different logical paths to the same project agree on the key. Fall back to the
  # literal path when the dir doesn't exist (e.g. a test-fixture root).
  root="$(cd "$root" 2>/dev/null && pwd -P || printf '%s' "$root")"
  printf '%s' "$root" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-10
}

aiur_resolve_identity() {
  local config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
  AIUR_PROJECT_ROOT="$(aiur_project_root)"
  AIUR_PROJECT_ROOT_SOURCE="$(aiur_project_root_source)"

  : "${AIUR_BG_STATE_DIR:=$config_home/aiur}"
  : "${AIUR_COOKIE_FILE:=$AIUR_BG_STATE_DIR/cookie}"
  : "${AIUR_SESSION_PREFIX:=aiur}"
  : "${AIUR_PROFILES_FILE:=$config_home/aiur/aiur.profiles}"
  # Compute the per-instance key once. `${VAR+x}` so an explicit empty value (no
  # project resolved) is honored and not recomputed on each call.
  if [ -z "${AIUR_INSTANCE_KEY+x}" ]; then
    AIUR_INSTANCE_KEY="$(aiur_instance_key)"
  fi
  : "${AIUR_RELEASE_NODE:=aiur-${USER}${AIUR_INSTANCE_KEY:+-$AIUR_INSTANCE_KEY}@127.0.0.1}"

  export AIUR_BG_STATE_DIR AIUR_COOKIE_FILE AIUR_SESSION_PREFIX \
    AIUR_PROFILES_FILE AIUR_RELEASE_NODE AIUR_INSTANCE_KEY \
    AIUR_PROJECT_ROOT AIUR_PROJECT_ROOT_SOURCE
}

aiur_print_identity() {
  aiur_resolve_identity
  printf 'AIUR_RELEASE_DIR=%s\n' "${AIUR_RELEASE_DIR:-}"
  printf 'AIUR_BG_STATE_DIR=%s\n' "$AIUR_BG_STATE_DIR"
  printf 'AIUR_SESSION_PREFIX=%s\n' "$AIUR_SESSION_PREFIX"
  printf 'AIUR_PROFILES_FILE=%s\n' "$AIUR_PROFILES_FILE"
  printf 'AIUR_RELEASE_NODE=%s\n' "$AIUR_RELEASE_NODE"
  printf 'AIUR_INSTANCE_KEY=%s\n' "$AIUR_INSTANCE_KEY"
  printf 'AIUR_PROJECT_ROOT=%s\n' "$AIUR_PROJECT_ROOT"
  printf 'AIUR_PROJECT_ROOT_SOURCE=%s\n' "$AIUR_PROJECT_ROOT_SOURCE"
  printf 'AIUR_COOKIE_FILE=%s\n' "$AIUR_COOKIE_FILE"
}


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

  [ -r "$cookie_file" ] || die "$cookie_file is not readable"

  if [ "$(stat -c '%U' "$cookie_file" 2>/dev/null || stat -f '%Su' "$cookie_file")" != "$USER" ]; then
    die "$cookie_file is not owned by $USER"
  fi

  local size
  size="$(wc -c <"$cookie_file" | tr -d ' ')"
  [ "$size" -ge 16 ] || die "$cookie_file is shorter than 16 bytes"

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
  export AIUR_ERLANG_COOKIE="$RELEASE_COOKIE"
}


release_dir=""
vsn_dir=""
release_bin=""

control_release_retry() {
  [ -n "${AIUR_CONTROL_RELEASE_RETRY_SIGNAL:-}" ] && : >"$AIUR_CONTROL_RELEASE_RETRY_SIGNAL"
  return 75
}

resolve_release() {
  release_dir="${AIUR_RELEASE_DIR:-}"
  [ -n "$release_dir" ] || die "AIUR_RELEASE_DIR is not set; the engine must be invoked via the aiur or aiurdev wrapper"
  if [ ! -d "$release_dir" ]; then
    # aiurdev uses EX_TEMPFAIL to wait out an in-place dev rebuild and retry
    # exactly once. Product launches keep the existing fatal diagnostics.
    if [ "${AIUR_CONTROL_RELEASE_RETRYABLE:-0}" = "1" ]; then
      control_release_retry
      return $?
    fi
    die "AIUR_RELEASE_DIR does not exist: $release_dir"
  fi

  local release_vsn
  release_vsn="$(cut -d' ' -f2 "$release_dir/releases/start_erl.data" 2>/dev/null || true)"
  vsn_dir="$release_dir/releases/$release_vsn"
  release_bin="$release_dir/bin/aiur"
  if [ -z "$release_vsn" ] || [ ! -x "$release_bin" ] || [ ! -x "$vsn_dir/elixir" ]; then
    if [ "${AIUR_CONTROL_RELEASE_RETRYABLE:-0}" = "1" ]; then
      control_release_retry
      return $?
    fi
    die "release elixir launcher not found at $vsn_dir/elixir"
  fi
}


argv_file=""
init_argv_file() {
  argv_file="$(mktemp "${TMPDIR:-/tmp}/aiur-argv.XXXXXX")"
  : >"$argv_file"
}
write_argv() {
  local a
  for a in "$@"; do printf '%s\n' "$a" >>"$argv_file"; done
}

release_cmd=()
build_release_cmd() {
  release_cmd=(
    "$vsn_dir/elixir"
    --cookie "$RELEASE_COOKIE"
    --name "$RELEASE_NODE"
    --erl-config "$vsn_dir/sys"
    --boot "$vsn_dir/start_clean"
    --boot-var RELEASE_LIB "$release_dir/lib"
    --vm-args "$vsn_dir/vm.args"
    --eval "Aiur.CLI.main(Aiur.CLI.argv_from_file())"
  )
}

# Distribution-free boot for the `init` wizard: same interactive `--eval` form
# (so the wizard's prompts receive keystrokes — `bin/aiur eval` is -noinput),
# but with no --name/--cookie since the wizard makes no RPC calls.
build_init_cmd() {
  release_cmd=(
    "$vsn_dir/elixir"
    --erl-config "$vsn_dir/sys"
    --boot "$vsn_dir/start_clean"
    --boot-var RELEASE_LIB "$release_dir/lib"
    --vm-args "$vsn_dir/vm.args"
    --eval "Aiur.CLI.main(Aiur.CLI.argv_from_file())"
  )
}
