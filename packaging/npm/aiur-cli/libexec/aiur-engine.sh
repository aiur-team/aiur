#!/usr/bin/env bash
#
# Shared aiur launcher engine.
#
# Owns every aiur subcommand. Both the installed `aiur` (bin/aiur.js) and the dev
# `aiurdev` (scripts/aiurdev) exec this one engine, differing only in which
# release is run:
#
#   AIUR_RELEASE_DIR    release dir whose bin/aiur is exec'd (required; set by the caller)
#
# There is a single `aiur` distribution identity (node/cookie/session). aiurdev
# shares it. The identity vars resolve to the fixed `aiur` values; they remain
# overridable only so tests can redirect state to a temp dir:
#
#   AIUR_BG_STATE_DIR   cookie + state dir  (default: ~/.config/aiur)
#   AIUR_COOKIE_FILE    cookie file         (default: $AIUR_BG_STATE_DIR/cookie)
#   AIUR_SESSION_PREFIX tmux session prefix (default: aiur)
#   AIUR_PROFILES_FILE  profiles file       (default: ~/.config/aiur/aiur.profiles)
#   AIUR_RELEASE_NODE   full node name      (default: aiur-$USER@127.0.0.1)
#
# The release is self-contained (bundled ERTS), so it runs without mise/Elixir on
# PATH. Dev's build-if-stale step lives in the aiurdev shim, not here.

set -euo pipefail

die() {
  echo "❌ $*" >&2
  exit 1
}

engine_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- distribution identity (fixed: the single `aiur` identity) ---------------

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

# --- release resolution ------------------------------------------------------

release_dir=""
vsn_dir=""
release_bin=""

resolve_release() {
  release_dir="${AIUR_RELEASE_DIR:-}"
  [ -n "$release_dir" ] || die "AIUR_RELEASE_DIR is not set; the engine must be invoked via the aiur or aiurdev wrapper"
  [ -d "$release_dir" ] || die "AIUR_RELEASE_DIR does not exist: $release_dir"

  local release_vsn
  release_vsn="$(cut -d' ' -f2 "$release_dir/releases/start_erl.data")"
  vsn_dir="$release_dir/releases/$release_vsn"
  release_bin="$release_dir/bin/aiur"
  [ -x "$vsn_dir/elixir" ] || die "release elixir launcher not found at $vsn_dir/elixir"
}

# --- argv round-trip (System.argv is empty under `elixir --eval`) -------------

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

usage() {
  cat <<'EOF'
Usage: aiur [--interactive] [--logs-root <path>] [--port <port>] [--host <host>] [path-to-.aiurconfig]
       aiur init [--force]   scaffold .aiurconfig (interactive setup wizard)
       aiur --bg             start in a detached tmux session
       aiur stop             stop the running session
       aiur status           show agent status
       aiur pause <ids|--all> | resume <ids|--all>
       aiur --version
EOF
}

# --- one-shot: --version (no tmux) -------------------------------------------

run_version() {
  resolve_release
  prepare_distribution
  build_release_cmd
  init_argv_file
  write_argv "$@"
  export AIUR_ARGV_FILE="$argv_file"
  exec "${release_cmd[@]}"
}

# --- one-shot: init (interactive wizard, distribution-free, no tmux) ----------

run_init() {
  resolve_release
  build_init_cmd
  init_argv_file
  write_argv "$@"
  export AIUR_ARGV_FILE="$argv_file"
  exec "${release_cmd[@]}"
}

# --- interactive / background run -------------------------------------------
#
# mode=foreground attaches the UI and tears down on exit; mode=background leaves
# the detached tmux session running and returns.

run_session() {
  local mode="$1"
  shift

  resolve_release

  local tmux_bin
  tmux_bin="$(command -v tmux || true)"
  [ -n "$tmux_bin" ] || die "tmux is required to run aiur; install tmux and retry"

  aiur_resolve_identity

  init_argv_file

  # Inject the flags a bare `aiur` needs: loopback bind, interactive UI, and the
  # no-guardrails ack. Skip any the user already passed.
  local has_host=0 has_interactive=0 has_ack=0 arg
  for arg in "$@"; do
    case "$arg" in
      --host | --host=*) has_host=1 ;;
      --interactive) has_interactive=1 ;;
      --i-understand-that-this-will-be-running-without-the-usual-guardrails) has_ack=1 ;;
    esac
  done
  local injected=()
  [ "$has_host" -eq 1 ] || injected+=(--host 127.0.0.1)
  [ "$has_interactive" -eq 1 ] || injected+=(--interactive)
  [ "$has_ack" -eq 1 ] || injected+=(--i-understand-that-this-will-be-running-without-the-usual-guardrails)

  write_argv "${injected[@]}" "$@"
  export AIUR_ARGV_FILE="$argv_file"

  prepare_distribution
  build_release_cmd

  # Force +fnu when no locale is set so the BEAM does not mangle non-ASCII paths.
  if [ -z "${LANG:-}" ] && [ -z "${LC_ALL:-}" ] && [ -z "${LC_CTYPE:-}" ]; then
    export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-} +fnu"
  fi

  local session="${AIUR_SESSION_PREFIX}-${USER:-user}-default"
  local socket="${AIUR_SESSION_PREFIX}-${USER:-user}"
  local conf
  conf="$(resolve_tmux_conf)"
  [ -f "$conf" ] || die "tmux conf not found at $conf"

  mkdir -p "$AIUR_BG_STATE_DIR"
  printf '%s\n' "$session" >"$AIUR_BG_STATE_DIR/state"
  export AIUR_TMUX_SESSION="$session"
  export AIUR_TMUX_SOCKET="$socket"
  export AIUR_TMUX_CONF="$conf"
  export AIUR_BIN="${BASH_SOURCE[0]}"

  local session_root="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
  export AIUR_SESSION_TMPFILE="${session_root}/aiur-${$}-sessions"
  : >"$AIUR_SESSION_TMPFILE"

  local startup_capture
  startup_capture="$(mktemp "${TMPDIR:-/tmp}/aiur-startup.XXXXXX")"

  # Inner pane script: tmux's server may pre-exist and not inherit our env, so
  # re-export every var the BEAM needs. tee preserves a startup capture.
  local launcher
  launcher="$(mktemp "${TMPDIR:-/tmp}/aiur-pane.XXXXXX")"
  chmod +x "$launcher"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -o pipefail\n'
    printf 'cd %q || exit 1\n' "$PWD"
    local v
    for v in AIUR_RELEASE_DIR AIUR_ARGV_FILE RELEASE_DISTRIBUTION RELEASE_NODE \
      RELEASE_COOKIE ERL_AFLAGS ERL_EPMD_ADDRESS AIUR_NODE AIUR_ERLANG_COOKIE \
      AIUR_TMUX_SESSION AIUR_TMUX_SOCKET AIUR_TMUX_CONF AIUR_BIN \
      AIUR_SESSION_TMPFILE ELIXIR_ERL_OPTIONS AIUR_LOGS_ROOT; do
      if [ -n "${!v:-}" ]; then printf 'export %s=%q\n' "$v" "${!v}"; fi
    done
    printf 'capture=%q\n' "$startup_capture"
    printf '%q' "${release_cmd[0]}"
    for arg in "${release_cmd[@]:1}"; do printf ' %q' "$arg"; done
    printf ' 2>&1 | tee -a "$capture"\n'
    printf 'exit ${PIPESTATUS[0]}\n'
  } >"$launcher"

  local inner_cmd
  printf -v inner_cmd '%q; rc=$?; rm -f %q; exit $rc' "$launcher" "$launcher"

  if [ "$mode" = "foreground" ]; then
    _session_socket="$socket" _session_name="$session" _session_conf="$conf" \
      _session_tmpfile="$AIUR_SESSION_TMPFILE" _session_capture="$startup_capture" \
      _session_argv="$argv_file" _session_release="$release_dir" _session_tmux="$tmux_bin"
    install_foreground_traps
  fi

  if ! "$tmux_bin" -L "$socket" -f "$conf" new-session -d -s "$session" \
    -x "${COLUMNS:-200}" -y "${LINES:-50}" "$inner_cmd"; then
    echo "❌ aiur failed to start; captured output:" >&2
    tail -n 30 "$startup_capture" 2>/dev/null | sed 's/^/  /' >&2 || true
    rm -f "$startup_capture" "$argv_file" 2>/dev/null || true
    exit 1
  fi

  # Grace window: surface a boot crash instead of attaching to nothing.
  local tick
  for ((tick = 0; tick < 30; tick++)); do
    if ! "$tmux_bin" -L "$socket" -f "$conf" has-session -t "$session" 2>/dev/null; then
      echo "❌ aiur exited during startup; captured output:" >&2
      tail -n 30 "$startup_capture" 2>/dev/null | sed 's/^/  /' >&2 || true
      [ "$mode" = "foreground" ] && return 1
      rm -f "$startup_capture" "$argv_file" 2>/dev/null || true
      exit 1
    fi
    sleep 0.1
  done

  if [ "$mode" = "background" ]; then
    echo "aiur started in the background (tmux session ${session}). Attach with: aiur" >&2
    rm -f "$startup_capture" "$argv_file" 2>/dev/null || true
    return 0
  fi

  # Foreground: attach the UI. Do not exec — that would drop the teardown trap.
  "$tmux_bin" -L "$socket" -f "$conf" attach -t "$session" 2> >(grep -v -F "[server exited]" >&2)
  return $?
}

resolve_tmux_conf() {
  if [ -n "${AIUR_TMUX_CONF:-}" ] && [ -f "${AIUR_TMUX_CONF:-}" ]; then
    printf '%s\n' "$AIUR_TMUX_CONF"
    return
  fi
  local user_conf="${XDG_CONFIG_HOME:-$HOME/.config}/aiur/tmux.conf"
  if [ -f "$user_conf" ]; then
    printf '%s\n' "$user_conf"
    return
  fi
  printf '%s\n' "$engine_dir/../share/aiur.tmux.conf"
}

# Foreground teardown: kill the session + BEAM and reap opencode sessions on exit.
_session_socket="" _session_name="" _session_conf="" _session_tmpfile=""
_session_capture="" _session_argv="" _session_release="" _session_tmux=""
_cleanup_ran=0
session_cleanup() {
  [ "$_cleanup_ran" = 1 ] && return 0
  _cleanup_ran=1
  local code=$?

  if [ -n "$_session_tmux" ]; then
    "$_session_tmux" -L "$_session_socket" -f "$_session_conf" kill-session -t "$_session_name" 2>/dev/null || true
  fi

  local beam_pids pid waited=0
  beam_pids="$(pgrep -f "$_session_release/.*erts.*beam.smp" 2>/dev/null || true)"
  if [ -n "$beam_pids" ]; then
    for pid in $beam_pids; do kill -TERM "$pid" 2>/dev/null || true; done
    while [ $waited -lt 30 ]; do
      beam_pids="$(pgrep -f "$_session_release/.*erts.*beam.smp" 2>/dev/null || true)"
      [ -z "$beam_pids" ] && break
      sleep 0.1
      waited=$((waited + 1))
    done
    beam_pids="$(pgrep -f "$_session_release/.*erts.*beam.smp" 2>/dev/null || true)"
    for pid in $beam_pids; do kill -KILL "$pid" 2>/dev/null || true; done
  fi

  if command -v opencode >/dev/null 2>&1 && [ -s "$_session_tmpfile" ]; then
    local id
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      opencode session delete "$id" >/dev/null 2>&1 &
    done <"$_session_tmpfile"
    wait 2>/dev/null || true
  fi

  # Reap agent-driver sockets this run orphaned at close, not next launch.
  sweep_dead_tmux_sockets || true

  rm -f "$_session_tmpfile" "$_session_capture" "$_session_argv" 2>/dev/null || true
  return $code
}
install_foreground_traps() {
  trap 'session_cleanup' EXIT
  trap 'trap - EXIT INT TERM HUP; session_cleanup; exit 130' INT
  trap 'trap - EXIT INT TERM HUP; session_cleanup; exit 143' TERM
  trap 'trap - EXIT INT TERM HUP; session_cleanup; exit 129' HUP
}

# --- lifecycle (RPC into the running node + tmux ops) ------------------------

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# RPC an expression into the running node. The control CLI prints a trailing
# `__AIUR_CONTROL_EXIT__:<code>` marker we translate into the process exit code.
run_control_rpc() {
  local expression="$1"
  resolve_release
  prepare_distribution || die "distribution setup failed; cannot contact aiur"

  local marker="__AIUR_CONTROL_EXIT__:"
  local output status exit_code=0 saw_marker=0 line

  set +e
  output="$("$release_bin" rpc "$expression" 2>&1)"
  status=$?
  set -e

  if [ "$status" -ne 0 ]; then
    echo "aiur: no running aiur node at ${RELEASE_NODE}; start aiur and try again" >&2
    return 1
  fi

  while IFS= read -r line; do
    case "$line" in
      "$marker"*)
        saw_marker=1
        exit_code="${line#"$marker"}"
        ;;
      :ok | "") ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <<<"$output"

  [ "$saw_marker" -eq 1 ] || return 1
  return "$exit_code"
}

elixir_list_literal() {
  local first=1 item
  printf '['
  for item in "$@"; do
    [ "$first" -eq 0 ] && printf ', '
    printf '"%s"' "$item"
    first=0
  done
  printf ']'
}

# Parse issue-id targets (e.g. `44 45,46` or `--all`) into parsed_targets/parsed_all.
parsed_targets=()
parsed_all=0
parse_issue_targets() {
  parsed_targets=()
  parsed_all=0
  [ "$#" -gt 0 ] || return 1

  if [ "$#" -eq 1 ] && [ "$1" = "--all" ]; then
    parsed_all=1
    return 0
  fi

  local raw part parts
  for raw in "$@"; do
    [ "$raw" = "--all" ] && return 1
    IFS=',' read -ra parts <<<"$raw"
    for part in "${parts[@]}"; do
      part="$(trim "$part")"
      if [ -z "$part" ] || [[ ! "$part" =~ ^[0-9]+$ ]]; then return 1; fi
      parsed_targets+=("$part")
    done
  done

  [ "${#parsed_targets[@]}" -gt 0 ]
}

cmd_status() {
  [ "$#" -eq 0 ] || die "status does not accept arguments"
  run_control_rpc "Aiur.AgentControlCLI.status()"
}

cmd_pause_resume() {
  local command="$1"
  shift
  if ! parse_issue_targets "$@"; then
    echo "aiur: $command expects issue IDs or --all (e.g. aiur $command 44 45,46; aiur $command --all)" >&2
    exit 64
  fi

  local expression
  if [ "$parsed_all" -eq 1 ]; then
    expression="Aiur.AgentControlCLI.${command}(:all)"
  else
    expression="Aiur.AgentControlCLI.${command}($(elixir_list_literal "${parsed_targets[@]}"))"
  fi

  run_control_rpc "$expression"
}

sweep_dead_tmux_sockets() {
  local tmux_bin
  tmux_bin="$(command -v tmux || true)"
  [ -n "$tmux_bin" ] || return 0

  local sockdir="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
  [ -d "$sockdir" ] || return 0

  local removed=0 name path
  for path in "$sockdir"/*; do
    [ -S "$path" ] || continue
    name="${path##*/}"
    case "$name" in
      aiur* | *-driver | *-driver-*) ;;
      *) continue ;;
    esac
    if ! "$tmux_bin" -L "$name" list-sessions >/dev/null 2>&1; then
      rm -f "$path" 2>/dev/null && removed=$((removed + 1))
    fi
  done

  [ "$removed" -gt 0 ] && echo "🧹 swept $removed dead aiur tmux socket(s)" >&2
  return 0
}

# Stop the running session: kill the tmux session + the release BEAM, then sweep.
cmd_stop() {
  resolve_release
  aiur_resolve_identity

  local tmux_bin
  tmux_bin="$(command -v tmux || true)"
  local session="${AIUR_SESSION_PREFIX}-${USER:-user}-default"
  local socket="${AIUR_SESSION_PREFIX}-${USER:-user}"
  if [ -n "$tmux_bin" ]; then
    "$tmux_bin" -L "$socket" kill-session -t "$session" 2>/dev/null || true
  fi

  local beam_pids pid waited=0
  beam_pids="$(pgrep -f "$release_dir/.*erts.*beam.smp" 2>/dev/null || true)"
  if [ -n "$beam_pids" ]; then
    for pid in $beam_pids; do kill -TERM "$pid" 2>/dev/null || true; done
    while [ $waited -lt 30 ]; do
      beam_pids="$(pgrep -f "$release_dir/.*erts.*beam.smp" 2>/dev/null || true)"
      [ -z "$beam_pids" ] && break
      sleep 0.1
      waited=$((waited + 1))
    done
    beam_pids="$(pgrep -f "$release_dir/.*erts.*beam.smp" 2>/dev/null || true)"
    for pid in $beam_pids; do kill -KILL "$pid" 2>/dev/null || true; done
  fi

  sweep_dead_tmux_sockets
}

# --- dispatch ----------------------------------------------------------------

aiur_engine_main() {
  local cmd="${1:-}"
  case "$cmd" in
    __identity)
      aiur_print_identity
      ;;
    help | -h | -help | --h | --help)
      usage
      ;;
    --version)
      run_version "$@"
      ;;
    init)
      run_init "$@"
      ;;
    --bg)
      shift
      run_session background "$@"
      ;;
    run)
      shift
      run_session foreground "$@"
      ;;
    status)
      shift
      cmd_status "$@"
      ;;
    pause | resume)
      shift
      cmd_pause_resume "$cmd" "$@"
      ;;
    stop)
      cmd_stop
      ;;
    "")
      run_session foreground
      ;;
    -*)
      # leading-flag forms (e.g. `aiur --interactive <config>`) are a run
      run_session foreground "$@"
      ;;
    *)
      # a path/config argument is a run; anything else is a usage error
      if [ -e "$cmd" ]; then
        run_session foreground "$@"
      else
        echo "aiur: unknown command: $cmd" >&2
        usage >&2
        exit 64
      fi
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  aiur_engine_main "$@"
fi
