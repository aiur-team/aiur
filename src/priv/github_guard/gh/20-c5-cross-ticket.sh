# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
# The dispatch gate honors GitHub blocked-by links and labels drive the ticket
# lifecycle, so a worker writing either on a ticket it does not own can stall
# work it does not own. Dependency links go through aiur_declare_blocker, which
# scopes them to the worker's own ticket; labels on other tickets go through an
# Executor decision. The worker's own ticket is the workspace directory name,
# taken from where this script is installed like the agent check above.

ticket_number_of() {
  ticket_ref=${1%/}
  ticket_ref=${ticket_ref##*/}
  ticket_ref=${ticket_ref#\#}
  case "$ticket_ref" in
    ''|*[!0-9]*) printf '%s\n' '?' ;;
    *) printf '%s\n' "$ticket_ref" ;;
  esac
  unset ticket_ref
}

own_ticket_number() {
  own_dir=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd) || own_dir=
  case "$own_dir" in
    */.aiur-runtime/bin) own_dir=${own_dir%/.aiur-runtime/bin} ;;
    *) own_dir=${AIUR_AGENT_WORKSPACE:-} ;;
  esac
  ticket_number_of "$own_dir"
  unset own_dir
}

dependency_link_write() {
  [ "${1:-}" = api ] && [ "$direction" = write ] || return 1

  if [ "$resource" = graphql ]; then
    for link_arg in "$@"; do
      case "$link_arg" in
        *addBlockedBy*|*removeBlockedBy*|*addSubIssue*|*removeSubIssue*|*reprioritizeSubIssue*)
          unset link_arg
          return 0
          ;;
      esac
    done
    unset link_arg
    return 1
  fi

  link_endpoint=$(api_command_endpoint "$@") || link_endpoint=
  link_endpoint=${link_endpoint%%\?*}
  link_endpoint=${link_endpoint%/}
  case "$link_endpoint" in
    */issues/*/dependencies/*|*/issues/*/sub_issue|*/issues/*/sub_issues|*/issues/*/sub_issues/*)
      unset link_endpoint
      return 0
      ;;
  esac
  unset link_endpoint
  return 1
}

# Prints each issue a label write targets, one per line; an unparseable target
# prints `?`, which never matches the worker's own number.
label_write_targets() {
  case "${1:-} ${2:-}" in
    "issue edit")
      shift 2
      label_targets=
      label_seen=0
      label_value_expected=0
      for label_arg in "$@"; do
        if [ "$label_value_expected" -eq 1 ]; then
          label_value_expected=0
          continue
        fi
        case "$label_arg" in
          --add-label|--remove-label) label_seen=1; label_value_expected=1 ;;
          --add-label=*|--remove-label=*) label_seen=1 ;;
          --add-assignee|--remove-assignee|--add-project|--remove-project|--body|--body-file|--milestone|--title|--repo) label_value_expected=1 ;;
          -b|-F|-m|-t|-R) label_value_expected=1 ;;
          -*) : ;;
          *) label_targets="$label_targets$(ticket_number_of "$label_arg")
" ;;
        esac
      done
      [ "$label_seen" -eq 1 ] && printf '%s' "$label_targets"
      unset label_targets label_seen label_value_expected label_arg
      ;;
    api\ *)
      [ "$resource" = core ] && [ "$direction" = write ] || return 0
      label_endpoint=$(api_command_endpoint "$@") || label_endpoint=
      label_endpoint=${label_endpoint%%\?*}
      label_endpoint=${label_endpoint%/}
      label_issue=
      case "$label_endpoint" in
        */issues/*/labels|*/issues/*/labels/*)
          label_issue=${label_endpoint%%/labels*}
          ;;
        */issues/*)
          for label_arg in "$@"; do
            case "$label_arg" in
              labels=*|labels\[\]=*) label_issue=$label_endpoint ;;
            esac
          done
          ;;
      esac
      [ -n "$label_issue" ] && ticket_number_of "$label_issue"
      unset label_endpoint label_issue label_arg
      ;;
  esac
  return 0
}

cross_ticket_label_write() {
  label_own=$(own_ticket_number)
  label_list=$(label_write_targets "$@")
  [ -n "$label_list" ] || { unset label_own label_list; return 1; }

  label_found=1
  while IFS= read -r label_target; do
    if [ "$label_own" = '?' ] || [ "$label_target" != "$label_own" ]; then
      label_found=0
    fi
  done <<EOF
$label_list
EOF
  unset label_own label_list label_target
  return "$label_found"
}

if [ "$agent_guard" -eq 1 ] && { dependency_link_write "$@" || cross_ticket_label_write "$@"; }; then
  printf '%s\n' 'aiur: agents cannot write issue dependencies, or labels on other tickets' >&2
  printf '%s\n' 'aiur: declare your own blocker with aiur_declare_blocker, or raise a decision to the Executor' >&2
  exit 77
fi
