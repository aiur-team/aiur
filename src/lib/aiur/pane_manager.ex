defmodule Aiur.PaneManager do
  @moduledoc """
  Owns the mapping from `agent_identifier` to its tmux pane id and drives
  the conversation-pane grid around the persistent agent-list pane.

  ## Layout model

  Every open / respawn / close routes through `Aiur.PaneManager.Layout`,
  which produces an explicit `tmux select-layout <string>` for the
  current window dimensions and slot occupancy. This sidesteps tmux's
  default auto-layout behaviour (and any `after-split-window` hooks) so
  the Executor sees a deterministic grid regardless of which pane tmux
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

  alias Aiur.{AgentEvents, Boot, Tmux}
  alias Aiur.Opencode.{AttachPool, Slot, SlotSupervisor}
  alias Aiur.PaneManager.{Anchor, Close, Layout, OpencodeOpen, OpenQueue, Placeholder, Reconcile}
  alias Aiur.PaneManager.{ScreenGrab, SlotAttach, State}

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
  layout immediately so the Executor sees the rotated grid without
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
            state = State.forget_pane_by_identifier(state, existing_pane)
            OpencodeOpen.do_open(state, identifier, command_to_run, opts, from)
        end

      :error ->
        OpencodeOpen.do_open(state, identifier, command_to_run, opts, from)
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
    Placeholder.handle_swap(state, identifier, placeholder_pane_id, slot_index, real_pane_id)
  end

  def handle_info({:convo_first_paint, _identifier, _pane_id, _wall_ms}, state) do
    # The convo_first_paint Perf event is the actual signal — this
    # handler just keeps the message from hitting the catch-all.
    {:noreply, state}
  end

  def handle_info({:placeholder_failed, identifier, placeholder_pane_id, reason}, state) do
    Placeholder.handle_failed(state, identifier, placeholder_pane_id, reason)
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
end
