#!/bin/sh
# PATH entrypoint for Elixir/Mix admission. Cheap commands pass straight through
# this POSIX dispatcher; only compile/test work starts Bash and loads the hook.
#
# aiur-build-gate-command-wrapper-marker: this literal identifies a copy of this
# script to another copy of it. Resolution below refuses to hand a command to a
# file carrying the marker, so a wrapper installed under a *second* name — a
# `mise reshim` that overwrites `~/.local/share/mise/shims/mix` with a symlink to
# this file, for instance — cannot be mistaken for the real toolchain (#2542).

command_name=${0##*/}
: "${AIUR_BUILD_GATE_BIN:=${0%/*}}"
export AIUR_BUILD_GATE_BIN

aiur_build_gate_wrapper_marker='aiur-build-gate-command-wrapper-marker'

# A candidate is another copy of this wrapper when the marker appears in its
# header. Bounded to the first 4 KiB so a large real binary — `mise` itself is
# tens of megabytes — is never read whole.
aiur_build_gate_wrapper_is_wrapper() {
  [ -r "$1" ] || return 1
  head -c 4096 "$1" 2>/dev/null | grep -q "$aiur_build_gate_wrapper_marker" 2>/dev/null
}

# The real binary for `lookup_name` on PATH, skipping this process's own file
# and every other wrapper copy.
aiur_build_gate_wrapper_path_lookup() {
  lookup_name=$1
  saved_ifs=$IFS
  IFS=:

  for path_entry in $PATH; do
    [ -n "$path_entry" ] || path_entry=.
    candidate="$path_entry/$lookup_name"

    if [ -f "$candidate" ] && [ -x "$candidate" ] &&
      ! [ "$candidate" -ef "$0" ] 2>/dev/null &&
      ! aiur_build_gate_wrapper_is_wrapper "$candidate"; then
      IFS=$saved_ifs
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  IFS=$saved_ifs
  return 1
}

# `mise which` answers for the current directory's tool configuration, which is
# exactly the toolchain the caller meant. Consulted only when PATH holds no real
# binary at all — the #2542 shape — so the ordinary case never runs it.
aiur_build_gate_wrapper_mise_lookup() {
  mise_binary=$(aiur_build_gate_wrapper_path_lookup mise) || return 1
  mise_resolved=$("$mise_binary" which "$1" 2>/dev/null) || return 1

  [ -n "$mise_resolved" ] || return 1
  [ -f "$mise_resolved" ] && [ -x "$mise_resolved" ] || return 1
  ! aiur_build_gate_wrapper_is_wrapper "$mise_resolved" || return 1

  printf '%s\n' "$mise_resolved"
}

# Prints "<source> <path>". The source is reported by the self-check so a
# resolution that goes wrong later is a named path, not a bare 127.
aiur_build_gate_wrapper_resolve() {
  if resolved=$(aiur_build_gate_wrapper_path_lookup "$command_name"); then
    printf 'path %s\n' "$resolved"
    return 0
  fi

  if resolved=$(aiur_build_gate_wrapper_mise_lookup "$command_name"); then
    printf 'mise %s\n' "$resolved"
    return 0
  fi

  return 1
}

aiur_build_gate_wrapper_real_command() {
  resolution=$(aiur_build_gate_wrapper_resolve) || return 1
  printf '%s\n' "${resolution#* }"
}

# Reports which binary this wrapper resolves for its own name, so a breakage is
# diagnosable without reproducing the failing build (#2542).
aiur_build_gate_wrapper_self_check() {
  if resolution=$(aiur_build_gate_wrapper_resolve); then
    printf 'aiur_build_gate self_check command=%s wrapper=%s source=%s real=%s status=0\n' \
      "$command_name" "$0" "${resolution%% *}" "${resolution#* }"
    return 0
  fi

  printf 'aiur_build_gate self_check command=%s wrapper=%s source=none real= status=127\n' \
    "$command_name" "$0" >&2
  return 127
}

aiur_build_gate_wrapper_elixir_mix_task() {
  while [ "$#" -gt 0 ]; do
    case $1 in
      -S)
        shift
        [ "${1:-}" = mix ] || return 1
        shift
        printf '%s\n' "${1:-}"
        return 0
        ;;

      -e | -r | -pr | -pa | -pz | --app | --erl | --cookie)
        shift
        [ "$#" -gt 0 ] || return 1
        shift
        ;;

      --) return 1 ;;
      -*) shift ;;
      *) return 1 ;;
    esac
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

    candidate="$path_entry/$command_name"

    if ! [ "$candidate" -ef "$0" ] 2>/dev/null &&
      ! aiur_build_gate_wrapper_is_wrapper "$candidate"; then
      filtered_path="$filtered_path$separator$path_entry"
      separator=:
    fi
  done

  IFS=$saved_ifs
  printf '%s\n' "$filtered_path"
}

aiur_build_gate_wrapper_ambiguous_string() {
  case $1 in
    *';'* | *'&'* | *'|'* | *'<'* | *'>'* | *'$'* | *'`'* | *'('* | *')'* | *'\'* | *"'"* | *'"'* | *'*'* | *'?'* | *'['* | *']'* | *'~'* | *"
"*) return 0 ;;
    *) return 1 ;;
  esac
}

aiur_build_gate_needs_wrapper() {
  case $command_name in
    elixir)
      elixir_mix_task=$(aiur_build_gate_wrapper_elixir_mix_task "$@") || return 1

      case $elixir_mix_task in
        compile | test | do) return 0 ;;
        *) return 1 ;;
      esac
      ;;

    mix)
      case ${1:-} in
        compile | test | do) return 0 ;;
        *) return 1 ;;
      esac
      ;;

    mise)
      case ${1:-} in
        exec | x) shift ;;
        *) return 1 ;;
      esac

      while [ "$#" -gt 0 ]; do
        case $1 in
          --)
            shift
            [ "$#" -gt 0 ] || return 1

            if [ "${1##*/}" = mix ]; then
              shift
              case ${1:-} in
                compile | test | do) return 0 ;;
                *) return 1 ;;
              esac
            fi

            if [ "${1##*/}" = env ]; then
              shift
              while [ "$#" -gt 0 ]; do
                case $1 in
                  *=* | -i | --ignore-environment | -0 | --null) shift ;;
                  --) shift; break ;;
                  -*) return 0 ;;
                  *) break ;;
                esac
              done
              [ "$#" -gt 0 ] && [ "${1##*/}" = mix ] && return 0
            fi

            return 1
            ;;

          -c | --command)
            shift
            [ "$#" -gt 0 ] || return 0
            aiur_build_gate_wrapper_ambiguous_string "$1" && return 0
            case $1 in
              mix\ compile* | mix\ test* | mix\ do* | */mix\ compile* | */mix\ test* | */mix\ do* | env\ *mix*)
                return 0
                ;;
              *) return 1 ;;
            esac
            ;;

          --command=*)
            command_string=${1#--command=}
            aiur_build_gate_wrapper_ambiguous_string "$command_string" && return 0
            case $command_string in
              mix\ compile* | mix\ test* | mix\ do* | */mix\ compile* | */mix\ test* | */mix\ do* | env\ *mix*)
                return 0
                ;;
              *) return 1 ;;
            esac
            ;;

          mix | */mix) return 0 ;;
          *) shift ;;
        esac
      done

      return 1
      ;;

    *)
      return 1
      ;;
  esac
}

if [ "${1:-}" = __aiur_build_gate_self_check__ ]; then
  aiur_build_gate_wrapper_self_check
  exit $?
fi

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

if [ -n "${AIUR_BUILD_GATE_DIR:-}" ] &&
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
  # Name the wrapper and the self-check, so the next reader of this line knows
  # which file shadowed the toolchain instead of only that something did (#2542).
  printf 'aiur_build_gate gate_error reason=command_unavailable command=%s wrapper=%s status=127\n' \
    "$command_name" "$0" >&2
  printf 'aiur_build_gate hint run="%s __aiur_build_gate_self_check__"\n' "$0" >&2
  exit 127
fi

# `elixir -S mix` loads the named script as Elixir source. Remove this shell
# wrapper from PATH so Elixir resolves the actual Mix script after admission.
if [ "$command_name" = elixir ] && aiur_build_gate_wrapper_elixir_mix_task "$@" >/dev/null; then
  PATH=$(aiur_build_gate_wrapper_path_without_self)
  export PATH
fi

exec "$real_command" "$@"
