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

# `--approve` is not a single spelling. gh accepts `--approve=true`, the short
# `-a`, and short clusters such as `-ab body`, so an exact-literal comparison
# refuses only the most obvious form. The scan must also skip the VALUES of
# value-taking flags, or `gh pr review --comment --body --approve` — a comment
# whose text happens to be `--approve` — is refused as an approval.
approve_flag_in_arguments() {
  approve_options=1
  approve_expect_value=0

  for approve_argument in "$@"; do
    [ "$approve_options" -eq 1 ] || continue

    if [ "$approve_expect_value" -eq 1 ]; then
      approve_expect_value=0
      continue
    fi

    case "$approve_argument" in
      --) approve_options=0 ;;
      --approve|--approve=*)
        unset approve_options approve_expect_value approve_argument approve_cluster
        return 0
        ;;
      --body|--body-file|--repo) approve_expect_value=1 ;;
      --*) : ;;
      -?*)
        # Walk the cluster one letter at a time. A value-taking letter consumes
        # the remainder of the cluster as its inline value (`-Rowner/aiur`), so
        # stop there instead of reading that value as more flags.
        approve_cluster=${approve_argument#-}
        while [ -n "$approve_cluster" ]; do
          case "$approve_cluster" in
            a*)
              unset approve_options approve_expect_value approve_argument approve_cluster
              return 0
              ;;
            b*|F*|R*)
              approve_cluster=${approve_cluster#?}
              [ -n "$approve_cluster" ] || approve_expect_value=1
              approve_cluster=
              ;;
            *) approve_cluster=${approve_cluster#?} ;;
          esac
        done
        ;;
    esac
  done

  unset approve_options approve_expect_value approve_argument approve_cluster
  return 1
}

# gh reads a GraphQL document from a file or standard input as readily as from
# argv. When it does, this process never sees the document, so the mutation-name
# scan below has nothing to match and would admit `addPullRequestReview` with
# the agent's PAT — an approval branch protection does not stop. The guard can
# only permit what it can read, so an unreadable body is a denial.
graphql_body_is_hidden() {
  for deny_argument in "$@"; do
    case "$deny_argument" in
      --input|--input=*|-|query=@*|-Fquery=@*|-F=query=@*|-fquery=@*|-f=query=@*|--field=query=@*|--raw-field=query=@*)
        unset deny_argument
        return 0
        ;;
    esac
  done
  unset deny_argument
  return 1
}

merge_or_approve_command() {
  case "${1:-} ${2:-}" in
    "pr merge") return 0 ;;
    "pr review") approve_flag_in_arguments "$@" && return 0 ;;
    # A manually dispatched workflow runs with `GITHUB_TOKEN` and whatever
    # permissions its YAML claims, entirely outside this guard — including
    # `contents: write`. Dispatching one is a way to ask GitHub to perform the
    # merge on the agent's behalf, so it is the same act as merging.
    "workflow run") return 0 ;;
  esac

  [ "${1:-}" = api ] || return 1

  if [ "$resource" = graphql ]; then
    # This check precedes the read/write gate on purpose: a hidden body makes
    # `direction` unknowable, and it is computed as `read` by default, so
    # gating on it here would skip the denial entirely.
    graphql_body_is_hidden "$@" && return 0
    [ "$direction" = write ] || return 1

    for deny_argument in "$@"; do
      case "$deny_argument" in
        *mergePullRequest*|*addPullRequestReview*|*submitPullRequestReview*|*enablePullRequestAutoMerge*)
          unset deny_argument
          return 0
          ;;
      esac
    done
    unset deny_argument
    return 1
  fi

  # A GET of `.../pulls/N/reviews` is how an agent checks whether review
  # happened; only the write forms are the gate bypass.
  [ "$direction" = write ] || return 1

  deny_endpoint=$(api_command_endpoint "$@") || deny_endpoint=
  deny_endpoint=${deny_endpoint%%\?*}
  deny_endpoint=${deny_endpoint%%\#*}
  deny_endpoint=${deny_endpoint%/}
  case "$deny_endpoint" in
    # `pulls/N/merge` and `pulls/N/reviews` are the direct forms. The rest reach
    # the same result without a pull request at all: `merges` commits a merge
    # onto a branch, a write to `git/refs` moves the protected branch to any
    # commit, and `update-branch` writes to the PR's base-tracking ref.
    */pulls/*/merge|*/pulls/*/reviews|*/pulls/*/reviews/*|*/pulls/*/update-branch|*/merges|*/git/refs|*/git/refs/*)
      unset deny_endpoint
      return 0
      ;;
    # Disarming the gate is as good as passing it. Branch protection and
    # rulesets are what make an agent's bot PAT unable to merge in the first
    # place, so an agent that can rewrite them has removed the control every
    # other denial here depends on.
    */branches/*/protection|*/branches/*/protection/*|*/rulesets|*/rulesets/*)
      unset deny_endpoint
      return 0
      ;;
    # The REST forms of the workflow dispatch denied above, plus
    # `repos/{o}/{r}/dispatches`, which triggers a `repository_dispatch`
    # workflow the same way.
    */actions/workflows/*/dispatches|*/dispatches)
      unset deny_endpoint
      return 0
      ;;
  esac
  unset deny_endpoint
  return 1
}

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

if [ "$admission_required" -eq 1 ] && [ "$budget_required" -eq 1 ] && [ "$budget_enabled" -ne 1 ]; then
  printf 'aiur: GitHub shared budget unavailable (%s; %s); refusing uncoordinated request\n' "$budget_unavailable_reason" "$budget_recovery" >&2
  exit 75
fi

consumer=unattributed
if [ -n "${AIUR_AGENT_WORKSPACE:-}" ]; then
  ticket=$(basename "$AIUR_AGENT_WORKSPACE")
  case "$ticket" in
    ''|*[!0-9]*) ;;
    *) consumer=ticket:$ticket ;;
  esac
fi
