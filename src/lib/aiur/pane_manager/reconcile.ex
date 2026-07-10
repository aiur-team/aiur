defmodule Aiur.PaneManager.Reconcile do
  @moduledoc """
  Handles pane-died events and reconciles the visible pane set against
  the live tmux window, cleaning up stale tracked panes and placeholders.
  """

  require Logger

  alias Aiur.{AgentPubSub, Tmux}
  alias Aiur.Opencode.{Slot, SlotRegistry}
  alias Aiur.PaneManager.{Layout, State}

  @spec handle_pane_closed(State.t(), State.pane_id()) :: State.t()
  def handle_pane_closed(state, pane_id) do
    case Map.fetch(state.pane_to_identifier, pane_id) do
      {:ok, identifier} ->
        AgentPubSub.broadcast_status_change(identifier, :pane_closed)
        new_state = State.forget_pane_by_identifier(state, pane_id)
        _ = Layout.apply(new_state)
        refocus_agent_list_if_focused(new_state, pane_id)

      :error ->
        # Unknown pane (could be the agent-list pane itself, a loading
        # placeholder, or a transient probe). Still clear any stale slot
        # or placeholder mapping.
        new_state =
          state
          |> State.forget_pane_by_identifier(pane_id)
          |> State.drop_placeholder_by_pane(pane_id)

        _ = Layout.apply(new_state)
        refocus_agent_list_if_focused(new_state, pane_id)
    end
  end

  @spec reconcile_visible_panes(State.t()) :: State.t()
  def reconcile_visible_panes(%State{} = state) do
    if map_size(state.pane_to_identifier) == 0 and map_size(state.placeholder_panes) == 0 do
      state
    else
      case Tmux.list_panes(state.tmux, state.window_target) do
        {:ok, pane_ids} ->
          live_panes = MapSet.new(pane_ids)

          state
          |> drop_stale_tracked_panes(live_panes)
          |> drop_stale_placeholders(live_panes)

        {:error, reason} ->
          Logger.warning("aiur_pane_manager phase=reconcile_failed window=#{state.window_target} reason=#{inspect(reason)}")
          state
      end
    end
  end

  @spec refocus_agent_list_if_focused(State.t(), State.pane_id()) :: State.t()
  def refocus_agent_list_if_focused(state, closed_pane_id) do
    if closed_pane_id == state.last_attached_pane_id do
      _ = Tmux.command(state.tmux, "select-pane -t #{state.agent_list_pane}")
      %{state | last_attached_pane_id: nil}
    else
      state
    end
  end

  defp drop_stale_tracked_panes(state, live_panes) do
    state.pane_to_identifier
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(live_panes, &1))
    |> Enum.reduce(state, fn pane_id, acc -> release_stale_visible_pane(acc, pane_id) end)
  end

  defp release_stale_visible_pane(state, pane_id) do
    identifier = Map.get(state.pane_to_identifier, pane_id)
    slot = Map.get(state.pane_to_slot, pane_id)

    if is_integer(slot) do
      case SlotRegistry.lookup(slot) do
        {:ok, slot_pid} -> Slot.deselect(slot_pid)
        :not_found -> :ok
      end
    end

    if is_binary(identifier), do: AgentPubSub.broadcast_status_change(identifier, :pane_closed)

    Logger.info("aiur_pane_manager phase=reconcile_drop_stale_pane identifier=#{identifier} slot=#{slot} pane_id=#{pane_id}")

    state
    |> State.forget_pane_by_identifier(pane_id)
    |> refocus_agent_list_if_focused(pane_id)
  end

  defp drop_stale_placeholders(state, live_panes) do
    state.placeholder_panes
    |> Enum.reject(fn {_identifier, %{pane_id: pane_id}} -> MapSet.member?(live_panes, pane_id) end)
    |> Enum.reduce(state, fn {identifier, %{pane_id: pane_id, slot: slot}}, acc ->
      Logger.info("aiur_pane_manager phase=reconcile_drop_stale_placeholder identifier=#{identifier} slot=#{slot} pane_id=#{pane_id}")
      State.drop_placeholder(acc, identifier)
    end)
  end
end
