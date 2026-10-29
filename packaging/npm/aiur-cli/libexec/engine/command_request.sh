# Executor-originated Command requests. Context files are read on the caller's machine.
cmd_command() {
  if [ "${1:-}" = request ]; then
    shift
    cmd_command_request "$@"
    return
  fi

  case "${1:-}" in
    --filter|--filter=*|--blocking|--ticket|--ticket=*|--search|--search=*|--cursor|--cursor=*|--limit|--limit=*|--json)
      cmd_commands "$@"
      return
      ;;
  esac

  local decision_id="" option_id="" custom_response="" quote="" relayed=0 arg
  if [ "$#" -gt 0 ] && [[ "$1" != -* ]]; then
    decision_id="$1"
    shift
  fi

  if [ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ "$1" = "--json" ]; }; then
    if [ -n "$decision_id" ]; then
      cmd_commands --filter all "$decision_id" "$@"
    else
      cmd_commands --filter open "$@"
    fi
    return
  fi

  [ -n "$decision_id" ] || { echo "aiur: command answers require a decision ID" >&2; exit 64; }
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --option) [ "$#" -gt 1 ] || { echo "aiur: command --option requires a value" >&2; exit 64; }; shift; option_id="$1" ;;
      --option=*) option_id="${arg#--option=}" ;;
      --custom-response) [ "$#" -gt 1 ] || { echo "aiur: command --custom-response requires a value" >&2; exit 64; }; shift; custom_response="$1" ;;
      --custom-response=*) custom_response="${arg#--custom-response=}" ;;
      --relayed) relayed=1 ;;
      --quote) [ "$#" -gt 1 ] || { echo "aiur: command --quote requires a value" >&2; exit 64; }; shift; quote="$1" ;;
      --quote=*) quote="${arg#--quote=}" ;;
      *) echo "aiur: command received an unexpected argument: $arg" >&2; exit 64 ;;
    esac
    shift
  done

  if [ "$relayed" -eq 1 ]; then
    [ -n "$quote" ] || { echo "aiur: command --relayed requires --quote" >&2; exit 64; }
    local relayed_by="${AIUR_EXECUTOR_ID:-${USER:-executor}}"
    local opts="decision_id: Base.decode64!(\"$(encode_control_value "$decision_id")\"), quote: Base.decode64!(\"$(encode_control_value "$quote")\"), relayed_by: Base.decode64!(\"$(encode_control_value "$relayed_by")\"), auto_current: true"
    if [ -n "$option_id" ] && [ -z "$custom_response" ]; then
      opts="$opts, option_id: Base.decode64!(\"$(encode_control_value "$option_id")\")"
    elif [ -z "$option_id" ] && [ -n "$custom_response" ]; then
      opts="$opts, custom_response: Base.decode64!(\"$(encode_control_value "$custom_response")\")"
    else
      echo "aiur: command requires exactly one of --option or --custom-response" >&2
      exit 64
    fi
    run_control_rpc "Aiur.AgentControlCLI.operator_relay_answer([$opts])"
  else
    [ -z "$quote" ] || { echo "aiur: command --quote requires --relayed" >&2; exit 64; }
    if [ -n "$option_id" ] && [ -z "$custom_response" ]; then
      cmd_operator_answer "$decision_id" --option "$option_id" --operator
    elif [ -z "$option_id" ] && [ -n "$custom_response" ]; then
      cmd_operator_answer "$decision_id" --custom-response "$custom_response" --operator
    else
      echo "aiur: command requires exactly one of --option or --custom-response" >&2
      exit 64
    fi
  fi
}

cmd_command_request() {
  local question="${1:-}" arg key value opts context_file="" context="" executor_id=""
  local options="" recommend="" blocking=true urgency=normal ticket="" summary="" idempotency_key="" json=false
  [ -n "$question" ] && [[ "$question" != -* ]] || { echo "aiur: command request expects one question" >&2; exit 64; }
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --blocking) blocking=true; shift; continue ;;
      --json) json=true; shift; continue ;;
      --option|--recommend|--urgency|--ticket|--context-file|--short-summary|--executor-id|--idempotency-key)
        [ "$#" -gt 1 ] && [ -n "$2" ] || { echo "aiur: command request $arg requires a value" >&2; exit 64; }
        key="$arg"; value="$2"; shift ;;
      --option=*|--recommend=*|--urgency=*|--ticket=*|--context-file=*|--short-summary=*|--executor-id=*|--idempotency-key=*)
        key="${arg%%=*}"; value="${arg#*=}"
        [ -n "$value" ] || { echo "aiur: command request $key requires a value" >&2; exit 64; } ;;
      *) echo "aiur: command request received an unexpected argument: $arg" >&2; exit 64 ;;
    esac
    case "$key" in
      --option) options="${options}${options:+, }Base.decode64!(\"$(encode_control_value "$value")\")" ;;
      --recommend) recommend="$value" ;;
      --urgency) urgency="$value" ;;
      --ticket) ticket="$value" ;;
      --context-file) context_file="$value" ;;
      --short-summary) summary="$value" ;;
      --executor-id) executor_id="$value" ;;
      --idempotency-key) idempotency_key="$value" ;;
    esac
    shift
  done
  case "$urgency" in low|normal|high|critical) ;; *) echo "aiur: command request --urgency expects low|normal|high|critical" >&2; exit 64 ;; esac
  if [ -n "$context_file" ]; then
    [ -f "$context_file" ] && [ -r "$context_file" ] || { echo "aiur: command request cannot read --context-file: $context_file" >&2; exit 64; }
    [ "$(wc -m < "$context_file")" -le 20000 ] || { echo "aiur: command request --context-file exceeds 20000 characters" >&2; exit 64; }
    context="$(cat -- "$context_file")" || { echo "aiur: command request cannot read --context-file" >&2; exit 64; }
  fi
  # Resolve caller identity before RPC; the daemon may have a different environment.
  if [ -z "$executor_id" ]; then
    local instance_key="${AIUR_INSTANCE_KEY:-default}"
    executor_id="${AIUR_EXECUTOR_ID:-$(hostname)-${instance_key:0:12}}"
  fi
  opts="question: Base.decode64!(\"$(encode_control_value "$question")\"), options: [$options], blocking: $blocking, json: $json"
  for key in recommend urgency ticket short_summary executor_id idempotency_key long_context_markdown; do
    case "$key" in
      recommend) value="$recommend" ;; urgency) value="$urgency" ;; ticket) value="$ticket" ;; short_summary) value="$summary" ;;
      executor_id) value="$executor_id" ;; idempotency_key) value="$idempotency_key" ;; long_context_markdown) value="$context" ;;
    esac
    [ -z "$value" ] || opts="$opts, $key: Base.decode64!(\"$(encode_control_value "$value")\")"
  done
  run_control_rpc "Aiur.AgentControlCLI.command_request([$opts])"
}
