defmodule Aiur.Machine.Records do
  @moduledoc false
  alias Aiur.Machine.{Permissions, Store, StoreLock}

  @spec read(atom()) :: {:ok, [map()]} | {:error, term()}
  def read(kind) do
    with {:ok, uid} <- Permissions.uid() do
      case Permissions.read(path(kind), uid) do
        {:error, :enoent} -> {:ok, []}
        {:ok, bytes} -> decode(kind, Jason.decode(bytes))
        error -> error
      end
    end
  end

  @spec change(atom(), keyword(), function()) :: term()
  def change(kind, opts, fun) do
    StoreLock.with_lock(
      fn ->
        with {:ok, rows} <- read(kind),
             {:ok, updated} <- fun.(rows),
             :ok <- journal(opts) do
          write(kind, updated)
        end
      end,
      opts
    )
  end

  @spec write(atom(), [map()]) :: :ok | {:error, term()}
  def write(kind, rows) do
    Aiur.Fs.atomic_write(path(kind), Jason.encode!(rows), fsync: true, mode: 0o600)
  end

  @spec normalize(map()) :: map()
  def normalize(row), do: row |> Jason.encode!() |> Jason.decode!()

  @spec now(keyword()) :: integer()
  def now(opts), do: Keyword.get(opts, :now, System.os_time(:second))

  @spec prune([map()], integer()) :: [map()]
  def prune(rows, now), do: Enum.filter(rows, &(&1["expires_at"] > now))

  @spec valid?(atom(), term()) :: boolean()
  def valid?(:devices, row) when is_map(row) do
    Enum.all?(~w(device_id label platform auth_public_key paired_at), &is_binary(row[&1])) and
      (is_nil(row["parent_device_id"]) or is_binary(row["parent_device_id"])) and
      is_list(row["token_hashes"]) and Enum.all?(row["token_hashes"], &valid?(:tokens, &1))
  end

  def valid?(:pairing, %{"hash" => hash, "expires_at" => expiry, "used" => used}), do: hash?(hash) and is_integer(expiry) and is_boolean(used)
  def valid?(:tokens, %{"hash" => hash, "expires_at" => expiry}), do: hash?(hash) and is_integer(expiry)

  def valid?(:known_instances, row) when is_map(row),
    do: Enum.all?(~w(instance_id repository project_root_basename), &is_binary(row[&1])) and is_integer(row["last_seen_at"])

  def valid?(_, _), do: false

  defp hash?(hash), do: is_binary(hash) and Regex.match?(~r/\A[0-9a-f]{64}\z/, hash)

  defp decode(kind, {:ok, rows}) when is_list(rows) do
    ids = if kind == :devices, do: Enum.map(rows, &if(is_map(&1), do: &1["device_id"])), else: []
    if Enum.all?(rows, &valid?(kind, &1)) and Enum.uniq(ids) == ids, do: {:ok, rows}, else: {:error, :store_corrupt}
  end

  defp decode(_, _), do: {:error, :store_corrupt}
  defp path(kind), do: Map.fetch!(Store.paths(), kind)

  defp journal(opts) do
    case Keyword.get(opts, :journal) do
      nil -> :ok
      callback -> callback.()
    end
  end
end
