# shellcheck shell=bash
# `aiur notify`: publish an operator.notify.<kind> event for the operator's devices.

cmd_notify() {
  local kind="${1:-}" text="" ticket="" url="" arg
  shift 2>/dev/null || true
  case "$kind" in
    review_ready | live | stalled | info) ;;
    "") echo "aiur: notify requires a kind: review_ready, live, stalled or info" >&2; exit 64 ;;
    *) echo "aiur: notify kind must be review_ready, live, stalled or info" >&2; exit 64 ;;
  esac
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --ticket) shift; ticket="${1:-}" ;;
      --ticket=*) ticket="${arg#--ticket=}" ;;
      --url) shift; url="${1:-}" ;;
      --url=*) url="${arg#--url=}" ;;
      --*) echo "aiur: notify accepts only --ticket <N> and --url <URL>" >&2; exit 64 ;;
      *) text="${text:+$text }$arg" ;;
    esac
    shift
  done
  [ -n "$text" ] || { echo "aiur: notify requires text" >&2; exit 64; }
  local kind_encoded text_encoded ticket_encoded url_encoded
  kind_encoded="$(printf '%s' "$kind" | base64 | tr -d '\n')"
  text_encoded="$(printf '%s' "$text" | base64 | tr -d '\n')"
  ticket_encoded="$(printf '%s' "$ticket" | base64 | tr -d '\n')"
  url_encoded="$(printf '%s' "$url" | base64 | tr -d '\n')"
  run_control_rpc "Aiur.AgentControlCLI.notify(Base.decode64!(\"$kind_encoded\"), Base.decode64!(\"$text_encoded\"), Base.decode64!(\"$ticket_encoded\"), Base.decode64!(\"$url_encoded\"))"
}
