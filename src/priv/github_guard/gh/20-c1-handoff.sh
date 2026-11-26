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


# An agent hands off through aiur_set_ticket_state, which gates the PR body; a raw
# label write to a handoff state skips that gate.
state_label_write() {
  label_next_adds=0
  case "${1:-} ${2:-}" in
    "issue edit"|"pr edit") label_command=edit ;;
    *)
      label_command=
      [ "${1:-}" = api ] && [ "$direction" = write ] && label_command=api
      ;;
  esac
  [ -n "$label_command" ] || return 1

  for label_arg in "$@"; do
    case "$label_command:$label_next_adds:$label_arg" in
      edit:1:*agent:ci-wait*|edit:1:*agent:human-review*|edit:*:--add-label=*agent:ci-wait*|edit:*:--add-label=*agent:human-review*|api:*:*agent:ci-wait*|api:*:*agent:human-review*)
        unset label_command label_next_adds label_arg
        return 0
        ;;
    esac
    case "$label_arg" in --add-label|-l) label_next_adds=1 ;; *) label_next_adds=0 ;; esac
  done
  unset label_command label_next_adds label_arg
  return 1
}
