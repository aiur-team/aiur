# All caller text crosses the control RPC as base64, including stdin JSON.
cmd_experiments() {
  local verb="${1:-}" arg value encoded opts="" argv="" separator=""
  if [ "$verb" = report ]; then
    shift
    [ "${1:-}" = submit ] || { echo "aiur: experiments report expects submit <id> --file <file|->" >&2; exit 64; }
    verb=report_submit
  fi
  case "$verb" in list|show|create|metrics|freeze|events|preregister|report_submit|stats|analyze) shift ;; *) echo "aiur: experiments expects list, show, events, metrics, create or freeze" >&2; exit 64 ;; esac
  while [ "$#" -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --file)
        [ "$verb" = preregister ] || [ "$verb" = report_submit ] || { echo "aiur: experiments --file requires preregister or report submit" >&2; exit 64; }
        [ "$#" -gt 0 ] || { echo "aiur: experiments --file requires a file or -" >&2; exit 64; }
        value="$1"; shift
        if [ "$value" = - ]; then value="$(cat)"; else
          value="$(cat -- "$value")" || { echo "aiur: experiments cannot read input file" >&2; exit 1; }
        fi
        arg="--contract-json=$value"
        ;;
      --contract-json*) echo "aiur: experiments use --file to supply JSON" >&2; exit 64 ;;
      --from)
        [ "$#" -gt 0 ] || { echo "aiur: experiments --from requires a file or -" >&2; exit 64; }
        value="$1"; shift
        if [ "$value" = - ]; then value="$(cat)"; else
          value="$(cat -- "$value")" || { echo "aiur: experiments cannot read input file" >&2; exit 1; }
        fi
        arg="--spec-json=$value"
        ;;
      --line)
        [ "$#" -gt 0 ] || { echo "aiur: experiments --line requires type:ref[@time]" >&2; exit 64; }
        case "$1" in ?*:?*) ;; *) echo "aiur: experiments --line requires type:ref[@time]" >&2; exit 64 ;; esac
        ;;
      --line=*)
        case "${arg#--line=}" in ?*:?*) ;; *) echo "aiur: experiments --line requires type:ref[@time]" >&2; exit 64 ;; esac
        ;;
      --spec-json*) echo "aiur: experiments use --from to supply JSON" >&2; exit 64 ;;
    esac
    encoded="$(encode_control_value "$arg")"
    argv="$argv$separator Base.decode64!(\"$encoded\")"; separator=,
  done
  opts="verb: :$verb, argv: [$argv]"
  run_control_rpc "Aiur.AgentControlCLI.experiments([$opts])"
}
