defmodule Aiur.GitHub.CycleFetchCache do
  @moduledoc false

  @table __MODULE__

  @spec start_cycle() :: :ok
  def start_cycle do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      table ->
        :ets.delete_all_objects(table)
    end

    :ok
  end

  @spec end_cycle() :: :ok
  def end_cycle do
    case :ets.whereis(@table) do
      :undefined -> :ok
      table -> :ets.delete(table)
    end

    :ok
  end

  @spec fetch(term(), (-> {:ok, term()} | {:not_modified, term()} | {:error, term()})) ::
          {:ok, term()} | {:not_modified, term()} | {:error, term()}
  def fetch(key, fetcher) when is_function(fetcher, 0) do
    case :ets.whereis(@table) do
      :undefined -> fetcher.()
      table -> fetch_cached(table, key, fetcher)
    end
  end

  defp fetch_cached(table, key, fetcher) do
    case :ets.lookup(table, key) do
      [{^key, result}] -> result
      [] -> :global.trans({__MODULE__, key}, fn -> fetch_and_store(table, key, fetcher) end)
    end
  end

  defp fetch_and_store(table, key, fetcher) do
    case :ets.lookup(table, key) do
      [{^key, result}] ->
        result

      [] ->
        result = fetcher.()

        if cacheable_result?(result) do
          true = :ets.insert(table, {key, result})
        end

        result
    end
  end

  defp cacheable_result?({:ok, _value}), do: true
  defp cacheable_result?({:not_modified, _etag}), do: true
  defp cacheable_result?(_result), do: false
end
