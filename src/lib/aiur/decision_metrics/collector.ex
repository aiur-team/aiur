defmodule Aiur.DecisionMetrics.Collector do
  @moduledoc "Pure event-correlation and bounded projection transitions for Decision metrics."

  alias Aiur.DecisionMetrics.{Event, Log, Sample, Window, Writer}

  @spec record(map(), map()) :: {:ok | :duplicate | :ignored, map()}
  def record(event, state) do
    state = index_attention(event, state)
    event = correlate_attention(event, state.attention_index)
    observed_at = state.clock.()

    with {:ok, fact} <- Event.normalize(event, observed_at),
         false <- Window.member?(state.seen, fact.event_id) do
      sample = Map.get(state.samples, fact.decision_id, Sample.new(fact.decision_id, fact.identifier))
      updated = Sample.observe(sample, fact.stage, fact)
      Writer.persist(Log.record(updated, fact, observed_at), state.writer)

      next_state =
        state
        |> Map.update!(:samples, &Map.put(&1, fact.decision_id, updated))
        |> Map.update!(:seen, &Window.put(&1, fact.event_id))
        |> bound()

      {:ok, next_state}
    else
      true -> {:duplicate, state}
      :ignored -> {:ignored, state}
    end
  end

  @spec seed([map()], map(), map()) :: map()
  def seed(events, index, state) do
    state = %{state | attention_index: Map.merge(index, state.attention_index)}

    events
    |> Enum.reduce(state, fn event, acc -> elem(record(event, acc), 1) end)
    |> bound()
  end

  @spec bound(map()) :: map()
  def bound(state) do
    {samples, retained_ids} = Window.recent(state.samples, state.sample_limit)
    retained_set = MapSet.new(retained_ids)

    %{
      state
      | samples: samples,
        attention_index:
          Map.filter(state.attention_index, fn {_topic, decision_id} ->
            MapSet.member?(retained_set, decision_id)
          end)
    }
  end

  defp index_attention(event, state) do
    case Event.attention_correlation(event) do
      {topic, decision_id} ->
        %{state | attention_index: Map.put(state.attention_index, topic, decision_id)}

      nil ->
        state
    end
  end

  defp correlate_attention(event, index) do
    topic = event_value(event, :topic)

    if attention_topic?(topic) and is_nil(event_value(event, :decision_id)) do
      case Map.get(index, topic) do
        nil -> event
        decision_id -> put_event_value(event, :decision_id, decision_id)
      end
    else
      event
    end
  end

  defp attention_topic?(topic) when is_binary(topic) do
    String.contains?(topic, ".agent.attention.") and not String.ends_with?(topic, ".resolved")
  end

  defp attention_topic?(_topic), do: false
  defp event_value(event, key), do: Map.get(event, key, Map.get(event, Atom.to_string(key)))

  defp put_event_value(event, key, value) do
    if Map.has_key?(event, Atom.to_string(key)),
      do: Map.put(event, Atom.to_string(key), value),
      else: Map.put(event, key, value)
  end
end
