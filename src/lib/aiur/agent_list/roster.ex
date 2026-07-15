defmodule Aiur.AgentList.Roster do
  @moduledoc """
  Fold for AgentList running-summary broadcasts.
  """

  alias Aiur.AgentList.{ActivityIntake, Selection, Summaries}
  alias Aiur.Events.SubscriptionStore

  @spec fold(map(), [map()]) :: {map(), [term()], [term()]}
  def fold(state, summaries) do
    summaries = Summaries.visible_summaries(summaries)
    selection_focus = if state.summaries == [] and summaries != [], do: :agents, else: state.selection_focus
    new_state = Selection.preserve_row(state, %{state | summaries: summaries, selection_focus: selection_focus})
    %{visible_ids: visible_ids, slot_ids: slot_ids, retain_ids: retain_ids} = Summaries.id_sets(summaries)
    visible_set = MapSet.new(Enum.map(visible_ids, &to_string/1))
    state = new_state |> put_visible_state(visible_set) |> ActivityIntake.reconcile()
    {state, slot_ids, retain_ids}
  end

  defp put_visible_state(state, visible_set) do
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
        # Activity presentation maps are rebuilt below from the daemon-owned
        # TicketActivity projection, joined through each summary's trusted
        # tracker identity. AgentList never seeds or folds activity itself.
        ticket_activity_presented: Map.take(state.ticket_activity_presented, visible_activity_keys(state, visible_set))
    }
  end

  defp refresh_open_attentions(active_set) do
    Enum.reduce(MapSet.to_list(active_set), %{}, fn id, acc ->
      Map.put(acc, id, SubscriptionStore.open_attention_count(id))
    end)
  end

  defp visible_activity_keys(state, visible_set) do
    state.summaries
    |> Enum.filter(&MapSet.member?(visible_set, to_string(Map.get(&1, :identifier))))
    |> Enum.map(&Aiur.TrackerIdentity.github_key(Map.get(&1, :tracker_identity)))
    |> Enum.reject(&is_nil/1)
  end
end
