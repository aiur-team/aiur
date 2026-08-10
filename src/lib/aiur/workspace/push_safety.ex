defmodule Aiur.Workspace.PushSafety do
  @moduledoc "Installs Aiur's fail-closed pre-push guard in agent workspaces."

  alias Aiur.Config
  alias Aiur.Workspace.Remote

  @default_max_base_behind_commits 50
  @default_max_untouched_deleted_files 100
  @default_fetch_timeout_seconds 30

  @hook_body """
  #!/bin/sh
  set -eu

  updates="$(mktemp "${TMPDIR:-/tmp}/aiur-pre-push.XXXXXX")"
  cleanup() {
    rm -f "$updates" "$updates.deleted" "$updates.touched" "$updates.untouched"
  }
  trap cleanup EXIT HUP INT TERM
  cat > "$updates"

  remote_name="$1"
  base_branch="$(git config --local --get aiur.baseBranch || true)"
  max_behind="$(git config --local --get aiur.maxBaseBehindCommits || true)"
  max_untouched="$(git config --local --get aiur.maxUntouchedDeletedFiles || true)"
  fetch_timeout="$(git config --local --get aiur.pushSafetyFetchTimeoutSeconds || true)"

  if [ -z "$base_branch" ] || [ -z "$max_behind" ] || [ -z "$max_untouched" ] ||
     [ -z "$fetch_timeout" ]; then
    echo "Aiur safety guard: refusing push because its configured limits are unavailable." >&2
    exit 41
  fi

  base_ref="refs/remotes/$remote_name/$base_branch"
  if ! git check-ref-format "$base_ref" >/dev/null 2>&1 ||
     ! git remote get-url "$remote_name" >/dev/null 2>&1; then
    echo "Aiur safety guard: refusing push because remote/base identity is invalid: $remote_name/$base_branch." >&2
    exit 42
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout "$fetch_timeout" git fetch --quiet "$remote_name" "+refs/heads/$base_branch:$base_ref" &&
      fetch_status=0 || fetch_status=$?
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV or exit 127' "$fetch_timeout" \
      git fetch --quiet "$remote_name" "+refs/heads/$base_branch:$base_ref" &&
      fetch_status=0 || fetch_status=$?
  else
    echo "Aiur safety guard: refusing push because no bounded-time command runner is available." >&2
    exit 43
  fi

  if [ "$fetch_status" -ne 0 ]; then
    echo "Aiur safety guard: refusing push because configured base $remote_name/$base_branch could not be refreshed." >&2
    exit 43
  fi

  while read -r local_ref local_sha remote_ref _remote_sha; do
    case "$remote_ref:$local_sha" in
      refs/heads/*:0000000000000000000000000000000000000000) continue ;;
      refs/heads/*:*) ;;
      *) continue ;;
    esac

    if ! git cat-file -e "$local_sha^{commit}" 2>/dev/null; then
      echo "Aiur safety guard: refusing push because $local_ref does not resolve to a commit." >&2
      exit 44
    fi

    behind="$(git rev-list --count "$local_sha..$base_ref")"
    if [ "$behind" -gt "$max_behind" ]; then
      echo "Aiur safety guard: refusing push: $local_ref is $behind commits behind $remote_name/$base_branch (limit $max_behind). Merge the configured base and re-verify the branch diff." >&2
      exit 45
    fi

    merge_base="$(git merge-base "$local_sha" "$base_ref" || true)"
    if [ -z "$merge_base" ]; then
      echo "Aiur safety guard: refusing push because $local_ref has no merge base with $remote_name/$base_branch." >&2
      exit 46
    fi

    git diff --diff-filter=D --name-only "$base_ref" "$local_sha" |
      LC_ALL=C sort -u > "$updates.deleted"
    git log --format= --name-only "$merge_base..$local_sha" |
      sed '/^$/d' | LC_ALL=C sort -u > "$updates.touched"
    LC_ALL=C comm -23 "$updates.deleted" "$updates.touched" > "$updates.untouched"
    untouched_count="$(wc -l < "$updates.untouched" | tr -d ' ')"

    if [ "$untouched_count" -gt "$max_untouched" ]; then
      echo "Aiur safety guard: refusing push: $local_ref deletes $untouched_count files from $remote_name/$base_branch that its commits never touched (limit $max_untouched)." >&2
      echo "This usually means the branch was created from the wrong base; recreate or merge the configured base before opening a PR." >&2
      exit 47
    fi
  done < "$updates"

  original_hooks="$(git config --local --get aiur.originalHooksPath || true)"
  if [ -n "$original_hooks" ] && [ -x "$original_hooks/pre-push" ] &&
     [ "$original_hooks/pre-push" != "$0" ]; then
    "$original_hooks/pre-push" "$@" < "$updates"
  fi
  """

  @spec install(Path.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def install(workspace, worker_host \\ nil, opts \\ [])

  def install(workspace, nil, opts) when is_binary(workspace) do
    with {:ok, script} <- install_script(workspace, opts) do
      case System.cmd("sh", ["-lc", script], stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {:push_safety_install_failed, workspace, status, output}}
      end
    end
  end

  def install(workspace, worker_host, opts)
      when is_binary(workspace) and is_binary(worker_host) do
    with {:ok, script} <- install_script(workspace, opts) do
      case Remote.run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
        {:ok, {_output, 0}} -> :ok
        {:ok, {output, status}} -> {:error, {:push_safety_install_failed, workspace, worker_host, status, output}}
        {:error, reason} -> {:error, {:push_safety_install_failed, workspace, worker_host, reason}}
      end
    end
  end

  @doc false
  @spec install_script(Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def install_script(workspace, opts) do
    base_branch = Keyword.get_lazy(opts, :base_branch, &Config.base_branch/0)
    max_behind = Keyword.get(opts, :max_base_behind_commits, @default_max_base_behind_commits)
    max_untouched = Keyword.get(opts, :max_untouched_deleted_files, @default_max_untouched_deleted_files)
    fetch_timeout = Keyword.get(opts, :fetch_timeout_seconds, @default_fetch_timeout_seconds)

    with :ok <- validate_base_branch(base_branch),
         :ok <- validate_limit(:max_base_behind_commits, max_behind),
         :ok <- validate_limit(:max_untouched_deleted_files, max_untouched),
         :ok <- validate_positive(:fetch_timeout_seconds, fetch_timeout) do
      {:ok, render_install_script(workspace, base_branch, max_behind, max_untouched, fetch_timeout)}
    end
  end

  defp render_install_script(workspace, base_branch, max_behind, max_untouched, fetch_timeout) do
    escaped_workspace = Aiur.Shell.escape(workspace)
    escaped_hook = Aiur.Shell.escape(@hook_body)

    """
    set -eu
    workspace=#{escaped_workspace}
    hook_body=#{escaped_hook}
    if ! git -C "$workspace" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      exit 0
    fi
    git_dir="$(git -C "$workspace" rev-parse --git-dir)"
    case "$git_dir" in
      /*) ;;
      *) git_dir="$workspace/$git_dir" ;;
    esac
    workspace_real="$(CDPATH= cd "$workspace" && pwd -P)"
    git_dir_real="$(CDPATH= cd "$git_dir" && pwd -P)"
    case "$git_dir_real/" in
      "$workspace_real"/*) ;;
      *) echo "Aiur push safety refuses git metadata outside the workspace: $git_dir_real" >&2; exit 31 ;;
    esac
    hook_dir="$git_dir_real/aiur-hooks"
    if [ -L "$hook_dir" ] || { [ -e "$hook_dir" ] && [ ! -d "$hook_dir" ]; }; then
      echo "Aiur push safety refuses unsafe hook directory: $hook_dir" >&2
      exit 32
    fi
    mkdir -p "$hook_dir"
    hook_dir_real="$(CDPATH= cd "$hook_dir" && pwd -P)"
    case "$hook_dir_real/" in
      "$git_dir_real"/*) ;;
      *) echo "Aiur push safety refuses hook directory outside git metadata: $hook_dir_real" >&2; exit 33 ;;
    esac
    hook_dir="$hook_dir_real"
    hook_path="$hook_dir/pre-push"
    current_hooks="$(git -C "$workspace" config --local --get core.hooksPath || true)"
    effective_hooks="$(git -C "$workspace" config --get core.hooksPath || true)"
    original_hooks="$(git -C "$workspace" config --local --get aiur.originalHooksPath || true)"
    configured_base="$(git -C "$workspace" config --local --get aiur.baseBranch || true)"
    configured_max_behind="$(git -C "$workspace" config --local --get aiur.maxBaseBehindCommits || true)"
    configured_max_untouched="$(git -C "$workspace" config --local --get aiur.maxUntouchedDeletedFiles || true)"
    configured_fetch_timeout="$(git -C "$workspace" config --local --get aiur.pushSafetyFetchTimeoutSeconds || true)"
    expected_hook_oid="$(printf '%s' "$hook_body" | git -C "$workspace" hash-object --stdin)"
    actual_hook_oid="$(git -C "$workspace" hash-object "$hook_path" 2>/dev/null || true)"
    if [ "$current_hooks" = "$hook_dir" ] &&
       [ -x "$hook_path" ] &&
       [ "$configured_base" = #{Aiur.Shell.escape(base_branch)} ] &&
       [ "$configured_max_behind" = #{max_behind} ] &&
       [ "$configured_max_untouched" = #{max_untouched} ] &&
       [ "$configured_fetch_timeout" = #{fetch_timeout} ] &&
       [ "$actual_hook_oid" = "$expected_hook_oid" ]; then
      exit 0
    fi
    if [ "$current_hooks" != "$hook_dir" ] && [ -z "$original_hooks" ]; then
      if [ -n "$effective_hooks" ]; then
        case "$effective_hooks" in
          /*) original_hooks="$effective_hooks" ;;
          *) original_hooks="$workspace/$effective_hooks" ;;
        esac
      else
        original_hooks="$(git -C "$workspace" rev-parse --git-path hooks)"
        case "$original_hooks" in
          /*) ;;
          *) original_hooks="$workspace/$original_hooks" ;;
        esac
      fi
      git -C "$workspace" config --local aiur.originalHooksPath "$original_hooks"
    fi
    hook_tmp="$(mktemp "$hook_dir/.pre-push.XXXXXX")"
    trap 'rm -f "$hook_tmp"' EXIT HUP INT TERM
    printf '%s' "$hook_body" > "$hook_tmp"
    chmod 700 "$hook_tmp"
    mv "$hook_tmp" "$hook_path"
    trap - EXIT HUP INT TERM
    git -C "$workspace" config --local aiur.baseBranch #{Aiur.Shell.escape(base_branch)}
    git -C "$workspace" config --local aiur.maxBaseBehindCommits #{max_behind}
    git -C "$workspace" config --local aiur.maxUntouchedDeletedFiles #{max_untouched}
    git -C "$workspace" config --local aiur.pushSafetyFetchTimeoutSeconds #{fetch_timeout}
    git -C "$workspace" config --local core.hooksPath "$hook_dir"
    """
  end

  defp validate_base_branch(base_branch) when is_binary(base_branch) do
    if String.trim(base_branch) == "",
      do: {:error, :missing_base_branch},
      else: :ok
  end

  defp validate_base_branch(_base_branch), do: {:error, :missing_base_branch}

  defp validate_limit(_name, value) when is_integer(value) and value >= 0, do: :ok
  defp validate_limit(name, value), do: {:error, {:invalid_push_safety_limit, name, value}}

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, value), do: {:error, {:invalid_push_safety_limit, name, value}}
end
