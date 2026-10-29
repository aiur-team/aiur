# Executor-originated Command requests. Context files are read on the caller's machine.
cmd_command() {
  [ "${1:-}" = request ] || { echo "aiur: command expects the request subcommand" >&2; exit 64; }
  shift
  cmd_command_request "$@"
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
