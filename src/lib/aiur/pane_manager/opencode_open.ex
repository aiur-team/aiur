defmodule Aiur.PaneManager.OpencodeOpen do
  @moduledoc """
  Routes `handle_call({:open, ...})` to the right open strategy: generic
  panes go through GenericOpen; opencode panes go through the warm path
  (SlotRegistry ETS → AttachPool.consume) falling back to a placeholder.
  """

  require Logger

  alias Aiur.{AgentPubSub, Tmux}
  alias Aiur.Opencode.{AttachPool, SlotRegistry}
  alias Aiur.PaneManager.{ConvoPaint, GenericOpen, Layout, Placeholder, SlotAttach, State}

  @spec do_open(
          State.t(),
          State.agent_id(),
          String.t(),
          keyword(),
          GenServer.from() | nil
        ) ::
          {:reply, {:ok, State.pane_id()} | {:error, term()}, State.t()}
          | {:noreply, State.t()}
  def do_open(state, identifier, command_to_run, opts, from) do
    case command_to_run do
      "__aiur_opencode__ " <> _ -> open_opencode_pane(state, identifier, opts, from)
      _ -> GenericOpen.open_generic_pane(state, identifier, command_to_run, from)
    end
  end

  # opencode panes use the slot-bound model: each pane slot owns its own
  # opencode-serve + opencode-attach process for the lifetime of the
  # aiur run. Opening a pane = `SlotSupervisor.acquire_slot/0` +
  # `Slot.select/2` + `Tmux.move_pane_visible/2`. If no slot is :ready
  # (chain pre-warm hasn't reached one yet), fall back to the legacy
  # cold-attach path so the user never sees an error.
  @spec open_opencode_pane(
          State.t(),
          State.agent_id(),
          keyword(),
          GenServer.from() | nil
        ) ::
          {:reply, {:ok, State.pane_id()} | {:error, term()}, State.t()}
          | {:noreply, State.t()}
  def open_opencode_pane(state, identifier, _opts, from) do
    # LOCK-FREE FAST PATH: SlotRegistry's ETS table holds each slot's
    # current {visible_identifier, pane_id}. If a slot is already
    # painted as the leadoff for this identifier, we can move its pane
    # visible WITHOUT going through any GenServer mailbox (Slot's or
    # AttachPool's). Both can be wedged 5+s when fan-out is in flight,
    # and a synchronous consume call there times out into the
    # placeholder path — turning the "instant open" pre-warm path into
    # a 5-7 s cold spawn. We mirror the consumed state into AttachPool
    # asynchronously below so its bookkeeping (visible_in,
    # exclude_visible filtering for the NEXT open) stays accurate.
    case SlotRegistry.find_visible(identifier) do
      {:ok, slot_index, pane_id} ->
        Aiur.Perf.event(:warm_open_registry_hit,
          identifier: identifier,
          slot: slot_index,
          pane_id: pane_id
        )

        AttachPool.mark_visible(AttachPool, identifier, slot_index)
        move_warm_pane_visible(state, identifier, slot_index, pane_id, from)

      :not_found ->
        # Slow path: ask AttachPool to find any slot that has this
        # identifier attached (including non-leadoff slots) and drive
        # Slot.set_visible. Still bounded by GenServer mailbox depth,
        # but only reached when no slot has the identifier already
        # painted as its visible leadoff.
        #
        # Pass the slots whose panes are CURRENTLY IN WINDOW 0 (the
        # ones the user is actively looking at) so consume doesn't
        # hijack them when rebinding to a different identifier. Slots
        # whose panes are still in aiur-hidden (the boot-time case for
        # leadoffs) ARE valid candidates — the previous
        # `exclude_visible: true` filter excluded every leadoff slot
        # regardless of window, which made post-boot opens on a non-
        # leadoff agent always miss when every slot had a hidden-
        # window leadoff painted.
        # `slot_panes` is pre-seeded with `{slot => nil}` for every
        # slot index 1..slot_count regardless of whether a chat pane
        # is currently visible. Filter to slots with a non-nil pane_id —
        # those are the ones actually mounted in window 0 right now.
        visible_in_window_0 =
          state.slot_panes
          |> Enum.filter(fn {_slot, pane_id} -> is_binary(pane_id) end)
          |> Enum.map(fn {slot, _pane_id} -> slot end)
          |> MapSet.new()

        case AttachPool.consume(identifier, exclude_slots: visible_in_window_0) do
          {:ok, %{slot_index: slot_index, pane_id: pane_id}} ->
            Aiur.Perf.event(:attach_pool_consume_hit,
              identifier: identifier,
              slot: slot_index,
              pane_id: pane_id
            )

            move_warm_pane_visible(state, identifier, slot_index, pane_id, from)

          :miss ->
            Placeholder.open_with_placeholder(state, identifier, from)
        end
    end
  end

  # Warm path: an opencode-attach process is already booted in aiur-
  # hidden, bound to this identifier's session and painted. Move it
  # to window 0 and record bookkeeping. No placeholder, no respawn.
  @spec move_warm_pane_visible(
          State.t(),
          State.agent_id(),
          pos_integer(),
          State.pane_id(),
          GenServer.from() | nil
        ) ::
          {:reply, {:ok, State.pane_id()} | {:error, term()}, State.t()}
          | {:noreply, State.t()}
  def move_warm_pane_visible(state, identifier, slot_index, pane_id, from) do
    move_span = Aiur.Perf.span_begin(:pane_move_visible, pane_id: pane_id, source: :warm)

    case Tmux.move_pane_visible(state.tmux, pane_id, state.window_target) do
      :ok ->
        Aiur.Perf.span_end(move_span, result: :ok, pane_id: pane_id, source: :warm)

        new_state =
          state
          |> SlotAttach.record_slot_pane(slot_index, pane_id, identifier)
          |> Map.put(:last_attached_pane_id, pane_id)

        _ = Layout.apply(new_state)
        AgentPubSub.broadcast_status_change(identifier, :pane_opened)

        Aiur.Perf.event(:pane_open_visible_warm,
          identifier: identifier,
          slot: slot_index,
          pane_id: pane_id
        )

        SlotAttach.bump_next_slot()

        # Also fire the convo_first_paint detector — even on warm
        # path the convo content is already rendered, so it should
        # detect within the first poll (~100 ms). This keeps the
        # 3-row debug footer's "opencode render" number consistent
        # across warm and cold opens.
        pm = self()
        tmux = state.tmux

        Task.start(fn ->
          ConvoPaint.detect_convo_first_paint(pm, tmux, identifier, slot_index, pane_id)
        end)

        SlotAttach.reply_or_noreply({:ok, pane_id}, from, new_state)

      {:error, reason} ->
        if SlotAttach.pane_already_visible_reason?(reason) do
          Aiur.Perf.span_end(move_span,
            result: :already_visible,
            pane_id: pane_id,
            source: :warm
          )

          new_state =
            state
            |> SlotAttach.record_slot_pane(slot_index, pane_id, identifier)
            |> Map.put(:last_attached_pane_id, pane_id)

          AgentPubSub.broadcast_status_change(identifier, :pane_opened)

          Aiur.Perf.event(:pane_open_visible_warm,
            identifier: identifier,
            slot: slot_index,
            pane_id: pane_id,
            result: :already_visible
          )

          SlotAttach.bump_next_slot()
          SlotAttach.reply_or_noreply({:ok, pane_id}, from, new_state)
        else
          Aiur.Perf.span_end(move_span,
            result: :failed,
            pane_id: pane_id,
            source: :warm,
            reason: reason
          )

          Logger.warning("aiur_pane_manager phase=warm_move_failed identifier=#{identifier} pane_id=#{pane_id} reason=#{inspect(reason)} — falling back to cold open")

          Placeholder.open_with_placeholder(state, identifier, from)
        end
    end
  end
end
