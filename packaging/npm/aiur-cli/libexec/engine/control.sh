# Control identity resolution and the control RPC runner and dispatch. Sourced by aiur-engine.sh.

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

confirm_stale_tmux_session() {
  local tmux_bin="$1" socket="$2" conf="$3" session="$4"
  local max_ticks="${AIUR_STALE_SESSION_GRACE_TICKS:-30}" tick

  for ((tick = 0; tick < max_ticks; tick++)); do
    "$tmux_bin" -L "$socket" -f "$conf" has-session -t "$session" 2>/dev/null || return 0
    [ "$(probe_control_liveness)" = "up" ] && return 1
    [ "$(probe_node_liveness)" = "down" ] || return 1
    sleep 0.1
  done

  "$tmux_bin" -L "$socket" -f "$conf" has-session -t "$session" 2>/dev/null || return 0
  [ "$(probe_control_liveness)" != "up" ] && [ "$(probe_node_liveness)" = "down" ]
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
  AIUR_RECORD_AGENT_TMPFILE=""
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

# Signalling the watchdog subshell alone leaves its `sleep` child running and
# orphaned: bash forks the subshell, and the sleep is a separate process the
# subshell's death does not reap. Kill the descendants too so a fast reply
# leaves nothing behind that outlives the command.
# Deepest-first: a bash subshell that is TERMed while waiting on a foreground
# child defers the signal until that child exits, so signalling the wrapper
# before the sleep it is waiting on can leave the sleep running.
cancel_timeout_watchdog() {
  local pid="$1" p tree=() i
  [ -n "$pid" ] || return 0
  while IFS= read -r p; do tree+=("$p"); done < <(agent_pid_tree "$pid")
  for ((i = ${#tree[@]} - 1; i >= 0; i--)); do kill -TERM "${tree[i]}" 2>/dev/null || true; done
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

  # The watchdog must not hold the caller's stdout/stderr. A caller that captures
  # our output (command substitution, a pipe, a language runtime's subprocess
  # capture) reads until EOF, and EOF arrives only when every process holding the
  # write end exits - including a watchdog that is merely sleeping. Closing those
  # descriptors here is what keeps the timeout a ceiling instead of a floor.
  (
    sleep "$timeout"
    if kill -0 "$pid" 2>/dev/null; then
      : >"$timeout_file"
      kill_control_rpc_process "$pid" "$grouped"
    fi
  ) >/dev/null 2>&1 &
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
    cancel_timeout_watchdog "$watchdog_pid"
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

control_command_label() {
  printf '%s' "${AIUR_CONTROL_COMMAND:-control rpc}"
}

control_attempt_sentence() {
  [ -n "${AIUR_CONTROL_ATTEMPT_CONTEXT:-}" ] || return 0
  printf ' Attempted %s against daemon endpoint %s.' "$AIUR_CONTROL_ATTEMPT_CONTEXT" "${RELEASE_NODE:-unknown}"
}

# Every line a control RPC surfaces to the operator routes through one of these
# two helpers, so `run_control_rpc` can prove it never returns non-zero while
# saying nothing (#1684): a silent failure is indistinguishable from a healthy
# idle fleet, and nobody reads exit codes interactively.
control_rpc_say() {
  AIUR_CONTROL_RPC_DIAGNOSED=1
  printf '%s\n' "$1" >&2
}

control_rpc_echo_output() {
  [ -n "$1" ] || return 0
  AIUR_CONTROL_RPC_DIAGNOSED=1
  printf '%s\n' "$1" >&2
}

# RPC an expression into the running node. The control CLI prints a trailing
# `__AIUR_CONTROL_EXIT__:<code>` marker we translate into the process exit code.
#
# Wrapper contract: a non-zero return ALWAYS carries at least one stderr line
# naming the command that failed. EX_TEMPFAIL (75) is exempt — it is the dev
# shim's internal rebuild-and-retry signal, never an operator-visible outcome.
run_control_rpc() {
  local status=0

  AIUR_CONTROL_RPC_DIAGNOSED=0
  run_control_rpc_dispatch "$@" || status=$?

  if [ "$status" -ne 0 ] && [ "$status" -ne 75 ] && [ "${AIUR_CONTROL_RPC_DIAGNOSED:-0}" -ne 1 ]; then
    if [ "$status" -eq 124 ]; then
      control_rpc_say "aiur: $(control_command_label) to ${RELEASE_NODE:-the daemon} timed out after $(control_rpc_timeout_seconds)s; outcome is unknown.$(control_attempt_sentence) The daemon did not reply within the budget - commonly one blocked process inside it, not host load. 'aiur alerts' is answered by a different process and can confirm the daemon is alive."
    elif [ -n "${AIUR_CONTROL_ATTEMPT_CONTEXT:-}" ]; then
      control_rpc_say "aiur: $(control_command_label) failed (exit ${status}) and produced no diagnostic output.$(control_attempt_sentence) Outcome is unknown. 'aiur alerts' is answered by a different process and can confirm the daemon is alive."
    else
      control_rpc_say "aiur: $(control_command_label) failed (exit ${status}) and produced no diagnostic output; outcome is unknown. 'aiur alerts' is answered by a different process and can confirm the daemon is alive."
    fi
  fi

  return "$status"
}

run_control_rpc_dispatch() {
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
    control_rpc_say "aiur: $(control_command_label) to ${RELEASE_NODE} timed out after $(control_rpc_timeout_seconds)s; outcome is unknown${partial_suffix}.$(control_attempt_sentence) Commonly one blocked process inside the daemon, not host load."
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
    #
    # An empty buffer is its own case: `--rpc-eval` kills itself without a word
    # when the evaluated expression exits (a GenServer call timing out against a
    # saturated daemon does exactly that), so "see the error above" would point
    # at nothing (#1684). Name the failure instead.
    case "$(probe_node_liveness)" in
      down)
        print_control_down_message
        AIUR_CONTROL_RPC_DIAGNOSED=1
        ;;
      up)
        control_rpc_echo_output "$output"
        if [ -n "$output" ]; then
          control_rpc_say "aiur: $(control_command_label) failed against ${RELEASE_NODE} (node is running); see the error above"
        elif [ -n "${AIUR_CONTROL_ATTEMPT_CONTEXT:-}" ]; then
          control_rpc_say "aiur: $(control_command_label) failed against ${RELEASE_NODE} with no diagnostic output (node is running).$(control_attempt_sentence) Outcome is unknown. 'aiur alerts' is answered by a different process and can confirm the daemon is alive."
        else
          control_rpc_say "aiur: $(control_command_label) failed against ${RELEASE_NODE} with no diagnostic output (node is running); outcome is unknown. 'aiur alerts' is answered by a different process and can confirm the daemon is alive."
        fi
        ;;
      *)
        control_rpc_echo_output "$output"
        if [ -n "$output" ]; then
          control_rpc_say "aiur: $(control_command_label) failed against ${RELEASE_NODE} (could not query epmd to confirm node state); see the error above"
        elif [ -n "${AIUR_CONTROL_ATTEMPT_CONTEXT:-}" ]; then
          control_rpc_say "aiur: $(control_command_label) failed against ${RELEASE_NODE} with no output (could not query epmd to confirm node state).$(control_attempt_sentence) Outcome is unknown."
        else
          control_rpc_say "aiur: $(control_command_label) failed against ${RELEASE_NODE} with no output (could not query epmd to confirm node state)"
        fi
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
        AIUR_CONTROL_RPC_DIAGNOSED=1
        printf '%s\n' "${line#"$error_marker"}" >&2
        ;;
      :ok | "") ;;
      *)
        saw_output=1
        AIUR_CONTROL_RPC_DIAGNOSED=1
        printf '%s\n' "$line"
        ;;
    esac
  done <<<"$output"

  if [ "$saw_marker" -ne 1 ]; then
    if [ -n "${AIUR_CONTROL_ATTEMPT_CONTEXT:-}" ]; then
      control_rpc_say "aiur: $(control_command_label) to ${RELEASE_NODE} returned no exit marker; command output may be incomplete.$(control_attempt_sentence)"
    else
      control_rpc_say "aiur: $(control_command_label) to ${RELEASE_NODE} returned no exit marker; command output may be incomplete"
    fi
    return 1
  fi

  if [ "$exit_code" -ne 0 ] && [ "$saw_error" -ne 1 ] && [ "$saw_output" -ne 1 ]; then
    if [ -n "${AIUR_CONTROL_ATTEMPT_CONTEXT:-}" ]; then
      control_rpc_say "aiur: $(control_command_label) failed with exit ${exit_code} and produced no diagnostic output.$(control_attempt_sentence) Outcome is unknown."
    else
      control_rpc_say "aiur: $(control_command_label) failed with exit ${exit_code} and returned no diagnostic output"
    fi
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
