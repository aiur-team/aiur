defmodule Aiur.Machine.StoreRecords do
  @moduledoc false
  alias Aiur.Machine.{Records, StoreLock}

  @spec put_device(map(), keyword()) :: term()
  def put_device(row, opts) do
    row = row |> Records.normalize() |> Map.put_new("token_hashes", []) |> Map.put_new("last_seen_at", nil) |> Map.put_new("push_registration", nil)

    if Records.valid?(:devices, row) do
      Records.change(:devices, opts, fn rows -> {:ok, prune_devices(Enum.reject(rows, &(&1["device_id"] == row["device_id"])) ++ [row], opts)} end)
    else
      {:error, :invalid_device}
    end
  end

  @spec delete_device(binary(), keyword()) :: term()
  def delete_device(id, opts) do
    Records.change(:devices, opts, fn rows -> {:ok, rows |> cascade([id]) |> prune_devices(opts)} end)
  end

  defp cascade(rows, ids) do
    {removed, kept} = Enum.split_with(rows, &(&1["device_id"] in ids or &1["parent_device_id"] in ids))
    if removed == [], do: kept, else: cascade(kept, Enum.map(removed, & &1["device_id"]))
  end

  @spec delete_all_devices(keyword()) :: term()
  def delete_all_devices(opts) do
    StoreLock.with_lock(
      fn ->
        with {:ok, _} <- Records.read(:devices),
             {:ok, _} <- Records.read(:pairing),
             :ok <- Records.write(:pairing, []) do
          Records.write(:devices, [])
        end
      end,
      opts
    )
  end

  @spec put_pairing_secret(binary(), integer(), keyword()) :: term()
  def put_pairing_secret(secret, expires_at, opts) when is_binary(secret) and is_integer(expires_at) do
    row = %{"hash" => digest(secret), "expires_at" => expires_at, "used" => false}

    Records.change(:pairing, opts, fn rows ->
      now = Records.now(opts)
      retained = rows |> Records.prune(now) |> Enum.reject(&(&1["used"] or &1["hash"] == row["hash"]))

      cond do
        expires_at <= now or expires_at > now + 600 -> {:error, :invalid_secret_expiry}
        Enum.any?(rows, &(&1["hash"] == row["hash"])) -> {:error, :pair_secret_exists}
        true -> {:ok, Enum.take(retained ++ [row], -3)}
      end
    end)
  end

  @spec consume_pairing_secret(binary(), integer(), keyword()) :: term()
  def consume_pairing_secret(secret, now, opts) do
    Records.change(:pairing, opts, fn rows ->
      hash = digest(secret)

      case Enum.find(rows, &:crypto.hash_equals(&1["hash"], hash)) do
        nil -> {:error, :pair_secret_unknown}
        %{"used" => true} -> {:error, :pair_secret_used}
        %{"expires_at" => expiry} when expiry <= now -> {:error, :pair_secret_expired}
        row -> {:ok, Enum.map(rows, &if(&1 == row, do: Map.put(&1, "used", true), else: &1))}
      end
    end)
  end

  @spec add_token_hash(binary(), binary(), integer(), keyword()) :: term()
  def add_token_hash(id, hash, expires_at, opts) do
    token = %{"hash" => hash, "expires_at" => expires_at}

    if Records.valid?(:tokens, token) do
      Records.change(:devices, opts, fn rows ->
        update_token(rows, id, token, opts)
      end)
    else
      {:error, :invalid_token_hash}
    end
  end

  defp update_token(rows, id, token, opts) do
    if Enum.any?(rows, &(&1["device_id"] == id)) do
      updated = Enum.map(rows, &add_token(&1, id, token))
      {:ok, prune_devices(updated, opts)}
    else
      {:error, :device_unknown}
    end
  end

  defp add_token(%{"device_id" => id} = row, id, token),
    do: Map.update!(row, "token_hashes", fn hashes -> Enum.reject(hashes, &(&1["hash"] == token["hash"])) ++ [token] end)

  defp add_token(row, _, _), do: row

  @spec prune_expired_tokens(integer(), keyword()) :: term()
  def prune_expired_tokens(now, opts), do: Records.change(:devices, opts, &{:ok, prune_devices(&1, Keyword.put(opts, :now, now))})

  @spec put_known_instances([map()], keyword()) :: term()
  def put_known_instances(rows, opts) do
    rows = Enum.map(rows, &Records.normalize/1)
    if Enum.all?(rows, &Records.valid?(:known_instances, &1)), do: Records.change(:known_instances, opts, fn _ -> {:ok, rows} end), else: {:error, :invalid_instances}
  end

  defp prune_devices(rows, opts),
    do: Enum.map(rows, &Map.update!(&1, "token_hashes", fn hashes -> hashes |> Records.prune(Records.now(opts)) |> Enum.take(-4) end))

  defp digest(secret), do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
end
