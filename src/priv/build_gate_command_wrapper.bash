#!/bin/sh
# PATH entrypoint for Elixir/Mix admission. Cheap commands pass straight through
# this POSIX dispatcher; only compile/test work starts Bash and loads the hook.

command_name=${0##*/}
: "${AIUR_BUILD_GATE_BIN:=${0%/*}}"
export AIUR_BUILD_GATE_BIN

aiur_build_gate_wrapper_real_command() {
  saved_ifs=$IFS
  IFS=:

  for path_entry in $PATH; do
    [ -n "$path_entry" ] || path_entry=.
    candidate="$path_entry/$command_name"

    if [ "$candidate" != "$AIUR_BUILD_GATE_BIN/$command_name" ] &&
      [ -f "$candidate" ] && [ -x "$candidate" ]; then
      IFS=$saved_ifs
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  IFS=$saved_ifs
  return 1
}

aiur_build_gate_wrapper_elixir_mix_task() {
  while [ "$#" -gt 0 ]; do
    if [ "$1" = -S ]; then
      shift
      [ "${1:-}" = mix ] || return 1
      shift
      printf '%s\n' "${1:-}"
      return 0
    fi

    shift
  done

  return 1
}

aiur_build_gate_wrapper_path_without_self() {
  saved_ifs=$IFS
  IFS=:
  filtered_path=
  separator=

  for path_entry in $PATH; do
    [ -n "$path_entry" ] || path_entry=.

    if [ "$path_entry" != "$AIUR_BUILD_GATE_BIN" ]; then
      filtered_path="$filtered_path$separator$path_entry"
      separator=:
    fi
  done

  IFS=$saved_ifs
  printf '%s\n' "$filtered_path"
}

aiur_build_gate_needs_wrapper() {
  case $command_name in
    elixir)
      elixir_mix_task=$(aiur_build_gate_wrapper_elixir_mix_task "$@") || return 1

      case $elixir_mix_task in
        compile | test) return 0 ;;
        *) return 1 ;;
      esac
      ;;

    mix)
      case ${1:-} in
        compile | test) return 0 ;;
        *) return 1 ;;
      esac
      ;;

    mise)
      case ${1:-} in
        exec | x) shift ;;
        *) return 1 ;;
      esac

      while [ "$#" -gt 0 ]; do
        if [ "$1" = -- ]; then
          shift
          break
        fi
        shift
      done

      [ "${1:-}" = mix ] || return 1
      shift

      case ${1:-} in
        compile | test) return 0 ;;
        *) return 1 ;;
      esac
      ;;

    *)
      return 1
      ;;
  esac
}

if [ "${1:-}" = __aiur_build_gate_bash__ ]; then
  shift

  if declare -F "$command_name" >/dev/null 2>&1; then
    "$command_name" "$@"
    exit $?
  fi

  printf 'aiur_build_gate gate_error reason=hook_unavailable command=%s status=125\n' \
    "$command_name" >&2
  exit 125
fi

if [ "${AIUR_BUILD_GATE_ACTIVE:-0}" != 1 ] &&
  [ -n "${AIUR_BUILD_GATE_DIR:-}" ] &&
  aiur_build_gate_needs_wrapper "$@"; then
  if [ ! -r "${BASH_ENV:-}" ]; then
    printf 'aiur_build_gate gate_error reason=hook_unavailable command=%s status=125\n' \
      "$command_name" >&2
    exit 125
  fi

  exec bash "$0" __aiur_build_gate_bash__ "$@"
fi

real_command=$(aiur_build_gate_wrapper_real_command) || real_command=

if [ -z "$real_command" ]; then
  printf 'aiur_build_gate gate_error reason=command_unavailable command=%s status=127\n' \
    "$command_name" >&2
  exit 127
fi

# `elixir -S mix` loads the named script as Elixir source. Remove this shell
# wrapper from PATH so Elixir resolves the actual Mix script after admission.
if [ "$command_name" = elixir ] && aiur_build_gate_wrapper_elixir_mix_task "$@" >/dev/null; then
  PATH=$(aiur_build_gate_wrapper_path_without_self)
  export PATH
fi

exec "$real_command" "$@"
