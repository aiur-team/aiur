# Durable estimate overrides; every unchecked string crosses RPC as base64.
cmd_ticket() {
  [ "${1:-}" = estimate ] || { echo 'aiur: unknown ticket subcommand (expected estimate)' >&2; exit 64; }
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
