# Read-only capability report through the daemon's local control RPC.
cmd_capabilities() {
  local opts="" arg
  for arg in "$@"; do
    case "$arg" in
      --json) opts="json: true" ;;
      -*) echo "aiur: capabilities received an unknown option: $arg" >&2; exit 64 ;;
      *) echo "aiur: capabilities does not accept positional arguments" >&2; exit 64 ;;
    esac
  done
  run_control_rpc "Aiur.AgentControlCLI.capabilities([$opts])"
}
