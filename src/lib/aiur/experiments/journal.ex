defmodule Aiur.Experiments.Journal do
  @moduledoc false

  alias Aiur.Experiments.Schema

  @spec read(Path.t()) :: {:ok, [map()]} | {:error, term()}
  def read(path), do: replay(path, false)

  @spec writable(Path.t()) :: :ok | {:error, term()}
  def writable(path) do
    with {:ok, rows} <- read(path) do
      Enum.reduce_while(rows, :ok, &check_version/2)
    end
  end

  defp check_version(row, :ok) do
    case Schema.migrate(row) do
      {:ok, _row} -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  @spec append(Path.t(), map()) :: :ok | {:error, term()}
  def append(path, entry) do
    append_many(path, [entry])
  end

  @spec append_many(Path.t(), [map()]) :: :ok | {:error, term()}
  def append_many(path, entries) do
    with {:ok, rows} <- replay(path, true),
         :ok <- Enum.reduce_while(rows, :ok, &check_version/2) do
      Aiur.Journal.append_many(path, entries)
    end
  end

  defp replay(path, repair?) do
    case Aiur.Journal.replay(path, &decode/1, repair_torn_tail: repair?) do
      {:ok, rows, nil} -> {:ok, rows}
      {:ok, _rows, corruption} -> {:error, corruption}
      error -> error
    end
  end

  defp decode(row) when is_map(row) do
    case Schema.migrate(row) do
      {:ok, migrated} -> {:ok, migrated}
      {:error, {:newer_version, _version}} -> {:ok, row}
      error -> error
    end
  end

  defp decode(_row), do: {:error, :invalid_record}
end
