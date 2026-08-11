defmodule Aiur.AgentGitHubGuard do
  @moduledoc """
  Installs the fleet quota guard that wraps agent-launched `gh` commands.

  The wrapper is embedded at compile time so local and SSH workers receive the
  same behavior from an OTP release without depending on the source checkout.
  """

  require Logger

  alias Aiur.AgentCommandInstaller

  @script_path Path.expand("../../priv/github_quota_guard.sh", __DIR__)
  @external_resource @script_path
  @script File.read!(@script_path)
  @relative_bin_dir ".aiur-runtime/bin"

  @spec bin_dir(Path.t()) :: Path.t()
  def bin_dir(workspace), do: AgentCommandInstaller.bin_dir(workspace, @relative_bin_dir)

  @spec install(Path.t() | nil) :: :ok | {:error, term()}
  def install(workspace) when is_binary(workspace) do
    case AgentCommandInstaller.install(workspace, @relative_bin_dir, ["gh"], @script, :agent_guard_install_failed) do
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
    AgentCommandInstaller.remote_install_script(workspace, @relative_bin_dir, ["gh"], @script)
  end
end
