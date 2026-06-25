defmodule Aiur.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias Aiur.{Config, PathSafety, RepoBase, SSH}

  @remote_workspace_marker "__AIUR_WORKSPACE__"
  @warm_cache_paths ["src/deps", "src/_build", "deps", "_build"]

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_or_materialize(workspace)

      true ->
        create_or_materialize(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  # When pre-warm is enabled and the shared base is ready, materialize the
  # workspace from it (copy-on-write where the filesystem supports it, carrying
  # the warm `_build`/deps) instead of cold-cloning + recompiling. Anything that
  # rules pre-warm out — disabled, base not ready, missing, or a copy failure —
  # falls through to the unchanged cold `create_workspace/1` path.
  defp create_or_materialize(workspace) do
    with true <- Config.prewarm_enabled?(),
         {:ready, base} when is_binary(base) <- RepoBase.status(),
         true <- File.dir?(base),
         :ok <- materialize_from_base(base, workspace) do
      {:ok, workspace, :materialized}
    else
      _ -> create_workspace(workspace)
    end
  end

  @doc false
  # Copy the warm base into `workspace` (CoW when the FS supports it) and branch
  # off the base's HEAD as `aiur/<id>`. Public for tests; callers go through
  # `create_or_materialize/1`.
  @spec materialize_from_base(Path.t(), Path.t()) :: :ok | {:error, term()}
  def materialize_from_base(base, workspace) do
    File.rm_rf!(workspace)
    # The repo-namespaced layout (`<root>/<repo>/<issue>`) means the `<repo>`
    # parent dir may not exist yet for the first agent of a repo; `cp` needs it
    # present. The cold `create_workspace/1` path gets this via `mkdir_p!`; the
    # materialize path must create the parent itself (the leaf is made by `cp`).
    File.mkdir_p!(Path.dirname(workspace))

    with {_out, 0} <- copy_tree(base, workspace),
         :ok <- checkout_fresh_branch(workspace) do
      :ok
    else
      other ->
        Logger.warning("prewarm materialize failed (#{inspect(other)}); falling back to cold clone")
        File.rm_rf!(workspace)
        {:error, other}
    end
  end

  # Branch the agent's `aiur/<id>` off the LIVE `origin/<base>` tip rather than the
  # warm base's copied HEAD. The warm base only refetches on a timer/dispatch gate
  # (#567), so without this a materialized workspace can silently start from stale
  # main. Fetch the base's own tracking branch and branch off its origin tip; if
  # there's no usable remote (tests, offline, detached HEAD), fall back to the
  # copied HEAD — today's behavior — so materialize still succeeds.
  defp checkout_fresh_branch(workspace) do
    args =
      ["-C", workspace, "checkout", "-B", branch_for(workspace)] ++ fresh_base_start_point(workspace)

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      other -> {:error, other}
    end
  end

  # `["origin/<base>"]` when the base's tracking branch could be refetched, else `[]`.
  defp fresh_base_start_point(workspace) do
    with base when is_binary(base) <- current_branch(workspace),
         {_out, 0} <-
           System.cmd("git", ["-C", workspace, "fetch", "origin", base, "--quiet"], stderr_to_stdout: true) do
      ["origin/" <> base]
    else
      _ -> []
    end
  end

  defp current_branch(workspace) do
    case System.cmd("git", ["-C", workspace, "symbolic-ref", "--quiet", "--short", "HEAD"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  # macOS APFS clones via `cp -c`; Linux btrfs/xfs reflink via `cp --reflink=auto`
  # (degrading to a full copy on ext4). Either way the warm `_build`/deps come
  # along, so the agent skips the recompile.
  defp copy_tree(base, workspace) do
    case :os.type() do
      {:unix, :darwin} -> System.cmd("cp", ["-Rc", base, workspace], stderr_to_stdout: true)
      _ -> System.cmd("cp", ["-a", "--reflink=auto", base, workspace], stderr_to_stdout: true)
    end
  end

  defp branch_for(workspace), do: "aiur/" <> Path.basename(workspace)

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            maybe_run_before_remove_hook(workspace, nil)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_id, worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)

    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(safe_id, nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    hook_result =
      run_before_run_command(hooks.before_run, workspace, issue_context, worker_host)

    case hook_result do
      :ok ->
        finalize_before_run_workspace(workspace, issue_context, worker_host)

      {:error, reason} = error ->
        maybe_recreate_stale_workspace(
          error,
          reason,
          hooks.before_run,
          workspace,
          issue_context,
          worker_host
        )
    end
  end

  defp finalize_before_run_workspace(workspace, issue_context, worker_host) do
    with :ok <- ensure_git_metadata_writable(workspace, worker_host) do
      maybe_seed_from_bootstrap_image(workspace, issue_context, worker_host)
    end
  end

  defp run_before_run_command(nil, _workspace, _issue_context, _worker_host), do: :ok

  defp run_before_run_command(command, workspace, issue_context, worker_host) do
    run_hook(command, workspace, issue_context, "before_run", worker_host)
  end

  defp maybe_recreate_stale_workspace(error, reason, before_run, workspace, issue_context, worker_host) do
    cond do
      is_nil(before_run) ->
        error

      not stale_leftover_refresh_refusal?(reason) ->
        error

      # A fresh todo dispatch that lands on a dirty *leftover* workspace
      # (#577): the dirty content is not this agent's WIP, so recreate the
      # workspace clean off origin/main and re-run before_run.
      todo_dispatch?(issue_context) ->
        Logger.warning(
          "Recreating stale leftover workspace after before_run dirty-refresh refusal #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)}"
        )

        with :ok <- recreate_workspace(workspace, worker_host),
             :ok <- run_before_run_command(before_run, workspace, issue_context, worker_host) do
          finalize_before_run_workspace(workspace, issue_context, worker_host)
        end

      # An in-flight / resumed agent (NOT a todo dispatch) whose "dirty"
      # workspace is its legitimate uncommitted WIP (#653). A base-branch
      # push (PR merge) or a resume-after-idle fires before_run, which
      # refuses to refresh from origin/main while tracked changes are
      # present (#569's guard). For a live agent that refusal must NOT be
      # fatal: skip the origin/main refresh and let the agent keep working
      # on its branch (it rebases/merges at PR time anyway). Returning :ok
      # here is what prevents the `Agent run failed -> 3 retries ->
      # retry_exhausted` chain that used to kill every other in-flight
      # agent on each PR merge.
      true ->
        Logger.info(
          "Skipping before_run origin/main refresh: agent has uncommitted WIP, continuing on its branch #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)}"
        )

        finalize_before_run_workspace(workspace, issue_context, worker_host)
    end
  end

  defp maybe_seed_from_bootstrap_image(workspace, issue_context, worker_host) do
    case Config.workspace_bootstrap_image() do
      image when is_binary(image) ->
        seed_from_bootstrap_image(
          workspace,
          issue_context,
          image,
          Config.workspace_bootstrap_image_pull?(),
          worker_host
        )

      _ ->
        :ok
    end
  end

  defp seed_from_bootstrap_image(workspace, issue_context, image, pull?, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Seeding workspace from bootstrap image #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local image=#{image}")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", bootstrap_image_script(workspace, image, pull?)],
          cd: workspace,
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, "bootstrap_image")

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace bootstrap image timed out #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, "bootstrap_image", timeout_ms}}
    end
  end

  defp seed_from_bootstrap_image(workspace, issue_context, image, pull?, worker_host)
       when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Seeding workspace from bootstrap image #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host} image=#{image}")

    case run_remote_command(worker_host, bootstrap_image_script(workspace, image, pull?), timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, "bootstrap_image")

      {:error, {:workspace_hook_timeout, "remote_command", ^timeout_ms}} ->
        {:error, {:workspace_hook_timeout, "bootstrap_image", timeout_ms}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bootstrap_image_script(workspace, image, pull?) do
    [
      "set -eu",
      remote_shell_assign("workspace", workspace),
      pull? && "docker pull #{shell_escape(image)}",
      "docker run --rm --user \"$(id -u):$(id -g)\" --volume \"$workspace:/workspace\" --workdir /workspace --entrypoint /bin/sh #{shell_escape(image)} -lc #{shell_escape(bootstrap_image_copy_script())}"
    ]
    |> Enum.reject(&(&1 in [nil, false, ""]))
    |> Enum.join("\n")
  end

  defp bootstrap_image_copy_script do
    paths = Enum.map_join(@warm_cache_paths, " ", &shell_escape/1)

    """
    set -eu
    found=0
    for path in #{paths}; do
      source="/opt/aiur/$path"
      target="/workspace/$path"

      if [ -e "$target" ]; then
        found=1
        printf 'aiur warm bootstrap: keep existing %s\\n' "$path"
      elif [ -e "$source" ]; then
        found=1
        mkdir -p "$(dirname "$target")"
        cp -R "$source" "$target"
        printf 'aiur warm bootstrap: seeded %s\\n' "$path"
      else
        printf 'aiur warm bootstrap: missing %s in image\\n' "$source"
      fi
    done

    if [ "$found" -eq 0 ]; then
      printf 'aiur warm bootstrap: no cache paths found in image or workspace\\n' >&2
      exit 66
    fi
    """
  end

  defp stale_leftover_refresh_refusal?({:workspace_hook_failed, "before_run", 65, _output}), do: true

  defp stale_leftover_refresh_refusal?(_reason), do: false

  defp todo_dispatch?(%{issue_state: issue_state, issue_labels: labels}) do
    normalize_issue_state(issue_state) == "todo" or
      Enum.any?(labels, &(normalize_issue_state(&1) == "agent:todo"))
  end

  defp normalize_issue_state(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_issue_state(_value), do: ""

  defp recreate_workspace(workspace, nil) do
    {:ok, _workspace, _created?} = create_or_materialize(workspace)
    :ok
  end

  defp recreate_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\"",
        "mkdir -p \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:workspace_prepare_failed, worker_host, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec ensure_git_metadata_writable(Path.t(), worker_host()) :: :ok | {:error, term()}
  def ensure_git_metadata_writable(workspace, worker_host \\ nil)

  def ensure_git_metadata_writable(workspace, nil) when is_binary(workspace) do
    case local_git_metadata_probe_paths(workspace) do
      {:ok, paths} ->
        probe_lock_files(paths)

      :not_git ->
        :ok

      {:error, reason} ->
        {:error, {:workspace_git_metadata_unwritable, workspace, reason}}
    end
  end

  def ensure_git_metadata_writable(workspace, worker_host)
      when is_binary(workspace) and is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if ! git -C \"$workspace\" rev-parse --is-inside-work-tree >/dev/null 2>&1; then",
        "  exit 0",
        "fi",
        "git_dir=\"$(git -C \"$workspace\" rev-parse --git-dir)\"",
        "case \"$git_dir\" in",
        "  /*) ;;",
        "  *) git_dir=\"$workspace/$git_dir\" ;;",
        "esac",
        "workspace_real=\"$(cd \"$workspace\" && pwd -P)\"",
        "git_dir_real=\"$(cd \"$git_dir\" && pwd -P)\"",
        "case \"$git_dir_real/\" in",
        "  \"$workspace_real\"/*) ;;",
        "  *) echo \"git metadata outside workspace: $git_dir_real\" >&2; exit 31 ;;",
        "esac",
        "probe_lock() {",
        "  lock_path=\"$1\"",
        "  mkdir -p \"$(dirname \"$lock_path\")\"",
        "  rm -f \"$lock_path\"",
        "  ( set -C; : > \"$lock_path\" )",
        "  rm -f \"$lock_path\"",
        "}",
        "issue_id=\"$(basename \"$workspace\")\"",
        "probe_lock \"$git_dir_real/index.lock\"",
        "probe_lock \"$git_dir_real/FETCH_HEAD.lock\"",
        "probe_lock \"$git_dir_real/ORIG_HEAD.lock\"",
        "probe_lock \"$git_dir_real/refs/remotes/origin/aiur/${issue_id}.lock\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        {:error, {:workspace_git_metadata_unwritable, workspace, worker_host, status, output}}

      {:error, reason} ->
        {:error, {:workspace_git_metadata_unwritable, workspace, worker_host, reason}}
    end
  end

  defp local_git_metadata_probe_paths(workspace) do
    with {:ok, git_dir} <- local_git_metadata_dir(workspace),
         :ok <- ensure_git_dir_inside_workspace(git_dir, workspace) do
      {:ok, git_metadata_probe_paths(workspace, git_dir)}
    end
  end

  defp probe_lock_files(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case probe_lock_file(path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp local_git_metadata_dir(workspace) do
    case System.cmd("git", ["-C", workspace, "rev-parse", "--is-inside-work-tree"], stderr_to_stdout: true) do
      {_output, 0} ->
        case System.cmd("git", ["-C", workspace, "rev-parse", "--git-dir"], stderr_to_stdout: true) do
          {git_dir, 0} ->
            {:ok, expand_git_dir(workspace, String.trim(git_dir))}

          {output, status} ->
            {:error, {:git_dir_unavailable, status, String.trim(output)}}
        end

      _ ->
        :not_git
    end
  end

  defp expand_git_dir(workspace, git_dir) do
    case Path.type(git_dir) do
      :absolute -> Path.expand(git_dir)
      _ -> Path.expand(git_dir, workspace)
    end
  end

  defp ensure_git_dir_inside_workspace(git_dir, workspace) do
    with {:ok, canonical_git_dir} <- PathSafety.canonicalize(git_dir),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace) do
      workspace_prefix = canonical_workspace <> "/"

      if String.starts_with?(canonical_git_dir <> "/", workspace_prefix) do
        :ok
      else
        {:error, {:git_dir_outside_workspace, canonical_git_dir}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp git_metadata_probe_paths(workspace, git_dir) do
    issue_id = Path.basename(workspace)

    [
      Path.join(git_dir, "index.lock"),
      Path.join(git_dir, "FETCH_HEAD.lock"),
      Path.join(git_dir, "ORIG_HEAD.lock"),
      Path.join([git_dir, "refs", "remotes", "origin", "aiur", "#{issue_id}.lock"])
    ]
  end

  defp probe_lock_file(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- remove_stale_lock(path),
         {:ok, io} <- File.open(path, [:write, :exclusive]) do
      File.close(io)
      File.rm(path)
    else
      {:error, reason} ->
        {:error, {:workspace_git_metadata_unwritable, path, reason}}
    end
  end

  defp remove_stale_lock(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  @doc """
  Per-issue workspace path under `root`, applying the same repo-namespace
  segment `create_for_issue/1` uses. `root` should already be expanded.

  Lets other modules (per-workspace alert logging, the opencode session
  writer) locate an existing workspace without re-deriving the layout — keeping
  them in sync with whatever `create_for_issue/1` produced.
  """
  @spec workspace_path_under(Path.t(), String.t()) :: Path.t()
  def workspace_path_under(root, identifier) when is_binary(root) and is_binary(identifier) do
    issue_workspace_path(root, safe_identifier(identifier))
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> issue_workspace_path(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, issue_workspace_path(Config.settings!().workspace.root, safe_id)}
  end

  # Namespace per-issue workspaces by repo so two repos sharing a root never
  # collide on issue number: <root>/<owner>/<repo>/<issue>. The append is
  # idempotent — if the configured root already ends with the repo segment
  # (e.g. `aiur init` baked owner/name into it), it is not doubled. Trackers
  # without a repo segment (memory, or a misconfigured provider) fall back to
  # <root>/<issue>.
  defp issue_workspace_path(root, safe_id) do
    case repo_segment() do
      nil ->
        Path.join(root, safe_id)

      segment ->
        trimmed = String.trim_trailing(root, "/")

        if trimmed == segment or String.ends_with?(trimmed, "/" <> segment) do
          Path.join(trimmed, safe_id)
        else
          Path.join([trimmed, segment, safe_id])
        end
    end
  end

  # Full `owner/name` segment (e.g. "its-applekid/actions"), kept as nested dirs
  # so forks of the same repo name never collide (its-applekid/actions vs
  # ethereum-optimism/actions). Linear uses project_slug (no owner). Each path
  # component is sanitized and traversal parts (".", "..", "") are dropped so the
  # segment can never escape the workspace root.
  defp repo_segment do
    settings = Config.settings!()

    raw =
      case settings.tracker.kind do
        "github" -> settings.tracker.github.repo
        "linear" -> settings.tracker.linear.project_slug
        _ -> nil
      end

    case raw do
      value when is_binary(value) and value != "" -> safe_repo_segment(value)
      _ -> nil
    end
  end

  defp safe_repo_segment(value) do
    segment =
      value
      |> String.split("/")
      |> Enum.map(&safe_identifier/1)
      |> Enum.reject(&(&1 in ["", ".", ".."]))
      |> Enum.join("/")

    if segment == "", do: nil, else: segment
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host)
        end

      # Materialized from the warm base — aiur already populated + branched the
      # workspace, so the cold-clone after_create hook must NOT run.
      :materialized ->
        :ok

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms
    started_at = System.monotonic_time(:millisecond)

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    # Scrub Erlang distribution env before running the hook command.
    # Without this, the operator's ERL_AFLAGS / RELEASE_NODE /
    # RELEASE_COOKIE propagate into the hook, and any `mix` call in
    # the hook tries to start an Erlang node with the operator's
    # name and fails instantly:
    #   `Protocol 'inet_tcp': the name aiur-orangekid@127.0.0.1
    #    seems to be in use by another Erlang node`
    # The error is non-fatal at the shell level (hook continues to
    # the next `&&` chain step which also fails), so deps.get +
    # compile silently produce nothing and the agent pays the cost
    # of the cold fetch on its first turn. Reuses the same scrub
    # that AgentEnvironment applies for the agent's own shell.
    scrubbed_command = Aiur.AgentEnvironment.scrub_shell_command(command)

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", scrubbed_command],
          cd: workspace,
          stderr_to_stdout: true,
          env: hook_env()
        )
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        Logger.info("aiur_perf workspace_hook phase=done hook=#{hook_name} #{issue_log_context(issue_context)} elapsed_ms=#{elapsed_ms}")

        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    case run_remote_command(worker_host, "cd #{shell_escape(workspace)} && #{command}", timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Env exported to workspace hooks. `THIS_REPOSITORY_URL` is the repo aiur is
  # operating on (the user's repo, not aiur), so an `after_create` hook can
  # `git clone "$THIS_REPOSITORY_URL" .` without hardcoding the URL. Resolved
  # from the same source aiur polls issues with, so it tracks repo-local and
  # global/auto-detected configs alike.
  defp hook_env do
    with "github" <- Config.settings!().tracker.kind,
         repo when is_binary(repo) and repo != "" <- Aiur.GitHub.Config.repo() do
      [{"THIS_REPOSITORY_URL", "https://github.com/#{repo}.git"}]
    else
      _ -> []
    end
  end

  defp handle_hook_command_result({output, 0}, _workspace, issue_context, hook_name) do
    # Log a small tail of successful output. Hooks pre-warm deps and
    # compile; when the hook silently does nothing (e.g. `mix
    # deps.get` was no-op because the inner shell exited early on a
    # masked error), the elapsed time looks fine but agents still pay
    # the deps.get cost on first turn. Visible tail catches that
    # regression early.
    tail = sanitize_hook_output_for_log(output, 512)

    Logger.debug("Workspace hook ok hook=#{hook_name} #{issue_log_context(issue_context)} output_tail=#{inspect(tail)}")

    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier} = issue) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      issue_state: Map.get(issue, :state),
      issue_labels: Map.get(issue, :labels, [])
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      issue_state: nil,
      issue_labels: []
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      issue_state: nil,
      issue_labels: []
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
