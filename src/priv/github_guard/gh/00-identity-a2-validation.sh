# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
if [ "${1:-}" = --validate-issue-command ]; then
  validate_only=1
  shift
fi

