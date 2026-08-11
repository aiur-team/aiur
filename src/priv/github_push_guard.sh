#!/bin/sh

# Identity guard for agent-launched `git` calls. The daemon prepends this
# wrapper's directory to agent PATH and captures the real executable before it
# does so. Authentication remains inert for local commands and reads; when Git
# asks for GitHub HTTPS credentials, the helper returns only the configured
# tracker token and never falls through to a cached Executor credential.
real_git=${AIUR_REAL_GIT:-}
if [ -z "$real_git" ] || [ ! -x "$real_git" ]; then
  printf '%s\n' 'aiur: real git executable is unavailable' >&2
  exit 127
fi

credential_helper='!f() { if test "$1" = get; then if test -z "${GITHUB_TOKEN:-}"; then printf "quit=true\n"; else printf "username=x-access-token\npassword=%s\n" "$GITHUB_TOKEN"; fi; fi; }; f'

push_command=false
for arg in "$@"; do
  if [ "$arg" = push ]; then
    push_command=true
    break
  fi
done

if [ "$push_command" = true ]; then
  push_target=
  after_push=false

  for arg in "$@"; do
    if [ "$after_push" = false ]; then
      [ "$arg" = push ] && after_push=true
      continue
    fi

    case "$arg" in
      -*) continue ;;
    esac

    if "$real_git" config --get "remote.$arg.url" >/dev/null 2>&1; then
      push_target="$arg"
      break
    fi

    case "$arg" in
      *://* | *@*:* )
        push_target="$arg"
        break
        ;;
    esac
  done

  if [ -z "$push_target" ]; then
    branch=$("$real_git" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    if [ -n "$branch" ]; then
      push_target=$("$real_git" config --get "branch.$branch.pushRemote" 2>/dev/null || true)
      [ -n "$push_target" ] || push_target=$("$real_git" config --get remote.pushDefault 2>/dev/null || true)
      [ -n "$push_target" ] || push_target=$("$real_git" config --get "branch.$branch.remote" 2>/dev/null || true)
    fi
    [ -n "$push_target" ] || push_target=origin
  fi

  push_url=$("$real_git" remote get-url --push "$push_target" 2>/dev/null || printf '%s' "$push_target")
  case "$push_url" in
    https://github.com/*) ;;
    *github.com* | *@github.com:* )
      printf '%s\n' 'aiur: GitHub pushes require a credential-free https://github.com remote' >&2
      exit 64
      ;;
  esac
fi

GIT_TERMINAL_PROMPT=0
GIT_CONFIG_PARAMETERS="'credential.https://github.com.helper=' 'credential.https://github.com.helper=$credential_helper' 'http.https://github.com/.extraheader='"
export GIT_TERMINAL_PROMPT GIT_CONFIG_PARAMETERS

exec "$real_git" "$@"
