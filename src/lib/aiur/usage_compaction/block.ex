defmodule Aiur.UsageCompaction.Block do
  @moduledoc false

  # A compacted block is a durable, dimension-preserving snapshot of the exact
  # DASH-024 aggregate contribution of one contiguous ledger position range
  # `[first_position, last_position]`. It is produced by folding exactly those
  # DASH-009 replay records through `Aiur.UsageAggregate.Projection` — the same
  # fold DASH-024 serves queries from — and serialized with the identical
  # `Aiur.UsageAggregate.Key` cell codec. So the block's cells are structurally
  # the contribution the live projection folded for that range, never a
  # re-derivation: every grouping dimension, exact total, and token-relationship
  # revision survives unchanged, and no two revisions ever share a cell.
  #
  # Blocks are the durable coverage that must exist before any raw segment is
  # retired, and the floor a rebuild seeds from once that raw is gone. They are
  # written same-filesystem via temp file, flush, and atomic rename, and carry a
  # checksum so a torn or tampered block is rejected rather than trusted.

  alias Aiur.Fs
  alias Aiur.UsageAggregate.{Key, Projection}

  @schema "usage_compaction_block"
  @version 1
  @record_keys ~w(cells checksum coverage covered first_position last_position schema source_generation version)
  @default_max_bytes 33_554_432
  @max_integer 18_446_744_073_709_551_615

  @type t :: %__MODULE__{
          first_position: pos_integer(),
          last_position: pos_integer(),
          source_generation: non_neg_integer(),
          cells: %{Key.cell() => Key.value()},
          coverage: map(),
          covered: map()
        }

  defstruct [:first_position, :last_position, :source_generation, :cells, :coverage, :covered]

  @doc """
  Builds a compacted block from an ordered, contiguous run of DASH-009 replay
  records. Returns `{:error, :empty_range}` for no records and
  `{:error, :non_contiguous_range}` if the folded positions do not form the
  gapless run `[first..last]` the caller promised — a block must never claim a
  range it did not fully cover.
  """
  @spec build([map()]) :: {:ok, t()} | {:error, atom()}
  def build([]), do: {:error, :empty_range}

  def build(records) when is_list(records) do
    positions = Enum.map(records, & &1.position)
    first = Enum.min(positions)
    last = Enum.max(positions)

    if contiguous?(positions, first, last) do
      projection = Projection.apply_records(Projection.new(), records)

      {:ok,
       %__MODULE__{
         first_position: first,
         last_position: last,
         source_generation: projection.source_generation,
         cells: projection.cells,
         coverage: coverage_map(projection.coverage),
         covered: covered_span(first, last, projection.cells)
       }}
    else
      {:error, :non_contiguous_range}
    end
  end

  @doc "Returns the decoded `{cell => value}` map for merging into a floor."
  @spec cells(t()) :: %{Key.cell() => Key.value()}
  def cells(%__MODULE__{cells: cells}), do: cells

  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = block) do
    payload = %{
      "schema" => @schema,
      "version" => @version,
      "first_position" => block.first_position,
      "last_position" => block.last_position,
      "source_generation" => block.source_generation,
      "covered" => encode_covered(block.covered),
      "coverage" => encode_coverage(block.coverage),
      "cells" => encode_cells(block.cells)
    }

    Map.put(payload, "checksum", checksum(payload))
  end

  @spec write(String.t(), t(), keyword()) :: :ok | {:error, atom()}
  def write(path, %__MODULE__{} = block, opts \\ []) when is_binary(path) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    contents = Jason.encode!(encode(block))

    if byte_size(contents) > max_bytes do
      {:error, :block_too_large}
    else
      case Fs.atomic_write(path, contents, fsync: true, mode: 0o600) do
        :ok -> :ok
        {:error, _reason} -> {:error, :block_write_failed}
      end
    end
  end

  @doc """
  Loads and validates a block file. Returns `:missing` for an absent or empty
  file, `{:ok, block}` for a structurally valid, checksum-verified block, or
  `{:corrupt, reason}` for anything else.
  """
  @spec load(String.t(), keyword()) :: :missing | {:ok, t()} | {:corrupt, atom()}
  def load(path, opts \\ []) when is_binary(path) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    case File.lstat(path) do
      {:error, :enoent} -> :missing
      {:ok, %File.Stat{type: :regular, size: 0}} -> :missing
      {:ok, %File.Stat{type: :regular, size: size}} when size <= max_bytes -> load_regular(path)
      {:ok, %File.Stat{type: :regular}} -> {:corrupt, :block_too_large}
      {:ok, %File.Stat{type: :symlink}} -> {:corrupt, :symlink_rejected}
      {:ok, _stat} -> {:corrupt, :not_a_regular_file}
      {:error, _reason} -> {:corrupt, :unreadable}
    end
  end

  defp load_regular(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents),
         {:ok, block} <- from_record(decoded) do
      {:ok, block}
    else
      {:error, reason} when is_atom(reason) -> {:corrupt, reason}
      _other -> {:corrupt, :invalid_block}
    end
  end

  @spec from_record(term()) :: {:ok, t()} | {:error, atom()}
  def from_record(record) when is_map(record) do
    with @record_keys <- record |> Map.keys() |> Enum.sort(),
         @schema <- Map.get(record, "schema"),
         @version <- Map.get(record, "version"),
         {:ok, first} <- positive(Map.get(record, "first_position")),
         {:ok, last} <- positive(Map.get(record, "last_position")),
         true <- last >= first,
         {:ok, source_generation} <- bounded(Map.get(record, "source_generation")),
         true <- Map.get(record, "checksum") == checksum(payload(record)),
         {:ok, covered} <- decode_covered(Map.get(record, "covered"), first, last),
         {:ok, coverage} <- decode_coverage(Map.get(record, "coverage")),
         {:ok, cells} <- decode_cells(Map.get(record, "cells")) do
      {:ok,
       %__MODULE__{
         first_position: first,
         last_position: last,
         source_generation: source_generation,
         cells: cells,
         coverage: coverage,
         covered: covered
       }}
    else
      false -> {:error, :invalid_block}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_block}
    end
  end

  def from_record(_record), do: {:error, :invalid_block}

  # --- range helpers ------------------------------------------------------

  defp contiguous?(positions, first, last) do
    length(positions) == last - first + 1 and Enum.sort(positions) == Enum.to_list(first..last)
  end

  defp covered_span(first, last, cells) do
    dates =
      cells
      |> Map.keys()
      |> Enum.map(fn {dims, _measure} -> dims.pricing_date end)
      |> Enum.reject(&is_nil/1)

    %{
      first_position: first,
      last_position: last,
      pricing_date_earliest: min_date(dates),
      pricing_date_latest: max_date(dates)
    }
  end

  defp min_date([]), do: nil
  defp min_date(dates), do: Enum.min_by(dates, &Date.to_erl/1)

  defp max_date([]), do: nil
  defp max_date(dates), do: Enum.max_by(dates, &Date.to_erl/1)

  defp coverage_map(coverage) do
    %{
      folded_records: coverage.folded_records,
      partial_records: coverage.partial_records,
      reasons: coverage.reasons
    }
  end

  # --- codec --------------------------------------------------------------

  defp encode_cells(cells) do
    cells
    |> Enum.map(&Key.encode_cell/1)
    |> Enum.sort_by(&:erlang.term_to_binary/1)
  end

  defp decode_cells(encoded) when is_list(encoded) do
    Enum.reduce_while(encoded, {:ok, %{}}, fn raw, {:ok, acc} ->
      case Key.decode_cell(raw) do
        {:ok, {cell, value}} -> {:cont, {:ok, Map.put(acc, cell, value)}}
        :error -> {:halt, {:error, :invalid_block}}
      end
    end)
  end

  defp decode_cells(_encoded), do: {:error, :invalid_block}

  defp encode_covered(covered) do
    %{
      "first_position" => covered.first_position,
      "last_position" => covered.last_position,
      "pricing_date_earliest" => encode_date(covered.pricing_date_earliest),
      "pricing_date_latest" => encode_date(covered.pricing_date_latest)
    }
  end

  defp decode_covered(%{"first_position" => first, "last_position" => last} = raw, expected_first, expected_last)
       when first == expected_first and last == expected_last do
    with {:ok, earliest} <- decode_date(Map.get(raw, "pricing_date_earliest")),
         {:ok, latest} <- decode_date(Map.get(raw, "pricing_date_latest")) do
      {:ok,
       %{
         first_position: first,
         last_position: last,
         pricing_date_earliest: earliest,
         pricing_date_latest: latest
       }}
    end
  end

  defp decode_covered(_raw, _first, _last), do: {:error, :invalid_block}

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

  defp decode_coverage(_coverage), do: {:error, :invalid_block}

  defp decode_reasons(reasons) do
    Enum.reduce_while(reasons, {:ok, MapSet.new()}, fn reason, {:ok, acc} ->
      case safe_reason(reason) do
        {:ok, atom} -> {:cont, {:ok, MapSet.put(acc, atom)}}
        :error -> {:halt, {:error, :invalid_block}}
      end
    end)
  end

  defp safe_reason(reason) when is_binary(reason) do
    {:ok, String.to_existing_atom(reason)}
  rescue
    ArgumentError -> :error
  end

  defp safe_reason(_reason), do: :error

  defp encode_date(nil), do: nil
  defp encode_date(%Date{} = date), do: Date.to_iso8601(date)

  defp decode_date(nil), do: {:ok, nil}

  defp decode_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_block}
    end
  end

  defp decode_date(_value), do: {:error, :invalid_block}

  defp payload(record), do: Map.drop(record, ["checksum"])

  defp positive(value) when is_integer(value) and value > 0 and value <= @max_integer, do: {:ok, value}
  defp positive(_value), do: {:error, :invalid_block}

  defp bounded(value) when is_integer(value) and value >= 0 and value <= @max_integer, do: {:ok, value}
  defp bounded(_value), do: {:error, :invalid_block}

  defp checksum(payload) do
    payload
    |> Map.drop(["checksum"])
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
