#!/usr/bin/env bash
set -euo pipefail

# Durable, run-scoped hourly retrospective for an Aiur Executor. The helper
# records validated action/no-action observations, summarizes the preceding
# hour, and atomically advances an independent retrospective timer.

mode="${1:-due}"
default_run_id="default"
if [ -n "${AIUR_TMUX_SOCKET:-}" ] && [ -n "${AIUR_TMUX_SESSION:-}" ] && command -v tmux >/dev/null 2>&1; then
  session_id="$(tmux -L "$AIUR_TMUX_SOCKET" display-message -p -t "$AIUR_TMUX_SESSION" '#{session_id}' 2>/dev/null || true)"
  if [[ "$session_id" =~ ^\$([0-9]+)$ ]]; then
    socket_key="${AIUR_TMUX_SOCKET//[^A-Za-z0-9._-]/_}"
    default_run_id="tmux-${socket_key}-${BASH_REMATCH[1]}"
  fi
fi
run_id="${AIUR_EXECUTOR_RUN_ID:-$default_run_id}"
interval_seconds="${AIUR_EXECUTOR_RETROSPECTIVE_SECONDS:-3600}"

# Adaptive quiet-audit wait bounds. Event-driven wakes stay immediate; these
# only bound the fallback timer between quiet audits.
wait_floor_seconds="${AIUR_EXECUTOR_WAIT_FLOOR_SECONDS:-30}"
wait_ceiling_seconds="${AIUR_EXECUTOR_WAIT_CEILING_SECONDS:-900}"
wait_backoff="${AIUR_EXECUTOR_WAIT_BACKOFF:-2}"

if [[ ! "$run_id" =~ ^[A-Za-z0-9._-]+$ ]] || [ "$run_id" = "." ] || [ "$run_id" = ".." ]; then
  printf 'AIUR_EXECUTOR_RUN_ID must match [A-Za-z0-9._-]+, and cannot be . or ..\n' >&2
  # Precondition exit codes are distinct: 67 = URL undiscoverable,
  # 68 = invalid run ID, 69 = dashboard password missing.
  exit 68
fi
if [[ ! "$interval_seconds" =~ ^[1-9][0-9]*$ ]]; then
  printf 'AIUR_EXECUTOR_RETROSPECTIVE_SECONDS must be a positive integer\n' >&2
  exit 64
fi
if [[ ! "$wait_floor_seconds" =~ ^[1-9][0-9]*$ ]]; then
  printf 'AIUR_EXECUTOR_WAIT_FLOOR_SECONDS must be a positive integer\n' >&2
  exit 64
fi
if [[ ! "$wait_ceiling_seconds" =~ ^[1-9][0-9]*$ ]] || [ "$wait_ceiling_seconds" -lt "$wait_floor_seconds" ]; then
  printf 'AIUR_EXECUTOR_WAIT_CEILING_SECONDS must be a positive integer >= the floor\n' >&2
  exit 64
fi
if [[ ! "$wait_backoff" =~ ^[1-9][0-9]*$ ]]; then
  printf 'AIUR_EXECUTOR_WAIT_BACKOFF must be a positive integer\n' >&2
  exit 64
fi

repo_slug="${AIUR_EXECUTOR_REPO:-}"
if [ -z "$repo_slug" ]; then
  remote_url="$(git config --get remote.origin.url 2>/dev/null || true)"
  remote_url="${remote_url%/}"
  remote_url="${remote_url%.git}"
  repo_name="${remote_url##*/}"
  remote_parent="${remote_url%/*}"
  repo_owner="${remote_parent##*:}"
  repo_owner="${repo_owner##*/}"
  if [ -n "$repo_owner" ] && [ -n "$repo_name" ]; then
    repo_slug="$repo_owner/$repo_name"
  fi
fi

case "$repo_slug" in
  */*)
    repo_owner="${repo_slug%%/*}"
    repo_name="${repo_slug#*/}"
    ;;
  *)
    repo_owner=""
    repo_name=""
    ;;
esac

if [[ ! "$repo_owner" =~ ^[A-Za-z0-9._-]+$ ]] ||
   [[ ! "$repo_name" =~ ^[A-Za-z0-9._-]+$ ]] ||
   [ "$repo_owner" = "." ] || [ "$repo_owner" = ".." ] ||
   [ "$repo_name" = "." ] || [ "$repo_name" = ".." ]; then
  if [ -z "${AIUR_EXECUTOR_STATE_DIR:-}" ] || [ -z "${AIUR_EXECUTOR_RETRO_FILE:-}" ]; then
    printf 'AIUR_EXECUTOR_REPO must be owner/repo when the repository cannot be derived from git\n' >&2
    exit 64
  fi
  repo_slug=""
fi

repo_state_root=""
if [ -n "$repo_slug" ]; then
  repo_state_root="${AIUR_EXECUTOR_REPO_STATE_DIR:-${HOME:?HOME is required}/.aiur/repo/$repo_slug}"
fi
state_root="${AIUR_EXECUTOR_STATE_DIR:-$repo_state_root/executor}"

run_dir="$state_root/$run_id"
state_file="$run_dir/retrospective-state.json"
history_file="$run_dir/history.ndjson"
retro_file="${AIUR_EXECUTOR_RETRO_FILE:-$repo_state_root/meta/retros/$run_id.md}"
lock_dir="$run_dir/.retrospective-lock"
lock_owner_marker=""
lock_claim_marker=""
lock_pending_owner_marker=""
# Resolve the physical skill directory. Codex exposes this skill through a
# .codex/skills symlink; keeping the lexical path makes Node normalize the
# sibling aiur-meta lookup under .codex before it follows that symlink.
script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$run_dir"

source "$script_dir/lib/retrospective-state.sh"
source "$script_dir/lib/retrospective-dashboard.sh"

arm() {
  local current at epoch payload
  acquire_lock
  current="$(cat "$state_file")"
  at="$(now_iso)"
  epoch="$(now_epoch)"
  payload="$(jq --arg at "$at" --argjson epoch "$epoch" --argjson interval "$interval_seconds" '
    .retrospective_interval_seconds=$interval |
    .last_retrospective_at=(.last_retrospective_at // $at) |
    .last_retrospective_epoch=(.last_retrospective_epoch // $epoch)
  ' <<< "$current")"
  write_state "$payload"
  unlock
  jq -nc --arg at "$(jq -r '.last_retrospective_at' <<< "$payload")" \
    --arg run_id "$run_id" --argjson interval "$interval_seconds" \
    '{armed:true,run_id:$run_id,last_retrospective_at:$at,interval_seconds:$interval}'
}

due() {
  local now last elapsed remaining is_due
  now="$(now_epoch)"
  last="$(last_epoch)"
  elapsed=$((now - last))
  remaining=$((interval_seconds - elapsed))
  if [ "$remaining" -le 0 ]; then
    remaining=0
    is_due=true
  else
    is_due=false
  fi
  jq -nc --argjson due "$is_due" --argjson elapsed_seconds "$elapsed" \
    --argjson remaining_seconds "$remaining" --arg run_id "$run_id" \
    '{due:$due,run_id:$run_id,elapsed_seconds:$elapsed_seconds,remaining_seconds:$remaining_seconds}'
}

summary() {
  local cutoff_epoch cutoff
  cutoff_epoch=$(( $(now_epoch) - interval_seconds ))
  cutoff="$(jq -nr --argjson epoch "$cutoff_epoch" '$epoch | strftime("%Y-%m-%dT%H:%M:%SZ")')"
  if [ ! -s "$history_file" ]; then
    jq -nc --arg since "$cutoff" --arg run_id "$run_id" \
      '{run_id:$run_id,since:$since,total_wakes:0,action_wakes:0,no_action_wakes:0,malformed_lines:0,no_action_reasons:[],repeated_no_action_reasons:[],count_sentence:("0 wakes (0 action / 0 no-action) since " + $since)}'
    return
  fi

  jq -Rsc --arg since "$cutoff" --arg run_id "$run_id" '
    (split("\n") | map(select(length > 0))) as $lines |
    ([$lines[] | try fromjson catch null]) as $parsed |
    [ $parsed[] | select(type == "object" and (.at // "") >= $since and (.outcome == "action" or .outcome == "no-action")) ] as $events |
    ([ $events[] | select(.outcome == "no-action") | .reason ] | group_by(.) | map({reason:.[0], count:length})) as $reasons |
    ($events|length) as $total |
    ([$events[]|select(.outcome == "action")]|length) as $action |
    ([$events[]|select(.outcome == "no-action")]|length) as $no_action |
    {
      run_id:$run_id,
      since:$since,
      total_wakes:$total,
      action_wakes:$action,
      no_action_wakes:$no_action,
      malformed_lines:([$parsed[]|select(type != "object")]|length),
      no_action_reasons:$reasons,
      repeated_no_action_reasons:[$reasons[]|select(.count > 1)],
      count_sentence:("\($total) wakes (\($action) action / \($no_action) no-action) since \($since)")
    }
  ' "$history_file"
}

observe() {
  local outcome="${2:-}" reason="${3:-}" event
  [ "$#" -eq 3 ] || {
    printf 'usage: %s observe action|no-action <reason>\n' "$0" >&2
    exit 64
  }
  case "$outcome" in
    action|no-action) ;;
    *) printf 'usage: %s observe action|no-action <reason>\n' "$0" >&2; exit 64 ;;
  esac
  [ -n "$reason" ] || {
    printf 'usage: %s observe action|no-action <reason>\n' "$0" >&2
    exit 64
  }
  event="$(jq -nc --arg at "$(now_iso)" --argjson epoch "$(now_epoch)" \
    --arg outcome "$outcome" --arg reason "$reason" --arg run_id "$run_id" \
    '{type:"monitoring_outcome",at:$at,epoch:$epoch,run_id:$run_id,outcome:$outcome,reason:$reason}')"
  acquire_lock
  printf '%s\n' "$event" >> "$history_file"
  unlock
  printf '%s\n' "$event"
}

# Adaptive quiet-audit wait planner. One low-token call per wake records the
# wake reason, its action/no-action outcome, and the next quiet interval so the
# thresholds can be tuned from a real multi-phase run. Event-driven wakes
# (attention, agent-state, PR/CI, daemon, stale, thrash) stay immediate; this
# only governs the fallback timer between quiet audits: an actionable or a
# thrash/stale wake resets it to the floor (watch closely), while each repeated
# no-action quiet audit widens it multiplicatively toward the ceiling.
plan_wait() {
  local category="${2:-}" reason="${3:-}" outcome prev next event current payload
  [ "$#" -eq 3 ] || {
    printf 'usage: %s plan-wait actionable|thrash|stale|quiet <reason>\n' "$0" >&2
    exit 64
  }
  case "$category" in
    actionable|thrash|stale) outcome="action" ;;
    quiet) outcome="no-action" ;;
    *)
      printf 'usage: %s plan-wait actionable|thrash|stale|quiet <reason>\n' "$0" >&2
      exit 64
      ;;
  esac
  [ -n "$reason" ] || {
    printf 'usage: %s plan-wait actionable|thrash|stale|quiet <reason>\n' "$0" >&2
    exit 64
  }

  acquire_lock
  current="$(cat "$state_file")"
  prev="$(jq -r --argjson floor "$wait_floor_seconds" '.last_wait_interval_seconds // $floor' <<< "$current")"
  [[ "$prev" =~ ^[1-9][0-9]*$ ]] || prev="$wait_floor_seconds"

  if [ "$category" = "quiet" ]; then
    next=$((prev * wait_backoff))
    [ "$next" -gt "$wait_ceiling_seconds" ] && next="$wait_ceiling_seconds"
  else
    next="$wait_floor_seconds"
  fi
  [ "$next" -lt "$wait_floor_seconds" ] && next="$wait_floor_seconds"

  event="$(jq -nc --arg at "$(now_iso)" --argjson epoch "$(now_epoch)" \
    --arg outcome "$outcome" --arg reason "$reason" --arg run_id "$run_id" \
    --arg category "$category" --argjson prev "$prev" --argjson next "$next" \
    --argjson floor "$wait_floor_seconds" --argjson ceiling "$wait_ceiling_seconds" \
    '{type:"monitoring_outcome",at:$at,epoch:$epoch,run_id:$run_id,outcome:$outcome,reason:$reason,category:$category,prev_interval_seconds:$prev,next_interval_seconds:$next,wait_floor_seconds:$floor,wait_ceiling_seconds:$ceiling}')"
  printf '%s\n' "$event" >> "$history_file"

  payload="$(jq --argjson next "$next" '.last_wait_interval_seconds=$next' <<< "$current")"
  write_state "$payload"
  unlock
  printf '%s\n' "$event"
}

record() {
  local assessment="${2:-}" adjustment="${3:-unchanged}" at epoch last elapsed report event current payload visual_check_err
  [ -n "$assessment" ] || {
    printf 'usage: %s record <assessment> [adjustment-or-unchanged]\n' "$0" >&2
    exit 64
  }

  acquire_lock
  epoch="$(now_epoch)"
  last="$(last_epoch)"
  elapsed=$((epoch - last))
  if [ "$elapsed" -lt "$interval_seconds" ]; then
    unlock
    jq -nc --arg run_id "$run_id" --argjson remaining_seconds "$((interval_seconds - elapsed))" \
      '{recorded:false,run_id:$run_id,reason:"not_due",remaining_seconds:$remaining_seconds}'
    return
  fi

  at="$(now_iso)"
  report="$(summary)"
  event="$(jq -nc --arg at "$at" --argjson epoch "$epoch" --arg assessment "$assessment" \
    --arg adjustment "$adjustment" --arg run_id "$run_id" --argjson interval "$interval_seconds" \
    --argjson report "$report" \
    '{type:"hourly_retrospective",at:$at,epoch:$epoch,run_id:$run_id,window_seconds:$interval,assessment:$assessment,adjustment:$adjustment,summary:$report}')"
  mkdir -p "$(dirname "$retro_file")"
  printf '## %s\n\n- Bottleneck: %s\n- Adjustment: %s\n- Window: %s\n\n' \
    "$at" "$assessment" "$adjustment" "$(jq -r '.count_sentence' <<< "$report")" >> "$retro_file"
  printf '%s\n' "$event" >> "$history_file"

  current="$(cat "$state_file")"
  payload="$(jq --arg at "$at" --argjson epoch "$epoch" --arg adjustment "$adjustment" --argjson interval "$interval_seconds" '
    .last_retrospective_at=$at |
    .last_retrospective_epoch=$epoch |
    .retrospective_interval_seconds=$interval |
    .last_retrospective_adjustment=$adjustment
  ' <<< "$current")"
  write_state "$payload"
  unlock

  # A retrospective is not complete until it has checked the operator-facing
  # dashboard. Capture failure is itself durable attention evidence, but must
  # not discard the completed wake/outcome summary.
  if [ "${AIUR_EXECUTOR_RETROSPECTIVE_VISUAL_CHECK:-1}" != "0" ]; then
    # The hourly path must not swallow the precondition line the way the
    # wrapper that redirects stdout+stderr to a log does. record still
    # completes and still writes the did-not-run narrative, but one stderr
    # line naming the failing precondition survives, so a redirected log is
    # never silently empty next to a bare exit code.
    visual_check_err="$(mktemp "$run_dir/visual-check.XXXXXX")"
    # Scope the temp file to this block so an interrupted shell or a future
    # `set -e` change cannot strand it in $run_dir.
    trap 'rm -f "$visual_check_err"' EXIT INT TERM
    # `$?` must be read immediately after the visual_check call: any command
    # inserted between the pipeline and this printf would silently change what
    # $? means, and the forwarded line would name the wrong failure.
    visual_check visual-check >/dev/null 2>"$visual_check_err" || \
      printf 'visual check did not run (status %s): %s\n' "$?" "$(head -n 1 "$visual_check_err")" >&2
    rm -f "$visual_check_err"
    trap - EXIT INT TERM
  fi

  # The terminal is an operator-facing surface too. Keep this outside the
  # retrospective lock because each control RPC has its own timeout and a
  # saturated daemon must not prevent the timer state from advancing.
  if [ "${AIUR_EXECUTOR_RETROSPECTIVE_CLI_CHECK:-1}" != "0" ]; then
    cli_check cli-check >/dev/null 2>&1 || true
  fi

  printf '%s\n' "$event"
}


ensure_state

case "$mode" in
  arm) arm ;;
  due) due ;;
  summarize) summary ;;
  observe) observe "$@" ;;
  plan-wait) plan_wait "$@" ;;
  record) record "$@" ;;
  visual-check) visual_check "$@" ;;
  cli-check) cli_check "$@" ;;
  *) printf 'usage: %s arm|due|summarize|observe|plan-wait|record|visual-check|cli-check\n' "$0" >&2; exit 64 ;;
esac
