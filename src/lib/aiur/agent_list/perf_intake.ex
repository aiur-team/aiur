defmodule Aiur.AgentList.PerfIntake do
  @moduledoc """
  Folds debug performance events into AgentList state and reports whether the
  compact three-row footer changed, so debug-only warmth events do not render.
  """

  @warmth_event_cap 500

  @spec fold(map(), map()) :: {map(), boolean()}
  def fold(state, event) do
    perf_summary = update_perf_summary(state.perf_summary, event)
    warmth_events = absorb_warmth_event(state.warmth_events, event)
    {%{state | perf_summary: perf_summary, warmth_events: warmth_events}, perf_summary != state.perf_summary}
  end

  # Pull the three milestones the debug footer cares about out of the
  # aiur_perf stream. Everything else is ignored — the user asked for
  # a compact 3-row footer, not a rolling event log.
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
