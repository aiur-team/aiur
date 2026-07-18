defmodule Aiur.UsageCompaction.Manifest do
  @moduledoc false

  # Versioned, checksummed state machine for the one destructive storage seam.
  # It records the raw watermark durably retired, the finalized compacted blocks
  # that cover everything up to it, and at most one in-flight destructive phase.
  #
  # The phase ordering is the crash-recovery contract:
  #
  #     prepared -> aggregate_committed -> source_retired -> (finalized)
  #
  #   * `prepared`            intent declared; the block may not be durable and
  #                           no raw has been deleted.
  #   * `aggregate_committed` the compacted block is durable and validated; raw
  #                           is still fully present.
  #   * `source_retired`      the manifest has committed to deleting the raw for
  #                           this range; the deletion is about to run or is
  #                           running. This is the point of no return.
  #
  # A restart interrupted at `prepared` or `aggregate_committed` rolls back (raw
  # is intact, so abandoning the in-flight range loses nothing — the live
  # aggregate is cumulative). A restart at `source_retired` rolls forward: the
  # raw is gone or going, so only re-running the idempotent retirement and
  # finalizing yields a valid state. Every transition is persisted same-
  # filesystem via temp file, flush, and atomic rename before the next
  # side effect, so recovery always sees a whole prior-or-next manifest.

  alias Aiur.Fs

  @schema "usage_compaction_manifest"
  @version 1
  @record_keys ~w(blocks checksum pending policy retired_through schema version)
  @default_max_bytes 8_388_608
  @max_integer 18_446_744_073_709_551_615
  @phases ~w(prepared aggregate_committed source_retired)

  @type block :: %{
          first_position: pos_integer(),
          last_position: pos_integer(),
          ref: String.t(),
          source_generation: non_neg_integer()
        }

  @type pending :: %{
          phase: :prepared | :aggregate_committed | :source_retired,
          first_position: pos_integer(),
          last_position: pos_integer(),
          ref: String.t(),
          source_generation: non_neg_integer()
        }

  @type t :: %__MODULE__{
          retired_through: non_neg_integer(),
          blocks: [block()],
          pending: pending() | nil,
          policy: map()
        }

  defstruct retired_through: 0, blocks: [], pending: nil, policy: %{}

  @spec new(map()) :: t()
  def new(policy \\ %{}) when is_map(policy), do: %__MODULE__{policy: policy}

  @doc "Replaces the recorded retention-policy facts (reporting only)."
  @spec put_policy(t(), map()) :: t()
  def put_policy(%__MODULE__{} = manifest, policy) when is_map(policy), do: %{manifest | policy: policy}

  @doc "The next contiguous raw position eligible for a fresh destructive phase."
  @spec next_position(t()) :: pos_integer()
  def next_position(%__MODULE__{retired_through: retired}), do: retired + 1

  @doc """
  Opens a destructive phase for `[first, last]`. The range must start exactly at
  `retired_through + 1` (gapless) and no other phase may be in flight.
  """
  @spec prepare(t(), pos_integer(), pos_integer(), String.t(), non_neg_integer()) ::
          {:ok, t()} | {:error, atom()}
  def prepare(%__MODULE__{pending: nil} = manifest, first, last, ref, source_generation)
      when is_integer(first) and is_integer(last) and last >= first and is_binary(ref) do
    if first == manifest.retired_through + 1 do
      pending = %{phase: :prepared, first_position: first, last_position: last, ref: ref, source_generation: source_generation}
      {:ok, %{manifest | pending: pending}}
    else
      {:error, :non_contiguous_range}
    end
  end

  def prepare(%__MODULE__{pending: %{}}, _first, _last, _ref, _generation), do: {:error, :phase_in_flight}
  def prepare(%__MODULE__{}, _first, _last, _ref, _generation), do: {:error, :invalid_range}

  @doc "Advances the in-flight phase along the fixed ordering."
  @spec advance(t(), :aggregate_committed | :source_retired) :: {:ok, t()} | {:error, atom()}
  def advance(%__MODULE__{pending: %{phase: :prepared} = pending} = manifest, :aggregate_committed) do
    {:ok, %{manifest | pending: %{pending | phase: :aggregate_committed}}}
  end

  def advance(%__MODULE__{pending: %{phase: :aggregate_committed} = pending} = manifest, :source_retired) do
    {:ok, %{manifest | pending: %{pending | phase: :source_retired}}}
  end

  def advance(%__MODULE__{}, _phase), do: {:error, :illegal_transition}

  @doc "Commits the in-flight `source_retired` phase: the block becomes durable coverage and the watermark advances."
  @spec finalize(t()) :: {:ok, t()} | {:error, atom()}
  def finalize(%__MODULE__{pending: %{phase: :source_retired} = pending} = manifest) do
    block = Map.take(pending, [:first_position, :last_position, :ref, :source_generation])

    {:ok,
     %{
       manifest
       | blocks: manifest.blocks ++ [block],
         retired_through: pending.last_position,
         pending: nil
     }}
  end

  def finalize(%__MODULE__{}), do: {:error, :not_retired}

  @doc "Abandons the in-flight phase, leaving the watermark and finalized blocks untouched."
  @spec rollback(t()) :: t()
  def rollback(%__MODULE__{} = manifest), do: %{manifest | pending: nil}

  @doc "The finalized block descriptors that cover `[1, retired_through]`, oldest first."
  @spec blocks(t()) :: [block()]
  def blocks(%__MODULE__{blocks: blocks}), do: blocks

  @doc "The in-flight phase, or `nil`."
  @spec pending(t()) :: pending() | nil
  def pending(%__MODULE__{pending: pending}), do: pending

  # --- codec + durability -------------------------------------------------

  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = manifest) do
    payload = %{
      "schema" => @schema,
      "version" => @version,
      "retired_through" => manifest.retired_through,
      "policy" => encode_policy(manifest.policy),
      "blocks" => Enum.map(manifest.blocks, &encode_block/1),
      "pending" => encode_pending(manifest.pending)
    }

    Map.put(payload, "checksum", checksum(payload))
  end

  @spec write(String.t(), t(), keyword()) :: :ok | {:error, atom()}
  def write(path, %__MODULE__{} = manifest, opts \\ []) when is_binary(path) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    contents = Jason.encode!(encode(manifest))

    if byte_size(contents) > max_bytes do
      {:error, :manifest_too_large}
    else
      case Fs.atomic_write(path, contents, fsync: true, mode: 0o600) do
        :ok -> :ok
        {:error, _reason} -> {:error, :manifest_write_failed}
      end
    end
  end

  @doc """
  Loads and validates the manifest. `:missing` for an absent/empty file (a
  fresh install), `{:ok, manifest}` for a checksum-verified manifest, or
  `{:corrupt, reason}` — the caller quarantines and halts destructive progress
  rather than trusting an ambiguous manifest.
  """
  @spec load(String.t(), keyword()) :: :missing | {:ok, t()} | {:corrupt, atom()}
  def load(path, opts \\ []) when is_binary(path) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    case File.lstat(path) do
      {:error, :enoent} -> :missing
      {:ok, %File.Stat{type: :regular, size: 0}} -> :missing
      {:ok, %File.Stat{type: :regular, size: size}} when size <= max_bytes -> load_regular(path)
      {:ok, %File.Stat{type: :regular}} -> {:corrupt, :manifest_too_large}
      {:ok, %File.Stat{type: :symlink}} -> {:corrupt, :symlink_rejected}
      {:ok, _stat} -> {:corrupt, :not_a_regular_file}
      {:error, _reason} -> {:corrupt, :unreadable}
    end
  end

  defp load_regular(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents),
         {:ok, manifest} <- from_record(decoded) do
      {:ok, manifest}
    else
      {:error, reason} when is_atom(reason) -> {:corrupt, reason}
      _other -> {:corrupt, :invalid_manifest}
    end
  end

  @spec from_record(term()) :: {:ok, t()} | {:error, atom()}
  def from_record(record) when is_map(record) do
    with @record_keys <- record |> Map.keys() |> Enum.sort(),
         @schema <- Map.get(record, "schema"),
         @version <- Map.get(record, "version"),
         {:ok, retired_through} <- bounded(Map.get(record, "retired_through")),
         true <- is_map(Map.get(record, "policy")),
         true <- Map.get(record, "checksum") == checksum(payload(record)),
         {:ok, blocks} <- decode_blocks(Map.get(record, "blocks"), retired_through),
         {:ok, pending} <- decode_pending(Map.get(record, "pending"), retired_through, blocks) do
      {:ok, %__MODULE__{retired_through: retired_through, blocks: blocks, pending: pending, policy: Map.get(record, "policy")}}
    else
      false -> {:error, :invalid_manifest}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_manifest}
    end
  end

  def from_record(_record), do: {:error, :invalid_manifest}

  # The policy is a reporting-only breadcrumb; normalize it to JSON-native types
  # so the checksummed payload is identical before and after a JSON round-trip.
  defp encode_policy(policy) when is_map(policy) do
    Map.new(policy, fn {key, value} -> {to_string(key), encode_policy_value(value)} end)
  end

  defp encode_policy_value(value) when is_integer(value) or is_binary(value) or is_nil(value) or is_boolean(value), do: value
  defp encode_policy_value(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_policy_value(value), do: inspect(value)

  defp encode_block(block) do
    %{
      "first_position" => block.first_position,
      "last_position" => block.last_position,
      "ref" => block.ref,
      "source_generation" => block.source_generation
    }
  end

  # Blocks must form a gapless, ordered cover of `[1, retired_through]`; a gap or
  # overlap means a torn or tampered manifest, not a state we ever wrote.
  defp decode_blocks(raw, retired_through) when is_list(raw) do
    Enum.reduce_while(raw, {:ok, [], 0}, fn entry, {:ok, acc, previous_last} ->
      case decode_block(entry, previous_last + 1) do
        {:ok, block} -> {:cont, {:ok, [block | acc], block.last_position}}
        :error -> {:halt, {:error, :invalid_manifest}}
      end
    end)
    |> case do
      {:ok, acc, ^retired_through} -> {:ok, Enum.reverse(acc)}
      {:ok, _acc, _last} -> {:error, :invalid_manifest}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_blocks(_raw, _retired_through), do: {:error, :invalid_manifest}

  defp decode_block(%{"first_position" => first, "last_position" => last, "ref" => ref, "source_generation" => generation}, expected_first)
       when first == expected_first and is_binary(ref) do
    with {:ok, first} <- positive(first),
         {:ok, last} <- positive(last),
         true <- last >= first,
         {:ok, generation} <- bounded(generation),
         true <- safe_ref?(ref) do
      {:ok, %{first_position: first, last_position: last, ref: ref, source_generation: generation}}
    else
      _ -> :error
    end
  end

  defp decode_block(_entry, _expected_first), do: :error

  defp encode_pending(nil), do: nil

  defp encode_pending(pending) do
    %{
      "phase" => Atom.to_string(pending.phase),
      "first_position" => pending.first_position,
      "last_position" => pending.last_position,
      "ref" => pending.ref,
      "source_generation" => pending.source_generation
    }
  end

  defp decode_pending(nil, _retired_through, _blocks), do: {:ok, nil}

  defp decode_pending(%{"phase" => phase} = raw, retired_through, _blocks) when phase in @phases do
    with {:ok, first} <- positive(Map.get(raw, "first_position")),
         {:ok, last} <- positive(Map.get(raw, "last_position")),
         true <- last >= first,
         true <- first == retired_through + 1,
         {:ok, generation} <- bounded(Map.get(raw, "source_generation")),
         ref when is_binary(ref) <- Map.get(raw, "ref"),
         true <- safe_ref?(ref) do
      {:ok,
       %{
         phase: String.to_existing_atom(phase),
         first_position: first,
         last_position: last,
         ref: ref,
         source_generation: generation
       }}
    else
      _ -> {:error, :invalid_manifest}
    end
  end

  defp decode_pending(_raw, _retired_through, _blocks), do: {:error, :invalid_manifest}

  # Block refs are daemon-generated filenames; reject anything that could escape
  # the blocks directory or is not a plain leaf name.
  defp safe_ref?(ref) do
    is_binary(ref) and ref != "" and Path.basename(ref) == ref and not String.contains?(ref, "/") and
      String.match?(ref, ~r/^[A-Za-z0-9._-]+$/)
  end

  defp payload(record), do: Map.drop(record, ["checksum"])

  defp positive(value) when is_integer(value) and value > 0 and value <= @max_integer, do: {:ok, value}
  defp positive(_value), do: :error

  defp bounded(value) when is_integer(value) and value >= 0 and value <= @max_integer, do: {:ok, value}
  defp bounded(_value), do: {:error, :invalid_manifest}

  defp checksum(payload) do
    payload
    |> Map.drop(["checksum"])
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
