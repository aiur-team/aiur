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

# Export the effective soft limit after the best-effort raise. The BEAM uses
# this inherited value for FD-headroom admission on hosts without procfs,
# avoiding a runtime `ulimit` subprocess precisely when descriptors are scarce.
__aiur_soft_nofile="$(ulimit -Sn 2>/dev/null || echo)"
if [[ "$__aiur_soft_nofile" =~ ^[0-9]+$ ]]; then
  export AIUR_NOFILE_SOFT_LIMIT="$__aiur_soft_nofile"
else
  unset AIUR_NOFILE_SOFT_LIMIT
fi
unset __aiur_soft_nofile

# Preserve the shell that initiated the run as a best-effort Executor root.
# An explicit positive override wins (service managers may know a better root);
# otherwise the engine's parent is the nearest identity available before tmux
# hands daemon ownership to its pane launcher.
if ! [[ "${AIUR_OPERATOR_PID:-}" =~ ^[1-9][0-9]*$ ]]; then
  if [[ "${PPID:-}" =~ ^[1-9][0-9]*$ ]]; then
    export AIUR_OPERATOR_PID="$PPID"
  else
    unset AIUR_OPERATOR_PID
  fi
fi

die() {
  echo "❌ $*" >&2
  exit 1
}

engine_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- distribution identity (per-instance: keyed by the aiur project root) -----

# The aiur project root used to key this instance. AIUR_REPO_ROOT (set by the dev
# shim) wins. Otherwise walk up from $PWD to the first dir holding a REPO-LOCAL
# config — but the walk STOPS at $HOME: the global config at ~/.aiur/config (legacy
# ~/.aiurconfig) is not a repo root, and treating it as one would collapse every
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
    if [ -f "$d/.aiur/config" ] || [ -f "$d/.aiurconfig" ]; then
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
    if [ -f "$d/.aiur/config" ] || [ -f "$d/.aiurconfig" ]; then
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
Usage: aiur [--interactive] [--no-dashboard] [--pause] [--max-agents <n>] [--logs-root <path>] [--port <port>] [--host <host>] [path-to-.aiurconfig]
       aiur run [--bg] [--no-dashboard] [--debug]  explicit launch form (foreground unless --bg)
       aiur init [--force]   scaffold .aiurconfig (interactive setup wizard)
       aiur --bg [--no-dashboard] [--debug]   start detached; dashboard on unless suppressed
       aiur stop             stop the running session
       aiur status           show agent status
       aiur agents           show each agent's state + current activity
       aiur commands [<decision-id>] [--filter all|open|blocking|resolved] [--blocking] [--ticket <id>] [--search <text>] [--cursor <cursor>] [--limit <n>] [--json]
       aiur analytics [--range run|full] [--since <ISO-8601>] [--until <ISO-8601>] [--build-order <id>] [--json]
       aiur alerts [--needs-attention]  show structured alert feed
       aiur watch [--full|--changes] [--interval <secs>]  server-side status board
       aiur executor-listen [--topic <pattern>]  stream Executor events as JSON lines
       aiur executor-emit <topic> --payload <json>  publish an Executor event
       aiur executor-subscribe|executor-unsubscribe <pattern>
       aiur executor-subscriptions  list persistent Executor bindings
       aiur set max-agents <n>   change the concurrent-agent cap at runtime
       aiur pause | resume             flip the global pause switch (whole daemon)
       aiur pause <ids|--all> | resume <ids|--all>  per-agent pause/resume
       aiur message <id> <text>  send Executor text to a running agent
       aiur --todo <ids...> [--only]  queue tickets; optionally dequeue all other pending tickets
       aiur findings [--unfiled] [--slugs] [--scope aiur|repo]  inspect host-local findings
       aiur findings --record <json> --repo <owner/repo>  append one validated finding
       aiur findings --digest [--scope aiur|repo]  generate the promoted Markdown digest
       aiur guard-pr-deletions [base-branch]  refuse PRs with excessive untouched deletions
       aiur ask <title> [--body <text>|--body-file <path>] [--urgency low|normal|high] [--blocking]
       aiur ask --done <id> [--note <text>]  create or resolve an operator request
       aiur asks [--open|--all] [--json]  inspect current-repository operator requests
       aiur cleanup-stale [--dry-run]  list/reap stale manual-smoke leftovers
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

# --- one-shot: --todo (control RPC; requires a running daemon) ----------------

parsed_todo_only=0

parse_todo_args() {
  parsed_targets=()
  parsed_todo_only=0

  local saw_todo=0 raw part parts
  for raw in "$@"; do
    case "$raw" in
      --todo)
        [ "$saw_todo" -eq 0 ] || return 1
        saw_todo=1
        ;;
      --only)
        parsed_todo_only=1
        ;;
      -*)
        return 1
        ;;
      *)
        IFS=',' read -ra parts <<<"$raw"
        for part in "${parts[@]}"; do
          part="$(trim "$part")"
          if [ -z "$part" ] || [[ ! "$part" =~ ^[0-9]+$ ]]; then return 1; fi
          while [ "${#part}" -gt 1 ] && [ "${part#0}" != "$part" ]; do
            part="${part#0}"
          done
          parsed_targets+=("$part")
        done
        ;;
    esac
  done

  [ "$saw_todo" -eq 1 ] && [ "${#parsed_targets[@]}" -gt 0 ]
}

run_todo() {
  if ! parse_todo_args "$@"; then
    echo "aiur: --todo expects one or more numeric issue IDs, optionally followed by --only" >&2
    exit 64
  fi

  local only_arg="false"
  [ "$parsed_todo_only" -eq 1 ] && only_arg="true"
  run_control_rpc "Aiur.AgentControlCLI.todo($(elixir_list_literal "${parsed_targets[@]}"), only: $only_arg, emit_exit_marker: true)"
}

# --- one-shot: findings (distribution-free, no daemon/tmux) -------------------

run_findings() {
  run_init "$@"
}

# --- one-shot: ask / asks (distribution-free, no daemon/tmux) ----------------

run_asks() {
  run_init "$@"
}

# --- interactive / background run -------------------------------------------
#
# mode=foreground attaches the UI and tears down on exit; mode=background leaves
# the detached tmux session running and returns.

# Load operator/machine credentials before repo-local settings. Since each file
# only fills unset names, shell exports win first, then ~/.aiur/.env, then ./.env.
load_dotenv() {
  load_dotenv_file "$HOME/.aiur/.env"
  load_dotenv_file ".env"
}

load_dotenv_file() {
  local file="$1" line key val
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

# The readiness token grants the one-shot `aiur init` assessment access that a
# normal daemon and its child agents must never inherit. Keep dotenv loading
# generic, then remove this run-only secret before any session process starts.
scrub_run_only_env() {
  unset AIUR_CI_READINESS_TOKEN
}

run_argv=()
# Default dashboard bind host. Prefer this machine's Tailscale IPv4 so the
# dashboard is reachable across the tailnet by default (no per-project config);
# fall back to loopback when Tailscale is absent, or when dashboard credentials
# are unset (a non-loopback bind requires them, so we stay on loopback rather
# than refuse to start). An explicit `--host` always overrides this.
default_dashboard_host() {
  local ip=""
  if command -v tailscale >/dev/null 2>&1; then
    ip="$(tailscale ip -4 2>/dev/null | grep -m1 -E '^100\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
  fi
  if [ -n "$ip" ] && [ -n "${AIUR_DASHBOARD_USERNAME:-}" ] && [ -n "${AIUR_DASHBOARD_PASSWORD:-}" ]; then
    printf '%s' "$ip"
  else
    printf '127.0.0.1'
  fi
}

build_run_argv() {
  local mode="$1"
  shift

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
  [ "$has_host" -eq 1 ] || injected+=(--host "$(default_dashboard_host)")
  if [ "$mode" = "background" ] && [ "$has_interactive" -eq 0 ]; then
    [ "$has_headless" -eq 1 ] || injected+=(--headless)
  else
    [ "$has_interactive" -eq 1 ] || injected+=(--interactive)
  fi
  [ "$has_ack" -eq 1 ] || injected+=(--i-understand-that-this-will-be-running-without-the-usual-guardrails)

  run_argv=("${injected[@]}" "$@")
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
  scrub_run_only_env

  init_argv_file

  # Inject the flags a bare `aiur` needs: loopback bind, UI mode, and the
  # no-guardrails ack. Skip any the user already passed. Foreground runs are
  # interactive; `--bg` runs headless (no panes/chat backfill) and is driven
  # over the control RPC (status/agents/message/pause/set). Dashboard binding is
  # independent: it remains enabled in either mode unless `--no-dashboard` is
  # supplied. `aiur --bg --interactive` opts back into the full terminal stack
  # for an attachable background session.
  build_run_argv "$mode" "$@"
  local no_dashboard=0
  for run_arg in "${run_argv[@]}"; do
    [ "$run_arg" = "--no-dashboard" ] && no_dashboard=1
  done
  write_argv "${run_argv[@]}"
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

  preflight_stale_manual_smoke

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

  # Workspace-root handoff for the shell cwd-sweep backstop. The BEAM writes the
  # resolved Aiur.Config.workspace_root() here after config loads.
  export AIUR_WORKSPACE_ROOT_FILE="${session_root}/aiur-${$}-workspace-root"
  : >"$AIUR_WORKSPACE_ROOT_FILE"

  # Background runs persist under a known run log dir so (a) the BEAM-death
  # watchdog, which outlives the BEAM, can drop a crash record next to aiur.log,
  # and (b) the post-start boot capture is not lost to /tmp when the launcher
  # removes its startup tempfile. Minting it here and exporting it makes the
  # shell and the BEAM (Aiur.LogFile honors AIUR_LOGS_ROOT) agree on one dir.
  if [ "$mode" = "background" ] && [ -z "${AIUR_LOGS_ROOT:-}" ]; then
    AIUR_LOGS_ROOT="$(printf '%s/%s-%s' "$HOME/.aiur/logs" "$(date -u +%Y%m%dT%H%M%SZ)" "$$")"
    export AIUR_LOGS_ROOT
  fi

  # Capture an erl_crash.dump on daemon BEAM death (#852) so a crash under load
  # is diagnosable instead of vanishing. Written next to the run's aiur.log so it
  # survives the launcher's tempfile cleanup; ERL_CRASH_DUMP_SECONDS bounds the
  # write so a wedged BEAM can't hang the dump indefinitely. Nothing in the
  # release boot disables dumps, and an Executor override of either var is kept.
  # Requires a durable logs root (background run or agent IR sandbox).
  if [ -n "${AIUR_LOGS_ROOT:-}" ]; then
    export ERL_CRASH_DUMP="${ERL_CRASH_DUMP:-$AIUR_LOGS_ROOT/erl_crash.dump}"
    export ERL_CRASH_DUMP_SECONDS="${ERL_CRASH_DUMP_SECONDS:-30}"
  fi

  # Capture sink for BEAM startup (and, in background mode, the whole run's
  # boot stdout/stderr). Foreground uses a throwaway tempfile; background points
  # at a durable file in the run log dir. The dir/file is created lazily just
  # before launch (below) so an idempotent early-return start leaves no empty dir.
  local startup_capture
  if [ "$mode" = "background" ] && [ -n "${AIUR_LOGS_ROOT:-}" ]; then
    startup_capture="$AIUR_LOGS_ROOT/log/boot.out.log"
  else
    startup_capture="$(mktemp "${TMPDIR:-/tmp}/aiur-startup.XXXXXX")"
  fi

  # Inner pane script: tmux's server may pre-exist and not inherit our env, so
  # re-export every var the BEAM needs. tee preserves a startup capture.
  local launcher
  launcher="$(mktemp "${TMPDIR:-/tmp}/aiur-pane.XXXXXX")"
  chmod +x "$launcher"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -o pipefail\n'
    printf 'unset AIUR_CI_READINESS_TOKEN\n'
    printf 'cd %q || exit 1\n' "$PWD"
    local v
    for v in AIUR_RELEASE_DIR AIUR_ARGV_FILE RELEASE_DISTRIBUTION RELEASE_NODE \
      RELEASE_COOKIE ERL_AFLAGS ERL_EPMD_ADDRESS AIUR_NODE AIUR_ERLANG_COOKIE \
      AIUR_TMUX_SESSION AIUR_TMUX_SOCKET AIUR_TMUX_CONF AIUR_BIN \
      AIUR_SESSION_TMPFILE AIUR_AGENT_TMPFILE AIUR_WORKSPACE_ROOT_FILE \
      ELIXIR_ERL_OPTIONS AIUR_LOGS_ROOT AIUR_OPENCODE_BRIDGE_PORT AIUR_DEBUG \
      AIUR_OPERATOR_PID AIUR_NOFILE_SOFT_LIMIT ERL_CRASH_DUMP ERL_CRASH_DUMP_SECONDS; do
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
      _session_node="$AIUR_RELEASE_NODE" _session_pidfile="$AIUR_AGENT_TMPFILE" \
      _session_workspace_root_file="$AIUR_WORKSPACE_ROOT_FILE"
    install_foreground_traps
  fi

  # Background starts are intentionally idempotent. A prior live node should not
  # fall through to tmux's opaque "duplicate session" failure, and a stale tmux
  # session whose BEAM/control plane is gone should be reclaimed before retry.
  if [ "$mode" = "background" ] && "$tmux_bin" -L "$socket" -f "$conf" has-session -t "$session" 2>/dev/null; then
    if [ "$(probe_control_liveness)" = "up" ]; then
      # Write a record only when none exists. A live session's own start already
      # wrote one — and it owns the BEAM-written AIUR_RECORD_WORKSPACE_ROOT_FILE
      # path, which must not be overwritten by this invocation's temp file.
      [ -f "$(aiur_instance_record_path)" ] || (AIUR_WORKSPACE_ROOT_FILE="" write_aiur_instance_record "$session" "$socket")
      echo "aiur is already running in the background (tmux session ${session})." >&2
      echo "Use: aiur status   # inspect agents" >&2
      echo "Use: aiur stop     # stop it before starting a fresh session" >&2
      rm -f "$startup_capture" "$argv_file" "$launcher" "$AIUR_SESSION_TMPFILE" "$AIUR_AGENT_TMPFILE" "$AIUR_WORKSPACE_ROOT_FILE" 2>/dev/null || true
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

  # Create the capture sink now (after the idempotent early-return checks above,
  # so a no-op "already running" start never mints an empty run log dir). The
  # launcher's `tee -a` needs the file's parent to exist when the pane runs.
  mkdir -p "$(dirname "$startup_capture")" 2>/dev/null || true
  : >"$startup_capture" 2>/dev/null || true

  if ! "$tmux_bin" -L "$socket" -f "$conf" new-session -d -s "$session" \
    -x "${COLUMNS:-200}" -y "${LINES:-50}" "$inner_cmd"; then
    echo "❌ aiur failed to start; captured output:" >&2
    tail -n 30 "$startup_capture" 2>/dev/null | sed 's/^/  /' >&2 || true
    rm -f "$startup_capture" "$argv_file" "$launcher" "$AIUR_SESSION_TMPFILE" "$AIUR_AGENT_TMPFILE" "$AIUR_WORKSPACE_ROOT_FILE" 2>/dev/null || true
    exit 1
  fi

  # Title the agent-list pane (the only pane in the fresh session). The conf's
  # `pane-border-status`/`pane-border-format` render it; PaneManager titles the
  # chat panes it opens. Best-effort — a missing title just shows the default.
  "$tmux_bin" -L "$socket" -f "$conf" select-pane -t "$session" -T "AIUR Agents" 2>/dev/null || true

  # Grace window: surface a boot crash instead of attaching to nothing. Prove
  # the control plane can answer before declaring startup usable: background
  # control commands depend on that RPC path, and foreground automation must not
  # treat a pre-TUI application crash as a successful `tmux attach`.
  local require_control=1
  if ! wait_for_session_startup "$tmux_bin" "$socket" "$conf" "$session" "$startup_capture" "$require_control"; then
    if [ "$mode" = "background" ]; then
      "$tmux_bin" -L "$socket" -f "$conf" kill-session -t "$session" 2>/dev/null || true
      reap_aiur_agents "$socket" "$AIUR_AGENT_TMPFILE"
      kill_beams_matching "-name ${AIUR_RELEASE_NODE}"
    fi
    [ "$mode" = "foreground" ] && return 1
    rm -f "$startup_capture" "$argv_file" "$launcher" "$AIUR_SESSION_TMPFILE" "$AIUR_AGENT_TMPFILE" "$AIUR_WORKSPACE_ROOT_FILE" 2>/dev/null || true
    exit 1
  fi

  write_aiur_instance_record "$session" "$socket"

  if [ "$mode" = "foreground" ]; then
    echo "aiur foreground tmux socket ${socket}, session ${session}" >&2
  fi

  if [ "$mode" = "background" ]; then
    # Fresh run: drop any stale crash/stop state from a prior dead instance so
    # `status` doesn't report a phantom orphan and the watchdog starts clean.
    rm -f "$(aiur_stop_sentinel_path)" "$(aiur_crash_marker_path)" 2>/dev/null || true

    local background_watchdog_pid
    background_watchdog_pid="$(start_beam_death_watchdog \
      "-name ${AIUR_RELEASE_NODE}" "$socket" "$AIUR_AGENT_TMPFILE" 1 1 \
      "$AIUR_RELEASE_NODE" "${AIUR_LOGS_ROOT:-}" \
      "$(aiur_stop_sentinel_path)" "$(aiur_crash_marker_path)" "$AIUR_WORKSPACE_ROOT_FILE")"
    disown "$background_watchdog_pid" 2>/dev/null || true
    print_background_dashboard_status "$no_dashboard" "$startup_capture"
    echo "aiur started in the background (tmux socket ${socket}, session ${session}). Attach with: aiur" >&2
    # Keep $startup_capture (boot.out.log) for the run's lifetime; only the
    # transient argv file is no longer needed.
    rm -f "$argv_file" 2>/dev/null || true
    return 0
  fi

  # Arm the BEAM-death watchdog before attaching. If the BEAM crashes
  # (:emfile) mid-run, agent windows keep the orphaned session alive so the
  # `tmux attach` below never returns and the EXIT trap never fires — the
  # watchdog is the external reaper that survives the dead BEAM, kill-servers
  # the session, and unblocks the attach. It polls the node name rather than a
  # captured pid, so another Aiur instance from the same release cannot hold it open.
  _session_watchdog_pid="$(start_beam_death_watchdog \
    "-name ${AIUR_RELEASE_NODE}" "$socket" "$AIUR_AGENT_TMPFILE" 1 0 \
    "" "" "" "" "$AIUR_WORKSPACE_ROOT_FILE")"

  # Foreground: attach the UI. Do not exec — that would drop the teardown trap.
  # Avoid process substitution here: some sandboxed non-TTY launchers reject
  # opening /dev/fd/* during the real manual-test wrapper path.
  local attach_stderr attach_code
  attach_stderr="$(mktemp "${TMPDIR:-/tmp}/aiur-attach-stderr.XXXXXX")"
  "$tmux_bin" -L "$socket" -f "$conf" attach -t "$session" 2>"$attach_stderr"
  attach_code=$?
  grep -v -F "[server exited]" "$attach_stderr" >&2 || true
  rm -f "$attach_stderr" 2>/dev/null || true
  return "$attach_code"
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

pid_owner() {
  ps -p "$1" -o user= 2>/dev/null | awk '{print $1}' || true
}

pid_command() {
  ps -p "$1" -o command= 2>/dev/null || true
}

pid_ppid() {
  ps -p "$1" -o ppid= 2>/dev/null | awk '{print $1}' || true
}

pid_cwd() {
  local pid="$1" cwd
  if [ -e "/proc/$pid/cwd" ]; then
    readlink "/proc/$pid/cwd" 2>/dev/null || true
    return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1 || true)"
    [ -n "$cwd" ] && printf '%s\n' "$cwd"
  fi
}

kill_pid_with_escalation() {
  local pid="$1" waited=0
  [ -n "$pid" ] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$waited" -lt 20 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  kill -KILL "$pid" 2>/dev/null || true
}

aiur_node_from_command() {
  local cmd="$1" node
  node="$(printf '%s\n' "$cmd" | sed -n "s/.*--name[[:space:]]\\(aiur-${USER}[-A-Za-z0-9_]*@127\\.0\\.0\\.1\\).*/\\1/p" | head -n 1)"
  [ -n "$node" ] && printf '%s\n' "$node"
}

aiur_release_root_from_command() {
  local cmd="$1"
  if [[ "$cmd" =~ --boot-var[[:space:]]+RELEASE_LIB[[:space:]]+([^[:space:]]+)/lib ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$cmd" =~ ([^[:space:]]*/src/_build/dev/rel/aiur)/releases/ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$cmd" =~ ([^[:space:]]*/release)/releases/ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

workspace_root_from_aiur_release_root() {
  local release_root="${1%/}"
  case "$release_root" in
    */src/_build/dev/rel/aiur)
      printf '%s\n' "${release_root%/src/_build/dev/rel/aiur}"
      ;;
    *)
      printf '%s\n' "$release_root"
      ;;
  esac
}

aiur_node_tmux_session_alive() {
  local node="$1" short tmux_bin
  short="${node%@*}"
  tmux_bin="$(command -v tmux || true)"
  [ -n "$tmux_bin" ] || return 1
  "$tmux_bin" -L "$short" has-session -t "${short}-default" 2>/dev/null
}

stale_manual_smoke_beam_inventory() {
  local pid cmd node release_root workspace_root owner
  aiur_resolve_identity

  for pid in $(pgrep -f -- "beam\\.smp.*--name aiur-${USER}.*@127\\.0\\.0\\.1" 2>/dev/null || true); do
    [ -n "$pid" ] || continue
    owner="$(pid_owner "$pid")"
    [ "$owner" = "$USER" ] || continue

    cmd="$(pid_command "$pid")"
    node="$(aiur_node_from_command "$cmd")"
    [ -n "$node" ] || continue

    release_root="$(aiur_release_root_from_command "$cmd" || true)"
    [ -n "$release_root" ] || continue
    workspace_root="$(workspace_root_from_aiur_release_root "$release_root")"

    # Scope this broad cleanup to stale issue/manual-smoke workspaces. The
    # current instance cleanup path handles the active daemon's own node.
    case "$workspace_root" in
      */aiur-workspaces/*) ;;
      *) continue ;;
    esac

    # A matching live aiur tmux session means this node may still be in use.
    aiur_node_tmux_session_alive "$node" && continue

    printf '%s\t%s\t%s\t%s\n' "$pid" "$node" "$workspace_root" "$release_root"
  done
}

manual_smoke_wrapper_tmux_sockets() {
  local tmux_bin sockdir path name panes current pane_path start manual_context all_sleep
  tmux_bin="$(command -v tmux || true)"
  [ -n "$tmux_bin" ] || return 0
  sockdir="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
  [ -d "$sockdir" ] || return 0

  for path in "$sockdir"/*; do
    [ -S "$path" ] || continue
    name="${path##*/}"
    case "$name" in
      codex-driver-* | codex-aiur* | codex-[0-9]* | claude-driver*) ;;
      *) continue ;;
    esac
    panes="$("$tmux_bin" -L "$name" list-panes -a -F '#{pane_current_command}	#{pane_current_path}	#{pane_start_command}' 2>/dev/null || true)"
    [ -n "$panes" ] || continue
    manual_context=0
    all_sleep=1
    while IFS=$'\t' read -r current pane_path start; do
      case "$start" in
        *aiurdev\ --test* | *scripts/aiurdev\ --test*) manual_context=1 ;;
      esac
      [ "$current" = "sleep" ] || all_sleep=0
    done <<<"$panes"
    [ "$manual_context" -eq 1 ] && [ "$all_sleep" -eq 1 ] && printf '%s\n' "$name"
  done
}

orphaned_opencode_attach_inventory() {
  local pid owner ppid cmd cwd
  for pid in $(pgrep -f -- "opencode attach http://127\\.0\\.0\\.1:" 2>/dev/null || true); do
    owner="$(pid_owner "$pid")"
    [ "$owner" = "$USER" ] || continue
    ppid="$(pid_ppid "$pid")"
    [ "$ppid" = "1" ] || continue
    cwd="$(pid_cwd "$pid")"
    case "$cwd" in
      */aiur-workspaces/*) ;;
      *) continue ;;
    esac
    cmd="$(pid_command "$pid")"
    case "$cmd" in
      *"opencode attach http://127.0.0.1:"*) printf '%s\t%s\t%s\n' "$pid" "$cwd" "$cmd" ;;
    esac
  done
}

report_stale_manual_smoke() {
  local found=0 pid node workspace_root release_root socket cwd cmd

  while IFS=$'\t' read -r pid node workspace_root release_root; do
    [ -n "$pid" ] || continue
    if [ "$found" -eq 0 ]; then
      echo "aiur: stale manual-smoke leftovers detected:" >&2
      found=1
    fi
    echo "  BEAM pid=${pid} node=${node} workspace=${workspace_root} release=${release_root}" >&2
  done < <(stale_manual_smoke_beam_inventory)

  while IFS= read -r socket; do
    [ -n "$socket" ] || continue
    if [ "$found" -eq 0 ]; then
      echo "aiur: stale manual-smoke leftovers detected:" >&2
      found=1
    fi
    echo "  wrapper tmux socket=${socket}" >&2
  done < <(manual_smoke_wrapper_tmux_sockets)

  while IFS=$'\t' read -r pid cwd cmd; do
    [ -n "$pid" ] || continue
    if [ "$found" -eq 0 ]; then
      echo "aiur: stale manual-smoke leftovers detected:" >&2
      found=1
    fi
    echo "  orphan opencode attach pid=${pid} workspace=${cwd}" >&2
  done < <(orphaned_opencode_attach_inventory)

  if [ "$found" -eq 1 ]; then
    echo "aiur: run 'aiur cleanup-stale' to TERM/KILL only these same-user Aiur leftovers." >&2
  fi

  return "$found"
}

preflight_stale_manual_smoke() {
  report_stale_manual_smoke >/dev/null || true
}

reap_stale_manual_smoke() {
  local include_wrappers="${1:-0}"
  local pid node workspace_root release_root socket cwd cmd tmux_bin reaped=0

  while IFS=$'\t' read -r pid node workspace_root release_root; do
    [ -n "$pid" ] || continue
    echo "aiur: reaping stale BEAM pid=${pid} node=${node} workspace=${workspace_root}" >&2
    kill_pid_with_escalation "$pid"
    reaped=$((reaped + 1))
  done < <(stale_manual_smoke_beam_inventory)

  tmux_bin="$(command -v tmux || true)"
  if [ "$include_wrappers" = "1" ] && [ -n "$tmux_bin" ]; then
    while IFS= read -r socket; do
      [ -n "$socket" ] || continue
      echo "aiur: reaping stale wrapper tmux socket=${socket}" >&2
      "$tmux_bin" -L "$socket" kill-server 2>/dev/null || true
      reaped=$((reaped + 1))
    done < <(manual_smoke_wrapper_tmux_sockets)
  fi

  while IFS=$'\t' read -r pid cwd cmd; do
    [ -n "$pid" ] || continue
    echo "aiur: reaping orphan opencode attach pid=${pid}" >&2
    kill_pid_with_escalation "$pid"
    reaped=$((reaped + 1))
  done < <(orphaned_opencode_attach_inventory)

  if [ "$reaped" -eq 0 ]; then
    echo "aiur: no stale manual-smoke leftovers found" >&2
  fi
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
# never touching the Executor’s own default tmux. Headless agents (claude/codex
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

# Stable, per-instance state paths the background BEAM-death machinery shares
# across `run`, `stop`, and `status`. Keyed by the (instance-keyed) release node
# rather than the tmux socket so `status` — which resolves the node but not the
# socket — agrees on the same files. AIUR_BG_STATE_DIR and AIUR_RELEASE_NODE are
# resolved by aiur_resolve_identity, which every one of those paths calls first.
aiur_state_slug() {
  printf '%s' "${AIUR_RELEASE_NODE:-aiur}" | tr -c 'A-Za-z0-9._-' '_'
}

aiur_instances_dir() {
  printf '%s/instances' "${AIUR_BG_STATE_DIR:?}"
}

aiur_instance_record_path() {
  printf '%s/%s.instance' "$(aiur_instances_dir)" "$(aiur_state_slug)"
}

write_aiur_instance_record() {
  local session="$1" socket="$2" record_dir record tmp root
  record_dir="$(aiur_instances_dir)"
  record="$(aiur_instance_record_path)"
  root="$(canonical_workspace_root "${AIUR_PROJECT_ROOT:-}")"
  mkdir -p "$record_dir" 2>/dev/null || return 0
  tmp="$(mktemp "$record_dir/.${AIUR_INSTANCE_KEY:-aiur}.XXXXXX" 2>/dev/null)" || return 0
  {
    printf 'AIUR_RECORD_NODE=%q\n' "$AIUR_RELEASE_NODE"
    printf 'AIUR_RECORD_INSTANCE_KEY=%q\n' "$AIUR_INSTANCE_KEY"
    printf 'AIUR_RECORD_SESSION=%q\n' "$session"
    printf 'AIUR_RECORD_SOCKET=%q\n' "$socket"
    printf 'AIUR_RECORD_WORKSPACE_ROOT_FILE=%q\n' "${AIUR_WORKSPACE_ROOT_FILE:-}"
    printf 'AIUR_RECORD_PROJECT_ROOT=%q\n' "$root"
    printf 'AIUR_RECORD_PROJECT_ROOT_SOURCE=%q\n' "${AIUR_PROJECT_ROOT_SOURCE:-}"
    printf 'AIUR_RECORD_WRITTEN_AT=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  } >"$tmp" || { rm -f "$tmp" 2>/dev/null || true; return 0; }
  chmod 0600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$record" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

# Marker `status` reads to tell "daemon crashed, agents may be orphaned" apart
# from "nothing was ever running". Written by the watchdog on an unexpected exit,
# cleared on a clean stop and on the next successful background start.
aiur_crash_marker_path() {
  printf '%s/%s.last-crash' "${AIUR_BG_STATE_DIR:?}" "$(aiur_state_slug)"
}

# Sentinel `stop` drops before killing the BEAM so the watchdog knows the exit
# was intentional and does not record a false crash.
aiur_stop_sentinel_path() {
  printf '%s/%s.stopping' "${AIUR_BG_STATE_DIR:?}" "$(aiur_state_slug)"
}

# Write a durable record that the background BEAM exited unexpectedly. Two sinks:
# the run log dir (full record next to aiur.log, for forensics) and the stable
# per-instance marker (for `status` to surface). Best-effort throughout — this
# runs in the disowned watchdog after the BEAM is already gone, so it must never
# fail loudly or block the reap that follows.
record_beam_crash() {
  local node="$1" run_log_dir="$2" marker="$3"
  local ts boot_tail=""
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  if [ -n "$run_log_dir" ] && [ -r "$run_log_dir/log/boot.out.log" ]; then
    boot_tail="$(tail -n 20 "$run_log_dir/log/boot.out.log" 2>/dev/null || true)"
  fi

  local body
  body="$(
    printf 'aiur background BEAM exited unexpectedly\n'
    printf 'timestamp: %s\n' "${ts:-unknown}"
    printf 'node: %s\n' "${node:-unknown}"
    printf 'run_log_dir: %s\n' "${run_log_dir:-unknown}"
    printf 'detected_by: background BEAM-death watchdog (no clean stop sentinel)\n'
    if [ -n "$boot_tail" ]; then
      printf -- '--- last 20 lines of boot.out.log ---\n%s\n' "$boot_tail"
    fi
  )"

  if [ -n "$run_log_dir" ]; then
    mkdir -p "$run_log_dir/log" 2>/dev/null || true
    printf '%s\n' "$body" >>"$run_log_dir/log/aiur.crash" 2>/dev/null || true
  fi
  if [ -n "$marker" ]; then
    printf '%s\n' "$body" >"$marker" 2>/dev/null || true
  fi
}

canonical_workspace_root() {
  local root="$1"
  if [ -d "$root" ]; then
    (cd "$root" 2>/dev/null && pwd -P) || printf '%s\n' "$root"
  else
    printf '%s\n' "$root"
  fi
}

workspace_root_is_shallow() {
  local root="${1%/}" trimmed
  trimmed="${root#/}"
  [ -n "$trimmed" ] || return 0
  case "$trimmed" in
    */*) return 1 ;;
    *) return 0 ;;
  esac
}

workspace_cwd_pids() {
  local root="${1%/}" proc_dir="${2:-/proc}" entry pid cwd
  [ -d "$proc_dir" ] || return 0

  for entry in "$proc_dir"/[0-9]*; do
    [ -d "$entry" ] || continue
    pid="${entry##*/}"
    cwd="$(readlink "$entry/cwd" 2>/dev/null || true)"
    [ -n "$cwd" ] || continue
    cwd="${cwd%/}"
    if [ "$cwd" != "$root" ] && [[ "$cwd/" == "$root/"* ]]; then
      printf '%s\n' "$pid"
    fi
  done
}

shell_protected_pid_list() {
  local p
  printf '%s\n' "$$"
  [ "${BASHPID:-$$}" = "$$" ] || printf '%s\n' "$BASHPID"
  [ -n "${PPID:-}" ] && printf '%s\n' "$PPID"
  for p in $(agent_pid_tree "$$" 2>/dev/null || true); do
    printf '%s\n' "$p"
  done
}

reap_workspace_cwd_agents() {
  local root="${1:-}"
  [ -n "$root" ] || return 0
  [ -d /proc ] || return 0

  root="$(canonical_workspace_root "$root")"
  if workspace_root_is_shallow "$root"; then
    echo "⚠️ refusing shallow workspace cwd sweep root: $root" >&2
    return 0
  fi

  local max_sweeps="${AIUR_WORKSPACE_REAP_SWEEPS:-6}"
  case "$max_sweeps" in '' | *[!0-9]*) max_sweeps=6 ;; esac
  [ "$max_sweeps" -gt 0 ] || return 0

  local protected pids=() filtered=() pid p sweep waited any
  protected=" $(shell_protected_pid_list | tr '\n' ' ') "

  sweep=0
  while [ "$sweep" -lt "$max_sweeps" ]; do
    mapfile -t pids < <(workspace_cwd_pids "$root" /proc)
    filtered=()
    for pid in "${pids[@]}"; do
      case "$protected" in *" $pid "*) continue ;; esac
      kill -0 "$pid" 2>/dev/null && filtered+=("$pid")
    done

    [ "${#filtered[@]}" -gt 0 ] || return 0

    for p in "${filtered[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
    waited=0
    while [ "$waited" -lt 10 ]; do
      any=0
      for p in "${filtered[@]}"; do kill -0 "$p" 2>/dev/null && { any=1; break; }; done
      [ "$any" -eq 0 ] && break
      sleep 0.1
      waited=$((waited + 1))
    done
    for p in "${filtered[@]}"; do kill -KILL "$p" 2>/dev/null || true; done

    sweep=$((sweep + 1))
    sleep 0.1
  done
}

reap_workspace_cwd_from_file() {
  local root_file="${1:-}" root
  [ -n "$root_file" ] && [ -s "$root_file" ] || return 0
  IFS= read -r root <"$root_file" || root=""
  reap_workspace_cwd_agents "$root"
}

workspace_root_file_from_instance_record() {
  load_aiur_instance_record "$(aiur_instance_record_path)" || return 1
  [ -n "${AIUR_RECORD_WORKSPACE_ROOT_FILE:-}" ] || return 1
  printf '%s\n' "$AIUR_RECORD_WORKSPACE_ROOT_FILE"
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
#   $6 node  $7 run_log_dir  $8 stop_sentinel  $9 crash_marker
#   $10 workspace_root_file
# Args 6-9 arm crash recording (background mode). Omit them (foreground) and the
# watchdog only reaps — a foreground BEAM death is already visible at the UI.
# Prints the watchdog's own pid so the caller can kill it on a clean teardown.
start_beam_death_watchdog() {
  local beam_pattern="$1" socket="$2" pidfile="$3" interval="${4:-1}" initial_seen="${5:-0}"
  local node="${6:-}" run_log_dir="${7:-}" stop_sentinel="${8:-}" crash_marker="${9:-}" workspace_root_file="${10:-}"
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
    # The BEAM we had seen is gone. A clean `aiur stop` drops the sentinel first;
    # its presence means an intentional exit (consume it, no crash record).
    # Anything else is an unexpected exit worth a durable record before reaping.
    if [ -n "$stop_sentinel" ] && [ -f "$stop_sentinel" ]; then
      rm -f "$stop_sentinel" 2>/dev/null || true
    elif [ -n "$crash_marker" ] || [ -n "$run_log_dir" ]; then
      record_beam_crash "$node" "$run_log_dir" "$crash_marker"
    fi
    reap_aiur_agents "$socket" "$pidfile"
    reap_workspace_cwd_from_file "$workspace_root_file"
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

# Return the externally useful dashboard URL only when the running node confirms
# that Bandit actually bound a listener. An empty result means the listener was
# suppressed or refused; configured server.port alone is never proof of service.
probe_dashboard_url() {
  local expression output status marker="__AIUR_DASHBOARD_URL__:"
  expression='case Aiur.HttpServer.base_url() do url when is_binary(url) -> IO.puts("__AIUR_DASHBOARD_URL__:" <> url); _ -> :ok end'

  set +e
  output="$("$release_bin" rpc "$expression" 2>&1)"
  status=$?
  set -e

  if [ "$status" -eq 0 ] && [[ "$output" == *"$marker"* ]]; then
    output="${output#*"$marker"}"
    printf '%s' "${output%%$'\n'*}"
  fi
}

print_background_dashboard_status() {
  local no_dashboard="$1" startup_capture="$2" url
  url="$(probe_dashboard_url)"

  if [ -n "$url" ]; then
    echo "Dashboard: ${url}" >&2
  elif [ "$no_dashboard" -eq 1 ]; then
    echo "Dashboard disabled by --no-dashboard." >&2
  else
    echo "⚠️ dashboard listener unavailable; inspect ${startup_capture} for bind or authentication refusal." >&2
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
_session_pidfile="" _session_watchdog_pid="" _session_workspace_root_file=""
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

  # Final cwd-sweep backstop after the BEAM is gone: catches workspace-rooted
  # agents or test children that registered too late, reparented during the
  # BEAM-side sweep, or survived a bounded in-BEAM cleanup.
  reap_workspace_cwd_from_file "$_session_workspace_root_file"

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

  rm -f "$_session_tmpfile" "$_session_capture" "$_session_argv" "$_session_pidfile" "$_session_workspace_root_file" 2>/dev/null || true
  rm -f "$(aiur_instance_record_path)" 2>/dev/null || true
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

probe_named_node_liveness() {
  local node="$1" old_node="${RELEASE_NODE:-}" state
  RELEASE_NODE="$node"
  state="$(probe_node_liveness)"
  RELEASE_NODE="$old_node"
  printf '%s' "$state"
}

load_aiur_instance_record() {
  local file="$1"
  AIUR_RECORD_NODE=""
  AIUR_RECORD_INSTANCE_KEY=""
  AIUR_RECORD_SESSION=""
  AIUR_RECORD_SOCKET=""
  AIUR_RECORD_WORKSPACE_ROOT_FILE=""
  AIUR_RECORD_PROJECT_ROOT=""
  AIUR_RECORD_PROJECT_ROOT_SOURCE=""
  [ -r "$file" ] || return 1
  # Records are written by this engine as KEY=%q lines under the user's state dir.
  # shellcheck disable=SC1090
  source "$file" 2>/dev/null || return 1
  [ -n "$AIUR_RECORD_NODE" ] && [ -n "$AIUR_RECORD_SESSION" ] && \
    [ -n "$AIUR_RECORD_SOCKET" ] && [ -n "$AIUR_RECORD_PROJECT_ROOT" ]
}

path_is_within_root() {
  local root child
  root="$(canonical_workspace_root "$1")"
  child="$(canonical_workspace_root "$2")"
  [ "$child" = "$root" ] || [[ "$child/" == "$root/"* ]]
}

AIUR_CONTROL_ADOPTED_RECORD=0
AIUR_CONTROL_CURRENT_NODE_STATE=""
AIUR_CONTROL_HINT_ROOTS=""
AIUR_CONTROL_CALLER_ROOT=""
AIUR_CONTROL_CALLER_NODE=""
AIUR_CONTROL_CALLER_ROOT_SOURCE=""

resolve_control_identity_from_records() {
  AIUR_CONTROL_ADOPTED_RECORD=0
  AIUR_CONTROL_CURRENT_NODE_STATE="$(probe_node_liveness)"
  AIUR_CONTROL_HINT_ROOTS=""
  AIUR_CONTROL_CALLER_ROOT="$(canonical_workspace_root "${AIUR_PROJECT_ROOT:-}")"
  AIUR_CONTROL_CALLER_NODE="$AIUR_RELEASE_NODE"
  AIUR_CONTROL_CALLER_ROOT_SOURCE="${AIUR_PROJECT_ROOT_SOURCE:-}"

  [ "$AIUR_CONTROL_CURRENT_NODE_STATE" = "down" ] || return 0
  [ "${AIUR_PROJECT_ROOT_SOURCE:-}" = "cwd" ] || return 0

  local dir file state root match_count=0
  local match_node="" match_key="" match_session="" match_socket="" match_root="" match_source=""
  dir="$(aiur_instances_dir)"
  [ -d "$dir" ] || return 0

  for file in "$dir"/*.instance; do
    [ -e "$file" ] || continue
    load_aiur_instance_record "$file" || continue
    state="$(probe_named_node_liveness "$AIUR_RECORD_NODE")"
    [ "$state" = "up" ] || continue

    root="$(canonical_workspace_root "$AIUR_RECORD_PROJECT_ROOT")"
    case "$AIUR_CONTROL_HINT_ROOTS" in
      *"
$root
"*) ;;
      *) AIUR_CONTROL_HINT_ROOTS="${AIUR_CONTROL_HINT_ROOTS}${root}
" ;;
    esac

    path_is_within_root "$root" "$AIUR_CONTROL_CALLER_ROOT" || continue
    match_count=$((match_count + 1))
    match_node="$AIUR_RECORD_NODE"
    match_key="$AIUR_RECORD_INSTANCE_KEY"
    match_session="$AIUR_RECORD_SESSION"
    match_socket="$AIUR_RECORD_SOCKET"
    match_root="$root"
    match_source="$AIUR_RECORD_PROJECT_ROOT_SOURCE"
  done

  [ "$match_count" -eq 1 ] || return 0

  AIUR_RELEASE_NODE="$match_node"
  AIUR_INSTANCE_KEY="$match_key"
  AIUR_PROJECT_ROOT="$match_root"
  AIUR_PROJECT_ROOT_SOURCE="$match_source"
  AIUR_ADOPTED_TMUX_SESSION="$match_session"
  AIUR_ADOPTED_TMUX_SOCKET="$match_socket"
  export AIUR_RELEASE_NODE AIUR_INSTANCE_KEY AIUR_PROJECT_ROOT AIUR_PROJECT_ROOT_SOURCE \
    AIUR_ADOPTED_TMUX_SESSION AIUR_ADOPTED_TMUX_SOCKET
  RELEASE_NODE="$AIUR_RELEASE_NODE"
  export RELEASE_NODE
  AIUR_CONTROL_ADOPTED_RECORD=1
}

print_global_config_control_hint() {
  [ -n "${AIUR_CONTROL_HINT_ROOTS:-}" ] || return 0
  [ "${AIUR_CONTROL_CALLER_ROOT_SOURCE:-}" = "cwd" ] || return 0
  [ "${AIUR_CONTROL_CURRENT_NODE_STATE:-}" = "down" ] || return 0

  echo "aiur: global-config control identity is keyed by cwd ${AIUR_CONTROL_CALLER_ROOT:-${AIUR_PROJECT_ROOT:-unknown}}" >&2
  echo "aiur: run control commands from the launch directory, or from a subdirectory of that launch directory" >&2
  echo "aiur: live launch directory candidate(s):" >&2
  printf '%s' "$AIUR_CONTROL_HINT_ROOTS" | sed '/^$/d; s/^/  /' >&2
}

control_rpc_timeout_seconds() {
  local seconds="${AIUR_CONTROL_RPC_TIMEOUT_SECONDS:-10}"
  case "$seconds" in
    '' | *[!0-9]* | 0) seconds=10 ;;
  esac
  printf '%s' "$seconds"
}

print_not_running_message() {
  echo "error: aiur is not running. Start it with \`aiurdev run\` (or \`aiurdev --bg\`), then retry." >&2
}

print_control_down_message() {
  local crash_marker
  crash_marker="$(aiur_crash_marker_path)"
  if [ -f "$crash_marker" ]; then
    echo "aiur: background daemon at ${RELEASE_NODE} is DOWN after an unexpected exit; agents may be orphaned" >&2
    sed 's/^/  /' "$crash_marker" >&2 2>/dev/null || true
    echo "aiur: run 'aiur stop' to reap any orphaned agents, then start aiur again" >&2
  else
    print_not_running_message
    print_global_config_control_hint
  fi
}

kill_control_rpc_process() {
  local pid="$1" grouped="$2" p tree=()
  [ -n "$pid" ] || return 0

  # Snapshot descendants before signalling the wrapper. A release launcher may
  # fork its rpc BEAM into another process group and then exit; group signalling
  # alone would orphan that child and lose the only relationship we can reap.
  while IFS= read -r p; do tree+=("$p"); done < <(agent_pid_tree "$pid")

  if [ "$grouped" = "1" ]; then
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  fi

  for p in "${tree[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
  sleep 0.2
  if [ "$grouped" = "1" ]; then
    kill -KILL "-$pid" 2>/dev/null || true
  fi
  for p in "${tree[@]}"; do kill -KILL "$p" 2>/dev/null || true; done
}

run_release_rpc_with_timeout() {
  local expression="$1" timeout output_file timeout_file pid watchdog_pid status grouped=0
  timeout="$(control_rpc_timeout_seconds)"
  output_file="$(mktemp "${TMPDIR:-/tmp}/aiur-control-rpc-output.XXXXXX")"
  timeout_file="$(mktemp "${TMPDIR:-/tmp}/aiur-control-rpc-timeout.XXXXXX")"
  rm -f "$timeout_file" 2>/dev/null || true

  if command -v setsid >/dev/null 2>&1; then
    setsid "$release_bin" rpc "$expression" >"$output_file" 2>&1 &
    grouped=1
  else
    "$release_bin" rpc "$expression" >"$output_file" 2>&1 &
  fi
  pid=$!

  (
    sleep "$timeout"
    if kill -0 "$pid" 2>/dev/null; then
      : >"$timeout_file"
      kill_control_rpc_process "$pid" "$grouped"
    fi
  ) &
  watchdog_pid=$!

  if wait "$pid"; then
    status=0
  else
    status=$?
  fi
  if [ -f "$timeout_file" ]; then
    # The timeout watchdog owns descendant cleanup. Once it has marked the
    # timeout, let it finish its TERM/KILL sequence; cancelling it here can
    # strand descendants that ignored TERM after the root process exits.
    :
  else
    kill "$watchdog_pid" 2>/dev/null || true
  fi
  wait "$watchdog_pid" 2>/dev/null || true

  AIUR_CONTROL_RPC_OUTPUT="$(cat "$output_file" 2>/dev/null || true)"
  if [ -f "$timeout_file" ]; then
    AIUR_CONTROL_RPC_TIMED_OUT=1
    status=124
  else
    AIUR_CONTROL_RPC_TIMED_OUT=0
  fi

  rm -f "$output_file" "$timeout_file" 2>/dev/null || true
  return "$status"
}

# RPC an expression into the running node. The control CLI prints a trailing
# `__AIUR_CONTROL_EXIT__:<code>` marker we translate into the process exit code.
run_control_rpc() {
  local expression="$1"
  resolve_release || return $?
  prepare_distribution || die "distribution setup failed; cannot contact aiur"
  resolve_control_identity_from_records
  if [ "${AIUR_CONTROL_ADOPTED_RECORD:-0}" -eq 1 ]; then
    prepare_distribution || die "distribution setup failed; cannot contact aiur"
  fi

  local marker="__AIUR_CONTROL_EXIT__:" error_marker="__AIUR_CONTROL_ERROR__:"
  local output status exit_code=0 saw_marker=0 saw_error=0 saw_output=0 line partial_suffix=""

  set +e
  run_release_rpc_with_timeout "$expression"
  status=$?
  output="$AIUR_CONTROL_RPC_OUTPUT"
  set -e

  if [ "$status" -ne 0 ] && [ "${AIUR_CONTROL_RELEASE_RETRYABLE:-0}" = "1" ] && \
    { [ ! -x "$release_bin" ] || [ ! -x "$vsn_dir/elixir" ] || [ ! -r "$release_dir/releases/start_erl.data" ]; }; then
    control_release_retry
    return $?
  fi

  if [ "${AIUR_CONTROL_RPC_TIMED_OUT:-0}" -eq 1 ]; then
    [ -n "$output" ] && partial_suffix="; partial output was discarded"
    echo "aiur: control rpc to ${RELEASE_NODE} timed out after $(control_rpc_timeout_seconds)s; daemon may be scheduler-saturated${partial_suffix}; rerun stop with the launcher that started this session (for example, 'aiurdev stop') to interrupt its workers, then start aiur again" >&2
    return 124
  fi

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
        print_control_down_message
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
      "$error_marker"*)
        saw_error=1
        printf '%s\n' "${line#"$error_marker"}" >&2
        ;;
      :ok | "") ;;
      *)
        saw_output=1
        printf '%s\n' "$line"
        ;;
    esac
  done <<<"$output"

  if [ "$saw_marker" -ne 1 ]; then
    echo "aiur: control rpc to ${RELEASE_NODE} returned no exit marker; command output may be incomplete" >&2
    return 1
  fi

  if [ "$exit_code" -ne 0 ] && [ "$saw_error" -ne 1 ] && [ "$saw_output" -ne 1 ]; then
    echo "aiur: control RPC failed with exit ${exit_code} and returned no diagnostic output" >&2
  fi

  return "$exit_code"
}

# A streaming Executor listener must retain the RPC process and its stdout. It
# intentionally bypasses the one-shot control timeout and exit-marker wrapper.
run_control_stream() {
  local expression="$1"
  resolve_release || return $?
  prepare_distribution || die "distribution setup failed; cannot contact aiur"
  resolve_control_identity_from_records
  if [ "${AIUR_CONTROL_ADOPTED_RECORD:-0}" -eq 1 ]; then
    prepare_distribution || die "distribution setup failed; cannot contact aiur"
  fi
  if [ "$(probe_node_liveness)" = "down" ]; then
    print_control_down_message
    return 1
  fi
  if "$release_bin" rpc "$expression"; then
    return 0
  else
    local status=$?
    echo "aiur: streaming control RPC failed with exit ${status}" >&2
    return "$status"
  fi
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

# `aiur usage` — Codex/Claude limit headroom from the daemon's meter
# projection, each value carrying the age of its observation.
cmd_usage() {
  [ "$#" -eq 0 ] || die "usage does not accept arguments"
  run_control_rpc "Aiur.AgentControlCLI.usage()"
}

cmd_pause_resume() {
  local command="$1"
  shift

  # Bare `aiur pause` / `aiur resume` (no IDs, no --all) flips the single
  # global pause switch: a daemon-wide halt distinct from per-agent pause.
  if [ "$#" -eq 0 ]; then
    run_control_rpc "Aiur.AgentControlCLI.${command}_global()"
    return
  fi

  if ! parse_issue_targets "$@"; then
    echo "aiur: $command expects issue IDs or --all (e.g. aiur $command 44 45,46; aiur $command --all; or bare aiur $command for the global switch)" >&2
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

# `aiur reset-budget <id>...` — clear the lifetime dispatch latch for one or
# more tickets (the supported exit from the #1453 latch; no JSON hand-editing).
cmd_reset_budget() {
  if ! parse_issue_targets "$@"; then
    echo "aiur: reset-budget expects issue IDs (e.g. aiur reset-budget 44 45,46)" >&2
    exit 64
  fi

  # --all is rejected (exit 64 with guidance) rather than silently no-opping:
  # clearing every ticket's latch at once is not a documented operation and
  # would mask which tickets are structurally stuck (#1453 review P2d).
  if [ "$parsed_all" -eq 1 ]; then
    echo "aiur: reset-budget does not accept --all; name ticket IDs explicitly (e.g. aiur reset-budget 44 45,46)" >&2
    exit 64
  fi

  local expression
  expression="Aiur.AgentControlCLI.reset_budget($(elixir_list_literal "${parsed_targets[@]}"))"
  run_control_rpc "$expression"
}

# `aiur message <issue> <text>` — deliver Executor text to one running agent.
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

# `aiur commands` — read the dashboard's retained Decision projection without
# exposing any dispatch or answer mutation path.
cmd_commands() {
  local filter="all" blocking=0 json=0 decision_id="" ticket="" search="" cursor="" limit="" arg

  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --filter) [ "$#" -gt 1 ] || { echo "aiur: commands --filter requires a value" >&2; exit 64; }; shift; filter="$1" ;;
      --filter=*) filter="${arg#--filter=}" ;;
      --blocking) blocking=1 ;;
      --ticket) [ "$#" -gt 1 ] || { echo "aiur: commands --ticket requires a value" >&2; exit 64; }; shift; ticket="$1" ;;
      --ticket=*) ticket="${arg#--ticket=}" ;;
      --search) [ "$#" -gt 1 ] || { echo "aiur: commands --search requires a value" >&2; exit 64; }; shift; search="$1" ;;
      --search=*) search="${arg#--search=}" ;;
      --cursor) [ "$#" -gt 1 ] || { echo "aiur: commands --cursor requires a value" >&2; exit 64; }; shift; cursor="$1" ;;
      --cursor=*) cursor="${arg#--cursor=}" ;;
      --limit) [ "$#" -gt 1 ] || { echo "aiur: commands --limit requires a value" >&2; exit 64; }; shift; limit="$1" ;;
      --limit=*) limit="${arg#--limit=}" ;;
      --json) json=1 ;;
      -*) echo "aiur: commands received an unknown option: $arg" >&2; exit 64 ;;
      *)
        if [ -n "$decision_id" ]; then
          echo "aiur: commands accepts at most one decision ID" >&2
          exit 64
        fi
        decision_id="$arg"
        ;;
    esac
    shift
  done

  case "$filter" in all|open|blocking|resolved) ;; *) echo "aiur: commands --filter accepts all, open, blocking, or resolved" >&2; exit 64 ;; esac
  [ -z "$limit" ] || [[ "$limit" =~ ^[1-9][0-9]*$ ]] || { echo "aiur: commands --limit expects a positive integer" >&2; exit 64; }
  [ -z "$ticket" ] || [ "$filter" = "all" ] || { echo "aiur: commands --ticket requires --filter all" >&2; exit 64; }
  [ -z "$search" ] || [ "$filter" = "all" ] || { echo "aiur: commands --search requires --filter all" >&2; exit 64; }

  local opts="filter: :$filter"
  [ "$blocking" -eq 1 ] && opts="$opts, blocking: true"
  [ "$json" -eq 1 ] && opts="$opts, json: true"
  [ -n "$limit" ] && opts="$opts, limit: $limit"
  local key raw encoded
  for key in decision_id ticket search cursor; do
    raw="${!key}"
    [ -n "$raw" ] || continue
    encoded="$(printf '%s' "$raw" | base64 | tr -d '\n')"
    opts="$opts, $key: Base.decode64!(\"$encoded\")"
  done

  run_control_rpc "Aiur.AgentControlCLI.commands([$opts])"
}

# `aiur analytics` — render the dashboard analytics projection for an explicit
# time window. This is read-only and obtains the same durable telemetry snapshot
# the page uses through the running node.
cmd_analytics() {
  local range="run" json=0 since="" until="" build_order="" has_build_order=0 arg

  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --range) [ "$#" -gt 1 ] || { echo "aiur: analytics --range requires a value" >&2; exit 64; }; shift; range="$1" ;;
      --range=*) range="${arg#--range=}" ;;
      --since) [ "$#" -gt 1 ] || { echo "aiur: analytics --since requires a value" >&2; exit 64; }; shift; since="$1" ;;
      --since=*) since="${arg#--since=}" ;;
      --until) [ "$#" -gt 1 ] || { echo "aiur: analytics --until requires a value" >&2; exit 64; }; shift; until="$1" ;;
      --until=*) until="${arg#--until=}" ;;
      --build-order) [ "$#" -gt 1 ] || { echo "aiur: analytics --build-order requires a value" >&2; exit 64; }; shift; build_order="$1"; has_build_order=1 ;;
      --build-order=*) build_order="${arg#--build-order=}"; has_build_order=1 ;;
      --json) json=1 ;;
      -*) echo "aiur: analytics received an unknown option: $arg" >&2; exit 64 ;;
      *) echo "aiur: analytics does not accept positional arguments" >&2; exit 64 ;;
    esac
    shift
  done

  case "$range" in run|full) ;; *) echo "aiur: analytics --range accepts run or full" >&2; exit 64 ;; esac
  [ "$has_build_order" -eq 0 ] || [[ "$build_order" =~ ^[0-9]+$ ]] || { echo "aiur: analytics --build-order expects a numeric ticket ID" >&2; exit 64; }

  local opts="range: :$range" key raw encoded
  [ "$json" -eq 1 ] && opts="$opts, json: true"
  for key in since until build_order; do
    raw="${!key}"
    [ -n "$raw" ] || continue
    encoded="$(printf '%s' "$raw" | base64 | tr -d '\n')"
    opts="$opts, $key: Base.decode64!(\"$encoded\")"
  done

  run_control_rpc "Aiur.AgentControlCLI.analytics([$opts])"
}

# `aiur alerts` — newline-delimited structured alert feed from persisted
# per-agent logs. `--needs-attention` filters to Executor-actionable alerts.
cmd_alerts() {
  local needs_attention=0 arg
  for arg in "$@"; do
    case "$arg" in
      --needs-attention) needs_attention=1 ;;
      *)
        echo "aiur: alerts only accepts --needs-attention" >&2
        exit 64
        ;;
    esac
  done

  if [ "$needs_attention" -eq 1 ]; then
    run_control_rpc "Aiur.AgentControlCLI.alerts(needs_attention: true)"
  else
    run_control_rpc "Aiur.AgentControlCLI.alerts()"
  fi
}

# `aiur watch` — the server-side status board. Compiles one row per active
# agent (state · complexity · activity-age · doing) plus an actionable section
# from aiur's own state, with no GitHub round-trip. `--changes` (default) prints
# only state-level deltas since the last call; `--full` prints every row;
# `--interval N` re-renders every N seconds as a foreground watcher (the Elixir
# call stays one-shot — the loop lives here).
cmd_watch() {
  local mode="changes" interval="" arg

  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --full) mode="full" ;;
      --changes) mode="changes" ;;
      --once) : ;;
      --interval)
        shift
        interval="${1:-}"
        watch_validate_interval "$interval"
        ;;
      --interval=*)
        interval="${arg#--interval=}"
        watch_validate_interval "$interval"
        ;;
      *)
        echo "aiur: watch accepts --full, --changes, --once, --interval <secs>" >&2
        exit 64
        ;;
    esac
    shift
  done

  local expression="Aiur.AgentControlCLI.watch(mode: :${mode})"

  if [ -n "$interval" ]; then
    while true; do
      run_control_rpc "$expression" || true
      sleep "$interval"
    done
  else
    run_control_rpc "$expression"
  fi
}

cmd_executor_listen() {
  local topic="executor.#" arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --topic) shift; topic="${1:-}" ;;
      --topic=*) topic="${arg#--topic=}" ;;
      *) echo "aiur: executor-listen accepts --topic <pattern>" >&2; exit 64 ;;
    esac
    [ -n "$topic" ] || { echo "aiur: executor-listen requires a topic" >&2; exit 64; }
    shift
  done
  local encoded
  encoded="$(printf '%s' "$topic" | base64 | tr -d '\n')"
  run_control_stream "Aiur.AgentControlCLI.executor_listen(topic: Base.decode64!(\"$encoded\"))"
}

cmd_executor_emit() {
  local topic="${1:-}" payload="" arg
  shift 2>/dev/null || true
  [ -n "$topic" ] || { echo "aiur: executor-emit requires a topic" >&2; exit 64; }
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --payload) shift; payload="${1:-}" ;;
      --payload=*) payload="${arg#--payload=}" ;;
      *) echo "aiur: executor-emit accepts only --payload <json>" >&2; exit 64 ;;
    esac
    shift
  done
  [ -n "$payload" ] || { echo "aiur: executor-emit requires --payload <json>" >&2; exit 64; }
  local topic_encoded payload_encoded
  topic_encoded="$(printf '%s' "$topic" | base64 | tr -d '\n')"
  payload_encoded="$(printf '%s' "$payload" | base64 | tr -d '\n')"
  run_control_rpc "Aiur.AgentControlCLI.executor_emit(Base.decode64!(\"$topic_encoded\"), Base.decode64!(\"$payload_encoded\"))"
}

cmd_executor_subscription() {
  local action="$1" topic="${2:-}"
  [ -n "$topic" ] && [ "$#" -eq 2 ] || { echo "aiur: $action requires one topic pattern" >&2; exit 64; }
  local encoded
  encoded="$(printf '%s' "$topic" | base64 | tr -d '\n')"
  case "$action" in
    executor-subscribe) run_control_rpc "Aiur.AgentControlCLI.executor_subscribe(Base.decode64!(\"$encoded\"))" ;;
    executor-unsubscribe) run_control_rpc "Aiur.AgentControlCLI.executor_unsubscribe(Base.decode64!(\"$encoded\"))" ;;
  esac
}

cmd_executor_subscriptions() {
  [ "$#" -eq 0 ] || { echo "aiur: executor-subscriptions does not accept arguments" >&2; exit 64; }
  run_control_rpc "Aiur.AgentControlCLI.executor_subscriptions()"
}

watch_validate_interval() {
  if ! [[ "$1" =~ ^[0-9]+$ ]] || [ "$1" -le 0 ]; then
    echo "aiur: watch --interval expects a positive integer (seconds)" >&2
    exit 64
  fi
}

cmd_cleanup_stale() {
  local dry_run=0 arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry_run=1 ;;
      *)
        echo "aiur: cleanup-stale only accepts --dry-run" >&2
        exit 64
        ;;
    esac
  done

  aiur_resolve_identity
  if [ "$dry_run" -eq 1 ]; then
    report_stale_manual_smoke || true
  else
    report_stale_manual_smoke || true
    reap_stale_manual_smoke 1
  fi
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
#     and BEAM write to. Arbitrary Executor worktrees/checkouts like
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

# A stop only reaps the daemon whose node name matches this project root's
# instance key (keys are sha256(project_root), so instances can't reap each
# other). A daemon launched from a different directory therefore survives a stop
# invoked elsewhere — the silent orphan that keeps holding the dashboard port and
# serving stale code/credentials. Surface it loudly (we warn, not reap, to
# respect the deliberate isolation) so the operator can stop it explicitly.
warn_other_aiur_daemons() {
  local self_node="$1" me pids pid cmd node port found=0
  me="${USER:-$(id -un 2>/dev/null)}"
  pids="$(pgrep -u "$me" -f -- "-name aiur-${me}" 2>/dev/null || true)"
  for pid in $pids; do
    cmd="$(pid_command "$pid")"
    case "$cmd" in *beam.smp*) : ;; *) continue ;; esac
    node="$(printf '%s' "$cmd" | grep -oE -- '-name [^ ]+' | awk '{print $2}' | head -1)"
    [ -z "$node" ] && continue
    [ "$node" = "$self_node" ] && continue
    port="$(ss -tlnpH 2>/dev/null | awk -v p="pid=$pid," '$0 ~ p {print $4}' \
      | grep -oE '[0-9]+$' | head -1 || true)"
    if [ "$found" -eq 0 ]; then
      echo "aiur: heads up — another aiur daemon is still running that this stop did not touch" >&2
      echo "      (launched from a different directory, so it has a different instance key):" >&2
      found=1
    fi
    echo "      pid=$pid node=$node${port:+ dashboard-port=$port} — stop it with:  kill $pid" >&2
  done
}

# Stop the running session: kill this instance's tmux + BEAM, then sweep.
cmd_stop() {
  resolve_release
  aiur_resolve_identity
  RELEASE_NODE="$AIUR_RELEASE_NODE"
  ERL_EPMD_ADDRESS="${ERL_EPMD_ADDRESS:-127.0.0.1}"
  export RELEASE_NODE ERL_EPMD_ADDRESS
  resolve_control_identity_from_records

  local workspace_root_file
  workspace_root_file="$(workspace_root_file_from_instance_record 2>/dev/null || true)"

  local tmux_bin
  tmux_bin="$(command -v tmux || true)"
  local session="${AIUR_ADOPTED_TMUX_SESSION:-${AIUR_SESSION_PREFIX}-${USER:-user}${AIUR_INSTANCE_KEY:+-$AIUR_INSTANCE_KEY}-default}"
  local socket="${AIUR_ADOPTED_TMUX_SOCKET:-${AIUR_SESSION_PREFIX}-${USER:-user}${AIUR_INSTANCE_KEY:+-$AIUR_INSTANCE_KEY}}"

  local has_session=0
  if [ -n "$tmux_bin" ] && "$tmux_bin" -L "$socket" has-session -t "$session" 2>/dev/null; then
    has_session=1
  fi

  if [ "${AIUR_CONTROL_ADOPTED_RECORD:-0}" -ne 1 ] && \
    [ "${AIUR_CONTROL_CURRENT_NODE_STATE:-}" = "down" ] && \
    [ "${AIUR_PROJECT_ROOT_SOURCE:-}" = "cwd" ] && \
    [ "$has_session" -eq 0 ] && \
    [ ! -f "$(aiur_crash_marker_path)" ]; then
    echo "aiur: no running aiur node at ${AIUR_RELEASE_NODE}; nothing stopped" >&2
    warn_other_aiur_daemons "$AIUR_RELEASE_NODE"
    print_global_config_control_hint
    return 1
  fi

  # Tell the background BEAM-death watchdog this exit is intentional before we
  # kill the BEAM, so it consumes the sentinel instead of recording a crash. The
  # watchdog removes the sentinel when it fires; a fresh start also clears it.
  # Clear any prior crash marker too — `status` should report a clean stop, not
  # a stale orphan from an earlier dead run.
  mkdir -p "$AIUR_BG_STATE_DIR" 2>/dev/null || true
  : >"$(aiur_stop_sentinel_path)" 2>/dev/null || true
  rm -f "$(aiur_crash_marker_path)" 2>/dev/null || true

  if [ -n "$tmux_bin" ]; then
    "$tmux_bin" -L "$socket" kill-session -t "$session" 2>/dev/null || true
  fi

  # Reap any BEAM holding our node name regardless of which release dir launched
  # it. Do not sweep by release dir: sibling instances share dev releases.
  kill_beams_matching "-name ${AIUR_RELEASE_NODE}"

  # Final cwd-sweep backstop after the BEAM is dead. The launcher's instance
  # record points to the BEAM-written root handoff, so degraded stop never has
  # to wait for an overloaded daemon before it starts tearing workers down.
  reap_workspace_cwd_from_file "$workspace_root_file"

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

  reap_stale_manual_smoke 0
  sweep_dead_tmux_sockets
  sweep_stale_tmp_artifacts
  rm -f "$(aiur_instance_record_path)" 2>/dev/null || true
  warn_other_aiur_daemons "$AIUR_RELEASE_NODE"
}

# --- dispatch ----------------------------------------------------------------

dispatch_run() {
  local mode="foreground" arg
  local args=()

  for arg in "$@"; do
    if [ "$arg" = "--bg" ]; then
      mode="background"
    else
      args+=("$arg")
    fi
  done

  # bash 3.2 (macOS default) errors on "${args[@]}" when args is empty under
  # `set -u` — happens for a bare `--bg` run. Guard the expansion.
  run_session "$mode" "${args[@]+"${args[@]}"}"
}

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
    --todo)
      run_todo "$@"
      ;;
    --only)
      echo "aiur: --only is valid only with --todo" >&2
      exit 64
      ;;
    init)
      run_init "$@"
      ;;
    findings)
      run_findings "$@"
      ;;
    guard-pr-deletions)
      shift
      "$engine_dir/guard-pr-deletions.sh" "$@"
      ;;
    ask | asks)
      run_asks "$@"
      ;;
    --bg)
      dispatch_run "$@"
      ;;
    run)
      shift
      dispatch_run "$@"
      ;;
    status)
      shift
      cmd_status "$@"
      ;;
    usage)
      shift
      cmd_usage "$@"
      ;;
    agents)
      shift
      cmd_agents "$@"
      ;;
    commands)
      shift
      cmd_commands "$@"
      ;;
    analytics)
      shift
      cmd_analytics "$@"
      ;;
    alerts)
      shift
      cmd_alerts "$@"
      ;;
    watch)
      shift
      cmd_watch "$@"
      ;;
    executor-listen)
      shift
      cmd_executor_listen "$@"
      ;;
    executor-emit)
      shift
      cmd_executor_emit "$@"
      ;;
    executor-subscribe | executor-unsubscribe)
      shift
      cmd_executor_subscription "$cmd" "$@"
      ;;
    executor-subscriptions)
      shift
      cmd_executor_subscriptions "$@"
      ;;
    set)
      shift
      cmd_set "$@"
      ;;
    pause | resume)
      shift
      cmd_pause_resume "$cmd" "$@"
      ;;
    reset-budget)
      shift
      cmd_reset_budget "$@"
      ;;
    message)
      shift
      cmd_message "$@"
      ;;
    cleanup-stale)
      shift
      cmd_cleanup_stale "$@"
      ;;
    stop)
      cmd_stop
      ;;
    "")
      dispatch_run
      ;;
    -*)
      # leading-flag forms (e.g. `aiur --interactive <config>`) are a run
      dispatch_run "$@"
      ;;
    *)
      # a path/config argument is a run; anything else is a usage error
      if [ -e "$cmd" ]; then
        dispatch_run "$@"
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
