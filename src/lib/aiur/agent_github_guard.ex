defmodule Aiur.AgentGitHubGuard do
  @moduledoc """
  Installs the fleet guards that wrap agent-launched `gh` and `git` commands.

  The wrapper is embedded at compile time so local and SSH workers receive the
  same behavior from an OTP release without depending on the source checkout.
  """

  require Logger

  alias Aiur.AgentCommandInstaller

  @gh_script_path Path.expand("../../priv/github_quota_guard.sh", __DIR__)
  @git_script_path Path.expand("../../priv/github_push_guard.sh", __DIR__)
  @external_resource @gh_script_path
  @external_resource @git_script_path
  @scripts [
    {"gh", File.read!(@gh_script_path)},
    {"git", File.read!(@git_script_path)}
  ]
  @relative_bin_dir ".aiur-runtime/bin"

  @spec bin_dir(Path.t()) :: Path.t()
  def bin_dir(workspace), do: AgentCommandInstaller.bin_dir(workspace, @relative_bin_dir)

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
end
