# Executor-originated Command requests. Context files are read on the caller's machine.
# @cli-reference aiur command request <question> --media FILE-OR-URL[,kind=K,alt=TEXT,caption=TEXT,option=ID] | Attaches typed media to the prompt, or to one option with `option=ID`; repeatable. Local files must sit under a configured root and become attachments; HTTPS URLs must be allowlisted; expiring URLs are refused. MIME type and kind are inferred from the extension unless `mime=` or `kind=` is given. | aiur command request 'Which sprite?' --option a=Left --option b=Right --media shots/a.png,option=a,alt='Left sprite'
# @cli-reference aiur command request <question> --after TICKET[,TICKET...] | Holds the Command as pending until every listed ticket is closed as completed, then publishes it. Unknown tickets and trackers that cannot report closure are refused. Any other closure drops it and raises an Executor attention. `aiur command` lists pending Commands. | aiur command request 'Which build feels better?' --option a=First --option b=Second --after 5,6
# @cli-reference aiur command cancel PENDING-ID | Removes a pending `--after` Command before it publishes. | aiur command cancel pend_1a2b3c4d
cmd_command() {
  if [ "${1:-}" = request ]; then
    shift
    cmd_command_request "$@"
    return
  fi
  if [ "${1:-}" = cancel ]; then
    [ "$#" -eq 2 ] && [[ "$2" =~ ^pend_[0-9a-f]{8}$ ]] || { echo "aiur: command cancel expects one pending ID (pend_xxxxxxxx)" >&2; exit 64; }
    run_control_rpc "Aiur.AgentControlCLI.command_cancel([pending_id: \"$2\"])"
    return
  fi

  case "${1:-}" in
    --filter|--filter=*|--blocking|--ticket|--ticket=*|--search|--search=*|--cursor|--cursor=*|--limit|--limit=*|--json)
      cmd_commands "$@"
      return
      ;;
  esac

  local decision_id="" option_id="" custom_response="" quote="" idempotency_key="" relayed=0 arg
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
      --idempotency-key) [ "$#" -gt 1 ] || { echo "aiur: command --idempotency-key requires a value" >&2; exit 64; }; shift; idempotency_key="$1" ;;
      --idempotency-key=*) idempotency_key="${arg#--idempotency-key=}" ;;
      --answer|--answer=*|--answer-text|--answer-text=*|--answers-file|--answers-file=*) question_answer_flag "$@"; shift "$QA_EXTRA" ;;
      *) echo "aiur: command received an unexpected argument: $arg" >&2; exit 64 ;;
    esac
    shift
  done

  if [ "$relayed" -eq 1 ]; then
    [ -n "$quote" ] || { echo "aiur: command --relayed requires --quote" >&2; exit 64; }
    local relayed_by="${AIUR_EXECUTOR_ID:-${USER:-executor}}"
    local opts="decision_id: Base.decode64!(\"$(encode_control_value "$decision_id")\"), quote: Base.decode64!(\"$(encode_control_value "$quote")\"), relayed_by: Base.decode64!(\"$(encode_control_value "$relayed_by")\"), auto_current: true"
    [ -z "$idempotency_key" ] || opts="$opts, idempotency_key: Base.decode64!(\"$(encode_control_value "$idempotency_key")\")"
    if question_answers_given; then
      [ -z "$option_id$custom_response" ] || { echo "aiur: command takes --answer/--answer-text/--answers-file or --option/--custom-response, not both" >&2; exit 64; }
      opts="$opts$(question_answer_argument)"
    elif [ -n "$option_id" ] && [ -z "$custom_response" ]; then
      opts="$opts, option_id: Base.decode64!(\"$(encode_control_value "$option_id")\")"
    elif [ -z "$option_id" ] && [ -n "$custom_response" ]; then
      opts="$opts, custom_response: Base.decode64!(\"$(encode_control_value "$custom_response")\")"
    else
      echo "aiur: command requires exactly one of --option or --custom-response" >&2
      exit 64
    fi
    run_control_rpc "Aiur.AgentControlCLI.operator_relay_answer([$opts])"
  else
    [ -z "$idempotency_key" ] || { echo "aiur: command --idempotency-key requires --relayed" >&2; exit 64; }
    [ -z "$quote" ] || { echo "aiur: command --quote requires --relayed" >&2; exit 64; }
    # ponytail: the interactive operator path previews one answer; per-question answers need --relayed or the dashboard.
    ! question_answers_given || { echo "aiur: command --answer/--answer-text/--answers-file require --relayed; answer interactively in the dashboard" >&2; exit 64; }
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
  local after="" options="" media="" recommend="" blocking=true urgency=normal ticket="" summary="" idempotency_key="" json=false
  [ -n "$question" ] && [[ "$question" != -* ]] || { echo "aiur: command request expects one question" >&2; exit 64; }
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --blocking) blocking=true; shift; continue ;;
      --json) json=true; shift; continue ;;
      --option|--media|--recommend|--urgency|--ticket|--context-file|--short-summary|--executor-id|--idempotency-key|--after)
        [ "$#" -gt 1 ] && [ -n "$2" ] || { echo "aiur: command request $arg requires a value" >&2; exit 64; }
        key="$arg"; value="$2"; shift ;;
      --option=*|--media=*|--recommend=*|--urgency=*|--ticket=*|--context-file=*|--short-summary=*|--executor-id=*|--idempotency-key=*|--after=*)
        key="${arg%%=*}"; value="${arg#*=}"
        [ -n "$value" ] || { echo "aiur: command request $key requires a value" >&2; exit 64; } ;;
      *) echo "aiur: command request received an unexpected argument: $arg" >&2; exit 64 ;;
    esac
    case "$key" in
      --option) options="${options}${options:+, }Base.decode64!(\"$(encode_control_value "$value")\")" ;;
      --media)
        # The daemon may run elsewhere: resolve a relative file on the caller's machine.
        case "$value" in https://*|http://*|/*) ;; *) value="$PWD/$value" ;; esac
        media="${media}${media:+, }Base.decode64!(\"$(encode_control_value "$value")\")" ;;
      --recommend) recommend="$value" ;;
      --urgency) urgency="$value" ;;
      --ticket) ticket="$value" ;;
      --context-file) context_file="$value" ;;
      --short-summary) summary="$value" ;;
      --executor-id) executor_id="$value" ;;
      --idempotency-key) idempotency_key="$value" ;;
      --after) after="$value" ;;
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
  opts="question: Base.decode64!(\"$(encode_control_value "$question")\"), options: [$options], media: [$media], blocking: $blocking, json: $json"
  for key in recommend urgency ticket short_summary executor_id idempotency_key long_context_markdown after; do
    case "$key" in
      recommend) value="$recommend" ;; urgency) value="$urgency" ;; ticket) value="$ticket" ;; short_summary) value="$summary" ;;
      executor_id) value="$executor_id" ;; idempotency_key) value="$idempotency_key" ;; long_context_markdown) value="$context" ;; after) value="$after" ;;
    esac
    [ -z "$value" ] || opts="$opts, $key: Base.decode64!(\"$(encode_control_value "$value")\")"
  done
  run_control_rpc "Aiur.AgentControlCLI.command_request([$opts])"
}
