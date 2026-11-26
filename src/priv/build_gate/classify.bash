# Loaded by build_gate.bash. Command classification and argument normalization: which invocations need a build slot.
aiur_build_gate_linux_locks() {
  local platform

  case ${AIUR_BUILD_GATE_LEASE_STRATEGY:-auto} in
    linux) return 0 ;;
    pid) return 1 ;;
  esac

  if ! platform=$(uname -s 2>/dev/null); then
    aiur_build_gate_fail "platform_detection_failed" "uname"
    return 125
  fi

  [[ $platform == Linux ]]
}

aiur_build_gate_needs_slot() {
  case ${1:-} in
    compile | test | lint | credo | dialyzer) return 0 ;;
    *) return 1 ;;
  esac
}

aiur_build_gate_ambiguous_command() {
  aiur_build_gate_log "gate_error reason=ambiguous_command command=$* status=125"
  return 125
}

aiur_build_gate_mix_phase() {
  local token task phase="" expect_task=0

  if aiur_build_gate_needs_slot "${1:-}"; then
    printf '%s\n' "$1"
    return 0
  fi

  [[ ${1:-} == do ]] || return 1
  shift

  while (($#)); do
    case $1 in
      --app)
        shift
        (($#)) && [[ -n $1 && $1 != -* ]] || return 125
        shift
        ;;
      --app=*)
        [[ -n ${1#--app=} ]] || return 125
        shift
        ;;
      *) break ;;
    esac
  done

  (($#)) || return 125
  expect_task=1

  for token in "$@"; do
    if ((expect_task == 1)); then
      [[ $token != + && $token != , ]] || return 125
      [[ $token != *,, ]] || return 125

      task=${token%,}
      [[ -n $task && $task != *","* ]] || return 125
      if [[ -z $phase ]] && aiur_build_gate_needs_slot "$task"; then
        phase=$task
      fi

      if [[ $token == *, ]]; then
        expect_task=1
      else
        expect_task=0
      fi
    else
      case $token in
        + | ,) expect_task=1 ;;
        *,,) return 125 ;;
        *,) expect_task=1 ;;
      esac
    fi
  done

  ((expect_task == 0)) || return 125
  [[ -n $phase ]] || return 1
  printf '%s\n' "$phase"
}

aiur_build_gate_is_mix_command() {
  local candidate=${1:-} real_mix

  [[ $candidate == mix ]] && return 0
  [[ $candidate == */* && -x $candidate ]] || return 1
  real_mix=$(aiur_build_gate_real_command mix) || return 1
  [[ $candidate -ef $real_mix ]]
}

aiur_build_gate_env_runs_mix() {
  [[ ${1##*/} == env ]] || return 1
  shift

  while (($#)); do
    case $1 in
      --)
        shift
        break
        ;;
      -i | --ignore-environment | -0 | --null | *=*) shift ;;
      -u | --unset | -C | --chdir)
        shift
        (($#)) || return 125
        shift
        ;;
      --unset=* | --chdir=*) shift ;;
      -*) return 125 ;;
      *) break ;;
    esac
  done

  (($#)) && aiur_build_gate_is_mix_command "$1"
}

aiur_build_gate_mise_command_string_phase() {
  local command_string=$1
  local -a words=()

  if [[ $command_string == *[';&|<>$`()\']* ]] ||
    [[ $command_string == *'"'* || $command_string == *'*'* ||
      $command_string == *'?'* || $command_string == *'['* ||
      $command_string == *']'* || $command_string == *'~'* ||
      $command_string == *$'\n'* ]]; then
    return 125
  fi

  read -r -a words <<<"$command_string"
  ((${#words[@]})) || return 1

  if aiur_build_gate_is_mix_command "${words[0]}"; then
    aiur_build_gate_mix_phase "${words[@]:1}"
  else
    aiur_build_gate_env_runs_mix "${words[@]}"
    case $? in
      0 | 125) return 125 ;;
      *) return 1 ;;
    esac
  fi
}

aiur_build_gate_mise_phase() {
  local command=${1:-} command_string="" command_source="" option
  shift || true

  case $command in
    exec | x) ;;
    *) return 1 ;;
  esac

  while (($#)); do
    option=$1

    case $option in
      --)
        [[ -z $command_source ]] || return 125
        shift
        (($#)) || return 1
        if ! aiur_build_gate_is_mix_command "${1:-}"; then
          aiur_build_gate_env_runs_mix "$@"
          case $? in
            0 | 125) return 125 ;;
            *) return 1 ;;
          esac
        fi
        shift
        aiur_build_gate_mix_phase "$@"
        return $?
        ;;
      -c | --command)
        [[ -z $command_source ]] || return 125
        shift
        (($#)) || return 125
        command_string=$1
        command_source=string
        shift
        ;;
      --command=*)
        [[ -z $command_source && -n ${option#--command=} ]] || return 125
        command_string=${option#--command=}
        command_source=string
        shift
        ;;
      -j | --jobs | -C | --cd | -E | --env | --allow-env | --allow-net | --allow-read | --allow-write)
        shift
        (($#)) || return 125
        shift
        ;;
      --jobs=* | --cd=* | --env=* | --allow-env=* | --allow-net=* | --allow-read=* | --allow-write=*)
        shift
        ;;
      -*) shift ;;
      *)
        [[ -z $command_source ]] || return 125
        aiur_build_gate_is_mix_command "$option" && return 125
        shift
        ;;
    esac
  done

  [[ $command_source == string ]] || return 1
  aiur_build_gate_mise_command_string_phase "$command_string"
}

# Mirrors the marker in build_gate_command_wrapper.bash. A candidate carrying
# it is another copy of the gate wrapper, whatever name it was installed
# under, and handing the command to it would loop or 127 (#2542).
aiur_build_gate_wrapper_marker='aiur-build-gate-command-wrapper-marker'

aiur_build_gate_is_wrapper_file() {
  [[ -r $1 ]] || return 1
  head -c 4096 "$1" 2>/dev/null | grep -q "$aiur_build_gate_wrapper_marker" 2>/dev/null
}

aiur_build_gate_path_command() {
  local command_name=$1 candidate
  local wrapper_path="${AIUR_BUILD_GATE_BIN:-}/$command_name"

  while IFS= read -r candidate; do
    if [[ -n ${AIUR_BUILD_GATE_BIN:-} && $candidate -ef $wrapper_path ]]; then
      continue
    fi

    aiur_build_gate_is_wrapper_file "$candidate" && continue

    printf '%s\n' "$candidate"
    return 0
  done < <(type -aP "$command_name" 2>/dev/null)

  return 1
}

# PATH first, then the toolchain manager. `mise which` answers for the
# directory's tool configuration, which is the toolchain the caller meant; it
# is the escape from a PATH whose only entry for this name is a wrapper.
aiur_build_gate_real_command() {
  local command_name=$1 mise_binary resolved

  if resolved=$(aiur_build_gate_path_command "$command_name"); then
    printf '%s\n' "$resolved"
    return 0
  fi

  mise_binary=$(aiur_build_gate_path_command mise) || return 1
  resolved=$("$mise_binary" which "$command_name" 2>/dev/null) || return 1

  [[ -n $resolved && -x $resolved ]] || return 1
  aiur_build_gate_is_wrapper_file "$resolved" && return 1

  printf '%s\n' "$resolved"
}

aiur_build_gate_elixir_mix_phase() {
  while (($#)); do
    case $1 in
      -S)
        shift
        [[ ${1:-} == mix ]] || return 1
        shift
        aiur_build_gate_mix_phase "$@"
        return $?
        ;;

      -e | -r | -pr | -pa | -pz | --app | --erl | --cookie)
        shift
        (($#)) || return 1
        shift
        ;;

      --) return 1 ;;
      -*) shift ;;
      *) return 1 ;;
    esac
  done

  return 1
}

aiur_build_gate_elixir_uses_mix() {
  while (($#)); do
    case $1 in
      -S)
        shift
        [[ ${1:-} == mix ]]
        return $?
        ;;
      -e | -r | -pr | -pa | -pz | --app | --erl | --cookie)
        shift
        (($#)) || return 1
        shift
        ;;
      --) return 1 ;;
      -*) shift ;;
      *) return 1 ;;
    esac
  done

  return 1
}

aiur_build_gate_path_without_wrapper() {
  local remaining=${PATH:-} path_entry filtered_path= separator= more

  while :; do
    path_entry=${remaining%%:*}

    if [[ $remaining == *:* ]]; then
      remaining=${remaining#*:}
      more=1
    else
      more=0
    fi

    [[ -n $path_entry ]] || path_entry=.

    if [[ ! $path_entry/${1:-elixir} -ef ${AIUR_BUILD_GATE_BIN:-}/${1:-elixir} ]] &&
      ! aiur_build_gate_is_wrapper_file "$path_entry/${1:-elixir}"; then
      filtered_path+="$separator$path_entry"
      separator=:
    fi

    ((more == 1)) || break
  done

  printf '%s\n' "$filtered_path"
}

aiur_build_gate_command_unavailable() {
  aiur_build_gate_log \
    "gate_error reason=command_unavailable command=$1 wrapper=${AIUR_BUILD_GATE_BIN:-}/$1 status=127"
  aiur_build_gate_log \
    "hint run=\"${AIUR_BUILD_GATE_BIN:-}/$1 __aiur_build_gate_self_check__\""
  return 127
}

# ExUnit forces `max_cases: 1` whenever `--trace` is present, silently
# overriding an explicit `--max-cases N` on the same command line. Strip
# `--trace` from a mix-level argument list when the two conflict (N > 1):
# the agent asked for parallelism explicitly and `--trace` is a debugging
# aid for a single test (#2311). Sets `aiur_build_gate_normalized_args` to
# the rewritten list; a non-conflicting command is copied verbatim.
aiur_build_gate_mix_args_without_trace_conflict() {
  aiur_build_gate_normalized_args=()
  local -a args=("$@")
  local i n arg has_trace=0 max_cases=""
  n=${#args[@]}

  for ((i = 0; i < n; i++)); do
    arg=${args[i]}

    if [[ $arg == --max-cases ]]; then
      ((i + 1 < n)) && max_cases=${args[i + 1]}
    elif [[ $arg == --max-cases=* ]]; then
      max_cases=${arg#--max-cases=}
    elif [[ $arg == --trace ]]; then
      has_trace=1
    fi
  done

  if [[ $has_trace == 1 && $max_cases =~ ^[1-9][0-9]*$ && $max_cases -gt 1 ]]; then
    for ((i = 0; i < n; i++)); do
      arg=${args[i]}
      [[ $arg == --trace ]] || aiur_build_gate_normalized_args+=("$arg")
    done
    aiur_build_gate_log "trace_stripped reason=conflict_with_max_cases max_cases=$max_cases"
  else
    aiur_build_gate_normalized_args=("${args[@]}")
  fi
}

# Normalize `elixir -S mix ...` arguments, rewriting only the mix-level
# flags after the `mix` token (mirrors aiur_build_gate_elixir_mix_phase).
# Initialized verbatim so every early return leaves a non-mix elixir
# invocation untouched.
aiur_build_gate_normalize_elixir_args() {
  aiur_build_gate_normalized_args=("$@")
  local -a args=("$@")
  local i n arg
  n=${#args[@]}

  for ((i = 0; i < n; i++)); do
    arg=${args[i]}

    case $arg in
      -S)
        if ((i + 1 < n)) && [[ ${args[i + 1]} == mix ]]; then
          aiur_build_gate_mix_args_without_trace_conflict "${args[@]:i+2}"
          aiur_build_gate_normalized_args=("${args[@]:0:i}" -S mix "${aiur_build_gate_normalized_args[@]}")
        fi
        return 0
        ;;
      -e | -r | -pr | -pa | -pz | --app | --erl | --cookie)
        ((i + 1 < n)) || return 0
        i=$((i + 1))
        ;;
      --) return 0 ;;
      -*) ;;
      *) return 0 ;;
    esac
  done

  return 0
}

# Normalize `mise exec -- mix ...` arguments, rewriting only the mix-level
# flags after `--` (mirrors aiur_build_gate_mise_phase's structural form).
# `-c`/`--command` strings need no rewrite here: the nested `mix` invocation
# they produce is normalized by the hook's `mix()` entry point. Initialized
# verbatim so a non-mix `--` payload is passed through untouched.
aiur_build_gate_normalize_mise_args() {
  aiur_build_gate_normalized_args=("$@")
  local -a args=("$@")
  local i n arg
  n=${#args[@]}

  for ((i = 0; i < n; i++)); do
    arg=${args[i]}

    if [[ $arg == -- ]]; then
      if ((i + 1 < n)) && aiur_build_gate_is_mix_command "${args[i + 1]}"; then
        aiur_build_gate_mix_args_without_trace_conflict "${args[@]:i+2}"
        aiur_build_gate_normalized_args=("${args[@]:0:i}" -- "${args[i + 1]}" "${aiur_build_gate_normalized_args[@]}")
      fi
      return 0
    fi
  done

  return 0
}
