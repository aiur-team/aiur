#!/usr/bin/env bash
# Sourced through BASH_ENV for local Aiur coding-agent shells and by the
# shell-independent command wrappers. It gates Mix
# compile/test/static analysis and browser work; other commands stay free to run.

if [[ -z ${AIUR_BUILD_GATE_HOOK_LOADED:-} ]]; then
  AIUR_BUILD_GATE_HOOK_LOADED=1

  source "$(dirname "${BASH_SOURCE[0]}")/browser_build_gate.bash"
  source "$(dirname "${BASH_SOURCE[0]}")/build_priority.bash"
  aiur_build_gate_log() {
    printf 'aiur_build_gate %s\n' "$*" >&2
  }

  aiur_build_gate_fail() {
    local reason=$1 path=${2:-unknown}

    aiur_build_gate_log \
      "gate_error reason=$reason path=$path status=125" \
      "recovery=repair_gate_or_disable_all_build_admission" \
      "disable=max_concurrent_builds_0,build_start_stagger_seconds_0,min_free_memory_mb_unset"
    return 125
  }

  # The gate is split by concern; every part must load or no build may run.
  aiur_build_gate_load_parts() {
    local dir part
    dir="$(dirname "${BASH_SOURCE[0]}")/build_gate"

    for part in classify process lease run_pid run_linux; do
      if [[ ! -r $dir/$part.bash ]] || ! source "$dir/$part.bash"; then
        aiur_build_gate_fail missing_part "$dir/$part.bash"
        return 125
      fi
    done
  }

  if ! aiur_build_gate_load_parts; then
    # Fail closed: without its parts the hook cannot admit a build, so the
    # wrapped commands refuse to run instead of bypassing admission.
    elixir() { aiur_build_gate_fail missing_part "$(dirname "${BASH_SOURCE[0]}")/build_gate"; }
    mix() { elixir; }
    mise() { elixir; }
    return 125
  fi

  aiur_build_gate_run() {
    local strategy_result

    if aiur_build_gate_linux_locks; then
      aiur_build_gate_run_linux "$@"
    else
      strategy_result=$?

      if ((strategy_result == 1)); then
        aiur_build_gate_run_pid "$@"
      else
        return "$strategy_result"
      fi
    fi
  }

  elixir() {
    local elixir_binary phase real_path classification
    elixir_binary=$(aiur_build_gate_real_command elixir)

    if [[ -z $elixir_binary ]]; then
      aiur_build_gate_command_unavailable elixir
      return $?
    fi

    aiur_build_gate_normalize_elixir_args "$@"
    set -- "${aiur_build_gate_normalized_args[@]}"

    if phase=$(aiur_build_gate_elixir_mix_phase "$@"); then
      classification=0
    else
      classification=$?
    fi

    case $classification in
      0)
        real_path=$(aiur_build_gate_path_without_wrapper)
        aiur_build_gate_run_or_reuse "$phase" env "PATH=$real_path" "$elixir_binary" "$@"
        ;;
      1)
        if aiur_build_gate_elixir_uses_mix "$@"; then
          real_path=$(aiur_build_gate_path_without_wrapper)
          PATH=$real_path "$elixir_binary" "$@"
        else
          "$elixir_binary" "$@"
        fi
        ;;
      *) aiur_build_gate_ambiguous_command elixir "$@" ;;
    esac
  }

  mix() {
    local mix_binary phase classification
    mix_binary=$(aiur_build_gate_real_command mix)

    if [[ -z $mix_binary ]]; then
      aiur_build_gate_command_unavailable mix
      return $?
    fi

    aiur_build_gate_mix_args_without_trace_conflict "$@"
    set -- "${aiur_build_gate_normalized_args[@]}"

    if phase=$(aiur_build_gate_mix_phase "$@"); then
      classification=0
    else
      classification=$?
    fi

    case $classification in
      0) aiur_build_gate_run_or_reuse "$phase" "$mix_binary" "$@" ;;
      1) "$mix_binary" "$@" ;;
      *) aiur_build_gate_ambiguous_command mix "$@" ;;
    esac
  }

  mise() {
    local mise_binary phase classification PATH=$PATH MISE_BIN __MISE_BIN __MISE_EXE
    mise_binary=$(aiur_build_gate_real_command mise)

    if [[ -z $mise_binary ]]; then
      aiur_build_gate_command_unavailable mise
      return $?
    fi
    PATH=$(aiur_build_gate_path_without_wrapper mise)
    export PATH MISE_BIN="$mise_binary" __MISE_BIN="$mise_binary" __MISE_EXE="$mise_binary"
    aiur_build_gate_normalize_mise_args "$@"
    set -- "${aiur_build_gate_normalized_args[@]}"
    if phase=$(aiur_build_gate_mise_phase "$@"); then
      classification=0
    else
      classification=$?
    fi

    case $classification in
      0) aiur_build_gate_run_or_reuse "$phase" "$mise_binary" "$@" ;;
      1) "$mise_binary" "$@" ;;
      *) aiur_build_gate_ambiguous_command mise "$@" ;;
    esac
  }
fi
