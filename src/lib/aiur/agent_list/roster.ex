defmodule Aiur.AgentList.Roster do
  @moduledoc """
  Fold for AgentList running-summary broadcasts.
  """

  alias Aiur.AgentList.{Selection, Summaries}
  alias Aiur.Events.SubscriptionStore

  @spec fold(map(), [map()]) :: {map(), [term()], [term()]}
  def fold(state, summaries) do
    summaries = Summaries.visible_summaries(summaries)
    selection_focus = if state.summaries == [] and summaries != [], do: :agents, else: state.selection_focus
    new_state = Selection.clamp_selection(%{state | summaries: summaries, selection_focus: selection_focus})
    %{visible_ids: visible_ids, slot_ids: slot_ids, retain_ids: retain_ids} = Summaries.id_sets(summaries)
    visible_set = MapSet.new(Enum.map(visible_ids, &to_string/1))
    progress_by_id = compact_and_seed_progress(new_state, visible_set, summaries)
    {put_visible_state(new_state, visible_set, progress_by_id), slot_ids, retain_ids}
  end

  defp compact_and_seed_progress(state, visible_set, summaries) do
    # Seed a synthetic (100, now) progress sample for every
    # `:deactivated` summary that doesn't already have a 100-percent
    # head. Covers two cases:
    #   - Live `:working → :deactivated` transitions where the agent
    #     never emitted a 100% sample (U1's prompt fixes this going
    #     forward, but pre-U1 agents and complexity:1 fast-paths may
    #     still flip the label without an explicit emit).
    #   - Boot-revived `:deactivated` entries (U6) that have never
    #     emitted any progress samples at all.
    seed_deactivated_progress_samples(
      Map.take(state.progress_by_id, MapSet.to_list(visible_set)),
      summaries
    )
  end

  defp put_visible_state(state, visible_set, progress_by_id) do
    %{
      state
      | # Trim `agents_with_content` so a stopped agent doesn't keep
        # its ⚪ glyph if it returns later — it'll re-earn ⚪ on the
        # next transcript event after re-dispatch. Use visible_set so
        # `:deactivated` rows preserve the ⚪ glyph they earned while
        # working.
        agents_with_content: MapSet.intersection(state.agents_with_content, visible_set),
        # Refresh the `❗` counts from SubscriptionStore on every
        # running_changed — agents come and go infrequently enough
        # that polling here beats threading a separate broadcast
        # through the attention-emit path.
        open_attentions_by_id: refresh_open_attentions(visible_set),
        # Trim Latest column entries to visible_set so `:deactivated`
        # rows keep their most-recent event message; a stale entry for
        # an id that's no longer running just wastes row space and is
        # misleading.
        latest_event_by_id: Map.take(state.latest_event_by_id, MapSet.to_list(visible_set)),
        # Trim active-phase entries to visible_set so a stopped agent's
        # last phase doesn't linger on a row it no longer owns.
        phase_by_identifier: Map.take(state.phase_by_identifier, MapSet.to_list(visible_set)),
        progress_by_id: progress_by_id
    }
  end

  defp refresh_open_attentions(active_set) do
    Enum.reduce(MapSet.to_list(active_set), %{}, fn id, acc ->
      case attention_count_for(id) do
        n when is_integer(n) -> Map.put(acc, id, n)
        _ -> acc
      end
    end)
  end

  defp attention_count_for(id) do
    case SubscriptionStore.snapshot(id) do
      %{open_attentions: list} when is_list(list) -> length(list)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  # For each `:deactivated` summary, ensure its `progress_by_id` ring
  # contains a 100-percent sample as the head. Inserts via
  # `Aiur.ProgressTracker.record/3`, which dedups by monotonic time —
  # repeated insertions of the same 100 sample do not accumulate.
  defp seed_deactivated_progress_samples(progress_by_id, summaries) do
    now_ms = System.monotonic_time(:millisecond)

    Enum.reduce(summaries, progress_by_id, fn summary, acc ->
      maybe_seed_deactivated_sample(summary, acc, now_ms)
    end)
  end

  defp maybe_seed_deactivated_sample(summary, progress_by_id, now_ms) do
    id = Map.get(summary, :identifier)

    cond do
      not Summaries.deactivated?(summary) ->
        progress_by_id

      not is_binary(id) ->
        progress_by_id

      head_at_100?(Map.get(progress_by_id, id)) ->
        progress_by_id

      true ->
        existing = Map.get(progress_by_id, id, [])
        updated = Aiur.ProgressTracker.record(existing, 100, now_ms)
        Map.put(progress_by_id, id, updated)
    end
  end

  defp head_at_100?([{100, _ts} | _]), do: true
  defp head_at_100?(_), do: false
end
