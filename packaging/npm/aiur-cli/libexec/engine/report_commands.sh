# Read-only reporting verbs: units, build orders, analytics, GitHub cost/usage, alerts, watch and listen. Sourced by aiur-engine.sh.

# `aiur units` — read the dashboard Units catalog through its own projection,
# including non-running tickets in current-run membership.
cmd_units() {
  local scope="live" format="" json=0 arg condition condition_value condition_encoded conditions_literal=""
  local -a conditions=() condition_values=()
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --scope) [ "$#" -gt 1 ] || { echo "aiur: units --scope requires a value" >&2; exit 64; }; shift; scope="$1" ;;
      --scope=*) scope="${arg#--scope=}" ;;
      --condition) [ "$#" -gt 1 ] || { echo "aiur: units --condition requires a value" >&2; exit 64; }; shift; conditions+=("$1") ;;
      --condition=*) conditions+=("${arg#--condition=}") ;;
      --format) [ "$#" -gt 1 ] || { echo "aiur: units --format requires a value" >&2; exit 64; }; shift; format="$1" ;;
      --format=*) format="${arg#--format=}" ;;
      --json) json=1 ;;
      -*) echo "aiur: units received an unknown option: $arg" >&2; exit 64 ;;
      *) echo "aiur: units does not accept positional arguments" >&2; exit 64 ;;
    esac
    shift
  done

  for condition in "${conditions[@]+"${conditions[@]}"}"; do
    IFS=',' read -r -a condition_values <<< "$condition"
    for condition_value in "${condition_values[@]+"${condition_values[@]}"}"; do
      if [ -n "$conditions_literal" ]; then conditions_literal="$conditions_literal, "; fi
      condition_encoded="$(printf '%s' "$condition_value" | base64 | tr -d '\n')"
      conditions_literal="${conditions_literal}Base.decode64!(\"${condition_encoded}\")"
    done
  done

  local scope_encoded
  scope_encoded="$(printf '%s' "$scope" | base64 | tr -d '\n')"
  local opts="scope: Base.decode64!(\"$scope_encoded\")"
  [ -z "$conditions_literal" ] || opts="$opts, conditions: [$conditions_literal]"

  if [ -n "$format" ]; then
    local format_encoded
    format_encoded="$(printf '%s' "$format" | base64 | tr -d '\n')"
    opts="$opts, format: Base.decode64!(\"$format_encoded\")"
  fi

  [ "$json" -eq 1 ] && opts="$opts, json: true"
  run_control_rpc "Aiur.AgentControlCLI.units([$opts])"
}

# `aiur build-orders` — read the dashboard Build Order projection without a
# second GitHub or API derivation. A root selector switches from catalog to the
# selected-root graph view.
cmd_build_orders() {
  local json=0 root="" arg

  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=1 ;;
      -*) echo "aiur: build-orders received an unknown option: $arg" >&2; exit 64 ;;
      *)
        if [ -n "$root" ]; then
          echo "aiur: build-orders accepts at most one root" >&2
          exit 64
        fi
        root="$arg"
        ;;
    esac
    shift
  done

  local opts=""
  [ "$json" -eq 1 ] && opts="json: true"

  if [ -n "$root" ]; then
    local encoded
    encoded="$(printf '%s' "$root" | base64 | tr -d '\n')"
    [ -n "$opts" ] && opts="$opts, "
    opts="${opts}root: Base.decode64!(\"$encoded\")"
  fi

  run_control_rpc "Aiur.AgentControlCLI.build_orders([$opts])"
}

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

  run_control_rpc "Aiur.AgentControlCLI.analytics([$opts])"
}

# `aiur github-cost` — GitHub API spend ranked by the call site that caused it,
# in points per hour, with the reconciliation against the credential's own
# `used` figure printed beside it. Read-only; it reads the meter the daemon
# already keeps and issues no GitHub request of its own.
cmd_github_cost() {
  local budget="graphql" format="" json=0 arg

  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --budget) [ "$#" -gt 1 ] || { echo "aiur: github-cost --budget requires a value" >&2; exit 64; }; shift; budget="$1" ;;
      --budget=*) budget="${arg#--budget=}" ;;
      --format) [ "$#" -gt 1 ] || { echo "aiur: github-cost --format requires a value" >&2; exit 64; }; shift; format="$1" ;;
      --format=*) format="${arg#--format=}" ;;
      --json) json=1 ;;
      -*) echo "aiur: github-cost received an unknown option: $arg" >&2; exit 64 ;;
      *) echo "aiur: github-cost does not accept positional arguments" >&2; exit 64 ;;
    esac
    shift
  done

  case "$budget" in graphql|core|all) ;; *) echo "aiur: github-cost --budget accepts graphql, core or all" >&2; exit 64 ;; esac
  case "$format" in ""|auto|table|records) ;; *) echo "aiur: github-cost --format accepts auto, table or records" >&2; exit 64 ;; esac

  # Both values are whitelisted above, so neither reaches the control RPC as
  # anything other than one of the literals named here.
  local opts="budget: \"$budget\""
  [ -z "$format" ] || opts="$opts, format: :$format"
  [ "$json" -eq 1 ] && opts="$opts, json: true"

  run_control_rpc "Aiur.AgentControlCLI.github_cost([$opts])"
}
# `aiur github-usage` — per-actor (daemon vs each agent workspace) Core/GraphQL
# usage and ceilings from the shared admission broker. Read-only; it reads the
# broker database and issues no GitHub request of its own.
cmd_github_usage() {
  local json=0 arg

  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=1 ;;
      -*) echo "aiur: github-usage received an unknown option: $arg" >&2; exit 64 ;;
      *) echo "aiur: github-usage does not accept positional arguments" >&2; exit 64 ;;
    esac
    shift
  done

  local opts=""
  [ "$json" -eq 1 ] && opts="json: true"
  run_control_rpc "Aiur.AgentControlCLI.github_usage([$opts])"
}
# `aiur alerts` — newline-delimited structured alert feed from persisted
# per-agent logs. `--needs-attention` filters to Executor-actionable alerts.
cmd_alerts() {
  local needs_attention=0 arg
  for arg in "$@"; do
    case "$arg" in
      --needs-attention) needs_attention=1 ;;
      *)
        echo "aiur: alerts only accepts --needs-attention" >&2
        exit 64
        ;;
    esac
  done

  if [ "$needs_attention" -eq 1 ]; then
    run_control_rpc "Aiur.AgentControlCLI.alerts(needs_attention: true)"
  else
    run_control_rpc "Aiur.AgentControlCLI.alerts()"
  fi
}

# `aiur watch` — the server-side status board. Compiles one row per active
# agent (state · complexity · activity-age · doing) plus an actionable section
# from aiur's own state, with no GitHub round-trip. `--changes` (default) prints
# only state-level deltas since the last call; `--full` prints every row;
# `--interval N` re-renders every N seconds as a foreground watcher (the Elixir
# call stays one-shot — the loop lives here).
cmd_watch() {
  local mode="changes" interval="" arg

  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --full) mode="full" ;;
      --changes) mode="changes" ;;
      --once) : ;;
      --interval)
        shift
        interval="${1:-}"
        watch_validate_interval "$interval"
        ;;
      --interval=*)
        interval="${arg#--interval=}"
        watch_validate_interval "$interval"
        ;;
      *)
        echo "aiur: watch accepts --full, --changes, --once, --interval <secs>" >&2
        exit 64
        ;;
    esac
    shift
  done

  local expression="Aiur.AgentControlCLI.watch(mode: :${mode})"

  if [ -n "$interval" ]; then
    while true; do
      run_control_rpc "$expression" || true
      sleep "$interval"
    done
  else
    run_control_rpc "$expression"
  fi
}

listen_clock() { printf '%s' "$SECONDS"; }

cmd_listen() {
  local topic="executor.#" ticket="" arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --topic) shift; topic="${1:-}" ;;
      --topic=*) topic="${arg#--topic=}" ;;
      --ticket) shift; ticket="${1:-}" ;;
      --ticket=*) ticket="${arg#--ticket=}" ;;
      *) echo "aiur: listen accepts --topic <pattern> or --ticket <id>" >&2; exit 64 ;;
    esac
    shift
  done
  if [ -n "$ticket" ]; then
    [[ "$ticket" =~ ^[0-9]+$ ]] || { echo "aiur: listen --ticket expects a numeric ticket id" >&2; exit 64; }
    [ "$topic" = "executor.#" ] || { echo "aiur: listen cannot combine --ticket and --topic" >&2; exit 64; }
    topic="ticket.${ticket}.#"
  fi
  [ -n "$topic" ] || { echo "aiur: listen requires a topic" >&2; exit 64; }
  local encoded
  encoded="$(printf '%s' "$topic" | base64 | tr -d '\n')"
  run_control_rpc "Aiur.AgentControlCLI.executor_listen_validate(Base.decode64!(\"$encoded\"))" || return $?
  # A stream that stayed up 30s had a live connection, so losing it starts a
  # new outage. Each outage gets a bounded backoff totalling ~10 minutes, long
  # enough to outlast a normal `aiur restart`.
  # ponytail: attempt duration stands in for "connected"; a wedged daemon whose
  # RPC hangs 30s+ before failing keeps the listener retrying past the budget.
  # Upgrade to a listener-ready signal if that case shows up in practice.
  local waited=0 delay=2 started status
  while :; do
    started="$(listen_clock)"
    status=0
    # Subshell: a `die` inside (e.g. the release dir missing mid-rebuild during
    # `aiurdev restart`) fails this attempt with exit 1 instead of the listener.
    (run_control_stream "Aiur.AgentControlCLI.executor_listen(topic: Base.decode64!(\"$encoded\"))") || status=$?
    [ "$status" -eq 0 ] && return 0
    if [ "$status" -ne 1 ] || [ "${AIUR_LISTEN_RECONNECT:-1}" -ne 1 ]; then
      echo "aiur: listen stopped after streaming control RPC failure (exit ${status}); restart the command after correcting the daemon error" >&2
      return "$status"
    fi
    if [ $(($(listen_clock) - started)) -ge 30 ]; then
      waited=0
      delay=2
    fi
    if [ "$waited" -ge 600 ]; then
      echo "aiur: listen could not reconnect within ${waited} seconds; daemon may be unavailable" >&2
      return 1
    fi
    echo "aiur: listen lost the daemon stream (exit ${status}); reconnecting in ${delay} seconds" >&2
    sleep "$delay"
    waited=$((waited + delay))
    delay=$((delay * 2 > 60 ? 60 : delay * 2))
  done
}

watch_validate_interval() {
  if ! [[ "$1" =~ ^[0-9]+$ ]] || [ "$1" -le 0 ]; then
    echo "aiur: watch --interval expects a positive integer (seconds)" >&2
    exit 64
  fi
}
