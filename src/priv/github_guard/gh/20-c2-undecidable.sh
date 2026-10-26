# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
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

