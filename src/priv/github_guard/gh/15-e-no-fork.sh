# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
# Agents work in the tracker repository, never on a fork: refuse `gh repo fork`
# and a `gh pr create` whose head names another owner (#7784).
fork_expected=${AIUR_GITHUB_REPO:-}
if [ -n "$fork_expected" ] && [ -n "${AIUR_AGENT_WORKSPACE:-}" ]; then
  fork_refuse=0
  [ "$command_key" = "repo fork" ] && fork_refuse=1
  if [ "$command_key" = "pr create" ]; then
    fork_head=
    fork_next=0
    for fork_arg in "$@"; do
      if [ "$fork_next" -eq 1 ]; then fork_head=$fork_arg; fork_next=0; continue; fi
      case "$fork_arg" in
        --head|-H) fork_next=1 ;;
        --head=*) fork_head=${fork_arg#--head=} ;;
        -H?*) fork_head=${fork_arg#-H} ;;
      esac
    done
    case "$fork_head" in
      *:*)
        fork_owner=$(printf '%s' "${fork_head%%:*}" | tr 'A-Z' 'a-z')
        fork_want=$(printf '%s' "${fork_expected%%/*}" | tr 'A-Z' 'a-z')
        [ "$fork_owner" = "$fork_want" ] || fork_refuse=1
        ;;
    esac
  fi
  if [ "$fork_refuse" -eq 1 ]; then
    printf 'aiur: refusing `gh %s`: agents work only in %s, never on a fork.\n' "$command_key" "$fork_expected" >&2
    printf 'aiur: the agent identity needs push access to %s; report the missing access instead of forking.\n' "$fork_expected" >&2
    exit 64
  fi
fi
