defmodule Aiur.Machine.StoreLock do
  @moduledoc """
  Cross-process mkdir lock, with a VM mutex for tasks sharing an OS pid.
  A gateway retains `hold_lock/1`'s handle and passes `lock: handle` to writes;
  release it with `release_lock/1` on shutdown. Handles never bypass the VM mutex.
  Nested writes in `with_lock/2` reuse the current process's ownership.
  """

  alias Aiur.Machine.Store

  @spec with_lock((-> term()), non_neg_integer() | keyword()) :: term()
  def with_lock(fun, timeout_or_opts \\ 5_000) do
    opts = options(timeout_or_opts)
    path = Path.join(Store.paths().dir, "store.lock")

    if Process.get({__MODULE__, path}) do
      fun.()
    else
      deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 5_000)
      serialized(path, deadline, fn -> run_locked(path, fun, opts, deadline) end, opts)
    end
  end

  @spec hold_lock(keyword()) :: {:ok, map()} | {:error, term()} | {:error, :store_locked, binary()}
  def hold_lock(opts \\ []) do
    path = Path.join(Store.paths().dir, "store.lock")
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 5_000)
    serialized(path, deadline, fn -> acquire(path, Keyword.put(opts, :role, :gateway), deadline) end)
  end

  @spec release_lock(map()) :: :ok | {:error, term()}
  def release_lock(%{path: path} = handle) do
    serialized(path, System.monotonic_time(:millisecond) + 5_000, fn -> release(handle) end)
  end

  defp options(timeout) when is_integer(timeout) and timeout >= 0, do: [timeout: timeout]
  defp options(opts) when is_list(opts), do: opts

  defp serialized(path, deadline, fun, opts \\ []) do
    id = {{__MODULE__, path}, self()}

    if :global.set_lock(id, [node()], 0) do
      try do
        fun.()
      after
        :global.del_lock(id, [node()])
      end
    else
      retry(path, deadline, fn -> serialized(path, deadline, fun, opts) end, opts)
    end
  end

  defp run_locked(path, fun, opts, deadline) do
    case Keyword.fetch(opts, :lock) do
      {:ok, handle} ->
        if handle.path == path and owned?(handle), do: invoke(path, fun), else: {:error, :lock_lost}

      :error ->
        with {:ok, handle} <- acquire(path, opts, deadline) do
          try do
            invoke(path, fun)
          after
            release(handle)
          end
        end
    end
  end

  defp invoke(path, fun) do
    Process.put({__MODULE__, path}, true)

    try do
      fun.()
    after
      Process.delete({__MODULE__, path})
    end
  end

  defp acquire(path, opts, deadline) do
    with :ok <- Store.check_dir(Path.dirname(path)) do
      case File.mkdir(path) do
        :ok -> claim(path, opts)
        {:error, :eexist} -> contend(path, opts, deadline)
        error -> error
      end
    end
  end

  defp claim(path, opts) do
    owner = System.pid() <> " " <> to_string(Keyword.get(opts, :role, :cli))

    with :ok <- File.chmod(path, 0o700),
         :ok <- Aiur.Fs.atomic_write(Path.join(path, "owner"), owner, mode: 0o600),
         {:ok, stat} <- File.stat(path) do
      File.rmdir(path <> ".recovery")
      {:ok, %{path: path, owner: owner, inode: stat.inode}}
    else
      error ->
        File.rm(Path.join(path, "owner"))
        File.rmdir(path)
        error
    end
  end

  defp contend(path, opts, deadline) do
    # A local gateway releases through this mutex too; never wait while holding it.
    if File.read(Path.join(path, "owner")) == {:ok, System.pid() <> " gateway"} do
      {:error, :store_locked, "gateway"}
    else
      reclaim(path, opts)
      retry(path, deadline, fn -> acquire(path, opts, deadline) end, opts)
    end
  end

  defp retry(path, deadline, fun, opts) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :store_locked, holder(path)}
    else
      Keyword.get(opts, :on_wait, fn -> :ok end).()
      Process.sleep(min(50, remaining))
      fun.()
    end
  end

  defp holder(path) do
    case File.read(Path.join(path, "owner")) do
      {:ok, owner} -> owner |> String.split() |> List.last()
      _ -> "unknown"
    end
  end

  defp reclaim(path, opts) do
    recovery = path <> ".recovery"

    if stale?(path, opts) and File.mkdir(recovery) == :ok do
      try do
        if stale?(path, opts), do: retire(path)
      after
        File.rmdir(recovery)
      end
    end
  end

  defp stale?(path, opts) do
    case File.read(Path.join(path, "owner")) do
      {:ok, owner} ->
        case String.split(owner) do
          [pid, role] when role in ["gateway", "cli"] ->
            dead_owner?(path, pid, role, opts)

          _ ->
            false
        end

      {:error, :enoent} ->
        case File.stat(path, time: :posix) do
          {:ok, stat} -> Keyword.get(opts, :now, System.os_time(:second)) - stat.mtime >= 120
          _ -> false
        end

      _ ->
        false
    end
  end

  defp dead_owner?(path, pid, role, opts) do
    abandoned_local = pid == System.pid() and role == "cli" and not Process.get({__MODULE__, path}, false)
    Regex.match?(~r/\A[1-9][0-9]*\z/, pid) and (abandoned_local or not Keyword.get(opts, :alive?, &alive?/1).(pid))
  end

  defp alive?(pid) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} -> true
      # EPERM is also a live process; conservatively retain ambiguous ownership.
      {output, _} -> not String.contains?(String.downcase(output), "no such process")
    end
  end

  defp owned?(%{path: path, owner: owner, inode: inode}) do
    File.read(Path.join(path, "owner")) == {:ok, owner} and match?({:ok, %{inode: ^inode}}, File.stat(path))
  end

  defp release(handle) do
    if owned?(handle), do: retire(handle.path), else: {:error, :lock_lost}
  end

  defp retire(path) do
    retired = path <> ".retired." <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    with :ok <- File.rename(path, retired) do
      File.rm(Path.join(retired, "owner"))
      File.rmdir(retired)
    end
  end
end
