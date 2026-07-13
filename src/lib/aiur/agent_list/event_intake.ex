defmodule Aiur.AgentList.EventIntake do
  @moduledoc """
  Pure fold for AgentList debug-log event intake.
  """

  # Cap on the in-memory debug-event ticker buffer. The renderer trims
  # further based on available pane height, but this stops unbounded
  # growth if the Executor leaves --debug on for hours.
  @debug_event_cap 200

  @spec fold(map(), map()) :: map()
  def fold(state, entry) do
    state =
      state
      |> record_latest_event(entry)
      |> record_progress_sample(entry)
      |> record_phase(entry)

    if state.debug_mode? do
      new_events = [entry | state.debug_events] |> Enum.take(@debug_event_cap)
      %{state | debug_events: new_events}
    else
      state
    end
  end

  # Map an `event_debug` entry onto the per-id `Latest` column store.
  # Only `:publish` advances the entry — `:receive` is a fan-out echo
  # of the same event the publisher already recorded, and `:read` is a
  # downstream marker that doesn't represent a new event landing on
  # the ticket. Topic shape is `ticket.<id>.<surface>.<verb>`; anything
  # else (system topics, etc.) is ignored.
  defp record_latest_event(state, %{kind: :publish, topic: topic, body: body})
       when is_binary(topic) do
    case extract_ticket_id(topic) do
      nil ->
        state

      id ->
        latest = %{
          topic: topic,
          message: event_message(topic, body),
          timestamp: DateTime.utc_now()
        }

        %{state | latest_event_by_id: Map.put(state.latest_event_by_id, id, latest)}
    end
  end

  defp record_latest_event(state, _entry), do: state

  defp extract_ticket_id("ticket." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [id, _] -> id
      _ -> nil
    end
  end

  defp extract_ticket_id(_), do: nil

  # Best-effort one-line message for the Latest column. Prefers an
  # explicit `:message` field on the event body; falls back to the
  # last verb segment of the topic (e.g. `branch.push` → `branch push`).
  defp event_message(topic, body) when is_map(body) do
    cond do
      is_binary(body[:message]) -> body[:message]
      is_binary(body["message"]) -> body["message"]
      true -> topic_verb(topic)
    end
  end

  defp event_message(topic, _body), do: topic_verb(topic)

  defp topic_verb(topic) do
    case String.split(topic, ".") do
      ["ticket", _id | rest] -> Enum.join(rest, " ")
      parts -> Enum.join(parts, " ")
    end
  end

  # Folds `ticket.<id>.agent.progress[.<source>]` publishes into the
  # per-id ProgressTracker sample ring with a source-aware ratchet:
  #
  #   - `agent.progress.checkin` (Executor-driven check-in) ALWAYS
  #     records — the agent's attested 1–10 estimate trumps prior
  #     phase guesses, even when it lowers the current value.
  #   - `agent.progress.phase` (phase boundary) and the bare
  #     `agent.progress` topic record only when `percent` is greater
  #     than or equal to the current head — phase guesses can ratchet
  #     up over an agent estimate (e.g. pr.opened → 100) but cannot
  #     drag it back down.
  defp record_progress_sample(state, %{kind: :publish, topic: topic, body: body})
       when is_binary(topic) and is_map(body) do
    with {:ok, id, source} <- parse_progress_topic(topic),
         percent when is_integer(percent) or is_float(percent) <- progress_percent(body) do
      maybe_push_progress(state, id, trunc(percent), source)
    else
      _ -> state
    end
  end

  defp record_progress_sample(state, _entry), do: state

  defp parse_progress_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.agent\.progress(?:\.(checkin|phase))?\z}, topic) do
      [_, id, "checkin"] -> {:ok, id, :checkin}
      [_, id, "phase"] -> {:ok, id, :phase}
      [_, id] -> {:ok, id, :phase}
      _ -> :error
    end
  end

  defp maybe_push_progress(state, id, percent, source) do
    existing = Map.get(state.progress_by_id, id, [])

    if accept_progress?(source, percent, existing) do
      now_ms = System.monotonic_time(:millisecond)
      updated = Aiur.ProgressTracker.record(existing, percent, now_ms)
      %{state | progress_by_id: Map.put(state.progress_by_id, id, updated)}
    else
      state
    end
  end

  defp accept_progress?(:checkin, _percent, _samples), do: true
  defp accept_progress?(:phase, percent, samples), do: percent >= head_percent(samples)

  defp head_percent([{percent, _ts} | _]) when is_integer(percent), do: percent
  defp head_percent(_), do: 0

  defp progress_percent(body) do
    cond do
      is_number(body[:percent]) -> body[:percent]
      is_number(body["percent"]) -> body["percent"]
      true -> nil
    end
  end

  # Folds `ticket.<id>.agent.phase.<phase>.<start|end>` publishes into
  # the per-id active-phase map that drives the running-state status
  # emoji (#68). `.start` sets the phase (last start wins); `.end`
  # clears it only when it matches the currently-tracked phase, so a
  # late `.end` for a superseded phase can't wipe a newer `.start`.
  defp record_phase(state, %{kind: :publish, topic: topic}) when is_binary(topic) do
    case parse_phase_topic(topic) do
      {:ok, id, phase, :start} ->
        %{state | phase_by_identifier: Map.put(state.phase_by_identifier, id, phase)}

      {:ok, id, phase, :end} ->
        if Map.get(state.phase_by_identifier, id) == phase do
          %{state | phase_by_identifier: Map.delete(state.phase_by_identifier, id)}
        else
          state
        end

      :error ->
        state
    end
  end

  defp record_phase(state, _entry), do: state

  defp parse_phase_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.agent\.phase\.(brainstorm|plan|work|review)\.(start|end)\z}, topic) do
      [_, id, phase, edge] -> {:ok, id, phase_atom(phase), edge_atom(edge)}
      _ -> :error
    end
  end

  defp phase_atom("brainstorm"), do: :brainstorm
  defp phase_atom("plan"), do: :plan
  defp phase_atom("work"), do: :work
  defp phase_atom("review"), do: :review

  defp edge_atom("start"), do: :start
  defp edge_atom("end"), do: :end
end
