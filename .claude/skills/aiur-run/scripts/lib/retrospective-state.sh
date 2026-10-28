# State and lock helpers for executor-retrospective.sh.

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
      if [ -n "${AIUR_EXECUTOR_RETROSPECTIVE_TEST_LOCK_HELD_FILE:-}" ]; then
        : > "$AIUR_EXECUTOR_RETROSPECTIVE_TEST_LOCK_HELD_FILE"
        while [ ! -e "${AIUR_EXECUTOR_RETROSPECTIVE_TEST_RELEASE_FILE:?}" ]; do
          sleep 0.01
        done
      fi
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
