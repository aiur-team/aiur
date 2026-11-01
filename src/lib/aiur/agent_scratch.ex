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

  alias Aiur.Shell

  @relative_path ".aiur-runtime/tmp"
  @mcp_socket_dir_env "AIUR_MCP_SOCKET_DIR"
  @mcp_socket_limit 107

  @doc "Absolute path of the workspace-private scratch directory."
  @spec dir(Path.t()) :: Path.t()
  def dir(workspace) when is_binary(workspace), do: Path.join(workspace, @relative_path)

  @doc "Short private directory for Claude MCP bridge sockets."
  @spec mcp_socket_dir(Path.t(), keyword()) :: Path.t()
  def mcp_socket_dir(workspace, opts \\ []) when is_binary(workspace) do
    runtime_root = Keyword.get(opts, :runtime_root) || runtime_root()
    user_id = Keyword.get(opts, :user_id) || user_id()
    digest = :crypto.hash(:sha256, workspace) |> Base.encode16(case: :lower) |> binary_part(0, 10)
    Path.join([runtime_root, "aiur-#{user_id}", digest])
  end

  @doc "Maximum historical Claude MCP socket path length for a configured root and repo segment."
  @spec legacy_mcp_socket_path_length(Path.t(), String.t()) :: non_neg_integer()
  def legacy_mcp_socket_path_length(workspace_root, repo_segment)
      when is_binary(workspace_root) and is_binary(repo_segment) do
    [workspace_root, repo_segment, String.duplicate("9", 5), @relative_path, "aiur-mcp-9999999-999.sock"]
    |> Path.join()
    |> byte_size()
  end

  @doc "Warn when the legacy socket path would exceed the Unix-domain socket limit."
  @spec warn_legacy_mcp_socket_path(Path.t(), String.t()) :: :ok
  def warn_legacy_mcp_socket_path(workspace_root, repo_segment) do
    length = legacy_mcp_socket_path_length(workspace_root, repo_segment)

    if length > @mcp_socket_limit do
      Logger.warning("Claude MCP bridge legacy socket path may exceed Unix sun_path limit: #{length} bytes > #{@mcp_socket_limit}")
    end

    :ok
  end

  @spec mcp_socket_path_limit() :: pos_integer()
  def mcp_socket_path_limit, do: @mcp_socket_limit

  @doc false
  @spec mcp_socket_env(Path.t()) :: [{charlist(), charlist()}]
  def mcp_socket_env(workspace), do: mcp_socket_env(workspace, [])

  @doc false
  @spec mcp_socket_env(Path.t(), keyword()) :: [{charlist(), charlist()}]
  def mcp_socket_env(workspace, opts) do
    path = mcp_socket_dir(workspace, opts)

    private_root = Path.dirname(path)

    with :ok <- File.mkdir_p(private_root),
         :ok <- ensure_private_root(private_root),
         :ok <- File.mkdir_p(path),
         :ok <- File.chmod(path, 0o700) do
      [{String.to_charlist(@mcp_socket_dir_env), String.to_charlist(path)}]
    else
      error ->
        Logger.warning("Claude MCP socket directory unavailable path=#{path} error=#{inspect(error)}")
        []
    end
  end

  defp ensure_private_root(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} when Bitwise.band(mode, 0o777) == 0o700 -> :ok
      {:ok, _} -> File.chmod(path, 0o700)
      {:error, reason} -> {:error, reason}
    end
  end

  defp runtime_root do
    case System.get_env("XDG_RUNTIME_DIR") do
      path when is_binary(path) and path != "" -> path
      _ -> "/tmp"
    end
  end

  defp user_id do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {id, 0} -> String.trim(id)
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

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
      Shell.remote_assign("aiur_scratch_workspace", workspace),
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
