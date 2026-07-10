defmodule Aiur.PaneManager.SlotAttach do
  @moduledoc """
  Drives slot acquisition + tmux pane movement + state bookkeeping for
  the warm open and queue-drain paths. Also owns the "attach focused"
  rebind path (R4.2: pressing Enter with an existing pane focused).
  """

  require Logger

  alias Aiur.{AgentPubSub, Boot, Tmux}
  alias Aiur.Opencode.{Slot, SlotPolicy, SlotRegistry}
  alias Aiur.PaneManager.{Layout, State}

  # Drive a ready slot through select + tmux move + state record. Single
  # success/error reply path — returns `{:reply, ...}` or `{:noreply, ...}`
  # the way `handle_call({:open, ...})` expects when given an explicit
  # `from` of `nil` (the queue-drain case re-replies via `GenServer.reply`).
  @spec attach_identifier_to_slot(
          State.t(),
          State.agent_id(),
          pos_integer(),
          pid(),
          GenServer.from() | nil
        ) ::
          {:reply, {:ok, State.pane_id()} | {:error, term()}, State.t()}
          | {:noreply, State.t()}
  def attach_identifier_to_slot(state, identifier, slot_index, slot_pid, from) do
    started_at = System.monotonic_time(:millisecond)
    select_span = Aiur.Perf.span_begin(:slot_select, slot: slot_index, identifier: identifier)

    case Slot.select(slot_pid, identifier) do
      {:ok, pane_id} ->
        Aiur.Perf.span_end(select_span,
          result: :ok,
          slot: slot_index,
          identifier: identifier,
          pane_id: pane_id
        )

        move_span = Aiur.Perf.span_begin(:pane_move_visible, pane_id: pane_id)

        case Tmux.move_pane_visible(state.tmux, pane_id, state.window_target) do
          :ok ->
            Aiur.Perf.span_end(move_span, result: :ok, pane_id: pane_id)

            new_state =
              state
              |> record_slot_pane(slot_index, pane_id, identifier)
              |> Map.put(:last_attached_pane_id, pane_id)

            _ = Layout.apply(new_state)
            AgentPubSub.broadcast_status_change(identifier, :pane_opened)

            open_ms = System.monotonic_time(:millisecond) - started_at

            Logger.info("aiur_pane_manager phase=open_visible elapsed_ms=#{Boot.elapsed_ms()} open_ms=#{open_ms} identifier=#{identifier} slot=#{slot_index} pane_id=#{pane_id}")

            Aiur.Perf.event(:pane_open_visible,
              identifier: identifier,
              slot: slot_index,
              pane_id: pane_id,
              wall_ms: open_ms
            )

            bump_next_slot()
            reply_or_noreply({:ok, pane_id}, from, new_state)

          {:error, reason} ->
            handle_pane_move_error(reason, state, slot_index, slot_pid, identifier, pane_id, from)
        end

      {:error, reason} ->
        Logger.warning("aiur_pane_manager phase=open_select_failed identifier=#{identifier} slot=#{slot_index} reason=#{inspect(reason)}")

        reply_or_noreply({:error, reason}, from, state)
    end
  end

  defp handle_pane_move_error(reason, state, slot_index, slot_pid, identifier, pane_id, from) do
    if pane_already_visible_reason?(reason) do
      # tmux refused to move because the slot's attach pane is already
      # in the visible window. Treat as success: record the new
      # (identifier, pane_id) and leave the slot's visible_identifier
      # intact.
      new_state =
        state
        |> record_slot_pane(slot_index, pane_id, identifier)
        |> Map.put(:last_attached_pane_id, pane_id)

      AgentPubSub.broadcast_status_change(identifier, :pane_opened)
      bump_next_slot()
      reply_or_noreply({:ok, pane_id}, from, new_state)
    else
      Logger.warning("aiur_pane_manager phase=open_move_failed identifier=#{identifier} slot=#{slot_index} reason=#{inspect(reason)}")

      _ = Slot.deselect(slot_pid)
      reply_or_noreply({:error, reason}, from, state)
    end
  end

  @spec pane_already_visible_reason?(term()) :: boolean()
  def pane_already_visible_reason?(reason) do
    text =
      case reason do
        {_code, msg} when is_binary(msg) -> msg
        msg when is_binary(msg) -> msg
        _ -> inspect(reason)
      end

    String.contains?(text, "source and target panes must be different")
  end

  # Rebind the focused pane's slot to a new agent identifier. The slot's
  # `Slot.select/2` triggers the incremental rebuild path (U3) for any
  # identifier not already in the slot's known set, so the user can
  # cycle the same pane through many agents without spawning new tmux
  # panes. The previously-shown agent's SessionWriter stays alive
  # (identifier-keyed in `SessionWriterRegistry`); the user can attach
  # it back any time.
  @spec attach_to_focused_pane(State.t(), State.agent_id(), GenServer.from()) ::
          {:reply, {:ok, State.pane_id()} | {:error, term()}, State.t()}
          | {:noreply, State.t()}
  def attach_to_focused_pane(state, identifier, from) do
    pane_id = state.last_attached_pane_id

    case Map.fetch(state.pane_to_slot, pane_id) do
      :error ->
        # last_attached_pane_id points at a pane PaneManager no longer
        # tracks (closed, died). Clear the pointer and fall through.
        new_state = %{state | last_attached_pane_id: nil}
        {:reply, {:error, :no_focused_pane}, new_state}

      {:ok, slot_index} ->
        case SlotRegistry.lookup(slot_index) do
          {:ok, slot_pid} ->
            # Drop the old identifier→pane mapping so the new identifier
            # can claim it. Slot.set_visible always respawns
            # opencode-attach with `--session <id>`, so
            # respawn_attach_with_session kills the old pane itself
            # before splitting a new one.
            new_state = State.forget_identifier_for_pane(state, pane_id)
            attach_identifier_to_slot(new_state, identifier, slot_index, slot_pid, from)

          :not_found ->
            new_state = %{state | last_attached_pane_id: nil}
            {:reply, {:error, :no_focused_pane}, new_state}
        end
    end
  end

  @spec reply_or_noreply(
          {:ok, State.pane_id()} | {:error, term()},
          GenServer.from() | nil,
          State.t()
        ) :: {:reply, term(), State.t()} | {:noreply, State.t()}
  def reply_or_noreply(result, nil = _from, new_state), do: {:reply, result, new_state}

  def reply_or_noreply(result, from, new_state) do
    GenServer.reply(from, result)
    {:noreply, new_state}
  end

  @spec bump_next_slot() :: :ok
  def bump_next_slot do
    SlotPolicy.bump()
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # State bookkeeping --------------------------------------------------------

  @spec record_slot_pane(State.t(), pos_integer(), State.pane_id(), State.agent_id()) :: State.t()
  def record_slot_pane(state, slot, pane_id, identifier) do
    new_state = State.record_slot_pane(state, slot, pane_id, identifier)
    set_pane_title(new_state, pane_id, identifier)
    new_state
  end

  # Best-effort: set the pane's tmux title to "<id> <issue title>" so the
  # configured `pane-border-format` names the agent each pane holds. The
  # format truncates to the pane width with an ellipsis, so we always set the
  # full title and let tmux clip per pane size (and re-clip on resize). A
  # failed title set never blocks the open/swap that triggered it.
  @spec set_pane_title(State.t(), State.pane_id(), State.agent_id()) :: :ok
  def set_pane_title(state, pane_id, identifier) do
    _ = Tmux.set_pane_title(state.tmux, pane_id, State.pane_title_text(state, identifier))
    :ok
  end
end
