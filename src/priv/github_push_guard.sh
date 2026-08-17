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

# Destructive commands must name the ticket workspace explicitly. Derive that
# authority from this installed wrapper's location rather than an environment
# variable that the child process can replace.
git_command=
git_context=
git_context_count=0
competing_context=false
config_override=false
expect_global_value=

for arg in "$@"; do
  if [ -n "$git_command" ]; then
    continue
  fi

  if [ -n "$expect_global_value" ]; then
    case "$expect_global_value" in
      context)
        git_context=$arg
        git_context_count=$((git_context_count + 1))
        ;;
    esac
    expect_global_value=
    continue
  fi

  case "$arg" in
    -C)
      expect_global_value=context
      ;;
    -C?*)
      git_context=${arg#-C}
      git_context_count=$((git_context_count + 1))
      ;;
    --git-dir | --work-tree)
      competing_context=true
      expect_global_value=competing
      ;;
    --git-dir=* | --work-tree=*)
      competing_context=true
      ;;
    -c | --config-env)
      config_override=true
      expect_global_value=other
      ;;
    -c?* | --config-env=*)
      config_override=true
      ;;
    --namespace | --exec-path)
      expect_global_value=other
      ;;
    --namespace=* | --exec-path=* | --bare | --no-pager | --paginate | --literal-pathspecs | --glob-pathspecs | --noglob-pathspecs | --icase-pathspecs)
      ;;
    --)
      ;;
    -*)
      ;;
    *)
      git_command=$arg
      ;;
  esac
done

destructive_command=false
after_git_command=false
worktree_subcommand=

for arg in "$@"; do
  if [ "$after_git_command" = false ]; then
    if [ "$arg" = "$git_command" ]; then
      after_git_command=true
    fi
    continue
  fi

  case "$git_command" in
    reset)
      case "$arg" in --h | --ha | --har | --hard | --hard=*) destructive_command=true ;; esac
      ;;
    clean)
      case "$arg" in
        --force | -*)
          clean_options=${arg#-}
          case "$clean_options" in *f*) destructive_command=true ;; esac
          ;;
      esac
      ;;
    worktree)
      if [ -z "$worktree_subcommand" ]; then
        case "$arg" in
          -*) ;;
          *) worktree_subcommand=$arg ;;
        esac
      fi
      [ "$worktree_subcommand" = remove ] && destructive_command=true
      ;;
  esac
done

case "$git_command" in
  checkout | restore) destructive_command=true ;;
esac

if [ "$destructive_command" = true ]; then
  if [ "$competing_context" = true ] || [ "$config_override" = true ] || [ -n "${GIT_DIR:-}" ] || [ -n "${GIT_WORK_TREE:-}" ]; then
    printf '%s\n' 'aiur: destructive git commands cannot use competing repository context' >&2
    exit 64
  fi

  case "$git_context" in
    /*) ;;
    *)
      if [ "$git_context_count" -eq 0 ]; then
        printf '%s\n' 'aiur: destructive git commands require an explicit absolute -C workspace' >&2
      else
        printf '%s\n' 'aiur: destructive git target is not the agent workspace' >&2
      fi
      exit 64
      ;;
  esac

  if [ "$git_context_count" -ne 1 ]; then
    printf '%s\n' 'aiur: destructive git target is not the agent workspace' >&2
    exit 64
  fi

  wrapper_bin=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
  runtime_dir=$(dirname "$wrapper_bin")
  expected_workspace=$(dirname "$runtime_dir")
  expected_workspace=$(CDPATH= cd -P "$expected_workspace" 2>/dev/null && pwd)
  target_top=$("$real_git" -C "$git_context" rev-parse --show-toplevel 2>/dev/null || true)
  target_top=$(CDPATH= cd -P "$target_top" 2>/dev/null && pwd)

  if [ -z "$expected_workspace" ] || [ -z "$target_top" ] || [ "$target_top" != "$expected_workspace" ]; then
    printf '%s\n' 'aiur: destructive git target is not the agent workspace' >&2
    exit 64
  fi
fi

git_in_context() {
  if [ "$git_context_count" -eq 1 ]; then
    "$real_git" -C "$git_context" "$@"
  else
    "$real_git" "$@"
  fi
}

push_command=false
[ "$git_command" = push ] && push_command=true

if [ "$push_command" = true ]; then
  if [ "$competing_context" = true ] || [ "$config_override" = true ] || [ -n "${GIT_DIR:-}" ] || [ -n "${GIT_WORK_TREE:-}" ]; then
    printf '%s\n' 'aiur: GitHub push guard cannot inspect competing repository context' >&2
    exit 64
  fi

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

    if git_in_context config --get "remote.$arg.url" >/dev/null 2>&1; then
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
    branch=$(git_in_context symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    if [ -n "$branch" ]; then
      push_target=$(git_in_context config --get "branch.$branch.pushRemote" 2>/dev/null || true)
      [ -n "$push_target" ] || push_target=$(git_in_context config --get remote.pushDefault 2>/dev/null || true)
      [ -n "$push_target" ] || push_target=$(git_in_context config --get "branch.$branch.remote" 2>/dev/null || true)
    fi
    [ -n "$push_target" ] || push_target=origin
  fi

  push_url=$(git_in_context remote get-url --push "$push_target" 2>/dev/null || printf '%s' "$push_target")
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
