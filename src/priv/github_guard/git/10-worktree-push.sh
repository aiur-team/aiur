# Fragment of the assembled `git` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.
# -------------------------------------------------------------------------
# `git worktree add` collision guard (#2362). Concurrent agents on one box
# used to create worktrees at the same generic path, and the second silently
# repointed the first's checkout at a different branch mid-run, so mutation
# tests ran against a tree that never contained the change and returned a
# confident wrong verdict. Creating a worktree at a path that already exists
# must fail loudly rather than reuse or repoint it. git itself refuses a
# registered or non-empty path but silently proceeds when the existing path
# is an empty directory - this guard closes that gap and names the failure
# mode so the caller picks a fresh unique path instead of reusing.
# -------------------------------------------------------------------------
if [ "$worktree_add" -eq 1 ] && [ -n "$worktree_target" ]; then
  if [ "$competing_context" = true ] || [ "$config_override" = true ] || [ -n "${GIT_DIR:-}" ] || [ -n "${GIT_WORK_TREE:-}" ]; then
    printf '%s\n' 'aiur: git worktree add cannot validate an existing-path collision under competing repository context' >&2
    exit 64
  fi

  worktree_base=$PWD
  if [ "$git_context_count" -eq 1 ]; then worktree_base=$git_context; fi
  worktree_base_resolved=$(CDPATH= cd -P "$worktree_base" 2>/dev/null && pwd) || worktree_base_resolved=
  case "$worktree_target" in
    /*) worktree_target_abs=$worktree_target ;;
    *)
      if [ -n "$worktree_base_resolved" ]; then
        worktree_target_abs=$worktree_base_resolved/$worktree_target
      fi
      ;;
  esac
  worktree_target_abs=${worktree_target_abs%/}

  if [ -n "$worktree_target_abs" ]; then
    if [ -d "$worktree_target_abs" ]; then
      printf 'aiur: refusing git worktree add: %s already exists\n' "$worktree_target_abs" >&2
      printf 'aiur: reusing an existing path can silently repoint another agent'\''s checkout; pick a fresh unique path (scripts/agent-worktree create) instead\n' >&2
      exit 64
    fi
    if git_in_context worktree list --porcelain 2>/dev/null | grep -q "^worktree ${worktree_target_abs}$"; then
      printf 'aiur: refusing git worktree add: %s is already a registered worktree\n' "$worktree_target_abs" >&2
      printf 'aiur: reusing an existing path can silently repoint another agent'\''s checkout; pick a fresh unique path (scripts/agent-worktree create) instead\n' >&2
      exit 64
    fi
  fi
fi

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
# @aiur-merge-queue-push-guard@
if [ "$worktree_remove" -eq 1 ]; then
  # Rebuild the argument list without the guard's own override flag (git does
  # not know it) and, when the worktree is dirty and the caller opted in, make
  # sure git's native `--force` is present so the removal actually happens.
  # POSIX sh has no arrays, so each argument is rotated from front to back;
  # the original count bounds the loop and the relative order is preserved.
  worktree_arg_count=$#
  worktree_arg_index=0
  while [ "$worktree_arg_index" -lt "$worktree_arg_count" ]; do
    worktree_arg=$1
    shift
    worktree_arg_index=$((worktree_arg_index + 1))
    if [ "$worktree_arg" = --aiur-remove-dirty ]; then
      continue
    fi
    set -- "$@" "$worktree_arg"
  done

  if [ "$worktree_dirty" -eq 1 ] && [ "$worktree_dirty_override" -eq 1 ]; then
    force_present=0
    for worktree_arg in "$@"; do
      case "$worktree_arg" in
        --force|-f) force_present=1 ;;
      esac
    done
    if [ "$force_present" -eq 0 ]; then
      set -- "$@" --force
    fi
  fi
fi

GIT_TERMINAL_PROMPT=0
GIT_CONFIG_PARAMETERS="'credential.https://github.com.helper=' 'credential.https://github.com.helper=$credential_helper' 'http.https://github.com/.extraheader='"
export GIT_TERMINAL_PROMPT GIT_CONFIG_PARAMETERS

exec "$real_git" "$@"
