# Shared launcher epic command parser. Sourced by aiur-engine.sh.
declare -F aiur_project_join >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/engine/project.sh"
# `aiur epic create|edit|add|remove|show|list` manage epic records: an epic
# holds features, and a Build Order root projects as one.
# `aiur epic set|clear|confirm` are the deprecated spelling of `aiur lane`, so
# they print the deprecation line on stderr and parse through the lane command.
epic_usage_error() { echo "aiur: $*" >&2; exit 64; }
epic_rpc_string() { printf 'Base.decode64!("%s")' "$(encode_control_value "$1")"; }

cmd_epic() {
  case "${1:-}" in
    set | clear | confirm)
      echo "aiur: epic ${1} is deprecated; use aiur lane ${1}" >&2
      cmd_lane "$@"
      return $?
      ;;
    create | edit | add | remove | show | list) cmd_epic_record "$@" ;;
    *) epic_usage_error 'epic requires create, edit, add, remove, show or list' ;;
  esac
}

cmd_epic_record() {
  local action="${1:-}" slug="" who="${USER:-}" json=0 arg value ids="" count=0 seen=" " edits=0 label_set=0
  [ "$#" -gt 0 ] && shift
  case "$action" in
    create | edit | add | remove)
      [ "$#" -gt 0 ] && [[ "$1" != --* ]] || epic_usage_error "epic $action requires a slug"
      slug="$1"
      [[ "$slug" =~ ^[a-z0-9][a-z0-9-]{0,41}$ ]] || epic_usage_error 'invalid epic slug'
      shift
      ;;
    show)
      if [ "$#" -gt 0 ] && [[ "$1" != --* ]]; then
        slug="$1"
        shift
      fi
      ;;
  esac
  local flags="" opts="action: :$action"
  [ -n "$slug" ] && opts="$opts, slug: $(epic_rpc_string "$slug")"
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=1 ;;
      --as | --label | --icon | --hue | --root)
        [ "$#" -ge 2 ] && [ -n "$2" ] && [[ "$2" != --* ]] || epic_usage_error "$arg requires a value"
        value="$2"
        shift
        case "$arg" in
          --as)
            [ "$action" != show ] && [ "$action" != list ] || epic_usage_error '--as requires an epic write'
            who="$value"
            ;;
          --label)
            [[ "$action" == create || "$action" == edit ]] || epic_usage_error '--label requires epic create or edit'
            label_set=1
            edits=$((edits + 1))
            flags="$flags, label: $(epic_rpc_string "$value")"
            ;;
          --icon)
            [[ "$action" == create || "$action" == edit ]] || epic_usage_error '--icon requires epic create or edit'
            edits=$((edits + 1))
            flags="$flags, icon: $(epic_rpc_string "$value")"
            ;;
          --hue)
            [[ "$action" == create || "$action" == edit ]] || epic_usage_error '--hue requires epic create or edit'
            [[ "$value" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$value))" -le 359 ] || epic_usage_error 'epic hue must be an integer from 0 to 359'
            edits=$((edits + 1))
            flags="$flags, hue: $((10#$value))"
            ;;
          --root)
            [ "$action" = create ] || epic_usage_error '--root requires epic create'
            [[ "$value" =~ ^[1-9][0-9]{0,9}$ ]] && [ "$((10#$value))" -lt 2147483648 ] || epic_usage_error 'epic root must be an issue number below 2147483648'
            flags="$flags, root: $((10#$value))"
            ;;
        esac
        ;;
      -*) epic_usage_error "unknown epic option $arg" ;;
      *)
        [[ "$action" == add || "$action" == remove ]] || epic_usage_error "epic $action does not accept feature slugs"
        [[ "$arg" =~ ^[a-z0-9][a-z0-9-]{0,41}$ ]] || epic_usage_error 'invalid feature slug'
        count=$((count + 1))
        [ "$count" -le 200 ] || epic_usage_error 'epic accepts at most 200 features'
        if [[ "$seen" != *" $arg "* ]]; then
          [ -n "$ids" ] && ids="$ids, "
          ids="$ids$(epic_rpc_string "$arg")"
          seen="$seen$arg "
        fi
        ;;
    esac
    shift
  done
  case "$action" in
    add | remove) [ "$count" -gt 0 ] || epic_usage_error "epic $action requires feature slugs"; opts="$opts, features: [$ids]" ;;
    create) [ "$label_set" -eq 1 ] || epic_usage_error 'epic create requires --label' ;;
    edit) [ "$edits" -gt 0 ] || epic_usage_error 'epic edit requires at least one change' ;;
  esac
  if [[ "$action" == create || "$action" == edit || "$action" == add || "$action" == remove ]]; then
    [[ "$who" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || epic_usage_error 'epic write requires a valid --as or USER'
    opts="$opts, who: $(epic_rpc_string "$who")"
  fi
  opts="$opts$flags"
  [ "$json" -eq 1 ] && opts="$opts, json: true"
  local AIUR_CONTROL_ATTEMPT_CONTEXT="epic $action $slug"
  aiur_project_join opts
  run_control_rpc "Aiur.AgentControlCLI.epic([$opts])"
}
