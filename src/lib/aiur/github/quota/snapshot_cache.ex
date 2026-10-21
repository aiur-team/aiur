defmodule Aiur.GitHub.Quota.SnapshotCache do
  @moduledoc false

  @table __MODULE__

  @spec ensure_table() :: atom()
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :set, :public, read_concurrency: true, write_concurrency: true])
        rescue
          ArgumentError -> @table
        end

      table ->
        table
    end
  end

  @spec put(pid(), map(), integer(), integer()) :: :ok
  def put(server, snapshot, cached_at_ms, observed_at_ms) do
    _table = ensure_table()
    true = :ets.insert(@table, {server, snapshot, cached_at_ms, observed_at_ms})
    :ok
  rescue
    ArgumentError ->
      ensure_table()
      true = :ets.insert(@table, {server, snapshot, cached_at_ms, observed_at_ms})
      :ok
  end

  @spec get(pid(), non_neg_integer(), integer()) :: {:ok, map(), non_neg_integer(), integer()} | :miss
  def get(server, max_age_ms, now_ms) do
    case :ets.lookup(@table, server) do
      [{^server, snapshot, cached_at_ms, observed_at_ms}] ->
        age_ms = max(now_ms - cached_at_ms, 0)
        if age_ms <= max_age_ms, do: {:ok, snapshot, age_ms, observed_at_ms}, else: :miss

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @spec delete(pid()) :: :ok
  def delete(server) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, server)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
