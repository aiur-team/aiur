# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
direction=read
track=1
resource=unknown
admission_required=1
admission_resource=unknown
endpoint_family=rest
api_paginated=0
# High-level (non-`gh api`) budgeted commands run with `GH_DEBUG=api` so this
# wrapper can observe the HTTP response status. `gh` keeps the status internal
# for those commands, which left every 304 from `pr view`/`issue view`/`search`
# billed as if it had cost quota (#2353). The debug transcript is consumed for
# the reconcile and then stripped, so the caller's stderr is unchanged.
high_level_debug=0

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
  # `/rate_limit` is accepted with or without its leading slash — the same
  # spelling tolerance the GraphQL arm below has — so the free endpoint is
  # never misbooked to `rest`/core (#2353).
  "api rate_limit"|"api /rate_limit") resource=none; endpoint_family=rate_limit ;;
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
  # `gh pr view|list|status|checks`, `gh issue view|list|status`, and
  # `gh search *` speak GraphQL on the wire, so they book to the graphql
  # resource — not core. They KEEP their descriptive families (pulls / issues /
  # search): `endpoint_family` is also the lease-pool key and the audit
  # histogram, so collapsing every GraphQL arm onto one family would merge four
  # in-flight pools into one. The broker's hourly accounting buckets on the
  # booked `resource`, not the family. `pr diff` is REST and stays in the pulls
  # family with resource=core (it must not inherit the graphql booking from its
  # read-arm sibling).
  "pr view"|"pr list"|"pr status"|"pr checks") resource=graphql; endpoint_family=pulls ;;
  "pr diff") resource=core; endpoint_family=pulls ;;
  "issue view"|"issue list"|"issue status") resource=graphql; endpoint_family=issues ;;
  "run view"|"run list"|"run watch") endpoint_family=actions ;;
  # `gh search` splits across two wire transports (measured with GH_DEBUG=api):
  # `search issues|prs` are GraphQL (`X-Ratelimit-Resource: graphql`); `search
  # code|commits|repos|users` hit REST `/search/*`, metered against a third pool,
  # `search` (~30 req/min). The `search` pool is its own resource so something
  # paces against it; booking it to core or graphql mis-states the spend and
  # protects the wrong window.
  "search issues"|"search prs") resource=graphql; endpoint_family=search ;;
  "search code"|"search commits"|"search repos"|"search users") resource=search; endpoint_family=search ;;
  "search "*) resource=search; endpoint_family=search ;;
  # The `pr`/`issue` write subcommands are a GraphQL/REST mix and must be
  # classified per subcommand rather than as one bucket: `pr create|merge|review`
  # and `issue create` mutate through GraphQL; the rest (close, reopen, comment,
  # edit, ready, lock/unlock, update-branch, transfer, ...) are REST. Each keeps
  # its descriptive pulls/issues family for the lease pool and books the resource
  # its wire traffic actually consumes.
  "pr create"|"pr merge"|"pr review") resource=graphql; endpoint_family=pulls; direction=write ;;
  "pr "*) resource=core; endpoint_family=pulls; direction=write ;;
  "issue create") resource=graphql; endpoint_family=issues; direction=write ;;
  "issue "*) resource=core; endpoint_family=issues; direction=write ;;
  "run rerun"|"run cancel"|"run delete") endpoint_family=actions; direction=write ;;
  "label create"|"label delete"|"label edit") endpoint_family=labels; direction=write ;;
  # Commands that change repository state without touching an issue or a pull
  # request. Left classified as reads they invalidated nothing, so
  # `gh repo edit --default-branch` or a release could change what a stored
  # answer says while every agent kept replaying the old one.
  "repo edit"|"repo rename"|"repo archive"|"repo unarchive"|"repo delete"|\
  "release create"|"release edit"|"release delete"|"release upload"|\
  "secret set"|"secret delete"|"variable set"|"variable delete"|\
  "gist create"|"gist edit"|"gist delete"|"cache delete") resource=core; direction=write ;;
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
    rate_limit|/rate_limit)
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
      # its own workpad comment. The #1793 guard is about creating issues, not
      # editing one.
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
      # because it cannot rule out a merge — claiming an opaque body here
      # would mislabel a possible merge as issue creation.
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

