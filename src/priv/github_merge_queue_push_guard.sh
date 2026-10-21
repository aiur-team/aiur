# Spliced into github_push_guard.sh at its `@aiur-merge-queue-push-guard@`
# marker by Aiur.AgentGitHubGuard.GitScript; not a standalone script.
#
# A push to a pull request in the merge queue removes it from the queue, and
# the queue already tests the merge, so a base-refresh push only costs the
# runner pool (#4200). Agent workspaces only: the Executor keeps full push
# authority. A lookup that cannot answer lets the push through.
queue_install=false
case "$(dirname "$0")" in */.aiur-runtime/bin) queue_install=true ;; esac

if [ "$push_command" = true ] && [ "$queue_install" = true ] && [ -x "$(dirname "$0")/gh" ]; then
  queue_branch=$(git_in_context symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  queue_slug=${push_url#https://github.com/}
  queue_slug=${queue_slug%.git}

  queue_refspec=
  queue_hits_branch=false
  queue_target_branch=
  after_push=false

  for arg in "$@"; do
    if [ "$after_push" = false ]; then
      [ "$arg" = push ] && after_push=true
      continue
    fi
    case "$arg" in
      -*) continue ;;
    esac
    [ "$arg" = "$push_target" ] && continue
    queue_refspec=$arg
    queue_normalized_refspec=${arg#+}
    case "$queue_normalized_refspec" in
      *:refs/heads/*)
        queue_target_branch=${queue_normalized_refspec##*:refs/heads/}
        [ -n "$queue_branch" ] && [ "$queue_target_branch" = "$queue_branch" ] && queue_hits_branch=true
        ;;
      *:*) queue_target_branch=${queue_normalized_refspec##*:} ;;
      *)
        queue_target_branch=${queue_normalized_refspec#refs/heads/}
        [ -n "$queue_branch" ] && { [ "$queue_normalized_refspec" = HEAD ] || [ "$queue_normalized_refspec" = "$queue_branch" ]; } && queue_hits_branch=true
        ;;
    esac
  done
  # A push with no refspec pushes the current branch.
  if [ -z "$queue_refspec" ]; then
    queue_hits_branch=true
    queue_target_branch=$queue_branch
  fi

  # Once the ticket is handed off, no worker wake may move the PR head while
  # the reviewer is examining it. Read the live tracker state at push time;
  # rework is the explicit exception after changes were requested. The leaf
  # workspace directory is the tracker issue number (or `pr-<number>` for a
  # watched PR workspace).
  agent_workspace=${AIUR_AGENT_WORKSPACE:-}
  if [ -z "$agent_workspace" ]; then
    agent_workspace=$(CDPATH= cd "$(dirname "$0")/../.." 2>/dev/null && pwd) || agent_workspace=
  fi
  ticket_leaf=${agent_workspace##*/}
  ticket_number=${ticket_leaf#pr-}
  ticket_number=${ticket_number##*-}
  case "$ticket_number" in *[!0-9]* | '') ticket_number= ;; esac
  # In a detached checkout the branch name is absent, but an explicit
  # destination such as HEAD:refs/heads/aiur/5085 remains authoritative. A
  # ticket workspace may only push its own ticket branch while handed off;
  # rescue refs and other non-head refs remain available.
  queue_ticket_branch=false
  [ -n "$queue_branch" ] && [ "$queue_hits_branch" = true ] && queue_ticket_branch=true
  [ -z "$queue_branch" ] && [ -n "$queue_target_branch" ] && case "$queue_target_branch" in refs/*|rescue/*) ;; *) queue_ticket_branch=true ;; esac
  if [ "$queue_ticket_branch" = true ] && [ "$queue_slug" != "$push_url" ] &&
    [ -n "$ticket_number" ]; then
    ticket_state=$("$(dirname "$0")/gh" api "repos/$queue_slug/issues/$ticket_number" --jq '[.labels[].name] | join(" ")' 2>/dev/null || true)
    case " $ticket_state " in
      *" agent:human-review "*|*" agent:ci-wait "*)
        printf '%s\n' "aiur: refusing git push: ticket #$ticket_number is handed off for review or CI" >&2
        printf '%s\n' 'aiur: wait for the review verdict; if GitHub reports the PR CONFLICTING or a reviewer asked for integration, first move the ticket to agent:in-progress with aiur_set_ticket_state, then integrate and push' >&2
        exit 64
        ;;
    esac
  fi

  if [ -n "$queue_branch" ] && [ "$queue_hits_branch" = true ] && [ "$queue_slug" != "$push_url" ]; then
    queue_state=$("$(dirname "$0")/gh" api graphql \
      -f query='query($o:String!,$r:String!,$b:String!){repository(owner:$o,name:$r){pullRequests(headRefName:$b,states:OPEN,first:1){nodes{isInMergeQueue mergeable reviewDecision}}}}' \
      -f o="${queue_slug%%/*}" -f r="${queue_slug#*/}" -f b="$queue_branch" \
      --jq '.data.repository.pullRequests.nodes[0] | "\(.isInMergeQueue) \(.mergeable) \(.reviewDecision)"' 2>/dev/null || true)
    case "$queue_state" in
      'true CONFLICTING '* | 'true '*' CHANGES_REQUESTED') ;;
      'true '*)
        printf '%s\n' "aiur: refusing git push: the pull request for $queue_branch is in the merge queue and a push removes it" >&2
        printf '%s\n' 'aiur: the queue tests the merge itself; push only when GitHub reports the PR CONFLICTING or changes are requested' >&2
        exit 64
        ;;
    esac
  fi
fi
