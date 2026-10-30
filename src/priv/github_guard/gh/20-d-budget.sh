# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
if [ "$admission_required" -eq 1 ] && [ "$budget_required" -eq 1 ] && [ "$budget_enabled" -ne 1 ]; then
  printf 'aiur: GitHub shared budget unavailable (%s; %s); refusing uncoordinated request\n' "$budget_unavailable_reason" "$budget_recovery" >&2
  exit 75
fi

consumer=unattributed
if [ -n "${AIUR_AGENT_WORKSPACE:-}" ]; then
  ticket=$(basename "$AIUR_AGENT_WORKSPACE")
  case "$ticket" in
    ''|*[!0-9]*) ;;
    *) consumer=ticket:$ticket ;;
  esac
fi
