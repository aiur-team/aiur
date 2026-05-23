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
  alias Aiur.Opencode.{AttachPool, HiddenWindow, Slot, SlotPolicy, SlotRegistry, SlotSupervisor}
  alias Aiur.PaneManager.Layout

  @type agent_id :: AgentEvents.agent_identifier()
  @type pane_id :: String.t()

  defstruct identifier_to_pane: %{},
            pane_to_identifier: %{},
            pane_to_slot: %{},
            slot_panes: %{},
            cycle_index: 0,
            max_vertical_panes: 3,
            slot_count: 5,
            agent_list_pane: nil,
            window_target: nil,
            orientation: :horizontal,
            tmux: nil,
            # FIFO queue of pending opens waiting on a `:slot_ready`
            # broadcast. Each entry is `{identifier, from, timer_ref}`.
            # The queue drains 1 entry per `:slot_ready` event in v1 —
            # multi-drain optimization deferred until measured need.
            open_queue: :queue.new(),
            # identifier => timer_ref, so a duplicate-open request can
            # detect the existing queued entry and refuse it without
            # walking the queue.
            open_queue_timers: %{},
            # Tracks the most-recently-opened or -attached chat pane.
            # Drives the `a` "attach to focused pane" keybind in
            # `AgentList` (U6). Reset to nil when the corresponding
            # slot signals `:slot_session_changed` with a nil identifier.
            last_attached_pane_id: nil,
            # identifier => %{pane_id: pane_id, slot: slot_index}
            # Loading placeholders are real visible tmux panes before
            # a Slot worker has produced the final opencode-attach pane.
            # They are included in layout occupancy but not reported as
            # open chat panes.
            placeholder_panes: %{}

  @type orientation :: :horizontal | :vertical

  # How long a queued open will wait for a slot to become `:ready` before
  # we reply `{:error, :no_ready_slot}` to the caller. Generous because
  # chain pre-warm sets the lower bound (slot N takes ~5 s after N-1
  # broadcasts ready); a stalled chain still completes within this window
  # in any realistic configuration.
  @open_queue_timeout_ms 60_000

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
    slot_count = slot_count(max_vertical_panes)
    orientation = Keyword.get(opts, :orientation, :horizontal)

    with {:ok, agent_list_pane} <- resolve_agent_list_pane(opts, tmux),
         {:ok, window_target} <- resolve_window_target(opts, tmux, agent_list_pane) do
      Logger.info(
        "PaneManager init agent_list_pane=#{agent_list_pane} window=#{window_target} " <>
          "max_vertical_panes=#{max_vertical_panes} slot_count=#{slot_count} " <>
          "orientation=#{orientation}"
      )

      case Tmux.subscribe_events(tmux) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("PaneManager: tmux subscribe failed: #{inspect(reason)}")
      end

      :ok = Phoenix.PubSub.subscribe(Aiur.PubSub, Slot.slots_topic())
      :ok = Phoenix.PubSub.subscribe(Aiur.PubSub, AttachPool.topic())

      :net_kernel.monitor_nodes(true, node_type: :hidden)

      {:ok,
       %__MODULE__{
         tmux: tmux,
         agent_list_pane: agent_list_pane,
         window_target: window_target,
         max_vertical_panes: max_vertical_panes,
         slot_count: slot_count,
         slot_panes: empty_slot_panes(slot_count),
         orientation: orientation
       }}
    else
      {:error, reason} ->
        Logger.warning(
          "PaneManager: cannot resolve agent-list pane (#{inspect(reason)}). " <>
            "Aiur must run inside a tmux pane started by scripts/aiur. Refusing to start."
        )

        {:stop, :no_agent_list_pane}
    end
  end

  @impl true
  def handle_call({:open, identifier, command_to_run, opts}, from, state) do
    Aiur.Perf.event(:pane_open_request, identifier: identifier)
    state = reconcile_visible_panes(state)

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
            do_open(forget_pane_by_identifier(state, existing_pane), identifier, command_to_run, opts, from)
        end

      :error ->
        do_open(state, identifier, command_to_run, opts, from)
    end
  end

  def handle_call({:attach, identifier, _command, _opts}, from, state) do
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
        attach_to_focused_pane(state, identifier, from)
    end
  end

  def handle_call({:close, identifier}, _from, state) do
    case Map.fetch(state.identifier_to_pane, identifier) do
      {:ok, pane_id} ->
        Logger.info("[user-action] close_conversation identifier=#{identifier} pane_id=#{pane_id}")

        close_opencode_or_generic(state, identifier, pane_id)

      :error ->
        {:reply, {:error, :not_open}, state}
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
    _ = apply_layout(new_state)
    {:reply, {:ok, new_orientation}, new_state}
  end

  @impl true
  def handle_info({:tmux_event, {:notification, :pane_died, pane_id}}, state) do
    {:noreply, handle_pane_closed(state, pane_id)}
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
        forget_pane_by_identifier(state, pane_id)
      else
        state
      end

    new_state =
      if clear_last_attached? do
        %{new_state | last_attached_pane_id: nil}
      else
        new_state
      end

    if is_binary(pane_id), do: apply_layout(new_state)
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

        {:reply, _, new_state} = close_opencode_or_generic(state, identifier, pane_id)
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
    case Map.fetch(state.open_queue_timers, identifier) do
      :error ->
        # Already drained — timer fired after the entry was dequeued
        # but before the timer could be cancelled cleanly. No-op.
        {:noreply, state}

      {:ok, _timer_ref} ->
        # Walk the queue once to find this identifier and pluck it.
        {entries, dropped_from} =
          state.open_queue
          |> :queue.to_list()
          |> Enum.reduce({[], nil}, fn
            {^identifier, from, _ref}, {acc, nil} -> {acc, from}
            other, {acc, dropped} -> {[other | acc], dropped}
          end)

        case dropped_from do
          nil ->
            {:noreply, state}

          from ->
            new_queue = :queue.from_list(Enum.reverse(entries))
            new_timers = Map.delete(state.open_queue_timers, identifier)

            Logger.warning("aiur_pane_manager phase=open_queue_timeout elapsed_ms=#{Boot.elapsed_ms()} identifier=#{identifier} timeout_ms=#{@open_queue_timeout_ms}")

            GenServer.reply(from, {:error, :no_ready_slot})
            {:noreply, %{state | open_queue: new_queue, open_queue_timers: new_timers}}
        end
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
          |> record_slot_pane(slot_index, real_pane_id, identifier)
          |> Map.put(:last_attached_pane_id, real_pane_id)
          |> drop_placeholder(identifier)

        _ = apply_layout(new_state)
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
          detect_convo_first_paint(pm, tmux, identifier, slot_index, real_pane_id)
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
        {:noreply, drop_placeholder(state, identifier)}
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
    new_state = drop_placeholder(state, identifier)
    _ = apply_layout(new_state)
    {:noreply, new_state}
  end

  def handle_info({:tmux_event, _event}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # Pop the next queued open (if any) and try to attach it to a ready
  # slot. If no slot is ready, leave the entry queued and wait for the
  # next `:slot_ready` broadcast. v1: drains 1 entry per broadcast.
  defp drain_open_queue(state) do
    case :queue.out(state.open_queue) do
      {:empty, _} -> state
      {{:value, entry}, rest} -> drain_open_entry(state, entry, rest)
    end
  end

  defp drain_open_entry(state, {identifier, from, timer_ref}, rest) do
    case SlotSupervisor.acquire_slot() do
      {slot_index, slot_pid} when is_integer(slot_index) ->
        _ = Process.cancel_timer(timer_ref)
        new_timers = Map.delete(state.open_queue_timers, identifier)
        new_state = %{state | open_queue: rest, open_queue_timers: new_timers}

        Logger.info("aiur_pane_manager phase=open_queue_drained elapsed_ms=#{Boot.elapsed_ms()} identifier=#{identifier} queue_depth=#{:queue.len(rest)}")

        case attach_identifier_to_slot(new_state, identifier, slot_index, slot_pid, from) do
          {:noreply, after_state} -> after_state
          {:reply, _result, after_state} -> after_state
        end

      {:error, :no_ready_slot} ->
        # Race: another open just took the newly-ready slot. Leave
        # the entry queued; the next `:slot_ready` will retry.
        state
    end
  end

  # Anchor / window discovery ------------------------------------------------

  defp resolve_agent_list_pane(opts, tmux) do
    cond do
      pane = Keyword.get(opts, :agent_list_pane) ->
        {:ok, pane}

      pane = env_pane() ->
        {:ok, pane}

      true ->
        Tmux.resolve_self_pane(tmux)
    end
  end

  defp env_pane do
    case System.get_env("TMUX_PANE") do
      pane when is_binary(pane) and pane != "" -> pane
      _ -> nil
    end
  end

  defp resolve_window_target(opts, tmux, agent_list_pane) do
    case Keyword.get(opts, :window_target) do
      target when is_binary(target) and target != "" -> {:ok, target}
      _ -> Tmux.window_for(tmux, agent_list_pane)
    end
  end

  # Slot allocation ----------------------------------------------------------

  defp do_open(state, identifier, command_to_run, opts, from) do
    case command_to_run do
      "__aiur_opencode__ " <> _ -> open_opencode_pane(state, identifier, opts, from)
      _ -> open_generic_pane(state, identifier, command_to_run, from)
    end
  end

  defp close_opencode_or_generic(state, identifier, pane_id) do
    # If this pane is currently owned by a slot worker, hide it (move to
    # the hidden warm window) and deselect the slot so the slot can
    # accept the next agent. Otherwise it's a generic pane — kill it.
    case slot_for_pane(state, pane_id) do
      {:ok, slot_index, slot_pid} ->
        hidden_window = HiddenWindow.window_name()

        case Tmux.move_pane_hidden(state.tmux, pane_id, hidden_window) do
          :ok ->
            :ok = Slot.deselect(slot_pid)
            new_state = forget_pane_by_identifier(state, pane_id)
            _ = apply_layout(new_state)

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
        new_state = forget_pane_by_identifier(state, pane_id)
        _ = apply_layout(new_state)
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

  # Non-opencode commands (rare today; mostly the bare `echo ...` test paths)
  # still go through the classic "split + wrap with unique BEAM node" flow.
  defp open_generic_pane(state, identifier, command_to_run, _from) do
    wrapped = wrap_with_unique_node(command_to_run, identifier)
    slot = state.cycle_index + 1

    case open_in_slot(state, slot, identifier, wrapped) do
      {:ok, pane_id, new_state} ->
        AgentPubSub.broadcast_status_change(identifier, :pane_opened)
        _ = apply_layout(new_state)
        {:reply, {:ok, pane_id}, advance_cycle(new_state)}

      {:error, reason} ->
        Logger.warning("PaneManager.open identifier=#{identifier} slot=#{slot} failed: #{inspect(reason)}")

        {:reply, {:error, reason}, state}
    end
  end

  # opencode panes use the slot-bound model: each pane slot owns its own
  # opencode-serve + opencode-attach process for the lifetime of the
  # aiur run. Opening a pane = `SlotSupervisor.acquire_slot/0` +
  # `Slot.select/2` + `Tmux.move_pane_visible/2`. If no slot is :ready
  # (chain pre-warm hasn't reached one yet), fall back to the legacy
  # cold-attach path so the user never sees an error.
  defp open_opencode_pane(state, identifier, _opts, from) do
    # FAST PATH: AttachPool may have a warm opencode-attach pane
    # already running in aiur-hidden for this identifier. If so, just
    # move it to visible (~50 ms — opencode is already painted).
    case AttachPool.consume(identifier) do
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
          |> record_slot_pane(slot_index, pane_id, identifier)
          |> Map.put(:last_attached_pane_id, pane_id)

        _ = apply_layout(new_state)
        AgentPubSub.broadcast_status_change(identifier, :pane_opened)

        Aiur.Perf.event(:pane_open_visible_warm,
          identifier: identifier,
          slot: slot_index,
          pane_id: pane_id
        )

        bump_next_slot()

        # Also fire the convo_first_paint detector — even on warm
        # path the convo content is already rendered, so it should
        # detect within the first poll (~100 ms). This keeps the
        # 3-row debug footer's "opencode render" number consistent
        # across warm and cold opens.
        pm = self()
        tmux = state.tmux

        Task.start(fn ->
          detect_convo_first_paint(pm, tmux, identifier, slot_index, pane_id)
        end)

        reply_or_noreply({:ok, pane_id}, from, new_state)

      {:error, reason} ->
        if pane_already_visible_reason?(reason) do
          Aiur.Perf.span_end(move_span,
            result: :already_visible,
            pane_id: pane_id,
            source: :warm
          )

          new_state =
            state
            |> record_slot_pane(slot_index, pane_id, identifier)
            |> Map.put(:last_attached_pane_id, pane_id)

          AgentPubSub.broadcast_status_change(identifier, :pane_opened)

          Aiur.Perf.event(:pane_open_visible_warm,
            identifier: identifier,
            slot: slot_index,
            pane_id: pane_id,
            result: :already_visible
          )

          bump_next_slot()
          reply_or_noreply({:ok, pane_id}, from, new_state)
        else
          Aiur.Perf.span_end(move_span,
            result: :failed,
            pane_id: pane_id,
            source: :warm,
            reason: reason
          )

          Logger.warning(
            "aiur_pane_manager phase=warm_move_failed identifier=#{identifier} pane_id=#{pane_id} reason=#{inspect(reason)} — falling back to cold open"
          )

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
    visual_slot = first_available_visual_slot(state) || state.slot_count

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

        _ = apply_layout(new_state)

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

        case SlotSupervisor.acquire_slot() do
          {slot_index, slot_pid} when is_integer(slot_index) ->
            Aiur.Perf.span_end(acquire_span,
              result: :ok,
              slot: slot_index,
              identifier: identifier
            )

            attach_identifier_to_slot(state, identifier, slot_index, slot_pid, from)

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
    placeholders = Map.get(state, :placeholder_panes, %{})

    Map.put(
      state,
      :placeholder_panes,
      Map.put(placeholders, identifier, %{pane_id: placeholder_pane_id, slot: slot})
    )
  end

  defp drop_placeholder(state, identifier) do
    placeholders = Map.get(state, :placeholder_panes, %{})
    Map.put(state, :placeholder_panes, Map.delete(placeholders, identifier))
  end

  # Poll the opencode-attach pane for the convo render marker. opencode
  # prints `▣  Build · issue-<id> · <timing>` once it finishes booting
  # the Node.js runtime, opening the WebSocket to the serve, reading
  # the SQLite session rows, and painting the TUI. That paint is what
  # the user sees as "opencode is up" — the tmux swap we already
  # measured fires much earlier.
  #
  # Polls every 100ms up to 30s; emits `convo_first_paint` with
  # wall_ms once the marker appears or `convo_first_paint_timeout`
  # if it never does.
  @convo_paint_poll_interval_ms 100
  @convo_paint_budget_ms 30_000

  defp detect_convo_first_paint(pm, tmux, identifier, slot_index, pane_id) do
    started_at = System.monotonic_time(:millisecond)
    deadline = started_at + @convo_paint_budget_ms

    do_detect_convo_paint(pm, tmux, identifier, slot_index, pane_id, started_at, deadline)
  end

  defp do_detect_convo_paint(pm, tmux, identifier, slot_index, pane_id, started_at, deadline) do
    case Tmux.command(tmux, "capture-pane -p -t #{pane_id}") do
      {:ok, lines} ->
        content = Enum.join(lines, "\n")

        if String.contains?(content, "Build · issue-") do
          wall_ms = System.monotonic_time(:millisecond) - started_at

          Aiur.Perf.event(:convo_first_paint,
            identifier: identifier,
            slot: slot_index,
            pane_id: pane_id,
            wall_ms: wall_ms
          )

          send(pm, {:convo_first_paint, identifier, pane_id, wall_ms})
        else
          wait_and_retry_convo_paint(
            pm,
            tmux,
            identifier,
            slot_index,
            pane_id,
            started_at,
            deadline
          )
        end

      _ ->
        wait_and_retry_convo_paint(
          pm,
          tmux,
          identifier,
          slot_index,
          pane_id,
          started_at,
          deadline
        )
    end
  end

  defp wait_and_retry_convo_paint(pm, tmux, identifier, slot_index, pane_id, started_at, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      wall_ms = System.monotonic_time(:millisecond) - started_at

      Aiur.Perf.event(:convo_first_paint_timeout,
        identifier: identifier,
        slot: slot_index,
        pane_id: pane_id,
        wall_ms: wall_ms
      )
    else
      Process.sleep(@convo_paint_poll_interval_ms)

      do_detect_convo_paint(pm, tmux, identifier, slot_index, pane_id, started_at, deadline)
    end
  end

  # Async worker: acquire slot, drive Slot.select (which respawns the
  # opencode-attach pane in aiur-hidden with --session), then tell
  # PaneManager to swap the real pane into the placeholder's spot.
  defp drive_real_attach(pm, identifier, placeholder_pane_id) do
    span = Aiur.Perf.span_begin(:async_drive_attach, identifier: identifier)

    case SlotSupervisor.acquire_slot() do
      {slot_index, slot_pid} when is_integer(slot_index) ->
        perform_select_for_placeholder(pm, span, identifier, placeholder_pane_id, slot_index, slot_pid)

      {:error, :no_ready_slot} ->
        # Wait briefly for a slot to become ready (slot pre-warm may
        # still be in flight). Poll up to 60 s.
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
    case SlotSupervisor.acquire_slot() do
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

  # Drive a ready slot through select + tmux move + state record. Single
  # success/error reply path — returns `{:reply, ...}` or `{:noreply, ...}`
  # the way `handle_call({:open, ...})` expects when given an explicit
  # `from` of `nil` (the queue-drain case re-replies via `GenServer.reply`).
  defp attach_identifier_to_slot(state, identifier, slot_index, slot_pid, from) do
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

            _ = apply_layout(new_state)
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
            cond do
              pane_already_visible_reason?(reason) ->
                # The slot's attach pane is already in the visible
                # window — common after an in-place /tui/select-session
                # swap on a pane the user already had open. Treat as
                # success: record the new (identifier, pane_id) and
                # leave the slot's visible_identifier intact so future
                # swaps can take the API fast-path.
                new_state =
                  state
                  |> record_slot_pane(slot_index, pane_id, identifier)
                  |> Map.put(:last_attached_pane_id, pane_id)

                AgentPubSub.broadcast_status_change(identifier, :pane_opened)
                bump_next_slot()
                reply_or_noreply({:ok, pane_id}, from, new_state)

              true ->
                Logger.warning(
                  "aiur_pane_manager phase=open_move_failed identifier=#{identifier} slot=#{slot_index} reason=#{inspect(reason)}"
                )

                _ = Slot.deselect(slot_pid)
                reply_or_noreply({:error, reason}, from, state)
            end
        end

      {:error, reason} ->
        Logger.warning(
          "aiur_pane_manager phase=open_select_failed identifier=#{identifier} slot=#{slot_index} reason=#{inspect(reason)}"
        )

        reply_or_noreply({:error, reason}, from, state)
    end
  end

  defp pane_already_visible_reason?(reason) do
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
  defp attach_to_focused_pane(state, identifier, from) do
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
            # can claim it, but leave the pane bookkeeping intact —
            # Slot.set_visible may reuse the existing pane in-place via
            # /tui/select-session (no respawn) when the pane is already
            # painted on a conversation. If it does have to respawn,
            # respawn_attach_with_session kills the old pane itself.
            new_state = forget_identifier_for_pane(state, pane_id)
            attach_identifier_to_slot(new_state, identifier, slot_index, slot_pid, from)

          :not_found ->
            new_state = %{state | last_attached_pane_id: nil}
            {:reply, {:error, :no_focused_pane}, new_state}
        end
    end
  end

  defp reply_or_noreply(result, nil = _from, new_state), do: {:reply, result, new_state}

  defp reply_or_noreply(result, from, new_state) do
    GenServer.reply(from, result)
    {:noreply, new_state}
  end

  defp enqueue_open(state, identifier, from) do
    case Map.has_key?(state.open_queue_timers, identifier) do
      true ->
        # Duplicate open while a previous one for the same identifier is
        # still queued. Refuse rather than coalesce — simpler to reason
        # about, and the original caller will still eventually receive
        # a reply (success or :no_ready_slot timeout).
        {:reply, {:error, :already_queued}, state}

      false ->
        timer_ref = Process.send_after(self(), {:open_queue_timeout, identifier}, @open_queue_timeout_ms)
        new_queue = :queue.in({identifier, from, timer_ref}, state.open_queue)
        new_timers = Map.put(state.open_queue_timers, identifier, timer_ref)

        new_state = %{state | open_queue: new_queue, open_queue_timers: new_timers}

        Logger.info("aiur_pane_manager phase=open_queued elapsed_ms=#{Boot.elapsed_ms()} identifier=#{identifier} queue_depth=#{:queue.len(new_queue)}")

        {:noreply, new_state}
    end
  end

  defp advance_cycle(%__MODULE__{} = state) do
    %{state | cycle_index: rem(state.cycle_index + 1, state.slot_count)}
  end

  defp open_in_slot(state, slot, identifier, wrapped) do
    Logger.info(
      "PaneManager opening identifier=#{identifier} into slot=#{slot} " <>
        "agent_list_pane=#{state.agent_list_pane}"
    )

    case Map.get(state.slot_panes, slot) do
      nil ->
        create_pane_for_slot(state, slot, identifier, wrapped)

      existing_pane ->
        replace_in_slot(state, slot, existing_pane, identifier, wrapped)
    end
  end

  defp replace_in_slot(state, slot, existing_pane, identifier, wrapped) do
    case Tmux.respawn_pane(state.tmux, existing_pane, wrapped) do
      :ok ->
        new_state =
          state
          |> forget_identifier_for_pane(existing_pane)
          |> record_slot_pane(slot, existing_pane, identifier)

        {:ok, existing_pane, new_state}

      {:error, _} ->
        # Cached pane id is stale (tmux killed it under us). Forget it
        # and create a fresh pane in this slot.
        create_pane_for_slot(forget_dead_slot(state, slot), slot, identifier, wrapped)
    end
  end

  defp create_pane_for_slot(state, slot, identifier, wrapped) do
    # Split anchor is always the agent-list pane. Position is irrelevant
    # — the layout string applied after the open will reposition every
    # pane in the window. Direction and percent are arbitrary defaults.
    case Tmux.split_pane(state.tmux, state.agent_list_pane, :horizontal, 50, wrapped) do
      {:ok, pane_id} ->
        new_state = record_slot_pane(state, slot, pane_id, identifier)
        {:ok, pane_id, new_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Layout application -------------------------------------------------------

  defp apply_layout(state) do
    with {:ok, {w, h}} <- Tmux.window_size(state.tmux, state.agent_list_pane),
         layout_string =
           Layout.build(
             w,
             h,
             state.max_vertical_panes,
             state.agent_list_pane,
             slot_panes_list(state),
             state.orientation
           ),
         :ok <- Tmux.select_layout(state.tmux, state.window_target, layout_string) do
      :ok
    else
      {:error, reason} = err ->
        Logger.warning("PaneManager: layout apply failed: #{inspect(reason)}")
        err
    end
  end

  defp slot_panes_list(%__MODULE__{} = state) do
    placeholder_slots =
      state.placeholder_panes
      |> Map.values()
      |> Map.new(fn %{pane_id: pane_id, slot: slot} -> {slot, pane_id} end)

    for slot <- 1..state.slot_count do
      Map.get(placeholder_slots, slot) || Map.get(state.slot_panes, slot)
    end
  end

  defp first_available_visual_slot(%__MODULE__{} = state) do
    state
    |> slot_panes_list()
    |> Enum.find_index(&is_nil/1)
    |> case do
      nil -> nil
      index -> index + 1
    end
  end

  defp slot_count(max_vertical_panes), do: max_vertical_panes * 2 - 1

  defp empty_slot_panes(slot_count) do
    Map.new(1..slot_count, fn slot -> {slot, nil} end)
  end

  # State bookkeeping --------------------------------------------------------

  defp record_slot_pane(%__MODULE__{} = state, slot, pane_id, identifier) do
    %{
      state
      | identifier_to_pane: Map.put(state.identifier_to_pane, identifier, pane_id),
        pane_to_identifier: Map.put(state.pane_to_identifier, pane_id, identifier),
        pane_to_slot: Map.put(state.pane_to_slot, pane_id, slot),
        slot_panes: Map.put(state.slot_panes, slot, pane_id)
    }
  end

  defp forget_identifier_for_pane(%__MODULE__{} = state, pane_id) do
    case Map.get(state.pane_to_identifier, pane_id) do
      nil ->
        state

      old_identifier ->
        %{state | identifier_to_pane: Map.delete(state.identifier_to_pane, old_identifier)}
    end
  end

  defp forget_pane_by_identifier(%__MODULE__{} = state, pane_id) do
    identifier = Map.get(state.pane_to_identifier, pane_id)
    slot = Map.get(state.pane_to_slot, pane_id)

    new_state = %{
      state
      | pane_to_identifier: Map.delete(state.pane_to_identifier, pane_id),
        pane_to_slot: Map.delete(state.pane_to_slot, pane_id)
    }

    new_state =
      if identifier do
        %{new_state | identifier_to_pane: Map.delete(new_state.identifier_to_pane, identifier)}
      else
        new_state
      end

    if slot do
      %{new_state | slot_panes: Map.put(new_state.slot_panes, slot, nil)}
    else
      new_state
    end
  end

  defp forget_dead_slot(%__MODULE__{} = state, slot) do
    case Map.get(state.slot_panes, slot) do
      nil -> state
      pane_id -> forget_pane_by_identifier(state, pane_id)
    end
  end

  defp handle_pane_closed(state, pane_id) do
    case Map.fetch(state.pane_to_identifier, pane_id) do
      {:ok, identifier} ->
        AgentPubSub.broadcast_status_change(identifier, :pane_closed)
        new_state = forget_pane_by_identifier(state, pane_id)
        _ = apply_layout(new_state)
        new_state

      :error ->
        # Unknown pane (could be the agent-list pane itself, a loading
        # placeholder, or a transient probe). Still clear any stale slot
        # or placeholder mapping.
        new_state =
          state
          |> forget_pane_by_identifier(pane_id)
          |> drop_placeholder_by_pane(pane_id)

        _ = apply_layout(new_state)
        new_state
    end
  end

  defp reconcile_visible_panes(%__MODULE__{} = state) do
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

    forget_pane_by_identifier(state, pane_id)
  end

  defp drop_stale_placeholders(state, live_panes) do
    state.placeholder_panes
    |> Enum.reject(fn {_identifier, %{pane_id: pane_id}} -> MapSet.member?(live_panes, pane_id) end)
    |> Enum.reduce(state, fn {identifier, %{pane_id: pane_id, slot: slot}}, acc ->
      Logger.info("aiur_pane_manager phase=reconcile_drop_stale_placeholder identifier=#{identifier} slot=#{slot} pane_id=#{pane_id}")
      drop_placeholder(acc, identifier)
    end)
  end

  defp drop_placeholder_by_pane(state, pane_id) do
    case Enum.find(state.placeholder_panes, fn {_identifier, placeholder} ->
           placeholder.pane_id == pane_id
         end) do
      {identifier, _placeholder} -> drop_placeholder(state, identifier)
      nil -> state
    end
  end

  # Distribution wrapping ----------------------------------------------------

  defp wrap_with_unique_node(command, identifier) do
    safe_id = String.replace(identifier, ~r/[^A-Za-z0-9_-]/, "-")
    suffix = Integer.to_string(System.unique_integer([:positive]), 36)
    node_long = "pane-#{safe_id}-#{suffix}@127.0.0.1"

    # The pane BEAM uses a LONG node name (`name@127.0.0.1`) to match the
    # parent aiur BEAM. Long names with an explicit IP sidestep
    # `/etc/hosts` weirdness (Debian-style boxes map the hostname to
    # 127.0.1.1 while we listen on 127.0.0.1, and the IP mismatch shows up
    # as a silent `Node.connect -> false`).
    #
    # tmux passes the resulting string to `/bin/sh -c`, so the value of
    # ERL_AFLAGS is parsed once by /bin/sh and then again by the BEAM's
    # argv splitter. Double quotes around the value let us embed
    # `{127,0,0,1}` without /bin/sh's single-quote rules tripping on it.
    cookie_flag =
      case read_erlang_cookie() do
        cookie when is_binary(cookie) and cookie != "" -> " -setcookie #{cookie}"
        _ -> ""
      end

    dist_flags = " -proto_dist inet_tcp -kernel inet_dist_use_interface {127,0,0,1}"

    "env ERL_AFLAGS=\"-name #{node_long}#{cookie_flag}#{dist_flags}\" #{command}"
  end

  # Lazy slot expansion: after the user opens another chat pane,
  # ask SlotPolicy to start the next slot. Idempotent and rate-limited
  # by SlotPolicy itself, so calling it on every successful open is
  # safe.
  defp bump_next_slot do
    SlotPolicy.bump()
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp read_erlang_cookie do
    case System.get_env("AIUR_ERLANG_COOKIE") do
      env when is_binary(env) and env != "" ->
        String.trim(env)

      _ ->
        path = Path.join(System.user_home!(), ".erlang.cookie")

        case File.read(path) do
          {:ok, contents} -> String.trim(contents)
          {:error, _} -> nil
        end
    end
  rescue
    _ -> nil
  end
end
