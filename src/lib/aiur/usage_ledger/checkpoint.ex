defmodule Aiur.UsageLedger.Checkpoint do
  @moduledoc false

  alias Aiur.{Fs, UsageLedger.CounterPolicy}

  @version 1
  @record_keys ~w(checksum generation policy position version)
  @default_max_bytes 1_048_576

  @spec record(non_neg_integer(), non_neg_integer(), CounterPolicy.state()) :: map()
  def record(position, generation, %CounterPolicy{} = policy)
      when is_integer(position) and position >= 0 and is_integer(generation) and generation >= 0 do
    payload = %{
      "version" => @version,
      "position" => position,
      "generation" => generation,
      "policy" => CounterPolicy.dump(policy)
    }

    Map.put(payload, "checksum", checksum(payload))
  end

  @spec from_record(term()) :: {:ok, map()} | {:error, atom()}
  def from_record(record) when is_map(record) do
    with @record_keys <- record |> Map.keys() |> Enum.sort(),
         @version <- Map.get(record, "version"),
         position when is_integer(position) and position >= 0 <- Map.get(record, "position"),
         generation when is_integer(generation) and generation >= 0 <- Map.get(record, "generation"),
         policy when is_map(policy) <- Map.get(record, "policy"),
         checksum_value when is_binary(checksum_value) <- Map.get(record, "checksum"),
         true <- checksum_value == checksum(payload(record)),
         {:ok, decoded_policy} <- CounterPolicy.load(policy) do
      {:ok, %{position: position, generation: generation, policy: decoded_policy}}
    else
      false -> {:error, :checksum_mismatch}
      _ -> {:error, :invalid_ledger_checkpoint}
    end
  end

  def from_record(_record), do: {:error, :invalid_ledger_checkpoint}

  @spec load(String.t(), keyword()) :: :missing | {:ok, map()} | {:corrupt, atom()}
  def load(path, opts \\ []) when is_binary(path) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    case File.lstat(path) do
      {:error, :enoent} -> :missing
      {:ok, %File.Stat{type: :regular, size: size}} when size <= max_bytes -> load_regular(path)
      {:ok, %File.Stat{type: :regular}} -> {:corrupt, :record_too_large}
      {:ok, %File.Stat{type: :symlink}} -> {:corrupt, :symlink_rejected}
      {:ok, _stat} -> {:corrupt, :not_a_regular_file}
      {:error, _reason} -> {:corrupt, :unreadable}
    end
  end

  @spec write(String.t(), map(), keyword()) :: :ok | {:error, atom()}
  def write(path, checkpoint, opts \\ []) when is_binary(path) and is_map(checkpoint) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    with :ok <- writable_path(path),
         {:ok, contents} <- encode(checkpoint, max_bytes),
         :ok <- Fs.atomic_write(path, contents, fsync: true, mode: 0o600),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp load_regular(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents),
         {:ok, checkpoint} <- from_record(decoded) do
      {:ok, checkpoint}
    else
      {:error, reason} when is_atom(reason) -> {:corrupt, reason}
      _ -> {:corrupt, :invalid_ledger_checkpoint}
    end
  end

  defp writable_path(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, :not_a_regular_file}
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  defp encode(checkpoint, max_bytes) do
    contents = Jason.encode!(checkpoint)
    if byte_size(contents) <= max_bytes, do: {:ok, contents}, else: {:error, :record_too_large}
  end

  defp payload(record), do: record |> Map.drop(["checksum"]) |> Map.put("version", @version)

  defp checksum(payload) do
    payload
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
