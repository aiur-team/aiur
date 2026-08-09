defmodule Aiur.GitHub.CycleFetchCache do
  @moduledoc false

  @process_key {__MODULE__, :table}

  @spec start_cycle() :: :ok
  def start_cycle do
    case cycle_table() do
      nil ->
        table = :ets.new(__MODULE__, [:private, :set, read_concurrency: true])
        Process.put(@process_key, table)

      table ->
        :ets.delete_all_objects(table)
    end

    :ok
  end

  @spec end_cycle() :: :ok
  def end_cycle do
    case Process.delete(@process_key) do
      nil ->
        :ok

      table ->
        if :ets.info(table) != :undefined do
          :ets.delete(table)
        end
    end

    :ok
  end

  @type result ::
          {:ok, term()}
          | {:ok, term(), term()}
          | {:not_modified, term()}
          | {:error, term()}

  @spec fetch(term(), (-> result())) :: result()
  def fetch(key, fetcher) when is_function(fetcher, 0) do
    case cycle_table() do
      nil -> fetcher.()
      table -> fetch_cached(table, key, fetcher)
    end
  end

  defp fetch_cached(table, key, fetcher) do
    case :ets.lookup(table, key) do
      [{^key, result}] -> result
      [] -> fetch_and_store(table, key, fetcher)
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
  defp cacheable_result?({:ok, _value, _etag}), do: true
  defp cacheable_result?({:not_modified, _etag}), do: true
  defp cacheable_result?(_result), do: false

  defp cycle_table do
    case Process.get(@process_key) do
      nil -> nil
      table -> if :ets.info(table) == :undefined, do: nil, else: table
    end
  end
end
