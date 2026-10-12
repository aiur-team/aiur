# Control verbs: status through commands, cleanup-stale and set. Sourced by aiur-engine.sh.

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
  [ ! -f "$engine_dir/aiur-mise-doctor" ] || bash "$engine_dir/aiur-mise-doctor" --check || true
  [ "$#" -eq 0 ] || die "status does not accept arguments"
  run_control_rpc "Aiur.AgentControlCLI.status()"
}

# `aiur usage` — Codex/Claude limit headroom from the daemon's meter
# projection, each value carrying the age of its observation.
cmd_usage() {
  [ "$#" -eq 0 ] || die "usage does not accept arguments"
  run_control_rpc "Aiur.AgentControlCLI.usage()"
}

cmd_accounts() {
  local json_arg=false harness="" arg encoded expression
  for arg in "$@"; do
    case "$arg" in
      --json)
        [ "$json_arg" = false ] || die "accounts accepts --json only once"
        json_arg=true
        ;;
      --all)
        ;;
      -*)
        die "accounts accepts an optional harness and --json"
        ;;
      *)
        [ -z "$harness" ] || die "accounts accepts only one harness"
        harness="$arg"
        ;;
    esac
  done

  resolve_release || return $?
  prepare_distribution || die "distribution setup failed; cannot contact aiur"
  resolve_control_identity_from_records
  if [ "$(probe_node_liveness)" = "down" ]; then
    # The local one-shot CLI renders the identity and marks usage unavailable.
    # It never makes a provider request.
    run_local_cli accounts "$@"
  else
    if [ -n "$harness" ]; then
      encoded="$(printf '%s' "$harness" | base64 | tr -d '\n')"
      expression="Aiur.AgentControlCLI.accounts($json_arg, Base.decode64!(\"$encoded\"))"
    else
      expression="Aiur.AgentControlCLI.accounts($json_arg)"
    fi
    run_control_rpc "$expression"
  fi
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

# Requires the operator to name the exact ticket and generation shown by
# status. The daemon independently verifies the recorded boot proof.
cmd_workspace_recover() {
  [ "$#" -eq 2 ] || { echo "aiur: workspace-recover expects a ticket identifier and generation (e.g. aiur workspace-recover ENG-123 7)" >&2; exit 64; }
  local ticket="$1" generation="$2" encoded
  [[ "$generation" =~ ^[1-9][0-9]*$ ]] || { echo "aiur: workspace-recover generation must be a positive integer" >&2; exit 64; }
  encoded="$(printf '%s' "$ticket" | base64 | tr -d '\n')"
  run_control_rpc "Aiur.AgentControlCLI.recover_workspace(Base.decode64!(\"$encoded\"), $generation)"
}

# `aiur message <issue> <text>` — deliver Executor text to one running agent.
# The text is base64-encoded for the RPC hop so arbitrary content (quotes,
# backslashes, `#{}`, newlines) survives without Elixir-string escaping.
cmd_message() {
  local usage="aiur: message expects an issue ID and text (e.g. aiur message 44 \"ship it\" or aiur message 44 --message-id ID \"ship it\")"
  local message_id="" message_id_given=0

  local issue="${1:-}"
  if [ -z "$issue" ] || [[ ! "$issue" =~ ^[0-9]+$ ]]; then
    echo "$usage" >&2
    exit 64
  fi
  shift

  # `--message-id ID` names this send, so a retry after an unknown outcome
  # returns the first copy instead of queueing a second one (#2717).
  case "${1:-}" in
    --message-id)
      [ "$#" -gt 1 ] || { echo "aiur: message --message-id requires a value" >&2; exit 64; }
      message_id="$2"
      message_id_given=1
      shift 2
      ;;
    --message-id=*)
      message_id="${1#--message-id=}"
      message_id_given=1
      shift
      ;;
  esac
  if [ "$message_id_given" = 1 ] && [[ ! "$message_id" =~ ^[A-Za-z0-9._:-]{1,128}$ ]]; then
    echo "aiur: message --message-id must be 1-128 letters, digits, '.', '_', ':' or '-' (it cannot be empty)" >&2
    exit 64
  fi

  local text="$*"
  if [ -z "$text" ]; then
    echo "$usage" >&2
    exit 64
  fi

  local encoded
  encoded="$(printf '%s' "$text" | base64 | tr -d '\n')"
  if [ -n "$message_id" ]; then
    run_control_rpc "Aiur.AgentControlCLI.message(\"$issue\", Base.decode64!(\"$encoded\"), \"$message_id\")"
  else
    run_control_rpc "Aiur.AgentControlCLI.message(\"$issue\", Base.decode64!(\"$encoded\"))"
  fi
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
