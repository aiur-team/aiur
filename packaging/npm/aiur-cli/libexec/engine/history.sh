# `aiur history export [--unsorted] [--after <n>] [--limit <k>] [--json]` — one
# page of past and open tickets from the daemon's local History store, read
# through the control RPC. Sourced by aiur-engine.sh.
cmd_history() {
  local sub="${1:-}" json=false unsorted=false after=0 limit=200 arg
  [ "$sub" = "export" ] || { echo "aiur: history: unknown subcommand '${sub}'; expected 'export'" >&2; exit 64; }
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
