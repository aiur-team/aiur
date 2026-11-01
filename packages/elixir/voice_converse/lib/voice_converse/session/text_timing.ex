defmodule VoiceConverse.Session.TextTiming do
  @moduledoc false
  require Logger
  alias VoiceConverse.{Events, TranscriptStore}
  alias VoiceConverse.Events.AgentTextTiming

  def handle(state, %Events.AgentText{turn_id: id, text: text, final?: final?}) do
    turn = turn(state, id)
    # Final AgentText is the complete turn, partial AgentText contains deltas.
    turn = %{turn | text: if(final?, do: text, else: turn.text <> text), final?: final?}
    state = put_turn(state, id, turn)

    if final? and state.config.providers.mode == :text,
      do: write(state, id, nil, false),
      else: {:ok, state}
  end

  def handle(state, %AgentTextTiming{turn_id: id} = event) do
    turn = turn(state, id)
    chars = if is_list(turn.chars) and is_list(event.chars), do: turn.chars ++ event.chars
    timed_text = turn.timed_text <> event.text
    turn = %{turn | timed_text: timed_text, chars: chars, audio?: true}
    {:ok, put_turn(state, id, turn)}
  end

  def handle(state, %Events.AgentAudio{turn_id: id}) do
    {:ok, put_turn(state, id, %{turn(state, id) | audio?: true})}
  end

  def handle(state, %Events.Interruption{turn_id: id}) do
    id = to_string(id)

    case Map.fetch(state.assistant_turns, id) do
      {:ok, %{written?: false}} ->
        token = make_ref()
        timer = state.schedule_after.(2_000, {:text_timing_grace, id, token})
        {:ok, %{state | interrupted_turn: {id, token, timer}}}

      _ ->
        {:ok, state}
    end
  end

  def playback(state, %{"state" => "stopped", "turn_id" => id} = frame) do
    case state.interrupted_turn do
      {^id, _, timer} ->
        VoiceConverse.Session.Runtime.cancel_timer(timer)
        played = Map.get(frame, "played_until_ms")
        provider_id = turn(state, id).provider_id

        {state, played} = maybe_truncate_provider(state, provider_id, played, id)

        with {:ok, state} <- write(state, id, played, true) do
          {:ok, resume(state)}
        end

      _ ->
        case Map.fetch(state.assistant_turns, id) do
          {:ok, %{final?: true}} -> write(state, id, nil, false)
          _ -> {:ok, state}
        end
    end
  end

  def playback(state, _frame), do: {:ok, state}

  def timeout(%{interrupted_turn: {id, token, _}} = state, id, token) do
    with {:ok, state} <- write(state, id, nil, true), do: {:ok, resume(state)}
  end

  def timeout(state, _id, _token), do: {:ok, state}

  def flush_before_user(state), do: flush(state, :user)
  def finish(state), do: flush(state, :finish)

  defp flush(state, reason) do
    Enum.reduce_while(state.assistant_turns, {:ok, state}, fn {id, turn}, {:ok, state} ->
      interrupted? =
        match?({^id, _, _}, state.interrupted_turn) or (reason == :user and not turn.final?)

      case write(state, id, nil, interrupted?) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    end)
  end

  defp resume(state) do
    Enum.each(Enum.reverse(state.timing_deferred), &send(self(), &1))
    %{state | interrupted_turn: nil, timing_deferred: []}
  end

  defp maybe_truncate_provider(state, provider_id, played, turn_id) do
    if is_integer(played) and not is_nil(state.provider_ref) and
         Map.get(state.provider.capabilities(), :manual_truncation, false) do
      case state.provider.truncate(state.provider_ref, provider_id, played) do
        :ok -> {state, played}
        {:error, reason} -> {record_truncation_error(state, turn_id, reason), nil}
        other -> {record_truncation_error(state, turn_id, {:unexpected_result, other}), nil}
      end
    else
      {state, played}
    end
  end

  defp record_truncation_error(state, turn_id, reason) do
    Logger.warning("Voice provider truncation failed for turn #{turn_id}: #{inspect(reason)}")

    record = %{
      type: "provider_truncation_error",
      turn_id: turn_id,
      error: inspect(reason),
      at: DateTime.to_iso8601(state.clock.())
    }

    case TranscriptStore.append(state.store, record) do
      :ok ->
        state

      {:error, append_reason} ->
        Logger.warning("Could not record voice provider truncation failure: #{inspect(append_reason)}")

        state
    end
  end

  defp turn(state, id) do
    Map.get(state.assistant_turns, to_string(id), %{
      text: "",
      timed_text: "",
      chars: [],
      audio?: false,
      final?: false,
      written?: false
    })
  end

  defp put_turn(state, id, turn),
    do: put_in(state.assistant_turns[to_string(id)], Map.put_new(turn, :provider_id, id))

  defp write(state, id, played, interrupted?) do
    turn = turn(state, id)

    if turn.written? or (turn.text == "" and turn.timed_text == "") do
      {:ok, state}
    else
      text = if turn.text == "", do: turn.timed_text, else: turn.text
      spans = if turn.timed_text == text and turn.chars != [], do: turn.chars

      text =
        if is_integer(played), do: AgentTextTiming.heard_prefix(text, spans, played), else: text

      record = %{
        type: "assistant_turn",
        turn_id: to_string(id),
        text: state.config.redactor.(text),
        at: DateTime.to_iso8601(state.clock.())
      }

      record = if interrupted?, do: Map.put(record, :interrupted?, true), else: record

      case TranscriptStore.append(state.store, record) do
        :ok -> {:ok, put_turn(state, id, %{turn | written?: true})}
        {:error, _} -> {:error, state}
      end
    end
  end
end
