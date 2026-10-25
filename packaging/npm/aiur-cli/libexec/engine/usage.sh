# One launcher module owns the usage namespace and its compatibility aliases.
# @cli-reference aiur usage [<provider>] [--json] | Show a shared usage summary, or one provider's versioned observation envelope. JSON uses the same envelope as the authenticated API. | aiur usage codex --json
cmd_usage() {
  local provider="" json=false arg
  for arg in "$@"; do
    case "$arg" in
      --json) [ "$json" = false ] || die "usage accepts --json only once"; json=true ;;
      -*) die "usage accepts a provider and --json" ;;
      *) [ -z "$provider" ] || die "usage accepts one provider"; provider="$arg" ;;
    esac
  done

  if [ -n "$provider" ] && [[ ! "$provider" =~ ^(claude|codex|github|broker|ticket)$ ]]; then
    die "unknown usage provider: $provider"
  fi
  local encoded_provider expression
  encoded_provider="$(encode_control_value "$provider")"
  expression="Aiur.Usage.CLI.rpc(Base.decode64!(\"$encoded_provider\"), $json)"
  [ -n "$provider" ] || expression="Aiur.Usage.CLI.rpc(nil, $json)"
  run_control_rpc "$expression"
}

usage_alias() {
  local command="$1"
  local replacement provider arg json=false positional="" all=false
  shift
  case "$command" in
    accounts) replacement="aiur usage"; provider="" ;;
    github-cost|github-usage) replacement="aiur usage github"; provider="github" ;;
    ticket-usage) replacement="aiur usage ticket"; provider="ticket" ;;
    *) die "unknown usage alias: $command" ;;
  esac
  echo "aiur: '$command' is deprecated; use '$replacement'" >&2

  # Keep the established GitHub reports during the deprecation release. They
  # expose rankings and the budget/format selectors that the shared snapshot
  # intentionally does not model.
  case "$command" in
    github-cost) cmd_github_cost "$@"; return ;;
    github-usage) cmd_github_usage "$@"; return ;;
  esac

  for arg in "$@"; do
    case "$arg" in
      --json)
        [ "$json" = false ] || die "$command accepts --json only once"
        json=true
        ;;
      --all)
        [ "$command" = accounts ] || die "$command does not accept --all"
        all=true
        ;;
      --*) die "$command does not accept $arg; use $replacement" ;;
      *)
        if [ -z "$positional" ] && { [ "$command" = accounts ] || [ "$command" = ticket-usage ]; }; then
          positional="$arg"
        else
          die "$command accepts at most one positional argument; use $replacement"
        fi
        ;;
    esac
  done

  if [ "$command" = accounts ]; then
    [ "$all" = false ] || [ -z "$positional" ] || die "accounts cannot combine --all with a harness filter"
    # Keep the old account rows and harness filter during the deprecation release.
    if [ -z "${AIUR_REMOTE_INSTANCE:-}" ]; then
      resolve_release || return $?
      prepare_distribution || die "distribution setup failed; cannot contact aiur"
      resolve_control_identity_from_records
    fi
    if [ -z "${AIUR_REMOTE_INSTANCE:-}" ] && [ "$(probe_node_liveness)" = "down" ]; then
      run_local_cli accounts "$@"
      return
    fi

    local encoded_harness expression
    encoded_harness="$(encode_control_value "$positional")"
    expression="Aiur.Usage.CLI.legacy_accounts($json, Base.decode64!(\"$encoded_harness\"))"
    [ -n "$positional" ] || expression="Aiur.Usage.CLI.legacy_accounts($json, nil)"
    run_control_rpc "$expression"
    return
  fi

  if [ "$command" = ticket-usage ]; then
    [[ "$positional" =~ ^[1-9][0-9]*$ ]] || die "ticket-usage requires a numeric ticket id"
    local encoded_ticket expression
    encoded_ticket="$(encode_control_value "$positional")"
    expression="Aiur.TicketUsageCLI.rpc(Base.decode64!(\"$encoded_ticket\"), json: $json)"
    run_control_rpc "$expression"
    return
  fi

  local args=()
  [ -z "$provider" ] || args+=("$provider")
  [ "$json" = false ] || args+=(--json)
  cmd_usage "${args[@]}"
}
