defmodule Aiur.AgentList.WarmthIntake do
  @moduledoc """
  Folds chat, pane, and pre-warm marker events into AgentList state.
  """

  @spec fold(map(), tuple()) :: {map(), boolean()}
  def fold(state, {:agent_chat_active, identifier}) when is_binary(identifier) do
    if MapSet.member?(state.agents_with_content, identifier) do
      {state, false}
    else
      {%{state | agents_with_content: MapSet.put(state.agents_with_content, identifier)}, true}
    end
  end

  def fold(state, {:status_changed, %{identifier: id, status: :pane_opened}}) do
    {%{state | opened_panes: MapSet.put(state.opened_panes, to_string(id))}, true}
  end

  def fold(state, {:status_changed, %{identifier: id, status: :pane_closed}}) do
    {%{state | opened_panes: MapSet.delete(state.opened_panes, to_string(id))}, true}
  end

  def fold(state, {:slot_session_changed, slot_index, identifier}) when is_integer(slot_index),
    do: put_visible_session(state, slot_index, identifier)

  def fold(state, {:slot_visible_changed, slot_index, identifier}),
    do: put_visible_session(state, slot_index, identifier)

  def fold(state, {kind, slot_index}) when kind in [:slot_ready, :slot_starting] and is_integer(slot_index) do
    {%{state | started_slots: MapSet.put(state.started_slots, slot_index)}, true}
  end

  def fold(state, {:attach_state_changed, identifier, attach_count, visible_in}) do
    {%{state | attach_state: Map.put(state.attach_state, identifier, %{attach_count: attach_count, visible_in: visible_in})}, true}
  end

  def fold(state, {:slot_fully_warmed, slot_index}) do
    {%{state | fully_warmed_slots: MapSet.put(state.fully_warmed_slots, slot_index)}, true}
  end

  def fold(state, {:slot_warmth_dropped, slot_index}) do
    {%{state | fully_warmed_slots: MapSet.delete(state.fully_warmed_slots, slot_index)}, true}
  end

  def fold(state, _event), do: {state, false}

  defp put_visible_session(state, slot_index, nil) do
    {%{state | visible_sessions: Map.delete(state.visible_sessions, slot_index)}, true}
  end

  defp put_visible_session(state, slot_index, identifier) when is_binary(identifier) do
    {%{state | visible_sessions: Map.put(state.visible_sessions, slot_index, identifier)}, true}
  end
end
