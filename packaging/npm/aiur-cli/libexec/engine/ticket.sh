# Durable estimate overrides; every unchecked string crosses RPC as base64.
cmd_ticket() {
  case "${1:-}" in
    owner|assign) cmd_ticket_ownership "$@"; return ;;
    reopen) shift; cmd_ticket_reopen "$@"; return ;;
    estimate) ;;
    *) echo 'aiur: unknown ticket subcommand (expected estimate, reopen, owner or assign)' >&2; exit 64 ;;
  esac
  shift
  local id="${1:-}" hours="" reason="" by="cli:${USER:-unknown}" clear=0 json=0 arg opts
  [[ "$id" =~ ^[0-9]+$ ]] && [[ "$id" =~ [1-9] ]] || { echo 'aiur: ticket estimate expects a positive numeric id' >&2; exit 64; }
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --reason)
        [ "$#" -gt 1 ] || { echo "aiur: --reason requires a value" >&2; exit 64; }
        shift; reason="$1" ;;
      --by)
        [ "$#" -gt 1 ] || { echo "aiur: --by requires a value" >&2; exit 64; }
        shift; by="$1" ;;
      --clear) clear=1 ;;
      --json) json=1 ;;
      -*) echo "aiur: unknown ticket estimate option: $arg" >&2; exit 64 ;;
      *) [ -z "$hours" ] || { echo 'aiur: ticket estimate accepts one hours value' >&2; exit 64; }; hours="$arg" ;;
    esac
    shift
  done
  [[ "$by" =~ ^[A-Za-z0-9._:@-]{1,64}$ ]] || { echo 'aiur: invalid --by actor' >&2; exit 64; }
  if [ -n "$hours" ]; then
    [[ "$hours" =~ ^[0-9]{1,3}(\.(0|00|25|5|50|75))?$ ]] && awk -v hours="$hours" 'BEGIN {exit !(hours > 0 && hours <= 999)}' || {
      echo 'aiur: hours must be a multiple of 0.25 from 0.25 to 999' >&2; exit 64;
    }
    [ "$clear" -eq 0 ] || { echo 'aiur: --clear cannot be combined with hours' >&2; exit 64; }
  fi
  if [ -n "$hours" ] || [ "$clear" -eq 1 ]; then
    [[ "$reason" =~ [^[:space:]] ]] && ! [[ "$reason" =~ [[:cntrl:]] ]] && [ "${#reason}" -le 500 ] || {
      echo 'aiur: --reason requires 1..500 characters without controls' >&2; exit 64;
    }
  elif [ -n "$reason" ]; then
    echo 'aiur: --reason requires hours or --clear' >&2; exit 64
  fi
  # Decimal id is normalized so leading zeros cannot create an invalid Elixir literal.
  id="$(printf '%s' "$id" | sed 's/^0*//')"
  opts="id: $id"
  [ -z "$hours" ] || opts="$opts, hours: \"$hours\""
  [ "$clear" -eq 0 ] || opts="$opts, clear: true"
  if [ -n "$hours" ] || [ "$clear" -eq 1 ]; then
    opts="$opts, reason: Base.decode64!(\"$(encode_control_value "$reason")\"), by: Base.decode64!(\"$(encode_control_value "$by")\")"
  fi
  [ "$json" -eq 0 ] || opts="$opts, json: true"
  run_control_rpc "Aiur.AgentControlCLI.ticket_estimate([$opts])"
}

# `owner <n> [--json]` and `assign <n> --to <gateway> --reason <text> [--force] [--as <id>] [--json]`.
# --force is local and human only: it never crosses --gateway/--instance and never pairs with --as.
cmd_ticket_ownership() {
  local sub="$1" id="${2:-}" to="" reason="" as="" force=0 json=0 arg opts
  [[ "$id" =~ ^(pr-)?[1-9][0-9]{0,9}$ ]] || { echo "aiur: ticket $sub expects a positive numeric id or pr-<n>" >&2; exit 64; }
  shift 2
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=1 ;;
      --force) [ "$sub" = assign ] || { echo "aiur: unknown ticket owner option: $arg" >&2; exit 64; }; force=1 ;;
      --to|--reason|--as)
        [ "$sub" = assign ] || { echo "aiur: unknown ticket owner option: $arg" >&2; exit 64; }
        [ "$#" -gt 1 ] || { echo "aiur: $arg requires a value" >&2; exit 64; }
        shift
        case "$arg" in --to) to="$1" ;; --reason) reason="$1" ;; --as) as="$1" ;; esac ;;
      *) echo "aiur: unknown ticket $sub option: $arg" >&2; exit 64 ;;
    esac
    shift
  done
  opts="ticket: \"$id\""
  [ "$json" -eq 0 ] || opts="$opts, json: true"
  if [ "$sub" = assign ]; then
    if [ "$force" -eq 1 ] && { [ -n "${AIUR_REMOTE_INSTANCE:-}" ] || [ -n "$as" ]; }; then
      echo 'aiur: --force is local and human only' >&2; exit 64
    fi
    [ -n "$to" ] || { echo 'aiur: ticket assign requires --to <gateway>' >&2; exit 64; }
    [[ "$reason" =~ [^[:space:]] ]] && ! [[ "$reason" =~ [[:cntrl:]] ]] && [ "${#reason}" -le 500 ] || {
      echo 'aiur: --reason requires 1..500 characters without controls' >&2; exit 64;
    }
    [ -z "$as" ] || [[ "$as" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo 'aiur: invalid --as executor id' >&2; exit 64; }
    # A remote caller is never a human: the daemon may not take the actor from the caller.
    [ -z "${AIUR_REMOTE_INSTANCE:-}" ] || [ -n "$as" ] || as=remote
    opts="$opts, to: Base.decode64!(\"$(encode_control_value "$to")\"), reason: Base.decode64!(\"$(encode_control_value "$reason")\")"
    [ -z "$as" ] || opts="$opts, as: \"$as\""
    [ "$force" -eq 0 ] || opts="$opts, force: true"
  fi
  run_control_rpc "Aiur.AgentControlCLI.ticket_$sub([$opts])"
}

# `ownership migrate --map <prefix>=<gateway> [--map ...] [--apply] [--json]`. Dry run unless --apply.
cmd_ownership() {
  [ "${1:-}" = migrate ] || { echo 'aiur: unknown ownership subcommand (expected migrate)' >&2; exit 64; }
  shift
  local maps="" apply=0 json=0 opts
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      --apply) apply=1 ;;
      --map)
        [ "$#" -gt 1 ] || { echo 'aiur: --map requires a value' >&2; exit 64; }
        shift
        maps="$maps${maps:+, }Base.decode64!(\"$(encode_control_value "$1")\")" ;;
      *) echo "aiur: unknown ownership migrate option: $1" >&2; exit 64 ;;
    esac
    shift
  done
  [ -n "$maps" ] || { echo 'aiur: ownership migrate requires --map <prefix>=<gateway>' >&2; exit 64; }
  opts="maps: [$maps]"
  [ "$apply" -eq 0 ] || opts="$opts, apply: true"
  [ "$json" -eq 0 ] || opts="$opts, json: true"
  run_control_rpc "Aiur.AgentControlCLI.ownership_migrate([$opts])"
}

# `reopen <n> --reason <text> [--state todo|rework] [--json]`: reopen a closed ticket and restore its links.
cmd_ticket_reopen() {
  local usage='usage: aiur ticket reopen <id> --reason <text> [--state todo|rework] [--json]'
  local id="${1:-}" reason="" state=todo json=0 by="cli:${USER:-unknown}" opts
  [[ "$id" =~ ^[1-9][0-9]{0,9}$ ]] || { echo 'aiur: ticket reopen expects a positive numeric id' >&2; echo "$usage" >&2; exit 64; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      --reason)
        [ "$#" -gt 1 ] || { echo 'aiur: --reason requires a value' >&2; exit 64; }
        reason="$2"; shift ;;
      --state)
        [ "$#" -gt 1 ] || { echo 'aiur: --state requires a value' >&2; exit 64; }
        state="$2"; shift ;;
      *) echo "aiur: unknown ticket reopen option: $1" >&2; exit 64 ;;
    esac
    shift
  done
  [[ "$reason" =~ [^[:space:]] ]] && ! [[ "$reason" =~ [[:cntrl:]] ]] && [ "${#reason}" -le 500 ] || {
    echo 'aiur: ticket reopen requires --reason with 1..500 characters without controls' >&2; echo "$usage" >&2; exit 64;
  }
  case "$state" in todo|rework) ;; *) echo 'aiur: --state must be todo or rework' >&2; exit 64 ;; esac
  opts="id: $id, state: \"$state\", reason: Base.decode64!(\"$(encode_control_value "$reason")\"), by: Base.decode64!(\"$(encode_control_value "$by")\")"
  [ "$json" -eq 0 ] || opts="$opts, json: true"
  run_control_rpc "Aiur.AgentControlCLI.ticket_reopen([$opts])"
}

# `rework <n> --reason <text>`: move a ticket back to agent:rework, keep its PR as is, give the worker a turn.
cmd_rework() {
  local usage='usage: aiur rework <id> --reason <text> [--key <key>]'
  local id="${1:-}" reason="" key=""
  [[ "$id" =~ ^[1-9][0-9]{0,9}$ ]] || { echo 'aiur: rework expects a positive numeric id' >&2; echo "$usage" >&2; exit 64; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason)
        [ "$#" -gt 1 ] || { echo 'aiur: --reason requires a value' >&2; exit 64; }
        reason="$2"; shift ;;
      --key)
        [ "$#" -gt 1 ] && [[ "$2" =~ ^[A-Za-z0-9._:-]{1,128}$ ]] || { echo 'aiur: --key requires 1..128 characters from A-Z a-z 0-9 . _ : -' >&2; exit 64; }
        key="$2"; shift ;;
      *) echo "aiur: unknown rework option: $1" >&2; echo "$usage" >&2; exit 64 ;;
    esac
    shift
  done
  [[ "$reason" =~ [^[:space:]] ]] && [ "${#reason}" -le 4000 ] || {
    echo 'aiur: rework requires --reason with 1..4000 characters' >&2; echo "$usage" >&2; exit 64;
  }
  # The reason may hold quotes and newlines, so it crosses the RPC as base64.
  export AIUR_CONTROL_RPC_TIMEOUT_SECONDS=70
  # `--key` makes a retry return the first receipt instead of running again.
  if [ -n "$key" ]; then
    run_control_rpc "Aiur.AgentControlCLI.rework(\"$id\", Base.decode64!(\"$(encode_control_value "$reason")\"), key: \"$key\")"
  else
    run_control_rpc "Aiur.AgentControlCLI.rework(\"$id\", Base.decode64!(\"$(encode_control_value "$reason")\"))"
  fi
}
