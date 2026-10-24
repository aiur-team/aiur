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
AIUR_ENGINE_MODULES="identity oneshot dotenv run processes reap instance session remote control commands executor_commands report_commands test-private-state lifecycle handoff upgrade pre_pr ticket ticket_usage"
for __aiur_engine_module in $AIUR_ENGINE_MODULES; do
  [ -f "$engine_dir/engine/$__aiur_engine_module.sh" ] ||
    die "missing engine module: $engine_dir/engine/$__aiur_engine_module.sh"
  source "$engine_dir/engine/$__aiur_engine_module.sh"
done
unset __aiur_engine_module

usage() {
  cat <<'EOF'
Usage: aiur [--interactive] [--no-dashboard] [--executor] [--pause] [--max-agents <n>] [--logs-root <path>] [--port <port>] [--host <host>] [config-path]
       aiur --instance <name> <command>  run a supported control command against a named remote instance
       aiur run [--bg] [--no-dashboard] [--executor] [--debug]  explicit launch form (foreground unless --bg)
       aiur init [--force]   scaffold .aiur/config (interactive setup wizard)
       aiur login <harness> <name> [--dir <path>]  sign in to a supported backend account
       aiur accounts [<harness>] [--json]  list registered accounts
       aiur logout <harness> <name> [--purge]  remove a backend account
       aiur --bg [--no-dashboard] [--executor] [--debug]   start detached; dashboard on unless suppressed
       aiur stop             stop the running session
       aiur restart [--keep-agents] [--no-build] [run flags]  stop, refresh the build, start again (detached)
       aiur status [--handoff [--json]]  show agent status or last handoff
       aiur agents [--json]   show each agent's state + current activity
       aiur commands [<decision-id>] [--filter all|open|blocking|resolved] [--blocking] [--ticket <id>] [--search <text>] [--cursor <cursor>] [--limit <n>] [--json]
       aiur executor-answer <decision-id> --expected-version <n> (--option <id>|--custom-response <text>) --rationale <text> --idempotency-key <key> [--supersede] [--executor-id <id>]
       aiur answer <decision-id> (--option <id>|--custom-response <text>) --operator
       aiur executor-escalate <decision-id> --expected-version <n> --reason <text> [--executor-id <id>]
       aiur executor-reclassify <decision-id> --expected-version <n> --rationale <text> [--executor-id <id>]
       aiur executor-moot <decision-id> --expected-version <n> --reason-class <class> [--reason <text>] [--executor-id <id>]
       aiur units [--scope live|unfinished|all|none] [--condition active|alert|paused|queued|finished]... [--format auto|table|records] [--json]
       aiur queue show [--queue NAME] [--json]  read queue; add/remove/reorder/order/hold/release/recover/clear steer it
       aiur build-orders [<root>] [--json]  show the Build Order catalog or one root
       aiur ticket estimate <id> [<hours> | --clear] [--reason <text>] [--by <who>] [--json]
       aiur epic set <epic> <ids...> [--as <who>] [--source cli|backfill-agent] [--json]
       aiur epic clear <ids...> [--as <who>] [--json]
       aiur epic show [<ids...>] [--json]
       aiur epic list [--json]
       aiur feature create <slug> --label <text> [--hue <0-359>] [--epic <key>=<label>]... [--as <who>] [--json]
       aiur feature add <slug> <ids...> [--epic <key>] [--move] [--source backfill-agent] [--as <who>] [--json]
       aiur feature remove <slug> <ids...> [--as <who>] [--json]
       aiur feature also <slug> <ids...> [--remove] [--as <who>] [--json]
       aiur feature baseline <slug> [--replace] [--as <who>] [--json]
       aiur feature edit <slug> [--label <text>] [--hue <0-359>] [--end now|<ISO-8601>] [--add-epic <key>=<label>]... [--as <who>] [--json]
       aiur feature show [<slug>] [--json]
       aiur analytics [--range run|full] [--since <ISO-8601>] [--until <ISO-8601>] [--build-order <id>] [--json]
       aiur github-cost [--budget graphql|core|all] [--format auto|table|records] [--json]  rank GitHub API spend by call site
       aiur experiments list [--status <status>] [--kind before_after|ab] [--json]
       aiur experiments abandon <id> --reason <text> --confirm [--json]
       aiur experiments show <id> [--json] | freeze <id> [--window before|after|observation] [--reason <text>] [--json]
       aiur experiments events <id> [--json] [--refresh]
       aiur experiments create --from <file|-> | --title <title> --line <type>:<ref>[@time] --metric <pack>/<metric>[:direction] [--draft] [--no-freeze] [--json]
       aiur capabilities [--json]  read-only instance capability report
       aiur github-usage [--json]  per-actor (daemon vs agent) GitHub usage and ceilings
       aiur ticket-usage <ticket> [--json]  one ticket's model usage per session, model and provider
       aiur alerts [--needs-attention] [--limit <n> | --all] | ack ticket.<id>.agent.attention.duplicate-dispatch --executor-id <id>  show or acknowledge duplicate-dispatch alerts
       aiur executor-sweep [--json] [--apply]  inspect local Executor findings
       aiur watch [--full|--changes] [--interval <secs>]  server-side status board
       aiur listen [--topic <pattern> | --ticket <id>]  stream events as JSON lines
       aiur executor-listen [--topic <pattern>]  deprecated alias for listen
       aiur executor-wait [--timeout <seconds>] [--session-id <uuid> [--harness codex]] [--json]  block until Executor work arrives
       aiur executor-fast-forward <wake-id> [--as <id>]  acknowledge an externally covered wake prefix
       aiur executor-emit <topic> --payload <json>  publish an Executor event
       aiur executor-subscribe|executor-unsubscribe <pattern>
       aiur executor-subscriptions  list persistent Executor bindings
       aiur workspace-recover <ticket-identifier> <generation>  release a held workspace after verified provider exit
       aiur executor-roster [--json]  list Executor consumers; executor-session [--json] reads the live Executor harness session
       aiur executor-claim [--as <id>]  claim the wake stream, or refuse and name the live owner
       aiur executor-release [--as <id>]  give up this consumer's claim
       aiur executor-revoke <consumer-id>  operator-only revoke of a live owner's claim
       aiur set max-agents <n>   change the concurrent-agent cap at runtime
       aiur upgrade [--force]   install the newer aiur-cli on your channel
       aiur pause | resume             flip the global pause switch (whole daemon)
       aiur pause <ids|--all> | resume <ids|--all> | park <ids>  per-agent pause/resume or release a paused reservation
       aiur take <id> | release <id>  mark or release an Executor-owned ticket
       aiur message <id> [--message-id ID] <text>  send Executor text to a running agent
       aiur --todo <ids...> [--only]  queue tickets; optionally dequeue all other pending tickets
       aiur pr merge <N> --reviewed-sha <sha> [--dry-run] [--approve-body-file <file>] [--inherited <check>]
       aiur findings [--unfiled] [--slugs] [--scope aiur|repo]  inspect host-local findings
       aiur findings --record <json> --repo <owner/repo>  append one validated finding
       aiur findings --digest [--scope aiur|repo]  generate the promoted Markdown digest
       aiur ask <title> [--body <text>|--body-file <path>] [--urgency low|normal|high] [--blocking]
       aiur ask --done <id> [--note <text>]  create or resolve an operator request
       aiur asks [--open|--all] [--json]  inspect current-repository operator requests
       aiur doctor [--repair]         check mise shims; repair only with consent
       aiur cleanup-stale [--dry-run]  list/reap stale manual-smoke leftovers
       aiur pre-pr           merge origin/main locally and run cheap PR gates
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
  # Only an explicit first-argument flag may select a remote target. Clear any
  # inherited value before parsing so a leaked shell variable cannot redirect
  # a direct shared-engine invocation.
  unset AIUR_REMOTE_INSTANCE
  case "${1:-}" in
    --instance)
      [ "$#" -gt 1 ] && [ -n "${2:-}" ] || { echo "aiur: --instance requires a name" >&2; return 64; }
      export AIUR_REMOTE_INSTANCE="$2"
      shift 2
      ;;
    --instance=*)
      export AIUR_REMOTE_INSTANCE="${1#--instance=}"
      shift
      ;;
  esac

  local cmd="${1:-}"
  # Names the running subcommand in control-RPC diagnostics so a failure says
  # which command failed instead of a generic "control rpc" (#1684).
  AIUR_CONTROL_COMMAND="${cmd:-run}"
  if [ -n "${AIUR_REMOTE_INSTANCE:-}" ]; then
    validate_remote_instance_name || return $?
    ensure_remote_command_allowed "$@" || return $?
  fi
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
    pr)
      export AIUR_PR_MERGE_ENGINE="$engine_source"
      run_local_cli "$@"
      ;;
    __pr-merge-state)
      run_control_rpc "Aiur.PrMerge.Record.print_watcher_state()"
      ;;
    __pr-merge-record)
      run_control_rpc "Aiur.PrMerge.Record.publish(\"$(encode_control_value "${2:-}")\" |> Base.decode64!())"
      ;;
    findings)
      run_findings "$@"
      ;;
    ask | asks)
      run_asks "$@"
      ;;
    # @cli-reference aiur --bg | Starts detached headless execution. Against an existing live session it exits successfully and names bare `aiur` as the attach command. A default headless session has no agent-list or chat panes; use the dashboard or control commands. | aiur --bg
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
    answer)
      shift
      cmd_operator_answer "$@"
      ;;
    executor-escalate)
      shift
      cmd_executor_escalate "$@"
      ;;
    executor-reclassify)
      shift
      cmd_executor_reclassify "$@"
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
    ticket) shift; cmd_ticket "$@" ;;
    epic) shift; cmd_epic "$@" ;;
    feature) shift; cmd_feature "$@" ;;
    build-orders)
      shift
      cmd_build_orders "$@"
      ;;
    analytics) shift; cmd_analytics "$@" ;;
    github-cost) shift; cmd_github_cost "$@" ;;
    experiments) shift; cmd_experiments "$@" ;;
    capabilities)
      shift; cmd_capabilities "$@" ;;
    ticket-usage) shift; cmd_ticket_usage "$@" ;;
    github-usage)
      shift
      cmd_github_usage "$@"
      ;;
    alerts)
      shift
      cmd_alerts "$@"
      ;;
    executor-sweep)
      shift
      cmd_executor_sweep "$@"
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
    executor-roster | executor-session)
      shift; "cmd_${cmd//-/_}" "$@" ;;
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
    pause | resume | park | take | release)
      shift
      case "$cmd" in
        take | release) cmd_executor_ownership "$cmd" "$@" ;;
        *) cmd_pause_resume "$cmd" "$@" ;;
      esac
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
    pre-pr)
      shift
      cmd_pre_pr "$@"
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
source "$(dirname "${BASH_SOURCE[0]}")/aiur-daemon-supervisor.sh"
source "$(dirname "${BASH_SOURCE[0]}")/aiur-queue.sh"
source "$(dirname "${BASH_SOURCE[0]}")/aiur-epic.sh"
source "$(dirname "${BASH_SOURCE[0]}")/aiur-feature.sh"
source "$(dirname "${BASH_SOURCE[0]}")/aiur-capabilities.sh"
source "$(dirname "${BASH_SOURCE[0]}")/aiur-executor-session.sh"
source "$(dirname "${BASH_SOURCE[0]}")/aiur-experiments.sh"
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  aiur_engine_main "$@"
fi
