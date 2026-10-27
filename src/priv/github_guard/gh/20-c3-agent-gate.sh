# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
if [ "$agent_guard" -eq 1 ] && merge_or_approve_command "$@"; then
  printf '%s\n' 'aiur: agents cannot approve or merge pull requests; a human reviewer holds the merge gate' >&2
  exit 77
fi

if update_branch_handoff "$@"; then exit 77; fi

if [ "$agent_guard" -eq 1 ] && undecidable_agent_command "$@"; then
  printf '%s\n' 'aiur: agents cannot rename or hide gh commands from the merge gate; refusing a command this guard cannot inspect' >&2
  exit 77
fi

