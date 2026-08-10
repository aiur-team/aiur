defmodule Aiur.AgentScratch do
  @moduledoc """
  Per-workspace scratch directory for agent temporary files.

  Concurrent agents share the host's `/tmp`, so two agents that independently
  stage a file at the same obvious path (`/tmp/wp_new.md`) silently clobber each
  other: the second write wins and the first agent publishes the other ticket's
  content. Pointing `TMPDIR` at a workspace-private directory fixes that class of
  bug for every tool the agent launches, not just the one path someone remembered
  to make unique.

  The directory lives under `.aiur-runtime/`, which `Aiur.Workspace.GitMetadata`
  already adds to the workspace's git exclusions, so scratch files never dirty
  the tree.
  """

  require Logger

  alias Aiur.Workspace.Remote

  @relative_path ".aiur-runtime/tmp"

  @doc "Absolute path of the workspace-private scratch directory."
  @spec dir(Path.t()) :: Path.t()
  def dir(workspace) when is_binary(workspace), do: Path.join(workspace, @relative_path)

  @doc """
  Create the scratch directory for a local workspace.

  A workspace root that does not exist is left alone: `install/1` runs on every
  agent launch as well as at provisioning time, and conjuring a tree under a
  path the workspace never occupied would be worse than the missing scratch dir.
  """
  @spec install(Path.t() | nil) :: :ok | {:error, term()}
  def install(workspace) when is_binary(workspace) do
    if File.dir?(workspace) do
      case ensure_directory(dir(workspace)) do
        :ok ->
          :ok

        {:error, reason} = error ->
          Logger.warning("agent scratch install failed workspace=#{workspace} reason=#{inspect(reason)}")
          error
      end
    else
      :ok
    end
  end

  def install(_workspace), do: :ok

  @doc "Shell fragment that creates the scratch directory on a remote worker."
  @spec remote_install_script(Path.t()) :: String.t()
  def remote_install_script(workspace) when is_binary(workspace) do
    [
      "set -eu",
      Remote.remote_shell_assign("aiur_scratch_workspace", workspace),
      "aiur_scratch_dir=\"$aiur_scratch_workspace/#{@relative_path}\"",
      "if [ -L \"$aiur_scratch_dir\" ]; then echo 'unsafe symlink in agent scratch path' >&2; exit 73; fi",
      "mkdir -p \"$aiur_scratch_dir\"",
      "unset aiur_scratch_workspace aiur_scratch_dir"
    ]
    |> Enum.join("\n")
  end

  # A symlink here would let a scratch path escape the workspace, so refuse it
  # rather than writing through it — same guard the GitHub wrapper install uses.
  defp ensure_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_agent_scratch_path, path, type}}
      {:error, :enoent} -> File.mkdir_p(path)
      {:error, reason} -> {:error, {:agent_scratch_path_unavailable, path, reason}}
    end
  end
end
