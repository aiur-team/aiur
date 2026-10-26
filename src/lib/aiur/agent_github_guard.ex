defmodule Aiur.AgentGitHubGuard do
  @moduledoc """
  Installs the fleet guards that wrap agent-launched `gh` and `git` commands.

  The wrappers are embedded at compile time so local and SSH workers receive
  the same behavior from an OTP release without depending on the source
  checkout.
  """

  require Logger

  alias Aiur.AgentCommandInstaller
  alias Aiur.AgentGitHubGuard.{RemoteInstall, Script}
  alias Aiur.GitHub.Access.Wrapper
  @git_script Aiur.AgentGitHubGuard.RecursionGuard.splice(Aiur.AgentGitHubGuard.GitScript.compose(Script.git()), "git")
  @scripts List.insert_at(Wrapper.scripts(), 1, {"git", @git_script})
  @broker @scripts |> List.keyfind("aiur-github-budget", 0) |> elem(1)
  @relative_bin_dir ".aiur-runtime/bin"
  @relative_gh_config_dir ".aiur-runtime/gh"
  @relative_quota_dir ".aiur-runtime/github-quota"

  @spec bin_dir(Path.t()) :: Path.t()
  def bin_dir(workspace), do: AgentCommandInstaller.bin_dir(workspace, @relative_bin_dir)

  @spec budget_broker_path(Path.t()) :: Path.t()
  defdelegate budget_broker_path(workspace), to: Wrapper

  @doc "The path to the credential file the `gh` guard reads; see `AgentToken.path/0`."
  @spec agent_token_path() :: Path.t()
  defdelegate agent_token_path, to: Wrapper

  @doc "Writes the bot PAT to the guard's credential file; see `AgentToken.ensure/1`."
  @spec ensure_agent_token_file(keyword()) :: :ok | :no_credential | {:error, term()}
  defdelegate ensure_agent_token_file(opts \\ []), to: Wrapper

  @doc """
  The agent-private `GH_CONFIG_DIR`.

  SECURITY INVARIANT — this directory holds no credential, and that is the
  point. `gh` resolves auth as `GH_TOKEN`/`GITHUB_TOKEN`, then the host config
  dir (`$GH_CONFIG_DIR`, else `$XDG_CONFIG_HOME/gh`, else `~/.config/gh`) and
  the OS keyring entry that config names. The operator's keyring identity is the
  sole `bypass_actors` entry on the protected branch, so an agent that reaches
  it can approve and merge as the human.

  Pointing agents at an empty workspace-local config dir removes that fallback:
  `env -u GITHUB_TOKEN -u GH_TOKEN gh pr review --approve` — the documented
  bypass — finds no host config and no keyring user, and fails unauthenticated
  instead of succeeding as the operator. Because this is an environment variable
  on the agent process rather than a `PATH` wrapper, it still applies when the
  real `gh` binary is invoked by absolute path.

  The agent's legitimate GitHub access is unaffected: it authenticates with the
  bot PAT in `GITHUB_TOKEN`, which is not a bypass actor. The directory is left
  empty rather than seeded with the bot credential — the token already reaches
  the agent through the environment, so writing a copy to disk would add a
  secret at rest and buy nothing.

  ## What this is not

  This is a **policy boundary, not a capability boundary.** Agents run as the
  same OS user as the Executor, so an agent that goes looking can still read
  `~/.config/gh/hosts.yml`, reach the operator keyring by other means, and read
  the BEAM cookie. What it removes is the documented, one-line `env -u` path and
  every accidental or casually-injected escalation along it — the difference
  between ~32 dispatched agents holding merge authority by default and none of
  them holding it without deliberately breaking out. Real containment needs a
  separate UID or container per agent; do not read this module as providing it.
  """
  @spec gh_config_dir(Path.t()) :: Path.t()
  def gh_config_dir(workspace), do: Path.join(workspace, @relative_gh_config_dir)

  @doc "Agent-private GitHub quota state directory (`AIUR_AGENT_QUOTA_STATE_PATH`)."
  @spec quota_dir(Path.t()) :: Path.t()
  def quota_dir(workspace), do: Path.join(workspace, @relative_quota_dir)

  @doc """
  Names the agent GitHub support pieces a local workspace is missing.

  The agent environment always points `PATH`, `GH_CONFIG_DIR` and
  `AIUR_AGENT_QUOTA_STATE_PATH` into the workspace. If any of these pieces is
  absent, `gh` falls through to the unauthenticated real binary and
  `GH_CONFIG_DIR` dangles (#2697), so dispatch checks this list before a turn
  starts. An empty list means the workspace is fully wired. A symlink never
  counts as present: it could point the agent at the operator's `gh` config.
  """
  @spec missing_workspace_support(Path.t()) :: [String.t()]
  def missing_workspace_support(workspace) when is_binary(workspace) do
    commands =
      for {name, _script} <- @scripts,
          not executable_file?(Path.join(bin_dir(workspace), name)),
          do: Path.join(@relative_bin_dir, name)

    directories =
      for relative <- [@relative_gh_config_dir, @relative_quota_dir],
          not real_directory?(Path.join(workspace, relative)),
          do: relative

    commands ++ directories
  end

  defp executable_file?(path) do
    match?({:ok, %File.Stat{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0, File.lstat(path))
  end

  defp real_directory?(path), do: match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))

  @spec host_bin_dir() :: Path.t()
  defdelegate host_bin_dir, to: Wrapper

  @spec real_gh() :: Path.t() | nil
  defdelegate real_gh, to: Wrapper

  @spec install_host() :: :ok | {:error, term()}
  def install_host, do: Wrapper.install_host([{"git", @git_script}])

  @spec install(Path.t() | nil) :: :ok | {:error, term()}
  def install(workspace) when is_binary(workspace) do
    maybe_log_stale_broker(workspace)

    result =
      Enum.reduce_while(@scripts, :ok, fn {name, script}, :ok ->
        case AgentCommandInstaller.install(workspace, @relative_bin_dir, [name], script, :agent_guard_install_failed) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case with(:ok <- result, :ok <- ensure_gh_config_dir(workspace), do: ensure_quota_dir(workspace)) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("agent GitHub guard install failed workspace=#{workspace} reason=#{inspect(reason)}")
        error
    end
  end

  def install(_workspace), do: :ok

  # A workspace provisioned under an older release keeps its old broker until
  # its next dispatch replaces it. That replacement is the fix for #2307, so
  # make it observable: a log line records when a stale broker was just
  # overwritten with the current release's broker, which is also the evidence
  # that agent-side 304 reconciliation has been restored for this workspace.
  defp maybe_log_stale_broker(workspace) do
    installed = Path.join(bin_dir(workspace), "aiur-github-budget")

    case File.read(installed) do
      {:ok, existing} when existing != @broker ->
        Logger.warning("refreshing stale agent budget broker workspace=#{workspace}")

      _current_or_missing ->
        :ok
    end
  end

  @spec remote_install_script(Path.t(), keyword()) :: String.t()
  def remote_install_script(workspace, opts \\ []) when is_binary(workspace) do
    RemoteInstall.script(workspace, @relative_bin_dir, @scripts, opts)
  end

  # SECURITY INVARIANT — the agent owns its workspace, so it can create
  # `ln -s ~/.config/gh <workspace>/.aiur-runtime/gh` and a bare `mkdir_p` would
  # happily succeed against that symlink on the next dispatch, handing the
  # operator keyring straight back. Reuse the same lstat type check the wrapper
  # install path uses and refuse anything that is not a real directory.
  defp ensure_gh_config_dir(workspace) do
    directory = gh_config_dir(workspace)

    case ensure_directory(directory) do
      :ok -> :ok
      {:error, reason} -> {:error, {:agent_gh_config_dir_unavailable, directory, reason}}
    end
  end

  # The `gh` guard creates this lazily on its first call, but only when the
  # guard itself is on PATH. Installing it here makes a missing quota dir a
  # provisioning gap that dispatch can see, not a silent side effect (#2697).
  defp ensure_quota_dir(workspace) do
    directory = quota_dir(workspace)

    case ensure_directory(directory) do
      :ok -> :ok
      {:error, reason} -> {:error, {:agent_quota_dir_unavailable, directory, reason}}
    end
  end

  defp ensure_directory(path), do: Wrapper.ensure_directory(path)
end
