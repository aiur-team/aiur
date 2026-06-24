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

# Raise the soft open-file limit toward the hard maximum. High agent concurrency
# spawns many tmux/opencode/git subprocesses + sockets; on hosts with a low
# default (macOS ships 256) that exhausts file descriptors (:emfile) and crashes
# the node. Soft<=hard needs no privilege; best-effort, never fatal.
__aiur_hard_nofile="$(ulimit -Hn 2>/dev/null || echo)"
if [ "${__aiur_hard_nofile}" = "unlimited" ]; then
  ulimit -Sn 65536 2>/dev/null || true
elif [ -n "${__aiur_hard_nofile}" ]; then
  ulimit -Sn "${__aiur_hard_nofile}" 2>/dev/null || true
fi
unset __aiur_hard_nofile

die() {
  echo "❌ $*" >&2
  exit 1
}

engine_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- distribution identity (per-instance: keyed by the aiur project root) -----

# The aiur project root (dir holding the active config). AIUR_REPO_ROOT (set by
# the dev shim) wins; otherwise walk up from $PWD. Empty when run outside a project.
aiur_project_root() {
  if [ -n "${AIUR_REPO_ROOT:-}" ]; then printf '%s' "$AIUR_REPO_ROOT"; return; fi
  local d="$PWD"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/.aiur/config" ] || [ -f "$d/.aiurconfig" ]; then
      printf '%s' "$d"
      return
    fi
    d="$(dirname "$d")"
  done
}

# Short, stable, node-name-legal (lowercase hex) key for the project root, so two
# aiur instances for the same user get distinct node/session/socket names and can't
# reap each other. Empty when no project resolves (names fall back to the legacy form).
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
    AIUR_PROFILES_FILE AIUR_RELEASE_NODE AIUR_INSTANCE_KEY
}

aiur_print_identity() {
  aiur_resolve_identity
  printf 'AIUR_RELEASE_DIR=%s\n' "${AIUR_RELEASE_DIR:-}"
  printf 'AIUR_BG_STATE_DIR=%s\n' "$AIUR_BG_STATE_DIR"
  printf 'AIUR_SESSION_PREFIX=%s\n' "$AIUR_SESSION_PREFIX"
  printf 'AIUR_PROFILES_FILE=%s\n' "$AIUR_PROFILES_FILE"
  printf 'AIUR_RELEASE_NODE=%s\n' "$AIUR_RELEASE_NODE"
  printf 'AIUR_INSTANCE_KEY=%s\n' "$AIUR_INSTANCE_KEY"
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
Usage: aiur [--interactive] [--max-agents <n>] [--logs-root <path>] [--port <port>] [--host <host>] [path-to-.aiurconfig]
       aiur init [--force]   scaffold .aiurconfig (interactive setup wizard)
       aiur --bg             start in a lean, headless detached tmux session
       aiur stop             stop the running session
       aiur status           show agent status
       aiur agents           show each agent's state + current activity
       aiur set max-agents <n>   change the concurrent-agent cap at runtime
       aiur pause <ids|--all> | resume <ids|--all>
       aiur message <id> <text>  send operator text to a running agent
       aiur --version
EOF
}

# --- one-shot: --version (no tmux) -------------------------------------------

run_version() {
  resolve_release
  # Distribution-free (like init): printing the version is a compile-time
  # constant, so never claim the node name — otherwise `aiur --version` fails
  # whenever an aiur session is already running.
  build_init_cmd
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

# Load KEY=VALUE pairs from ./.env into the environment so the running release
# (e.g. GITHUB_TOKEN, dashboard creds) sees what `aiur init` scaffolded there.
# An already-exported variable always wins, so a shell export overrides the file.
load_dotenv() {
  local file=".env" line key val
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in '' | '#'*) continue ;; esac
    [ "${line#*=}" = "$line" ] && continue
    key="${line%%=*}"
    key="${key%"${key##*[![:space:]]}"}"
    case "$key" in '' | *[!A-Za-z0-9_]*) continue ;; esac
    val="${line#*=}"
    val="${val#"${val%%[![:space:]]*}"}"
    case "$val" in
      \"*\") val="${val#\"}" && val="${val%\"}" ;;
      \'*\') val="${val#\'}" && val="${val%\'}" ;;
    esac
    [ -n "${!key+x}" ] && continue
    export "$key=$val"
  done <"$file"
}

run_session() {
  local mode="$1"
  shift

  # --debug is an engine-level convenience on the run path: turn on verbose
  # logging (AIUR_DEBUG) and strip the flag before the release parses argv.
  local run_args=() run_arg
  for run_arg in "$@"; do
    case "$run_arg" in
      --debug) export AIUR_DEBUG=1 ;;
      *) run_args+=("$run_arg") ;;
    esac
  done
  if [ "${#run_args[@]}" -gt 0 ]; then set -- "${run_args[@]}"; else set --; fi

  resolve_release

  local tmux_bin
  tmux_bin="$(command -v tmux || true)"
  [ -n "$tmux_bin" ] || die "tmux is required to run aiur; install tmux and retry"

  aiur_resolve_identity

  # Pick up GITHUB_TOKEN / dashboard creds the wizard wrote to ./.env so the
  # running tracker can authenticate. Shell exports still take precedence.
  load_dotenv

  init_argv_file

  # Inject the flags a bare `aiur` needs: loopback bind, UI mode, and the
  # no-guardrails ack. Skip any the user already passed. Foreground runs are
  # interactive (tmux panes + dashboard); `--bg` runs lean/headless — no panes,
  # no dashboard bind, no chat backfill — and is driven over the control RPC
  # (status/agents/message/pause/set). `aiur --bg --interactive` opts back into
  # the full interactive stack for an attachable background session.
  local has_host=0 has_interactive=0 has_headless=0 has_ack=0 arg
  for arg in "$@"; do
    case "$arg" in
      --host | --host=*) has_host=1 ;;
      --interactive) has_interactive=1 ;;
      --headless) has_headless=1 ;;
      --i-understand-that-this-will-be-running-without-the-usual-guardrails) has_ack=1 ;;
    esac
  done
  local injected=()
  [ "$has_host" -eq 1 ] || injected+=(--host 127.0.0.1)
  if [ "$mode" = "background" ] && [ "$has_interactive" -eq 0 ]; then
    [ "$has_headless" -eq 1 ] || injected+=(--headless)
  else
    [ "$has_interactive" -eq 1 ] || injected+=(--interactive)
  fi
  [ "$has_ack" -eq 1 ] || injected+=(--i-understand-that-this-will-be-running-without-the-usual-guardrails)

  write_argv "${injected[@]}" "$@"
  export AIUR_ARGV_FILE="$argv_file"

  prepare_distribution
  build_release_cmd

  # Force +fnu when no locale is set so the BEAM does not mangle non-ASCII paths.
  if [ -z "${LANG:-}" ] && [ -z "${LC_ALL:-}" ] && [ -z "${LC_CTYPE:-}" ]; then
    export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-} +fnu"
  fi

  local session="${AIUR_SESSION_PREFIX}-${USER:-user}${AIUR_INSTANCE_KEY:+-$AIUR_INSTANCE_KEY}-default"
  local socket="${AIUR_SESSION_PREFIX}-${USER:-user}${AIUR_INSTANCE_KEY:+-$AIUR_INSTANCE_KEY}"
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

  # Agent pidfile: the BEAM appends one line per spawned agent (pane or headless
  # os_pid) via Aiur.ProcessReaper. The BEAM-death watchdog and session_cleanup
  # reap from it after the BEAM is gone — a crashed BEAM can kill nothing itself.
  export AIUR_AGENT_TMPFILE="${session_root}/aiur-${$}-agents"
  : >"$AIUR_AGENT_TMPFILE"

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
      AIUR_SESSION_TMPFILE AIUR_AGENT_TMPFILE ELIXIR_ERL_OPTIONS AIUR_LOGS_ROOT AIUR_DEBUG; do
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
      _session_argv="$argv_file" _session_release="$release_dir" _session_tmux="$tmux_bin" \
      _session_node="$AIUR_RELEASE_NODE" _session_pidfile="$AIUR_AGENT_TMPFILE"
    install_foreground_traps
  fi

  # Background starts are intentionally idempotent. A prior live node should not
  # fall through to tmux's opaque "duplicate session" failure, and a stale tmux
  # session whose BEAM/control plane is gone should be reclaimed before retry.
  if [ "$mode" = "background" ] && "$tmux_bin" -L "$socket" -f "$conf" has-session -t "$session" 2>/dev/null; then
    if [ "$(probe_control_liveness)" = "up" ]; then
      echo "aiur is already running in the background (tmux session ${session})." >&2
      echo "Use: aiur status   # inspect agents" >&2
      echo "Use: aiur stop     # stop it before starting a fresh session" >&2
      rm -f "$startup_capture" "$argv_file" "$launcher" "$AIUR_SESSION_TMPFILE" "$AIUR_AGENT_TMPFILE" 2>/dev/null || true
      return 0
    fi

    echo "aiur found stale tmux session ${session}; cleaning it up before restart" >&2
    reap_aiur_agents "$socket" "$AIUR_AGENT_TMPFILE"
    kill_beams_matching "-name ${AIUR_RELEASE_NODE}"
  fi

  # An orphaned BEAM (its tmux session gone) can still hold THIS instance's node
  # name. With no live session on our (instance-keyed) socket, reap the name-holder
  # so the launch isn't blocked by "name seems to be in use". The keyed name means
  # this only ever reaps our own instance's orphan, never another live aiur.
  if ! "$tmux_bin" -L "$socket" -f "$conf" has-session -t "$session" 2>/dev/null; then
    kill_beams_matching "-name ${AIUR_RELEASE_NODE}"
  fi

  # Transition reclaim: a keyed instance also reaps a stale beam under the legacy
  # un-keyed name (aiur-$USER@127.0.0.1) — but only when no live legacy session
  # exists, so a pre-fix run still in progress is never killed. (Runs on every keyed
  # launch, not latched; it's a cheap best-effort sweep guarded by has-session.)
  if [ -n "${AIUR_INSTANCE_KEY:-}" ]; then
    local legacy_socket="${AIUR_SESSION_PREFIX}-${USER:-user}"
    if ! "$tmux_bin" -L "$legacy_socket" -f "$conf" has-session -t "${legacy_socket}-default" 2>/dev/null; then
      kill_beams_matching "-name aiur-${USER}@127.0.0.1"
    fi
  fi

  if ! "$tmux_bin" -L "$socket" -f "$conf" new-session -d -s "$session" \
    -x "${COLUMNS:-200}" -y "${LINES:-50}" "$inner_cmd"; then
    echo "❌ aiur failed to start; captured output:" >&2
    tail -n 30 "$startup_capture" 2>/dev/null | sed 's/^/  /' >&2 || true
    rm -f "$startup_capture" "$argv_file" "$launcher" "$AIUR_SESSION_TMPFILE" "$AIUR_AGENT_TMPFILE" 2>/dev/null || true
    exit 1
  fi

  # Title the agent-list pane (the only pane in the fresh session). The conf's
  # `pane-border-status`/`pane-border-format` render it; PaneManager titles the
  # chat panes it opens. Best-effort — a missing title just shows the default.
  "$tmux_bin" -L "$socket" -f "$conf" select-pane -t "$session" -T "AIUR Agents" 2>/dev/null || true

  # Grace window: surface a boot crash instead of attaching to nothing. For
  # headless background runs, also prove the control plane can answer before
  # claiming startup succeeded; control commands depend on that RPC path.
  local require_control=0
  [ "$mode" = "background" ] && require_control=1
  if ! wait_for_session_startup "$tmux_bin" "$socket" "$conf" "$session" "$startup_capture" "$require_control"; then
    if [ "$mode" = "background" ]; then
      "$tmux_bin" -L "$socket" -f "$conf" kill-session -t "$session" 2>/dev/null || true
      reap_aiur_agents "$socket" "$AIUR_AGENT_TMPFILE"
      kill_beams_matching "-name ${AIUR_RELEASE_NODE}"
    fi
    [ "$mode" = "foreground" ] && return 1
    rm -f "$startup_capture" "$argv_file" "$launcher" "$AIUR_SESSION_TMPFILE" "$AIUR_AGENT_TMPFILE" 2>/dev/null || true
    exit 1
  fi

  if [ "$mode" = "background" ]; then
    local background_watchdog_pid
    background_watchdog_pid="$(start_beam_death_watchdog \
      "-name ${AIUR_RELEASE_NODE}" "$socket" "$AIUR_AGENT_TMPFILE" 1 1)"
    disown "$background_watchdog_pid" 2>/dev/null || true
    echo "aiur started in the background (tmux session ${session}). Attach with: aiur" >&2
    rm -f "$startup_capture" "$argv_file" 2>/dev/null || true
    return 0
  fi

  # Arm the BEAM-death watchdog before attaching. If the BEAM crashes
  # (:emfile) mid-run, agent windows keep the orphaned session alive so the
  # `tmux attach` below never returns and the EXIT trap never fires — the
  # watchdog is the external reaper that survives the dead BEAM, kill-servers
  # the session, and unblocks the attach. It polls the node name rather than a
  # captured pid, so another Aiur instance from the same release cannot hold it open.
  _session_watchdog_pid="$(start_beam_death_watchdog \
    "-name ${AIUR_RELEASE_NODE}" "$socket" "$AIUR_AGENT_TMPFILE" 1)"

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

# TERM-then-KILL every BEAM whose command line matches $1. Reaps a stale node by
# name (covers orphans from any release dir): under the unified identity a dev
# `_build` BEAM and an installed BEAM both claim the same node name, so a
# release-path pgrep misses whichever one this run didn't launch.
kill_beams_matching() {
  local pattern="$1" pids pid waited=0
  pids="$(pgrep -f -- "$pattern" 2>/dev/null || true)"
  [ -n "$pids" ] || return 0
  for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done
  while [ "$waited" -lt 30 ]; do
    pids="$(pgrep -f -- "$pattern" 2>/dev/null || true)"
    [ -z "$pids" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  pids="$(pgrep -f -- "$pattern" 2>/dev/null || true)"
  for pid in $pids; do kill -KILL "$pid" 2>/dev/null || true; done
}

# Echo $1 and every descendant pid, depth-first. Mac-safe (`pgrep -P`, no
# /proc), mirroring Aiur.RemoteControl.collect_descendants so the launcher reaps
# the same tree the BEAM-side reaper would. The recorded agent pid is a bash
# `-lc` wrapper; the model process (claude --print / codex) is its child and
# reparents to init if only the wrapper is signalled — orphan-and-survive is
# exactly the bug — so the whole tree must be collected before any kill lands.
agent_pid_tree() {
  local root="$1" child
  printf '%s\n' "$root"
  for child in $(pgrep -P "$root" 2>/dev/null || true); do
    agent_pid_tree "$child"
  done
}

# pid-reuse guard: succeeds when pid $1 is alive AND its command still contains
# the comm substring $2 the BEAM recorded. An empty comm kills unconditionally.
# Mirrors the BEAM-side cmdline guard (Aiur.ProcessReaper) but Mac-safe via
# `ps -o command=`, so a recycled pid whose command no longer matches is spared.
agent_pid_matches() {
  local pid="$1" comm="$2" cmd
  kill -0 "$pid" 2>/dev/null || return 1
  [ -n "$comm" ] || return 0
  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$cmd" in *"$comm"*) return 0 ;; *) return 1 ;; esac
}

# Reap every aiur agent the BEAM can no longer reap itself.
#
#   $1 socket   aiur tmux socket (-L); kill-server nukes all panes (may be empty)
#   $2 pidfile  AIUR_AGENT_TMPFILE (BEAM-written agent refs; may be empty/missing)
#
# tmux runs on aiur's PRIVATE socket (-L aiur-$USER), so kill-server tears down
# every REPL/chat pane agent in one shot AND leaves no live aiur tmux server —
# never touching the operator's own default tmux. Headless agents (claude/codex
# app-servers spawned via Port) are bare OS processes that reparent to init on a
# BEAM crash; kill-server can't see them, so they're reaped from the pidfile by
# process tree, comm-guarded against pid reuse. Idempotent.
reap_aiur_agents() {
  local socket="$1" pidfile="${2:-}"
  local tmux_bin
  tmux_bin="$(command -v tmux || true)"

  if [ -n "$tmux_bin" ] && [ -n "$socket" ]; then
    "$tmux_bin" -L "$socket" kill-server 2>/dev/null || true
  fi

  [ -n "$pidfile" ] && [ -r "$pidfile" ] || return 0

  # Snapshot the full process tree of every still-matching headless agent before
  # signalling, so descendants that reparent mid-reap are already on the list.
  local kind pid comm tree=() p
  while read -r kind pid comm; do
    [ "$kind" = "pid" ] && [ -n "$pid" ] || continue
    agent_pid_matches "$pid" "$comm" || continue
    while IFS= read -r p; do tree+=("$p"); done < <(agent_pid_tree "$pid")
  done <"$pidfile"

  [ "${#tree[@]}" -gt 0 ] || return 0

  for p in "${tree[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
  local waited=0
  while [ "$waited" -lt 20 ]; do
    local any=0
    for p in "${tree[@]}"; do kill -0 "$p" 2>/dev/null && { any=1; break; }; done
    [ "$any" -eq 0 ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  for p in "${tree[@]}"; do kill -KILL "$p" 2>/dev/null || true; done
}

# Background watchdog that survives the BEAM. Polls for the release BEAM by
# command pattern and, once it has SEEN the BEAM and then the BEAM disappears
# (orderly halt OR :emfile-style crash), reaps every agent. Polling the pattern
# rather than a captured pid avoids two failure modes: a recycled BEAM pid the
# watchdog would poll forever, and an empty pid at arm time that would silently
# disarm the only crash reaper. The `seen` latch prevents a startup race from
# reaping before the BEAM has come up. kill-server collapses the orphaned tmux
# session, which returns the foreground `tmux attach` so the EXIT trap
# (session_cleanup) runs its idempotent reap too.
#
#   $1 beam_pattern  $2 socket  $3 pidfile  $4 interval_s  $5 initial_seen
# Prints the watchdog's own pid so the caller can kill it on a clean teardown.
start_beam_death_watchdog() {
  local beam_pattern="$1" socket="$2" pidfile="$3" interval="${4:-1}" initial_seen="${5:-0}"
  # Redirect the subshell's stdout so a command-substitution caller
  # (`pid=$(start_beam_death_watchdog ...)`) returns immediately instead of
  # blocking on the still-open pipe until the watchdog finishes.
  (
    seen="$initial_seen"
    while :; do
      if pgrep -f -- "$beam_pattern" >/dev/null 2>&1; then
        seen=1
      elif [ "$seen" = 1 ]; then
        break
      fi
      sleep "$interval"
    done
    reap_aiur_agents "$socket" "$pidfile"
  ) >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

probe_control_liveness() {
  local expression output status
  expression='case Process.whereis(Aiur.Orchestrator) do pid when is_pid(pid) -> case Aiur.Orchestrator.status(Aiur.Orchestrator, 100) do statuses when is_list(statuses) -> IO.puts("__AIUR_CONTROL_READY__"); _ -> IO.puts("__AIUR_CONTROL_NOT_READY__") end; _ -> IO.puts("__AIUR_CONTROL_NOT_READY__") end'

  set +e
  output="$("$release_bin" rpc "$expression" 2>&1)"
  status=$?
  set -e

  if [ "$status" -eq 0 ] && [[ "$output" == *"__AIUR_CONTROL_READY__"* ]]; then
    printf 'up'
  else
    printf 'down'
  fi
}

wait_for_session_startup() {
  local tmux_bin="$1" socket="$2" conf="$3" session="$4" startup_capture="$5" require_control="$6"
  local max_ticks="${AIUR_TMUX_GRACE_TICKS:-30}" tick control_state
  if [ "$require_control" = "1" ]; then
    max_ticks="${AIUR_NODE_GRACE_TICKS:-100}"
  fi

  for ((tick = 0; tick < max_ticks; tick++)); do
    if ! "$tmux_bin" -L "$socket" -f "$conf" has-session -t "$session" 2>/dev/null; then
      echo "❌ aiur exited during startup; captured output:" >&2
      tail -n 30 "$startup_capture" 2>/dev/null | sed 's/^/  /' >&2 || true
      return 1
    fi

    if [ "$require_control" != "1" ]; then
      sleep 0.1
      continue
    fi

    control_state="$(probe_control_liveness)"
    if [ "$control_state" = "up" ]; then
      return 0
    fi

    sleep 0.1
  done

  if [ "$require_control" = "1" ]; then
    echo "❌ aiur control plane did not become ready at ${RELEASE_NODE:-unknown} during startup; captured output:" >&2
    tail -n 30 "$startup_capture" 2>/dev/null | sed 's/^/  /' >&2 || true
    return 1
  fi

  return 0
}

# Foreground teardown: kill the session + BEAM and reap opencode sessions on exit.
_session_socket="" _session_name="" _session_conf="" _session_tmpfile=""
_session_capture="" _session_argv="" _session_release="" _session_tmux="" _session_node=""
_session_pidfile="" _session_watchdog_pid=""
_cleanup_ran=0
session_cleanup() {
  [ "$_cleanup_ran" = 1 ] && return 0
  _cleanup_ran=1
  local code=$?

  # Stop the BEAM-death watchdog: cleanup is running, so it has no work left and
  # a lingering poller would outlive this teardown.
  [ -n "$_session_watchdog_pid" ] && kill "$_session_watchdog_pid" 2>/dev/null || true

  # kill-session on the detached aiur session FIRST: this is what propagates
  # SIGHUP to the BEAM in that session so it begins its own orderly shutdown.
  # Without it the BEAM survives Ctrl+C, holding port 4000 + the node name and
  # breaking the next launch (regression test/aiur/regression/shutdown_cleanup_test.exs).
  if [ -n "$_session_tmux" ] && [ -n "$_session_socket" ] && [ -n "$_session_name" ]; then
    "$_session_tmux" -L "$_session_socket" kill-session -t "$_session_name" 2>/dev/null || true
  fi

  # Then kill-server on aiur's private socket: tears down every pane agent across
  # all windows AND leaves no live aiur tmux server, then reaps headless agents
  # from the pidfile. Idempotent with the watchdog's own reap and the kill-session
  # above. reap_aiur_agents re-resolves tmux itself and reaps headless agents even
  # when tmux is absent, so it is not gated on $_session_tmux.
  reap_aiur_agents "$_session_socket" "$_session_pidfile"

  # Reap only this instance's BEAM. Multiple keyed instances can share the same
  # release dir, so release-path pgrep would terminate sibling workflows.
  [ -n "$_session_node" ] && kill_beams_matching "-name ${_session_node}"

  # Reap the epmd our BEAM spawned for distribution so it doesn't linger after
  # exit. The node is dead by now, so `epmd -kill` succeeds; it safely refuses
  # while any *other* Erlang node is alive, so a daemon shared with an unrelated
  # Erlang program is never disrupted. Use the release's bundled epmd and pin it
  # to the loopback address aiur starts it on.
  for _epmd in "$_session_release"/erts-*/bin/epmd; do
    [ -x "$_epmd" ] || continue
    ERL_EPMD_ADDRESS="${ERL_EPMD_ADDRESS:-127.0.0.1}" "$_epmd" -kill >/dev/null 2>&1 || true
  done

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

  # Reap stale aiur /tmp debris (per-run tempfiles, leaked test artifacts) so a
  # tmpfs /tmp can't fill across runs. Age-gated + pid-safe; our own still-present
  # tempfiles are spared (fresh + live pid) before the explicit rm below clears them.
  sweep_stale_tmp_artifacts || true

  rm -f "$_session_tmpfile" "$_session_capture" "$_session_argv" "$_session_pidfile" 2>/dev/null || true
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

# Classify our distribution node's liveness via epmd, which only advertises a
# node while its BEAM holds the registration. Echoes exactly one word:
#   up      — node is registered: it is alive, so an rpc failure is a real error
#   down    — epmd answered and our node is absent: it genuinely is not running
#   unknown — epmd could not be queried (binary missing, or daemon unreachable),
#             so node state is indeterminate and callers must NOT assume "down"
#             and mask the real error
# Distinguishing `unknown` from `down` matters: a live node whose epmd we cannot
# reach must still surface its real rpc error rather than the "start aiur" hint.
# Relies on RELEASE_NODE + ERL_EPMD_ADDRESS (prepare_distribution) and
# release_dir (resolve_release), so call it only after both have run.
probe_node_liveness() {
  local epmd names short="${RELEASE_NODE%@*}"
  for epmd in "$release_dir"/erts-*/bin/epmd; do
    [ -x "$epmd" ] || continue
    names="$(ERL_EPMD_ADDRESS="${ERL_EPMD_ADDRESS:-127.0.0.1}" "$epmd" -names 2>/dev/null)" \
      || { printf 'unknown'; return; }
    case "$names" in
      *"name ${short} at port "*) printf 'up' ;;
      *) printf 'down' ;;
    esac
    return
  done
  printf 'unknown'
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
    # A non-zero exit here is the rpc transport failing — application-level
    # outcomes ride the marker path below. `bin/aiur rpc` (Elixir --rpc-eval)
    # reports a genuinely-down node and a live-but-unreachable one identically
    # (`:noconnection`), and prints any exception raised inside the expression.
    # So the reason string can't be trusted; classify via epmd instead. Only a
    # node epmd confirms is down earns the friendly "start aiur" hint; an `up`
    # node failed for a real reason, and an `unknown` probe must not be assumed
    # down — in both of those cases surface the actual rpc output, never mask it.
    case "$(probe_node_liveness)" in
      down)
        echo "aiur: no running aiur node at ${RELEASE_NODE}; start aiur and try again" >&2
        ;;
      up)
        [ -n "$output" ] && printf '%s\n' "$output" >&2
        echo "aiur: rpc to ${RELEASE_NODE} failed (node is running); see the error above" >&2
        ;;
      *)
        [ -n "$output" ] && printf '%s\n' "$output" >&2
        echo "aiur: rpc to ${RELEASE_NODE} failed (could not query epmd to confirm node state); see the error above" >&2
        ;;
    esac
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

# `aiur message <issue> <text>` — deliver operator text to one running agent.
# The text is base64-encoded for the RPC hop so arbitrary content (quotes,
# backslashes, `#{}`, newlines) survives without Elixir-string escaping.
cmd_message() {
  local usage="aiur: message expects an issue ID and text (e.g. aiur message 44 \"ship it\")"

  local issue="${1:-}"
  if [ -z "$issue" ] || [[ ! "$issue" =~ ^[0-9]+$ ]]; then
    echo "$usage" >&2
    exit 64
  fi
  shift

  local text="$*"
  if [ -z "$text" ]; then
    echo "$usage" >&2
    exit 64
  fi

  local encoded
  encoded="$(printf '%s' "$text" | base64 | tr -d '\n')"
  run_control_rpc "Aiur.AgentControlCLI.message(\"$issue\", Base.decode64!(\"$encoded\"))"
}

# `aiur agents` — concise one-line-per-agent state + current activity from a
# live node (the headless equivalent of the dashboard / aiur-status skill).
cmd_agents() {
  [ "$#" -eq 0 ] || die "agents does not accept arguments"
  run_control_rpc "Aiur.AgentControlCLI.agents()"
}

# `aiur set <key> <value>` — runtime config overrides without editing
# `.aiur/config`. Currently: `aiur set max-agents N`.
cmd_set() {
  local key="${1:-}"
  shift 2>/dev/null || true

  case "$key" in
    max-agents)
      local n="${1:-}"
      if [ -z "$n" ] || [[ ! "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ]; then
        echo "aiur: set max-agents expects a positive integer (e.g. aiur set max-agents 5)" >&2
        exit 64
      fi
      run_control_rpc "Aiur.AgentControlCLI.set_max_agents($n)"
      ;;
    *)
      echo "aiur: unknown setting: ${key:-(none)} (supported: max-agents)" >&2
      exit 64
      ;;
  esac
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

# Reap stale aiur /tmp debris so a tmpfs /tmp can't fill from accumulated per-run
# tempfiles and leaked test artifacts. Runs alongside sweep_dead_tmux_sockets on
# foreground teardown (session_cleanup) and on `aiur stop`. Bounded and safe:
#
#   * Only exact top-level Aiur artifact families under the temp roots the engine
#     and BEAM write to. Arbitrary operator worktrees/checkouts like
#     `/tmp/aiur-pr490` are not candidates.
#   * Age-gated by AIUR_TMP_REAP_MINUTES (default 1440 = 24h). An entry is removed
#     only when NOTHING in its subtree was modified within the window, so a live
#     run's shared debug dir (aiur-rc / aiur-claude-hooks / aiur-debug) holding a
#     fresh file is spared even when the dir's own mtime is stale. A non-numeric or
#     0 value disables the sweep.
#   * Ownership-gated: if anything in the tree is not owned by the effective user,
#     the whole tree is spared.
#   * A live run's `aiur-<pid>-sessions|-agents` bookkeeping is kept while its pid
#     is alive, regardless of age.
is_aiur_tmp_artifact_candidate() {
  local base="$1" pid
  case "$base" in
    aiur-argv.* | aiur-startup.* | aiur-pane.* | aiur-launcher.* | aiur-capture.* | \
      aiur-trap.*.log | aiur-tree.*.json | aiur-wrapper.pid | aiur-*-frames.bin | \
      aiur-rc | aiur-claude-hooks | aiur-debug)
      return 0
      ;;
    aiur-*-sessions | aiur-*-agents)
      pid="${base#aiur-}"
      pid="${pid%-*}"
      [ -n "$pid" ] && [ -z "${pid//[0-9]/}" ]
      return
      ;;
    *)
      return 1
      ;;
  esac
}

sweep_stale_tmp_artifacts() {
  local minutes="${AIUR_TMP_REAP_MINUTES:-1440}"
  case "$minutes" in '' | *[!0-9]*) return 0 ;; esac
  [ "$minutes" -gt 0 ] || return 0

  # The dirs the engine + BEAM target: ${TMPDIR:-/tmp} (argv/startup/pane tempfiles
  # plus the BEAM's System.tmp_dir debug dirs) and ${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}
  # (the session/agent pidfiles' session_root). Deduped — a typical box scans one dir.
  local roots=() d seen
  for d in "${TMPDIR:-/tmp}" "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"; do
    [ -d "$d" ] || continue
    seen=0
    local root
    if [ "${#roots[@]}" -gt 0 ]; then
      for root in "${roots[@]}"; do
        [ "$root" = "$d" ] && { seen=1; break; }
      done
    fi
    [ "$seen" -eq 1 ] || roots+=("$d")
  done
  [ "${#roots[@]}" -gt 0 ] || return 0

  local removed=0 path base pid uid found
  uid="$(id -u)"
  for d in "${roots[@]}"; do
    while IFS= read -r -d '' path; do
      base="${path##*/}"
      is_aiur_tmp_artifact_candidate "$base" || continue

      # Spare mixed-ownership trees; cleanup should never cross user boundaries.
      if ! found="$(find "$path" ! -user "$uid" -print -quit 2>/dev/null)"; then
        continue
      fi
      if [ -n "$found" ]; then
        continue
      fi
      # Spare anything modified within the window anywhere in its subtree.
      if ! found="$(find "$path" -mmin "-$minutes" -print -quit 2>/dev/null)"; then
        continue
      fi
      if [ -n "$found" ]; then
        continue
      fi
      # Spare a live run's session/agent bookkeeping (name is aiur-<pid>-<kind>).
      case "$base" in
        aiur-*-sessions | aiur-*-agents)
          pid="${base#aiur-}"
          pid="${pid%-*}"
          if [ -n "$pid" ] && [ -z "${pid//[0-9]/}" ] && kill -0 "$pid" 2>/dev/null; then
            continue
          fi
          ;;
      esac
      if rm -rf -- "$path" 2>/dev/null; then
        removed=$((removed + 1))
      fi
    done < <(find "$d" -maxdepth 1 -mindepth 1 -name 'aiur-*' -print0 2>/dev/null)
  done

  [ "$removed" -gt 0 ] && echo "🧹 swept $removed stale aiur tmp artifact(s)" >&2
  return 0
}

# Stop the running session: kill this instance's tmux + BEAM, then sweep.
cmd_stop() {
  resolve_release
  aiur_resolve_identity

  local tmux_bin
  tmux_bin="$(command -v tmux || true)"
  local session="${AIUR_SESSION_PREFIX}-${USER:-user}${AIUR_INSTANCE_KEY:+-$AIUR_INSTANCE_KEY}-default"
  local socket="${AIUR_SESSION_PREFIX}-${USER:-user}${AIUR_INSTANCE_KEY:+-$AIUR_INSTANCE_KEY}"
  if [ -n "$tmux_bin" ]; then
    "$tmux_bin" -L "$socket" kill-session -t "$session" 2>/dev/null || true
  fi

  # Reap any BEAM holding our node name regardless of which release dir launched
  # it. Do not sweep by release dir: sibling instances share dev releases.
  kill_beams_matching "-name ${AIUR_RELEASE_NODE}"

  # The BEAM (alive until the TERM above) reaped its own headless agents through
  # ProcessReaper on Application.stop. kill-server is the guarantee the earlier
  # kill-session can't give for mid-turn agents: every pane agent across all
  # windows dies and no live aiur tmux server is left behind.
  if [ -n "$tmux_bin" ]; then
    "$tmux_bin" -L "$socket" kill-server 2>/dev/null || true
  fi

  # Belt-and-suspenders for a mid-turn stop: sweep any headless agent (this run
  # or a prior crashed one) still recorded in a pidfile. comm-guarded, so a
  # recycled pid is spared. Empty socket: the kill-server above already ran.
  local session_root agentfile
  session_root="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
  for agentfile in "$session_root"/aiur-*-agents; do
    [ -e "$agentfile" ] || continue
    reap_aiur_agents "" "$agentfile"
    rm -f "$agentfile" 2>/dev/null || true
  done

  sweep_dead_tmux_sockets
  sweep_stale_tmp_artifacts
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
    agents)
      shift
      cmd_agents "$@"
      ;;
    set)
      shift
      cmd_set "$@"
      ;;
    pause | resume)
      shift
      cmd_pause_resume "$cmd" "$@"
      ;;
    message)
      shift
      cmd_message "$@"
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
