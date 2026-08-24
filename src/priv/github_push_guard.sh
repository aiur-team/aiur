#!/bin/sh

# Identity guard for agent-launched `git` calls. The daemon prepends this
# wrapper's directory to agent PATH and captures the real executable before it
# does so. Authentication remains inert for local commands and reads; when Git
# asks for GitHub HTTPS credentials, the helper returns only the configured
# tracker token and never falls through to a cached Executor credential.
#
# The same script also installs at host level (`~/.aiur/bin`, alongside the
# `gh` guard and `aiurdev`), so an operator shell or CI step that resolves
# `git` through it is covered by the worktree-removal protection (#2094): a
# `git worktree remove` must not destroy a worktree that still has a live
# process rooted in it, or one holding uncommitted work. Every other git
# command passes through the host wrapper untouched — the Executor keeps the
# full git authority it holds today, exactly as the `gh` guard's host mode
# keeps merge authority for the Executor.
real_git=${AIUR_REAL_GIT:-}
is_guard_git() {
  case "$1" in
    "$HOME/.aiur/bin/git"|"$HOME/.aiur/github-budget/bin/git"|*/.aiur-runtime/bin/git) return 0 ;;
    *) return 1 ;;
  esac
}
if [ -n "$real_git" ] && is_guard_git "$real_git"; then real_git=; fi
if [ -z "$real_git" ]; then
  guard_dir=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd) || guard_dir=
  guard_path=${PATH:-}
  guard_old_ifs=$IFS
  IFS=:
  for guard_entry in $guard_path; do
    [ -n "$guard_entry" ] || guard_entry=.
    [ "$guard_entry" = "$guard_dir" ] && continue
    guard_candidate=$guard_entry/git
    is_guard_git "$guard_candidate" && continue
    if [ -x "$guard_candidate" ]; then real_git=$guard_candidate; break; fi
  done
  IFS=$guard_old_ifs
  unset guard_dir guard_path guard_old_ifs guard_entry guard_candidate
fi
if [ -z "$real_git" ] || [ ! -x "$real_git" ]; then
  printf '%s\n' 'aiur: real git executable is unavailable' >&2
  exit 127
fi

credential_helper='!f() { if test "$1" = get; then t=""; f="${AIUR_GITHUB_CREDENTIAL_FILE:-}"; if [ -n "$f" ] && [ -f "$f" ]; then t=$(sed -n "1p" "$f" 2>/dev/null || true); fi; if [ -z "$t" ]; then t=${GITHUB_TOKEN:-${GH_TOKEN:-}}; fi; if [ -z "$t" ]; then printf "quit=true\n"; else printf "username=x-access-token\npassword=%s\n" "$t"; fi; fi; }; f'

# Destructive commands must name the ticket workspace explicitly. Derive that
# authority from this installed wrapper's location rather than an environment
# variable that the child process can replace.
git_command=
git_context=
git_context_count=0
competing_context=false
config_override=false
alias_override=false
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
      config)
        case "$arg" in alias.*=*) alias_override=true ;; esac
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
      expect_global_value=config
      ;;
    -c?*)
      config_override=true
      config_value=${arg#-c}
      case "$config_value" in alias.*=*) alias_override=true ;; esac
      ;;
    --config-env=*)
      config_override=true
      config_value=${arg#--config-env=}
      case "$config_value" in alias.*=*) alias_override=true ;; esac
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

if [ "$alias_override" = true ]; then
  printf '%s\n' 'aiur: inline git aliases cannot bypass repository context' >&2
  exit 64
fi

git_in_context() {
  if [ "$git_context_count" -eq 1 ]; then
    "$real_git" -C "$git_context" "$@"
  else
    "$real_git" "$@"
  fi
}

resolved_git_command=$git_command
alias_depth=0
alias_command=false

while [ "$alias_depth" -lt 8 ]; do
  alias_value=$(git_in_context config --get "alias.$resolved_git_command" 2>/dev/null || true)
  [ -n "$alias_value" ] || break
  alias_command=true

  case "$alias_value" in
    !*)
      printf '%s\n' 'aiur: shell git aliases cannot be validated safely' >&2
      exit 64
      ;;
  esac

  resolved_git_command=${alias_value%%[[:space:]]*}
  case "$resolved_git_command" in
    '' | -*)
      printf '%s\n' 'aiur: git alias repository context cannot be validated safely' >&2
      exit 64
      ;;
  esac

  alias_depth=$((alias_depth + 1))
done

if [ "$alias_depth" -eq 8 ] && git_in_context config --get "alias.$resolved_git_command" >/dev/null 2>&1; then
  printf '%s\n' 'aiur: git alias chain cannot be validated safely' >&2
  exit 64
fi

destructive_command=false
after_git_command=false
worktree_subcommand=
worktree_remove=0
worktree_add=0
worktree_target=
worktree_target_abs=
worktree_dirty=0
worktree_dirty_override=0
worktree_expect_value=
clean_force=false
clean_dry_run=false

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
        --force) clean_force=true ;;
        --dry-run) clean_dry_run=true ;;
        -*)
          clean_options=${arg#-}
          case "$clean_options" in *f*) clean_force=true ;; esac
          case "$clean_options" in *n*) clean_dry_run=true ;; esac
          ;;
      esac
      ;;
    worktree)
      if [ -z "$worktree_subcommand" ]; then
        case "$arg" in
          -*) ;;
          *)
            worktree_subcommand=$arg
            case "$worktree_subcommand" in
              remove)
                destructive_command=true
                worktree_remove=1
                ;;
              add)
                worktree_add=1
                ;;
            esac
            ;;
        esac
      elif [ "$worktree_remove" -eq 1 ] && [ -z "$worktree_target" ]; then
        case "$arg" in
          -*) ;;
          *) worktree_target=$arg ;;
        esac
      elif [ "$worktree_add" -eq 1 ] && [ -z "$worktree_target" ]; then
        # `git worktree add` takes the target path as its first non-flag
        # argument after the subcommand, but `-b`/`-B` consume a following
        # branch name that must not be mistaken for the path (#2362).
        if [ -n "$worktree_expect_value" ]; then
          worktree_expect_value=
        else
          case "$arg" in
            -b|-B) worktree_expect_value=1 ;;
            -*) ;;
            *) worktree_target=$arg ;;
          esac
        fi
      fi
      ;;
  esac
done

case "$git_command" in
  checkout | restore) destructive_command=true ;;
  clean)
    if [ "$clean_force" = true ] || [ "$clean_dry_run" = false ]; then
      destructive_command=true
    fi
    ;;
esac

if [ "$alias_command" = true ]; then
  case "$resolved_git_command" in
    reset | clean | checkout | restore | worktree) destructive_command=true ;;
  esac
fi

if [ "$worktree_remove" -eq 1 ]; then
  for arg in "$@"; do
    if [ "$arg" = --aiur-remove-dirty ]; then worktree_dirty_override=1; fi
  done
fi

if [ "$destructive_command" = true ]; then
  # Whether this wrapper lives inside a fleet workspace
  # (`<workspace>/.aiur-runtime/bin`) or at host level (`~/.aiur/bin`). Only
  # the workspace form carries the #2049 workspace-derived authority; the host
  # form intercepts just `worktree remove` and passes everything else through.
  wrapper_bin=$(CDPATH= cd -P "$(dirname "$0")" 2>/dev/null && pwd)
  workspace_install=0
  case "$wrapper_bin" in
    */.aiur-runtime/bin) workspace_install=1 ;;
  esac

  # Competing repository context is refused for every destructive command in a
  # workspace and for `worktree remove` everywhere: a removal whose repository
  # the guard cannot resolve is a removal it cannot protect.
  if [ "$workspace_install" -eq 1 ] || [ "$worktree_remove" -eq 1 ]; then
    if [ "$competing_context" = true ] || [ "$config_override" = true ] || [ -n "${GIT_DIR:-}" ] || [ -n "${GIT_WORK_TREE:-}" ]; then
      printf '%s\n' 'aiur: destructive git commands cannot use competing repository context' >&2
      exit 64
    fi
  fi

  # The #2049 `-C` requirement and its workspace-derived authority. Unchanged
  # for workspace installs; a host install has no workspace and applies only
  # the universal worktree-removal checks below.
  if [ "$workspace_install" -eq 1 ]; then
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

    runtime_dir=$(dirname "$wrapper_bin")
    expected_workspace=$(dirname "$runtime_dir")
    expected_workspace=$(CDPATH= cd -P "$expected_workspace" 2>/dev/null && pwd)
    target_top=$("$real_git" -C "$git_context" rev-parse --show-toplevel 2>/dev/null || true)
    if [ -n "$target_top" ]; then
      target_top=$(CDPATH= cd -P "$target_top" 2>/dev/null && pwd)
    fi

    if [ -z "$expected_workspace" ] || [ -z "$target_top" ] || [ "$target_top" != "$expected_workspace" ]; then
      printf '%s\n' 'aiur: destructive git target is not the agent workspace' >&2
      exit 64
    fi
  fi

  # -------------------------------------------------------------------------
  # `git worktree remove` (#2094). A worktree is a directory where a live
  # process — an agent session, a running test, a coordinating subagent — holds
  # uncommitted work and an open working directory. Two checks make removing
  # it safe regardless of which process invokes the command:
  #
  #  1. LIVENESS. `/proc/<pid>/cwd` answers "is this process rooted here?"
  #     directly and cheaply, and it catches sibling wrapper processes whose
  #     command lines never mention git or worktree — the case that defeats
  #     naive `/proc/*/cmdline` matching. A live worktree is refused with the
  #     offending pid named, with no override: a process rooted in a worktree
  #     means the worktree is not idle, so removal must wait.
  #
  #  2. UNCOMMITTED CHANGES. Committed work survives in the reflog; uncommitted
  #     work does not, so the asymmetry is encoded rather than left to
  #     judgement. git's own `--force` is REQUIRED for dirty removal, so it
  #     cannot also be the discrimination the guard needs — a coordinator
  #     reflexively passing `--force` would bypass the protection. The caller
  #     must deliberately add the guard's distinct `--aiur-remove-dirty` flag
  #     (which is stripped before the real git sees it, and which also supplies
  #     git's `--force`).
  # -------------------------------------------------------------------------
  if [ "$worktree_remove" -eq 1 ]; then
    if [ -n "$worktree_target" ]; then
      worktree_base=$PWD
      if [ "$git_context_count" -eq 1 ]; then worktree_base=$git_context; fi
      worktree_target_abs=$(CDPATH= cd -P "$worktree_base" 2>/dev/null && cd -P "$worktree_target" 2>/dev/null && pwd 2>/dev/null) || worktree_target_abs=
    fi

    if [ -n "$worktree_target_abs" ] && [ -d /proc ]; then
      for proc_dir in /proc/[0-9]*; do
        [ -d "$proc_dir" ] || continue
        proc_cwd=$(readlink "$proc_dir/cwd" 2>/dev/null || true)
        [ -n "$proc_cwd" ] || continue
        proc_relative=${proc_cwd#"$worktree_target_abs"}
        if [ "$proc_relative" != "$proc_cwd" ]; then
          if [ -z "$proc_relative" ] || [ "${proc_relative#/}" != "$proc_relative" ]; then
            live_pid=${proc_dir#/proc/}
            printf 'aiur: refusing git worktree remove: pid %s is rooted in %s\n' "$live_pid" "$worktree_target_abs" >&2
            exit 64
          fi
        fi
      done
    fi

    if [ -n "$worktree_target_abs" ] && [ -d "$worktree_target_abs" ]; then
      dirty_output=$("$real_git" -C "$worktree_target_abs" status --porcelain 2>/dev/null || true)
      if [ -n "$dirty_output" ]; then worktree_dirty=1; fi
    fi
    if [ "$worktree_dirty" -eq 1 ] && [ "$worktree_dirty_override" -ne 1 ]; then
      printf 'aiur: refusing git worktree remove: %s has uncommitted changes; pass --aiur-remove-dirty to destroy them\n' "$worktree_target_abs" >&2
      exit 64
    fi
  fi
fi

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
