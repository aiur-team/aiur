# Shared launcher lane command parser. Sourced by aiur-engine.sh.
declare -F aiur_project_join >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/engine/project.sh"
# `aiur lane` is the canonical spelling; `aiur epic set|clear|confirm` parses
# through the same function and prints a deprecation line naming `aiur lane`.
cmd_lane() {
  local action="${1:-}" epic="" who="${USER:-}" source="cli" json=0 ids="" count=0 arg n opts expect="" unconfirmed=0 seen=" "
  [ "$#" -gt 0 ] && shift
  case "$action" in
    set) [ "$#" -gt 0 ] || { echo 'aiur: lane set requires a lane' >&2; exit 64; }; epic="$1"; shift
      [[ "$epic" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || { echo 'aiur: invalid lane key' >&2; exit 64; } ;;
    clear|show|list|confirm) ;;
    *) echo 'aiur: lane requires set, clear, confirm, show or list' >&2; exit 64 ;;
  esac
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=1 ;;
      --unconfirmed) [ "$action" = show ] || { echo 'aiur: --unconfirmed requires show' >&2; exit 64; }; unconfirmed=1 ;;
      --epic)
        [ "$action" = confirm ] && [ "$#" -ge 2 ] || { echo 'aiur: --epic requires confirm and a key' >&2; exit 64; }
        expect="$2"; shift
        [[ "$expect" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || { echo 'aiur: invalid lane key' >&2; exit 64; } ;;
      --lane)
        [ "$action" = confirm ] && [ "$#" -ge 2 ] || { echo 'aiur: --lane requires confirm and a key' >&2; exit 64; }
        expect="$2"; shift
        [[ "$expect" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || { echo 'aiur: invalid lane key' >&2; exit 64; } ;;
      --as)
        [[ "$action" == set || "$action" == clear || "$action" == confirm ]] && [ "$#" -ge 2 ] || { echo 'aiur: invalid --as' >&2; exit 64; }
        who="$2"; shift ;;
      --source)
        [ "$action" = set ] && [ "$#" -ge 2 ] || { echo 'aiur: invalid --source' >&2; exit 64; }
        source="$2"; shift
        [[ "$source" == cli || "$source" == backfill-agent ]] || { echo 'aiur: invalid lane source' >&2; exit 64; } ;;
      -*) echo 'aiur: unknown lane option' >&2; exit 64 ;;
      *)
        [ "$action" != list ] && [[ "$arg" =~ ^#?[1-9][0-9]{0,9}$ ]] || { echo 'aiur: invalid lane ticket id' >&2; exit 64; }
        n="${arg#\#}"; [ "$n" -lt 2147483648 ] || { echo 'aiur: invalid lane ticket id' >&2; exit 64; }
        if [[ "$seen" != *" $n "* ]]; then
          [ -n "$ids" ] && ids="$ids, "; ids="$ids$n"; count=$((count + 1)); seen="$seen$n "
        fi ;;
    esac
    shift
  done
  [ "$count" -le 200 ] || { echo 'aiur: lane accepts at most 200 ids' >&2; exit 64; }
  opts="action: :$action"
  if [[ "$action" == set || "$action" == clear || "$action" == confirm ]]; then
    [ "$count" -gt 0 ] && [[ "$who" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo 'aiur: lane write requires ids and a valid --as or USER' >&2; exit 64; }
    [ "$action" = set ] && opts="$opts, epic: Base.decode64!(\"$(encode_control_value "$epic")\")"
    opts="$opts, ids: [$ids]"
    [ -n "$expect" ] && opts="$opts, expect_epic: Base.decode64!(\"$(encode_control_value "$expect")\")"
    opts="$opts, who: Base.decode64!(\"$(encode_control_value "$who")\")"
    [ "$action" = set ] && { if [ "$source" = cli ]; then opts="$opts, source: :cli"; else opts="$opts, source: :\"backfill-agent\""; fi; }
  elif [ "$count" -gt 0 ]; then
    opts="$opts, ids: [$ids]"
  fi
  [ "$unconfirmed" -eq 1 ] && opts="$opts, unconfirmed: true"
  [ "$json" -eq 1 ] && opts="$opts, json: true"
  aiur_project_join opts
  run_control_rpc "Aiur.AgentControlCLI.lane([$opts])"
}
