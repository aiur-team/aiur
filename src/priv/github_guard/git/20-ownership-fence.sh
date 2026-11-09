# Fragment of the assembled `git` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
# Ownership fence (MPG-105): a push is refused when the daemon says this ticket moved to
# another owner, or cannot say. Inactive unless the daemon exported the fence socket.
if [ "$push_command" = true ] && [ -n "${AIUR_OWNERSHIP_FENCE_SOCKET:-}" ] && [ -n "${AIUR_AGENT_WORKSPACE:-}" ]; then
  fence_dry_run=false
  for arg in "$@"; do
    case "$arg" in --dry-run|-n) fence_dry_run=true ;; esac
  done
  if [ "$fence_dry_run" = false ]; then
    fence_out=$(python3 -I "$(dirname "$0")/aiur-github-budget-socket" "$AIUR_OWNERSHIP_FENCE_SOCKET" fence --workspace "$AIUR_AGENT_WORKSPACE" --action push 2>/dev/null)
    fence_rc=$?
    case "$fence_rc:$fence_out" in
      0:ok\ *) ;;
      0:moved\ *)
        printf 'aiur: ownership moved (%s); this ticket now belongs to another owner; stop and leave the workspace as is\n' "${fence_out#moved }" >&2
        exit 77
        ;;
      *)
        printf 'aiur: ownership unverifiable (%s); refusing push\n' "${fence_out:-daemon fence socket unreachable, exit $fence_rc}" >&2
        exit 75
        ;;
    esac
  fi
fi

GIT_TERMINAL_PROMPT=0
GIT_CONFIG_PARAMETERS="'credential.https://github.com.helper=' 'credential.https://github.com.helper=$credential_helper' 'http.https://github.com/.extraheader='"
export GIT_TERMINAL_PROMPT GIT_CONFIG_PARAMETERS

exec "$real_git" "$@"
