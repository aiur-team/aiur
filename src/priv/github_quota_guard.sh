#!/bin/sh

# Fleet guard for agent-launched `gh` calls. The daemon prepends this wrapper's
# directory to agent PATH and supplies the real executable separately.
# #1793: a ticket filed without a dispatch disposition is undispatchable and
# invisible. The repo PreToolUse hook and the agent-suite tests invoke this
# wrapper in validate-only mode to check a `gh` issue command's disposition
# without requiring a real gh executable or touching any quota/budget state.
validate_only=0
if [ "${1:-}" = --validate-issue-command ]; then
  validate_only=1
  shift
fi

dispatch_prefix=${AIUR_GITHUB_LABEL_PREFIX:-agent}
direct_issue_api=0

real_gh=${AIUR_REAL_GH:-}
is_guard_gh() {
  case "$1" in
    "$HOME/.aiur/bin/gh"|"$HOME/.aiur/github-budget/bin/gh"|*/.aiur-runtime/bin/gh) return 0 ;;
    *) return 1 ;;
  esac
}
if [ -n "$real_gh" ] && is_guard_gh "$real_gh"; then real_gh=; fi
if [ -z "$real_gh" ]; then
  guard_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
  guard_path=${PATH:-}
  guard_old_ifs=$IFS
  IFS=:
  for guard_entry in $guard_path; do
    [ -n "$guard_entry" ] || guard_entry=.
    [ "$guard_entry" = "$guard_dir" ] && continue
    guard_candidate=$guard_entry/gh
    is_guard_gh "$guard_candidate" && continue
    if [ -x "$guard_candidate" ]; then real_gh=$guard_candidate; break; fi
  done
  IFS=$guard_old_ifs
  unset guard_dir guard_path guard_old_ifs guard_entry guard_candidate
fi
if [ "$validate_only" -eq 0 ] && { [ -z "$real_gh" ] || [ ! -x "$real_gh" ]; }; then
  printf '%s\n' 'aiur: real gh executable is unavailable' >&2
  exit 127
fi

state_root=${AIUR_REPO_STATE_PATH:-}
quota_dir=
agent_quota_dir=${AIUR_AGENT_QUOTA_STATE_PATH:-}
events_file=
budget_root=${AIUR_GITHUB_BUDGET_ROOT:-"$HOME/.aiur/github-budget"}
budget_key=${AIUR_GITHUB_BUDGET_KEY:-}
budget_broker=${AIUR_GITHUB_BUDGET_BROKER:-"$(dirname "$0")/aiur-github-budget"}
budget_requested=${AIUR_GITHUB_BUDGET_ENABLED:-1}
budget_db=
budget_enabled=0
budget_required=0
budget_unavailable_reason=
budget_lease=
budget_renewal_pid=
budget_lease_ttl_ms=${AIUR_GITHUB_LEASE_TTL_MS:-35000}
budget_ignore_token_cooldown=0
budget_consumer=${AIUR_GITHUB_BUDGET_CONSUMER:-"executor:${PPID:-$$}"}
budget_consumer_key=

case "$budget_requested" in
  0|false|FALSE|no|NO|off|OFF) budget_required=0 ;;
  *) [ -n "$budget_root" ] && budget_required=1 ;;
esac
unset budget_requested

fingerprint_value() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

if [ -n "$state_root" ]; then
  quota_dir=$state_root/github-quota
  mkdir -p "$quota_dir" 2>/dev/null || true
fi

if [ -z "$agent_quota_dir" ]; then agent_quota_dir=$quota_dir; fi
if [ -n "$agent_quota_dir" ]; then
  events_file=$agent_quota_dir/agent-requests.tsv
  mkdir -p "$agent_quota_dir" 2>/dev/null || true
fi

if [ "$budget_required" -eq 1 ]; then
  if [ -z "$budget_broker" ] || [ ! -x "$budget_broker" ]; then
    budget_unavailable_reason='broker executable is unavailable'
  elif ! command -v python3 >/dev/null 2>&1; then
    budget_unavailable_reason='python3 is unavailable'
  elif ! mkdir -p "$budget_root" 2>/dev/null; then
    budget_unavailable_reason='state directory is unavailable'
  else
    if [ -z "$budget_key" ]; then
      budget_token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
      if [ -z "$budget_token" ]; then
        budget_token=$(GITHUB_TOKEN= GH_TOKEN= "$real_gh" auth token --hostname github.com 2>/dev/null || true)
      fi

      if [ -z "$budget_token" ]; then
        budget_unavailable_reason='GitHub credential is unavailable'
      else
        budget_key=$(fingerprint_value "$budget_token") || budget_key=
        [ -n "$budget_key" ] || budget_unavailable_reason='credential fingerprint is unavailable'
      fi
      unset budget_token
    fi

    if [ -z "$budget_unavailable_reason" ]; then
      budget_db=$budget_root/budget.sqlite3
      budget_enabled=1
    fi
  fi
fi

if [ "$budget_enabled" -eq 1 ]; then
  budget_consumer_key=$(fingerprint_value "$budget_consumer") || budget_consumer_key=
  [ -n "$budget_consumer_key" ] || budget_consumer_key=shared
fi
unset budget_consumer

direction=read
track=1
resource=unknown
admission_required=1
admission_resource=unknown
endpoint_family=rest
api_paginated=0

api_command_endpoint() {
  shift
  api_options=1
  api_value_expected=0

  for api_argument in "$@"; do
    if [ "$api_options" -eq 0 ]; then
      printf '%s\n' "$api_argument"
      unset api_options api_value_expected api_argument
      return 0
    fi

    if [ "$api_value_expected" -eq 1 ]; then
      api_value_expected=0
      continue
    fi

    case "$api_argument" in
      --) api_options=0 ;;
      --cache|-F|--field|-f|--raw-field|-H|--header|--hostname|--input|-q|--jq|-X|--method|-p|--preview|-t|--template) api_value_expected=1 ;;
      --cache=*|--field=*|--raw-field=*|--header=*|--hostname=*|--input=*|--jq=*|--method=*|--preview=*|--template=*|-F*|-f*|-H*|-q*|-X*|-p*|-t*) : ;;
      --*) : ;;
      -*) : ;;
      *)
        printf '%s\n' "$api_argument"
        unset api_options api_value_expected api_argument
        return 0
        ;;
    esac
  done

  unset api_options api_value_expected api_argument
  return 1
}

case "${1:-} ${2:-}" in
  "api rate_limit") resource=none; endpoint_family=rate_limit ;;
  "api graphql"|"api /graphql")
    resource=graphql
    endpoint_family=graphql
    api_options=1
    for arg in "$@"; do
      if [ "$api_options" -eq 1 ] && [ "$arg" = -- ]; then
        api_options=0
        continue
      fi
      [ "$api_options" -eq 1 ] || continue
      case "$arg" in
        *mutation*|*Mutation*) direction=write ;;
        --paginate|--paginate=true) api_paginated=1 ;;
      esac
    done
    unset api_options
    ;;
  "api "*)
    resource=core
    endpoint=${2#/}
    endpoint=${endpoint#repos/}
    endpoint=${endpoint%%\?*}
    endpoint=${endpoint%%\#*}
    case "$endpoint" in
      */*/*) endpoint_family=$(printf '%s' "$endpoint" | cut -d/ -f3) ;;
      *) endpoint_family=rest ;;
    esac
    prior=
    api_options=1
    for arg in "$@"; do
      if [ "$api_options" -eq 1 ] && [ "$arg" = -- ]; then
        api_options=0
        continue
      fi
      [ "$api_options" -eq 1 ] || continue
      if [ "$prior" = -X ] || [ "$prior" = --method ]; then
        case "$arg" in GET|get) ;; *) direction=write ;; esac
      fi
      case "$arg" in
        -XPOST|-XPATCH|-XPUT|-XDELETE|--method=POST|--method=PATCH|--method=PUT|--method=DELETE|-f|-F|--field|--raw-field|--field=*|--raw-field=*) direction=write ;;
        --paginate|--paginate=true) api_paginated=1 ;;
      esac
      prior=$arg
    done
    unset api_options
    ;;
  "pr view"|"pr list"|"pr status"|"pr checks"|"pr diff") endpoint_family=pulls ;;
  "issue view"|"issue list"|"issue status") endpoint_family=issues ;;
  "run view"|"run list"|"run watch") endpoint_family=actions ;;
  "search "*) endpoint_family=search ;;
  "pr "*) endpoint_family=pulls; direction=write ;;
  "issue "*) endpoint_family=issues; direction=write ;;
  "run rerun"|"run cancel"|"run delete") endpoint_family=actions; direction=write ;;
  "label create"|"label delete"|"label edit") endpoint_family=labels; direction=write ;;
  "config "*|"alias "*|"completion "*|"help "*|"version "*) track=0; resource=none; admission_required=0 ;;
  "auth token") track=0; resource=none; admission_required=0 ;;
  "auth "*|"extension "*) track=0 ;;
esac

# `gh api` accepts options before its endpoint. Derive the resource family from
# that actual endpoint so a paginated `gh api -X GET repos/.../issues` uses the
# same per-endpoint ceiling as its unflagged form.
if [ "${1:-}" = api ]; then
  resolved_api_endpoint=$(api_command_endpoint "$@") || resolved_api_endpoint=

  case "$resolved_api_endpoint" in
    rate_limit)
      resource=none
      endpoint_family=rate_limit
      ;;
    graphql|/graphql)
      resource=graphql
      endpoint_family=graphql
      ;;
    *)
      resource=core
      resolved_endpoint=${resolved_api_endpoint#/}
      resolved_endpoint=${resolved_endpoint#repos/}
      resolved_endpoint=${resolved_endpoint%%\?*}
      resolved_endpoint=${resolved_endpoint%%\#*}
      case "$resolved_endpoint" in
        */*/*) endpoint_family=$(printf '%s' "$resolved_endpoint" | cut -d/ -f3) ;;
        *) endpoint_family=rest ;;
      esac
      unset resolved_endpoint
      ;;
  esac

  unset resolved_api_endpoint
fi

# Fields imply POST only when the caller did not explicitly select a method.
# Recompute this after locating the endpoint so `gh api -X GET ... -f q=...`
# remains a budgeted read instead of being rejected as a paginated write.
if [ "${1:-}" = api ]; then
  api_options=1
  api_method=
  api_payload=0
  api_mutation=0
  api_method_expected=0

  for api_argument in "$@"; do
    [ "$api_options" -eq 1 ] || continue

    if [ "$api_method_expected" -eq 1 ]; then
      api_method=$api_argument
      api_method_expected=0
      continue
    fi

    case "$api_argument" in
      --) api_options=0 ;;
      -X|--method) api_method_expected=1 ;;
      -X*) api_method=${api_argument#-X} ;;
      --method=*) api_method=${api_argument#--method=} ;;
      -F|-f|--field|--raw-field|--input|--input=*) api_payload=1 ;;
      -F*|-f*|--field=*|--raw-field=*) api_payload=1 ;;
      *mutation*|*Mutation*) api_mutation=1 ;;
    esac
  done

  case "$resource" in
    graphql)
      [ "$api_mutation" -eq 1 ] && direction=write || direction=read
      ;;
    *)
      case "$api_method" in
        GET|get) direction=read ;;
        '') [ "$api_payload" -eq 1 ] && direction=write || direction=read ;;
        *) direction=write ;;
      esac
      ;;
  esac

  unset api_options api_method api_payload api_mutation api_method_expected api_argument
fi

# #1793: direct GitHub issue API creation bypasses the `issue create`
# disposition enforcement below, so refuse it outright and point at the
# sanctioned path. Detect both REST issue endpoints and GraphQL `createIssue`
# mutations, including file- and stdin-backed GraphQL bodies. Paginated calls
# are owned by the pagination guard below, which already refuses every
# paginated write and non-replayable body, so leave those to it.
if [ "${1:-}" = api ] && [ "$api_paginated" -eq 0 ]; then
  for direct_arg in "$@"; do
    case "$direct_arg" in
      *createIssue*|*CreateIssue*) direct_issue_api=1 ;;
    esac
  done

  if [ "$direct_issue_api" -eq 0 ]; then
    direct_endpoint=$(api_command_endpoint "$@") || direct_endpoint=
    case "$direct_endpoint" in
      # The collection endpoint, optionally with a trailing slash, query string,
      # or fragment. `?` is escaped so it matches a literal `?`: unescaped it is
      # a glob wildcard, which made this arm claim every issue *subresource*
      # too — `issues/comments/<id>` most visibly, so an agent could not PATCH
      # its own workpad comment and was told to run `gh issue create` instead.
      # The #1793 guard is about creating issues, not about editing one.
      *repos/*/*/issues|*repos/*/*/issues/|\
      *repos/*/*/issues\?*|*repos/*/*/issues/\?*|\
      *repos/*/*/issues#*|*repos/*/*/issues/#*)
        direct_method=
        direct_payload=0
        direct_method_expected=0
        for direct_arg in "$@"; do
          [ "$direct_method_expected" -eq 1 ] && { direct_method=$direct_arg; direct_method_expected=0; continue; }
          case "$direct_arg" in
            --) break ;;
            -X|--method) direct_method_expected=1 ;;
            -XGET|-X=GET|--method=GET|-Xget|-X=get|--method=get) direct_method=get ;;
            -XPOST|-X=POST|--method=POST|-Xpost|-X=post|--method=post) direct_method=post ;;
            -X*) direct_method=${direct_arg#-X} ;;
            --method=*) direct_method=${direct_arg#--method=} ;;
            -F|-f|--field|--raw-field|--input|--input=*) direct_payload=1 ;;
            -F*|-f*|--field=*|--raw-field=*) direct_payload=1 ;;
          esac
        done
        case "$direct_method" in
          =*) direct_method=${direct_method#=} ;;
        esac
        case "$direct_method" in
          GET|get) ;;
          '') [ "$direct_payload" -eq 1 ] && direct_issue_api=1 ;;
          *) direct_issue_api=1 ;;
        esac
        ;;
    esac
  fi

  # File- and stdin-backed GraphQL bodies are opaque to the argv scan above.
  if [ "$direct_issue_api" -eq 0 ]; then
    direct_graphql_file=
    direct_prior=
    for direct_arg in "$@"; do
      case "$direct_prior" in
        --input) direct_graphql_file=$direct_arg ;;
      esac
      case "$direct_arg" in
        --input=*) direct_graphql_file=${direct_arg#--input=} ;;
        query=@*|-Fquery=@*|-F=query=@*|-fquery=@*|-f=query=@*|--field=query=@*|--raw-field=query=@*) direct_graphql_file=${direct_arg#*@} ;;
      esac
      direct_prior=$direct_arg
    done
    if [ -n "$direct_graphql_file" ]; then
      case "$direct_graphql_file" in
        @*) direct_graphql_file=${direct_graphql_file#@} ;;
      esac
      # Only a body this process can read AND prove creates an issue is
      # claimed by the #1793 guard. A stdin, unreadable, or otherwise opaque
      # body cannot be confirmed as issue creation, so it is left to the
      # pre-existing merge gate, which denies every unreadable GraphQL body
      # outright because it cannot rule out a merge. Claiming an opaque body
      # here would mislabel a possible merge as issue creation.
      if [ -f "$direct_graphql_file" ] && grep -q 'createIssue' "$direct_graphql_file" 2>/dev/null; then
        direct_issue_api=1
      fi
    fi
  fi
fi

if [ "$direct_issue_api" -eq 1 ]; then
  printf '%s\n' 'aiur: refusing direct GitHub issue API creation (#1793).' >&2
  printf '%s\n' 'aiur: use `gh issue create --label ...` so the dispatch disposition is explicit and enforceable.' >&2
  exit 78
fi

dispatch_disposition() {
  label=$1
  case "$label" in
    "$dispatch_prefix:todo"|human:todo|needs-triage|build-order|epic) return 0 ;;
    *) return 1 ;;
  esac
}

# #1793: a ticket created without a lifecycle label is undispatchable AND
# invisible - no agent can claim it and it appears in no state-scoped view, so
# it reads to the operator as "no work left". 29 accumulated in one run. The
# skills tell every filing path to set the disposition in the same request;
# this refuses the call that does not, because an unlabelled issue that already
# exists cannot be un-filed. Hierarchy that is deliberately not runnable
# (Build Order roots, epics) and deliberately parked work still pass by naming
# their own disposition.
command_name=
subcommand_name=
# The third positional word, which is where `gh pr view 2073` and its siblings
# put the resource number. The shared-state cache below reads the identity from
# exactly this position and from nowhere else, so a rarer spelling such as
# `gh pr view --json body 2073` resolves to no identity and is simply not
# cached. Guessing a position instead would risk keying a response under the
# wrong number, and a wrong cached shape is worse than a cache miss.
positional_three=
positional_count=0
skip_root_value=0
for arg in "$@"; do
  if [ "$skip_root_value" -eq 1 ]; then
    skip_root_value=0
    continue
  fi
  case "$arg" in
    -R|--repo|--hostname) skip_root_value=1; continue ;;
    -R?*|--repo=*|--hostname=*) continue ;;
  esac
  positional_count=$((positional_count + 1))
  case "$positional_count" in
    1) command_name=$arg ;;
    2) subcommand_name=$arg ;;
    *) positional_three=$arg; break ;;
  esac
done
unset positional_count
command_key="$command_name $subcommand_name"

if [ "$command_key" = "issue create" ]; then
  disposition=0
  prior=
  for arg in "$@"; do
    label_value=
    case "$arg" in
      --label=*) label_value=${arg#--label=} ;;
      -l?*) label_value=${arg#-l} ;;
      *)
        case "$prior" in
          --label|-l) label_value=$arg ;;
        esac
        ;;
    esac
    prior=$arg
    [ -n "$label_value" ] || continue
    # `gh` accepts repeated flags and comma-separated lists in one flag.
    old_ifs=$IFS
    IFS=,
    for label in $label_value; do
      if dispatch_disposition "$label"; then disposition=1; fi
    done
    IFS=$old_ifs
  done

  if [ "$disposition" -eq 0 ]; then
    printf '%s\n' 'aiur: refusing `gh issue create` with no dispatch disposition (#1793).' >&2
    printf '%s\n' 'aiur: an unlabelled ticket is undispatchable and invisible, so it reads as no work left.' >&2
    printf 'aiur: pass --label %s:todo for executable work, or --label needs-triage / human:todo\n' "$dispatch_prefix" >&2
    printf '%s\n' 'aiur: to park it deliberately, or --label build-order / epic for a non-runnable container.' >&2
    exit 78
  fi
fi

if [ "$validate_only" -eq 1 ]; then exit 0; fi

admission_resource=$resource
[ "$admission_resource" != none ] || admission_resource=core

# ---------------------------------------------------------------------------
# SECURITY INVARIANT — agents never approve or merge a pull request.
#
# The human merge gate is the last irreversible-action control in Aiur. An agent
# that can approve its own PR and merge it has removed every human from the
# loop, and prompt injection from a public issue body is enough to make it try.
#
# Two facts make this check work where an env-var switch would not:
#
#  1. Agent context is decided by WHERE THIS SCRIPT LIVES, not by an env var.
#     The daemon installs an identical copy at `<workspace>/.aiur-runtime/bin/gh`
#     for agents and at `~/.aiur/bin/gh` for the Executor. `$0` cannot be
#     cleared with `env -u`, so `env -u AIUR_AGENT_WORKSPACE gh pr merge` still
#     lands here as an agent.
#  2. It is paired with a per-agent `GH_CONFIG_DIR` (see
#     `Aiur.AgentGitHubGuard.gh_config_dir/1`). That is what stops the real
#     documented bypass, `env -u GITHUB_TOKEN -u GH_TOKEN gh pr review
#     --approve`, which made `gh` fall back to the operator keyring — the one
#     identity in the branch-protection `bypass_actors` list. With an empty
#     agent-private config dir there is no keyring entry to fall back to, and
#     that holds even when the real `gh` binary is invoked by absolute path,
#     because it is process environment rather than a wrapper.
#
# Reads stay allowed: an agent must still be able to inspect review state and
# check whether a PR merged. Only the writes are refused.
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
# the agent's PAT — an approval, which branch protection does not stop. The
# guard can only permit what it can read, so an unreadable body is a denial.
graphql_body_is_hidden() {
  for deny_argument in "$@"; do
    case "$deny_argument" in
      --input|--input=*|*=@*|-)
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

# The denylist keys on the command name, so anything that renames a command
# defeats it: `gh alias set zz "pr merge"` followed by `gh zz 7` arrives here as
# `zz`, matches nothing, and is admitted. The per-workspace `GH_CONFIG_DIR` that
# closes the keyring bypass also hands the agent a writable place to store that
# alias. Refusing alias mutation removes the write half; refusing an unknown
# command name removes the read half, and covers aliases the agent did not have
# to create. An unrecognised name is not a command this guard has decided is
# safe — it is a command this guard cannot decide about at all.
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

if [ "$agent_guard" -eq 1 ] && undecidable_agent_command "$@"; then
  printf '%s\n' 'aiur: agents cannot rename or hide gh commands from the merge gate; refusing a command this guard cannot inspect' >&2
  exit 77
fi

if [ "$admission_required" -eq 1 ] && [ "$budget_required" -eq 1 ] && [ "$budget_enabled" -ne 1 ]; then
  printf 'aiur: GitHub shared budget unavailable (%s); refusing uncoordinated request\n' "$budget_unavailable_reason" >&2
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

# ---------------------------------------------------------------------------
# SHARED GITHUB STATE CACHE (#2073 U6)
#
# The broker above rations permission to spend. It stores no answers, so
# sixteen agents asking about one pull request take sixteen leases and pay
# sixteen times. This section serves the answer instead, from a store shared by
# every agent on the host.
#
# Three rules govern everything below.
#
#  1. REPLAY BYTES, NEVER RECONSTRUCT THEM. A hit writes back the exact stdout
#     the real `gh` produced for an invocation whose output-affecting arguments
#     hash identically — `--json` field set, `--jq` expression, `--template`,
#     and whether stdout is a terminal. Nothing is re-serialised, re-filtered or
#     re-ordered, so `gh pr view N --json body -q .body` is byte-identical to
#     the uncached path by construction rather than by careful imitation. A
#     wrong shape silently corrupts agent input, which is worse than paying for
#     the call.
#
#  2. THE ENTRY IS KEYED BY RESOURCE IDENTITY; THE SHAPE ONLY NAMES THE FILE.
#     `<owner>/<repo>/<kind>/<id>/<shape>` — so a mutation, or a later daemon
#     writer, invalidates every shape of a resource by touching one marker in
#     its directory, without knowing which shapes exist.
#
#  3. ANY DOUBT FALLS THROUGH. An unrecognised command, an unknown repository, a
#     missing or unwritable store, an unparseable entry, a non-zero exit — all
#     of them leave `$cache_body` empty and the call proceeds exactly as it does
#     today. The cache may cost throughput when it fails. It may never cost
#     correctness.
#
# WHAT THIS IS NOT. Entries are written mode 600 under a 700 directory, which
# keeps other local users out, but every agent runs as the SAME OS user and
# therefore may write here — exactly as they may already write the shared budget
# database beside it. An agent that goes looking can plant a response another
# agent then reads. This is the same policy-not-capability boundary documented
# on `Aiur.AgentGitHubGuard.gh_config_dir/1`, and it is not widened here: an
# agent able to do that can already write the other agent's workspace. Real
# containment needs a separate UID per agent.
# ---------------------------------------------------------------------------

# The store sits beside the budget broker's database because that is already the
# one directory every agent on a host shares. It is derived from the RAW
# environment variable rather than from `$budget_root`, which defaults to
# `$HOME/.aiur/github-budget` when unset — deriving from the default would give
# a test harness that deliberately clears the budget root a live cache in the
# operator's own home directory.
cache_root=${AIUR_GITHUB_STATE_CACHE_ROOT:-}
if [ -z "$cache_root" ] && [ -n "${AIUR_GITHUB_BUDGET_ROOT:-}" ]; then
  cache_root=${AIUR_GITHUB_BUDGET_ROOT%/}/state-cache
fi
case "$cache_root" in
  /*) ;;
  *) cache_root= ;;
esac
case "${AIUR_GITHUB_STATE_CACHE_ENABLED:-1}" in
  0|false|FALSE|no|NO|off|OFF) cache_root= ;;
esac

# R10's strict-freshness bypass. A caller that must not be served stale — a
# merge decision, a CI verdict — sets this and pays for the round trip. Writes
# still invalidate, so the bypass never leaves a stale entry behind it.
cache_bypass=0
case "${AIUR_GITHUB_STATE_CACHE_BYPASS:-0}" in
  1|true|TRUE|yes|YES|on|ON) cache_bypass=1 ;;
esac

# Seconds, because that is the resolution `date` gives without a subprocess per
# comparison. A window below one second is not expressible and rounds to zero,
# which still serves an entry written in the same second — so the setting is
# documented in whole seconds and a sub-second value is treated as "off" here
# rather than pretending to a precision the entry stamps do not carry.
cache_ttl=${AIUR_GITHUB_STATE_CACHE_TTL_MS:-60000}
case "$cache_ttl" in ''|*[!0-9]*) cache_ttl=60000 ;; esac
if [ "$cache_ttl" -lt 1000 ]; then
  cache_root=
  cache_ttl=0
else
  cache_ttl=$((cache_ttl / 1000))
fi
cache_max_bytes=${AIUR_GITHUB_STATE_CACHE_MAX_BYTES:-1048576}
case "$cache_max_bytes" in ''|*[!0-9]*) cache_max_bytes=1048576 ;; esac

cache_owner=
cache_repo_name=
cache_kind=
cache_id=
cache_write_id=
cache_collection=0
cache_repo_dir=
cache_entry_dir=
cache_body=
cache_meta=
cache_stage=
cache_started_at=
cache_events_file=
cache_shape=

# `shasum`/`sha256sum` are how a shape becomes a filename. Without one there is
# no cache at all, which is the same safe no-op as an unset root.
cache_fingerprint() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | cut -d' ' -f1
  else
    return 1
  fi
}

cache_valid_digest() {
  case "$1" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 64 ]
}

# Every argument is length-prefixed so no two argument vectors can serialise to
# the same bytes — `["a b"]` and `["a", "b"]` must not share an entry. The
# terminal and colour variables join them because `gh` renders differently on a
# TTY, and an entry written by a piped agent must never be replayed to an
# interactive Executor shell as if it were the same request.
#
# `cache_tty` is sampled at the top level rather than inside this function
# because the function's own stdout is the fingerprint pipe, where `[ -t 1 ]`
# is false for every caller and would record nothing.
cache_tty=0
[ -t 1 ] && cache_tty=1

cache_material() {
  printf 'aiur-gh-cache/v2\n%s\n' "$cache_tty"
  # The credential the answer was fetched with. Everything else the broker keeps
  # — budgets, leases, cooldowns — is already keyed by this fingerprint, and a
  # response body is more identity-dependent than any of them: a private
  # repository one token cannot see, the `permissions` object, a collaborator
  # list. Two identities sharing one store must not share one answer.
  printf '%s\n' "${budget_key:-unkeyed}"
  printf '%s\n%s\n%s\n%s\n%s\n' "${NO_COLOR-}" "${CLICOLOR-}" "${CLICOLOR_FORCE-}" "${GH_FORCE_TTY-}" "${COLUMNS-}"
  printf '%s\n%s\n%s\n' "${GH_HOST-}" "${GH_REPO-}" "$#"
  for cache_arg in "$@"; do
    printf '%s\n%s\n' "${#cache_arg}" "$cache_arg"
  done
  unset cache_tty cache_arg
}

cache_valid_slug() {
  case "$1" in
    *[!A-Za-z0-9./_-]*|*..*|.*|*/) return 1 ;;
    */*/*) return 1 ;;
    ?*/?*) return 0 ;;
  esac
  return 1
}

cache_numeric() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 12 ]
}

# `https://github.com/OWNER/REPO/pull/2073` names its repository and its number
# outright, so it is a stronger identity than the inferred slug below and
# overrides it. Parsed with parameter expansion only — no subprocess.
cache_read_url_identity() {
  case "$1" in
    https://github.com/*/*/pull/*|https://github.com/*/*/pulls/*|https://github.com/*/*/issues/*) ;;
    *) return 1 ;;
  esac

  cache_url_rest=${1#https://github.com/}
  cache_url_owner=${cache_url_rest%%/*}
  cache_url_rest=${cache_url_rest#*/}
  cache_url_repo=${cache_url_rest%%/*}
  cache_url_rest=${cache_url_rest#*/}
  cache_url_type=${cache_url_rest%%/*}
  cache_url_number=${cache_url_rest#*/}
  cache_url_number=${cache_url_number%%/*}
  cache_url_number=${cache_url_number%%\?*}
  cache_url_number=${cache_url_number%%\#*}

  if cache_valid_slug "$cache_url_owner/$cache_url_repo" && cache_numeric "$cache_url_number"; then
    cache_owner=$cache_url_owner
    cache_repo_name=$cache_url_repo
    cache_id=$cache_url_number
    case "$cache_url_type" in
      issues) cache_kind=issue ;;
      *) cache_kind=pr ;;
    esac
    unset cache_url_rest cache_url_owner cache_url_repo cache_url_type cache_url_number
    return 0
  fi

  unset cache_url_rest cache_url_owner cache_url_repo cache_url_type cache_url_number
  return 1
}

if [ -n "$cache_root" ]; then
  # `--hostname` and `GH_HOST` move the request to another GitHub deployment
  # whose numbering is unrelated. Nothing is cached for those.
  cache_hostname_override=0
  for cache_arg in "$@"; do
    case "$cache_arg" in
      --hostname|--hostname=*) cache_hostname_override=1 ;;
    esac
  done
  case "${GH_HOST:-github.com}" in
    github.com) ;;
    *) cache_hostname_override=1 ;;
  esac
  [ "$cache_hostname_override" -eq 0 ] || cache_root=
  unset cache_hostname_override cache_arg
fi

if [ -n "$cache_root" ]; then
  # Repository identity, most explicit source first. The workspace anchor is
  # the subtle one: `AIUR_GITHUB_REPO` is the repo the daemon dispatched this
  # agent against, and `gh` resolves the repo from the working directory, so the
  # two only agree while the agent is inside its own workspace. An agent that
  # cloned something else and ran `gh pr view 5` there would otherwise have its
  # answer filed under the wrong repository — so that case resolves to no
  # identity and is not cached.
  cache_flag_repo=
  cache_prior=
  for cache_arg in "$@"; do
    case "$cache_prior" in
      -R|--repo) cache_flag_repo=$cache_arg ;;
    esac
    case "$cache_arg" in
      -R?*) cache_flag_repo=${cache_arg#-R} ;;
      --repo=*) cache_flag_repo=${cache_arg#--repo=} ;;
    esac
    cache_prior=$cache_arg
  done

  cache_slug=
  if [ -n "$cache_flag_repo" ]; then
    cache_slug=$cache_flag_repo
  elif [ -n "${GH_REPO:-}" ]; then
    cache_slug=$GH_REPO
  elif [ -n "${AIUR_GITHUB_REPO:-}" ] && [ -n "${AIUR_AGENT_WORKSPACE:-}" ]; then
    case "${PWD:-}" in
      "$AIUR_AGENT_WORKSPACE"|"$AIUR_AGENT_WORKSPACE"/*) cache_slug=$AIUR_GITHUB_REPO ;;
    esac
  fi

  if cache_valid_slug "$cache_slug"; then
    cache_owner=${cache_slug%%/*}
    cache_repo_name=${cache_slug#*/}
  fi

  unset cache_flag_repo cache_prior cache_arg cache_slug
fi

# The `--json` fields whose value is a verdict rather than a fact: CI state, and
# whether a pull request can be merged. `gh pr checks` is excluded from the
# cacheable commands below for the same reason — and would have been unsafe in a
# second way, because it exits 1 for a failure and 8 for pending while only a
# zero-status response is ever stored, so the only verdict it could ever replay
# is "everything passed".
cache_volatile_fields() {
  case ",$1," in
    *,statusCheckRollup,*|*,mergeable,*|*,mergeStateStatus,*|*,mergeCommit,*|\
    *,reviewDecision,*|*,latestReviews,*|*,reviews,*|*,state,*|*,merged,*|*,mergedAt,*|\
    *,closed,*|*,closedAt,*|*,headRefOid,*|*,commits,*) return 0 ;;
  esac
  return 1
}

# The output shapes this guard serves. Everything absent from this list — a
# bare `gh pr view` with no number, `gh pr diff`, `gh api graphql`, every write
# — falls through to the real `gh` untouched.
#
# `--json` is required for the high-level commands on purpose. Without it `gh`
# prints a human table containing relative timestamps and terminal-width
# layout, which is neither stable across two agents nor meaningful to replay.
if [ -n "$cache_root" ]; then
  cache_has_json=0
  cache_has_web=0
  cache_has_payload=0
  cache_volatile=0
  cache_options=1
  cache_expect_value=0
  cache_json_expected=0

  for cache_arg in "$@"; do
    [ "$cache_options" -eq 1 ] || break

    if [ "$cache_json_expected" -eq 1 ]; then
      cache_json_expected=0
      cache_expect_value=0
      cache_volatile_fields "$cache_arg" && cache_volatile=1
      continue
    fi

    if [ "$cache_expect_value" -eq 1 ]; then
      cache_expect_value=0
      continue
    fi

    case "$cache_arg" in
      --) cache_options=0 ;;
      --json|--jq|-q|--template|-t|--repo|-R|--hostname|--interval|-i|--limit|-L|--label|-l|\
      --assignee|-a|--author|-A|--search|-S|--state|-s|--base|-B|--head|-H|--milestone|-m|\
      --app|--mention|--cache|--header|--method|-X|--preview|-p)
        case "$cache_arg" in
          --json) cache_has_json=1; cache_json_expected=1 ;;
        esac
        cache_expect_value=1
        ;;
      --json=*)
        cache_has_json=1
        cache_volatile_fields "${cache_arg#--json=}" && cache_volatile=1
        ;;
      --web|-w) cache_has_web=1 ;;
      -F|-f|--field|--raw-field|--input) cache_has_payload=1; cache_expect_value=1 ;;
      -F*|-f*|--field=*|--raw-field=*|--input=*|*=@*|-) cache_has_payload=1 ;;
    esac
  done

  # R10. A merge decision and a CI verdict may not be served stale, ever, and
  # neither may be repaired after the fact: an agent that reads "all green" for a
  # commit CI has not seen, or "mergeable" for a branch that has moved, has
  # already acted on it. Nothing invalidates these either — `git push` and a
  # check run completing never pass through this wrapper — so the freshness
  # window is the ONLY thing standing between the read and a wrong answer. These
  # field names are therefore refused outright rather than given a short window.
  [ "$cache_volatile" -eq 0 ] || cache_root=

  case "$command_key" in
    "pr view"|"issue view")
      if [ "$cache_has_json" -eq 1 ] && [ "$cache_has_web" -eq 0 ] && [ -n "$positional_three" ]; then
        if cache_numeric "$positional_three"; then
          cache_id=$positional_three
          case "$command_name" in
            pr) cache_kind=pr ;;
            *) cache_kind=issue ;;
          esac
        else
          cache_read_url_identity "$positional_three" || cache_id=
        fi
      fi
      ;;
    "pr list"|"issue list")
      if [ "$cache_has_json" -eq 1 ] && [ "$cache_has_web" -eq 0 ]; then
        cache_id=list
        cache_collection=1
        case "$command_name" in
          pr) cache_kind=pr ;;
          *) cache_kind=issue ;;
        esac
      fi
      ;;
    "api "*|"api")
      # REST GETs of a repository-scoped endpoint only. GraphQL is excluded:
      # its identity is an arbitrary document rather than a resource, so an
      # entry could not be invalidated by the resource writers above. Paginated
      # reads are excluded here and cached one page at a time, because the
      # pagination path re-enters this guard per page.
      if [ "$direction" = read ] && [ "$resource" = core ] && [ "$api_paginated" -eq 0 ] && [ "$cache_has_payload" -eq 0 ]; then
        cache_endpoint=$(api_command_endpoint "$@") || cache_endpoint=
        cache_endpoint=${cache_endpoint#/}
        case "$cache_endpoint" in
          repos/*/*/*|repos/*/*)
            cache_api_rest=${cache_endpoint#repos/}
            cache_api_owner=${cache_api_rest%%/*}
            cache_api_rest=${cache_api_rest#*/}
            cache_api_repo=${cache_api_rest%%/*}
            if cache_valid_slug "$cache_api_owner/$cache_api_repo"; then
              cache_owner=$cache_api_owner
              cache_repo_name=$cache_api_repo

              # An endpoint that NAMES a resource is filed under that resource,
              # not under the endpoint. `repos/o/r/pulls/1670` and
              # `gh pr view 1670 --json body` are the same pull request, so a
              # writer retiring pull request 1670 must retire both — and it
              # cannot, if one of them is filed under a digest of a URL the
              # writer has never seen. The endpoint still separates the two
              # entries, because every argument is hashed into the shape.
              cache_api_number=
              case "$cache_api_rest" in
                */issues/*|*/pulls/*)
                  cache_api_tail=${cache_api_rest#*/}
                  case "$cache_api_tail" in
                    issues/*) cache_api_kind=issue; cache_api_tail=${cache_api_tail#issues/} ;;
                    pulls/*) cache_api_kind=pr; cache_api_tail=${cache_api_tail#pulls/} ;;
                    *) cache_api_kind= ;;
                  esac
                  cache_api_number=${cache_api_tail%%/*}
                  if [ -n "$cache_api_kind" ] && cache_numeric "$cache_api_number"; then
                    cache_kind=$cache_api_kind
                    cache_id=$cache_api_number
                  fi
                  unset cache_api_tail cache_api_kind
                  ;;
              esac

              if [ -z "$cache_id" ]; then
                # An endpoint naming no single resource — a list, a search, a
                # repository-level read. Filed under the endpoint and treated as a
                # collection, so a write anywhere in the repository retires it.
                cache_kind=api
                cache_collection=1
                cache_id=$(printf '%s' "$cache_endpoint" | cache_fingerprint) || cache_id=
                cache_valid_digest "$cache_id" || cache_id=
              fi
              unset cache_api_number
            fi
            unset cache_api_rest cache_api_owner cache_api_repo
            ;;
        esac
        unset cache_endpoint
      fi
      ;;
  esac

  unset cache_has_json cache_has_web cache_has_payload cache_volatile cache_options cache_expect_value \
    cache_json_expected cache_arg
fi

# The number a write mutates. Pull requests and issues share one number space on
# GitHub, so a comment posted through `gh issue comment 2073` changes what
# `gh pr view 2073 --json comments` would answer. Both directories are marked.
case "$command_key" in
  "pr create"|"issue create") cache_write_id=collection ;;
  "pr "*|"issue "*)
    if cache_numeric "$positional_three"; then cache_write_id=$positional_three; fi
    ;;
esac

if [ -n "$cache_root" ] && [ "$direction" = write ] && [ "${1:-}" = api ] && [ -z "$cache_write_id" ]; then
  cache_write_endpoint=$(api_command_endpoint "$@") || cache_write_endpoint=
  cache_write_endpoint=${cache_write_endpoint#/}
  cache_write_endpoint=${cache_write_endpoint%%\?*}
  case "$cache_write_endpoint" in
    repos/*/*/issues/*|repos/*/*/pulls/*)
      cache_write_rest=${cache_write_endpoint#repos/}
      cache_write_owner=${cache_write_rest%%/*}
      cache_write_rest=${cache_write_rest#*/}
      cache_write_repo=${cache_write_rest%%/*}
      cache_write_rest=${cache_write_rest#*/}
      cache_write_rest=${cache_write_rest#*/}
      cache_write_number=${cache_write_rest%%/*}
      if cache_valid_slug "$cache_write_owner/$cache_write_repo"; then
        cache_owner=$cache_write_owner
        cache_repo_name=$cache_write_repo

        if cache_numeric "$cache_write_number"; then
          cache_write_id=$cache_write_number
        else
          # `issues/comments/<id>`, `pulls/comments/<id>`, `issues/events/<id>`:
          # a subresource whose own id is not an issue or pull request number.
          # The agent workpad is edited through exactly this shape.
          cache_write_id=subresource
        fi
      fi
      unset cache_write_rest cache_write_owner cache_write_repo cache_write_number
      ;;
    repos/*/*/issues|repos/*/*/pulls)
      cache_write_rest=${cache_write_endpoint#repos/}
      cache_write_owner=${cache_write_rest%%/*}
      cache_write_rest=${cache_write_rest#*/}
      cache_write_repo=${cache_write_rest%%/*}
      if cache_valid_slug "$cache_write_owner/$cache_write_repo"; then
        cache_owner=$cache_write_owner
        cache_repo_name=$cache_write_repo
        cache_write_id=collection
      fi
      unset cache_write_rest cache_write_owner cache_write_repo
      ;;
  esac
  unset cache_write_endpoint
fi

if [ -n "$cache_root" ]; then
  cache_started_at=$(date -u +%s 2>/dev/null || printf '')
  case "$cache_started_at" in
    ''|*[!0-9]*) cache_root= ;;
  esac
fi

# `cache_now` is what freshness is measured against. It starts equal to the
# process's start and is re-sampled only by a coalesced follower, which is the
# one caller for whom "now" has genuinely moved since it started.
cache_now=${cache_started_at:-0}

if [ -n "$cache_root" ] && [ -n "$cache_owner" ] && [ -n "$cache_repo_name" ]; then
  # Down-cased, exactly as `Aiur.GitHub.ResourceStore.key/4` does, because the
  # daemon and this wrapper must name one repository one way. `-R AIUR-Team/Aiur`
  # and a webhook's `aiur-team/aiur` are the same repository, and filed apart the
  # daemon would retire entries no agent is reading while the agents keep serving
  # the ones it meant to retire — a cache that is wrong in the one direction a
  # cache may not be wrong in.
  if command -v tr >/dev/null 2>&1; then
    cache_identity=$(printf '%s/%s' "$cache_owner" "$cache_repo_name" | tr '[:upper:]' '[:lower:]')
    case "$cache_identity" in
      ?*/?*)
        cache_owner=${cache_identity%%/*}
        cache_repo_name=${cache_identity#*/}
        ;;
      *) cache_root= ;;
    esac
    unset cache_identity
  else
    # No `tr`, no way to guarantee one spelling. Caching nothing is the safe
    # answer; a half-shared store is worse than none.
    cache_root=
  fi
fi

if [ -n "$cache_root" ] && [ -n "$cache_owner" ] && [ -n "$cache_repo_name" ]; then
  cache_repo_dir=$cache_root/v1/$cache_owner/$cache_repo_name
fi

if [ -n "$cache_repo_dir" ] && [ -n "$cache_kind" ] && [ -n "$cache_id" ]; then
  cache_shape=$(cache_material "$@" | cache_fingerprint) || cache_shape=
  if cache_valid_digest "$cache_shape"; then
    cache_entry_dir=$cache_repo_dir/$cache_kind/$cache_id
    cache_body=$cache_entry_dir/$cache_shape.body
    cache_meta=$cache_entry_dir/$cache_shape.meta
  else
    cache_shape=
  fi
fi

if [ -n "$agent_quota_dir" ]; then cache_events_file=$agent_quota_dir/agent-cache.tsv; fi

# U8 attribution and U9's debug page read this: one row per cacheable
# invocation, so agent-side effectiveness is a counted fact rather than an
# inference from falling request rates.
cache_record() {
  [ -n "$cache_events_file" ] || return 0

  cache_events_size=0
  if [ -f "$cache_events_file" ]; then
    cache_events_size=$(wc -c < "$cache_events_file" 2>/dev/null || printf '0')
  fi
  case "$cache_events_size" in
    ''|*[!0-9]*) cache_events_size=0 ;;
  esac
  if [ "$cache_events_size" -gt 1048576 ]; then
    mv -f "$cache_events_file" "$cache_events_file.1" 2>/dev/null || true
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' "$cache_started_at" "$consumer" "$1" "${cache_kind:-unknown}" "${cache_id:-unknown}" \
    >> "$cache_events_file" 2>/dev/null || true
  unset cache_events_size
  return 0
}

# Reads use the shell's own `read` rather than `sed` so a hit spends no
# subprocess on freshness at all. #1984 measures the broker at 250-450ms and
# two `python3` spawns per call; a cache that added its own spawns to every
# lookup would hand back what it saved.
cache_marker_at() {
  [ -f "$1" ] || return 0

  cache_marker_value=
  IFS= read -r cache_marker_value < "$1" 2>/dev/null || cache_marker_value=
  case "$cache_marker_value" in
    ''|*[!0-9]*) cache_marker_value=0 ;;
  esac
  if [ "$cache_marker_value" -gt "$cache_invalidated_at" ]; then cache_invalidated_at=$cache_marker_value; fi
  unset cache_marker_value
  return 0
}

cache_lookup() {
  [ -n "$cache_body" ] || return 1
  [ "$cache_bypass" -eq 0 ] || return 1
  [ -f "$cache_meta" ] || return 1
  [ -r "$cache_body" ] || return 1

  cache_fetched_at=
  IFS= read -r cache_fetched_at < "$cache_meta" 2>/dev/null || return 1
  case "$cache_fetched_at" in
    ''|*[!0-9]*) return 1 ;;
  esac

  # A clock that moved backwards, or an entry stamped in the future, is not
  # something to reason about — treat it as a miss and re-fetch.
  #
  # Compared against `$cache_now` rather than this process's start, because a
  # coalesced follower looks again after waiting: measured from its start, an
  # entry the leader wrote one second later reads as stamped in the future and is
  # refused, which is precisely the duplicate fetch the wait existed to avoid.
  [ "$cache_fetched_at" -le "$cache_now" ] || return 1
  [ $((cache_now - cache_fetched_at)) -le "$cache_ttl" ] || return 1

  cache_invalidated_at=0
  cache_marker_at "$cache_root/v1/.invalidated"
  cache_marker_at "$cache_repo_dir/.invalidated"
  [ "$cache_collection" -eq 0 ] || cache_marker_at "$cache_repo_dir/.collections-invalidated"
  cache_marker_at "$cache_entry_dir/.invalidated"

  [ "$cache_fetched_at" -gt "$cache_invalidated_at" ] || return 1
  return 0
}

cache_write_file() {
  cache_write_target=$1
  cache_write_tmp=$1.$$.tmp

  case "$cache_write_target" in
    */*) mkdir -p "${cache_write_target%/*}" 2>/dev/null || { unset cache_write_target cache_write_tmp; return 1; } ;;
  esac

  if printf '%s\n' "$2" > "$cache_write_tmp" 2>/dev/null &&
    mv -f "$cache_write_tmp" "$cache_write_target" 2>/dev/null; then
    unset cache_write_target cache_write_tmp
    return 0
  fi

  rm -f "$cache_write_tmp" 2>/dev/null || true
  unset cache_write_target cache_write_tmp
  return 1
}

# Marked with the moment the mutation FINISHED, and entries are stamped with the
# moment their read STARTED. Those two choices together are what make the marker
# safe, and both are load-bearing:
#
#   * A read that began before the write completed is retired even if its response
#     arrived afterwards, because its stamp predates the marker. Stamping the
#     marker at the mutation's start instead would leave that read — which cannot
#     contain the change — looking newer than the change, and an agent would be
#     unable to see the comment it had just posted for the whole window.
#   * The error runs one way only. A read that genuinely postdates the write is
#     also retired when it began within the same second, which costs one
#     re-fetch. Over-invalidation is the only acceptable direction here.
cache_invalidate_writes() {
  [ -n "$cache_root" ] || return 0
  [ "$direction" = write ] || return 0

  cache_finished_at=$(date -u +%s 2>/dev/null || printf '')
  case "$cache_finished_at" in ''|*[!0-9]*) cache_finished_at=$cache_started_at ;; esac
  case "$cache_finished_at" in ''|*[!0-9]*) return 0 ;; esac

  if [ -z "$cache_repo_dir" ]; then
    # A write whose repository could not be identified may have changed
    # anything, so nothing may be trusted. This is deliberately blunt: a rare
    # over-invalidation costs one re-fetch, while a missed one serves a stale
    # answer for the whole freshness window.
    cache_write_file "$cache_root/v1/.invalidated" "$cache_finished_at" || true
    unset cache_finished_at
    return 0
  fi

  cache_write_file "$cache_repo_dir/.collections-invalidated" "$cache_finished_at" || true

  case "$cache_write_id" in
    # A write whose subject is a SUBRESOURCE — a comment id, a review id — names
    # a number that is not an issue or pull request number, and the parent it
    # belongs to is not derivable from it. Retiring the repository for it would
    # be correct and ruinous: agents rewrite their workpad comment every few
    # minutes, so every one of those edits would flush the whole store and the
    # sharing this exists for would never happen. The collections marker written
    # above is the honest scope for it.
    collection|subresource) ;;
    ''|*[!0-9]*) cache_write_file "$cache_repo_dir/.invalidated" "$cache_finished_at" || true ;;
    *)
      cache_write_file "$cache_repo_dir/pr/$cache_write_id/.invalidated" "$cache_finished_at" || true
      cache_write_file "$cache_repo_dir/issue/$cache_write_id/.invalidated" "$cache_finished_at" || true
      ;;
  esac

  unset cache_finished_at
  return 0
}

cache_store() {
  [ -n "$cache_body" ] || return 0
  [ -n "$cache_stage" ] && [ -f "$cache_stage" ] || return 0
  [ "${status:-1}" -eq 0 ] || return 0

  cache_size=$(wc -c < "$cache_stage" 2>/dev/null || printf '')
  case "$cache_size" in
    ''|*[!0-9]*) unset cache_size; return 0 ;;
  esac
  if [ "$cache_size" -gt "$cache_max_bytes" ]; then unset cache_size; return 0; fi
  unset cache_size

  mkdir -p "$cache_entry_dir" 2>/dev/null || return 0

  cache_body_tmp=$cache_body.$$.tmp
  if cat "$cache_stage" > "$cache_body_tmp" 2>/dev/null && mv -f "$cache_body_tmp" "$cache_body" 2>/dev/null; then
    # The body lands first and the stamp commits the entry, so a reader that
    # finds a readable stamp always finds a complete body behind it.
    cache_write_file "$cache_meta" "$cache_started_at" || rm -f "$cache_body" 2>/dev/null || true
    cache_record store
  else
    rm -f "$cache_body_tmp" 2>/dev/null || true
  fi

  unset cache_body_tmp
  return 0
}

# Entries are never read after their window closes, so retention exists only to
# stop the store growing without bound. Backgrounded and rate-limited to once an
# hour so it never appears in the latency of a call.
cache_prune() {
  [ -n "$cache_root" ] || return 0
  [ -d "$cache_root/v1" ] || return 0
  command -v find >/dev/null 2>&1 || return 0

  cache_pruned_at=0
  if [ -f "$cache_root/v1/.pruned" ]; then
    IFS= read -r cache_pruned_at < "$cache_root/v1/.pruned" 2>/dev/null || cache_pruned_at=0
    case "$cache_pruned_at" in
      ''|*[!0-9]*) cache_pruned_at=0 ;;
    esac
  fi

  if [ $((cache_started_at - cache_pruned_at)) -lt 3600 ]; then unset cache_pruned_at; return 0; fi
  unset cache_pruned_at
  cache_write_file "$cache_root/v1/.pruned" "$cache_started_at" || return 0

  # The subshell's own descriptors are redirected, not just the `find`'s. A
  # background job that keeps a copy of this script's stdout holds the pipe
  # open, and `$(gh pr view ...)` blocks on EOF — so an unredirected sweep would
  # stall the very command it was meant to be invisible to. Same reason
  # `budget_start_renewal` redirects its subshell.
  (
    find "$cache_root/v1" -type f \( -name '*.body' -o -name '*.meta' \) -mmin +120 -delete || true
  ) >/dev/null 2>&1 &

  return 0
}

cache_serve() {
  cache_record "$1"
  cat "$cache_body"
}

# A second look, with the clock re-sampled. Between a caller's own lookup and the
# moment it is admitted to spend, another agent's identical fetch can land — so
# every point where this call is about to reach GitHub asks once more first. One
# `date` and a handful of stats against a network round trip.
cache_recheck() {
  [ -n "$cache_body" ] || return 1

  cache_now=$(date -u +%s 2>/dev/null || printf '%s' "$cache_started_at")
  case "$cache_now" in ''|*[!0-9]*) cache_now=$cache_started_at ;; esac

  cache_lookup
}

if cache_lookup; then
  cache_serve hit
  exit 0
fi

[ -z "$cache_body" ] || cache_record miss

# COALESCING (#2073 U6). A hit above costs no `python3` and no network, so the
# store already removes the second and later reads of a resource. It cannot
# remove the SIMULTANEOUS ones: thirteen agents that all look before any of them
# has answered all miss, and all thirteen pay. Nothing in a lookup can fix that,
# because at lookup time there is nothing to find.
#
# So the miss path names the shape it is about to fetch, and the broker — the one
# place every agent on the host already meets under a transaction — admits one
# fetcher per shape and tells the rest to wait. They wait, look again, and find
# the leader's answer. The claim is bounded by its own TTL and by the waiter's
# patience below, so a leader that dies costs one duplicate fetch and never a
# stall.
cache_claim_key=
if [ -n "$cache_body" ] && [ -n "$cache_shape" ]; then
  cache_claim_key=$cache_owner/$cache_repo_name/$cache_kind/$cache_id/$cache_shape
fi

# How long a follower waits for the leader before deciding the leader is not
# coming and fetching for itself. Bounded on purpose: a wait that could outlast
# the call it replaces would turn a saving into a hang. Measured against the
# CLOCK, not against the sleeps the broker advertised — each iteration also pays
# a `python3` start and a SQLite write transaction, so counting only the
# advertised sleep understated the real wait by more than a factor of two and the
# documented bound would not have been the bound.
cache_claim_wait_budget_ms=${AIUR_GITHUB_STATE_CACHE_WAIT_MS:-15000}
case "$cache_claim_wait_budget_ms" in ''|*[!0-9]*) cache_claim_wait_budget_ms=15000 ;; esac
cache_claim_wait_budget=$(( (cache_claim_wait_budget_ms + 999) / 1000 ))
cache_claim_waited_ms=0
cache_claim_overtake=0
cache_served=0

budget_command() {
  python3 "$budget_broker" "$@" --db "$budget_db" --token-key "$budget_key"
}

budget_sleep_ms() {
  budget_delay=$1
  case "$budget_delay" in ''|0|*[!0-9]*) return 1 ;; esac
  budget_seconds=$(awk "BEGIN { printf \"%.3f\", $budget_delay / 1000 }")
  sleep "$budget_seconds"
}

valid_budget_lease() {
  case "$1" in ''|*[!0-9abcdef]*) return 1 ;; esac
  [ "${#1}" -eq 32 ]
}

budget_acquire() {
  [ "$budget_enabled" -eq 1 ] || return 0

  while :; do
    # Whatever this loop last waited for — a hold, a full lease table, another
    # agent's identical fetch — the answer may have arrived meanwhile. Looking
    # again is a stat and a `read`, so it is cheaper than any of the reasons the
    # loop is here.
    if [ "$cache_claim_waited_ms" -gt 0 ] && cache_recheck; then
      cache_serve coalesced
      cache_served=1
      return 66
    fi

    budget_ignore_flag=
    [ "$budget_ignore_token_cooldown" -eq 1 ] && budget_ignore_flag=--ignore-token-cooldown
    budget_cache_flags=
    if [ -n "$cache_claim_key" ]; then
      budget_cache_flags="--cache-key $cache_claim_key --cache-claim-ttl-ms $budget_lease_ttl_ms"
      [ "$cache_claim_overtake" -eq 1 ] && budget_cache_flags="$budget_cache_flags --cache-ignore-claim"
    fi
    if ! budget_result=$(budget_command acquire --resource "$admission_resource" --consumer-key "$budget_consumer_key" --endpoint-family "$endpoint_family" \
      $budget_ignore_flag $budget_cache_flags \
      --max-inflight "${AIUR_GITHUB_MAX_INFLIGHT:-4}" \
      --max-inflight-per-endpoint "${AIUR_GITHUB_MAX_INFLIGHT_PER_ENDPOINT:-2}" \
      --requests-per-minute "${AIUR_GITHUB_REQUESTS_PER_MINUTE:-120}" \
      --stagger-ms "${AIUR_GITHUB_STAGGER_MS:-75}" --lease-ttl-ms "$budget_lease_ttl_ms" 2>/dev/null); then
      printf '%s\n' 'aiur: GitHub budget broker unavailable; refusing uncoordinated request' >&2
      return 75
    fi
    unset budget_ignore_flag budget_cache_flags

    case "$budget_result" in
      "granted "*)
        budget_lease=${budget_result#granted }
        if valid_budget_lease "$budget_lease"; then
          # Admitted, and therefore about to spend. The window between this
          # call's own lookup and this grant is exactly where a simultaneous
          # reader's answer lands, and it is not covered by the claim: a caller
          # arriving after the leader released has no claim to wait behind and
          # would fetch a resource that is already in the store.
          if [ -n "$cache_claim_key" ] && cache_recheck; then
            cache_serve coalesced
            cache_served=1
            budget_release
            return 66
          fi

          return 0
        fi
        printf '%s\n' 'aiur: GitHub budget broker returned an invalid admission response' >&2
        return 75
        ;;
      "wait "*)
        budget_wait_ms=${budget_result#wait }
        if ! budget_sleep_ms "$budget_wait_ms"; then
          printf '%s\n' 'aiur: GitHub budget broker returned an invalid or unusable wait response' >&2
          return 75
        fi
        case "$budget_wait_ms" in
          ''|*[!0-9]*) ;;
          *) cache_claim_waited_ms=$((cache_claim_waited_ms + budget_wait_ms)) ;;
        esac
        # Patience spent. The leader may have died between claiming the resource
        # and answering for it, and a follower that waits forever on a dead
        # leader has been made worse off by the optimisation. Overtake the claim
        # and fetch; the cost is the one call this was trying to save.
        if [ -n "$cache_claim_key" ] && [ "$cache_claim_overtake" -eq 0 ]; then
          cache_waited=$(date -u +%s 2>/dev/null || printf '')
          case "$cache_waited" in
            ''|*[!0-9]*) ;;
            *)
              if [ $((cache_waited - cache_started_at)) -ge "$cache_claim_wait_budget" ]; then
                cache_claim_overtake=1
              fi
              ;;
          esac
          unset cache_waited
        fi
        unset budget_wait_ms
        ;;
      *)
        printf '%s\n' 'aiur: GitHub budget broker returned an invalid admission response' >&2
        return 75
        ;;
    esac
  done
}

budget_release() {
  if [ -n "$budget_renewal_pid" ]; then
    kill "$budget_renewal_pid" 2>/dev/null || true
    budget_renewal_pid=
  fi
  [ -n "$budget_lease" ] || return 0
  budget_command release --lease-id "$budget_lease" >/dev/null 2>&1 || true
  budget_lease=
}

budget_start_renewal() {
  [ -n "$budget_lease" ] || return 0
  budget_renew_interval=$((budget_lease_ttl_ms / 3 / 1000))
  [ "$budget_renew_interval" -gt 0 ] || budget_renew_interval=1

  (
    while sleep "$budget_renew_interval"; do
      budget_command renew --lease-id "$budget_lease" --lease-ttl-ms "$budget_lease_ttl_ms" >/dev/null 2>&1 || exit 0
    done
  ) >/dev/null 2>&1 &
  budget_renewal_pid=$!
  unset budget_renew_interval
}

budget_hold() {
  budget_scope=$1
  budget_delay=$2
  budget_resource=${3:-$resource}
  [ "$budget_enabled" -eq 1 ] || return 0
  budget_command hold --scope "$budget_scope" --resource "$budget_resource" --delay-ms "$budget_delay" >/dev/null 2>&1 || true
}

# `gh api --paginate` normally makes its follow-up requests inside one gh
# process. Re-enter this guard for each REST page instead, so every network
# request obtains and releases its own shared broker lease. The child is also
# responsible for response observation and quota tracking; it has no
# `--paginate` flag, so it follows the ordinary single-request path.
run_budgeted_paginated_api() {
  AIUR_GITHUB_PAGINATION_WRAPPER="$0" AIUR_GITHUB_PAGINATION_REAL_GH="$real_gh" AIUR_GITHUB_PAGINATION_DIRECTION="$direction" python3 - "$@" <<'PY'
import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import threading
from urllib.parse import urlsplit


def split_response(output):
    match = re.search(br"\r?\n\r?\n", output)
    if match is None:
        return b"", output
    return output[: match.start()], output[match.end() :]


def next_endpoint(headers):
    for line in headers.decode("utf-8", "replace").splitlines():
        if not line.lower().startswith("link:"):
            continue
        match = re.search(r'<([^>]+)>;\s*rel="next"', line, re.IGNORECASE)
        if match is None:
            continue
        parsed = urlsplit(match.group(1))
        endpoint = parsed.path or "/"
        return f"{endpoint}?{parsed.query}" if parsed.query else endpoint
    return None


def next_cursor(body):
    try:
        response = json.loads(body)
    except json.JSONDecodeError:
        print("aiur: gh api GraphQL pagination returned a non-JSON page", file=sys.stderr)
        raise SystemExit(1)

    stack = [response]
    while stack:
        value = stack.pop()
        if isinstance(value, dict):
            if {"hasNextPage", "endCursor"} <= value.keys():
                if not value["hasNextPage"]:
                    return None
                cursor = value["endCursor"]
                if isinstance(cursor, str) and cursor:
                    return cursor
                print("aiur: gh api GraphQL pagination returned an invalid endCursor", file=sys.stderr)
                raise SystemExit(1)
            stack.extend(value.values())
        elif isinstance(value, list):
            stack.extend(value)

    print("aiur: gh api GraphQL pagination response is missing pageInfo", file=sys.stderr)
    raise SystemExit(1)


def endpoint_index(args):
    value_flags = {
        "--cache", "-F", "--field", "-f", "--raw-field", "-H", "--header",
        "--hostname", "--input", "-q", "--jq", "-X", "--method", "-p",
        "--preview", "-t", "--template",
    }
    awaiting_value = False

    for index, arg in enumerate(args[1:], start=1):
        if awaiting_value:
            awaiting_value = False
            continue
        if arg == "--":
            return index + 1 if index + 1 < len(args) else None
        if arg in value_flags:
            awaiting_value = True
            continue
        if arg in {"--include", "-i", "--silent", "--verbose"}:
            continue
        if arg.startswith("--"):
            continue
        if arg.startswith("-"):
            if arg[:2] in {"-F", "-f", "-H", "-q", "-X", "-p", "-t"} and len(arg) > 2:
                continue
            return None
        return index

    return None


def active_flag(args, *values):
    options = True

    for arg in args:
        if options and arg == "--":
            options = False
        elif options and (arg in values or any(value.startswith("--") and arg == f"{value}=true" for value in values)):
            return True

    return False


def without_pagination_flags(args):
    page_args = []
    options = True

    for arg in args:
        if options and arg == "--":
            options = False
        if options and arg in {"--paginate", "--paginate=true", "--slurp", "--slurp=true"}:
            continue
        page_args.append(arg)

    return page_args


def extract_output_formatter(args):
    """Keep one unformatted request per page and retain gh's formatter args."""

    page_args = []
    formatter = None
    index = 0
    options = True

    while index < len(args):
        arg = args[index]
        if options and arg == "--":
            options = False
            page_args.extend(args[index:])
            break

        kind = None
        expression = None
        if options and arg in {"-q", "--jq", "-t", "--template"}:
            if index + 1 >= len(args):
                print(f"aiur: {arg} requires an output expression", file=sys.stderr)
                raise SystemExit(64)
            kind = "jq" if arg in {"-q", "--jq"} else "template"
            expression = args[index + 1]
            index += 2
        elif options and arg.startswith("--jq="):
            kind, expression = "jq", arg.split("=", 1)[1]
            index += 1
        elif options and arg.startswith("--template="):
            kind, expression = "template", arg.split("=", 1)[1]
            index += 1
        elif options and arg.startswith("-q") and len(arg) > 2:
            kind, expression = "jq", arg[2:]
            index += 1
        elif options and arg.startswith("-t") and len(arg) > 2:
            kind, expression = "template", arg[2:]
            index += 1
        else:
            page_args.append(arg)
            index += 1
            continue

        if formatter is not None:
            print("aiur: gh api accepts only one output formatter", file=sys.stderr)
            raise SystemExit(64)
        formatter = (kind, expression)

    return page_args, formatter


def paginated_request_uses_input(args):
    value_flags = {"-F", "--field", "-f", "--raw-field"}

    for index, arg in enumerate(args):
        if arg == "--input" or arg.startswith("--input="):
            return True
        if arg in value_flags and index + 1 < len(args):
            value = args[index + 1]
            if "=@" in value:
                return True
        if "=@" in arg and (
            arg.startswith(("-F", "-f")) or arg.startswith(("--field=", "--raw-field="))
        ):
            return True

    return False


def add_include(args):
    if active_flag(args, "--include", "-i"):
        return args

    page_args = args.copy()
    try:
        page_args.insert(page_args.index("--"), "--include")
    except ValueError:
        page_args.append("--include")
    return page_args


def formatter_arguments(formatter):
    kind, expression = formatter
    return ["--jq" if kind == "jq" else "--template", expression]


def response_status(headers):
    match = re.search(br"^HTTP/[^\s]+\s+(\d{3})", headers)
    return int(match.group(1)) if match else 200


def response_headers(headers):
    for line in headers.splitlines()[1:]:
        if b":" not in line:
            continue
        name, value = line.split(b":", 1)
        name = name.decode("latin-1")
        if name.lower() in {"connection", "content-length", "link", "transfer-encoding"}:
            continue
        yield name, value.decode("latin-1").strip()


def response_header_values(headers, name):
    prefix = name.lower().encode("ascii") + b":"
    return [line for line in headers.splitlines()[1:] if line.lower().startswith(prefix)]


def linux_process_owns_connection(pid, client_port, server_port):
    """Verify the renderer owns the client side of this loopback connection."""

    inode = None
    try:
        with open("/proc/net/tcp", encoding="ascii") as connections:
            for line in connections.readlines()[1:]:
                fields = line.split()
                local_port = int(fields[1].rsplit(":", 1)[1], 16)
                remote_port = int(fields[2].rsplit(":", 1)[1], 16)
                if fields[3] == "01" and local_port == client_port and remote_port == server_port:
                    inode = fields[9]
                    break
    except (FileNotFoundError, OSError, ValueError, IndexError):
        return False

    if inode is None:
        return False

    expected = f"socket:[{inode}]"
    try:
        file_descriptors = os.listdir(f"/proc/{pid}/fd")
    except (FileNotFoundError, OSError):
        return False

    for fd in file_descriptors:
        try:
            if os.readlink(f"/proc/{pid}/fd/{fd}") == expected:
                return True
        except (FileNotFoundError, OSError):
            continue
    return False


def darwin_process_owns_connection(pid, client_port, server_port):
    """Use macOS's system lsof to bind the replay to the renderer process."""

    lsof = shutil.which("lsof")
    if lsof is None and os.path.isfile("/usr/sbin/lsof"):
        lsof = "/usr/sbin/lsof"
    if lsof is None:
        return False

    try:
        result = subprocess.run(
            [lsof, "-nP", "-a", "-p", str(pid), "-iTCP"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    connection = f"127.0.0.1:{client_port}->127.0.0.1:{server_port}"
    return result.returncode == 0 and connection in result.stdout


def process_owns_connection(pid, client_port, server_port):
    if sys.platform.startswith("linux"):
        return linux_process_owns_connection(pid, client_port, server_port)
    if sys.platform == "darwin":
        return darwin_process_owns_connection(pid, client_port, server_port)
    return False


def render_with_native_gh(formatter, captured_pages, slurp, include_headers):
    """Replay admitted responses locally and let gh render them unchanged.

    Calling gh once more against GitHub would bypass the captured page's lease.
    A loopback replay keeps the formatter in gh itself (including its embedded
    jq, Go-template helpers, and table state) without another GitHub request.
    """

    if slurp:
        try:
            payload = json.dumps([json.loads(body) for _headers, body in captured_pages]).encode("utf-8")
        except json.JSONDecodeError:
            print("aiur: gh api --paginate --slurp returned a non-JSON page", file=sys.stderr)
            raise SystemExit(1)
        replay_pages = [(b"", payload)]
        paginate = False
    else:
        replay_pages = captured_pages
        paginate = True

    class ReplayHandler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            self.server.renderer_ready.wait(timeout=5)
            renderer_pid = self.server.renderer_pid
            if renderer_pid is None or not process_owns_connection(
                renderer_pid, self.client_address[1], self.server.server_port
            ):
                self.send_error(403)
                return

            match = re.fullmatch(r"/(\d+)", self.path.split("?", 1)[0])
            page = int(match.group(1)) if match else -1
            if not 0 <= page < len(replay_pages):
                self.send_error(404)
                return

            headers, body = replay_pages[page]
            self.send_response(response_status(headers))
            content_type = False
            for name, value in response_headers(headers):
                content_type = content_type or name.lower() == "content-type"
                self.send_header(name, value)
            if not content_type:
                self.send_header("Content-Type", "application/json")
            if page + 1 < len(replay_pages):
                self.send_header("Link", f"<http://127.0.0.1:{self.server.server_port}/{page + 1}>; rel=\"next\"")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def send_response(self, code, message=None):
            # Preserve captured response headers instead of adding the replay
            # server's own Server and Date headers to --include output.
            self.send_response_only(code, message)

        def log_message(self, _format, *_args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ReplayHandler)
    server.daemon_threads = True
    server.block_on_close = False
    server.renderer_pid = None
    server.renderer_ready = threading.Event()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        command = [os.environ["AIUR_GITHUB_PAGINATION_REAL_GH"], "api", f"http://127.0.0.1:{server.server_port}/0"]
        if paginate:
            command.append("--paginate")
        if include_headers:
            command.append("--include")
        command.extend(formatter_arguments(formatter))
        environment = os.environ.copy()
        for name in ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"):
            environment.pop(name, None)
        # gh requires an authentication source before it will issue even an
        # absolute loopback request. Replace inherited credentials with a
        # fixed non-secret accepted only by this renderer-bound local server.
        environment["GH_TOKEN"] = "aiur-local-replay"
        environment["NO_PROXY"] = "127.0.0.1,localhost"
        environment["no_proxy"] = "127.0.0.1,localhost"
        capture_headers = include_headers and paginate
        process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE if capture_headers else None)
        server.renderer_pid = process.pid
        server.renderer_ready.set()
        rendered, _stderr = process.communicate()

        if capture_headers:
            for page, (headers, _body) in enumerate(replay_pages[:-1]):
                local = f'Link: <http://127.0.0.1:{server.server_port}/{page + 1}>; rel="next"'.encode("ascii")
                original = b"\n".join(response_header_values(headers, "Link"))
                rendered = rendered.replace(local, original)
            sys.stdout.buffer.write(rendered)

        return process.returncode
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


args = sys.argv[1:]
include_headers = active_flag(args, "--include", "-i")
slurp = active_flag(args, "--slurp")
silent = active_flag(args, "--silent")
verbose = active_flag(args, "--verbose")
display_args = without_pagination_flags(args)
raw_args, formatter = extract_output_formatter(display_args)

if formatter and (silent or verbose):
    print("only one of `--template`, `--jq`, `--silent`, or `--verbose` may be used", file=sys.stderr)
    raise SystemExit(1)

raw_args = add_include(raw_args)
raw_endpoint_index = endpoint_index(raw_args)

if raw_endpoint_index is None or raw_args[0] != "api":
    print("aiur: cannot budget malformed gh api pagination command", file=sys.stderr)
    raise SystemExit(64)

if paginated_request_uses_input(raw_args):
    print("aiur: cannot budget gh api --paginate commands that use an input body or standard input", file=sys.stderr)
    raise SystemExit(64)

if os.environ.get("AIUR_GITHUB_PAGINATION_DIRECTION") == "write":
    print("aiur: cannot budget a paginated write", file=sys.stderr)
    raise SystemExit(64)

wrapper = os.environ["AIUR_GITHUB_PAGINATION_WRAPPER"]
pages = []
captured_pages = []
graphql = raw_args[raw_endpoint_index] in {"graphql", "/graphql"}

raw_cursor_arg_index = next(
    (
        index
        for index, arg in enumerate(raw_args)
        if index > 0
        and arg.startswith("endCursor=")
        and raw_args[index - 1] in {"-F", "--field", "-f", "--raw-field"}
    ),
    None,
)

while True:
    result = subprocess.run([wrapper, *raw_args], stdout=subprocess.PIPE)
    headers, body = split_response(result.stdout)

    if result.returncode:
        if not silent:
            if include_headers:
                sys.stdout.buffer.write(headers)
                if headers:
                    sys.stdout.buffer.write(b"\n\n")
            sys.stdout.buffer.write(body)
        raise SystemExit(result.returncode)

    if silent:
        pass
    elif formatter:
        captured_pages.append((headers, body))
    elif slurp:
        try:
            pages.append(json.loads(body))
        except json.JSONDecodeError:
            print("aiur: gh api --paginate --slurp returned a non-JSON page", file=sys.stderr)
            raise SystemExit(1)
    else:
        if include_headers:
            sys.stdout.buffer.write(headers)
            if headers:
                sys.stdout.buffer.write(b"\n\n")
        sys.stdout.buffer.write(body)

    if graphql:
        cursor = next_cursor(body)
        if cursor is None:
            break
        if raw_cursor_arg_index is None:
            raw_args.extend(["-F", f"endCursor={cursor}"])
            raw_cursor_arg_index = len(raw_args) - 1
        else:
            raw_args[raw_cursor_arg_index] = f"endCursor={cursor}"
    else:
        endpoint = next_endpoint(headers)
        if endpoint is None:
            break
        raw_args[raw_endpoint_index] = endpoint

if formatter:
    raise SystemExit(render_with_native_gh(formatter, captured_pages, slurp, include_headers))

if slurp:
    payload = json.dumps(pages).encode("utf-8")
    if not silent:
        sys.stdout.buffer.write(payload)
        sys.stdout.buffer.write(b"\n")
PY
}

trap 'budget_release; exit 143' HUP INT TERM
trap 'budget_release' 0

secondary_delay_ms() {
  retry_after=
  for retry_source in "$@"; do
    [ -n "$retry_source" ] && [ -f "$retry_source" ] || continue
    retry_after=$(sed -n -E 's/^[[:space:]]*[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:[[:space:]]*([0-9]+).*/\1/p' "$retry_source" | sed -n '1p')
    [ -n "$retry_after" ] && break
  done

  case "$retry_after" in
    ''|0|*[!0-9]*) printf '%s\n' 60000 ;;
    *)
      if [ "$retry_after" -gt 3600 ]; then retry_after=3600; fi
      printf '%s\n' $((retry_after * 1000))
      ;;
  esac
}

# Reuse the timestamp the cache section already sampled rather than forking
# `date` a second time; they are the same instant for every purpose here.
now=${cache_started_at:-}
case "$now" in
  ''|*[!0-9]*) now=$(date -u +%s) ;;
esac
hold_until=0

# A truncating `>` redirect leaves the hold file empty between truncate and
# write. A concurrent reader sampling it in that gap sees no hold, `consider_hold`
# bails, and the call goes out during an exhausted window. Writing to a sibling
# temp file and renaming makes the hold appear in one step — the same reason the
# Elixir side uses temp+rename in `Aiur.AgentGitHubGuard.write_hold_file/3`.
write_hold() {
  write_hold_tmp="$1.tmp.$$"

  if printf '%s\n' "$2" > "$write_hold_tmp" 2>/dev/null; then
    mv -f "$write_hold_tmp" "$1" 2>/dev/null || rm -f "$write_hold_tmp" 2>/dev/null || true
  else
    rm -f "$write_hold_tmp" 2>/dev/null || true
  fi

  return 0
}

# Exhaustion an agent discovers first is fleet-wide news, but holds used to be
# written only to the per-workspace dir that no other agent and not the daemon
# reads — so everyone else rediscovered it on the daemon's next `/rate_limit`
# probe. Reads already consult both dirs (`consider_resource_holds` below), so
# writes publish to both too. An unwritable shared dir just fails quietly and
# leaves the workspace hold in place.
publish_hold() {
  if [ -n "$agent_quota_dir" ]; then write_hold "$agent_quota_dir/$1" "$2"; fi

  if [ -n "$quota_dir" ] && [ "$quota_dir" != "$agent_quota_dir" ]; then
    write_hold "$quota_dir/$1" "$2"
  fi

  return 0
}

consider_hold() {
  candidate=$(sed -n '1p' "$1" 2>/dev/null)
  case "$candidate" in
    ''|*[!0-9]*) return ;;
  esac

  if [ "$candidate" -gt "$now" ]; then
    if [ "$candidate" -gt "$hold_until" ]; then hold_until=$candidate; fi
  else
    rm -f "$1" 2>/dev/null || true
  fi
}

# Both hold kinds gate a call: `-hold` is the exhausted primary window, and
# `-secondary-hold` is a secondary/abuse-limit backoff, which GitHub raises
# while the primary window still reads healthy.
consider_resource_holds() {
  case "$2" in
    core|graphql)
      consider_hold "$1/$2-hold"
      consider_hold "$1/$2-secondary-hold"
      ;;
    *)
      consider_hold "$1/core-hold"
      consider_hold "$1/core-secondary-hold"
      consider_hold "$1/graphql-hold"
      consider_hold "$1/graphql-secondary-hold"
      ;;
  esac
}

# The high-level list commands keep their own pagination loop inside one `gh`
# process. A shell guard cannot admit those hidden HTTP pages individually, so
# never let an invocation request more than one GitHub page under one lease.
# `gh api --paginate` is handled above and remains the supported guarded path
# for callers that need more than GitHub's maximum 100-item page.
native_page_limit_exceeds_single_request() {
  [ "${1:-}" != api ] || return 1

  native_limit=
  native_expect_limit=0
  native_options=1

  for native_argument in "$@"; do
    [ "$native_options" -eq 1 ] || continue

    if [ "$native_expect_limit" -eq 1 ]; then
      native_limit=$native_argument
      native_expect_limit=0
      continue
    fi

    case "$native_argument" in
      --) native_options=0 ;;
      --limit|-L) native_expect_limit=1 ;;
      --limit=*) native_limit=${native_argument#--limit=} ;;
      -L*) native_limit=${native_argument#-L} ;;
    esac
  done

  case "$native_limit" in
    ''|*[!0-9]*) return 1 ;;
  esac

  [ "$native_limit" -gt "${AIUR_GITHUB_NATIVE_PAGE_SIZE:-100}" ]
}

if [ "$resource" != none ] && [ "$budget_enabled" -eq 1 ] && native_page_limit_exceeds_single_request "$@"; then
  printf '%s\n' 'aiur: guarded high-level gh commands cannot fetch more than one page; use gh api --paginate for budgeted multi-page reads' >&2
  exit 64
fi

if [ "$resource" != none ] && [ -n "$quota_dir" ]; then
  consider_resource_holds "$quota_dir" "$resource"
fi

if [ "$resource" != none ] && [ -n "$agent_quota_dir" ] && [ "$agent_quota_dir" != "$quota_dir" ]; then
  consider_resource_holds "$agent_quota_dir" "$resource"
fi

if [ "$hold_until" -gt "$now" ]; then
  delay=$((hold_until - now))
  printf 'aiur: GitHub quota backoff; waiting %ss until %s\n' "$delay" "$(date -u -d "@$hold_until" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' "$hold_until")" >&2
  sleep "$delay"
  now=$(date -u +%s)
fi

if [ "$admission_required" -eq 1 ]; then
  if [ "$api_paginated" -eq 1 ] && [ "$budget_enabled" -eq 1 ]; then
    run_budgeted_paginated_api "$@"
    exit $?
  fi
  budget_acquire
  budget_admission=$?
  if [ "$budget_admission" -eq 0 ]; then
    budget_start_renewal
  elif [ "$cache_served" -eq 1 ]; then
    # Another agent's identical fetch answered this one while it waited. The
    # answer is already on stdout and no request was made.
    exit 0
  else
    exit "$budget_admission"
  fi
  unset budget_admission
fi

if [ "$track" -eq 1 ] && [ -n "$events_file" ]; then
  size=0
  if [ -f "$events_file" ]; then size=$(wc -c < "$events_file" 2>/dev/null || printf '0'); fi
  case "$size" in
    ''|*[!0-9]*) size=0 ;;
  esac
  if [ "$size" -gt 1048576 ]; then mv -f "$events_file" "$events_file.1" 2>/dev/null || true; fi

  # The resource column tells the daemon which budget the call was billed to.
  # Without it every agent call was counted against core, and a GraphQL query —
  # billed in points against a separate budget — landed in the wrong window.
  track_resource=$resource
  case "$track_resource" in
    core|graphql) ;;
    *) track_resource=core ;;
  esac

  printf '%s\t%s\t%s\t%s\n' "$now" "$consumer" "$direction" "$track_resource" >> "$events_file" 2>/dev/null || true
fi

error_file=
status_file=
output_file=
api_capture=0
api_requested_include=0
stderr_streamed=0

# `gh api` is always run with `--include` so the rate-limit headers can be read,
# then the headers are stripped again unless the caller asked for them. The
# bytes this prints are what the caller sees, so they are also exactly what the
# cache must store.
emit_api_output() {
  if [ "$api_requested_include" -eq 1 ]; then
    cat "$output_file"
  elif sed -n '1p' "$output_file" | grep -Eq '^HTTP/'; then
    sed '1,/^[[:space:]]*$/d' "$output_file"
  else
    cat "$output_file"
  fi
}
if [ "$resource" != none ]; then
  old_umask=$(umask)
  umask 077
  error_file=$(mktemp "${TMPDIR:-/tmp}/aiur-gh-stderr.XXXXXX" 2>/dev/null || true)
  status_file=$(mktemp "${TMPDIR:-/tmp}/aiur-gh-status.XXXXXX" 2>/dev/null || true)
  umask "$old_umask"
fi

if [ -n "$error_file" ]; then
  if [ "${1:-}" = api ]; then
    for api_arg in "$@"; do
      case "$api_arg" in
        --include|--include=true|-i) api_requested_include=1 ;;
        --paginate) : ;;
      esac
    done

    if [ "$api_paginated" -eq 0 ]; then
      old_umask=$(umask)
      umask 077
      output_file=$(mktemp "${TMPDIR:-/tmp}/aiur-gh-stdout.XXXXXX" 2>/dev/null || true)
      umask "$old_umask"
      [ -n "$output_file" ] && api_capture=1
    fi
  fi

  # A cacheable read is captured so its exact bytes can be stored. Only the
  # shapes classified above reach this branch, and all of them are short,
  # one-shot, machine-readable reads — nothing that streams progress or prompts,
  # which is why the `tee` branch below still exists for everything else.
  if [ -n "$cache_body" ] && [ "$api_capture" -eq 0 ]; then
    old_umask=$(umask)
    umask 077
    cache_stage=$(mktemp "${TMPDIR:-/tmp}/aiur-gh-cache.XXXXXX" 2>/dev/null || true)
    umask "$old_umask"
  fi

  if [ "$api_capture" -eq 1 ]; then
    # stdout is already being captured for header parsing, so there is no live
    # output to interleave with; buffering stderr here costs nothing.
    if [ "$api_requested_include" -eq 1 ]; then
      "$real_gh" "$@" > "$output_file" 2> "$error_file"
    else
      "$real_gh" "$@" --include > "$output_file" 2> "$error_file"
    fi
    status=$?
  elif [ -n "$cache_stage" ]; then
    "$real_gh" "$@" > "$cache_stage" 2> "$error_file"
    status=$?
    cat "$cache_stage"
  elif [ -n "$status_file" ] && command -v tee > /dev/null 2>&1; then
    # Pass stderr through `tee` so it reaches the terminal as it is written
    # while still being captured for the rate-limit classification below.
    # Replaying a buffered copy after exit stalls `gh run watch` progress — an
    # allowlisted read — and swallows interactive prompts. `tee` ends the
    # pipeline, so the real exit status travels via `status_file`.
    { { "$real_gh" "$@"; printf '%s\n' "$?" > "$status_file"; } 2>&1 1>&3 | tee "$error_file" >&2; } 3>&1
    stderr_streamed=1
    # An unreadable or non-numeric status means the real exit code could not be
    # confirmed. Reporting 0 there would turn a failed `gh` into an apparent
    # success for every caller, so this fails closed instead.
    status=$(sed -n '1p' "$status_file" 2>/dev/null)
    case "$status" in
      ''|*[!0-9]*) status=1 ;;
    esac
  else
    "$real_gh" "$@" 2> "$error_file"
    status=$?
  fi

  if [ "$api_capture" -eq 1 ]; then
    emit_api_output

    # The cache copy is produced by a SECOND pass rather than by redirecting the
    # first. The agent's stdout must not depend on the cache being writable.
    if [ -n "$cache_body" ] && [ "$status" -eq 0 ]; then
      old_umask=$(umask)
      umask 077
      cache_stage=$(mktemp "${TMPDIR:-/tmp}/aiur-gh-cache.XXXXXX" 2>/dev/null || true)
      umask "$old_umask"
      if [ -n "$cache_stage" ]; then emit_api_output > "$cache_stage" 2>/dev/null || cache_stage=; fi
    fi
  fi

  if [ "$stderr_streamed" -eq 0 ]; then
    while IFS= read -r line || [ -n "$line" ]; do printf '%s\n' "$line" >&2; done < "$error_file"
  fi
else
  "$real_gh" "$@"
  status=$?
fi

probe_rate_limit() {
  original_resource=$resource
  original_admission_resource=$admission_resource
  original_family=$endpoint_family
  # The probe is a different request against a different resource. Claiming the
  # original read's shape for it would make every follower wait on an answer this
  # call is never going to write — and, worse, admission is re-entered here AFTER
  # the real `gh` has already failed, so a cached body found during the probe
  # would be printed onto the stdout of a call that is about to exit non-zero.
  # `$(gh ... --json ...)` would read that as a successful answer. Both the claim
  # and the ability to serve are withdrawn for the duration.
  original_claim_key=$cache_claim_key
  original_cache_body=$cache_body
  cache_claim_key=
  cache_body=
  immediate_cooldown=$(secondary_delay_ms "$error_file" "$output_file")
  budget_hold token "$immediate_cooldown"
  budget_release
  resource=core
  admission_resource=core
  endpoint_family=rate_limit
  budget_ignore_token_cooldown=1
  if budget_acquire; then
    budget_start_renewal
    rate_limit_observation=$("$real_gh" api rate_limit --template '{{.resources.core.remaining}} {{.resources.core.reset}} {{.resources.graphql.remaining}} {{.resources.graphql.reset}}' 2>/dev/null || true)
  else
    rate_limit_observation=
  fi
  budget_ignore_token_cooldown=0
  budget_release
  resource=$original_resource
  admission_resource=$original_admission_resource
  endpoint_family=$original_family
  cache_claim_key=$original_claim_key
  cache_body=$original_cache_body
  unset original_resource original_admission_resource original_family original_claim_key original_cache_body \
    immediate_cooldown
}

rate_limited_response() {
  grep -Eiq 'rate.?limit|rate_limit' "$error_file" && return 0
  [ -n "$output_file" ] && grep -Eiq 'rate.?limit|rate_limit' "$output_file" && return 0
  [ -n "$output_file" ] && grep -Eq '^HTTP/[0-9.]+[[:space:]]+(403|429)' "$output_file" && grep -Eiq '^[Rr]etry-[Aa]fter:' "$output_file"
}

record_successful_budget_hold() {
  [ "$status" -eq 0 ] || return 0
  [ -n "$output_file" ] && [ -f "$output_file" ] || return 0

  response_remaining=$(sed -n -E 's/^[[:space:]]*[Xx]-[Rr][Aa][Tt][Ee][Ll][Ii][Mm][Ii][Tt]-[Rr][Ee][Mm][Aa][Ii][Nn][Ii][Nn][Gg]:[[:space:]]*([0-9]+).*/\1/p' "$output_file" | tail -n 1)
  response_reset=$(sed -n -E 's/^[[:space:]]*[Xx]-[Rr][Aa][Tt][Ee][Ll][Ii][Mm][Ii][Tt]-[Rr][Ee][Ss][Ee][Tt]:[[:space:]]*([0-9]+).*/\1/p' "$output_file" | tail -n 1)

  case "$response_remaining:$response_reset" in
    0:[0-9]*)
      response_delay=$(( (response_reset - $(date -u +%s)) * 1000 ))
      if [ "$response_delay" -gt 0 ]; then
        publish_hold "$resource-hold" "$response_reset"
        budget_hold resource "$response_delay" "$resource"
      fi
      ;;
  esac

  unset response_remaining response_reset response_delay
}

record_successful_budget_hold

# A mutation invalidates before its response is stored, so an agent that edits a
# pull request and immediately reads it back can never be answered from the copy
# it just superseded. Invalidation runs whatever the exit status was: a write
# that failed late may still have landed.
if [ -n "$cache_root" ]; then
  cache_old_umask=$(umask)
  umask 077
fi
cache_invalidate_writes
cache_store
cache_prune
if [ -n "$cache_root" ]; then umask "$cache_old_umask"; fi
if [ -n "$cache_stage" ]; then rm -f "$cache_stage" 2>/dev/null || true; fi

if [ "$status" -ne 0 ] && [ -n "$error_file" ] && rate_limited_response && { [ -n "$agent_quota_dir" ] || [ "$budget_enabled" -eq 1 ]; }; then
  probe_rate_limit
  observation=$rate_limit_observation
  unset rate_limit_observation
  set -- $observation
  exhausted=0

  if [ "$#" -eq 4 ]; then
    core_remaining=$1
    core_reset=$2
    graphql_remaining=$3
    graphql_reset=$4

    case "$core_remaining:$core_reset" in
      0:[0-9]*)
        publish_hold "core-hold" "$core_reset"
        budget_delay=$(( (core_reset - $(date -u +%s)) * 1000 ))
        if [ "$budget_delay" -gt 0 ]; then budget_hold resource "$budget_delay" core; fi
        exhausted=1
        ;;
    esac
    case "$graphql_remaining:$graphql_reset" in
      0:[0-9]*)
        publish_hold "graphql-hold" "$graphql_reset"
        budget_delay=$(( (graphql_reset - $(date -u +%s)) * 1000 ))
        if [ "$budget_delay" -gt 0 ]; then budget_hold resource "$budget_delay" graphql; fi
        exhausted=1
        ;;
    esac

    if [ "$exhausted" -eq 1 ]; then
      printf '%s\n' 'aiur: GitHub quota exhausted; exact reset backoff recorded' >&2
    fi
  fi

  # A rate-limit refusal while both primary windows still read healthy is a
  # secondary (abuse) limit. Nothing in the primary windows records it, so
  # without its own backoff the next call retries straight into another
  # rejection. Honour Retry-After when gh exposes it, with GitHub's 60-second
  # guidance as the fallback.
  if [ "$exhausted" -eq 0 ]; then
    secondary_delay=$(secondary_delay_ms "$error_file" "$output_file")
    secondary_wait_seconds=$(( (secondary_delay + 999) / 1000 ))
    secondary_until=$(( $(date -u +%s) + secondary_wait_seconds ))

    case "$resource" in
      core|graphql) publish_hold "$resource-secondary-hold" "$secondary_until" ;;
      *)
        publish_hold "core-secondary-hold" "$secondary_until"
        publish_hold "graphql-secondary-hold" "$secondary_until"
        ;;
    esac

    printf 'aiur: GitHub secondary rate limit; backing off %ss before the next call\n' "$secondary_wait_seconds" >&2
    budget_hold token "$secondary_delay"
  fi
fi

budget_release
if [ -n "$error_file" ]; then rm -f "$error_file" 2>/dev/null || true; fi
if [ -n "$status_file" ]; then rm -f "$status_file" 2>/dev/null || true; fi
if [ -n "$output_file" ]; then rm -f "$output_file" 2>/dev/null || true; fi
exit "$status"
