# Executor harness-session registration flags and the `executor-session` read.

# Consumes `--session-id <uuid>` / `--harness <name>` (or `=` forms) at "$1" for
# executor-wait. Returns 1 for anything else; sets EXECUTOR_SESSION_EXTRA to the
# extra args to shift.
executor_session_flag() {
  local flag="${1%%=*}" value
  EXECUTOR_SESSION_EXTRA=0
  case "$flag" in --session-id | --harness) ;; *) return 1 ;; esac
  if [ "$flag" = "$1" ]; then value="${2:-}"; EXECUTOR_SESSION_EXTRA=1; else value="${1#*=}"; fi
  case "$flag" in
    --session-id)
      [[ "$value" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || { echo "aiur: executor-wait --session-id expects a UUID" >&2; exit 64; }
      EXECUTOR_SESSION_ID="$value" ;;
    --harness)
      [[ "$value" =~ ^(claude|codex)$ ]] || { echo "aiur: executor-wait --harness expects claude or codex" >&2; exit 64; }
      EXECUTOR_SESSION_HARNESS="$value" ;;
  esac
}

# Keyword arguments for the RPC. The daemon's environment says nothing about the
# caller's harness, so the caller's variables travel base64-encoded (no quoting hazards).
executor_session_argument() {
  local name out=""
  [ -z "${EXECUTOR_SESSION_ID:-}" ] || out=", session_id: \"$EXECUTOR_SESSION_ID\""
  [ -z "${EXECUTOR_SESSION_HARNESS:-}" ] || out="$out, harness: \"$EXECUTOR_SESSION_HARNESS\""
  out="$out, env: ["
  for name in CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR CLAUDE_PID CLAUDE_CODE_CHILD_SESSION CODEX_THREAD_ID PWD; do
    [ -z "${!name:-}" ] || out="$out{\"$name\", \"$(printf %s "${!name}" | base64 | tr -d '\n')\"},"
  done
  printf '%s]' "$out"
}

cmd_executor_session() {
  local json=false
  if [ "$#" -gt 1 ]; then echo "aiur: executor-session accepts only --json" >&2; exit 64; fi
  case "${1:-}" in "") ;; --json) json=true ;; *) echo "aiur: executor-session accepts only --json" >&2; exit 64 ;; esac
  run_control_rpc "Aiur.AgentControlCLI.executor_session(json: $json)"
}

executor_project_root() {
  git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$PWD"
}

cmd_executor_attach() {
  local harness="" takeover=false print_config=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --harness)
        [ "$#" -ge 2 ] || { echo "aiur: --harness requires claude or codex" >&2; exit 64; }
        harness="$2"; shift ;;
      --harness=*) harness="${1#*=}" ;;
      --takeover) takeover=true ;;
      --print-config) print_config=true ;;
      *) echo "aiur: executor-attach: unknown argument $1" >&2; exit 64 ;;
    esac
    shift
  done
  case "$harness" in claude|codex) ;; *) echo "aiur: executor-attach requires --harness claude or codex" >&2; exit 64 ;; esac
  run_control_rpc "Aiur.AgentControlCLI.executor_attach(harness: \"$harness\", takeover?: $takeover, print_config: $print_config, repo_root: \"$(encode_control_value "$(executor_project_root)")\" |> Base.decode64!())"
}

cmd_executor_detach() {
  [ "$#" -eq 0 ] || { echo "aiur: executor-detach accepts no arguments" >&2; exit 64; }
  run_control_rpc "Aiur.AgentControlCLI.executor_detach(repo_root: \"$(encode_control_value "$(executor_project_root)")\" |> Base.decode64!())"
}
