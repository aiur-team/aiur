# Replay-safe remote writes: leading --instance/--request-id flags, UUIDv7 ids and retry hints.
# Sourced by aiur-engine.sh.

aiur_valid_request_id() {
  [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]
}

# Consumes leading --instance and --request-id flags (either order, `--flag value` or
# `--flag=value`). Sets AIUR_REMOTE_INSTANCE, AIUR_REQUEST_ID and AIUR_FLAGS_CONSUMED (words to shift).
# Only a flag may select a remote target, so any inherited AIUR_REMOTE_INSTANCE is cleared first.
aiur_parse_remote_flags() {
  local flag value used
  unset AIUR_REMOTE_INSTANCE
  AIUR_FLAGS_CONSUMED=0
  while :; do
    case "${1:-}" in
      --instance=*) flag=--instance value="${1#*=}" used=1 ;;
      --request-id=*) flag=--request-id value="${1#*=}" used=1 ;;
      --instance) flag=--instance value="${2:-}" used=2 ;;
      --request-id) flag=--request-id value="${2:-}" used=2 ;;
      *) break ;;
    esac
    AIUR_FLAGS_CONSUMED=$((AIUR_FLAGS_CONSUMED + used))
    shift "$used" 2>/dev/null || shift "$#"
    if [ -z "$value" ]; then
      [ "$flag" = --instance ] && echo "aiur: --instance requires a name" >&2 || echo "aiur: --request-id requires a value" >&2
      return 64
    fi
    if [ "$flag" = --instance ]; then export AIUR_REMOTE_INSTANCE="$value"; else AIUR_REQUEST_ID="$value"; fi
  done
  [ -z "${AIUR_REQUEST_ID:-}" ] || aiur_valid_request_id "$AIUR_REQUEST_ID" || { echo "aiur: --request-id must be a UUIDv7" >&2; return 64; }
  [ -z "${AIUR_REQUEST_ID:-}" ] || [ "${AIUR_REMOTE_INSTANCE:-}" != all ] || { echo "aiur: --request-id cannot be combined with --instance all" >&2; return 64; }
}

aiur_new_request_id() {
  "$(remote_js_runtime)" -e '
    const b = require("node:crypto").randomBytes(16);
    let t = BigInt(Date.now());
    for (let i = 5; i >= 0; i--) { b[i] = Number(t & 0xffn); t >>= 8n; }
    b[6] = (b[6] & 0x0f) | 0x70;
    b[8] = (b[8] & 0x3f) | 0x80;
    const h = b.toString("hex");
    console.log([h.slice(0, 8), h.slice(8, 12), h.slice(12, 16), h.slice(16, 20), h.slice(20)].join("-"));
  '
}

# Prints the id to send, or nothing when the call is read-scope or must not be stored (executor-wait).
aiur_request_id_for_call() {
  [ "${AIUR_REMOTE_MAX_SCOPE:-write}" = write ] && [ -z "${AIUR_REMOTE_NO_REQUEST_ID:-}" ] || return 0
  if [ -n "${AIUR_REQUEST_ID:-}" ]; then printf '%s' "$AIUR_REQUEST_ID"; else aiur_new_request_id; fi
}

aiur_request_id_hint() {
  printf 'retry with --request-id %s is safe' "$1"
}

# A lost answer (curl timeout, reset, short read) may hide an applied write: say so, with the id, when we sent one.
aiur_remote_curl_failure() {
  local name="$1" curl_status="$2" request_id="$3"
  case "$curl_status:$request_id" in
    28:?* | 52:?* | 56:?*)
      control_rpc_say "aiur: $(control_command_label) to $name timed out; outcome unknown on $name; $(aiur_request_id_hint "$request_id")"
      return 124
      ;;
  esac
  control_rpc_say "aiur: could not reach remote instance '$name' (curl exit $curl_status)"
  return 69
}

# An older daemon refused contract 2 before running anything, so one contract-1 retry is safe; it has no replay safety.
aiur_remote_v1_retry() {
  control_rpc_say "aiur: $1 runs a build without replay-safe writes; retrying without a request id (upgrade it)"
  AIUR_REMOTE_NO_REQUEST_ID=1 run_remote_rpc_with_timeout "$2"
}

aiur_remote_conflict() {
  local name="$1" response_file="$2" request_id="$3" code
  code="$(remote_json_field "$response_file" "error.code" 2>/dev/null || true)"
  case "$code" in
    request_in_progress)
      control_rpc_say "aiur: $(control_command_label) is still running on $name; retry later with --request-id $request_id"
      return 75
      ;;
    outcome_unknown | result_not_retained)
      control_rpc_say "aiur: $(control_command_label) outcome unknown on $name ($code); verify its state, then use a new id"
      return 124
      ;;
  esac
  control_rpc_say "aiur: remote instance '$name' refused $(control_command_label) (HTTP 409${code:+, $code})"
  return 64
}
