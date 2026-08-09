defmodule Aiur.AlertLedger do
  @moduledoc false

  alias Aiur.Config.Paths

  @ledger_suffix ".alerts.ndjson"
  @backfill_suffix ".alerts.backfill"
  @append_lock_timeout 1_000
  @backfill_lock_timeout 60_000

  @spec append(map(), keyword()) :: :ok | {:error, term()}
  def append(alert, opts \\ []) when is_map(alert) do
    with_lock(opts, fn ->
      path = path(opts)
      encoded = alert |> Map.put_new("event", "alert") |> Jason.encode!()

      case File.mkdir_p(Path.dirname(path)) do
        :ok -> File.write(path, encoded <> "\n", [:append])
        {:error, _reason} = error -> error
      end
    end)
  rescue
    error -> {:error, error}
  end

  @spec path(keyword()) :: Path.t()
  def path(opts \\ []) do
    case Keyword.get(opts, :ledger_path) do
      path when is_binary(path) and path != "" -> path
      _ -> Path.join(log_root(opts), Paths.project_name() <> @ledger_suffix)
    end
  end

  @spec paths(keyword()) :: [Path.t()]
  def paths(opts \\ []) do
    case Keyword.get(opts, :ledger_paths) do
      paths when is_list(paths) ->
        Enum.filter(paths, &is_binary/1)

      _ ->
        case Keyword.get(opts, :ledger_path) do
          path when is_binary(path) and path != "" -> [path]
          _ -> Enum.map(log_roots(opts), &Path.join(&1, Paths.project_name() <> @ledger_suffix))
        end
    end
  end

  @spec backfilled?(keyword()) :: boolean()
  def backfilled?(opts \\ []), do: File.regular?(backfill_marker(opts))

  @spec mark_backfilled(keyword()) :: :ok | {:error, term()}
  def mark_backfilled(opts \\ []) do
    marker = backfill_marker(opts)

    with :ok <- File.mkdir_p(Path.dirname(marker)),
         :ok <- File.write(marker, "complete\n") do
      :ok
    else
      {:error, _reason} = error -> error
    end
  rescue
    error -> {:error, error}
  end

  @spec with_lock(keyword(), (-> term())) :: term()
  def with_lock(opts, fun) when is_list(opts) and is_function(fun, 0) do
    with_named_lock({:append, Path.expand(path(opts))}, Keyword.get(opts, :lock_timeout, @append_lock_timeout), fun)
  end

  @spec with_backfill_lock(keyword(), (-> term())) :: term()
  def with_backfill_lock(opts, fun) when is_list(opts) and is_function(fun, 0) do
    with_external_lock({:backfill, Path.expand(path(opts))}, Keyword.get(opts, :backfill_lock_timeout, @backfill_lock_timeout), fun)
  end

  defp with_named_lock(name, timeout, fun) when is_integer(timeout) and timeout >= 0 do
    lock_key = {__MODULE__, :lock_depth, name}

    case Process.get(lock_key) do
      nil ->
        case acquire_lock(name, timeout) do
          :ok ->
            Process.put(lock_key, 1)

            try do
              fun.()
            after
              Process.delete(lock_key)
              :ok = :global.unregister_name(name)
            end

          {:error, :lock_timeout} = error ->
            error
        end

      depth ->
        Process.put(lock_key, depth + 1)

        try do
          fun.()
        after
          Process.put(lock_key, depth)
        end
    end
  end

  defp with_named_lock(_name, _timeout, _fun), do: {:error, :invalid_lock_timeout}

  defp with_external_lock(name, timeout, fun) when is_integer(timeout) and timeout >= 0 do
    parent = self()
    ref = make_ref()

    holder =
      spawn(fn ->
        parent_monitor = Process.monitor(parent)

        case acquire_lock(name, timeout) do
          :ok ->
            send(parent, {:external_lock_acquired, ref, self()})

            receive do
              {:release_external_lock, ^ref} -> :ok
              {:DOWN, ^parent_monitor, :process, ^parent, _reason} -> :ok
            end

            :ok = :global.unregister_name(name)
            send(parent, {:external_lock_released, ref})

          {:error, :lock_timeout} = error ->
            send(parent, {:external_lock_failed, ref, error})
        end
      end)

    receive do
      {:external_lock_acquired, ^ref, ^holder} ->
        try do
          fun.()
        after
          send(holder, {:release_external_lock, ref})

          receive do
            {:external_lock_released, ^ref} -> :ok
          end
        end

      {:external_lock_failed, ^ref, error} ->
        error
    after
      timeout + 50 ->
        Process.exit(holder, :kill)
        {:error, :lock_timeout}
    end
  end

  defp with_external_lock(_name, _timeout, _fun), do: {:error, :invalid_lock_timeout}

  defp backfill_marker(opts), do: path(opts) <> @backfill_suffix

  defp acquire_lock(name, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_acquire_lock(name, deadline)
  end

  defp do_acquire_lock(name, deadline) do
    case :global.register_name(name, self()) do
      :yes ->
        :ok

      :no ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 do
          Process.sleep(min(10, remaining))
          do_acquire_lock(name, deadline)
        else
          {:error, :lock_timeout}
        end
    end
  end

  defp log_root(opts), do: List.first(log_roots(opts)) || Paths.log_root_dir()

  defp log_roots(opts) do
    case Keyword.get(opts, :log_roots) do
      roots when is_list(roots) -> roots
      _ -> [Paths.log_root_dir()]
    end
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end
end
