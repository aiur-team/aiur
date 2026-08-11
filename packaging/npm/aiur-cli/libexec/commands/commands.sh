# `aiur commands` — read the dashboard's retained Decision projection without
# exposing any dispatch or answer mutation path.
cmd_commands() {
  local filter="all" blocking=0 json=0 decision_id="" ticket="" search="" cursor="" limit="" arg

  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --filter) [ "$#" -gt 1 ] || { echo "aiur: commands --filter requires a value" >&2; exit 64; }; shift; filter="$1" ;;
      --filter=*) filter="${arg#--filter=}" ;;
      --blocking) blocking=1 ;;
      --ticket) [ "$#" -gt 1 ] || { echo "aiur: commands --ticket requires a value" >&2; exit 64; }; shift; ticket="$1" ;;
      --ticket=*) ticket="${arg#--ticket=}" ;;
      --search) [ "$#" -gt 1 ] || { echo "aiur: commands --search requires a value" >&2; exit 64; }; shift; search="$1" ;;
      --search=*) search="${arg#--search=}" ;;
      --cursor) [ "$#" -gt 1 ] || { echo "aiur: commands --cursor requires a value" >&2; exit 64; }; shift; cursor="$1" ;;
      --cursor=*) cursor="${arg#--cursor=}" ;;
      --limit) [ "$#" -gt 1 ] || { echo "aiur: commands --limit requires a value" >&2; exit 64; }; shift; limit="$1" ;;
      --limit=*) limit="${arg#--limit=}" ;;
      --json) json=1 ;;
      -*) echo "aiur: commands received an unknown option: $arg" >&2; exit 64 ;;
      *)
        if [ -n "$decision_id" ]; then
          echo "aiur: commands accepts at most one decision ID" >&2
          exit 64
        fi
        decision_id="$arg"
        ;;
    esac
    shift
  done

  case "$filter" in all|open|blocking|resolved) ;; *) echo "aiur: commands --filter accepts all, open, blocking, or resolved" >&2; exit 64 ;; esac
  [ -z "$limit" ] || [[ "$limit" =~ ^[1-9][0-9]*$ ]] || { echo "aiur: commands --limit expects a positive integer" >&2; exit 64; }
  [ -z "$ticket" ] || [ "$filter" = "all" ] || { echo "aiur: commands --ticket requires --filter all" >&2; exit 64; }
  [ -z "$search" ] || [ "$filter" = "all" ] || { echo "aiur: commands --search requires --filter all" >&2; exit 64; }

  local opts="filter: :$filter"
  [ "$blocking" -eq 1 ] && opts="$opts, blocking: true"
  [ "$json" -eq 1 ] && opts="$opts, json: true"
  [ -n "$limit" ] && opts="$opts, limit: $limit"
  local key raw encoded
  for key in decision_id ticket search cursor; do
    raw="${!key}"
    [ -n "$raw" ] || continue
    encoded="$(printf '%s' "$raw" | base64 | tr -d '\n')"
    opts="$opts, $key: Base.decode64!(\"$encoded\")"
  done

  run_control_rpc "Aiur.AgentControlCLI.run_command(\"commands\", Aiur.CommandsCLI, [$opts])"
}

register_control_command \
  "commands" \
  "aiur commands [<decision-id>] [--filter all|open|blocking|resolved] [--blocking] [--ticket <id>] [--search <text>] [--cursor <cursor>] [--limit <n>] [--json]" \
  "cmd_commands"
