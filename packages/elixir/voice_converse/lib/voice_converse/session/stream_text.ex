defmodule VoiceConverse.Session.StreamText do
  @moduledoc false
  alias VoiceConverse.{Events, Redact}
  alias VoiceConverse.Session.TextTiming

  @spec handle_and_broadcast(map(), term()) :: {:ok, map()} | {:error, map()}
  def handle_and_broadcast(state, %Events.Interruption{} = event) do
    {state, events} = flush_stream_text(state, event.turn_id)
    broadcast_events(state, events)
    handle_event(state, event)
  end

  def handle_and_broadcast(state, event), do: handle_event(state, event)

  defp handle_event(state, event) do
    case TextTiming.handle(state, event) do
      {:ok, state} ->
        {state, events} = broadcast_event(state, event)
        broadcast_events(state, events)
        {:ok, state}

      error ->
        error
    end
  end

  defp broadcast_event(state, %Events.Interruption{} = event), do: {state, [event]}

  defp broadcast_event(state, %Events.AgentText{} = event) do
    if not is_nil(state.interrupted_turn) do
      {state, [%{event | text: state.config.redactor.(event.text)}]}
    else
      {tails, events} = stream_text(state, event)
      {%{state | broadcast_tails: tails}, events}
    end
  end

  defp broadcast_event(state, event), do: {state, [TextTiming.redact_for_broadcast(event, state.config.redactor)]}

  defp broadcast_events(state, events),
    do: Enum.each(events, &state.event_broadcast.(state.subscribers, state.id, &1))

  defp stream_text(state, %Events.AgentText{} = event) do
    id = to_string(event.turn_id)
    previous = Map.get(state.broadcast_tails, id, "")

    if event.final? do
      final_event = %{event | text: state.config.redactor.(event.text)}

      tail_event =
        if previous == "",
          do: nil,
          else: %Events.AgentText{turn_id: event.turn_id, text: state.config.redactor.(previous), final?: false}

      {Map.delete(state.broadcast_tails, id), [tail_event, final_event] |> Enum.reject(&is_nil/1)}
    else
      {safe, tail} = split_safe_prefix(previous <> event.text)
      events = if safe == "", do: [], else: [%{event | text: state.config.redactor.(safe)}]
      {put_tail(state.broadcast_tails, id, tail), events}
    end
  end

  defp split_safe_prefix(text) do
    graphemes = String.graphemes(text)
    held = Redact.holdback(text)
    {Enum.take(graphemes, length(graphemes) - held) |> Enum.join(), Enum.take(graphemes, -held) |> Enum.join()}
  end

  defp put_tail(tails, id, ""), do: Map.delete(tails, id)
  defp put_tail(tails, id, tail), do: Map.put(tails, id, tail)

  defp flush_stream_text(state, id) do
    key = to_string(id)

    case Map.pop(state.broadcast_tails, key) do
      {nil, tails} ->
        {%{state | broadcast_tails: tails}, []}

      {tail, tails} ->
        {%{state | broadcast_tails: tails},
         [%Events.AgentText{turn_id: id, text: state.config.redactor.(tail), final?: false}]}
    end
  end

  @spec flush_all(map()) :: map()
  def flush_all(state) do
    Enum.reduce(Map.keys(state.broadcast_tails), state, fn id, state ->
      {state, events} = flush_stream_text(state, id)
      broadcast_events(state, events)
      state
    end)
  end

  @spec finish(map()) :: {:ok, map()} | {:error, map()}
  def finish(state), do: state |> flush_all() |> TextTiming.finish()
end
