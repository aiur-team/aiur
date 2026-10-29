# `aiur history export [--unsorted] [--after <n>] [--limit <k>] [--json]` — one
# page of past and open tickets from the daemon's local History store, read
# through the control RPC. Sourced by aiur-engine.sh.
cmd_history() {
  local sub="${1:-}" json=false unsorted=false after=0 limit=200 arg
  if [ "$sub" = "label-writes" ]; then shift; cmd_history_label_writes "$@"; return; fi
  [ "$sub" = "export" ] || { echo "aiur: history: unknown subcommand '${sub}'; expected 'export' or 'label-writes'" >&2; exit 64; }
  shift
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=true ;;
      --unsorted) unsorted=true ;;
      # Guard before shift: under `set -e` a bare shift past the last argument
      # would exit 1 instead of the usage exit 64.
      --after) [ "$#" -gt 1 ] || { echo "aiur: history export --after requires a value" >&2; exit 64; }; shift; after="$1" ;;
      --after=*) after="${arg#--after=}" ;;
      --limit) [ "$#" -gt 1 ] || { echo "aiur: history export --limit requires a value" >&2; exit 64; }; shift; limit="$1" ;;
      --limit=*) limit="${arg#--limit=}" ;;
      *) echo "aiur: history export received an unknown option: $arg" >&2; exit 64 ;;
    esac
    shift
  done
  # Digits only, so every value reaches the RPC expression as a plain integer
  # literal; the length checks keep huge values out of shell arithmetic.
  case "$after" in '' | *[!0-9]*) echo "aiur: history export --after needs a non-negative integer" >&2; exit 64 ;; esac
  [ "${#after}" -le 10 ] || { echo "aiur: history export --after needs a non-negative integer" >&2; exit 64; }
  case "$limit" in '' | *[!0-9]*) echo "aiur: history export --limit needs an integer from 1 to 500" >&2; exit 64 ;; esac
  if [ "${#limit}" -gt 3 ] || [ "$((10#$limit))" -lt 1 ] || [ "$((10#$limit))" -gt 500 ]; then
    echo "aiur: history export --limit needs an integer from 1 to 500" >&2; exit 64
  fi
  run_control_rpc "Aiur.HistoryCLI.rpc([json: $json, unsorted: $unsorted, after: $((10#$after)), limit: $((10#$limit))])"
}

cmd_history_label_writes() {
  local action="${1:-}" json=false epic_labels=false expect="" per_hour=60 arg
  case "$action" in plan|start|pause|resume|status) shift ;; *) echo "aiur: history label-writes: expected plan, start, pause, resume or status" >&2; exit 64 ;; esac
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=true ;;
      --epic-labels) case "$action" in plan|start) epic_labels=true ;; *) echo "aiur: history label-writes: --epic-labels requires plan or start" >&2; exit 64 ;; esac ;;
      --expect)
        [ "$action" = start ] && [ "$#" -gt 1 ] || { echo "aiur: history label-writes: --expect requires start and a value" >&2; exit 64; }
        shift; expect="$1" ;;
      --per-hour)
        [ "$action" = start ] && [ "$#" -gt 1 ] || { echo "aiur: history label-writes: --per-hour requires start and a value" >&2; exit 64; }
        shift; per_hour="$1" ;;
      *) echo "aiur: history label-writes: unknown option $arg" >&2; exit 64 ;;
    esac
    shift
  done
  if [ "$action" = start ]; then
    case "$expect" in ''|*[!0-9]*) echo "aiur: history label-writes: --expect needs a non-negative integer" >&2; exit 64 ;; esac
    [ "${#expect}" -le 10 ] || { echo "aiur: history label-writes: --expect too large" >&2; exit 64; }
  fi
  case "$per_hour" in ''|*[!0-9]*) echo "aiur: history label-writes: --per-hour needs an integer" >&2; exit 64 ;; esac
  [ "${#per_hour}" -le 10 ] || { echo "aiur: history label-writes: --per-hour too large" >&2; exit 64; }
  if [ -n "${AIUR_AGENT_WORKSPACE:-}" ] && { [ "$action" = start ] || [ "$action" = resume ]; }; then
    echo "aiur: history label-writes is refused inside agent workspaces" >&2
    exit 1
  fi
  local options="action: :$action, json: $json, epic_labels: $epic_labels, per_hour: $((10#$per_hour))"
  if [ "$action" = start ]; then options="$options, expect: $((10#$expect))"; fi
  run_control_rpc "Aiur.AgentControlCLI.history_label_writes([$options])"
}
