defmodule Aiur.AlertLedger do
  @moduledoc false

  require Logger

  alias Aiur.{AlertTopic, Fs, Jsonl}
  alias Aiur.AlertLedger.Tail
  alias Aiur.Config.Paths

  @ledger_suffix ".alerts.ndjson"
  @backfill_suffix ".alerts.backfill"
  @append_lock_timeout 1_000
  @backfill_lock_timeout 60_000
  @max_bytes 8 * 1_024 * 1_024

  @spec append(map(), keyword()) :: :ok | {:error, term()}
  def append(alert, opts \\ []) when is_map(alert) do
    appended = alert |> Map.put_new("event", "alert") |> entry(:appended)
    max_bytes = max_bytes(opts)

    if appended.size > max_bytes do
      {:error, {:record_too_large, appended.size, max_bytes}}
    else
      with_lock(opts, fn -> append_locked(path(opts), appended, max_bytes) end)
    end
  rescue
    error -> {:error, error}
  end

  @doc false
  @spec compact(keyword()) :: :ok | {:error, term()}
  def compact(opts \\ []) do
    path = path(opts)
    max_bytes = max_bytes(opts)

    case File.stat(path) do
      {:ok, %{size: size}} when size > max_bytes -> with_lock(opts, fn -> compact_if_needed(path, max_bytes) end)
      {:ok, _stat} -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  rescue
    error -> {:error, error}
  end

  @doc false
  @spec read(Path.t(), keyword()) :: [map()]
  def read(path, opts \\ []) when is_binary(path) do
    Tail.read(path, max_bytes(opts))
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

  defp append_locked(path, appended, max_bytes) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      case File.stat(path) do
        {:ok, %{size: size}} when size + appended.size <= max_bytes ->
          File.write(path, appended.line, [:append])

        {:ok, _stat} ->
          compact_file(path, appended, max_bytes)

        {:error, :enoent} ->
          File.write(path, appended.line)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp compact_if_needed(path, max_bytes) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > max_bytes -> compact_file(path, nil, max_bytes)
      {:ok, _stat} -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp compact_file(path, appended, max_bytes) do
    with {:ok, entries} <- read_entries(path) do
      entries = if appended, do: entries ++ [appended], else: entries
      {retained, dropped_active_count} = retained_entries(entries, max_bytes)

      if dropped_active_count > 0 do
        Logger.warning("alert_ledger compaction dropped_active_count=#{dropped_active_count} path=#{path} max_bytes=#{max_bytes}")
      end

      retained
      |> Enum.map(& &1.line)
      |> then(&Fs.atomic_write(path, &1, fsync: true, mode: 0o600))
    end
  end

  defp read_entries(path) do
    entries =
      path
      |> File.stream!([], :line)
      |> Stream.with_index()
      |> Enum.flat_map(fn {line, index} ->
        case Jsonl.decode_line(line) do
          {:ok, record} -> [entry(record, index, line)]
          :skip -> []
        end
      end)

    {:ok, entries}
  rescue
    error -> {:error, error}
  end

  defp entry(record, index), do: entry(record, index, [Jason.encode!(record), "\n"])

  defp entry(record, index, line) do
    line = ensure_newline(line)
    %{index: index, record: record, line: line, size: IO.iodata_length(line)}
  end

  defp ensure_newline(line) when is_binary(line) do
    if String.ends_with?(line, "\n"), do: line, else: [line, "\n"]
  end

  defp ensure_newline(line), do: line

  defp retained_entries([], _max_bytes), do: {[], 0}

  defp retained_entries(entries, max_bytes) do
    newest = List.last(entries)
    active = active_entries(entries)
    selection = select_entry({[], 0, MapSet.new()}, newest, max_bytes)
    {selection, dropped_active_count} = select_active(active, selection, max_bytes)

    selection =
      if dropped_active_count == 0 do
        select_history(Enum.reverse(entries), selection, max_bytes)
      else
        selection
      end

    {selected, _used_bytes, _selected_indexes} = selection
    {Enum.sort_by(selected, &entry_order/1), dropped_active_count}
  end

  defp active_entries(entries) do
    entries
    |> Enum.reduce(%{}, fn entry, active ->
      case {attention_key(entry.record), AlertTopic.resolved_attention_key(entry.record)} do
        {key, _resolution} when not is_nil(key) -> Map.put(active, key, entry)
        {_key, resolution} when not is_nil(resolution) -> Map.delete(active, resolution)
        _ -> active
      end
    end)
    |> Map.values()
    |> Enum.sort_by(&entry_order/1, :desc)
  end

  defp select_active(active, selection, max_bytes) do
    candidates = Enum.reject(active, &selected?(&1, selection))
    do_select_active(candidates, selection, max_bytes)
  end

  defp do_select_active([], selection, _max_bytes), do: {selection, 0}

  defp do_select_active([entry | rest], selection, max_bytes) do
    case select_entry(selection, entry, max_bytes) do
      ^selection ->
        {updated, dropped_count} = do_select_active(rest, selection, max_bytes)
        {updated, dropped_count + 1}

      updated ->
        do_select_active(rest, updated, max_bytes)
    end
  end

  defp select_history(entries, selection, max_bytes) do
    entries
    |> Enum.reject(&selected?(&1, selection))
    |> Enum.reduce_while(selection, fn entry, selected ->
      case select_entry(selected, entry, max_bytes) do
        ^selected -> {:halt, selected}
        updated -> {:cont, updated}
      end
    end)
  end

  defp select_entry({selected, used_bytes, selected_indexes} = selection, entry, max_bytes) do
    if used_bytes + entry.size <= max_bytes do
      {[entry | selected], used_bytes + entry.size, MapSet.put(selected_indexes, entry.index)}
    else
      selection
    end
  end

  defp selected?(entry, {_selected, _used_bytes, selected_indexes}), do: MapSet.member?(selected_indexes, entry.index)
  defp entry_order(%{index: :appended}), do: :infinity
  defp entry_order(%{index: index}), do: index

  defp attention_key(%{"needs_attention" => true} = record), do: AlertTopic.attention_key(record)
  defp attention_key(_record), do: nil

  defp max_bytes(opts) do
    case Keyword.get(opts, :max_bytes, @max_bytes) do
      value when is_integer(value) and value > 0 -> value
      _ -> @max_bytes
    end
  end

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
