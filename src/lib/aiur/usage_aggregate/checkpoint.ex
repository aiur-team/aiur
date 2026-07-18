defmodule Aiur.UsageAggregate.Checkpoint do
  @moduledoc false

  # Crash-safe aggregate checkpoint snapshot: schema, version, checksum, and the
  # source ledger position/generation the cells reproduce. Written same-filesystem
  # via temporary file, flush, and atomic rename so a reader sees either the prior
  # or the complete new snapshot. Recovery validates the checksum and structure
  # before trusting it; anything else is treated as corrupt and rebuilt from the
  # retained DASH-009 raw authority.

  alias Aiur.Fs
  alias Aiur.UsageAggregate.{Key, Projection}

  @version 1
  @record_keys ~w(cells checksum coverage generation schema source_generation source_position version)
  @default_max_bytes 33_554_432

  @spec encode(Projection.t()) :: map()
  def encode(%Projection{} = projection) do
    payload = %{
      "schema" => "usage_aggregate",
      "version" => @version,
      "source_position" => projection.source_position,
      "source_generation" => projection.source_generation,
      "generation" => projection.generation,
      "coverage" => encode_coverage(projection.coverage),
      "cells" => encode_cells(projection.cells)
    }

    Map.put(payload, "checksum", checksum(payload))
  end

  @spec write(String.t(), Projection.t(), keyword()) :: :ok | {:error, atom()}
  def write(path, %Projection{} = projection, opts \\ []) when is_binary(path) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    contents = Jason.encode!(encode(projection))

    if byte_size(contents) > max_bytes do
      {:error, :checkpoint_too_large}
    else
      atomic_write(path, contents)
    end
  end

  @doc """
  Loads and validates the latest checkpoint.

  Returns `:missing` for an absent or empty snapshot, `{:ok, projection}` for a
  structurally valid and checksum-verified snapshot, or `{:corrupt, reason}`.
  """
  @spec load(String.t(), keyword()) :: :missing | {:ok, Projection.t()} | {:corrupt, atom()}
  def load(path, opts \\ []) when is_binary(path) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    case File.lstat(path) do
      {:error, :enoent} -> :missing
      {:ok, %File.Stat{type: :regular, size: 0}} -> :missing
      {:ok, %File.Stat{type: :regular, size: size}} when size <= max_bytes -> load_regular(path)
      {:ok, %File.Stat{type: :regular}} -> {:corrupt, :checkpoint_too_large}
      {:ok, %File.Stat{type: :symlink}} -> {:corrupt, :symlink_rejected}
      {:ok, _stat} -> {:corrupt, :not_a_regular_file}
      {:error, _reason} -> {:corrupt, :unreadable}
    end
  end

  defp load_regular(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents),
         {:ok, projection} <- from_record(decoded) do
      {:ok, projection}
    else
      {:error, reason} when is_atom(reason) -> {:corrupt, reason}
      _other -> {:corrupt, :invalid_checkpoint}
    end
  end

  @spec from_record(term()) :: {:ok, Projection.t()} | {:error, atom()}
  def from_record(record) when is_map(record) do
    with @record_keys <- record |> Map.keys() |> Enum.sort(),
         "usage_aggregate" <- Map.get(record, "schema"),
         @version <- Map.get(record, "version"),
         {:ok, source_position} <- bounded(Map.get(record, "source_position")),
         {:ok, source_generation} <- bounded(Map.get(record, "source_generation")),
         {:ok, generation} <- bounded(Map.get(record, "generation")),
         true <- Map.get(record, "checksum") == checksum(payload(record)),
         {:ok, coverage} <- decode_coverage(Map.get(record, "coverage")),
         {:ok, cells} <- decode_cells(Map.get(record, "cells")) do
      {:ok,
       %Projection{
         cells: cells,
         source_position: source_position,
         source_generation: source_generation,
         generation: generation,
         coverage: coverage
       }}
    else
      false -> {:error, :checksum_mismatch}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_checkpoint}
    end
  end

  def from_record(_record), do: {:error, :invalid_checkpoint}

  defp encode_cells(cells) do
    cells
    |> Enum.map(&Key.encode_cell/1)
    |> Enum.sort_by(&:erlang.term_to_binary/1)
  end

  defp decode_cells(encoded) when is_list(encoded) do
    Enum.reduce_while(encoded, {:ok, %{}}, fn raw, {:ok, acc} ->
      case Key.decode_cell(raw) do
        {:ok, {cell, value}} -> {:cont, {:ok, Map.put(acc, cell, value)}}
        :error -> {:halt, {:error, :invalid_checkpoint}}
      end
    end)
  end

  defp decode_cells(_encoded), do: {:error, :invalid_checkpoint}

  defp encode_coverage(coverage) do
    %{
      "folded_records" => coverage.folded_records,
      "partial_records" => coverage.partial_records,
      "reasons" => coverage.reasons |> MapSet.to_list() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    }
  end

  defp decode_coverage(%{"folded_records" => folded, "partial_records" => partial, "reasons" => reasons})
       when is_list(reasons) do
    with {:ok, folded} <- bounded(folded),
         {:ok, partial} <- bounded(partial),
         {:ok, reasons} <- decode_reasons(reasons) do
      {:ok, %{folded_records: folded, partial_records: partial, reasons: reasons}}
    end
  end

  defp decode_coverage(_coverage), do: {:error, :invalid_checkpoint}

  defp decode_reasons(reasons) do
    Enum.reduce_while(reasons, {:ok, MapSet.new()}, fn reason, {:ok, acc} ->
      case safe_reason(reason) do
        {:ok, atom} -> {:cont, {:ok, MapSet.put(acc, atom)}}
        :error -> {:halt, {:error, :invalid_checkpoint}}
      end
    end)
  end

  defp safe_reason(reason) when is_binary(reason) do
    {:ok, String.to_existing_atom(reason)}
  rescue
    ArgumentError -> :error
  end

  defp safe_reason(_reason), do: :error

  defp atomic_write(path, contents) do
    case Fs.atomic_write(path, contents, fsync: true, mode: 0o600) do
      :ok -> :ok
      {:error, _reason} -> {:error, :checkpoint_write_failed}
    end
  end

  defp payload(record), do: Map.drop(record, ["checksum"])

  defp bounded(value) when is_integer(value) and value >= 0 and value <= 18_446_744_073_709_551_615, do: {:ok, value}
  defp bounded(_value), do: {:error, :invalid_checkpoint}

  defp checksum(payload) do
    payload
    |> Map.drop(["checksum"])
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
