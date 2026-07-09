defmodule Aiur.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias Aiur.{Alerts, Config, RepoBase}
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.Tracker, as: GitHubTracker
  alias Aiur.Workspace.{Checkout, Context, GitMetadata, Layout, Remote}

  @remote_workspace_marker "__AIUR_WORKSPACE__"
  @warm_cache_paths ["src/deps", "src/_build", "deps", "_build"]

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = Context.build(issue_or_identifier)

    try do
      safe_id = Layout.safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- Layout.workspace_path_for_issue(safe_id, worker_host),
           :ok <- Layout.validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <-
             ensure_workspace(workspace, worker_host, issue_context.pr_head_ref),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, worker_host),
           :ok <- maybe_run_github_workspace_preflight(workspace, issue_context, worker_host) do
        maybe_install_agent_skills(workspace, worker_host)
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{Context.log_context(issue_context)} worker_host=#{Context.worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  # Install aiur's bundled agent-operating skills (`using-aiur`, `/aiur-agent`)
  # into the freshly populated workspace so the agent can load the skills the
  # per-turn prompt routes it to instead of full-disk-searching (#689). Local
  # worker only — a remote worker materializes on another host where these local
  # file writes wouldn't land. Idempotent, so reuse + re-dispatch are safe.
  defp maybe_install_agent_skills(workspace, nil), do: Aiur.AgentSkills.install(workspace)
  defp maybe_install_agent_skills(_workspace, worker_host) when is_binary(worker_host), do: :ok

  # PR-anchored creation (`pr_head_ref` set) is only wired for the local
  # worker today; a remote worker_host ignores it and keeps the legacy
  # `aiur/<id>` remote path byte-for-byte (SSH PR-anchored is out of scope
  # for this unit). The 3-arity head delegates to the unchanged 2-arity
  # clauses for the legacy (`pr_head_ref == nil`) path.
  defp ensure_workspace(workspace, worker_host, nil), do: ensure_workspace(workspace, worker_host)

  defp ensure_workspace(workspace, nil, pr_head_ref) when is_binary(pr_head_ref) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_or_materialize(workspace, pr_head_ref)

      true ->
        create_or_materialize(workspace, pr_head_ref)
    end
  end

  defp ensure_workspace(workspace, worker_host, pr_head_ref)
       when is_binary(worker_host) and is_binary(pr_head_ref) do
    ensure_workspace(workspace, worker_host)
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
        Remote.remote_shell_assign("workspace", workspace),
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

    case Remote.run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
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

  defp maybe_run_github_workspace_preflight(workspace, issue_context, worker_host) do
    if github_workspace_preflight_enabled?() do
      case run_workspace_github_preflight(workspace, worker_host) do
        :ok ->
          :ok

        {:error, reason} ->
          emit_workspace_github_preflight_alert(workspace, issue_context, worker_host, reason)
          {:error, {:workspace_github_connectivity_failed, workspace, reason}}

        other ->
          reason = {:unexpected_workspace_github_preflight_result, other}
          emit_workspace_github_preflight_alert(workspace, issue_context, worker_host, reason)
          {:error, {:workspace_github_connectivity_failed, workspace, reason}}
      end
    else
      :ok
    end
  end

  defp github_workspace_preflight_enabled? do
    Application.get_env(:aiur, :workspace_github_preflight_enabled, true) == true and
      Config.tracker_kind() == "github"
  rescue
    _ -> false
  end

  defp run_workspace_github_preflight(workspace, worker_host) do
    fun =
      Application.get_env(:aiur, :workspace_github_preflight_fun, fn _workspace, _worker_host ->
        GitHubTracker.auth_preflight()
      end)

    cond do
      is_function(fun, 2) -> fun.(workspace, worker_host)
      is_function(fun, 1) -> fun.(workspace)
      is_function(fun, 0) -> fun.()
      true -> {:error, {:invalid_workspace_github_preflight_fun, inspect(fun)}}
    end
  end

  defp emit_workspace_github_preflight_alert(workspace, issue_context, worker_host, reason) do
    message = github_workspace_preflight_message(workspace, issue_context, reason)

    Alerts.emit_custom("system.github.connectivity_lost", message,
      reason: message,
      needs_attention: true,
      severity: "warning",
      workspace: workspace,
      worker_host: worker_host
    )
  end

  defp github_workspace_preflight_message(workspace, issue_context, reason) do
    repo = GitHubConfig.repo() || "(unknown repo)"
    formatted = GitHubClient.format_auth_preflight_error(reason)

    "GitHub workspace preflight failed #{Context.log_context(issue_context)} workspace=#{workspace} " <>
      "repo=#{repo}. Probe: #{github_preflight_probe(repo)}. Reason: #{formatted}"
  end

  defp github_preflight_probe("(unknown repo)") do
    "GET https://api.github.com/rate_limit"
  end

  defp github_preflight_probe(repo) do
    "GET https://api.github.com/rate_limit; " <>
      "GET https://api.github.com/repos/#{repo}; " <>
      "GET https://api.github.com/repos/#{repo}/issues?state=open&per_page=1"
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

  # PR-anchored variant: materialize from the warm base (CoW) but check out
  # the PR's existing head branch (`pr_head_ref`) instead of creating a fresh
  # `aiur/<id>`. When pre-warm is unavailable, fall back to the unchanged cold
  # `create_workspace/1` path (the operator's after_create hook owns the clone;
  # PR-anchored cold-clone branch selection is out of scope for this unit).
  defp create_or_materialize(workspace, pr_head_ref) when is_binary(pr_head_ref) do
    with true <- Config.prewarm_enabled?(),
         {:ready, base} when is_binary(base) <- RepoBase.status(),
         true <- File.dir?(base),
         :ok <- materialize_from_base(base, workspace, pr_head_ref) do
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
         :ok <- Checkout.checkout_fresh_branch(workspace) do
      :ok
    else
      other ->
        Logger.warning("prewarm materialize failed (#{inspect(other)}); falling back to cold clone")
        File.rm_rf!(workspace)
        {:error, other}
    end
  end

  @doc false
  # PR-anchored materialize: copy the warm base (CoW) then check out the PR's
  # existing head branch (`pr_head_ref`) instead of creating `aiur/<id>`. The PR
  # branch is a human's existing branch — the agent works it directly and pushes
  # back there, never opening a new `aiur/<id>` PR. Public for tests; callers go
  # through `create_or_materialize/2`.
  @spec materialize_from_base(Path.t(), Path.t(), String.t()) :: :ok | {:error, term()}
  def materialize_from_base(base, workspace, pr_head_ref) when is_binary(pr_head_ref) do
    File.rm_rf!(workspace)
    File.mkdir_p!(Path.dirname(workspace))

    with {_out, 0} <- copy_tree(base, workspace),
         :ok <- Checkout.checkout_existing_pr_branch(workspace, pr_head_ref) do
      :ok
    else
      other ->
        Logger.warning("prewarm materialize (PR-anchored) failed (#{inspect(other)}); falling back to cold clone")
        File.rm_rf!(workspace)
        {:error, other}
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

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case Layout.validate_workspace_path(workspace, nil) do
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
        Remote.remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case Remote.run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
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
    safe_id = Layout.safe_identifier(identifier)

    case Layout.workspace_path_for_issue(safe_id, worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    safe_id = Layout.safe_identifier(identifier)

    case Config.settings!().worker.ssh_hosts do
      [] ->
        case Layout.workspace_path_for_issue(safe_id, nil) do
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
    issue_context = Context.build(issue_or_identifier)
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
    with :ok <- GitMetadata.ensure_git_metadata_writable(workspace, worker_host) do
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
      Context.todo_dispatch?(issue_context) ->
        Logger.warning(
          "Recreating stale leftover workspace after before_run dirty-refresh refusal #{Context.log_context(issue_context)} workspace=#{workspace} worker_host=#{Context.worker_host_for_log(worker_host)}"
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
          "Skipping before_run origin/main refresh: agent has uncommitted WIP, continuing on its branch #{Context.log_context(issue_context)} workspace=#{workspace} worker_host=#{Context.worker_host_for_log(worker_host)}"
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

    Logger.info("Seeding workspace from bootstrap image #{Context.log_context(issue_context)} workspace=#{workspace} worker_host=local image=#{image}")

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

        Logger.warning("Workspace bootstrap image timed out #{Context.log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, "bootstrap_image", timeout_ms}}
    end
  end

  defp seed_from_bootstrap_image(workspace, issue_context, image, pull?, worker_host)
       when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Seeding workspace from bootstrap image #{Context.log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host} image=#{image}")

    case Remote.run_remote_command(worker_host, bootstrap_image_script(workspace, image, pull?), timeout_ms) do
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
      Remote.remote_shell_assign("workspace", workspace),
      pull? && "docker pull #{Remote.shell_escape(image)}",
      "docker run --rm --user \"$(id -u):$(id -g)\" --volume \"$workspace:/workspace\" --workdir /workspace --entrypoint /bin/sh #{Remote.shell_escape(image)} -lc #{Remote.shell_escape(bootstrap_image_copy_script())}"
    ]
    |> Enum.reject(&(&1 in [nil, false, ""]))
    |> Enum.join("\n")
  end

  defp bootstrap_image_copy_script do
    paths = Enum.map_join(@warm_cache_paths, " ", &Remote.shell_escape/1)

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

  defp recreate_workspace(workspace, nil) do
    {:ok, _workspace, _created?} = create_or_materialize(workspace)
    :ok
  end

  defp recreate_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        Remote.remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\"",
        "mkdir -p \"$workspace\""
      ]
      |> Enum.join("\n")

    case Remote.run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:workspace_prepare_failed, worker_host, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec ensure_git_metadata_writable(Path.t(), worker_host()) :: :ok | {:error, term()}
  def ensure_git_metadata_writable(workspace, worker_host \\ nil),
    do: GitMetadata.ensure_git_metadata_writable(workspace, worker_host)

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = Context.build(issue_or_identifier)
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
    Layout.issue_workspace_path(root, Layout.safe_identifier(identifier))
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
            Remote.remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        Remote.run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
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

    Logger.info("Running workspace hook hook=#{hook_name} #{Context.log_context(issue_context)} workspace=#{workspace} worker_host=local")

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

        Logger.info("aiur_perf workspace_hook phase=done hook=#{hook_name} #{Context.log_context(issue_context)} elapsed_ms=#{elapsed_ms}")

        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{Context.log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{Context.log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    case Remote.run_remote_command(worker_host, "cd #{Remote.shell_escape(workspace)} && #{command}", timeout_ms) do
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

    Logger.debug("Workspace hook ok hook=#{hook_name} #{Context.log_context(issue_context)} output_tail=#{inspect(tail)}")

    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{Context.log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

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
end
