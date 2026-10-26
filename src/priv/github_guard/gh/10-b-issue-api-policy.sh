# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
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

