# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
update_branch_handoff() {
  [ "${1:-}" = pr ] && [ "${2:-}" = update-branch ] || return 1
  [ "$agent_guard" -eq 1 ] || return 1

  agent_workspace=${AIUR_AGENT_WORKSPACE:-}
  if [ -z "$agent_workspace" ]; then
    agent_workspace=$(CDPATH= cd "$(dirname "$0")/../.." 2>/dev/null && pwd) || agent_workspace=
  fi
  ticket_leaf=${agent_workspace##*/}
  ticket_number=${ticket_leaf#pr-}
  ticket_number=${ticket_number##*-}
  case "$ticket_number" in *[!0-9]*|'') return 1 ;; esac

  # The ticket belongs to this workspace's origin, even if the command names
  # another repository with -R/--repo.
  remote=$(git -C "$agent_workspace" config --get remote.origin.url 2>/dev/null || true)
  case "$remote" in
    https://github.com/*) repo=${remote#https://github.com/} ;;
    git@github.com:*) repo=${remote#git@github.com:} ;;
    *) return 1 ;;
  esac
  repo=${repo%.git}
  case "$repo" in */*) ;; *) return 1 ;; esac

  # Re-enter with distinct arguments so the conditional REST read receives its
  # own admission, attribution and response reconciliation.
  state=$("$0" api "repos/$repo/issues/$ticket_number" --jq '[.labels[].name] | join(" ")' 2>/dev/null || true)
  case " $state " in
    *" agent:human-review "*|*" agent:ci-wait "*)
      printf '%s\n' "aiur: refusing gh pr update-branch: ticket #$ticket_number is handed off for review or CI" >&2
      printf '%s\n' 'aiur: wait for the review verdict; if GitHub reports the PR CONFLICTING or a reviewer asked for integration, first move the ticket to agent:in-progress with aiur_set_ticket_state, then integrate and push' >&2
      return 0
      ;;
  esac
  return 1
}

