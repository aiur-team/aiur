#!/usr/bin/env bash
# Sourced through BASH_ENV for local Aiur coding-agent shells. It intentionally
# gates only Mix compile/test work; editing, Git, and other shell commands stay
# free to run while a verification command holds a lease.

if [[ -z ${AIUR_BUILD_GATE_HOOK_LOADED:-} ]]; then
  AIUR_BUILD_GATE_HOOK_LOADED=1

  aiur_build_gate_log() {
    printf 'aiur_build_gate %s\n' "$*" >&2
  }

  aiur_build_gate_needs_slot() {
    case ${1:-} in
      compile | test) return 0 ;;
      *) return 1 ;;
    esac
  }

  aiur_build_gate_owner_pid() {
    local owner_file=$1 first_line

    [[ -f $owner_file ]] || return 1
    IFS= read -r first_line <"$owner_file" || return 1
    [[ $first_line =~ ^pid=([1-9][0-9]*)$ ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
  }

  aiur_build_gate_reclaim_stale_slot() {
    local slot_path=$1 slot=$2 owner_file="$slot_path/owner" owner_pid

    owner_pid=$(aiur_build_gate_owner_pid "$owner_file")

    if [[ -n $owner_pid ]]; then
      kill -0 "$owner_pid" 2>/dev/null && return 1

      rm -f "$owner_file"
      if rmdir "$slot_path" 2>/dev/null; then
        aiur_build_gate_log "stale_owner_recovered slot=$slot owner_pid=$owner_pid"
        return 0
      fi

      return 1
    fi

    # A process can die between mkdir and writing its owner file. Waiting
    # contenders safely reclaim only an empty slot; a delayed owner write then
    # fails and retries rather than running without a lease.
    if rmdir "$slot_path" 2>/dev/null; then
      aiur_build_gate_log "stale_owner_recovered slot=$slot owner_pid=unknown"
      return 0
    fi

    return 1
  }

  aiur_build_gate_run() {
    local executable=$1
    shift

    local gate_dir=${AIUR_BUILD_GATE_DIR:-}
    local slots=${AIUR_BUILD_GATE_SLOTS:-0}
    local timeout_seconds=${AIUR_BUILD_GATE_TIMEOUT_SECONDS:-900}
    local queue_dir queue_file deadline slot slot_path owner_file result

    if [[ ! $slots =~ ^[1-9][0-9]*$ ]] || [[ ! $timeout_seconds =~ ^[0-9]+$ ]] || [[ -z $gate_dir ]]; then
      aiur_build_gate_log "gate_error reason=invalid_configuration"
      "$executable" "$@"
      return
    fi

    queue_dir="$gate_dir/queue"
    if ! mkdir -p "$queue_dir" 2>/dev/null; then
      aiur_build_gate_log "gate_error reason=directory_unavailable path=$gate_dir"
      "$executable" "$@"
      return
    fi

    queue_file="$queue_dir/$$"
    if ! printf 'pid=%s\ncommand=%s\n' "$$" "$*" >"$queue_file"; then
      aiur_build_gate_log "gate_error reason=queue_record_failed path=$queue_file"
      "$executable" "$@"
      return
    fi

    deadline=$((SECONDS + timeout_seconds))
    aiur_build_gate_log "queued slots=$slots command=$*"

    while :; do
      for ((slot = 1; slot <= slots; slot++)); do
        slot_path="$gate_dir/slot-$slot"

        if mkdir "$slot_path" 2>/dev/null; then
          owner_file="$slot_path/owner"

          if ! printf 'pid=%s\ncommand=%s\n' "$$" "$*" >"$owner_file"; then
            rmdir "$slot_path" 2>/dev/null || true
            continue
          fi

          rm -f "$queue_file"
          aiur_build_gate_log "acquired slot=$slot command=$*"
          "$executable" "$@"
          result=$?

          if ! rm -rf "$slot_path" 2>/dev/null; then
            aiur_build_gate_log "gate_error reason=release_failed slot=$slot"
          fi

          aiur_build_gate_log "released slot=$slot status=$result"
          return "$result"
        fi

        aiur_build_gate_reclaim_stale_slot "$slot_path" "$slot" || true
      done

      if ((SECONDS >= deadline)); then
        rm -f "$queue_file"
        aiur_build_gate_log "timeout slots=$slots command=$*"
        return 124
      fi

      sleep 1
    done
  }

  aiur_build_gate_mise_needs_slot() {
    local command=${1:-}
    shift || true

    case $command in
      exec | x) ;;
      *) return 1 ;;
    esac

    while (($#)); do
      if [[ $1 == -- ]]; then
        shift
        break
      fi

      shift
    done

    [[ ${1:-} == mix ]] || return 1
    shift
    aiur_build_gate_needs_slot "${1:-}"
  }

  mix() {
    local mix_binary
    mix_binary=$(type -P mix)

    if [[ -n $mix_binary ]] && aiur_build_gate_needs_slot "${1:-}"; then
      aiur_build_gate_run "$mix_binary" "$@"
    elif [[ -n $mix_binary ]]; then
      "$mix_binary" "$@"
    else
      command mix "$@"
    fi
  }

  mise() {
    local mise_binary
    mise_binary=$(type -P mise)

    if [[ -n $mise_binary ]] && aiur_build_gate_mise_needs_slot "$@"; then
      aiur_build_gate_run "$mise_binary" "$@"
    elif [[ -n $mise_binary ]]; then
      "$mise_binary" "$@"
    else
      command mise "$@"
    fi
  }
fi
