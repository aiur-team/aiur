defmodule Aiur.UsageLedger.RetiredFloor do
  @moduledoc false

  # The durable watermark of the highest raw ledger position that has been
  # retired after its dimension-preserving aggregate coverage was committed by
  # DASH-025 compaction. Recovery treats this floor as authoritative: any raw
  # record at or below it is ignored (and may be reclaimed), so the floor can be
  # persisted before the segment is rewritten and a crash in between is safe —
  # the extra un-reclaimed raw is simply dropped on the next boot.
  #
  # A missing floor means nothing has ever been retired (floor 0). A corrupt
  # floor is fatal for a retired ledger — the retained tail alone cannot rebuild
  # the retired prefix — so the caller halts rather than guessing.

  alias Aiur.Fs

  @version 1
  @record_keys ~w(checksum retired_through version)
  @max_integer 18_446_744_073_709_551_615

  @spec write(String.t(), non_neg_integer(), (-> :ok | {:error, term()})) :: :ok | {:error, atom()}
  def write(path, retired_through, sync_fun)
      when is_binary(path) and is_integer(retired_through) and retired_through >= 0 and is_function(sync_fun, 0) do
    payload = %{"version" => @version, "retired_through" => retired_through}
    contents = Jason.encode!(Map.put(payload, "checksum", checksum(payload)))

    with :ok <- atomic_write(path, contents),
         :ok <- sync_fun.() do
      :ok
    else
      {:error, _reason} -> {:error, :retired_floor_write_failed}
    end
  end

  @spec load(String.t()) :: {:ok, non_neg_integer()} | :missing | {:corrupt, atom()}
  def load(path) when is_binary(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :missing
      {:ok, %File.Stat{type: :regular, size: 0}} -> :missing
      {:ok, %File.Stat{type: :regular, size: size}} when size <= 1_024 -> load_regular(path)
      {:ok, %File.Stat{type: :regular}} -> {:corrupt, :retired_floor_too_large}
      {:ok, %File.Stat{type: :symlink}} -> {:corrupt, :symlink_rejected}
      {:ok, _stat} -> {:corrupt, :not_a_regular_file}
      {:error, _reason} -> {:corrupt, :unreadable}
    end
  end

  defp load_regular(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents),
         {:ok, retired_through} <- from_record(decoded) do
      {:ok, retired_through}
    else
      _ -> {:corrupt, :invalid_retired_floor}
    end
  end

  defp from_record(record) when is_map(record) do
    with @record_keys <- record |> Map.keys() |> Enum.sort(),
         @version <- Map.get(record, "version"),
         value when is_integer(value) and value >= 0 and value <= @max_integer <- Map.get(record, "retired_through"),
         true <- Map.get(record, "checksum") == checksum(payload(record)) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  defp from_record(_record), do: :error

  defp payload(record), do: Map.drop(record, ["checksum"])

  defp atomic_write(path, contents), do: Fs.atomic_write(path, contents, fsync: true, mode: 0o600)

  defp checksum(payload) do
    payload
    |> Map.drop(["checksum"])
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
