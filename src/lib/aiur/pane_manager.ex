defmodule Aiur.PaneManager do
  @moduledoc """
  Owns the mapping from `agent_identifier` to its tmux pane id and drives
  the conversation-pane grid around the persistent agent-list pane.

  ## Layout model

  Every open / respawn / close routes through `Aiur.PaneManager.Layout`,
  which produces an explicit `tmux select-layout <string>` for the
  current window dimensions and slot occupancy. This sidesteps tmux's
  default auto-layout behaviour (and any `after-split-window` hooks) so
  the operator sees a deterministic grid regardless of which pane tmux
  happened to split from.

  With `max_vertical_panes: 3`, the fully-populated grid is:

      +----------+----------+----------+
      | agent    | slot 1   | slot 2   |
      | list     |          |          |
      +----------+----------+----------+
      | slot 3   | slot 4   | slot 5   |
      +----------+----------+----------+

  Empty slots collapse: row siblings expand evenly to fill the freed
  width. An entirely empty bottom row makes the top row span full height.

  ## Slot cycling

  `cycle_index` advances by 1 after every successful open. When the
  pointer lands on a slot whose pane is alive, the running command is
  replaced via `respawn-pane` and the pane id is preserved. When the
  pointer lands on an empty slot, a fresh pane is created via
  `split-window` (anchored to the agent-list pane — position is set by
  the layout string we apply right after).

  ## Anchor pane

  `agent_list_pane` is resolved at init time from
  `Aiur.Tmux.resolve_self_pane/1` (which validates `$TMUX_PANE` against
  the tmux server). If resolution fails, `init/1` refuses to start with
  `{:stop, :no_agent_list_pane}` rather than silently falling through to
  a broken anchor — that silent fallback was the root cause of the
  regression issue #34 tracks.

  Consumes tmux notifications via `Aiur.Tmux.subscribe_events/1` and
  treats `%pane-died` (and, when distribution is in play, `:nodedown`)
  as authoritative pane-closed signals.
  """

  use GenServer
  require Logger

  alias Aiur.{AgentEvents, AgentPubSub, Boot, Tmux}
  alias Aiur.Opencode.{AttachPool, Slot, SlotRegistry, SlotSupervisor}
  alias Aiur.PaneManager.{Anchor, Close, ConvoPaint, GenericOpen, Layout, OpenQueue, Reconcile, ScreenGrab, SlotAttach, State}

  @type agent_id :: AgentEvents.agent_identifier()
  @type pane_id :: String.t()

  @type orientation :: :horizontal | :vertical

  # Public API ----------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec open_conversation(GenServer.server(), agent_id(), String.t(), keyword()) ::
          {:ok, pane_id()} | {:error, term()}
  def open_conversation(server \\ __MODULE__, identifier, command_to_run, opts \\ [])
      when is_binary(identifier) and is_binary(command_to_run) and is_list(opts) do
    # Timeout matches `attach_conversation/4` and the open-queue's 60 s
    # upper bound. PaneManager parks the call when no slot is ready and
    # only replies after the queue drains; the default 5 s GenServer
    # timeout would crash the caller mid-park during cold pre-warm.
    GenServer.call(server, {:open, identifier, command_to_run, opts}, 65_000)
  end

  @spec close_conversation(GenServer.server(), agent_id()) :: :ok | {:error, term()}
  @doc """
  Hide the conversation pane WITHOUT releasing its slot: the pane moves to
  the hidden warm window with its opencode-attach process intact and the
  slot keeps its identifier binding, so reopening swaps the same pane back
  via `Slot.set_visible/2`'s fast path — no respawn, no prewarm wait. This
  is the Ctrl+Q / Ctrl+C-close semantic; the agent-list close
  (`close_conversation/2`) additionally deselects so the slot frees up.

  Returns `{:error, :not_slot_pane}` for panes no slot owns — callers fall
  back to a plain kill.
  """
  @spec hide_by_pane_id(GenServer.server(), String.t()) ::
          :ok | {:error, :not_slot_pane | term()}
  def hide_by_pane_id(server \\ __MODULE__, pane_id) when is_binary(pane_id) do
    GenServer.call(server, {:hide_by_pane_id, pane_id}, 10_000)
  catch
    :exit, {:noproc, _} -> {:error, :no_pane_manager}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @spec close_conversation(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def close_conversation(server \\ __MODULE__, identifier) when is_binary(identifier) do
    GenServer.call(server, {:close, identifier})
  end

  @doc """
  Attach `identifier` to the slot owning `state.last_attached_pane_id`.
  The slot rebuilds its serve with the new identifier (via the
  existing `Slot.select/2` rebuild path) and the pane stays in the
  same tmux location.

  Returns `{:error, :no_focused_pane}` when no chat pane has been
  opened yet — caller (AgentList) falls through to `open_conversation`.

  Timeout matches the open-queue timeout's upper bound so the call
  sees the queue's reply rather than its own timeout, in case the
  slot rebuild takes longer than expected.
  """
  @spec attach_conversation(GenServer.server(), agent_id(), String.t(), keyword()) ::
          {:ok, pane_id()} | {:error, term()}
  def attach_conversation(server \\ __MODULE__, identifier, command_to_run, opts \\ [])
      when is_binary(identifier) and is_binary(command_to_run) and is_list(opts) do
    GenServer.call(server, {:attach, identifier, command_to_run, opts}, 65_000)
  end

  @spec list_open_panes(GenServer.server()) :: %{optional(agent_id()) => pane_id()}
  def list_open_panes(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @spec orientation(GenServer.server()) :: orientation()
  def orientation(server \\ __MODULE__) do
    GenServer.call(server, :orientation)
  end

  @doc """
  Flip the grid between `:horizontal` (default — anchor sits in the top
  row) and `:vertical` (anchor sits at the top of the left column, slots
  stack downward, then continue in a second column). Re-applies the
  layout immediately so the operator sees the rotated grid without
  waiting for the next open/close.
  """
  @spec toggle_orientation(GenServer.server()) :: {:ok, orientation()}
  def toggle_orientation(server \\ __MODULE__) do
    GenServer.call(server, :toggle_orientation)
  end

  # GenServer callbacks -------------------------------------------------------

  @impl true
  def init(opts) do
    tmux = Keyword.get(opts, :tmux, Tmux)
    max_vertical_panes = Keyword.get(opts, :max_vertical_panes, Aiur.Config.max_vertical_panes())

    # slot_count is the LARGER of grid capacity (panes-* 2 - 1) and
    # max_concurrent_agents — pre-warm needs one slot per active agent
    # so an agent that's queued past grid capacity still gets a leadoff
    # when it becomes active. Tests pass `slot_count` explicitly to
    # exercise round-robin behavior with a known cap.
    slot_count =
      Keyword.get_lazy(opts, :slot_count, fn ->
        grid = State.slot_count(max_vertical_panes)

        max_agents =
          try do
            Aiur.Config.max_concurrent_agents()
          rescue
            _ -> grid
          end

        max(grid, max_agents)
      end)

    orientation = Keyword.get(opts, :orientation, :horizontal)

    with {:ok, agent_list_pane} <- Anchor.resolve_agent_list_pane(opts, tmux),
         {:ok, window_target} <- Anchor.resolve_window_target(opts, tmux, agent_list_pane) do
      Logger.info(
        "PaneManager init agent_list_pane=#{agent_list_pane} window=#{window_target} " <>
          "max_vertical_panes=#{max_vertical_panes} slot_count=#{slot_count} " <>
          "orientation=#{orientation}"
      )

      case Tmux.subscribe_events(tmux) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("PaneManager: tmux subscribe failed: #{inspect(reason)}")
      end

      Anchor.publish_control_url(tmux)

      :ok = Phoenix.PubSub.subscribe(Aiur.PubSub, Slot.slots_topic())
      :ok = Phoenix.PubSub.subscribe(Aiur.PubSub, AttachPool.topic())

      :net_kernel.monitor_nodes(true, node_type: :hidden)

      if ScreenGrab.screen_grab?() do
        Process.send_after(self(), :screen_grab_tick, ScreenGrab.interval_ms())
      end

      {:ok,
       %State{
         tmux: tmux,
         agent_list_pane: agent_list_pane,
         window_target: window_target,
         max_vertical_panes: max_vertical_panes,
         slot_count: slot_count,
         slot_panes: State.empty_slot_panes(slot_count),
         orientation: orientation
       }}
    else
      {:error, reason} ->
        Logger.warning(
          "PaneManager: cannot resolve agent-list pane (#{inspect(reason)}). " <>
            "Aiur must run inside a tmux pane started by the aiur launcher. Refusing to start."
        )

        {:stop, :no_agent_list_pane}
    end
  end

  @impl true
  def handle_call({:open, identifier, command_to_run, opts}, from, state) do
    Aiur.Perf.event(:pane_open_request, identifier: identifier)
    state = State.remember_title(state, identifier, opts)
    state = Reconcile.reconcile_visible_panes(state)

    case Map.fetch(state.identifier_to_pane, identifier) do
      {:ok, existing_pane} ->
        case Tmux.command(state.tmux, "select-pane -t #{existing_pane}") do
          {:ok, _} ->
            Logger.info("aiur_pane_manager phase=open_already_visible elapsed_ms=#{Boot.elapsed_ms()} identifier=#{identifier} pane_id=#{existing_pane}")

            Aiur.Perf.event(:pane_open_already_visible,
              identifier: identifier,
              pane_id: existing_pane
            )

            {:reply, {:ok, existing_pane}, state}

          {:error, _reason} ->
            do_open(State.forget_pane_by_identifier(state, existing_pane), identifier, command_to_run, opts, from)
        end

      :error ->
        do_open(state, identifier, command_to_run, opts, from)
    end
  end

  def handle_call({:attach, identifier, _command, opts}, from, state) do
    state = State.remember_title(state, identifier, opts)

    cond do
      Map.has_key?(state.identifier_to_pane, identifier) ->
        # Identifier already visible somewhere — refocus existing pane
        # instead of re-attaching. Mirrors the open path's idempotence.
        existing_pane = Map.fetch!(state.identifier_to_pane, identifier)
        _ = Tmux.command(state.tmux, "select-pane -t #{existing_pane}")
        {:reply, {:ok, existing_pane}, %{state | last_attached_pane_id: existing_pane}}

      is_nil(state.last_attached_pane_id) ->
        # No pane has been opened yet — caller (AgentList) falls through
        # to open_conversation per R4.2.
        {:reply, {:error, :no_focused_pane}, state}

      true ->
        SlotAttach.attach_to_focused_pane(state, identifier, from)
    end
  end

  def handle_call({:close, identifier}, _from, state) do
    case Map.fetch(state.identifier_to_pane, identifier) do
      {:ok, pane_id} ->
        Logger.info("[user-action] close_conversation identifier=#{identifier} pane_id=#{pane_id}")

        Close.close_opencode_or_generic(state, identifier, pane_id)

      :error ->
        {:reply, {:error, :not_open}, state}
    end
  end

  def handle_call({:hide_by_pane_id, pane_id}, _from, state) do
    case Map.fetch(state.pane_to_identifier, pane_id) do
      {:ok, identifier} ->
        Logger.info("[user-action] hide_pane identifier=#{identifier} pane_id=#{pane_id}")

        Close.hide_slot_pane(state, identifier, pane_id)

      :error ->
        {:reply, {:error, :not_slot_pane}, state}
    end
  end

  def handle_call(:list, _from, state), do: {:reply, state.identifier_to_pane, state}

  def handle_call(:orientation, _from, state), do: {:reply, state.orientation, state}

  def handle_call(:toggle_orientation, _from, state) do
    new_orientation =
      case state.orientation do
        :horizontal -> :vertical
        :vertical -> :horizontal
      end

    Logger.info("[user-action] toggle_orientation #{state.orientation} -> #{new_orientation}")
    new_state = %{state | orientation: new_orientation}
    _ = Layout.apply(new_state)
    {:reply, {:ok, new_orientation}, new_state}
  end

  @impl true
  def handle_info({:tmux_event, {:notification, :pane_died, pane_id}}, state) do
    identifier = Map.get(state.pane_to_identifier, pane_id)
    slot = Map.get(state.pane_to_slot, pane_id)

    Logger.warning("aiur_pane_manager phase=tmux_pane_died pane_id=#{pane_id} identifier=#{inspect(identifier)} slot=#{inspect(slot)}")

    Aiur.Perf.event(:pane_died_event,
      pane_id: pane_id,
      identifier: identifier,
      slot: slot
    )

    {:noreply, Reconcile.handle_pane_closed(state, pane_id)}
  end

  def handle_info({:slot_ready, _slot_index}, state) do
    {:noreply, drain_open_queue(state)}
  end

  def handle_info({:slot_session_changed, slot_index, nil}, state) do
    # A slot's session was deselected — clear `last_attached_pane_id`
    # if it pointed at that slot's pane so the `a` keybind doesn't
    # try to attach to a dead pane.
    pane_id = Map.get(state.slot_panes, slot_index)
    clear_last_attached? = Map.get(state.pane_to_slot, state.last_attached_pane_id) == slot_index

    new_state =
      if is_binary(pane_id) do
        State.forget_pane_by_identifier(state, pane_id)
      else
        state
      end

    new_state =
      if clear_last_attached? do
        %{new_state | last_attached_pane_id: nil}
      else
        new_state
      end

    if is_binary(pane_id), do: Layout.apply(new_state)
    {:noreply, new_state}
  end

  def handle_info({:slot_session_changed, _slot_index, _identifier}, state) do
    {:noreply, state}
  end

  def handle_info({:slot_visible_changed, _slot_index, _identifier}, state) do
    {:noreply, state}
  end

  def handle_info({:slot_attach_added, _slot_index, _identifier}, state),
    do: {:noreply, state}

  def handle_info({:slot_attach_removed, _slot_index, _identifier}, state),
    do: {:noreply, state}

  def handle_info({:agent_inactive, identifier}, state) when is_binary(identifier) do
    case Map.fetch(state.identifier_to_pane, identifier) do
      {:ok, pane_id} ->
        Logger.info("aiur_pane_manager phase=close_inactive identifier=#{identifier} pane_id=#{pane_id}")

        {:reply, _, new_state} = Close.close_opencode_or_generic(state, identifier, pane_id)
        {:noreply, new_state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:attach_state_changed, _identifier, _count, _visible_in}, state),
    do: {:noreply, state}

  def handle_info({:slot_fully_warmed, _slot_index}, state), do: {:noreply, state}
  def handle_info({:slot_warmth_dropped, _slot_index}, state), do: {:noreply, state}

  def handle_info({:attach_consumed, _identifier, _pane_id, _slot_index}, state),
    do: {:noreply, state}

  def handle_info({:attach_failed, _identifier, _slot_index, _reason}, state),
    do: {:noreply, state}

  def handle_info({:open_queue_timeout, identifier}, state) do
    case OpenQueue.pluck(state.open_queue, state.open_queue_timers, identifier) do
      :not_queued ->
        {:noreply, state}

      {from, new_queue, new_timers} ->
        Logger.warning("aiur_pane_manager phase=open_queue_timeout elapsed_ms=#{Boot.elapsed_ms()} identifier=#{identifier} timeout_ms=#{OpenQueue.timeout_ms()}")

        GenServer.reply(from, {:error, :no_ready_slot})
        {:noreply, %{state | open_queue: new_queue, open_queue_timers: new_timers}}
    end
  end

  def handle_info({:nodedown, _node}, state), do: {:noreply, state}
  def handle_info({:nodeup, _node, _info}, state), do: {:noreply, state}
  def handle_info({:nodeup, _node}, state), do: {:noreply, state}

  def handle_info({:placeholder_swap, identifier, placeholder_pane_id, slot_index, real_pane_id}, state) do
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

  def handle_info({:convo_first_paint, _identifier, _pane_id, _wall_ms}, state) do
    # The convo_first_paint Perf event is the actual signal — this
    # handler just keeps the message from hitting the catch-all.
    {:noreply, state}
  end

  def handle_info({:placeholder_failed, identifier, placeholder_pane_id, reason}, state) do
    Logger.warning("aiur_pane_manager phase=placeholder_failed identifier=#{identifier} placeholder=#{placeholder_pane_id} reason=#{inspect(reason)}")

    Aiur.Perf.event(:placeholder_failed, identifier: identifier, reason: reason)

    _ = Tmux.command(state.tmux, "kill-pane -t #{placeholder_pane_id}")
    new_state = State.drop_placeholder(state, identifier)
    _ = Layout.apply(new_state)
    {:noreply, new_state}
  end

  def handle_info({:tmux_event, event}, state) do
    if debug_mode?() do
      Logger.info("aiur_tmux_event #{inspect(event)}")
    end

    {:noreply, state}
  end

  def handle_info(:screen_grab_tick, state) do
    ScreenGrab.log_screen_grab(state)

    if ScreenGrab.screen_grab?() do
      Process.send_after(self(), :screen_grab_tick, ScreenGrab.interval_ms())
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp debug_mode? do
    case System.get_env("AIUR_DEBUG") do
      value when is_binary(value) ->
        String.downcase(String.trim(value)) in ["1", "true", "yes"]

      _ ->
        false
    end
  end

  # Pop the next queued open (if any) and try to attach it to a ready
  # slot. If no slot is ready, leave the entry queued and wait for the
  # next `:slot_ready` broadcast. v1: drains 1 entry per broadcast.
  defp drain_open_queue(state) do
    case OpenQueue.pop(state.open_queue) do
      :empty -> state
      {entry, rest} -> drain_open_entry(state, entry, rest)
    end
  end

  defp drain_open_entry(state, {identifier, from, timer_ref}, rest) do
    case SlotSupervisor.acquire_slot_or_grow() do
      {slot_index, slot_pid} when is_integer(slot_index) ->
        _ = Process.cancel_timer(timer_ref)
        new_timers = Map.delete(state.open_queue_timers, identifier)
        new_state = %{state | open_queue: rest, open_queue_timers: new_timers}

        Logger.info("aiur_pane_manager phase=open_queue_drained elapsed_ms=#{Boot.elapsed_ms()} identifier=#{identifier} queue_depth=#{:queue.len(rest)}")

        case SlotAttach.attach_identifier_to_slot(new_state, identifier, slot_index, slot_pid, from) do
          {:noreply, after_state} -> after_state
          {:reply, _result, after_state} -> after_state
        end

      {:error, :no_ready_slot} ->
        # Race: another open just took the newly-ready slot. Leave
        # the entry queued; the next `:slot_ready` will retry.
        state
    end
  end

  # Slot allocation ----------------------------------------------------------

  defp do_open(state, identifier, command_to_run, opts, from) do
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
  defp open_opencode_pane(state, identifier, _opts, from) do
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
            open_with_placeholder(state, identifier, from)
        end
    end
  end

  # Warm path: an opencode-attach process is already booted in aiur-
  # hidden, bound to this identifier's session and painted. Move it
  # to window 0 and record bookkeeping. No placeholder, no respawn.
  defp move_warm_pane_visible(state, identifier, slot_index, pane_id, from) do
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

          open_with_placeholder(state, identifier, from)
        end
    end
  end

  defp open_with_placeholder(state, identifier, from) do
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
