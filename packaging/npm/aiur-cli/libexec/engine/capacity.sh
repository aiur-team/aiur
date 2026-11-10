# The capacity namespace. `report` reads capacity samples and dispatch points from the running daemon's logs.
# @cli-reference aiur capacity report --since <date> [--json] | Report the capacity policy's validation metrics since a date, each with its population and unknown count, split by the agent.priority in force. | aiur capacity report --since 2026-11-01
cmd_capacity() {
  local sub="${1:-}" since="" json=false
  [ "$sub" = report ] || die "usage: aiur capacity report --since <date> [--json]"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --since) [ $# -ge 2 ] && [ -z "$since" ] || die "capacity report takes one --since <date>"; since="$2"; shift 2 ;;
      --json) [ "$json" = false ] || die "capacity report accepts --json only once"; json=true; shift ;;
      *) die "usage: aiur capacity report --since <date> [--json]" ;;
    esac
  done
  [ -n "$since" ] || die "capacity report needs --since <date>"
  run_control_rpc "Aiur.Capacity.ReportCLI.rpc(Base.decode64!(\"$(encode_control_value "$since")\"), $json)"
}
