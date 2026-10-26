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

# The denylist keys on the command name, so anything that renames a command
# defeats it: `gh alias set zz "pr merge"` followed by `gh zz 7` arrives here as
# `zz`, matches nothing, and is admitted. The per-workspace `GH_CONFIG_DIR` that
# closes the keyring bypass also hands the agent a writable place to store that
# alias: refusing alias mutation removes the write half; refusing an unknown
# command name removes the read half — an unrecognised name is not one this
# guard has decided is safe, but one it cannot decide about at all.
undecidable_agent_command() {
  case "${1:-} ${2:-}" in
    "alias set"|"alias delete"|"alias import") return 0 ;;
  esac

  case "${1:-}" in
    # Bare `gh` and its top-level flags print local help; no command is run.
    ''|-*) return 1 ;;
    accessibility|alias|api|attestation|auth|browse|cache|codespace|completion) return 1 ;;
    config|extension|gist|gpg-key|help|issue|label|org|pr|preview|project) return 1 ;;
    release|repo|ruleset|run|search|secret|ssh-key|status|variable|version|workflow) return 1 ;;
    *) return 0 ;;
  esac
}

if [ "$agent_guard" -eq 1 ] && merge_or_approve_command "$@"; then
  printf '%s\n' 'aiur: agents cannot approve or merge pull requests; a human reviewer holds the merge gate' >&2
  exit 77
fi

if update_branch_handoff "$@"; then exit 77; fi

if [ "$agent_guard" -eq 1 ] && undecidable_agent_command "$@"; then
  printf '%s\n' 'aiur: agents cannot rename or hide gh commands from the merge gate; refusing a command this guard cannot inspect' >&2
  exit 77
fi

