defmodule Aiur.PaneManager.Placeholder do
  @moduledoc """
  Drives the instant-placeholder open path: spawns a visible loading pane
  immediately, then acquires a slot and swaps the real attach pane in
  asynchronously. Also owns the queue-enqueue fallback when no slot is
  ready and no placeholder could be spawned.
  """

  require Logger

  alias Aiur.{AgentPubSub, Boot, Tmux}
  alias Aiur.Opencode.{Slot, SlotSupervisor}
  alias Aiur.PaneManager.{ConvoPaint, Layout, OpenQueue, SlotAttach, State}

  @spec open_with_placeholder(State.t(), State.agent_id(), GenServer.from()) ::
          {:noreply, State.t()} | {:reply, {:error, term()}, State.t()}
  def open_with_placeholder(state, identifier, from) do
    # INSTANT placeholder: spawn a visible pane with a loading message
    # in window 0 RIGHT NOW. The user sees a pane appear in < 100 ms
    # regardless of opencode-serve readiness. The real attach pane is
    # built asynchronously and swapped in when ready.
    placeholder_span = Aiur.Perf.span_begin(:placeholder_spawn, identifier: identifier)
    visual_slot = State.first_available_visual_slot(state) || state.slot_count

    case spawn_placeholder_pane(state, identifier) do
      {:ok, placeholder_pane_id} ->
        Aiur.Perf.span_end(placeholder_span,
          identifier: identifier,
          pane_id: placeholder_pane_id
        )

        Aiur.Perf.event(:placeholder_visible,
          identifier: identifier,
          pane_id: placeholder_pane_id
        )

        new_state =
          state
          |> record_placeholder(identifier, placeholder_pane_id, visual_slot)

        _ = Layout.apply(new_state)

        # Reply to the caller (AgentList Task) after the placeholder
        # has been assigned to the balanced visual grid.
        GenServer.reply(from, {:ok, placeholder_pane_id})

        # Async: acquire slot + select + swap real attach into the
        # placeholder's spot. The Task sends back a :placeholder_swap
        # message PaneManager handles via handle_info.
        pm = self()

        Task.start(fn -> drive_real_attach(pm, identifier, placeholder_pane_id) end)

        {:noreply, new_state}

      {:error, reason} ->
        Aiur.Perf.span_end(placeholder_span,
          result: :failed,
          identifier: identifier,
          reason: reason
        )

        Logger.warning("aiur_pane_manager phase=placeholder_spawn_failed identifier=#{identifier} reason=#{inspect(reason)}")

        # Fall back to the synchronous open path (pre-U3 behavior) so
        # we never hard-fail a user open just because tmux split-window
        # blipped.
        acquire_span = Aiur.Perf.span_begin(:acquire_slot, identifier: identifier)

        case SlotSupervisor.acquire_slot_or_grow() do
          {slot_index, slot_pid} when is_integer(slot_index) ->
            Aiur.Perf.span_end(acquire_span,
              result: :ok,
              slot: slot_index,
              identifier: identifier
            )

            SlotAttach.attach_identifier_to_slot(state, identifier, slot_index, slot_pid, from)

          {:error, :no_ready_slot} ->
            Aiur.Perf.span_end(acquire_span, result: :no_ready_slot, identifier: identifier)
            enqueue_open(state, identifier, from)
        end
    end
  end

  @spec handle_swap(
          State.t(),
          State.agent_id(),
          State.pane_id(),
          pos_integer(),
          State.pane_id()
        ) :: {:noreply, State.t()}
  def handle_swap(state, identifier, placeholder_pane_id, slot_index, real_pane_id) do
    swap_span =
      Aiur.Perf.span_begin(:placeholder_swap,
        identifier: identifier,
        placeholder: placeholder_pane_id,
        real: real_pane_id
      )

    # Swap real attach into the placeholder's location, then kill the
    # placeholder. Use tmux's swap-pane primitive — it moves both panes
    # in one atomic op, preserving the layout the user already sees.
    case Tmux.command(state.tmux, "swap-pane -s #{real_pane_id} -t #{placeholder_pane_id}") do
      {:ok, _} ->
        _ = Tmux.command(state.tmux, "kill-pane -t #{placeholder_pane_id}")
        _ = Tmux.command(state.tmux, "select-pane -t #{real_pane_id}")

        Aiur.Perf.span_end(swap_span,
          identifier: identifier,
          slot: slot_index,
          real: real_pane_id
        )

        new_state =
          state
          |> SlotAttach.record_slot_pane(slot_index, real_pane_id, identifier)
          |> Map.put(:last_attached_pane_id, real_pane_id)
          |> State.drop_placeholder(identifier)

        _ = Layout.apply(new_state)
        AgentPubSub.broadcast_status_change(identifier, :pane_opened)

        Aiur.Perf.event(:pane_open_complete,
          identifier: identifier,
          slot: slot_index,
          pane_id: real_pane_id
        )

        # Async detect when opencode-attach actually renders the convo
        # (process boot + WS handshake + SQLite read + TUI paint). This
        # is what the user experiences as "opencode is up", not the
        # tmux swap above. Poll pane content for the message-turn
        # marker `Build · issue-` which opencode prints only once a
        # session is rendered.
        pm = self()
        tmux = state.tmux

        Task.start(fn ->
          ConvoPaint.detect_convo_first_paint(pm, tmux, identifier, slot_index, real_pane_id)
        end)

        {:noreply, new_state}

      {:error, reason} ->
        Aiur.Perf.span_end(swap_span,
          result: :swap_failed,
          identifier: identifier,
          reason: reason
        )

        Logger.warning("aiur_pane_manager phase=placeholder_swap_failed identifier=#{identifier} placeholder=#{placeholder_pane_id} real=#{real_pane_id} reason=#{inspect(reason)}")

        # Best effort: kill the placeholder so the user isn't stuck
        # staring at a loading screen forever.
        _ = Tmux.command(state.tmux, "kill-pane -t #{placeholder_pane_id}")
        {:noreply, State.drop_placeholder(state, identifier)}
    end
  end

  @spec handle_failed(State.t(), State.agent_id(), State.pane_id(), term()) ::
          {:noreply, State.t()}
  def handle_failed(state, identifier, placeholder_pane_id, reason) do
    Logger.warning("aiur_pane_manager phase=placeholder_failed identifier=#{identifier} placeholder=#{placeholder_pane_id} reason=#{inspect(reason)}")

    Aiur.Perf.event(:placeholder_failed, identifier: identifier, reason: reason)

    _ = Tmux.command(state.tmux, "kill-pane -t #{placeholder_pane_id}")
    new_state = State.drop_placeholder(state, identifier)
    _ = Layout.apply(new_state)
    {:noreply, new_state}
  end

  # Spawn an instantly-visible placeholder pane in window 0 with a
  # short loading message. The real opencode-attach swaps into this
  # pane's spot once the slot is ready.
  defp spawn_placeholder_pane(state, identifier) do
    # Embed identifier into the shell command so the loading text is
    # contextual. `tail -f /dev/null` keeps the pane alive until we
    # swap it out and kill it.
    safe_id = String.replace(identifier, "'", "")

    cmd =
      "bash -c 'clear; printf \"\\033[1;36m  Loading opencode for issue-#{safe_id}...\\033[0m\\n\\n  This will take a moment on first open per slot.\\n\"; tail -f /dev/null'"

    case Tmux.split_pane(
           state.tmux,
           state.agent_list_pane,
           horizontal_orientation(state.orientation),
           50,
           cmd,
           silent: false
         ) do
      {:ok, pane_id} -> {:ok, pane_id}
      err -> err
    end
  end

  defp horizontal_orientation(:horizontal), do: :horizontal
  defp horizontal_orientation(:vertical), do: :vertical
  defp horizontal_orientation(_), do: :horizontal

  defp record_placeholder(state, identifier, placeholder_pane_id, slot) do
    new_state = State.record_placeholder(state, identifier, placeholder_pane_id, slot)
    SlotAttach.set_pane_title(new_state, placeholder_pane_id, identifier)
    new_state
  end

  # Async worker: acquire slot, drive Slot.select (which respawns the
  # opencode-attach pane in aiur-hidden with --session), then tell
  # PaneManager to swap the real pane into the placeholder's spot.
  defp drive_real_attach(pm, identifier, placeholder_pane_id) do
    span = Aiur.Perf.span_begin(:async_drive_attach, identifier: identifier)

    case SlotSupervisor.acquire_slot_or_grow() do
      {slot_index, slot_pid} when is_integer(slot_index) ->
        perform_select_for_placeholder(pm, span, identifier, placeholder_pane_id, slot_index, slot_pid)

      {:error, :no_ready_slot} ->
        # No ready slot yet — either the warm pool is still booting or
        # `acquire_slot_or_grow` just started a fresh cold slot beyond
        # the warm pool. Either way, poll until one becomes ready
        # (~10 s for a cold start). Poll up to 60 s.
        wait_then_select_for_placeholder(pm, span, identifier, placeholder_pane_id)
    end
  end

  defp wait_then_select_for_placeholder(pm, span, identifier, placeholder_pane_id) do
    case wait_for_slot(60_000) do
      {:ok, {slot_index, slot_pid}} ->
        perform_select_for_placeholder(pm, span, identifier, placeholder_pane_id, slot_index, slot_pid)

      {:error, :timeout} ->
        Aiur.Perf.span_end(span, result: :slot_wait_timeout, identifier: identifier)
        send(pm, {:placeholder_failed, identifier, placeholder_pane_id, :no_ready_slot})
    end
  end

  defp perform_select_for_placeholder(pm, span, identifier, placeholder_pane_id, slot_index, slot_pid) do
    case Slot.select(slot_pid, identifier) do
      {:ok, real_pane_id} ->
        Aiur.Perf.span_end(span,
          identifier: identifier,
          slot: slot_index,
          real_pane_id: real_pane_id
        )

        send(pm, {:placeholder_swap, identifier, placeholder_pane_id, slot_index, real_pane_id})

      {:error, reason} ->
        Aiur.Perf.span_end(span,
          result: :select_failed,
          identifier: identifier,
          slot: slot_index,
          reason: reason
        )

        send(pm, {:placeholder_failed, identifier, placeholder_pane_id, reason})
    end
  end

  defp wait_for_slot(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_slot(deadline)
  end

  defp do_wait_for_slot(deadline) do
    case SlotSupervisor.acquire_slot_or_grow() do
      {idx, pid} when is_integer(idx) ->
        {:ok, {idx, pid}}

      {:error, :no_ready_slot} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(150)
          do_wait_for_slot(deadline)
        end
    end
  end

  @spec enqueue_open(State.t(), State.agent_id(), GenServer.from()) ::
          {:noreply, State.t()} | {:reply, {:error, :already_queued}, State.t()}
  defp enqueue_open(state, identifier, from) do
    case OpenQueue.queued?(state.open_queue_timers, identifier) do
      true ->
        # Duplicate open while a previous one for the same identifier is
        # still queued. Refuse rather than coalesce — simpler to reason
        # about, and the original caller will still eventually receive
        # a reply (success or :no_ready_slot timeout).
        {:reply, {:error, :already_queued}, state}

      false ->
        timer_ref = Process.send_after(self(), {:open_queue_timeout, identifier}, OpenQueue.timeout_ms())

        {new_queue, new_timers} =
          OpenQueue.enqueue(state.open_queue, state.open_queue_timers, identifier, from, timer_ref)

        new_state = %{state | open_queue: new_queue, open_queue_timers: new_timers}

        Logger.info("aiur_pane_manager phase=open_queued elapsed_ms=#{Boot.elapsed_ms()} identifier=#{identifier} queue_depth=#{:queue.len(new_queue)}")

        {:noreply, new_state}
    end
  end
end
