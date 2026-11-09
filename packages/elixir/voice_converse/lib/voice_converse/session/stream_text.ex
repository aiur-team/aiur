defmodule VoiceConverse.Session.StreamText do
  @moduledoc false
  alias VoiceConverse.{Events, Redact}
  alias VoiceConverse.Session.TextTiming

  @spec handle_and_broadcast(map(), term()) :: {:ok, map()} | {:error, map()}
  def handle_and_broadcast(state, %Events.Interruption{} = event) do
    {state, events} = flush(state, event.turn_id)
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

  defp broadcast_event(state, %Events.AgentText{} = event), do: stream_text(state, event)

  defp broadcast_event(state, event), do: {state, [TextTiming.redact_for_broadcast(event, state.config.redactor)]}

  defp broadcast_events(state, events),
    do: Enum.each(events, &state.event_broadcast.(state.subscribers, state.id, &1))

  # Each partial re-redacts the whole turn so far, minus a tail that could still
  # grow into a match, and sends only the redacted text not yet sent. A secret
  # split across chunks, or still streaming after a complete match, stays masked.
  defp stream_text(state, %Events.AgentText{final?: true} = event) do
    {state, rest} = flush(state, event.turn_id)
    {state, rest ++ [%{event | text: state.config.redactor.(event.text)}]}
  end

  defp stream_text(state, %Events.AgentText{} = event) do
    key = to_string(event.turn_id)
    stream = Map.get(state.broadcast_streams, key, %{raw: "", sent: ""})
    {stream, text} = step(stream, event.text, state.config.redactor)
    {%{state | broadcast_streams: Map.put(state.broadcast_streams, key, stream)}, emit(event, text)}
  end

  @doc false
  # Pure stream step: appends `chunk` and returns the new masked text to send, or nil.
  @spec step(map(), String.t(), (String.t() -> String.t())) :: {map(), String.t() | nil}
  def step(%{raw: raw, sent: sent}, chunk, redactor) do
    raw = raw <> chunk
    safe = raw |> String.slice(0, String.length(raw) - Redact.holdback(raw)) |> redactor.()
    {sent, text} = unsent(sent, safe)
    {%{raw: raw, sent: sent}, text}
  end

  @doc false
  # Pure release of the held tail when the turn ends.
  @spec drain(map(), (String.t() -> String.t())) :: String.t() | nil
  def drain(%{raw: raw, sent: sent}, redactor), do: sent |> unsent(redactor.(raw)) |> elem(1)

  defp unsent(sent, redacted) do
    case redacted do
      ^sent -> {sent, nil}
      <<^sent::binary-size(byte_size(sent)), new::binary>> -> {redacted, new}
      # Redaction rewrote text already sent; the final event carries the full masked turn.
      _ -> {sent, nil}
    end
  end

  defp emit(_event, nil), do: []
  defp emit(event, text), do: [%{event | text: text}]

  defp flush(state, id) do
    case Map.pop(state.broadcast_streams, to_string(id)) do
      {nil, _} ->
        {state, []}

      {stream, streams} ->
        event = %Events.AgentText{turn_id: id, text: "", final?: false}
        {%{state | broadcast_streams: streams}, emit(event, drain(stream, state.config.redactor))}
    end
  end

  @spec flush_all(map()) :: map()
  def flush_all(state) do
    Enum.reduce(Map.keys(state.broadcast_streams), state, fn id, state ->
      {state, events} = flush(state, id)
      broadcast_events(state, events)
      state
    end)
  end

  @spec finish(map()) :: {:ok, map()} | {:error, map()}
  def finish(state), do: state |> flush_all() |> TextTiming.finish()
end
