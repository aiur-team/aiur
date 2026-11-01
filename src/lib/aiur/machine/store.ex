defmodule Aiur.Machine.Store do
  @moduledoc """
  Boot identity, durable machine keys and atomic authorization records.
  No API exports the seed or signs arbitrary bytes. Purpose-tagged signing belongs
  to the pairing-token layer. Callers serialize initialization with the store lock.
  """

  alias Aiur.Machine.{Paths, Permissions, Records}

  @doc "Device rows use JSON string keys. Token/secret expiry times are Unix seconds."
  @spec devices() :: {:ok, [map()]} | {:error, term()}
  def devices, do: Records.read(:devices)

  @spec known_instances() :: {:ok, [map()]} | {:error, term()}
  def known_instances, do: Records.read(:known_instances)

  @spec put_device(term(), keyword()) :: term()
  defdelegate put_device(row, opts \\ []), to: Aiur.Machine.StoreRecords

  @spec delete_device(term(), keyword()) :: term()
  defdelegate delete_device(id, opts \\ []), to: Aiur.Machine.StoreRecords

  @spec delete_all_devices(keyword()) :: term()
  defdelegate delete_all_devices(opts \\ []), to: Aiur.Machine.StoreRecords

  @spec put_pairing_secret(term(), term(), keyword()) :: term()
  defdelegate put_pairing_secret(secret, expires_at, opts \\ []), to: Aiur.Machine.StoreRecords

  @spec consume_pairing_secret(term(), term(), keyword()) :: term()
  defdelegate consume_pairing_secret(secret, now, opts \\ []), to: Aiur.Machine.StoreRecords

  @spec add_token_hash(term(), term(), term(), keyword()) :: term()
  defdelegate add_token_hash(id, hash, expires_at, opts \\ []), to: Aiur.Machine.StoreRecords

  @spec prune_expired_tokens(term(), keyword()) :: term()
  defdelegate prune_expired_tokens(now, opts \\ []), to: Aiur.Machine.StoreRecords

  @spec put_known_instances(term(), keyword()) :: term()
  defdelegate put_known_instances(rows, opts \\ []), to: Aiur.Machine.StoreRecords

  @spec with_lock(function(), non_neg_integer() | keyword()) :: term()
  defdelegate with_lock(fun, timeout_or_opts \\ 5_000), to: Aiur.Machine.StoreLock

  @spec hold_lock(keyword()) :: term()
  defdelegate hold_lock(opts \\ []), to: Aiur.Machine.StoreLock

  @spec release_lock(map()) :: term()
  defdelegate release_lock(handle), to: Aiur.Machine.StoreLock

  @spec paths() :: map()
  def paths, do: Paths.paths()

  @spec identity() :: {:ok, map()} | {:error, :identity_unavailable, :missing | :corrupt | :bad_owner | :unreadable}
  def identity do
    paths = paths()

    with {:ok, uid} <- Permissions.uid(),
         :ok <- Permissions.inspect_path(paths.dir, uid, :directory),
         :ok <- Permissions.inspect_path(paths.identity, uid, :regular),
         {:ok, bytes} <- File.read(paths.identity),
         {:ok, value} <- Jason.decode(bytes),
         {:ok, identity} <- decode_identity(value) do
      {:ok, identity}
    else
      {:error, :enoent} -> {:error, :identity_unavailable, :missing}
      {:error, :bad_owner} -> {:error, :identity_unavailable, :bad_owner}
      {:error, %Jason.DecodeError{}} -> {:error, :identity_unavailable, :corrupt}
      {:error, :corrupt} -> {:error, :identity_unavailable, :corrupt}
      {:error, _reason} -> {:error, :identity_unavailable, :unreadable}
    end
  end

  defp decode_identity(%{"schema_version" => 1, "machine_id" => id, "machine_label" => label, "created_at" => created_at})
       when is_binary(id) and is_binary(label) and is_binary(created_at) do
    if Regex.match?(~r/\A[a-z2-7]{26}\z/, id),
      do: {:ok, %{machine_id: id, machine_label: label, created_at: created_at}},
      else: {:error, :corrupt}
  end

  defp decode_identity(_value), do: {:error, :corrupt}

  @spec check_dir(Path.t(), keyword()) :: :ok | {:error, term()}
  def check_dir(dir, opts \\ []) do
    with {:ok, uid} <- Permissions.uid(),
         :ok <- File.mkdir_p(dir),
         :ok <- Permissions.inspect_path(dir, uid, :directory, Keyword.get(opts, :stat_fun, &File.lstat/1)) do
      File.chmod(dir, 0o700)
    end
  end

  @spec init_machine_key() :: {:ok, binary()} | {:error, term()}
  def init_machine_key do
    paths = paths()

    with :ok <- check_dir(paths.dir),
         {:ok, uid} <- Permissions.uid(),
         :ok <- ensure_schema(paths.store, uid),
         {:ok, pub} <- ensure_key(paths, uid),
         :ok <- Aiur.Fs.sync_filesystem() do
      {:ok, pub}
    end
  end

  defp ensure_schema(path, uid) do
    case Permissions.read(path, uid) do
      {:error, :enoent} -> write(path, Jason.encode!(%{schema: 1}))
      {:ok, bytes} -> validate_schema(Jason.decode(bytes))
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_schema({:ok, %{"schema" => 1}}), do: :ok
  defp validate_schema({:ok, %{"schema" => n}}) when is_integer(n) and n > 1, do: {:error, :store_schema_unsupported}
  defp validate_schema(_value), do: {:error, :store_corrupt}

  defp ensure_key(paths, uid) do
    case Permissions.read(paths.machine_key, uid) do
      {:ok, <<seed::binary-size(32)>>} -> ensure_public(paths.machine_public_key, uid, seed)
      {:ok, _bytes} -> {:error, :machine_key_corrupt}
      {:error, :enoent} -> create_key(paths)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_key(paths) do
    case File.lstat(paths.machine_public_key) do
      {:error, :enoent} ->
        {pub, seed} = :crypto.generate_key(:eddsa, :ed25519)

        with :ok <- write(paths.machine_key, seed), :ok <- write(paths.machine_public_key, pub), do: {:ok, pub}

      {:ok, _stat} ->
        {:error, :machine_key_missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_public(path, uid, seed) do
    {pub, _seed} = :crypto.generate_key(:eddsa, :ed25519, seed)

    case Permissions.read(path, uid) do
      {:ok, ^pub} -> {:ok, pub}
      {:ok, _other} -> {:error, :machine_key_mismatch}
      {:error, :enoent} -> with :ok <- write(path, pub), do: {:ok, pub}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec machine_public_key() :: {:ok, binary()} | {:error, term()}
  def machine_public_key do
    paths = paths()

    with {:ok, uid} <- Permissions.uid(),
         :ok <- Permissions.inspect_path(paths.dir, uid, :directory),
         {:ok, <<seed::binary-size(32)>>} <- Permissions.read(paths.machine_key, uid),
         {:ok, pub} <- Permissions.read(paths.machine_public_key, uid) do
      {expected, _seed} = :crypto.generate_key(:eddsa, :ed25519, seed)
      if pub == expected, do: {:ok, pub}, else: {:error, :machine_key_mismatch}
    else
      {:ok, _bytes} -> {:error, :machine_key_corrupt}
      {:error, :enoent} -> {:error, :machine_key_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec verify(binary(), binary()) :: boolean()
  def verify(bytes, signature) when is_binary(bytes) and is_binary(signature) and byte_size(signature) == 64 do
    case machine_public_key() do
      {:ok, pub} -> :crypto.verify(:eddsa, :none, bytes, signature, [pub, :ed25519])
      {:error, _reason} -> false
    end
  end

  def verify(_bytes, _signature), do: false

  defp write(path, bytes), do: Aiur.Fs.atomic_write(path, bytes, fsync: true, mode: 0o600)
end
