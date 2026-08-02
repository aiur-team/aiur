defmodule Aiur.GitHub.BlockerCache do
  @moduledoc false

  @table :aiur_github_blocker_cache
  @ttl_ms 30_000

  @spec fetch(String.t(), (-> {:ok, [map()]} | {:error, term()}), keyword()) ::
          {:ok, [map()]} | {:stale, [map()], term()} | {:error, term()}
  def fetch(issue_id, fetcher, opts \\ []) when is_binary(issue_id) and is_function(fetcher, 0) do
    now_ms = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))

    case lookup(issue_id, now_ms, Keyword.get(opts, :ttl_ms, @ttl_ms)) do
      {:fresh, blockers} ->
        {:ok, blockers}

      {:stale, blockers} ->
        refresh(issue_id, blockers, fetcher, now_ms)

      :missing ->
        refresh(issue_id, nil, fetcher, now_ms)
    end
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
