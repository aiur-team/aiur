# Shared launcher feature parser. Text enters the RPC only through base64.
feature_usage_error() { echo "aiur: $*" >&2; exit 64; }
feature_rpc_string() { printf 'Base.decode64!("%s")' "$(encode_control_value "$1")"; }

cmd_feature() {
  local op="${1:-}" slug="" who="${USER:-}" opts arg value n ids="" seen=" " count=0 edits=0
  [ "$#" -gt 0 ] && shift
  case "$op" in
    create|add|remove|also|baseline|edit)
      [ "$#" -gt 0 ] && [[ "$1" != --* ]] || feature_usage_error "feature $op requires a slug"
      slug="$1"; shift ;;
    show)
      if [ "$#" -gt 0 ] && [[ "$1" != --* ]]; then slug="$1"; shift; fi ;;
    *) feature_usage_error 'feature requires create, add, remove, also, baseline, edit or show' ;;
  esac
  opts="op: :$op"
  [ -n "$slug" ] && opts="$opts, slug: $(feature_rpc_string "$slug")"
  local flags="" epics="" add_epics="" label_set=0 json=0
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=1 ;;
      --move) [ "$op" = add ] || feature_usage_error '--move requires feature add'; flags="$flags, move: true" ;;
      --remove) [ "$op" = also ] || feature_usage_error '--remove requires feature also'; flags="$flags, remove: true" ;;
      --replace) [ "$op" = baseline ] || feature_usage_error '--replace requires feature baseline'; flags="$flags, replace: true" ;;
      --as|--label|--hue|--epic|--add-epic|--end|--source)
        [ "$#" -ge 2 ] && [ -n "$2" ] && [[ "$2" != --* ]] || feature_usage_error "$arg requires a value"
        value="$2"; shift
        case "$arg" in
          --as) [ "$op" != show ] || feature_usage_error '--as requires a feature write'; who="$value" ;;
          --label|--hue|--end|--add-epic)
            [[ "$op" == create || "$op" == edit ]] || feature_usage_error "$arg requires feature create or edit"
            [[ "$arg" != --end && "$arg" != --add-epic || "$op" == edit ]] || feature_usage_error "$arg requires feature edit"
            edits=$((edits + 1))
            case "$arg" in
              --label) label_set=1; flags="$flags, label: $(feature_rpc_string "$value")" ;;
              --hue)
                [[ "$value" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$value))" -le 359 ] || feature_usage_error 'feature hue must be an integer from 0 to 359'
                flags="$flags, hue: $((10#$value))" ;;
              --end) flags="$flags, end: $(feature_rpc_string "$value")" ;;
              --add-epic)
                [[ "$value" == *=* && -n "${value%%=*}" && -n "${value#*=}" ]] || feature_usage_error '--add-epic requires key=label'
                [ -n "$add_epics" ] && add_epics="$add_epics, "
                add_epics="$add_epics%{key: $(feature_rpc_string "${value%%=*}"), label: $(feature_rpc_string "${value#*=}")}" ;;
            esac ;;
          --epic)
            [[ "$op" == create || "$op" == add ]] || feature_usage_error '--epic requires feature create or add'
            if [ "$op" = add ]; then flags="$flags, epic: $(feature_rpc_string "$value")"
            else
              [[ "$value" == *=* && -n "${value%%=*}" && -n "${value#*=}" ]] || feature_usage_error '--epic requires key=label'
              [ -n "$epics" ] && epics="$epics, "
              epics="$epics%{key: $(feature_rpc_string "${value%%=*}"), label: $(feature_rpc_string "${value#*=}")}"
            fi ;;
          --source)
            [ "$op" = add ] && [ "$value" = backfill-agent ] || feature_usage_error '--source accepts only backfill-agent on feature add'
            flags="$flags, source: $(feature_rpc_string "$value")" ;;
        esac ;;
      -*) feature_usage_error "unknown feature option $arg" ;;
      *)
        [[ "$op" == add || "$op" == remove || "$op" == also ]] || feature_usage_error "feature $op does not accept ticket ids"
        [[ "$arg" =~ ^#?[1-9][0-9]{0,9}$ ]] || feature_usage_error 'invalid feature ticket id'
        n="${arg#\#}"; [ "$n" -lt 2147483648 ] || feature_usage_error 'feature ticket id must be below 2147483648'
        count=$((count + 1)); [ "$count" -le 200 ] || feature_usage_error 'feature accepts at most 200 ids'
        if [[ "$seen" != *" $n "* ]]; then
          [ -n "$ids" ] && ids="$ids, "
          ids="$ids$n"; seen="$seen$n "
        fi ;;
    esac
    shift
  done
  case "$op" in
    add|remove|also) [ "$count" -gt 0 ] || feature_usage_error "feature $op requires ticket ids"; opts="$opts, ids: [$ids]" ;;
    create) [ "$label_set" -eq 1 ] || feature_usage_error 'feature create requires --label' ;;
    edit) [ "$edits" -gt 0 ] || feature_usage_error 'feature edit requires at least one edit flag' ;;
  esac
  if [ "$op" != show ]; then
    [[ "$who" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || feature_usage_error 'feature write requires a valid --as or USER'
    opts="$opts, who: $(feature_rpc_string "$who")"
  fi
  opts="$opts$flags"
  [ -n "$epics" ] && opts="$opts, epics: [$epics]"
  [ -n "$add_epics" ] && opts="$opts, add_epics: [$add_epics]"
  [ "$json" -eq 1 ] && opts="$opts, json: true"
  local AIUR_CONTROL_ATTEMPT_CONTEXT="feature $op $slug for $count tickets"
  run_control_rpc "Aiur.AgentControlCLI.feature([$opts])"
}
