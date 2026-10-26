defmodule Aiur.UsageLedger.RetiredKeys do
  @moduledoc false

  alias Aiur.Fs

  @version 1

  @spec write(String.t(), MapSet.t(String.t())) :: :ok | {:error, term()}
  def write(path, keys) when is_binary(path) and is_struct(keys, MapSet) do
    payload = %{"version" => @version, "keys" => keys |> MapSet.to_list() |> Enum.sort()}
    encoded = Map.put(payload, "checksum", checksum(payload)) |> Jason.encode!()
    Fs.atomic_write(path, encoded, fsync: true, mode: 0o600)
  end

  @spec load(String.t()) :: {:ok, MapSet.t(String.t())} | {:error, atom()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> decode(contents)
      {:error, :enoent} -> {:ok, MapSet.new()}
      {:error, _reason} -> {:error, :retired_idempotency_unavailable}
    end
  end

  defp decode(contents) do
    with {:ok, %{"version" => @version, "keys" => keys, "checksum" => supplied}} <- Jason.decode(contents),
         true <- is_list(keys) and Enum.all?(keys, &is_binary/1),
         true <- Enum.uniq(keys) == keys,
         payload = %{"version" => @version, "keys" => keys},
         true <- checksum(payload) == supplied do
      {:ok, MapSet.new(keys)}
    else
      _ -> {:error, :retired_idempotency_corrupt}
    end
  end

  defp checksum(payload) do
    payload
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
