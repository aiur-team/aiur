# `aiur analytics` — render the dashboard analytics projection for an explicit
# time window. This is read-only and obtains the same durable telemetry snapshot
# the page uses through the running node.
cmd_analytics() {
  local range="run" json=0 since="" until="" build_order="" has_build_order=0 arg

  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --range) [ "$#" -gt 1 ] || { echo "aiur: analytics --range requires a value" >&2; exit 64; }; shift; range="$1" ;;
      --range=*) range="${arg#--range=}" ;;
      --since) [ "$#" -gt 1 ] || { echo "aiur: analytics --since requires a value" >&2; exit 64; }; shift; since="$1" ;;
      --since=*) since="${arg#--since=}" ;;
      --until) [ "$#" -gt 1 ] || { echo "aiur: analytics --until requires a value" >&2; exit 64; }; shift; until="$1" ;;
      --until=*) until="${arg#--until=}" ;;
      --build-order) [ "$#" -gt 1 ] || { echo "aiur: analytics --build-order requires a value" >&2; exit 64; }; shift; build_order="$1"; has_build_order=1 ;;
      --build-order=*) build_order="${arg#--build-order=}"; has_build_order=1 ;;
      --json) json=1 ;;
      -*) echo "aiur: analytics received an unknown option: $arg" >&2; exit 64 ;;
      *) echo "aiur: analytics does not accept positional arguments" >&2; exit 64 ;;
    esac
    shift
  done

  case "$range" in run|full) ;; *) echo "aiur: analytics --range accepts run or full" >&2; exit 64 ;; esac
  [ "$has_build_order" -eq 0 ] || [[ "$build_order" =~ ^[0-9]+$ ]] || { echo "aiur: analytics --build-order expects a numeric ticket ID" >&2; exit 64; }

  local opts="range: :$range" key raw encoded
  [ "$json" -eq 1 ] && opts="$opts, json: true"
  for key in since until build_order; do
    raw="${!key}"
    [ -n "$raw" ] || continue
    encoded="$(printf '%s' "$raw" | base64 | tr -d '\n')"
    opts="$opts, $key: Base.decode64!(\"$encoded\")"
  done

  run_control_rpc "Aiur.AgentControlCLI.run_command(\"analytics\", Aiur.AnalyticsCLI, [$opts])"
}

register_control_command \
  "analytics" \
  "aiur analytics [--range run|full] [--since <ISO-8601>] [--until <ISO-8601>] [--build-order <id>] [--json]" \
  "cmd_analytics"
