defmodule Aiur.AlertFeed.StrictRead do
  @moduledoc false

  alias Aiur.AlertLedger

  @spec read(Path.t(), keyword()) :: [map()]
  def read(path, opts) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> read_error!(path, :eisdir)
      {:ok, _stat} -> read_file(path, opts)
      {:error, :enoent} -> []
      {:error, reason} -> read_error!(path, reason)
    end
  end

  defp read_file(path, opts) do
    case File.open(path, [:read, :binary], fn _device -> AlertLedger.read(path, opts) end) do
      {:ok, records} -> records
      {:error, :enoent} -> []
      {:error, reason} -> read_error!(path, reason)
    end
  end

  defp read_error!(path, reason), do: raise(File.Error, reason: reason, action: "read alert ledger", path: path)
end
