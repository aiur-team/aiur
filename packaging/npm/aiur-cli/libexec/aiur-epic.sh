# Shared launcher epic command parser. Sourced by aiur-engine.sh.
cmd_epic() {
  local action="${1:-}" epic="" who="${USER:-}" source="cli" json=0 ids="" count=0 arg n opts
  [ "$#" -gt 0 ] && shift
  case "$action" in
    set) [ "$#" -gt 0 ] || { echo 'aiur: epic set requires an epic' >&2; exit 64; }; epic="$1"; shift
      [[ "$epic" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || { echo 'aiur: invalid epic key' >&2; exit 64; } ;;
    clear|show|list) ;;
    *) echo 'aiur: epic requires set, clear, show or list' >&2; exit 64 ;;
  esac
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=1 ;;
      --as)
        [[ "$action" == set || "$action" == clear ]] && [ "$#" -ge 2 ] || { echo 'aiur: invalid --as' >&2; exit 64; }
        who="$2"; shift ;;
      --source)
        [ "$action" = set ] && [ "$#" -ge 2 ] || { echo 'aiur: invalid --source' >&2; exit 64; }
        source="$2"; shift
        [[ "$source" == cli || "$source" == backfill-agent ]] || { echo 'aiur: invalid epic source' >&2; exit 64; } ;;
      -*) echo 'aiur: unknown epic option' >&2; exit 64 ;;
      *)
        [ "$action" != list ] && [[ "$arg" =~ ^#?[1-9][0-9]{0,9}$ ]] || { echo 'aiur: invalid epic ticket id' >&2; exit 64; }
        n="${arg#\#}"; [ -n "$ids" ] && ids="$ids, "; ids="$ids$n"; count=$((count + 1)) ;;
    esac
    shift
  done
  [ "$count" -le 200 ] || { echo 'aiur: epic accepts at most 200 ids' >&2; exit 64; }
  opts="action: :$action"
  if [[ "$action" == set || "$action" == clear ]]; then
    [ "$count" -gt 0 ] && [[ "$who" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo 'aiur: epic write requires ids and a valid --as or USER' >&2; exit 64; }
    [ "$action" = set ] && opts="$opts, epic: Base.decode64!(\"$(encode_control_value "$epic")\")"
    opts="$opts, ids: [$ids], who: Base.decode64!(\"$(encode_control_value "$who")\")"
    [ "$action" = set ] && { if [ "$source" = cli ]; then opts="$opts, source: :cli"; else opts="$opts, source: :\"backfill-agent\""; fi; }
  elif [ "$count" -gt 0 ]; then
    opts="$opts, ids: [$ids]"
  fi
  [ "$json" -eq 1 ] && opts="$opts, json: true"
  run_control_rpc "Aiur.AgentControlCLI.epic([$opts])"
}
