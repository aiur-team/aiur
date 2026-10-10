#!/usr/bin/env bash
#
# Shared aiur launcher engine.
#
# Owns every aiur subcommand. Both the installed `aiur` (bin/aiur.js) and the dev
# `aiurdev` (scripts/aiurdev) exec this one engine, differing only in which
# release is run:
#
#   AIUR_RELEASE_DIR    release dir whose bin/aiur is exec'd (required; set by the caller)
#
# There is a single `aiur` distribution identity (node/cookie/session). aiurdev
# shares it. The identity vars resolve to the fixed `aiur` values; they remain
# overridable only so tests can redirect state to a temp dir:
#
#   AIUR_BG_STATE_DIR   cookie + state dir  (default: ~/.config/aiur)
#   AIUR_COOKIE_FILE    cookie file         (default: $AIUR_BG_STATE_DIR/cookie)
#   AIUR_SESSION_PREFIX tmux session prefix (default: aiur)
#   AIUR_PROFILES_FILE  profiles file       (default: ~/.config/aiur/aiur.profiles)
#   AIUR_RELEASE_NODE   full node name      (default: aiur-$USER@127.0.0.1)
#
# The release is self-contained (bundled ERTS), so it runs without mise/Elixir on
# PATH. Dev's build-if-stale step lives in the aiurdev shim, not here.
set -euo pipefail
# Raise the soft open-file limit toward the hard maximum. High agent concurrency
# spawns many tmux/opencode/git subprocesses + sockets; on hosts with a low
# default (macOS ships 256) that exhausts file descriptors (:emfile) and crashes
# the node. Soft<=hard needs no privilege; best-effort, never fatal.
__aiur_hard_nofile="$(ulimit -Hn 2>/dev/null || echo)"
if [ "${__aiur_hard_nofile}" = "unlimited" ]; then
  ulimit -Sn 65536 2>/dev/null || true
elif [ -n "${__aiur_hard_nofile}" ]; then
  ulimit -Sn "${__aiur_hard_nofile}" 2>/dev/null || true
fi
unset __aiur_hard_nofile
# Export the effective soft limit after the best-effort raise. The BEAM uses
# this inherited value for FD-headroom admission on hosts without procfs,
# avoiding a runtime `ulimit` subprocess precisely when descriptors are scarce.
__aiur_soft_nofile="$(ulimit -Sn 2>/dev/null || echo)"
if [[ "$__aiur_soft_nofile" =~ ^[0-9]+$ ]]; then
  export AIUR_NOFILE_SOFT_LIMIT="$__aiur_soft_nofile"
else
  unset AIUR_NOFILE_SOFT_LIMIT
fi
unset __aiur_soft_nofile
# Preserve the shell that initiated the run as a best-effort Executor root.
# An explicit positive override wins (service managers may know a better root);
# otherwise the engine's parent is the nearest identity available before tmux
# hands daemon ownership to its pane launcher.
if ! [[ "${AIUR_OPERATOR_PID:-}" =~ ^[1-9][0-9]*$ ]]; then
  if [[ "${PPID:-}" =~ ^[1-9][0-9]*$ ]]; then
    export AIUR_OPERATOR_PID="$PPID"
  else
    unset AIUR_OPERATOR_PID
  fi
fi
die() {
  echo "❌ $*" >&2
  exit 1
}

engine_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
engine_source="${BASH_SOURCE[0]}"

# Every other function lives in a sibling module. A missing one fails here, by
# path, instead of as "command not found" halfway through a run.
AIUR_ENGINE_MODULES="identity oneshot dotenv run processes reap instance session control commands executor_commands report_commands lifecycle upgrade"
for __aiur_engine_module in $AIUR_ENGINE_MODULES; do
  [ -f "$engine_dir/engine/$__aiur_engine_module.sh" ] ||
    die "missing engine module: $engine_dir/engine/$__aiur_engine_module.sh"
  source "$engine_dir/engine/$__aiur_engine_module.sh"
done
unset __aiur_engine_module

usage() {
  cat <<'EOF'
Usage: aiur [--interactive] [--no-dashboard] [--executor] [--pause] [--max-agents <n>] [--logs-root <path>] [--port <port>] [--host <host>] [config-path]
       aiur run [--bg] [--no-dashboard] [--executor] [--debug]  explicit launch form (foreground unless --bg)
       aiur init [--force]   scaffold .aiur/config (interactive setup wizard)
       aiur login <harness> <name> [--dir <path>]  sign in to a supported backend account
       aiur accounts [<harness>] [--json]  list registered accounts
       aiur logout <harness> <name> [--purge]  remove a backend account
       aiur --bg [--no-dashboard] [--executor] [--debug]   start detached; dashboard on unless suppressed
       aiur stop             stop the running session
       aiur restart [--no-build] [run flags]  stop, refresh the build, start again (detached)
       aiur status           show agent status
       aiur agents           show each agent's state + current activity
       aiur commands [<decision-id>] [--filter all|open|blocking|resolved] [--blocking] [--ticket <id>] [--search <text>] [--cursor <cursor>] [--limit <n>] [--json]
       aiur executor-answer <decision-id> --expected-version <n> (--option <id>|--custom-response <text>) --rationale <text> --idempotency-key <key> [--supersede] [--executor-id <id>]
       aiur executor-escalate <decision-id> --expected-version <n> --reason <text> [--executor-id <id>]
       aiur executor-moot <decision-id> --expected-version <n> --reason-class <class> [--reason <text>] [--executor-id <id>]
       aiur units [--scope live|unfinished|all|none] [--condition active|alert|paused|queued|finished]... [--format auto|table|records] [--json]
       aiur queue show [--queue NAME] [--json]  read queue; add/remove/reorder/hold/release/recover/clear steer it
       aiur build-orders [<root>] [--json]  show the Build Order catalog or one root
       aiur epic set <epic> <ids...> [--as <who>] [--source cli|backfill-agent] [--json]
       aiur epic clear <ids...> [--as <who>] [--json]
       aiur epic show [<ids...>] [--json]
       aiur epic list [--json]
       aiur analytics [--range run|full] [--since <ISO-8601>] [--until <ISO-8601>] [--build-order <id>] [--json]
       aiur github-cost [--budget graphql|core|all] [--format auto|table|records] [--json]  rank GitHub API spend by call site
       aiur capabilities [--json]  read-only instance capability report
       aiur github-usage [--json]  per-actor (daemon vs agent) GitHub usage and ceilings
       aiur alerts [--needs-attention]  show structured alert feed
       aiur watch [--full|--changes] [--interval <secs>]  server-side status board
       aiur listen [--topic <pattern> | --ticket <id>]  stream events as JSON lines
       aiur executor-listen [--topic <pattern>]  deprecated alias for listen
       aiur executor-wait [--timeout <seconds>] [--json]  block until Executor work arrives
       aiur executor-fast-forward <wake-id> [--as <id>]  acknowledge an externally covered wake prefix
       aiur executor-emit <topic> --payload <json>  publish an Executor event
       aiur executor-subscribe|executor-unsubscribe <pattern>
       aiur executor-subscriptions  list persistent Executor bindings
       aiur workspace-recover <ticket-identifier> <generation>  release a held workspace after verified provider exit
       aiur executor-roster [--json]  list Executor consumers with their liveness evidence
       aiur executor-claim [--as <id>]  claim the wake stream, or refuse and name the live owner
       aiur executor-release [--as <id>]  give up this consumer's claim
       aiur executor-revoke <consumer-id>  operator-only revoke of a live owner's claim
       aiur set max-agents <n>   change the concurrent-agent cap at runtime
       aiur upgrade [--force]   install the newer aiur-cli on your channel
       aiur pause | resume             flip the global pause switch (whole daemon)
       aiur pause <ids|--all> | resume <ids|--all>  per-agent pause/resume
       aiur message <id> [--message-id ID] <text>  send Executor text to a running agent
       aiur --todo <ids...> [--only]  queue tickets; optionally dequeue all other pending tickets
       aiur findings [--unfiled] [--slugs] [--scope aiur|repo]  inspect host-local findings
       aiur findings --record <json> --repo <owner/repo>  append one validated finding
       aiur findings --digest [--scope aiur|repo]  generate the promoted Markdown digest
       aiur ask <title> [--body <text>|--body-file <path>] [--urgency low|normal|high] [--blocking]
       aiur ask --done <id> [--note <text>]  create or resolve an operator request
       aiur asks [--open|--all] [--json]  inspect current-repository operator requests
       aiur doctor [--repair]         check mise shims; repair only with consent
       aiur cleanup-stale [--dry-run]  list/reap stale manual-smoke leftovers
       aiur --version
Bare aiur: start or attach to this directory's interactive session.
EOF
}

# --- dispatch ----------------------------------------------------------------
dispatch_run() {
  [ ! -f "$engine_dir/aiur-mise-doctor" ] || bash "$engine_dir/aiur-mise-doctor" --check || true
  local mode="foreground" arg
  local args=()

  reject_legacy_config "$@"

  for arg in "$@"; do
    if [ "$arg" = "--bg" ]; then
      mode="background"
    else
      args+=("$arg")
    fi
  done

  # bash 3.2 (macOS default) errors on "${args[@]}" when args is empty under
  # `set -u` — happens for a bare `--bg` run. Guard the expansion.
  run_session "$mode" "${args[@]+"${args[@]}"}"
}
aiur_engine_main() {
  local cmd="${1:-}"
  # Names the running subcommand in control-RPC diagnostics so a failure says
  # which command failed instead of a generic "control rpc" (#1684).
  AIUR_CONTROL_COMMAND="${cmd:-run}"
  case "$cmd" in
    __identity)
      aiur_print_identity
      ;;
    help | -h | -help | --h | --help)
      usage
      ;;
    --version)
      run_version "$@"
      ;;
    --todo)
      run_todo "$@"
      ;;
    --only)
      echo "aiur: --only is valid only with --todo" >&2
      exit 64
      ;;
    init)
      run_init "$@"
      ;;
    login)
      run_account_login "$@"
      ;;
    accounts)
      shift
      cmd_accounts "$@"
      ;;
    logout)
      run_local_cli "$@"
      ;;
    findings)
      run_findings "$@"
      ;;
    ask | asks)
      run_asks "$@"
      ;;
    --bg)
      dispatch_run "$@"
      ;;
    run)
      shift
      dispatch_run "$@"
      ;;
    doctor) shift; exec bash "$engine_dir/aiur-mise-doctor" "$@" ;;
    status)
      shift
      cmd_status "$@"
      ;;
    usage)
      shift
      cmd_usage "$@"
      ;;
    agents)
      shift
      cmd_agents "$@"
      ;;
    commands)
      shift
      cmd_commands "$@"
      ;;
    executor-answer)
      shift
      cmd_executor_answer "$@"
      ;;
    executor-escalate)
      shift
      cmd_executor_escalate "$@"
      ;;
    executor-moot)
      shift
      cmd_executor_moot "$@"
      ;;
    units)
      shift
      cmd_units "$@"
      ;;
    queue)
      shift
      cmd_queue "$@"
      ;;
    epic) shift; cmd_epic "$@" ;;
    build-orders)
      shift
      cmd_build_orders "$@"
      ;;
    analytics)
      shift
      cmd_analytics "$@"
      ;;
    github-cost)
      shift
      cmd_github_cost "$@"
      ;;
    capabilities)
      shift; cmd_capabilities "$@" ;;
    github-usage)
      shift
      cmd_github_usage "$@"
      ;;
    alerts)
      shift
      cmd_alerts "$@"
      ;;
    watch)
      shift
      cmd_watch "$@"
      ;;
    listen|executor-listen)
      shift
      cmd_listen "$@"
      ;;
    executor-wait)
      shift
      cmd_executor_wait "$@"
      ;;
    executor-emit)
      shift
      cmd_executor_emit "$@"
      ;;
    executor-subscribe | executor-unsubscribe)
      shift
      cmd_executor_subscription "$cmd" "$@"
      ;;
    executor-subscriptions)
      shift
      cmd_executor_subscriptions "$@"
      ;;
    executor-roster)
      shift
      cmd_executor_roster "$@"
      ;;
    executor-fast-forward)
      shift
      cmd_executor_fast_forward "$@"
      ;;
    executor-claim)
      shift
      cmd_executor_claim "$@"
      ;;
    executor-release)
      shift
      cmd_executor_release "$@"
      ;;
    executor-revoke)
      shift
      cmd_executor_revoke "$@"
      ;;
    set)
      shift
      cmd_set "$@"
      ;;
    upgrade)
      shift
      cmd_upgrade "$@"
      ;;
    pause | resume)
      shift
      cmd_pause_resume "$cmd" "$@"
      ;;
    reset-budget)
      shift
      cmd_reset_budget "$@"
      ;;
    workspace-recover)
      shift
      cmd_workspace_recover "$@"
      ;;
    message)
      shift
      cmd_message "$@"
      ;;
    cleanup-stale)
      shift
      cmd_cleanup_stale "$@"
      ;;
    stop)
      cmd_stop
      ;;
    restart)
      shift
      cmd_restart "$@"
      ;;
    "")
      dispatch_run
      ;;
    -*)
      # leading-flag forms (e.g. `aiur --interactive <config>`) are a run
      dispatch_run "$@"
      ;;
    *)
      # a path/config argument is a run; anything else is a usage error
      if [ -e "$cmd" ]; then
        dispatch_run "$@"
      else
        echo "aiur: unknown command: $cmd" >&2
        warn_if_cli_behind_release_checkout
        usage >&2
        exit 64
      fi
      ;;
  esac
}
source "$(dirname "${BASH_SOURCE[0]}")/aiur-queue.sh"
source "$(dirname "${BASH_SOURCE[0]}")/aiur-epic.sh"
source "$(dirname "${BASH_SOURCE[0]}")/aiur-capabilities.sh"
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  aiur_engine_main "$@"
fi
