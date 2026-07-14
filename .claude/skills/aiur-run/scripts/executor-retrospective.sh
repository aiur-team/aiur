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
lock_owner_marker=""
lock_claim_marker=""
lock_pending_owner_marker=""
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
  local owner_marker="${lock_owner_marker:-$lock_pending_owner_marker}"

  if [ -n "$owner_marker" ] && rm -- "$owner_marker" 2>/dev/null; then
    rmdir "$lock_dir" 2>/dev/null || true
  fi
  if [ -n "$lock_claim_marker" ]; then
    rm -f -- "$lock_claim_marker"
  fi
  if [ -n "$lock_pending_owner_marker" ] && [ -d "$lock_dir" ] &&
      ! compgen -G "$lock_dir/owner.*" >/dev/null; then
    reclaim_empty_lock || true
  fi

  lock_owner_marker=""
  lock_claim_marker=""
  lock_pending_owner_marker=""
}

exit_on_signal() {
  local status="$1"
  release_lock
  trap - EXIT INT TERM
  exit "$status"
}

marker_pid() {
  local marker_name="${1##*/}" remainder

  case "$marker_name" in
    owner.*) remainder="${marker_name#owner.}" ;;
    .retrospective-lock.claim.*)
      remainder="${marker_name#.retrospective-lock.claim.}"
      ;;
    *) return 1 ;;
  esac

  remainder="${remainder%%-*}"
  [[ "$remainder" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$remainder"
}

process_start_identity() {
  local owner_pid="$1" identity stat rest

  if [ -r "/proc/$owner_pid/stat" ]; then
    IFS= read -r stat < "/proc/$owner_pid/stat" || return 1
    rest="${stat##*) }"
    set -- $rest
    [ "$#" -ge 20 ] || return 1
    printf 'proc:%s\n' "${20}"
    return
  fi

  identity="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$owner_pid" 2>/dev/null)" || return 1
  identity="${identity#"${identity%%[![:space:]]*}"}"
  identity="${identity%"${identity##*[![:space:]]}"}"
  [ -n "$identity" ] || return 1
  printf 'ps:%s\n' "$identity"
}

owner_is_live() {
  local marker="$1" owner_pid recorded_start current_start

  owner_pid="$(marker_pid "$marker")" || return 1
  kill -0 "$owner_pid" 2>/dev/null || return 1
  recorded_start="$(sed -n 's/^started=//p' "$marker" 2>/dev/null | head -n 1)" || return 1

  # Legacy/manual markers without a birth identity remain fail-closed. New
  # markers distinguish the original owner from an unrelated recycled PID.
  [ -n "$recorded_start" ] || return 0
  current_start="$(process_start_identity "$owner_pid")" || return 0
  [ "$current_start" = "$recorded_start" ]
}

live_claim_exists() {
  local claim claim_pid

  for claim in "$run_dir"/.retrospective-lock.claim.*; do
    [ -f "$claim" ] || continue
    if claim_pid="$(marker_pid "$claim")" && owner_is_live "$claim"; then
      return 0
    fi
    rm -- "$claim" 2>/dev/null || true
  done

  return 1
}

reclaim_empty_lock() {
  local recovery_dir="$lock_dir/.reclaiming"

  # A contender publishes its claim before mkdir and keeps it until the owner
  # marker is linked. That closes the otherwise unsafe empty-directory window.
  live_claim_exists && return 1
  mkdir "$recovery_dir" 2>/dev/null || return 1

  if compgen -G "$lock_dir/owner.*" >/dev/null || live_claim_exists; then
    rmdir "$recovery_dir" 2>/dev/null || true
    return 1
  fi

  rmdir "$recovery_dir" 2>/dev/null || return 1
  if rmdir "$lock_dir" 2>/dev/null; then
    printf 'reclaimed abandoned retrospective lock\n' >&2
    return 0
  fi

  return 1
}

reclaim_abandoned_lock() {
  local marker owner_pid owner_count=0 dead_marker=""

  [ -d "$lock_dir" ] || return 1
  for marker in "$lock_dir"/owner.*; do
    [ -f "$marker" ] || continue
    owner_count=$((owner_count + 1))
    dead_marker="$marker"
  done

  if [ "$owner_count" -eq 0 ]; then
    reclaim_empty_lock
    return
  fi

  # Multiple owner markers violate the lock invariant. Fail closed rather than
  # guessing which process owns the critical section.
  [ "$owner_count" -eq 1 ] || return 1
  owner_pid="$(marker_pid "$dead_marker")" || return 1
  owner_is_live "$dead_marker" && return 1

  # Only the contender that removes this exact immutable marker may remove the
  # directory. A competing reclaimer therefore cannot delete a replacement
  # lock created after this owner was found dead.
  rm -- "$dead_marker" 2>/dev/null || return 1
  if rmdir "$lock_dir" 2>/dev/null; then
    printf 'reclaimed abandoned retrospective lock owner_pid=%s\n' "$owner_pid" >&2
    return 0
  fi

  return 1
}

acquire_lock() {
  local attempt owner_pid owner_started owner_token owner_marker claim_marker
  trap release_lock EXIT
  trap 'exit_on_signal 130' INT
  trap 'exit_on_signal 143' TERM

  owner_pid="${BASHPID:-$$}"
  if ! owner_started="$(process_start_identity "$owner_pid")"; then
    printf 'failed to identify retrospective lock owner\n' >&2
    exit 74
  fi

  for attempt in $(seq 1 200); do
    owner_token="$owner_pid-${RANDOM}-${RANDOM}"
    claim_marker="$run_dir/.retrospective-lock.claim.$owner_token"
    owner_marker="$lock_dir/owner.$owner_token"
    lock_claim_marker="$claim_marker"
    lock_pending_owner_marker="$owner_marker"
    printf 'pid=%s\nstarted=%s\ntoken=%s\n' \
      "$owner_pid" "$owner_started" "$owner_token" > "$claim_marker"

    if mkdir "$lock_dir" 2>/dev/null; then
      if ! ln "$claim_marker" "$owner_marker" 2>/dev/null; then
        rm -f -- "$claim_marker"
        lock_claim_marker=""
        lock_pending_owner_marker=""
        rmdir "$lock_dir" 2>/dev/null || true
        printf 'failed to publish retrospective lock owner\n' >&2
        exit 74
      fi
      lock_owner_marker="$owner_marker"
      rm -f -- "$claim_marker"
      lock_claim_marker=""
      return
    fi
    rm -f -- "$claim_marker"
    lock_claim_marker=""
    lock_pending_owner_marker=""
    reclaim_abandoned_lock || true
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
