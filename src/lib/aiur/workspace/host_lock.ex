defmodule Aiur.Workspace.HostLock do
  @moduledoc """
  Host-wide exclusive lock on one workspace directory (#2551).

  `Aiur.Workspace.Ownership` excludes two sessions inside a single daemon, but
  the workspace path is derived purely from repo and ticket
  (`<root>/<owner>/<repo>/<ticket>`), so two daemons on the same host that
  resolve the same repository interleave writes into one working tree with no
  lock and no error. That is silent corruption: both sessions edit the same
  files in place, and every gate result either one reports — including CI on a
  pushed branch — is worthless.

  The exclusion primitive here is the filesystem, because the filesystem is the
  thing the two daemons actually share. The lock is a sibling file next to the
  workspace directory (`<workspace>.lock`), created with `O_EXCL`, recording
  the owning daemon's node name and OS pid. It deliberately does not live
  *inside* the workspace: provisioning treats a non-empty workspace directory
  as pre-existing state, and a stray file there would change that judgement.

  A lock whose recorded pid is no longer alive is reclaimable. A daemon that
  crashes or is killed must not strand its workspaces forever, so a stale lock
  is taken over rather than honoured. Liveness is probed with
  `Aiur.ProcessIdentity.alive?/1`, which fails *closed* (reports alive) when
  the probe itself errors, so an unreadable process table can never be mistaken
  for a dead holder.

  Remote worker hosts are out of scope: their workspace lives on another
  machine's filesystem, so a lock taken here would exclude nothing.
  """

  require Logger

  alias Aiur.ProcessIdentity
  alias Aiur.Workspace.Layout

  @type worker_host :: String.t() | nil

  @type holder :: %{
          node: String.t(),
          os_pid: integer() | nil,
          ticket: String.t(),
          owner_id: String.t(),
          acquired_at: String.t()
        }

  @type t :: %{path: Path.t(), workspace: Path.t(), holder: holder()}

  @doc """
  Resolves the local workspace for `identifier` and takes its host lock.

  Returns `:not_applicable` for remote worker hosts, whose workspace is not on
  this filesystem.
  """
  @spec acquire_for_issue(String.t(), worker_host(), keyword()) ::
          {:ok, t()} | :not_applicable | {:error, {:workspace_locked, holder()}} | {:error, term()}
  def acquire_for_issue(identifier, worker_host \\ nil, opts \\ [])

  def acquire_for_issue(_identifier, worker_host, _opts) when is_binary(worker_host), do: :not_applicable

  def acquire_for_issue(identifier, nil, opts) when is_binary(identifier) do
    safe_id = Layout.safe_identifier(identifier)

    case Layout.workspace_path_for_issue(safe_id, nil) do
      {:ok, workspace} -> acquire(workspace, identifier, opts)
      {:error, reason} -> {:error, {:workspace_lock_unavailable, reason}}
    end
  end

  @doc """
  Takes the exclusive host lock on `workspace` for `ticket`.

  Fails with `{:error, {:workspace_locked, holder}}` — never silently — when a
  live process on this host already holds it.
  """
  @spec acquire(Path.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, {:workspace_locked, holder()}} | {:error, term()}
  def acquire(workspace, ticket, opts \\ []) when is_binary(workspace) and is_binary(ticket) do
    alive_fun = Keyword.get(opts, :alive_fun, &ProcessIdentity.alive?/1)
    holder = new_holder(ticket, opts)
    path = lock_path(workspace)

    case File.mkdir_p(Path.dirname(path)) do
      :ok -> attempt(path, workspace, holder, alive_fun, true)
      {:error, reason} -> {:error, {:workspace_lock_unavailable, reason}}
    end
  end

  @doc """
  Releases a lock this process took. Never removes a lock another owner holds.
  """
  @spec release(t() | term()) :: :ok
  def release(%{path: path, holder: %{owner_id: owner_id}}) when is_binary(path) do
    case read_holder(path) do
      {:ok, %{owner_id: ^owner_id}} ->
        _ = File.rm(path)
        :ok

      _other ->
        :ok
    end
  end

  def release(_lock), do: :ok

  @doc """
  Current holder of `workspace`'s lock, if any, regardless of liveness.
  """
  @spec holder(Path.t()) :: {:ok, holder()} | :none
  def holder(workspace) when is_binary(workspace) do
    case read_holder(lock_path(workspace)) do
      {:ok, holder} -> {:ok, holder}
      _other -> :none
    end
  end

  @doc """
  One-line, operator-readable description of a holder, for logs and alerts.

  A refusal that does not name the holder leaves an operator guessing which of
  several daemons on the host to look at, so every refusal path routes through
  this.
  """
  @spec describe(holder() | term()) :: String.t()
  def describe(%{node: node, os_pid: os_pid} = holder) do
    "node=#{node} pid=#{os_pid} ticket=#{Map.get(holder, :ticket, "unknown")} since=#{Map.get(holder, :acquired_at, "unknown")}"
  end

  def describe(_holder), do: "an unidentified holder"

  @doc false
  @spec lock_path(Path.t()) :: Path.t()
  def lock_path(workspace) when is_binary(workspace) do
    String.trim_trailing(workspace, "/") <> ".lock"
  end

  defp new_holder(ticket, opts) do
    %{
      node: Keyword.get(opts, :node, to_string(Node.self())),
      os_pid: Keyword.get(opts, :os_pid, os_pid()),
      ticket: ticket,
      owner_id: "#{System.unique_integer([:positive, :monotonic])}-#{System.system_time(:microsecond)}",
      acquired_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp os_pid do
    :os.getpid() |> List.to_string() |> String.to_integer()
  rescue
    _ -> nil
  end

  defp attempt(path, workspace, holder, alive_fun, reclaimable?) do
    case create_exclusive(path, holder) do
      :ok -> {:ok, %{path: path, workspace: workspace, holder: holder}}
      {:error, :eexist} -> resolve_conflict(path, workspace, holder, alive_fun, reclaimable?)
      {:error, reason} -> {:error, {:workspace_lock_unavailable, reason}}
    end
  end

  defp resolve_conflict(path, workspace, holder, alive_fun, reclaimable?) do
    existing = read_holder(path)

    cond do
      not reclaimable? ->
        {:error, {:workspace_locked, contended_holder(existing)}}

      live?(existing, alive_fun) ->
        {:error, {:workspace_locked, contended_holder(existing)}}

      true ->
        reclaim(path, workspace, holder, alive_fun, existing)
    end
  end

  # The recorded pid is gone (or the lock is unreadable and names nobody at
  # all), so the workspace has no live owner and must not stay stranded.
  defp reclaim(path, workspace, holder, alive_fun, existing) do
    Logger.warning("Reclaiming stale workspace lock #{path} from #{describe(contended_holder(existing))}")

    case File.rm(path) do
      :ok -> attempt(path, workspace, holder, alive_fun, false)
      {:error, :enoent} -> attempt(path, workspace, holder, alive_fun, false)
      {:error, reason} -> {:error, {:workspace_lock_unavailable, reason}}
    end
  end

  defp contended_holder({:ok, holder}), do: holder
  defp contended_holder(_other), do: %{node: "unknown", os_pid: nil}

  # A holder whose pid cannot be read names no process to check, so it is not
  # evidence of a live session; a holder with a pid is honoured whenever the
  # probe says the process is still there.
  defp live?({:ok, %{os_pid: os_pid}}, alive_fun) when is_integer(os_pid) and os_pid > 0, do: alive_fun.(os_pid)
  defp live?(_existing, _alive_fun), do: false

  defp create_exclusive(path, holder) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, io} -> write_and_close(path, io, holder)
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_and_close(path, io, holder) do
    result = IO.binwrite(io, encode(holder))
    File.close(io)

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        # A half-written lock names no holder, and leaving it behind would make
        # the next acquirer reclaim it rather than report this failure.
        _ = File.rm(path)
        {:error, reason}
    end
  end

  defp encode(holder), do: Jason.encode!(holder) <> "\n"

  defp read_holder(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(contents) do
      {:ok, decode_holder(decoded)}
    else
      _other -> :none
    end
  end

  defp decode_holder(decoded) do
    %{
      node: string_field(decoded, "node"),
      os_pid: integer_field(decoded, "os_pid"),
      ticket: string_field(decoded, "ticket"),
      owner_id: string_field(decoded, "owner_id"),
      acquired_at: string_field(decoded, "acquired_at")
    }
  end

  defp string_field(decoded, key) do
    case Map.get(decoded, key) do
      value when is_binary(value) -> value
      _other -> "unknown"
    end
  end

  defp integer_field(decoded, key) do
    case Map.get(decoded, key) do
      value when is_integer(value) -> value
      _other -> nil
    end
  end
end
