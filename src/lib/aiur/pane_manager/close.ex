defmodule Aiur.PaneManager.Close do
  @moduledoc """
  Handles closing and hiding conversation panes. Differentiates between
  hide (move to hidden window, slot keeps its identifier binding) and
  close (hide + deselect the slot so it frees up for the next agent).
  """

  require Logger

  alias Aiur.{Boot, Tmux}
  alias Aiur.Opencode.{HiddenWindow, Slot, SlotRegistry}
  alias Aiur.AgentPubSub
  alias Aiur.PaneManager.{Layout, Reconcile, State}

  @spec hide_slot_pane(State.t(), State.agent_id(), State.pane_id()) ::
          {:reply, :ok | {:error, term()}, State.t()}
  def hide_slot_pane(state, identifier, pane_id) do
    case slot_for_pane(state, pane_id) do
      {:ok, slot_index, _slot_pid} ->
        hidden_window = HiddenWindow.window_name()

        case Tmux.move_pane_hidden(state.tmux, pane_id, hidden_window) do
          :ok ->
            new_state = State.forget_pane_by_identifier(state, pane_id)
            _ = Layout.apply(new_state)
            AgentPubSub.broadcast_status_change(identifier, :pane_closed)
            Reconcile.refocus_agent_list_if_focused(new_state, pane_id)

            Logger.info("aiur_pane_manager phase=hide_pane elapsed_ms=#{Boot.elapsed_ms()} identifier=#{identifier} slot=#{slot_index} pane_id=#{pane_id}")

            Aiur.Perf.event(:pane_hide, identifier: identifier, slot: slot_index, pane_id: pane_id)

            {:reply, :ok, new_state}

          {:error, reason} ->
            Logger.warning("aiur_pane_manager phase=hide_pane_failed identifier=#{identifier} pane_id=#{pane_id} reason=#{inspect(reason)}")

            {:reply, {:error, reason}, state}
        end

      :not_found ->
        {:reply, {:error, :not_slot_pane}, state}
    end
  end

  @spec close_opencode_or_generic(State.t(), State.agent_id(), State.pane_id()) ::
          {:reply, :ok, State.t()}
  def close_opencode_or_generic(state, identifier, pane_id) do
    # If this pane is currently owned by a slot worker, hide it (move to
    # the hidden warm window) and deselect the slot so the slot can
    # accept the next agent. Otherwise it's a generic pane — kill it.
    case slot_for_pane(state, pane_id) do
      {:ok, slot_index, slot_pid} ->
        hidden_window = HiddenWindow.window_name()

        case Tmux.move_pane_hidden(state.tmux, pane_id, hidden_window) do
          :ok ->
            :ok = Slot.deselect(slot_pid)
            new_state = State.forget_pane_by_identifier(state, pane_id)
            _ = Layout.apply(new_state)

            # Broadcast so the agent list drops 🟢 back to ⚪/🔘.
            # All three close paths (tmux-driven dies via
            # `handle_pane_closed/2`, reconcile drops via
            # `release_stale_visible_pane/2`, user-initiated hide here)
            # broadcast the same signal so the renderer stays in sync.
            AgentPubSub.broadcast_status_change(identifier, :pane_closed)

            Logger.info("aiur_pane_manager phase=close_hide elapsed_ms=#{Boot.elapsed_ms()} identifier=#{identifier} slot=#{slot_index} pane_id=#{pane_id}")

            {:reply, :ok, new_state}

          {:error, reason} ->
            Logger.warning("aiur_pane_manager phase=close_hide_failed identifier=#{identifier} slot=#{slot_index} pane_id=#{pane_id} reason=#{inspect(reason)}")

            # Fallback: tell the slot to deselect so it isn't wedged, and
            # leave the pane in place — user can retry close.
            _ = Slot.deselect(slot_pid)
            {:reply, :ok, state}
        end

      :not_found ->
        # Generic (non-opencode) pane — kill behavior.
        _ = Tmux.command(state.tmux, "kill-pane -t #{pane_id}")
        new_state = State.forget_pane_by_identifier(state, pane_id)
        _ = Layout.apply(new_state)
        {:reply, :ok, new_state}
    end
  end

  # Resolve which slot worker (if any) owns the given pane_id. Looks up
  # every alive slot in SlotRegistry and asks for its snapshot.
  defp slot_for_pane(_state, pane_id) do
    SlotRegistry.all()
    |> Enum.find_value(:not_found, fn {slot_index, slot_pid} ->
      case Slot.snapshot(slot_pid) do
        %{pane_id: ^pane_id} -> {:ok, slot_index, slot_pid}
        _ -> nil
      end
    end)
  end
end
