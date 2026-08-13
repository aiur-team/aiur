defmodule Aiur.AgentGitHubGuard do
  @moduledoc """
  Installs the fleet guards that wrap agent-launched `gh` and `git` commands.

  The wrappers are embedded at compile time so local and SSH workers receive
  the same behavior from an OTP release without depending on the source
  checkout.
  """

  require Logger

  alias Aiur.AgentCommandInstaller

  @gh_script_path Path.expand("../../priv/github_quota_guard.sh", __DIR__)
  @git_script_path Path.expand("../../priv/github_push_guard.sh", __DIR__)
  @broker_path Path.expand("../../priv/github_budget.py", __DIR__)
  @external_resource @gh_script_path
  @external_resource @git_script_path
  @external_resource @broker_path
  @gh_script File.read!(@gh_script_path)
  @git_script File.read!(@git_script_path)
  @broker File.read!(@broker_path)
  @scripts [{"gh", @gh_script}, {"git", @git_script}, {"aiur-github-budget", @broker}]
  @relative_bin_dir ".aiur-runtime/bin"
  @broker_relative_path ".aiur-runtime/bin/aiur-github-budget"
  @legacy_host_guard_path Path.join(System.user_home!(), ".aiur/github-budget/bin/gh")

  @spec bin_dir(Path.t()) :: Path.t()
  def bin_dir(workspace), do: AgentCommandInstaller.bin_dir(workspace, @relative_bin_dir)

  @spec budget_broker_path(Path.t()) :: Path.t()
  def budget_broker_path(workspace), do: Path.join(workspace, @broker_relative_path)

  @spec host_bin_dir() :: Path.t()
  def host_bin_dir, do: Path.join(System.user_home!(), ".aiur/bin")

  @spec real_gh() :: Path.t() | nil
  def real_gh do
    System.get_env("PATH", "")
    |> String.split(":", trim: true)
    |> Enum.map(&Path.join(&1, "gh"))
    |> Enum.find(&real_gh_path?/1)
  end

  @doc "Installs an opt-in wrapper for Executor shells outside the shared budget state."
  @spec install_host() :: :ok | {:error, term()}
  def install_host do
    bin = host_bin_dir()

    with :ok <- ensure_directory(Path.join(System.user_home!(), ".aiur")),
         :ok <- ensure_directory(Path.dirname(bin)),
         :ok <- ensure_directory(bin),
         :ok <- atomic_install(Path.join(bin, "gh"), @gh_script),
         :ok <- atomic_install(Path.join(bin, "aiur-github-budget"), @broker),
         :ok <- retire_legacy_host_guard() do
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("host GitHub guard install failed reason=#{inspect(reason)}")
        error
    end
  end

  @spec install(Path.t() | nil) :: :ok | {:error, term()}
  def install(workspace) when is_binary(workspace) do
    result =
      Enum.reduce_while(@scripts, :ok, fn {name, script}, :ok ->
        case AgentCommandInstaller.install(workspace, @relative_bin_dir, [name], script, :agent_guard_install_failed) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case result do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("agent GitHub guard install failed workspace=#{workspace} reason=#{inspect(reason)}")
        error
    end
  end

  def install(_workspace), do: :ok

  @spec remote_install_script(Path.t()) :: String.t()
  def remote_install_script(workspace) when is_binary(workspace) do
    Enum.map_join(@scripts, "\n", fn {name, script} ->
      AgentCommandInstaller.remote_install_script(workspace, @relative_bin_dir, [name], script)
    end)
  end

  defp ensure_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_agent_support_path, path, type}}
      {:error, :enoent} -> File.mkdir(path)
      {:error, reason} -> {:error, {:agent_support_path_unavailable, path, reason}}
    end
  end

  defp atomic_install(target, script) do
    temporary = target <> ".#{System.unique_integer([:positive])}.tmp"

    with {:ok, file} <- File.open(temporary, [:write, :binary, :exclusive]),
         :ok <- IO.binwrite(file, script),
         :ok <- File.close(file),
         :ok <- File.chmod(temporary, 0o755),
         :ok <- File.rename(temporary, target) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, {:agent_guard_install_failed, target, reason}}
    end
  end

  defp real_gh_path?(path) do
    path = Path.expand(path)

    path != Path.join(host_bin_dir(), "gh") and
      path != Path.join(System.user_home!(), ".aiur/github-budget/bin/gh") and
      not String.ends_with?(path, "/.aiur-runtime/bin/gh") and
      match?({:ok, %File.Stat{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0, File.stat(path))
  end

  defp retire_legacy_host_guard do
    case File.read(@legacy_host_guard_path) do
      {:ok, contents} ->
        if String.contains?(contents, "Fleet guard for agent-launched `gh` calls.") do
          File.rm(@legacy_host_guard_path)
        else
          :ok
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:legacy_host_guard_unavailable, @legacy_host_guard_path, reason}}
    end
  end
end
