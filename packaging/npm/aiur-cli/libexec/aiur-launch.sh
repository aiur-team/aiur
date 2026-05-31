#!/usr/bin/env bash
# Distribution launcher for the aiur OTP release.
#
# Reproduces the interactive run that `scripts/aiur` provides for repo/dev use,
# but with every repo/toolchain assumption stripped out. It drives a relocated
# `mix release` (bundled ERTS, no Elixir/Erlang on PATH) pointed to by
# AIUR_RELEASE_DIR: sets the distribution env contract (cookie + named node),
# backgrounds the BEAM inside an isolated tmux session, attaches the foreground
# UI, and tears the session + BEAM down on exit.
#
# The Node shim (bin/aiur.js) resolves the platform package, runs tmux/opencode
# preflight, and execs this script with AIUR_RELEASE_DIR + AIUR_TMUX_CONF set.
set -euo pipefail

die() {
  echo "❌ $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

release_dir="${AIUR_RELEASE_DIR:-}"
[ -n "$release_dir" ] || die "AIUR_RELEASE_DIR is not set; this launcher must be invoked via the aiur shim"
[ -d "$release_dir" ] || die "AIUR_RELEASE_DIR does not exist: $release_dir"

release_vsn="$(cut -d' ' -f2 "$release_dir/releases/start_erl.data")"
vsn_dir="$release_dir/releases/$release_vsn"
[ -x "$vsn_dir/elixir" ] || die "release elixir launcher not found at $vsn_dir/elixir"

tmux_bin="$(command -v tmux || true)"

# Argv crosses into the BEAM via a temp file, one arg per line, because
# `System.argv()` is empty under `elixir --eval`. Aiur.CLI.argv_from_file/0
# reads it back. Quoting and spaces survive the round-trip this way.
argv_file="$(mktemp "${TMPDIR:-/tmp}/aiur-argv.XXXXXX")"
trap 'rm -f "$argv_file"' EXIT
: >"$argv_file"
write_argv() {
  local a
  for a in "$@"; do
    printf '%s\n' "$a" >>"$argv_file"
  done
}

# Build the low-level `elixir --eval` distribution invocation. This is the same
# boot the dev shim (mix.exs copy_cli_launcher) uses for RELEASE_DISTRIBUTION=name:
# a named, cookie-authenticated node so opencode panes can RPC back in. Built
# after prepare_distribution so RELEASE_COOKIE/RELEASE_NODE are populated.
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

# --- distribution env contract ---------------------------------------------
# Port of scripts/aiur ensure_erlang_cookie + prepare_distribution. A stable
# secret cookie + a 127.0.0.1-pinned long node name so neither BEAM resolves a
# hostname (Debian maps the hostname to 127.0.1.1, which breaks Node.connect).
prepare_distribution() {
  local state_dir="${AIUR_STATE_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aiur}"
  mkdir -p "$state_dir"
  local cookie_file="$state_dir/cookie"

  if [ ! -f "$cookie_file" ]; then
    (
      umask 0177
      local tmp
      tmp="$(mktemp "$state_dir/cookie.XXXXXX")"
      head -c 32 /dev/urandom | base64 | tr -d '\n=+/' | head -c 32 >"$tmp"
      mv "$tmp" "$cookie_file"
    )
    chmod 0400 "$cookie_file"
  fi

  [ -r "$cookie_file" ] || die "$cookie_file is not readable"
  local owner
  owner="$(stat -c '%U' "$cookie_file" 2>/dev/null || stat -f '%Su' "$cookie_file")"
  [ "$owner" = "$USER" ] || die "$cookie_file is not owned by $USER"
  local size
  size="$(wc -c <"$cookie_file" | tr -d ' ')"
  [ "$size" -ge 16 ] || die "$cookie_file is shorter than 16 bytes"

  local cookie
  cookie="$(cat "$cookie_file")"

  export RELEASE_DISTRIBUTION="name"
  export RELEASE_NODE="${AIUR_RELEASE_NODE:-aiur-${USER}@127.0.0.1}"
  export RELEASE_COOKIE="$cookie"
  export ERL_AFLAGS=" -proto_dist inet_tcp -kernel inet_dist_use_interface {127,0,0,1}"
  export ERL_EPMD_ADDRESS="127.0.0.1"
  export AIUR_NODE="$RELEASE_NODE"
  export AIUR_ERLANG_COOKIE="$RELEASE_COOKIE"
}

# --- one-shot path: --version (no tmux, exits fast) -------------------------
for arg in "$@"; do
  if [ "$arg" = "--version" ]; then
    prepare_distribution
    build_release_cmd
    write_argv "$@"
    export AIUR_ARGV_FILE="$argv_file"
    exec "${release_cmd[@]}"
  fi
done

# --- interactive run --------------------------------------------------------
[ -n "$tmux_bin" ] || die "tmux is required to run aiur; install tmux and retry"

# Inject the flags the dev launcher injects so a bare `aiur` just works:
# bind the server to loopback, force interactive UI, and acknowledge the
# no-guardrails run. Skip any the user already passed.
has_host=0
has_interactive=0
has_ack=0
for arg in "$@"; do
  case "$arg" in
    --host|--host=*) has_host=1 ;;
    --interactive) has_interactive=1 ;;
    --i-understand-that-this-will-be-running-without-the-usual-guardrails) has_ack=1 ;;
  esac
done

injected=()
[ "$has_host" -eq 1 ] || injected+=(--host 127.0.0.1)
[ "$has_interactive" -eq 1 ] || injected+=(--interactive)
[ "$has_ack" -eq 1 ] || injected+=(--i-understand-that-this-will-be-running-without-the-usual-guardrails)

write_argv "${injected[@]}" "$@"
export AIUR_ARGV_FILE="$argv_file"

prepare_distribution
build_release_cmd

# Filename unicode mode: a parent that wiped the locale (e.g. env -i) leaves
# the BEAM in latin1 and it warns + mangles non-ASCII paths. Force +fnu when
# no locale is set rather than depending on the caller's environment.
if [ -z "${LANG:-}" ] && [ -z "${LC_ALL:-}" ] && [ -z "${LC_CTYPE:-}" ]; then
  export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-} +fnu"
fi

session="aiur-${USER:-user}-default"
socket="aiur-${USER:-user}"

resolve_conf() {
  if [ -n "${AIUR_TMUX_CONF:-}" ] && [ -f "${AIUR_TMUX_CONF:-}" ]; then
    printf '%s\n' "$AIUR_TMUX_CONF"
    return
  fi
  local user_conf="${XDG_CONFIG_HOME:-$HOME/.config}/aiur/tmux.conf"
  if [ -f "$user_conf" ]; then
    printf '%s\n' "$user_conf"
    return
  fi
  printf '%s\n' "$script_dir/../share/aiur.tmux.conf"
}
conf="$(resolve_conf)"
[ -f "$conf" ] || die "tmux conf not found at $conf"

# Persist the session/socket/conf so the Elixir Tmux client and the chat-pane
# subcommand target the same isolated tmux server. AIUR_BIN lets workflow
# commands re-invoke aiur; the relocated release has no repo shim, so point it
# at this launcher (covers one-shot uses like `$AIUR_BIN --version`).
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/aiur"
printf '%s\n' "$session" >"${XDG_CONFIG_HOME:-$HOME/.config}/aiur/state"
export AIUR_TMUX_SESSION="$session"
export AIUR_TMUX_SOCKET="$socket"
export AIUR_TMUX_CONF="$conf"
export AIUR_BIN="${BASH_SOURCE[0]}"

# opencode session id sidecar: SessionWriter appends one id per line; the
# teardown trap reaps each on exit so we don't leak opencode sessions.
session_root="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
export AIUR_SESSION_TMPFILE="${session_root}/aiur-${$}-sessions"
: >"$AIUR_SESSION_TMPFILE"

startup_capture="$(mktemp "${TMPDIR:-/tmp}/aiur-startup.XXXXXX")"

cleanup_ran=0
cleanup() {
  [ "$cleanup_ran" = 1 ] && return 0
  cleanup_ran=1
  local code=$?

  if [ -n "$tmux_bin" ]; then
    "$tmux_bin" -L "$socket" -f "$conf" kill-session -t "$session" 2>/dev/null || true
  fi

  # SIGTERM the release BEAM (graceful Aiur.Shutdown), then SIGKILL stragglers.
  local beam_pids
  beam_pids="$(pgrep -f "$release_dir/.*erts.*beam.smp" 2>/dev/null || true)"
  if [ -n "$beam_pids" ]; then
    local pid
    for pid in $beam_pids; do kill -TERM "$pid" 2>/dev/null || true; done
    local waited=0
    while [ $waited -lt 30 ]; do
      beam_pids="$(pgrep -f "$release_dir/.*erts.*beam.smp" 2>/dev/null || true)"
      [ -z "$beam_pids" ] && break
      sleep 0.1
      waited=$((waited + 1))
    done
    beam_pids="$(pgrep -f "$release_dir/.*erts.*beam.smp" 2>/dev/null || true)"
    for pid in $beam_pids; do kill -KILL "$pid" 2>/dev/null || true; done
  fi

  if command -v opencode >/dev/null 2>&1 && [ -s "$AIUR_SESSION_TMPFILE" ]; then
    local id
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      opencode session delete "$id" >/dev/null 2>&1 &
    done <"$AIUR_SESSION_TMPFILE"
    wait 2>/dev/null || true
  fi

  rm -f "$AIUR_SESSION_TMPFILE" "$startup_capture" "$argv_file" 2>/dev/null || true
  return $code
}
trap 'cleanup' EXIT
trap 'trap - EXIT INT TERM HUP; cleanup; exit 130' INT
trap 'trap - EXIT INT TERM HUP; cleanup; exit 143' TERM
trap 'trap - EXIT INT TERM HUP; cleanup; exit 129' HUP

# Inner pane script. tmux's server may already exist on this socket and would
# not inherit our env, so re-export every var the BEAM needs. Piping to tee
# preserves a startup capture even when kill-session SIGHUPs the pane.
launcher="$(mktemp "${TMPDIR:-/tmp}/aiur-pane.XXXXXX")"
chmod +x "$launcher"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -o pipefail\n'
  printf 'cd %q || exit 1\n' "$PWD"
  for v in AIUR_RELEASE_DIR AIUR_ARGV_FILE RELEASE_DISTRIBUTION RELEASE_NODE \
    RELEASE_COOKIE ERL_AFLAGS ERL_EPMD_ADDRESS AIUR_NODE AIUR_ERLANG_COOKIE \
    AIUR_TMUX_SESSION AIUR_TMUX_SOCKET AIUR_TMUX_CONF AIUR_BIN \
    AIUR_SESSION_TMPFILE ELIXIR_ERL_OPTIONS AIUR_LOGS_ROOT; do
    if [ -n "${!v:-}" ]; then
      printf 'export %s=%q\n' "$v" "${!v}"
    fi
  done
  printf 'capture=%q\n' "$startup_capture"
  printf '%q' "${release_cmd[0]}"
  for arg in "${release_cmd[@]:1}"; do printf ' %q' "$arg"; done
  printf ' 2>&1 | tee -a "$capture"\n'
  printf 'exit ${PIPESTATUS[0]}\n'
} >"$launcher"

printf -v inner_cmd '%q; rc=$?; rm -f %q; exit $rc' "$launcher" "$launcher"

if ! "$tmux_bin" -L "$socket" -f "$conf" new-session -d -s "$session" \
  -x "${COLUMNS:-200}" -y "${LINES:-50}" "$inner_cmd"; then
  echo "❌ aiur failed to start; captured output:" >&2
  tail -n 30 "$startup_capture" 2>/dev/null | sed 's/^/  /' >&2 || true
  exit 1
fi

# Grace window: if the session dies during boot (e.g. port in use), surface the
# captured startup log instead of a silent attach to nothing.
for ((tick = 0; tick < 30; tick++)); do
  if ! "$tmux_bin" -L "$socket" -f "$conf" has-session -t "$session" 2>/dev/null; then
    echo "❌ aiur exited during startup; captured output:" >&2
    tail -n 30 "$startup_capture" 2>/dev/null | sed 's/^/  /' >&2 || true
    exit 1
  fi
  sleep 0.1
done

# Attach the foreground UI. Do not exec — that would drop our teardown trap.
"$tmux_bin" -L "$socket" -f "$conf" attach -t "$session" 2> >(grep -v -F "[server exited]" >&2)
tmux_status=$?

exit $tmux_status
