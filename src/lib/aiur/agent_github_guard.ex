defmodule Aiur.AgentGitHubGuard do
  @moduledoc """
  Installs the fleet quota guard that wraps agent-launched `gh` commands.

  The wrapper is embedded at compile time so local and SSH workers receive the
  same behavior from an OTP release without depending on the source checkout.
  """

  require Logger

  alias Aiur.Workspace.Remote

  @script_path Path.expand("../../priv/github_quota_guard.sh", __DIR__)
  @broker_path Path.expand("../../priv/github_budget.py", __DIR__)
  @external_resource @script_path
  @external_resource @broker_path
  @script File.read!(@script_path)
  @broker File.read!(@broker_path)
  @relative_path ".aiur-runtime/bin/gh"
  @broker_relative_path ".aiur-runtime/bin/aiur-github-budget"

  @spec bin_dir(Path.t()) :: Path.t()
  def bin_dir(workspace), do: Path.join(workspace, ".aiur-runtime/bin")

  @spec budget_broker_path(Path.t()) :: Path.t()
  def budget_broker_path(workspace), do: Path.join(workspace, @broker_relative_path)

  @spec host_bin_dir() :: Path.t()
  def host_bin_dir, do: Path.join(System.user_home!(), ".aiur/github-budget/bin")

  @spec real_gh() :: Path.t() | nil
  def real_gh do
    System.get_env("PATH", "")
    |> String.split(":", trim: true)
    |> Enum.map(&Path.join(&1, "gh"))
    |> Enum.find(&real_gh_path?/1)
  end

  @doc "Installs an opt-in wrapper for Executor shells under the shared budget root."
  @spec install_host() :: :ok | {:error, term()}
  def install_host do
    bin = host_bin_dir()

    with :ok <- ensure_directory(Path.join(System.user_home!(), ".aiur")),
         :ok <- ensure_directory(Path.dirname(bin)),
         :ok <- ensure_directory(bin),
         :ok <- atomic_install(Path.join(bin, "gh"), @script),
         :ok <- atomic_install(Path.join(bin, "aiur-github-budget"), @broker) do
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("host GitHub guard install failed reason=#{inspect(reason)}")
        error
    end
  end

  @spec install(Path.t() | nil) :: :ok | {:error, term()}
  def install(workspace) when is_binary(workspace) do
    target = Path.join(workspace, @relative_path)

    with :ok <- ensure_directory(Path.join(workspace, ".aiur-runtime")),
         :ok <- ensure_directory(Path.dirname(target)),
         :ok <- atomic_install(target, @script),
         :ok <- atomic_install(budget_broker_path(workspace), @broker) do
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("agent GitHub guard install failed workspace=#{workspace} reason=#{inspect(reason)}")
        error
    end
  end

  def install(_workspace), do: :ok

  @spec remote_install_script(Path.t()) :: String.t()
  def remote_install_script(workspace) when is_binary(workspace) do
    encoded = Base.encode64(@script)
    broker_encoded = Base.encode64(@broker)

    [
      "set -eu",
      Remote.remote_shell_assign("workspace", workspace),
      "runtime=\"$workspace/.aiur-runtime\"",
      "bin=\"$runtime/bin\"",
      "if [ -L \"$runtime\" ] || [ -L \"$bin\" ]; then echo 'unsafe symlink in agent support path' >&2; exit 73; fi",
      "target=\"$workspace/#{@relative_path}\"",
      "mkdir -p \"$(dirname \"$target\")\"",
      "tmp=\"$target.tmp.$$\"",
      "trap 'rm -f \"$tmp\"' EXIT HUP INT TERM",
      "(set -C; : > \"$tmp\")",
      "printf '%s' '#{encoded}' | base64 -d > \"$tmp\"",
      "chmod 755 \"$tmp\"",
      "mv -f \"$tmp\" \"$target\"",
      "budget_target=\"$workspace/#{@broker_relative_path}\"",
      "budget_tmp=\"$budget_target.tmp.$$\"",
      "trap 'rm -f \"$tmp\" \"$budget_tmp\"' EXIT HUP INT TERM",
      "(set -C; : > \"$budget_tmp\")",
      "printf '%s' '#{broker_encoded}' | base64 -d > \"$budget_tmp\"",
      "chmod 755 \"$budget_tmp\"",
      "mv -f \"$budget_tmp\" \"$budget_target\"",
      "trap - EXIT HUP INT TERM"
    ]
    |> Enum.join("\n")
  end

  defp ensure_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_agent_support_path, path, type}}
      {:error, :enoent} -> File.mkdir(path)
      {:error, reason} -> {:error, {:agent_support_path_unavailable, path, reason}}
    end
  end

  defp atomic_install(target, contents) do
    temporary = target <> ".#{System.unique_integer([:positive])}.tmp"

    with {:ok, file} <- File.open(temporary, [:write, :binary, :exclusive]),
         :ok <- IO.binwrite(file, contents),
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
      not String.ends_with?(path, "/.aiur-runtime/bin/gh") and
      match?({:ok, %File.Stat{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0, File.stat(path))
  end
end
