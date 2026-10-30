defmodule Aiur.AlertFeed.StrictRead do
  @moduledoc false

  @spec read(Path.t(), keyword()) :: [map()]
  def read(path, _opts) do
    case File.read(path) do
      {:ok, bytes} ->
        bytes
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.map(fn record when is_map(record) -> record end)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read alert ledger", path: path
    end
  end
end
