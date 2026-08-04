defmodule Aiur.Workspace.Hooks do
  @moduledoc "Workspace lifecycle hooks: run_hook/5 with env-scrub and Task-timeout envelope, after-create / after-run / before-remove dispatch, and GitHub connectivity preflight."

  require Logger
  alias Aiur.{Alerts, Config, RepoBase}
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.Tracker, as: GitHubTracker
  alias Aiur.Workspace.{Context, Reconstruction, Remote}

  @spec run_after_create(Path.t(), map(), boolean() | :materialized, String.t() | nil) ::
          :ok | {:error, term()}
  def run_after_create(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    run_after_create_hook(hooks.after_create, workspace, issue_context, created?, worker_host)
  end

  # Materialized from the warm base — aiur already populated + branched the
  # workspace, so the cold-clone after_create hook must NOT run.
  defp run_after_create_hook(_command, _workspace, _issue_context, created?, _worker_host)
       when created? != true,
       do: :ok

  defp run_after_create_hook(nil, _workspace, _issue_context, true, _worker_host), do: :ok

  defp run_after_create_hook(command, workspace, issue_context, true, nil) do
    Reconstruction.run(workspace, fn stage ->
      run_hook(command, stage, issue_context, "after_create", nil)
    end)
  end

  defp run_after_create_hook(command, workspace, issue_context, true, worker_host)
       when is_binary(worker_host) do
    run_hook(command, workspace, issue_context, "after_create", worker_host)
  end

  @spec run_after_run(Path.t(), map() | String.t() | nil, String.t() | nil) :: :ok
  def run_after_run(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
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

  @spec run_hook(String.t(), Path.t(), map(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms
    started_at = System.monotonic_time(:millisecond)

    Logger.info("Running workspace hook hook=#{hook_name} #{Context.log_context(issue_context)} workspace=#{workspace} worker_host=local")

    # Scrub Erlang distribution env before running the hook command.
    # Without this, the Executor’s ERL_AFLAGS / RELEASE_NODE /
    # RELEASE_COOKIE propagate into the hook, and any `mix` call in
    # the hook tries to start an Erlang node with the Executor’s
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
          env: hook_env(issue_context)
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

  def run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{Context.log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    case Remote.run_remote_command(worker_host, remote_hook_command(command, workspace, issue_context), timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec remote_hook_command(String.t(), Path.t(), map()) :: String.t()
  def remote_hook_command(command, workspace, issue_context) do
    {state_path, environment} =
      hook_env(issue_context, remote?: true)
      |> Enum.split_with(fn {key, _value} -> key == "AIUR_REPO_STATE_PATH" end)

    state_exports =
      Enum.map_join(state_path, "\n", fn {key, value} ->
        [Remote.remote_shell_assign(key, value), "export #{key}"]
        |> Enum.join("\n")
      end)

    exports = Enum.map_join(environment, " ", fn {key, value} -> "#{key}=#{Aiur.Shell.escape(value)}" end)

    prefix =
      [
        state_exports,
        if(exports == "", do: "", else: "export #{exports};")
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    if prefix == "" do
      "cd #{Aiur.Shell.escape(workspace)} && #{command}"
    else
      "#{prefix}\ncd #{Aiur.Shell.escape(workspace)} && #{command}"
    end
  end

  @doc false
  @spec handle_hook_command_result({iodata(), non_neg_integer()}, Path.t(), map(), String.t()) ::
          :ok | {:error, term()}
  def handle_hook_command_result({output, 0}, _workspace, issue_context, hook_name) do
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

  def handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{Context.log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  @doc false
  @spec ignore_hook_failure(:ok | {:error, term()}) :: :ok
  def ignore_hook_failure(:ok), do: :ok
  def ignore_hook_failure({:error, _reason}), do: :ok

  @doc false
  @spec run_github_preflight(Path.t(), map(), String.t() | nil) :: :ok | {:error, term()}
  def run_github_preflight(workspace, issue_context, worker_host) do
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

  # Env exported to workspace hooks. `THIS_REPOSITORY_URL` is the repo aiur is
  # operating on (the user's repo, not aiur), so an `after_create` hook can
  # `git clone "$THIS_REPOSITORY_URL" .` without hardcoding the URL.
  # `THIS_BASE_BRANCH` is resolved by RepoBase, keeping generated hooks on the
  # same configured branch as warm-base refresh and materialization.
  #
  # `AIUR_REPO_STATE_PATH` is ALWAYS exported. Scaffolded hooks (which `aiur
  # init` writes for every tracker) guard it with `${VAR:?}`, so a tracker
  # without a repo slug must still receive a usable value or the whole hook
  # aborts. Non-GitHub trackers get the same neutral state path that
  # `AgentEnvironment` hands agents, keeping hooks and agents consistent.
  defp hook_env(issue_context, opts \\ []) do
    remote? = Keyword.get(opts, :remote?, false)

    repository_env =
      case github_repo_url() do
        nil ->
          [{"AIUR_REPO_STATE_PATH", repo_state_path(Aiur.AgentEnvironment.neutral_repo_url(), remote?)}]

        repo_url ->
          :ok = RepoBase.ensure_state_tree(repo_url)

          [
            {"THIS_REPOSITORY_URL", repo_url},
            {"THIS_BASE_BRANCH", RepoBase.base_branch()},
            {"AIUR_REPO_STATE_PATH", repo_state_path(repo_url, remote?)}
          ]
      end

    case Map.get(issue_context, :branch_name) do
      branch_name when is_binary(branch_name) and branch_name != "" -> [{"AIUR_TICKET_BRANCH", branch_name} | repository_env]
      _ -> repository_env
    end
  end

  defp github_repo_url do
    with "github" <- Config.settings!().tracker.kind,
         repo when is_binary(repo) and repo != "" <- Aiur.GitHub.Config.repo() do
      "https://github.com/#{repo}.git"
    else
      _ -> nil
    end
  end

  defp repo_state_path(repo_url, true), do: Path.join("~", RepoBase.repo_relative_path(repo_url))
  defp repo_state_path(repo_url, false), do: RepoBase.repo_path(repo_url)

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
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
end
