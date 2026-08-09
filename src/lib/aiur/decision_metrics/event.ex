defmodule Aiur.DecisionMetrics.Event do
  @moduledoc """
  Normalizes current and forward-compatible Decision Exchange envelopes into
  the small, redacted fact shape consumed by `Aiur.DecisionMetrics`.
  """

  alias Aiur.{Decision, DecisionEvent, DecisionProjection}
  alias Aiur.DecisionMetrics.Event.Fields

  @stage_aliases %{
    "request" => :requested,
    "requested" => :requested,
    "decision_requested" => :requested,
    "answer_recorded" => :decided,
    "answered" => :decided,
    "decided" => :decided,
    "decision_recorded" => :decided,
    "dispatch_queued" => :dispatched,
    "dispatched" => :dispatched,
    "queued" => :dispatched,
    "delivered" => :delivered,
    "dispatch_delivered" => :delivered,
    "handed_off" => :delivered,
    "ack" => :acknowledged,
    "acknowledged" => :acknowledged,
    "resolved" => :resolved,
    "reminded" => :reminder,
    "reminder" => :reminder,
    "revised" => :revised,
    "revision_recorded" => :revised,
    "attention" => :attention
  }
  @implicit_stages %{"attention" => :attention, "requested" => :requested}

  @type fact :: %{
          stage: Aiur.DecisionMetrics.Sample.stage(),
          decision_id: String.t(),
          identifier: String.t(),
          event_id: String.t(),
          at: DateTime.t(),
          blocking: boolean() | nil,
          actor: String.t() | nil
        }

  @doc "Normalizes a Decision lifecycle event or ignores unrelated/uncorrelated events."
  @spec normalize(map(), DateTime.t()) :: {:ok, fact()} | :ignored
  def normalize(event, %DateTime{} = observed_at) when is_map(event) do
    event = Fields.stringify(event)
    topic = event["topic"]

    with stage when is_atom(stage) and not is_nil(stage) <- stage_for(event, topic),
         true <- trusted_stage?(stage, event),
         decision_id when is_binary(decision_id) <- decision_id(event),
         identifier when is_binary(identifier) <- Fields.identifier(event, topic),
         event_id when is_binary(event_id) <- Fields.event_id(event) do
      {:ok,
       %{
         stage: stage,
         decision_id: decision_id,
         identifier: identifier,
         event_id: event_id,
         at: Fields.event_time(event, stage, observed_at),
         blocking: Fields.value(event, ["blocking"]),
         actor: Fields.actor(event)
       }}
    else
      _other -> :ignored
    end
  end

  @doc "Returns legacy-attention topic correlation carried by a persisted request."
  @spec attention_correlation(map()) :: {String.t(), String.t()} | nil
  def attention_correlation(event) when is_map(event) do
    event = Fields.stringify(event)
    attention = event |> Fields.value(["legacy_attention"]) |> Fields.stringify()

    case {attention, decision_id(event)} do
      {%{"topic" => topic}, decision_id} when is_binary(topic) and is_binary(decision_id) ->
        {topic, decision_id}

      _other ->
        nil
    end
  end

  defp stage_for(event, topic) do
    explicit = event["event_type"] || event["event"] || event["type"]
    stage = stage_alias(explicit) || Map.get(@implicit_stages, topic_label(topic))

    if stage == :requested and revision?(event), do: :revised, else: stage
  end

  defp revision?(event) do
    version = Fields.value(event, ["decision_version", "version"])
    legacy_attention = Fields.value(event, ["legacy_attention"])
    is_integer(version) and version > 1 and is_nil(legacy_attention)
  end

  defp stage_alias(label), do: Map.get(@stage_aliases, normalize_label(label))

  defp trusted_stage?(:requested, event) do
    canonical_event?(event) or
      match?({:ok, %Decision{}}, DecisionProjection.decode_request_record(event))
  end

  defp trusted_stage?(:revised, event) do
    canonical_event?(event) or
      match?({:ok, %DecisionEvent{type: :revision_recorded}}, DecisionEvent.from_json_safe(event)) or
      match?({:ok, %Decision{}}, DecisionProjection.decode_request_record(event))
  end

  defp trusted_stage?(stage, event)
       when stage in [:decided, :dispatched, :delivered, :acknowledged, :resolved] do
    canonical_event?(event) or match?({:ok, %DecisionEvent{}}, DecisionEvent.from_json_safe(event))
  end

  defp trusted_stage?(_stage, _event), do: true

  defp canonical_event?(event) do
    case Fields.event_id(event) do
      "canonical:" <> _suffix -> true
      _other -> false
    end
  end

  defp topic_label(topic) when is_binary(topic) do
    cond do
      String.contains?(topic, ".decision.") -> topic |> String.split(".decision.", parts: 2) |> List.last()
      String.contains?(topic, ".attention.") and not String.ends_with?(topic, ".resolved") -> "attention"
      true -> nil
    end
  end

  defp topic_label(_topic), do: nil
  defp normalize_label(label) when is_atom(label), do: label |> Atom.to_string() |> normalize_label()

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.replace_prefix("decision_", "")
  end

  defp normalize_label(_label), do: nil

  defp decision_id(event), do: Fields.value(event, ["decision_id"])
end
