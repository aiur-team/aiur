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
  case "${1:-}" in "") ;; --json) json=true ;; *) echo "aiur: executor-session accepts only --json" >&2; exit 64 ;; esac
  run_control_rpc "Aiur.ExecutorSessionCLI.rpc(json: $json)"
}
