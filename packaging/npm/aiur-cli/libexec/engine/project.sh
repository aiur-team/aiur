# --project <owner/repo>: names one project on a multi-project gateway. Sourced by aiur-engine.sh.
# Server side: Aiur.ControlCall.Project. Only flag-given values count (no AIUR_PROJECT default).

# Commands whose RPC carries `aiur_project_join`. Keep in step with @project_scoped in project.ex.
AIUR_PROJECT_COMMANDS=" queue lane epic feature units build-orders analytics set "

# @cli-reference aiur --project OWNER/REPO | Targets one project on a multi-project gateway; see [Choosing a project](#choosing-a-project). | aiur --gateway nook queue show --project o/b
aiur_b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# `owner/repo` of the current directory's origin remote; empty on any failure. No network.
aiur_cwd_repo() {
  local url
  url="$(git -C "$PWD" remote get-url origin 2>/dev/null)" || return 0
  url="${url%.git}"
  case "$url" in
    https://github.com/* | http://github.com/*) url="${url#*://github.com/}" ;;
    git@github.com:* | ssh://git@github.com/*) url="${url#*github.com[:/]}" ;;
    *) return 0 ;;
  esac
  [[ "$url" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] && printf '%s' "$url"
  return 0
}

# Appends the project keywords to the variable named $1: explicit `project:`, else (local only) the cwd
# `project_hint:`. Not run in a subshell: it sets AIUR_PROJECT_WRAP, which is what makes a local call wrap.
aiur_project_join() {
  local -n _opts="$1"
  local kw="" hint
  if [ -n "${AIUR_PROJECT:-}" ]; then
    kw="project: Base.decode64!(\"$(aiur_b64 "$AIUR_PROJECT")\")"
  elif [ -z "${AIUR_REMOTE_INSTANCE:-}" ] && hint="$(aiur_cwd_repo)" && [ -n "$hint" ]; then
    kw="project_hint: Base.decode64!(\"$(aiur_b64 "$hint")\")"
  fi
  [ -n "$kw" ] || return 0
  AIUR_PROJECT_WRAP=1
  _opts="${_opts}${_opts:+, }${kw}"
}

# A local call that carries project keywords (AIUR_PROJECT_WRAP, set by aiur_project_join) goes through
# ControlCall so it resolves like a remote one. Anything else is sent unchanged.
aiur_project_local_expr() {
  if [ "${AIUR_PROJECT_WRAP:-}" = 1 ]; then
    printf 'Aiur.ControlCall.Project.run_local(Base.decode64!("%s"))' "$(aiur_b64 "$1")"
  else
    printf '%s' "$1"
  fi
}

# Consumes the flags counted in AIUR_FLAGS_CONSUMED plus any --project (leading, or anywhere after a
# project-scoped command). Leaves the remaining words in AIUR_ARGS and the project in AIUR_PROJECT.
aiur_project_args() {
  unset AIUR_PROJECT AIUR_PROJECT_WRAP
  AIUR_ARGS=()
  shift "$AIUR_FLAGS_CONSUMED"
  local seen=0 value="" rest=() cmd="" word
  while [ "$#" -gt 0 ]; do
    word="$1"
    if [ "$word" = "--project" ] || [[ "$word" == --project=* ]]; then
      if [ -n "$cmd" ] && [[ "$AIUR_PROJECT_COMMANDS" != *" $cmd "* ]]; then rest+=("$word"); shift; continue; fi
      if [ "$word" = "--project" ]; then value="${2:-}"; shift; else value="${word#*=}"; fi
      shift
      [ "$seen" -eq 0 ] || { echo "aiur: --project given twice" >&2; return 64; }
      seen=1
      [[ "$value" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "aiur: --project expects owner/repo" >&2; return 64; }
      AIUR_PROJECT="$value"
      continue
    fi
    [ -n "$cmd" ] || cmd="$word"
    rest+=("$word")
    shift
  done
  if [ "$seen" -eq 1 ]; then
    [ "${AIUR_REMOTE_INSTANCE:-}" != all ] || { echo "aiur: --project names one project and cannot be used with 'all'" >&2; return 64; }
    if [[ "$AIUR_PROJECT_COMMANDS" != *" $cmd "* ]]; then
      echo "aiur: ${cmd:-this command} is gateway-scoped or not project-aware yet; --project does not apply" >&2
      return 64
    fi
    export AIUR_PROJECT
  fi
  AIUR_ARGS=("${rest[@]+"${rest[@]}"}")
}
