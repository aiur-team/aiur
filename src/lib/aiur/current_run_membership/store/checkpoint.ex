defmodule Aiur.CurrentRunMembership.Store.Checkpoint do
  @moduledoc false

  alias Aiur.CurrentRunMembership.{Event.Codec, Projection}

  @version 1
  @record_keys ~w(checksum generation members run_id version)

  @spec load(String.t(), String.t()) :: :missing | {:ok, Projection.t()} | {:corrupt, term()}
  def load(path, run_id) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :missing

      {:ok, %File.Stat{type: :regular, size: size}} ->
        load_regular_checkpoint(path, run_id, size)

      {:ok, %File.Stat{type: :symlink}} ->
        {:corrupt, :symlink_rejected}

      {:ok, _stat} ->
        {:corrupt, :not_a_regular_file}

      {:error, reason} ->
        {:corrupt, {:unreadable, reason}}
    end
  end

  defp load_regular_checkpoint(path, run_id, size) do
    if size <= Codec.max_checkpoint_bytes() do
      with {:ok, contents} <- File.read(path),
           {:ok, record} <- Jason.decode(contents),
           {:ok, projection} <- from_record(record, run_id) do
        {:ok, projection}
      else
        {:error, reason} -> {:corrupt, reason}
      end
    else
      {:corrupt, :record_too_large}
    end
  end

  @spec record(Projection.t()) :: map()
  def record(projection) do
    checkpoint = Projection.checkpoint(projection)
    checkpoint |> Map.put("version", @version) |> Map.put("checksum", checksum(checkpoint))
  end

  @spec from_record(term(), String.t()) :: {:ok, Projection.t()} | {:error, atom()}
  def from_record(record, run_id) when is_map(record) do
    with @record_keys <- record |> Map.keys() |> Enum.sort(),
         @version <- Map.get(record, "version"),
         ^run_id <- Map.get(record, "run_id"),
         generation when is_integer(generation) and generation >= 0 <- Map.get(record, "generation"),
         members when is_list(members) <- Map.get(record, "members"),
         checksum_value when is_binary(checksum_value) <- Map.get(record, "checksum"),
         true <- checksum_value == checksum(payload(record)),
         {:ok, projection} <- Projection.restore_checkpoint(run_id, generation, members) do
      {:ok, projection}
    else
      false -> {:error, :checksum_mismatch}
      _ -> {:error, :invalid_checkpoint}
    end
  end

  def from_record(_record, _run_id), do: {:error, :invalid_checkpoint}

  defp payload(record) do
    record |> Map.drop(["version", "checksum"]) |> Map.put("version", @version)
  end

  defp checksum(%{"run_id" => run_id, "generation" => generation, "members" => members}) do
    {@version, run_id, generation, members}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
