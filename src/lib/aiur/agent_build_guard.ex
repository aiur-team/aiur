defmodule Aiur.AgentBuildGuard do
  @moduledoc """
  Installs shell-independent `elixir`, `mix`, and `mise` entrypoints for the build gate.

  Local coding agents may execute tools through zsh or another shell that does not
  source `BASH_ENV`. The wrappers start Bash explicitly, allowing the existing
  gate hook to enforce the shared lease before resolving the real executable.
  """

  require Logger

  alias Aiur.AgentCommandInstaller

  @script_path Path.expand("../../priv/build_gate_command_wrapper.bash", __DIR__)
  @external_resource @script_path
  @script File.read!(@script_path)
  @commands ~w(elixir mix mise)
  @relative_bin_dir ".aiur-runtime/build-bin"

  @spec bin_dir(Path.t()) :: Path.t()
  def bin_dir(workspace), do: AgentCommandInstaller.bin_dir(workspace, @relative_bin_dir)

  @spec install(Path.t() | nil) :: :ok | {:error, term()}
  def install(workspace) when is_binary(workspace) do
    case AgentCommandInstaller.install(workspace, @relative_bin_dir, @commands, @script, :agent_build_guard_install_failed) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("agent build guard install failed workspace=#{workspace} reason=#{inspect(reason)}")
        error
    end
  end

  def install(_workspace), do: :ok
end
