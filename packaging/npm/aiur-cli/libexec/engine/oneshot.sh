# One-shot commands: version, init, local CLI, logins, --todo, findings and asks. Sourced by aiur-engine.sh.

run_version() {
  resolve_release
  AIUR_CLI_VERSION="$(cli_package_version || true)"
  export AIUR_CLI_VERSION
  # Distribution-free (like init): printing the version is a compile-time
  # constant, so never claim the node name — otherwise `aiur --version` fails
  # whenever an aiur session is already running.
  build_init_cmd
  init_argv_file
  write_argv "$@"
  export AIUR_ARGV_FILE="$argv_file"
  exec "${release_cmd[@]}"
}


run_init() {
  resolve_release
  build_init_cmd
  init_argv_file
  write_argv "$@"
  export AIUR_ARGV_FILE="$argv_file"
  exec "${release_cmd[@]}"
}

run_local_cli() {
  resolve_release
  build_init_cmd
  init_argv_file
  write_argv "$@"
  export AIUR_ARGV_FILE="$argv_file"
  exec "${release_cmd[@]}"
}

run_claude_login() {
  resolve_release
  local profile_dir
  build_init_cmd
  init_argv_file
  write_argv "__login_prepare" "${@:2}"
  export AIUR_ARGV_FILE="$argv_file"
  profile_dir="$("${release_cmd[@]}")" || return $?
  [ -n "$profile_dir" ] || { echo "aiur: account profile directory is unavailable" >&2; return 1; }
  local login_action="${profile_dir##*$'\n'}"
  profile_dir="${profile_dir%$'\n'*}"
  if [ "$login_action" = "registered" ]; then
    printf 'registered claude:%s (signed in)\n' "${2:-default}"
    return 0
  fi
  if [ ! -t 0 ]; then
    echo "aiur: profile is not signed in; run 'aiur login claude ${2:-default}' in an interactive terminal" >&2
    return 1
  fi
  exec env "CLAUDE_CONFIG_DIR=$profile_dir" claude
}

run_account_login() {
  local harness="$2"
  case "$harness" in
    kimi|deepseek|openrouter) run_local_cli "$@"; return $? ;;
  esac
  resolve_release
  local profile_dir
  build_init_cmd
  init_argv_file
  write_argv "__login_prepare" "$harness" "${@:3}"
  export AIUR_ARGV_FILE="$argv_file"
  profile_dir="$("${release_cmd[@]}")" || return $?
  [ -n "$profile_dir" ] || { echo "aiur: account profile directory is unavailable" >&2; return 1; }
  local login_action="${profile_dir##*$'\n'}"
  profile_dir="${profile_dir%$'\n'*}"
  if [ "$login_action" = "registered" ]; then
    printf 'registered %s:%s (signed in)\n' "$harness" "${3:-default}"
    return 0
  fi
  if [ ! -t 0 ]; then
    echo "aiur: profile is not signed in; run 'aiur login $harness ${3:-default}' in an interactive terminal" >&2
    return 1
  fi
  case "$harness" in
    claude) exec env "CLAUDE_CONFIG_DIR=$profile_dir" claude ;;
    codex) exec env "CODEX_HOME=$profile_dir" codex ;;
    *) echo "aiur: unsupported account harness: $harness" >&2; return 64 ;;
  esac
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

# `--todo` is the one control command whose runtime scales with its arguments
# rather than with daemon state: every requested ID is a GitHub issue fetch, and
# `--only` adds an active-ticket enumeration plus up to 50 serial label DELETEs.
# On a repo with a deep `agent:todo` queue that is minutes of network work, and
# the shared 10s budget killed it every time — labels half-applied, outcome
# reported as unknown, `--only` scoping unusable (#2519). Size the watchdog to
# the work instead. An explicit operator override still wins outright.
todo_rpc_seconds_base=15
todo_rpc_seconds_per_id=3
todo_rpc_seconds_only=90
# The daemon is handed a budget this many seconds shorter than the watchdog, so
# it always stops itself and prints its summary and exit marker before the
# watchdog can discard them.
todo_rpc_grace_seconds=10

todo_rpc_seconds() {
  local id_count="$1" only="$2" seconds

  # Only a usable override wins. Everywhere else an unset, zero, or malformed
  # value falls back to the shared 10s default; here that default is the bug, so
  # fall back to work-proportional sizing instead.
  if [[ "${AIUR_CONTROL_RPC_TIMEOUT_SECONDS:-}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$AIUR_CONTROL_RPC_TIMEOUT_SECONDS"
    return 0
  fi

  seconds=$((todo_rpc_seconds_base + todo_rpc_seconds_per_id * id_count))
  [ "$only" -eq 1 ] && seconds=$((seconds + todo_rpc_seconds_only))
  printf '%s' "$seconds"
}

# Never hand the daemon a non-positive budget: an operator who sets the override
# below the grace window should still get a bounded run rather than an unlimited
# one.
todo_daemon_budget_ms() {
  local seconds=$(($1 - todo_rpc_grace_seconds))
  [ "$seconds" -ge 1 ] || seconds=1
  printf '%s' $((seconds * 1000))
}

run_todo() {
  if ! parse_todo_args "$@"; then
    echo "aiur: --todo expects one or more numeric issue IDs, optionally followed by --only" >&2
    exit 64
  fi

  local only_arg="false"
  [ "$parsed_todo_only" -eq 1 ] && only_arg="true"

  local seconds budget_ms
  seconds="$(todo_rpc_seconds "${#parsed_targets[@]}" "$parsed_todo_only")"
  budget_ms="$(todo_daemon_budget_ms "$seconds")"

  AIUR_CONTROL_RPC_TIMEOUT_SECONDS="$seconds" \
    run_control_rpc "Aiur.AgentControlCLI.todo($(elixir_list_literal "${parsed_targets[@]}"), only: $only_arg, budget_ms: $budget_ms, emit_exit_marker: true)"
}

# --- one-shot: findings (distribution-free, no daemon/tmux) -------------------

run_findings() {
  run_init "$@"
}

# --- one-shot: ask / asks (distribution-free, no daemon/tmux) ----------------

run_asks() {
  run_init "$@"
}

# Ask writes now use the daemon; legacy history stays distribution-free.
run_ask() {
  local arg path body instance_key="${AIUR_INSTANCE_KEY:-default}" executor_id
  local argv=() encoded="" legacy=0 list=0
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --list) list=1; continue ;;
      --done)
        case "${1:-}" in ask_*) legacy=1 ;; esac
        argv+=("$arg")
        if [ "$#" -gt 0 ]; then argv+=("$1"); shift; fi
        continue ;;
      --done=ask_*) legacy=1; argv+=("$arg"); continue ;;
      --body|--note|--urgency)
        argv+=("$arg")
        if [ "$#" -gt 0 ]; then argv+=("$1"); shift; fi
        continue ;;
      --body-file|--body-file=*)
        if [ "$arg" = --body-file ]; then
          [ "$#" -gt 0 ] || { echo 'aiur ask: --body-file requires a path' >&2; return 64; }
          path="$1"; shift
        else
          path="${arg#*=}"
        fi
        [ -f "$path" ] && [ -r "$path" ] || { echo 'aiur ask: cannot read --body-file' >&2; return 64; }
        body="$(cat -- "$path" && printf '.')" || { echo 'aiur ask: cannot read --body-file' >&2; return 64; }
        body="${body%.}"
        argv+=(--body "$body") ;;
      *) argv+=("$arg") ;;
    esac
  done
  if [ "$list" -eq 1 ]; then run_asks asks "${argv[@]}"; return $?; fi
  if [ "$legacy" -eq 1 ]; then run_asks ask "${argv[@]}"; return $?; fi
  executor_id="${AIUR_EXECUTOR_ID:-$(hostname)-${instance_key:0:12}}"
  for arg in ask "${argv[@]}"; do
    encoded="${encoded}${encoded:+, }Base.decode64!(\"$(encode_control_value "$arg")\")"
  done
  run_control_rpc "Aiur.AsksCLI.rpc([$encoded], Base.decode64!(\"$(encode_control_value "$executor_id")\"))"
}
