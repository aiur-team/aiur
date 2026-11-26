# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
# ---------------------------------------------------------------------------
# SECURITY INVARIANT — agents never approve or merge a pull request.
#
# The human merge gate is the last irreversible-action control in Aiur: an agent
# that can approve and merge its own PR removes every human from the loop, and
# prompt injection from a public issue body is enough to make it try.
#
# Two facts make this check work where an env-var switch would not:
#
#  1. Agent context is decided by WHERE THIS SCRIPT LIVES, not by an env var.
#     The daemon installs an identical copy at `<workspace>/.aiur-runtime/bin/gh`
#     for agents and at `~/.aiur/bin/gh` for the Executor. `$0` cannot be
#     cleared with `env -u`, so `env -u AIUR_AGENT_WORKSPACE gh pr merge` still
#     lands here as an agent.
#  2. It is paired with a per-agent `GH_CONFIG_DIR` (see
#     `Aiur.AgentGitHubGuard.gh_config_dir/1`), which stops the documented
#     bypass `env -u GITHUB_TOKEN -u GH_TOKEN gh pr review --approve`: with no
#     keyring entry to fall back to, `gh` cannot reach the operator identity in
#     the branch-protection `bypass_actors` list — even when the real `gh` is
#     invoked by absolute path, because it is process environment, not a wrapper.
#
# Reads stay allowed: an agent must still inspect review state and whether a PR
# merged. Only the writes are refused.
# ---------------------------------------------------------------------------
# The redirect belongs to `cd`, not `pwd`: a missing directory must fail this
# command substitution silently instead of writing a shell error to the agent's
# stderr, where it would look like output from the command the agent ran.
guard_self_dir=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd) || guard_self_dir=
agent_guard=0
case "$guard_self_dir" in
  */.aiur-runtime/bin) agent_guard=1 ;;
esac
[ -z "${AIUR_AGENT_WORKSPACE:-}" ] || agent_guard=1
unset guard_self_dir

