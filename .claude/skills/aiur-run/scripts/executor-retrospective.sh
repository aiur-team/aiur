#!/usr/bin/env bash
set -euo pipefail

# Durable, run-scoped hourly retrospective for an Aiur Executor. The helper
# records validated action/no-action observations, summarizes the preceding
# hour, and atomically advances an independent retrospective timer.

mode="${1:-due}"
run_id="${AIUR_EXECUTOR_RUN_ID:-}"
state_root="${AIUR_EXECUTOR_STATE_DIR:-/tmp/aiur-executor-watch}"
interval_seconds="${AIUR_EXECUTOR_RETROSPECTIVE_SECONDS:-3600}"

if [[ ! "$run_id" =~ ^[A-Za-z0-9._-]+$ ]] || [ "$run_id" = "." ] || [ "$run_id" = ".." ]; then
  printf 'AIUR_EXECUTOR_RUN_ID is required, must match [A-Za-z0-9._-]+, and cannot be . or ..\n' >&2
  exit 64
fi
if [[ ! "$interval_seconds" =~ ^[1-9][0-9]*$ ]]; then
  printf 'AIUR_EXECUTOR_RETROSPECTIVE_SECONDS must be a positive integer\n' >&2
  exit 64
fi

run_dir="$state_root/$run_id"
state_file="$run_dir/retrospective-state.json"
history_file="$run_dir/history.ndjson"
lock_dir="$run_dir/.retrospective-lock"
mkdir -p "$run_dir"

now_epoch() {
  date '+%s'
}

now_iso() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

write_state() {
  local payload="$1" tmp
  tmp="$(mktemp "$run_dir/retrospective-state.XXXXXX")"
  printf '%s\n' "$payload" > "$tmp"
  mv "$tmp" "$state_file"
}

ensure_state() {
  if [ ! -s "$state_file" ]; then
    write_state "$(jq -n --arg run_id "$run_id" '{version:1,run_id:$run_id}')"
  elif [ "$(jq -r '.run_id // empty' "$state_file")" != "$run_id" ]; then
    printf 'retrospective state run ID does not match %s\n' "$run_id" >&2
    exit 65
  fi
}

release_lock() {
  rmdir "$lock_dir" 2>/dev/null || true
}

exit_on_signal() {
  local status="$1"
  release_lock
  trap - EXIT INT TERM
  exit "$status"
}

acquire_lock() {
  local attempt
  for attempt in $(seq 1 200); do
    if mkdir "$lock_dir" 2>/dev/null; then
      trap release_lock EXIT
      trap 'exit_on_signal 130' INT
      trap 'exit_on_signal 143' TERM
      return
    fi
    sleep 0.05
  done
  printf 'timed out waiting for retrospective lock\n' >&2
  exit 75
}

unlock() {
  release_lock
  trap - EXIT INT TERM
}

last_epoch() {
  jq -r '.last_retrospective_epoch // 0' "$state_file"
}

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
      '{run_id:$run_id,since:$since,total_wakes:0,action_wakes:0,no_action_wakes:0,malformed_lines:0,no_action_reasons:[],repeated_no_action_reasons:[]}'
    return
  fi

  jq -Rsc --arg since "$cutoff" --arg run_id "$run_id" '
    (split("\n") | map(select(length > 0))) as $lines |
    ([$lines[] | try fromjson catch null]) as $parsed |
    [ $parsed[] | select(type == "object" and (.at // "") >= $since and (.outcome == "action" or .outcome == "no-action")) ] as $events |
    ([ $events[] | select(.outcome == "no-action") | .reason ] | group_by(.) | map({reason:.[0], count:length})) as $reasons |
    {
      run_id:$run_id,
      since:$since,
      total_wakes:($events|length),
      action_wakes:([$events[]|select(.outcome == "action")]|length),
      no_action_wakes:([$events[]|select(.outcome == "no-action")]|length),
      malformed_lines:([$parsed[]|select(type != "object")]|length),
      no_action_reasons:$reasons,
      repeated_no_action_reasons:[$reasons[]|select(.count > 1)]
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

record() {
  local assessment="${2:-}" adjustment="${3:-unchanged}" at epoch last elapsed report event current payload
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
  printf '%s\n' "$event"
}

ensure_state

case "$mode" in
  arm) arm ;;
  due) due ;;
  summarize) summary ;;
  observe) observe "$@" ;;
  record) record "$@" ;;
  *) printf 'usage: %s arm|due|summarize|observe|record\n' "$0" >&2; exit 64 ;;
esac
