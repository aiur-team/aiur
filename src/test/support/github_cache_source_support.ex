defmodule Aiur.GithubCacheSourceSupport do
  @moduledoc """
  A cache source the tests can seed, standing in for `ResourceStore`.

  It also counts reads, which is what lets a test assert that filtering and
  sorting never touch the store: the count after typing a search must be the
  count before it.
  """

  @behaviour Aiur.GitHub.CacheInspector.Source

  @table __MODULE__.Table
  @counter __MODULE__.Counter

  @spec install([map()]) :: :ok
  def install(entries) do
    reset()
    :ets.insert(@table, {:entries, entries})
    Application.put_env(:aiur, :github_cache_inspector_source, __MODULE__)
    :ok
  end

  @spec uninstall() :: :ok
  def uninstall do
    Application.delete_env(:aiur, :github_cache_inspector_source)
    :ok
  end

  @spec reads() :: non_neg_integer()
  def reads do
    case :ets.lookup(@counter, :reads) do
      [{:reads, count}] -> count
      _none -> 0
    end
  end

  @impl true
  def available? do
    ensure_tables()
    :ets.lookup(@table, :entries) != []
  end

  @impl true
  def entries do
    ensure_tables()
    :ets.update_counter(@counter, :reads, 1, {:reads, 0})

    case :ets.lookup(@table, :entries) do
      [{:entries, entries}] -> entries
      _none -> []
    end
  end

  defp reset do
    ensure_tables()
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@counter)
  end

  defp ensure_tables do
    for table <- [@table, @counter] do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :public, :set])
      end
    end

    :ok
  rescue
    ArgumentError -> :ok
  end
end
