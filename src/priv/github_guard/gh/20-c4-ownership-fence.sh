# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
# Ownership fence (MPG-105): refuse the irreversible PR writes when the daemon says this
# ticket moved to another owner, or cannot say. Inactive unless the daemon exported the
# fence socket. Runs before budget admission, so a refusal costs no GitHub quota.
fence_action=
if [ "$agent_guard" -eq 1 ] && [ -n "${AIUR_OWNERSHIP_FENCE_SOCKET:-}" ] && [ -n "${AIUR_AGENT_WORKSPACE:-}" ]; then
  case "${1:-} ${2:-}" in
    "pr create") fence_action=pr-create ;;
    "pr ready"|"pr reopen") fence_action=pr-ready ;;
    "pr merge") fence_action=pr-merge ;;
    "api "*)
      if [ "$direction" = write ]; then
        for fence_arg in "$@"; do
          case "$fence_arg" in
            *createPullRequest*|*markPullRequestReadyForReview*) fence_action=api-pr-write ;;
            repos/*/pulls|/repos/*/pulls|repos/*/pulls/) fence_action=api-pr-write ;;
          esac
        done
      fi
      ;;
  esac
fi
if [ -n "$fence_action" ]; then
  fence_out=$(python3 -I "$(dirname "$budget_broker")/aiur-github-budget-socket" "$AIUR_OWNERSHIP_FENCE_SOCKET" fence --workspace "$AIUR_AGENT_WORKSPACE" --action "$fence_action" 2>/dev/null)
  fence_rc=$?
  case "$fence_rc:$fence_out" in
    0:ok\ *) ;;
    0:moved\ *)
      printf 'aiur: ownership moved (%s); this ticket now belongs to another owner; stop and leave the workspace as is\n' "${fence_out#moved }" >&2
      exit 77
      ;;
    *)
      printf 'aiur: ownership unverifiable (%s); refusing %s\n' "${fence_out:-daemon fence socket unreachable, exit $fence_rc}" "$fence_action" >&2
      exit 75
      ;;
  esac
fi
