defmodule Aiur.AgentGitHubGuard do
  @moduledoc """
  Installs the fleet quota guard that wraps agent-launched `gh` commands.

  The wrapper is embedded at compile time so local and SSH workers receive the
  same behavior from an OTP release without depending on the source checkout.
  """

  require Logger

  alias Aiur.Workspace.Remote

  @script_path Path.expand("../../priv/github_quota_guard.sh", __DIR__)
  @external_resource @script_path
  @script File.read!(@script_path)
  @relative_path ".aiur-runtime/bin/gh"

  @spec bin_dir(Path.t()) :: Path.t()
  def bin_dir(workspace), do: Path.join(workspace, ".aiur-runtime/bin")

  @spec install(Path.t() | nil) :: :ok | {:error, term()}
  def install(workspace) when is_binary(workspace) do
    target = Path.join(workspace, @relative_path)

    with :ok <- ensure_directory(Path.join(workspace, ".aiur-runtime")),
         :ok <- ensure_directory(Path.dirname(target)),
         :ok <- atomic_install(target) do
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

  defp atomic_install(target) do
    temporary = target <> ".#{System.unique_integer([:positive])}.tmp"

    with {:ok, file} <- File.open(temporary, [:write, :binary, :exclusive]),
         :ok <- IO.binwrite(file, @script),
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
end
