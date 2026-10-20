defmodule Aiur.TestSupport.SourceSnapshot do
  @moduledoc false

  @table __MODULE__

  def files(globs) do
    ensure_table()

    globs
    |> Enum.uniq()
    |> Enum.flat_map(&cached_glob/1)
  end

  defp cached_glob(glob), do: cached_glob(glob, 5)

  defp cached_glob(glob, retries) do
    case :ets.lookup(@table, glob) do
      [{^glob, files}] ->
        files

      [] ->
        files =
          glob
          |> Path.wildcard()
          |> Enum.map(fn path -> {path, File.read!(path)} end)

        store_or_retry(glob, files, retries)
    end
  end

  defp store_or_retry(glob, files, retries) do
    case :ets.insert_new(@table, {glob, files}) do
      true -> files
      false when retries > 0 -> cached_glob(glob, retries - 1)
      false -> files
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _table ->
        :ok
    end
  end
end
