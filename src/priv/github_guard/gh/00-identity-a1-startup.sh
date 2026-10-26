# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
#!/bin/sh
# @aiur-recursion-guard@
# Fleet guard for agent-launched `gh` calls. The daemon prepends this wrapper's
# directory to agent PATH and supplies the real executable separately.
# #1793: a ticket filed without a dispatch disposition is undispatchable and
# invisible. The repo PreToolUse hook and the agent-suite tests invoke this
# wrapper in validate-only mode to check a `gh` issue command's disposition
# without requiring a real gh executable or touching any quota/budget state.
validate_only=0
