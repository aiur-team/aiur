defmodule Aiur.GitHub.BlockerCache do
  @moduledoc false

  @table :aiur_github_blocker_cache
  @ttl_ms 300_000

  @spec fetch(String.t(), (-> {:ok, [map()]} | {:error, term()}), keyword()) ::
          {:ok, [map()]} | {:stale, [map()], term()} | {:error, term()}
  def fetch(issue_id, fetcher, opts \\ []) when is_binary(issue_id) and is_function(fetcher, 0) do
    now_ms = now_ms(opts)

    case cached(issue_id, opts) do
      {:fresh, blockers} ->
        {:ok, blockers}

      {:stale, blockers} ->
        refresh(issue_id, blockers, fetcher, now_ms)

      :missing ->
        refresh(issue_id, nil, fetcher, now_ms)
    end
  end

  @doc false
  @spec cached(String.t(), keyword()) :: {:fresh | :stale, [map()]} | :missing
  def cached(issue_id, opts \\ []) when is_binary(issue_id) do
    lookup(issue_id, now_ms(opts), Keyword.get(opts, :ttl_ms, @ttl_ms))
  end

  @doc false
  @spec clear() :: :ok
  def clear do
    case :ets.whereis(@table) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end

    :ok
  end

  @doc false
  @spec scheduled_refreshes([String.t()], non_neg_integer()) :: MapSet.t()
  def scheduled_refreshes(issue_ids, limit) when is_list(issue_ids) and is_integer(limit) and limit >= 0 do
    candidates = Enum.uniq(issue_ids)

    case candidates do
      [] ->
        MapSet.new()

      _ ->
        table = ensure_table()
        cursor = cursor(table, length(candidates))
        rotated = Enum.drop(candidates, cursor) ++ Enum.take(candidates, cursor)
        selected = Enum.take(rotated, limit)
        :ets.insert(table, {:refresh_cursor, rem(cursor + length(selected), length(candidates))})
        MapSet.new(selected)
    end
  end

  @doc false
  @spec put(String.t(), [map()], keyword()) :: :ok
  def put(issue_id, blockers, opts \\ []) when is_binary(issue_id) and is_list(blockers) do
    :ets.insert(ensure_table(), {{:blockers, issue_id}, now_ms(opts), blockers})
    :ok
  end

  @doc false
  @spec invalidate_blocker(String.t()) :: :ok
  def invalidate_blocker(blocker_id) when is_binary(blocker_id) do
    ensure_table()
    |> :ets.tab2list()
    |> Enum.each(fn
      {{:blockers, issue_id}, _fetched_ms, blockers} when is_list(blockers) ->
        if Enum.any?(blockers, &(blocker_identifier(&1) == blocker_id)) do
          :ets.delete(@table, {:blockers, issue_id})
        end

      _entry ->
        :ok
    end)

    :ok
  end

  defp refresh(issue_id, stale, fetcher, now_ms) do
    case fetcher.() do
      {:ok, blockers} when is_list(blockers) ->
        :ets.insert(ensure_table(), {{:blockers, issue_id}, now_ms, blockers})
        {:ok, blockers}

      {:error, reason} when is_list(stale) ->
        {:stale, stale, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lookup(issue_id, now_ms, ttl_ms) do
    case :ets.lookup(ensure_table(), {:blockers, issue_id}) do
      [{{:blockers, ^issue_id}, fetched_ms, blockers}] when now_ms - fetched_ms < ttl_ms -> {:fresh, blockers}
      [{{:blockers, ^issue_id}, _fetched_ms, blockers}] -> {:stale, blockers}
      [] -> :missing
    end
  end

  defp now_ms(opts), do: Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))

  defp cursor(table, count) do
    case :ets.lookup(table, :refresh_cursor) do
      [{:refresh_cursor, cursor}] when is_integer(cursor) and cursor >= 0 -> rem(cursor, count)
      _ -> 0
    end
  end

  defp blocker_identifier(%{"number" => number}), do: to_string(number)
  defp blocker_identifier(%{number: number}), do: to_string(number)
  defp blocker_identifier(_blocker), do: nil

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> @table
        end

      table ->
        table
    end
  end
end
