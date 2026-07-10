defmodule Aiur.AgentList.PerfIntake do
  @moduledoc """
  Folds debug performance events into AgentList state.
  """

  @warmth_event_cap 500

  @spec fold(map(), map()) :: {map(), boolean()}
  def fold(state, event) do
    perf_summary = update_perf_summary(state.perf_summary, event)
    warmth_events = absorb_warmth_event(state.warmth_events, event)
    {%{state | perf_summary: perf_summary, warmth_events: warmth_events}, perf_summary != state.perf_summary}
  end

  defp update_perf_summary(summary, %{phase: :agent_list_ready, meta: %{wall_ms: ms}}),
    do: %{summary | agent_list_ready_ms: ms}

  defp update_perf_summary(summary, %{phase: :placeholder_spawn_done, meta: %{wall_ms: ms}}),
    do: %{summary | chat_pane_visible_ms: ms}

  defp update_perf_summary(summary, %{phase: :convo_first_paint, meta: %{wall_ms: ms}}),
    do: %{summary | opencode_render_ms: ms}

  defp update_perf_summary(summary, _event), do: summary

  defp absorb_warmth_event(events, %{phase: phase, meta: meta, at_ms: at_ms})
       when phase in [:slot_attach_added, :slot_attach_removed, :slot_visible_changed] do
    [%{phase: phase, at_ms: at_ms, identifier: Map.get(meta, :identifier), slot: Map.get(meta, :slot)} | events]
    |> Enum.take(@warmth_event_cap)
  end

  defp absorb_warmth_event(events, _event), do: events
end
