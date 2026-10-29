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
  alias Aiur.Workspace.Ownership

  @type worker_host :: String.t() | nil

  @type holder :: %{
          optional(:owner_started_at) => String.t() | nil,
          node: String.t(),
          os_pid: integer() | nil,
          ticket: String.t(),
          owner_id: String.t(),
          acquired_at: String.t()
        }

  @type dead_owner_check :: :owner_pid_dead | {:keep, atom()}

  @type t :: %{path: Path.t(), workspace: Path.t(), holder: holder()}

  @typedoc """
  Every outcome of taking the lock.

  `{:error, {:workspace_locked, holder}}` is the refusal that matters — it
  always carries the holder, so no caller can report a collision without
  naming who holds it. `{:error, {:workspace_lock_unavailable, reason}}` means
  the lock could not be evaluated at all (an unwritable path, an unresolvable
  layout); it is a failure, not a refusal, and must not be read as "free".
  """
  @type acquisition ::
          {:ok, t()}
          | {:error, {:workspace_locked, holder()}}
          | {:error, {:workspace_lock_unavailable, term()}}

  @doc """
  Resolves the local workspace for `identifier` and takes its host lock.

  Returns `:not_applicable` for remote worker hosts, whose workspace is not on
  this filesystem.
  """
  @spec acquire_for_issue(String.t(), worker_host(), keyword()) :: acquisition() | :not_applicable
  def acquire_for_issue(identifier, worker_host \\ nil, opts \\ [])

  def acquire_for_issue(_identifier, worker_host, _opts) when is_binary(worker_host),
    do: :not_applicable

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
  @spec acquire(Path.t(), String.t(), keyword()) :: acquisition()
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

  @doc false
  @spec handoff_to_ownership(t(), Ownership.lease()) :: :ok | {:error, :workspace_ownership_lost}
  def handoff_to_ownership(lock, ownership) do
    case Ownership.track_host_lock(ownership, lock) do
      :ok ->
        :ok

      {:error, :workspace_ownership_lost} = error ->
        release(lock)
        error
    end
  end

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
  @spec dead_owner_proof(map() | nil, String.t(), map() | nil) :: dead_owner_check()
  def dead_owner_proof(holder, current_node, host_lock),
    do: dead_owner_proof(holder, current_node, host_lock, [])

  @doc false
  @spec dead_owner_proof(map() | nil, String.t(), map() | nil, keyword()) :: dead_owner_check()
  def dead_owner_proof(
        %{node: node, os_pid: pid, owner_id: owner_id, acquired_at: acquired_at} = holder,
        current_node,
        host_lock,
        opts
      )
      when is_integer(pid) and pid > 0 and is_binary(owner_id) and is_binary(acquired_at) do
    proc_root = Keyword.get(opts, :proc_root, "/proc")
    current_os_pid = Keyword.get(opts, :current_os_pid, os_pid())

    with :ok <- stale_owner_status(holder, node, current_node, host_lock, current_os_pid),
         {:dead, _reason} <- pid_status(pid, holder, proc_root, opts) do
      :owner_pid_dead
    else
      {:keep, reason} -> {:keep, reason}
      {:live, reason} -> {:keep, reason}
      :unknown -> {:keep, :proc_unreadable}
      _ -> {:keep, :pid_alive}
    end
  end

  def dead_owner_proof(%{os_pid: nil}, _current_node, _host_lock, _opts),
    do: {:keep, :pid_missing}

  def dead_owner_proof(_holder, _current_node, _host_lock, _opts),
    do: {:keep, :owner_identity_unavailable}

  defp stale_owner_status(%{os_pid: pid}, _node, _current_node, _host_lock, pid),
    do: {:keep, :owner_matches_daemon}

  defp stale_owner_status(holder, _node, _current_node, %{path: path}, _current_os_pid)
       when is_binary(path) do
    case lock_owner_state(path, holder) do
      :absent -> :ok
      :same_holder -> :ok
      :different_holder -> {:keep, :owner_not_stale}
      :unreadable -> {:keep, :lock_unreadable}
    end
  end

  defp stale_owner_status(_holder, _node, _current_node, _host_lock, _current_os_pid),
    do: {:keep, :lock_identity_unavailable}

  defp lock_owner_state(path, expected_holder) do
    case File.read(path) do
      {:error, :enoent} ->
        :absent

      {:ok, contents} ->
        decode_lock_owner(contents, expected_holder)

      {:error, _reason} ->
        :unreadable
    end
  rescue
    _ -> :unreadable
  end

  defp decode_lock_owner(contents, expected_holder) do
    case Jason.decode(contents) do
      {:ok, decoded} when is_map(decoded) ->
        if same_lock_owner?(decode_holder(decoded), expected_holder),
          do: :same_holder,
          else: :different_holder

      _ ->
        :unreadable
    end
  end

  defp same_lock_owner?(%{owner_id: owner_id, node: node, os_pid: pid}, expected),
    do: owner_id == expected.owner_id and node == expected.node and pid == expected.os_pid

  defp pid_status(pid, holder, proc_root, opts) do
    case File.read(Path.join([proc_root, "self", "stat"])) do
      {:ok, _self_stat} ->
        case File.read(Path.join([proc_root, Integer.to_string(pid), "stat"])) do
          {:error, :enoent} -> {:dead, :absent}
          {:ok, stat} -> process_start_status(stat, holder, proc_root, opts)
          {:error, _} -> :unknown
        end

      _ ->
        :unknown
    end
  rescue
    _ -> :unknown
  end

  defp process_start_status(stat, holder, proc_root, opts) do
    with {close, _} <- List.last(:binary.matches(stat, ")")),
         fields <- binary_part(stat, close + 1, byte_size(stat) - close - 1) |> String.split(),
         {ticks, ""} <- Integer.parse(Enum.at(fields, 19)),
         {:ok, acquired, _} <-
           DateTime.from_iso8601(Map.get(holder, :owner_started_at) || holder.acquired_at),
         {:ok, boot_time} <- proc_boot_time(proc_root),
         {:ok, clock_ticks} <- clock_ticks(opts) do
      started_at_ms = trunc((boot_time + ticks / clock_ticks) * 1_000)
      acquired_at_ms = DateTime.to_unix(acquired, :millisecond)

      cond do
        started_at_ms > acquired_at_ms + 2_000 -> {:dead, :pid_reused}
        started_at_ms > acquired_at_ms -> {:live, :start_time_within_tolerance}
        true -> {:live, :pid_alive}
      end
    else
      _ -> :unknown
    end
  end

  defp clock_ticks(opts) do
    case Keyword.fetch(opts, :clock_ticks) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> :error
      :error -> clock_ticks()
    end
  end

  defp proc_boot_time(proc_root) do
    with {:ok, stat} <- File.read(Path.join(proc_root, "stat")),
         [_, seconds] <- Regex.run(~r/^btime\s+(\d+)$/m, stat),
         {value, ""} <- Integer.parse(seconds),
         do: {:ok, value}
  end

  defp clock_ticks do
    case System.cmd("getconf", ["CLK_TCK"], stderr_to_stdout: true) do
      {value, 0} ->
        case Integer.parse(String.trim(value)) do
          {ticks, ""} when ticks > 0 -> {:ok, ticks}
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

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
      acquired_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      owner_started_at: owner_started_at(Keyword.get(opts, :os_pid, os_pid()))
    }
  end

  defp os_pid do
    :os.getpid() |> List.to_string() |> String.to_integer()
  rescue
    _ -> nil
  end

  defp owner_started_at(pid) when is_integer(pid) and pid > 0 do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         {close, _} <- List.last(:binary.matches(stat, ")")),
         fields <- binary_part(stat, close + 1, byte_size(stat) - close - 1) |> String.split(),
         {ticks, ""} <- Integer.parse(Enum.at(fields, 19)),
         {:ok, boot_time} <- proc_boot_time("/proc"),
         {:ok, clock_ticks} <- clock_ticks() do
      DateTime.from_unix!(trunc((boot_time + ticks / clock_ticks) * 1_000), :millisecond)
      |> DateTime.to_iso8601()
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp owner_started_at(_pid), do: nil

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

  # A refusal always carries a full holder, even when the lock file could not
  # be read: callers pattern-match on the shape to build the message that names
  # who is holding the workspace, and must not have to special-case a partial
  # one.
  defp contended_holder(_other),
    do: %{
      node: "unknown",
      os_pid: nil,
      ticket: "unknown",
      owner_id: "unknown",
      acquired_at: "unknown",
      owner_started_at: nil
    }

  # A holder whose pid cannot be read names no process to check, so it is not
  # evidence of a live session; a holder with a pid is honoured whenever the
  # probe says the process is still there.
  defp live?({:ok, %{os_pid: os_pid}}, alive_fun) when is_integer(os_pid) and os_pid > 0,
    do: alive_fun.(os_pid)

  defp live?(_existing, _alive_fun), do: false

  # `:file` rather than `File`/`IO`: the whole point of this call is the
  # `:eexist` that `:exclusive` returns when someone already holds the lock,
  # and `IO.binwrite/2` is specced to return `:ok` alone, so a write failure
  # there is unreportable.
  defp create_exclusive(path, holder) do
    case :file.open(path, [:write, :binary, :exclusive]) do
      {:ok, io} -> write_and_close(path, io, holder)
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_and_close(path, io, holder) do
    result = :file.write(io, encode(holder))
    _ = :file.close(io)

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
      acquired_at: string_field(decoded, "acquired_at"),
      owner_started_at: optional_string_field(decoded, "owner_started_at")
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

  defp optional_string_field(decoded, key),
    do: if(is_binary(Map.get(decoded, key)), do: Map.get(decoded, key), else: nil)
end
