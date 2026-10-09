# Queue commands shared by the installed CLI and aiurdev.
queue_usage_error() { echo "aiur: queue $*" >&2; exit 64; }
queue_string() { printf 'Base.decode64!("%s")' "$(printf '%s' "$1" | base64 | tr -d '\n')"; }
queue_workspace_guard() {
  if [ -n "${AIUR_AGENT_WORKSPACE:-}" ] || [[ "$PWD" == */aiur-workspaces/* ]] ||
     [[ "${AIUR_PROJECT_ROOT:-}" == */aiur-workspaces/* ]] || [[ "${AIUR_REPO_ROOT:-}" == */aiur-workspaces/* ]]; then
    echo 'aiur queue changes are blocked inside agent workspaces' >&2
    exit 64
  fi
}

cmd_queue() {
  local verb="${1:-}" json=0 queue="" after="" at="" to="" root="" opts="" id status=0
  local ids=()
  case "$verb" in
    show) ;;
    add|remove|reorder|hold|release) queue_workspace_guard ;;
    *) queue_usage_error 'expects show, add, remove, reorder, hold, or release' ;;
  esac
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) [ "$verb" = show ] || queue_usage_error '--json requires show'; json=1 ;;
      --queue)
        [ "$#" -ge 2 ] && [ -n "$2" ] && [[ "$2" != -* ]] || queue_usage_error '--queue requires a name'
        case "$verb" in show|add|hold|release) ;; *) queue_usage_error "--queue is not valid for $verb" ;; esac
        [ -z "$queue" ] || queue_usage_error 'duplicate --queue'
        queue="$2"; shift ;;
      --after)
        [ "$verb" = add ] && [ "$#" -ge 2 ] && [[ "$2" =~ ^[1-9][0-9]*$ ]] && [ -z "$after" ] || queue_usage_error '--after requires add and a positive ticket ID'
        after="$2"; shift ;;
      --at)
        [ "$verb" = add ] && [ "$#" -ge 2 ] && [[ "$2" =~ ^(0|[1-9][0-9]*)$ ]] && [ -z "$at" ] || queue_usage_error '--at requires add and a non-negative position'
        at="$2"; shift ;;
      --to)
        [ "$verb" = reorder ] && [ "$#" -ge 2 ] && [[ "$2" =~ ^(0|[1-9][0-9]*)$ ]] && [ -z "$to" ] || queue_usage_error '--to requires reorder and a non-negative position'
        to="$2"; shift ;;
      --build-order)
        [ "$verb" = add ] && [ "$#" -ge 2 ] && [[ "$2" =~ ^[1-9][0-9]*$ ]] && [ -z "$root" ] || queue_usage_error '--build-order requires add and a positive root ID'
        root="$2"; shift ;;
      -*) queue_usage_error "received an unknown argument: $1" ;;
      *)
        [[ "$1" =~ ^[1-9][0-9]*$ ]] || queue_usage_error "invalid ticket ID: $1"
        for id in "${ids[@]}"; do [ "$id" != "$1" ] || queue_usage_error "duplicate ticket ID: $1"; done
        ids+=("$1") ;;
    esac
    shift
  done
  case "$verb" in
    show) [ "${#ids[@]}" -eq 0 ] || queue_usage_error 'show does not take ticket IDs' ;;
    add)
      if [ -n "$root" ]; then
        [ "${#ids[@]}" -eq 0 ] && [ -z "$after$at" ] || queue_usage_error '--build-order cannot be combined with ticket IDs, --after, or --at'
      else
        [ "${#ids[@]}" -gt 0 ] || queue_usage_error 'add requires ticket IDs or --build-order'
      fi ;;
    remove) [ "${#ids[@]}" -gt 0 ] || queue_usage_error 'remove requires ticket IDs' ;;
    reorder) [ "${#ids[@]}" -eq 1 ] && [ -n "$to" ] || queue_usage_error 'reorder requires one ticket ID and --to POS' ;;
    hold|release)
      { [ "${#ids[@]}" -eq 1 ] && [ -z "$queue" ]; } ||
        { [ "${#ids[@]}" -eq 0 ] && [ -n "$queue" ]; } || queue_usage_error "$verb requires one ticket ID or --queue NAME" ;;
  esac
  opts="verb: :$verb, caller_agent_workspace: $(queue_string "${AIUR_AGENT_WORKSPACE:-}")"
  [ "$json" -eq 1 ] && opts="$opts, json: true"
  [ -n "$queue" ] && opts="$opts, queue: $(queue_string "$queue")"
  [ -n "$root" ] && opts="$opts, build_order: $root"
  [ -n "$after" ] && opts="$opts, after: \"$after\""
  [ -n "$at" ] && opts="$opts, at: $at"
  [ -n "$to" ] && opts="$opts, to: $to"
  if [ "${#ids[@]}" -gt 0 ]; then
    opts="$opts, ids: ["
    for id in "${ids[@]}"; do opts="$opts\"$id\","; done
    opts="${opts%,}]"
  fi
  if [ "$verb" = add ] || [ "$verb" = remove ]; then
    AIUR_CONTROL_RPC_TIMEOUT_SECONDS="$(todo_rpc_seconds "${#ids[@]}" 0)"
  fi
  AIUR_CONTROL_COMMAND="queue $verb" run_control_rpc "Aiur.AgentControlCLI.queue([$opts])" || status=$?
  if [ "$status" -eq 124 ]; then echo 'aiur: queue outcome unknown; run aiur queue show before retrying' >&2; fi
  return "$status"
}
