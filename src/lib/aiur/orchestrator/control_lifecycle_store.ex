defmodule Aiur.Orchestrator.ControlLifecycleStore do
  @moduledoc false

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.Executor.StatePaths
  alias Aiur.JsonStore
  alias Aiur.Orchestrator.ControlLifecycle
  alias Aiur.ProcessIdentity

  @lock_retry_ms 10
  @lock_stale_after_seconds 30
  @lock_timeout_ms 5_000

  @doc "Loads the last redacted lifecycle projection, treating unreadable state as empty."
  @spec load() :: ControlLifecycle.t()
  def load do
    case JsonStore.read(path_for(), %{}) do
      {:ok, persisted} ->
        ControlLifecycle.restore(persisted, [])

      {:error, reason} ->
        Logger.warning("Control lifecycle journal could not be read at #{path_for()}: #{inspect(reason)}; starting empty")
        ControlLifecycle.new()
    end
  end

  @doc "Best-effort durable write after each lifecycle transition."
  @spec save(ControlLifecycle.t()) :: :ok
  def save(%ControlLifecycle{} = lifecycle) do
    persist(&ControlLifecycle.merge(lifecycle, &1))
  end

  @doc false
  @spec update((ControlLifecycle.t() -> ControlLifecycle.t())) :: :ok
  def update(fun) when is_function(fun, 1) do
    persist(fun)
  end

  @doc "Converts any persisted unresolved request to `:expired` during daemon recovery."
  @spec expire_unresolved_on_recovery(ControlLifecycle.t(), keyword()) :: ControlLifecycle.t()
  def expire_unresolved_on_recovery(%ControlLifecycle{} = lifecycle, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    {_expired, lifecycle} = ControlLifecycle.expire_unresolved(lifecycle, :daemon_restart, now: now)
    lifecycle
  end

  @doc false
  @spec path_for() :: Path.t()
  def path_for do
    Application.get_env(:aiur, :control_lifecycle_store_path) ||
      Path.join(StatePaths.dir(), "#{Paths.repo_name()}.control-lifecycle.json")
  end

  defp persist(fun) do
    path = path_for()
    :ok = File.mkdir_p(Path.dirname(path))

    case with_lock(path, fn ->
           lifecycle = fun.(load())
           JsonStore.write!(path, ControlLifecycle.dump(lifecycle))
         end) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Control lifecycle journal lock failed at #{path}: #{inspect(reason)}")
    end

    :ok
  rescue
    error ->
      Logger.warning("Control lifecycle journal could not be persisted at #{path_for()}: #{Exception.message(error)}")
      :ok
  end

  defp with_lock(path, fun), do: acquire_lock(path <> ".lock", fun, @lock_timeout_ms)

  defp acquire_lock(lock, fun, remaining_ms) do
    owner = lock_owner()

    case create_lock(lock, owner) do
      :ok ->
        try do
          fun.()
        after
          release_lock(lock, owner)
        end

      {:error, :eexist} when remaining_ms > 0 ->
        break_stale_lock(lock)
        Process.sleep(@lock_retry_ms)
        acquire_lock(lock, fun, remaining_ms - @lock_retry_ms)

      {:error, :eexist} ->
        {:error, :lock_timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Build the owner record before publishing the canonical lock. A hard link is
  # an atomic create-if-absent operation, so a process killed during candidate
  # creation can leave only an irrelevant candidate file, never an empty lock
  # that blocks every future journal writer.
  defp create_lock(lock, owner) do
    candidate = "#{lock}.#{owner["token"]}.candidate"

    try do
      with :ok <- File.write(candidate, Jason.encode!(owner), [:write, :binary, :exclusive, :sync]) do
        File.ln(candidate, lock)
      end
    after
      File.rm(candidate)
    end
  end

  defp break_stale_lock(lock) do
    with {:ok, %File.Stat{mtime: mtime} = stat} <- File.stat(lock, time: :posix),
         true <- System.os_time(:second) - mtime > @lock_stale_after_seconds do
      reclaim_stale_lock(lock, stat, read_lock_owner(lock))
    end

    :ok
  end

  defp reclaim_stale_lock(lock, _stat, {:ok, owner}) do
    if lock_owner_dead?(owner), do: remove_stale_lock(lock, fn -> release_lock(lock, owner) end)
  end

  defp reclaim_stale_lock(lock, stat, {:error, :invalid_lock_owner}) do
    fingerprint = lock_fingerprint(stat)
    remove_stale_lock(lock, fn -> release_invalid_lock(lock, fingerprint) end)
  end

  defp lock_owner do
    os_pid = System.pid()

    %{
      "hostname" => hostname(),
      "os_pid" => os_pid,
      "process_identity" => encoded_process_identity(os_pid),
      "token" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    }
  end

  defp read_lock_owner(lock) do
    with {:ok, encoded} <- File.read(lock),
         {:ok, %{"hostname" => hostname, "os_pid" => os_pid, "token" => token} = owner} <- Jason.decode(encoded),
         true <- Enum.all?([hostname, os_pid, token], &(is_binary(&1) and &1 != "")),
         true <- valid_process_identity?(Map.get(owner, "process_identity")) do
      {:ok, owner}
    else
      _ -> {:error, :invalid_lock_owner}
    end
  end

  defp lock_owner_dead?(%{"hostname" => hostname, "os_pid" => os_pid} = owner) do
    with true <- hostname == hostname(),
         {pid, ""} <- Integer.parse(os_pid) do
      not ProcessIdentity.alive?(pid) or process_identity_changed?(pid, Map.get(owner, "process_identity"))
    else
      _ -> false
    end
  end

  defp process_identity_changed?(_pid, nil), do: false

  defp process_identity_changed?(pid, expected_identity) do
    case encoded_process_identity(pid) do
      nil -> false
      current -> current != expected_identity
    end
  end

  defp encoded_process_identity(os_pid) when is_binary(os_pid) do
    case Integer.parse(os_pid) do
      {pid, ""} -> encoded_process_identity(pid)
      _ -> nil
    end
  end

  defp encoded_process_identity(pid) when is_integer(pid) do
    case ProcessIdentity.resolve(pid) do
      {:ok, identity} -> identity |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)
      _ -> nil
    end
  end

  defp valid_process_identity?(nil), do: true
  defp valid_process_identity?(identity), do: is_binary(identity) and identity != ""

  defp remove_stale_lock(lock, release_fun) do
    case release_fun.() do
      :ok -> Logger.warning("Removed stale control lifecycle journal lock at #{lock}")
      _ownership_changed -> :ok
    end
  end

  defp release_invalid_lock(lock, fingerprint) do
    with {:ok, stat} <- File.stat(lock, time: :posix),
         ^fingerprint <- lock_fingerprint(stat),
         {:error, :invalid_lock_owner} <- read_lock_owner(lock),
         {:ok, final_stat} <- File.stat(lock, time: :posix),
         ^fingerprint <- lock_fingerprint(final_stat) do
      File.rm(lock)
    else
      _ -> :ownership_changed
    end
  end

  defp lock_fingerprint(%File.Stat{} = stat), do: {stat.inode, stat.size, stat.mtime, stat.ctime}

  defp release_lock(lock, owner) do
    case read_lock_owner(lock) do
      {:ok, ^owner} -> File.rm(lock)
      _ -> :ownership_changed
    end
  end

  defp hostname do
    {:ok, hostname} = :inet.gethostname()
    List.to_string(hostname)
  end
end
