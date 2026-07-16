defmodule Aiur.UsageLedger.CounterPolicy do
  @moduledoc false

  alias Aiur.{UsageEnvelope, UsageLedger.Record}

  @token_fields UsageEnvelope.token_dimensions() ++ [:provider_reported_total]

  defstruct idempotency: MapSet.new(),
            absolute: %{},
            streams: %{},
            coverage: %{lower: nil, upper: nil, status: :empty}

  @type state :: %__MODULE__{
          idempotency: MapSet.t(),
          absolute: map(),
          streams: %{optional(String.t()) => :absolute | :delta},
          coverage: %{
            lower: non_neg_integer() | nil,
            upper: non_neg_integer() | nil,
            status: :empty | :unknown | :partial | :full
          }
        }

  @spec new() :: state()
  def new, do: %__MODULE__{}

  @spec apply(state(), UsageEnvelope.t()) ::
          {:ok, %{state: state(), delta: map()}} | {:duplicate, state()} | {:error, atom(), state()}
  def apply(%__MODULE__{} = state, %UsageEnvelope{} = envelope) do
    with :ok <- Record.admit(envelope),
         false <- MapSet.member?(state.idempotency, idempotency_key(envelope)),
         {:ok, entries} <- entries(envelope),
         :ok <- compatible_streams?(state, entries),
         {:ok, absolute, delta_values} <- apply_entries(state.absolute, entries) do
      streams = Enum.reduce(entries, state.streams, &Map.put(&2, &1.stream_key, &1.kind))

      next_state = %{
        state
        | idempotency: MapSet.put(state.idempotency, idempotency_key(envelope)),
          absolute: absolute,
          streams: streams,
          coverage: coverage(state.coverage, envelope)
      }

      {:ok, %{state: next_state, delta: delta(envelope, delta_values)}}
    else
      true -> {:duplicate, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @spec dump(state()) :: map()
  def dump(%__MODULE__{} = state) do
    %{
      "idempotency" => state.idempotency |> MapSet.to_list() |> Enum.sort(),
      "absolute" =>
        Map.new(state.absolute, fn {key, value} ->
          {key,
           %{
             "value" => encode_value(value.value),
             "kind" => if(is_struct(value.value, Decimal), do: "money", else: "token"),
             "source_sequence" => value.source_sequence
           }}
        end),
      "streams" => Map.new(state.streams, fn {key, kind} -> {key, Atom.to_string(kind)} end),
      "coverage" => %{
        "lower" => state.coverage.lower,
        "upper" => state.coverage.upper,
        "status" => Atom.to_string(state.coverage.status)
      }
    }
  end

  @spec load(map()) :: {:ok, state()} | {:error, atom()}
  def load(value) when is_map(value) do
    with :ok <- only_keys(value, ["idempotency", "absolute", "streams", "coverage"]),
         {:ok, idempotency} <- idempotency(value_of(value, :idempotency)),
         {:ok, absolute} <- absolute(value_of(value, :absolute)),
         {:ok, streams} <- streams(value_of(value, :streams)),
         {:ok, coverage} <- coverage(value_of(value, :coverage)) do
      {:ok, %__MODULE__{idempotency: idempotency, absolute: absolute, streams: streams, coverage: coverage}}
    end
  end

  def load(_value), do: {:error, :invalid_ledger_checkpoint}

  @spec idempotency_key(UsageEnvelope.t()) :: String.t()
  def idempotency_key(%UsageEnvelope{} = envelope) do
    {
      envelope.provider,
      envelope.backend,
      envelope.transport,
      envelope.auth_mode,
      envelope.account_generation.generation,
      envelope.counter_epoch,
      scope(envelope, envelope.counter_scope),
      envelope.requested_model,
      envelope.resolved_model,
      envelope.source,
      envelope.source_version,
      envelope.source_event_id,
      cost_idempotency_context(envelope.cost)
    }
    |> :erlang.term_to_binary()
    |> Base.url_encode64(padding: false)
  end

  defp entries(envelope) do
    tokens =
      Enum.flat_map(@token_fields, fn field ->
        case Map.fetch!(envelope.tokens, field) do
          nil -> []
          value -> [entry(envelope, :token, field, value, envelope.measurement_kind)]
        end
      end)

    cost =
      case envelope.cost do
        nil -> []
        money -> [entry(envelope, :cost, money.currency, money.amount, money.measurement_kind, money)]
      end

    {:ok, tokens ++ cost}
  end

  defp entry(envelope, type, dimension, value, kind, money \\ nil) do
    identity = {
      envelope.provider,
      envelope.backend,
      envelope.transport,
      envelope.auth_mode,
      envelope.account_generation.generation,
      envelope.counter_epoch,
      scope(envelope, stream_scope(envelope, money)),
      type,
      dimension,
      envelope.requested_model,
      envelope.resolved_model,
      source(envelope, money)
    }

    key = identity |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)

    %{
      key: key,
      stream_key: key,
      type: type,
      dimension: dimension,
      value: value,
      kind: kind,
      money: money,
      source_sequence: envelope.source_sequence
    }
  end

  defp source(envelope, nil), do: {envelope.source, envelope.source_version, envelope.counter_scope}
  defp source(_envelope, money), do: {money.source, money.source_version, money.counter_scope}

  defp stream_scope(envelope, nil), do: envelope.counter_scope
  defp stream_scope(_envelope, money), do: money.counter_scope

  defp scope(envelope, :session) do
    attribution = envelope.attribution
    {attribution.session_id}
  end

  defp scope(envelope, :thread) do
    attribution = envelope.attribution
    {attribution.session_id, attribution.thread_id}
  end

  defp scope(envelope, :turn) do
    attribution = envelope.attribution
    {attribution.session_id, attribution.thread_id, attribution.turn_id}
  end

  defp scope(envelope, :request) do
    attribution = envelope.attribution
    {attribution.session_id, attribution.thread_id, attribution.turn_id, attribution.request_id}
  end

  defp cost_idempotency_context(nil), do: nil

  defp cost_idempotency_context(money) do
    {money.currency, money.measurement_kind, money.counter_scope, money.source, money.source_version}
  end

  defp compatible_streams?(state, entries) do
    case Enum.find(entries, fn entry -> Map.has_key?(state.streams, entry.stream_key) and state.streams[entry.stream_key] != entry.kind end) do
      nil -> :ok
      _entry -> {:error, :mixed_measurement_stream}
    end
  end

  defp apply_entries(absolute, entries) do
    Enum.reduce_while(entries, {:ok, absolute, %{}}, fn entry, {:ok, current, deltas} ->
      case apply_entry(current, entry) do
        {:ok, next, value} -> {:cont, {:ok, next, Map.put(deltas, entry.key, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_entry(absolute, %{kind: :delta, value: value}), do: {:ok, absolute, value}

  defp apply_entry(absolute, %{kind: :absolute, key: key, value: value} = entry) do
    case Map.get(absolute, key) do
      nil -> {:ok, Map.put(absolute, key, %{value: value, source_sequence: sequence(entry)}), value}
      previous -> advance_absolute(absolute, key, previous, value, sequence(entry))
    end
  end

  defp advance_absolute(absolute, key, previous, value, sequence) do
    if sequence <= previous.source_sequence do
      {:ok, absolute, zero(value)}
    else
      case compare(value, previous.value) do
        :gt ->
          {:ok, Map.put(absolute, key, %{value: value, source_sequence: sequence}), subtract(value, previous.value)}

        :eq ->
          {:ok, Map.put(absolute, key, %{previous | source_sequence: sequence}), zero(value)}

        :lt ->
          {:error, :counter_decreased}
      end
    end
  end

  # The sequence is intentionally held on the entry instead of recovered from
  # its opaque identity key. Keeping it explicit prevents a future key-format
  # change from changing stale-observation semantics.
  defp sequence(entry), do: entry.source_sequence

  defp compare(%Decimal{} = left, %Decimal{} = right), do: Decimal.compare(left, right)
  defp compare(left, right) when left > right, do: :gt
  defp compare(left, right) when left == right, do: :eq
  defp compare(_left, _right), do: :lt

  defp subtract(%Decimal{} = left, %Decimal{} = right), do: Decimal.sub(left, right)
  defp subtract(left, right), do: left - right
  defp zero(%Decimal{}), do: Decimal.new(0)
  defp zero(_value), do: 0

  defp delta(envelope, delta_values) do
    tokens =
      Map.new(@token_fields, fn field ->
        case Map.fetch!(envelope.tokens, field) do
          nil -> {field, nil}
          _value -> {field, Map.fetch!(delta_values, entry(envelope, :token, field, Map.fetch!(envelope.tokens, field), envelope.measurement_kind).key)}
        end
      end)

    cost =
      case envelope.cost do
        nil -> nil
        money -> %{money | amount: Map.fetch!(delta_values, entry(envelope, :cost, money.currency, money.amount, money.measurement_kind, money).key)}
      end

    %{
      tokens: tokens,
      cost: cost,
      source_version: envelope.source_version,
      relationship_revision: envelope.relationship_revision,
      coverage_reasons: envelope.coverage_reasons
    }
  end

  defp coverage(coverage, envelope) do
    sequence = envelope.source_sequence

    %{
      lower: if(coverage.lower == nil, do: sequence, else: min(coverage.lower, sequence)),
      upper: if(coverage.upper == nil, do: sequence, else: max(coverage.upper, sequence)),
      status: coverage_status(coverage.status, envelope)
    }
  end

  defp coverage_status(:unknown, _envelope), do: :unknown

  defp coverage_status(:partial, envelope) do
    if unknown_coverage?(envelope), do: :unknown, else: :partial
  end

  defp coverage_status(_previous, envelope) do
    cond do
      unknown_coverage?(envelope) -> :unknown
      envelope.coverage_reasons != [] or partial_cost?(envelope.cost) -> :partial
      true -> :full
    end
  end

  defp unknown_coverage?(envelope) do
    envelope.attribution.tracker_identity == nil or
      (envelope.cost != nil and envelope.cost.coverage == :unknown)
  end

  defp partial_cost?(nil), do: false
  defp partial_cost?(money), do: money.coverage == :partial

  defp encode_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp encode_value(value), do: value

  defp idempotency(values) when is_list(values) do
    if Enum.all?(values, &checkpoint_key?/1), do: {:ok, MapSet.new(values)}, else: {:error, :invalid_ledger_checkpoint}
  end

  defp idempotency(_values), do: {:error, :invalid_ledger_checkpoint}

  defp absolute(values) when is_map(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, result} ->
      with true <- checkpoint_key?(key),
           {:ok, decoded} <- absolute_value(value) do
        {:cont, {:ok, Map.put(result, key, decoded)}}
      else
        _ -> {:halt, {:error, :invalid_ledger_checkpoint}}
      end
    end)
  end

  defp absolute(_values), do: {:error, :invalid_ledger_checkpoint}

  defp absolute_value(value) when is_map(value) do
    source_sequence = value_of(value, :source_sequence)

    with :ok <- only_keys(value, ["value", "kind", "source_sequence"]),
         true <- is_integer(source_sequence) and source_sequence >= 0,
         {:ok, decoded} <- checkpoint_value(value_of(value, :kind), value_of(value, :value)) do
      {:ok, %{value: decoded, source_sequence: source_sequence}}
    else
      _ -> {:error, :invalid_ledger_checkpoint}
    end
  end

  defp absolute_value(_value), do: {:error, :invalid_ledger_checkpoint}
  defp checkpoint_value("token", value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp checkpoint_value("money", value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> if(Decimal.negative?(decimal), do: {:error, :invalid_ledger_checkpoint}, else: {:ok, decimal})
      _ -> {:error, :invalid_ledger_checkpoint}
    end
  end

  defp checkpoint_value(_kind, _value), do: {:error, :invalid_ledger_checkpoint}

  defp streams(values) when is_map(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, result} ->
      case value do
        "absolute" -> stream_entry(key, :absolute, result)
        "delta" -> stream_entry(key, :delta, result)
        _ -> {:halt, {:error, :invalid_ledger_checkpoint}}
      end
    end)
  end

  defp streams(_values), do: {:error, :invalid_ledger_checkpoint}

  defp stream_entry(key, kind, result) do
    if checkpoint_key?(key),
      do: {:cont, {:ok, Map.put(result, key, kind)}},
      else: {:halt, {:error, :invalid_ledger_checkpoint}}
  end

  defp coverage(values) when is_map(values) do
    lower = value_of(values, :lower)
    upper = value_of(values, :upper)
    status = value_of(values, :status)

    if valid_coverage?(values, lower, upper, status) do
      {:ok, %{lower: lower, upper: upper, status: String.to_existing_atom(status)}}
    else
      {:error, :invalid_ledger_checkpoint}
    end
  end

  defp coverage(_values), do: {:error, :invalid_ledger_checkpoint}

  defp valid_coverage?(values, lower, upper, status) do
    only_keys(values, ["lower", "upper", "status"]) == :ok and
      (is_nil(lower) or is_integer(lower)) and
      (is_nil(upper) or is_integer(upper)) and
      status in ["empty", "unknown", "partial", "full"]
  end

  defp only_keys(value, expected) do
    if value |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort() == Enum.sort(expected), do: :ok, else: {:error, :invalid_ledger_checkpoint}
  end

  defp checkpoint_key?(value) when is_binary(value) and byte_size(value) in 1..4_096,
    do: String.match?(value, ~r/\A[A-Za-z0-9_-]+\z/)

  defp checkpoint_key?(_value), do: false
  defp value_of(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
