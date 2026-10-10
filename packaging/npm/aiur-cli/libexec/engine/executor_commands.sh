# Trusted-Executor verbs: answer, escalate, moot and the executor consumer commands. Sourced by aiur-engine.sh.

encode_control_value() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

# These are explicit trusted-Executor mutations, deliberately separate from
# the read-only `commands` catalog. Revisions remain dashboard-owned.
cmd_executor_answer() {
  local decision_id="${1:-}" expected_version="" option_id="" custom_response="" rationale="" idempotency_key="" executor_id="aiur-cli" supersede=0 arg
  if [ -z "$decision_id" ] || [[ "$decision_id" = -* ]]; then
    echo "aiur: executor-answer expects exactly one decision ID" >&2
    exit 64
  fi
  shift

  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --expected-version) [ "$#" -gt 1 ] || { echo "aiur: executor-answer --expected-version requires a value" >&2; exit 64; }; shift; expected_version="$1" ;;
      --expected-version=*) expected_version="${arg#--expected-version=}" ;;
      --option) [ "$#" -gt 1 ] || { echo "aiur: executor-answer --option requires a value" >&2; exit 64; }; shift; option_id="$1" ;;
      --option=*) option_id="${arg#--option=}" ;;
      --custom-response) [ "$#" -gt 1 ] || { echo "aiur: executor-answer --custom-response requires a value" >&2; exit 64; }; shift; custom_response="$1" ;;
      --custom-response=*) custom_response="${arg#--custom-response=}" ;;
      --rationale) [ "$#" -gt 1 ] || { echo "aiur: executor-answer --rationale requires a value" >&2; exit 64; }; shift; rationale="$1" ;;
      --rationale=*) rationale="${arg#--rationale=}" ;;
      --idempotency-key) [ "$#" -gt 1 ] || { echo "aiur: executor-answer --idempotency-key requires a value" >&2; exit 64; }; shift; idempotency_key="$1" ;;
      --idempotency-key=*) idempotency_key="${arg#--idempotency-key=}" ;;
      --executor-id) [ "$#" -gt 1 ] || { echo "aiur: executor-answer --executor-id requires a value" >&2; exit 64; }; shift; executor_id="$1" ;;
      --executor-id=*) executor_id="${arg#--executor-id=}" ;;
      --supersede) supersede=1 ;;
      -*) echo "aiur: executor-answer received an unknown option: $arg" >&2; exit 64 ;;
      *) echo "aiur: executor-answer expects exactly one decision ID" >&2; exit 64 ;;
    esac
    shift
  done

  [[ "$expected_version" =~ ^[1-9][0-9]*$ ]] || { echo "aiur: executor-answer --expected-version expects a positive integer" >&2; exit 64; }
  if { [ -n "$option_id" ] && [ -n "$custom_response" ]; } || { [ -z "$option_id" ] && [ -z "$custom_response" ]; }; then
    echo "aiur: executor-answer requires exactly one of --option or --custom-response" >&2
    exit 64
  fi
  [ -n "$rationale" ] || { echo "aiur: executor-answer --rationale is required" >&2; exit 64; }
  [ -n "$idempotency_key" ] || { echo "aiur: executor-answer --idempotency-key is required" >&2; exit 64; }
  [ -n "$executor_id" ] || { echo "aiur: executor-answer --executor-id must not be empty" >&2; exit 64; }

  local opts="decision_id: Base.decode64!(\"$(encode_control_value "$decision_id")\"), expected_version: $expected_version"
  if [ -n "$option_id" ]; then
    opts="$opts, option_id: Base.decode64!(\"$(encode_control_value "$option_id")\")"
  else
    opts="$opts, custom_response: Base.decode64!(\"$(encode_control_value "$custom_response")\")"
  fi
  opts="$opts, rationale: Base.decode64!(\"$(encode_control_value "$rationale")\")"
  opts="$opts, idempotency_key: Base.decode64!(\"$(encode_control_value "$idempotency_key")\")"
  opts="$opts, executor_id: Base.decode64!(\"$(encode_control_value "$executor_id")\")"
  if [ "$supersede" -eq 1 ]; then
    opts="$opts, supersede: true"
  fi
  local AIUR_CONTROL_ATTEMPT_CONTEXT="decision ID ${decision_id} with expected version ${expected_version}"
  run_control_rpc "Aiur.AgentControlCLI.executor_answer([$opts])"
}

cmd_executor_escalate() {
  local decision_id="${1:-}" expected_version="" reason="" executor_id="aiur-cli" arg
  if [ -z "$decision_id" ] || [[ "$decision_id" = -* ]]; then
    echo "aiur: executor-escalate expects exactly one decision ID" >&2
    exit 64
  fi
  shift

  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --expected-version) [ "$#" -gt 1 ] || { echo "aiur: executor-escalate --expected-version requires a value" >&2; exit 64; }; shift; expected_version="$1" ;;
      --expected-version=*) expected_version="${arg#--expected-version=}" ;;
      --reason) [ "$#" -gt 1 ] || { echo "aiur: executor-escalate --reason requires a value" >&2; exit 64; }; shift; reason="$1" ;;
      --reason=*) reason="${arg#--reason=}" ;;
      --executor-id) [ "$#" -gt 1 ] || { echo "aiur: executor-escalate --executor-id requires a value" >&2; exit 64; }; shift; executor_id="$1" ;;
      --executor-id=*) executor_id="${arg#--executor-id=}" ;;
      -*) echo "aiur: executor-escalate received an unknown option: $arg" >&2; exit 64 ;;
      *) echo "aiur: executor-escalate expects exactly one decision ID" >&2; exit 64 ;;
    esac
    shift
  done

  [[ "$expected_version" =~ ^[1-9][0-9]*$ ]] || { echo "aiur: executor-escalate --expected-version expects a positive integer" >&2; exit 64; }
  [ -n "$reason" ] || { echo "aiur: executor-escalate --reason is required" >&2; exit 64; }
  [ -n "$executor_id" ] || { echo "aiur: executor-escalate --executor-id must not be empty" >&2; exit 64; }

  local opts="decision_id: Base.decode64!(\"$(encode_control_value "$decision_id")\"), expected_version: $expected_version"
  opts="$opts, reason: Base.decode64!(\"$(encode_control_value "$reason")\")"
  opts="$opts, executor_id: Base.decode64!(\"$(encode_control_value "$executor_id")\")"
  local AIUR_CONTROL_ATTEMPT_CONTEXT="decision ID ${decision_id} with expected version ${expected_version}"
  run_control_rpc "Aiur.AgentControlCLI.executor_escalate([$opts])"
}

cmd_executor_moot() {
  local decision_id="${1:-}" expected_version="" reason_class="" reason="" executor_id="aiur-cli" arg
  if [ -z "$decision_id" ] || [[ "$decision_id" = -* ]]; then
    echo "aiur: executor-moot expects exactly one decision ID" >&2
    exit 64
  fi
  shift

  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --expected-version) [ "$#" -gt 1 ] || { echo "aiur: executor-moot --expected-version requires a value" >&2; exit 64; }; shift; expected_version="$1" ;;
      --expected-version=*) expected_version="${arg#--expected-version=}" ;;
      --reason-class) [ "$#" -gt 1 ] || { echo "aiur: executor-moot --reason-class requires a value" >&2; exit 64; }; shift; reason_class="$1" ;;
      --reason-class=*) reason_class="${arg#--reason-class=}" ;;
      --reason) [ "$#" -gt 1 ] || { echo "aiur: executor-moot --reason requires a value" >&2; exit 64; }; shift; reason="$1" ;;
      --reason=*) reason="${arg#--reason=}" ;;
      --executor-id) [ "$#" -gt 1 ] || { echo "aiur: executor-moot --executor-id requires a value" >&2; exit 64; }; shift; executor_id="$1" ;;
      --executor-id=*) executor_id="${arg#--executor-id=}" ;;
      -*) echo "aiur: executor-moot received an unknown option: $arg" >&2; exit 64 ;;
      *) echo "aiur: executor-moot expects exactly one decision ID" >&2; exit 64 ;;
    esac
    shift
  done

  [[ "$expected_version" =~ ^[1-9][0-9]*$ ]] || { echo "aiur: executor-moot --expected-version expects a positive integer" >&2; exit 64; }
  [ -n "$reason_class" ] || { echo "aiur: executor-moot --reason-class is required" >&2; exit 64; }
  [ -n "$executor_id" ] || { echo "aiur: executor-moot --executor-id must not be empty" >&2; exit 64; }

  local opts="decision_id: Base.decode64!(\"$(encode_control_value "$decision_id")\"), expected_version: $expected_version"
  opts="$opts, reason_class: Base.decode64!(\"$(encode_control_value "$reason_class")\")"
  if [ -n "$reason" ]; then
    opts="$opts, reason: Base.decode64!(\"$(encode_control_value "$reason")\")"
  fi
  opts="$opts, executor_id: Base.decode64!(\"$(encode_control_value "$executor_id")\")"
  local AIUR_CONTROL_ATTEMPT_CONTEXT="decision ID ${decision_id} with expected version ${expected_version}"
  run_control_rpc "Aiur.AgentControlCLI.executor_moot([$opts])"
}

cmd_executor_wait() {
  local timeout=300 json=0 as="" arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --timeout) shift; timeout="${1:-}" ;;
      --timeout=*) timeout="${arg#--timeout=}" ;;
      --json) json=1 ;;
      --as) shift; as="${1:-}" ;;
      --as=*) as="${arg#--as=}" ;;
      *) echo "aiur: executor-wait accepts --timeout <seconds>, --as <id> and --json" >&2; exit 64 ;;
    esac
    shift
  done
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || { echo "aiur: executor-wait --timeout expects a positive integer" >&2; exit 64; }
  executor_validate_consumer_id "$as" "executor-wait"
  local json_arg=false
  if [ "$json" -eq 1 ]; then json_arg=true; fi
  AIUR_CONTROL_COMMAND="executor-wait"
  AIUR_CONTROL_RPC_TIMEOUT_SECONDS=$((timeout + 10)) run_control_rpc "Aiur.AgentControlCLI.executor_wait(timeout_ms: $((timeout * 1000)), json: $json_arg$(executor_as_argument "$as"))"
}

# The consumer id is an explicit identity, never inferred from the environment.
executor_validate_consumer_id() {
  local value="$1" command="$2"
  [ -n "$value" ] || return 0
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "aiur: $command --as expects [A-Za-z0-9._-]+" >&2; exit 64; }
}

executor_as_argument() {
  [ -n "$1" ] || return 0
  printf ', as: "%s"' "$1"
}

executor_as_keyword() {
  [ -n "$1" ] || return 0
  printf 'as: "%s"' "$1"
}

cmd_executor_roster() {
  local json=0 arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=1 ;;
      *) echo "aiur: executor-roster accepts only --json" >&2; exit 64 ;;
    esac
    shift
  done
  local json_arg=false
  if [ "$json" -eq 1 ]; then json_arg=true; fi
  run_control_rpc "Aiur.AgentControlCLI.executor_roster(json: $json_arg)"
}

cmd_executor_fast_forward() {
  local wake_id="${1:-}" as="" arg
  [ -n "$wake_id" ] || { echo "aiur: executor-fast-forward expects a positive wake id" >&2; exit 64; }
  shift
  [[ "$wake_id" =~ ^[1-9][0-9]*$ ]] || { echo "aiur: executor-fast-forward expects a positive wake id" >&2; exit 64; }

  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --as)
        shift
        [ "$#" -gt 0 ] && [ -n "${1:-}" ] || { echo "aiur: executor-fast-forward --as requires a consumer id" >&2; exit 64; }
        as="$1"
        ;;
      --as=*)
        as="${arg#--as=}"
        [ -n "$as" ] || { echo "aiur: executor-fast-forward --as requires a consumer id" >&2; exit 64; }
        ;;
      *) echo "aiur: executor-fast-forward accepts <wake-id> and --as <id>" >&2; exit 64 ;;
    esac
    shift
  done

  executor_validate_consumer_id "$as" "executor-fast-forward"
  run_control_rpc "Aiur.AgentControlCLI.executor_fast_forward($wake_id, [$(executor_as_keyword "$as")])"
}

cmd_executor_claim() {
  local as="" arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --as) shift; as="${1:-}" ;;
      --as=*) as="${arg#--as=}" ;;
      *) echo "aiur: executor-claim accepts only --as <id>" >&2; exit 64 ;;
    esac
    shift
  done
  executor_validate_consumer_id "$as" "executor-claim"
  run_control_rpc "Aiur.AgentControlCLI.executor_claim([$(executor_as_keyword "$as")])"
}

cmd_executor_release() {
  local as="" arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --as) shift; as="${1:-}" ;;
      --as=*) as="${arg#--as=}" ;;
      *) echo "aiur: executor-release accepts only --as <id>" >&2; exit 64 ;;
    esac
    shift
  done
  executor_validate_consumer_id "$as" "executor-release"
  run_control_rpc "Aiur.AgentControlCLI.executor_release([$(executor_as_keyword "$as")])"
}

cmd_executor_revoke() {
  local owner="${1:-}"
  [ -n "$owner" ] || { echo "aiur: executor-revoke requires the current owner's consumer id" >&2; exit 64; }
  shift
  [ "$#" -eq 0 ] || { echo "aiur: executor-revoke accepts only <consumer-id>" >&2; exit 64; }
  executor_validate_consumer_id "$owner" "executor-revoke"
  run_control_rpc "Aiur.AgentControlCLI.executor_revoke(\"$owner\")"
}

cmd_executor_emit() {
  local topic="${1:-}" payload="" arg
  shift 2>/dev/null || true
  [ -n "$topic" ] || { echo "aiur: executor-emit requires a topic" >&2; exit 64; }
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --payload) shift; payload="${1:-}" ;;
      --payload=*) payload="${arg#--payload=}" ;;
      *) echo "aiur: executor-emit accepts only --payload <json>" >&2; exit 64 ;;
    esac
    shift
  done
  [ -n "$payload" ] || { echo "aiur: executor-emit requires --payload <json>" >&2; exit 64; }
  local topic_encoded payload_encoded
  topic_encoded="$(printf '%s' "$topic" | base64 | tr -d '\n')"
  payload_encoded="$(printf '%s' "$payload" | base64 | tr -d '\n')"
  run_control_rpc "Aiur.AgentControlCLI.executor_emit(Base.decode64!(\"$topic_encoded\"), Base.decode64!(\"$payload_encoded\"))"
}

cmd_executor_subscription() {
  local action="$1" topic="${2:-}"
  [ -n "$topic" ] && [ "$#" -eq 2 ] || { echo "aiur: $action requires one topic pattern" >&2; exit 64; }
  local encoded
  encoded="$(printf '%s' "$topic" | base64 | tr -d '\n')"
  case "$action" in
    executor-subscribe) run_control_rpc "Aiur.AgentControlCLI.executor_subscribe(Base.decode64!(\"$encoded\"))" ;;
    executor-unsubscribe) run_control_rpc "Aiur.AgentControlCLI.executor_unsubscribe(Base.decode64!(\"$encoded\"))" ;;
  esac
}

cmd_executor_subscriptions() {
  [ "$#" -eq 0 ] || { echo "aiur: executor-subscriptions does not accept arguments" >&2; exit 64; }
  run_control_rpc "Aiur.AgentControlCLI.executor_subscriptions()"
}
