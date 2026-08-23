#!/usr/bin/env bash
set -euo pipefail

# Durable, run-scoped hourly retrospective for an Aiur Executor. The helper
# records validated action/no-action observations, summarizes the preceding
# hour, and atomically advances an independent retrospective timer.

mode="${1:-due}"
run_id="${AIUR_EXECUTOR_RUN_ID:-}"
interval_seconds="${AIUR_EXECUTOR_RETROSPECTIVE_SECONDS:-3600}"

# Adaptive quiet-audit wait bounds. Event-driven wakes stay immediate; these
# only bound the fallback timer between quiet audits.
wait_floor_seconds="${AIUR_EXECUTOR_WAIT_FLOOR_SECONDS:-30}"
wait_ceiling_seconds="${AIUR_EXECUTOR_WAIT_CEILING_SECONDS:-900}"
wait_backoff="${AIUR_EXECUTOR_WAIT_BACKOFF:-2}"

if [[ ! "$run_id" =~ ^[A-Za-z0-9._-]+$ ]] || [ "$run_id" = "." ] || [ "$run_id" = ".." ]; then
  printf 'AIUR_EXECUTOR_RUN_ID is required, must match [A-Za-z0-9._-]+, and cannot be . or ..\n' >&2
  # Precondition exit codes are distinct so a wrapper can tell which
  # precondition failed: 67 = URL undiscoverable, 68 = run ID missing,
  # 69 = dashboard password missing.
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
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Read @aiur_control_url from one tmux server. Aiur publishes it only once the
# HTTP listener is actually bound (src/lib/aiur/pane_manager/anchor.ex), and
# scripts/aiur.tmux.conf seeds the option empty, so both "absent" and "present
# but empty" mean the same thing: this server has no dashboard to offer.
dashboard_url_from_socket() {
  local tmux_bin="$1" socket="$2" url
  if [ -n "$socket" ]; then
    url="$("$tmux_bin" -L "$socket" show-options -gqv @aiur_control_url 2>/dev/null || true)"
  else
    url="$("$tmux_bin" show-options -gqv @aiur_control_url 2>/dev/null || true)"
  fi
  case "$url" in
    http://*|https://*) printf '%s\n' "${url%/}" ;;
    *) return 1 ;;
  esac
}

# Discover the daemon dashboard. Every rung reads a URL that Aiur itself
# published; there is deliberately no port guess. A guessed port cannot tell
# the Aiur dashboard apart from any other listener, and writing a stranger's
# pages into the hourly narrative as if they were the daemon's is worse than
# the explicit attention verdict a failed discovery produces.
#
# On success stdout is "url<TAB>socket": the dashboard URL and the tmux socket
# (empty for the URL override or the ambient server) whose server published
# it. visual_check() reuses the socket for the credential fallback so it reads
# the same daemon whose dashboard it is about to capture, never a sibling
# instance on the host.
dashboard_url() {
  local url tmux_bin socket socket_dir candidate found found_socket

  if [ -n "${AIUR_DASHBOARD_URL:-}" ]; then
    printf '%s\t%s\n' "${AIUR_DASHBOARD_URL%/}" ""
    return 0
  fi

  tmux_bin="$(command -v tmux || true)"
  [ -n "$tmux_bin" ] || return 1

  # 1. The socket the caller named. This is also the disambiguator when more
  # than one Aiur daemon is live on the host.
  if [ -n "${AIUR_TMUX_SOCKET:-}" ]; then
    url="$(dashboard_url_from_socket "$tmux_bin" "$AIUR_TMUX_SOCKET" || true)"
    [ -n "$url" ] && { printf '%s\t%s\n' "$url" "$AIUR_TMUX_SOCKET"; return 0; }
  fi

  # 2. The ambient tmux server, for an Executor running inside the session.
  url="$(dashboard_url_from_socket "$tmux_bin" '' || true)"
  [ -n "$url" ] && { printf '%s\t%s\n' "$url" ""; return 0; }

  # 3. Live aiur-* tmux servers on this host. The Executor usually runs
  # outside the daemon's tmux session, so the ambient server above is its own,
  # not Aiur's; without this sweep discovery can never see the daemon at all.
  socket_dir="${AIUR_TMUX_SOCKET_DIR:-${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)}"
  [ -d "$socket_dir" ] || return 1

  # Prefer a socket that names this run before considering any other.
  if [ -n "${AIUR_EXECUTOR_RUN_ID:-}" ]; then
    for socket in "$socket_dir"/aiur-*"$AIUR_EXECUTOR_RUN_ID"*; do
      [ -S "$socket" ] || continue
      url="$(dashboard_url_from_socket "$tmux_bin" "$(basename "$socket")" || true)"
      [ -n "$url" ] && { printf '%s\t%s\n' "$url" "$(basename "$socket")"; return 0; }
    done
  fi

  # Otherwise accept a sweep result only when it is unambiguous. Several live
  # daemons publishing different URLs means we cannot tell which one this
  # Executor owns, and picking by glob order would silently audit the wrong
  # fleet. Refusing sends the operator to AIUR_TMUX_SOCKET instead.
  found=""
  found_socket=""
  for socket in "$socket_dir"/aiur-*; do
    [ -S "$socket" ] || continue
    candidate="$(dashboard_url_from_socket "$tmux_bin" "$(basename "$socket")" || true)"
    [ -n "$candidate" ] || continue
    if [ -z "$found" ]; then
      found="$candidate"
      found_socket="$(basename "$socket")"
    elif [ "$found" != "$candidate" ]; then
      return 1
    fi
  done

  [ -n "$found" ] || return 1
  printf '%s\t%s\n' "$found" "$found_socket"
}

# Find the daemon BEAM process under one tmux pane. The pane runs the release
# launcher chain (shell → launcher script → bin/aiur → beam.smp), so the BEAM
# is a descendant of the pane PID. Scoped to the pane's subtree so a host
# running several daemons can never read the wrong instance's credentials.
beam_descendant() {
  local frontier="$1" pid ppid next_ppid i
  for i in 1 2 3 4 5 6 7 8; do
    next_ppid=""
    for pid in /proc/[0-9]*; do
      pid="${pid#/proc/}"
      ppid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null || true)"
      case " $frontier " in
        *" $ppid "*) ;;
        *) continue ;;
      esac
      if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q -- 'beam.smp'; then
        printf '%s\n' "$pid"
        return 0
      fi
      next_ppid="${next_ppid:+$next_ppid }$pid"
    done
    [ -n "$next_ppid" ] || return 1
    frontier="$next_ppid"
  done
  return 1
}

# Read one variable from the running daemon's environment. The BEAM loads .env
# itself, so the authoritative copy lives in /proc/<beam>/environ; the tmux
# server's environment is only what a pane inherited and can be stale. The
# read is scoped to the same socket that published the dashboard URL so a
# multi-daemon host never mixes one instance's credentials into another's
# capture. A concrete (non-empty) socket is required: an operator-set
# AIUR_DASHBOARD_URL has no daemon socket attached, and probing the ambient
# server for credentials would risk reading a stranger's pane.
daemon_env_var() {
  local var="$1" socket="$2" tmux_bin session pane_pid beam_pid value pane_pids
  [ -n "$socket" ] || return 1
  tmux_bin="$(command -v tmux || true)"
  [ -n "$tmux_bin" ] || return 1

  session="${AIUR_TMUX_SESSION:-${socket}-default}"
  pane_pids="$("$tmux_bin" -L "$socket" list-panes -t "$session" -F '#{pane_pid}' 2>/dev/null || true)"
  [ -n "$pane_pids" ] || return 1

  # Try every pane, not just the first: the daemon pane is the session's first
  # window in the common case, but a TUI or agent pane may sort ahead, and
  # stopping at the first pane would miss credentials the daemon BEAM does hold.
  for pane_pid in $pane_pids; do
    [[ "$pane_pid" =~ ^[1-9][0-9]*$ ]] || continue

    beam_pid="$(beam_descendant "$pane_pid" || true)"
    if [ -n "$beam_pid" ]; then
      # -r guards the read so a pane that exited between list-panes and here
      # cannot leak a "No such file or directory" onto the check's stderr.
      value="$( { [ -r "/proc/$beam_pid/environ" ] && tr '\0' '\n' < "/proc/$beam_pid/environ"; } 2>/dev/null | sed -n "s/^${var}=//p" | head -n 1 || true)"
      [ -n "$value" ] && { printf '%s\n' "$value"; return 0; }
    fi

    # The pane shell's own environment is a weaker source (it misses variables
    # the BEAM loaded from .env itself) but is better than failing when the
    # BEAM is not a recognizable descendant of the pane.
    value="$( { [ -r "/proc/$pane_pid/environ" ] && tr '\0' '\n' < "/proc/$pane_pid/environ"; } 2>/dev/null | sed -n "s/^${var}=//p" | head -n 1 || true)"
    [ -n "$value" ] && { printf '%s\n' "$value"; return 0; }
  done
  return 1
}

# Write the "did not run" evidence for a precondition failure. Both the
# narrative verdict and the machine-readable report say "did not run" — never
# "attention" — so a wrapper that reads either artifact (or an empty stdout
# log) can never mistake a skipped check for one that ran and found nothing.
# Direct invocations of capture-dashboard.mjs write the same two files, so a
# wrapper sees one consistent shape whether the failure was caught here or in
# the browser script.
write_did_not_run() {
  local dir="$1" detail="$2" message="$3" base="${4:-}"
  cat > "$dir/verdict.md" <<EOF
# Dashboard visual check

- capture: **did not run** — $message

Overall: **did not run**. Captures were not attempted.
EOF
  cat > "$dir/report.json" <<EOF
{
  "checkedAt": "$(now_iso)",
  "baseUrl": "$base",
  "verdict": "did-not-run",
  "precondition": "$detail",
  "pages": []
}
EOF
}

# Capture the four operator-facing reports and append their compact verdict to
# the same durable narrative as the hourly retrospective. The browser work is
# intentionally outside the retrospective lock: a Playwright startup must not
# block a concurrent observation or a timer-state update. Only the append is
# serialized.
visual_check() {
  local capture_script capture_dir dashboard_base_url timestamp capture_status verdict
  local dashboard_socket dashboard_username dashboard_password discovery
  local url_override="${AIUR_DASHBOARD_URL:-}"
  # "$@" still carries the subcommand word (the dispatcher never shifts), so
  # $1 is "visual-check" and an operator-supplied base URL arrives as $2.
  # Accepting that argument is what makes the documented URL override usable
  # from the command line as well as from the environment.
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || {
    printf 'usage: %s visual-check [dashboard-url]\n' "$0" >&2
    return 64
  }
  if [ "$#" -eq 2 ]; then
    case "$2" in
      http://*|https://*) url_override="$2" ;;
      *)
        printf 'usage: %s visual-check [dashboard-url]\n' "$0" >&2
        return 64
        ;;
    esac
  fi

  capture_script="${AIUR_EXECUTOR_DASHBOARD_CAPTURE_SCRIPT:-$script_dir/../../aiur-meta/scripts/capture-dashboard.mjs}"
  if [ ! -f "$capture_script" ]; then
    printf 'dashboard capture script is unavailable: %s\n' "$capture_script" >&2
    return 66
  fi

  timestamp="$(now_epoch)"
  capture_dir="${AIUR_EXECUTOR_DASHBOARD_CAPTURE_DIR:-${retro_file}.d/dashboard-$timestamp}"
  mkdir -p "$capture_dir"

  discovery="$(AIUR_DASHBOARD_URL="$url_override" dashboard_url 2>/dev/null || true)"
  if [ -n "$discovery" ]; then
    dashboard_base_url="${discovery%%$'\t'*}"
    dashboard_socket="${discovery#*$'\t'}"
    [ "$dashboard_socket" = "$discovery" ] && dashboard_socket=""
  else
    dashboard_base_url=""
    dashboard_socket=""
  fi
  if [ -z "$dashboard_base_url" ]; then
    # Precondition: no dashboard URL to capture. Exit 67 names this exact
    # precondition, the stderr line tells the operator which variable to set,
    # and the verdict says "did not run" so an empty log can never read as a
    # healthy capture.
    capture_status=67
    printf 'AIUR_DASHBOARD_URL is required: could not discover the daemon dashboard URL. Set AIUR_DASHBOARD_URL, or run inside the Aiur tmux session.\n' >&2
    write_did_not_run \
      "$capture_dir" \
      'AIUR_DASHBOARD_URL is not set; no dashboard URL to capture.' \
      'could not discover the daemon dashboard URL; set AIUR_DASHBOARD_URL or run from the Aiur tmux session.' \
      "$dashboard_base_url"
  else
    # Credentials normally live in the daemon's environment, so the wrapper may
    # not carry them even though the daemon does. Read what the operator would
    # have to extract by hand when the environment is bare — but only when the
    # URL came from a tmux socket, so the read is scoped to the daemon that
    # published it. An operator-set AIUR_DASHBOARD_URL has no socket to scope
    # to, so that path requires the credentials explicitly.
    dashboard_username="${AIUR_DASHBOARD_USERNAME:-}"
    dashboard_password="${AIUR_DASHBOARD_PASSWORD:-}"
    if [ -n "$dashboard_socket" ]; then
      [ -n "$dashboard_username" ] || dashboard_username="$(daemon_env_var AIUR_DASHBOARD_USERNAME "$dashboard_socket" || true)"
      [ -n "$dashboard_password" ] || dashboard_password="$(daemon_env_var AIUR_DASHBOARD_PASSWORD "$dashboard_socket" || true)"
    fi
    dashboard_username="${dashboard_username:-aiur}"

    if [ -z "$dashboard_password" ]; then
      # Precondition: the dashboard refuses every request without a password.
      # Exit 69 names this precondition distinctly from a missing URL (67) or a
      # missing run ID (68).
      capture_status=69
      printf 'AIUR_DASHBOARD_PASSWORD is required: set AIUR_DASHBOARD_USERNAME and AIUR_DASHBOARD_PASSWORD, or run where the daemon environment has them.\n' >&2
      write_did_not_run \
        "$capture_dir" \
        'AIUR_DASHBOARD_PASSWORD is not set; the dashboard refuses all requests without it.' \
        'AIUR_DASHBOARD_PASSWORD is not set and could not be read from the running daemon; set it (with AIUR_DASHBOARD_USERNAME) and retry.' \
        "$dashboard_base_url"
    else
      set +e
      AIUR_DASHBOARD_URL="$dashboard_base_url" \
      AIUR_DASHBOARD_USERNAME="$dashboard_username" \
      AIUR_DASHBOARD_PASSWORD="$dashboard_password" \
        node "$capture_script" "$capture_dir" > "$capture_dir/capture-output.json" 2> "$capture_dir/capture-error.log"
      capture_status=$?
      set -e
    fi
  fi

  verdict="$capture_dir/verdict.md"
  if [ "$capture_status" -ne 0 ] && [ ! -s "$verdict" ]; then
    cat > "$verdict" <<EOF
# Dashboard visual check

- capture: **attention** — browser check exited with status $capture_status; inspect capture-error.log.

Overall: **attention**. Captures may be incomplete.
EOF
  fi

  acquire_lock
  mkdir -p "$(dirname "$retro_file")"
  {
    printf '### Dashboard visual check %s\n\n' "$(now_iso)"
    sed '1{/^# Dashboard visual check$/d;}' "$verdict"
    printf '\n- Evidence: %s\n\n' "$capture_dir"
  } >> "$retro_file"
  unlock

  if [ "$capture_status" -ne 0 ]; then
    return "$capture_status"
  fi

  cat "$capture_dir/report.json"
}

# Run the read-only CLI probe against this run's explicitly keyed daemon and
# append its compact command/pane evidence to the same durable narrative.
cli_check() {
  local check_script check_dir timestamp check_status report
  [ "$#" -eq 1 ] || {
    printf 'usage: %s cli-check\n' "$0" >&2
    exit 64
  }

  check_script="${AIUR_EXECUTOR_CLI_CHECK_SCRIPT:-$script_dir/executor-cli-check.sh}"
  if [ ! -x "$check_script" ]; then
    printf 'CLI check script is unavailable: %s\n' "$check_script" >&2
    return 66
  fi

  timestamp="$(now_epoch)"
  check_dir="${AIUR_EXECUTOR_CLI_CHECK_DIR:-${retro_file}.d/cli-$timestamp}"
  mkdir -p "$check_dir"

  set +e
  "$check_script" > "$check_dir/report.json" 2> "$check_dir/check-error.log"
  check_status=$?
  set -e

  report="$check_dir/report.json"
  acquire_lock
  mkdir -p "$(dirname "$retro_file")"
  {
    printf '### Interactive CLI check %s\n\n' "$(now_iso)"
    if [ "$check_status" -eq 0 ] && [ -s "$report" ] && jq -e . "$report" >/dev/null 2>&1; then
      jq -r '
        .commands[] |
        "- `aiur \(.command)`: answered=\(.answered), timed_out=\(.timed_out), elapsed_ms=\(.elapsed_ms), non_empty=\(.non_empty), well_formed=\(.well_formed)\n  first_lines: \((.first_lines // []) | join(" | "))"
      ' "$report"
      jq -r '"- Pane surface: session_present=\(.pane_surface.session_present), panes=\(.pane_surface.pane_count // "unknown"), pre_warmed_sessions=\(.pane_surface.pre_warmed_sessions // "unknown"), live_agent_cap=\(.pane_surface.live_agent_cap // "unknown")"' "$report"
      jq -r '"- TUI: attached=\(.tui_surface.attached), agents_row=\(.tui_surface.agents_row), cap_controls=\(.tui_surface.cap_controls)"' "$report"
      if jq -e '.findings | length > 0' "$report" >/dev/null; then
        jq -r '.findings[] | "- Finding: \(.kind) \(.command // "pane") — \(.reason), elapsed_ms=\(.elapsed_ms // "n/a")"' "$report"
      else
        printf '%s\n' '- Findings: none.'
      fi
    else
      printf '%s\n' "- Check: **attention** — CLI probe exited with status $check_status; inspect check-error.log."
    fi
    printf '\n- Evidence: %s\n\n' "$check_dir"
  } >> "$retro_file"
  unlock

  if [ "$check_status" -ne 0 ]; then
    return "$check_status"
  fi

  cat "$report"
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
