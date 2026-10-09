# Read-only queue command, shared by the installed CLI and aiurdev.
cmd_queue() {
  if [ "${1:-}" != show ]; then
    echo 'aiur: queue expects show [--queue NAME] [--json]' >&2
    exit 64
  fi
  shift
  local json=0 queue="" opts="" encoded
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      --queue)
        if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == -* ]]; then
          echo 'aiur: queue show --queue requires a name' >&2
          exit 64
        fi
        queue="$2"
        shift
        ;;
      *) echo "aiur: queue show received an unknown argument: $1" >&2; exit 64 ;;
    esac
    shift
  done
  [ "$json" -eq 1 ] && opts="json: true"
  if [ -n "$queue" ]; then
    encoded="$(printf '%s' "$queue" | base64 | tr -d '\n')"
    [ -n "$opts" ] && opts="$opts, "
    opts="${opts}queue: Base.decode64!(\"$encoded\")"
  fi
  run_control_rpc "Aiur.AgentControlCLI.queue([$opts])"
}
