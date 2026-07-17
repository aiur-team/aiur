defmodule Aiur.TicketObservation do
  @moduledoc """
  A versioned, safe observation attached to ticket-scoped event publications.

  Event topics remain routing text. Consumers may join an observation only when
  `status` is `:joinable` and its `tracker_identity` passes BO-004's configured
  repository identity check. The normalizer deliberately does not inspect a
  topic, issue number, workspace, or arbitrary payload to discover identity.
  """

  alias Aiur.{OpaqueIdentifier, TrackerIdentity}

  @version 1
  @payload_version 1
  @progress_names ["progress", "progress.checkin", "progress.phase"]
  @stages ["brainstorm", "plan", "work", "review"]
  @transitions ["start", "end"]
  @severities ["info", "warning", "critical"]

  @derive {
    Jason.Encoder,
    only: [
      :version,
      :status,
      :reason,
      :tracker_identity,
      :source,
      :event_id,
      :provenance,
      :occurred_at,
      :observed_at,
      :payload_version,
      :attributes
    ]
  }
  defstruct version: @version,
            status: :unattributed,
            reason: :missing_trusted_identity,
            tracker_identity: nil,
            source: %{kind: :legacy, name: "unclassified"},
            event_id: nil,
            provenance: %{},
            occurred_at: nil,
            observed_at: nil,
            payload_version: @payload_version,
            attributes: %{}

  @type status :: :joinable | :unattributed

  @type t :: %__MODULE__{
          version: pos_integer(),
          status: status(),
          reason: atom() | nil,
          tracker_identity: TrackerIdentity.t() | nil,
          source: %{kind: :agent_alert | :agent_event | :legacy, name: String.t()},
          event_id: pos_integer() | nil,
          provenance: map(),
          occurred_at: DateTime.t() | nil,
          observed_at: DateTime.t() | nil,
          payload_version: pos_integer(),
          attributes: map()
        }

  @doc """
  Normalizes a trusted producer context into the V1 envelope.

  A malformed or absent timestamp is unknown (`nil`), never silently replaced
  with the current time. The Publisher, as the ingestion boundary, supplies
  its explicit `:observed_at`; `:occurred_at` remains unknown unless the source
  provides a valid value.
  """
  @spec normalize(map(), keyword()) :: t()
  def normalize(payload, opts \\ [])

  def normalize(payload, opts) when is_map(payload) and is_list(opts) do
    source = normalize_source(Keyword.get(opts, :source))

    %__MODULE__{
      version: @version,
      status: identity_status(Keyword.get(opts, :identity)),
      reason: identity_reason(Keyword.get(opts, :identity)),
      tracker_identity: normalized_identity(Keyword.get(opts, :identity)),
      source: source,
      event_id: positive_integer_or_nil(Keyword.get(opts, :event_id)),
      provenance: normalize_provenance(Keyword.get(opts, :provenance, %{})),
      occurred_at: normalize_timestamp(Keyword.get(opts, :occurred_at)),
      observed_at: observed_at(opts),
      payload_version: positive_integer_or_default(Keyword.get(opts, :payload_version), @payload_version),
      attributes: safe_attributes(source, payload)
    }
  end

  def normalize(_payload, _opts), do: normalize(%{}, [])

  @doc """
  Lists the source families that publish a BO-017 observation. This is an
  inventory aid for BO-005 without making the current publisher a reducer.
  """
  @spec producer_inventory() :: [map()]
  def producer_inventory do
    [
      %{
        producer: :agent_event,
        identity: :trusted_when_available,
        observations: [:progress, :progress_checkin, :progress_phase]
      },
      %{producer: :agent_alert, identity: :trusted_when_available, observations: [:active_stage, :safe_alert_evidence]},
      %{producer: :publisher_compatibility, identity: :unattributed, observations: [:legacy]}
    ]
  end

  defp identity_status(identity), do: if(TrackerIdentity.joinable?(identity), do: :joinable, else: :unattributed)

  defp identity_reason(identity) do
    cond do
      TrackerIdentity.joinable?(identity) -> nil
      match?(%TrackerIdentity{}, identity) -> :unjoinable_trusted_identity
      true -> :missing_trusted_identity
    end
  end

  defp normalized_identity(%TrackerIdentity{} = identity), do: identity
  defp normalized_identity(_identity), do: nil

  defp normalize_source(%{kind: :agent_event, name: name}) do
    if name in @progress_names, do: %{kind: :agent_event, name: name}, else: %{kind: :agent_event, name: "unclassified"}
  end

  defp normalize_source(%{kind: :agent_alert, name: name}) when is_binary(name) do
    case parse_stage(name) do
      {:ok, _stage, _transition} -> %{kind: :agent_alert, name: name}
      :error -> %{kind: :agent_alert, name: "alert"}
    end
  end

  defp normalize_source(_source), do: %{kind: :legacy, name: "unclassified"}

  defp safe_attributes(%{kind: :agent_event, name: name}, payload) when name in @progress_names do
    case percent(payload_value(payload, "percent")) do
      nil -> %{}
      value -> %{percent: value}
    end
  end

  defp safe_attributes(%{kind: :agent_alert, name: name}, payload) do
    case parse_stage(name) do
      {:ok, stage, transition} -> %{stage: stage, transition: transition}
      :error -> alert_attributes(payload)
    end
  end

  defp safe_attributes(_source, _payload), do: %{}

  defp alert_attributes(payload) do
    %{}
    |> maybe_put(:needs_attention, payload_value(payload, "needs_attention"), &is_boolean/1)
    |> maybe_put(:severity, payload_value(payload, "severity"), &(&1 in @severities))
  end

  defp maybe_put(attributes, key, value, predicate) when is_function(predicate, 1) do
    if predicate.(value), do: Map.put(attributes, key, value), else: attributes
  end

  defp parse_stage("phase." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [stage, transition] when stage in @stages and transition in @transitions ->
        {:ok, String.to_existing_atom(stage), String.to_existing_atom(transition)}

      _ ->
        :error
    end
  end

  defp parse_stage(_name), do: :error

  defp payload_value(payload, key), do: Map.get(payload, key, Map.get(payload, String.to_atom(key)))

  defp percent(value) when is_integer(value) and value >= 0 and value <= 100, do: value
  defp percent(_value), do: nil

  defp normalize_provenance(provenance) when is_map(provenance) do
    Enum.reduce([:run_id, :attempt, :session_id, :source_event_id], %{}, fn key, result ->
      case opaque(provenance_value(provenance, key)) do
        nil -> result
        value -> Map.put(result, key, value)
      end
    end)
  end

  defp normalize_provenance(_provenance), do: %{}

  defp provenance_value(provenance, key), do: Map.get(provenance, key, Map.get(provenance, Atom.to_string(key)))

  defp opaque(value) when is_integer(value) and value >= 0, do: value

  defp opaque(value) when is_binary(value), do: OpaqueIdentifier.normalize(value)

  defp opaque(_value), do: nil

  defp observed_at(opts) do
    case Keyword.fetch(opts, :observed_at) do
      {:ok, value} -> normalize_timestamp(value)
      :error -> nil
    end
  end

  defp normalize_timestamp(%DateTime{} = timestamp), do: timestamp

  defp normalize_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, normalized, _offset} -> normalized
      _ -> nil
    end
  end

  defp normalize_timestamp(_timestamp), do: nil

  defp positive_integer_or_nil(value) when is_integer(value) and value > 0, do: value
  defp positive_integer_or_nil(_value), do: nil

  defp positive_integer_or_default(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer_or_default(_value, default), do: default
end
