# `aiur ticket-usage <ticket> [--json]` — one ticket's model usage per session,
# model and provider, read through the daemon's local control RPC. Sourced by aiur-engine.sh.
cmd_ticket_usage() {
  local ticket="" json=0 arg
  for arg in "$@"; do
    case "$arg" in
      --json) json=1 ;;
      -*) echo "aiur: ticket-usage received an unknown option: $arg" >&2; exit 64 ;;
      *)
        [ -z "$ticket" ] || { echo "aiur: ticket-usage accepts one ticket" >&2; exit 64; }
        ticket="$arg"
        ;;
    esac
  done

  [ -n "$ticket" ] || { echo "aiur: ticket-usage requires a ticket number" >&2; exit 64; }
  # Whitelisted to digits, so the ticket reaches the RPC only as a plain literal.
  [[ "$ticket" =~ ^[1-9][0-9]*$ ]] || { echo "aiur: ticket-usage expects a numeric ticket ID" >&2; exit 64; }

  local opts=""
  [ "$json" -eq 1 ] && opts="json: true"
  run_control_rpc "Aiur.TicketUsageCLI.rpc(\"$ticket\", [$opts])"
}
