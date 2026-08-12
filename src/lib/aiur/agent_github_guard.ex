defmodule Aiur.AgentGitHubGuard do
  @moduledoc """
  Installs the fleet guards that wrap agent-launched `gh` and `git` commands.

  The wrapper is embedded at compile time so local and SSH workers receive the
  same behavior from an OTP release without depending on the source checkout.
  """

  require Logger

  alias Aiur.Workspace.Remote

  @gh_script_path Path.expand("../../priv/github_quota_guard.sh", __DIR__)
  @git_script_path Path.expand("../../priv/github_push_guard.sh", __DIR__)
  @external_resource @gh_script_path
  @external_resource @git_script_path
  @scripts [
    {"gh", File.read!(@gh_script_path)},
    {"git", File.read!(@git_script_path)}
  ]

  @spec bin_dir(Path.t()) :: Path.t()
  def bin_dir(workspace), do: Path.join(workspace, ".aiur-runtime/bin")

  @spec install(Path.t() | nil) :: :ok | {:error, term()}
  def install(workspace) when is_binary(workspace) do
    bin_dir = bin_dir(workspace)

    with :ok <- ensure_directory(Path.join(workspace, ".aiur-runtime")),
         :ok <- ensure_directory(bin_dir),
         :ok <- install_scripts(bin_dir) do
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
    [
      "set -eu",
      Remote.remote_shell_assign("workspace", workspace),
      "runtime=\"$workspace/.aiur-runtime\"",
      "bin=\"$runtime/bin\"",
      "if [ -L \"$runtime\" ] || [ -L \"$bin\" ]; then echo 'unsafe symlink in agent support path' >&2; exit 73; fi",
      "mkdir -p \"$bin\"",
      Enum.map_join(@scripts, "\n", fn {name, script} -> remote_install_command(name, script) end)
    ]
    |> Enum.join("\n")
  end

  defp remote_install_command(name, script) do
    encoded = Base.encode64(script)

    [
      "target=\"$bin/#{name}\"",
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

  defp install_scripts(bin_dir) do
    Enum.reduce_while(@scripts, :ok, fn {name, script}, :ok ->
      case atomic_install(Path.join(bin_dir, name), script) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
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
end
