defmodule Aiur.DecisionMetrics.Sample do
  @moduledoc """
  Pure projection of observed Decision lifecycle milestones.

  The canonical Decision audit remains the source of truth. This struct is a
  redacted metrics snapshot: it retains identifiers, timestamps, actor class,
  and counters, but never question, answer, rationale, or artifact content.
  """

  @type stage ::
          :requested
          | :decided
          | :dispatched
          | :delivered
          | :acknowledged
          | :resolved
          | :attention
          | :reminder
          | :revised

  @type t :: %__MODULE__{
          decision_id: String.t(),
          identifier: String.t(),
          blocking: boolean() | nil,
          requested_at: DateTime.t() | nil,
          decided_at: DateTime.t() | nil,
          dispatched_at: DateTime.t() | nil,
          delivered_at: DateTime.t() | nil,
          acknowledged_at: DateTime.t() | nil,
          resolved_at: DateTime.t() | nil,
          last_observed_at: DateTime.t() | nil,
          reminder_count: non_neg_integer(),
          attention_count: non_neg_integer(),
          actor: String.t() | nil,
          revised: boolean()
        }

  @enforce_keys [:decision_id, :identifier]
  @timestamps ~w(requested_at decided_at dispatched_at delivered_at acknowledged_at resolved_at last_observed_at)a
  defstruct [
    :decision_id,
    :identifier,
    :blocking,
    :requested_at,
    :decided_at,
    :dispatched_at,
    :delivered_at,
    :acknowledged_at,
    :resolved_at,
    :last_observed_at,
    :actor,
    reminder_count: 0,
    attention_count: 0,
    revised: false
  ]

  @doc "Creates an empty metrics projection for one Decision."
  @spec new(String.t(), String.t()) :: t()
  def new(decision_id, identifier) when is_binary(decision_id) and is_binary(identifier) do
    %__MODULE__{decision_id: decision_id, identifier: identifier}
  end

  @doc "Applies one deduplicated lifecycle observation to a projection."
  @spec observe(t(), stage(), %{required(:at) => DateTime.t(), optional(atom()) => term()}) :: t()
  def observe(%__MODULE__{} = sample, stage, %{at: %DateTime{} = at} = attributes) do
    sample
    |> apply_stage(stage, at, attributes)
    |> Map.update!(:last_observed_at, &latest(&1, at))
  end

  @doc "Returns the append-safe, JSON-encodable metrics snapshot."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = sample) do
    %{
      schema_version: 1,
      decision_id: sample.decision_id,
      identifier: sample.identifier,
      blocking: sample.blocking,
      requested_at: iso8601(sample.requested_at),
      decided_at: iso8601(sample.decided_at),
      dispatched_at: iso8601(sample.dispatched_at),
      delivered_at: iso8601(sample.delivered_at),
      acknowledged_at: iso8601(sample.acknowledged_at),
      resolved_at: iso8601(sample.resolved_at),
      last_observed_at: iso8601(sample.last_observed_at),
      request_to_decision_ms: duration(sample.requested_at, sample.decided_at),
      decision_to_dispatch_ms: duration(sample.decided_at, sample.dispatched_at),
      dispatch_to_delivery_ms: duration(sample.dispatched_at, sample.delivered_at),
      delivery_to_ack_ms: duration(sample.delivered_at, sample.acknowledged_at),
      blocked_time_ms: blocked_time(sample),
      reminder_count: sample.reminder_count,
      attention_count: sample.attention_count,
      actor: sample.actor,
      revised: sample.revised
    }
  end

  @doc "Rehydrates the latest snapshot while replaying the append-only metrics log."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(raw) when is_map(raw) do
    with decision_id when is_binary(decision_id) <- raw["decision_id"],
         identifier when is_binary(identifier) <- raw["identifier"],
         {:ok, timestamps} <- timestamps_from(raw) do
      {:ok,
       struct!(
         __MODULE__,
         [decision_id: decision_id, identifier: identifier] ++
           timestamps ++
           [
             blocking: boolean_or_nil(raw["blocking"]),
             reminder_count: non_negative(raw["reminder_count"]),
             attention_count: non_negative(raw["attention_count"]),
             actor: binary_or_nil(raw["actor"]),
             revised: raw["revised"] == true
           ]
       )}
    else
      _other -> {:error, :invalid_snapshot}
    end
  end

  def from_map(_raw), do: {:error, :invalid_snapshot}

  defp apply_stage(sample, :requested, at, attributes) do
    %{sample | requested_at: earliest(sample.requested_at, at), blocking: requested_blocking(sample, attributes)}
  end

  defp apply_stage(sample, :decided, at, attributes) do
    %{sample | decided_at: earliest(sample.decided_at, at), actor: sample.actor || attributes[:actor]}
  end

  defp apply_stage(s, :dispatched, at, _attrs), do: %{s | dispatched_at: earliest(s.dispatched_at, at)}
  defp apply_stage(s, :delivered, at, _attrs), do: %{s | delivered_at: earliest(s.delivered_at, at)}
  defp apply_stage(s, :acknowledged, at, _attrs), do: %{s | acknowledged_at: earliest(s.acknowledged_at, at)}
  defp apply_stage(s, :resolved, at, _attrs), do: %{s | resolved_at: earliest(s.resolved_at, at)}
  defp apply_stage(sample, :reminder, _at, _attributes), do: Map.update!(sample, :reminder_count, &(&1 + 1))
  defp apply_stage(sample, :revised, _at, _attributes), do: %{sample | revised: true}

  defp apply_stage(sample, :attention, _at, _attributes) do
    reminders = if sample.attention_count > 0, do: sample.reminder_count + 1, else: sample.reminder_count
    %{sample | attention_count: sample.attention_count + 1, reminder_count: reminders}
  end

  defp requested_blocking(_sample, %{blocking: blocking}) when is_boolean(blocking), do: blocking
  defp requested_blocking(sample, _attributes), do: sample.blocking

  defp blocked_time(%__MODULE__{blocking: false}), do: 0
  defp blocked_time(%__MODULE__{blocking: nil}), do: nil

  defp blocked_time(%__MODULE__{} = sample) do
    finished_at = sample.acknowledged_at || sample.resolved_at || sample.last_observed_at
    duration(sample.requested_at, finished_at)
  end

  defp duration(%DateTime{} = started_at, %DateTime{} = finished_at) do
    case DateTime.diff(finished_at, started_at, :millisecond) do
      milliseconds when milliseconds >= 0 -> milliseconds
      _negative -> nil
    end
  end

  defp duration(_started_at, _finished_at), do: nil

  defp earliest(nil, %DateTime{} = value), do: value

  defp earliest(%DateTime{} = existing, %DateTime{} = value),
    do: if(DateTime.before?(value, existing), do: value, else: existing)

  defp latest(nil, %DateTime{} = value), do: value

  defp latest(%DateTime{} = existing, %DateTime{} = value),
    do: if(DateTime.after?(value, existing), do: value, else: existing)

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(nil), do: nil

  defp timestamps_from(raw) do
    Enum.reduce_while(@timestamps, {:ok, []}, fn field, {:ok, acc} ->
      case parse_timestamp(raw[Atom.to_string(field)]) do
        {:ok, value} -> {:cont, {:ok, [{field, value} | acc]}}
        {:error, reason} -> {:halt, {:error, {field, reason}}}
      end
    end)
  end

  defp parse_timestamp(nil), do: {:ok, nil}
  defp parse_timestamp(%DateTime{} = value), do: {:ok, value}

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_timestamp}
    end
  end

  defp parse_timestamp(_value), do: {:error, :invalid_timestamp}

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value), do: 0
  defp boolean_or_nil(value) when is_boolean(value), do: value
  defp boolean_or_nil(_value), do: nil
  defp binary_or_nil(value) when is_binary(value), do: value
  defp binary_or_nil(_value), do: nil
end
