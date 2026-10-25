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

  if [ "$command" = accounts ] && [ -n "$positional" ]; then
    case "$positional" in
      claude|codex)
        [ "$all" = false ] || die "accounts cannot combine --all with a provider"
        provider="$positional"
        ;;
      *) die "accounts harness filters are unavailable in usage; use $replacement" ;;
    esac
  fi

  if [ "$command" = ticket-usage ]; then
    [[ "$positional" =~ ^[1-9][0-9]*$ ]] || die "ticket-usage requires a numeric ticket id; use $replacement for the ticket usage aggregate"
  fi

  local args=()
  [ -z "$provider" ] || args+=("$provider")
  [ "$json" = false ] || args+=(--json)
  cmd_usage "${args[@]}"
}
